/// Workflow engine for zipet — chains multiple snippets/commands into sequential pipelines.
/// Supports: step ordering, snippet references, inline commands, on_fail policies,
/// inter-step data passing via {{prev_stdout}}, {{prev_exit}}, and workflow-level params.
const std = @import("std");
const template = @import("template.zig");
const store = @import("store.zig");
const executor = @import("executor.zig");
const config = @import("config.zig");
const toml = @import("toml.zig");

pub const OnFail = enum {
    stop,
    @"continue",
    skip_rest,

    pub fn fromString(s: []const u8) OnFail {
        if (std.mem.eql(u8, s, "continue")) return .@"continue";
        if (std.mem.eql(u8, s, "skip_rest")) return .skip_rest;
        return .stop;
    }
};

pub const Step = struct {
    name: []const u8,
    /// Inline command (mutually exclusive with snippet_ref)
    cmd: ?[]const u8,
    /// Reference to an existing snippet by name
    snippet_ref: ?[]const u8,
    on_fail: OnFail,
    /// Fixed param overrides for this step (key=value pairs)
    param_overrides: []const ParamOverride,

    pub const ParamOverride = struct {
        key: []const u8,
        value: []const u8,
    };
};

pub const Workflow = struct {
    name: []const u8,
    desc: []const u8,
    tags: []const []const u8,
    steps: []const Step,
    params: []const template.Param,
    namespace: []const u8,
};

pub const StepResult = struct {
    step_name: []const u8,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    skipped: bool,
};

pub const WorkflowResult = struct {
    step_results: []StepResult,
    success: bool,
    allocator: std.mem.Allocator,

    pub fn deinit(self: WorkflowResult) void {
        for (self.step_results) |r| {
            self.allocator.free(r.stdout);
            self.allocator.free(r.stderr);
        }
        self.allocator.free(self.step_results);
    }
};

fn writeOut(data: []const u8) void {
    std.fs.File.stdout().writeAll(data) catch {};
}

fn printOut(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
    const s = std.fmt.allocPrint(alloc, fmt, args) catch return;
    defer alloc.free(s);
    writeOut(s);
}

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

/// Execute a workflow silently (no stdout/prompts) with pre-supplied param values.
/// Returns the WorkflowResult. Output is collected in step_results.
pub fn executeSilent(
    allocator: std.mem.Allocator,
    wf: *const Workflow,
    snip_store: *store.Store,
    param_keys: []const []const u8,
    param_values_in: []const []const u8,
) !WorkflowResult {
    var step_results: std.ArrayList(StepResult) = .{};
    var prev_stdout: []const u8 = "";
    var prev_exit: u8 = 0;
    var all_success = true;
    var prev_stdout_owned = false;

    defer {
        if (prev_stdout_owned) allocator.free(prev_stdout);
    }

    for (wf.steps) |step| {
        const raw_cmd = blk: {
            if (step.cmd) |cmd| {
                break :blk cmd;
            } else if (step.snippet_ref) |ref| {
                const snip = findSnippet(snip_store, ref);
                if (snip) |s| {
                    break :blk s.cmd;
                } else {
                    try step_results.append(allocator, .{
                        .step_name = step.name,
                        .exit_code = 1,
                        .stdout = try allocator.dupe(u8, ""),
                        .stderr = try allocator.dupe(u8, "snippet not found"),
                        .skipped = true,
                    });
                    all_success = false;
                    switch (step.on_fail) {
                        .stop, .skip_rest => break,
                        .@"continue" => continue,
                    }
                }
            } else {
                try step_results.append(allocator, .{
                    .step_name = step.name,
                    .exit_code = 1,
                    .stdout = try allocator.dupe(u8, ""),
                    .stderr = try allocator.dupe(u8, "no command"),
                    .skipped = true,
                });
                continue;
            }
        };

        const extra_count: usize = 2;
        const override_count = step.param_overrides.len;
        const total_k = param_keys.len + extra_count + override_count;

        var all_keys = try allocator.alloc([]const u8, total_k);
        defer allocator.free(all_keys);
        var all_vals = try allocator.alloc([]const u8, total_k);
        defer {
            allocator.free(all_vals[param_keys.len]);
            allocator.free(all_vals[param_keys.len + 1]);
            for (param_keys.len + extra_count..total_k) |oi| allocator.free(all_vals[oi]);
            allocator.free(all_vals);
        }

        for (0..param_keys.len) |pi| {
            all_keys[pi] = param_keys[pi];
            all_vals[pi] = param_values_in[pi];
        }

        all_keys[param_keys.len] = "prev_stdout";
        all_vals[param_keys.len] = try allocator.dupe(u8, prev_stdout);
        all_keys[param_keys.len + 1] = "prev_exit";
        all_vals[param_keys.len + 1] = try std.fmt.allocPrint(allocator, "{d}", .{prev_exit});

        for (step.param_overrides, 0..) |ov, oi| {
            all_keys[param_keys.len + extra_count + oi] = ov.key;
            all_vals[param_keys.len + extra_count + oi] = try allocator.dupe(u8, ov.value);
        }

        const rendered = try template.render(allocator, raw_cmd, all_keys, all_vals);
        defer allocator.free(rendered);

        const result = try executor.run(allocator, rendered);

        const step_success = result.exit_code == 0;
        if (!step_success) all_success = false;

        if (prev_stdout_owned) allocator.free(prev_stdout);
        prev_stdout = try allocator.dupe(u8, std.mem.trim(u8, result.stdout, "\n\r"));
        prev_stdout_owned = true;
        prev_exit = result.exit_code;

        try step_results.append(allocator, .{
            .step_name = step.name,
            .exit_code = result.exit_code,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .skipped = false,
        });

        if (!step_success) {
            switch (step.on_fail) {
                .stop, .skip_rest => break,
                .@"continue" => {},
            }
        }
    }

    return WorkflowResult{
        .step_results = try step_results.toOwnedSlice(allocator),
        .success = all_success,
        .allocator = allocator,
    };
}

/// Execute a complete workflow, prompting for params and running each step in order.
pub fn execute(
    allocator: std.mem.Allocator,
    workflow: *const Workflow,
    snip_store: *store.Store,
    cfg: config.Config,
) !WorkflowResult {
    _ = cfg;

    // ── Prompt for workflow-level params ──
    var param_keys = try allocator.alloc([]const u8, workflow.params.len);
    defer allocator.free(param_keys);
    var param_values = try allocator.alloc([]const u8, workflow.params.len);
    defer {
        for (param_values[0..workflow.params.len]) |v| allocator.free(v);
        allocator.free(param_values);
    }

    if (workflow.params.len > 0) {
        printOut(allocator, "\n\x1b[1;36m━━━ Workflow: {s} ━━━\x1b[0m\n", .{workflow.name});
        printOut(allocator, "\x1b[2m{s}\x1b[0m\n\n", .{workflow.desc});
    }

    for (workflow.params, 0..) |p, i| {
        param_keys[i] = p.name;

        // Dynamic parameter — run command to get options
        if (p.command) |cmd| {
            const result = std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "/bin/sh", "-c", cmd },
            }) catch {
                param_values[i] = try allocator.dupe(u8, p.default orelse "");
                continue;
            };
            defer allocator.free(result.stderr);

            printOut(allocator, "\n{s}:\n", .{p.prompt orelse p.name});
            var lines = std.mem.splitScalar(u8, result.stdout, '\n');
            var options: std.ArrayList([]const u8) = .{};
            defer options.deinit(allocator);

            var line_num: usize = 1;
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                printOut(allocator, "  {d}) {s}\n", .{ line_num, line });
                try options.append(allocator, line);
                line_num += 1;
            }

            printOut(allocator, "Choose (1-{d}): ", .{line_num - 1});
            var buf: [256]u8 = undefined;
            const input = readLine(&buf);

            if (input) |inp| {
                const choice = std.fmt.parseInt(usize, inp, 10) catch {
                    param_values[i] = try allocator.dupe(u8, p.default orelse "");
                    allocator.free(result.stdout);
                    continue;
                };

                if (choice > 0 and choice <= options.items.len) {
                    param_values[i] = try allocator.dupe(u8, options.items[choice - 1]);
                } else {
                    param_values[i] = try allocator.dupe(u8, p.default orelse "");
                }
            } else {
                param_values[i] = try allocator.dupe(u8, p.default orelse "");
            }
            allocator.free(result.stdout);
            continue;
        }

        // Simple text prompt
        const prompt_text = p.prompt orelse p.name;
        if (p.default) |d| {
            printOut(allocator, "{s} [{s}]: ", .{ prompt_text, d });
        } else {
            printOut(allocator, "{s}: ", .{prompt_text});
        }

        var buf: [1024]u8 = undefined;
        const input = readLine(&buf);

        if (input) |inp| {
            if (inp.len == 0 and p.default != null) {
                param_values[i] = try allocator.dupe(u8, p.default.?);
            } else {
                param_values[i] = try allocator.dupe(u8, inp);
            }
        } else {
            param_values[i] = try allocator.dupe(u8, p.default orelse "");
        }
    }

    // ── Execute steps ──
    var step_results: std.ArrayList(StepResult) = .{};
    var prev_stdout: []const u8 = "";
    var prev_exit: u8 = 0;
    var all_success = true;
    var prev_stdout_owned = false;

    defer {
        if (prev_stdout_owned) allocator.free(prev_stdout);
    }

    printOut(allocator, "\n\x1b[1;36m▶ Running workflow: {s} ({d} steps)\x1b[0m\n\n", .{ workflow.name, workflow.steps.len });

    for (workflow.steps, 0..) |step, step_idx| {
        printOut(allocator, "\x1b[1m[{d}/{d}] {s}\x1b[0m\n", .{ step_idx + 1, workflow.steps.len, step.name });

        // Resolve the command for this step
        const raw_cmd = blk: {
            if (step.cmd) |cmd| {
                break :blk cmd;
            } else if (step.snippet_ref) |ref| {
                // Look up snippet in the store
                const snip = findSnippet(snip_store, ref);
                if (snip) |s| {
                    break :blk s.cmd;
                } else {
                    printOut(allocator, "  \x1b[31m✗ Snippet '{s}' not found, skipping\x1b[0m\n\n", .{ref});
                    try step_results.append(allocator, .{
                        .step_name = step.name,
                        .exit_code = 1,
                        .stdout = try allocator.dupe(u8, ""),
                        .stderr = try allocator.dupe(u8, "snippet not found"),
                        .skipped = true,
                    });
                    all_success = false;
                    switch (step.on_fail) {
                        .stop => break,
                        .skip_rest => break,
                        .@"continue" => continue,
                    }
                }
            } else {
                printOut(allocator, "  \x1b[31m✗ No command or snippet reference\x1b[0m\n\n", .{});
                try step_results.append(allocator, .{
                    .step_name = step.name,
                    .exit_code = 1,
                    .stdout = try allocator.dupe(u8, ""),
                    .stderr = try allocator.dupe(u8, "no command"),
                    .skipped = true,
                });
                continue;
            }
        };

        // Build extended keys/values: workflow params + prev_stdout + prev_exit + step overrides
        const extra_count: usize = 2; // prev_stdout, prev_exit
        const override_count = step.param_overrides.len;
        const total_keys = workflow.params.len + extra_count + override_count;

        var all_keys = try allocator.alloc([]const u8, total_keys);
        defer allocator.free(all_keys);
        var all_values = try allocator.alloc([]const u8, total_keys);
        defer {
            // Free only the extra values we own (NOT the borrowed workflow param values)
            // prev_stdout value
            allocator.free(all_values[workflow.params.len]);
            // prev_exit value
            allocator.free(all_values[workflow.params.len + 1]);
            // override values
            for (workflow.params.len + extra_count..total_keys) |oi| {
                allocator.free(all_values[oi]);
            }
            allocator.free(all_values);
        }

        // Borrow workflow-level params (owned by outer scope)
        for (0..workflow.params.len) |pi| {
            all_keys[pi] = param_keys[pi];
            all_values[pi] = param_values[pi];
        }

        // Add prev_stdout and prev_exit (owned by this scope)
        all_keys[workflow.params.len] = "prev_stdout";
        all_values[workflow.params.len] = try allocator.dupe(u8, prev_stdout);
        all_keys[workflow.params.len + 1] = "prev_exit";
        all_values[workflow.params.len + 1] = try std.fmt.allocPrint(allocator, "{d}", .{prev_exit});

        // Add step param overrides (owned by this scope)
        for (step.param_overrides, 0..) |ov, oi| {
            all_keys[workflow.params.len + extra_count + oi] = ov.key;
            all_values[workflow.params.len + extra_count + oi] = try allocator.dupe(u8, ov.value);
        }

        // Render the command
        const rendered = try template.render(allocator, raw_cmd, all_keys, all_values);
        defer allocator.free(rendered);

        printOut(allocator, "  \x1b[2m$ {s}\x1b[0m\n", .{rendered});

        // Execute
        const result = try executor.run(allocator, rendered);

        if (result.stdout.len > 0) {
            writeOut(result.stdout);
            if (result.stdout[result.stdout.len - 1] != '\n') writeOut("\n");
        }
        if (result.stderr.len > 0) {
            printOut(allocator, "\x1b[31m{s}\x1b[0m", .{result.stderr});
            if (result.stderr[result.stderr.len - 1] != '\n') writeOut("\n");
        }

        const step_success = result.exit_code == 0;
        if (step_success) {
            printOut(allocator, "  \x1b[32m✓ OK\x1b[0m\n\n", .{});
        } else {
            printOut(allocator, "  \x1b[31m✗ Exit code: {d}\x1b[0m\n\n", .{result.exit_code});
            all_success = false;
        }

        // Update prev_stdout/prev_exit for next step
        if (prev_stdout_owned) allocator.free(prev_stdout);
        prev_stdout = try allocator.dupe(u8, std.mem.trim(u8, result.stdout, "\n\r"));
        prev_stdout_owned = true;
        prev_exit = result.exit_code;

        try step_results.append(allocator, .{
            .step_name = step.name,
            .exit_code = result.exit_code,
            .stdout = result.stdout,
            .stderr = result.stderr,
            .skipped = false,
        });

        // Handle failure policy
        if (!step_success) {
            switch (step.on_fail) {
                .stop => {
                    printOut(allocator, "\x1b[31m⏹ Workflow stopped at step '{s}'\x1b[0m\n", .{step.name});
                    break;
                },
                .skip_rest => {
                    printOut(allocator, "\x1b[33m⏭ Skipping remaining steps\x1b[0m\n", .{});
                    break;
                },
                .@"continue" => {
                    printOut(allocator, "\x1b[33m↳ Continuing despite failure\x1b[0m\n", .{});
                },
            }
        }
    }

    // Summary
    printOut(allocator, "\x1b[1;36mWorkflow '{s}' ", .{workflow.name});
    if (all_success) {
        writeOut("\x1b[32mcompleted successfully\x1b[0m\n");
    } else {
        writeOut("\x1b[31mcompleted with errors\x1b[0m\n");
    }

    return WorkflowResult{
        .step_results = try step_results.toOwnedSlice(allocator),
        .success = all_success,
        .allocator = allocator,
    };
}

fn findSnippet(snip_store: *store.Store, name: []const u8) ?*const store.Snippet {
    for (snip_store.snippets.items) |*snip| {
        if (snip.kind == .snippet and std.mem.eql(u8, snip.name, name)) {
            return snip;
        }
    }
    return null;
}

/// Load workflows from a TOML file into the store as Snippet entries with kind=.workflow
pub fn loadWorkflowFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    namespace: []const u8,
    snip_store: *store.Store,
) !void {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 1024 * 256);
    defer allocator.free(content);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    const table = try toml.parse(arena_alloc, content);

    // Collect workflow names from keys like "workflows.<name>.<something>"
    var wf_names = std.StringHashMap(void).init(allocator);
    defer {
        var key_iter = wf_names.keyIterator();
        while (key_iter.next()) |k| allocator.free(k.*);
        wf_names.deinit();
    }

    for (table.keys) |key| {
        if (std.mem.startsWith(u8, key, "workflows.")) {
            const rest = key["workflows.".len..];
            if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
                const name = rest[0..dot];
                if (!wf_names.contains(name)) {
                    try wf_names.put(try allocator.dupe(u8, name), {});
                }
            }
        }
    }

    var name_iter = wf_names.keyIterator();
    while (name_iter.next()) |name_ptr| {
        const wf_name = name_ptr.*;

        const desc_key = try std.fmt.allocPrint(allocator, "workflows.{s}.desc", .{wf_name});
        defer allocator.free(desc_key);
        const desc_val = table.getString(desc_key) orelse "";

        const tags_key = try std.fmt.allocPrint(allocator, "workflows.{s}.tags", .{wf_name});
        defer allocator.free(tags_key);

        var tags: std.ArrayList([]const u8) = .{};
        if (table.getArray(tags_key)) |arr| {
            for (arr) |item| {
                switch (item) {
                    .string => |s| try tags.append(allocator, try allocator.dupe(u8, s)),
                    else => {},
                }
            }
        }

        // Collect steps - look for workflows.<name>.steps.<N>.cmd or .snippet
        var steps: std.ArrayList(Step) = .{};
        var step_num: usize = 1;
        while (step_num <= 100) : (step_num += 1) {
            const step_cmd_key = try std.fmt.allocPrint(allocator, "workflows.{s}.steps.{d}.cmd", .{ wf_name, step_num });
            defer allocator.free(step_cmd_key);

            const step_snippet_key = try std.fmt.allocPrint(allocator, "workflows.{s}.steps.{d}.snippet", .{ wf_name, step_num });
            defer allocator.free(step_snippet_key);

            const step_name_key = try std.fmt.allocPrint(allocator, "workflows.{s}.steps.{d}.name", .{ wf_name, step_num });
            defer allocator.free(step_name_key);

            const step_onfail_key = try std.fmt.allocPrint(allocator, "workflows.{s}.steps.{d}.on_fail", .{ wf_name, step_num });
            defer allocator.free(step_onfail_key);

            const has_cmd = table.getString(step_cmd_key) != null;
            const has_snippet = table.getString(step_snippet_key) != null;

            if (!has_cmd and !has_snippet) break;

            const step_name = table.getString(step_name_key) orelse
                try std.fmt.allocPrint(allocator, "Step {d}", .{step_num});
            const on_fail_str = table.getString(step_onfail_key) orelse "stop";

            try steps.append(allocator, .{
                .name = try allocator.dupe(u8, step_name),
                .cmd = if (has_cmd) try allocator.dupe(u8, table.getString(step_cmd_key).?) else null,
                .snippet_ref = if (has_snippet) try allocator.dupe(u8, table.getString(step_snippet_key).?) else null,
                .on_fail = OnFail.fromString(on_fail_str),
                .param_overrides = &.{},
            });
        }

        if (steps.items.len == 0) continue;

        // Collect workflow-level params
        var params_list: std.ArrayList(template.Param) = .{};

        // Detect params from all step commands
        for (steps.items) |step| {
            if (step.cmd) |cmd| {
                const detected = try template.detectParams(allocator, cmd);
                defer allocator.free(detected);
                for (detected) |pname| {
                    // Skip prev_stdout, prev_exit — they're auto-provided
                    if (std.mem.eql(u8, pname, "prev_stdout") or std.mem.eql(u8, pname, "prev_exit")) {
                        allocator.free(pname);
                        continue;
                    }
                    // Check duplicates
                    var found = false;
                    for (params_list.items) |existing| {
                        if (std.mem.eql(u8, existing.name, pname)) {
                            found = true;
                            allocator.free(pname);
                            break;
                        }
                    }
                    if (!found) {
                        var param = template.Param{
                            .name = pname,
                            .prompt = null,
                            .default = null,
                            .options = null,
                            .command = null,
                        };

                        // Check for param config in TOML
                        const param_key = try std.fmt.allocPrint(allocator, "workflows.{s}.params.{s}", .{ wf_name, pname });
                        defer allocator.free(param_key);

                        for (table.keys, table.values) |tk, tv| {
                            if (std.mem.eql(u8, tk, param_key)) {
                                switch (tv) {
                                    .table => |pt| {
                                        if (pt.getString("prompt")) |pr| {
                                            param.prompt = try allocator.dupe(u8, pr);
                                        }
                                        if (pt.getString("default")) |d| {
                                            param.default = try allocator.dupe(u8, d);
                                        }
                                        if (pt.getString("command")) |c| {
                                            param.command = try allocator.dupe(u8, c);
                                        }
                                    },
                                    else => {},
                                }
                            }
                        }

                        try params_list.append(allocator, param);
                    }
                }
            }
        }

        // Build a summary command for display (shows step flow)
        var cmd_buf: std.ArrayList(u8) = .{};
        const cmd_writer = cmd_buf.writer(allocator);
        for (steps.items, 0..) |step, si| {
            if (si > 0) try cmd_writer.writeAll(" → ");
            if (step.snippet_ref) |ref| {
                try cmd_writer.print("[{s}]", .{ref});
            } else if (step.cmd) |cmd| {
                const display = if (cmd.len > 40) cmd[0..40] else cmd;
                try cmd_writer.writeAll(display);
                if (cmd.len > 40) try cmd_writer.writeAll("...");
            }
        }

        // Get owned params slice — shared between snippet entry and workflow registry
        const owned_params = try params_list.toOwnedSlice(allocator);
        const owned_steps = try steps.toOwnedSlice(allocator);

        // Check for duplicates before adding
        var already_exists = false;
        for (snip_store.snippets.items) |existing| {
            if (std.mem.eql(u8, existing.name, wf_name) and existing.kind == .workflow) {
                already_exists = true;
                break;
            }
        }
        if (already_exists) {
            // Free everything we allocated for this workflow
            for (owned_steps) |step| {
                allocator.free(step.name);
                if (step.cmd) |c| allocator.free(c);
                if (step.snippet_ref) |r| allocator.free(r);
            }
            allocator.free(owned_steps);
            for (owned_params) |p| {
                allocator.free(p.name);
                if (p.prompt) |pr| allocator.free(pr);
                if (p.default) |d| allocator.free(d);
                if (p.command) |c| allocator.free(c);
            }
            allocator.free(owned_params);
            continue;
        }

        // Store the workflow as a Snippet with kind=.workflow
        try snip_store.snippets.append(allocator, .{
            .name = try allocator.dupe(u8, wf_name),
            .desc = try allocator.dupe(u8, desc_val),
            .cmd = try cmd_buf.toOwnedSlice(allocator),
            .tags = try tags.toOwnedSlice(allocator),
            .params = owned_params,
            .namespace = try allocator.dupe(u8, namespace),
            .kind = .workflow,
        });

        // Also register in global workflow storage
        // The workflow borrows params from the snippet entry (same pointer)
        try registerWorkflow(allocator, .{
            .name = try allocator.dupe(u8, wf_name),
            .desc = try allocator.dupe(u8, desc_val),
            .tags = &.{},
            .steps = owned_steps,
            .params = owned_params, // shared with snippet entry
            .namespace = try allocator.dupe(u8, namespace),
        });
    }
}

// ── Global workflow registry ──

var g_workflows: std.StringHashMap(Workflow) = undefined;
var g_workflows_initialized: bool = false;

fn ensureRegistryInit(allocator: std.mem.Allocator) void {
    if (!g_workflows_initialized) {
        g_workflows = std.StringHashMap(Workflow).init(allocator);
        g_workflows_initialized = true;
    }
}

pub fn registerWorkflow(allocator: std.mem.Allocator, wf: Workflow) !void {
    ensureRegistryInit(allocator);
    try g_workflows.put(wf.name, wf);
}

pub fn getWorkflow(allocator: std.mem.Allocator, name: []const u8) ?*const Workflow {
    ensureRegistryInit(allocator);
    if (g_workflows.getPtr(name)) |ptr| return ptr;
    return null;
}

pub fn deinitRegistry(allocator: std.mem.Allocator) void {
    if (!g_workflows_initialized) return;

    // Collect all values first, then free — avoids use-after-free on HashMap keys
    var vals: std.ArrayList(Workflow) = .{};
    defer vals.deinit(allocator);
    var iter = g_workflows.valueIterator();
    while (iter.next()) |wf| {
        vals.append(allocator, wf.*) catch {};
    }
    // Clear the HashMap first (releases its internal storage)
    g_workflows.deinit();
    g_workflows_initialized = false;

    // Now free all the owned data
    for (vals.items) |wf| {
        for (wf.steps) |step| {
            allocator.free(step.name);
            if (step.cmd) |c| allocator.free(c);
            if (step.snippet_ref) |r| allocator.free(r);
        }
        allocator.free(wf.steps);
        allocator.free(wf.name);
        allocator.free(wf.desc);
        allocator.free(wf.namespace);
        // Note: wf.params is shared with store's snippet entry — store frees it
    }
}

/// Save a workflow to a TOML file.
pub fn saveWorkflow(allocator: std.mem.Allocator, wf: *const Workflow, cfg: config.Config) !void {
    const workflows_dir = try cfg.getWorkflowsDir(allocator);
    defer allocator.free(workflows_dir);

    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ workflows_dir, wf.namespace });
    defer allocator.free(path);

    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.print("# zipet workflow — {s}\n\n", .{wf.namespace});

    try writer.print("[workflows.{s}]\n", .{wf.name});
    try writer.print("desc = \"{s}\"\n", .{wf.desc});

    try writer.writeAll("tags = [");
    for (wf.tags, 0..) |tag, i| {
        if (i > 0) try writer.writeAll(", ");
        try writer.print("\"{s}\"", .{tag});
    }
    try writer.writeAll("]\n\n");

    for (wf.steps, 0..) |step, si| {
        const step_num = si + 1;
        try writer.print("[workflows.{s}.steps.{d}]\n", .{ wf.name, step_num });
        try writer.print("name = \"{s}\"\n", .{step.name});

        if (step.cmd) |cmd| {
            try writer.print("cmd = \"{s}\"\n", .{cmd});
        }
        if (step.snippet_ref) |ref| {
            try writer.print("snippet = \"{s}\"\n", .{ref});
        }

        const on_fail_str: []const u8 = switch (step.on_fail) {
            .stop => "stop",
            .@"continue" => "continue",
            .skip_rest => "skip_rest",
        };
        try writer.print("on_fail = \"{s}\"\n\n", .{on_fail_str});
    }

    // Write param configs
    for (wf.params) |p| {
        if (p.prompt != null or p.default != null or p.command != null) {
            try writer.print("[workflows.{s}.params.{s}]\n", .{ wf.name, p.name });
            if (p.prompt) |pr| try writer.print("prompt = \"{s}\"\n", .{pr});
            if (p.default) |d| try writer.print("default = \"{s}\"\n", .{d});
            if (p.command) |c| try writer.print("command = \"{s}\"\n", .{c});
            try writer.writeAll("\n");
        }
    }

    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

/// Execute multiple workflows in parallel.
/// Each workflow runs with pre-supplied param values (no interactive prompts).
pub fn executeParallel(
    allocator: std.mem.Allocator,
    workflows: []const ParallelWorkflowItem,
    snip_store: *store.Store,
) ![]ParallelWorkflowResult {
    if (workflows.len == 0) {
        return try allocator.alloc(ParallelWorkflowResult, 0);
    }

    // Build parallel items — render each workflow into a compound shell command
    var items = try allocator.alloc(executor.ParallelItem, workflows.len);
    defer {
        for (items) |item| allocator.free(item.cmd);
        allocator.free(items);
    }

    for (workflows, 0..) |pw, i| {
        const wf = pw.workflow;

        // Build a single shell script that runs all steps sequentially
        var script_buf: std.ArrayList(u8) = .{};
        const writer = script_buf.writer(allocator);
        try writer.writeAll("set -e\n");

        const prev_stdout_val: []const u8 = "";
        const prev_exit_val: []const u8 = "0";

        for (wf.steps) |step_item| {
            const raw_cmd = blk: {
                if (step_item.cmd) |cmd| break :blk cmd;
                if (step_item.snippet_ref) |ref| {
                    if (findSnippet(snip_store, ref)) |s| break :blk s.cmd;
                }
                continue;
            };

            // Build keys/vals for template rendering
            const extra: usize = 2;
            const total = pw.param_keys.len + extra;
            var keys = try allocator.alloc([]const u8, total);
            defer allocator.free(keys);
            var vals = try allocator.alloc([]const u8, total);
            defer {
                allocator.free(vals[pw.param_keys.len]);
                allocator.free(vals[pw.param_keys.len + 1]);
                allocator.free(vals);
            }

            for (0..pw.param_keys.len) |pi| {
                keys[pi] = pw.param_keys[pi];
                vals[pi] = pw.param_values[pi];
            }
            keys[pw.param_keys.len] = "prev_stdout";
            vals[pw.param_keys.len] = try allocator.dupe(u8, prev_stdout_val);
            keys[pw.param_keys.len + 1] = "prev_exit";
            vals[pw.param_keys.len + 1] = try allocator.dupe(u8, prev_exit_val);

            const rendered = try template.render(allocator, raw_cmd, keys, vals);
            defer allocator.free(rendered);

            try writer.print("{s}\n", .{rendered});
        }

        items[i] = .{
            .name = wf.name,
            .cmd = try script_buf.toOwnedSlice(allocator),
        };
    }

    const exec_results = try executor.runParallel(allocator, items);
    defer allocator.free(exec_results);

    var results = try allocator.alloc(ParallelWorkflowResult, workflows.len);
    for (exec_results, 0..) |er, i| {
        results[i] = .{
            .name = er.name,
            .success = er.exit_code == 0 and !er.err,
            .exit_code = er.exit_code,
            .stdout = if (!er.err) er.stdout else try allocator.dupe(u8, ""),
            .stderr = if (!er.err) er.stderr else try allocator.dupe(u8, "execution error"),
            .duration_ms = er.duration_ms,
        };
    }

    return results;
}

pub const ParallelWorkflowItem = struct {
    workflow: *const Workflow,
    param_keys: []const []const u8,
    param_values: []const []const u8,
};

pub const ParallelWorkflowResult = struct {
    name: []const u8,
    success: bool,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    duration_ms: u64,
};

pub fn freeParallelWorkflowResults(allocator: std.mem.Allocator, results: []ParallelWorkflowResult) void {
    for (results) |r| {
        allocator.free(r.stdout);
        allocator.free(r.stderr);
    }
    allocator.free(results);
}

test "workflow basic" {
    // Placeholder test
    const gpa = std.testing.allocator;
    _ = gpa;
}
