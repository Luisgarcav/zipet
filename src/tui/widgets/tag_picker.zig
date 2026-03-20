/// TagPicker — full-screen overlay that shows a list of tags for filtering.
/// User can select a tag to filter snippets, clear the filter, or cancel.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const store = @import("../../store.zig");
const history_mod = @import("../../history.zig");
const utils = @import("../utils.zig");
const vxfw = t.vxfw;

state: *t.State,
snip_store: *store.Store,
hist: *history_mod.History,
cfg: config.Config,
allocator: std.mem.Allocator,
list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },

const TagPicker = @This();

pub fn widget(self: *TagPicker) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

// ── Event handling ──

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *TagPicker = @ptrCast(@alignCast(userdata));

    switch (event) {
        .key_press => |key| {
            if (key.matches(vaxis.Key.escape, .{})) {
                // Clear tag filter and refilter
                self.state.active_tag_filter = null;
                self.state.search_len = 0;
                refilter(self);
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.enter, .{})) {
                if (self.state.tag_list.len > 0 and self.list_view.cursor < self.state.tag_list.len) {
                    self.state.active_tag_filter = self.state.tag_list[self.list_view.cursor];
                    refilter(self);
                    self.state.mode = .normal;
                }
                return ctx.consumeAndRedraw();
            }

            if (key.matches('q', .{})) {
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }

            if (key.matches('x', .{})) {
                self.state.active_tag_filter = null;
                self.state.search_len = 0;
                refilter(self);
                self.state.mode = .normal;
                self.state.message = "Tag filter cleared";
                return ctx.consumeAndRedraw();
            }
        },
        else => {},
    }

    // Forward unhandled events (j/k/arrows/mouse) to ListView
    return self.list_view.handleEvent(ctx, event);
}

fn refilter(self: *TagPicker) void {
    self.allocator.free(self.state.filtered_indices);
    self.state.filtered_indices = utils.updateFilterFrecency(self.allocator, self.snip_store, self.state.searchQuery(), self.state.active_tag_filter, self.hist) catch &.{};
    self.state.cursor = 0;
}

// ── Rendering ──

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *TagPicker = @ptrCast(@alignCast(userdata));
    const state = self.state;
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;

    const items = state.tag_list;

    // Build Text widgets for list_view
    const texts = try ctx.arena.alloc(vxfw.Text, items.len);
    const widgets = try ctx.arena.alloc(vxfw.Widget, items.len);
    for (items, 0..) |tag, i| {
        texts[i] = .{
            .text = tag,
            .style = if (i == self.list_view.cursor) t.accentBoldStyle(accent) else t.dim_style,
        };
        widgets[i] = texts[i].widget();
    }
    self.list_view.children = .{ .slice = widgets };
    self.list_view.item_count = @intCast(items.len);

    // Determine child count: title + optional active filter + list_view (flex=1) + footer
    const active_filter_row: usize = if (state.active_tag_filter != null) 1 else 0;
    const child_count = 1 + active_filter_row + 1 + 1; // title + filter? + list_view + footer

    const children = try ctx.arena.alloc(vxfw.FlexItem, child_count);
    var idx: usize = 0;

    // ── Title ──
    {
        const title_w = try ctx.arena.create(vxfw.Text);
        title_w.* = .{ .text = "Tags", .style = t.accentBoldStyle(accent) };
        children[idx] = .{ .widget = title_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Active filter ──
    if (state.active_tag_filter) |tag| {
        const filter_line = try std.fmt.allocPrint(ctx.arena, "  Active: [{s}]", .{tag});
        const filter_w = try ctx.arena.create(vxfw.Text);
        filter_w.* = .{ .text = filter_line, .style = t.accentStyle(accent) };
        children[idx] = .{ .widget = filter_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── ListView (flex=1, takes remaining space) ──
    const guard = try ctx.arena.create(t.ListViewGuard);
    guard.* = .{ .inner = &self.list_view };
    children[idx] = .{ .widget = guard.widget(), .flex = 1 };
    idx += 1;

    // ── Footer ──
    {
        const footer_w = try ctx.arena.create(vxfw.Text);
        footer_w.* = .{ .text = "  Enter select  x clear  Esc/q cancel", .style = t.dim_style };
        children[idx] = .{ .widget = footer_w.widget(), .flex = 0 };
        idx += 1;
    }

    var col = vxfw.FlexColumn{ .children = children[0..idx] };
    const labels = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
    labels[0] = .{ .text = "Tag Filter", .alignment = .top_center };
    var border = vxfw.Border{
        .child = col.widget(),
        .style = t.dim_style,
        .labels = labels,
    };
    return border.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}
