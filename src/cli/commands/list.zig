//! List command - List all installed packages
const std = @import("std");
const fangz = @import("fangz");

const ArgMatches = fangz.ArgMatches;

/// Execute the list command
pub fn execute(matches: ArgMatches) !void {
    _ = matches;
    // TODO: Implement list command
    std.log.info("List command - TODO", .{});
}

