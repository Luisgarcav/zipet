/// WorkflowForm — two-phase form for creating workflows.
/// Phase 1 (info): 4 text fields (Name, Description, Tags, Namespace).
/// Phase 2 (steps): step list + new step editor.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const utils = @import("../utils.zig");
const actions = @import("../actions.zig");
const store_mod = @import("../../store.zig");
const unicode = @import("../unicode.zig");
const vxfw = t.vxfw;

state: *t.State,
snip_store: *store_mod.Store,
cfg: config.Config,
allocator: std.mem.Allocator,

// Info phase vxfw.TextField instances
info_fields: [4]vxfw.TextField,
info_active: usize = 0,

// Steps phase: new step text fields
step_name_field: vxfw.TextField,
step_cmd_field: vxfw.TextField,

const WorkflowFormWidget = @This();

pub fn initFields(self: *WorkflowFormWidget) void {
    for (&self.info_fields) |*f| {
        f.* = vxfw.TextField.init(self.allocator);
    }
    self.step_name_field = vxfw.TextField.init(self.allocator);
    self.step_cmd_field = vxfw.TextField.init(self.allocator);
    // Default namespace
    self.info_fields[3].insertSliceAtCursor("general") catch {};
}

pub fn deinitFields(self: *WorkflowFormWidget) void {
    for (&self.info_fields) |*f| {
        f.deinit();
    }
    self.step_name_field.deinit();
    self.step_cmd_field.deinit();
}

pub fn widget(self: *WorkflowFormWidget) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

// ── Sync helpers ──

/// Copy vxfw.TextField content back to state.wf_form.info_fields so
/// actions.submitWorkflowForm can read them without modification.
fn syncInfoToState(self: *WorkflowFormWidget) void {
    const wf = &self.state.wf_form;
    for (0..4) |i| {
        const first = self.info_fields[i].buf.firstHalf();
        const second = self.info_fields[i].buf.secondHalf();
        wf.info_fields[i].clear();
        if (first.len > 0) wf.info_fields[i].insertSlice(first);
        if (second.len > 0) wf.info_fields[i].insertSlice(second);
    }
}

/// Copy vxfw.TextField content for new step back to state.wf_form.new_step.
fn syncNewStepToState(self: *WorkflowFormWidget) void {
    const wf = &self.state.wf_form;
    // Sync name
    const name_first = self.step_name_field.buf.firstHalf();
    const name_second = self.step_name_field.buf.secondHalf();
    wf.new_step.name_len = 0;
    if (name_first.len > 0) {
        const n = @min(name_first.len, t.FIELD_CAP);
        @memcpy(wf.new_step.name[0..n], name_first[0..n]);
        wf.new_step.name_len = n;
    }
    if (name_second.len > 0) {
        const n = @min(name_second.len, t.FIELD_CAP - wf.new_step.name_len);
        @memcpy(wf.new_step.name[wf.new_step.name_len .. wf.new_step.name_len + n], name_second[0..n]);
        wf.new_step.name_len += n;
    }
    // Sync cmd
    const cmd_first = self.step_cmd_field.buf.firstHalf();
    const cmd_second = self.step_cmd_field.buf.secondHalf();
    wf.new_step.cmd_len = 0;
    if (cmd_first.len > 0) {
        const n = @min(cmd_first.len, t.FIELD_CAP);
        @memcpy(wf.new_step.cmd[0..n], cmd_first[0..n]);
        wf.new_step.cmd_len = n;
    }
    if (cmd_second.len > 0) {
        const n = @min(cmd_second.len, t.FIELD_CAP - wf.new_step.cmd_len);
        @memcpy(wf.new_step.cmd[wf.new_step.cmd_len .. wf.new_step.cmd_len + n], cmd_second[0..n]);
        wf.new_step.cmd_len += n;
    }
}

// ── Reset check ──

fn checkReset(self: *WorkflowFormWidget) void {
    const wf = &self.state.wf_form;
    if (!wf.needs_reset) return;
    wf.needs_reset = false;

    // Clear and re-populate info fields
    for (0..4) |i| {
        self.info_fields[i].clearRetainingCapacity();
    }
    self.info_active = 0;

    // Populate from state (e.g. namespace default)
    for (0..4) |i| {
        const text = wf.info_fields[i].text();
        if (text.len > 0) {
            self.info_fields[i].insertSliceAtCursor(text) catch {};
        }
    }

    // Clear step fields
    self.step_name_field.clearRetainingCapacity();
    self.step_cmd_field.clearRetainingCapacity();
}

// ── Event handling ──

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *WorkflowFormWidget = @ptrCast(@alignCast(userdata));
    const wf = &self.state.wf_form;

    // Check for reset on each event
    self.checkReset();

    switch (event) {
        .key_press => |key| {
            // ── Global keys (both phases) ──
            if (key.matches(vaxis.Key.escape, .{})) {
                if (wf.phase == .steps) {
                    wf.phase = .info;
                } else {
                    self.state.mode = .normal;
                }
                return ctx.consumeAndRedraw();
            }

            if (key.matches('s', .{ .ctrl = true })) {
                if (wf.phase == .info) {
                    // Sync info fields, validate name, move to steps phase
                    self.syncInfoToState();
                    const name = wf.info_fields[t.WorkflowFormState.F_NAME].text();
                    if (name.len == 0) {
                        wf.error_msg = "Name is required";
                        return ctx.consumeAndRedraw();
                    }
                    wf.error_msg = null;
                    wf.phase = .steps;
                } else {
                    // Steps phase: submit
                    self.syncInfoToState();
                    self.syncNewStepToState();
                    try actions.submitWorkflowForm(self.allocator, self.state, self.snip_store, self.cfg);
                }
                return ctx.consumeAndRedraw();
            }

            // ── Phase-specific handling ──
            switch (wf.phase) {
                .info => try self.handleInfoPhase(ctx, key),
                .steps => try self.handleStepsPhase(ctx, key),
            }
        },
        else => {},
    }
}

fn handleInfoPhase(self: *WorkflowFormWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
    const wf = &self.state.wf_form;

    if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.down, .{})) {
        self.info_active = (self.info_active + 1) % 4;
        return ctx.consumeAndRedraw();
    }

    if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.up, .{})) {
        self.info_active = if (self.info_active > 0) self.info_active - 1 else 3;
        return ctx.consumeAndRedraw();
    }

    if (key.matches(vaxis.Key.enter, .{})) {
        // Sync and validate name, move to steps phase
        self.syncInfoToState();
        const name = wf.info_fields[t.WorkflowFormState.F_NAME].text();
        if (name.len == 0) {
            wf.error_msg = "Name is required";
            return ctx.consumeAndRedraw();
        }
        wf.error_msg = null;
        wf.phase = .steps;
        return ctx.consumeAndRedraw();
    }

    // Forward to active vxfw.TextField
    try self.info_fields[self.info_active].handleEvent(ctx, .{ .key_press = key });
}

fn handleStepsPhase(self: *WorkflowFormWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
    const wf = &self.state.wf_form;
    if (wf.editing_new_step) {
        try self.handleNewStepEditing(ctx, key);
    } else {
        handleStepBrowsing(wf, key, ctx);
    }
}

fn handleNewStepEditing(self: *WorkflowFormWidget, ctx: *vxfw.EventContext, key: vaxis.Key) !void {
    const wf = &self.state.wf_form;

    // Tab/Down: cycle new_step_field 0-3
    if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.down, .{})) {
        wf.new_step_field = (wf.new_step_field + 1) % 4;
        return ctx.consumeAndRedraw();
    }

    // Shift+Tab/Up: cycle backwards
    if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.up, .{})) {
        wf.new_step_field = if (wf.new_step_field > 0) wf.new_step_field - 1 else 3;
        return ctx.consumeAndRedraw();
    }

    // Ctrl+L: switch to step list browsing (if steps exist)
    if (key.matches('l', .{ .ctrl = true })) {
        if (wf.step_count > 0) {
            wf.editing_new_step = false;
        }
        return ctx.consumeAndRedraw();
    }

    // Field-specific handling
    switch (wf.new_step_field) {
        0 => {
            // Name text field
            if (key.matches(vaxis.Key.enter, .{})) {
                self.syncNewStepToState();
                if (wf.addCurrentStep()) {
                    self.step_name_field.clearRetainingCapacity();
                    self.step_cmd_field.clearRetainingCapacity();
                }
                return ctx.consumeAndRedraw();
            }
            try self.step_name_field.handleEvent(ctx, .{ .key_press = key });
        },
        1 => {
            // Type toggle (cmd/snippet)
            if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
                wf.new_step.is_snippet = !wf.new_step.is_snippet;
                return ctx.consumeAndRedraw();
            }
        },
        2 => {
            // Cmd text field
            if (key.matches(vaxis.Key.enter, .{})) {
                self.syncNewStepToState();
                if (wf.addCurrentStep()) {
                    self.step_name_field.clearRetainingCapacity();
                    self.step_cmd_field.clearRetainingCapacity();
                }
                return ctx.consumeAndRedraw();
            }
            try self.step_cmd_field.handleEvent(ctx, .{ .key_press = key });
        },
        3 => {
            // On-fail toggle
            if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.space, .{})) {
                wf.new_step.on_fail = wf.new_step.on_fail.next();
                return ctx.consumeAndRedraw();
            }
        },
        else => {},
    }
}

fn handleStepBrowsing(wf: *t.WorkflowFormState, key: vaxis.Key, ctx: *vxfw.EventContext) void {
    // j/Down: next step
    if (key.matches('j', .{}) or key.matches(vaxis.Key.down, .{})) {
        if (wf.step_count > 0 and wf.step_cursor + 1 < wf.step_count) {
            wf.step_cursor += 1;
        }
        return ctx.consumeAndRedraw();
    }

    // k/Up: prev step
    if (key.matches('k', .{}) or key.matches(vaxis.Key.up, .{})) {
        if (wf.step_cursor > 0) {
            wf.step_cursor -= 1;
        }
        return ctx.consumeAndRedraw();
    }

    // d: delete step at cursor
    if (key.matches('d', .{})) {
        wf.removeStep(wf.step_cursor);
        if (wf.step_count == 0) {
            wf.editing_new_step = true;
        }
        return ctx.consumeAndRedraw();
    }

    // Tab/i/Enter: switch back to new step form
    if (key.matches(vaxis.Key.tab, .{}) or key.matches('i', .{}) or key.matches(vaxis.Key.enter, .{})) {
        wf.editing_new_step = true;
        return ctx.consumeAndRedraw();
    }
}

// ── Helper: get text from a vxfw.TextField as a contiguous slice ──

fn getTextFieldContent(field: *vxfw.TextField, arena: std.mem.Allocator) ![]const u8 {
    const first = field.buf.firstHalf();
    const second = field.buf.secondHalf();
    if (first.len + second.len == 0) return "";
    const buf = try arena.alloc(u8, first.len + second.len);
    @memcpy(buf[0..first.len], first);
    @memcpy(buf[first.len..], second);
    return buf;
}

// ── Rendering ──

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *WorkflowFormWidget = @ptrCast(@alignCast(userdata));
    const wf = &self.state.wf_form;
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;

    switch (wf.phase) {
        .info => return self.drawInfoPhase(wf, accent, width, height, ctx),
        .steps => return drawStepsPhase(self, wf, accent, width, height, ctx),
    }
}

fn drawInfoPhase(self: *WorkflowFormWidget, wf: *t.WorkflowFormState, accent: config.Color, width: u16, height: u16, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    // Count children: title + blank + (3 per field max: label + content + spacer) + optional error + hint
    const field_rows: usize = 4 * 3;
    const error_rows: usize = if (wf.error_msg != null) 1 else 0;
    const child_count = 1 + 1 + field_rows + error_rows + 1;

    const children = try ctx.arena.alloc(vxfw.FlexItem, child_count);
    var idx: usize = 0;

    // ── Title ──
    const title_w = try ctx.arena.create(vxfw.Text);
    title_w.* = .{ .text = "  Create Workflow", .style = t.accentBoldStyle(accent) };
    children[idx] = .{ .widget = title_w.widget(), .flex = 0 };
    idx += 1;

    // ── Blank line ──
    const blank_w = try ctx.arena.create(vxfw.Text);
    blank_w.* = .{ .text = " ", .style = .{} };
    children[idx] = .{ .widget = blank_w.widget(), .flex = 0 };
    idx += 1;

    // ── Fields ──
    const label_pad = 16;
    const info_labels = [_][]const u8{ "Name", "Description", "Tags", "Namespace" };

    for (0..4) |fi| {
        const label = info_labels[fi];
        const is_active = fi == self.info_active;

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

            self.info_fields[fi].style = .{ .fg = t.accentColor(accent), .bg = .{ .index = 236 } };
            const guard = try ctx.arena.create(t.FlexGuard);
            guard.* = .{ .inner = self.info_fields[fi].widget() };
            children[idx] = .{ .widget = guard.widget(), .flex = 0 };
        } else {
            // Inactive field: show text content as static Text
            const content = try getTextFieldContent(&self.info_fields[fi], ctx.arena);
            const display = if (content.len > 0) content else "\xe2\x80\x94";
            const line = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ label_str, display });
            const field_w = try ctx.arena.create(vxfw.Text);
            field_w.* = .{ .text = line, .style = t.dim_style };
            children[idx] = .{ .widget = field_w.widget(), .flex = 0 };
        }
        idx += 1;

        const spacer_w = try ctx.arena.create(vxfw.Text);
        spacer_w.* = .{ .text = " ", .style = .{} };
        children[idx] = .{ .widget = spacer_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Error message ──
    if (wf.error_msg) |emsg| {
        const err_w = try ctx.arena.create(vxfw.Text);
        err_w.* = .{ .text = emsg, .style = t.err_style };
        children[idx] = .{ .widget = err_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Footer hints ──
    const hint_w = try ctx.arena.create(vxfw.Text);
    hint_w.* = .{ .text = "  Tab: next  Enter/Ctrl+S: continue  Esc: cancel", .style = t.dim_style };
    children[idx] = .{ .widget = hint_w.widget(), .flex = 0 };
    idx += 1;

    var col = vxfw.FlexColumn{ .children = children[0..idx] };
    return col.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}

fn drawStepsPhase(self: *WorkflowFormWidget, wf: *t.WorkflowFormState, accent: config.Color, width: u16, height: u16, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    // Count children: title + blank + step_count + separator + "New Step:" header +
    // 4 sub-fields (each with spacer) + optional error + hint
    const step_rows: usize = if (wf.step_count > 0) wf.step_count else 1; // at least "No steps yet"
    const new_step_rows: usize = 4 * 3; // 4 sub-fields, max 3 items each (label + content + spacer)
    const error_rows: usize = if (wf.error_msg != null) 1 else 0;
    const child_count = 1 + 1 + step_rows + 1 + 1 + new_step_rows + error_rows + 1;

    const children = try ctx.arena.alloc(vxfw.FlexItem, child_count);
    var idx: usize = 0;

    // ── Title ──
    const title_w = try ctx.arena.create(vxfw.Text);
    title_w.* = .{ .text = "  Workflow Steps", .style = t.accentBoldStyle(accent) };
    children[idx] = .{ .widget = title_w.widget(), .flex = 0 };
    idx += 1;

    // ── Blank line ──
    const blank_w = try ctx.arena.create(vxfw.Text);
    blank_w.* = .{ .text = " ", .style = .{} };
    children[idx] = .{ .widget = blank_w.widget(), .flex = 0 };
    idx += 1;

    // ── Step list ──
    if (wf.step_count == 0) {
        const empty_w = try ctx.arena.create(vxfw.Text);
        empty_w.* = .{ .text = "  (no steps yet)", .style = t.dim_style };
        children[idx] = .{ .widget = empty_w.widget(), .flex = 0 };
        idx += 1;
    } else {
        var si: usize = 0;
        while (si < wf.step_count) : (si += 1) {
            const step = &wf.steps[si];
            const type_label: []const u8 = if (step.is_snippet) "snippet" else "cmd";
            const on_fail_label = step.on_fail.label();

            const line = try std.fmt.allocPrint(ctx.arena, "  {d}. {s} ({s}) [{s}]", .{
                si + 1,
                step.nameSlice(),
                type_label,
                on_fail_label,
            });

            const is_selected = !wf.editing_new_step and si == wf.step_cursor;
            const style: t.Style = if (is_selected)
                .{ .fg = t.accentColor(accent), .bg = .{ .index = 236 } }
            else
                .{};

            const step_w = try ctx.arena.create(vxfw.Text);
            step_w.* = .{ .text = line, .style = style };
            children[idx] = .{ .widget = step_w.widget(), .flex = 0 };
            idx += 1;
        }
    }

    // ── Separator ──
    const sep_w = try ctx.arena.create(vxfw.Text);
    sep_w.* = .{ .text = "  \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80", .style = t.dim_style };
    children[idx] = .{ .widget = sep_w.widget(), .flex = 0 };
    idx += 1;

    // ── "New Step:" header ──
    const ns_header_w = try ctx.arena.create(vxfw.Text);
    const ns_header_style: t.Style = if (wf.editing_new_step) t.accentBoldStyle(accent) else t.dim_style;
    ns_header_w.* = .{ .text = "  New Step:", .style = ns_header_style };
    children[idx] = .{ .widget = ns_header_w.widget(), .flex = 0 };
    idx += 1;

    // ── 4 sub-fields for new step ──
    const sub_labels = [_][]const u8{ "Name", "Type", "Command", "On Fail" };
    const label_pad = 14;

    var sfi: usize = 0;
    while (sfi < 4) : (sfi += 1) {
        const label = sub_labels[sfi];
        const is_active = wf.editing_new_step and sfi == wf.new_step_field;

        const pad_after = if (label_pad > label.len + 3) label_pad - label.len - 3 else 1;
        const spaces = try ctx.arena.alloc(u8, pad_after);
        @memset(spaces, ' ');
        const label_str = try std.fmt.allocPrint(ctx.arena, "    {s}:{s}", .{ label, spaces });

        // For text fields (0=name, 2=cmd): use vxfw.TextField when active, static text when inactive
        // For toggle fields (1=type, 3=on_fail): always static text
        const is_text_field = sfi == 0 or sfi == 2;

        if (is_active and is_text_field) {
            // Active text field: label on one line, TextField on the next
            const label_w = try ctx.arena.create(vxfw.Text);
            label_w.* = .{ .text = label_str, .style = .{ .fg = t.accentColor(accent), .bold = true } };
            children[idx] = .{ .widget = label_w.widget(), .flex = 0 };
            idx += 1;

            const tf: *vxfw.TextField = if (sfi == 0) &self.step_name_field else &self.step_cmd_field;
            tf.style = .{ .fg = t.accentColor(accent), .bg = .{ .index = 236 } };
            const guard = try ctx.arena.create(t.FlexGuard);
            guard.* = .{ .inner = tf.widget() };
            children[idx] = .{ .widget = guard.widget(), .flex = 0 };
        } else {
            // Static text rendering
            const content: []const u8 = switch (sfi) {
                0 => blk: {
                    const s = try getTextFieldContent(&self.step_name_field, ctx.arena);
                    break :blk if (s.len > 0) s else if (!is_active) "\xe2\x80\x94" else " ";
                },
                1 => if (wf.new_step.is_snippet) "snippet" else "cmd",
                2 => blk: {
                    const s = try getTextFieldContent(&self.step_cmd_field, ctx.arena);
                    break :blk if (s.len > 0) s else if (!is_active) "\xe2\x80\x94" else " ";
                },
                3 => wf.new_step.on_fail.label(),
                else => "",
            };

            const line = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ label_str, content });

            const style: t.Style = if (is_active)
                .{ .fg = t.accentColor(accent), .bg = .{ .index = 236 } }
            else
                t.dim_style;

            const field_w = try ctx.arena.create(vxfw.Text);
            field_w.* = .{ .text = line, .style = style };
            children[idx] = .{ .widget = field_w.widget(), .flex = 0 };
        }
        idx += 1;

        const spacer_w = try ctx.arena.create(vxfw.Text);
        spacer_w.* = .{ .text = " ", .style = .{} };
        children[idx] = .{ .widget = spacer_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Error message ──
    if (wf.error_msg) |emsg| {
        const err_w = try ctx.arena.create(vxfw.Text);
        err_w.* = .{ .text = emsg, .style = t.err_style };
        children[idx] = .{ .widget = err_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Footer hints ──
    const hint_w = try ctx.arena.create(vxfw.Text);
    hint_w.* = .{ .text = "  Tab: next  Enter: add step  Ctrl+S: save  Ctrl+L: browse  Esc: back", .style = t.dim_style };
    children[idx] = .{ .widget = hint_w.widget(), .flex = 0 };
    idx += 1;

    var col = vxfw.FlexColumn{ .children = children[0..idx] };
    return col.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}
