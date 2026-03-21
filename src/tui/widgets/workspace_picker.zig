/// WorkspacePicker — full-screen overlay for switching between workspaces.
/// Shows global (all snippets) plus each configured workspace with snippet counts.
const std = @import("std");
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");
const store = @import("../../store.zig");
const history_mod = @import("../../history.zig");
const workspace_mod = @import("../../workspace.zig");
const utils = @import("../utils.zig");
const vxfw = t.vxfw;

state: *t.State,
snip_store: *store.Store,
hist: *history_mod.History,
cfg: config.Config,
allocator: std.mem.Allocator,
list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },

const WorkspacePicker = @This();

pub fn widget(self: *WorkspacePicker) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

// ── Event handling ──

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *WorkspacePicker = @ptrCast(@alignCast(userdata));

    switch (event) {
        .key_press => |key| {
            // Step 1: Esc/q for both modes
            if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
                if (self.state.ws_creating) {
                    self.state.ws_creating = false;
                    self.state.ws_form.error_msg = null;
                    return ctx.consumeAndRedraw();
                }
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }

            // Step 2: Form-mode event routing
            if (self.state.ws_creating) {
                const field = self.state.ws_form.activeField();

                // Ctrl+S: submit from any field
                if (key.matches('s', .{ .ctrl = true })) {
                    self.handleFormSubmit();
                    return ctx.consumeAndRedraw();
                }

                // Tab/Down: next field (wraps around)
                if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.down, .{})) {
                    self.state.ws_form.active = @intCast((@as(usize, self.state.ws_form.active) + 1) % t.WorkspaceFormState.FIELD_COUNT);
                    return ctx.consumeAndRedraw();
                }

                // Shift+Tab/Up: prev field (wraps around)
                if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.up, .{})) {
                    self.state.ws_form.active = @intCast((@as(usize, self.state.ws_form.active) + t.WorkspaceFormState.FIELD_COUNT - 1) % t.WorkspaceFormState.FIELD_COUNT);
                    return ctx.consumeAndRedraw();
                }

                // Enter: submit
                if (key.matches(vaxis.Key.enter, .{})) {
                    self.handleFormSubmit();
                    return ctx.consumeAndRedraw();
                }

                // Backspace: delete char before cursor
                if (key.matches(vaxis.Key.backspace, .{})) {
                    field.backspace();
                    return ctx.consumeAndRedraw();
                }

                // Delete: delete char at cursor
                if (key.matches(vaxis.Key.delete, .{})) {
                    field.deleteForward();
                    return ctx.consumeAndRedraw();
                }

                // Left
                if (key.matches(vaxis.Key.left, .{})) {
                    field.moveLeft();
                    return ctx.consumeAndRedraw();
                }

                // Right
                if (key.matches(vaxis.Key.right, .{})) {
                    field.moveRight();
                    return ctx.consumeAndRedraw();
                }

                // Home
                if (key.matches(vaxis.Key.home, .{})) {
                    field.moveHome();
                    return ctx.consumeAndRedraw();
                }

                // End
                if (key.matches(vaxis.Key.end, .{})) {
                    field.moveEnd();
                    return ctx.consumeAndRedraw();
                }

                // Text input
                if (key.text) |txt| {
                    field.insertSlice(txt);
                    return ctx.consumeAndRedraw();
                } else if (key.codepoint >= 32) {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(@intCast(key.codepoint), &buf) catch return;
                    field.insertSlice(buf[0..len]);
                    return ctx.consumeAndRedraw();
                }

                return;
            }

            if (key.matches(vaxis.Key.enter, .{})) {
                if (self.list_view.cursor == 0) {
                    // Global
                    if (self.state.active_workspace) |ws| self.allocator.free(ws);
                    self.state.active_workspace = null;
                    workspace_mod.setActiveWorkspace(self.allocator, self.cfg, null) catch {};
                    self.snip_store.cfg.active_workspace = null;
                    self.state.message = "\xe2\x9c\x93 Switched to global";
                } else if (self.list_view.cursor - 1 < self.state.ws_list.len) {
                    const ws = self.state.ws_list[self.list_view.cursor - 1];
                    if (self.state.active_workspace) |old| self.allocator.free(old);
                    self.state.active_workspace = self.allocator.dupe(u8, ws.name) catch null;
                    workspace_mod.setActiveWorkspace(self.allocator, self.cfg, ws.name) catch {};
                    self.snip_store.cfg.active_workspace = self.state.active_workspace;
                    self.state.message = "\xe2\x9c\x93 Switched workspace";
                }
                utils.reloadStore(self.allocator, self.state, self.snip_store);
                self.state.mode = .normal;
                return ctx.consumeAndRedraw();
            }

            // Step 3: n key handler in list mode
            if (key.matches('n', .{})) {
                self.state.ws_creating = true;
                self.state.ws_form.reset();
                return ctx.consumeAndRedraw();
            }
        },
        else => {},
    }

    // Forward unhandled events (j/k/arrows/mouse) to ListView
    return self.list_view.handleEvent(ctx, event);
}

// Step 4: handleFormSubmit method
fn handleFormSubmit(self: *WorkspacePicker) void {
    const form = &self.state.ws_form;
    const name = form.fields[t.WorkspaceFormState.F_NAME].text();
    const desc = form.fields[t.WorkspaceFormState.F_DESC].text();
    const path_text = form.fields[t.WorkspaceFormState.F_PATH].text();

    if (name.len == 0) {
        form.error_msg = "Name is required";
        return;
    }

    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
            form.error_msg = "Name: only letters, numbers, hyphens, underscores";
            return;
        }
    }

    const path: ?[]const u8 = if (path_text.len > 0) path_text else null;

    workspace_mod.create(self.allocator, self.cfg, name, desc, path) catch |err| {
        form.error_msg = switch (err) {
            error.AlreadyExists => "Workspace already exists",
            else => "Failed to create workspace",
        };
        return;
    };

    if (self.state.active_workspace) |ws| self.allocator.free(ws);
    self.state.active_workspace = self.allocator.dupe(u8, name) catch null;
    workspace_mod.setActiveWorkspace(self.allocator, self.cfg, name) catch {};
    self.snip_store.cfg.active_workspace = self.state.active_workspace;
    utils.reloadStore(self.allocator, self.state, self.snip_store);

    self.state.ws_creating = false;
    self.state.message = "\xe2\x9c\x93 Created workspace";
    self.state.mode = .normal;
}

// ── Rendering ──

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *WorkspacePicker = @ptrCast(@alignCast(userdata));
    const state = self.state;
    const accent = self.cfg.accent_color;
    const width: u16 = ctx.max.width orelse 80;
    const height: u16 = ctx.max.height orelse 24;

    // Step 5: Form draw logic
    if (state.ws_creating) {
        return self.drawForm(ctx, accent, width, height);
    }

    const ws_count = state.ws_list.len;
    const total_items = ws_count + 1; // +1 for "Global"

    // Build Text widgets for list_view
    const texts = try ctx.arena.alloc(vxfw.Text, total_items);
    const widgets = try ctx.arena.alloc(vxfw.Widget, total_items);

    // Global item (index 0)
    {
        const is_active = state.active_workspace == null;
        const label = "Global (all snippets)";
        texts[0] = .{
            .text = label,
            .style = if (0 == self.list_view.cursor or is_active) t.accentBoldStyle(accent) else .{},
        };
        widgets[0] = texts[0].widget();
    }

    // Workspace items
    for (state.ws_list, 0..) |ws, i| {
        const item_idx = i + 1;
        const is_active = if (state.active_workspace) |aw| std.mem.eql(u8, aw, ws.name) else false;
        const line = try std.fmt.allocPrint(ctx.arena, "{s} ({d} snippets)", .{ ws.name, ws.snippet_count });
        texts[item_idx] = .{
            .text = line,
            .style = if (item_idx == self.list_view.cursor or is_active) t.accentBoldStyle(accent) else .{},
        };
        widgets[item_idx] = texts[item_idx].widget();
    }

    self.list_view.children = .{ .slice = widgets };
    self.list_view.item_count = @intCast(total_items);

    // Layout: title + list_view (flex=1) + footer
    const children = try ctx.arena.alloc(vxfw.FlexItem, 3);

    // ── Title ──
    const title_w = try ctx.arena.create(vxfw.Text);
    title_w.* = .{ .text = "Select a workspace", .style = t.accentBoldStyle(accent) };
    children[0] = .{ .widget = title_w.widget(), .flex = 0 };

    // ── ListView (flex=1) ──
    const guard = try ctx.arena.create(t.ListViewGuard);
    guard.* = .{ .inner = &self.list_view };
    children[1] = .{ .widget = guard.widget(), .flex = 1 };

    // ── Footer ── (Step 6: updated text)
    const footer_w = try ctx.arena.create(vxfw.Text);
    footer_w.* = .{ .text = "  Enter select  n new  Esc/q cancel", .style = t.dim_style };
    children[2] = .{ .widget = footer_w.widget(), .flex = 0 };

    var col = vxfw.FlexColumn{ .children = children };
    const labels = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
    labels[0] = .{ .text = "Workspaces", .alignment = .top_center };
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

fn drawForm(self: *WorkspacePicker, ctx: vxfw.DrawContext, accent: config.Color, width: u16, height: u16) std.mem.Allocator.Error!vxfw.Surface {
    const form = &self.state.ws_form;
    const FIELD_COUNT = t.WorkspaceFormState.FIELD_COUNT;

    // Max children: 2 (title + blank) + 3*FIELD_COUNT (label, content, spacer per active; combined, spacer per inactive) + 1 (error) + 1 (footer) = 13
    const max_children = 2 + 3 * FIELD_COUNT + 1 + 1;
    const children = try ctx.arena.alloc(vxfw.FlexItem, max_children);
    var idx: usize = 0;

    // Title
    const title_w = try ctx.arena.create(vxfw.Text);
    title_w.* = .{ .text = "  New Workspace", .style = t.accentBoldStyle(accent) };
    children[idx] = .{ .widget = title_w.widget(), .flex = 0 };
    idx += 1;

    // Blank line
    const blank_w = try ctx.arena.create(vxfw.Text);
    blank_w.* = .{ .text = " " };
    children[idx] = .{ .widget = blank_w.widget(), .flex = 0 };
    idx += 1;

    // Fields
    for (0..FIELD_COUNT) |fi| {
        const is_active = fi == form.active;
        const label = form.labels[fi];
        const content = form.fields[fi].text();

        if (is_active) {
            // Label on its own line in accent bold
            const lbl_w = try ctx.arena.create(vxfw.Text);
            const lbl_txt = try std.fmt.allocPrint(ctx.arena, "  {s}:", .{label});
            lbl_w.* = .{ .text = lbl_txt, .style = t.accentBoldStyle(accent) };
            children[idx] = .{ .widget = lbl_w.widget(), .flex = 0 };
            idx += 1;

            // Content with "> " prefix in accent
            const cnt_w = try ctx.arena.create(vxfw.Text);
            const cnt_txt = try std.fmt.allocPrint(ctx.arena, "  > {s}", .{content});
            cnt_w.* = .{ .text = cnt_txt, .style = t.accentStyle(accent) };
            children[idx] = .{ .widget = cnt_w.widget(), .flex = 0 };
            idx += 1;
        } else {
            // Combined line: "  Label:   content" in dim style
            const combined_w = try ctx.arena.create(vxfw.Text);
            const display = if (content.len > 0) content else "\xe2\x80\x94";
            const combined_txt = try std.fmt.allocPrint(ctx.arena, "  {s}:   {s}", .{ label, display });
            combined_w.* = .{ .text = combined_txt, .style = t.dim_style };
            children[idx] = .{ .widget = combined_w.widget(), .flex = 0 };
            idx += 1;
        }

        // Spacer between fields
        const spacer_w = try ctx.arena.create(vxfw.Text);
        spacer_w.* = .{ .text = " " };
        children[idx] = .{ .widget = spacer_w.widget(), .flex = 0 };
        idx += 1;
    }

    // Error message
    if (form.error_msg) |err_msg| {
        const err_w = try ctx.arena.create(vxfw.Text);
        const err_txt = try std.fmt.allocPrint(ctx.arena, "  {s}", .{err_msg});
        err_w.* = .{ .text = err_txt, .style = t.err_style };
        children[idx] = .{ .widget = err_w.widget(), .flex = 0 };
        idx += 1;
    }

    // Footer
    const footer_w = try ctx.arena.create(vxfw.Text);
    footer_w.* = .{ .text = "  Tab: next  Ctrl+S: save  Esc: cancel", .style = t.dim_style };
    children[idx] = .{ .widget = footer_w.widget(), .flex = 0 };
    idx += 1;

    var col = vxfw.FlexColumn{ .children = children[0..idx] };
    const labels = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
    labels[0] = .{ .text = "New Workspace", .alignment = .top_center };
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
