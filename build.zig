const std = @import("std");
const fangz_build = @import("fangz");
const release_build = @import("release.build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod_name = "zigit";

    const sqlite_dep = b.dependency(
        "sqlite",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    const fangz_dep = b.dependency(
        "fangz",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    const fugaz_dep = b.dependency(
        "fugaz",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    const vereda_dep = b.dependency(
        "vereda",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    const carnaval_dep = b.dependency(
        "carnaval",
        .{
            .target = target,
            .optimize = optimize,
        },
    );

    const fangz_mod = fangz_dep.module("fangz");
    const sqlite_mod = sqlite_dep.module("sqlite");
    const fugaz_mod = fugaz_dep.module("fugaz");
    const vereda_mod = vereda_dep.module("vereda");
    const carnaval_mod = carnaval_dep.module("carnaval");

    const lib_mod = b.addModule(mod_name, .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sqlite", .module = sqlite_mod },
            .{ .name = "fugaz", .module = fugaz_mod },
            .{ .name = "vereda", .module = vereda_mod },
            .{ .name = "carnaval", .module = carnaval_mod },
        },
    });

    const cli_step = b.step("cli", "Test the CLI");

    const exe = b.addExecutable(.{
        .name = mod_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigit", .module = lib_mod },
                .{ .name = "fangz", .module = fangz_mod },
                .{ .name = "carnaval", .module = carnaval_mod },
                .{ .name = "fugaz", .module = fugaz_mod },
            },
        }),
    });

    fangz_build.injectMeta(b, exe, fangz_mod);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    cli_step.dependOn(&run_cmd.step);
    release_build.addReleaseStep(b, mod_name, fangz_build);
}
