/// WorkflowRunner — displays a running workflow's progress with pipeline view,
/// live output, and keyboard controls.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const vxfw = t.vxfw;

const WorkflowRunner = @This();

state: *t.State,
cfg: config.Config,
scroll_offset: usize = 0,

const StepStatus = enum { pending, running, completed, failed, skipped };

const StepDisplay = struct {
    name: []const u8,
    status: StepStatus,
    duration_ms: u64,
    exit_code: u8,
};

pub fn widget(self: *WorkflowRunner) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *WorkflowRunner = @ptrCast(@alignCast(userdata));

    switch (event) {
        .key_press => |key| {
            if (key.matches('q', .{})) {
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }
            if (key.matches('r', .{})) {
                self.state.wf_runner.user_response = 'r';
                return ctx.consumeAndRedraw();
            }
            if (key.matches('s', .{})) {
                self.state.wf_runner.user_response = 's';
                return ctx.consumeAndRedraw();
            }
            if (key.matches('c', .{}) or key.matches('a', .{})) {
                self.state.wf_runner.user_response = 'a';
                return ctx.consumeAndRedraw();
            }
            if (key.matches('y', .{})) {
                self.state.wf_runner.user_response = 'y';
                return ctx.consumeAndRedraw();
            }
            if (key.matches('n', .{})) {
                self.state.wf_runner.user_response = 'n';
                return ctx.consumeAndRedraw();
            }
            if (key.matches('j', .{})) {
                self.scroll_offset +|= 1;
                return ctx.consumeAndRedraw();
            }
            if (key.matches('k', .{})) {
                if (self.scroll_offset > 0) self.scroll_offset -= 1;
                return ctx.consumeAndRedraw();
            }
        },
        else => {},
    }
}

/// Build step display info by processing workflow events (thread-safe).
fn buildStepDisplays(self: *const WorkflowRunner, arena: std.mem.Allocator) std.mem.Allocator.Error![]StepDisplay {
    const runner = &self.state.wf_runner;
    const total = runner.total_steps;
    if (total == 0) return &.{};

    const steps = try arena.alloc(StepDisplay, total);
    // Initialize all as pending
    for (0..total) |i| {
        steps[i] = .{
            .name = "",
            .status = .pending,
            .duration_ms = 0,
            .exit_code = 0,
        };
    }

    // Lock mutex to safely read events from the engine thread
    const mutex = &@constCast(&self.state.wf_runner).mutex;
    mutex.lock();
    defer mutex.unlock();

    // Process events to update statuses
    for (runner.events.items) |ev| {
        switch (ev) {
            .step_started => |info| {
                if (info.index < total) {
                    steps[info.index].name = info.name;
                    steps[info.index].status = .running;
                }
            },
            .step_completed => |info| {
                if (info.index < total) {
                    steps[info.index].name = info.name;
                    steps[info.index].status = .completed;
                    steps[info.index].duration_ms = info.duration_ms;
                    steps[info.index].exit_code = info.exit_code;
                }
            },
            .step_failed => |info| {
                if (info.index < total) {
                    steps[info.index].name = info.name;
                    steps[info.index].status = .failed;
                    steps[info.index].duration_ms = info.duration_ms;
                    steps[info.index].exit_code = info.exit_code;
                }
            },
            .step_skipped => |info| {
                if (info.index < total) {
                    steps[info.index].name = info.name;
                    steps[info.index].status = .skipped;
                }
            },
            else => {},
        }
    }

    return steps;
}

/// Collect output lines from events (thread-safe).
fn collectOutputLines(self: *const WorkflowRunner, arena: std.mem.Allocator) std.mem.Allocator.Error![]const OutputEntry {
    const runner = &self.state.wf_runner;
    const mutex = &@constCast(&self.state.wf_runner).mutex;
    mutex.lock();
    defer mutex.unlock();

    var lines: std.ArrayListUnmanaged(OutputEntry) = .{};
    for (runner.events.items) |ev| {
        switch (ev) {
            .output_line => |info| {
                try lines.append(arena, .{ .text = info.text, .is_stderr = info.is_stderr });
            },
            else => {},
        }
    }
    return lines.items;
}

const OutputEntry = struct {
    text: []const u8,
    is_stderr: bool,
};

/// Get prompt message if there's a pending confirm/ask (thread-safe).
fn getPromptMessage(self: *const WorkflowRunner) ?[]const u8 {
    const runner = &self.state.wf_runner;
    const mutex = &@constCast(&self.state.wf_runner).mutex;
    mutex.lock();
    defer mutex.unlock();

    // Walk events backwards to find latest prompt
    var i = runner.events.items.len;
    while (i > 0) {
        i -= 1;
        switch (runner.events.items[i]) {
            .confirm_requested => return "Confirm step? [y]es / [n]o / [c]ancel",
            .ask_requested => return "Step failed. [r]etry / [s]kip / [a]bort?",
            .workflow_done => return null, // workflow finished, no prompt
            .step_started => return null, // a step started after prompt, means it was answered
            else => {},
        }
    }
    return null;
}

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *WorkflowRunner = @ptrCast(@alignCast(userdata));
    const runner = &self.state.wf_runner;
    const accent = self.cfg.accent_color;

    const steps = try self.buildStepDisplays(ctx.arena);
    const output_lines = try self.collectOutputLines(ctx.arena);
    const prompt = self.getPromptMessage();

    // Calculate flex item count: title + steps + blank + output_title + output lines + controls
    // Use FlexColumn with: title(1) + pipeline steps + blank + output section (flex=1) + controls(1)
    const pipeline_count = steps.len;

    // Build flex items
    var items = std.ArrayListUnmanaged(vxfw.FlexItem){};

    // ── Title ──
    const title_str = try std.fmt.allocPrint(ctx.arena, " Workflow: {s}", .{
        if (runner.workflow_name.len > 0) runner.workflow_name else "(unnamed)",
    });
    const title_w = try ctx.arena.create(vxfw.Text);
    title_w.* = .{ .text = title_str, .style = t.accentBoldStyle(accent) };
    try items.append(ctx.arena, .{ .widget = title_w.widget(), .flex = 0 });

    // ── Blank separator ──
    const blank1 = try ctx.arena.create(vxfw.Text);
    blank1.* = .{ .text = " ", .style = .{} };
    try items.append(ctx.arena, .{ .widget = blank1.widget(), .flex = 0 });

    // ── Pipeline steps ──
    for (0..pipeline_count) |i| {
        const step = steps[i];
        const line = try formatStepLine(ctx.arena, step, i);
        const style = stepStyle(step.status);
        const step_w = try ctx.arena.create(vxfw.Text);
        step_w.* = .{ .text = line, .style = style };
        try items.append(ctx.arena, .{ .widget = step_w.widget(), .flex = 0 });
    }

    // ── Blank separator ──
    const blank2 = try ctx.arena.create(vxfw.Text);
    blank2.* = .{ .text = " ", .style = .{} };
    try items.append(ctx.arena, .{ .widget = blank2.widget(), .flex = 0 });

    // ── Output header ──
    const out_header = try ctx.arena.create(vxfw.Text);
    out_header.* = .{ .text = " Output:", .style = t.header_style };
    try items.append(ctx.arena, .{ .widget = out_header.widget(), .flex = 0 });

    // ── Output lines (use ScrollView for flex=1 portion) ──
    const out_texts = try ctx.arena.alloc(vxfw.Text, output_lines.len);
    const out_widgets = try ctx.arena.alloc(vxfw.Widget, output_lines.len);

    // Apply scroll offset
    const visible_start = @min(self.scroll_offset, if (output_lines.len > 0) output_lines.len - 1 else 0);
    _ = visible_start;

    for (output_lines, 0..) |ol, i| {
        const style: t.Style = if (ol.is_stderr) t.err_style else .{};
        out_texts[i] = .{
            .text = if (ol.text.len > 0) ol.text else " ",
            .style = style,
        };
        out_widgets[i] = out_texts[i].widget();
    }

    // Use a ScrollView for output
    const sv = try ctx.arena.create(vxfw.ScrollView);
    sv.* = .{ .children = .{ .slice = out_widgets } };
    // Scroll to bottom to show latest output
    if (output_lines.len > 0) {
        _ = sv.scroll.linesDown(@intCast(@min(output_lines.len, 255)));
    }

    const sv_guard = try ctx.arena.create(t.ScrollViewGuard);
    sv_guard.* = .{ .inner = sv };
    try items.append(ctx.arena, .{ .widget = sv_guard.widget(), .flex = 1 });

    // ── Prompt line (if any) ──
    if (prompt) |p| {
        const prompt_w = try ctx.arena.create(vxfw.Text);
        prompt_w.* = .{ .text = p, .style = t.Style{ .fg = .{ .index = 3 }, .bold = true } };
        try items.append(ctx.arena, .{ .widget = prompt_w.widget(), .flex = 0 });
    }

    // ── Controls bar ──
    const controls_str = if (runner.is_running)
        " [r] retry  [s] skip  [c] cancel  [q] quit  [j/k] scroll"
    else
        " Workflow finished. [q] quit  [j/k] scroll";
    const controls_w = try ctx.arena.create(vxfw.Text);
    controls_w.* = .{ .text = controls_str, .style = t.dim_style };
    try items.append(ctx.arena, .{ .widget = controls_w.widget(), .flex = 0 });

    // ── Assemble FlexColumn in Border ──
    const flex_children = try items.toOwnedSlice(ctx.arena);
    var col = vxfw.FlexColumn{ .children = flex_children };

    const label = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
    label[0] = .{ .text = "Workflow Runner", .alignment = .top_center };
    var border = vxfw.Border{
        .child = col.widget(),
        .style = t.accentStyle(accent),
        .labels = label,
    };
    return border.widget().draw(ctx);
}

fn formatStepLine(arena: std.mem.Allocator, step: StepDisplay, index: usize) std.mem.Allocator.Error![]const u8 {
    const icon = stepIcon(step.status);
    const name = if (step.name.len > 0) step.name else try std.fmt.allocPrint(arena, "step {d}", .{index + 1});
    const status_text = switch (step.status) {
        .pending => "pending",
        .running => "running...",
        .completed => try std.fmt.allocPrint(arena, "ok ({d}.{d}s)", .{ step.duration_ms / 1000, (step.duration_ms % 1000) / 100 }),
        .failed => try std.fmt.allocPrint(arena, "FAIL (exit {d})", .{step.exit_code}),
        .skipped => "skipped",
    };

    // Build dotted line between name and status
    const name_len = name.len;
    const status_len = status_text.len;
    const icon_len: usize = 2; // icon + space
    const min_line_len: usize = 40;
    const used = icon_len + name_len + 1 + status_len; // icon + name + space + status
    const dots_len = if (min_line_len > used) min_line_len - used else 2;

    const dots = try arena.alloc(u8, dots_len);
    @memset(dots, '.');

    return try std.fmt.allocPrint(arena, " {s} {s} {s} {s}", .{ icon, name, dots, status_text });
}

fn stepIcon(status: StepStatus) []const u8 {
    return switch (status) {
        .pending => "○",
        .running => "●",
        .completed => "✓",
        .failed => "✗",
        .skipped => "⊘",
    };
}

fn stepStyle(status: StepStatus) t.Style {
    return switch (status) {
        .pending => t.dim_style,
        .running => .{ .fg = .{ .index = 3 }, .bold = true }, // yellow
        .completed => .{ .fg = .{ .index = 2 } }, // green
        .failed => .{ .fg = .{ .index = 1 }, .bold = true }, // red
        .skipped => t.dim_style,
    };
}
