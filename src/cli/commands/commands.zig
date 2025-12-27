//! Commands module for zigit CLI
const std = @import("std");
const fangz = @import("fangz");

const App = fangz.App;
const Command = fangz.Command;
const Arg = fangz.Arg;
const ArgMatches = fangz.ArgMatches;

const info = @import("info.zig");
const install = @import("install.zig");
const uninstall = @import("uninstall.zig");
const list = @import("list.zig");
const update = @import("update.zig");

/// Sets up all commands for the CLI
pub fn setupCommands(app: *App, root: *Command) !void {
    // info command
    var info_cmd = app.createCommand("info", "Show information about an installed or to-be-installed package");
    try info_cmd.addArg(Arg.positional("PACKAGE", "Package name or repository URL", null));
    try root.addSubcommand(info_cmd);

    // install command
    var install_cmd = app.createCommand("install", "Install a zig package/project from a git repository");
    try install_cmd.addArg(Arg.positional("REPOSITORY", "Git repository URL", null));
    try install_cmd.addArg(Arg.singleValueOption("alias", 'a', "Alias name for the package"));
    try install_cmd.addArg(Arg.singleValueOption("tag", 't', "Install from a specific tag"));
    try install_cmd.addArg(Arg.singleValueOption("branch", 'b', "Install from a specific branch"));
    try install_cmd.addArg(Arg.singleValueOption("commit", 'c', "Install from a specific commit hash"));
    try root.addSubcommand(install_cmd);

    // uninstall command
    var uninstall_cmd = app.createCommand("uninstall", "Uninstall a package");
    try uninstall_cmd.addArg(Arg.positional("PACKAGE", "Package name to uninstall", null));
    try root.addSubcommand(uninstall_cmd);

    // list command
    var list_cmd = app.createCommand("list", "List all installed packages");
    try list_cmd.addArg(Arg.booleanOption("outdated", 'o', "Show only outdated packages"));
    try root.addSubcommand(list_cmd);

    // update command
    var update_cmd = app.createCommand("update", "Update an installed package");
    try update_cmd.addArg(Arg.positional("PACKAGE", "Package name to update", null));
    try update_cmd.addArg(Arg.booleanOption("force", 'f', "Force rebuild from scratch"));
    try update_cmd.addArg(Arg.booleanOption("rebuild", 'r', "Rebuild after updating"));
    try update_cmd.addArg(Arg.singleValueOption("tag", 't', "Update to a specific tag"));
    try update_cmd.addArg(Arg.singleValueOption("branch", 'b', "Update to a specific branch"));
    try update_cmd.addArg(Arg.singleValueOption("commit", 'c', "Update to a specific commit hash"));
    try root.addSubcommand(update_cmd);
}

/// Handles command execution based on parsed matches
pub fn handleCommands(_: *App, _: *Command, matches: ArgMatches) !void {
    if (matches.subcommandMatches("info")) |info_matches| {
        try info.execute(info_matches);
        return;
    }

    if (matches.subcommandMatches("install")) |install_matches| {
        try install.execute(install_matches);
        return;
    }

    if (matches.subcommandMatches("uninstall")) |uninstall_matches| {
        try uninstall.execute(uninstall_matches);
        return;
    }

    if (matches.subcommandMatches("list")) |list_matches| {
        try list.execute(list_matches);
        return;
    }

    if (matches.subcommandMatches("update")) |update_matches| {
        try update.execute(update_matches);
        return;
    }
}

