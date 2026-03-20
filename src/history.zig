/// Execution history and frecency scoring for zipet.
/// Uses a simple JSON-lines file (~/.config/zipet/history.jsonl) instead of SQLite
/// for zero external dependencies. Each line is a JSON object representing one execution event.
///
/// Frecency = frequency * recency_weight
/// Where recency_weight decays based on how long ago the snippet was last used.
const std = @import("std");
const config = @import("config.zig");

pub const HistoryEntry = struct {
    snippet_name: []const u8,
    timestamp: i64, // unix seconds
    exit_code: u8,
    duration_ms: u64,
    workspace: ?[]const u8,
};

pub const FrecencyScore = struct {
    name: []const u8,
    score: f64,
    run_count: u32,
    last_run: i64,
};

pub const History = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(HistoryEntry),
    cfg: config.Config,

    pub fn init(allocator: std.mem.Allocator, cfg: config.Config) History {
        return .{
            .allocator = allocator,
            .entries = .{},
            .cfg = cfg,
        };
    }

    pub fn deinit(self: *History) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.snippet_name);
            if (e.workspace) |w| self.allocator.free(w);
        }
        self.entries.deinit(self.allocator);
    }

    /// Load history from the JSONL file.
    pub fn load(self: *History) !void {
        const path = try self.getHistoryPath();
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return; // no file yet
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 1024 * 1024 * 4) catch return;
        defer self.allocator.free(content);

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const entry = parseEntry(self.allocator, line) catch continue;
            self.entries.append(self.allocator, entry) catch continue;
        }
    }

    /// Record a new execution event and persist it.
    pub fn record(self: *History, snippet_name: []const u8, exit_code: u8, duration_ms: u64) !void {
        const now = std.time.timestamp();
        const entry = HistoryEntry{
            .snippet_name = try self.allocator.dupe(u8, snippet_name),
            .timestamp = now,
            .exit_code = exit_code,
            .duration_ms = duration_ms,
            .workspace = if (self.cfg.active_workspace) |w|
                try self.allocator.dupe(u8, w)
            else
                null,
        };
        try self.entries.append(self.allocator, entry);
        try self.appendToFile(entry);
    }

    /// Compute frecency scores for all known snippets.
    /// Returns sorted by score descending.
    pub fn frecencyScores(self: *History, allocator: std.mem.Allocator) ![]FrecencyScore {
        const now = std.time.timestamp();

        // Aggregate by snippet name
        var score_map = std.StringHashMap(struct {
            count: u32,
            last_run: i64,
            score: f64,
        }).init(allocator);
        defer score_map.deinit();

        for (self.entries.items) |e| {
            const age_hours = @as(f64, @floatFromInt(@max(now - e.timestamp, 0))) / 3600.0;
            const recency_weight = recencyDecay(age_hours);

            const gop = try score_map.getOrPut(e.snippet_name);
            if (gop.found_existing) {
                gop.value_ptr.count += 1;
                gop.value_ptr.score += recency_weight;
                if (e.timestamp > gop.value_ptr.last_run)
                    gop.value_ptr.last_run = e.timestamp;
            } else {
                gop.value_ptr.* = .{
                    .count = 1,
                    .last_run = e.timestamp,
                    .score = recency_weight,
                };
            }
        }

        var result: std.ArrayList(FrecencyScore) = .{};
        var iter = score_map.iterator();
        while (iter.next()) |kv| {
            try result.append(allocator, .{
                .name = kv.key_ptr.*,
                .score = kv.value_ptr.score,
                .run_count = kv.value_ptr.count,
                .last_run = kv.value_ptr.last_run,
            });
        }

        // Sort by score descending
        std.mem.sort(FrecencyScore, result.items, {}, struct {
            fn cmp(_: void, a: FrecencyScore, b: FrecencyScore) bool {
                return a.score > b.score;
            }
        }.cmp);

        return try result.toOwnedSlice(allocator);
    }

    /// Get the frecency score for a specific snippet name.
    pub fn getScore(self: *History, name: []const u8) f64 {
        const now = std.time.timestamp();
        var score: f64 = 0;
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.snippet_name, name)) {
                const age_hours = @as(f64, @floatFromInt(@max(now - e.timestamp, 0))) / 3600.0;
                score += recencyDecay(age_hours);
            }
        }
        return score;
    }

    /// Get execution count for a snippet.
    pub fn getRunCount(self: *History, name: []const u8) u32 {
        var count: u32 = 0;
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.snippet_name, name))
                count += 1;
        }
        return count;
    }

    /// Get last run timestamp for a snippet (0 if never run).
    pub fn getLastRun(self: *History, name: []const u8) i64 {
        var last: i64 = 0;
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.snippet_name, name) and e.timestamp > last)
                last = e.timestamp;
        }
        return last;
    }

    /// Get recent history entries (most recent first), limited to `max` entries.
    pub fn recent(self: *History, allocator: std.mem.Allocator, max: usize) ![]const HistoryEntry {
        const total = self.entries.items.len;
        const count = @min(total, max);
        const result = try allocator.alloc(HistoryEntry, count);
        for (0..count) |i| {
            result[i] = self.entries.items[total - 1 - i];
        }
        return result;
    }

    /// Clear all history.
    pub fn clear(self: *History) !void {
        for (self.entries.items) |e| {
            self.allocator.free(e.snippet_name);
            if (e.workspace) |w| self.allocator.free(w);
        }
        self.entries.clearRetainingCapacity();

        // Truncate the file
        const path = try self.getHistoryPath();
        defer self.allocator.free(path);
        const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch return;
        file.close();
    }

    /// Prune history to keep only the latest N entries.
    pub fn prune(self: *History, keep: usize) !void {
        if (self.entries.items.len <= keep) return;

        // Free old entries
        const remove_count = self.entries.items.len - keep;
        for (self.entries.items[0..remove_count]) |e| {
            self.allocator.free(e.snippet_name);
            if (e.workspace) |w| self.allocator.free(w);
        }

        // Shift remaining entries to the front
        const remaining = self.entries.items[remove_count..];
        std.mem.copyForwards(HistoryEntry, self.entries.items[0..remaining.len], remaining);
        self.entries.items.len = keep;

        // Rewrite the file
        try self.rewriteFile();
    }

    // ── Internal ──

    fn getHistoryPath(self: *History) ![]const u8 {
        const base = try self.cfg.getConfigDir(self.allocator);
        defer self.allocator.free(base);
        return std.fmt.allocPrint(self.allocator, "{s}/history.jsonl", .{base});
    }

    fn appendToFile(self: *History, entry: HistoryEntry) !void {
        const path = try self.getHistoryPath();
        defer self.allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{
            .truncate = false,
        });
        defer file.close();

        // Seek to end
        file.seekFromEnd(0) catch {};

        const line = try serializeEntry(self.allocator, entry);
        defer self.allocator.free(line);

        try file.writeAll(line);
        try file.writeAll("\n");
    }

    fn rewriteFile(self: *History) !void {
        const path = try self.getHistoryPath();
        defer self.allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
        defer file.close();

        for (self.entries.items) |entry| {
            const line = serializeEntry(self.allocator, entry) catch continue;
            defer self.allocator.free(line);
            file.writeAll(line) catch continue;
            file.writeAll("\n") catch continue;
        }
    }

    fn serializeEntry(allocator: std.mem.Allocator, entry: HistoryEntry) ![]const u8 {
        // Simple manual JSON serialization to avoid needing std.json writer
        const ws_part = if (entry.workspace) |w|
            try std.fmt.allocPrint(allocator, ",\"ws\":\"{s}\"", .{w})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(ws_part);

        return std.fmt.allocPrint(
            allocator,
            "{{\"n\":\"{s}\",\"t\":{d},\"e\":{d},\"d\":{d}{s}}}",
            .{ entry.snippet_name, entry.timestamp, entry.exit_code, entry.duration_ms, ws_part },
        );
    }

    fn parseEntry(allocator: std.mem.Allocator, line: []const u8) !HistoryEntry {
        // Minimal JSON parsing for our known format:
        // {"n":"name","t":12345,"e":0,"d":100,"ws":"workspace"}
        const name = extractJsonString(line, "\"n\":\"") orelse return error.ParseError;
        const timestamp = extractJsonInt(line, "\"t\":") orelse return error.ParseError;
        const exit_code_i = extractJsonInt(line, "\"e\":") orelse 0;
        const duration = extractJsonInt(line, "\"d\":") orelse 0;
        const workspace = extractJsonString(line, "\"ws\":\"");

        return HistoryEntry{
            .snippet_name = try allocator.dupe(u8, name),
            .timestamp = timestamp,
            .exit_code = @intCast(@min(exit_code_i, 255)),
            .duration_ms = @intCast(@max(duration, 0)),
            .workspace = if (workspace) |w| try allocator.dupe(u8, w) else null,
        };
    }

    fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
        const start_idx = std.mem.indexOf(u8, json, key) orelse return null;
        const val_start = start_idx + key.len;
        if (val_start >= json.len) return null;
        // Find closing quote (handle escaped quotes minimally)
        var i = val_start;
        while (i < json.len) : (i += 1) {
            if (json[i] == '"' and (i == val_start or json[i - 1] != '\\')) {
                return json[val_start..i];
            }
        }
        return null;
    }

    fn extractJsonInt(json: []const u8, key: []const u8) ?i64 {
        const start_idx = std.mem.indexOf(u8, json, key) orelse return null;
        const val_start = start_idx + key.len;
        if (val_start >= json.len) return null;
        var end = val_start;
        if (end < json.len and json[end] == '-') end += 1;
        while (end < json.len and json[end] >= '0' and json[end] <= '9') : (end += 1) {}
        if (end == val_start) return null;
        return std.fmt.parseInt(i64, json[val_start..end], 10) catch null;
    }
};

/// Frecency decay function.
/// Returns a weight between 0.0 and 1.0 based on how many hours ago the event was.
/// Uses a piecewise decay:
///   - Last 4 hours:  weight 1.0 (very recent)
///   - Last 24 hours: weight 0.8
///   - Last 7 days:   weight 0.5
///   - Last 30 days:  weight 0.3
///   - Last 90 days:  weight 0.1
///   - Older:         weight 0.05
fn recencyDecay(age_hours: f64) f64 {
    if (age_hours < 4) return 1.0;
    if (age_hours < 24) return 0.8;
    if (age_hours < 24 * 7) return 0.5;
    if (age_hours < 24 * 30) return 0.3;
    if (age_hours < 24 * 90) return 0.1;
    return 0.05;
}

/// Format a unix timestamp as a relative time string (e.g., "2h ago", "3d ago").
pub fn formatRelativeTime(allocator: std.mem.Allocator, timestamp: i64) ![]const u8 {
    const now = std.time.timestamp();
    const diff = @max(now - timestamp, 0);

    if (diff < 60) return try allocator.dupe(u8, "just now");
    if (diff < 3600) return try std.fmt.allocPrint(allocator, "{d}m ago", .{@divFloor(diff, 60)});
    if (diff < 86400) return try std.fmt.allocPrint(allocator, "{d}h ago", .{@divFloor(diff, 3600)});
    if (diff < 86400 * 30) return try std.fmt.allocPrint(allocator, "{d}d ago", .{@divFloor(diff, 86400)});
    if (diff < 86400 * 365) return try std.fmt.allocPrint(allocator, "{d}mo ago", .{@divFloor(diff, 86400 * 30)});
    return try std.fmt.allocPrint(allocator, "{d}y ago", .{@divFloor(diff, 86400 * 365)});
}

test "recency decay" {
    try std.testing.expectEqual(@as(f64, 1.0), recencyDecay(0));
    try std.testing.expectEqual(@as(f64, 1.0), recencyDecay(3));
    try std.testing.expectEqual(@as(f64, 0.8), recencyDecay(12));
    try std.testing.expectEqual(@as(f64, 0.5), recencyDecay(48));
    try std.testing.expectEqual(@as(f64, 0.05), recencyDecay(24 * 365));
}

test "serialize and parse entry" {
    const allocator = std.testing.allocator;
    const entry = HistoryEntry{
        .snippet_name = "test-snip",
        .timestamp = 1700000000,
        .exit_code = 0,
        .duration_ms = 150,
        .workspace = "myproject",
    };
    const line = try History.serializeEntry(allocator, entry);
    defer allocator.free(line);

    const parsed = try History.parseEntry(allocator, line);
    defer allocator.free(parsed.snippet_name);
    defer if (parsed.workspace) |w| allocator.free(w);

    try std.testing.expectEqualStrings("test-snip", parsed.snippet_name);
    try std.testing.expectEqual(@as(i64, 1700000000), parsed.timestamp);
    try std.testing.expectEqual(@as(u8, 0), parsed.exit_code);
    try std.testing.expectEqual(@as(u64, 150), parsed.duration_ms);
    try std.testing.expectEqualStrings("myproject", parsed.workspace.?);
}
