/// CLI command dispatcher for zipet.
const std = @import("std");
const store = @import("store.zig");
const config = @import("config.zig");
const executor = @import("executor.zig");
const template = @import("template.zig");

fn writeOut(data: []const u8) void {
    std.fs.File.stdout().writeAll(data) catch {};
}

fn writeErr(data: []const u8) void {
    std.fs.File.stderr().writeAll(data) catch {};
}

fn printOut(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, fmt, args) catch return;
    defer alloc.free(s);
    writeOut(s);
}

fn readLine(buf: []u8) ?[]const u8 {
    const f = std.fs.File.stdin();
    var read_buf: [1]u8 = undefined;
    var i: usize = 0;
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

pub fn dispatch(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    const cmd = args[0];

    if (std.mem.eql(u8, cmd, "add")) {
        try cmdAdd(allocator, args[1..], snip_store);
    } else if (std.mem.eql(u8, cmd, "run")) {
        try cmdRun(allocator, args[1..], snip_store, cfg);
    } else if (std.mem.eql(u8, cmd, "ls")) {
        try cmdList(allocator, args[1..], snip_store);
    } else if (std.mem.eql(u8, cmd, "rm")) {
        try cmdRemove(args[1..], snip_store);
    } else if (std.mem.eql(u8, cmd, "tags")) {
        try cmdTags(allocator, snip_store);
    } else if (std.mem.eql(u8, cmd, "edit")) {
        try cmdEdit(allocator, args[1..], snip_store, cfg);
    } else if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(allocator, cfg);
    } else if (std.mem.eql(u8, cmd, "shell")) {
        try cmdShell(args[1..]);
    } else if (std.mem.eql(u8, cmd, "history")) {
        writeOut("History not yet implemented (requires SQLite)\n");
    } else if (std.mem.eql(u8, cmd, "export")) {
        try cmdExport(snip_store);
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        printHelp();
    } else if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        writeOut("zipet 0.1.0\n");
    } else {
        // Treat unknown as implicit "run" with fuzzy search
        try cmdRun(allocator, args, snip_store, cfg);
    }
}

fn cmdAdd(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store) !void {
    var cmd_text: []const u8 = "";
    var needs_free = false;

    if (args.len > 0 and std.mem.eql(u8, args[0], "--last")) {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "/bin/sh", "-c", "fc -ln -1 2>/dev/null || history 1 2>/dev/null | sed 's/^[ ]*[0-9]*[ ]*//' " },
        }) catch {
            writeOut("Could not retrieve last command\n");
            return;
        };
        defer allocator.free(result.stderr);
        cmd_text = std.mem.trim(u8, result.stdout, " \t\n\r");
        if (cmd_text.len == 0) {
            allocator.free(result.stdout);
            writeOut("No previous command found\n");
            return;
        }
        printOut(allocator, "Command: {s}\n", .{cmd_text});
        cmd_text = try allocator.dupe(u8, cmd_text);
        allocator.free(result.stdout);
        needs_free = true;
    } else if (args.len > 0) {
        cmd_text = args[0];
    } else {
        writeOut("Command: ");
        var buf: [2048]u8 = undefined;
        const input = readLine(&buf) orelse return;
        cmd_text = try allocator.dupe(u8, input);
        needs_free = true;
    }
    defer if (needs_free) allocator.free(cmd_text);

    if (cmd_text.len == 0) {
        writeOut("Empty command, aborting\n");
        return;
    }

    writeOut("Name: ");
    var name_buf: [256]u8 = undefined;
    const name = readLine(&name_buf) orelse return;
    if (name.len == 0) {
        writeOut("Name required, aborting\n");
        return;
    }

    writeOut("Description: ");
    var desc_buf: [512]u8 = undefined;
    const desc = readLine(&desc_buf) orelse return;

    writeOut("Tags (comma-separated): ");
    var tags_buf: [512]u8 = undefined;
    const tags_str = readLine(&tags_buf) orelse return;

    var tags: std.ArrayList([]const u8) = .{};
    if (tags_str.len > 0) {
        var iter = std.mem.splitScalar(u8, tags_str, ',');
        while (iter.next()) |tag| {
            const trimmed = std.mem.trim(u8, tag, " \t");
            if (trimmed.len > 0) {
                try tags.append(allocator, try allocator.dupe(u8, trimmed));
            }
        }
    }

    writeOut("Namespace [general]: ");
    var ns_buf: [256]u8 = undefined;
    const ns_input = readLine(&ns_buf) orelse return;
    const namespace = if (ns_input.len > 0) ns_input else "general";

    const detected = try template.detectParams(allocator, cmd_text);
    const params = try allocator.alloc(template.Param, detected.len);
    for (detected, 0..) |pname, i| {
        params[i] = .{
            .name = pname,
            .prompt = null,
            .default = null,
            .options = null,
            .command = null,
        };
    }

    if (detected.len > 0) {
        printOut(allocator, "Detected {d} parameter(s): ", .{detected.len});
        for (detected, 0..) |pname, i| {
            if (i > 0) writeOut(", ");
            writeOut(pname);
        }
        writeOut("\n");
    }

    const snippet = store.Snippet{
        .name = try allocator.dupe(u8, name),
        .desc = try allocator.dupe(u8, desc),
        .cmd = try allocator.dupe(u8, cmd_text),
        .tags = try tags.toOwnedSlice(allocator),
        .params = params,
        .namespace = try allocator.dupe(u8, namespace),
        .kind = .snippet,
    };

    try snip_store.add(snippet);
    printOut(allocator, "✓ Snippet '{s}' saved to {s}.toml\n", .{ name, namespace });
}

fn cmdRun(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    if (args.len == 0) {
        writeOut("Usage: zipet run <query>\n");
        return;
    }

    const query = args[0];
    const results = try snip_store.search(allocator, query);
    defer allocator.free(results);

    if (results.len == 0) {
        printOut(allocator, "No snippets matching '{s}'\n", .{query});
        return;
    }

    if (results.len == 1) {
        const result = try executor.execute(allocator, results[0], cfg);
        defer result.deinit();
        if (result.stdout.len > 0) writeOut(result.stdout);
        if (result.stderr.len > 0) writeErr(result.stderr);
        if (result.exit_code != 0) {
            printOut(allocator, "\n\x1b[31mExit code: {d}\x1b[0m\n", .{result.exit_code});
        }
        return;
    }

    printOut(allocator, "Found {d} matches for '{s}':\n\n", .{ results.len, query });
    const max_show = @min(results.len, 10);
    for (results[0..max_show], 1..) |snip, i| {
        printOut(allocator, "  {d}) \x1b[1m{s}\x1b[0m — {s}\n", .{ i, snip.name, snip.desc });
        printOut(allocator, "     \x1b[2m$ {s}\x1b[0m\n", .{snip.cmd});
    }

    writeOut("\nChoose (number): ");
    var buf: [64]u8 = undefined;
    const input = readLine(&buf) orelse return;
    const choice = std.fmt.parseInt(usize, input, 10) catch return;

    if (choice > 0 and choice <= max_show) {
        const result = try executor.execute(allocator, results[choice - 1], cfg);
        defer result.deinit();
        if (result.stdout.len > 0) writeOut(result.stdout);
        if (result.stderr.len > 0) writeErr(result.stderr);
    }
}

fn cmdList(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store) !void {
    var tag_filter: ?[]const u8 = null;
    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "--tags=")) {
            tag_filter = arg["--tags=".len..];
        }
    }

    if (snip_store.snippets.items.len == 0) {
        writeOut("No snippets yet. Add one with: zipet add\n");
        return;
    }

    var max_name: usize = 0;
    for (snip_store.snippets.items) |snip| {
        if (snip.name.len > max_name) max_name = snip.name.len;
    }
    max_name = @min(max_name, 30);

    for (snip_store.snippets.items) |snip| {
        if (tag_filter) |tf| {
            var has_tag = false;
            for (snip.tags) |tag| {
                if (std.mem.eql(u8, tag, tf)) {
                    has_tag = true;
                    break;
                }
            }
            if (!has_tag) continue;
        }

        printOut(allocator, "  \x1b[1m{s}\x1b[0m", .{snip.name});

        var pad = max_name -| snip.name.len;
        while (pad > 0) : (pad -= 1) {
            writeOut(" ");
        }

        printOut(allocator, "  {s}", .{snip.desc});

        if (snip.tags.len > 0) {
            writeOut("  \x1b[2m[");
            for (snip.tags, 0..) |tag, i| {
                if (i > 0) writeOut(", ");
                writeOut(tag);
            }
            writeOut("]\x1b[0m");
        }
        writeOut("\n");

        printOut(allocator, "  \x1b[2m$ {s}\x1b[0m\n", .{snip.cmd});
    }

    printOut(allocator, "\n{d} snippet(s)\n", .{snip_store.snippets.items.len});
}

fn cmdRemove(args: []const []const u8, snip_store: *store.Store) !void {
    if (args.len == 0) {
        writeOut("Usage: zipet rm <name>\n");
        return;
    }

    snip_store.remove(args[0]) catch |err| {
        if (err == error.NotFound) {
            writeOut("Snippet '");
            writeOut(args[0]);
            writeOut("' not found\n");
            return;
        }
        return err;
    };

    writeOut("✓ Removed '");
    writeOut(args[0]);
    writeOut("'\n");
}

fn cmdTags(allocator: std.mem.Allocator, snip_store: *store.Store) !void {
    const all_tags = try snip_store.allTags(allocator);
    defer allocator.free(all_tags);

    if (all_tags.len == 0) {
        writeOut("No tags\n");
        return;
    }

    for (all_tags) |tag| {
        var count: usize = 0;
        for (snip_store.snippets.items) |snip| {
            for (snip.tags) |t| {
                if (std.mem.eql(u8, t, tag)) {
                    count += 1;
                    break;
                }
            }
        }
        printOut(allocator, "  {s} ({d})\n", .{ tag, count });
    }
}

fn cmdEdit(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    if (args.len == 0) {
        writeOut("Usage: zipet edit <name>\n");
        return;
    }

    for (snip_store.snippets.items) |snip| {
        if (std.mem.eql(u8, snip.name, args[0])) {
            const snippets_dir = try cfg.getSnippetsDir(allocator);
            defer allocator.free(snippets_dir);

            const path = try std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ snippets_dir, snip.namespace });
            defer allocator.free(path);

            var child = std.process.Child.init(&.{ cfg.editor, path }, allocator);
            _ = try child.spawnAndWait();
            return;
        }
    }

    writeOut("Snippet '");
    writeOut(args[0]);
    writeOut("' not found\n");
}

fn cmdInit(allocator: std.mem.Allocator, cfg: config.Config) !void {
    const config_dir = try cfg.getConfigDir(allocator);
    defer allocator.free(config_dir);

    std.fs.makeDirAbsolute(config_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const snippets_dir = try cfg.getSnippetsDir(allocator);
    defer allocator.free(snippets_dir);
    std.fs.makeDirAbsolute(snippets_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const workflows_dir = try cfg.getWorkflowsDir(allocator);
    defer allocator.free(workflows_dir);
    std.fs.makeDirAbsolute(workflows_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.toml", .{config_dir});
    defer allocator.free(config_path);

    std.fs.accessAbsolute(config_path, .{}) catch {
        const file = try std.fs.createFileAbsolute(config_path, .{});
        defer file.close();
        try file.writeAll(
            \\# zipet configuration
            \\
            \\[general]
            \\# accent_color = "cyan"
            \\# preview = true
            \\
            \\[shell]
            \\# shell = "/bin/sh"
            \\# editor = "vim"
            \\
        );
    };

    const example_path = try std.fmt.allocPrint(allocator, "{s}/examples.toml", .{snippets_dir});
    defer allocator.free(example_path);

    std.fs.accessAbsolute(example_path, .{}) catch {
        const file = try std.fs.createFileAbsolute(example_path, .{});
        defer file.close();
        try file.writeAll(
            \\# zipet snippets — examples
            \\# Delete this file once you've added your own snippets!
            \\
            \\[snippets.hello]
            \\desc = "Hello world example"
            \\tags = ["example"]
            \\cmd = "echo 'Hello from zipet, {{name}}!'"
            \\
            \\[snippets.hello.params]
            \\name = { prompt = "Your name", default = "world" }
            \\
            \\[snippets.disk-usage]
            \\desc = "Show disk usage sorted by size"
            \\tags = ["system", "disk"]
            \\cmd = "du -sh * 2>/dev/null | sort -rh | head -20"
            \\
            \\[snippets.find-large]
            \\desc = "Find large files"
            \\tags = ["system", "find"]
            \\cmd = "find {{path}} -type f -size +{{size}} -exec ls -lh {} \\;"
            \\
            \\[snippets.find-large.params]
            \\path = { prompt = "Search path", default = "." }
            \\size = { prompt = "Minimum size", default = "100M" }
            \\
        );
    };

    printOut(allocator, "✓ Initialized zipet at {s}\n", .{config_dir});
    writeOut("  Created config.toml and example snippets\n");
    writeOut("  Run 'zipet ls' to see examples\n");
}

fn cmdShell(args: []const []const u8) !void {
    if (args.len == 0) {
        writeOut("Usage: zipet shell <bash|zsh|fish>\n");
        return;
    }

    const shell = args[0];

    if (std.mem.eql(u8, shell, "bash")) {
        writeOut(
            \\# zipet shell integration for bash
            \\# Add to ~/.bashrc: eval "$(zipet shell bash)"
            \\
            \\_zipet_widget() {
            \\    local selected
            \\    selected=$(zipet run --pick 2>/dev/null)
            \\    if [ -n "$selected" ]; then
            \\        READLINE_LINE="$selected"
            \\        READLINE_POINT=${#selected}
            \\    fi
            \\}
            \\
            \\_zipet_save() {
            \\    local cmd="$READLINE_LINE"
            \\    if [ -n "$cmd" ]; then
            \\        zipet add "$cmd"
            \\    fi
            \\}
            \\
            \\bind -x '"\C-s": _zipet_widget'
            \\bind -x '"\C-x\C-s": _zipet_save'
            \\
        );
    } else if (std.mem.eql(u8, shell, "zsh")) {
        writeOut(
            \\# zipet shell integration for zsh
            \\# Add to ~/.zshrc: eval "$(zipet shell zsh)"
            \\
            \\_zipet_widget() {
            \\    local selected
            \\    selected=$(zipet run --pick 2>/dev/null)
            \\    if [ -n "$selected" ]; then
            \\        LBUFFER="$selected"
            \\        zle redisplay
            \\    fi
            \\}
            \\zle -N _zipet_widget
            \\bindkey '^S' _zipet_widget
            \\
            \\_zipet_save() {
            \\    local cmd="$LBUFFER$RBUFFER"
            \\    if [ -n "$cmd" ]; then
            \\        zipet add "$cmd" </dev/tty
            \\    fi
            \\}
            \\zle -N _zipet_save
            \\bindkey '^X^S' _zipet_save
            \\
        );
    } else if (std.mem.eql(u8, shell, "fish")) {
        writeOut(
            \\# zipet shell integration for fish
            \\# Add to ~/.config/fish/config.fish: zipet shell fish | source
            \\
            \\function _zipet_widget
            \\    set -l selected (zipet run --pick 2>/dev/null)
            \\    if test -n "$selected"
            \\        commandline -r "$selected"
            \\    end
            \\end
            \\bind \cs _zipet_widget
            \\
        );
    } else {
        writeOut("Unknown shell. Supported: bash, zsh, fish\n");
    }
}

fn cmdExport(snip_store: *store.Store) !void {
    const alloc = std.heap.page_allocator;
    for (snip_store.snippets.items) |snip| {
        printOut(alloc, "[snippets.{s}]\n", .{snip.name});
        printOut(alloc, "desc = \"{s}\"\n", .{snip.desc});
        writeOut("tags = [");
        for (snip.tags, 0..) |tag, i| {
            if (i > 0) writeOut(", ");
            writeOut("\"");
            writeOut(tag);
            writeOut("\"");
        }
        writeOut("]\n");
        printOut(alloc, "cmd = \"{s}\"\n\n", .{snip.cmd});
    }
}

fn printHelp() void {
    writeOut(
        \\zipet — snippets that grow with you
        \\
        \\Usage: zipet [command] [options]
        \\
        \\Commands:
        \\  (none)         Open TUI
        \\  add [cmd]      Add a snippet (interactive or from argument)
        \\  add --last     Save last shell command as snippet
        \\  run <query>    Fuzzy search and execute
        \\  edit <name>    Edit snippet in $EDITOR
        \\  rm <name>      Delete snippet
        \\  ls [--tags=x]  List snippets, optionally filtered by tag
        \\  tags           List all tags
        \\  init           Initialize config directory
        \\  shell <sh>     Output shell integration (bash/zsh/fish)
        \\  export         Export all snippets as TOML
        \\  history        Show execution history
        \\  help           Show this help
        \\  version        Show version
        \\
        \\TUI Keybindings:
        \\  j/k            Navigate up/down
        \\  gg/G           First/last item
        \\  /              Focus search
        \\  Enter          Execute selected
        \\  e              Edit in $EDITOR
        \\  d              Delete
        \\  a              Add new snippet
        \\  y              Copy command to clipboard
        \\  Space          Toggle preview
        \\  t              Filter by tag
        \\  ?              Toggle help
        \\  :q             Quit
        \\
        \\https://github.com/zipet/zipet
        \\
    );
}
