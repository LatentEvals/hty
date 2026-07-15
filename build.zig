const std = @import("std");
const builtin = @import("builtin");

// zon holds the last released version — the convention is to bump it
// in the same PR as the git tag, with the tag driving the display at
// release time. `@import("build.zig.zon")` is supported on Zig 0.15
// (ghostty/zls use the same trick); the field access below returns the
// `.version` string baked into the zon file.
const zon_version = @import("build.zig.zon").version;

const GitInfo = struct {
    commit: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    dirty: bool = false,
    describe: ?[]const u8 = null,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run Zig unit tests");

    // `-Dversion-string=STR` escape hatch for source-tarball / CI builds
    // where git isn't available or you want to force a specific value.
    // When set it takes precedence over both the exact-match tag and the
    // zon fallback.
    const version_override = b.option(
        []const u8,
        "version-string",
        "Force the build version string (overrides git tag + zon fallback)",
    );

    const git_info = collectGitInfo(b);

    // Paranoia check (ported from ghostty): if the working tree is on an
    // exact-match tag, assert the tag (minus leading `v`) equals the zon
    // `.version`. This catches "bumped one, forgot the other" at build
    // time rather than shipping a binary whose version disagrees with
    // the release tag. Skipped for dev / untagged builds.
    if (git_info.tag) |tag| {
        const bare_tag = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
        if (!std.mem.eql(u8, bare_tag, zon_version)) {
            std.debug.print(
                "tagged release {s} does not match build.zig.zon version \"{s}\"; update zon before tagging\n",
                .{ tag, zon_version },
            );
            std.process.exit(1);
        }
    }

    // Canonical version resolution:
    //   (a) -Dversion-string= if set,
    //   (b) tag from `git describe --exact-match` (strip leading `v`) if
    //       HEAD is tagged,
    //   (c) fallback to the zon `.version`.
    const resolved_version: []const u8 = resolved: {
        if (version_override) |v| break :resolved v;
        if (git_info.tag) |tag| {
            break :resolved if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
        }
        break :resolved zon_version;
    };

    const build_info_options = b.addOptions();
    build_info_options.addOption([]const u8, "version", resolved_version);
    build_info_options.addOption(?[]const u8, "commit", git_info.commit);
    build_info_options.addOption(?[]const u8, "tag", git_info.tag);
    build_info_options.addOption(bool, "dirty", git_info.dirty);
    build_info_options.addOption(?[]const u8, "describe", git_info.describe);
    build_info_options.addOption([]const u8, "mode", @tagName(optimize));

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // `build_info` is consumed by `src/commands/info.zig` (reachable
    // from the headless exe and its test targets) and by
    // `src/tests.zig` which lib_mod aggregates via comptime discovery.
    lib_mod.addOptions("build_info", build_info_options);

    // forkpty lives in libutil on Linux (glibc < 2.34 and musl). Modern
    // glibc moved it into libc proper so the link is effectively a
    // no-op, but we always link it on Linux to keep the build portable
    // across distros.
    if (target.result.os.tag == .linux) {
        lib_mod.linkSystemLibrary("util", .{});
    }

    if (b.lazyDependency("ghostty", .{})) |dep| {
        lib_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    // zg provides the Unicode `Normalize` module used to fold combining
    // marks into their precomposed form in the snapshot `cells` field.
    // zg is explicitly modular — we only pull in `Normalize` to keep
    // binary size bounded.
    if (b.lazyDependency("zg", .{})) |dep| {
        lib_mod.addImport("Normalize", dep.module("Normalize"));
    }

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "hty",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);

    const headless = b.addExecutable(.{
        .name = "hty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/headless.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "hty", .module = lib_mod },
            },
        }),
    });
    headless.root_module.addCSourceFile(.{ .file = b.path("src/regex_helper.c") });
    headless.root_module.addOptions("build_info", build_info_options);
    b.installArtifact(headless);

    // Custom test runner filters `.stream`-scoped warn logs from the
    // bundled ghostty-vt parser (see #6). Identical to Zig's default
    // runner in all other respects.
    const test_runner: std.Build.Step.Compile.TestRunner = .{
        .path = b.path("src/test_runner.zig"),
        .mode = .server,
    };

    const unit_tests = b.addTest(.{
        .root_module = lib_mod,
        .test_runner = test_runner,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    const headless_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/headless.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "hty", .module = lib_mod },
            },
        }),
        .test_runner = test_runner,
    });
    headless_tests.root_module.addCSourceFile(.{ .file = b.path("src/regex_helper.c") });
    headless_tests.root_module.addOptions("build_info", build_info_options);
    const run_headless_tests = b.addRunArtifact(headless_tests);
    test_step.dependOn(&run_headless_tests.step);

    // Event-loop core (src/loop.zig) tests are discovered through the
    // headless test module now that server.zig imports the loop; no
    // standalone test compilation needed anymore.

    // Golden-frame VT tests. cwd is pinned to the build root so the test can
    // read/write `testdata/vt/*.golden` regardless of where `zig build` was
    // invoked from.
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vt_golden_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "hty", .module = lib_mod },
            },
        }),
        .test_runner = test_runner,
    });
    const run_golden_tests = b.addRunArtifact(golden_tests);
    run_golden_tests.setCwd(b.path("."));
    test_step.dependOn(&run_golden_tests.step);

    // Real-program fixture tests. Same cwd pinning — reads session logs and
    // goldens from `testdata/sessions/`. The fixture suite is deterministic
    // because replay is pure byte-feeding into a fresh VT, so committed logs
    // produce the same grid on every OS.
    const fixture_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vt_fixture_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "hty", .module = lib_mod },
            },
        }),
        .test_runner = test_runner,
    });
    const run_fixture_tests = b.addRunArtifact(fixture_tests);
    run_fixture_tests.setCwd(b.path("."));
    test_step.dependOn(&run_fixture_tests.step);
}

/// Best-effort: shell out to git to collect commit / tag / dirty info
/// for the current tree. Any failure (git missing, not a repo, worktree
/// with shallow history, etc.) falls back to nulls — we never fail the
/// build for this.
fn collectGitInfo(b: *std.Build) GitInfo {
    var info: GitInfo = .{};

    info.commit = runGitLine(b, &.{ "git", "rev-parse", "--short", "HEAD" });
    // `--exact-match` returns non-zero when HEAD isn't a tag, which is
    // the common case on dev builds; we swallow that and leave tag null.
    info.tag = runGitLine(b, &.{ "git", "describe", "--tags", "--exact-match", "HEAD" });
    info.describe = runGitLine(b, &.{ "git", "describe", "--tags", "--always", "--dirty" });

    // `git status --porcelain` prints one line per modified entry and is
    // empty on a clean tree. Any non-empty output = dirty.
    if (runGitLineAllowEmpty(b, &.{ "git", "status", "--porcelain" })) |porcelain| {
        info.dirty = porcelain.len > 0;
    }

    return info;
}

/// Run a git command and return stdout with whitespace trimmed. Returns
/// null (rather than failing the build) if the command isn't available
/// or exits non-zero — e.g. `git describe --exact-match` on a non-tagged
/// commit.
fn runGitLine(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    var code: u8 = undefined;
    const raw = b.runAllowFail(argv, &code, .Ignore) catch return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return null;
    // Duplicate so we keep the trimmed slice after `raw` escapes this fn
    // — the allocator is the build allocator which lives for the whole
    // build, so leaking the original `raw` is fine.
    return b.allocator.dupe(u8, trimmed) catch null;
}

/// Same as `runGitLine` but allows empty stdout (used for the
/// `git status --porcelain` dirty-check where empty = clean).
fn runGitLineAllowEmpty(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    var code: u8 = undefined;
    const raw = b.runAllowFail(argv, &code, .Ignore) catch return null;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return b.allocator.dupe(u8, trimmed) catch null;
}
