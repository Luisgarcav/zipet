/// OutputView — displays styled text lines (command output) with scroll support.
/// This is a full-screen vxfw widget that reads from state.output.lines.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const vxfw = t.vxfw;

state: *t.State,
cfg: config.Config,
pending_g: bool = false,

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
    const state = self.state;

    switch (event) {
        .key_press => |key| {
            // q or Escape → back to normal
            if (key.codepoint == 'q' or key.codepoint == vaxis.Key.escape) {
                self.pending_g = false;
                state.mode = .normal;
                state.output_scroll = 0;
                return ctx.consumeAndRedraw();
            }

            // j / Down → scroll down 1
            if (key.codepoint == 'j' or key.codepoint == vaxis.Key.down) {
                self.pending_g = false;
                const max = self.maxScroll();
                if (state.output_scroll < max) state.output_scroll += 1;
                return ctx.consumeAndRedraw();
            }

            // k / Up → scroll up 1
            if (key.codepoint == 'k' or key.codepoint == vaxis.Key.up) {
                self.pending_g = false;
                if (state.output_scroll > 0) state.output_scroll -= 1;
                return ctx.consumeAndRedraw();
            }

            // G → scroll to end
            if (key.codepoint == 'G') {
                self.pending_g = false;
                state.output_scroll = self.maxScroll();
                return ctx.consumeAndRedraw();
            }

            // g (double tap) → scroll to top
            if (key.codepoint == 'g') {
                if (self.pending_g) {
                    self.pending_g = false;
                    state.output_scroll = 0;
                } else {
                    self.pending_g = true;
                }
                return ctx.consumeAndRedraw();
            }

            // Ctrl-D → page down (half screen)
            if (key.codepoint == 'd' and key.mods.ctrl) {
                self.pending_g = false;
                const half = last_height / 2;
                const max = self.maxScroll();
                state.output_scroll = @min(state.output_scroll + half, max);
                return ctx.consumeAndRedraw();
            }

            // Ctrl-U → page up (half screen)
            if (key.codepoint == 'u' and key.mods.ctrl) {
                self.pending_g = false;
                const half = last_height / 2;
                state.output_scroll -|= half;
                return ctx.consumeAndRedraw();
            }
        },
        else => {},
    }
}

/// Cached height from last draw, used for page up/down calculations.
var last_height: usize = 24;

fn maxScroll(self: *const OutputView) usize {
    const total = self.state.output.lines.items.len;
    // Reserve 2 lines for title bar + bottom hint
    const visible = if (last_height > 2) last_height - 2 else 1;
    if (total <= visible) return 0;
    return total - visible;
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
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;
    const h: usize = @intCast(height);

    // Cache height for page up/down
    last_height = h;

    const lines = state.output.lines.items;

    // Layout: 1 line title, (height-2) content, 1 line hints
    const content_h: usize = if (h > 2) h - 2 else 1;

    // Build children array: title + content lines + hint bar
    const visible_count = @min(content_h, if (lines.len > state.output_scroll) lines.len - state.output_scroll else 0);
    const child_count = 1 + visible_count + 1; // title + lines + hint

    const children = try ctx.arena.alloc(vxfw.FlexItem, child_count);

    // ── Title bar ──
    const title_text = if (state.output_title.len > 0) state.output_title else "Output";
    const title_widget = try ctx.arena.create(vxfw.Text);
    title_widget.* = .{ .text = title_text, .style = t.header_style };
    children[0] = .{ .widget = title_widget.widget(), .flex = 0 };

    // ── Content lines ──
    for (0..visible_count) |i| {
        const line = lines[state.output_scroll + i];
        const style = lineStyleToVaxis(line.style, self.cfg);
        const text_w = try ctx.arena.create(vxfw.Text);
        text_w.* = .{ .text = if (line.text.len > 0) line.text else " ", .style = style };
        children[1 + i] = .{ .widget = text_w.widget(), .flex = 0 };
    }

    // ── Hint bar ──
    const hint_w = try ctx.arena.create(vxfw.Text);
    hint_w.* = .{ .text = " q:close  j/k:scroll  G:end  gg:top  ^D/^U:page", .style = t.dim_style };
    children[child_count - 1] = .{ .widget = hint_w.widget(), .flex = 0 };

    // Build FlexColumn
    var col = vxfw.FlexColumn{ .children = children };
    return col.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}
