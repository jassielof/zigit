//! `zigit uninstall <alias> [--purge] [--yes]`
//!
//! Removes the binary, the database record, and (with --purge) the bare clone.

const std = @import("std");
const fangz = @import("fangz");
const zigit = @import("zigit");

const Command = fangz.Command;
const ParseContext = fangz.ParseContext;
const paths = zigit.paths;
const database = zigit.database;

pub fn setup(parent: *Command) !void {
    const cmd = try parent.addSubcommand(.{
        .name = "uninstall",
        .description = "Uninstall an installed tool",
    });

    try cmd.addPositional(.{
        .name = "alias",
        .description = "Alias (or name) of the tool to uninstall",
        .required = true,
    });
    try cmd.addFlag(bool, .{
        .name = "purge",
        .description = "Also remove the bare clone from the cache",
    });
    try cmd.addFlag(bool, .{
        .name = "yes",
        .short = 'y',
        .description = "Skip confirmation prompt",
    });

    cmd.hooks.run = &run;
}

fn run(ctx: *ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    const alias = ctx.positional(0) orelse {
        try printErr("alias argument is required");
        std.process.exit(1);
    };

    const purge = ctx.boolFlag("purge") orelse false;
    const yes = ctx.boolFlag("yes") orelse false;

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

    if (!yes) {
        const stdout = std.fs.File.stdout();
        var buf: [256]u8 = undefined;
        var w = stdout.writer(&buf);
        try w.interface.print("Uninstall '{s}' ({s})? [y/N] ", .{ pkg.alias, pkg.binary_path });
        try w.interface.flush();

        var stdin_buf: [8]u8 = undefined;
        const stdin = std.fs.File.stdin();
        const n = stdin.read(&stdin_buf) catch 0;
        const answer = std.mem.trim(u8, stdin_buf[0..n], " \r\n\t");
        if (!std.mem.eql(u8, answer, "y") and !std.mem.eql(u8, answer, "Y")) {
            return;
        }
    }

    // Remove binary
    std.fs.cwd().deleteFile(pkg.binary_path) catch |err| {
        if (err != error.FileNotFound) {
            const msg = try std.fmt.allocPrint(allocator, "could not remove binary: {}", .{err});
            defer allocator.free(msg);
            try printErr(msg);
        }
    };

    if (purge) {
        const bare_path = try paths.bareRepoPath(allocator, pkg.host, pkg.owner, pkg.repo);
        defer allocator.free(bare_path);
        std.fs.cwd().deleteTree(bare_path) catch {};
    }

    try db.deletePackage(alias);

    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("Uninstalled '{s}'\n", .{alias});
    try w.interface.flush();
}

fn printErr(msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print("error: {s}\n", .{msg});
    try w.interface.flush();
}
