//! Database module for managing installed packages
const std = @import("std");
const sqlite = @import("sqlite");

const Allocator = std.mem.Allocator;

/// Package record in the database
pub const PackageRecord = struct {
    name: []const u8,
    repository_url: []const u8,
    git_ref_type: ?[]const u8, // "tag", "branch", or null for commit
    git_ref: ?[]const u8, // tag name, branch name, or commit hash
    commit_hash: []const u8,
    alias: ?[]const u8,
};

/// Database manager
pub const Database = struct {
    db: sqlite.Db,
    allocator: Allocator,

    /// Initialize the database, creating tables if needed
    pub fn init(allocator: Allocator, db_path: [:0]const u8) !Database {
        var db = try sqlite.Db.init(.{
            .mode = .{ .File = db_path },
            .open_flags = .{ .write = true, .create = true },
        });

        // Create tables if they don't exist
        try db.exec(
            \\CREATE TABLE IF NOT EXISTS packages (
            \\    name TEXT PRIMARY KEY,
            \\    repository_url TEXT NOT NULL,
            \\    git_ref_type TEXT,
            \\    git_ref TEXT,
            \\    commit_hash TEXT NOT NULL,
            \\    alias TEXT
            \\)
        , .{}, .{});

        return Database{
            .db = db,
            .allocator = allocator,
        };
    }

    /// Deinitialize the database
    pub fn deinit(self: *Database) void {
        self.db.deinit();
    }

    /// Get package information by name or alias
    pub fn getPackage(self: *Database, package_name: []const u8) !?PackageRecord {
        var stmt = try self.db.prepare(
            \\SELECT name, repository_url, git_ref_type, git_ref, commit_hash, alias
            \\FROM packages
            \\WHERE name = ? OR alias = ?
        );
        defer stmt.deinit();

        // Use oneAlloc to get a single row with allocated strings
        const Row = struct {
            name: []const u8,
            repository_url: []const u8,
            git_ref_type: ?[]const u8,
            git_ref: ?[]const u8,
            commit_hash: []const u8,
            alias: ?[]const u8,
        };

        const row = try stmt.oneAlloc(Row, self.allocator, .{}, .{
            .name = package_name,
            .alias = package_name,
        });

        if (row) |r| {
            return PackageRecord{
                .name = r.name,
                .repository_url = r.repository_url,
                .git_ref_type = r.git_ref_type,
                .git_ref = r.git_ref,
                .commit_hash = r.commit_hash,
                .alias = r.alias,
            };
        }

        return null;
    }

    /// Insert or update a package record
    pub fn upsertPackage(self: *Database, record: PackageRecord) !void {
        var stmt = try self.db.prepare(
            \\INSERT OR REPLACE INTO packages (name, repository_url, git_ref_type, git_ref, commit_hash, alias)
            \\VALUES (?, ?, ?, ?, ?, ?)
        );
        defer stmt.deinit();

        try stmt.exec(.{}, .{
            .name = record.name,
            .repository_url = record.repository_url,
            .git_ref_type = record.git_ref_type,
            .git_ref = record.git_ref,
            .commit_hash = record.commit_hash,
            .alias = record.alias,
        });
    }

    /// Delete a package by name or alias
    pub fn deletePackage(self: *Database, package_name: []const u8) !void {
        var stmt = try self.db.prepare(
            \\DELETE FROM packages WHERE name = ? OR alias = ?
        );
        defer stmt.deinit();

        try stmt.exec(.{}, .{
            .name = package_name,
            .alias = package_name,
        });
    }

    /// List all packages
    pub fn listPackages(self: *Database) !std.ArrayList(PackageRecord) {
        var stmt = try self.db.prepare(
            \\SELECT name, repository_url, git_ref_type, git_ref, commit_hash, alias
            \\FROM packages
            \\ORDER BY name
        );
        defer stmt.deinit();

        const Row = struct {
            name: []const u8,
            repository_url: []const u8,
            git_ref_type: ?[]const u8,
            git_ref: ?[]const u8,
            commit_hash: []const u8,
            alias: ?[]const u8,
        };

        const rows = try stmt.all(Row, self.allocator, .{}, .{});

        var packages = std.ArrayList(PackageRecord).init(self.allocator);
        errdefer {
            for (packages.items) |*pkg| {
                self.allocator.free(pkg.name);
                self.allocator.free(pkg.repository_url);
                if (pkg.git_ref_type) |r| self.allocator.free(r);
                if (pkg.git_ref) |r| self.allocator.free(r);
                self.allocator.free(pkg.commit_hash);
                if (pkg.alias) |a| self.allocator.free(a);
            }
            packages.deinit();
        }

        for (rows) |row| {
            try packages.append(PackageRecord{
                .name = try self.allocator.dupe(u8, row.name),
                .repository_url = try self.allocator.dupe(u8, row.repository_url),
                .git_ref_type = if (row.git_ref_type) |r| try self.allocator.dupe(u8, r) else null,
                .git_ref = if (row.git_ref) |r| try self.allocator.dupe(u8, r) else null,
                .commit_hash = try self.allocator.dupe(u8, row.commit_hash),
                .alias = if (row.alias) |a| try self.allocator.dupe(u8, a) else null,
            });
        }

        return packages;
    }
};
