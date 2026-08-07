const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pg_module = b.dependency("pg", .{}).module("pg");

    const core_mod = b.createModule(.{
        .root_source_file = b.path("core/src/zpg.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pg", .module = pg_module },
        },
    });

    const exe_tui = b.addExecutable(.{
        .name = "zpg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tui/src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
            },
        }),
    });
    b.installArtifact(exe_tui);

    const lib_gui = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zpg",
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/src/ffi.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });
    b.installArtifact(lib_gui);

    const run_cmd = b.addRunArtifact(exe_tui);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the TUI app");
    run_step.dependOn(&run_cmd.step);

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("core/src/zpg.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pg", .module = pg_module },
            },
        }),
    });

    const run_core_tests = b.addRunArtifact(core_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_core_tests.step);
}
