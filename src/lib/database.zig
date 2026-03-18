//! Database layer: wraps sqlite-zig with the zigit schema.
//!
//! Schema version: 1
//! All mutations are wrapped in transactions for atomicity.

const std = @import("std");
const sqlite = @import("sqlite");
const Allocator = std.mem.Allocator;

pub const SCHEMA_VERSION: i64 = 1;

/// A package row as returned from the database.
/// All slice fields are heap-allocated via the Db's allocator.
/// Call `sqlite.release(allocator, pkg)` or `pkg.deinit(allocator)` to free.
pub const Package = struct {
    id: i64,
    name: []const u8,
    alias: []const u8,
    url: []const u8,
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
    branch: ?[]const u8,
    tag: ?[]const u8,
    commit: []const u8,
    pinned: bool,
    installed_at: []const u8,
    updated_at: []const u8,
    binary_path: []const u8,

    pub fn deinit(self: *const Package, allocator: Allocator) void {
        sqlite.release(allocator, self.*);
    }
};

/// Parameters for inserting a new package record.
pub const InsertParams = struct {
    name: []const u8,
    alias: []const u8,
    url: []const u8,
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
    branch: ?[]const u8,
    tag: ?[]const u8,
    commit: []const u8,
    optimize: []const u8,
    binary_path: []const u8,
};

/// Parameters for updating a package record after a rebuild.
pub const UpdateParams = struct {
    commit: []const u8,
    branch: ?[]const u8,
    tag: ?[]const u8,
    binary_path: []const u8,
    updated_at: []const u8,
};

pub const Db = struct {
    inner: sqlite.Db,

    pub fn open(allocator: Allocator, path: [:0]const u8) !Db {
        var db = try sqlite.Db.open(allocator, .{ .path = path });
        errdefer db.deinit();

        try db.exec("PRAGMA journal_mode = WAL", .{});
        try db.exec("PRAGMA foreign_keys = ON", .{});

        try db.exec(
            \\CREATE TABLE IF NOT EXISTS schema_version (
            \\  version INTEGER NOT NULL
            \\)
        , .{});

        try db.exec(
            \\CREATE TABLE IF NOT EXISTS packages (
            \\  id           INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  name         TEXT NOT NULL,
            \\  alias        TEXT NOT NULL UNIQUE,
            \\  url          TEXT NOT NULL,
            \\  host         TEXT NOT NULL,
            \\  owner        TEXT NOT NULL,
            \\  repo         TEXT NOT NULL,
            \\  branch       TEXT,
            \\  tag          TEXT,
            \\  "commit"     TEXT NOT NULL,
            \\  pinned       INTEGER NOT NULL DEFAULT 0,
            \\  installed_at TEXT NOT NULL,
            \\  updated_at   TEXT NOT NULL,
            \\  binary_path  TEXT NOT NULL
            \\)
        , .{});

        try db.exec(
            \\CREATE TABLE IF NOT EXISTS build_log (
            \\  id         INTEGER PRIMARY KEY AUTOINCREMENT,
            \\  package_id INTEGER NOT NULL REFERENCES packages(id) ON DELETE CASCADE,
            \\  timestamp  TEXT NOT NULL,
            \\  optimize   TEXT NOT NULL DEFAULT 'ReleaseFast',
            \\  success    INTEGER NOT NULL,
            \\  output     TEXT
            \\)
        , .{});

        // Seed schema_version if empty
        const count = (try db.one(i64, "SELECT COUNT(*) FROM schema_version", .{})) orelse 0;
        if (count == 0) {
            try db.exec("INSERT INTO schema_version (version) VALUES (?)", .{SCHEMA_VERSION});
        }

        return Db{ .inner = db };
    }

    pub fn deinit(self: *Db) void {
        self.inner.deinit();
    }

    // ------------------------------------------------------------------ //
    //  Packages                                                            //
    // ------------------------------------------------------------------ //

    /// Insert a new package record. Returns the new row id.
    pub fn insertPackage(self: *Db, p: InsertParams) !i64 {
        const now = try isoNow(self.inner.allocator);
        defer self.inner.allocator.free(now);

        var tx = try self.inner.transaction(.immediate);
        defer tx.deinit();

        try self.inner.exec(
            \\INSERT INTO packages
            \\  (name, alias, url, host, owner, repo, branch, tag, "commit",
            \\   pinned, installed_at, updated_at, binary_path)
            \\VALUES (:name, :alias, :url, :host, :owner, :repo, :branch, :tag, :commit,
            \\        0, :now, :now, :binary_path)
        , .{
            .name = p.name,
            .alias = p.alias,
            .url = p.url,
            .host = p.host,
            .owner = p.owner,
            .repo = p.repo,
            .branch = p.branch,
            .tag = p.tag,
            .commit = p.commit,
            .now = now,
            .binary_path = p.binary_path,
        });

        const pkg_id = self.inner.lastInsertRowId();

        try self.inner.exec(
            \\INSERT INTO build_log (package_id, timestamp, optimize, success)
            \\VALUES (:pkg_id, :now, :optimize, 1)
        , .{ .pkg_id = pkg_id, .now = now, .optimize = p.optimize });

        try tx.commit();
        return pkg_id;
    }

    /// Update a package record after a rebuild.
    pub fn updatePackage(self: *Db, alias: []const u8, p: UpdateParams, optimize: []const u8, success: bool, output: ?[]const u8) !void {
        var tx = try self.inner.transaction(.immediate);
        defer tx.deinit();

        try self.inner.exec(
            \\UPDATE packages SET
            \\  "commit" = :commit, branch = :branch, tag = :tag,
            \\  binary_path = :binary_path, updated_at = :updated_at
            \\WHERE alias = :alias
        , .{
            .commit = p.commit,
            .branch = p.branch,
            .tag = p.tag,
            .binary_path = p.binary_path,
            .updated_at = p.updated_at,
            .alias = alias,
        });

        const pkg_id = try self.inner.one(i64, "SELECT id FROM packages WHERE alias = :alias", .{ .alias = alias }) orelse
            return error.PackageNotFound;

        try self.inner.exec(
            \\INSERT INTO build_log (package_id, timestamp, optimize, success, output)
            \\VALUES (:pkg_id, :updated_at, :optimize, :success, :output)
        , .{
            .pkg_id = pkg_id,
            .updated_at = p.updated_at,
            .optimize = optimize,
            .success = @as(i64, if (success) 1 else 0),
            .output = output,
        });

        try tx.commit();
    }

    /// Look up a package by alias or name. Caller must call `pkg.deinit(allocator)`.
    pub fn getPackage(self: *Db, alias_or_name: []const u8) !?Package {
        return self.inner.one(Package,
            \\SELECT id, name, alias, url, host, owner, repo,
            \\       branch, tag, "commit" AS "commit", pinned, installed_at, updated_at, binary_path
            \\FROM packages WHERE alias = :key OR name = :key LIMIT 1
        , .{ .key = alias_or_name });
    }

    /// Returns true if any package has this alias.
    pub fn aliasExists(self: *Db, alias: []const u8) !bool {
        const n = try self.inner.one(i64, "SELECT 1 FROM packages WHERE alias = :alias LIMIT 1", .{ .alias = alias });
        return n != null;
    }

    /// List all packages sorted by alias. Caller must call
    /// `sqlite.release(allocator, packages)` on the result.
    pub fn listPackages(self: *Db) ![]Package {
        return self.inner.all(Package,
            \\SELECT id, name, alias, url, host, owner, repo,
            \\       branch, tag, "commit" AS "commit", pinned, installed_at, updated_at, binary_path
            \\FROM packages ORDER BY alias
        , .{});
    }

    /// Delete a package by alias (cascades to build_log).
    pub fn deletePackage(self: *Db, alias: []const u8) !void {
        try self.inner.exec("DELETE FROM packages WHERE alias = :alias", .{ .alias = alias });
    }

    /// Rename a package's alias.
    pub fn renameAlias(self: *Db, old_alias: []const u8, new_alias: []const u8) !void {
        try self.inner.exec(
            "UPDATE packages SET alias = :new_alias WHERE alias = :old_alias",
            .{ .new_alias = new_alias, .old_alias = old_alias },
        );
    }

    /// Toggle the pinned flag.
    pub fn setPinned(self: *Db, alias: []const u8, pinned: bool) !void {
        try self.inner.exec(
            "UPDATE packages SET pinned = :pinned WHERE alias = :alias",
            .{ .pinned = @as(i64, if (pinned) 1 else 0), .alias = alias },
        );
    }
};

// ---- helpers ----------------------------------------------------------------

/// Return the current UTC time as an ISO-8601 string (YYYY-MM-DDTHH:MM:SSZ).
/// Caller owns the returned slice.
pub fn isoNow(allocator: Allocator) ![]u8 {
    const ts: u64 = @intCast(std.time.timestamp());
    const epoch = std.time.epoch.EpochSeconds{ .secs = ts };
    const yd = epoch.getEpochDay();
    const ds = epoch.getDaySeconds();
    const yr = yd.calculateYearDay();
    const md = yr.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yr.year,
        md.month.numeric(),
        md.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}
