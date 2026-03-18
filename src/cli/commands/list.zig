//! `zigit list [--outdated] [--json]`
//!
//! Displays installed packages as a table or JSON.

const std = @import("std");
const fangz = @import("fangz");
const zigit = @import("zigit");

const Command = fangz.Command;
const ParseContext = fangz.ParseContext;
const paths = zigit.paths;
const git = zigit.git;
const database = zigit.database;

pub fn setup(parent: *Command) !void {
    const cmd = try parent.addSubcommand(.{
        .name = "list",
        .description = "List installed tools",
    });

    try cmd.addFlag(bool, .{
        .name = "outdated",
        .short = 'o',
        .description = "Check remote for newer commits and mark outdated packages",
    });
    try cmd.addFlag(bool, .{
        .name = "json",
        .short = 'j',
        .description = "Output as JSON",
    });

    cmd.hooks.run = &run;
}

fn run(ctx: *ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    const outdated_check = ctx.boolFlag("outdated") orelse false;
    const json_output = ctx.boolFlag("json") orelse false;

    const db_path = try paths.dbPath(allocator);
    defer allocator.free(db_path);

    var db = try database.Db.open(allocator, db_path);
    defer db.deinit();

    const packages = try db.listPackages();
    defer {
        for (packages) |*p| p.deinit(allocator);
        allocator.free(packages);
    }

    if (packages.len == 0) {
        if (json_output) {
            var buf: [8]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            try w.interface.print("[]\n", .{});
            try w.interface.flush();
        } else {
            var buf: [128]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            try w.interface.print("No tools installed. Use `zigit install <url>` to get started.\n", .{});
            try w.interface.flush();
        }
        return;
    }

    // Collect outdated status per package
    const is_outdated = try allocator.alloc(bool, packages.len);
    defer allocator.free(is_outdated);
    @memset(is_outdated, false);

    if (outdated_check) {
        for (packages, 0..) |pkg, i| {
            if (pkg.pinned) continue;
            const bare_path = paths.bareRepoPath(allocator, pkg.host, pkg.owner, pkg.repo) catch continue;
            defer allocator.free(bare_path);

            const fetch_ref: []const u8 = if (pkg.tag) |t| t else if (pkg.branch) |b| b else "HEAD";
            git.fetch(allocator, bare_path, fetch_ref) catch continue;
            const remote_commit = git.revParse(allocator, bare_path, "FETCH_HEAD") catch continue;
            defer allocator.free(remote_commit);
            if (!std.mem.eql(u8, remote_commit, pkg.commit)) {
                is_outdated[i] = true;
            }
        }
    }

    if (json_output) {
        try printJson(allocator, packages, is_outdated);
    } else {
        try printTable(allocator, packages, is_outdated, outdated_check);
    }
}

fn printTable(
    allocator: std.mem.Allocator,
    packages: []const database.Package,
    is_outdated: []const bool,
    show_outdated_col: bool,
) !void {
    const stdout = std.fs.File.stdout();
    var buf: [4096]u8 = undefined;
    var w = stdout.writer(&buf);

    if (show_outdated_col) {
        try w.interface.print("{s:<20}  {s:<18}  {s:<10}  {s:<12}  {s}\n", .{
            "ALIAS", "BRANCH/TAG", "COMMIT", "INSTALLED", "STATUS",
        });
        try w.interface.print("{s}\n", .{"─" ** 80});
    } else {
        try w.interface.print("{s:<20}  {s:<18}  {s:<10}  {s}\n", .{
            "ALIAS", "BRANCH/TAG", "COMMIT", "INSTALLED",
        });
        try w.interface.print("{s}\n", .{"─" ** 66});
    }

    // Flush header before rows (buffer may be too small for many rows)
    try w.interface.flush();

    for (packages, 0..) |pkg, i| {
        const ref = if (pkg.tag) |t| t else if (pkg.branch) |b| b else "-";
        const short_commit = pkg.commit[0..@min(8, pkg.commit.len)];
        const installed_date = if (pkg.installed_at.len >= 10) pkg.installed_at[0..10] else pkg.installed_at;

        // Print each row into a fresh local buffer
        var row_buf: [512]u8 = undefined;
        var rw = stdout.writer(&row_buf);

        if (show_outdated_col) {
            const status: []const u8 = if (pkg.pinned) "pinned" else if (is_outdated[i]) "outdated" else "ok";
            try rw.interface.print("{s:<20}  {s:<18}  {s:<10}  {s:<12}  {s}\n", .{
                pkg.alias, ref, short_commit, installed_date, status,
            });
        } else {
            try rw.interface.print("{s:<20}  {s:<18}  {s:<10}  {s}\n", .{
                pkg.alias, ref, short_commit, installed_date,
            });
        }
        try rw.interface.flush();
    }

    _ = allocator;
}

fn printJson(allocator: std.mem.Allocator, packages: []const database.Package, is_outdated: []const bool) !void {
    _ = allocator;
    const stdout = std.fs.File.stdout();
    var buf: [8192]u8 = undefined;
    var w = stdout.writer(&buf);

    try w.interface.print("[\n", .{});
    for (packages, 0..) |pkg, i| {
        const comma: []const u8 = if (i + 1 < packages.len) "," else "";
        const ref_type: []const u8 = if (pkg.tag != null) "tag" else if (pkg.branch != null) "branch" else "commit";
        const ref_val: []const u8 = if (pkg.tag) |t| t else if (pkg.branch) |b| b else pkg.commit;
        try w.interface.print(
            \\  {{"alias":"{s}","name":"{s}","url":"{s}","ref_type":"{s}","ref":"{s}","commit":"{s}","pinned":{s},"outdated":{s},"installed_at":"{s}","binary_path":"{s}"}}{s}
            \\
        , .{
            pkg.alias,
            pkg.name,
            pkg.url,
            ref_type,
            ref_val,
            pkg.commit,
            if (pkg.pinned) "true" else "false",
            if (is_outdated[i]) "true" else "false",
            pkg.installed_at,
            pkg.binary_path,
            comma,
        });
    }
    try w.interface.print("]\n", .{});
    try w.interface.flush();
}
