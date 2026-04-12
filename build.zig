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
    const run_headless_tests = b.addRunArtifact(headless_tests);
    test_step.dependOn(&run_headless_tests.step);
}
