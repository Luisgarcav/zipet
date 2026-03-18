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
const vxfw = t.vxfw;

/// Root widget that routes between modes. Currently renders a placeholder;
/// real mode-specific widgets will be added in later migration tasks.
const ZipetRoot = struct {
    state: *t.State,
    store: *store.Store,
    cfg: config.Config,
    hist: *history_mod.History,
    allocator: std.mem.Allocator,

    pub fn widget(self: *ZipetRoot) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = ZipetRoot.handleEvent,
            .drawFn = ZipetRoot.draw,
        };
    }

    fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *ZipetRoot = @ptrCast(@alignCast(userdata));

        switch (event) {
            .key_press => |key| {
                if (key.codepoint == 'q') {
                    self.state.running = false;
                }
            },
            else => {},
        }

        // Bridge: sync state.running → vxfw quit
        if (!self.state.running) ctx.quit = true;
    }

    fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        _ = userdata;
        var label = vxfw.Text{ .text = "zipet - migrating to vxfw, press q to quit", .style = .{} };
        return label.widget().draw(ctx);
    }
};

// Re-export run as the public API
pub fn run(allocator: std.mem.Allocator, snip_store: *store.Store, cfg: config.Config, hist: *history_mod.History) !void {
    var state = t.State{};
    state.output = t.OutputBuf.init(allocator);
    defer state.output.deinit();
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
    };

    var app = try vxfw.App.init(allocator);
    defer app.deinit();
    try app.run(root.widget(), .{ .framerate = 60 });
}
