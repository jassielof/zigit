//! `zigit info <alias|url>`
//!
//! Shows detailed information about an installed package (read from DB) or
//! a not-yet-installed repository (shallow-cloned to a temp dir).

const std = @import("std");
const fangz = @import("fangz");
const zigit = @import("zigit");

const Command = fangz.Command;
const ParseContext = fangz.ParseContext;
const paths = zigit.paths;
const git = zigit.git;
const database = zigit.database;
const fugaz = @import("fugaz");

pub fn setup(parent: *Command) !void {
    const cmd = try parent.addSubcommand(.{
        .name = "info",
        .description = "Show information about an installed tool or a Git repository URL",
    });

    try cmd.addPositional(.{
        .name = "target",
        .description = "Alias of an installed tool, or a Git repository URL",
        .required = true,
    });

    cmd.hooks.run = &run;
}

fn run(ctx: *ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    const target = ctx.positional(0) orelse {
        try printErr("target argument is required");
        std.process.exit(1);
    };

    const is_url = std.mem.indexOf(u8, target, "://") != null or
        std.mem.startsWith(u8, target, "git@");

    if (is_url) {
        try infoFromUrl(allocator, target);
    } else {
        try infoFromInstalled(allocator, target);
    }
}

fn infoFromInstalled(allocator: std.mem.Allocator, alias: []const u8) !void {
    const db_path = try paths.dbPath(allocator);
    defer allocator.free(db_path);

    var db = try database.Db.open(allocator, db_path);
    defer db.deinit();

    const pkg = try db.getPackage(alias) orelse {
        const msg = try std.fmt.allocPrint(allocator, "'{s}' is not installed", .{alias});
        defer allocator.free(msg);
        try printErr(msg);
        std.process.exit(1);
    };
    defer pkg.deinit(allocator);

    const bare_path = try paths.bareRepoPath(allocator, pkg.host, pkg.owner, pkg.repo);
    defer allocator.free(bare_path);

    const readme = readReadme(allocator, bare_path) catch null;
    defer if (readme) |r| allocator.free(r);

    try printInfo(.{
        .name = pkg.name,
        .alias = pkg.alias,
        .url = pkg.url,
        .host = pkg.host,
        .owner = pkg.owner,
        .ref_type = if (pkg.tag != null) "tag" else if (pkg.branch != null) "branch" else "commit",
        .ref = if (pkg.tag) |t| t else if (pkg.branch) |b| b else pkg.commit,
        .commit = pkg.commit,
        .pinned = pkg.pinned,
        .installed = true,
        .binary_path = pkg.binary_path,
        .installed_at = pkg.installed_at,
        .updated_at = pkg.updated_at,
        .readme_excerpt = readme,
    });
}

fn infoFromUrl(allocator: std.mem.Allocator, url: []const u8) !void {
    const parsed = git.parseUrl(allocator, url) catch {
        try printErr("could not parse git URL");
        std.process.exit(1);
    };
    defer parsed.deinit(allocator);

    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("Fetching info for {s}/{s}/{s}...\n", .{ parsed.host, parsed.owner, parsed.repo });
    try w.interface.flush();

    var tmp = try fugaz.tempDir(allocator);
    defer tmp.deinit();
    const tmp_path = tmp.path();

    git.cloneBare(allocator, url, tmp_path, null) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "clone failed: {}", .{err});
        defer allocator.free(msg);
        try printErr(msg);
        std.process.exit(1);
    };

    const commit = git.revParse(allocator, tmp_path, "HEAD") catch
        try allocator.dupe(u8, "(unknown)");
    defer allocator.free(commit);

    const branch = git.defaultBranch(allocator, tmp_path) catch
        try allocator.dupe(u8, "(unknown)");
    defer allocator.free(branch);

    // Checkout worktree to read README
    var wt_tmp = try fugaz.tempDir(allocator);
    defer wt_tmp.deinit();
    const wt_path = wt_tmp.path();
    wt_tmp.close() catch {};

    const readme: ?[]u8 = blk: {
        git.worktreeAdd(allocator, tmp_path, wt_path, commit) catch break :blk null;
        defer git.worktreeRemove(allocator, tmp_path, wt_path);
        break :blk readReadme(allocator, wt_path) catch null;
    };
    defer if (readme) |r| allocator.free(r);

    try printInfo(.{
        .name = parsed.repo,
        .alias = parsed.repo,
        .url = url,
        .host = parsed.host,
        .owner = parsed.owner,
        .ref_type = "branch",
        .ref = branch,
        .commit = commit,
        .pinned = false,
        .installed = false,
        .binary_path = null,
        .installed_at = null,
        .updated_at = null,
        .readme_excerpt = readme,
    });
}

const InfoDisplay = struct {
    name: []const u8,
    alias: []const u8,
    url: []const u8,
    host: []const u8,
    owner: []const u8,
    ref_type: []const u8,
    ref: []const u8,
    commit: []const u8,
    pinned: bool,
    installed: bool,
    binary_path: ?[]const u8,
    installed_at: ?[]const u8,
    updated_at: ?[]const u8,
    readme_excerpt: ?[]const u8,
};

fn printInfo(info: InfoDisplay) !void {
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);

    try w.interface.print("Name:        {s}\n", .{info.name});
    try w.interface.print("Alias:       {s}\n", .{info.alias});
    try w.interface.print("URL:         {s}\n", .{info.url});
    try w.interface.print("Host:        {s}\n", .{info.host});
    try w.interface.print("Owner:       {s}\n", .{info.owner});
    try w.interface.print("{s}:       {s}\n", .{ info.ref_type, info.ref });
    try w.interface.print("Commit:      {s}\n", .{info.commit[0..@min(16, info.commit.len)]});
    try w.interface.print("Pinned:      {s}\n", .{if (info.pinned) "yes" else "no"});
    try w.interface.print("Installed:   {s}\n", .{if (info.installed) "yes" else "no"});
    if (info.binary_path) |p| try w.interface.print("Binary:      {s}\n", .{p});
    if (info.installed_at) |t| try w.interface.print("Installed:   {s}\n", .{t});
    if (info.updated_at) |t| try w.interface.print("Updated:     {s}\n", .{t});
    if (info.readme_excerpt) |r| {
        try w.interface.print("\n{s}\n", .{r});
    }
    try w.interface.flush();
}

fn readReadme(allocator: std.mem.Allocator, repo_path: []const u8) ![]u8 {
    const names = [_][]const u8{ "README.md", "README.txt", "README", "readme.md" };
    var dir = try std.fs.cwd().openDir(repo_path, .{});
    defer dir.close();

    for (names) |name| {
        const file = dir.openFile(name, .{}) catch continue;
        defer file.close();
        const content = file.readToEndAlloc(allocator, 16 * 1024) catch continue;
        defer allocator.free(content);
        // Return first paragraph (up to double newline)
        const end = std.mem.indexOf(u8, content, "\n\n") orelse
            std.mem.indexOf(u8, content, "\n") orelse
            content.len;
        return allocator.dupe(u8, content[0..end]);
    }
    return error.NotFound;
}

fn printErr(msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print("error: {s}\n", .{msg});
    try w.interface.flush();
}
