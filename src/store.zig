/// Snippet store — manages loading, saving, and querying snippets from TOML files.
const std = @import("std");
const toml = @import("toml.zig");
const config = @import("config.zig");
const template = @import("template.zig");
const fuzzy = @import("fuzzy.zig");
const workflow_mod = @import("workflow.zig");

pub const Snippet = struct {
    name: []const u8,
    desc: []const u8,
    cmd: []const u8,
    tags: []const []const u8,
    params: []const template.Param,
    namespace: []const u8,
    kind: Kind,

    pub const Kind = enum { snippet, chain, workflow };

    pub fn displayName(self: Snippet, allocator: std.mem.Allocator) ![]const u8 {
        const prefix: []const u8 = switch (self.kind) {
            .snippet => "",
            .chain => "[chain] ",
            .workflow => "[workflow] ",
        };
        return std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, self.name });
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    snippets: std.ArrayList(Snippet),
    cfg: config.Config,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) !Store {
        var self = Store{
            .allocator = allocator,
            .snippets = .{},
            .cfg = cfg,
        };

        self.ensureDirs() catch {};
        try self.loadAll();

        return self;
    }

    pub fn deinit(self: *Store) void {
        for (self.snippets.items) |snip| {
            self.freeSnippet(snip);
        }
        self.snippets.deinit(self.allocator);
    }

    pub fn freeSnippet(self: *Store, snip: Snippet) void {
        self.allocator.free(snip.name);
        self.allocator.free(snip.desc);
        self.allocator.free(snip.cmd);
        for (snip.tags) |t| self.allocator.free(t);
        self.allocator.free(snip.tags);
        for (snip.params) |p| {
            self.allocator.free(p.name);
            if (p.prompt) |pr| self.allocator.free(pr);
            if (p.default) |d| self.allocator.free(d);
            if (p.command) |c| self.allocator.free(c);
            if (p.options) |opts| {
                for (opts) |o| self.allocator.free(o);
                self.allocator.free(opts);
            }
        }
        self.allocator.free(snip.params);
        self.allocator.free(snip.namespace);
    }

    fn ensureDirs(self: *Store) !void {
        const config_dir = try self.cfg.getConfigDir(self.allocator);
        defer self.allocator.free(config_dir);
        std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const snippets_dir = try self.cfg.getSnippetsDir(self.allocator);
        defer self.allocator.free(snippets_dir);
        std.fs.makeDirAbsolute(snippets_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };

        const workflows_dir = try self.cfg.getWorkflowsDir(self.allocator);
        defer self.allocator.free(workflows_dir);
        std.fs.makeDirAbsolute(workflows_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    pub fn loadAll(self: *Store) !void {
        // Always load global snippets first
        const global_snippets = try self.cfg.getGlobalSnippetsDir(self.allocator);
        defer self.allocator.free(global_snippets);
        try self.loadSnippetsFromDir(global_snippets);

        const global_workflows = try self.cfg.getGlobalWorkflowsDir(self.allocator);
        defer self.allocator.free(global_workflows);
        try self.loadWorkflowsFromDir(global_workflows);

        // If a workspace is active, also load workspace-specific snippets/workflows
        if (self.cfg.active_workspace != null) {
            const ws_snippets = try self.cfg.getSnippetsDir(self.allocator);
            defer self.allocator.free(ws_snippets);

            // Only load if it's a different directory than global
            if (!std.mem.eql(u8, ws_snippets, global_snippets)) {
                try self.loadSnippetsFromDir(ws_snippets);
            }

            const ws_workflows = try self.cfg.getWorkflowsDir(self.allocator);
            defer self.allocator.free(ws_workflows);

            if (!std.mem.eql(u8, ws_workflows, global_workflows)) {
                try self.loadWorkflowsFromDir(ws_workflows);
            }
        }
    }

    fn loadSnippetsFromDir(self: *Store, snippets_dir: []const u8) !void {
        if (std.fs.openDirAbsolute(snippets_dir, .{ .iterate = true })) |*dir_ptr| {
            var dir = dir_ptr.*;
            defer dir.close();

            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;

                const namespace = try self.allocator.dupe(u8, entry.name[0 .. entry.name.len - 5]);
                defer self.allocator.free(namespace);

                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ snippets_dir, entry.name });
                defer self.allocator.free(path);

                self.loadFile(path, namespace) catch |err| {
                    std.debug.print("Warning: could not load {s}: {}\n", .{ entry.name, err });
                    continue;
                };
            }
        } else |_| {}
    }

    fn loadWorkflowsFromDir(self: *Store, workflows_dir: []const u8) !void {
        if (std.fs.openDirAbsolute(workflows_dir, .{ .iterate = true })) |*dir_ptr| {
            var dir = dir_ptr.*;
            defer dir.close();

            var iter = dir.iterate();
            while (try iter.next()) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".toml")) continue;

                const namespace = try self.allocator.dupe(u8, entry.name[0 .. entry.name.len - 5]);
                defer self.allocator.free(namespace);

                const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ workflows_dir, entry.name });
                defer self.allocator.free(path);

                workflow_mod.loadWorkflowFile(self.allocator, path, namespace, self) catch |err| {
                    std.debug.print("Warning: could not load workflow {s}: {}\n", .{ entry.name, err });
                    continue;
                };
            }
        } else |_| {}
    }

    fn loadFile(self: *Store, path: []const u8, namespace: []const u8) !void {
        const file = try std.fs.openFileAbsolute(path, .{});
        defer file.close();

        const content = try file.readToEndAlloc(self.allocator, 1024 * 256);
        defer self.allocator.free(content);

        // Use arena for TOML parsing — all parse allocations freed at once
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const table = try toml.parse(arena_alloc, content);

        // Collect snippet names from keys like "snippets.<name>.cmd"
        var snippet_names = std.StringHashMap(void).init(self.allocator);
        defer {
            var key_iter = snippet_names.keyIterator();
            while (key_iter.next()) |k| {
                self.allocator.free(k.*);
            }
            snippet_names.deinit();
        }

        for (table.keys) |key| {
            if (std.mem.startsWith(u8, key, "snippets.")) {
                const rest = key["snippets.".len..];
                if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                    const name = rest[0..dot];
                    if (!snippet_names.contains(name)) {
                        try snippet_names.put(try self.allocator.dupe(u8, name), {});
                    }
                }
            }
        }

        var name_iter = snippet_names.keyIterator();
        while (name_iter.next()) |name_ptr| {
            const sname = name_ptr.*;

            const cmd_key = try std.fmt.allocPrint(self.allocator, "snippets.{s}.cmd", .{sname});
            defer self.allocator.free(cmd_key);

            const desc_key = try std.fmt.allocPrint(self.allocator, "snippets.{s}.desc", .{sname});
            defer self.allocator.free(desc_key);

            const tags_key = try std.fmt.allocPrint(self.allocator, "snippets.{s}.tags", .{sname});
            defer self.allocator.free(tags_key);

            const cmd_val = table.getString(cmd_key) orelse continue;
            const desc_val = table.getString(desc_key) orelse "";

            var tags: std.ArrayList([]const u8) = .{};
            if (table.getArray(tags_key)) |arr| {
                for (arr) |item| {
                    switch (item) {
                        .string => |s| try tags.append(self.allocator, try self.allocator.dupe(u8, s)),
                        else => {},
                    }
                }
            }

            const detected = try template.detectParams(self.allocator, cmd_val);
            defer self.allocator.free(detected); // free the slice, names are moved to params
            const params = try self.allocator.alloc(template.Param, detected.len);
            for (detected, 0..) |pname, i| {
                params[i] = .{
                    .name = pname,
                    .prompt = null,
                    .default = null,
                    .options = null,
                    .command = null,
                };

                const param_prefix = try std.fmt.allocPrint(self.allocator, "snippets.{s}.params.{s}", .{ sname, pname });
                defer self.allocator.free(param_prefix);

                for (table.keys, table.values) |tk, tv| {
                    if (std.mem.eql(u8, tk, param_prefix)) {
                        switch (tv) {
                            .table => |pt| {
                                if (pt.getString("prompt")) |pr| {
                                    params[i].prompt = try self.allocator.dupe(u8, pr);
                                }
                                if (pt.getString("default")) |d| {
                                    params[i].default = try self.allocator.dupe(u8, d);
                                }
                                if (pt.getString("command")) |c| {
                                    params[i].command = try self.allocator.dupe(u8, c);
                                }
                            },
                            else => {},
                        }
                    }
                }
            }

            try self.snippets.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, sname),
                .desc = try self.allocator.dupe(u8, desc_val),
                .cmd = try self.allocator.dupe(u8, cmd_val),
                .tags = try tags.toOwnedSlice(self.allocator),
                .params = params,
                .namespace = try self.allocator.dupe(u8, namespace),
                .kind = .snippet,
            });
        }

        // Arena frees all TOML parse allocations
    }

    pub fn search(self: *Store, allocator: std.mem.Allocator, query: []const u8) ![]const *Snippet {
        if (query.len == 0) {
            const result = try allocator.alloc(*Snippet, self.snippets.items.len);
            for (self.snippets.items, 0..) |*snip, i| {
                result[i] = snip;
            }
            return result;
        }

        const search_strs = try allocator.alloc([]const u8, self.snippets.items.len);
        defer {
            for (search_strs) |s| allocator.free(s);
            allocator.free(search_strs);
        }

        for (self.snippets.items, 0..) |snip, i| {
            search_strs[i] = try std.fmt.allocPrint(allocator, "{s} {s}", .{ snip.name, snip.desc });
        }

        const ranked = try fuzzy.rank(allocator, search_strs, query);
        defer allocator.free(ranked);

        const result = try allocator.alloc(*Snippet, ranked.len);
        for (ranked, 0..) |idx, i| {
            result[i] = &self.snippets.items[idx];
        }
        return result;
    }

    pub fn add(self: *Store, snip: Snippet) !void {
        try self.snippets.append(self.allocator, snip);
        try self.saveNamespace(snip.namespace);
    }

    pub fn remove(self: *Store, name: []const u8) !void {
        for (self.snippets.items, 0..) |snip, i| {
            if (std.mem.eql(u8, snip.name, name)) {
                const ns = try self.allocator.dupe(u8, snip.namespace);
                defer self.allocator.free(ns);

                self.freeSnippet(snip);
                _ = self.snippets.orderedRemove(i);
                try self.saveNamespace(ns);
                return;
            }
        }
        return error.NotFound;
    }

    pub fn saveNamespace(self: *Store, namespace: []const u8) !void {
        const snippets_dir = try self.cfg.getSnippetsDir(self.allocator);
        defer self.allocator.free(snippets_dir);

        const path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.toml", .{ snippets_dir, namespace });
        defer self.allocator.free(path);

        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        try writer.print("# zipet snippets — {s}\n\n", .{namespace});

        for (self.snippets.items) |snip| {
            if (!std.mem.eql(u8, snip.namespace, namespace)) continue;
            if (snip.kind == .workflow) continue; // workflows are saved separately

            try writer.print("[snippets.{s}]\n", .{snip.name});
            try writer.print("desc = \"{s}\"\n", .{snip.desc});

            try writer.writeAll("tags = [");
            for (snip.tags, 0..) |tag, i| {
                if (i > 0) try writer.writeAll(", ");
                try writer.print("\"{s}\"", .{tag});
            }
            try writer.writeAll("]\n");

            try writer.print("cmd = \"{s}\"\n", .{snip.cmd});

            if (snip.params.len > 0) {
                try writer.writeAll("\n");
                for (snip.params) |p| {
                    try writer.print("[snippets.{s}.params.{s}]\n", .{ snip.name, p.name });
                    if (p.prompt) |pr| try writer.print("prompt = \"{s}\"\n", .{pr});
                    if (p.default) |d| try writer.print("default = \"{s}\"\n", .{d});
                    if (p.command) |c| try writer.print("command = \"{s}\"\n", .{c});
                }
            }

            try writer.writeAll("\n");
        }

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();
        try file.writeAll(buf.items);
    }

    pub fn allTags(self: *Store, allocator: std.mem.Allocator) ![]const []const u8 {
        var tag_set = std.StringHashMap(usize).init(allocator);
        defer tag_set.deinit();

        for (self.snippets.items) |snip| {
            for (snip.tags) |tag| {
                const entry = try tag_set.getOrPut(tag);
                if (entry.found_existing) {
                    entry.value_ptr.* += 1;
                } else {
                    entry.value_ptr.* = 1;
                }
            }
        }

        const result = try allocator.alloc([]const u8, tag_set.count());
        var i: usize = 0;
        var iter = tag_set.keyIterator();
        while (iter.next()) |k| {
            result[i] = k.*;
            i += 1;
        }
        return result;
    }
};

test "store basic" {
    const gpa = std.testing.allocator;
    _ = gpa;
}
