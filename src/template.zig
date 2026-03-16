/// Template engine for zipet.
/// Handles {{param}} interpolation, built-in variables, and parameter detection.
const std = @import("std");

pub const Param = struct {
    name: []const u8,
    prompt: ?[]const u8 = null,
    default: ?[]const u8 = null,
    options: ?[]const []const u8 = null,
    command: ?[]const u8 = null,
};

/// Detect all {{param}} placeholders in a template string.
/// Returns unique parameter names found (excludes builtins).
pub fn detectParams(allocator: std.mem.Allocator, tmpl: []const u8) ![]const []const u8 {
    var params: std.ArrayList([]const u8) = .{};
    var i: usize = 0;

    while (i + 1 < tmpl.len) {
        if (tmpl[i] == '{' and tmpl[i + 1] == '{') {
            i += 2;
            while (i < tmpl.len and tmpl[i] == ' ') i += 1;
            const start = i;
            while (i < tmpl.len and tmpl[i] != '}' and tmpl[i] != ' ') i += 1;
            const name = tmpl[start..i];
            while (i + 1 < tmpl.len) {
                if (tmpl[i] == '}' and tmpl[i + 1] == '}') {
                    i += 2;
                    break;
                }
                i += 1;
            }

            if (name.len > 0 and !isBuiltin(name)) {
                var found = false;
                for (params.items) |existing| {
                    if (std.mem.eql(u8, existing, name)) {
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    try params.append(allocator, try allocator.dupe(u8, name));
                }
            }
        } else {
            i += 1;
        }
    }

    return try params.toOwnedSlice(allocator);
}

pub fn isBuiltin(name: []const u8) bool {
    const builtins = [_][]const u8{
        "git_branch",  "git_sha",   "git_root",
        "date",        "datetime",  "timestamp",
        "hostname",    "user",      "cwd",
        "os",          "arch",      "clipboard",
        "last_output", "last_exit",
    };
    for (builtins) |b| {
        if (std.mem.eql(u8, name, b)) return true;
    }
    return false;
}

pub fn resolveBuiltin(allocator: std.mem.Allocator, name: []const u8) !?[]const u8 {
    if (std.mem.eql(u8, name, "user")) {
        if (std.posix.getenv("USER")) |u| return try allocator.dupe(u8, u);
        return null;
    }
    if (std.mem.eql(u8, name, "hostname")) {
        var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = std.posix.gethostname(&buf) catch return null;
        return try allocator.dupe(u8, hostname);
    }
    if (std.mem.eql(u8, name, "cwd")) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.posix.getcwd(&buf) catch return null;
        return try allocator.dupe(u8, cwd);
    }
    if (std.mem.eql(u8, name, "os")) {
        return try allocator.dupe(u8, @tagName(std.Target.Os.Tag.linux));
    }
    if (std.mem.eql(u8, name, "arch")) {
        return try allocator.dupe(u8, @tagName(@import("builtin").cpu.arch));
    }
    if (std.mem.eql(u8, name, "date")) {
        return try getDate(allocator);
    }
    if (std.mem.eql(u8, name, "timestamp")) {
        const ts = std.time.timestamp();
        return try std.fmt.allocPrint(allocator, "{d}", .{ts});
    }
    if (std.mem.eql(u8, name, "git_branch")) {
        return try runCapture(allocator, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
    }
    if (std.mem.eql(u8, name, "git_sha")) {
        return try runCapture(allocator, &.{ "git", "rev-parse", "--short", "HEAD" });
    }
    if (std.mem.eql(u8, name, "git_root")) {
        return try runCapture(allocator, &.{ "git", "rev-parse", "--show-toplevel" });
    }
    return null;
}

/// Interpolate all {{param}} placeholders in a template.
pub fn render(allocator: std.mem.Allocator, tmpl: []const u8, keys: []const []const u8, values: []const []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    var i: usize = 0;

    while (i < tmpl.len) {
        if (i + 1 < tmpl.len and tmpl[i] == '{' and tmpl[i + 1] == '{') {
            i += 2;
            while (i < tmpl.len and tmpl[i] == ' ') i += 1;
            const start = i;
            while (i < tmpl.len and tmpl[i] != '}' and tmpl[i] != ' ') i += 1;
            const name = tmpl[start..i];
            while (i + 1 < tmpl.len) {
                if (tmpl[i] == '}' and tmpl[i + 1] == '}') {
                    i += 2;
                    break;
                }
                i += 1;
            }

            var found = false;
            for (keys, values) |k, v| {
                if (std.mem.eql(u8, k, name)) {
                    try result.appendSlice(allocator, v);
                    found = true;
                    break;
                }
            }
            if (!found) {
                if (try resolveBuiltin(allocator, name)) |builtin_val| {
                    defer allocator.free(builtin_val);
                    try result.appendSlice(allocator, builtin_val);
                } else {
                    try result.appendSlice(allocator, "{{");
                    try result.appendSlice(allocator, name);
                    try result.appendSlice(allocator, "}}");
                }
            }
        } else {
            try result.append(allocator, tmpl[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

fn getDate(allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.time.timestamp();
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(ts) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
    });
}

fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch return null;
    defer allocator.free(result.stderr);

    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return null;
    }

    var out = result.stdout;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
        out = out[0 .. out.len - 1];
    }

    if (out.len == result.stdout.len) return out;
    const trimmed = try allocator.dupe(u8, out);
    allocator.free(result.stdout);
    return trimmed;
}

// ── Tests ──────────────────────────────────────────────────────

test "detect params" {
    const gpa = std.testing.allocator;
    const params = try detectParams(gpa, "docker build -t {{image}}:{{tag}} .");
    defer {
        for (params) |p| gpa.free(p);
        gpa.free(params);
    }

    try std.testing.expectEqual(@as(usize, 2), params.len);
    try std.testing.expectEqualStrings("image", params[0]);
    try std.testing.expectEqualStrings("tag", params[1]);
}

test "detect params skips builtins" {
    const gpa = std.testing.allocator;
    const params = try detectParams(gpa, "echo {{user}} builds {{image}}");
    defer {
        for (params) |p| gpa.free(p);
        gpa.free(params);
    }

    try std.testing.expectEqual(@as(usize, 1), params.len);
    try std.testing.expectEqualStrings("image", params[0]);
}

test "detect params deduplicates" {
    const gpa = std.testing.allocator;
    const params = try detectParams(gpa, "{{x}} and {{x}} again");
    defer {
        for (params) |p| gpa.free(p);
        gpa.free(params);
    }

    try std.testing.expectEqual(@as(usize, 1), params.len);
}

test "render template" {
    const gpa = std.testing.allocator;
    const result = try render(gpa, "docker build -t {{image}}:{{tag}} .", &.{ "image", "tag" }, &.{ "myapp", "latest" });
    defer gpa.free(result);

    try std.testing.expectEqualStrings("docker build -t myapp:latest .", result);
}

test "render preserves unknown" {
    const gpa = std.testing.allocator;
    const result = try render(gpa, "echo {{unknown}}", &.{}, &.{});
    defer gpa.free(result);

    try std.testing.expectEqualStrings("echo {{unknown}}", result);
}
