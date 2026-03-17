/// CLI command dispatcher for zipet.
const std = @import("std");
const store = @import("store.zig");
const config = @import("config.zig");
const executor = @import("executor.zig");
const template = @import("template.zig");
const workflow = @import("workflow.zig");

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
    } else if (std.mem.eql(u8, cmd, "workflow") or std.mem.eql(u8, cmd, "wf")) {
        try cmdWorkflow(allocator, args[1..], snip_store, cfg);
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
