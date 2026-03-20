/// FormScreen — add/edit/paste snippet form.
/// Uses vxfw.TextField instances for text input and passes values to actions.submitForm().
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const actions = @import("../actions.zig");
const store_mod = @import("../../store.zig");
const history_mod = @import("../../history.zig");
const vxfw = t.vxfw;

const FormScreen = @This();

pub const MAX_FIELDS = 5;
pub const F_NAME = 0;
pub const F_DESC = 1;
pub const F_CMD = 2;
pub const F_TAGS = 3;
pub const F_NS = 4;

state: *t.State,
snip_store: *store_mod.Store,
hist: *history_mod.History,
cfg: config.Config,
allocator: std.mem.Allocator,

fields: [MAX_FIELDS]vxfw.TextField,
active_field: usize = 0,
labels: [MAX_FIELDS][]const u8 = .{ "Name", "Description", "Command", "Tags", "Namespace" },
error_msg: ?[]const u8 = null,
purpose: t.FormPurpose = .add,
editing_snip_idx: ?usize = null,

pub fn initFields(self: *FormScreen) void {
    for (&self.fields) |*f| {
        f.* = vxfw.TextField.init(self.allocator);
    }
    // Default namespace
    self.fields[F_NS].insertSliceAtCursor("general") catch {};
}

pub fn deinitFields(self: *FormScreen) void {
    for (&self.fields) |*f| {
        f.deinit();
    }
}

pub fn widget(self: *FormScreen) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

// ── Reset / Populate ──

fn clearField(self: *FormScreen, idx: usize) void {
    self.fields[idx].clearRetainingCapacity();
}

pub fn reset(self: *FormScreen, purpose: t.FormPurpose) void {
    for (0..MAX_FIELDS) |i| {
        self.clearField(i);
    }
    self.active_field = 0;
    self.error_msg = null;
    self.purpose = purpose;
    self.editing_snip_idx = null;
    // Set default namespace
    self.fields[F_NS].insertSliceAtCursor("general") catch {};
}

pub fn populateForEdit(self: *FormScreen, snip: *const store_mod.Snippet) void {
    // Clear all fields first
    for (0..MAX_FIELDS) |i| {
        self.clearField(i);
    }
    self.fields[F_NAME].insertSliceAtCursor(snip.name) catch {};
    self.fields[F_DESC].insertSliceAtCursor(snip.desc) catch {};
    self.fields[F_CMD].insertSliceAtCursor(snip.cmd) catch {};

    // Join tags with commas
    var tags_joined: [512]u8 = undefined;
    var tl: usize = 0;
    for (snip.tags, 0..) |tag, ti| {
        if (ti > 0 and tl < 510) {
            tags_joined[tl] = ',';
            tl += 1;
        }
        const copy_len = @min(tag.len, 512 - tl);
        @memcpy(tags_joined[tl .. tl + copy_len], tag[0..copy_len]);
        tl += copy_len;
    }
    self.fields[F_TAGS].insertSliceAtCursor(tags_joined[0..tl]) catch {};
    self.fields[F_NS].insertSliceAtCursor(snip.namespace) catch {};
}

pub fn populateCmd(self: *FormScreen, cmd_text: []const u8) void {
    self.clearField(F_CMD);
    self.fields[F_CMD].insertSliceAtCursor(cmd_text) catch {};
}

// ── Read field text ──

fn getFieldSlice(self: *FormScreen, idx: usize) ![]const u8 {
    return self.fields[idx].buf.dupe();
}

// ── Event handling ──

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *FormScreen = @ptrCast(@alignCast(userdata));

    // Check if FormState signals a reset is needed
    self.checkReset();

    switch (event) {
        .key_press => |key| {
            if (key.matches(vaxis.Key.escape, .{})) {
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }

            if (key.matches('s', .{ .ctrl = true })) {
                try self.handleSubmit();
                return ctx.consumeAndRedraw();
            }

            // Enter on non-Command fields submits; on Command field, let TextField handle it
            // Actually, Enter always submits in form mode (single-line fields)
            if (key.matches(vaxis.Key.enter, .{})) {
                try self.handleSubmit();
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.down, .{})) {
                if (self.active_field + 1 < MAX_FIELDS) self.active_field += 1 else self.active_field = 0;
                return ctx.consumeAndRedraw();
            }

            if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.up, .{})) {
                if (self.active_field > 0) self.active_field -= 1 else self.active_field = MAX_FIELDS - 1;
                return ctx.consumeAndRedraw();
            }

            // Forward to active TextField
            try self.fields[self.active_field].handleEvent(ctx, .{ .key_press = key });
            return;
        },
        else => {},
    }
}

fn checkReset(self: *FormScreen) void {
    const f = &self.state.form;
    if (!f.needs_reset) return;
    f.needs_reset = false;

    self.reset(f.purpose);
    self.editing_snip_idx = f.editing_snip_idx;

    if (f.purpose == .edit) {
        if (f.editing_snip_idx) |si| {
            if (si < self.snip_store.snippets.items.len) {
                const snip = &self.snip_store.snippets.items[si];
                self.populateForEdit(snip);
            }
        }
    } else if (f.purpose == .paste) {
        if (f.paste_cmd_cache) |cmd_text| {
            self.populateCmd(cmd_text);
            self.allocator.free(cmd_text);
            f.paste_cmd_cache = null;
        }
    }
}

fn handleSubmit(self: *FormScreen) !void {
    const name = try self.getFieldSlice(F_NAME);
    defer self.allocator.free(name);
    const desc = try self.getFieldSlice(F_DESC);
    defer self.allocator.free(desc);
    const cmd = try self.getFieldSlice(F_CMD);
    defer self.allocator.free(cmd);
    const tags = try self.getFieldSlice(F_TAGS);
    defer self.allocator.free(tags);
    const ns = try self.getFieldSlice(F_NS);
    defer self.allocator.free(ns);

    const err = actions.submitForm(self.allocator, self.state, self.snip_store, self.hist, .{
        .name = name,
        .desc = desc,
        .cmd = cmd,
        .tags_str = tags,
        .namespace = ns,
        .purpose = self.purpose,
        .editing_snip_idx = self.editing_snip_idx,
    });
    if (err) |msg| {
        self.error_msg = msg;
    } else {
        self.error_msg = null;
    }
}

// ── Rendering ──

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *FormScreen = @ptrCast(@alignCast(userdata));
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;

    // Count children: title + blank + (3 per field max: label + content + spacer) + optional error + hint
    const field_rows = MAX_FIELDS * 3;
    const error_rows: usize = if (self.error_msg != null) 1 else 0;
    const child_count = 1 + 1 + field_rows + error_rows + 1;

    const children = try ctx.arena.alloc(vxfw.FlexItem, child_count);
    var idx: usize = 0;

    // ── Title ──
    const title: []const u8 = switch (self.purpose) {
        .add => "  Add Snippet",
        .edit => "  Edit Snippet",
        .paste => "  Paste as Snippet",
    };
    const title_w = try ctx.arena.create(vxfw.Text);
    title_w.* = .{ .text = title, .style = t.accentBoldStyle(accent) };
    children[idx] = .{ .widget = title_w.widget(), .flex = 0 };
    idx += 1;

    // ── Blank line ──
    const blank_w = try ctx.arena.create(vxfw.Text);
    blank_w.* = .{ .text = " ", .style = .{} };
    children[idx] = .{ .widget = blank_w.widget(), .flex = 0 };
    idx += 1;

    // ── Fields ──
    const label_pad = 16;
    for (0..MAX_FIELDS) |fi| {
        const label = self.labels[fi];
        const is_active = fi == self.active_field;

        // Build label prefix: "  Label:    "
        const pad_after_label = if (label_pad > label.len + 3) label_pad - label.len - 3 else 1;
        const spaces = try ctx.arena.alloc(u8, pad_after_label);
        @memset(spaces, ' ');
        const label_str = try std.fmt.allocPrint(ctx.arena, "  {s}:{s}", .{ label, spaces });

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
            } else "\xe2\x80\x94"; // em-dash for empty

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

    // ── Error message ──
    if (self.error_msg) |emsg| {
        const err_w = try ctx.arena.create(vxfw.Text);
        err_w.* = .{ .text = emsg, .style = t.err_style };
        children[idx] = .{ .widget = err_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Footer hints ──
    const hint_w = try ctx.arena.create(vxfw.Text);
    hint_w.* = .{ .text = "  Tab/\xe2\x86\x93: next field   Shift+Tab/\xe2\x86\x91: prev   Ctrl+S: save   Esc: cancel", .style = t.dim_style };
    children[idx] = .{ .widget = hint_w.widget(), .flex = 0 };
    idx += 1;

    var col = vxfw.FlexColumn{ .children = children[0..idx] };
    const border_label: []const u8 = switch (self.purpose) {
        .add => "Add Snippet",
        .edit => "Edit Snippet",
        .paste => "Paste as Snippet",
    };
    const border_labels = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
    border_labels[0] = .{ .text = border_label, .alignment = .top_center };
    var border = vxfw.Border{
        .child = col.widget(),
        .style = t.dim_style,
        .labels = border_labels,
    };
    return border.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}
