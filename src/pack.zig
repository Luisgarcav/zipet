/// Pack system for zipet — shareable collections of snippets & workflows.
/// Packs are TOML files that can be installed from local files, URLs, or the built-in registry.
/// Structure: ~/.config/zipet/packs/<pack-name>.toml (metadata)
///            Content gets imported into the store or a workspace.
const std = @import("std");
const config = @import("config.zig");
const store = @import("store.zig");
const toml = @import("toml.zig");
const template = @import("template.zig");
const workspace = @import("workspace.zig");

pub const PackMeta = struct {
    name: []const u8,
    description: []const u8,
    author: []const u8,
    version: []const u8,
    category: []const u8,
    tags: []const []const u8,
    snippet_count: usize,
    workflow_count: usize,
    installed: bool,
    is_community: bool = false,
};

/// Get packs directory
pub fn getPacksDir(allocator: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    const base = try cfg.getConfigDir(allocator);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/packs", .{base});
}

/// Get the built-in packs directory (shipped with zipet)
pub fn getBuiltinPacksDir(allocator: std.mem.Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/zipet/packs/registry", .{home});
}

/// Install a pack from a TOML file path into the store (or a workspace)
pub fn install(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    source: []const u8,
    target_workspace: ?[]const u8,
    snip_store: *store.Store,
) !InstallResult {
    var content: []const u8 = undefined;
    var content_owned = false;

    // Check if it's a built-in pack name (no path separator, no extension)
    if (std.mem.indexOfScalar(u8, source, '/') == null and !std.mem.endsWith(u8, source, ".toml")) {
        // Try built-in registry first
        const builtin_path = try getBuiltinPackPath(allocator, source);
        defer allocator.free(builtin_path);

        if (std.fs.openFileAbsolute(builtin_path, .{})) |file| {
            defer file.close();
            content = try file.readToEndAlloc(allocator, 1024 * 512);
            content_owned = true;
        } else |_| {
            // Try packs directory
            const packs_dir = try getPacksDir(allocator, cfg);
            defer allocator.free(packs_dir);
            const pack_path = try std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ packs_dir, source });
            defer allocator.free(pack_path);

            if (std.fs.openFileAbsolute(pack_path, .{})) |file| {
                defer file.close();
                content = try file.readToEndAlloc(allocator, 1024 * 512);
                content_owned = true;
            } else |_| {
                return InstallResult{ .snippets_added = 0, .workflows_added = 0, .pack_name = try allocator.dupe(u8, source), .err_msg = try allocator.dupe(u8, "Pack not found") };
            }
        }
    } else if (std.mem.startsWith(u8, source, "http://") or std.mem.startsWith(u8, source, "https://")) {
        // Download from URL
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "curl", "-sfL", source },
        }) catch {
            return InstallResult{ .snippets_added = 0, .workflows_added = 0, .pack_name = try allocator.dupe(u8, "unknown"), .err_msg = try allocator.dupe(u8, "Failed to download (is curl installed?)") };
        };
        defer allocator.free(result.stderr);
        if (result.term.Exited != 0) {
            allocator.free(result.stdout);
            return InstallResult{ .snippets_added = 0, .workflows_added = 0, .pack_name = try allocator.dupe(u8, "unknown"), .err_msg = try allocator.dupe(u8, "Download failed") };
        }
        content = result.stdout;
        content_owned = true;
    } else {
        // Local file path
        const file = std.fs.cwd().openFile(source, .{}) catch {
            const abs_file = std.fs.openFileAbsolute(source, .{}) catch {
                return InstallResult{ .snippets_added = 0, .workflows_added = 0, .pack_name = try allocator.dupe(u8, source), .err_msg = try allocator.dupe(u8, "File not found") };
            };
            defer abs_file.close();
            content = try abs_file.readToEndAlloc(allocator, 1024 * 512);
            content_owned = true;
            return try installFromContent(allocator, cfg, content, target_workspace, snip_store, source);
        };
        defer file.close();
        content = try file.readToEndAlloc(allocator, 1024 * 512);
        content_owned = true;
    }

    defer if (content_owned) allocator.free(content);
    return try installFromContent(allocator, cfg, content, target_workspace, snip_store, source);
}

fn getBuiltinPackPath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(allocator, "{s}/.config/zipet/packs/registry/{s}.toml", .{ home, name });
}

fn installFromContent(
    allocator: std.mem.Allocator,
    cfg: config.Config,
    content: []const u8,
    target_workspace: ?[]const u8,
    snip_store: *store.Store,
    source_name: []const u8,
) !InstallResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const table = toml.parse(arena_alloc, content) catch {
        return InstallResult{ .snippets_added = 0, .workflows_added = 0, .pack_name = try allocator.dupe(u8, source_name), .err_msg = try allocator.dupe(u8, "Failed to parse TOML") };
    };

    // Read pack metadata
    const pack_name = table.getString("pack.name") orelse blk: {
        const basename = std.fs.path.basename(source_name);
        break :blk if (std.mem.endsWith(u8, basename, ".toml")) basename[0 .. basename.len - 5] else basename;
    };

    var snippets_added: usize = 0;
    var workflows_added: usize = 0;

    // Determine target namespace
    const ns = if (target_workspace) |ws| ws else pack_name;

    // If targeting a workspace, ensure it exists
    if (target_workspace) |ws_name| {
        workspace.create(allocator, cfg, ws_name, "Imported from pack", null) catch |err| {
            if (err != error.AlreadyExists) return err;
        };
    }

    // Import snippets
    var snippet_names = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = snippet_names.keyIterator();
        while (key_iter.next()) |k| allocator.free(k.*);
        snippet_names.deinit();
    }

    for (table.keys) |key| {
        if (std.mem.startsWith(u8, key, "snippets.")) {
            const rest = key["snippets.".len..];
            if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                const name = rest[0..dot];
                if (!snippet_names.contains(name)) {
                    try snippet_names.put(try allocator.dupe(u8, name), {});
                }
            }
        }
    }

    var name_iter = snippet_names.keyIterator();
    while (name_iter.next()) |name_ptr| {
        const sname = name_ptr.*;

        const cmd_key = try std.fmt.allocPrint(allocator, "snippets.{s}.cmd", .{sname});
        defer allocator.free(cmd_key);
        const desc_key = try std.fmt.allocPrint(allocator, "snippets.{s}.desc", .{sname});
        defer allocator.free(desc_key);
        const tags_key = try std.fmt.allocPrint(allocator, "snippets.{s}.tags", .{sname});
        defer allocator.free(tags_key);

        const cmd_val = table.getString(cmd_key) orelse continue;
        const desc_val = table.getString(desc_key) orelse "";

        var tags: std.ArrayList([]const u8) = .{};
        if (table.getArray(tags_key)) |arr| {
            for (arr) |item| {
                switch (item) {
                    .string => |s| try tags.append(allocator, try allocator.dupe(u8, s)),
                    else => {},
                }
            }
        }

        // Check duplicate
        var duplicate = false;
        for (snip_store.snippets.items) |existing| {
            if (std.mem.eql(u8, existing.name, sname)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            for (tags.items) |t| allocator.free(t);
            tags.deinit(allocator);
            continue;
        }

        const detected = try template.detectParams(allocator, cmd_val);
        defer allocator.free(detected);
        const params = try allocator.alloc(template.Param, detected.len);
        for (detected, 0..) |pname, i| {
            params[i] = .{ .name = pname, .prompt = null, .default = null, .options = null, .command = null };

            const param_prefix = try std.fmt.allocPrint(allocator, "snippets.{s}.params.{s}", .{ sname, pname });
            defer allocator.free(param_prefix);

            for (table.keys, table.values) |tk, tv| {
                if (std.mem.eql(u8, tk, param_prefix)) {
                    switch (tv) {
                        .table => |pt| {
                            if (pt.getString("prompt")) |pr| params[i].prompt = try allocator.dupe(u8, pr);
                            if (pt.getString("default")) |d| params[i].default = try allocator.dupe(u8, d);
                            if (pt.getString("command")) |c| params[i].command = try allocator.dupe(u8, c);
                        },
                        else => {},
                    }
                }
            }
        }

        const snippet = store.Snippet{
            .name = try allocator.dupe(u8, sname),
            .desc = try allocator.dupe(u8, desc_val),
            .cmd = try allocator.dupe(u8, cmd_val),
            .tags = try tags.toOwnedSlice(allocator),
            .params = params,
            .namespace = try allocator.dupe(u8, ns),
            .kind = .snippet,
        };

        try snip_store.add(snippet);
        snippets_added += 1;
    }

    // Count workflows (basic detection)
    for (table.keys) |key| {
        if (std.mem.startsWith(u8, key, "workflows.")) {
            const rest = key["workflows.".len..];
            if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                const name = rest[0..dot];
                if (std.mem.eql(u8, rest[dot..], ".desc")) {
                    _ = name;
                    workflows_added += 1;
                }
            }
        }
    }

    // Save installed pack metadata
    try savePackMeta(allocator, cfg, pack_name, content);

    return InstallResult{
        .snippets_added = snippets_added,
        .workflows_added = workflows_added,
        .pack_name = try allocator.dupe(u8, pack_name),
        .err_msg = null,
    };
}

fn savePackMeta(allocator: std.mem.Allocator, cfg: config.Config, name: []const u8, _: []const u8) !void {
    const packs_dir = try getPacksDir(allocator, cfg);
    defer allocator.free(packs_dir);

    std.fs.makeDirAbsolute(packs_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const meta_path = try std.fmt.allocPrint(allocator, "{s}/{s}.installed", .{ packs_dir, name });
    defer allocator.free(meta_path);

    const file = try std.fs.createFileAbsolute(meta_path, .{});
    defer file.close();

    const ts = std.time.timestamp();
    var buf: [64]u8 = undefined;
    const ts_str = std.fmt.bufPrint(&buf, "{d}", .{ts}) catch "0";
    try file.writeAll(ts_str);
}

/// List available packs (both registry and installed)
pub fn listAvailable(allocator: std.mem.Allocator, cfg: config.Config) ![]PackMeta {
    var result: std.ArrayList(PackMeta) = .{};

    // Scan registry
    const registry_dir = try getBuiltinPacksDir(allocator);
    defer allocator.free(registry_dir);

    // Ensure registry exists
    std.fs.makeDirAbsolute(registry_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            // Try creating parent dirs
            const packs_dir = try getPacksDir(allocator, cfg);
            defer allocator.free(packs_dir);
            std.fs.makeDirAbsolute(packs_dir) catch |e2| switch (e2) {
                error.PathAlreadyExists => {},
                else => return e2,
            };
            std.fs.makeDirAbsolute(registry_dir) catch |e3| switch (e3) {
                error.PathAlreadyExists => {},
                else => return e3,
            };
        },
    };

    if (std.fs.openDirAbsolute(registry_dir, .{ .iterate = true })) |*dir_ptr| {
        var dir = dir_ptr.*;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".toml")) continue;

            const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ registry_dir, entry.name });
            defer allocator.free(path);

            if (parsePackMeta(allocator, cfg, path)) |meta| {
                try result.append(allocator, meta);
            } else |_| {}
        }
    } else |_| {}

    return try result.toOwnedSlice(allocator);
}

fn parsePackMeta(allocator: std.mem.Allocator, cfg: config.Config, path: []const u8) !PackMeta {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 256);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const table = try toml.parse(arena.allocator(), content);

    const name = table.getString("pack.name") orelse "unknown";
    const desc = table.getString("pack.description") orelse "";
    const author = table.getString("pack.author") orelse "unknown";
    const version = table.getString("pack.version") orelse "1.0.0";
    const category = table.getString("pack.category") orelse "general";

    var tags: std.ArrayList([]const u8) = .{};
    if (table.getArray("pack.tags")) |arr| {
        for (arr) |item| {
            switch (item) {
                .string => |s| try tags.append(allocator, try allocator.dupe(u8, s)),
                else => {},
            }
        }
    }

    // Count snippets and workflows
    var snip_count: usize = 0;
    var wf_count: usize = 0;
    var counted_snippets = std.StringHashMap(void).init(allocator);
    defer counted_snippets.deinit();
    var counted_wfs = std.StringHashMap(void).init(allocator);
    defer counted_wfs.deinit();

    for (table.keys) |key| {
        if (std.mem.startsWith(u8, key, "snippets.")) {
            const rest = key["snippets.".len..];
            if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                const sn = rest[0..dot];
                if (!counted_snippets.contains(sn)) {
                    try counted_snippets.put(sn, {});
                    snip_count += 1;
                }
            }
        }
        if (std.mem.startsWith(u8, key, "workflows.")) {
            const rest = key["workflows.".len..];
            if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                const wn = rest[0..dot];
                if (!counted_wfs.contains(wn)) {
                    try counted_wfs.put(wn, {});
                    wf_count += 1;
                }
            }
        }
    }

    // Check if installed
    const packs_dir = try getPacksDir(allocator, cfg);
    defer allocator.free(packs_dir);
    const installed_path = try std.fmt.allocPrint(allocator, "{s}/{s}.installed", .{ packs_dir, name });
    defer allocator.free(installed_path);
    const is_installed = blk: {
        std.fs.accessAbsolute(installed_path, .{}) catch break :blk false;
        break :blk true;
    };

    return .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, desc),
        .author = try allocator.dupe(u8, author),
        .version = try allocator.dupe(u8, version),
        .category = try allocator.dupe(u8, category),
        .tags = try tags.toOwnedSlice(allocator),
        .snippet_count = snip_count,
        .workflow_count = wf_count,
        .installed = is_installed,
    };
}

/// Remove an installed pack
pub fn uninstall(allocator: std.mem.Allocator, cfg: config.Config, name: []const u8, snip_store: *store.Store) !usize {
    // Remove all snippets/workflows with this namespace
    var removed: usize = 0;
    var i: usize = 0;
    while (i < snip_store.snippets.items.len) {
        if (std.mem.eql(u8, snip_store.snippets.items[i].namespace, name)) {
            snip_store.freeSnippet(snip_store.snippets.items[i]);
            _ = snip_store.snippets.orderedRemove(i);
            removed += 1;
        } else {
            i += 1;
        }
    }

    // Remove .installed marker
    const packs_dir = try getPacksDir(allocator, cfg);
    defer allocator.free(packs_dir);
    const installed_path = try std.fmt.allocPrint(allocator, "{s}/{s}.installed", .{ packs_dir, name });
    defer allocator.free(installed_path);
    std.fs.deleteFileAbsolute(installed_path) catch {};

    // Remove the namespace TOML file
    const snippets_dir = try cfg.getSnippetsDir(allocator);
    defer allocator.free(snippets_dir);
    const ns_path = try std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ snippets_dir, name });
    defer allocator.free(ns_path);
    std.fs.deleteFileAbsolute(ns_path) catch {};

    return removed;
}

/// Create a pack from existing snippets by namespace
pub fn createPack(
    allocator: std.mem.Allocator,
    name: []const u8,
    description: []const u8,
    author: []const u8,
    category: []const u8,
    snip_store: *store.Store,
    namespace_filter: ?[]const u8,
    output_path: []const u8,
) !usize {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.print("# zipet pack — {s}\n", .{name});
    try writer.print("# Share this file: zipet pack install {s}.toml\n\n", .{name});

    try writer.print("[pack]\n", .{});
    try writer.print("name = \"{s}\"\n", .{name});
    try writer.print("description = \"{s}\"\n", .{description});
    try writer.print("author = \"{s}\"\n", .{author});
    try writer.print("version = \"1.0.0\"\n", .{});
    try writer.print("category = \"{s}\"\n\n", .{category});

    var count: usize = 0;
    for (snip_store.snippets.items) |snip| {
        if (snip.kind == .workflow) continue;

        if (namespace_filter) |ns| {
            if (!std.mem.eql(u8, snip.namespace, ns)) continue;
        }

        try writer.print("[snippets.{s}]\n", .{snip.name});
        try writer.print("desc = \"{s}\"\n", .{snip.desc});
        try writer.writeAll("tags = [");
        for (snip.tags, 0..) |tag, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("\"{s}\"", .{tag});
        }
        try writer.writeAll("]\n");
        try writer.print("cmd = \"{s}\"\n", .{snip.cmd});

        if (snip.params.len > 0) {
            for (snip.params) |p| {
                try writer.print("\n[snippets.{s}.params.{s}]\n", .{ snip.name, p.name });
                if (p.prompt) |pr| try writer.print("prompt = \"{s}\"\n", .{pr});
                if (p.default) |d| try writer.print("default = \"{s}\"\n", .{d});
                if (p.command) |c| try writer.print("command = \"{s}\"\n", .{c});
            }
        }
        try writer.writeAll("\n");
        count += 1;
    }

    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(buf.items);

    return count;
}

pub const InstallResult = struct {
    snippets_added: usize,
    workflows_added: usize,
    pack_name: []const u8,
    err_msg: ?[]const u8,
};

pub fn freeInstallResult(allocator: std.mem.Allocator, r: InstallResult) void {
    allocator.free(r.pack_name);
    if (r.err_msg) |e| allocator.free(e);
}

/// A single snippet/workflow entry preview from a pack file
pub const PackItemPreview = struct {
    name: []const u8,
    desc: []const u8,
    cmd: []const u8,
    tags: []const []const u8,
    kind: enum { snippet, workflow },
};

/// Get a detailed preview of all snippets/workflows inside a pack (by pack name)
pub fn getPackPreview(allocator: std.mem.Allocator, name: []const u8) ![]PackItemPreview {
    // Find the pack file
    const builtin_path = try getBuiltinPackPath(allocator, name);
    defer allocator.free(builtin_path);

    const file = std.fs.openFileAbsolute(builtin_path, .{}) catch {
        return allocator.alloc(PackItemPreview, 0);
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 512);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const table = toml.parse(arena.allocator(), content) catch {
        return allocator.alloc(PackItemPreview, 0);
    };

    var result: std.ArrayList(PackItemPreview) = .{};

    // Collect snippet names
    var snippet_names = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = snippet_names.keyIterator();
        while (key_iter.next()) |k| allocator.free(k.*);
        snippet_names.deinit();
    }

    for (table.keys) |key| {
        if (std.mem.startsWith(u8, key, "snippets.")) {
            const rest = key["snippets.".len..];
            if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                const sn = rest[0..dot];
                if (!snippet_names.contains(sn)) {
                    try snippet_names.put(try allocator.dupe(u8, sn), {});
                }
            }
        }
    }

    var name_iter = snippet_names.keyIterator();
    while (name_iter.next()) |name_ptr| {
        const sname = name_ptr.*;
        const cmd_key = try std.fmt.allocPrint(allocator, "snippets.{s}.cmd", .{sname});
        defer allocator.free(cmd_key);
        const desc_key = try std.fmt.allocPrint(allocator, "snippets.{s}.desc", .{sname});
        defer allocator.free(desc_key);
        const tags_key = try std.fmt.allocPrint(allocator, "snippets.{s}.tags", .{sname});
        defer allocator.free(tags_key);

        const cmd_val = table.getString(cmd_key) orelse continue;
        const desc_val = table.getString(desc_key) orelse "";

        var tags: std.ArrayList([]const u8) = .{};
        if (table.getArray(tags_key)) |arr| {
            for (arr) |item| {
                switch (item) {
                    .string => |s| try tags.append(allocator, try allocator.dupe(u8, s)),
                    else => {},
                }
            }
        }

        try result.append(allocator, .{
            .name = try allocator.dupe(u8, sname),
            .desc = try allocator.dupe(u8, desc_val),
            .cmd = try allocator.dupe(u8, cmd_val),
            .tags = try tags.toOwnedSlice(allocator),
            .kind = .snippet,
        });
    }

    // Collect workflow names
    var wf_names = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = wf_names.keyIterator();
        while (key_iter.next()) |k| allocator.free(k.*);
        wf_names.deinit();
    }

    for (table.keys) |key| {
        if (std.mem.startsWith(u8, key, "workflows.")) {
            const rest = key["workflows.".len..];
            if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                const wn = rest[0..dot];
                if (!wf_names.contains(wn)) {
                    try wf_names.put(try allocator.dupe(u8, wn), {});
                }
            }
        }
    }

    var wf_iter = wf_names.keyIterator();
    while (wf_iter.next()) |wn_ptr| {
        const wname = wn_ptr.*;
        const desc_key = try std.fmt.allocPrint(allocator, "workflows.{s}.desc", .{wname});
        defer allocator.free(desc_key);
        const desc_val = table.getString(desc_key) orelse "";

        try result.append(allocator, .{
            .name = try allocator.dupe(u8, wname),
            .desc = try allocator.dupe(u8, desc_val),
            .cmd = try allocator.dupe(u8, ""),
            .tags = try allocator.alloc([]const u8, 0),
            .kind = .workflow,
        });
    }

    return try result.toOwnedSlice(allocator);
}

pub fn freePackPreview(allocator: std.mem.Allocator, items: []PackItemPreview) void {
    for (items) |item| {
        allocator.free(item.name);
        allocator.free(item.desc);
        allocator.free(item.cmd);
        for (item.tags) |tag| allocator.free(tag);
        allocator.free(item.tags);
    }
    allocator.free(items);
}

pub fn freePackMetas(allocator: std.mem.Allocator, metas: []PackMeta) void {
    for (metas) |m| {
        allocator.free(m.name);
        allocator.free(m.description);
        allocator.free(m.author);
        allocator.free(m.version);
        allocator.free(m.category);
        for (m.tags) |t| allocator.free(t);
        allocator.free(m.tags);
    }
    allocator.free(metas);
}
