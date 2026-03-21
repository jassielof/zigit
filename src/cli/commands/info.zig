//! `zigit info <alias|url>`
//!
//! Shows detailed information about an installed package (read from DB) or
//! a not-yet-installed repository (shallow-cloned to a temp dir).

const std = @import("std");
const fangz = @import("fangz");
const zigit = @import("zigit");

const Command = fangz.Command;
const ParseContext = fangz.ParseContext;
const paths = zigit.paths;
const git = zigit.git;
const database = zigit.database;
const fugaz = @import("fugaz");
const carnaval = @import("carnaval");

pub fn setup(parent: *Command) !void {
    const cmd = try parent.addSubcommand(.{
        .name = "info",
        .description = "Show information about an installed tool or a Git repository URL",
    });

    cmd.help_on_empty_args = true;

    try cmd.addPositional(.{
        .name = "target",
        .description = "Alias of an installed tool, or repository target (URL, host/owner/repo, gh/owner/repo)",
        .required = true,
    });

    try cmd.addFlag(bool, .{
        .name = "list-branches",
        .description = "List remote branches",
    });
    try cmd.addFlag(bool, .{
        .name = "list-tags",
        .description = "List remote tags",
    });

    cmd.hooks.run = &run;
}

fn run(ctx: *ParseContext) anyerror!void {
    const allocator = ctx.allocator;

    const target = ctx.positional(0) orelse {
        try printErr("missing target argument");
        std.process.exit(1);
    };

    const list_branches = ctx.boolFlag("list-branches") orelse false;
    const list_tags = ctx.boolFlag("list-tags") orelse false;

    const is_url = looksLikeRepoTarget(target);

    if (is_url) {
        try infoFromUrl(allocator, target, list_branches, list_tags);
    } else {
        try infoFromInstalled(allocator, target, list_branches, list_tags);
    }
}

fn looksLikeRepoTarget(target: []const u8) bool {
    if (std.mem.indexOf(u8, target, "://") != null) return true;
    if (std.mem.startsWith(u8, target, "git@")) return true;
    if (std.mem.startsWith(u8, target, "gh/")) return true;
    if (std.mem.indexOfScalar(u8, target, '/') != null) return true;
    return false;
}

fn infoFromInstalled(allocator: std.mem.Allocator, alias: []const u8, list_branches: bool, list_tags: bool) !void {
    const db_path = try paths.dbPath(allocator);
    defer allocator.free(db_path);

    var db = try database.Db.open(allocator, db_path);
    defer db.deinit();

    const pkg = try db.getPackage(alias) orelse {
        const msg = try std.fmt.allocPrint(allocator, "'{s}' is not installed", .{alias});
        defer allocator.free(msg);
        try printErr(msg);
        std.process.exit(1);
    };
    defer pkg.deinit(allocator);

    const canonical_url = try std.fmt.allocPrint(allocator, "https://{s}/{s}/{s}.git", .{ pkg.host, pkg.owner, pkg.repo });
    defer allocator.free(canonical_url);

    const bare_path = try paths.bareRepoPath(allocator, pkg.host, pkg.owner, pkg.repo);
    defer allocator.free(bare_path);

    var details = gatherRepoDetailsFromBare(allocator, bare_path, canonical_url, list_branches, list_tags) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "failed to gather repository details: {}", .{err});
        defer allocator.free(msg);
        try printErr(msg);
        std.process.exit(1);
    };
    defer details.deinit(allocator);

    try printInfo(allocator, .{
        .name = pkg.name,
        .url = pkg.url,
        .host = pkg.host,
        .owner = pkg.owner,
        .repo = pkg.repo,
        .default_branch = details.default_branch,
        .head_commit = details.head_commit,
        .latest_tag = details.latest_tag,
        .tags = details.tags,
        .branches = details.branches,
        .manifest = details.manifest,
        .build_script = details.build_script,
        .installed = true,
        .alias = pkg.alias,
        .pinned = pkg.pinned,
        .binary_path = pkg.binary_path,
        .installed_at = pkg.installed_at,
        .updated_at = pkg.updated_at,
    });
}

fn infoFromUrl(allocator: std.mem.Allocator, target: []const u8, list_branches: bool, list_tags: bool) !void {
    const normalized_target = try normalizeRepoTargetSlashes(allocator, target);
    defer allocator.free(normalized_target);

    const canonical_url = if (std.mem.startsWith(u8, normalized_target, "gh/"))
        try std.fmt.allocPrint(allocator, "https://github.com/{s}.git", .{normalized_target[3..]})
    else
        git.canonicalRemoteUrl(allocator, normalized_target) catch {
            try printErr("could not parse git URL");
            std.process.exit(1);
        };
    defer allocator.free(canonical_url);

    const parsed = git.parseUrl(allocator, canonical_url) catch {
        try printErr("could not parse git URL");
        std.process.exit(1);
    };
    defer parsed.deinit(allocator);

    var buf: [256]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);
    try w.interface.print("Fetching info for {s}/{s}/{s}...\n", .{ parsed.host, parsed.owner, parsed.repo });
    try w.interface.flush();

    var tmp = try fugaz.tempDir(allocator);
    defer tmp.deinit();
    const tmp_path = tmp.path();

    git.cloneBare(allocator, canonical_url, tmp_path, null) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "clone failed: {}", .{err});
        defer allocator.free(msg);
        try printErr(msg);
        std.process.exit(1);
    };

    var details = gatherRepoDetailsFromBare(allocator, tmp_path, canonical_url, list_branches, list_tags) catch |err| {
        const msg = try std.fmt.allocPrint(allocator, "failed to gather repository details: {}", .{err});
        defer allocator.free(msg);
        try printErr(msg);
        std.process.exit(1);
    };
    defer details.deinit(allocator);

    try printInfo(allocator, .{
        .name = parsed.repo,
        .url = canonical_url,
        .host = parsed.host,
        .owner = parsed.owner,
        .repo = parsed.repo,
        .default_branch = details.default_branch,
        .head_commit = details.head_commit,
        .latest_tag = details.latest_tag,
        .tags = details.tags,
        .branches = details.branches,
        .manifest = details.manifest,
        .build_script = details.build_script,
        .installed = false,
        .alias = null,
        .pinned = null,
        .binary_path = null,
        .installed_at = null,
        .updated_at = null,
    });
}

fn normalizeRepoTargetSlashes(allocator: std.mem.Allocator, target: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, target);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

const RefEntry = struct {
    name: []u8,
    commit: []u8,

    fn deinit(self: *RefEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.commit);
    }
};

const ManifestDependency = struct {
    name: []u8,
    path: ?[]u8,
    url: ?[]u8,
    is_submodule_path: bool,

    fn deinit(self: *ManifestDependency, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.path) |p| allocator.free(p);
        if (self.url) |u| allocator.free(u);
    }
};

const ManifestInfo = struct {
    present: bool,
    name: ?[]u8,
    version: ?[]u8,
    minimum_zig_version: ?[]u8,
    dependencies: []ManifestDependency,
    paths: [][]u8,
    submodules: [][]u8,

    fn deinit(self: *ManifestInfo, allocator: std.mem.Allocator) void {
        if (self.name) |s| allocator.free(s);
        if (self.version) |s| allocator.free(s);
        if (self.minimum_zig_version) |s| allocator.free(s);
        for (self.dependencies) |*d| d.deinit(allocator);
        allocator.free(self.dependencies);
        for (self.paths) |p| allocator.free(p);
        allocator.free(self.paths);
        for (self.submodules) |s| allocator.free(s);
        allocator.free(self.submodules);
    }
};

const BuildImport = struct {
    name: []u8,

    fn deinit(self: *BuildImport, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

const BuildUnit = struct {
    kind: []const u8,
    variable: []u8,
    name_expr: ?[]u8,
    root_source_file: ?[]u8,
    target_expr: ?[]u8,
    optimize_expr: ?[]u8,
    imports: []BuildImport,
    installed: bool,
    has_run_step: bool,

    fn deinit(self: *BuildUnit, allocator: std.mem.Allocator) void {
        allocator.free(self.variable);
        if (self.name_expr) |s| allocator.free(s);
        if (self.root_source_file) |s| allocator.free(s);
        if (self.target_expr) |s| allocator.free(s);
        if (self.optimize_expr) |s| allocator.free(s);
        for (self.imports) |*imp| imp.deinit(allocator);
        allocator.free(self.imports);
    }
};

const BuildScriptInfo = struct {
    present: bool,
    units: []BuildUnit,

    fn deinit(self: *BuildScriptInfo, allocator: std.mem.Allocator) void {
        for (self.units) |*u| u.deinit(allocator);
        allocator.free(self.units);
    }
};

const RepoDetails = struct {
    default_branch: []u8,
    head_commit: []u8,
    latest_tag: ?[]u8,
    tags: []RefEntry,
    branches: []RefEntry,
    manifest: ManifestInfo,
    build_script: BuildScriptInfo,

    fn deinit(self: *RepoDetails, allocator: std.mem.Allocator) void {
        allocator.free(self.default_branch);
        allocator.free(self.head_commit);
        if (self.latest_tag) |t| allocator.free(t);
        for (self.tags) |*tag| tag.deinit(allocator);
        allocator.free(self.tags);
        for (self.branches) |*br| br.deinit(allocator);
        allocator.free(self.branches);
        self.manifest.deinit(allocator);
        self.build_script.deinit(allocator);
    }
};

const InfoDisplay = struct {
    name: []const u8,
    url: []const u8,
    host: []const u8,
    owner: []const u8,
    repo: []const u8,
    default_branch: []const u8,
    head_commit: []const u8,
    latest_tag: ?[]const u8,
    tags: []const RefEntry,
    branches: []const RefEntry,
    manifest: ManifestInfo,
    build_script: BuildScriptInfo,
    installed: bool,
    alias: ?[]const u8,
    pinned: ?bool,
    binary_path: ?[]const u8,
    installed_at: ?[]const u8,
    updated_at: ?[]const u8,
};

fn gatherRepoDetailsFromBare(allocator: std.mem.Allocator, bare_path: []const u8, canonical_url: []const u8, list_branches: bool, list_tags: bool) !RepoDetails {
    _ = canonical_url;

    _ = git.run(allocator, null, &.{ "-C", bare_path, "fetch", "--quiet", "origin", "+refs/heads/*:refs/remotes/origin/*" }) catch "";
    _ = git.run(allocator, null, &.{ "-C", bare_path, "fetch", "--quiet", "--tags", "origin" }) catch "";

    var default_branch = git.defaultBranch(allocator, bare_path) catch try allocator.dupe(u8, "(unknown)");

    const tags = try gatherRefs(allocator, bare_path, .tags, list_tags);
    const branches = try gatherRefs(allocator, bare_path, .branches, list_branches);
    if (std.mem.eql(u8, default_branch, "(unknown)") and branches.len > 0) {
        allocator.free(default_branch);
        default_branch = try allocator.dupe(u8, branches[0].name);
    }

    const branch_ref = if (std.mem.eql(u8, default_branch, "(unknown)"))
        "HEAD"
    else
        try std.fmt.allocPrint(allocator, "refs/remotes/origin/{s}", .{default_branch});
    defer if (!std.mem.eql(u8, default_branch, "(unknown)")) allocator.free(branch_ref);

    const head_commit = git.revParse(allocator, bare_path, branch_ref) catch
        git.revParse(allocator, bare_path, "HEAD") catch
        try allocator.dupe(u8, "(unknown)");

    const latest_tag = if (tags.len > 0) try allocator.dupe(u8, tags[0].name) else null;

    const manifest_src = try readGitFileAtCommit(allocator, bare_path, head_commit, "build.zig.zon");
    defer if (manifest_src) |s| allocator.free(s);

    const gitmodules_src = try readGitFileAtCommit(allocator, bare_path, head_commit, ".gitmodules");
    defer if (gitmodules_src) |s| allocator.free(s);

    const build_src = try readGitFileAtCommit(allocator, bare_path, head_commit, "build.zig");
    defer if (build_src) |s| allocator.free(s);

    const manifest = try inspectManifestFromSource(allocator, manifest_src, gitmodules_src);
    const build_script = try inspectBuildScriptFromSource(allocator, build_src);

    return RepoDetails{
        .default_branch = default_branch,
        .head_commit = head_commit,
        .latest_tag = latest_tag,
        .tags = tags,
        .branches = branches,
        .manifest = manifest,
        .build_script = build_script,
    };
}

fn gatherRefs(allocator: std.mem.Allocator, bare_path: []const u8, kind: git.RefKind, include_all: bool) ![]RefEntry {
    const refs = git.listRemoteRefs(allocator, bare_path, kind) catch return &.{};
    defer {
        for (refs) |*r| r.deinit(allocator);
        allocator.free(refs);
    }

    if (refs.len == 0) return &.{};

    const max_count: usize = if (include_all) refs.len else @min(@as(usize, 8), refs.len);
    const out = try allocator.alloc(RefEntry, max_count);
    for (out, 0..) |*item, i| {
        item.* = .{
            .name = try allocator.dupe(u8, refs[i].name),
            .commit = try allocator.dupe(u8, refs[i].commit),
        };
    }
    return out;
}

fn inspectManifestFromSource(allocator: std.mem.Allocator, manifest_src: ?[]const u8, gitmodules_src: ?[]const u8) !ManifestInfo {
    const src = manifest_src orelse {
        return ManifestInfo{
            .present = false,
            .name = null,
            .version = null,
            .minimum_zig_version = null,
            .dependencies = &.{},
            .paths = &.{},
            .submodules = &.{},
        };
    };
    const submodules = try parseGitmodulesPathsFromSource(allocator, gitmodules_src);

    const name = try parseValueTokenAfterField(allocator, src, ".name");
    const version = try parseQuotedStringAfterField(allocator, src, ".version");
    const minimum_zig_version = try parseQuotedStringAfterField(allocator, src, ".minimum_zig_version");
    const dependencies = try parseManifestDependencies(allocator, src, submodules);
    const manifest_paths = try parseStringListAfterField(allocator, src, ".paths");

    return ManifestInfo{
        .present = true,
        .name = name,
        .version = version,
        .minimum_zig_version = minimum_zig_version,
        .dependencies = dependencies,
        .paths = manifest_paths,
        .submodules = submodules,
    };
}

fn inspectBuildScriptFromSource(allocator: std.mem.Allocator, build_src: ?[]const u8) !BuildScriptInfo {
    const src = build_src orelse {
        return BuildScriptInfo{ .present = false, .units = &.{} };
    };

    var units = std.ArrayList(BuildUnit).empty;
    defer units.deinit(allocator);

    inline for (.{ "addExecutable", "addLibrary", "addTest" }) |kind_name| {
        var search_from: usize = 0;
        const needle = "b." ++ kind_name ++ "(.{";
        while (std.mem.indexOfPos(u8, src, search_from, needle)) |idx| {
            const obj_start = idx + ("b." ++ kind_name ++ "(.").len;
            const obj_span = extractBalancedBraces(src, obj_start) orelse {
                search_from = idx + needle.len;
                continue;
            };

            const var_name = parseAssignedConstName(allocator, src, idx) catch try allocator.dupe(u8, "(anonymous)");
            const obj_text = src[obj_span.start .. obj_span.end + 1];
            const name_expr = try parseValueTokenAfterField(allocator, obj_text, ".name");
            const root_module_expr = extractFieldValueToken(obj_text, ".root_module");

            var root_source_file: ?[]u8 = null;
            var target_expr: ?[]u8 = null;
            var optimize_expr: ?[]u8 = null;
            var imports = std.ArrayList(BuildImport).empty;
            defer imports.deinit(allocator);

            if (root_module_expr) |module_expr| {
                if (std.mem.indexOf(u8, module_expr, "createModule(.{")) |midx| {
                    const mod_obj_start = midx + "createModule(".len;
                    if (extractBalancedBraces(module_expr, mod_obj_start)) |mod_span| {
                        const mod_obj = module_expr[mod_span.start .. mod_span.end + 1];
                        root_source_file = try parsePathCallArgAfterField(allocator, mod_obj, ".root_source_file");
                        target_expr = try parseValueTokenAfterField(allocator, mod_obj, ".target");
                        optimize_expr = try parseValueTokenAfterField(allocator, mod_obj, ".optimize");
                        imports = try parseBuildImports(allocator, mod_obj);
                    }
                }
            }

            const installed = isArtifactInstalled(src, var_name);
            const has_run_step = hasRunArtifact(src, var_name);

            try units.append(allocator, .{
                .kind = kind_name,
                .variable = var_name,
                .name_expr = name_expr,
                .root_source_file = root_source_file,
                .target_expr = target_expr,
                .optimize_expr = optimize_expr,
                .imports = try imports.toOwnedSlice(allocator),
                .installed = installed,
                .has_run_step = has_run_step,
            });

            search_from = obj_span.end + 1;
        }
    }

    return BuildScriptInfo{
        .present = true,
        .units = try units.toOwnedSlice(allocator),
    };
}

fn parseBuildImports(allocator: std.mem.Allocator, module_obj: []const u8) !std.ArrayList(BuildImport) {
    var list = std.ArrayList(BuildImport).empty;

    const imports_val = extractFieldValueToken(module_obj, ".imports") orelse return list;
    const arr_start = std.mem.indexOf(u8, imports_val, "&.{") orelse return list;
    const brace_start = arr_start + 2;
    const arr_span = extractBalancedBraces(imports_val, brace_start) orelse return list;
    const arr_obj = imports_val[arr_span.start .. arr_span.end + 1];

    var from: usize = 0;
    while (std.mem.indexOfPos(u8, arr_obj, from, ".name")) |idx| {
        const after = arr_obj[idx..];
        const name_val = try parseQuotedStringAfterField(allocator, after, ".name");
        if (name_val) |nm| {
            try list.append(allocator, .{ .name = nm });
        }
        from = idx + 5;
    }

    return list;
}

fn parseManifestDependencies(allocator: std.mem.Allocator, src: []const u8, submodules: [][]u8) ![]ManifestDependency {
    const deps_val = extractFieldValueToken(src, ".dependencies") orelse return &.{};
    const dot_obj_start = std.mem.indexOf(u8, deps_val, ".{") orelse return &.{};
    const brace_start = dot_obj_start + 1;
    const deps_span = extractBalancedBraces(deps_val, brace_start) orelse return &.{};
    const deps_obj = deps_val[deps_span.start .. deps_span.end + 1];

    var list = std.ArrayList(ManifestDependency).empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < deps_obj.len) : (i += 1) {
        if (deps_obj[i] != '.') continue;
        const key_start = i + 1;
        var key_end = key_start;
        while (key_end < deps_obj.len and isIdentChar(deps_obj[key_end])) : (key_end += 1) {}
        if (key_end == key_start) continue;

        const after_key = std.mem.trimLeft(u8, deps_obj[key_end..], " \r\n\t");
        if (after_key.len == 0 or after_key[0] != '=') continue;

        const eq_idx = std.mem.indexOfScalarPos(u8, deps_obj, key_end, '=') orelse continue;
        const rhs = std.mem.trimLeft(u8, deps_obj[eq_idx + 1 ..], " \r\n\t");
        if (!std.mem.startsWith(u8, rhs, ".{")) continue;

        const rhs_start = eq_idx + 1 + (deps_obj[eq_idx + 1 ..].len - rhs.len) + 1;
        const rhs_span = extractBalancedBraces(deps_obj, rhs_start) orelse continue;
        const dep_obj = deps_obj[rhs_span.start .. rhs_span.end + 1];

        const dep_path = try parseQuotedStringAfterField(allocator, dep_obj, ".path");
        const dep_url = try parseQuotedStringAfterField(allocator, dep_obj, ".url");
        const dep_name = try allocator.dupe(u8, deps_obj[key_start..key_end]);

        var is_submodule_path = false;
        if (dep_path) |p| {
            for (submodules) |sm| {
                if (std.mem.eql(u8, p, sm)) {
                    is_submodule_path = true;
                    break;
                }
            }
        }

        try list.append(allocator, .{
            .name = dep_name,
            .path = dep_path,
            .url = dep_url,
            .is_submodule_path = is_submodule_path,
        });

        i = rhs_span.end;
    }

    return list.toOwnedSlice(allocator);
}

fn parseGitmodulesPathsFromSource(allocator: std.mem.Allocator, gitmodules_src: ?[]const u8) ![][]u8 {
    const src = gitmodules_src orelse return &.{};

    var list = std.ArrayList([]u8).empty;
    defer list.deinit(allocator);

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \r\t");
        if (!std.mem.startsWith(u8, line, "path")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \r\t");
        if (value.len == 0) continue;
        try list.append(allocator, try allocator.dupe(u8, value));
    }

    return list.toOwnedSlice(allocator);
}

fn parseStringListAfterField(allocator: std.mem.Allocator, src: []const u8, field_name: []const u8) ![][]u8 {
    const field_val = extractFieldValueToken(src, field_name) orelse return &.{};
    const dot_obj = std.mem.indexOf(u8, field_val, ".{") orelse return &.{};
    const brace_start = dot_obj + 1;
    const span = extractBalancedBraces(field_val, brace_start) orelse return &.{};
    const list_text = field_val[span.start .. span.end + 1];

    var list = std.ArrayList([]u8).empty;
    defer list.deinit(allocator);

    var i: usize = 0;
    while (i < list_text.len) : (i += 1) {
        if (list_text[i] != '"') continue;
        const end = findStringEnd(list_text, i + 1) orelse break;
        try list.append(allocator, try allocator.dupe(u8, list_text[i + 1 .. end]));
        i = end;
    }

    return list.toOwnedSlice(allocator);
}

fn parsePathCallArgAfterField(allocator: std.mem.Allocator, src: []const u8, field_name: []const u8) !?[]u8 {
    const value = extractFieldValueToken(src, field_name) orelse return null;
    const p = std.mem.indexOf(u8, value, "b.path(") orelse return null;
    const after = value[p + "b.path(".len ..];
    const q = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    const end = findStringEnd(after, q + 1) orelse return null;
    return try allocator.dupe(u8, after[q + 1 .. end]);
}

fn parseQuotedStringAfterField(allocator: std.mem.Allocator, src: []const u8, field_name: []const u8) !?[]u8 {
    const value = extractFieldValueToken(src, field_name) orelse return null;
    if (value.len == 0 or value[0] != '"') return null;
    const end = findStringEnd(value, 1) orelse return null;
    return try allocator.dupe(u8, value[1..end]);
}

fn parseValueTokenAfterField(allocator: std.mem.Allocator, src: []const u8, field_name: []const u8) !?[]u8 {
    const value = extractFieldValueToken(src, field_name) orelse return null;
    var token = std.mem.trim(u8, value, " \r\n\t");
    if (token.len == 0) return null;
    if (token[token.len - 1] == ',') token = std.mem.trimRight(u8, token, ",");
    return try allocator.dupe(u8, token);
}

fn extractFieldValueToken(src: []const u8, field_name: []const u8) ?[]const u8 {
    const idx = std.mem.indexOf(u8, src, field_name) orelse return null;
    const eq = std.mem.indexOfScalarPos(u8, src, idx, '=') orelse return null;
    var i = eq + 1;
    while (i < src.len and isSpace(src[i])) : (i += 1) {}
    if (i >= src.len) return null;

    if (src[i] == '"') {
        const end = findStringEnd(src, i + 1) orelse return null;
        return src[i .. end + 1];
    }
    if (src[i] == '{') {
        const span = extractBalancedBraces(src, i) orelse return null;
        return src[span.start .. span.end + 1];
    }
    if (src[i] == '.' and i + 1 < src.len and src[i + 1] == '{') {
        const span = extractBalancedBraces(src, i + 1) orelse return null;
        return src[i .. span.end + 1];
    }

    var end = i;
    var paren_depth: usize = 0;
    while (end < src.len) : (end += 1) {
        const c = src[end];
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            ',' => if (paren_depth == 0) break,
            '\n' => if (paren_depth == 0) break,
            else => {},
        }
    }
    return std.mem.trimRight(u8, src[i..end], " \r\n\t,");
}

const Span = struct { start: usize, end: usize };

fn extractBalancedBraces(src: []const u8, brace_start: usize) ?Span {
    if (brace_start >= src.len or src[brace_start] != '{') return null;

    var i = brace_start;
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (in_string) {
            if (escaped) {
                escaped = false;
                continue;
            }
            if (c == '\\') {
                escaped = true;
                continue;
            }
            if (c == '"') in_string = false;
            continue;
        }

        if (c == '"') {
            in_string = true;
            continue;
        }
        if (c == '{') {
            depth += 1;
            continue;
        }
        if (c == '}') {
            if (depth == 0) return null;
            depth -= 1;
            if (depth == 0) return .{ .start = brace_start, .end = i };
        }
    }

    return null;
}

fn findStringEnd(src: []const u8, from: usize) ?usize {
    var i = from;
    var escaped = false;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (escaped) {
            escaped = false;
            continue;
        }
        if (c == '\\') {
            escaped = true;
            continue;
        }
        if (c == '"') return i;
    }
    return null;
}

fn parseAssignedConstName(allocator: std.mem.Allocator, src: []const u8, pos: usize) ![]u8 {
    const line_start = std.mem.lastIndexOfScalar(u8, src[0..pos], '\n') orelse 0;
    const line = src[line_start..pos];
    const const_pos = std.mem.indexOf(u8, line, "const ") orelse return allocator.dupe(u8, "(anonymous)");
    const name_start = const_pos + "const ".len;
    var name_end = name_start;
    while (name_end < line.len and isIdentChar(line[name_end])) : (name_end += 1) {}
    if (name_end == name_start) return allocator.dupe(u8, "(anonymous)");
    return allocator.dupe(u8, line[name_start..name_end]);
}

fn isArtifactInstalled(src: []const u8, artifact_var: []const u8) bool {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "b.installArtifact({s})", .{artifact_var}) catch return false;
    return std.mem.indexOf(u8, src, needle) != null;
}

fn hasRunArtifact(src: []const u8, artifact_var: []const u8) bool {
    var buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, "b.addRunArtifact({s})", .{artifact_var}) catch return false;
    return std.mem.indexOf(u8, src, needle) != null;
}

fn readGitFileAtCommit(allocator: std.mem.Allocator, bare_path: []const u8, commit: []const u8, rel_path: []const u8) !?[]u8 {
    const object = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ commit, rel_path });
    defer allocator.free(object);

    var result = git.runCapture(allocator, null, &.{ "-C", bare_path, "show", object }) catch return null;
    defer result.deinit(allocator);

    if (result.exit_code != 0) return null;
    return try allocator.dupe(u8, std.mem.trimRight(u8, result.stdout, "\r\n"));
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t';
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_' or c == '-';
}

fn printHeaderStyled(allocator: std.mem.Allocator, w: anytype, text: []const u8) !void {
    const header_style = carnaval.Style.init().fg(.{ .ansi16 = .cyan }).bolded();
    const rendered = try header_style.renderAllocWithProfile(text, allocator, .ansi16);
    defer allocator.free(rendered);
    try w.interface.print("\n{s}\n", .{rendered});
}

fn printInfo(allocator: std.mem.Allocator, info: InfoDisplay) !void {
    var buf: [16384]u8 = undefined;
    var w = std.fs.File.stdout().writer(&buf);

    try printHeaderStyled(allocator, &w, "Repository");
    try w.interface.print("Name:            {s}\n", .{info.name});
    try w.interface.print("URL:             {s}\n", .{info.url});
    try w.interface.print("Host:            {s}\n", .{info.host});
    try w.interface.print("Owner:           {s}\n", .{info.owner});
    try w.interface.print("Repo:            {s}\n", .{info.repo});
    try w.interface.print("Default branch:  {s}\n", .{info.default_branch});
    try w.interface.print("Latest commit:   {s}\n", .{info.head_commit});
    if (info.latest_tag) |tag| {
        try w.interface.print("Latest tag:      {s}\n", .{tag});
    } else {
        try w.interface.print("Latest tag:      (none)\n", .{});
    }
    try w.interface.print("Installed:       {s}\n", .{if (info.installed) "yes" else "no"});
    if (info.alias) |a| try w.interface.print("Alias:           {s}\n", .{a});
    if (info.pinned) |p| try w.interface.print("Pinned:          {s}\n", .{if (p) "yes" else "no"});
    if (info.binary_path) |p| try w.interface.print("Binary path:     {s}\n", .{p});
    if (info.installed_at) |t| try w.interface.print("Installed at:    {s}\n", .{t});
    if (info.updated_at) |t| try w.interface.print("Updated at:      {s}\n", .{t});

    try printHeaderStyled(allocator, &w, "Manifest (build.zig.zon)");
    if (!info.manifest.present) {
        try w.interface.print("Present:         no\n", .{});
    } else {
        try w.interface.print("Present:         yes\n", .{});
        try w.interface.print("Name:            {s}\n", .{info.manifest.name orelse "(unknown)"});
        try w.interface.print("Version:         {s}\n", .{info.manifest.version orelse "(unknown)"});
        try w.interface.print("Min Zig:         {s}\n", .{info.manifest.minimum_zig_version orelse "(unknown)"});
        try w.interface.print("Dependencies:    {d}\n", .{info.manifest.dependencies.len});
        for (info.manifest.dependencies) |dep| {
            const path = dep.path orelse "(none)";
            const dep_url = dep.url orelse "(none)";
            try w.interface.print("  - {s}  path={s}  url={s}", .{ dep.name, path, dep_url });
            if (dep.is_submodule_path) {
                try w.interface.print("  [submodule]\n", .{});
            } else {
                try w.interface.print("\n", .{});
            }
        }

        if (info.manifest.paths.len > 0) {
            try w.interface.print("Paths:\n", .{});
            for (info.manifest.paths) |p| {
                try w.interface.print("  - {s}\n", .{p});
            }
        }

        if (info.manifest.submodules.len > 0) {
            try w.interface.print("Submodules (.gitmodules):\n", .{});
            for (info.manifest.submodules) |p| {
                try w.interface.print("  - {s}\n", .{p});
            }

            var has_dep_submodule = false;
            for (info.manifest.dependencies) |dep| {
                if (dep.is_submodule_path) {
                    has_dep_submodule = true;
                    break;
                }
            }
            if (has_dep_submodule) {
                try w.interface.print("Recommendation:  clone with submodules (e.g. --recurse-submodules).\n", .{});
            }
        }
    }

    try printHeaderStyled(allocator, &w, "Build Script (build.zig)");
    if (!info.build_script.present) {
        try w.interface.print("Present:         no\n", .{});
    } else {
        try w.interface.print("Present:         yes\n", .{});
        if (info.build_script.units.len == 0) {
            try w.interface.print("Compiled units:  none found\n", .{});
        } else {
            try w.interface.print("Compiled units:  {d}\n", .{info.build_script.units.len});
            for (info.build_script.units) |u| {
                try w.interface.print("  - kind={s} var={s}\n", .{ u.kind, u.variable });
                if (u.name_expr) |n| try w.interface.print("      name:            {s}\n", .{n});
                if (u.root_source_file) |r| try w.interface.print("      root_source:     {s}\n", .{r});
                if (u.target_expr) |t| try w.interface.print("      target:          {s}\n", .{t});
                if (u.optimize_expr) |o| try w.interface.print("      optimize:        {s}\n", .{o});
                if (u.imports.len > 0) {
                    try w.interface.print("      imports:         ", .{});
                    for (u.imports, 0..) |imp, idx| {
                        const sep: []const u8 = if (idx + 1 < u.imports.len) ", " else "\n";
                        try w.interface.print("{s}{s}", .{ imp.name, sep });
                    }
                }
                try w.interface.print("      install step:    {s}\n", .{if (u.installed) "yes (zig-out/bin for executables)" else "no"});
                try w.interface.print("      run step:        {s}\n", .{if (u.has_run_step) "yes" else "no"});
            }
        }
    }

    try printHeaderStyled(allocator, &w, "Refs");
    if (info.branches.len > 0) {
        try w.interface.print("Branches ({d}):\n", .{info.branches.len});
        for (info.branches) |br| {
            try w.interface.print("  - {s} ({s})\n", .{ br.name, br.commit[0..@min(12, br.commit.len)] });
        }
    } else {
        try w.interface.print("Branches:        (none found)\n", .{});
    }
    if (info.tags.len > 0) {
        try w.interface.print("Tags ({d}):\n", .{info.tags.len});
        for (info.tags) |tag| {
            try w.interface.print("  - {s} ({s})\n", .{ tag.name, tag.commit[0..@min(12, tag.commit.len)] });
        }
    } else {
        try w.interface.print("Tags:            (none found)\n", .{});
    }

    try w.interface.flush();
}

fn printErr(msg: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = std.fs.File.stderr().writer(&buf);
    try w.interface.print("error: {s}\n", .{msg});
    try w.interface.flush();
}
