const std = @import("std");
const cli = @import("cli.zig");
const tui = @import("tui.zig");
const store = @import("store.zig");
const config = @import("config.zig");
const workflow = @import("workflow.zig");
const pack = @import("pack.zig");
const workspace = @import("workspace.zig");
const history = @import("history.zig");

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // Load config
    var cfg = config.load(gpa) catch config.Config.default();

    // Detect active workspace (auto-detect by directory or explicit)
    const active_ws = workspace.getActiveWorkspace(gpa, cfg) catch null;
    defer if (active_ws) |aws| gpa.free(aws);
    cfg.active_workspace = active_ws;

    // Initialize store (loads snippets from the active workspace or global)
    var snip_store = store.Store.init(gpa, cfg) catch |err| {
        std.debug.print("Error: could not initialize store: {}\n", .{err});
        return err;
    };
    defer snip_store.deinit();
    defer workflow.deinitRegistry(gpa);

    // Initialize history (frecency tracking)
    var hist = history.History.init(gpa, cfg);
    defer hist.deinit();
    hist.load() catch {};

    // Parse and dispatch CLI commands
    if (args.len <= 1) {
        // No arguments → open TUI
        try tui.run(gpa, &snip_store, cfg, &hist);
    } else {
        try cli.dispatch(gpa, args[1..], &snip_store, cfg, &hist);
    }
}

test {
    _ = @import("toml.zig");
    _ = @import("fuzzy.zig");
    _ = @import("template.zig");
    _ = @import("store.zig");
    _ = @import("config.zig");
    _ = @import("workflow.zig");
    _ = @import("pack.zig");
    _ = @import("update.zig");
    _ = @import("workspace.zig");
    _ = @import("history.zig");
    _ = @import("highlight.zig");
    _ = @import("dag.zig");
    _ = @import("condition.zig");
}
