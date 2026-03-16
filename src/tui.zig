/// TUI for zipet — vim-native terminal interface.
/// Uses raw ANSI escape codes, no ncurses dependency.
const std = @import("std");
const store = @import("store.zig");
const config = @import("config.zig");
const executor = @import("executor.zig");
const template = @import("template.zig");

const ESC = "\x1b";
const CSI = ESC ++ "[";
const RESET = CSI ++ "0m";
const BOLD = CSI ++ "1m";
const DIM = CSI ++ "2m";
const REVERSE = CSI ++ "7m";
const HIDE_CURSOR = CSI ++ "?25l";
const SHOW_CURSOR = CSI ++ "?25h";
const CLEAR_LINE = CSI ++ "2K";
const HOME = CSI ++ "H";
const ALT_SCREEN_ON = CSI ++ "?1049h";
const ALT_SCREEN_OFF = CSI ++ "?1049l";

const Mode = enum {
    normal,
    search,
    command,
    help,
    confirm_delete,
};

const State = struct {
    mode: Mode = .normal,
    cursor: usize = 0,
    scroll_offset: usize = 0,
    search_buf: [256]u8 = [_]u8{0} ** 256,
    search_len: usize = 0,
    command_buf: [256]u8 = [_]u8{0} ** 256,
    command_len: usize = 0,
    preview_visible: bool = true,
    running: bool = true,
    filtered_indices: []usize = &.{},
    term_rows: usize = 24,
    term_cols: usize = 80,
    message: ?[]const u8 = null,
    pending_g: bool = false,

    fn searchQuery(self: *State) []const u8 {
        return self.search_buf[0..self.search_len];
    }

    fn commandStr(self: *State) []const u8 {
        return self.command_buf[0..self.command_len];
    }

    fn listHeight(self: *State) usize {
        const chrome = if (self.preview_visible) @as(usize, 8) else @as(usize, 4);
        if (self.term_rows <= chrome) return 1;
        return self.term_rows - chrome;
    }
};

/// Buffer-based writer that collects output and flushes to a file descriptor.
const ScreenBuf = struct {
    buf: std.ArrayList(u8),

    fn init() ScreenBuf {
        return .{ .buf = .{} };
    }

    fn writeAll(self: *ScreenBuf, alloc: std.mem.Allocator, data: []const u8) !void {
        try self.buf.appendSlice(alloc, data);
    }

    fn print(self: *ScreenBuf, alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(alloc, fmt, args);
        defer alloc.free(s);
        try self.buf.appendSlice(alloc, s);
    }

    fn writeByteNTimes(self: *ScreenBuf, alloc: std.mem.Allocator, byte: u8, n: usize) !void {
        var i: usize = 0;
        while (i < n) : (i += 1) {
            try self.buf.append(alloc, byte);
        }
    }

    fn flush(self: *ScreenBuf, alloc: std.mem.Allocator, file: std.fs.File) !void {
        if (self.buf.items.len > 0) {
            try file.writeAll(self.buf.items);
            self.buf.clearRetainingCapacity();
        }
        _ = alloc;
    }

    fn deinit(self: *ScreenBuf, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }
};

fn readLine(buf: []u8) ?[]const u8 {
    const f = std.fs.File.stdin();
    var i: usize = 0;
    var read_buf: [1]u8 = undefined;
    while (i < buf.len) {
        const n = f.read(&read_buf) catch return null;
        if (n == 0) return null;
        if (read_buf[0] == '\n') {
            return std.mem.trim(u8, buf[0..i], " \t\r");
        }
        buf[i] = read_buf[0];
        i += 1;
    }
    return std.mem.trim(u8, buf[0..i], " \t\r");
}

pub fn run(allocator: std.mem.Allocator, snip_store: *store.Store, cfg: config.Config) !void {
    const tty = try std.fs.openFileAbsolute("/dev/tty", .{ .mode = .read_write });
    defer tty.close();

    const orig_termios = try std.posix.tcgetattr(tty.handle);

    var state = State{};
    state.term_rows, state.term_cols = getTermSize();

    // Initial filter
    state.filtered_indices = try updateFilter(allocator, snip_store, state.searchQuery());
    defer allocator.free(state.filtered_indices);

    var screen = ScreenBuf.init();
    defer screen.deinit(allocator);

    // Main loop
    while (state.running) {
        // Enter raw mode each iteration (may have been restored for editor)
        var raw = orig_termios;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.cc[@intFromEnum(std.posix.system.V.MIN)] = 0;
        raw.cc[@intFromEnum(std.posix.system.V.TIME)] = 1;
        try std.posix.tcsetattr(tty.handle, .FLUSH, raw);

        try tty.writeAll(ALT_SCREEN_ON ++ HIDE_CURSOR);

        try renderScreen(allocator, &screen, &state, snip_store, cfg);
        try screen.flush(allocator, tty);

        // Read input
        var buf: [16]u8 = undefined;
        const n = tty.read(&buf) catch 0;
        if (n == 0) continue;

        const input = buf[0..n];
        try handleInput(allocator, input, &state, snip_store, cfg, tty, orig_termios);
    }

    // Restore terminal on exit
    tty.writeAll(ALT_SCREEN_OFF ++ SHOW_CURSOR) catch {};
    std.posix.tcsetattr(tty.handle, .FLUSH, orig_termios) catch {};
}

fn getTermSize() struct { usize, usize } {
    var wsz: std.posix.winsize = undefined;
    const rc = std.posix.system.ioctl(std.posix.STDOUT_FILENO, std.posix.system.T.IOCGWINSZ, @intFromPtr(&wsz));
    if (rc == 0 and wsz.row > 0 and wsz.col > 0) {
        return .{ wsz.row, wsz.col };
    }
    return .{ 24, 80 };
}

fn renderScreen(alloc: std.mem.Allocator, w: *ScreenBuf, state: *State, snip_store: *store.Store, cfg: config.Config) !void {
    const accent = cfg.accent_color.ansiCode();
    const accent_bold = cfg.accent_color.boldCode();
    const cols = state.term_cols;

    try w.writeAll(alloc, HOME);

    // ── Status bar ──
    try w.writeAll(alloc, REVERSE);
    try w.print(alloc, " zipet", .{});
    const status_right = try std.fmt.allocPrint(alloc, "{d} snippets ", .{snip_store.snippets.items.len});
    defer alloc.free(status_right);

    const pad_len = if (cols > 6 + status_right.len) cols - 6 - status_right.len else 0;
    try w.writeByteNTimes(alloc, ' ', pad_len);
    try w.writeAll(alloc, status_right);
    try w.writeAll(alloc, RESET ++ "\n");

    // ── Search bar ──
    try w.writeAll(alloc, CLEAR_LINE);
    if (state.mode == .search) {
        try w.print(alloc, " {s}>{s} {s}", .{ accent_bold, RESET, state.searchQuery() });
        try w.writeAll(alloc, SHOW_CURSOR);
    } else if (state.mode == .command) {
        try w.print(alloc, " :{s}", .{state.commandStr()});
        try w.writeAll(alloc, SHOW_CURSOR);
    } else {
        try w.writeAll(alloc, HIDE_CURSOR);
        if (state.search_len > 0) {
            try w.print(alloc, " {s}/{s} {s}", .{ DIM, RESET, state.searchQuery() });
        } else {
            try w.print(alloc, " {s}type / to search{s}", .{ DIM, RESET });
        }
    }
    try w.writeAll(alloc, "\n");

    // ── Separator ──
    try w.writeAll(alloc, CLEAR_LINE ++ DIM);
    try w.writeByteNTimes(alloc, '-', cols);
    try w.writeAll(alloc, RESET ++ "\n");

    // ── List ──
    const list_h = state.listHeight();
    const total = state.filtered_indices.len;

    var i: usize = 0;
    while (i < list_h) : (i += 1) {
        try w.writeAll(alloc, CLEAR_LINE);
        const idx = state.scroll_offset + i;
        if (idx < total) {
            const snip_idx = state.filtered_indices[idx];
            const snip = &snip_store.snippets.items[snip_idx];
            const is_selected = idx == state.cursor;

            if (is_selected) {
                try w.print(alloc, " {s}▸{s} ", .{ accent_bold, RESET });
                try w.print(alloc, "{s}{s}{s}", .{ accent_bold, snip.name, RESET });
            } else {
                try w.writeAll(alloc, "   ");
                try w.print(alloc, "{s}{s}{s}", .{ BOLD, snip.name, RESET });
            }

            const name_len = snip.name.len;
            if (name_len < 24) {
                try w.writeByteNTimes(alloc, ' ', 24 - name_len);
            } else {
                try w.writeAll(alloc, " ");
            }

            const desc_max = if (cols > 40) cols - 40 else 10;
            if (snip.desc.len > desc_max) {
                try w.print(alloc, "{s}", .{DIM});
                try w.writeAll(alloc, snip.desc[0..desc_max -| 3]);
                try w.print(alloc, "...{s}", .{RESET});
            } else {
                try w.print(alloc, "{s}{s}{s}", .{ DIM, snip.desc, RESET });
            }

            if (snip.tags.len > 0 and cols > 60) {
                try w.print(alloc, "  {s}[", .{DIM});
                for (snip.tags, 0..) |tag, ti| {
                    if (ti > 0) try w.writeAll(alloc, ",");
                    try w.writeAll(alloc, tag);
                }
                try w.print(alloc, "]{s}", .{RESET});
            }
        }
        try w.writeAll(alloc, "\n");
    }

    // ── Preview ──
    if (state.preview_visible) {
        try w.writeAll(alloc, CLEAR_LINE ++ DIM);
        try w.writeByteNTimes(alloc, '-', cols);
        try w.writeAll(alloc, RESET ++ "\n");

        if (total > 0 and state.cursor < total) {
            const snip_idx = state.filtered_indices[state.cursor];
            const snip = &snip_store.snippets.items[snip_idx];

            try w.writeAll(alloc, CLEAR_LINE);
            try w.print(alloc, " {s}$ {s}{s}\n", .{ accent, snip.cmd, RESET });

            try w.writeAll(alloc, CLEAR_LINE);
            if (snip.params.len > 0) {
                try w.print(alloc, " {s}params: ", .{DIM});
                for (snip.params, 0..) |p, pi| {
                    if (pi > 0) try w.writeAll(alloc, ", ");
                    try w.writeAll(alloc, p.name);
                    if (p.default) |d| {
                        try w.print(alloc, " (default: {s})", .{d});
                    }
                }
                try w.print(alloc, "{s}", .{RESET});
            }
            try w.writeAll(alloc, "\n");
        } else {
            try w.writeAll(alloc, CLEAR_LINE ++ "\n");
            try w.writeAll(alloc, CLEAR_LINE ++ "\n");
        }
    }

    // ── Keybinding bar ──
    try w.writeAll(alloc, CLEAR_LINE ++ DIM);
    if (state.mode == .help) {
        try w.writeAll(alloc, CLEAR_LINE);
        try w.writeAll(alloc, " j/k move  gg/G first/last  Ctrl-D/U page  / search  Enter run");
        try w.writeAll(alloc, "\n" ++ CLEAR_LINE);
        try w.writeAll(alloc, " e edit  d delete  a add  y yank  Space preview  t tags  :q quit");
    } else if (state.message) |msg| {
        try w.writeAll(alloc, msg);
        state.message = null;
    } else {
        try w.writeAll(alloc, " j/k move  Enter run  e edit  d del  a add  y yank  / search  ? help");
    }
    try w.writeAll(alloc, RESET);
}

fn handleInput(allocator: std.mem.Allocator, input: []const u8, state: *State, snip_store: *store.Store, cfg: config.Config, tty: std.fs.File, orig_termios: std.posix.termios) !void {
    switch (state.mode) {
        .search => try handleSearchInput(allocator, input, state, snip_store),
        .command => try handleCommandInput(input, state),
        .confirm_delete => try handleConfirmDelete(input, state, snip_store),
        .normal => try handleNormalInput(allocator, input, state, snip_store, cfg, tty, orig_termios),
        .help => {
            if (input[0] == '?' or input[0] == 27) {
                state.mode = .normal;
            }
        },
    }
}

fn handleNormalInput(allocator: std.mem.Allocator, input: []const u8, state: *State, snip_store: *store.Store, cfg: config.Config, tty: std.fs.File, orig_termios: std.posix.termios) !void {
    const total = state.filtered_indices.len;

    if (input.len == 1) {
        switch (input[0]) {
            'j' => {
                if (total > 0 and state.cursor < total - 1) {
                    state.cursor += 1;
                    adjustScroll(state);
                }
                state.pending_g = false;
            },
            'k' => {
                if (state.cursor > 0) {
                    state.cursor -= 1;
                    adjustScroll(state);
                }
                state.pending_g = false;
            },
            'g' => {
                if (state.pending_g) {
                    state.cursor = 0;
                    state.scroll_offset = 0;
                    state.pending_g = false;
                } else {
                    state.pending_g = true;
                }
            },
            'G' => {
                if (total > 0) {
                    state.cursor = total - 1;
                    adjustScroll(state);
                }
                state.pending_g = false;
            },
            '/' => {
                state.mode = .search;
                state.pending_g = false;
            },
            ':' => {
                state.mode = .command;
                state.command_len = 0;
                state.pending_g = false;
            },
            '?' => {
                state.mode = .help;
                state.pending_g = false;
            },
            'q' => {
                state.running = false;
            },
            ' ' => {
                state.preview_visible = !state.preview_visible;
                state.pending_g = false;
            },
            'a' => {
                // Exit alt screen, restore terminal for interactive add
                tty.writeAll(ALT_SCREEN_OFF ++ SHOW_CURSOR) catch {};
                std.posix.tcsetattr(tty.handle, .FLUSH, orig_termios) catch {};

                // Interactive add flow
                const stdout = std.fs.File.stdout();
                stdout.writeAll("Command: ") catch {};
                var cmd_buf: [2048]u8 = undefined;
                const cmd_input = readLine(&cmd_buf);
                if (cmd_input) |cmd_text| {
                    if (cmd_text.len > 0) {
                        stdout.writeAll("Name: ") catch {};
                        var name_buf: [256]u8 = undefined;
                        const name = readLine(&name_buf);
                        if (name) |n| {
                            if (n.len > 0) {
                                stdout.writeAll("Description: ") catch {};
                                var desc_buf: [512]u8 = undefined;
                                const desc = readLine(&desc_buf) orelse "";

                                stdout.writeAll("Tags (comma-separated): ") catch {};
                                var tags_buf: [512]u8 = undefined;
                                const tags_str = readLine(&tags_buf) orelse "";

                                var tags: std.ArrayList([]const u8) = .{};
                                if (tags_str.len > 0) {
                                    var iter = std.mem.splitScalar(u8, tags_str, ',');
                                    while (iter.next()) |tag| {
                                        const trimmed = std.mem.trim(u8, tag, " \t");
                                        if (trimmed.len > 0) {
                                            tags.append(allocator, allocator.dupe(u8, trimmed) catch continue) catch {};
                                        }
                                    }
                                }

                                stdout.writeAll("Namespace [general]: ") catch {};
                                var ns_buf: [256]u8 = undefined;
                                const ns_input = readLine(&ns_buf) orelse "";
                                const namespace = if (ns_input.len > 0) ns_input else "general";

                                const detected = template.detectParams(allocator, cmd_text) catch &[_][]const u8{};
                                var params: []template.Param = &.{};
                                if (detected.len > 0) {
                                    if (allocator.alloc(template.Param, detected.len)) |p| {
                                        params = p;
                                        for (detected, 0..) |pname, i| {
                                            params[i] = .{
                                                .name = pname,
                                                .prompt = null,
                                                .default = null,
                                                .options = null,
                                                .command = null,
                                            };
                                        }
                                    } else |_| {}
                                }

                                const snippet = store.Snippet{
                                    .name = allocator.dupe(u8, n) catch "",
                                    .desc = allocator.dupe(u8, desc) catch "",
                                    .cmd = allocator.dupe(u8, cmd_text) catch "",
                                    .tags = tags.toOwnedSlice(allocator) catch &.{},
                                    .params = params,
                                    .namespace = allocator.dupe(u8, namespace) catch "general",
                                    .kind = .snippet,
                                };

                                snip_store.add(snippet) catch {};

                                // Rebuild filter
                                allocator.free(state.filtered_indices);
                                state.filtered_indices = updateFilter(allocator, snip_store, state.searchQuery()) catch &.{};

                                state.message = "✓ Snippet added";
                            }
                        }
                    }
                }
                state.pending_g = false;
            },
            'y' => {
                if (total > 0 and state.cursor < total) {
                    const snip_idx = state.filtered_indices[state.cursor];
                    const snip = &snip_store.snippets.items[snip_idx];

                    const copy_cmds = [_][]const []const u8{
                        &.{ "xclip", "-selection", "clipboard" },
                        &.{ "xsel", "--clipboard", "--input" },
                        &.{"wl-copy"},
                        &.{"pbcopy"},
                    };

                    var copied = false;
                    for (copy_cmds) |argv| {
                        var child = std.process.Child.init(argv, allocator);
                        child.stdin_behavior = .Pipe;
                        if (child.spawn()) |_| {} else |_| continue;

                        if (child.stdin) |*stdin_pipe| {
                            stdin_pipe.writeAll(snip.cmd) catch {};
                            stdin_pipe.close();
                            child.stdin = null;
                        }
                        const term = child.wait() catch continue;
                        if (term.Exited == 0) {
                            copied = true;
                            break;
                        }
                    }

                    state.message = if (copied) "✓ Copied to clipboard" else "✗ No clipboard tool found";
                }
                state.pending_g = false;
            },
            'd' => {
                if (total > 0 and state.cursor < total) {
                    state.mode = .confirm_delete;
                }
                state.pending_g = false;
            },
            'e' => {
                if (total > 0 and state.cursor < total) {
                    const snip_idx = state.filtered_indices[state.cursor];
                    const snip = &snip_store.snippets.items[snip_idx];

                    const snippets_dir = cfg.getSnippetsDir(allocator) catch null;
                    if (snippets_dir) |sdir| {
                        defer allocator.free(sdir);

                        const path = std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ sdir, snip.namespace }) catch null;
                        if (path) |p| {
                            defer allocator.free(p);

                            // Exit alt screen and restore terminal for editor
                            tty.writeAll(ALT_SCREEN_OFF ++ SHOW_CURSOR) catch {};
                            std.posix.tcsetattr(tty.handle, .FLUSH, orig_termios) catch {};

                            // Spawn editor
                            var child = std.process.Child.init(&.{ cfg.editor, p }, allocator);
                            child.stdin_behavior = .Inherit;
                            child.stdout_behavior = .Inherit;
                            child.stderr_behavior = .Inherit;
                            _ = child.spawnAndWait() catch {};

                            // Reload snippets after editing
                            for (snip_store.snippets.items) |s| {
                                snip_store.freeSnippet(s);
                            }
                            snip_store.snippets.clearRetainingCapacity();
                            snip_store.loadAll() catch {};

                            // Rebuild filter
                            allocator.free(state.filtered_indices);
                            state.filtered_indices = updateFilter(allocator, snip_store, state.searchQuery()) catch &.{};
                            if (state.cursor >= state.filtered_indices.len and state.filtered_indices.len > 0) {
                                state.cursor = state.filtered_indices.len - 1;
                            }

                            state.message = "✓ Reloaded after edit";
                        }
                    }
                }
                state.pending_g = false;
            },
            '\r', '\n' => {
                if (total > 0 and state.cursor < total) {
                    // Exit TUI, execute the snippet
                    tty.writeAll(ALT_SCREEN_OFF ++ SHOW_CURSOR) catch {};

                    const snip_idx = state.filtered_indices[state.cursor];
                    const snip = &snip_store.snippets.items[snip_idx];

                    const pout = std.fmt.allocPrint(allocator, "\x1b[1m{s}\x1b[0m — {s}\n\x1b[2m$ {s}\x1b[0m\n\n", .{ snip.name, snip.desc, snip.cmd }) catch null;
                    if (pout) |p| {
                        std.fs.File.stdout().writeAll(p) catch {};
                        allocator.free(p);
                    }

                    if (snip.params.len > 0) {
                        var param_keys = try allocator.alloc([]const u8, snip.params.len);
                        defer allocator.free(param_keys);
                        var param_values = try allocator.alloc([]const u8, snip.params.len);
                        defer {
                            for (param_values[0..snip.params.len]) |v| allocator.free(v);
                            allocator.free(param_values);
                        }

                        for (snip.params, 0..) |p, pi| {
                            param_keys[pi] = p.name;
                            const prompt_text = p.prompt orelse p.name;
                            if (p.default) |d| {
                                const pr = std.fmt.allocPrint(allocator, "{s} [{s}]: ", .{ prompt_text, d }) catch null;
                                if (pr) |pp| {
                                    std.fs.File.stdout().writeAll(pp) catch {};
                                    allocator.free(pp);
                                }
                            } else {
                                const pr = std.fmt.allocPrint(allocator, "{s}: ", .{prompt_text}) catch null;
                                if (pr) |pp| {
                                    std.fs.File.stdout().writeAll(pp) catch {};
                                    allocator.free(pp);
                                }
                            }

                            var buf: [1024]u8 = undefined;
                            const user_in = readLine(&buf);
                            if (user_in) |inp| {
                                if (inp.len == 0 and p.default != null) {
                                    param_values[pi] = try allocator.dupe(u8, p.default.?);
                                } else {
                                    param_values[pi] = try allocator.dupe(u8, inp);
                                }
                            } else {
                                param_values[pi] = try allocator.dupe(u8, p.default orelse "");
                            }
                        }

                        const rendered = try template.render(allocator, snip.cmd, param_keys, param_values);
                        defer allocator.free(rendered);

                        const rp = std.fmt.allocPrint(allocator, "\n\x1b[2m$ {s}\x1b[0m\n\n", .{rendered}) catch null;
                        if (rp) |r| {
                            std.fs.File.stdout().writeAll(r) catch {};
                            allocator.free(r);
                        }
                        _ = try executor.execForeground(rendered);
                    } else {
                        _ = try executor.execForeground(snip.cmd);
                    }

                    state.running = false;
                }
                state.pending_g = false;
            },
            4 => { // Ctrl-D
                const half = state.listHeight() / 2;
                if (total > 0) {
                    state.cursor = @min(state.cursor + half, total - 1);
                    adjustScroll(state);
                }
                state.pending_g = false;
            },
            21 => { // Ctrl-U
                const half = state.listHeight() / 2;
                state.cursor -|= half;
                adjustScroll(state);
                state.pending_g = false;
            },
            27 => { // Esc
                if (state.search_len > 0) {
                    state.search_len = 0;
                    state.cursor = 0;
                    state.scroll_offset = 0;
                    allocator.free(state.filtered_indices);
                    state.filtered_indices = try updateFilter(allocator, snip_store, "");
                }
                state.pending_g = false;
            },
            else => {
                state.pending_g = false;
            },
        }
    } else if (input.len >= 3 and input[0] == 27 and input[1] == '[') {
        switch (input[2]) {
            'A' => {
                if (state.cursor > 0) {
                    state.cursor -= 1;
                    adjustScroll(state);
                }
            },
            'B' => {
                if (total > 0 and state.cursor < total - 1) {
                    state.cursor += 1;
                    adjustScroll(state);
                }
            },
            else => {},
        }
        state.pending_g = false;
    }
}

fn handleSearchInput(allocator: std.mem.Allocator, input: []const u8, state: *State, snip_store: *store.Store) !void {
    if (input.len == 1) {
        switch (input[0]) {
            27 => {
                state.mode = .normal;
            },
            '\r', '\n' => {
                state.mode = .normal;
            },
            127, 8 => {
                if (state.search_len > 0) {
                    state.search_len -= 1;
                    state.cursor = 0;
                    state.scroll_offset = 0;
                    allocator.free(state.filtered_indices);
                    state.filtered_indices = try updateFilter(allocator, snip_store, state.searchQuery());
                }
            },
            else => {
                if (input[0] >= 32 and input[0] < 127 and state.search_len < state.search_buf.len - 1) {
                    state.search_buf[state.search_len] = input[0];
                    state.search_len += 1;
                    state.cursor = 0;
                    state.scroll_offset = 0;
                    allocator.free(state.filtered_indices);
                    state.filtered_indices = try updateFilter(allocator, snip_store, state.searchQuery());
                }
            },
        }
    }
}

fn handleCommandInput(input: []const u8, state: *State) !void {
    if (input.len == 1) {
        switch (input[0]) {
            27 => {
                state.mode = .normal;
                state.command_len = 0;
            },
            '\r', '\n' => {
                const cmd = state.commandStr();
                if (std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "quit")) {
                    state.running = false;
                } else if (std.mem.eql(u8, cmd, "help")) {
                    state.mode = .help;
                } else {
                    state.message = "Unknown command";
                }
                state.command_len = 0;
                if (state.running) state.mode = .normal;
            },
            127, 8 => {
                if (state.command_len > 0) {
                    state.command_len -= 1;
                }
            },
            else => {
                if (input[0] >= 32 and input[0] < 127 and state.command_len < state.command_buf.len - 1) {
                    state.command_buf[state.command_len] = input[0];
                    state.command_len += 1;
                }
            },
        }
    }
}

fn handleConfirmDelete(input: []const u8, state: *State, snip_store: *store.Store) !void {
    if (input.len == 1) {
        switch (input[0]) {
            'y', 'Y' => {
                const total = state.filtered_indices.len;
                if (state.cursor < total) {
                    const snip_idx = state.filtered_indices[state.cursor];
                    const name = snip_store.snippets.items[snip_idx].name;
                    snip_store.remove(name) catch {};
                    state.message = "✓ Deleted";
                    if (state.cursor > 0) state.cursor -= 1;
                }
                state.mode = .normal;
            },
            else => {
                state.mode = .normal;
                state.message = "Delete cancelled";
            },
        }
    }
}

fn adjustScroll(state: *State) void {
    const h = state.listHeight();
    if (state.cursor < state.scroll_offset) {
        state.scroll_offset = state.cursor;
    } else if (state.cursor >= state.scroll_offset + h) {
        state.scroll_offset = state.cursor - h + 1;
    }
}

fn updateFilter(allocator: std.mem.Allocator, snip_store: *store.Store, query: []const u8) ![]usize {
    if (query.len == 0) {
        const indices = try allocator.alloc(usize, snip_store.snippets.items.len);
        for (indices, 0..) |*idx, i| idx.* = i;
        return indices;
    }

    const fuzzy_mod = @import("fuzzy.zig");

    const items = try allocator.alloc([]const u8, snip_store.snippets.items.len);
    defer {
        for (items) |s| allocator.free(s);
        allocator.free(items);
    }

    for (snip_store.snippets.items, 0..) |snip, i| {
        items[i] = try std.fmt.allocPrint(allocator, "{s} {s} {s}", .{ snip.name, snip.desc, snip.cmd });
    }

    const ranked = try fuzzy_mod.rank(allocator, items, query);
    return ranked;
}
