//! Path utilities following XDG convention (cross-platform)
const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// Get the base directory for zigit data (following XDG convention)
/// On Windows: %USERPROFILE%\.zigit
/// On Unix: $HOME/.zigit or $XDG_DATA_HOME/zigit
pub fn getZigitDataDir(allocator: Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const userprofile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(userprofile);
        return try std.fmt.allocPrint(allocator, "{s}\\.zigit", .{userprofile});
    } else {
        // Try XDG_DATA_HOME first, fallback to HOME/.local/share
        if (std.process.getEnvVarOwned(allocator, "XDG_DATA_HOME")) |xdg_data| {
            defer allocator.free(xdg_data);
            return try std.fmt.allocPrint(allocator, "{s}/zigit", .{xdg_data});
        } else |_| {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            return try std.fmt.allocPrint(allocator, "{s}/.local/share/zigit", .{home});
        }
    }
}

/// Get the cache directory for zigit (following XDG convention)
/// On Windows: %USERPROFILE%\.zigit\cache
/// On Unix: $HOME/.cache/zigit or $XDG_CACHE_HOME/zigit
pub fn getZigitCacheDir(allocator: Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const userprofile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(userprofile);
        return try std.fmt.allocPrint(allocator, "{s}\\.zigit\\cache", .{userprofile});
    } else {
        // Try XDG_CACHE_HOME first, fallback to HOME/.cache
        if (std.process.getEnvVarOwned(allocator, "XDG_CACHE_HOME")) |xdg_cache| {
            defer allocator.free(xdg_cache);
            return try std.fmt.allocPrint(allocator, "{s}/zigit", .{xdg_cache});
        } else |_| {
            const home = try std.process.getEnvVarOwned(allocator, "HOME");
            defer allocator.free(home);
            return try std.fmt.allocPrint(allocator, "{s}/.cache/zigit", .{home});
        }
    }
}

/// Get the bin directory for zigit (where binaries are installed)
/// On Windows: %USERPROFILE%\.zigit\bin
/// On Unix: $HOME/.local/bin (or $XDG_DATA_HOME/../bin)
pub fn getZigitBinDir(allocator: Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const userprofile = try std.process.getEnvVarOwned(allocator, "USERPROFILE");
        defer allocator.free(userprofile);
        return try std.fmt.allocPrint(allocator, "{s}\\.zigit\\bin", .{userprofile});
    } else {
        const home = try std.process.getEnvVarOwned(allocator, "HOME");
        defer allocator.free(home);
        return try std.fmt.allocPrint(allocator, "{s}/.local/bin", .{home});
    }
}

/// Get the database path
pub fn getDatabasePath(allocator: Allocator) ![:0]const u8 {
    const data_dir = try getZigitDataDir(allocator);
    defer allocator.free(data_dir);

    // Ensure directory exists
    try std.fs.cwd().makePath(data_dir);

    const db_path = try std.fmt.allocPrint(allocator, "{s}/zigit.db", .{data_dir});
    const db_path_z = try allocator.dupeZ(u8, db_path);
    allocator.free(db_path);
    return db_path_z;
}

/// Get the cache path for a repository
/// Format: <cache_dir>/<hosting_platform>/<user>/<repo>
pub fn getRepositoryCachePath(allocator: Allocator, repo_url: []const u8) ![]const u8 {
    const cache_dir = try getZigitCacheDir(allocator);
    defer allocator.free(cache_dir);

    // Parse URL to extract platform/user/repo
    const repo_path = try extractRepoPath(repo_url);
    defer allocator.free(repo_path);

    return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ cache_dir, repo_path });
}

/// Extract repository path from URL
/// Converts: https://github.com/user/repo.git -> github.com/user/repo
///          git@github.com:user/repo.git -> github.com/user/repo
fn extractRepoPath(url: []const u8) ![]const u8 {
    const allocator = std.heap.page_allocator;
    var url_copy = try allocator.dupe(u8, url);
    defer allocator.free(url_copy);

    // Remove .git suffix
    if (std.mem.endsWith(u8, url_copy, ".git")) {
        url_copy = url_copy[0..url_copy.len - 4];
    }

    // Handle git@ format: git@host:user/repo -> host/user/repo
    if (std.mem.startsWith(u8, url_copy, "git@")) {
        if (std.mem.indexOf(u8, url_copy, ":")) |colon_idx| {
            const host = url_copy[4..colon_idx];
            const path = url_copy[colon_idx + 1..];
            return try std.fmt.allocPrint(allocator, "{s}/{s}", .{ host, path });
        }
    }

    // Handle https:// or http:// format
    if (std.mem.indexOf(u8, url_copy, "://")) |protocol_idx| {
        const after_protocol = url_copy[protocol_idx + 3..];
        return try allocator.dupe(u8, after_protocol);
    }

    // Already in the right format
    return try allocator.dupe(u8, url_copy);
}

