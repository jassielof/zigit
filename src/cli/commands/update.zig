//! `zigit update [alias] [options]`
//!
//! Fetches the latest commit for the package's tracking ref, rebuilds, and
//! atomically replaces the installed binary.

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
        .name = "update",
        .description = "Update an installed tool to the latest version",
    });

    try cmd.addPositional(.{
        .name = "alias",
        .description = "Alias of the tool to update (omit with --all)",
        .required = false,
    });
    try cmd.addFlag(bool, .{
        .name = "all",
        .description = "Update all non-pinned tools",
    });
    try cmd.addFlag([]const u8, .{
        .name = "branch",
        .short = 'b',
        .description = "Switch to a branch and update to its HEAD",
    });
    try cmd.addFlag([]const u8, .{
        .name = "tag",
        .short = 't',
        .description = "Switch to a specific tag",
    });
    try cmd.addFlag([]const u8, .{
        .name = "commit",
        .short = 'c',
        .description = "Pin to a specific commit",
    });
    try cmd.addFlag(bool, .{
        .name = "force",
        .short = 'f',
        .description = "Rebuild even if already up-to-date",
    });
    try cmd.addFlag(bool, .{
        .name = "check",
        .description = "Fetch only — report if outdated, do not rebuild",
    });

    cmd.hooks.run = &run;
}

fn run(ctx: *ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    const alias_arg = ctx.positional(0);
    const all = ctx.boolFlag("all") orelse false;
    const check_only = ctx.boolFlag("check") orelse false;
    const force = ctx.boolFlag("force") orelse false;
    const branch_flag = ctx.stringFlag("branch");
    const tag_flag = ctx.stringFlag("tag");
    const commit_flag = ctx.stringFlag("commit");

    if (alias_arg == null and !all) {
        try printErr("provide an alias or use --all");
        std.process.exit(1);
    }

    const db_path = try paths.dbPath(allocator);
    defer allocator.free(db_path);

    var db = try database.Db.open(allocator, db_path);
    defer db.deinit();

    if (all) {
        const packages = try db.listPackages();
        defer {
            for (packages) |*p| p.deinit(allocator);
            allocator.free(packages);
        }
        for (packages) |pkg| {
            if (pkg.pinned) continue;
            updateOne(allocator, &db, pkg, branch_flag, tag_flag, commit_flag, force, check_only) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "failed to update '{s}': {}", .{ pkg.alias, err });
                defer allocator.free(msg);
                try printErr(msg);
            };
        }
    } else {
        const alias = alias_arg.?;
        const pkg = try db.getPackage(alias) orelse {
            const msg = try std.fmt.allocPrint(allocator, "'{s}' is not installed", .{alias});
            defer allocator.free(msg);
            try printErr(msg);
            std.process.exit(1);
        };
        defer pkg.deinit(allocator);
        try updateOne(allocator, &db, pkg, branch_flag, tag_flag, commit_flag, force, check_only);
    }
}

fn updateOne(
    allocator: std.mem.Allocator,
    db: *database.Db,
    pkg: database.Package,
    branch_flag: ?[]const u8,
    tag_flag: ?[]const u8,
    commit_flag: ?[]const u8,
    force: bool,
    check_only: bool,
) !void {
    const bare_path = try paths.bareRepoPath(allocator, pkg.host, pkg.owner, pkg.repo);
    defer allocator.free(bare_path);

    // Determine the ref to fetch
    const fetch_ref: []const u8 = if (tag_flag) |t|
        t
    else if (branch_flag) |b|
        b
    else if (pkg.tag) |t|
        t
    else if (pkg.branch) |b|
        b
    else blk: {
        const br = git.defaultBranch(allocator, bare_path) catch
            try allocator.dupe(u8, "HEAD");
        break :blk br;
    };
    const ref_owned = pkg.tag == null and pkg.branch == null and branch_flag == null and tag_flag == null;
    defer if (ref_owned) allocator.free(fetch_ref);

    // Fetch
    if (commit_flag == null) {
        git.fetch(allocator, bare_path, fetch_ref) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "fetch failed for '{s}': {}", .{ pkg.alias, err });
            defer allocator.free(msg);
            try printErr(msg);
            return;
        };
    }

    // Resolve new commit
    const new_commit: []const u8 = if (commit_flag) |c|
        try allocator.dupe(u8, c)
    else
        git.revParse(allocator, bare_path, "FETCH_HEAD") catch
            try git.revParse(allocator, bare_path, fetch_ref);
    defer allocator.free(new_commit);

    if (!force and std.mem.eql(u8, new_commit, pkg.commit)) {
        if (check_only) {
            var buf: [256]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            try w.interface.print("{s}: up to date\n", .{pkg.alias});
            try w.interface.flush();
        } else {
            var buf: [256]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            try w.interface.print("{s}: already up to date ({s})\n", .{ pkg.alias, new_commit[0..@min(8, new_commit.len)] });
            try w.interface.flush();
        }
        return;
    }

    if (check_only) {
        var buf: [256]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        try w.interface.print("{s}: outdated ({s} -> {s})\n", .{
            pkg.alias,
            pkg.commit[0..@min(8, pkg.commit.len)],
            new_commit[0..@min(8, new_commit.len)],
        });
        try w.interface.flush();
        return;
    }

    {
        var buf: [256]u8 = undefined;
        var w = std.fs.File.stdout().writer(&buf);
        try w.interface.print("Updating '{s}' {s} -> {s}...\n", .{
            pkg.alias,
            pkg.commit[0..@min(8, pkg.commit.len)],
            new_commit[0..@min(8, new_commit.len)],
        });
        try w.interface.flush();
    }

    // Checkout worktree
    var tmp = try fugaz.tempDir(allocator);
    defer tmp.deinit();
    const worktree_path = tmp.path();
    tmp.close() catch {};

    try git.worktreeAdd(allocator, bare_path, worktree_path, new_commit);
    defer git.worktreeRemove(allocator, bare_path, worktree_path);

    const build_cache = try paths.buildCacheDir(allocator);
    defer allocator.free(build_cache);

    const bin_dir = try paths.binDir(allocator);
    defer allocator.free(bin_dir);

    const optimize_str = "ReleaseFast";
    const optimize = builder.OptimizeMode.ReleaseFast;

    const binary_path = builder.buildAndInstall(
        allocator,
        worktree_path,
        pkg.alias,
        optimize,
        build_cache,
        bin_dir,
    ) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "build failed: {}", .{err});
        defer allocator.free(msg);
        try printErr(msg);
        return;
    };
    defer allocator.free(binary_path);

    const now = try database.isoNow(allocator);
    defer allocator.free(now);

    try db.updatePackage(pkg.alias, .{
        .commit = new_commit,
        .branch = if (branch_flag) |b| b else pkg.branch,
        .tag = if (tag_flag) |t| t else pkg.tag,
        .binary_path = binary_path,
        .updated_at = now,
    }, optimize_str, true, null);

    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("Updated '{s}' to {s}\n", .{ pkg.alias, new_commit[0..@min(8, new_commit.len)] });
    try w.interface.flush();
}

fn printErr(msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print("error: {s}\n", .{msg});
    try w.interface.flush();
}
