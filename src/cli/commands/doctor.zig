//! `zigit doctor`
//!
//! Diagnoses zigit installation and PATH configuration.

const std = @import("std");
const fangz = @import("fangz");
const zigit = @import("zigit");

const Command = fangz.Command;
const ParseContext = fangz.ParseContext;
const paths = zigit.paths;

pub fn setup(parent: *Command) !void {
    const cmd = try parent.addSubcommand(.{
        .name = "doctor",
        .description = "Check zigit installation and PATH configuration",
    });

    cmd.hooks.run = &run;
}

fn run(ctx: *ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    const bin_dir = try paths.binDir(allocator);
    defer allocator.free(bin_dir);

    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);

    try w.interface.print("\n", .{});
    try w.interface.print("  Zigit doctor\n", .{});
    try w.interface.print("  -----------------------------------------\n\n", .{});

    // Install directory
    try w.interface.print("  Install directory\n", .{});
    try w.interface.print("    {s}\n", .{bin_dir});

    var dir = std.fs.cwd().openDir(bin_dir, .{}) catch null;
    const dir_ok = dir != null;
    if (dir) |*d| d.close();

    if (dir_ok) {
        try w.interface.print("    ok    path exists\n", .{});
    } else {
        try w.interface.print("    warn  path does not exist (run a command that creates it, or create it manually)\n", .{});
    }

    // PATH
    try w.interface.print("\n  PATH\n", .{});
    var path_env = try std.process.getEnvMap(allocator);
    defer path_env.deinit();

    const path_var = path_env.get("PATH");
    if (path_var == null) {
        try w.interface.print("    err   PATH is not set\n", .{});
        try w.interface.print("\n", .{});
        try w.interface.flush();
        return;
    }

    const path_str = path_var.?;
    const path_sep = if (@import("builtin").os.tag == .windows) ';' else ':';

    var found_in_path = false;
    var path_iter = std.mem.splitScalar(u8, path_str, path_sep);
    while (path_iter.next()) |entry| {
        const trimmed = std.mem.trim(u8, entry, " \t");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, bin_dir)) {
            found_in_path = true;
            break;
        }
    }

    if (found_in_path) {
        try w.interface.print("    ok    this directory is on PATH\n", .{});
    } else {
        try w.interface.print("    warn  this directory is not on PATH\n", .{});
        try w.interface.print("\n    Add it so installed tools are found. For example:\n", .{});
        if (@import("builtin").os.tag == .windows) {
            try w.interface.print("      setx PATH \"%PATH%;{s}\"\n", .{bin_dir});
        } else {
            try w.interface.print("      export PATH=\"$PATH:{s}\"\n", .{bin_dir});
            try w.interface.print("      (put that in ~/.bashrc, ~/.zshrc, or your shell config)\n", .{});
        }
    }

    // zigit on PATH
    try w.interface.print("\n  Shell\n", .{});
    const is_available = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zigit", "--version" },
        .max_output_bytes = 256,
    }) catch {
        try w.interface.print("    warn  `zigit` is not reachable from this shell (PATH or new terminal needed)\n", .{});
        try w.interface.print("\n", .{});
        try w.interface.flush();
        return;
    };

    defer {
        allocator.free(is_available.stdout);
        allocator.free(is_available.stderr);
    }

    if (is_available.term == .Exited and is_available.term.Exited == 0) {
        const ver = std.mem.trim(u8, is_available.stdout, " \t\r\n");
        if (ver.len > 0) {
            try w.interface.print("    ok    zigit responds: {s}\n", .{ver});
        } else {
            try w.interface.print("    ok    zigit is on PATH\n", .{});
        }
    } else {
        try w.interface.print("    warn  `zigit --version` did not succeed from this shell\n", .{});
    }

    try w.interface.print("\n", .{});
    try w.interface.flush();
}
