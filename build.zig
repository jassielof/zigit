const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const name = "zigit";

    const sqlite_dep = b.dependency("sqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const fangz_dep = b.dependency("fangz", .{
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule(name, .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_dep.module("sqlite") },
        },
    });

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "zigit", .module = mod }, .{ .name = "sqlite", .module = sqlite_dep.module("sqlite") }, .{ .name = "fangz", .module = fangz_dep.module("fangz") } },
        }),
    });

    b.installArtifact(exe);
    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const docs = b.addInstallDirectory(.{
        .source_dir = exe.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step("docs", "Generate documentation");
    docs_step.dependOn(&docs.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/tests/suite.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = name, .module = mod }} }) });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("tests", "Run tests");
    test_step.dependOn(&run_tests.step);
}
