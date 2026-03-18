//! Platform-aware directory resolution for zigit.
//!
//! Follows XDG Base Directory specification on Linux, Apple conventions on
//! macOS, and APPDATA/LOCALAPPDATA on Windows.
//!
//! All returned slices are heap-allocated and owned by the caller.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

fn getEnv(allocator: Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

/// Data directory: where zigit.db lives.
///
/// - Linux:   $XDG_DATA_HOME/zigit/   or  ~/.local/share/zigit/
/// - macOS:   ~/Library/Application Support/zigit/
/// - Windows: %APPDATA%\zigit\
pub fn dataDir(allocator: Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            const appdata = getEnv(allocator, "APPDATA") orelse
                return error.MissingEnvVar;
            defer allocator.free(appdata);
            return std.fs.path.join(allocator, &.{ appdata, "zigit" });
        },
        .macos => {
            const home = getEnv(allocator, "HOME") orelse return error.MissingEnvVar;
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "zigit" });
        },
        else => {
            if (getEnv(allocator, "XDG_DATA_HOME")) |xdg| {
                defer allocator.free(xdg);
                return std.fs.path.join(allocator, &.{ xdg, "zigit" });
            }
            const home = getEnv(allocator, "HOME") orelse return error.MissingEnvVar;
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, ".local", "share", "zigit" });
        },
    }
}

/// Cache root: where bare git clones and build artifacts live.
///
/// - Linux:   $XDG_CACHE_HOME/zigit/   or  ~/.cache/zigit/
/// - macOS:   ~/Library/Caches/zigit/
/// - Windows: %LOCALAPPDATA%\zigit\
pub fn cacheRoot(allocator: Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            const local = getEnv(allocator, "LOCALAPPDATA") orelse
                return error.MissingEnvVar;
            defer allocator.free(local);
            return std.fs.path.join(allocator, &.{ local, "zigit" });
        },
        .macos => {
            const home = getEnv(allocator, "HOME") orelse return error.MissingEnvVar;
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, "Library", "Caches", "zigit" });
        },
        else => {
            if (getEnv(allocator, "XDG_CACHE_HOME")) |xdg| {
                defer allocator.free(xdg);
                return std.fs.path.join(allocator, &.{ xdg, "zigit" });
            }
            const home = getEnv(allocator, "HOME") orelse return error.MissingEnvVar;
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, ".cache", "zigit" });
        },
    }
}

/// Directory where bare git clones are stored.
/// Format: <cache_root>/repos/
pub fn reposDir(allocator: Allocator) ![]const u8 {
    const root = try cacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "repos" });
}

/// Shared Zig build cache directory (set as ZIG_GLOBAL_CACHE_DIR).
/// Format: <cache_root>/build/
pub fn buildCacheDir(allocator: Allocator) ![]const u8 {
    const root = try cacheRoot(allocator);
    defer allocator.free(root);
    return std.fs.path.join(allocator, &.{ root, "build" });
}

/// Directory where installed binaries are placed.
///
/// - Linux/macOS: $XDG_BIN_HOME or ~/.local/bin/
/// - Windows:     %LOCALAPPDATA%\Programs\zigit\bin\
pub fn binDir(allocator: Allocator) ![]const u8 {
    switch (builtin.os.tag) {
        .windows => {
            const local = getEnv(allocator, "LOCALAPPDATA") orelse
                return error.MissingEnvVar;
            defer allocator.free(local);
            return std.fs.path.join(allocator, &.{ local, "Programs", "zigit", "bin" });
        },
        else => {
            if (getEnv(allocator, "XDG_BIN_HOME")) |xdg_bin| {
                return xdg_bin;
            }
            const home = getEnv(allocator, "HOME") orelse return error.MissingEnvVar;
            defer allocator.free(home);
            return std.fs.path.join(allocator, &.{ home, ".local", "bin" });
        },
    }
}

/// Absolute path to the SQLite database file.
/// Ensures the data directory exists.
pub fn dbPath(allocator: Allocator) ![:0]u8 {
    const dir = try dataDir(allocator);
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "zigit.db" });
    defer allocator.free(path);
    return allocator.dupeZ(u8, path);
}

/// Absolute path to the bare clone for a given (host, owner, repo).
/// Format: <repos_dir>/<host>/<owner>/<repo>.git
pub fn bareRepoPath(allocator: Allocator, host: []const u8, owner: []const u8, repo: []const u8) ![]const u8 {
    const repos = try reposDir(allocator);
    defer allocator.free(repos);
    const repo_dot_git = try std.fmt.allocPrint(allocator, "{s}.git", .{repo});
    defer allocator.free(repo_dot_git);
    return std.fs.path.join(allocator, &.{ repos, host, owner, repo_dot_git });
}

/// Ensure all runtime directories exist on startup.
pub fn ensureDirs(allocator: Allocator) !void {
    inline for (.{ dataDir, reposDir, buildCacheDir, binDir }) |fn_ptr| {
        const dir = try fn_ptr(allocator);
        defer allocator.free(dir);
        try std.fs.cwd().makePath(dir);
    }
}
