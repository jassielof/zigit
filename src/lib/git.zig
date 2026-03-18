//! Git operations using bare clone + worktree strategy.
//!
//! All git interaction is via `std.process.Child` shelling out to the `git`
//! binary. No C library binding is used.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const GitError = error{
    GitNotFound,
    CommandFailed,
    ParseError,
    OutOfMemory,
};

/// Parsed components of a git remote URL.
pub const ParsedUrl = struct {
    host: []const u8,
    owner: []const u8,
    repo: []const u8,

    pub fn deinit(self: *const ParsedUrl, allocator: Allocator) void {
        allocator.free(self.host);
        allocator.free(self.owner);
        allocator.free(self.repo);
    }
};

/// Parse a git URL into (host, owner, repo).
///
/// Handles:
///   https://github.com/owner/repo
///   https://github.com/owner/repo.git
///   git@github.com:owner/repo.git
pub fn parseUrl(allocator: Allocator, url: []const u8) !ParsedUrl {
    var work = url;

    // Strip trailing .git
    if (std.mem.endsWith(u8, work, ".git")) {
        work = work[0 .. work.len - 4];
    }

    if (std.mem.startsWith(u8, work, "git@")) {
        // git@host:owner/repo
        const after_at = work[4..];
        const colon = std.mem.indexOfScalar(u8, after_at, ':') orelse return error.ParseError;
        const host = after_at[0..colon];
        const rest = after_at[colon + 1 ..];
        const slash = std.mem.lastIndexOfScalar(u8, rest, '/') orelse return error.ParseError;
        return ParsedUrl{
            .host = try allocator.dupe(u8, host),
            .owner = try allocator.dupe(u8, rest[0..slash]),
            .repo = try allocator.dupe(u8, rest[slash + 1 ..]),
        };
    }

    if (std.mem.indexOf(u8, work, "://")) |proto_end| {
        const after_proto = work[proto_end + 3 ..];
        const first_slash = std.mem.indexOfScalar(u8, after_proto, '/') orelse return error.ParseError;
        const host = after_proto[0..first_slash];
        const path = after_proto[first_slash + 1 ..];
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.ParseError;
        return ParsedUrl{
            .host = try allocator.dupe(u8, host),
            .owner = try allocator.dupe(u8, path[0..slash]),
            .repo = try allocator.dupe(u8, path[slash + 1 ..]),
        };
    }

    return error.ParseError;
}

/// Run a git command and return trimmed stdout. Caller owns the returned slice.
pub fn run(allocator: Allocator, cwd: ?[]const u8, args: []const []const u8) ![]u8 {
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args) |arg| try argv.append(allocator, arg);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = cwd,
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch return GitError.CommandFailed;
    defer allocator.free(result.stderr);
    defer allocator.free(result.stdout);

    switch (result.term) {
        .Exited => |code| if (code != 0) return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    }

    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n\t"));
}

/// Like `run` but also captures stderr, returned alongside stdout. Caller owns both.
pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: u8,

    pub fn deinit(self: *RunResult, allocator: Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub fn runCapture(allocator: Allocator, cwd: ?[]const u8, args: []const []const u8) !RunResult {
    var argv = try std.ArrayList([]const u8).initCapacity(allocator, args.len + 1);
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args) |arg| try argv.append(allocator, arg);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = cwd,
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch return GitError.CommandFailed;

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        else => 127,
    };

    return RunResult{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}

/// Perform a bare shallow clone.
///
/// git clone --bare --depth 1 --single-branch [--branch <ref>] <url> <dest>
pub fn cloneBare(allocator: Allocator, url: []const u8, dest: []const u8, ref: ?[]const u8) !void {
    // Ensure parent directory exists
    const parent = std.fs.path.dirname(dest) orelse ".";
    try std.fs.cwd().makePath(parent);

    var args = try std.ArrayList([]const u8).initCapacity(allocator, 10);
    defer args.deinit(allocator);

    try args.append(allocator, "clone");
    try args.append(allocator, "--bare");
    try args.append(allocator, "--depth");
    try args.append(allocator, "1");
    try args.append(allocator, "--single-branch");
    if (ref) |r| {
        try args.append(allocator, "--branch");
        try args.append(allocator, r);
    }
    try args.append(allocator, url);
    try args.append(allocator, dest);

    var argv = try std.ArrayList([]const u8).initCapacity(allocator, args.items.len + 1);
    defer argv.deinit(allocator);
    try argv.append(allocator, "git");
    for (args.items) |a| try argv.append(allocator, a);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch return GitError.CommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return GitError.CommandFailed,
        else => return GitError.CommandFailed,
    }
}

/// Fetch a ref into an existing bare repo.
///
/// git -C <bare_path> fetch --depth 1 origin <ref>
pub fn fetch(allocator: Allocator, bare_path: []const u8, ref: []const u8) !void {
    const out = try run(allocator, null, &.{ "-C", bare_path, "fetch", "--depth", "1", "origin", ref });
    allocator.free(out);
}

/// Resolve a ref to a full SHA. Caller owns the returned string.
pub fn revParse(allocator: Allocator, bare_path: []const u8, ref: []const u8) ![]u8 {
    return run(allocator, null, &.{ "-C", bare_path, "rev-parse", ref });
}

/// Get the remote default branch (e.g. "main" or "master"). Caller owns result.
pub fn defaultBranch(allocator: Allocator, bare_path: []const u8) ![]u8 {
    // HEAD -> refs/remotes/origin/HEAD -> refs/remotes/origin/main
    const sym = run(allocator, null, &.{ "-C", bare_path, "symbolic-ref", "refs/remotes/origin/HEAD" }) catch {
        // Fall back to checking remote HEAD
        return run(allocator, null, &.{ "-C", bare_path, "rev-parse", "--abbrev-ref", "origin/HEAD" });
    };
    defer allocator.free(sym);
    // sym looks like "refs/remotes/origin/main"
    const prefix = "refs/remotes/origin/";
    if (std.mem.startsWith(u8, sym, prefix)) {
        return allocator.dupe(u8, sym[prefix.len..]);
    }
    return allocator.dupe(u8, sym);
}

/// Add a worktree at `worktree_path` checked out at `commit`.
///
/// git -C <bare_path> worktree add <worktree_path> <commit>
pub fn worktreeAdd(allocator: Allocator, bare_path: []const u8, worktree_path: []const u8, commit: []const u8) !void {
    const out = try run(allocator, null, &.{ "-C", bare_path, "worktree", "add", "--detach", worktree_path, commit });
    allocator.free(out);
}

/// Remove a worktree from the bare repo.
///
/// git -C <bare_path> worktree remove --force <worktree_path>
pub fn worktreeRemove(allocator: Allocator, bare_path: []const u8, worktree_path: []const u8) void {
    const out = run(allocator, null, &.{ "-C", bare_path, "worktree", "remove", "--force", worktree_path }) catch return;
    allocator.free(out);
}

/// Prune stale worktree metadata from a bare repo.
pub fn worktreePrune(allocator: Allocator, bare_path: []const u8) void {
    const out = run(allocator, null, &.{ "-C", bare_path, "worktree", "prune" }) catch return;
    allocator.free(out);
}

/// Check whether a bare repo directory already exists.
pub fn bareExists(path: []const u8) bool {
    var dir = std.fs.cwd().openDir(path, .{}) catch return false;
    dir.close();
    return true;
}

/// Detect the binary name from a worktree.
/// Looks for build.zig and, if found, returns true + the exe name from the
/// worktree directory basename.
pub fn hasBuildZig(worktree_path: []const u8) bool {
    var dir = std.fs.cwd().openDir(worktree_path, .{}) catch return false;
    defer dir.close();
    const file = dir.openFile("build.zig", .{}) catch return false;
    file.close();
    return true;
}
