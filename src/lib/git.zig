//! Git operations for fetching repository information
const std = @import("std");
const builtin = @import("builtin");

const Allocator = std.mem.Allocator;

/// Repository information
pub const RepoInfo = struct {
    commit_hash: []const u8,
    current_branch: ?[]const u8,
    current_tag: ?[]const u8,
    description: ?[]const u8,
    author: ?[]const u8,
};

/// Get repository information from a local git repository
pub fn getRepoInfo(allocator: Allocator, repo_path: []const u8) !RepoInfo {
    // Get current commit hash
    const commit_hash = try runGitCommand(allocator, repo_path, &.{"rev-parse", "HEAD"});
    errdefer allocator.free(commit_hash);

    // Get current branch
    const branch_output = runGitCommand(allocator, repo_path, &.{"rev-parse", "--abbrev-ref", "HEAD"}) catch null;
    const current_branch = if (branch_output) |b| b else null;

    // Get current tag (if any)
    const tag_output = runGitCommand(allocator, repo_path, &.{"describe", "--tags", "--exact-match", "HEAD"}) catch null;
    const current_tag = if (tag_output) |t| t else null;

    // Try to read README.md for description
    const description = readReadme(allocator, repo_path) catch null;

    // Get author from git config
    const author = runGitCommand(allocator, repo_path, &.{"config", "user.name"}) catch null;

    return RepoInfo{
        .commit_hash = commit_hash,
        .current_branch = current_branch,
        .current_tag = current_tag,
        .description = description,
        .author = author,
    };
}

/// Clone a repository to a temporary location
pub fn cloneToTemp(allocator: Allocator, repo_url: []const u8) ![]const u8 {
    const tmp_env = if (@import("builtin").os.tag == .windows) "TEMP" else "TMPDIR";
    const tmp_dir_owned = std.process.getEnvVarOwned(allocator, tmp_env) catch
        std.process.getEnvVarOwned(allocator, "TMP") catch null;
    defer if (tmp_dir_owned) |d| allocator.free(d);

    const tmp_base = if (tmp_dir_owned) |d| d else (if (@import("builtin").os.tag == .windows) "C:\\Temp" else "/tmp");

    // Create temporary directory
    const temp_path = try std.fmt.allocPrint(allocator, "{s}/zigit-{d}", .{ tmp_base, std.time.timestamp() });
    try std.fs.cwd().makePath(temp_path);

    // Clone the repository
    _ = try runGitCommand(allocator, ".", &.{ "clone", "--depth", "1", repo_url, temp_path });

    return temp_path;
}

/// Run a git command and return its output
fn runGitCommand(allocator: Allocator, cwd: []const u8, args: []const []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var argv = std.ArrayList([]const u8).initCapacity(arena_allocator, args.len + 1) catch return error.OutOfMemory;
    try argv.append(arena_allocator, "git");
    for (args) |arg| {
        try argv.append(arena_allocator, arg);
    }

    const result = try std.process.Child.run(.{
        .allocator = arena_allocator,
        .argv = argv.items,
        .cwd = cwd,
        .max_output_bytes = 1024 * 1024, // 1MB max
    });

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                return error.GitCommandFailed;
            }
        },
        else => return error.GitCommandFailed,
    }

    // Trim whitespace and return
    const output = std.mem.trim(u8, result.stdout, " \n\r\t");
    return try allocator.dupe(u8, output);
}

/// Read README.md from repository
fn readReadme(allocator: Allocator, repo_path: []const u8) !?[]const u8 {
    const readme_paths = [_][]const u8{ "README.md", "README.txt", "README", "readme.md" };

    for (readme_paths) |readme_name| {
        const full_path = try std.fs.path.join(allocator, &.{ repo_path, readme_name });
        defer allocator.free(full_path);

        const file = std.fs.cwd().openFile(full_path, .{}) catch continue;
        defer file.close();

        // Read file using readToEndAlloc
        const content = try file.readToEndAlloc(allocator, 1024 * 10); // 10KB max
        defer allocator.free(content);

        // Extract first paragraph or first few lines as description
        if (std.mem.indexOf(u8, content, "\n\n")) |double_newline| {
            return try allocator.dupe(u8, content[0..double_newline]);
        }
        if (std.mem.indexOf(u8, content, "\n")) |newline| {
            return try allocator.dupe(u8, content[0..newline]);
        }
        return try allocator.dupe(u8, content);
    }

    return null;
}

