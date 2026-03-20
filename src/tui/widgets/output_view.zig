/// OutputView — displays styled text lines (command output) with scroll support.
/// Uses vxfw.ScrollView for automatic scroll management.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const vxfw = t.vxfw;

state: *t.State,
cfg: config.Config,
pending_g: bool = false,
scroll_view: vxfw.ScrollView = .{ .children = .{ .slice = &.{} } },

const OutputView = @This();

pub fn widget(self: *OutputView) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *OutputView = @ptrCast(@alignCast(userdata));

    switch (event) {
        .key_press => |key| {
            // q or Escape → back to normal (intercept before ScrollView gets Esc)
            if (key.matches('q', .{}) or key.matches(vaxis.Key.escape, .{})) {
                self.pending_g = false;
                self.state.mode = .normal;
                // Reset scroll position for next time
                self.scroll_view.scroll = .{};
                return ctx.consumeAndRedraw();
            }

            // G → scroll to end
            if (key.matches('G', .{})) {
                self.pending_g = false;
                _ = self.scroll_view.scroll.linesDown(255);
                return ctx.consumeAndRedraw();
            }

            // gg → scroll to top
            if (key.matches('g', .{})) {
                if (self.pending_g) {
                    self.pending_g = false;
                    self.scroll_view.scroll = .{};
                    return ctx.consumeAndRedraw();
                } else {
                    self.pending_g = true;
                    return ctx.consumeAndRedraw();
                }
            }

            // Reset pending_g on any other key
            self.pending_g = false;

            // Forward j/k/Ctrl-D/Ctrl-U/arrows/mouse to ScrollView
            return self.scroll_view.handleEvent(ctx, event);
        },
        .mouse => {
            // Forward mouse events (wheel scroll) to ScrollView
            return self.scroll_view.handleEvent(ctx, event);
        },
        else => {},
    }
}

fn lineStyleToVaxis(ls: t.LineStyle, cfg: config.Config) t.Style {
    return switch (ls) {
        .normal => .{},
        .header => t.header_style,
        .dim => t.dim_style,
        .success => t.success_style,
        .err => t.err_style,
        .cmd => t.accentStyle(cfg.accent_color),
    };
}

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *OutputView = @ptrCast(@alignCast(userdata));
    const state = self.state;
    const lines = state.output.lines.items;

    // Build text widgets for each line on arena
    const texts = try ctx.arena.alloc(vxfw.Text, lines.len);
    const widgets = try ctx.arena.alloc(vxfw.Widget, lines.len);
    for (lines, 0..) |line, i| {
        texts[i] = .{
            .text = if (line.text.len > 0) line.text else " ",
            .style = lineStyleToVaxis(line.style, self.cfg),
        };
        widgets[i] = texts[i].widget();
    }

    // Update scroll view children
    self.scroll_view.children = .{ .slice = widgets };
    self.scroll_view.item_count = @intCast(lines.len);

    // Build FlexColumn: title + scrollview + footer
    const title_text_str = state.output_title orelse "Output";
    const title_widget = try ctx.arena.create(vxfw.Text);
    title_widget.* = .{ .text = title_text_str, .style = t.header_style };

    const footer_widget = try ctx.arena.create(vxfw.Text);
    footer_widget.* = .{ .text = " q:close  j/k:scroll  G:end  gg:top  ^D/^U:page", .style = t.dim_style };

    const flex_children = try ctx.arena.alloc(vxfw.FlexItem, 3);
    flex_children[0] = .{ .widget = title_widget.widget(), .flex = 0 };
    const sv_guard = try ctx.arena.create(t.ScrollViewGuard);
    sv_guard.* = .{ .inner = &self.scroll_view };
    flex_children[1] = .{ .widget = sv_guard.widget(), .flex = 1 };
    flex_children[2] = .{ .widget = footer_widget.widget(), .flex = 0 };

    var col = vxfw.FlexColumn{ .children = flex_children };
    var border = vxfw.Border{
        .child = col.widget(),
        .style = t.dim_style,
    };
    return border.widget().draw(ctx);
}
