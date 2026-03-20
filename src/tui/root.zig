/// TUI for zipet — vxfw-based terminal interface.
/// This is the root module that wires together the vxfw App with ZipetRoot as the mode-routing widget.
const std = @import("std");
const vaxis = @import("vaxis");
const store = @import("../store.zig");
const config = @import("../config.zig");
const history_mod = @import("../history.zig");
const workspace_mod = @import("../workspace.zig");
const pack_mod = @import("../pack.zig");

const t = @import("types.zig");
const utils = @import("utils.zig");
const OutputView = @import("widgets/output_view.zig");
const HelpScreen = @import("widgets/help.zig");
const FormScreen = @import("widgets/form.zig");
const ParamInput = @import("widgets/param_input.zig");
const WorkflowForm = @import("widgets/workflow_form.zig");
const PackBrowser = @import("widgets/pack_browser.zig");
const PackPreview = @import("widgets/pack_preview.zig");
const TagPicker = @import("widgets/tag_picker.zig");
const WorkspacePicker = @import("widgets/workspace_picker.zig");
const MainScreen = @import("widgets/main_screen.zig");
const vxfw = t.vxfw;

/// Root widget that routes between modes. Currently renders a placeholder;
/// real mode-specific widgets will be added in later migration tasks.
const ZipetRoot = struct {
    state: *t.State,
    store: *store.Store,
    cfg: config.Config,
    hist: *history_mod.History,
    allocator: std.mem.Allocator,
    output_view: OutputView,
    help_screen: HelpScreen,
    form_screen: FormScreen,
    param_input: ParamInput,
    workflow_form: WorkflowForm,
    pack_browser: PackBrowser,
    pack_preview: PackPreview,
    tag_picker: TagPicker,
    workspace_picker: WorkspacePicker,
    main_screen: MainScreen,

    pub fn widget(self: *ZipetRoot) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = ZipetRoot.handleEvent,
            .drawFn = ZipetRoot.draw,
        };
    }

    fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *ZipetRoot = @ptrCast(@alignCast(userdata));

        // Global Space preview popup — intercept before child widgets
        // Only in modes where it makes sense (not in text input modes)
        switch (event) {
            .key_press => |key| {
                if (key.matches(' ', .{})) {
                    const mode = self.state.mode;
                    // Toggle popup in navigation modes, skip in text input modes
                    if (mode == .search or mode == .command or mode == .form or
                        mode == .param_input or mode == .workflow_form or mode == .pack_search)
                    {
                        // Let text input handle Space normally
                    } else if (self.state.preview_popup) {
                        // Close popup
                        self.state.preview_popup = false;
                        ctx.consumeAndRedraw();
                        return;
                    } else if (getPreviewContent(self)) |_| {
                        // Open popup if there's something to preview
                        self.state.preview_popup = true;
                        ctx.consumeAndRedraw();
                        return;
                    }
                }
                // Close popup on any other key
                if (self.state.preview_popup and !key.matches(' ', .{})) {
                    self.state.preview_popup = false;
                    ctx.consumeAndRedraw();
                    // Don't return — let the key also be handled by the child widget
                }
            },
            else => {},
        }

        switch (self.state.mode) {
            .output_view => try self.output_view.widget().handleEvent(ctx, event),
            .help => try self.help_screen.widget().handleEvent(ctx, event),
            .form => try self.form_screen.widget().handleEvent(ctx, event),
            .param_input => try self.param_input.widget().handleEvent(ctx, event),
            .workflow_form => try self.workflow_form.widget().handleEvent(ctx, event),
            .pack_browser, .pack_search => try self.pack_browser.widget().handleEvent(ctx, event),
            .pack_preview => try self.pack_preview.widget().handleEvent(ctx, event),
            .tag_picker => try self.tag_picker.widget().handleEvent(ctx, event),
            .workspace_picker => try self.workspace_picker.widget().handleEvent(ctx, event),
            .normal, .search, .command, .confirm_delete, .confirm_delete_multi, .info => try self.main_screen.widget().handleEvent(ctx, event),
            .workflow_runner => {}, // handled by workflow runner widget (Task 13)
        }

        // Bridge: sync state.running → vxfw quit
        if (!self.state.running) ctx.quit = true;
    }

    /// Get preview content based on current mode and selection.
    /// Returns snippet info if available, null otherwise.
    const PreviewInfo = struct {
        name: []const u8,
        desc: []const u8,
        cmd: []const u8,
        tags: []const []const u8,
        kind: []const u8,
        namespace: []const u8,
    };

    fn getPreviewContent(self: *ZipetRoot) ?PreviewInfo {
        const state = self.state;
        switch (state.mode) {
            .normal, .confirm_delete, .confirm_delete_multi, .info => {
                // Main screen: preview selected snippet
                const cursor = self.main_screen.list_view.cursor;
                if (cursor < state.filtered_indices.len) {
                    const si = state.filtered_indices[cursor];
                    if (si < self.store.snippets.items.len) {
                        const snip = &self.store.snippets.items[si];
                        return .{
                            .name = snip.name,
                            .desc = snip.desc,
                            .cmd = snip.cmd,
                            .tags = snip.tags,
                            .kind = if (snip.kind == .workflow) "workflow" else "snippet",
                            .namespace = snip.namespace,
                        };
                    }
                }
            },
            .pack_browser => {
                // Pack browser: preview selected pack as text
                const cursor = self.pack_browser.list_view.cursor;
                const total = if (state.pack_search_active) state.pack_filtered_indices.len else state.pack_list.len;
                if (cursor < total) {
                    const real_idx = if (state.pack_search_active and cursor < state.pack_filtered_indices.len)
                        state.pack_filtered_indices[cursor]
                    else
                        cursor;
                    if (real_idx < state.pack_list.len) {
                        const p = &state.pack_list[real_idx];
                        return .{
                            .name = p.name,
                            .desc = p.description,
                            .cmd = p.category,
                            .tags = p.tags,
                            .kind = if (p.is_community) "community pack" else "local pack",
                            .namespace = p.author,
                        };
                    }
                }
            },
            .pack_preview => {
                // Pack preview: preview selected item
                const cursor = self.pack_preview.list_view.cursor;
                if (cursor < state.pack_preview_items.len) {
                    const item = &state.pack_preview_items[cursor];
                    return .{
                        .name = item.name,
                        .desc = item.desc,
                        .cmd = item.cmd,
                        .tags = item.tags,
                        .kind = if (item.kind == .workflow) "workflow" else "snippet",
                        .namespace = "",
                    };
                }
            },
            else => {},
        }
        return null;
    }

    fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *ZipetRoot = @ptrCast(@alignCast(userdata));

        // Draw the base screen
        const base = switch (self.state.mode) {
            .output_view => try self.output_view.widget().draw(ctx),
            .help => try self.help_screen.widget().draw(ctx),
            .form => try self.form_screen.widget().draw(ctx),
            .param_input => try self.param_input.widget().draw(ctx),
            .workflow_form => try self.workflow_form.widget().draw(ctx),
            .pack_browser, .pack_search => try self.pack_browser.widget().draw(ctx),
            .pack_preview => try self.pack_preview.widget().draw(ctx),
            .tag_picker => try self.tag_picker.widget().draw(ctx),
            .workspace_picker => try self.workspace_picker.widget().draw(ctx),
            .normal, .search, .command, .confirm_delete, .confirm_delete_multi, .info => try self.main_screen.widget().draw(ctx),
            .workflow_runner => try self.main_screen.widget().draw(ctx), // placeholder until Task 13
        };

        // If preview popup is active, composite it over the base
        if (self.state.preview_popup) {
            if (getPreviewContent(self)) |info| {
                const popup = try drawPreviewPopup(self, ctx, info);
                const max_w = ctx.max.width orelse 80;
                const max_h = ctx.max.height orelse 24;

                // Center the popup
                const popup_w = popup.size.width;
                const popup_h = popup.size.height;
                const ox: i17 = @intCast((max_w -| popup_w) / 2);
                const oy: i17 = @intCast((max_h -| popup_h) / 2);

                var children = try ctx.arena.alloc(vxfw.SubSurface, 2);
                children[0] = .{ .origin = .{ .row = 0, .col = 0 }, .surface = base, .z_index = 0 };
                children[1] = .{ .origin = .{ .row = oy, .col = ox }, .surface = popup, .z_index = 1 };
                return vxfw.Surface.initWithChildren(ctx.arena, self.widget(), .{ .width = max_w, .height = max_h }, children);
            }
        }

        return base;
    }

    fn drawPreviewPopup(self: *ZipetRoot, ctx: vxfw.DrawContext, info: PreviewInfo) std.mem.Allocator.Error!vxfw.Surface {
        const accent = self.cfg.accent_color;
        const max_w = ctx.max.width orelse 80;
        const popup_w: u16 = @min(60, max_w -| 4);

        // Build content lines
        var lines = try ctx.arena.alloc(vxfw.FlexItem, 10);
        var count: usize = 0;

        // Name
        const name_line = try std.fmt.allocPrint(ctx.arena, "  {s}", .{info.name});
        const name_w = try ctx.arena.create(vxfw.Text);
        name_w.* = .{ .text = name_line, .style = t.accentBoldStyle(accent) };
        lines[count] = .{ .widget = name_w.widget(), .flex = 0 };
        count += 1;

        // Description
        if (info.desc.len > 0) {
            const desc_line = try std.fmt.allocPrint(ctx.arena, "  {s}", .{info.desc});
            const desc_w = try ctx.arena.create(vxfw.Text);
            desc_w.* = .{ .text = desc_line, .style = .{} };
            lines[count] = .{ .widget = desc_w.widget(), .flex = 0 };
            count += 1;
        }

        // Blank
        const blank = try ctx.arena.create(vxfw.Text);
        blank.* = .{ .text = " ", .style = .{} };
        lines[count] = .{ .widget = blank.widget(), .flex = 0 };
        count += 1;

        // Command / Category
        if (info.cmd.len > 0) {
            const cmd_label = if (std.mem.eql(u8, info.kind, "community pack") or std.mem.eql(u8, info.kind, "local pack")) "Category" else "Command";
            const cmd_line = try std.fmt.allocPrint(ctx.arena, "  {s}: {s}", .{ cmd_label, info.cmd });
            const cmd_w = try ctx.arena.create(vxfw.Text);
            cmd_w.* = .{ .text = cmd_line, .style = t.dim_style };
            lines[count] = .{ .widget = cmd_w.widget(), .flex = 0 };
            count += 1;
        }

        // Type + Namespace/Author
        {
            const type_line = if (info.namespace.len > 0)
                try std.fmt.allocPrint(ctx.arena, "  Type: {s}  |  {s}", .{ info.kind, info.namespace })
            else
                try std.fmt.allocPrint(ctx.arena, "  Type: {s}", .{info.kind});
            const type_w = try ctx.arena.create(vxfw.Text);
            type_w.* = .{ .text = type_line, .style = t.dim_style };
            lines[count] = .{ .widget = type_w.widget(), .flex = 0 };
            count += 1;
        }

        // Tags
        if (info.tags.len > 0) {
            var tag_buf: std.ArrayList(u8) = .{};
            const tw = tag_buf.writer(ctx.arena);
            try tw.writeAll("  Tags: ");
            for (info.tags, 0..) |tag_, ti| {
                if (ti > 0) try tw.writeAll(", ");
                try tw.writeAll(tag_);
            }
            const tag_line = try tag_buf.toOwnedSlice(ctx.arena);
            const tag_w = try ctx.arena.create(vxfw.Text);
            tag_w.* = .{ .text = tag_line, .style = t.accentStyle(accent) };
            lines[count] = .{ .widget = tag_w.widget(), .flex = 0 };
            count += 1;
        }

        // Hint
        const hint_w = try ctx.arena.create(vxfw.Text);
        hint_w.* = .{ .text = "  Space to close", .style = t.dim_style };
        lines[count] = .{ .widget = hint_w.widget(), .flex = 0 };
        count += 1;

        const col = try ctx.arena.create(vxfw.FlexColumn);
        col.* = .{ .children = lines[0..count] };

        // Wrap in border
        const label = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
        label[0] = .{ .text = "Preview", .alignment = .top_center };
        const border = try ctx.arena.create(vxfw.Border);
        border.* = .{ .child = col.widget(), .style = t.accentStyle(accent), .labels = label };

        // Draw with constrained width
        const popup_ctx = ctx.withConstraints(
            .{ .width = popup_w, .height = 0 },
            .{ .width = popup_w, .height = ctx.max.height },
        );
        return border.widget().draw(popup_ctx);
    }
};

// Re-export run as the public API
pub fn run(allocator: std.mem.Allocator, snip_store: *store.Store, cfg: config.Config, hist: *history_mod.History) !void {
    var state = t.State{};
    state.output = t.OutputBuf.init(allocator);
    defer state.output.deinit();
    defer if (state.output_title) |tt| allocator.free(tt);
    state.initSelectedSet(allocator);
    defer state.deinitSelectedSet();
    state.active_workspace = workspace_mod.getActiveWorkspace(allocator, cfg) catch null;
    defer if (state.active_workspace) |ws| allocator.free(ws);
    state.filtered_indices = try utils.updateFilterFrecency(allocator, snip_store, state.searchQuery(), null, hist);
    defer allocator.free(state.filtered_indices);

    // Defer cleanup for pack/workspace state
    defer {
        if (state.pack_preview_items.len > 0)
            pack_mod.freePackPreview(allocator, state.pack_preview_items);
        if (state.pack_list.len > 0)
            pack_mod.freePackMetas(allocator, state.pack_list);
        if (state.pack_filtered_indices.len > 0)
            allocator.free(state.pack_filtered_indices);
        if (state.ws_loaded)
            workspace_mod.freeWorkspaces(allocator, state.ws_list);
    }

    var root = ZipetRoot{
        .state = &state,
        .store = snip_store,
        .cfg = cfg,
        .hist = hist,
        .allocator = allocator,
        .output_view = .{ .state = &state, .cfg = cfg },
        .help_screen = .{ .state = &state, .cfg = cfg },
        .form_screen = .{ .state = &state, .snip_store = snip_store, .hist = hist, .cfg = cfg, .allocator = allocator, .fields = undefined },
        .param_input = .{ .state = &state, .snip_store = snip_store, .hist = hist, .cfg = cfg, .allocator = allocator, .fields = undefined },
        .workflow_form = .{ .state = &state, .snip_store = snip_store, .cfg = cfg, .allocator = allocator, .info_fields = undefined, .step_name_field = undefined, .step_cmd_field = undefined },
        .pack_browser = .{ .state = &state, .snip_store = snip_store, .cfg = cfg, .allocator = allocator },
        .pack_preview = .{ .state = &state, .snip_store = snip_store, .cfg = cfg, .allocator = allocator },
        .tag_picker = .{ .state = &state, .snip_store = snip_store, .hist = hist, .cfg = cfg, .allocator = allocator },
        .workspace_picker = .{ .state = &state, .snip_store = snip_store, .hist = hist, .cfg = cfg, .allocator = allocator },
        .main_screen = .{ .state = &state, .snip_store = snip_store, .cfg = cfg, .hist = hist, .allocator = allocator, .search_field = vxfw.TextField.init(allocator), .command_field = vxfw.TextField.init(allocator) },
    };
    root.form_screen.initFields();
    defer root.form_screen.deinitFields();
    root.param_input.initFields();
    defer root.param_input.deinitFields();
    root.workflow_form.initFields();
    defer root.workflow_form.deinitFields();
    defer root.main_screen.search_field.deinit();
    defer root.main_screen.command_field.deinit();

    var app = try vxfw.App.init(allocator);
    defer app.deinit();
    try app.run(root.widget(), .{ .framerate = 60 });
}
