const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the hty demo wrapper");
    const test_step = b.step("test", "Run Zig unit tests");

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

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
