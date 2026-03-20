/// Community pack registry for zipet.
/// Fetches pack index and packs from a GitHub-hosted community repository.
/// Repo: github.com/Luisgarcav/zipet-community-packs
///
/// Structure:
///   index.json          — pack metadata index
///   packs/<name>.toml   — individual pack files
///
/// Users publish packs via PR to the community repo.
const std = @import("std");
const config = @import("config.zig");

const community_repo = "Luisgarcav/zipet-community-packs";
const index_url = "https://raw.githubusercontent.com/" ++ community_repo ++ "/main/index.json";
const packs_base_url = "https://raw.githubusercontent.com/" ++ community_repo ++ "/main/packs/";
const repo_url = "https://github.com/" ++ community_repo;

pub const CommunityPack = struct {
    name: []const u8,
    description: []const u8,
    author: []const u8,
    version: []const u8,
    category: []const u8,
    tags: []const []const u8,
    snippet_count: usize,
    workflow_count: usize,
    downloads: usize,
};

pub const CommunityIndex = struct {
    packs: []CommunityPack,
    fetched: bool,
    err_msg: ?[]const u8,
};

/// Fetch the community pack index from GitHub.
pub fn fetchIndex(allocator: std.mem.Allocator) !CommunityIndex {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sfL", "--connect-timeout", "5", "--max-time", "10", index_url },
    }) catch {
        return .{ .packs = &.{}, .fetched = false, .err_msg = try allocator.dupe(u8, "Failed to run curl (is it installed?)") };
    };
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return .{ .packs = &.{}, .fetched = false, .err_msg = try allocator.dupe(u8, "Could not reach community registry (check your connection)") };
    }

    defer allocator.free(result.stdout);
    return parseIndex(allocator, result.stdout);
}

/// Parse the JSON index content into CommunityIndex.
fn parseIndex(allocator: std.mem.Allocator, content: []const u8) !CommunityIndex {
    // Simple JSON parser for the index format
    // Expected format:
    // {
    //   "packs": [
    //     {
    //       "name": "...",
    //       "description": "...",
    //       "author": "...",
    //       "version": "...",
    //       "category": "...",
    //       "tags": ["..."],
    //       "snippet_count": N,
    //       "workflow_count": N,
    //       "downloads": N
    //     }
    //   ]
    // }

    const parsed = std.json.parseFromSlice(JsonIndex, allocator, content, .{ .allocate = .alloc_always }) catch {
        return .{ .packs = &.{}, .fetched = false, .err_msg = try allocator.dupe(u8, "Failed to parse community index (malformed JSON)") };
    };
    defer parsed.deinit();

    var packs_list: std.ArrayList(CommunityPack) = .{};

    for (parsed.value.packs) |jp| {
        var tags: std.ArrayList([]const u8) = .{};
        for (jp.tags) |t| {
            try tags.append(allocator, try allocator.dupe(u8, t));
        }

        try packs_list.append(allocator, .{
            .name = try allocator.dupe(u8, jp.name),
            .description = try allocator.dupe(u8, jp.description),
            .author = try allocator.dupe(u8, jp.author),
            .version = try allocator.dupe(u8, jp.version),
            .category = try allocator.dupe(u8, jp.category),
            .tags = try tags.toOwnedSlice(allocator),
            .snippet_count = jp.snippet_count,
            .workflow_count = jp.workflow_count,
            .downloads = jp.downloads,
        });
    }

    return .{
        .packs = try packs_list.toOwnedSlice(allocator),
        .fetched = true,
        .err_msg = null,
    };
}

const JsonIndex = struct {
    packs: []const JsonPack,
};

const JsonPack = struct {
    name: []const u8,
    description: []const u8 = "",
    author: []const u8 = "unknown",
    version: []const u8 = "1.0.0",
    category: []const u8 = "general",
    tags: []const []const u8 = &.{},
    snippet_count: usize = 0,
    workflow_count: usize = 0,
    downloads: usize = 0,
};

/// Search the community index by query (fuzzy match on name, description, tags, category).
pub fn search(allocator: std.mem.Allocator, index: CommunityIndex, query: []const u8) ![]const CommunityPack {
    if (!index.fetched or index.packs.len == 0) return try allocator.alloc(CommunityPack, 0);

    const query_lower = try toLower(allocator, query);
    defer allocator.free(query_lower);

    var results: std.ArrayList(CommunityPack) = .{};

    for (index.packs) |p| {
        var score: i32 = 0;

        // Check name
        const name_lower = try toLower(allocator, p.name);
        defer allocator.free(name_lower);
        if (std.mem.indexOf(u8, name_lower, query_lower) != null) {
            score += 10;
            if (std.mem.eql(u8, name_lower, query_lower)) score += 20; // exact match bonus
        }

        // Check description
        const desc_lower = try toLower(allocator, p.description);
        defer allocator.free(desc_lower);
        if (std.mem.indexOf(u8, desc_lower, query_lower) != null) score += 5;

        // Check category
        const cat_lower = try toLower(allocator, p.category);
        defer allocator.free(cat_lower);
        if (std.mem.indexOf(u8, cat_lower, query_lower) != null) score += 7;

        // Check author
        const author_lower = try toLower(allocator, p.author);
        defer allocator.free(author_lower);
        if (std.mem.indexOf(u8, author_lower, query_lower) != null) score += 3;

        // Check tags
        for (p.tags) |tag| {
            const tag_lower = try toLower(allocator, tag);
            defer allocator.free(tag_lower);
            if (std.mem.indexOf(u8, tag_lower, query_lower) != null) {
                score += 8;
                break;
            }
        }

        if (score > 0) {
            try results.append(allocator, p);
        }
    }

    return try results.toOwnedSlice(allocator);
}

fn toLower(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf;
}

/// Get the download URL for a community pack.
pub fn getPackUrl(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}.toml", .{ packs_base_url, name });
}

/// Get the community repo URL (for publishing).
pub fn getRepoUrl() []const u8 {
    return repo_url;
}

/// Get the URL to create a new issue (for submitting a pack).
pub fn getSubmitUrl(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/issues/new?template=submit-pack.md&title=[Pack]+", .{repo_url});
}

/// Get the URL to create a new PR (for submitting a pack).
pub fn getPullRequestUrl(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/compare", .{repo_url});
}

/// Validate a pack TOML file has the required metadata for publishing.
pub const ValidationResult = struct {
    valid: bool,
    errors: []const []const u8,
};

pub fn validateForPublish(allocator: std.mem.Allocator, pack_path: []const u8) !ValidationResult {

    const file = std.fs.cwd().openFile(pack_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            const abs_file = std.fs.openFileAbsolute(pack_path, .{}) catch {
                var errors: std.ArrayList([]const u8) = .{};
                try errors.append(allocator, try allocator.dupe(u8, "File not found"));
                return .{ .valid = false, .errors = try errors.toOwnedSlice(allocator) };
            };
            defer abs_file.close();
            const content = try abs_file.readToEndAlloc(allocator, 1024 * 512);
            defer allocator.free(content);
            return validateContent(allocator, content);
        }
        var errors: std.ArrayList([]const u8) = .{};
        try errors.append(allocator, try allocator.dupe(u8, "Cannot open file"));
        return .{ .valid = false, .errors = try errors.toOwnedSlice(allocator) };
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 512);
    defer allocator.free(content);
    return validateContent(allocator, content);
}

fn validateContent(allocator: std.mem.Allocator, content: []const u8) !ValidationResult {
    const toml_mod = @import("toml.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const table = toml_mod.parse(arena.allocator(), content) catch {
        var errors: std.ArrayList([]const u8) = .{};
        try errors.append(allocator, try allocator.dupe(u8, "Invalid TOML syntax"));
        return .{ .valid = false, .errors = try errors.toOwnedSlice(allocator) };
    };

    var errors: std.ArrayList([]const u8) = .{};

    if (table.getString("pack.name") == null) {
        try errors.append(allocator, try allocator.dupe(u8, "Missing [pack] name"));
    }
    if (table.getString("pack.description") == null) {
        try errors.append(allocator, try allocator.dupe(u8, "Missing [pack] description"));
    }
    if (table.getString("pack.author") == null) {
        try errors.append(allocator, try allocator.dupe(u8, "Missing [pack] author"));
    }
    if (table.getString("pack.version") == null) {
        try errors.append(allocator, try allocator.dupe(u8, "Missing [pack] version (e.g. \"1.0.0\")"));
    }
    if (table.getString("pack.category") == null) {
        try errors.append(allocator, try allocator.dupe(u8, "Missing [pack] category"));
    }

    // Check that there's at least one snippet
    var has_snippet = false;
    for (table.keys) |key| {
        if (std.mem.startsWith(u8, key, "snippets.")) {
            has_snippet = true;
            break;
        }
    }
    if (!has_snippet) {
        try errors.append(allocator, try allocator.dupe(u8, "Pack has no snippets"));
    }

    return .{
        .valid = errors.items.len == 0,
        .errors = try errors.toOwnedSlice(allocator),
    };
}

/// Free a CommunityIndex.
pub fn freeIndex(allocator: std.mem.Allocator, index: CommunityIndex) void {
    for (index.packs) |p| {
        allocator.free(p.name);
        allocator.free(p.description);
        allocator.free(p.author);
        allocator.free(p.version);
        allocator.free(p.category);
        for (p.tags) |t| allocator.free(t);
        allocator.free(p.tags);
    }
    allocator.free(index.packs);
    if (index.err_msg) |e| allocator.free(e);
}

/// Free search results (shallow — the CommunityPack data is owned by the index).
pub fn freeSearchResults(allocator: std.mem.Allocator, results: []const CommunityPack) void {
    allocator.free(results);
}

/// Cache the community index locally for faster subsequent access.
pub fn getCacheDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.cache/zipet", .{home});
}

pub fn cacheIndex(allocator: std.mem.Allocator, content: []const u8) !void {
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    std.fs.makeDirAbsolute(cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/community-index.json", .{cache_dir});
    defer allocator.free(cache_path);

    const file = try std.fs.createFileAbsolute(cache_path, .{});
    defer file.close();
    try file.writeAll(content);
}

pub fn loadCachedIndex(allocator: std.mem.Allocator) !?CommunityIndex {
    const cache_dir = try getCacheDir(allocator);
    defer allocator.free(cache_dir);

    const cache_path = try std.fmt.allocPrint(allocator, "{s}/community-index.json", .{cache_dir});
    defer allocator.free(cache_path);

    const file = std.fs.openFileAbsolute(cache_path, .{}) catch return null;
    defer file.close();

    // Check if cache is older than 1 hour
    const stat = file.stat() catch return null;
    const now = std.time.timestamp();
    const mtime = @divFloor(stat.mtime, std.time.ns_per_s);
    if (now - mtime > 3600) return null; // Cache expired

    const content = file.readToEndAlloc(allocator, 1024 * 256) catch return null;
    defer allocator.free(content);

    const idx = parseIndex(allocator, content) catch return null;
    return idx;
}

/// Fetch index with cache support.
pub fn fetchIndexCached(allocator: std.mem.Allocator) !CommunityIndex {
    // Try cache first
    if (try loadCachedIndex(allocator)) |cached| {
        return cached;
    }

    // Fetch fresh
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sfL", "--connect-timeout", "5", "--max-time", "10", index_url },
    }) catch {
        return .{ .packs = &.{}, .fetched = false, .err_msg = try allocator.dupe(u8, "Failed to run curl (is it installed?)") };
    };
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return .{ .packs = &.{}, .fetched = false, .err_msg = try allocator.dupe(u8, "Could not reach community registry") };
    }

    // Cache the raw content
    cacheIndex(allocator, result.stdout) catch {};

    defer allocator.free(result.stdout);
    return parseIndex(allocator, result.stdout);
}
