/// TUI for zipet — vim-native terminal interface using libvaxis.
/// This is the root module that wires together types, rendering, input, actions, and utils.
const std = @import("std");
const vaxis = @import("vaxis");
const store = @import("../store.zig");
const config = @import("../config.zig");
const workspace_mod = @import("../workspace.zig");

const t = @import("types.zig");
const render = @import("render.zig");
const input = @import("input.zig");
const utils = @import("utils.zig");

const Event = t.Event;
const OutputBuf = t.OutputBuf;

// Re-export run as the public API
pub fn run(allocator: std.mem.Allocator, snip_store: *store.Store, cfg: config.Config) !void {
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(&tty_buf);
    defer tty.deinit();

    var vx = try vaxis.init(allocator, .{});
    defer vx.deinit(allocator, tty.writer());

    var loop: vaxis.Loop(Event) = .{ .vaxis = &vx, .tty = &tty };
    try loop.init();
    try loop.start();
    defer loop.stop();

    const writer = tty.writer();
    try vx.enterAltScreen(writer);
    try vx.queryTerminal(writer, 1 * std.time.ns_per_s);
    try writer.flush();

    var state = t.State{};
    state.output = OutputBuf.init(allocator);
    defer state.output.deinit();
    state.initSelectedSet(allocator);
    defer state.deinitSelectedSet();
    state.active_workspace = workspace_mod.getActiveWorkspace(allocator, cfg) catch null;
    defer if (state.active_workspace) |ws| allocator.free(ws);
    state.filtered_indices = try utils.updateFilter(allocator, snip_store, state.searchQuery());
    defer allocator.free(state.filtered_indices);

    while (state.running) {
        const event = loop.nextEvent();
        switch (event) {
            .winsize => |ws| try vx.resize(allocator, writer, ws),
            .key_press => |key| try input.handleKeyPress(allocator, key, &state, snip_store, cfg),
            else => {},
        }

        const win = vx.window();
        win.clear();

        switch (state.mode) {
            .form => render.renderForm(win, &state, cfg),
            .param_input => render.renderParamInput(win, &state, snip_store, cfg),
            .output_view => render.renderOutputView(win, &state, cfg),
            .workspace_picker => {
                render.renderMainScreen(win, &state, snip_store, cfg);
                render.renderWorkspacePicker(win, &state, allocator, cfg);
            },
            .pack_browser => render.renderPackBrowser(win, &state, cfg),
            .pack_preview => render.renderPackPreview(win, &state, cfg),
            else => {
                render.renderMainScreen(win, &state, snip_store, cfg);
            },
        }

        // Cursor
        render.setCursor(win, &state);

        try vx.render(writer);
        try writer.flush();
    }

    try vx.exitAltScreen(writer);
    try writer.flush();
}
