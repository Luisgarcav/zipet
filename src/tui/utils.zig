/// TUI utility functions: filtering, clipboard, reload, helpers.
const std = @import("std");
const store = @import("../store.zig");
const template = @import("../template.zig");
const history_mod = @import("../history.zig");
const pack_mod = @import("../pack.zig");
const workflow_mod = @import("../workflow.zig");
const t = @import("types.zig");
const Key = t.Key;
const State = t.State;

pub fn yankToClipboard(allocator: std.mem.Allocator, text: []const u8) bool {
    const cmds = [_][]const []const u8{
        &.{ "xclip", "-selection", "clipboard" },
        &.{ "xsel", "--clipboard", "--input" },
        &.{"wl-copy"},
        &.{"pbcopy"},
    };
    for (cmds) |argv| {
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Pipe;
        if (child.spawn()) |_| {} else |_| continue;
        if (child.stdin) |*sp| {
            sp.writeAll(text) catch {};
            sp.close();
            child.stdin = null;
        }
        const term = child.wait() catch continue;
        if (term.Exited == 0) return true;
    }
    return false;
}

pub fn clearMessage(allocator: std.mem.Allocator, state: *State) void {
    if (state.message_owned) {
        if (state.message) |msg| allocator.free(msg);
    }
    state.message = null;
    state.message_owned = false;
}

pub fn setMessageLiteral(allocator: std.mem.Allocator, state: *State, msg: []const u8) void {
    clearMessage(allocator, state);
    state.message = msg;
    state.message_owned = false;
}

pub fn setMessageOwned(allocator: std.mem.Allocator, state: *State, msg: []const u8) void {
    clearMessage(allocator, state);
    state.message = msg;
    state.message_owned = true;
}

pub fn reloadStore(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store) void {
    // Clear workflow registry first (frees owned workflow data: steps, name, desc, namespace)
    workflow_mod.clearRegistry(allocator);
    for (snip_store.snippets.items) |s| snip_store.freeSnippet(s);
    snip_store.snippets.clearRetainingCapacity();
    snip_store.loadAll() catch {};
    allocator.free(state.filtered_indices);
    state.filtered_indices = updateFilter(allocator, snip_store, state.searchQuery()) catch &.{};
    if (state.cursor >= state.filtered_indices.len and state.filtered_indices.len > 0)
        state.cursor = state.filtered_indices.len - 1;
}

pub fn refilter(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store) void {
    allocator.free(state.filtered_indices);
    state.filtered_indices = updateFilterWithTag(allocator, snip_store, state.searchQuery(), state.active_tag_filter) catch &.{};
    state.cursor = 0;
    state.clearSelection();
}

pub fn refilterFrecency(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store, hist: *history_mod.History) void {
    allocator.free(state.filtered_indices);
    state.filtered_indices = updateFilterFrecency(allocator, snip_store, state.searchQuery(), state.active_tag_filter, hist) catch &.{};
    state.cursor = 0;
    state.clearSelection();
}

/// Update filter with frecency-based sorting when no search query is active.
/// When a search query is present, fuzzy match score takes priority but frecency is used as tiebreaker.
pub fn updateFilterFrecency(allocator: std.mem.Allocator, snip_store: *store.Store, query: []const u8, tag_filter: ?[]const u8, hist: *history_mod.History) ![]usize {
    // First get tag-filtered indices
    var tag_indices: std.ArrayList(usize) = .{};
    defer tag_indices.deinit(allocator);
    for (snip_store.snippets.items, 0..) |snip, i| {
        if (tag_filter) |tf| {
            var has = false;
            for (snip.tags) |tag| {
                if (std.mem.eql(u8, tag, tf)) {
                    has = true;
                    break;
                }
            }
            if (!has) continue;
        }
        try tag_indices.append(allocator, i);
    }

    if (query.len == 0) {
        // No search query — sort purely by frecency (most used first, then alphabetical)
        const result = try allocator.alloc(usize, tag_indices.items.len);
        @memcpy(result, tag_indices.items);

        // Sort by frecency score descending, then alphabetically
        const Context = struct {
            store_ref: *store.Store,
            hist_ref: *history_mod.History,
        };
        const ctx = Context{ .store_ref = snip_store, .hist_ref = hist };

        std.mem.sort(usize, result, ctx, struct {
            fn cmp(c: Context, a: usize, b: usize) bool {
                const sa = c.hist_ref.getScore(c.store_ref.snippets.items[a].name);
                const sb = c.hist_ref.getScore(c.store_ref.snippets.items[b].name);
                if (sa != sb) return sa > sb;
                // Tiebreaker: alphabetical
                return std.mem.lessThan(u8, c.store_ref.snippets.items[a].name, c.store_ref.snippets.items[b].name);
            }
        }.cmp);

        return result;
    }

    // With search query — fuzzy match, then sort by fuzzy score (frecency as tiebreaker)
    const fuzzy_mod = @import("../fuzzy.zig");
    var items: std.ArrayList([]const u8) = .{};
    defer {
        for (items.items) |s| allocator.free(s);
        items.deinit(allocator);
    }
    for (tag_indices.items) |idx| {
        const snip = &snip_store.snippets.items[idx];
        try items.append(allocator, try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ snip.name, snip.desc, snip.cmd }));
    }
    const ranked = try fuzzy_mod.rank(allocator, items.items, query);
    defer allocator.free(ranked);
    const result = try allocator.alloc(usize, ranked.len);
    for (ranked, 0..) |ri, i| result[i] = tag_indices.items[ri];
    return result;
}

pub fn updateFilterWithTag(allocator: std.mem.Allocator, snip_store: *store.Store, query: []const u8, tag_filter: ?[]const u8) ![]usize {
    var tag_indices: std.ArrayList(usize) = .{};
    defer tag_indices.deinit(allocator);
    for (snip_store.snippets.items, 0..) |snip, i| {
        if (tag_filter) |tf| {
            var has = false;
            for (snip.tags) |tag| {
                if (std.mem.eql(u8, tag, tf)) {
                    has = true;
                    break;
                }
            }
            if (!has) continue;
        }
        try tag_indices.append(allocator, i);
    }
    if (query.len == 0) return try tag_indices.toOwnedSlice(allocator);

    const fuzzy_mod = @import("../fuzzy.zig");
    var items: std.ArrayList([]const u8) = .{};
    defer {
        for (items.items) |s| allocator.free(s);
        items.deinit(allocator);
    }
    for (tag_indices.items) |idx| {
        const snip = &snip_store.snippets.items[idx];
        try items.append(allocator, try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ snip.name, snip.desc, snip.cmd }));
    }
    const ranked = try fuzzy_mod.rank(allocator, items.items, query);
    defer allocator.free(ranked);
    const result = try allocator.alloc(usize, ranked.len);
    for (ranked, 0..) |ri, i| result[i] = tag_indices.items[ri];
    return result;
}

pub fn updateFilter(allocator: std.mem.Allocator, snip_store: *store.Store, query: []const u8) ![]usize {
    if (query.len == 0) {
        const indices = try allocator.alloc(usize, snip_store.snippets.items.len);
        for (indices, 0..) |*idx, i| idx.* = i;
        return indices;
    }
    const fuzzy_mod = @import("../fuzzy.zig");
    const items = try allocator.alloc([]const u8, snip_store.snippets.items.len);
    defer {
        for (items) |s| allocator.free(s);
        allocator.free(items);
    }
    for (snip_store.snippets.items, 0..) |snip, i|
        items[i] = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ snip.name, snip.desc, snip.cmd });
    return try fuzzy_mod.rank(allocator, items, query);
}

// ── Pack search filtering ──

fn toLower(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| {
        buf[i] = if (c >= 'A' and c <= 'Z') c + 32 else c;
    }
    return buf;
}

fn containsLower(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8) bool {
    const h = toLower(allocator, haystack) catch return false;
    defer allocator.free(h);
    return std.mem.indexOf(u8, h, needle) != null;
}

pub fn filterPacks(allocator: std.mem.Allocator, pack_list: []const pack_mod.PackMeta, query: []const u8) ![]usize {
    if (query.len == 0) {
        const result = try allocator.alloc(usize, pack_list.len);
        for (result, 0..) |*idx, i| idx.* = i;
        return result;
    }

    const query_lower = try toLower(allocator, query);
    defer allocator.free(query_lower);

    var results: std.ArrayList(usize) = .{};
    for (pack_list, 0..) |p, i| {
        if (containsLower(allocator, p.name, query_lower) or
            containsLower(allocator, p.description, query_lower) or
            containsLower(allocator, p.category, query_lower) or
            containsLower(allocator, p.author, query_lower))
        {
            try results.append(allocator, i);
            continue;
        }
        // Check tags
        var tag_match = false;
        for (p.tags) |tag| {
            if (containsLower(allocator, tag, query_lower)) {
                tag_match = true;
                break;
            }
        }
        if (tag_match) try results.append(allocator, i);
    }

    return try results.toOwnedSlice(allocator);
}

pub fn refilterPacks(allocator: std.mem.Allocator, state: *State) void {
    if (state.pack_filtered_indices.len > 0) allocator.free(state.pack_filtered_indices);
    state.pack_filtered_indices = filterPacks(allocator, state.pack_list, state.packSearchQuery()) catch &.{};
    state.pack_cursor = 0;
    state.pack_scroll = 0;
}

pub fn insertKeyChar(buf: []u8, len: *usize, max: usize, key: Key) bool {
    if (key.text) |text| {
        if (text.len > 0 and text[0] >= 32 and len.* + text.len <= max) {
            @memcpy(buf[len.* .. len.* + text.len], text);
            len.* += text.len;
            return true;
        }
    } else if (key.codepoint >= 32) {
        var enc_buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(key.codepoint), &enc_buf) catch return false;
        if (len.* + n <= max) {
            @memcpy(buf[len.* .. len.* + n], enc_buf[0..n]);
            len.* += n;
            return true;
        }
    }
    return false;
}
