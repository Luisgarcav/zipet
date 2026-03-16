const std = @import("std");
const cli = @import("cli.zig");
const tui = @import("tui.zig");
const store = @import("store.zig");
const config = @import("config.zig");

pub fn main() !void {
    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    // Load config
    const cfg = config.load(gpa) catch config.Config.default();

    // Initialize store
    var snip_store = store.Store.init(gpa, cfg) catch |err| {
        std.debug.print("Error: could not initialize store: {}\n", .{err});
        return err;
    };
    defer snip_store.deinit();

    // Parse and dispatch CLI commands
    if (args.len <= 1) {
        // No arguments → open TUI
        try tui.run(gpa, &snip_store, cfg);
    } else {
        try cli.dispatch(gpa, args[1..], &snip_store, cfg);
    }
}

test {
    _ = @import("toml.zig");
    _ = @import("fuzzy.zig");
    _ = @import("template.zig");
    _ = @import("store.zig");
    _ = @import("config.zig");
}
