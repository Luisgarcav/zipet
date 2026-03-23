/// PackBrowser — browsable list of available packs (local + community) with search.
/// Handles both .pack_browser and .pack_search modes.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const utils = @import("../utils.zig");
const actions = @import("../actions.zig");
const store_mod = @import("../../store.zig");
const pack_mod = @import("../../pack.zig");
const unicode = @import("../unicode.zig");
const vxfw = t.vxfw;

state: *t.State,
snip_store: *store_mod.Store,
cfg: config.Config,
allocator: std.mem.Allocator,
list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },

const PackBrowserWidget = @This();

pub fn widget(self: *PackBrowserWidget) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

// ── Helpers ──

fn packEffectiveTotal(state: *t.State) usize {
    return if (state.pack_search_active) state.pack_filtered_indices.len else state.pack_list.len;
}

fn packRealIndex(state: *t.State, cursor: usize) usize {
    return if (state.pack_search_active and cursor < state.pack_filtered_indices.len)
        state.pack_filtered_indices[cursor]
    else
        cursor;
}

// ── Event handling ──

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *PackBrowserWidget = @ptrCast(@alignCast(userdata));

    switch (event) {
        .key_press => |key| {
            switch (self.state.mode) {
                .pack_browser => try handlePackBrowserKey(self, key, ctx, event),
                .pack_search => handlePackSearchKey(self, key, ctx),
                else => {},
            }
        },
        else => {},
    }
}

fn handlePackBrowserKey(self: *PackBrowserWidget, key: vaxis.Key, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
    const state = self.state;
    const total = packEffectiveTotal(state);

    if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
        if (state.pack_search_active) {
            // Clear search first
            state.pack_search_len = 0;
            state.pack_search_active = false;
            if (state.pack_filtered_indices.len > 0) self.allocator.free(state.pack_filtered_indices);
            state.pack_filtered_indices = &.{};
            self.list_view.cursor = 0;
        } else {
            state.mode = .normal;
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches(vaxis.Key.enter, .{}) or key.matches('l', .{}) or key.matches(vaxis.Key.space, .{})) {
        // Open pack preview
        if (total > 0 and self.list_view.cursor < total) {
            const real_idx = packRealIndex(state, self.list_view.cursor);
            state.pack_cursor = real_idx;
            state.pack_search_active = false;
            if (state.pack_filtered_indices.len > 0) self.allocator.free(state.pack_filtered_indices);
            state.pack_filtered_indices = &.{};
            try actions.openPackPreview(self.allocator, state);
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('i', .{})) {
        // Direct install from browser
        if (total > 0 and self.list_view.cursor < total) {
            const real_idx = packRealIndex(state, self.list_view.cursor);
            const p = &state.pack_list[real_idx];
            if (p.installed) {
                utils.setMessageLiteral(self.allocator, state, "Pack already installed");
            } else {
                const result = pack_mod.install(self.allocator, self.cfg, p.name, null, self.snip_store) catch {
                    utils.setMessageLiteral(self.allocator, state, "\xe2\x9c\x97 Failed to install pack");
                    return ctx.consumeAndRedraw();
                };
                defer pack_mod.freeInstallResult(self.allocator, result);

                if (result.err_msg) |_| {
                    utils.setMessageLiteral(self.allocator, state, "\xe2\x9c\x97 Failed to install pack");
                } else {
                    p.installed = true;
                    self.allocator.free(state.filtered_indices);
                    state.filtered_indices = utils.updateFilter(self.allocator, self.snip_store, "") catch &.{};
                    utils.setMessageLiteral(self.allocator, state, "\xe2\x9c\x93 Pack installed!");
                }
            }
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('u', .{})) {
        if (total > 0 and self.list_view.cursor < total) {
            const real_idx = packRealIndex(state, self.list_view.cursor);
            const p = &state.pack_list[real_idx];
            if (!p.installed) {
                utils.setMessageLiteral(self.allocator, state, "Pack not installed");
            } else {
                const removed = pack_mod.uninstall(self.allocator, self.cfg, p.name, self.snip_store) catch {
                    utils.setMessageLiteral(self.allocator, state, "\xe2\x9c\x97 Failed to uninstall");
                    return ctx.consumeAndRedraw();
                };
                _ = removed;
                p.installed = false;
                self.allocator.free(state.filtered_indices);
                state.filtered_indices = utils.updateFilter(self.allocator, self.snip_store, "") catch &.{};
                utils.setMessageLiteral(self.allocator, state, "\xe2\x9c\x93 Pack uninstalled");
            }
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('/', .{})) {
        // Enter pack search mode — load community packs on first search
        actions.loadCommunityIntoPackList(self.allocator, state);
        state.pack_search_len = 0;
        state.pack_search_active = true;
        utils.refilterPacks(self.allocator, state);
        self.list_view.cursor = 0;
        state.mode = .pack_search;
        return ctx.consumeAndRedraw();
    }

    // Forward remaining events (j/k/arrows/g/G/mouse) to ListView
    return self.list_view.handleEvent(ctx, event);
}

fn handlePackSearchKey(self: *PackBrowserWidget, key: vaxis.Key, ctx: *vxfw.EventContext) void {
    const state = self.state;

    if (key.matches(vaxis.Key.escape, .{})) {
        // Clear search and go back to browser
        state.pack_search_len = 0;
        state.pack_search_active = false;
        if (state.pack_filtered_indices.len > 0) self.allocator.free(state.pack_filtered_indices);
        state.pack_filtered_indices = &.{};
        self.list_view.cursor = 0;
        state.mode = .pack_browser;
        return ctx.consumeAndRedraw();
    }

    if (key.matches(vaxis.Key.enter, .{})) {
        // Keep filter active, go back to browser for navigation
        state.mode = .pack_browser;
        return ctx.consumeAndRedraw();
    }

    if (key.matches(vaxis.Key.backspace, .{})) {
        if (state.pack_search_len > 0) {
            state.pack_search_len = unicode.prevCodepointStart(state.pack_search_buf[0..state.pack_search_len], state.pack_search_len);
            utils.refilterPacks(self.allocator, state);
            self.list_view.cursor = 0;
        }
        return ctx.consumeAndRedraw();
    }

    // Printable chars
    if (utils.insertKeyChar(&state.pack_search_buf, &state.pack_search_len, state.pack_search_buf.len - 1, key)) {
        utils.refilterPacks(self.allocator, state);
        self.list_view.cursor = 0;
    }
    return ctx.consumeAndRedraw();
}

// ── Rendering ──

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *PackBrowserWidget = @ptrCast(@alignCast(userdata));
    const state = self.state;
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;
    const w: usize = @intCast(width);

    const total = packEffectiveTotal(state);
    const search_visible = state.mode == .pack_search or state.pack_search_active;

    // Build Text widgets for list_view
    if (total == 0) {
        const empty_texts = try ctx.arena.alloc(vxfw.Text, 1);
        const empty_widgets = try ctx.arena.alloc(vxfw.Widget, 1);
        const empty_msg: []const u8 = if (state.pack_search_active) "  No packs match your search" else "  No packs available";
        empty_texts[0] = .{ .text = empty_msg, .style = t.dim_style };
        empty_widgets[0] = empty_texts[0].widget();
        self.list_view.children = .{ .slice = empty_widgets };
        self.list_view.item_count = 1;
    } else {
        const texts = try ctx.arena.alloc(vxfw.Text, total);
        const widgets = try ctx.arena.alloc(vxfw.Widget, total);

        for (0..total) |i| {
            const real_idx = packRealIndex(state, i);
            if (real_idx >= state.pack_list.len) {
                texts[i] = .{ .text = " ", .style = .{} };
                widgets[i] = texts[i].widget();
                continue;
            }
            const p = &state.pack_list[real_idx];
            const is_selected = i == self.list_view.cursor;

            const status_icon: []const u8 = if (p.installed)
                "\xe2\x9c\x93" // ✓
            else if (p.is_community)
                "\xe2\x98\x81" // ☁
            else
                "\xe2\x97\x89"; // ◉

            const line = try std.fmt.allocPrint(ctx.arena, "{s} {s}  {s}", .{ status_icon, p.name, p.description });
            const max_content: usize = if (w > 4) w - 4 else 1;
            const truncated = unicode.truncateToDisplayWidth(line, max_content);

            const style: t.Style = if (is_selected)
                .{ .fg = t.accentColor(accent), .bold = true }
            else
                .{};

            texts[i] = .{ .text = truncated, .style = style };
            widgets[i] = texts[i].widget();
        }
        self.list_view.children = .{ .slice = widgets };
        self.list_view.item_count = @intCast(total);
    }

    // Layout: title + search bar (conditional) + list_view (flex=1) + preview panel (3 rows) + footer
    const search_rows: usize = if (search_visible) 1 else 0;
    const child_count = 1 + search_rows + 1 + 3 + 1; // title + search? + list_view + preview(3) + footer
    const children = try ctx.arena.alloc(vxfw.FlexItem, child_count);
    var idx: usize = 0;

    // ── Title bar ──
    {
        const count_str = try std.fmt.allocPrint(ctx.arena, "{d} packs", .{total});
        const title_prefix = "  Pack Browser";
        const gap = if (w > title_prefix.len + count_str.len + 2) w - title_prefix.len - count_str.len - 2 else 1;
        const spaces = try ctx.arena.alloc(u8, gap);
        @memset(spaces, ' ');
        const title_line = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ title_prefix, spaces, count_str });

        const title_w = try ctx.arena.create(vxfw.Text);
        title_w.* = .{ .text = title_line, .style = t.accentBoldStyle(accent) };
        children[idx] = .{ .widget = title_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Search bar ──
    if (search_visible) {
        const query = state.packSearchQuery();
        const cursor_char: []const u8 = if (state.mode == .pack_search) "\xe2\x96\x8e" else ""; // ▎
        const search_line = try std.fmt.allocPrint(ctx.arena, "  / {s}{s}", .{ query, cursor_char });

        const search_w = try ctx.arena.create(vxfw.Text);
        search_w.* = .{ .text = search_line, .style = t.accentStyle(accent) };
        children[idx] = .{ .widget = search_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── ListView (flex=1, takes remaining space) ──
    // Use ListViewGuard: FlexColumn's first pass sends max.height=null, but ListView asserts non-null
    const guard = try ctx.arena.create(t.ListViewGuard);
    guard.* = .{ .inner = &self.list_view };
    children[idx] = .{ .widget = guard.widget(), .flex = 1 };
    idx += 1;

    // ── Preview panel (3 rows): tags + version of selected pack ──
    {
        const cursor_pos = self.list_view.cursor;
        if (total > 0 and cursor_pos < total) {
            const real_idx = packRealIndex(state, cursor_pos);
            if (real_idx < state.pack_list.len) {
                const p = &state.pack_list[real_idx];

                // Row 1: tags
                var tags_buf: std.ArrayList(u8) = .{};
                const tw = tags_buf.writer(ctx.arena);
                try tw.writeAll("  Tags: ");
                if (p.tags.len > 0) {
                    for (p.tags, 0..) |tag, ti| {
                        if (ti > 0) try tw.writeAll(", ");
                        try tw.writeAll(tag);
                    }
                } else {
                    try tw.writeAll("(none)");
                }
                const tags_line = try tags_buf.toOwnedSlice(ctx.arena);
                const tags_w = try ctx.arena.create(vxfw.Text);
                tags_w.* = .{ .text = tags_line, .style = t.dim_style };
                children[idx] = .{ .widget = tags_w.widget(), .flex = 0 };
                idx += 1;

                // Row 2: version
                const ver_line = try std.fmt.allocPrint(ctx.arena, "  Version: {s}", .{if (p.version.len > 0) p.version else "?"});
                const ver_w = try ctx.arena.create(vxfw.Text);
                ver_w.* = .{ .text = ver_line, .style = t.dim_style };
                children[idx] = .{ .widget = ver_w.widget(), .flex = 0 };
                idx += 1;

                // Row 3: spacer
                const sp_w = try ctx.arena.create(vxfw.Text);
                sp_w.* = .{ .text = " ", .style = .{} };
                children[idx] = .{ .widget = sp_w.widget(), .flex = 0 };
                idx += 1;
            } else {
                // Fill 3 empty rows
                var r: usize = 0;
                while (r < 3) : (r += 1) {
                    const ew = try ctx.arena.create(vxfw.Text);
                    ew.* = .{ .text = " ", .style = .{} };
                    children[idx] = .{ .widget = ew.widget(), .flex = 0 };
                    idx += 1;
                }
            }
        } else {
            // No pack selected — 3 empty rows
            var r: usize = 0;
            while (r < 3) : (r += 1) {
                const ew = try ctx.arena.create(vxfw.Text);
                ew.* = .{ .text = " ", .style = .{} };
                children[idx] = .{ .widget = ew.widget(), .flex = 0 };
                idx += 1;
            }
        }
    }

    // ── Footer ──
    {
        const footer_keys = "  / search  j/k move  Enter preview  i install  u uninstall  q close";
        const footer_line = if (state.message) |msg| blk: {
            const keys_w_usize = unicode.displayWidth(footer_keys);
            const msg_w_usize = unicode.displayWidth(msg);
            const total_w: usize = keys_w_usize + msg_w_usize + 2;
            if (total_w < w) {
                const gap = w - total_w;
                const spaces = try ctx.arena.alloc(u8, gap);
                @memset(spaces, ' ');
                break :blk try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ footer_keys, spaces, msg });
            } else {
                break :blk footer_keys;
            }
        } else footer_keys;

        const footer_w = try ctx.arena.create(vxfw.Text);
        footer_w.* = .{ .text = footer_line, .style = t.dim_style };
        children[idx] = .{ .widget = footer_w.widget(), .flex = 0 };
        idx += 1;
    }

    var col = vxfw.FlexColumn{ .children = children[0..idx] };
    return col.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}
