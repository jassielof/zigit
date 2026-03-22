//! `zigit install <url> [options]`
//!
//! For remotes: clones (bare, shallow), checks out a worktree, builds with
//! `zig build`, copies the binary, and records the package. For a local path,
//! builds in that directory (no clone).

const std = @import("std");
const fangz = @import("fangz");
const zigit = @import("zigit");

const Command = fangz.Command;
const ParseContext = fangz.ParseContext;
const paths = zigit.paths;
const git = zigit.git;
const builder = zigit.builder;
const database = zigit.database;
const fugaz = @import("fugaz");

pub fn setup(parent: *Command) !void {
    const cmd = try parent.addSubcommand(.{
        .name = "install",
        .description = "Install a Zig tool from a Git repository or local directory",
    });

    try cmd.addPositional(.{
        .name = "url",
        .description = "Git repository URL or path to a local checkout",
        .required = true,
    });
    try cmd.addFlag([]const u8, .{
        .name = "alias",
        .short = 'a',
        .description = "Install under a custom name",
    });
    try cmd.addFlag([]const u8, .{
        .name = "branch",
        .short = 'b',
        .description = "Checkout a specific branch",
    });
    try cmd.addFlag([]const u8, .{
        .name = "tag",
        .short = 't',
        .description = "Checkout a specific tag",
    });
    try cmd.addFlag([]const u8, .{
        .name = "commit",
        .short = 'c',
        .description = "Pin to a specific commit SHA",
    });
    // TODO: use enum flag
    try cmd.addFlag([]const u8, .{
        .name = "optimize",
        .short = 'O',
        .description = "Build optimisation: ReleaseFast (default), ReleaseSafe, ReleaseSmall",
        .default = "ReleaseFast",
        .allowed_values = &.{ "ReleaseFast", "ReleaseSafe", "ReleaseSmall" },
    });
    try cmd.addFlag(bool, .{
        .name = "rebuild",
        .description = "Force clean build",
    });

    cmd.hooks.run = &run;
}

fn run(ctx: *ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    const url = ctx.positional(0) orelse {
        try printErr("url argument is required");
        std.process.exit(1);
    };

    const alias_flag = ctx.stringFlag("alias");
    const branch_flag = ctx.stringFlag("branch");
    const tag_flag = ctx.stringFlag("tag");
    const commit_flag = ctx.stringFlag("commit");
    const optimize_str = ctx.stringFlag("optimize") orelse "ReleaseFast";

    const optimize = builder.OptimizeMode.fromString(optimize_str) orelse {
        try printErr("invalid --optimize value");
        std.process.exit(1);
    };

    const target = git.resolveInstallTarget(allocator, url) catch {
        try printErr("could not parse git URL");
        std.process.exit(1);
    };
    defer switch (target) {
        .remote => |p| p.deinit(allocator),
        .local => |p| allocator.free(p),
    };

    // Ensure runtime dirs exist
    try paths.ensureDirs(allocator);

    // Open (or create) database
    const db_path = try paths.dbPath(allocator);
    defer allocator.free(db_path);

    var db = try database.Db.open(allocator, db_path);
    defer db.deinit();

    switch (target) {
        .local => |abs_path| {
            if (branch_flag != null or tag_flag != null or commit_flag != null) {
                try printErr("installing from a local path does not support --branch, --tag, or --commit");
                std.process.exit(1);
            }

            const trimmed = std.mem.trimRight(u8, abs_path, "/\\");
            const repo_name = std.fs.path.basename(trimmed);
            const alias = alias_flag orelse repo_name;

            if (try db.aliasExists(alias)) {
                const msg = try std.fmt.allocPrint(allocator, "alias '{s}' already exists — use --alias to choose a different name", .{alias});
                defer allocator.free(msg);
                try printErr(msg);
                std.process.exit(1);
            }

            const commit = try git.revParseHeadOrLocal(allocator, abs_path);
            defer allocator.free(commit);

            {
                var buf: [256]u8 = undefined;
                var w = std.fs.File.stdout().writer(&buf);
                try w.interface.print("Building {s} @ {s}...\n", .{ alias, commit[0..@min(8, commit.len)] });
                try w.interface.flush();
            }

            git.submoduleUpdateInit(allocator, abs_path) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "git submodule update failed: {}", .{err});
                defer allocator.free(msg);
                try printErr(msg);
                std.process.exit(1);
            };

            if (!builder.hasBuildZig(abs_path)) {
                try printErr("no build.zig found — only Zig projects are supported");
                std.process.exit(1);
            }

            const build_cache = try paths.buildCacheDir(allocator);
            defer allocator.free(build_cache);

            const bin_dir = try paths.binDir(allocator);
            defer allocator.free(bin_dir);

            const binary_path = builder.buildAndInstall(
                allocator,
                abs_path,
                alias,
                optimize,
                build_cache,
                bin_dir,
            ) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "build failed: {}", .{err});
                defer allocator.free(msg);
                try printErr(msg);
                std.process.exit(1);
            };
            defer allocator.free(binary_path);

            _ = try db.insertPackage(.{
                .name = repo_name,
                .alias = alias,
                .url = abs_path,
                .host = "local",
                .owner = "",
                .repo = repo_name,
                .branch = null,
                .tag = null,
                .commit = commit,
                .optimize = optimize_str,
                .binary_path = binary_path,
            });

            var buf: [512]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            try w.interface.print("Installed '{s}' -> {s}\n", .{ alias, binary_path });
            try w.interface.flush();
            return;
        },
        .remote => |parsed| {
            const alias = alias_flag orelse parsed.repo;

            var effective_branch: ?[]const u8 = null;
            var owns_effective_branch = false;
            defer if (owns_effective_branch and effective_branch != null) allocator.free(effective_branch.?);

            if (try db.aliasExists(alias)) {
                const msg = try std.fmt.allocPrint(allocator, "alias '{s}' already exists — use --alias to choose a different name", .{alias});
                defer allocator.free(msg);
                try printErr(msg);
                std.process.exit(1);
            }

            // Determine ref for clone
            // Resolution precedence: tag > branch+commit > commit > branch > HEAD
            const clone_ref: ?[]const u8 = if (tag_flag) |t|
                t
            else if (branch_flag) |b|
                b
            else
                null;

            const bare_path = try paths.bareRepoPath(allocator, parsed.host, parsed.owner, parsed.repo);
            defer allocator.free(bare_path);

            if (!git.bareExists(bare_path)) {
                git.cloneBare(allocator, url, bare_path, clone_ref) catch |err| {
                    const msg = try std.fmt.allocPrint(allocator, "git clone failed: {}", .{err});
                    defer allocator.free(msg);
                    try printErr(msg);
                    std.process.exit(1);
                };
            }

            const commit: []const u8 = blk: {
                if (tag_flag) |t| {
                    git.fetch(allocator, bare_path, t) catch {};
                    const sha = git.revParse(allocator, bare_path, t) catch {
                        try printErr("could not resolve tag");
                        std.process.exit(1);
                    };
                    break :blk sha;
                } else if (branch_flag) |b| {
                    effective_branch = b;
                    if (commit_flag) |c| {
                        break :blk try allocator.dupe(u8, c);
                    }
                    git.fetch(allocator, bare_path, b) catch {};
                    const sha = git.revParse(allocator, bare_path, "FETCH_HEAD") catch {
                        const sha2 = git.revParse(allocator, bare_path, b) catch {
                            try printErr("could not resolve branch");
                            std.process.exit(1);
                        };
                        break :blk sha2;
                    };
                    break :blk sha;
                } else if (commit_flag) |c| {
                    break :blk try allocator.dupe(u8, c);
                } else {
                    const branch = git.defaultBranch(allocator, bare_path) catch
                        try allocator.dupe(u8, "HEAD");
                    owns_effective_branch = true;
                    if (!std.mem.eql(u8, branch, "HEAD")) {
                        effective_branch = branch;
                    }
                    git.fetch(allocator, bare_path, branch) catch {};
                    const sha = git.revParse(allocator, bare_path, "FETCH_HEAD") catch
                        try git.revParse(allocator, bare_path, "HEAD");
                    break :blk sha;
                }
            };
            defer allocator.free(commit);

            {
                var buf: [256]u8 = undefined;
                var w = std.fs.File.stdout().writer(&buf);
                try w.interface.print("Building {s}...\n", .{alias});
                try w.interface.flush();
            }

            var tmp = try fugaz.tempDir(allocator);
            defer tmp.deinit();
            const worktree_path = try allocator.dupe(u8, tmp.path());
            defer allocator.free(worktree_path);

            tmp.close() catch {};

            git.worktreeAdd(allocator, bare_path, worktree_path, commit) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "git worktree add failed: {}", .{err});
                defer allocator.free(msg);
                try printErr(msg);
                std.process.exit(1);
            };
            defer git.worktreeRemove(allocator, bare_path, worktree_path);

            if (effective_branch) |b| {
                git.checkoutBranchAtCommit(allocator, worktree_path, b, commit) catch |err| {
                    const msg = try std.fmt.allocPrint(allocator, "git checkout failed: {}", .{err});
                    defer allocator.free(msg);
                    try printErr(msg);
                    std.process.exit(1);
                };
            }

            git.submoduleUpdateInit(allocator, worktree_path) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "git submodule update failed: {}", .{err});
                defer allocator.free(msg);
                try printErr(msg);
                std.process.exit(1);
            };

            if (!builder.hasBuildZig(worktree_path)) {
                try printErr("no build.zig found — only Zig projects are supported");
                std.process.exit(1);
            }

            const build_cache = try paths.buildCacheDir(allocator);
            defer allocator.free(build_cache);

            const bin_dir = try paths.binDir(allocator);
            defer allocator.free(bin_dir);

            const binary_path = builder.buildAndInstall(
                allocator,
                worktree_path,
                alias,
                optimize,
                build_cache,
                bin_dir,
            ) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "build failed: {}", .{err});
                defer allocator.free(msg);
                try printErr(msg);
                std.process.exit(1);
            };
            defer allocator.free(binary_path);

            _ = try db.insertPackage(.{
                .name = parsed.repo,
                .alias = alias,
                .url = url,
                .host = parsed.host,
                .owner = parsed.owner,
                .repo = parsed.repo,
                .branch = effective_branch,
                .tag = tag_flag,
                .commit = commit,
                .optimize = optimize_str,
                .binary_path = binary_path,
            });

            var buf: [512]u8 = undefined;
            var w = std.fs.File.stdout().writer(&buf);
            try w.interface.print("Installed '{s}' -> {s}\n", .{ alias, binary_path });
            try w.interface.flush();
        },
    }
}

fn printErr(msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print("error: {s}\n", .{msg});
    try w.interface.flush();
}
