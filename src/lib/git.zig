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

pub const RefKind = enum {
    branches,
    local_branches,
    tags,
};

pub const RefInfo = struct {
    name: []u8,
    commit: []u8,

    pub fn deinit(self: *RefInfo, allocator: Allocator) void {
        allocator.free(self.name);
        allocator.free(self.commit);
    }
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
///   github.com/owner/repo
///   gh/owner/repo
pub fn parseUrl(allocator: Allocator, url: []const u8) !ParsedUrl {
    var work = url;
    var normalized_owned: ?[]u8 = null;
    defer if (normalized_owned) |b| allocator.free(b);

    if (std.mem.indexOfScalar(u8, work, '\\') != null) {
        const normalized = try allocator.dupe(u8, work);
        for (normalized) |*ch| {
            if (ch.* == '\\') ch.* = '/';
        }
        normalized_owned = normalized;
        work = normalized;
    }

    if (std.mem.startsWith(u8, work, "gh/")) {
        work = try std.fmt.allocPrint(allocator, "github.com/{s}", .{work[3..]});
        defer allocator.free(work);
    }

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

    // host/owner/repo shorthand without protocol
    {
        const first_slash = std.mem.indexOfScalar(u8, work, '/') orelse return error.ParseError;
        const host = work[0..first_slash];
        const path = work[first_slash + 1 ..];
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.ParseError;
        return ParsedUrl{
            .host = try allocator.dupe(u8, host),
            .owner = try allocator.dupe(u8, path[0..slash]),
            .repo = try allocator.dupe(u8, path[slash + 1 ..]),
        };
    }
}

/// Normalize accepted remote shorthand into canonical HTTPS URL ending in .git.
pub fn canonicalRemoteUrl(allocator: Allocator, raw: []const u8) ![]u8 {
    const parsed = try parseUrl(allocator, raw);
    defer parsed.deinit(allocator);
    return std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}.git", .{ parsed.host, parsed.owner, parsed.repo });
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

/// Return refs from `git for-each-ref` for branches or tags.
/// The returned list and each entry's buffers are owned by the caller.
pub fn listRemoteRefs(allocator: Allocator, bare_path: []const u8, kind: RefKind) ![]RefInfo {
    const format = "%(refname:short)|%(objectname)";
    const pattern = switch (kind) {
        .branches => "refs/remotes",
        .local_branches => "refs/heads",
        .tags => "refs/tags",
    };

    const output = try run(allocator, null, &.{ "-C", bare_path, "for-each-ref", "--sort=-committerdate", "--format", format, pattern });
    defer allocator.free(output);

    var list = std.ArrayList(RefInfo).empty;
    defer list.deinit(allocator);

    var lines = std.mem.splitScalar(u8, output, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (line.len == 0) continue;

        const sep = std.mem.indexOfScalar(u8, line, '|') orelse continue;
        const ref_name = line[0..sep];
        const commit = std.mem.trim(u8, line[sep + 1 ..], " \r\t");
        if (commit.len == 0) continue;

        if (kind == .branches) {
            // Keep remote-qualified names explicit (e.g. origin/main, upstream/main).
            // Skip synthetic refs such as origin/HEAD and namespace-only refs like origin.
            if (std.mem.endsWith(u8, ref_name, "/HEAD")) continue;
            if (std.mem.indexOfScalar(u8, ref_name, '/') == null) continue;
        }

        try list.append(allocator, .{
            .name = try allocator.dupe(u8, ref_name),
            .commit = try allocator.dupe(u8, commit),
        });
    }

    return list.toOwnedSlice(allocator);
}

/// Add a worktree at `worktree_path` checked out at `commit`.
///
/// git -C <bare_path> worktree add <worktree_path> <commit>
pub fn worktreeAdd(allocator: Allocator, bare_path: []const u8, worktree_path: []const u8, commit: []const u8) !void {
    const out = try run(allocator, null, &.{ "-C", bare_path, "worktree", "add", "--detach", worktree_path, commit });
    allocator.free(out);
}

/// Populate nested git submodules in a worktree (no-op when there are none).
///
/// git -C <worktree_path> submodule update --init --recursive
pub fn submoduleUpdateInit(allocator: Allocator, worktree_path: []const u8) !void {
    const out = try run(allocator, worktree_path, &.{ "submodule", "update", "--init", "--recursive" });
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
