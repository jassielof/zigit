//! Build detection and invocation for checked-out Zig projects.
//!
//! Only `zig build` is supported (build.zig required).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const OptimizeMode = enum {
    ReleaseFast,
    ReleaseSafe,
    ReleaseSmall,

    pub fn asString(self: OptimizeMode) []const u8 {
        return switch (self) {
            .ReleaseFast => "ReleaseFast",
            .ReleaseSafe => "ReleaseSafe",
            .ReleaseSmall => "ReleaseSmall",
        };
    }

    pub fn fromString(s: []const u8) ?OptimizeMode {
        if (std.mem.eql(u8, s, "ReleaseFast")) return .ReleaseFast;
        if (std.mem.eql(u8, s, "ReleaseSafe")) return .ReleaseSafe;
        if (std.mem.eql(u8, s, "ReleaseSmall")) return .ReleaseSmall;
        return null;
    }
};

pub const BuildResult = struct {
    success: bool,
    output: []const u8,

    pub fn deinit(self: *BuildResult, allocator: Allocator) void {
        allocator.free(self.output);
    }
};

/// Build a Zig project in `worktree_path` and return the path to the
/// compiled binary. The binary is copied into `dest_dir/<binary_name>`.
///
/// Set ZIG_GLOBAL_CACHE_DIR to the shared build cache to speed repeated builds.
pub fn buildAndInstall(
    allocator: Allocator,
    worktree_path: []const u8,
    binary_name: []const u8,
    optimize: OptimizeMode,
    build_cache_dir: []const u8,
    dest_dir: []const u8,
) ![]u8 {
    const optimize_flag = try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{optimize.asString()});
    defer allocator.free(optimize_flag);

    // Invoke zig build
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build", optimize_flag },
        .cwd = worktree_path,
        .max_output_bytes = 8 * 1024 * 1024,
        .env_map = null,
    }) catch return error.BuildFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    _ = build_cache_dir;

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("zig build failed:\n{s}", .{result.stderr});
                return error.BuildFailed;
            }
        },
        else => return error.BuildFailed,
    }

    // Locate produced binary
    const exe_ext = switch (@import("builtin").os.tag) {
        .windows => ".exe",
        else => "",
    };
    const binary_file = try std.fmt.allocPrint(allocator, "{s}{s}", .{ binary_name, exe_ext });
    defer allocator.free(binary_file);

    const src_path = try std.fs.path.join(allocator, &.{ worktree_path, "zig-out", "bin", binary_file });
    defer allocator.free(src_path);

    // Ensure destination directory exists
    try std.fs.cwd().makePath(dest_dir);

    const dest_file = try std.fmt.allocPrint(allocator, "{s}{s}", .{ binary_name, exe_ext });
    defer allocator.free(dest_file);
    const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, dest_file });
    errdefer allocator.free(dest_path);

    // Atomic rename: old -> .old, copy new, remove .old
    const old_path = try std.fmt.allocPrint(allocator, "{s}.old", .{dest_path});
    defer allocator.free(old_path);

    const file_exists = blk: {
        std.fs.cwd().access(dest_path, .{}) catch break :blk false;
        break :blk true;
    };

    if (file_exists) {
        std.fs.cwd().rename(dest_path, old_path) catch {};
    }

    std.fs.cwd().copyFile(src_path, std.fs.cwd(), dest_path, .{}) catch |err| {
        // Restore on failure
        if (file_exists) {
            std.fs.cwd().rename(old_path, dest_path) catch {};
        }
        return err;
    };

    // Remove .old on success
    std.fs.cwd().deleteFile(old_path) catch {};

    return dest_path;
}

/// Returns true if the directory contains a build.zig file.
pub fn hasBuildZig(worktree_path: []const u8) bool {
    var dir = std.fs.cwd().openDir(worktree_path, .{}) catch return false;
    defer dir.close();
    const f = dir.openFile("build.zig", .{}) catch return false;
    f.close();
    return true;
}
