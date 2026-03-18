/// CLI command dispatcher for zipet.
const std = @import("std");
const store = @import("store.zig");
const config = @import("config.zig");
const executor = @import("executor.zig");
const template = @import("template.zig");
const workflow = @import("workflow.zig");
const pack = @import("pack.zig");
const workspace_mod = @import("workspace.zig");

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

fn eqlInsensitive(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        const la: u8 = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
        const lb: u8 = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
        if (la != lb) return false;
    }
    return true;
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
    } else if (std.mem.eql(u8, cmd, "workflow") or std.mem.eql(u8, cmd, "wf")) {
        try cmdWorkflow(allocator, args[1..], snip_store, cfg);
    } else if (std.mem.eql(u8, cmd, "parallel") or std.mem.eql(u8, cmd, "par")) {
        try cmdParallel(allocator, args[1..], snip_store, cfg);
    } else if (std.mem.eql(u8, cmd, "init")) {
        try cmdInit(allocator, cfg);
    } else if (std.mem.eql(u8, cmd, "shell")) {
        try cmdShell(args[1..]);
    } else if (std.mem.eql(u8, cmd, "pack")) {
        try cmdPack(allocator, args[1..], snip_store, cfg);
    } else if (std.mem.eql(u8, cmd, "workspace") or std.mem.eql(u8, cmd, "ws")) {
        try cmdWorkspace(allocator, args[1..], cfg);
    } else if (std.mem.eql(u8, cmd, "history")) {
        writeOut("History not yet implemented (requires SQLite)\n");
    } else if (std.mem.eql(u8, cmd, "export")) {
        try cmdExport(allocator, snip_store, args[1..]);
    } else if (std.mem.eql(u8, cmd, "import")) {
        try cmdImport(allocator, args[1..], snip_store, cfg);
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

    // Fast path: exact name match → run directly, no fuzzy needed
    for (snip_store.snippets.items) |*snip| {
        if (eqlInsensitive(snip.name, query)) {
            const result = try executor.execute(allocator, snip, cfg);
            defer result.deinit();
            if (result.stdout.len > 0) writeOut(result.stdout);
            if (result.stderr.len > 0) writeErr(result.stderr);
            if (result.exit_code != 0) {
                printOut(allocator, "\n\x1b[31mExit code: {d}\x1b[0m\n", .{result.exit_code});
            }
            return;
        }
    }

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

fn cmdExport(allocator: std.mem.Allocator, snip_store: *store.Store, args: []const []const u8) !void {
    var format: enum { toml_fmt, json } = .toml_fmt;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) format = .json;
    }

    switch (format) {
        .json => {
            writeOut("[\n");
            for (snip_store.snippets.items, 0..) |snip, si| {
                if (snip.kind == .workflow) continue;
                if (si > 0) writeOut(",\n");
                writeOut("  {\n");
                printOut(allocator, "    \"name\": \"{s}\",\n", .{snip.name});
                printOut(allocator, "    \"desc\": \"{s}\",\n", .{snip.desc});
                printOut(allocator, "    \"cmd\": \"{s}\",\n", .{snip.cmd});
                printOut(allocator, "    \"namespace\": \"{s}\",\n", .{snip.namespace});
                writeOut("    \"tags\": [");
                for (snip.tags, 0..) |tag, i| {
                    if (i > 0) writeOut(", ");
                    writeOut("\"");
                    writeOut(tag);
                    writeOut("\"");
                }
                writeOut("]\n");
                writeOut("  }");
            }
            writeOut("\n]\n");
        },
        .toml_fmt => {
            for (snip_store.snippets.items) |snip| {
                if (snip.kind == .workflow) continue;
                printOut(allocator, "[snippets.{s}]\n", .{snip.name});
                printOut(allocator, "desc = \"{s}\"\n", .{snip.desc});
                writeOut("tags = [");
                for (snip.tags, 0..) |tag, i| {
                    if (i > 0) writeOut(", ");
                    writeOut("\"");
                    writeOut(tag);
                    writeOut("\"");
                }
                writeOut("]\n");
                printOut(allocator, "cmd = \"{s}\"\n", .{snip.cmd});

                if (snip.params.len > 0) {
                    for (snip.params) |p| {
                        printOut(allocator, "\n[snippets.{s}.params.{s}]\n", .{ snip.name, p.name });
                        if (p.prompt) |pr| printOut(allocator, "prompt = \"{s}\"\n", .{pr});
                        if (p.default) |d| printOut(allocator, "default = \"{s}\"\n", .{d});
                        if (p.command) |c| printOut(allocator, "command = \"{s}\"\n", .{c});
                    }
                }
                writeOut("\n");
            }
        },
    }
}

fn cmdImport(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    _ = cfg;
    if (args.len == 0) {
        writeOut("Usage: zipet import <file>\n");
        writeOut("  Supports .toml snippet files\n");
        return;
    }

    const path = args[0];

    // Check if it's a URL (starts with http:// or https://)
    if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
        // Download with curl
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "curl", "-sfL", path },
        }) catch {
            writeOut("Failed to download URL (is curl installed?)\n");
            return;
        };
        defer allocator.free(result.stderr);
        defer allocator.free(result.stdout);

        if (result.term.Exited != 0) {
            writeOut("Failed to download: ");
            writeOut(path);
            writeOut("\n");
            return;
        }

        const count = importTomlContent(allocator, result.stdout, "imported", snip_store) catch {
            writeOut("Failed to parse downloaded content\n");
            return;
        };
        printOut(allocator, "✓ Imported {d} snippet(s) from URL\n", .{count});
        return;
    }

    // Local file
    const file = std.fs.cwd().openFile(path, .{}) catch {
        // Try absolute path
        const abs_file = std.fs.openFileAbsolute(path, .{}) catch {
            writeOut("File not found: ");
            writeOut(path);
            writeOut("\n");
            return;
        };
        defer abs_file.close();
        const content = abs_file.readToEndAlloc(allocator, 1024 * 256) catch {
            writeOut("Failed to read file\n");
            return;
        };
        defer allocator.free(content);

        const count = importTomlContent(allocator, content, "imported", snip_store) catch {
            writeOut("Failed to parse file\n");
            return;
        };
        printOut(allocator, "✓ Imported {d} snippet(s) from {s}\n", .{ count, path });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 256) catch {
        writeOut("Failed to read file\n");
        return;
    };
    defer allocator.free(content);

    // Derive namespace from filename
    const basename = std.fs.path.basename(path);
    const namespace = if (std.mem.endsWith(u8, basename, ".toml"))
        basename[0 .. basename.len - 5]
    else
        basename;

    const count = importTomlContent(allocator, content, namespace, snip_store) catch {
        writeOut("Failed to parse file\n");
        return;
    };
    printOut(allocator, "✓ Imported {d} snippet(s) from {s}\n", .{ count, path });
}

fn importTomlContent(allocator: std.mem.Allocator, content: []const u8, namespace: []const u8, snip_store: *store.Store) !usize {
    const toml_mod = @import("toml.zig");

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const table = try toml_mod.parse(arena_alloc, content);

    // Collect snippet names
    var snippet_names = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = snippet_names.keyIterator();
        while (key_iter.next()) |k| allocator.free(k.*);
        snippet_names.deinit();
    }

    for (table.keys) |key| {
        if (std.mem.startsWith(u8, key, "snippets.")) {
            const rest = key["snippets.".len..];
            if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                const name = rest[0..dot];
                if (!snippet_names.contains(name)) {
                    try snippet_names.put(try allocator.dupe(u8, name), {});
                }
            }
        }
    }

    var count: usize = 0;
    var name_iter = snippet_names.keyIterator();
    while (name_iter.next()) |name_ptr| {
        const sname = name_ptr.*;

        const cmd_key = try std.fmt.allocPrint(allocator, "snippets.{s}.cmd", .{sname});
        defer allocator.free(cmd_key);
        const desc_key = try std.fmt.allocPrint(allocator, "snippets.{s}.desc", .{sname});
        defer allocator.free(desc_key);
        const tags_key = try std.fmt.allocPrint(allocator, "snippets.{s}.tags", .{sname});
        defer allocator.free(tags_key);

        const cmd_val = table.getString(cmd_key) orelse continue;
        const desc_val = table.getString(desc_key) orelse "";

        var tags: std.ArrayList([]const u8) = .{};
        if (table.getArray(tags_key)) |arr| {
            for (arr) |item| {
                switch (item) {
                    .string => |s| try tags.append(allocator, try allocator.dupe(u8, s)),
                    else => {},
                }
            }
        }

        // Check for duplicate name
        var duplicate = false;
        for (snip_store.snippets.items) |existing| {
            if (std.mem.eql(u8, existing.name, sname)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) {
            printOut(allocator, "  ⚠ Skipping '{s}' (already exists)\n", .{sname});
            for (tags.items) |t| allocator.free(t);
            tags.deinit(allocator);
            continue;
        }

        const detected = try template.detectParams(allocator, cmd_val);
        defer allocator.free(detected);
        const params = try allocator.alloc(template.Param, detected.len);
        for (detected, 0..) |pname, i| {
            params[i] = .{ .name = pname, .prompt = null, .default = null, .options = null, .command = null };

            const param_prefix = try std.fmt.allocPrint(allocator, "snippets.{s}.params.{s}", .{ sname, pname });
            defer allocator.free(param_prefix);

            for (table.keys, table.values) |tk, tv| {
                if (std.mem.eql(u8, tk, param_prefix)) {
                    switch (tv) {
                        .table => |pt| {
                            if (pt.getString("prompt")) |pr| params[i].prompt = try allocator.dupe(u8, pr);
                            if (pt.getString("default")) |d| params[i].default = try allocator.dupe(u8, d);
                            if (pt.getString("command")) |c| params[i].command = try allocator.dupe(u8, c);
                        },
                        else => {},
                    }
                }
            }
        }

        const snippet = store.Snippet{
            .name = try allocator.dupe(u8, sname),
            .desc = try allocator.dupe(u8, desc_val),
            .cmd = try allocator.dupe(u8, cmd_val),
            .tags = try tags.toOwnedSlice(allocator),
            .params = params,
            .namespace = try allocator.dupe(u8, namespace),
            .kind = .snippet,
        };

        try snip_store.add(snippet);
        printOut(allocator, "  + {s}\n", .{sname});
        count += 1;
    }

    return count;
}

fn cmdWorkflow(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    if (args.len == 0) {
        writeOut("Usage: zipet workflow <subcommand>\n\n");
        writeOut("Subcommands:\n");
        writeOut("  add              Create a new workflow interactively\n");
        writeOut("  run <name>       Run a workflow by name\n");
        writeOut("  ls               List all workflows\n");
        writeOut("  show <name>      Show workflow details\n");
        writeOut("  rm <name>        Delete a workflow\n");
        writeOut("  edit <name>      Edit workflow in $EDITOR\n");
        return;
    }

    const sub = args[0];
    if (std.mem.eql(u8, sub, "add")) {
        try cmdWorkflowAdd(allocator, snip_store, cfg);
    } else if (std.mem.eql(u8, sub, "run")) {
        if (args.len < 2) {
            writeOut("Usage: zipet workflow run <name>\n");
            return;
        }
        try cmdWorkflowRun(allocator, args[1], snip_store, cfg);
    } else if (std.mem.eql(u8, sub, "ls")) {
        cmdWorkflowList(allocator, snip_store);
    } else if (std.mem.eql(u8, sub, "show")) {
        if (args.len < 2) {
            writeOut("Usage: zipet workflow show <name>\n");
            return;
        }
        cmdWorkflowShow(allocator, args[1], snip_store);
    } else if (std.mem.eql(u8, sub, "rm")) {
        if (args.len < 2) {
            writeOut("Usage: zipet workflow rm <name>\n");
            return;
        }
        try cmdWorkflowRemove(args[1], snip_store);
    } else if (std.mem.eql(u8, sub, "edit")) {
        if (args.len < 2) {
            writeOut("Usage: zipet workflow edit <name>\n");
            return;
        }
        try cmdWorkflowEdit(allocator, args[1], snip_store, cfg);
    } else {
        printOut(allocator, "Unknown workflow subcommand: {s}\n", .{sub});
    }
}

fn cmdWorkflowAdd(allocator: std.mem.Allocator, snip_store: *store.Store, cfg: config.Config) !void {
    writeOut("\x1b[1;36m━━━ Create Workflow ━━━\x1b[0m\n\n");

    writeOut("Workflow name: ");
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

    // List available snippets for reference
    writeOut("\n\x1b[2mAvailable snippets:\x1b[0m\n");
    for (snip_store.snippets.items) |snip| {
        if (snip.kind == .snippet) {
            printOut(allocator, "  • {s} — {s}\n", .{ snip.name, snip.desc });
        }
    }
    writeOut("\n");

    // Collect steps
    var steps: std.ArrayList(workflow.Step) = .{};
    var step_num: usize = 1;

    while (true) {
        printOut(allocator, "\x1b[1mStep {d}\x1b[0m (empty name to finish):\n", .{step_num});

        writeOut("  Step name: ");
        var sname_buf: [256]u8 = undefined;
        const sname = readLine(&sname_buf) orelse break;
        if (sname.len == 0) break;

        writeOut("  Type (cmd/snippet) [cmd]: ");
        var type_buf: [64]u8 = undefined;
        const step_type = readLine(&type_buf) orelse break;

        var step_cmd: ?[]const u8 = null;
        var step_snippet: ?[]const u8 = null;

        if (std.mem.eql(u8, step_type, "snippet") or std.mem.eql(u8, step_type, "s")) {
            writeOut("  Snippet name: ");
            var ref_buf: [256]u8 = undefined;
            const ref = readLine(&ref_buf) orelse break;
            if (ref.len == 0) {
                writeOut("  Snippet name required, skipping step\n");
                continue;
            }
            step_snippet = try allocator.dupe(u8, ref);
        } else {
            writeOut("  Command: ");
            var cmd_buf: [2048]u8 = undefined;
            const cmd = readLine(&cmd_buf) orelse break;
            if (cmd.len == 0) {
                writeOut("  Command required, skipping step\n");
                continue;
            }
            step_cmd = try allocator.dupe(u8, cmd);
        }

        writeOut("  On failure (stop/continue/skip_rest) [stop]: ");
        var fail_buf: [64]u8 = undefined;
        const fail_input = readLine(&fail_buf) orelse break;
        const on_fail = if (fail_input.len > 0) workflow.OnFail.fromString(fail_input) else .stop;

        try steps.append(allocator, .{
            .name = try allocator.dupe(u8, sname),
            .cmd = step_cmd,
            .snippet_ref = step_snippet,
            .on_fail = on_fail,
            .param_overrides = &.{},
        });

        step_num += 1;
        writeOut("\n");
    }

    if (steps.items.len == 0) {
        writeOut("No steps added, aborting\n");
        return;
    }

    // Detect params from all steps
    var params_list: std.ArrayList(template.Param) = .{};
    for (steps.items) |step| {
        if (step.cmd) |cmd| {
            const detected = try template.detectParams(allocator, cmd);
            defer allocator.free(detected);
            for (detected) |pname| {
                if (std.mem.eql(u8, pname, "prev_stdout") or std.mem.eql(u8, pname, "prev_exit")) {
                    allocator.free(pname);
                    continue;
                }
                var found = false;
                for (params_list.items) |existing| {
                    if (std.mem.eql(u8, existing.name, pname)) {
                        found = true;
                        allocator.free(pname);
                        break;
                    }
                }
                if (!found) {
                    try params_list.append(allocator, .{
                        .name = pname,
                        .prompt = null,
                        .default = null,
                        .options = null,
                        .command = null,
                    });
                }
            }
        }
    }

    // Ask for param defaults
    if (params_list.items.len > 0) {
        printOut(allocator, "\nDetected {d} parameter(s):\n", .{params_list.items.len});
        for (params_list.items, 0..) |*p, i| {
            _ = i;
            printOut(allocator, "  Default for '{s}' (empty to skip): ", .{p.name});
            var def_buf: [512]u8 = undefined;
            const def_input = readLine(&def_buf) orelse "";
            if (def_input.len > 0) {
                p.default = try allocator.dupe(u8, def_input);
            }
        }
    }

    const owned_steps = try steps.toOwnedSlice(allocator);
    const owned_params = try params_list.toOwnedSlice(allocator);

    // Build display command (step flow summary)
    var cmd_buf: std.ArrayList(u8) = .{};
    const cmd_writer = cmd_buf.writer(allocator);
    for (owned_steps, 0..) |step, si| {
        if (si > 0) try cmd_writer.writeAll(" → ");
        if (step.snippet_ref) |ref| {
            try cmd_writer.print("[{s}]", .{ref});
        } else if (step.cmd) |cmd| {
            const display = if (cmd.len > 40) cmd[0..40] else cmd;
            try cmd_writer.writeAll(display);
            if (cmd.len > 40) try cmd_writer.writeAll("...");
        }
    }

    const wf = workflow.Workflow{
        .name = try allocator.dupe(u8, name),
        .desc = try allocator.dupe(u8, desc),
        .tags = try tags.toOwnedSlice(allocator),
        .steps = owned_steps,
        .params = owned_params,
        .namespace = try allocator.dupe(u8, namespace),
    };

    // Save to file
    try workflow.saveWorkflow(allocator, &wf, cfg);

    // Register in memory
    try workflow.registerWorkflow(allocator, wf);

    // Add to store as a snippet entry
    try snip_store.snippets.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .desc = try allocator.dupe(u8, desc),
        .cmd = try cmd_buf.toOwnedSlice(allocator),
        .tags = wf.tags,
        .params = wf.params,
        .namespace = try allocator.dupe(u8, namespace),
        .kind = .workflow,
    });

    printOut(allocator, "\n\x1b[32m✓ Workflow '{s}' saved with {d} steps\x1b[0m\n", .{ name, owned_steps.len });
}

fn cmdWorkflowRun(allocator: std.mem.Allocator, name: []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    if (workflow.getWorkflow(allocator, name)) |wf| {
        const result = try workflow.execute(allocator, wf, snip_store, cfg);
        defer result.deinit();
    } else {
        printOut(allocator, "Workflow '{s}' not found\n", .{name});
    }
}

fn cmdWorkflowList(allocator: std.mem.Allocator, snip_store: *store.Store) void {
    var count: usize = 0;
    for (snip_store.snippets.items) |snip| {
        if (snip.kind == .workflow) {
            printOut(allocator, "  \x1b[1;36m⚡ {s}\x1b[0m", .{snip.name});

            const name_len = snip.name.len;
            var pad = if (name_len < 24) 24 - name_len else @as(usize, 1);
            while (pad > 0) : (pad -= 1) writeOut(" ");

            printOut(allocator, "{s}\n", .{snip.desc});
            printOut(allocator, "    \x1b[2m{s}\x1b[0m\n", .{snip.cmd});
            count += 1;
        }
    }
    if (count == 0) {
        writeOut("No workflows yet. Create one with: zipet workflow add\n");
    } else {
        printOut(allocator, "\n{d} workflow(s)\n", .{count});
    }
}

fn cmdWorkflowShow(allocator: std.mem.Allocator, name: []const u8, snip_store: *store.Store) void {
    _ = snip_store;
    if (workflow.getWorkflow(allocator, name)) |wf| {
        printOut(allocator, "\x1b[1;36m⚡ {s}\x1b[0m\n", .{wf.name});
        printOut(allocator, "   {s}\n\n", .{wf.desc});
        printOut(allocator, "Steps ({d}):\n", .{wf.steps.len});

        for (wf.steps, 0..) |step, i| {
            printOut(allocator, "  {d}. \x1b[1m{s}\x1b[0m\n", .{ i + 1, step.name });
            if (step.cmd) |cmd| {
                printOut(allocator, "     \x1b[2m$ {s}\x1b[0m\n", .{cmd});
            }
            if (step.snippet_ref) |ref| {
                printOut(allocator, "     \x1b[2m→ snippet: {s}\x1b[0m\n", .{ref});
            }
            const on_fail_str: []const u8 = switch (step.on_fail) {
                .stop => "stop",
                .@"continue" => "continue",
                .skip_rest => "skip_rest",
            };
            printOut(allocator, "     on_fail: {s}\n", .{on_fail_str});
        }

        if (wf.params.len > 0) {
            printOut(allocator, "\nParameters ({d}):\n", .{wf.params.len});
            for (wf.params) |p| {
                printOut(allocator, "  • {s}", .{p.name});
                if (p.default) |d| printOut(allocator, " (default: {s})", .{d});
                writeOut("\n");
            }
        }
    } else {
        printOut(allocator, "Workflow '{s}' not found\n", .{name});
    }
}

fn cmdWorkflowRemove(name: []const u8, snip_store: *store.Store) !void {
    for (snip_store.snippets.items, 0..) |snip, i| {
        if (snip.kind == .workflow and std.mem.eql(u8, snip.name, name)) {
            snip_store.freeSnippet(snip);
            _ = snip_store.snippets.orderedRemove(i);
            writeOut("✓ Removed workflow '");
            writeOut(name);
            writeOut("'\n");
            return;
        }
    }
    writeOut("Workflow '");
    writeOut(name);
    writeOut("' not found\n");
}

fn cmdWorkflowEdit(allocator: std.mem.Allocator, name: []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    for (snip_store.snippets.items) |snip| {
        if (snip.kind == .workflow and std.mem.eql(u8, snip.name, name)) {
            const workflows_dir = try cfg.getWorkflowsDir(allocator);
            defer allocator.free(workflows_dir);

            const path = try std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ workflows_dir, snip.namespace });
            defer allocator.free(path);

            var child = std.process.Child.init(&.{ cfg.editor, path }, allocator);
            _ = try child.spawnAndWait();
            return;
        }
    }
    writeOut("Workflow '");
    writeOut(name);
    writeOut("' not found\n");
}

fn cmdParallel(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    _ = cfg;

    if (args.len == 0) {
        writeOut("Usage: zipet parallel <name1> <name2> ... [-- key=val ...]\n");
        writeOut("  Run multiple snippets/workflows in parallel\n\n");
        writeOut("Examples:\n");
        writeOut("  zipet parallel check-disk check-mem check-net\n");
        writeOut("  zipet par deploy-api deploy-web -- env=prod\n");
        return;
    }

    // Separate snippet/workflow names from param overrides (after --)
    var names: std.ArrayList([]const u8) = .{};
    defer names.deinit(allocator);
    var param_keys_list: std.ArrayList([]const u8) = .{};
    defer param_keys_list.deinit(allocator);
    var param_vals_list: std.ArrayList([]const u8) = .{};
    defer param_vals_list.deinit(allocator);

    var after_separator = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) {
            after_separator = true;
            continue;
        }
        if (after_separator) {
            // Parse key=value
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                try param_keys_list.append(allocator, arg[0..eq]);
                try param_vals_list.append(allocator, arg[eq + 1 ..]);
            }
        } else {
            try names.append(allocator, arg);
        }
    }

    if (names.items.len == 0) {
        writeOut("No snippets/workflows specified\n");
        return;
    }

    // Resolve each name to a snippet or workflow
    var parallel_items: std.ArrayList(executor.ParallelItem) = .{};
    defer parallel_items.deinit(allocator);
    var wf_items: std.ArrayList(workflow.ParallelWorkflowItem) = .{};
    defer wf_items.deinit(allocator);

    var rendered_cmds: std.ArrayList([]const u8) = .{};
    defer {
        for (rendered_cmds.items) |c| allocator.free(c);
        rendered_cmds.deinit(allocator);
    }

    var has_workflows = false;
    var has_snippets = false;

    for (names.items) |name| {
        // Check if it's a workflow first
        if (workflow.getWorkflow(allocator, name)) |wf| {
            has_workflows = true;
            try wf_items.append(allocator, .{
                .workflow = wf,
                .param_keys = param_keys_list.items,
                .param_values = param_vals_list.items,
            });
            continue;
        }

        // Check if it's a snippet
        var found = false;
        for (snip_store.snippets.items) |*snip| {
            if (snip.kind == .snippet and std.mem.eql(u8, snip.name, name)) {
                found = true;
                has_snippets = true;

                // Render the command with provided params
                const rendered = template.render(allocator, snip.cmd, param_keys_list.items, param_vals_list.items) catch |err| {
                    printOut(allocator, "Error rendering '{s}': {}\n", .{ name, err });
                    break;
                };
                try rendered_cmds.append(allocator, rendered);

                try parallel_items.append(allocator, .{
                    .name = snip.name,
                    .cmd = rendered,
                });
                break;
            }
        }

        if (!found and !has_workflows) {
            printOut(allocator, "⚠ '{s}' not found, skipping\n", .{name});
        }
    }

    const total = parallel_items.items.len + wf_items.items.len;
    if (total == 0) {
        writeOut("Nothing to run\n");
        return;
    }

    printOut(allocator, "\n\x1b[1;36m▶ Running {d} item(s) in parallel\x1b[0m\n\n", .{total});

    // Run snippets in parallel
    if (has_snippets and parallel_items.items.len > 0) {
        const results = try executor.runParallel(allocator, parallel_items.items);
        defer executor.freeParallelResults(allocator, results);

        for (results) |r| {
            if (r.err) {
                printOut(allocator, "\x1b[31m✗ {s}\x1b[0m — execution error\n", .{r.name});
            } else if (r.exit_code == 0) {
                printOut(allocator, "\x1b[32m✓ {s}\x1b[0m ({d}ms)\n", .{ r.name, r.duration_ms });
            } else {
                printOut(allocator, "\x1b[31m✗ {s}\x1b[0m exit={d} ({d}ms)\n", .{ r.name, r.exit_code, r.duration_ms });
            }

            if (r.stdout.len > 0) {
                printOut(allocator, "  \x1b[2mstdout:\x1b[0m {s}", .{r.stdout});
                if (r.stdout[r.stdout.len - 1] != '\n') writeOut("\n");
            }
            if (r.stderr.len > 0) {
                printOut(allocator, "  \x1b[31mstderr:\x1b[0m {s}", .{r.stderr});
                if (r.stderr[r.stderr.len - 1] != '\n') writeOut("\n");
            }
        }
    }

    // Run workflows in parallel
    if (has_workflows and wf_items.items.len > 0) {
        const wf_results = try workflow.executeParallel(allocator, wf_items.items, snip_store);
        defer workflow.freeParallelWorkflowResults(allocator, wf_results);

        for (wf_results) |r| {
            if (r.success) {
                printOut(allocator, "\x1b[32m✓ {s}\x1b[0m ({d}ms)\n", .{ r.name, r.duration_ms });
            } else {
                printOut(allocator, "\x1b[31m✗ {s}\x1b[0m exit={d} ({d}ms)\n", .{ r.name, r.exit_code, r.duration_ms });
            }

            if (r.stdout.len > 0) {
                printOut(allocator, "  \x1b[2mstdout:\x1b[0m {s}", .{r.stdout});
                if (r.stdout[r.stdout.len - 1] != '\n') writeOut("\n");
            }
            if (r.stderr.len > 0) {
                printOut(allocator, "  \x1b[31mstderr:\x1b[0m {s}", .{r.stderr});
                if (r.stderr[r.stderr.len - 1] != '\n') writeOut("\n");
            }
        }
    }

    // Summary
    writeOut("\n\x1b[1;36m━━━ Parallel execution complete ━━━\x1b[0m\n");
}

// ── Pack commands ──
fn cmdPack(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    if (args.len == 0) {
        writeOut("Usage: zipet pack <subcommand>\n\n");
        writeOut("Subcommands:\n");
        writeOut("  ls                 List available packs\n");
        writeOut("  install <name>     Install a pack (name, file path, or URL)\n");
        writeOut("  uninstall <name>   Remove an installed pack\n");
        writeOut("  create <name>      Create a pack from your snippets\n");
        writeOut("  info <name>        Show pack details\n");
        writeOut("\nBuilt-in packs:\n");
        writeOut("  pentesting         Nmap, gobuster, sqlmap, hydra, hashcat...\n");
        writeOut("  devops             Docker, Kubernetes, deployment, monitoring\n");
        writeOut("  git-power          Advanced Git workflows and shortcuts\n");
        writeOut("  sysadmin           Linux system administration essentials\n");
        writeOut("  web-dev            HTTP testing, API debugging, JWT, encoding\n");
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "ls") or std.mem.eql(u8, sub, "list")) {
        try cmdPackList(allocator, cfg);
    } else if (std.mem.eql(u8, sub, "install")) {
        if (args.len < 2) { writeOut("Usage: zipet pack install <name|file|url> [--workspace=<ws>]\n"); return; }
        var target_ws: ?[]const u8 = null;
        for (args[2..]) |arg| {
            if (std.mem.startsWith(u8, arg, "--workspace=") or std.mem.startsWith(u8, arg, "--ws=")) {
                target_ws = arg[std.mem.indexOf(u8, arg, "=").? + 1 ..];
            }
        }
        try cmdPackInstall(allocator, args[1], target_ws, snip_store, cfg);
    } else if (std.mem.eql(u8, sub, "uninstall") or std.mem.eql(u8, sub, "rm")) {
        if (args.len < 2) { writeOut("Usage: zipet pack uninstall <name>\n"); return; }
        try cmdPackUninstall(allocator, args[1], snip_store, cfg);
    } else if (std.mem.eql(u8, sub, "create")) {
        if (args.len < 2) { writeOut("Usage: zipet pack create <name> [--namespace=<ns>]\n"); return; }
        try cmdPackCreate(allocator, args[1..], snip_store);
    } else if (std.mem.eql(u8, sub, "info")) {
        if (args.len < 2) { writeOut("Usage: zipet pack info <name>\n"); return; }
        try cmdPackInfo(allocator, args[1], cfg);
    } else {
        printOut(allocator, "Unknown pack subcommand: {s}\n", .{sub});
    }
}

fn cmdPackList(allocator: std.mem.Allocator, cfg: config.Config) !void {
    const packs = try pack.listAvailable(allocator, cfg);
    defer pack.freePackMetas(allocator, packs);

    if (packs.len == 0) {
        writeOut("No packs in registry.\n");
        writeOut("Install built-in packs with: zipet pack install <name>\n");
        writeOut("Available: pentesting, devops, git-power, sysadmin, web-dev\n");
        return;
    }

    writeOut("\n\x1b[1;36m📦 Available Packs\x1b[0m\n\n");
    for (packs) |p| {
        const status = if (p.installed) "\x1b[32m✓\x1b[0m" else " ";
        printOut(allocator, "  {s} \x1b[1m{s}\x1b[0m", .{ status, p.name });
        const pad = if (p.name.len < 20) 20 - p.name.len else @as(usize, 1);
        var i: usize = 0;
        while (i < pad) : (i += 1) writeOut(" ");
        printOut(allocator, "{s}\n", .{p.description});
        printOut(allocator, "    \x1b[2m{s} • {s} • {d} snippets", .{ p.category, p.author, p.snippet_count });
        if (p.workflow_count > 0) printOut(allocator, " • {d} workflows", .{p.workflow_count});
        writeOut("\x1b[0m\n");
    }
    writeOut("\n");
}

fn cmdPackInstall(allocator: std.mem.Allocator, source: []const u8, target_ws: ?[]const u8, snip_store: *store.Store, cfg: config.Config) !void {
    printOut(allocator, "Installing pack '{s}'...\n", .{source});

    const result = try pack.install(allocator, cfg, source, target_ws, snip_store);
    defer pack.freeInstallResult(allocator, result);

    if (result.err_msg) |err| {
        printOut(allocator, "\x1b[31m✗ {s}\x1b[0m\n", .{err});
        return;
    }

    printOut(allocator, "\x1b[32m✓ Pack '{s}' installed\x1b[0m\n", .{result.pack_name});
    printOut(allocator, "  {d} snippet(s) added\n", .{result.snippets_added});
    if (result.workflows_added > 0)
        printOut(allocator, "  {d} workflow(s) added\n", .{result.workflows_added});
    if (target_ws) |ws|
        printOut(allocator, "  Target workspace: {s}\n", .{ws});
}

fn cmdPackUninstall(allocator: std.mem.Allocator, name: []const u8, snip_store: *store.Store, cfg: config.Config) !void {
    const removed = try pack.uninstall(allocator, cfg, name, snip_store);
    if (removed > 0) {
        printOut(allocator, "\x1b[32m✓ Removed pack '{s}' ({d} items)\x1b[0m\n", .{ name, removed });
    } else {
        printOut(allocator, "Pack '{s}' not found or already uninstalled\n", .{name});
    }
}

fn cmdPackCreate(allocator: std.mem.Allocator, args: []const []const u8, snip_store: *store.Store) !void {
    const name = args[0];
    var ns_filter: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--namespace=") or std.mem.startsWith(u8, arg, "--ns=")) {
            ns_filter = arg[std.mem.indexOf(u8, arg, "=").? + 1 ..];
        }
    }

    writeOut("Description: ");
    var desc_buf: [512]u8 = undefined;
    const desc = readLine(&desc_buf) orelse return;

    writeOut("Author: ");
    var author_buf: [256]u8 = undefined;
    const author = readLine(&author_buf) orelse return;

    writeOut("Category [general]: ");
    var cat_buf: [256]u8 = undefined;
    const cat_input = readLine(&cat_buf) orelse return;
    const category = if (cat_input.len > 0) cat_input else "general";

    const output_file = try std.fmt.allocPrint(allocator, "{s}.toml", .{name});
    defer allocator.free(output_file);

    const count = try pack.createPack(allocator, name, desc, author, category, snip_store, ns_filter, output_file);
    printOut(allocator, "\x1b[32m✓ Pack '{s}' created with {d} snippets → {s}\x1b[0m\n", .{ name, count, output_file });
    writeOut("Share this file or publish it for others!\n");
}

fn cmdPackInfo(allocator: std.mem.Allocator, name: []const u8, cfg: config.Config) !void {
    // Try to find pack in registry
    const packs = try pack.listAvailable(allocator, cfg);
    defer pack.freePackMetas(allocator, packs);

    for (packs) |p| {
        if (std.mem.eql(u8, p.name, name)) {
            printOut(allocator, "\n\x1b[1;36m📦 {s}\x1b[0m", .{p.name});
            if (p.installed) writeOut(" \x1b[32m(installed)\x1b[0m");
            writeOut("\n\n");
            printOut(allocator, "  Description:  {s}\n", .{p.description});
            printOut(allocator, "  Author:       {s}\n", .{p.author});
            printOut(allocator, "  Version:      {s}\n", .{p.version});
            printOut(allocator, "  Category:     {s}\n", .{p.category});
            printOut(allocator, "  Snippets:     {d}\n", .{p.snippet_count});
            printOut(allocator, "  Workflows:    {d}\n", .{p.workflow_count});
            if (p.tags.len > 0) {
                writeOut("  Tags:         ");
                for (p.tags, 0..) |tag, i| {
                    if (i > 0) writeOut(", ");
                    writeOut(tag);
                }
                writeOut("\n");
            }
            writeOut("\n");
            return;
        }
    }
    printOut(allocator, "Pack '{s}' not found in registry\n", .{name});
}

// ── Workspace commands ──
fn cmdWorkspace(allocator: std.mem.Allocator, args: []const []const u8, cfg: config.Config) !void {
    if (args.len == 0) {
        writeOut("Usage: zipet workspace <subcommand>\n\n");
        writeOut("Subcommands:\n");
        writeOut("  ls               List all workspaces\n");
        writeOut("  create <name>    Create a new workspace (links to current dir by default)\n");
        writeOut("  create <name> --path=<dir>  Create linked to specific directory\n");
        writeOut("  create <name> --no-path     Create without directory link\n");
        writeOut("  use <name>       Switch to a workspace\n");
        writeOut("  use --global     Switch back to global (default)\n");
        writeOut("  rm <name>        Delete a workspace\n");
        writeOut("  current          Show active workspace\n");
        writeOut("\nDirectory auto-detection:\n");
        writeOut("  When a workspace is linked to a directory, zipet auto-activates\n");
        writeOut("  it when you run commands from that directory (or subdirectories).\n");
        writeOut("  Workspace snippets are merged with global snippets.\n");
        writeOut("\nAliases: zipet ws\n");
        return;
    }

    const sub = args[0];

    if (std.mem.eql(u8, sub, "ls") or std.mem.eql(u8, sub, "list")) {
        try cmdWorkspaceList(allocator, cfg);
    } else if (std.mem.eql(u8, sub, "create") or std.mem.eql(u8, sub, "new")) {
        if (args.len < 2) { writeOut("Usage: zipet workspace create <name> [--path=<dir>]\n"); return; }
        try cmdWorkspaceCreate(allocator, args[1..], cfg);
    } else if (std.mem.eql(u8, sub, "use") or std.mem.eql(u8, sub, "switch")) {
        if (args.len < 2) { writeOut("Usage: zipet workspace use <name|--global>\n"); return; }
        try cmdWorkspaceUse(allocator, args[1], cfg);
    } else if (std.mem.eql(u8, sub, "rm") or std.mem.eql(u8, sub, "delete")) {
        if (args.len < 2) { writeOut("Usage: zipet workspace rm <name>\n"); return; }
        try cmdWorkspaceRemove(allocator, args[1], cfg);
    } else if (std.mem.eql(u8, sub, "current") or std.mem.eql(u8, sub, "active")) {
        try cmdWorkspaceCurrent(allocator, cfg);
    } else {
        printOut(allocator, "Unknown workspace subcommand: {s}\n", .{sub});
    }
}

fn cmdWorkspaceList(allocator: std.mem.Allocator, cfg: config.Config) !void {
    const workspaces = try workspace_mod.list(allocator, cfg);
    defer workspace_mod.freeWorkspaces(allocator, workspaces);

    const active = try workspace_mod.getActiveWorkspace(allocator, cfg);
    defer if (active) |a| allocator.free(a);

    writeOut("\n\x1b[1;36m📂 Workspaces\x1b[0m\n\n");

    // Always show "global" as an option
    const global_active = active == null;
    if (global_active) {
        writeOut("  \x1b[32m▸ global\x1b[0m (default)\n");
    } else {
        writeOut("    global (default)\n");
    }

    if (workspaces.len == 0) {
        writeOut("\n  No custom workspaces yet.\n");
        writeOut("  Create one with: zipet workspace create <name>\n");
    } else {
        for (workspaces) |ws| {
            const is_active = if (active) |a| std.mem.eql(u8, a, ws.name) else false;
            if (is_active) {
                printOut(allocator, "  \x1b[32m▸ {s}\x1b[0m", .{ws.name});
            } else {
                printOut(allocator, "    {s}", .{ws.name});
            }

            const pad = if (ws.name.len < 18) 18 - ws.name.len else @as(usize, 1);
            var i: usize = 0;
            while (i < pad) : (i += 1) writeOut(" ");

            if (ws.description.len > 0)
                printOut(allocator, "{s}", .{ws.description});

            printOut(allocator, "  \x1b[2m({d} snip", .{ws.snippet_count});
            if (ws.workflow_count > 0) printOut(allocator, ", {d} wf", .{ws.workflow_count});
            writeOut(")\x1b[0m");

            if (ws.path.len > 0)
                printOut(allocator, "  \x1b[2m→ {s}\x1b[0m", .{ws.path});

            writeOut("\n");
        }
    }
    writeOut("\n");
}

fn cmdWorkspaceCreate(allocator: std.mem.Allocator, args: []const []const u8, cfg: config.Config) !void {
    const name = args[0];
    var project_path: ?[]const u8 = null;
    var no_path = false;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--path=")) {
            project_path = arg["--path=".len..];
        } else if (std.mem.eql(u8, arg, "--no-path")) {
            no_path = true;
        }
    }

    // Default: use current directory as project path (unless --no-path)
    var cwd_buf: ?[]const u8 = null;
    defer if (cwd_buf) |c| allocator.free(c);

    if (project_path == null and !no_path) {
        cwd_buf = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
        if (cwd_buf) |c| {
            printOut(allocator, "Link to current directory? ({s})\n", .{c});
            writeOut("(Y/n): ");
            var yn_buf: [64]u8 = undefined;
            const yn = readLine(&yn_buf) orelse return;
            if (yn.len == 0 or yn[0] == 'y' or yn[0] == 'Y') {
                project_path = c;
            }
        }
    }

    writeOut("Description: ");
    var desc_buf: [512]u8 = undefined;
    const desc = readLine(&desc_buf) orelse return;

    workspace_mod.create(allocator, cfg, name, desc, project_path) catch |err| {
        if (err == error.AlreadyExists) {
            printOut(allocator, "Workspace '{s}' already exists\n", .{name});
            return;
        }
        return err;
    };

    printOut(allocator, "\x1b[32m✓ Workspace '{s}' created\x1b[0m\n", .{name});
    if (project_path) |pp| {
        printOut(allocator, "  Linked to: {s}\n", .{pp});
        printOut(allocator, "  Auto-activates when you run zipet from this directory\n", .{});
    }
    printOut(allocator, "  Switch to it: zipet workspace use {s}\n", .{name});
    printOut(allocator, "  Install packs: zipet pack install pentesting --workspace={s}\n", .{name});
}

fn cmdWorkspaceUse(allocator: std.mem.Allocator, name: []const u8, cfg: config.Config) !void {
    if (std.mem.eql(u8, name, "--global") or std.mem.eql(u8, name, "global")) {
        try workspace_mod.setActiveWorkspace(allocator, cfg, null);
        writeOut("\x1b[32m✓ Switched to global workspace\x1b[0m\n");
        return;
    }

    // Verify workspace exists
    const ws_dir = try workspace_mod.getWorkspaceDir(allocator, cfg, name);
    defer allocator.free(ws_dir);

    std.fs.accessAbsolute(ws_dir, .{}) catch {
        printOut(allocator, "Workspace '{s}' not found. Create it first: zipet workspace create {s}\n", .{ name, name });
        return;
    };

    try workspace_mod.setActiveWorkspace(allocator, cfg, name);
    printOut(allocator, "\x1b[32m✓ Switched to workspace '{s}'\x1b[0m\n", .{name});
}

fn cmdWorkspaceRemove(allocator: std.mem.Allocator, name: []const u8, cfg: config.Config) !void {
    if (std.mem.eql(u8, name, "global")) {
        writeOut("Cannot delete the global workspace\n");
        return;
    }

    writeOut("Delete workspace '");
    writeOut(name);
    writeOut("' and all its snippets? (y/N): ");
    var buf: [64]u8 = undefined;
    const input = readLine(&buf) orelse return;
    if (input.len == 0 or (input[0] != 'y' and input[0] != 'Y')) {
        writeOut("Cancelled\n");
        return;
    }

    workspace_mod.remove(allocator, cfg, name) catch |err| {
        if (err == error.NotFound) {
            printOut(allocator, "Workspace '{s}' not found\n", .{name});
            return;
        }
        return err;
    };

    printOut(allocator, "\x1b[32m✓ Workspace '{s}' deleted\x1b[0m\n", .{name});
}

fn cmdWorkspaceCurrent(allocator: std.mem.Allocator, cfg: config.Config) !void {
    // Check if auto-detected by directory
    const auto_detected = workspace_mod.detectWorkspaceByDir(allocator, cfg) catch null;
    defer if (auto_detected) |ad| allocator.free(ad);

    const active = try workspace_mod.getActiveWorkspace(allocator, cfg);
    if (active) |a| {
        defer allocator.free(a);
        printOut(allocator, "Active workspace: \x1b[1;36m{s}\x1b[0m", .{a});
        if (auto_detected != null and std.mem.eql(u8, auto_detected.?, a)) {
            writeOut(" \x1b[2m(auto-detected from directory)\x1b[0m");
        }
        writeOut("\n");

        // Show linked path if available
        const workspaces = try workspace_mod.list(allocator, cfg);
        defer workspace_mod.freeWorkspaces(allocator, workspaces);
        for (workspaces) |ws| {
            if (std.mem.eql(u8, ws.name, a) and ws.path.len > 0) {
                printOut(allocator, "  Linked to: {s}\n", .{ws.path});
                break;
            }
        }
    } else {
        writeOut("Active workspace: \x1b[1;36mglobal\x1b[0m (default)\n");
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
        \\  workflow add   Create a workflow (chain of snippets/commands)
        \\  workflow run   Run a workflow
        \\  workflow ls    List workflows
        \\  workflow show  Show workflow details
        \\  wf             Alias for workflow
        \\  parallel       Run multiple snippets/workflows in parallel
        \\  par            Alias for parallel
        \\  pack ls        List available packs
        \\  pack install   Install a pack (name, file, or URL)
        \\  pack uninstall Remove an installed pack
        \\  pack create    Create a pack from your snippets
        \\  workspace ls   List workspaces
        \\  workspace create  Create a workspace
        \\  workspace use  Switch workspace
        \\  ws             Alias for workspace
        \\  init           Initialize config directory
        \\  shell <sh>     Output shell integration (bash/zsh/fish)
        \\  export [--json] Export all snippets (TOML default, or JSON)
        \\  import <file>  Import snippets from .toml file or URL
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
