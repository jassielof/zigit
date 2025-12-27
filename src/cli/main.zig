const std = @import("std");
const fangz = @import("fangz");

const commands = @import("commands/commands.zig");

const App = fangz.App;
const Arg = fangz.Arg;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

pub fn main() !void {
    defer _ = gpa.deinit();

    var app = App.init(allocator, "zigit", "Zig tool CLI to manage tools via Git repositories");
    defer app.deinit();

    var root = app.rootCommand();
    root.setShort("Zig tool CLI to manage tools via Git repositories");
    root.setProperty(.help_on_empty_args);

    // Add subcommands
    try commands.setupCommands(&app, root);

    const matches = try app.parseProcess();

    // Handle commands
    try commands.handleCommands(&app, root, matches);
}
