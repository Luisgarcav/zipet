const std = @import("std");

pub const VarContext = std.StringHashMap([]const u8);

pub const TokenKind = enum {
    literal,
    op_eq,
    op_neq,
    op_contains,
    op_empty,
    op_not_empty,
    op_and,
    op_or,
    op_not,
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8,
};

/// Tokenize an expression string into tokens. Splits on whitespace and maps
/// keywords to their respective token kinds.
pub fn tokenize(allocator: std.mem.Allocator, expr: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .{};
    errdefer tokens.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, expr, " \t\r\n");
    while (it.next()) |word| {
        // Sentinel byte \x00 represents an empty-string literal produced by
        // resolveVars when a variable is missing or has an empty value.
        if (word.len == 1 and word[0] == 0) {
            try tokens.append(allocator, Token{ .kind = .literal, .value = "" });
            continue;
        }

        const kind: TokenKind = if (std.mem.eql(u8, word, "=="))
            .op_eq
        else if (std.mem.eql(u8, word, "!="))
            .op_neq
        else if (std.mem.eql(u8, word, "contains"))
            .op_contains
        else if (std.mem.eql(u8, word, "empty"))
            .op_empty
        else if (std.mem.eql(u8, word, "not_empty"))
            .op_not_empty
        else if (std.mem.eql(u8, word, "and"))
            .op_and
        else if (std.mem.eql(u8, word, "or"))
            .op_or
        else if (std.mem.eql(u8, word, "not"))
            .op_not
        else
            .literal;

        try tokens.append(allocator, Token{ .kind = kind, .value = word });
    }

    return tokens.toOwnedSlice(allocator);
}

/// Resolve {{var}} placeholders in expr using the given VarContext.
/// Returns a newly allocated string — caller must free.
fn resolveVars(allocator: std.mem.Allocator, expr: []const u8, ctx: *const VarContext) ![]u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < expr.len) {
        if (i + 1 < expr.len and expr[i] == '{' and expr[i + 1] == '{') {
            // Find closing }}
            const start = i + 2;
            var end = start;
            while (end + 1 < expr.len) {
                if (expr[end] == '}' and expr[end + 1] == '}') break;
                end += 1;
            }
            const var_name = expr[start..end];
            const value = ctx.get(var_name) orelse "";
            if (value.len == 0) {
                // Use a sentinel byte so the tokenizer emits an empty literal
                // rather than producing no token at all.
                try result.append(allocator, 0);
            } else {
                try result.appendSlice(allocator, value);
            }
            i = end + 2;
        } else {
            try result.append(allocator, expr[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

/// Parser state for recursive descent
const Parser = struct {
    tokens: []const Token,
    pos: usize,

    fn init(tokens: []const Token) Parser {
        return .{ .tokens = tokens, .pos = 0 };
    }

    fn peek(self: *Parser) ?Token {
        if (self.pos >= self.tokens.len) return null;
        return self.tokens[self.pos];
    }

    fn consume(self: *Parser) ?Token {
        if (self.pos >= self.tokens.len) return null;
        const tok = self.tokens[self.pos];
        self.pos += 1;
        return tok;
    }

    /// parseOr: parseAnd (('or') parseAnd)*
    fn parseOr(self: *Parser) bool {
        var left = self.parseAnd();
        while (self.peek()) |tok| {
            if (tok.kind != .op_or) break;
            _ = self.consume();
            const right = self.parseAnd();
            left = left or right;
        }
        return left;
    }

    /// parseAnd: parseNot (('and') parseNot)*
    fn parseAnd(self: *Parser) bool {
        var left = self.parseNot();
        while (self.peek()) |tok| {
            if (tok.kind != .op_and) break;
            _ = self.consume();
            const right = self.parseNot();
            left = left and right;
        }
        return left;
    }

    /// parseNot: 'not' parseComparison | parseComparison
    fn parseNot(self: *Parser) bool {
        if (self.peek()) |tok| {
            if (tok.kind == .op_not) {
                _ = self.consume();
                return !self.parseComparison();
            }
        }
        return self.parseComparison();
    }

    /// parseComparison: literal (op literal | 'empty' | 'not_empty')?
    fn parseComparison(self: *Parser) bool {
        // Expect a literal (left-hand side)
        const lhs_tok = self.consume() orelse return false;
        if (lhs_tok.kind != .literal) return false;

        const lhs = lhs_tok.value;

        const op_tok = self.peek() orelse return lhs.len > 0;

        switch (op_tok.kind) {
            .op_eq => {
                _ = self.consume();
                const rhs_tok = self.consume() orelse return false;
                return std.mem.eql(u8, lhs, rhs_tok.value);
            },
            .op_neq => {
                _ = self.consume();
                const rhs_tok = self.consume() orelse return false;
                return !std.mem.eql(u8, lhs, rhs_tok.value);
            },
            .op_contains => {
                _ = self.consume();
                const rhs_tok = self.consume() orelse return false;
                return std.mem.containsAtLeast(u8, lhs, 1, rhs_tok.value);
            },
            .op_empty => {
                _ = self.consume();
                return lhs.len == 0;
            },
            .op_not_empty => {
                _ = self.consume();
                return lhs.len > 0;
            },
            // Next token is not an operator for this expression — treat as bare literal (truthy if non-empty)
            else => return lhs.len > 0,
        }
    }
};

/// Evaluate a condition expression against the given variable context.
/// Returns true/false result.
pub fn evaluate(allocator: std.mem.Allocator, expr: []const u8, ctx: *const VarContext) !bool {
    const resolved = try resolveVars(allocator, expr, ctx);
    defer allocator.free(resolved);

    const tokens = try tokenize(allocator, resolved);
    defer allocator.free(tokens);

    var parser = Parser.init(tokens);
    return parser.parseOr();
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "tokenize simple equality" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "prod == production");
    defer alloc.free(tokens);
    try std.testing.expectEqual(@as(usize, 3), tokens.len);
    try std.testing.expectEqual(TokenKind.literal, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.op_eq, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.literal, tokens[2].kind);
}

test "tokenize with logical operators" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "prod == production and us-east != us-west");
    defer alloc.free(tokens);
    try std.testing.expectEqual(@as(usize, 7), tokens.len);
    try std.testing.expectEqual(TokenKind.literal, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.op_eq, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.literal, tokens[2].kind);
    try std.testing.expectEqual(TokenKind.op_and, tokens[3].kind);
    try std.testing.expectEqual(TokenKind.literal, tokens[4].kind);
    try std.testing.expectEqual(TokenKind.op_neq, tokens[5].kind);
    try std.testing.expectEqual(TokenKind.literal, tokens[6].kind);
}

test "tokenize empty/not_empty" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "somevalue not_empty");
    defer alloc.free(tokens);
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqual(TokenKind.literal, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.op_not_empty, tokens[1].kind);
}

test "tokenize not prefix" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "not prod == staging");
    defer alloc.free(tokens);
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqual(TokenKind.op_not, tokens[0].kind);
    try std.testing.expectEqual(TokenKind.literal, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.op_eq, tokens[2].kind);
    try std.testing.expectEqual(TokenKind.literal, tokens[3].kind);
}

test "evaluate simple equality true" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("env", "production");
    const result = try evaluate(alloc, "{{env}} == production", &ctx);
    try std.testing.expect(result);
}

test "evaluate simple equality false" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("env", "staging");
    const result = try evaluate(alloc, "{{env}} == production", &ctx);
    try std.testing.expect(!result);
}

test "evaluate not_empty" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("version", "1.0");
    const result = try evaluate(alloc, "{{version}} not_empty", &ctx);
    try std.testing.expect(result);
}

test "evaluate empty (missing var)" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    const result = try evaluate(alloc, "{{missing}} empty", &ctx);
    try std.testing.expect(result);
}

test "evaluate contains" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("tags", "deploy,ci,test");
    const result = try evaluate(alloc, "{{tags}} contains deploy", &ctx);
    try std.testing.expect(result);
}

test "evaluate and (both true)" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("env", "prod");
    try ctx.put("region", "us-east");
    const result = try evaluate(alloc, "{{env}} == prod and {{region}} == us-east", &ctx);
    try std.testing.expect(result);
}

test "evaluate and (one false)" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("env", "prod");
    try ctx.put("region", "eu-west");
    const result = try evaluate(alloc, "{{env}} == prod and {{region}} == us-east", &ctx);
    try std.testing.expect(!result);
}

test "evaluate or" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("debug", "false");
    try ctx.put("verbose", "true");
    const result = try evaluate(alloc, "{{debug}} == true or {{verbose}} == true", &ctx);
    try std.testing.expect(result);
}

test "evaluate not" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("skip", "false");
    const result = try evaluate(alloc, "not {{skip}} == true", &ctx);
    try std.testing.expect(result);
}

test "evaluate precedence: not > and > or" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("a", "1");
    try ctx.put("b", "2");
    // not {{a}} == 1 or {{b}} == 2
    // → (not (1==1)) or (2==2)
    // → false or true
    // → true
    const result = try evaluate(alloc, "not {{a}} == 1 or {{b}} == 2", &ctx);
    try std.testing.expect(result);
}

test "evaluate numeric inequality false" {
    const alloc = std.testing.allocator;
    var ctx = VarContext.init(alloc);
    defer ctx.deinit();
    try ctx.put("exit", "0");
    const result = try evaluate(alloc, "{{exit}} != 0", &ctx);
    try std.testing.expect(!result);
}
