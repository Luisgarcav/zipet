/// MainScreen — snippet list with vim-style navigation, search/command bar, and preview panel.
/// Sub-state overlays (confirm delete, tag picker, info) will be added in task 9c.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const store = @import("../../store.zig");
const history_mod = @import("../../history.zig");
const actions = @import("../actions.zig");
const utils = @import("../utils.zig");
const unicode = @import("../unicode.zig");
const template = @import("../../template.zig");
const vxfw = t.vxfw;

const ListViewGuard = t.ListViewGuard;

state: *t.State,
snip_store: *store.Store,
cfg: config.Config,
hist: *history_mod.History,
allocator: std.mem.Allocator,
list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },
search_field: vxfw.TextField,
command_field: vxfw.TextField,

const MainScreen = @This();

pub fn widget(self: *MainScreen) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

// ── Event handling ──

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *MainScreen = @ptrCast(@alignCast(userdata));

    switch (event) {
        .key_press => |key| {
            if (self.state.mode == .confirm_delete) {
                self.handleConfirmDeleteKey(key);
                return ctx.consumeAndRedraw();
            }
            if (self.state.mode == .confirm_delete_multi) {
                self.handleConfirmDeleteMultiKey(key);
                return ctx.consumeAndRedraw();
            }
            if (self.state.mode == .info) {
                if (key.matches('i', .{}) or key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                    self.state.mode = .normal;
                }
                return ctx.consumeAndRedraw();
            }
            if (self.state.mode == .search) {
                // Intercept Esc/Enter before forwarding to TextField
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.state.mode = .normal;
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    self.state.mode = .normal;
                    return ctx.consumeAndRedraw();
                }
                // Forward to TextField for text editing
                try self.search_field.handleEvent(ctx, .{ .key_press = key });
                // Sync TextField content back to state for filtering
                self.syncSearchToState();
                utils.refilterFrecency(self.allocator, self.state, self.snip_store, self.hist);
                self.list_view.cursor = 0;
                self.list_view.item_count = @intCast(self.state.filtered_indices.len);
                self.state.cursor = 0;
                return;
            }
            if (self.state.mode == .command) {
                if (key.matches(vaxis.Key.escape, .{})) {
                    self.state.mode = .normal;
                    self.state.command_len = 0;
                    self.command_field.clearRetainingCapacity();
                    return ctx.consumeAndRedraw();
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    self.syncCommandToState();
                    self.executeCommand();
                    self.state.command_len = 0;
                    self.command_field.clearRetainingCapacity();
                    return ctx.consumeAndRedraw();
                }
                try self.command_field.handleEvent(ctx, .{ .key_press = key });
                return;
            }
            try handleNormalKey(self, key, ctx);
        },
        else => {},
    }
}

fn handleNormalKey(self: *MainScreen, key: vaxis.Key, ctx: *vxfw.EventContext) !void {
    const state = self.state;
    const total = state.filtered_indices.len;
    const cursor = self.list_view.cursor;

    if (key.matches('q', .{})) {
        state.running = false;
        return ctx.consumeAndRedraw();
    }

    if (key.matches('?', .{}) or key.matches('?', .{ .shift = true })) {
        state.mode = .help;
        return ctx.consumeAndRedraw();
    }

    if (key.matches(vaxis.Key.escape, .{})) {
        if (state.search_len > 0 or state.active_tag_filter != null) {
            state.search_len = 0;
            state.active_tag_filter = null;
            self.search_field.clearRetainingCapacity();
            self.allocator.free(state.filtered_indices);
            state.filtered_indices = utils.updateFilterFrecency(self.allocator, self.snip_store, "", null, self.hist) catch &.{};
            self.list_view.cursor = 0;
            self.list_view.item_count = @intCast(state.filtered_indices.len);
            state.cursor = 0;
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches(vaxis.Key.enter, .{})) {
        if (total > 0 and cursor < total) {
            const si = state.filtered_indices[cursor];
            const snip = &self.snip_store.snippets.items[si];
            if (snip.params.len > 0) {
                actions.initParamInput(state, si, snip);
                state.mode = .param_input;
            } else {
                try actions.executeSnippetDirect(self.allocator, state, snip, self.cfg, self.snip_store, self.hist);
            }
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('a', .{})) {
        state.form = t.FormState.init(.add);
        state.mode = .form;
        return ctx.consumeAndRedraw();
    }

    if (key.matches('w', .{})) {
        state.wf_form = t.WorkflowFormState.init();
        state.mode = .workflow_form;
        return ctx.consumeAndRedraw();
    }

    if (key.matches('e', .{})) {
        if (total > 0 and cursor < total) {
            const si = state.filtered_indices[cursor];
            state.form = t.FormState.init(.edit);
            state.form.editing_snip_idx = si;
            state.mode = .form;
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('d', .{})) {
        if (total > 0 and cursor < total) state.mode = .confirm_delete;
        return ctx.consumeAndRedraw();
    }

    if (key.matches('o', .{})) {
        if (total > 0 and cursor < total) {
            const si = state.filtered_indices[cursor];
            const snip = &self.snip_store.snippets.items[si];
            actions.openExternalEditor(self.allocator, snip, self.cfg);
            utils.reloadStore(self.allocator, state, self.snip_store);
            self.list_view.item_count = @intCast(state.filtered_indices.len);
            state.message = "\xe2\x9c\x93 Reloaded after edit";
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('y', .{})) {
        if (total > 0 and cursor < total) {
            const si = state.filtered_indices[cursor];
            const snip = &self.snip_store.snippets.items[si];
            state.message = if (utils.yankToClipboard(self.allocator, snip.cmd)) "\xe2\x9c\x93 Copied to clipboard" else "\xe2\x9c\x97 No clipboard tool found";
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('p', .{})) {
        const clip = template.readClipboard(self.allocator) catch null;
        if (clip) |clip_text| {
            state.form = t.FormState.init(.paste);
            state.form.paste_cmd_cache = clip_text; // FormScreen will free after populating
            state.mode = .form;
        } else {
            state.message = "\xe2\x9c\x97 No clipboard content";
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('t', .{})) {
        const all_tags = self.snip_store.allTags(self.allocator) catch &.{};
        if (all_tags.len > 0) {
            if (state.tag_list.len > 0) self.allocator.free(state.tag_list);
            state.tag_list = all_tags;
            state.tag_cursor = 0;
            state.mode = .tag_picker;
        } else {
            state.message = "No tags found";
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('x', .{})) {
        if (total > 0 and cursor < total) {
            const si = state.filtered_indices[cursor];
            state.toggleSelect(si);
            if (cursor + 1 < total) {
                self.list_view.cursor += 1;
            }
        }
        state.cursor = self.list_view.cursor;
        return ctx.consumeAndRedraw();
    }

    if (key.matches('X', .{}) or key.matches('x', .{ .shift = true })) {
        if (state.selectionCount() > 0) {
            state.clearSelection();
            state.message = "Selection cleared";
        } else {
            for (state.filtered_indices) |si| {
                state.selected_set.put(si, {}) catch {};
            }
            var buf: [64]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "{d} selected", .{state.filtered_indices.len}) catch "Selected all";
            state.message = self.allocator.dupe(u8, msg) catch "Selected all";
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('R', .{}) or key.matches('r', .{ .shift = true })) {
        if (state.selectionCount() > 0) {
            try actions.executeSelectedParallel(self.allocator, state, self.snip_store);
        } else {
            state.message = "No snippets selected (use x to select)";
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('D', .{}) or key.matches('d', .{ .shift = true })) {
        if (state.selectionCount() > 0) {
            state.mode = .confirm_delete_multi;
        } else {
            state.message = "No snippets selected (use x to select)";
        }
        return ctx.consumeAndRedraw();
    }

    if (key.matches('i', .{})) {
        if (total > 0 and cursor < total) state.mode = .info;
        return ctx.consumeAndRedraw();
    }

    if (key.matches('W', .{}) or key.matches('w', .{ .shift = true })) {
        try actions.openWorkspacePicker(self.allocator, state, self.cfg);
        return ctx.consumeAndRedraw();
    }

    if (key.matches('P', .{}) or key.matches('p', .{ .shift = true })) {
        try actions.openPackBrowser(self.allocator, state, self.cfg);
        return ctx.consumeAndRedraw();
    }

    if (key.matches('/', .{})) {
        state.mode = .search;
        // Clear the search field for a fresh search
        self.search_field.clearRetainingCapacity();
        return ctx.consumeAndRedraw();
    }

    if (key.matches(':', .{}) or key.matches(':', .{ .shift = true })) {
        state.mode = .command;
        state.command_len = 0;
        self.command_field.clearRetainingCapacity();
        return ctx.consumeAndRedraw();
    }

    if (key.matches(' ', .{})) {
        state.preview_visible = !state.preview_visible;
        return ctx.consumeAndRedraw();
    }

    // Forward unhandled events (j/k/arrows/G) to ListView
    try self.list_view.handleEvent(ctx, .{ .key_press = key });
    state.cursor = self.list_view.cursor;
}

// ── TextField sync helpers ──

fn syncSearchToState(self: *MainScreen) void {
    const first = self.search_field.buf.firstHalf();
    const second = self.search_field.buf.secondHalf();
    const total = first.len + second.len;
    const n = @min(total, self.state.search_buf.len - 1);
    const first_n = @min(first.len, n);
    @memcpy(self.state.search_buf[0..first_n], first[0..first_n]);
    if (first_n < n) {
        const second_n = n - first_n;
        @memcpy(self.state.search_buf[first_n..n], second[0..second_n]);
    }
    self.state.search_len = n;
}

fn syncCommandToState(self: *MainScreen) void {
    const first = self.command_field.buf.firstHalf();
    const second = self.command_field.buf.secondHalf();
    const total = first.len + second.len;
    const n = @min(total, self.state.command_buf.len - 1);
    const first_n = @min(first.len, n);
    @memcpy(self.state.command_buf[0..first_n], first[0..first_n]);
    if (first_n < n) {
        const second_n = n - first_n;
        @memcpy(self.state.command_buf[first_n..n], second[0..second_n]);
    }
    self.state.command_len = n;
}

// ── Confirm delete input ──

fn handleConfirmDeleteKey(self: *MainScreen, key: vaxis.Key) void {
    const state = self.state;
    if (key.matches('y', .{})) {
        if (self.list_view.cursor >= state.filtered_indices.len) {
            state.mode = .normal;
            return;
        }
        const si = state.filtered_indices[self.list_view.cursor];
        const name = self.snip_store.snippets.items[si].name;
        self.snip_store.remove(name) catch {};
        self.allocator.free(state.filtered_indices);
        state.filtered_indices = utils.updateFilterFrecency(self.allocator, self.snip_store, state.searchQuery(), state.active_tag_filter, self.hist) catch &.{};
        self.list_view.item_count = @intCast(state.filtered_indices.len);
        if (self.list_view.cursor >= state.filtered_indices.len and state.filtered_indices.len > 0)
            self.list_view.cursor = @intCast(state.filtered_indices.len - 1);
        state.cursor = self.list_view.cursor;
        state.message = "Snippet deleted";
        state.mode = .normal;
    } else {
        state.mode = .normal;
    }
}

fn handleConfirmDeleteMultiKey(self: *MainScreen, key: vaxis.Key) void {
    const state = self.state;
    if (key.matches('y', .{})) {
        actions.deleteSelected(self.allocator, state, self.snip_store);
        self.list_view.cursor = 0;
        self.list_view.item_count = @intCast(state.filtered_indices.len);
        state.cursor = 0;
        state.mode = .normal;
    } else {
        state.mode = .normal;
    }
}

fn executeCommand(self: *MainScreen) void {
    const state = self.state;
    const cmd = state.commandStr();
    const eql = std.mem.eql;

    if (eql(u8, cmd, "q") or eql(u8, cmd, "quit")) {
        state.running = false;
    } else if (eql(u8, cmd, "help")) {
        state.mode = .help;
    } else if (eql(u8, cmd, "tags")) {
        const all_tags = self.snip_store.allTags(self.allocator) catch &.{};
        if (all_tags.len > 0) {
            if (state.tag_list.len > 0) self.allocator.free(state.tag_list);
            state.tag_list = all_tags;
            state.tag_cursor = 0;
            state.mode = .tag_picker;
        } else {
            state.message = "No tags found";
        }
    } else if (eql(u8, cmd, "export")) {
        actions.buildExportOutput(self.allocator, state, self.snip_store);
        state.mode = .output_view;
    } else if (eql(u8, cmd, "ws") or eql(u8, cmd, "workspace") or eql(u8, cmd, "workspaces")) {
        actions.openWorkspacePicker(self.allocator, state, self.cfg) catch {};
    } else if (eql(u8, cmd, "packs") or eql(u8, cmd, "pack")) {
        actions.openPackBrowser(self.allocator, state, self.cfg) catch {};
    } else if (eql(u8, cmd, "history")) {
        actions.showHistory(self.allocator, state, self.hist);
        state.mode = .output_view;
    } else if (eql(u8, cmd, "w")) {
        actions.saveAll(self.allocator, self.snip_store);
        state.message = "All saved";
    } else if (eql(u8, cmd, "wq")) {
        actions.saveAll(self.allocator, self.snip_store);
        state.running = false;
    }
}

// ── Rendering ──

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *MainScreen = @ptrCast(@alignCast(userdata));
    const state = self.state;
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;
    const w: usize = @intCast(width);

    const total = state.filtered_indices.len;
    const cursor = self.list_view.cursor;

    // Determine whether info panel or snippet list is shown
    const show_info = state.mode == .info and total > 0;
    const show_list = !show_info and total > 0;
    const show_empty = !show_info and total == 0;
    const show_preview = !show_info and state.preview_visible and total > 0;

    // Count children: status(1) + search(1) + separator(1) + (info 10 | list 1 | empty 1) + preview(4) + footer(1)
    const info_rows: usize = if (show_info) 10 else 0;
    const list_rows: usize = if (show_list) 1 else 0;
    const empty_rows: usize = if (show_empty) 1 else 0;
    const preview_rows: usize = if (show_preview) 4 else 0;
    const child_count = 3 + info_rows + list_rows + empty_rows + preview_rows + 1;

    const children = try ctx.arena.alloc(vxfw.FlexItem, child_count);
    var idx: usize = 0;

    // ── Row 0: Status bar ──
    {
        var status_buf: std.ArrayList(u8) = .{};
        const sw = status_buf.writer(ctx.arena);
        try sw.writeAll(" zipet");
        if (state.active_workspace) |ws| {
            try sw.print(" {s}", .{ws});
        }

        // Right side: snippet count
        var right_buf: std.ArrayList(u8) = .{};
        const rw = right_buf.writer(ctx.arena);
        const sel_count = state.selectionCount();
        if (sel_count > 0) {
            try rw.print("{d} selected  {d} snippets", .{ sel_count, total });
        } else {
            try rw.print("{d} snippets", .{total});
        }

        const left_str = try status_buf.toOwnedSlice(ctx.arena);
        const right_str = try right_buf.toOwnedSlice(ctx.arena);
        const left_w_usize = unicode.displayWidth(left_str);
        const right_w_usize = unicode.displayWidth(right_str);
        const gap: usize = if (w > left_w_usize + right_w_usize + 1) w - left_w_usize - right_w_usize - 1 else 1;
        const spaces = try ctx.arena.alloc(u8, gap);
        @memset(spaces, ' ');
        const status_line = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ left_str, spaces, right_str });

        const status_w = try ctx.arena.create(vxfw.Text);
        status_w.* = .{ .text = status_line, .style = t.reverse_style };
        children[idx] = .{ .widget = status_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Row 1: Search / Command bar ──
    {
        if (state.mode == .search) {
            // FlexRow: prefix " > " + TextField
            const prefix_w = try ctx.arena.create(vxfw.Text);
            prefix_w.* = .{ .text = " > ", .style = t.accentBoldStyle(accent) };
            self.search_field.style = t.accentBoldStyle(accent);
            const row_items = try ctx.arena.alloc(vxfw.FlexItem, 2);
            row_items[0] = .{ .widget = prefix_w.widget(), .flex = 0 };
            row_items[1] = .{ .widget = self.search_field.widget(), .flex = 1 };
            const row = try ctx.arena.create(vxfw.FlexRow);
            row.* = .{ .children = row_items };
            const guard = try ctx.arena.create(t.FlexGuard);
            guard.* = .{ .inner = row.widget() };
            children[idx] = .{ .widget = guard.widget(), .flex = 0 };
        } else if (state.mode == .command) {
            // FlexRow: prefix " :" + TextField
            const prefix_w = try ctx.arena.create(vxfw.Text);
            prefix_w.* = .{ .text = " :", .style = .{} };
            self.command_field.style = .{};
            const row_items = try ctx.arena.alloc(vxfw.FlexItem, 2);
            row_items[0] = .{ .widget = prefix_w.widget(), .flex = 0 };
            row_items[1] = .{ .widget = self.command_field.widget(), .flex = 1 };
            const row = try ctx.arena.create(vxfw.FlexRow);
            row.* = .{ .children = row_items };
            const guard = try ctx.arena.create(t.FlexGuard);
            guard.* = .{ .inner = row.widget() };
            children[idx] = .{ .widget = guard.widget(), .flex = 0 };
        } else if (state.search_len > 0) {
            const query = state.search_buf[0..state.search_len];
            const line = try std.fmt.allocPrint(ctx.arena, " / {s}", .{query});
            const hint_w = try ctx.arena.create(vxfw.Text);
            hint_w.* = .{ .text = line, .style = t.dim_style };
            children[idx] = .{ .widget = hint_w.widget(), .flex = 0 };
        } else {
            const hint_w = try ctx.arena.create(vxfw.Text);
            hint_w.* = .{ .text = " type / to search", .style = t.dim_style };
            children[idx] = .{ .widget = hint_w.widget(), .flex = 0 };
        }
        idx += 1;
    }

    // ── Row 2: Separator ──
    {
        const sep_buf = try ctx.arena.alloc(u8, w * 3); // ─ is 3 bytes
        var si: usize = 0;
        var col: usize = 0;
        while (col < w) : (col += 1) {
            if (si + 3 <= sep_buf.len) {
                sep_buf[si] = 0xe2;
                sep_buf[si + 1] = 0x94;
                sep_buf[si + 2] = 0x80;
                si += 3;
            }
        }
        const sep_w = try ctx.arena.create(vxfw.Text);
        sep_w.* = .{ .text = sep_buf[0..si], .style = t.dim_style };
        children[idx] = .{ .widget = sep_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Snippet list / Info panel ──
    if (show_info and cursor < total) {
        // Info panel replaces the snippet list
        const cur_si = state.filtered_indices[cursor];
        const cur_snip = &self.snip_store.snippets.items[cur_si];

        // Title
        {
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = "\xe2\x94\x80\xe2\x94\x80 Snippet Info \xe2\x94\x80\xe2\x94\x80", .style = t.accentBoldStyle(accent) };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
        // Name
        {
            const line = try std.fmt.allocPrint(ctx.arena, " Name: {s}", .{cur_snip.name});
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = line, .style = t.bold_style };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
        // Description
        {
            const line = try std.fmt.allocPrint(ctx.arena, " Description: {s}", .{cur_snip.desc});
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = line, .style = .{} };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
        // Command label
        {
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = " Command:", .style = .{} };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
        // Command value
        {
            const line = try std.fmt.allocPrint(ctx.arena, " $ {s}", .{cur_snip.cmd});
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = line, .style = t.accentStyle(accent) };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
        // Tags
        {
            var tags_buf: std.ArrayList(u8) = .{};
            const tw2 = tags_buf.writer(ctx.arena);
            try tw2.writeAll(" Tags: [");
            for (cur_snip.tags, 0..) |tag_str, ti| {
                if (ti > 0) try tw2.writeAll(", ");
                try tw2.writeAll(tag_str);
            }
            try tw2.writeAll("]");
            const tags_line = try tags_buf.toOwnedSlice(ctx.arena);
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = tags_line, .style = t.accentStyle(accent) };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
        // Namespace
        {
            const line = try std.fmt.allocPrint(ctx.arena, " Namespace: {s}", .{cur_snip.namespace});
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = line, .style = t.dim_style };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
        // Type
        {
            const kind_str: []const u8 = if (cur_snip.kind == .workflow) "workflow" else "snippet";
            const line = try std.fmt.allocPrint(ctx.arena, " Type: {s}", .{kind_str});
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = line, .style = .{} };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
        // Spacer
        {
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = "", .style = .{} };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
        // Close hint
        {
            const iw = try ctx.arena.create(vxfw.Text);
            iw.* = .{ .text = " Esc/i to close", .style = t.dim_style };
            children[idx] = .{ .widget = iw.widget(), .flex = 0 };
            idx += 1;
        }
    } else if (show_empty) {
        const empty_w = try ctx.arena.create(vxfw.Text);
        empty_w.* = .{ .text = "  No snippets", .style = t.dim_style };
        children[idx] = .{ .widget = empty_w.widget(), .flex = 0 };
        idx += 1;
    } else if (show_list) {
        // Build Text widgets for list_view
        const indices = state.filtered_indices;
        const texts = try ctx.arena.alloc(vxfw.Text, indices.len);
        const widgets = try ctx.arena.alloc(vxfw.Widget, indices.len);
        for (indices, 0..) |si, i| {
            if (si >= self.snip_store.snippets.items.len) {
                texts[i] = .{ .text = "  ???", .style = t.dim_style };
                widgets[i] = texts[i].widget();
                continue;
            }
            const snip = &self.snip_store.snippets.items[si];
            const icon: []const u8 = if (snip.kind == .workflow) "⚡" else " $ ";
            const is_selected = state.isSelected(si);
            const sel_marker: []const u8 = if (is_selected) "\xe2\x97\x89 " else "  ";

            var line_buf: std.ArrayList(u8) = .{};
            const lw2 = line_buf.writer(ctx.arena);
            try lw2.print("{s}{s}{s}", .{ sel_marker, icon, snip.name });
            if (snip.desc.len > 0) {
                try lw2.print("  {s}", .{snip.desc});
            }
            // Append tags on same line
            try lw2.writeAll("  [");
            for (snip.tags, 0..) |tag, ti| {
                if (ti > 0) try lw2.writeAll(", ");
                try lw2.writeAll(tag);
            }
            try lw2.writeAll("]");
            const line_content = try line_buf.toOwnedSlice(ctx.arena);

            const max_content: usize = if (w > 1) w - 1 else 1;
            const truncated = unicode.truncateToDisplayWidth(line_content, max_content);

            const style: t.Style = if (i == cursor)
                .{ .fg = t.accentColor(accent), .bold = true }
            else if (is_selected)
                .{ .bold = true }
            else
                .{};

            texts[i] = .{ .text = truncated, .style = style };
            widgets[i] = texts[i].widget();
        }
        self.list_view.children = .{ .slice = widgets };
        self.list_view.item_count = @intCast(indices.len);

        const guard = try ctx.arena.create(ListViewGuard);
        guard.* = .{ .inner = &self.list_view };
        children[idx] = .{ .widget = guard.widget(), .flex = 1 };
        idx += 1;
    }

    // ── Preview panel (skip in info mode) ──
    if (show_preview and cursor < total) {
        const cur_si = state.filtered_indices[cursor];
        const cur_snip = &self.snip_store.snippets.items[cur_si];

        // Separator
        {
            const sep_buf2 = try ctx.arena.alloc(u8, w * 3);
            var si2: usize = 0;
            var col2: usize = 0;
            while (col2 < w) : (col2 += 1) {
                if (si2 + 3 <= sep_buf2.len) {
                    sep_buf2[si2] = 0xe2;
                    sep_buf2[si2 + 1] = 0x94;
                    sep_buf2[si2 + 2] = 0x80;
                    si2 += 3;
                }
            }
            const psep_w = try ctx.arena.create(vxfw.Text);
            psep_w.* = .{ .text = sep_buf2[0..si2], .style = t.dim_style };
            children[idx] = .{ .widget = psep_w.widget(), .flex = 0 };
            idx += 1;
        }

        // Name + description
        {
            const name_line = if (cur_snip.desc.len > 0)
                try std.fmt.allocPrint(ctx.arena, " {s} \xe2\x80\x94 {s}", .{ cur_snip.name, cur_snip.desc })
            else
                try std.fmt.allocPrint(ctx.arena, " {s}", .{cur_snip.name});
            const pname_w = try ctx.arena.create(vxfw.Text);
            pname_w.* = .{ .text = name_line, .style = t.bold_style };
            children[idx] = .{ .widget = pname_w.widget(), .flex = 0 };
            idx += 1;
        }

        // Command
        {
            const cmd_line = try std.fmt.allocPrint(ctx.arena, " $ {s}", .{cur_snip.cmd});
            const truncated_cmd = unicode.truncateToDisplayWidth(cmd_line, if (w > 1) w - 1 else 1);
            const pcmd_w = try ctx.arena.create(vxfw.Text);
            pcmd_w.* = .{ .text = truncated_cmd, .style = t.accentStyle(accent) };
            children[idx] = .{ .widget = pcmd_w.widget(), .flex = 0 };
            idx += 1;
        }

        // Tags
        {
            var ptags_buf: std.ArrayList(u8) = .{};
            const ptw = ptags_buf.writer(ctx.arena);
            try ptw.writeAll(" [");
            for (cur_snip.tags, 0..) |tag_str, ti| {
                if (ti > 0) try ptw.writeAll(", ");
                try ptw.writeAll(tag_str);
            }
            try ptw.writeAll("]");
            const ptags_line = try ptags_buf.toOwnedSlice(ctx.arena);
            const ptags_w = try ctx.arena.create(vxfw.Text);
            ptags_w.* = .{ .text = ptags_line, .style = t.accentStyle(accent) };
            children[idx] = .{ .widget = ptags_w.widget(), .flex = 0 };
            idx += 1;
        }
    }

    // ── Footer ──
    {
        if (state.mode == .confirm_delete) {
            const footer_w = try ctx.arena.create(vxfw.Text);
            footer_w.* = .{ .text = " Delete this snippet? (y/N)", .style = t.del_style };
            children[idx] = .{ .widget = footer_w.widget(), .flex = 0 };
            idx += 1;
        } else if (state.mode == .confirm_delete_multi) {
            const sel_n = state.selectionCount();
            const del_line = try std.fmt.allocPrint(ctx.arena, " Delete {d} selected snippets? (y/N)", .{sel_n});
            const footer_w = try ctx.arena.create(vxfw.Text);
            footer_w.* = .{ .text = del_line, .style = t.del_style };
            children[idx] = .{ .widget = footer_w.widget(), .flex = 0 };
            idx += 1;
        } else {
            const footer_keys = " j/k move  Enter run  x select  a add  w workflow  e edit  d del  P packs  ? help";
            const footer_line = if (state.message) |msg| blk: {
                const keys_w_usize = unicode.displayWidth(footer_keys);
                const msg_w_usize = unicode.displayWidth(msg);
                const total_w_val: usize = keys_w_usize + msg_w_usize + 2;
                if (total_w_val < w) {
                    const gap_val = w - total_w_val;
                    const spaces = try ctx.arena.alloc(u8, gap_val);
                    @memset(spaces, ' ');
                    const line = try std.fmt.allocPrint(ctx.arena, "{s}{s}{s}", .{ footer_keys, spaces, msg });
                    state.message = null;
                    break :blk line;
                } else {
                    state.message = null;
                    break :blk footer_keys;
                }
            } else footer_keys;

            const footer_w = try ctx.arena.create(vxfw.Text);
            footer_w.* = .{ .text = footer_line, .style = t.dim_style };
            children[idx] = .{ .widget = footer_w.widget(), .flex = 0 };
            idx += 1;
        }
    }

    var col = vxfw.FlexColumn{ .children = children[0..idx] };
    return col.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}
