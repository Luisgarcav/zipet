/// HelpScreen — displays a static help reference panel.
/// On `?` or `Esc` it closes (returns to normal mode).
/// All other key events are NOT consumed — they bubble up to ZipetRoot.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const vxfw = t.vxfw;

state: *t.State,
cfg: config.Config,

const HelpScreen = @This();

pub fn widget(self: *HelpScreen) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *HelpScreen = @ptrCast(@alignCast(userdata));

    switch (event) {
        .key_press => |key| {
            if (key.codepoint == '?' or key.codepoint == vaxis.Key.escape) {
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }
            // All other keys: do NOT consume, let them bubble up.
        },
        else => {},
    }
}

const HelpLine = union(enum) {
    title: []const u8,
    header: []const u8,
    entry: struct { key: []const u8, desc: []const u8 },
    spacer,
};

const help_content = [_]HelpLine{
    .{ .title = "QUICK REFERENCE" },
    .spacer,
    .{ .header = "Navigation" },
    .{ .entry = .{ .key = "  j / k", .desc = "Up / Down" } },
    .{ .entry = .{ .key = "  gg / G", .desc = "First / Last" } },
    .{ .entry = .{ .key = "  Ctrl-D / U", .desc = "Page Down / Up" } },
    .{ .entry = .{ .key = "  /", .desc = "Search" } },
    .{ .entry = .{ .key = "  Esc", .desc = "Clear / Back" } },
    .spacer,
    .{ .header = "Actions" },
    .{ .entry = .{ .key = "  Enter", .desc = "Run snippet" } },
    .{ .entry = .{ .key = "  e", .desc = "Edit snippet" } },
    .{ .entry = .{ .key = "  d", .desc = "Delete (confirm)" } },
    .{ .entry = .{ .key = "  a", .desc = "Add new snippet" } },
    .{ .entry = .{ .key = "  w", .desc = "Create workflow" } },
    .{ .entry = .{ .key = "  y", .desc = "Yank/Copy" } },
    .{ .entry = .{ .key = "  p", .desc = "Paste" } },
    .{ .entry = .{ .key = "  o", .desc = "Open TOML file" } },
    .{ .entry = .{ .key = "  i", .desc = "Full info panel" } },
    .{ .entry = .{ .key = "  Space", .desc = "Toggle preview" } },
    .{ .entry = .{ .key = "  x", .desc = "Toggle select" } },
    .{ .entry = .{ .key = "  X", .desc = "Select all / Clear" } },
    .{ .entry = .{ .key = "  R", .desc = "Run selected" } },
    .{ .entry = .{ .key = "  D", .desc = "Delete selected" } },
    .{ .entry = .{ .key = "  t", .desc = "Filter by tag" } },
    .{ .entry = .{ .key = "  W", .desc = "Workspace picker" } },
    .{ .entry = .{ .key = "  P", .desc = "Pack browser" } },
    .spacer,
    .{ .header = "Commands" },
    .{ .entry = .{ .key = "  :q", .desc = "Quit" } },
    .{ .entry = .{ .key = "  :w", .desc = "Save all" } },
    .{ .entry = .{ .key = "  :wq", .desc = "Save & quit" } },
    .{ .entry = .{ .key = "  :tags", .desc = "Tag picker" } },
    .{ .entry = .{ .key = "  :export", .desc = "Export snippets" } },
    .{ .entry = .{ .key = "  :ws", .desc = "Workspace picker" } },
    .{ .entry = .{ .key = "  :packs", .desc = "Pack browser" } },
    .spacer,
};

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *HelpScreen = @ptrCast(@alignCast(userdata));
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;

    const children = try ctx.arena.alloc(vxfw.FlexItem, help_content.len);

    for (help_content, 0..) |line, i| {
        const text_w = try ctx.arena.create(vxfw.Text);
        switch (line) {
            .title => |txt| {
                text_w.* = .{ .text = txt, .style = t.accentBoldStyle(accent) };
            },
            .header => |txt| {
                text_w.* = .{ .text = txt, .style = t.accentBoldStyle(accent) };
            },
            .entry => |e| {
                if (e.desc.len == 0) {
                    // "? to close" — render as accent
                    text_w.* = .{ .text = e.key, .style = t.accentStyle(accent) };
                } else {
                    // Build "key  desc" with mixed styles using concatenation
                    // Since vxfw.Text only supports a single style, we pad and concat
                    const pad_to = 16;
                    const key_len = e.key.len;
                    const pad_len = if (pad_to > key_len) pad_to - key_len else 2;
                    const spaces = try ctx.arena.alloc(u8, pad_len);
                    @memset(spaces, ' ');
                    const full = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ e.key, spaces, e.desc });
                    text_w.* = .{ .text = full, .style = t.dim_style };
                }
            },
            .spacer => {
                text_w.* = .{ .text = " ", .style = .{} };
            },
        }
        children[i] = .{ .widget = text_w.widget(), .flex = 0 };
    }

    var col = vxfw.FlexColumn{ .children = children };
    const labels = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
    labels[0] = .{ .text = "Help", .alignment = .top_center };
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
