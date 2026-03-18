/// Workspace manager for zipet — organize snippets by context/project/directory.
/// Workspaces are subdirectories under ~/.config/zipet/workspaces/<name>/
/// Each workspace has its own snippets/ and workflows/ directories.
/// The active workspace is stored in ~/.config/zipet/active_workspace
const std = @import("std");
const config = @import("config.zig");
const toml = @import("toml.zig");

pub const Workspace = struct {
    name: []const u8,
    description: []const u8,
    path: []const u8, // optional: associated project directory
    snippet_count: usize,
    workflow_count: usize,
};

/// Get the workspaces base directory
pub fn getWorkspacesDir(allocator: std.mem.Allocator, cfg: config.Config) ![]const u8 {
    const base = try cfg.getConfigDir(allocator);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/workspaces", .{base});
}

/// Get a specific workspace directory
pub fn getWorkspaceDir(allocator: std.mem.Allocator, cfg: config.Config, name: []const u8) ![]const u8 {
    const base = try getWorkspacesDir(allocator, cfg);
    defer allocator.free(base);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
}

/// Get the snippets dir for a workspace
pub fn getWorkspaceSnippetsDir(allocator: std.mem.Allocator, cfg: config.Config, name: []const u8) ![]const u8 {
    const ws_dir = try getWorkspaceDir(allocator, cfg, name);
    defer allocator.free(ws_dir);
    return std.fmt.allocPrint(allocator, "{s}/snippets", .{ws_dir});
}

/// Get the workflows dir for a workspace
pub fn getWorkspaceWorkflowsDir(allocator: std.mem.Allocator, cfg: config.Config, name: []const u8) ![]const u8 {
    const ws_dir = try getWorkspaceDir(allocator, cfg, name);
    defer allocator.free(ws_dir);
    return std.fmt.allocPrint(allocator, "{s}/workflows", .{ws_dir});
}

/// Read the active workspace name (null = "default" / global)
/// First checks if the current directory matches any workspace's project path,
/// then falls back to the stored active_workspace file.
pub fn getActiveWorkspace(allocator: std.mem.Allocator, cfg: config.Config) !?[]const u8 {
    // 1. Auto-detect by current working directory
    if (detectWorkspaceByDir(allocator, cfg)) |ws_name| {
        return ws_name;
    } else |_| {}

    // 2. Fall back to explicit active_workspace file
    const config_dir = try cfg.getConfigDir(allocator);
    defer allocator.free(config_dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/active_workspace", .{config_dir});
    defer allocator.free(path);

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024) catch return null;
    const trimmed = std.mem.trim(u8, content, " \t\n\r");
    if (trimmed.len == 0) {
        allocator.free(content);
        return null;
    }
    if (trimmed.len == content.len) return content;
    const duped = try allocator.dupe(u8, trimmed);
    allocator.free(content);
    return duped;
}

/// Detect workspace by matching cwd (or any parent) against workspace paths.
/// Returns the workspace name if found, null otherwise.
pub fn detectWorkspaceByDir(allocator: std.mem.Allocator, cfg: config.Config) !?[]const u8 {
    const cwd_buf = std.fs.cwd().realpathAlloc(allocator, ".") catch return null;
    defer allocator.free(cwd_buf);

    const ws_base = try getWorkspacesDir(allocator, cfg);
    defer allocator.free(ws_base);

    // Ensure directory exists
    std.fs.makeDirAbsolute(ws_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return null,
    };

    var dir = std.fs.openDirAbsolute(ws_base, .{ .iterate = true }) catch return null;
    defer dir.close();

    var best_match: ?[]const u8 = null;
    var best_len: usize = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const meta_path = try std.fmt.allocPrint(allocator, "{s}/{s}/workspace.toml", .{ ws_base, entry.name });
        defer allocator.free(meta_path);

        const meta_file = std.fs.openFileAbsolute(meta_path, .{}) catch continue;
        defer meta_file.close();

        const content = meta_file.readToEndAlloc(allocator, 1024 * 64) catch continue;
        defer allocator.free(content);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        const table = toml.parse(arena.allocator(), content) catch continue;

        const ws_path = table.getString("workspace.path") orelse continue;
        if (ws_path.len == 0) continue;

        // Resolve ~ in workspace path
        const resolved = if (std.mem.startsWith(u8, ws_path, "~/")) blk: {
            const home = std.posix.getenv("HOME") orelse continue;
            break :blk std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, ws_path[2..] }) catch continue;
        } else blk: {
            break :blk allocator.dupe(u8, ws_path) catch continue;
        };
        defer allocator.free(resolved);

        // Check if cwd starts with (or equals) the workspace path
        // This handles being in a subdirectory of the project
        if (std.mem.eql(u8, cwd_buf, resolved) or
            (std.mem.startsWith(u8, cwd_buf, resolved) and
            cwd_buf.len > resolved.len and
            cwd_buf[resolved.len] == '/'))
        {
            // Longest match wins (most specific project dir)
            if (resolved.len > best_len) {
                if (best_match) |prev| allocator.free(prev);
                best_match = allocator.dupe(u8, entry.name) catch continue;
                best_len = resolved.len;
            }
        }
    }

    return best_match;
}

/// Set the active workspace
pub fn setActiveWorkspace(allocator: std.mem.Allocator, cfg: config.Config, name: ?[]const u8) !void {
    const config_dir = try cfg.getConfigDir(allocator);
    defer allocator.free(config_dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/active_workspace", .{config_dir});
    defer allocator.free(path);

    if (name) |n| {
        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(n);
    } else {
        std.fs.deleteFileAbsolute(path) catch {};
    }
}

/// Create a new workspace
pub fn create(allocator: std.mem.Allocator, cfg: config.Config, name: []const u8, description: []const u8, project_path: ?[]const u8) !void {
    const ws_dir = try getWorkspaceDir(allocator, cfg, name);
    defer allocator.free(ws_dir);

    // Create workspace directory structure
    std.fs.makeDirAbsolute(ws_dir) catch |err| switch (err) {
        error.PathAlreadyExists => return error.AlreadyExists,
        else => return err,
    };

    const snippets_dir = try std.fmt.allocPrint(allocator, "{s}/snippets", .{ws_dir});
    defer allocator.free(snippets_dir);
    std.fs.makeDirAbsolute(snippets_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const workflows_dir = try std.fmt.allocPrint(allocator, "{s}/workflows", .{ws_dir});
    defer allocator.free(workflows_dir);
    std.fs.makeDirAbsolute(workflows_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Write workspace metadata
    const meta_path = try std.fmt.allocPrint(allocator, "{s}/workspace.toml", .{ws_dir});
    defer allocator.free(meta_path);

    const file = try std.fs.createFileAbsolute(meta_path, .{});
    defer file.close();

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.print("# zipet workspace — {s}\n\n", .{name});
    try writer.print("[workspace]\n", .{});
    try writer.print("name = \"{s}\"\n", .{name});
    try writer.print("description = \"{s}\"\n", .{description});
    if (project_path) |pp| {
        try writer.print("path = \"{s}\"\n", .{pp});
    }

    try file.writeAll(buf.items);
}

/// List all workspaces
pub fn list(allocator: std.mem.Allocator, cfg: config.Config) ![]Workspace {
    const ws_base = try getWorkspacesDir(allocator, cfg);
    defer allocator.free(ws_base);

    // Ensure directory exists
    std.fs.makeDirAbsolute(ws_base) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var result: std.ArrayList(Workspace) = .{};

    var dir = std.fs.openDirAbsolute(ws_base, .{ .iterate = true }) catch {
        return try result.toOwnedSlice(allocator);
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;

        const meta_path = try std.fmt.allocPrint(allocator, "{s}/{s}/workspace.toml", .{ ws_base, entry.name });
        defer allocator.free(meta_path);

        var description: []const u8 = "";
        var project_path: []const u8 = "";

        // Try to read metadata
        if (std.fs.openFileAbsolute(meta_path, .{})) |meta_file| {
            defer meta_file.close();
            const content = meta_file.readToEndAlloc(allocator, 1024 * 64) catch "";
            defer if (content.len > 0) allocator.free(content);

            if (content.len > 0) {
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                if (toml.parse(arena.allocator(), content)) |table| {
                    if (table.getString("workspace.description")) |d| {
                        description = try allocator.dupe(u8, d);
                    }
                    if (table.getString("workspace.path")) |p| {
                        project_path = try allocator.dupe(u8, p);
                    }
                } else |_| {}
            }
        } else |_| {}

        // Count snippets and workflows
        const snip_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}/snippets", .{ ws_base, entry.name });
        defer allocator.free(snip_dir_path);
        const snip_count = countTomlFiles(snip_dir_path);

        const wf_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}/workflows", .{ ws_base, entry.name });
        defer allocator.free(wf_dir_path);
        const wf_count = countTomlFiles(wf_dir_path);

        try result.append(allocator, .{
            .name = try allocator.dupe(u8, entry.name),
            .description = description,
            .path = project_path,
            .snippet_count = snip_count,
            .workflow_count = wf_count,
        });
    }

    return try result.toOwnedSlice(allocator);
}

fn countTomlFiles(dir_path: []const u8) usize {
    var d = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return 0;
    defer d.close();
    var count: usize = 0;
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".toml")) count += 1;
    }
    return count;
}

/// Remove a workspace
pub fn remove(allocator: std.mem.Allocator, cfg: config.Config, name: []const u8) !void {
    const ws_dir = try getWorkspaceDir(allocator, cfg, name);
    defer allocator.free(ws_dir);

    // Check if it's the active workspace
    const active = try getActiveWorkspace(allocator, cfg);
    if (active) |a| {
        defer allocator.free(a);
        if (std.mem.eql(u8, a, name)) {
            try setActiveWorkspace(allocator, cfg, null);
        }
    }

    // Remove recursively
    std.fs.deleteTreeAbsolute(ws_dir) catch return error.NotFound;
}

/// Free a workspace list
pub fn freeWorkspaces(allocator: std.mem.Allocator, workspaces: []Workspace) void {
    for (workspaces) |ws| {
        allocator.free(ws.name);
        if (ws.description.len > 0) allocator.free(ws.description);
        if (ws.path.len > 0) allocator.free(ws.path);
    }
    allocator.free(workspaces);
}

pub const AlreadyExists = error.AlreadyExists;
