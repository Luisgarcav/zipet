/// TUI utility functions: filtering, clipboard, reload, helpers.
const std = @import("std");
const store = @import("../store.zig");
const template = @import("../template.zig");
const t = @import("types.zig");

const Key = t.Key;
const State = t.State;
const TextField = t.TextField;

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

pub fn reloadStore(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store) void {
    for (snip_store.snippets.items) |s| snip_store.freeSnippet(s);
    snip_store.snippets.clearRetainingCapacity();
    snip_store.loadAll() catch {};
    allocator.free(state.filtered_indices);
    state.filtered_indices = updateFilter(allocator, snip_store, state.searchQuery()) catch &.{};
    if (state.cursor >= state.filtered_indices.len and state.filtered_indices.len > 0)
        state.cursor = state.filtered_indices.len - 1;
}

pub fn adjustScroll(state: *State, term_rows: u16) void {
    const h = state.listHeight(term_rows);
    if (state.cursor < state.scroll_offset) state.scroll_offset = state.cursor
    else if (state.cursor >= state.scroll_offset + h) state.scroll_offset = state.cursor - h + 1;
}

pub fn refilter(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store) void {
    allocator.free(state.filtered_indices);
    state.filtered_indices = updateFilterWithTag(allocator, snip_store, state.searchQuery(), state.active_tag_filter) catch &.{};
    state.cursor = 0;
    state.scroll_offset = 0;
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

pub fn handleTextFieldKey(field: *TextField, key: Key) void {
    if (key.matches(Key.backspace, .{})) {
        field.backspace();
    } else if (key.matches(Key.delete, .{}) or key.matches('d', .{ .ctrl = true })) {
        field.deleteForward();
    } else if (key.matches(Key.left, .{}) or key.matches('b', .{ .ctrl = true })) {
        field.moveLeft();
    } else if (key.matches(Key.right, .{}) or key.matches('f', .{ .ctrl = true })) {
        field.moveRight();
    } else if (key.matches(Key.home, .{}) or key.matches('a', .{ .ctrl = true })) {
        field.moveHome();
    } else if (key.matches(Key.end, .{}) or key.matches('e', .{ .ctrl = true })) {
        field.moveEnd();
    } else if (key.matches('u', .{ .ctrl = true })) {
        field.clear();
    } else {
        if (key.text) |text| {
            for (text) |c| {
                if (c >= 32 and c < 127) field.insertChar(c);
            }
        } else if (key.codepoint >= 32 and key.codepoint < 127) {
            field.insertChar(@intCast(key.codepoint));
        }
    }
}

pub fn insertKeyChar(buf: []u8, len: *usize, max: usize, key: Key) bool {
    var inserted = false;
    if (key.text) |text| {
        for (text) |c| {
            if (c >= 32 and c < 127 and len.* < max) {
                buf[len.*] = c;
                len.* += 1;
                inserted = true;
            }
        }
    } else if (key.codepoint >= 32 and key.codepoint < 127 and len.* < max) {
        buf[len.*] = @intCast(key.codepoint);
        len.* += 1;
        inserted = true;
    }
    return inserted;
}
