//! Top-level command registration.
//! Each sub-module exposes a `setup(*Command) !void` that adds flags,
//! positionals, and a run hook to the given subcommand node.

const fangz = @import("fangz");
const Command = fangz.Command;

const install = @import("install.zig");
const uninstall = @import("uninstall.zig");
const update = @import("update.zig");
const list = @import("list.zig");
const info = @import("info.zig");
const doctor = @import("doctor.zig");

/// Register all subcommands on the root command.
pub fn setup(root: *Command) !void {
    try install.setup(root);
    try uninstall.setup(root);
    try update.setup(root);
    try list.setup(root);
    try info.setup(root);
    try doctor.setup(root);
}
