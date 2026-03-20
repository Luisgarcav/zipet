/// Self-update module for zipet.
/// Downloads the latest release from GitHub and replaces the current binary.
const std = @import("std");

pub const version = "0.1.0";
const repo = "Luisgarcav/zipet";

pub const UpdateResult = struct {
    current: []const u8,
    latest: []const u8,
    updated: bool,
    err_msg: ?[]const u8,
};

fn writeOut(data: []const u8) void {
    std.fs.File.stdout().writeAll(data) catch {};
}

fn printOut(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, fmt, args) catch return;
    defer alloc.free(s);
    writeOut(s);
}

/// Detect platform string matching install.sh naming: e.g. "x86_64-linux", "aarch64-macos"
fn detectTarget(alloc: std.mem.Allocator) ![]const u8 {
    const tag = @import("builtin").target;
    const arch = switch (tag.cpu.arch) {
        .x86_64 => "x86_64",
        .aarch64 => "aarch64",
        else => return error.UnsupportedArch,
    };
    const os = switch (tag.os.tag) {
        .linux => "linux",
        .macos => "macos",
        else => return error.UnsupportedOS,
    };
    return std.fmt.allocPrint(alloc, "{s}-{s}", .{ arch, os });
}

/// Get the path of the currently running binary.
fn getSelfExePath(alloc: std.mem.Allocator) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fs.selfExePath(&buf);
    return try alloc.dupe(u8, path);
}

/// Fetch the latest release tag from GitHub API using curl.
fn fetchLatestTag(alloc: std.mem.Allocator) ![]const u8 {
    const api_url = "https://api.github.com/repos/" ++ repo ++ "/releases/latest";

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-sfL", "-H", "Accept: application/vnd.github.v3+json", api_url },
    }) catch return error.CurlFailed;
    defer alloc.free(result.stderr);
    defer alloc.free(result.stdout);

    if (result.term.Exited != 0) return error.ApiFailed;

    // Simple JSON parsing: find "tag_name": "vX.Y.Z" or "tag_name": "X.Y.Z"
    const tag_key = "\"tag_name\"";
    const idx = std.mem.indexOf(u8, result.stdout, tag_key) orelse return error.TagNotFound;
    const after_key = result.stdout[idx + tag_key.len ..];

    // Find the colon, then the opening quote
    const colon = std.mem.indexOfScalar(u8, after_key, ':') orelse return error.TagNotFound;
    const after_colon = after_key[colon + 1 ..];
    const open_quote = std.mem.indexOfScalar(u8, after_colon, '"') orelse return error.TagNotFound;
    const after_open = after_colon[open_quote + 1 ..];
    const close_quote = std.mem.indexOfScalar(u8, after_open, '"') orelse return error.TagNotFound;

    var tag_value = after_open[0..close_quote];
    // Strip leading 'v' if present (e.g. "v0.2.0" → "0.2.0")
    if (tag_value.len > 0 and tag_value[0] == 'v') {
        tag_value = tag_value[1..];
    }

    return try alloc.dupe(u8, tag_value);
}

/// Compare two semver strings. Returns .gt, .lt, or .eq.
fn compareSemver(a: []const u8, b: []const u8) std.math.Order {
    const a_parts = parseSemver(a);
    const b_parts = parseSemver(b);

    if (a_parts[0] != b_parts[0]) return std.math.order(a_parts[0], b_parts[0]);
    if (a_parts[1] != b_parts[1]) return std.math.order(a_parts[1], b_parts[1]);
    return std.math.order(a_parts[2], b_parts[2]);
}

fn parseSemver(s: []const u8) [3]u32 {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var iter = std.mem.splitScalar(u8, s, '.');
    var i: usize = 0;
    while (iter.next()) |part| {
        if (i >= 3) break;
        parts[i] = std.fmt.parseInt(u32, part, 10) catch 0;
        i += 1;
    }
    return parts;
}

/// Perform the self-update.
pub fn selfUpdate(alloc: std.mem.Allocator, force: bool) !void {
    writeOut("\x1b[1;36m▸ zipet self-update\x1b[0m\n\n");

    printOut(alloc, "  Current version: \x1b[1m{s}\x1b[0m\n", .{version});

    // Fetch latest
    writeOut("  Checking for updates...");
    const latest = fetchLatestTag(alloc) catch |err| {
        writeOut("\n\n");
        switch (err) {
            error.CurlFailed => writeOut("\x1b[31m✗ curl not found. Install curl and try again.\x1b[0m\n"),
            error.ApiFailed => writeOut("\x1b[31m✗ Could not reach GitHub API. Check your connection.\x1b[0m\n"),
            error.TagNotFound => writeOut("\x1b[31m✗ No releases found on GitHub.\x1b[0m\n"),
            else => printOut(alloc, "\x1b[31m✗ Unexpected error: {}\x1b[0m\n", .{err}),
        }
        return;
    };
    defer alloc.free(latest);

    printOut(alloc, " \x1b[1m{s}\x1b[0m\n", .{latest});

    // Compare
    const order = compareSemver(latest, version);
    if (order == .eq) {
        writeOut("\n  \x1b[32m✓ Already up to date!\x1b[0m\n");
        return;
    }
    if (order == .lt) {
        writeOut("\n  \x1b[33m⚠ Local version is newer than latest release.\x1b[0m\n");
        if (!force) return;
    }

    printOut(alloc, "\n  Updating \x1b[1m{s}\x1b[0m → \x1b[1;32m{s}\x1b[0m\n\n", .{ version, latest });

    // Detect target
    const target = detectTarget(alloc) catch {
        writeOut("\x1b[31m✗ Unsupported platform for self-update.\x1b[0m\n");
        return;
    };
    defer alloc.free(target);

    // Get current binary path
    const self_path = getSelfExePath(alloc) catch {
        writeOut("\x1b[31m✗ Could not determine binary location.\x1b[0m\n");
        writeOut("  Try reinstalling with the install script:\n");
        writeOut("  curl -sSL https://raw.githubusercontent.com/" ++ repo ++ "/main/scripts/install.sh | bash\n");
        return;
    };
    defer alloc.free(self_path);

    printOut(alloc, "  Binary: {s}\n", .{self_path});
    printOut(alloc, "  Target: {s}\n", .{target});

    // Download to temp file
    const download_url = try std.fmt.allocPrint(
        alloc,
        "https://github.com/{s}/releases/latest/download/zipet-{s}.tar.gz",
        .{ repo, target },
    );
    defer alloc.free(download_url);

    writeOut("  Downloading...");

    // Create temp dir
    const tmpdir = "/tmp/zipet-update";
    // Clean up any previous attempt
    std.fs.deleteTreeAbsolute(tmpdir) catch {};
    std.fs.makeDirAbsolute(tmpdir) catch {
        writeOut("\n\x1b[31m✗ Could not create temp directory.\x1b[0m\n");
        return;
    };
    defer std.fs.deleteTreeAbsolute(tmpdir) catch {};

    const tarball = tmpdir ++ "/zipet.tar.gz";

    // Download
    const dl_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "curl", "-sfL", "-o", tarball, download_url },
    }) catch {
        writeOut("\n\x1b[31m✗ Download failed.\x1b[0m\n");
        return;
    };
    defer alloc.free(dl_result.stdout);
    defer alloc.free(dl_result.stderr);

    if (dl_result.term.Exited != 0) {
        writeOut("\n\x1b[31m✗ Download failed. Release may not exist for your platform.\x1b[0m\n");
        return;
    }

    // Extract
    const extract_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "tar", "-xzf", tarball, "-C", tmpdir },
    }) catch {
        writeOut("\n\x1b[31m✗ Extraction failed.\x1b[0m\n");
        return;
    };
    defer alloc.free(extract_result.stdout);
    defer alloc.free(extract_result.stderr);

    if (extract_result.term.Exited != 0) {
        writeOut("\n\x1b[31m✗ Failed to extract archive.\x1b[0m\n");
        return;
    }

    const new_binary = tmpdir ++ "/zipet";

    // Verify the new binary exists
    std.fs.accessAbsolute(new_binary, .{}) catch {
        writeOut("\n\x1b[31m✗ Binary not found in archive.\x1b[0m\n");
        return;
    };

    writeOut(" done\n");

    // Replace: rename old → .bak, copy new, remove .bak
    const backup_path = try std.fmt.allocPrint(alloc, "{s}.bak", .{self_path});
    defer alloc.free(backup_path);

    // Remove old backup if it exists
    std.fs.deleteFileAbsolute(backup_path) catch {};

    // Rename current → backup
    std.fs.renameAbsolute(self_path, backup_path) catch {
        // If rename fails (different filesystem), try copy approach
        writeOut("  Replacing binary...");

        const cp_result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "cp", "-f", new_binary, self_path },
        }) catch {
            writeOut("\n\x1b[31m✗ Failed to replace binary. Try with sudo or reinstall.\x1b[0m\n");
            return;
        };
        defer alloc.free(cp_result.stdout);
        defer alloc.free(cp_result.stderr);

        if (cp_result.term.Exited != 0) {
            writeOut("\n\x1b[31m✗ Permission denied. Try:\x1b[0m\n");
            printOut(alloc, "  sudo cp {s} {s}\n", .{ new_binary, self_path });
            return;
        }

        // Make executable
        const chmod_result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = &.{ "chmod", "+x", self_path },
        }) catch null;
        if (chmod_result) |cr| {
            alloc.free(cr.stdout);
            alloc.free(cr.stderr);
        }

        writeOut(" done\n");
        printOut(alloc, "\n  \x1b[32m✓ Updated to {s}! 🐾\x1b[0m\n", .{latest});
        return;
    };

    // Copy new binary to the original path
    const cp2_result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "cp", "-f", new_binary, self_path },
    }) catch {
        // Restore backup
        std.fs.renameAbsolute(backup_path, self_path) catch {};
        writeOut("\n\x1b[31m✗ Failed to install new binary. Restored previous version.\x1b[0m\n");
        return;
    };
    defer alloc.free(cp2_result.stdout);
    defer alloc.free(cp2_result.stderr);

    if (cp2_result.term.Exited != 0) {
        // Restore backup
        std.fs.renameAbsolute(backup_path, self_path) catch {};
        writeOut("\x1b[31m✗ Failed to install new binary. Restored previous version.\x1b[0m\n");
        return;
    }

    // Make executable
    const chmod_res = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "chmod", "+x", self_path },
    }) catch null;
    if (chmod_res) |cr| {
        alloc.free(cr.stdout);
        alloc.free(cr.stderr);
    }

    // Remove backup
    std.fs.deleteFileAbsolute(backup_path) catch {};

    printOut(alloc, "\n  \x1b[32m✓ Updated to {s}! 🐾\x1b[0m\n", .{latest});
}

// ── Tests ──
test "parseSemver" {
    const a = parseSemver("0.1.0");
    try std.testing.expectEqual([3]u32{ 0, 1, 0 }, a);

    const b = parseSemver("1.23.456");
    try std.testing.expectEqual([3]u32{ 1, 23, 456 }, b);
}

test "compareSemver" {
    try std.testing.expectEqual(std.math.Order.eq, compareSemver("0.1.0", "0.1.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareSemver("0.2.0", "0.1.0"));
    try std.testing.expectEqual(std.math.Order.lt, compareSemver("0.1.0", "0.2.0"));
    try std.testing.expectEqual(std.math.Order.gt, compareSemver("1.0.0", "0.9.9"));
}
