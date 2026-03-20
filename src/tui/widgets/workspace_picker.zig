/// WorkspacePicker — full-screen overlay for switching between workspaces.
/// Shows global (all snippets) plus each configured workspace with snippet counts.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const store = @import("../../store.zig");
const history_mod = @import("../../history.zig");
const workspace_mod = @import("../../workspace.zig");
const utils = @import("../utils.zig");
const vxfw = t.vxfw;

state: *t.State,
snip_store: *store.Store,
hist: *history_mod.History,
cfg: config.Config,
allocator: std.mem.Allocator,
list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },

const WorkspacePicker = @This();

pub fn widget(self: *WorkspacePicker) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

// ── Event handling ──

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *WorkspacePicker = @ptrCast(@alignCast(userdata));

    switch (event) {
        .key_press => |key| {
            if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.enter, .{})) {
                if (self.list_view.cursor == 0) {
                    // Global
                    if (self.state.active_workspace) |ws| self.allocator.free(ws);
                    self.state.active_workspace = null;
                    workspace_mod.setActiveWorkspace(self.allocator, self.cfg, null) catch {};
                    self.state.message = "\xe2\x9c\x93 Switched to global";
                } else if (self.list_view.cursor - 1 < self.state.ws_list.len) {
                    const ws = self.state.ws_list[self.list_view.cursor - 1];
                    if (self.state.active_workspace) |old| self.allocator.free(old);
                    self.state.active_workspace = self.allocator.dupe(u8, ws.name) catch null;
                    workspace_mod.setActiveWorkspace(self.allocator, self.cfg, ws.name) catch {};
                    self.state.message = "\xe2\x9c\x93 Switched workspace";
                }
                utils.reloadStore(self.allocator, self.state, self.snip_store);
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }
        },
        else => {},
    }

    // Forward unhandled events (j/k/arrows/mouse) to ListView
    return self.list_view.handleEvent(ctx, event);
}

// ── Rendering ──

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *WorkspacePicker = @ptrCast(@alignCast(userdata));
    const state = self.state;
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;

    const ws_count = state.ws_list.len;
    const total_items = ws_count + 1; // +1 for "Global"

    // Build Text widgets for list_view
    const texts = try ctx.arena.alloc(vxfw.Text, total_items);
    const widgets = try ctx.arena.alloc(vxfw.Widget, total_items);

    // Global item (index 0)
    {
        const is_active = state.active_workspace == null;
        const label = "Global (all snippets)";
        texts[0] = .{
            .text = label,
            .style = if (0 == self.list_view.cursor or is_active) t.accentBoldStyle(accent) else .{},
        };
        widgets[0] = texts[0].widget();
    }

    // Workspace items
    for (state.ws_list, 0..) |ws, i| {
        const item_idx = i + 1;
        const is_active = if (state.active_workspace) |aw| std.mem.eql(u8, aw, ws.name) else false;
        const line = try std.fmt.allocPrint(ctx.arena, "{s} ({d} snippets)", .{ ws.name, ws.snippet_count });
        texts[item_idx] = .{
            .text = line,
            .style = if (item_idx == self.list_view.cursor or is_active) t.accentBoldStyle(accent) else .{},
        };
        widgets[item_idx] = texts[item_idx].widget();
    }

    self.list_view.children = .{ .slice = widgets };
    self.list_view.item_count = @intCast(total_items);

    // Layout: title + list_view (flex=1) + footer
    const children = try ctx.arena.alloc(vxfw.FlexItem, 3);

    // ── Title ──
    const title_w = try ctx.arena.create(vxfw.Text);
    title_w.* = .{ .text = "Select a workspace", .style = t.accentBoldStyle(accent) };
    children[0] = .{ .widget = title_w.widget(), .flex = 0 };

    // ── ListView (flex=1) ──
    const guard = try ctx.arena.create(t.ListViewGuard);
    guard.* = .{ .inner = &self.list_view };
    children[1] = .{ .widget = guard.widget(), .flex = 1 };

    // ── Footer ──
    const footer_w = try ctx.arena.create(vxfw.Text);
    footer_w.* = .{ .text = "  Enter select  Esc/q cancel", .style = t.dim_style };
    children[2] = .{ .widget = footer_w.widget(), .flex = 0 };

    var col = vxfw.FlexColumn{ .children = children };
    const labels = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
    labels[0] = .{ .text = "Workspaces", .alignment = .top_center };
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
