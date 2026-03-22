const std = @import("std");

pub const ReleaseTarget = struct {
    query: std.Target.Query,
    name: []const u8,
};

pub const targets = [_]ReleaseTarget{
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .linux }, .name = "x86_64-linux" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .linux }, .name = "aarch64-linux" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .macos }, .name = "x86_64-macos" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .macos }, .name = "aarch64-macos" },
    .{ .query = .{ .cpu_arch = .x86_64, .os_tag = .windows }, .name = "x86_64-windows" },
    .{ .query = .{ .cpu_arch = .aarch64, .os_tag = .windows }, .name = "aarch64-windows" },
};

/// fangz_build is anytype because it comes from a named dep import
/// that only resolves in the root build.zig — we accept it as a value.
pub fn addReleaseStep(
    b: *std.Build,
    mod_name: []const u8,
    fangz_build: anytype,
) void {
    const release_step = b.step("release", "Release the app");
    const rel_optimize: std.builtin.OptimizeMode = .ReleaseSafe;

    for (targets) |platform| {
        const rel_target = b.resolveTargetQuery(platform.query);

        const rel_sqlite_dep = b.dependency("sqlite", .{ .target = rel_target, .optimize = rel_optimize });
        const rel_fangz_dep = b.dependency("fangz", .{ .target = rel_target, .optimize = rel_optimize });
        const rel_fugaz_dep = b.dependency("fugaz", .{ .target = rel_target, .optimize = rel_optimize });
        const rel_vereda_dep = b.dependency("vereda", .{ .target = rel_target, .optimize = rel_optimize });
        const rel_carnaval_dep = b.dependency("carnaval", .{ .target = rel_target, .optimize = rel_optimize });

        const rel_fangz_mod = rel_fangz_dep.module("fangz");

        const rel_lib_mod = b.createModule(.{
            .root_source_file = b.path("src/lib/root.zig"),
            .target = rel_target,
            .optimize = rel_optimize,
            .imports = &.{
                .{ .name = "sqlite", .module = rel_sqlite_dep.module("sqlite") },
                .{ .name = "fugaz", .module = rel_fugaz_dep.module("fugaz") },
                .{ .name = "vereda", .module = rel_vereda_dep.module("vereda") },
                .{ .name = "carnaval", .module = rel_carnaval_dep.module("carnaval") },
            },
        });

        const rel_exe = b.addExecutable(.{
            .name = mod_name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/cli/main.zig"),
                .target = rel_target,
                .optimize = rel_optimize,
                .imports = &.{
                    .{ .name = "zigit", .module = rel_lib_mod },
                    .{ .name = "fangz", .module = rel_fangz_mod },
                    .{ .name = "carnaval", .module = rel_carnaval_dep.module("carnaval") },
                    .{ .name = "fugaz", .module = rel_fugaz_dep.module("fugaz") },
                },
            }),
        });

        fangz_build.injectMeta(b, rel_exe, rel_fangz_mod);

        const install = b.addInstallArtifact(rel_exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("release/{s}", .{platform.name}) } },
        });

        const is_windows = platform.query.os_tag == .windows;
        const exe_name = if (is_windows) b.fmt("{s}.exe", .{mod_name}) else mod_name;
        const bin_path = b.pathJoin(&.{ b.install_prefix, "release", platform.name, exe_name });

        const compress = if (is_windows) blk: {
            const archive = b.pathJoin(&.{ b.install_prefix, "release", b.fmt("{s}-{s}.zip", .{ mod_name, platform.name }) });
            const cmd = b.addSystemCommand(&.{ "zip", "-j", archive, bin_path });
            cmd.step.dependOn(&install.step);
            break :blk cmd;
        } else blk: {
            const archive = b.pathJoin(&.{ b.install_prefix, "release", b.fmt("{s}-{s}.tar.gz", .{ mod_name, platform.name }) });
            const src_dir = b.pathJoin(&.{ b.install_prefix, "release", platform.name });
            const cmd = b.addSystemCommand(&.{ "tar", "-czf", archive, "-C", src_dir, exe_name });
            cmd.step.dependOn(&install.step);
            break :blk cmd;
        };

        // ── Cleanup: remove the per-target dir after archiving ────────────────
        const target_dir = b.pathJoin(&.{ b.install_prefix, "release", platform.name });
        const remove_dir = b.addRemoveDirTree(.{ .cwd_relative = target_dir }); // ← no b.path()
        remove_dir.step.dependOn(&compress.step);

        release_step.dependOn(&remove_dir.step);
    }
}
