const std = @import("std");
const fangz = @import("fangz");
const commands = @import("commands/commands.zig");

var gpa = std.heap.GeneralPurposeAllocator(.{}){};

pub fn main() anyerror!void {
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var app = try fangz.App.init(allocator, .{
        .description = "Zig CLI tool manager — install, build, and update tools from Git repositories",
    });
    defer app.deinit();

    const root = app.root();
    root.setHelpOnEmptyArgs(true);

    try commands.setup(root);

    try app.executeProcess();
}
