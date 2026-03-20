const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Node = struct {
    name: []const u8,
    index: usize,
    depends_on: []const []const u8,
};

pub const GraphError = error{
    CycleDetected,
    UnknownDependency,
};

/// Returns indices in topological execution order.
/// Steps with empty depends_on implicitly depend on the previous step (index - 1),
/// except the first step (index 0) which has no dependencies.
/// Steps with explicit depends_on use those names resolved to indices.
pub fn topologicalSort(allocator: Allocator, nodes: []const Node) ![]usize {
    const n = nodes.len;
    if (n == 0) return allocator.alloc(usize, 0);

    // Validate node indices match positions
    for (nodes, 0..) |node, pos| {
        if (node.index != pos) return GraphError.UnknownDependency;
    }

    // Build name → index lookup
    var name_map = std.StringHashMap(usize).init(allocator);
    defer name_map.deinit();
    for (nodes) |node| {
        try name_map.put(node.name, node.index);
    }

    // Validate all dependency names first
    for (nodes) |node| {
        for (node.depends_on) |dep_name| {
            if (!name_map.contains(dep_name)) return GraphError.UnknownDependency;
        }
    }

    // Build adjacency list: adj[i] = list of nodes that depend on node i (forward edges)
    var adj = try allocator.alloc(std.ArrayListUnmanaged(usize), n);
    defer {
        for (adj) |*list| list.deinit(allocator);
        allocator.free(adj);
    }
    for (0..n) |i| adj[i] = .{};

    var in_degree = try allocator.alloc(usize, n);
    defer allocator.free(in_degree);
    @memset(in_degree, 0);

    for (nodes) |node| {
        const i = node.index;
        if (node.depends_on.len > 0) {
            // Explicit dependencies
            for (node.depends_on) |dep_name| {
                const dep_idx = name_map.get(dep_name).?;
                // Edge: dep_idx → i  (dep_idx must come before i)
                try adj[dep_idx].append(allocator, i);
                in_degree[i] += 1;
            }
        } else if (i > 0) {
            // Implicit dependency on previous step
            try adj[i - 1].append(allocator, i);
            in_degree[i] += 1;
        }
    }

    // Kahn's algorithm
    var queue: std.ArrayListUnmanaged(usize) = .{};
    defer queue.deinit(allocator);

    for (0..n) |i| {
        if (in_degree[i] == 0) try queue.append(allocator, i);
    }

    var result: std.ArrayListUnmanaged(usize) = .{};
    errdefer result.deinit(allocator);

    var head: usize = 0;
    while (head < queue.items.len) {
        const cur = queue.items[head];
        head += 1;
        try result.append(allocator, cur);

        for (adj[cur].items) |dependent| {
            in_degree[dependent] -= 1;
            if (in_degree[dependent] == 0) {
                try queue.append(allocator, dependent);
            }
        }
    }

    if (result.items.len != n) return GraphError.CycleDetected;

    return result.toOwnedSlice(allocator);
}

/// Returns all indices that TRANSITIVELY depend on the failed node.
/// Used to mark dependents as skipped when a step fails.
pub fn dependentsOf(allocator: Allocator, nodes: []const Node, failed_index: usize) ![]usize {
    const n = nodes.len;

    // Validate node indices match positions
    for (nodes, 0..) |node, pos| {
        if (node.index != pos) return GraphError.UnknownDependency;
    }

    // Build name → index lookup
    var name_map = std.StringHashMap(usize).init(allocator);
    defer name_map.deinit();
    for (nodes) |node| {
        try name_map.put(node.name, node.index);
    }

    // Build forward adjacency list: adj[i] = list of nodes depending on i
    var adj = try allocator.alloc(std.ArrayListUnmanaged(usize), n);
    defer {
        for (adj) |*list| list.deinit(allocator);
        allocator.free(adj);
    }
    for (0..n) |i| adj[i] = .{};

    for (nodes) |node| {
        const i = node.index;
        if (node.depends_on.len > 0) {
            for (node.depends_on) |dep_name| {
                const dep_idx = name_map.get(dep_name) orelse return GraphError.UnknownDependency;
                try adj[dep_idx].append(allocator, i);
            }
        } else if (i > 0) {
            try adj[i - 1].append(allocator, i);
        }
    }

    // BFS from failed_index collecting all reachable dependents
    var visited = try allocator.alloc(bool, n);
    defer allocator.free(visited);
    @memset(visited, false);

    var queue: std.ArrayListUnmanaged(usize) = .{};
    defer queue.deinit(allocator);

    visited[failed_index] = true;
    try queue.append(allocator, failed_index);

    var head: usize = 0;
    while (head < queue.items.len) {
        const cur = queue.items[head];
        head += 1;
        for (adj[cur].items) |dep| {
            if (!visited[dep]) {
                visited[dep] = true;
                try queue.append(allocator, dep);
            }
        }
    }

    // Collect results, excluding failed_index itself
    var result: std.ArrayListUnmanaged(usize) = .{};
    errdefer result.deinit(allocator);
    for (0..n) |i| {
        if (visited[i] and i != failed_index) try result.append(allocator, i);
    }

    return result.toOwnedSlice(allocator);
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "toposort — sequential (no depends_on)" {
    const allocator = std.testing.allocator;
    const nodes = [_]Node{
        .{ .name = "a", .index = 0, .depends_on = &.{} },
        .{ .name = "b", .index = 1, .depends_on = &.{} },
        .{ .name = "c", .index = 2, .depends_on = &.{} },
    };
    const order = try topologicalSort(allocator, &nodes);
    defer allocator.free(order);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, order);
}

test "toposort — explicit depends_on reorders" {
    const allocator = std.testing.allocator;
    const pkg_deps = [_][]const u8{"build"};
    const deploy_deps = [_][]const u8{ "test", "package" };
    const nodes = [_]Node{
        .{ .name = "build", .index = 0, .depends_on = &.{} },
        .{ .name = "test", .index = 1, .depends_on = &.{} },
        .{ .name = "package", .index = 2, .depends_on = &pkg_deps },
        .{ .name = "deploy", .index = 3, .depends_on = &deploy_deps },
    };
    const order = try topologicalSort(allocator, &nodes);
    defer allocator.free(order);

    // build must come first, deploy must come last
    try std.testing.expectEqual(@as(usize, 0), order[0]);
    try std.testing.expectEqual(@as(usize, 3), order[order.len - 1]);
    try std.testing.expectEqual(@as(usize, 4), order.len);
}

test "toposort — cycle detected" {
    const allocator = std.testing.allocator;
    const a_deps = [_][]const u8{"b"};
    const b_deps = [_][]const u8{"a"};
    const nodes = [_]Node{
        .{ .name = "a", .index = 0, .depends_on = &a_deps },
        .{ .name = "b", .index = 1, .depends_on = &b_deps },
    };
    const result = topologicalSort(allocator, &nodes);
    try std.testing.expectError(GraphError.CycleDetected, result);
}

test "toposort — unknown dependency" {
    const allocator = std.testing.allocator;
    const a_deps = [_][]const u8{"nonexistent"};
    const nodes = [_]Node{
        .{ .name = "a", .index = 0, .depends_on = &a_deps },
    };
    const result = topologicalSort(allocator, &nodes);
    try std.testing.expectError(GraphError.UnknownDependency, result);
}

test "toposort — single step no deps" {
    const allocator = std.testing.allocator;
    const nodes = [_]Node{
        .{ .name = "only", .index = 0, .depends_on = &.{} },
    };
    const order = try topologicalSort(allocator, &nodes);
    defer allocator.free(order);
    try std.testing.expectEqualSlices(usize, &.{0}, order);
}

test "dependentsOf — transitive" {
    const allocator = std.testing.allocator;
    const deploy_deps = [_][]const u8{"test"};
    const nodes = [_]Node{
        .{ .name = "build", .index = 0, .depends_on = &.{} },
        .{ .name = "test", .index = 1, .depends_on = &.{} }, // implicit dep on build
        .{ .name = "deploy", .index = 2, .depends_on = &deploy_deps },
    };
    const deps = try dependentsOf(allocator, &nodes, 0);
    defer allocator.free(deps);
    // test (1) depends on build; deploy (2) depends on test
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, deps);
}
