/// ParamInput — form for entering parameter values before executing a parameterized snippet.
/// Uses vxfw.TextField instances for text input and passes values to actions.submitParamInput().
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const utils = @import("../utils.zig");
const actions = @import("../actions.zig");
const store_mod = @import("../../store.zig");
const history_mod = @import("../../history.zig");
const vxfw = t.vxfw;

const MAX_PARAMS = t.MAX_PARAMS;

state: *t.State,
snip_store: *store_mod.Store,
hist: *history_mod.History,
cfg: config.Config,
allocator: std.mem.Allocator,

fields: [MAX_PARAMS]vxfw.TextField,

const ParamInput = @This();

pub fn initFields(self: *ParamInput) void {
    for (&self.fields) |*f| {
        f.* = vxfw.TextField.init(self.allocator);
    }
}

pub fn deinitFields(self: *ParamInput) void {
    for (&self.fields) |*f| {
        f.deinit();
    }
}

fn clearField(self: *ParamInput, idx: usize) void {
    self.fields[idx].clearRetainingCapacity();
}

fn checkReset(self: *ParamInput) void {
    const pi = &self.state.param_input;
    if (!pi.needs_reset) return;
    pi.needs_reset = false;

    // Clear all fields
    for (0..MAX_PARAMS) |i| {
        self.clearField(i);
    }

    // Populate fields with defaults
    for (0..pi.param_count) |i| {
        if (pi.defaults[i]) |d| {
            self.fields[i].insertSliceAtCursor(d) catch {};
        }
    }
}

pub fn widget(self: *ParamInput) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *ParamInput = @ptrCast(@alignCast(userdata));
    const pi = &self.state.param_input;

    // Check if we need to reset fields from state
    self.checkReset();

    switch (event) {
        .key_press => |key| {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.enter, .{})) {
                try self.handleSubmit();
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.down, .{})) {
                if (pi.param_count > 0) {
                    if (pi.active + 1 < pi.param_count) pi.active += 1 else pi.active = 0;
                }
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.up, .{})) {
                if (pi.param_count > 0) {
                    if (pi.active > 0) pi.active -= 1 else pi.active = pi.param_count - 1;
                }
                return ctx.consumeAndRedraw();
            }

            // Forward to active TextField
            try self.fields[pi.active].handleEvent(ctx, .{ .key_press = key });
            return;
        },
        else => {},
    }
}

fn handleSubmit(self: *ParamInput) !void {
    const pi = &self.state.param_input;

    var values = try self.allocator.alloc([]const u8, pi.param_count);
    defer {
        for (values[0..pi.param_count]) |v| self.allocator.free(v);
        self.allocator.free(values);
    }

    for (0..pi.param_count) |i| {
        values[i] = try self.fields[i].buf.dupe();
    }

    try actions.submitParamInput(self.allocator, self.state, self.snip_store, self.cfg, self.hist, values);
}

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *ParamInput = @ptrCast(@alignCast(userdata));
    const pi = &self.state.param_input;
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;

    // Check reset in draw too, in case we haven't received an event yet
    self.checkReset();

    // Count children: title + desc + blank + cmd_line + blank + (3 per field max: label + content + spacer) + hint
    const field_rows = pi.param_count * 3;
    const child_count = 1 + 1 + 1 + 1 + 1 + field_rows + 1; // title + desc + blank + cmd + blank + fields + hint

    const children = try ctx.arena.alloc(vxfw.FlexItem, child_count);
    var idx: usize = 0;

    // ── Title: "Parameters" ──
    const snip = &self.snip_store.snippets.items[pi.snippet_idx];
    const title = try std.fmt.allocPrint(ctx.arena, "Parameters", .{});
    const title_w = try ctx.arena.create(vxfw.Text);
    title_w.* = .{ .text = title, .style = t.accentBoldStyle(accent) };
    children[idx] = .{ .widget = title_w.widget(), .flex = 0 };
    idx += 1;

    // ── Description ──
    const desc_w = try ctx.arena.create(vxfw.Text);
    desc_w.* = .{ .text = try std.fmt.allocPrint(ctx.arena, "  {s}", .{snip.desc}), .style = t.dim_style };
    children[idx] = .{ .widget = desc_w.widget(), .flex = 0 };
    idx += 1;

    // ── Blank line ──
    const blank1 = try ctx.arena.create(vxfw.Text);
    blank1.* = .{ .text = " ", .style = .{} };
    children[idx] = .{ .widget = blank1.widget(), .flex = 0 };
    idx += 1;

    // ── Command preview: "  $ {cmd}" ──
    const cmd_line = try std.fmt.allocPrint(ctx.arena, "  $ {s}", .{snip.cmd});
    const cmd_w = try ctx.arena.create(vxfw.Text);
    cmd_w.* = .{ .text = cmd_line, .style = t.accentStyle(accent) };
    children[idx] = .{ .widget = cmd_w.widget(), .flex = 0 };
    idx += 1;

    // ── Blank line ──
    const blank2 = try ctx.arena.create(vxfw.Text);
    blank2.* = .{ .text = " ", .style = .{} };
    children[idx] = .{ .widget = blank2.widget(), .flex = 0 };
    idx += 1;

    // ── Parameter fields ──
    const label_pad = 20;
    var fi: usize = 0;
    while (fi < pi.param_count) : (fi += 1) {
        const label = pi.labels[fi];
        const is_active = fi == pi.active;

        // Build label with default hint
        const default_hint: []const u8 = if (pi.defaults[fi]) |d|
            try std.fmt.allocPrint(ctx.arena, " [{s}]", .{d})
        else
            "";

        const label_with_hint = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ label, default_hint });

        const pad_after_label = if (label_pad > label_with_hint.len + 3) label_pad - label_with_hint.len - 3 else 1;
        const spaces = try ctx.arena.alloc(u8, pad_after_label);
        @memset(spaces, ' ');

        const label_str = try std.fmt.allocPrint(ctx.arena, "  {s}:{s}", .{ label_with_hint, spaces });

        if (is_active) {
            // Active field: label on one line, TextField on the next
            const label_w = try ctx.arena.create(vxfw.Text);
            label_w.* = .{ .text = label_str, .style = .{ .fg = t.accentColor(accent), .bold = true } };
            children[idx] = .{ .widget = label_w.widget(), .flex = 0 };
            idx += 1;

            self.fields[fi].style = .{ .fg = t.accentColor(accent), .bg = .{ .index = 236 } };
            const guard = try ctx.arena.create(t.FlexGuard);
            guard.* = .{ .inner = self.fields[fi].widget() };
            children[idx] = .{ .widget = guard.widget(), .flex = 0 };
        } else {
            // Inactive field: show text content as static Text
            const first = self.fields[fi].buf.firstHalf();
            const second = self.fields[fi].buf.secondHalf();
            const content = if (first.len + second.len > 0) blk: {
                const buf = try ctx.arena.alloc(u8, first.len + second.len);
                @memcpy(buf[0..first.len], first);
                @memcpy(buf[first.len..], second);
                break :blk buf;
            } else if (pi.defaults[fi] != null)
                pi.defaults[fi].?
            else
                "\xe2\x80\x94"; // em-dash for empty

            const line = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ label_str, content });
            const field_w = try ctx.arena.create(vxfw.Text);
            field_w.* = .{ .text = line, .style = t.dim_style };
            children[idx] = .{ .widget = field_w.widget(), .flex = 0 };
        }
        idx += 1;

        // Spacer between fields
        const spacer_w = try ctx.arena.create(vxfw.Text);
        spacer_w.* = .{ .text = " ", .style = .{} };
        children[idx] = .{ .widget = spacer_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Footer hints ──
    const hint_w = try ctx.arena.create(vxfw.Text);
    hint_w.* = .{ .text = "  Tab/\xe2\x86\x93: next   Shift+Tab/\xe2\x86\x91: prev   Enter: run   Esc: cancel", .style = t.dim_style };
    children[idx] = .{ .widget = hint_w.widget(), .flex = 0 };
    idx += 1;

    var col = vxfw.FlexColumn{ .children = children[0..idx] };
    const border_title = try std.fmt.allocPrint(ctx.arena, "Run: {s}", .{snip.name});
    const labels = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
    labels[0] = .{ .text = border_title, .alignment = .top_center };
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
