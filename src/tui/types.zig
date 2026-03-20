/// TUI types, state, and style definitions for zipet.
const std = @import("std");
const vaxis = @import("vaxis");
pub const vxfw = vaxis.vxfw;
const config = @import("../config.zig");
const workspace_mod = @import("../workspace.zig");
const pack_mod = @import("../pack.zig");
const unicode = @import("unicode.zig");

pub const Cell = vaxis.Cell;
pub const Key = vaxis.Key;
pub const Style = Cell.Style;
pub const Color = Cell.Color;
pub const Segment = Cell.Segment;
pub const Window = vaxis.Window;

// ── Event type ──
pub const Event = union(enum) {
    key_press: Key,
    winsize: vaxis.Winsize,
    focus_in,
    focus_out,
};

// ── Modes ──
pub const Mode = enum {
    normal,
    search,
    command,
    help,
    confirm_delete,
    confirm_delete_multi,
    tag_picker,
    info,
    form,
    param_input,
    output_view,
    workspace_picker,
    pack_browser,
    pack_search,
    pack_preview,
    workflow_form,
    workflow_runner,
};

// ── Text Field ──
pub const FIELD_CAP = 1024;

pub const TextField = struct {
    buf: [FIELD_CAP]u8 = [_]u8{0} ** FIELD_CAP,
    len: usize = 0,
    cursor: usize = 0,

    pub fn text(self: *const TextField) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn setText(self: *TextField, s: []const u8) void {
        const n = @min(s.len, FIELD_CAP);
        @memcpy(self.buf[0..n], s[0..n]);
        self.len = n;
        self.cursor = n;
    }

    pub fn clear(self: *TextField) void {
        self.len = 0;
        self.cursor = 0;
    }

    /// Insert a single ASCII character at cursor position.
    pub fn insertChar(self: *TextField, c: u8) void {
        self.insertSlice(&.{c});
    }

    /// Insert a UTF-8 encoded slice at cursor position.
    pub fn insertSlice(self: *TextField, bytes: []const u8) void {
        if (bytes.len == 0) return;
        if (self.len + bytes.len > FIELD_CAP - 1) return;
        // Shift existing bytes to the right
        if (self.cursor < self.len) {
            var i = self.len + bytes.len - 1;
            while (i >= self.cursor + bytes.len) : (i -= 1) {
                self.buf[i] = self.buf[i - bytes.len];
                if (i == 0) break;
            }
        }
        // Copy new bytes in
        @memcpy(self.buf[self.cursor .. self.cursor + bytes.len], bytes);
        self.len += bytes.len;
        self.cursor += bytes.len;
    }

    /// Delete the UTF-8 codepoint before the cursor.
    pub fn backspace(self: *TextField) void {
        if (self.cursor == 0) return;
        const prev = unicode.prevCodepointStart(self.buf[0..self.len], self.cursor);
        const del_len = self.cursor - prev;
        // Shift bytes left
        var i = prev;
        while (i + del_len < self.len) : (i += 1) {
            self.buf[i] = self.buf[i + del_len];
        }
        self.len -= del_len;
        self.cursor = prev;
    }

    /// Delete the UTF-8 codepoint at the cursor.
    pub fn deleteForward(self: *TextField) void {
        if (self.cursor >= self.len) return;
        const next = unicode.nextCodepointEnd(self.buf[0..self.len], self.cursor);
        const del_len = next - self.cursor;
        var i = self.cursor;
        while (i + del_len < self.len) : (i += 1) {
            self.buf[i] = self.buf[i + del_len];
        }
        self.len -= del_len;
    }

    /// Move cursor one codepoint to the left.
    pub fn moveLeft(self: *TextField) void {
        self.cursor = unicode.prevCodepointStart(self.buf[0..self.len], self.cursor);
    }

    /// Move cursor one codepoint to the right.
    pub fn moveRight(self: *TextField) void {
        self.cursor = unicode.nextCodepointEnd(self.buf[0..self.len], self.cursor);
    }

    pub fn moveHome(self: *TextField) void {
        self.cursor = 0;
    }

    pub fn moveEnd(self: *TextField) void {
        self.cursor = self.len;
    }
};

// ── Form state ──
pub const MAX_FORM_FIELDS = 6;

pub const FormPurpose = enum { add, edit, paste };

pub const FormState = struct {
    fields: [MAX_FORM_FIELDS]TextField = [_]TextField{.{}} ** MAX_FORM_FIELDS,
    labels: [MAX_FORM_FIELDS][]const u8 = [_][]const u8{""} ** MAX_FORM_FIELDS,
    field_count: usize = 0,
    active: usize = 0,
    purpose: FormPurpose = .add,
    editing_snip_idx: ?usize = null,
    error_msg: ?[]const u8 = null,
    needs_reset: bool = false,
    /// Cached clipboard text for paste mode (freed by FormScreen after populating fields).
    paste_cmd_cache: ?[]const u8 = null,

    pub const F_NAME = 0;
    pub const F_DESC = 1;
    pub const F_CMD = 2;
    pub const F_TAGS = 3;
    pub const F_NS = 4;

    pub fn init(purpose: FormPurpose) FormState {
        var f = FormState{};
        f.purpose = purpose;
        f.needs_reset = true;
        f.field_count = 5;
        f.labels = .{ "Name", "Description", "Command", "Tags", "Namespace", "" };
        f.fields[F_NS].setText("general");
        return f;
    }

    pub fn activeField(self: *FormState) *TextField {
        return &self.fields[self.active];
    }
};

// ── Param input state ──
pub const MAX_PARAMS = 16;

pub const ParamInputState = struct {
    fields: [MAX_PARAMS]TextField = [_]TextField{.{}} ** MAX_PARAMS,
    labels: [MAX_PARAMS][]const u8 = [_][]const u8{""} ** MAX_PARAMS,
    defaults: [MAX_PARAMS]?[]const u8 = [_]?[]const u8{null} ** MAX_PARAMS,
    param_count: usize = 0,
    active: usize = 0,
    snippet_idx: usize = 0,
    is_workflow: bool = false,
    rendered_cmd: ?[]const u8 = null,
    needs_reset: bool = false,

    pub fn activeField(self: *ParamInputState) *TextField {
        return &self.fields[self.active];
    }
};

// ── Workflow form state ──
pub const WF_MAX_STEPS = 20;

pub const WorkflowFormPhase = enum { info, steps };

pub const OnFailOption = enum {
    stop,
    @"continue",
    skip_rest,
    ask,

    pub fn label(self: OnFailOption) []const u8 {
        return switch (self) {
            .stop => "stop",
            .@"continue" => "continue",
            .skip_rest => "skip_rest",
            .ask => "ask",
        };
    }

    pub fn next(self: OnFailOption) OnFailOption {
        return switch (self) {
            .stop => .@"continue",
            .@"continue" => .skip_rest,
            .skip_rest => .ask,
            .ask => .stop,
        };
    }
};

pub const StepEntry = struct {
    name: [FIELD_CAP]u8 = [_]u8{0} ** FIELD_CAP,
    name_len: usize = 0,
    is_snippet: bool = false,
    cmd: [FIELD_CAP]u8 = [_]u8{0} ** FIELD_CAP,
    cmd_len: usize = 0,
    on_fail: OnFailOption = .stop,

    pub fn nameSlice(self: *const StepEntry) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn cmdSlice(self: *const StepEntry) []const u8 {
        return self.cmd[0..self.cmd_len];
    }

    pub fn setName(self: *StepEntry, s: []const u8) void {
        const n = @min(s.len, FIELD_CAP);
        @memcpy(self.name[0..n], s[0..n]);
        self.name_len = n;
    }

    pub fn setCmd(self: *StepEntry, s: []const u8) void {
        const n = @min(s.len, FIELD_CAP);
        @memcpy(self.cmd[0..n], s[0..n]);
        self.cmd_len = n;
    }
};

pub const WorkflowFormState = struct {
    pub const F_NAME = 0;
    pub const F_DESC = 1;
    pub const F_TAGS = 2;
    pub const F_NS = 3;

    phase: WorkflowFormPhase = .info,

    // Info phase fields (reuse TextField)
    info_fields: [4]TextField = [_]TextField{.{}} ** 4,
    info_labels: [4][]const u8 = .{ "Name", "Description", "Tags", "Namespace" },
    info_active: usize = 0,
    error_msg: ?[]const u8 = null,

    // Steps phase
    steps: [WF_MAX_STEPS]StepEntry = [_]StepEntry{.{}} ** WF_MAX_STEPS,
    step_count: usize = 0,
    step_cursor: usize = 0, // which step is selected in the list
    step_scroll: usize = 0,

    // Current step being edited (the "new step" form at the bottom)
    new_step: StepEntry = .{},
    /// 0=name, 1=type toggle, 2=cmd/snippet, 3=on_fail toggle
    new_step_field: usize = 0,

    // Whether we're editing the new step fields or browsing the step list
    editing_new_step: bool = true,

    // Reset flag: when true, WorkflowFormWidget should re-populate its vxfw.TextFields
    needs_reset: bool = false,

    pub fn init() WorkflowFormState {
        var s = WorkflowFormState{};
        s.info_fields[F_NS].setText("general");
        s.needs_reset = true;
        return s;
    }

    pub fn activeInfoField(self: *WorkflowFormState) *TextField {
        return &self.info_fields[self.info_active];
    }

    pub fn addCurrentStep(self: *WorkflowFormState) bool {
        if (self.step_count >= WF_MAX_STEPS) return false;
        if (self.new_step.name_len == 0) return false;
        if (self.new_step.cmd_len == 0) return false;

        self.steps[self.step_count] = self.new_step;
        self.step_count += 1;
        self.new_step = .{};
        self.new_step_field = 0;
        return true;
    }

    pub fn removeStep(self: *WorkflowFormState, idx: usize) void {
        if (idx >= self.step_count) return;
        var i = idx;
        while (i + 1 < self.step_count) : (i += 1) {
            self.steps[i] = self.steps[i + 1];
        }
        self.step_count -= 1;
        if (self.step_cursor > 0 and self.step_cursor >= self.step_count) {
            self.step_cursor = if (self.step_count > 0) self.step_count - 1 else 0;
        }
    }
};

// ── Output line style ──
pub const LineStyle = enum { normal, header, dim, success, err, cmd };

// ── Output buffer that stores styled lines ──
pub const OutputBuf = struct {
    alloc: std.mem.Allocator,
    lines: std.ArrayList(StyledLine),

    pub const StyledLine = struct {
        text: []const u8,
        style: LineStyle,
    };

    pub fn init(alloc: std.mem.Allocator) OutputBuf {
        return .{ .alloc = alloc, .lines = .{} };
    }

    pub fn deinit(self: *OutputBuf) void {
        for (self.lines.items) |line| self.alloc.free(line.text);
        self.lines.deinit(self.alloc);
    }

    pub fn add(self: *OutputBuf, t: []const u8, style: LineStyle) void {
        const owned = self.alloc.dupe(u8, t) catch return;
        self.lines.append(self.alloc, .{ .text = owned, .style = style }) catch {
            self.alloc.free(owned);
        };
    }

    pub fn addFmt(self: *OutputBuf, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype, style: LineStyle) void {
        const t = std.fmt.allocPrint(alloc, fmt, args) catch return;
        self.lines.append(self.alloc, .{ .text = t, .style = style }) catch {
            alloc.free(t);
        };
    }

    pub fn addMultiline(self: *OutputBuf, t: []const u8, style: LineStyle) void {
        var iter = std.mem.splitScalar(u8, t, '\n');
        while (iter.next()) |line| {
            if (line.len > 0 or iter.peek() != null) {
                self.add(line, style);
            }
        }
    }
};

// ── Workflow event system ──
pub const WorkflowEvent = union(enum) {
    step_started: StepEventInfo,
    step_completed: StepCompletedInfo,
    step_failed: StepCompletedInfo,
    step_skipped: StepSkippedInfo,
    confirm_requested: StepEventInfo,
    ask_requested: StepFailedAskInfo,
    retry_started: RetryInfo,
    workflow_done: WorkflowDoneInfo,
    output_line: OutputLineInfo,

    pub const StepEventInfo = struct {
        name: []const u8,
        index: usize,
    };
    pub const StepCompletedInfo = struct {
        name: []const u8,
        index: usize,
        exit_code: u8,
        duration_ms: u64,
    };
    pub const StepSkippedInfo = struct {
        name: []const u8,
        index: usize,
        reason: []const u8,
    };
    pub const StepFailedAskInfo = struct {
        name: []const u8,
        index: usize,
        exit_code: u8,
    };
    pub const RetryInfo = struct {
        name: []const u8,
        index: usize,
        attempt: u8,
        max_attempts: u8,
    };
    pub const WorkflowDoneInfo = struct {
        success: bool,
    };
    pub const OutputLineInfo = struct {
        text: []const u8,
        is_stderr: bool,
    };
};

pub const WorkflowRunnerState = struct {
    workflow_name: []const u8 = "",
    total_steps: usize = 0,
    events: std.ArrayListUnmanaged(WorkflowEvent) = .{},
    mutex: std.Thread.Mutex = .{},
    user_response: ?u8 = null,
    is_running: bool = false,
    engine_thread: ?std.Thread = null,

    pub fn deinit(self: *WorkflowRunnerState, alloc: std.mem.Allocator) void {
        self.events.deinit(alloc);
    }
};

// ── Main state ──
pub const State = struct {
    mode: Mode = .normal,
    cursor: usize = 0,
    search_buf: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    command_buf: [256]u8 = [_]u8{0} ** 256,
    command_len: usize = 0,
    preview_visible: bool = true,
    preview_popup: bool = false,
    running: bool = true,
    filtered_indices: []usize = &.{},
    message: ?[]const u8 = null,
    pending_g: bool = false,
    tag_list: []const []const u8 = &.{},
    tag_cursor: usize = 0,
    active_tag_filter: ?[]const u8 = null,

    // Multi-select state
    selected_set: std.AutoHashMap(usize, void) = undefined,
    selected_set_inited: bool = false,

    // Sub-states
    form: FormState = .{},
    param_input: ParamInputState = .{},
    wf_form: WorkflowFormState = .{},
    output: OutputBuf = undefined,
    output_title: ?[]const u8 = null,

    // Workspace state
    active_workspace: ?[]const u8 = null,
    ws_list: []workspace_mod.Workspace = &.{},
    ws_cursor: usize = 0,
    ws_loaded: bool = false,

    // Pack browser state
    pack_list: []pack_mod.PackMeta = &.{},
    pack_cursor: usize = 0,
    pack_scroll: usize = 0,
    pack_search_buf: [256]u8 = [_]u8{0} ** 256,
    pack_search_len: usize = 0,
    pack_search_active: bool = false,
    pack_filtered_indices: []usize = &.{},
    pack_community_loaded: bool = false,

    // Pack preview state
    pack_preview_items: []pack_mod.PackItemPreview = &.{},
    pack_preview_cursor: usize = 0,
    pack_preview_scroll: usize = 0,
    pack_preview_name: []const u8 = "",
    pack_preview_installed: bool = false,

    // Workflow runner sub-state
    wf_runner: WorkflowRunnerState = .{},

    pub fn initSelectedSet(self: *State, allocator: std.mem.Allocator) void {
        if (!self.selected_set_inited) {
            self.selected_set = std.AutoHashMap(usize, void).init(allocator);
            self.selected_set_inited = true;
        }
    }

    pub fn deinitSelectedSet(self: *State) void {
        if (self.selected_set_inited) {
            self.selected_set.deinit();
            self.selected_set_inited = false;
        }
    }

    pub fn toggleSelect(self: *State, store_idx: usize) void {
        if (self.selected_set.contains(store_idx)) {
            _ = self.selected_set.remove(store_idx);
        } else {
            self.selected_set.put(store_idx, {}) catch {};
        }
    }

    pub fn isSelected(self: *State, store_idx: usize) bool {
        if (!self.selected_set_inited) return false;
        return self.selected_set.contains(store_idx);
    }

    pub fn selectionCount(self: *State) usize {
        if (!self.selected_set_inited) return 0;
        return self.selected_set.count();
    }

    pub fn clearSelection(self: *State) void {
        if (self.selected_set_inited) {
            self.selected_set.clearRetainingCapacity();
        }
    }

    pub fn searchQuery(self: *State) []const u8 {
        return self.search_buf[0..self.search_len];
    }

    pub fn packSearchQuery(self: *State) []const u8 {
        return self.pack_search_buf[0..self.pack_search_len];
    }

    pub fn commandStr(self: *State) []const u8 {
        return self.command_buf[0..self.command_len];
    }

};

// ── FlexGuard: wraps any widget that asserts max.height/width != null ──
// FlexColumn's first layout pass sends max.height = null to measure intrinsic sizes.
// Widgets like ListView, ScrollView, FlexRow assert non-null constraints.
// This wrapper returns a zero-height surface during that pass and delegates normally otherwise.
pub const FlexGuard = struct {
    inner: vxfw.Widget,

    pub fn widget(self: *const FlexGuard) vxfw.Widget {
        return .{
            .userdata = @constCast(@ptrCast(self)),
            .drawFn = drawFn,
        };
    }

    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const FlexGuard = @ptrCast(@alignCast(ptr));
        if (ctx.max.height == null or ctx.max.width == null) {
            return vxfw.Surface.init(ctx.arena, self.inner, .{ .width = 0, .height = 0 });
        }
        return self.inner.draw(ctx);
    }
};

// Convenience aliases
pub const ListViewGuard = struct {
    inner: *vxfw.ListView,
    pub fn widget(self: *const ListViewGuard) vxfw.Widget {
        // We can't directly create FlexGuard here since we need to call inner.widget()
        // So we keep the direct approach
        return .{ .userdata = @constCast(@ptrCast(self)), .drawFn = drawFn };
    }
    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const ListViewGuard = @ptrCast(@alignCast(ptr));
        if (ctx.max.height == null or ctx.max.width == null) {
            return vxfw.Surface.init(ctx.arena, self.inner.widget(), .{ .width = 0, .height = 0 });
        }
        return self.inner.draw(ctx);
    }
};

pub const ScrollViewGuard = struct {
    inner: *vxfw.ScrollView,
    pub fn widget(self: *const ScrollViewGuard) vxfw.Widget {
        return .{ .userdata = @constCast(@ptrCast(self)), .drawFn = drawFn };
    }
    fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *const ScrollViewGuard = @ptrCast(@alignCast(ptr));
        if (ctx.max.height == null or ctx.max.width == null) {
            return vxfw.Surface.init(ctx.arena, self.inner.widget(), .{ .width = 0, .height = 0 });
        }
        return self.inner.draw(ctx);
    }
};

// ── Styles ──
pub fn accentColor(c: config.Color) Color {
    return switch (c) {
        .cyan => .{ .index = 6 },
        .green => .{ .index = 2 },
        .yellow => .{ .index = 3 },
        .magenta => .{ .index = 5 },
        .red => .{ .index = 1 },
        .blue => .{ .index = 4 },
        .white => .{ .index = 7 },
    };
}

pub fn accentStyle(c: config.Color) Style {
    return .{ .fg = accentColor(c) };
}

pub fn accentBoldStyle(c: config.Color) Style {
    return .{ .fg = accentColor(c), .bold = true };
}

pub const dim_style: Style = .{ .dim = true };
pub const bold_style: Style = .{ .bold = true };
pub const reverse_style: Style = .{ .reverse = true };
pub const wf_style: Style = .{ .fg = .{ .index = 3 }, .bold = true };
pub const chain_style: Style = .{ .fg = .{ .index = 5 }, .bold = true };
pub const snip_icon_style: Style = .{ .dim = true };
pub const del_style: Style = .{ .fg = .{ .index = 1 }, .bold = true };
pub const success_style: Style = .{ .fg = .{ .index = 2 }, .bold = true };
pub const err_style: Style = .{ .fg = .{ .index = 1 } };
pub const header_style: Style = .{ .fg = .{ .index = 6 }, .bold = true };
