/// Minimal TOML parser for zipet snippet files.
/// Supports: tables, key-value pairs, strings, arrays, inline tables.
/// Does NOT aim for full TOML spec — just enough for snippet/chain/workflow files.
const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    array: []const Value,
    table: Table,
};

pub const Table = struct {
    keys: []const []const u8,
    values: []const Value,

    pub fn get(self: Table, key: []const u8) ?Value {
        for (self.keys, self.values) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }

    pub fn getTable(self: Table, key: []const u8) ?Table {
        if (self.get(key)) |v| {
            switch (v) {
                .table => |t| return t,
                else => return null,
            }
        }
        return null;
    }

    pub fn getString(self: Table, key: []const u8) ?[]const u8 {
        if (self.get(key)) |v| {
            switch (v) {
                .string => |s| return s,
                else => return null,
            }
        }
        return null;
    }

    pub fn getArray(self: Table, key: []const u8) ?[]const Value {
        if (self.get(key)) |v| {
            switch (v) {
                .array => |a| return a,
                else => return null,
            }
        }
        return null;
    }
};

pub const ParseError = error{
    UnexpectedCharacter,
    UnterminatedString,
    InvalidEscape,
    ExpectedEquals,
    ExpectedNewline,
    InvalidNumber,
    OutOfMemory,
    InvalidTableHeader,
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!Table {
    var parser = Parser{
        .source = source,
        .pos = 0,
        .allocator = allocator,
    };
    return parser.parseRoot();
}

const Parser = struct {
    source: []const u8,
    pos: usize,
    allocator: std.mem.Allocator,

    fn parseRoot(self: *Parser) ParseError!Table {
        var keys: std.ArrayList([]const u8) = .{};
        var values: std.ArrayList(Value) = .{};

        var current_path: []const []const u8 = &.{};

        while (self.pos < self.source.len) {
            self.skipWhitespaceAndNewlines();
            if (self.pos >= self.source.len) break;

            const c = self.source[self.pos];

            if (c == '#') {
                self.skipLine();
                continue;
            }

            if (c == '[') {
                const is_array = self.pos + 1 < self.source.len and self.source[self.pos + 1] == '[';
                if (is_array) {
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }

                const path = self.parseTablePath() catch return ParseError.InvalidTableHeader;
                current_path = path;

                if (is_array) {
                    if (self.pos < self.source.len and self.source[self.pos] == ']') self.pos += 1;
                }
                if (self.pos < self.source.len and self.source[self.pos] == ']') self.pos += 1;
                self.skipLine();
                continue;
            }

            const key = self.parseKey() catch continue;
            self.skipWhitespace();
            if (self.pos >= self.source.len or self.source[self.pos] != '=') {
                self.skipLine();
                continue;
            }
            self.pos += 1;
            self.skipWhitespace();
            const value = self.parseValue() catch continue;
            self.skipLine();

            const full_key = self.buildFullKey(current_path, key) catch continue;

            keys.append(self.allocator, full_key) catch return ParseError.OutOfMemory;
            values.append(self.allocator, value) catch return ParseError.OutOfMemory;
        }

        return Table{
            .keys = keys.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .values = values.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        };
    }

    fn buildFullKey(self: *Parser, path: []const []const u8, key: []const u8) ![]const u8 {
        if (path.len == 0) return key;

        var total_len: usize = 0;
        for (path) |segment| {
            total_len += segment.len + 1;
        }
        total_len += key.len;

        const buf = try self.allocator.alloc(u8, total_len);
        var offset: usize = 0;
        for (path) |segment| {
            @memcpy(buf[offset .. offset + segment.len], segment);
            offset += segment.len;
            buf[offset] = '.';
            offset += 1;
        }
        @memcpy(buf[offset .. offset + key.len], key);

        return buf;
    }

    fn parseTablePath(self: *Parser) ![]const []const u8 {
        var segments: std.ArrayList([]const u8) = .{};

        while (self.pos < self.source.len and self.source[self.pos] != ']') {
            self.skipWhitespace();
            const start = self.pos;

            if (self.pos < self.source.len and self.source[self.pos] == '"') {
                const s = try self.parseString();
                try segments.append(self.allocator, s);
            } else {
                while (self.pos < self.source.len) {
                    const ch = self.source[self.pos];
                    if (ch == '.' or ch == ']' or ch == ' ' or ch == '\t') break;
                    self.pos += 1;
                }
                if (self.pos == start) break;
                try segments.append(self.allocator, try self.allocator.dupe(u8, self.source[start..self.pos]));
            }

            self.skipWhitespace();
            if (self.pos < self.source.len and self.source[self.pos] == '.') {
                self.pos += 1;
            }
        }

        return try segments.toOwnedSlice(self.allocator);
    }

    fn parseKey(self: *Parser) ![]const u8 {
        const start = self.pos;
        if (self.pos < self.source.len and self.source[self.pos] == '"') {
            return self.parseString();
        }

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '=' or c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
            self.pos += 1;
        }
        if (self.pos == start) return ParseError.UnexpectedCharacter;
        return self.allocator.dupe(u8, self.source[start..self.pos]) catch return ParseError.OutOfMemory;
    }

    fn parseValue(self: *Parser) ParseError!Value {
        if (self.pos >= self.source.len) return ParseError.UnexpectedCharacter;

        const c = self.source[self.pos];

        if (c == '"') {
            return Value{ .string = try self.parseString() };
        }
        if (c == '[') {
            return Value{ .array = try self.parseArray() };
        }
        if (c == '{') {
            return Value{ .table = try self.parseInlineTable() };
        }
        if (c == 't' or c == 'f') {
            return try self.parseBool();
        }
        if (c == '-' or (c >= '0' and c <= '9')) {
            return try self.parseNumber();
        }

        return ParseError.UnexpectedCharacter;
    }

    fn parseString(self: *Parser) ParseError![]const u8 {
        if (self.pos >= self.source.len or self.source[self.pos] != '"') return ParseError.UnexpectedCharacter;
        self.pos += 1;

        var result: std.ArrayList(u8) = .{};

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '"') {
                self.pos += 1;
                return result.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.source.len) return ParseError.InvalidEscape;
                const esc = self.source[self.pos];
                const escaped: u8 = switch (esc) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    else => return ParseError.InvalidEscape,
                };
                result.append(self.allocator, escaped) catch return ParseError.OutOfMemory;
            } else {
                result.append(self.allocator, c) catch return ParseError.OutOfMemory;
            }
            self.pos += 1;
        }

        return ParseError.UnterminatedString;
    }

    fn parseArray(self: *Parser) ParseError![]const Value {
        self.pos += 1;
        var items: std.ArrayList(Value) = .{};

        while (self.pos < self.source.len) {
            self.skipWhitespaceAndNewlines();
            if (self.pos >= self.source.len) break;

            if (self.source[self.pos] == ']') {
                self.pos += 1;
                return items.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
            }

            if (self.source[self.pos] == '#') {
                self.skipLine();
                continue;
            }

            const v = try self.parseValue();
            items.append(self.allocator, v) catch return ParseError.OutOfMemory;

            self.skipWhitespaceAndNewlines();
            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            }
        }

        return items.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
    }

    fn parseInlineTable(self: *Parser) ParseError!Table {
        self.pos += 1;
        var k: std.ArrayList([]const u8) = .{};
        var v: std.ArrayList(Value) = .{};

        while (self.pos < self.source.len) {
            self.skipWhitespace();
            if (self.pos >= self.source.len) break;

            if (self.source[self.pos] == '}') {
                self.pos += 1;
                return Table{
                    .keys = k.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
                    .values = v.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
                };
            }

            const key = self.parseKey() catch break;
            self.skipWhitespace();
            if (self.pos < self.source.len and self.source[self.pos] == '=') {
                self.pos += 1;
            }
            self.skipWhitespace();
            const val = self.parseValue() catch break;

            k.append(self.allocator, key) catch return ParseError.OutOfMemory;
            v.append(self.allocator, val) catch return ParseError.OutOfMemory;

            self.skipWhitespace();
            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            }
        }

        return Table{
            .keys = k.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
            .values = v.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory,
        };
    }

    fn parseBool(self: *Parser) ParseError!Value {
        if (self.pos + 4 <= self.source.len and std.mem.eql(u8, self.source[self.pos .. self.pos + 4], "true")) {
            self.pos += 4;
            return Value{ .boolean = true };
        }
        if (self.pos + 5 <= self.source.len and std.mem.eql(u8, self.source[self.pos .. self.pos + 5], "false")) {
            self.pos += 5;
            return Value{ .boolean = false };
        }
        return ParseError.UnexpectedCharacter;
    }

    fn parseNumber(self: *Parser) ParseError!Value {
        const start = self.pos;
        if (self.source[self.pos] == '-') self.pos += 1;
        while (self.pos < self.source.len and self.source[self.pos] >= '0' and self.source[self.pos] <= '9') {
            self.pos += 1;
        }
        if (self.pos == start) return ParseError.InvalidNumber;
        const num = std.fmt.parseInt(i64, self.source[start..self.pos], 10) catch return ParseError.InvalidNumber;
        return Value{ .integer = num };
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.pos < self.source.len and (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) {
            self.pos += 1;
        }
    }

    fn skipWhitespaceAndNewlines(self: *Parser) void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else break;
        }
    }

    fn skipLine(self: *Parser) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.source.len) self.pos += 1;
    }
};

// ── Tests ──────────────────────────────────────────────────────

test "parse simple key-value" {
    const source =
        \\name = "hello"
        \\count = 42
        \\enabled = true
    ;
    const gpa = std.testing.allocator;
    const table = try parse(gpa, source);
    defer {
        for (table.keys) |k| gpa.free(k);
        gpa.free(table.keys);
        for (table.values) |v| {
            switch (v) {
                .string => |s| gpa.free(s),
                else => {},
            }
        }
        gpa.free(table.values);
    }

    try std.testing.expectEqualStrings("hello", table.getString("name").?);
    try std.testing.expectEqual(@as(i64, 42), table.get("count").?.integer);
    try std.testing.expectEqual(true, table.get("enabled").?.boolean);
}

test "parse string array" {
    const source =
        \\tags = ["docker", "build", "container"]
    ;
    const gpa = std.testing.allocator;
    const table = try parse(gpa, source);
    defer {
        for (table.keys) |k| gpa.free(k);
        gpa.free(table.keys);
        for (table.values) |v| {
            switch (v) {
                .array => |arr| {
                    for (arr) |item| {
                        switch (item) {
                            .string => |s| gpa.free(s),
                            else => {},
                        }
                    }
                    gpa.free(arr);
                },
                else => {},
            }
        }
        gpa.free(table.values);
    }

    const arr = table.getArray("tags").?;
    try std.testing.expectEqual(@as(usize, 3), arr.len);
    try std.testing.expectEqualStrings("docker", arr[0].string);
    try std.testing.expectEqualStrings("build", arr[1].string);
}

test "parse inline table" {
    const source =
        \\image = { prompt = "Image name" }
    ;
    const gpa = std.testing.allocator;
    const table = try parse(gpa, source);
    defer {
        for (table.keys) |k| gpa.free(k);
        gpa.free(table.keys);
        for (table.values) |v| {
            switch (v) {
                .table => |t| {
                    for (t.keys) |k| gpa.free(k);
                    gpa.free(t.keys);
                    for (t.values) |tv| {
                        switch (tv) {
                            .string => |s| gpa.free(s),
                            else => {},
                        }
                    }
                    gpa.free(t.values);
                },
                else => {},
            }
        }
        gpa.free(table.values);
    }

    const inner = table.getTable("image").?;
    try std.testing.expectEqualStrings("Image name", inner.getString("prompt").?);
}
