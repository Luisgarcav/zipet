/// Syntax highlighting for shell commands in the preview panel.
/// Provides token-level coloring for common shell syntax:
///   - Commands/executables (bold)
///   - Flags/options (accent color)
///   - Strings (green)
///   - Variables $VAR, ${VAR} (yellow)
///   - Pipes, redirects, logical operators (cyan)
///   - Comments (dim)
///   - Numbers (magenta)
///   - Template params {{param}} (bold yellow)
const std = @import("std");

pub const TokenKind = enum {
    command, // first word or word after pipe/semicolon/&&/||
    flag, // -f, --flag
    string, // "...", '...'
    variable, // $VAR, ${VAR}
    operator, // |, ||, &&, ;, >, >>, <, 2>&1
    comment, // # ...
    number, // standalone numbers
    template, // {{param}}
    plain, // everything else
    whitespace, // spaces/tabs
};

pub const Token = struct {
    text: []const u8,
    kind: TokenKind,
};

/// Tokenize a shell command string for syntax highlighting.
/// Returns a slice of tokens. Caller owns the slice (not the text — it points into `cmd`).
pub fn tokenize(allocator: std.mem.Allocator, cmd: []const u8) ![]Token {
    var tokens: std.ArrayList(Token) = .{};
    var i: usize = 0;
    var expect_command = true; // next non-whitespace is a command

    while (i < cmd.len) {
        // Whitespace
        if (cmd[i] == ' ' or cmd[i] == '\t') {
            const start = i;
            while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
            try tokens.append(allocator, .{ .text = cmd[start..i], .kind = .whitespace });
            continue;
        }

        // Comment
        if (cmd[i] == '#') {
            try tokens.append(allocator, .{ .text = cmd[i..], .kind = .comment });
            break;
        }

        // Template parameter {{...}}
        if (i + 1 < cmd.len and cmd[i] == '{' and cmd[i + 1] == '{') {
            const start = i;
            i += 2;
            while (i + 1 < cmd.len) {
                if (cmd[i] == '}' and cmd[i + 1] == '}') {
                    i += 2;
                    break;
                }
                i += 1;
            }
            try tokens.append(allocator, .{ .text = cmd[start..i], .kind = .template });
            expect_command = false;
            continue;
        }

        // Variable $VAR or ${VAR}
        if (cmd[i] == '$') {
            const start = i;
            i += 1;
            if (i < cmd.len and cmd[i] == '{') {
                while (i < cmd.len and cmd[i] != '}') i += 1;
                if (i < cmd.len) i += 1; // skip }
            } else if (i < cmd.len and cmd[i] == '(') {
                // $(...) subshell
                var depth: usize = 1;
                i += 1;
                while (i < cmd.len and depth > 0) {
                    if (cmd[i] == '(') depth += 1;
                    if (cmd[i] == ')') depth -= 1;
                    i += 1;
                }
            } else {
                while (i < cmd.len and (std.ascii.isAlphanumeric(cmd[i]) or cmd[i] == '_')) i += 1;
            }
            try tokens.append(allocator, .{ .text = cmd[start..i], .kind = .variable });
            expect_command = false;
            continue;
        }

        // String (double-quoted)
        if (cmd[i] == '"') {
            const start = i;
            i += 1;
            while (i < cmd.len) {
                if (cmd[i] == '\\' and i + 1 < cmd.len) {
                    i += 2;
                    continue;
                }
                if (cmd[i] == '"') {
                    i += 1;
                    break;
                }
                i += 1;
            }
            try tokens.append(allocator, .{ .text = cmd[start..i], .kind = .string });
            expect_command = false;
            continue;
        }

        // String (single-quoted)
        if (cmd[i] == '\'') {
            const start = i;
            i += 1;
            while (i < cmd.len and cmd[i] != '\'') i += 1;
            if (i < cmd.len) i += 1; // skip closing '
            try tokens.append(allocator, .{ .text = cmd[start..i], .kind = .string });
            expect_command = false;
            continue;
        }

        // Backtick subshell
        if (cmd[i] == '`') {
            const start = i;
            i += 1;
            while (i < cmd.len and cmd[i] != '`') i += 1;
            if (i < cmd.len) i += 1;
            try tokens.append(allocator, .{ .text = cmd[start..i], .kind = .variable });
            expect_command = false;
            continue;
        }

        // Operators: ||, &&, |, ;, >, >>, <, <<, 2>&1, 2>, &>, &
        if (isOperatorStart(cmd, i)) {
            const start = i;
            const op_len = operatorLength(cmd, i);
            i += op_len;
            try tokens.append(allocator, .{ .text = cmd[start..i], .kind = .operator });
            expect_command = true; // next word after operator is a command
            continue;
        }

        // Word (command, flag, number, or plain)
        {
            const start = i;
            while (i < cmd.len and cmd[i] != ' ' and cmd[i] != '\t' and
                !isOperatorStart(cmd, i) and cmd[i] != '"' and cmd[i] != '\'' and
                cmd[i] != '$' and cmd[i] != '#' and
                !(i + 1 < cmd.len and cmd[i] == '{' and cmd[i + 1] == '{'))
            {
                i += 1;
            }

            const word = cmd[start..i];
            if (word.len == 0) {
                // Safety: skip one byte to avoid infinite loop
                i += 1;
                continue;
            }

            const kind: TokenKind = if (word.len > 0 and word[0] == '-')
                .flag
            else if (expect_command and !isNumber(word))
                .command
            else if (isNumber(word))
                .number
            else
                .plain;

            try tokens.append(allocator, .{ .text = word, .kind = kind });
            if (kind == .command) expect_command = false;
        }
    }

    return try tokens.toOwnedSlice(allocator);
}

fn isOperatorStart(cmd: []const u8, i: usize) bool {
    const c = cmd[i];
    if (c == '|' or c == ';' or c == '>' or c == '<') return true;
    if (c == '&') return true;
    // 2> or 2>> redirect
    if (c == '2' and i + 1 < cmd.len and (cmd[i + 1] == '>' or (cmd[i + 1] == '&' and i + 2 < cmd.len and cmd[i + 2] == '1'))) return true;
    return false;
}

fn operatorLength(cmd: []const u8, i: usize) usize {
    if (i >= cmd.len) return 0;
    const remaining = cmd.len - i;

    // 2>&1
    if (remaining >= 4 and cmd[i] == '2' and cmd[i + 1] == '>' and cmd[i + 2] == '&' and cmd[i + 3] == '1') return 4;
    // 2>>
    if (remaining >= 3 and cmd[i] == '2' and cmd[i + 1] == '>' and cmd[i + 2] == '>') return 3;
    // 2>
    if (remaining >= 2 and cmd[i] == '2' and cmd[i + 1] == '>') return 2;
    // &>
    if (remaining >= 2 and cmd[i] == '&' and cmd[i + 1] == '>') return 2;
    // >>
    if (remaining >= 2 and cmd[i] == '>' and cmd[i + 1] == '>') return 2;
    // <<
    if (remaining >= 2 and cmd[i] == '<' and cmd[i + 1] == '<') return 2;
    // ||
    if (remaining >= 2 and cmd[i] == '|' and cmd[i + 1] == '|') return 2;
    // &&
    if (remaining >= 2 and cmd[i] == '&' and cmd[i + 1] == '&') return 2;
    // Single operators
    if (cmd[i] == '|' or cmd[i] == '>' or cmd[i] == '<' or cmd[i] == ';') return 1;
    // & at end or before space (background operator)
    if (cmd[i] == '&') return 1;
    return 1;
}

fn isNumber(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| {
        if (c != '.' and (c < '0' or c > '9')) return false;
    }
    return true;
}

/// Well-known commands for better detection in complex pipelines
const known_commands = [_][]const u8{
    "awk",     "cat",      "cd",       "chmod",  "chown",   "cp",
    "curl",    "cut",      "diff",     "docker", "echo",    "env",
    "exec",    "export",   "find",     "git",    "grep",    "head",
    "jq",      "kubectl",  "less",     "ln",     "ls",      "make",
    "mkdir",   "more",     "mount",    "mv",     "npm",     "pip",
    "printf",  "ps",       "python",   "python3", "rm",     "rsync",
    "scp",     "sed",      "sort",     "ssh",    "sudo",    "tail",
    "tar",     "tee",      "test",     "touch",  "tr",      "uniq",
    "wc",      "wget",     "which",    "xargs",  "yarn",    "zig",
};

pub fn isKnownCommand(word: []const u8) bool {
    for (known_commands) |cmd| {
        if (std.mem.eql(u8, word, cmd)) return true;
    }
    return false;
}

test "tokenize simple command" {
    const allocator = std.testing.allocator;
    const tokens = try tokenize(allocator, "docker build -t myimage:latest .");
    defer allocator.free(tokens);

    try std.testing.expectEqual(@as(usize, 9), tokens.len);
    try std.testing.expectEqual(TokenKind.command, tokens[0].kind);
    try std.testing.expectEqualStrings("docker", tokens[0].text);
    try std.testing.expectEqual(TokenKind.flag, tokens[4].kind);
    try std.testing.expectEqualStrings("-t", tokens[4].text);
}

test "tokenize with pipe and template" {
    const allocator = std.testing.allocator;
    const tokens = try tokenize(allocator, "echo {{name}} | grep test");
    defer allocator.free(tokens);

    // echo, " ", {{name}}, " ", |, " ", grep, " ", test
    var has_template = false;
    var has_operator = false;
    for (tokens) |tok| {
        if (tok.kind == .template) has_template = true;
        if (tok.kind == .operator) has_operator = true;
    }
    try std.testing.expect(has_template);
    try std.testing.expect(has_operator);
}

test "tokenize with variable and string" {
    const allocator = std.testing.allocator;
    const tokens = try tokenize(allocator, "curl -s \"$API_URL/endpoint\"");
    defer allocator.free(tokens);

    var has_flag = false;
    var has_string = false;
    for (tokens) |tok| {
        if (tok.kind == .flag) has_flag = true;
        if (tok.kind == .string) has_string = true;
    }
    try std.testing.expect(has_flag);
    try std.testing.expect(has_string);
}
