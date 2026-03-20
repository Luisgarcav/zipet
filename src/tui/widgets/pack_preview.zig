/// PackPreview — shows the contents of a selected pack (snippets + workflows) with a detail panel.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const utils = @import("../utils.zig");
const store = @import("../../store.zig");
const pack_mod = @import("../../pack.zig");
const unicode = @import("../unicode.zig");
const vxfw = t.vxfw;

state: *t.State,
snip_store: *store.Store,
cfg: config.Config,
allocator: std.mem.Allocator,
list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },

const PackPreviewWidget = @This();

pub fn widget(self: *PackPreviewWidget) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

// ── Event handling ──

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *PackPreviewWidget = @ptrCast(@alignCast(userdata));

    switch (event) {
        .key_press => |key| {
            if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                self.state.mode = .pack_browser;
                return ctx.consumeAndRedraw();
            }

            if (key.matches('h', .{}) or key.matches(vaxis.Key.left, .{})) {
                self.state.mode = .pack_browser;
                return ctx.consumeAndRedraw();
            }

            if (key.matches('i', .{}) or key.matches(vaxis.Key.enter, .{})) {
                try handleInstall(self, ctx);
                return;
            }
        },
        else => {},
    }

    // Forward remaining events (j/k/arrows/g/G/mouse) to ListView
    return self.list_view.handleEvent(ctx, event);
}

fn handleInstall(self: *PackPreviewWidget, ctx: *vxfw.EventContext) !void {
    const state = self.state;
    if (state.pack_preview_installed) {
        state.message = "Pack already installed";
    } else {
        const result = pack_mod.install(self.allocator, self.cfg, state.pack_preview_name, null, self.snip_store) catch {
            state.message = "\xe2\x9c\x97 Failed to install pack";
            return ctx.consumeAndRedraw();
        };
        defer pack_mod.freeInstallResult(self.allocator, result);

        if (result.err_msg) |_| {
            state.message = "\xe2\x9c\x97 Failed to install pack";
        } else {
            state.pack_preview_installed = true;
            // Also update the browser list entry
            for (state.pack_list) |*p| {
                if (std.mem.eql(u8, p.name, state.pack_preview_name)) {
                    p.installed = true;
                    break;
                }
            }
            self.allocator.free(state.filtered_indices);
            state.filtered_indices = utils.updateFilter(self.allocator, self.snip_store, "") catch &.{};
            state.message = "\xe2\x9c\x93 Pack installed!";
        }
    }
    return ctx.consumeAndRedraw();
}

// ── Rendering ──

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *PackPreviewWidget = @ptrCast(@alignCast(userdata));
    const state = self.state;
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;
    const w: usize = @intCast(width);

    const items = state.pack_preview_items;
    const total = items.len;

    // Build Text widgets for list_view
    if (total == 0) {
        const empty_texts = try ctx.arena.alloc(vxfw.Text, 1);
        const empty_widgets = try ctx.arena.alloc(vxfw.Widget, 1);
        empty_texts[0] = .{ .text = "  No items in this pack", .style = t.dim_style };
        empty_widgets[0] = empty_texts[0].widget();
        self.list_view.children = .{ .slice = empty_widgets };
        self.list_view.item_count = 1;
    } else {
        const texts = try ctx.arena.alloc(vxfw.Text, total);
        const widgets = try ctx.arena.alloc(vxfw.Widget, total);

        for (items, 0..) |*item, i| {
            const is_selected = i == self.list_view.cursor;
            const kind_icon: []const u8 = if (item.kind == .snippet) "$ " else "⚡";
            const line = try std.fmt.allocPrint(ctx.arena, "{s}{s}  {s}", .{ kind_icon, item.name, item.desc });
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

    // Layout: title + list_view (flex=1) + separator + detail(5) + footer
    const total_children = 1 + 1 + 1 + 5 + 1; // title + list_view + separator + detail(5) + footer
    const children = try ctx.arena.alloc(vxfw.FlexItem, total_children);
    var idx: usize = 0;

    // ── Title bar ──
    {
        const installed_str: []const u8 = if (state.pack_preview_installed) " \xe2\x9c\x93 installed" else "";
        const count_str = try std.fmt.allocPrint(ctx.arena, "{d} items", .{total});
        const title_prefix = try std.fmt.allocPrint(ctx.arena, "  Pack: {s}{s}", .{ state.pack_preview_name, installed_str });
        const prefix_w = unicode.displayWidth(title_prefix);
        const count_w = unicode.displayWidth(count_str);
        const gap = if (w > prefix_w + count_w + 2) w - prefix_w - count_w - 2 else 1;
        const spaces = try ctx.arena.alloc(u8, gap);
        @memset(spaces, ' ');
        const title_line = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ title_prefix, spaces, count_str });

        const title_w = try ctx.arena.create(vxfw.Text);
        title_w.* = .{ .text = title_line, .style = t.reverse_style };
        children[idx] = .{ .widget = title_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── ListView (flex=1, takes remaining space) ──
    const guard = try ctx.arena.create(t.ListViewGuard);
    guard.* = .{ .inner = &self.list_view };
    children[idx] = .{ .widget = guard.widget(), .flex = 1 };
    idx += 1;

    // ── Detail panel separator ──
    {
        const sep_w = try ctx.arena.create(vxfw.Text);
        const sep_text = try std.fmt.allocPrint(ctx.arena, "  {s} Preview {s}", .{
            "\xe2\x94\x80\xe2\x94\x80", // ──
            "\xe2\x94\x80\xe2\x94\x80", // ──
        });
        sep_w.* = .{ .text = sep_text, .style = t.dim_style };
        children[idx] = .{ .widget = sep_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Detail panel (5 rows) ──
    if (total > 0 and self.list_view.cursor < total) {
        const item = &items[self.list_view.cursor];

        // Name
        {
            const name_line = try std.fmt.allocPrint(ctx.arena, "  Name: {s}", .{item.name});
            const nw = try ctx.arena.create(vxfw.Text);
            nw.* = .{ .text = name_line, .style = t.bold_style };
            children[idx] = .{ .widget = nw.widget(), .flex = 0 };
            idx += 1;
        }

        // Description
        {
            const desc_line = try std.fmt.allocPrint(ctx.arena, "  {s}", .{if (item.desc.len > 0) item.desc else "(no description)"});
            const dw = try ctx.arena.create(vxfw.Text);
            dw.* = .{ .text = desc_line, .style = .{} };
            children[idx] = .{ .widget = dw.widget(), .flex = 0 };
            idx += 1;
        }

        // Command or type
        {
            const cmd_line = if (item.kind == .snippet) blk: {
                if (item.cmd.len > 0) {
                    const max_cmd_w: usize = if (w > 4) w - 4 else 1;
                    const truncated = unicode.truncateToDisplayWidth(item.cmd, max_cmd_w);
                    break :blk try std.fmt.allocPrint(ctx.arena, "  $ {s}", .{truncated});
                } else {
                    break :blk try std.fmt.allocPrint(ctx.arena, "  $ (no command)", .{});
                }
            } else try std.fmt.allocPrint(ctx.arena, "  Type: workflow", .{});

            const cw = try ctx.arena.create(vxfw.Text);
            cw.* = .{ .text = cmd_line, .style = t.dim_style };
            children[idx] = .{ .widget = cw.widget(), .flex = 0 };
            idx += 1;
        }

        // Tags
        {
            var tags_buf: std.ArrayList(u8) = .{};
            const tw = tags_buf.writer(ctx.arena);
            try tw.writeAll("  Tags: ");
            if (item.tags.len > 0) {
                for (item.tags, 0..) |tag, ti| {
                    if (ti > 0) try tw.writeAll(", ");
                    try tw.writeAll(tag);
                }
            } else {
                try tw.writeAll("(none)");
            }
            const tags_line = try tags_buf.toOwnedSlice(ctx.arena);

            const tw2 = try ctx.arena.create(vxfw.Text);
            tw2.* = .{ .text = tags_line, .style = t.dim_style };
            children[idx] = .{ .widget = tw2.widget(), .flex = 0 };
            idx += 1;
        }

        // Spacer
        {
            const sp = try ctx.arena.create(vxfw.Text);
            sp.* = .{ .text = " ", .style = .{} };
            children[idx] = .{ .widget = sp.widget(), .flex = 0 };
            idx += 1;
        }
    } else {
        // No item selected — 5 empty rows
        var r: usize = 0;
        while (r < 5) : (r += 1) {
            const ew = try ctx.arena.create(vxfw.Text);
            ew.* = .{ .text = " ", .style = .{} };
            children[idx] = .{ .widget = ew.widget(), .flex = 0 };
            idx += 1;
        }
    }

    // ── Footer ──
    {
        const install_hint: []const u8 = if (state.pack_preview_installed) "already installed" else "Enter install";
        const footer_keys = try std.fmt.allocPrint(ctx.arena, "  j/k move  {s}  q/Esc back to browser", .{install_hint});

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
