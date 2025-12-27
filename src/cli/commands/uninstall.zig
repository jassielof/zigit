//! Uninstall command - Uninstall a package
const std = @import("std");
const fangz = @import("fangz");

const ArgMatches = fangz.ArgMatches;

/// Execute the uninstall command
pub fn execute(matches: ArgMatches) !void {
    _ = matches;
    // TODO: Implement uninstall command
    std.log.info("Uninstall command - TODO", .{});
}

