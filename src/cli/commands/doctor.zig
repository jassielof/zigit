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

    var buf: [2048]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);

    try w.interface.print("=== zigit Doctor ===\n\n", .{});

    // Show install directory
    try w.interface.print("Install directory: {s}\n", .{bin_dir});

    // Check if directory exists
    var dir = std.fs.cwd().openDir(bin_dir, .{}) catch null;
    if (dir) |*d| {
        defer d.close();
        try w.interface.print("  ✓ Directory exists\n", .{});
    } else {
        try w.interface.print("  ✗ Directory does not exist\n", .{});
    }

    // Check PATH
    try w.interface.print("\nChecking PATH...\n", .{});
    var path_env = try std.process.getEnvMap(allocator);
    defer path_env.deinit();

    const path_var = path_env.get("PATH");
    if (path_var == null) {
        try w.interface.print("  ✗ PATH environment variable not set\n", .{});
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
        try w.interface.print("  ✓ Install directory is in PATH\n", .{});
    } else {
        try w.interface.print("  ✗ Install directory is NOT in PATH\n", .{});
        try w.interface.print("\n  To fix this, add {s} to your PATH:\n", .{bin_dir});
        if (@import("builtin").os.tag == .windows) {
            try w.interface.print("    setx PATH \"%PATH%;{s}\"\n", .{bin_dir});
        } else {
            try w.interface.print("    export PATH=\"$PATH:{s}\"\n", .{bin_dir});
            try w.interface.print("    # Add this line to your shell profile (~/.bashrc, ~/.zshrc, etc.)\n", .{});
        }
    }

    // Try to execute zigit as a sanity check
    try w.interface.print("\nVerifying binary accessibility...\n", .{});
    const is_available = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zigit", "--version" },
        .max_output_bytes = 256,
    }) catch {
        try w.interface.print("  ✗ 'zigit' command is not accessible from current shell\n", .{});
        try w.interface.print("    (You may need to restart your terminal or run 'source' on your shell profile)\n", .{});
        try w.interface.print("\n=== End of Report ===\n", .{});
        try w.interface.flush();
        return;
    };

    defer {
        allocator.free(is_available.stdout);
        allocator.free(is_available.stderr);
    }

    if (is_available.term == .Exited and is_available.term.Exited == 0) {
        try w.interface.print("  ✓ 'zigit' command is accessible from current shell\n", .{});
    } else {
        try w.interface.print("  ✗ 'zigit' command is not accessible from current shell\n", .{});
        try w.interface.print("    (You may need to restart your terminal or run 'source' on your shell profile)\n", .{});
    }

    try w.interface.print("\n=== End of Report ===\n", .{});
    try w.interface.flush();
}
