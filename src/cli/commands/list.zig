//! `zigit list [--outdated] [--json]`
//!
//! Displays installed packages as a table or JSON.

const std = @import("std");
const fangz = @import("fangz");
const zigit = @import("zigit");
const carnaval = @import("carnaval");

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
    var buf: [8192]u8 = undefined;
    var w = stdout.writer(&buf);

    const cols: usize = if (show_outdated_col) 5 else 4;
    const headers5 = [_][]const u8{ "ALIAS", "BRANCH/TAG", "COMMIT", "INSTALLED", "STATUS" };
    const headers4 = [_][]const u8{ "ALIAS", "BRANCH/TAG", "COMMIT", "INSTALLED" };
    const headers: []const []const u8 = if (show_outdated_col) &headers5 else &headers4;

    const rows = try allocator.alloc([]const []const u8, packages.len);
    defer {
        for (rows) |r| allocator.free(r);
        allocator.free(rows);
    }

    for (packages, 0..) |pkg, i| {
        const row = try allocator.alloc([]const u8, cols);
        const ref = if (pkg.tag) |t| t else if (pkg.branch) |b| b else "-";
        const short_commit = pkg.commit[0..@min(8, pkg.commit.len)];
        const installed_date = if (pkg.installed_at.len >= 10) pkg.installed_at[0..10] else pkg.installed_at;

        row[0] = pkg.alias;
        row[1] = ref;
        row[2] = short_commit;
        row[3] = installed_date;
        if (show_outdated_col) {
            row[4] = if (pkg.pinned) "pinned" else if (is_outdated[i]) "outdated" else "ok";
        }
        rows[i] = row;
    }

    const profile = carnaval.colorProfileForHandle(stdout.handle);
    try carnaval.renderTableStyled(allocator, headers, rows, &w.interface, profile, .unicode);
    try w.interface.flush();
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
