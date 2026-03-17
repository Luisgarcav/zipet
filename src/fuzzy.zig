/// Fuzzy matching algorithm for zipet.
/// Inspired by fzf/Sublime Text scoring: consecutive matches and word
/// boundaries are heavily rewarded, while scattered matches are penalised.
const std = @import("std");

pub const Match = struct {
    score: i32,
    positions: []const usize,

    pub fn deinit(self: Match, allocator: std.mem.Allocator) void {
        allocator.free(self.positions);
    }
};

// ── Scoring constants ──────────────────────────────────────────
// Tuned so that scattered single-letter matches across a long string
// produce a negative or near-zero score, while tight/exact matches
// score very high.

const SCORE_MATCH: i32 = 16;
const SCORE_GAP_START: i32 = -8; // was -3 — much heavier now
const SCORE_GAP_EXTENSION: i32 = -3; // was -1
const BONUS_BOUNDARY: i32 = 12; // match at word boundary (after - _ / . :)
const BONUS_CONSECUTIVE: i32 = 12; // was 4 — consecutive letters are king
const BONUS_FIRST_CHAR: i32 = 8; // needle starts at haystack start
const BONUS_CAMEL_CASE: i32 = 8; // camelCase boundary
const BONUS_EXACT_PREFIX: i32 = 48; // was 32 — needle matches from pos 0
const BONUS_EXACT_MATCH: i32 = 100; // haystack == needle (case insensitive)
const BONUS_EXACT_WORD: i32 = 64; // needle matches a full word in haystack
const BONUS_CASE_MATCH: i32 = 2; // exact case match per char (was 1)

/// Minimum score threshold as a function of needle length.
/// Short queries need higher per-char quality to avoid noise.
pub fn scoreThreshold(needle_len: usize) i32 {
    // Require a solid per-char average to pass. Consecutive tight matches
    // score ~28/char (MATCH + CONSECUTIVE), so we ask for ~50% of that.
    // This filters scattered junk while keeping real substring matches.
    return @as(i32, @intCast(needle_len)) * 14;
}

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

    // Check for exact case-insensitive match of entire string
    const is_exact = haystack.len == needle.len and eqlInsensitive(haystack, needle);

    var best_score: i32 = std.math.minInt(i32);
    const positions = try allocator.alloc(usize, needle.len);
    const best_positions = try allocator.alloc(usize, needle.len);
    defer allocator.free(positions);

    var start: usize = 0;
    while (start < haystack.len) {
        if (toLower(haystack[start]) == toLower(needle[0])) {
            const score = scoreMatch(haystack, needle, start, positions);
            if (score) |s| {
                var total = s;
                if (is_exact) total += BONUS_EXACT_MATCH;
                // Check if needle matches a complete word in haystack
                if (!is_exact) {
                    const end = start + needle.len;
                    if (end <= haystack.len) {
                        const at_word_start = (start == 0 or isBoundary(haystack[start - 1]));
                        const at_word_end = (end == haystack.len or isBoundary(haystack[end]));
                        if (at_word_start and at_word_end and eqlInsensitive(haystack[start..end], needle)) {
                            total += BONUS_EXACT_WORD;
                        }
                    }
                }
                if (total > best_score) {
                    best_score = total;
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

            // Case-exact bonus
            if (haystack[h_i] == needle[n_i]) score += BONUS_CASE_MATCH;
            // Starting at position 0
            if (n_i == 0 and h_i == 0) score += BONUS_EXACT_PREFIX;
            if (n_i == 0) score += BONUS_FIRST_CHAR;
            // Word boundary
            if (h_i > 0 and isBoundary(haystack[h_i - 1])) score += BONUS_BOUNDARY;
            // camelCase
            if (h_i > 0 and isLower(haystack[h_i - 1]) and isUpper(haystack[h_i])) score += BONUS_CAMEL_CASE;
            // Consecutive
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

fn eqlInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

/// Rank items by fuzzy match score. Returns indices sorted by score
/// descending. Applies a minimum score threshold to filter out weak matches.
pub fn rank(allocator: std.mem.Allocator, items: []const []const u8, query: []const u8) ![]usize {
    if (query.len == 0) {
        const indices = try allocator.alloc(usize, items.len);
        for (indices, 0..) |*idx, i| idx.* = i;
        return indices;
    }

    const threshold = scoreThreshold(query.len);

    const ScoredIndex = struct { index: usize, score: i32 };
    var scored: std.ArrayList(ScoredIndex) = .{};
    defer scored.deinit(allocator);

    for (items, 0..) |item, i| {
        if (try match(allocator, item, query)) |m| {
            defer m.deinit(allocator);
            if (m.score >= threshold) {
                try scored.append(allocator, .{ .index = i, .score = m.score });
            }
        }
    }

    const slice = try scored.toOwnedSlice(allocator);
    defer allocator.free(slice);

    std.mem.sort(ScoredIndex, slice, {}, struct {
        fn lessThan(_: void, a: ScoredIndex, b: ScoredIndex) bool {
            return a.score > b.score;
        }
    }.lessThan);

    // Secondary cutoff: if best score is much higher than tail, trim.
    // Drop results scoring below 30% of the best score.
    var keep: usize = slice.len;
    if (slice.len > 1) {
        const best = slice[0].score;
        if (best > 0) {
            const cutoff = @divTrunc(best * 30, 100);
            for (slice, 0..) |entry, i| {
                if (entry.score < cutoff) {
                    keep = i;
                    break;
                }
            }
        }
    }

    const result = try allocator.alloc(usize, keep);
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

    try std.testing.expect(m1.score > m2.score);
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

test "scattered match scores below threshold" {
    const gpa = std.testing.allocator;
    // "Test" scattered across "list-servers-tool" should score low
    const m = try match(gpa, "list-servers-tool", "Test");
    if (m) |mt| {
        defer mt.deinit(gpa);
        const threshold = scoreThreshold(4);
        // Should be below threshold
        try std.testing.expect(mt.score < threshold);
    }
    // null is also acceptable — means no match at all
}

test "exact name match scores much higher than scattered" {
    const gpa = std.testing.allocator;

    const m_exact = (try match(gpa, "Test", "Test")).?;
    defer m_exact.deinit(gpa);

    const m_scattered = try match(gpa, "list-servers-tool", "Test");
    if (m_scattered) |ms| {
        defer ms.deinit(gpa);
        // Exact should be at least 3x higher
        try std.testing.expect(m_exact.score > ms.score * 3);
    }
}

test "rank filters out weak matches" {
    const gpa = std.testing.allocator;
    const items = [_][]const u8{
        "Test",
        "Test-server",
        "run-test",
        "list-servers-tool",
        "my-templates",
        "git-stash",
    };
    const result = try rank(gpa, &items, "Test");
    defer gpa.free(result);

    // Should NOT return all 6 — scattered junk should be filtered
    try std.testing.expect(result.len <= 4);
}
