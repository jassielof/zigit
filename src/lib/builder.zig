//! Build detection and invocation for checked-out Zig projects.
//!
//! Only `zig build` is supported (build.zig required).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const fugaz = @import("fugaz");

/// Rename `old_path` to `new_path`, replacing the destination if it exists.
///
/// On Windows, Zig's `Dir.rename` goes through `NtSetInformationFile` which
/// fails with `AccessDenied` when the source is the currently-running
/// executable (the Windows image loader holds an incompatible share mode at
/// that layer).  `MoveFileExW` uses a higher-level Win32 code path that
/// respects the `FILE_SHARE_DELETE` flag the loader sets and succeeds for
/// running executables on NTFS.
fn renameFile(allocator: Allocator, old_path: []const u8, new_path: []const u8) !void {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const old_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, old_path);
        defer allocator.free(old_w);
        const new_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, new_path);
        defer allocator.free(new_w);
        const MOVEFILE_REPLACE_EXISTING: windows.DWORD = 0x00000001;
        if (windows.kernel32.MoveFileExW(old_w.ptr, new_w.ptr, MOVEFILE_REPLACE_EXISTING) == 0) {
            return switch (windows.kernel32.GetLastError()) {
                .ACCESS_DENIED => error.AccessDenied,
                .FILE_NOT_FOUND => error.FileNotFound,
                .SHARING_VIOLATION => error.FileBusy,
                else => |err| windows.unexpectedError(err),
            };
        }
        return;
    }
    return std.fs.cwd().rename(old_path, new_path);
}

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

    // Install into a temp prefix instead of zig-out. Building the same repo as the running
    // zigit process would otherwise try to overwrite zig-out/bin/zigit.exe on Windows
    // (and some Unix setups) while the file is still mapped/locked.
    var prefix_tmp = try fugaz.tempDir(allocator);
    defer prefix_tmp.deinit();
    const prefix_path = prefix_tmp.path();

    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    try env.put("ZIG_GLOBAL_CACHE_DIR", build_cache_dir);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "build", optimize_flag, "--prefix", prefix_path },
        .cwd = worktree_path,
        .max_output_bytes = 8 * 1024 * 1024,
        .env_map = &env,
    }) catch return error.BuildFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                std.log.err("zig build failed:\n{s}", .{result.stderr});
                return error.BuildFailed;
            }
            // Print build output so user sees compilation progress
            if (result.stderr.len > 0) {
                var buf: [8192]u8 = undefined;
                var w = std.fs.File.stderr().writer(&buf);
                w.interface.print("{s}", .{result.stderr}) catch {};
                w.interface.flush() catch {};
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

    const src_path = try std.fs.path.join(allocator, &.{ prefix_path, "bin", binary_file });
    defer allocator.free(src_path);

    // Ensure destination directory exists
    try std.fs.cwd().makePath(dest_dir);

    const dest_file = try std.fmt.allocPrint(allocator, "{s}{s}", .{ binary_name, exe_ext });
    defer allocator.free(dest_file);
    const dest_path = try std.fs.path.join(allocator, &.{ dest_dir, dest_file });
    errdefer allocator.free(dest_path);

    const old_path = try std.fmt.allocPrint(allocator, "{s}.old", .{dest_path});
    defer allocator.free(old_path);
    const stage_path = try std.fmt.allocPrint(allocator, "{s}.new", .{dest_path});
    defer allocator.free(stage_path);

    const file_exists = blk: {
        std.fs.cwd().access(dest_path, .{}) catch break :blk false;
        break :blk true;
    };

    // Clean up any leftovers from a previous self-update attempt before
    // touching the destination. On Windows you cannot delete or write over a
    // running executable, but you CAN rename it on NTFS.  The strategy is:
    //
    //   1. Copy new binary to <dest>.new   (no locking — new file)
    //   2. Rename <dest>  → <dest>.old     (NTFS: rename of running exe is ok)
    //   3. Rename <dest>.new → <dest>      (fast, <dest> is now free)
    //   4. Delete <dest>.old               (may fail if still in use — ignored)
    std.fs.cwd().deleteFile(old_path) catch {};
    std.fs.cwd().deleteFile(stage_path) catch {};

    // Step 1: stage the new binary
    try std.fs.cwd().copyFile(src_path, std.fs.cwd(), stage_path, .{});
    errdefer std.fs.cwd().deleteFile(stage_path) catch {};

    // Step 2: move the current binary aside
    if (file_exists) {
        try renameFile(allocator, dest_path, old_path);
    }

    // Step 3: promote the staged binary
    renameFile(allocator, stage_path, dest_path) catch |err| {
        if (file_exists) renameFile(allocator, old_path, dest_path) catch {};
        return err;
    };

    // Step 4: remove the old binary; silently ignored when still in use
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
