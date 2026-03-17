const std = @import("std");
const toml = @import("toml.zig");

pub const Config = struct {
    config_dir: []const u8,
    accent_color: Color,
    editor: []const u8,
    shell: []const u8,
    preview_enabled: bool,

    pub fn default() Config {
        return .{
            .config_dir = "~/.config/zipet",
            .accent_color = .cyan,
            .editor = "vi",
            .shell = "/bin/sh",
            .preview_enabled = true,
        };
    }

    pub fn getConfigDir(self: Config, allocator: std.mem.Allocator) ![]const u8 {
        // Check XDG_CONFIG_HOME first
        if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
            return std.fmt.allocPrint(allocator, "{s}/zipet", .{xdg});
        }
        if (std.mem.startsWith(u8, self.config_dir, "~/")) {
            const home = std.posix.getenv("HOME") orelse return error.NoHome;
            return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, self.config_dir[2..] });
        }
        return allocator.dupe(u8, self.config_dir);
    }

    pub fn getSnippetsDir(self: Config, allocator: std.mem.Allocator) ![]const u8 {
        const base = try self.getConfigDir(allocator);
        defer allocator.free(base);
        return std.fmt.allocPrint(allocator, "{s}/snippets", .{base});
    }

    pub fn getWorkflowsDir(self: Config, allocator: std.mem.Allocator) ![]const u8 {
        const base = try self.getConfigDir(allocator);
        defer allocator.free(base);
        return std.fmt.allocPrint(allocator, "{s}/workflows", .{base});
    }
};

pub const Color = enum {
    cyan,
    green,
    yellow,
    magenta,
    red,
    blue,
    white,

    pub fn ansiCode(self: Color) []const u8 {
        return switch (self) {
            .cyan => "\x1b[36m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .magenta => "\x1b[35m",
            .red => "\x1b[31m",
            .blue => "\x1b[34m",
            .white => "\x1b[37m",
        };
    }

    pub fn boldCode(self: Color) []const u8 {
        return switch (self) {
            .cyan => "\x1b[1;36m",
            .green => "\x1b[1;32m",
            .yellow => "\x1b[1;33m",
            .magenta => "\x1b[1;35m",
            .red => "\x1b[1;31m",
            .blue => "\x1b[1;34m",
            .white => "\x1b[1;37m",
        };
    }
};

fn colorFromString(s: []const u8) Color {
    if (std.mem.eql(u8, s, "cyan")) return .cyan;
    if (std.mem.eql(u8, s, "green")) return .green;
    if (std.mem.eql(u8, s, "yellow")) return .yellow;
    if (std.mem.eql(u8, s, "magenta")) return .magenta;
    if (std.mem.eql(u8, s, "red")) return .red;
    if (std.mem.eql(u8, s, "blue")) return .blue;
    if (std.mem.eql(u8, s, "white")) return .white;
    return .cyan;
}

pub fn load(allocator: std.mem.Allocator) !Config {
    var cfg = Config.default();

    // Try to read $EDITOR
    if (std.posix.getenv("EDITOR")) |editor| {
        cfg.editor = editor;
    }

    // Try to read $SHELL
    if (std.posix.getenv("SHELL")) |shell| {
        cfg.shell = shell;
    }

    // Try $XDG_CONFIG_HOME — store env pointer, getConfigDir builds the path
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        _ = xdg;
        // getConfigDir handles XDG via the env var directly
    }

    // Try to parse config.toml
    const config_path = try cfg.getConfigDir(allocator);
    defer allocator.free(config_path);

    const full_path = try std.fmt.allocPrint(allocator, "{s}/config.toml", .{config_path});
    defer allocator.free(full_path);

    // If config file exists, parse it
    const file = std.fs.openFileAbsolute(full_path, .{}) catch {
        return cfg; // No config file, use defaults
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 64);
    defer allocator.free(content);

    // Parse config TOML
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const table = toml.parse(arena_alloc, content) catch return cfg;

    // [general] section
    if (table.getString("general.accent_color")) |color_str| {
        cfg.accent_color = colorFromString(color_str);
    }
    if (table.get("general.preview")) |v| {
        switch (v) {
            .boolean => |b| cfg.preview_enabled = b,
            else => {},
        }
    }

    // [shell] section
    if (table.getString("shell.shell")) |s| {
        cfg.shell = s;
        // Note: s points into arena memory which will be freed,
        // but cfg.shell is only used during this process lifetime
        // and the env var fallback above already set it if available.
        // We need to dupe to survive arena deinit.
        cfg.shell = allocator.dupe(u8, s) catch cfg.shell;
    }
    if (table.getString("shell.editor")) |e| {
        cfg.editor = allocator.dupe(u8, e) catch cfg.editor;
    }

    return cfg;
}

test "config default" {
    const cfg = Config.default();
    try std.testing.expectEqualStrings("~/.config/zipet", cfg.config_dir);
    try std.testing.expect(cfg.preview_enabled);
}
