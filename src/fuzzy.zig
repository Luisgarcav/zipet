/// Fuzzy matching algorithm for zipet.
const std = @import("std");

pub const Match = struct {
    score: i32,
    positions: []const usize,

    pub fn deinit(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
    }
};

const SCORE_MATCH: i32 = 16;
const SCORE_GAP_START: i32 = -3;
const SCORE_GAP_EXTENSION: i32 = -1;
const BONUS_BOUNDARY: i32 = 8;
const BONUS_CONSECUTIVE: i32 = 4;
const BONUS_FIRST_CHAR: i32 = 4;
const BONUS_CAMEL_CASE: i32 = 6;
const BONUS_EXACT_PREFIX: i32 = 32;

pub fn match(allocator: std.mem.Allocator, haystack: []const u8, needle: []const u8) !?Match {
    if (needle.len == 0) {
        return Match{ .score = 0, .positions = try allocator.alloc(usize, 0) };
    }
    if (needle.len > haystack.len) return null;

    // Quick check: do all needle chars exist in haystack?
    var ni: usize = 0;
    var hi: usize = 0;
    while (ni < needle.len and hi < haystack.len) {
        if (toLower(haystack[hi]) == toLower(needle[ni])) {
            ni += 1;
        }
        hi += 1;
    }
    if (ni < needle.len) return null;

    var best_score: i32 = std.math.minInt(i32);
    const positions = try allocator.alloc(usize, needle.len);
    const best_positions = try allocator.alloc(usize, needle.len);
    defer allocator.free(positions);

    var start: usize = 0;
    while (start < haystack.len) {
        if (toLower(haystack[start]) == toLower(needle[0])) {
            const score = scoreMatch(haystack, needle, start, positions);
            if (score) |s| {
                if (s > best_score) {
                    best_score = s;
                    @memcpy(best_positions, positions);
                }
            }
        }
        start += 1;
    }

    if (best_score == std.math.minInt(i32)) {
        allocator.free(best_positions);
        return null;
    }

    return Match{ .score = best_score, .positions = best_positions };
}

fn scoreMatch(haystack: []const u8, needle: []const u8, start: usize, positions: []usize) ?i32 {
    var score: i32 = 0;
    var n_i: usize = 0;
    var h_i: usize = start;
    var prev_matched = false;
    var in_gap = false;

    while (n_i < needle.len and h_i < haystack.len) {
        if (toLower(haystack[h_i]) == toLower(needle[n_i])) {
            positions[n_i] = h_i;
            score += SCORE_MATCH;

            if (haystack[h_i] == needle[n_i]) score += 1;
            if (n_i == 0 and h_i == 0) score += BONUS_EXACT_PREFIX;
            if (n_i == 0) score += BONUS_FIRST_CHAR;
            if (h_i > 0 and isBoundary(haystack[h_i - 1])) score += BONUS_BOUNDARY;
            if (h_i > 0 and isLower(haystack[h_i - 1]) and isUpper(haystack[h_i])) score += BONUS_CAMEL_CASE;
            if (prev_matched) score += BONUS_CONSECUTIVE;

            prev_matched = true;
            in_gap = false;
            n_i += 1;
        } else {
            if (prev_matched and !in_gap) {
                score += SCORE_GAP_START;
                in_gap = true;
            } else if (in_gap) {
                score += SCORE_GAP_EXTENSION;
            }
            prev_matched = false;
        }
        h_i += 1;
    }

    if (n_i < needle.len) return null;
    return score;
}

fn isBoundary(c: u8) bool {
    return c == '-' or c == '_' or c == '/' or c == '.' or c == ' ' or c == ':';
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

/// Rank items by fuzzy match score. Returns indices sorted by score descending.
pub fn rank(allocator: std.mem.Allocator, items: []const []const u8, query: []const u8) ![]usize {
    if (query.len == 0) {
        const indices = try allocator.alloc(usize, items.len);
        for (indices, 0..) |*idx, i| idx.* = i;
        return indices;
    }

    const ScoredIndex = struct { index: usize, score: i32 };
    var scored: std.ArrayList(ScoredIndex) = .{};
    defer scored.deinit(allocator);

    for (items, 0..) |item, i| {
        if (try match(allocator, item, query)) |m| {
            defer m.deinit(allocator);
            try scored.append(allocator, .{ .index = i, .score = m.score });
        }
    }

    const slice = try scored.toOwnedSlice(allocator);
    defer allocator.free(slice);

    std.mem.sort(ScoredIndex, slice, {}, struct {
        fn lessThan(_: void, a: ScoredIndex, b: ScoredIndex) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const result = try allocator.alloc(usize, slice.len);
    for (result, 0..) |*r, i| r.* = slice[i].index;
    return result;
}

// ── Tests ──────────────────────────────────────────────────────

test "exact match scores higher than partial" {
    const gpa = std.testing.allocator;

    const m1 = (try match(gpa, "docker-build", "docker-build")).?;
    defer m1.deinit(gpa);

    const m2 = (try match(gpa, "docker-build-cache", "docker-build")).?;
    defer m2.deinit(gpa);

    // Both start at the same position, so scores are equal or m1 >= m2
    try std.testing.expect(m1.score >= m2.score);
}

test "no match returns null" {
    const gpa = std.testing.allocator;
    const result = try match(gpa, "docker", "xyz");
    try std.testing.expect(result == null);
}

test "case insensitive" {
    const gpa = std.testing.allocator;
    const m = (try match(gpa, "DockerBuild", "dockerbuild")).?;
    defer m.deinit(gpa);
    try std.testing.expect(m.score > 0);
}

test "empty needle matches everything" {
    const gpa = std.testing.allocator;
    const m = (try match(gpa, "anything", "")).?;
    defer m.deinit(gpa);
    try std.testing.expectEqual(@as(i32, 0), m.score);
}

test "rank orders by score" {
    const gpa = std.testing.allocator;
    const items = [_][]const u8{ "git-push", "docker-push", "push-all" };
    const result = try rank(gpa, &items, "push");
    defer gpa.free(result);

    try std.testing.expect(result.len == 3);
}
