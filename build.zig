const std = @import("std");
const builtin = @import("builtin");

// Canonical semver. Kept in lockstep with `build.zig.zon` — the build
// asserts below that the two match, which catches the "bumped one, forgot
// the other" bug at `zig build` time rather than at release time.
// `@import("build.zig.zon")` exists on 0.15 but is semi-stable; keeping a
// plain `const` here plus a runtime assertion is the simpler/robust path.
const hty_version = "0.0.0";

const GitInfo = struct {
    commit: ?[]const u8 = null,
    tag: ?[]const u8 = null,
    dirty: bool = false,
    describe: ?[]const u8 = null,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the hty demo wrapper");
    const test_step = b.step("test", "Run Zig unit tests");

    assertZonVersionMatches(b, hty_version);

    const build_info_options = b.addOptions();
    build_info_options.addOption([]const u8, "version", hty_version);
    const git_info = collectGitInfo(b);
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

    const exe = b.addExecutable(.{
        .name = "hty-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "hty", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

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

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.stdio = .inherit;
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = lib_mod,
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
    });
    headless_tests.root_module.addCSourceFile(.{ .file = b.path("src/regex_helper.c") });
    headless_tests.root_module.addOptions("build_info", build_info_options);
    const run_headless_tests = b.addRunArtifact(headless_tests);
    test_step.dependOn(&run_headless_tests.step);

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
    });
    const run_fixture_tests = b.addRunArtifact(fixture_tests);
    run_fixture_tests.setCwd(b.path("."));
    test_step.dependOn(&run_fixture_tests.step);
}

/// Verify the `const hty_version` in this file matches the `.version`
/// field in `build.zig.zon`. They're the same semver in two places; a
/// mismatch means one was bumped without the other. Failing here at
/// build time is much friendlier than shipping a binary whose
/// `hty info --json` reports a version that doesn't match the release
/// tag.
fn assertZonVersionMatches(b: *std.Build, expected: []const u8) void {
    const zon_bytes = std.fs.cwd().readFileAlloc(
        b.allocator,
        b.pathFromRoot("build.zig.zon"),
        64 * 1024,
    ) catch |err| {
        std.debug.print("warning: could not read build.zig.zon to verify version: {s}\n", .{@errorName(err)});
        return;
    };
    defer b.allocator.free(zon_bytes);

    const field = ".version";
    const field_idx = std.mem.indexOf(u8, zon_bytes, field) orelse {
        std.debug.print("warning: build.zig.zon has no .version field\n", .{});
        return;
    };
    const after = zon_bytes[field_idx + field.len ..];
    const open = std.mem.indexOfScalar(u8, after, '"') orelse return;
    const rest = after[open + 1 ..];
    const close = std.mem.indexOfScalar(u8, rest, '"') orelse return;
    const found = rest[0..close];
    if (!std.mem.eql(u8, found, expected)) {
        std.debug.print(
            "build.zig hty_version=\"{s}\" does not match build.zig.zon .version=\"{s}\"; update both in lockstep\n",
            .{ expected, found },
        );
        std.process.exit(1);
    }
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
