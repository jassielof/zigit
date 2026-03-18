//! `zigit install <url> [options]`
//!
//! Clones (bare, shallow) the repository, checks out a worktree, builds with
//! `zig build`, copies the binary, and records the package in the database.

const std = @import("std");
const fangz = @import("fangz");
const zigit = @import("zigit");

const Command = fangz.Command;
const ParseContext = fangz.ParseContext;
const paths = zigit.paths;
const git = zigit.git;
const builder = zigit.builder;
const database = zigit.database;
const fugaz = @import("fugaz");

pub fn setup(parent: *Command) !void {
    const cmd = try parent.addSubcommand(.{
        .name = "install",
        .description = "Install a Zig tool from a Git repository",
    });

    try cmd.addPositional(.{
        .name = "url",
        .description = "Git repository URL",
        .required = true,
    });
    try cmd.addFlag([]const u8, .{
        .name = "alias",
        .short = 'a',
        .description = "Install under a custom name",
    });
    try cmd.addFlag([]const u8, .{
        .name = "branch",
        .short = 'b',
        .description = "Checkout a specific branch",
    });
    try cmd.addFlag([]const u8, .{
        .name = "tag",
        .short = 't',
        .description = "Checkout a specific tag",
    });
    try cmd.addFlag([]const u8, .{
        .name = "commit",
        .short = 'c',
        .description = "Pin to a specific commit SHA",
    });
    try cmd.addFlag([]const u8, .{
        .name = "optimize",
        .short = 'O',
        .description = "Build optimisation: ReleaseFast (default), ReleaseSafe, ReleaseSmall",
        .default = "ReleaseFast",
        .allowed_values = &.{ "ReleaseFast", "ReleaseSafe", "ReleaseSmall" },
    });
    try cmd.addFlag(bool, .{
        .name = "rebuild",
        .description = "Force clean build",
    });

    cmd.hooks.run = &run;
}

fn run(ctx: *ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    const url = ctx.positional(0) orelse {
        try printErr("url argument is required");
        std.process.exit(1);
    };

    const alias_flag = ctx.stringFlag("alias");
    const branch_flag = ctx.stringFlag("branch");
    const tag_flag = ctx.stringFlag("tag");
    const commit_flag = ctx.stringFlag("commit");
    const optimize_str = ctx.stringFlag("optimize") orelse "ReleaseFast";

    const optimize = builder.OptimizeMode.fromString(optimize_str) orelse {
        try printErr("invalid --optimize value");
        std.process.exit(1);
    };

    // Parse URL
    const parsed = git.parseUrl(allocator, url) catch {
        try printErr("could not parse git URL");
        std.process.exit(1);
    };
    defer parsed.deinit(allocator);

    const alias = alias_flag orelse parsed.repo;

    // Ensure runtime dirs exist
    try paths.ensureDirs(allocator);

    // Open (or create) database
    const db_path = try paths.dbPath(allocator);
    defer allocator.free(db_path);

    var db = try database.Db.open(allocator, db_path);
    defer db.deinit();

    // Conflict check
    if (try db.aliasExists(alias)) {
        const msg = try std.fmt.allocPrint(allocator, "alias '{s}' already exists — use --alias to choose a different name", .{alias});
        defer allocator.free(msg);
        try printErr(msg);
        std.process.exit(1);
    }

    // Determine ref for clone
    // Resolution precedence: tag > branch+commit > commit > branch > HEAD
    const clone_ref: ?[]const u8 = if (tag_flag) |t|
        t
    else if (branch_flag) |b|
        b
    else
        null;

    // Bare clone path
    const bare_path = try paths.bareRepoPath(allocator, parsed.host, parsed.owner, parsed.repo);
    defer allocator.free(bare_path);

    const stdout = std.fs.File.stdout();

    if (!git.bareExists(bare_path)) {
        var buf: [256]u8 = undefined;
        var w = stdout.writer(&buf);
        try w.interface.print("Cloning {s}/{s}/{s}...\n", .{ parsed.host, parsed.owner, parsed.repo });
        try w.interface.flush();

        git.cloneBare(allocator, url, bare_path, clone_ref) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "git clone failed: {}", .{err});
            defer allocator.free(msg);
            try printErr(msg);
            std.process.exit(1);
        };
    }

    // Resolve the commit we'll build
    const commit: []const u8 = blk: {
        if (tag_flag) |t| {
            // Fetch the tag first
            git.fetch(allocator, bare_path, t) catch {};
            const sha = git.revParse(allocator, bare_path, t) catch {
                try printErr("could not resolve tag");
                std.process.exit(1);
            };
            break :blk sha;
        } else if (commit_flag) |c| {
            break :blk try allocator.dupe(u8, c);
        } else if (branch_flag) |b| {
            git.fetch(allocator, bare_path, b) catch {};
            const sha = git.revParse(allocator, bare_path, "FETCH_HEAD") catch {
                const sha2 = git.revParse(allocator, bare_path, b) catch {
                    try printErr("could not resolve branch");
                    std.process.exit(1);
                };
                break :blk sha2;
            };
            break :blk sha;
        } else {
            // Default branch HEAD
            const branch = git.defaultBranch(allocator, bare_path) catch
                try allocator.dupe(u8, "HEAD");
            defer allocator.free(branch);
            git.fetch(allocator, bare_path, branch) catch {};
            const sha = git.revParse(allocator, bare_path, "FETCH_HEAD") catch
                try git.revParse(allocator, bare_path, "HEAD");
            break :blk sha;
        }
    };
    defer allocator.free(commit);

    {
        var buf: [256]u8 = undefined;
        var w = stdout.writer(&buf);
        try w.interface.print("Building {s} @ {s}...\n", .{ alias, commit[0..@min(8, commit.len)] });
        try w.interface.flush();
    }

    // Create a temporary worktree
    var tmp = try fugaz.tempDir(allocator);
    defer tmp.deinit();
    const worktree_path = tmp.path();

    // Remove the fugaz-created empty dir so git worktree add can create it
    tmp.close() catch {};

    git.worktreeAdd(allocator, bare_path, worktree_path, commit) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "git worktree add failed: {}", .{err});
        defer allocator.free(msg);
        try printErr(msg);
        std.process.exit(1);
    };
    defer git.worktreeRemove(allocator, bare_path, worktree_path);

    if (!builder.hasBuildZig(worktree_path)) {
        try printErr("no build.zig found — only Zig projects are supported");
        std.process.exit(1);
    }

    const build_cache = try paths.buildCacheDir(allocator);
    defer allocator.free(build_cache);

    const bin_dir = try paths.binDir(allocator);
    defer allocator.free(bin_dir);

    const binary_path = builder.buildAndInstall(
        allocator,
        worktree_path,
        alias,
        optimize,
        build_cache,
        bin_dir,
    ) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "build failed: {}", .{err});
        defer allocator.free(msg);
        try printErr(msg);
        std.process.exit(1);
    };
    defer allocator.free(binary_path);

    // Record in database
    _ = try db.insertPackage(.{
        .name = parsed.repo,
        .alias = alias,
        .url = url,
        .host = parsed.host,
        .owner = parsed.owner,
        .repo = parsed.repo,
        .branch = if (tag_flag != null) null else branch_flag,
        .tag = tag_flag,
        .commit = commit,
        .optimize = optimize_str,
        .binary_path = binary_path,
    });

    var buf: [512]u8 = undefined;
    var w = stdout.writer(&buf);
    try w.interface.print("Installed '{s}' -> {s}\n", .{ alias, binary_path });
    try w.interface.flush();
}

fn printErr(msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print("error: {s}\n", .{msg});
    try w.interface.flush();
}
