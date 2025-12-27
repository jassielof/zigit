//! Info command - Show information about an installed or to-be-installed package
const std = @import("std");
const fangz = @import("fangz");
const zigit = @import("zigit");

const ArgMatches = fangz.ArgMatches;
const Database = zigit.database.Database;
const PackageRecord = zigit.database.PackageRecord;
const paths = zigit.paths;
const git = zigit.git;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
const allocator = gpa.allocator();

/// Package information structure
const PackageInfo = struct {
    name: []const u8,
    repository_url: []const u8,
    git_ref_type: ?[]const u8, // "tag", "branch", or null for commit
    git_ref: ?[]const u8, // tag name, branch name, or commit hash
    commit_hash: []const u8,
    description: ?[]const u8,
    author: ?[]const u8,
    is_installed: bool,
    is_outdated: bool,

    pub fn deinit(self: *PackageInfo) void {
        allocator.free(self.name);
        allocator.free(self.repository_url);
        if (self.git_ref_type) |r| allocator.free(r);
        if (self.git_ref) |r| allocator.free(r);
        allocator.free(self.commit_hash);
        if (self.description) |d| allocator.free(d);
        if (self.author) |a| allocator.free(a);
    }
};

/// Execute the info command
pub fn execute(matches: ArgMatches) !void {
    defer _ = gpa.deinit();

    const package_name_or_url = matches.getSingleValue("PACKAGE") orelse {
        std.log.err("Error: PACKAGE argument is required", .{});
        std.process.exit(1);
    };

    // Determine if it's a URL or package name
    const is_url = std.mem.indexOf(u8, package_name_or_url, "://") != null or
        std.mem.indexOf(u8, package_name_or_url, "git@") != null;

    var info: PackageInfo = undefined;
    errdefer info.deinit();

    if (is_url) {
        // It's a repository URL - fetch info from git
        info = try getInfoFromRepository(package_name_or_url);
    } else {
        // It's a package name - check if installed
        info = try getInfoFromInstalled(package_name_or_url);
    }

    // Display the information
    try displayInfo(info);
    info.deinit();
}

/// Get package information from a repository URL (for to-be-installed packages)
fn getInfoFromRepository(repo_url: []const u8) !PackageInfo {
    // Check if repository is already cached
    const cache_path = paths.getRepositoryCachePath(allocator, repo_url) catch |err| {
        std.log.warn("Could not get cache path: {}", .{err});
        // Fallback: clone to temp
        return getInfoFromRepositoryTemp(repo_url);
    };
    defer allocator.free(cache_path);

    // Check if cached repository exists
    var cache_dir = std.fs.cwd().openDir(cache_path, .{}) catch {
        // Not cached, clone to temp
        return getInfoFromRepositoryTemp(repo_url);
    };
    defer cache_dir.close();

    // Get info from cached repository
    const repo_info = try git.getRepoInfo(allocator, cache_path);
    defer {
        allocator.free(repo_info.commit_hash);
        if (repo_info.current_branch) |b| allocator.free(b);
        if (repo_info.current_tag) |t| allocator.free(t);
        if (repo_info.description) |d| allocator.free(d);
        if (repo_info.author) |a| allocator.free(a);
    }

    const name = try extractPackageNameFromUrl(repo_url);
    const git_ref_type: ?[]const u8 = if (repo_info.current_tag) |_|
        try allocator.dupe(u8, "tag")
    else if (repo_info.current_branch) |_|
        try allocator.dupe(u8, "branch")
    else null;
    const git_ref = repo_info.current_tag orelse repo_info.current_branch;

    return PackageInfo{
        .name = name,
        .repository_url = try allocator.dupe(u8, repo_url),
        .git_ref_type = git_ref_type,
        .git_ref = if (git_ref) |r| try allocator.dupe(u8, r) else null,
        .commit_hash = try allocator.dupe(u8, repo_info.commit_hash),
        .description = if (repo_info.description) |d| try allocator.dupe(u8, d) else null,
        .author = if (repo_info.author) |a| try allocator.dupe(u8, a) else null,
        .is_installed = false,
        .is_outdated = false,
    };
}

/// Get package information by cloning to a temporary location
fn getInfoFromRepositoryTemp(repo_url: []const u8) !PackageInfo {
    // Clone to temporary location
    const temp_path = try git.cloneToTemp(allocator, repo_url);
    defer {
        // Clean up temp directory
        std.fs.cwd().deleteTree(temp_path) catch {};
        allocator.free(temp_path);
    }

    // Get info from cloned repository
    const repo_info = try git.getRepoInfo(allocator, temp_path);
    defer {
        allocator.free(repo_info.commit_hash);
        if (repo_info.current_branch) |b| allocator.free(b);
        if (repo_info.current_tag) |t| allocator.free(t);
        if (repo_info.description) |d| allocator.free(d);
        if (repo_info.author) |a| allocator.free(a);
    }

    const name = try extractPackageNameFromUrl(repo_url);
    const git_ref_type: ?[]const u8 = if (repo_info.current_tag) |_|
        try allocator.dupe(u8, "tag")
    else if (repo_info.current_branch) |_|
        try allocator.dupe(u8, "branch")
    else null;
    const git_ref = repo_info.current_tag orelse repo_info.current_branch;

    return PackageInfo{
        .name = name,
        .repository_url = try allocator.dupe(u8, repo_url),
        .git_ref_type = git_ref_type,
        .git_ref = if (git_ref) |r| try allocator.dupe(u8, r) else null,
        .commit_hash = try allocator.dupe(u8, repo_info.commit_hash),
        .description = if (repo_info.description) |d| try allocator.dupe(u8, d) else null,
        .author = if (repo_info.author) |a| try allocator.dupe(u8, a) else null,
        .is_installed = false,
        .is_outdated = false,
    };
}

/// Get package information from installed packages database
fn getInfoFromInstalled(package_name: []const u8) !PackageInfo {
    const db_path = try paths.getDatabasePath(allocator);
    defer allocator.free(db_path);

    var db = try Database.init(allocator, db_path);
    defer db.deinit();

    const record = try db.getPackage(package_name);
    if (record) |pkg| {
        defer {
            allocator.free(pkg.name);
            allocator.free(pkg.repository_url);
            if (pkg.git_ref_type) |r| allocator.free(r);
            if (pkg.git_ref) |r| allocator.free(r);
            allocator.free(pkg.commit_hash);
            if (pkg.alias) |a| allocator.free(a);
        }

        // Check if outdated by comparing with remote
        const is_outdated = checkIfOutdated(pkg.repository_url, pkg.commit_hash) catch false;

        // Try to get description and author from cached repository
        const cache_path = paths.getRepositoryCachePath(allocator, pkg.repository_url) catch null;
        defer if (cache_path) |p| allocator.free(p);

        var description: ?[]const u8 = null;
        var author: ?[]const u8 = null;

        if (cache_path) |cp| {
            const repo_info = git.getRepoInfo(allocator, cp) catch null;
            if (repo_info) |ri| {
                defer {
                    allocator.free(ri.commit_hash);
                    if (ri.current_branch) |b| allocator.free(b);
                    if (ri.current_tag) |t| allocator.free(t);
                    if (ri.description) |d| allocator.free(d);
                    if (ri.author) |a| allocator.free(a);
                }
                description = if (ri.description) |d| try allocator.dupe(u8, d) else null;
                author = if (ri.author) |a| try allocator.dupe(u8, a) else null;
            }
        }

        return PackageInfo{
            .name = try allocator.dupe(u8, pkg.name),
            .repository_url = try allocator.dupe(u8, pkg.repository_url),
            .git_ref_type = if (pkg.git_ref_type) |r| try allocator.dupe(u8, r) else null,
            .git_ref = if (pkg.git_ref) |r| try allocator.dupe(u8, r) else null,
            .commit_hash = try allocator.dupe(u8, pkg.commit_hash),
            .description = description,
            .author = author,
            .is_installed = true,
            .is_outdated = is_outdated,
        };
    } else {
        std.log.err("Package '{s}' not found in database", .{package_name});
        std.process.exit(1);
    }
}

/// Check if a package is outdated by comparing local commit with remote
fn checkIfOutdated(repo_url: []const u8, local_commit: []const u8) !bool {
    // TODO: Fetch from remote and compare commits
    // For now, return false
    _ = repo_url;
    _ = local_commit;
    return false;
}

/// Extract package name from repository URL
fn extractPackageNameFromUrl(url: []const u8) ![]const u8 {
    // Handle different URL formats:
    // - https://github.com/user/repo.git
    // - git@github.com:user/repo.git
    // - github.com/user/repo

    var url_copy = try allocator.dupe(u8, url);
    errdefer allocator.free(url_copy);

    // Remove .git suffix if present
    if (std.mem.endsWith(u8, url_copy, ".git")) {
        url_copy = url_copy[0..url_copy.len - 4];
    }

    // Find the last component (repo name)
    if (std.mem.lastIndexOf(u8, url_copy, "/")) |last_slash| {
        return try allocator.dupe(u8, url_copy[last_slash + 1..]);
    }

    if (std.mem.lastIndexOf(u8, url_copy, ":")) |last_colon| {
        return try allocator.dupe(u8, url_copy[last_colon + 1..]);
    }

    return url_copy;
}

/// Display package information in a formatted way
fn displayInfo(info: PackageInfo) !void {
    var buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Package: {s}\n", .{info.name});
    try stdout.print("Repository: {s}\n", .{info.repository_url});

    if (info.git_ref_type) |ref_type| {
        try stdout.print("Git Reference: {s} ({s})\n", .{ ref_type, info.git_ref.? });
    }
    try stdout.print("Commit: {s}\n", .{info.commit_hash});

    if (info.description) |desc| {
        try stdout.print("Description: {s}\n", .{desc});
    }

    if (info.author) |author| {
        try stdout.print("Author: {s}\n", .{author});
    }

    try stdout.print("Status: {s}", .{if (info.is_installed) "Installed" else "Not Installed"});

    if (info.is_installed and info.is_outdated) {
        try stdout.print(" (Outdated)", .{});
    }
    try stdout.print("\n", .{});

    try stdout.flush();
}
