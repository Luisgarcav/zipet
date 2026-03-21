/// TUI actions: snippet execution, form submission, workflow running.
const std = @import("std");
const store = @import("../store.zig");
const config = @import("../config.zig");
const executor = @import("../executor.zig");
const template = @import("../template.zig");
const workflow_mod = @import("../workflow.zig");
const history_mod = @import("../history.zig");
const pack_mod = @import("../pack.zig");
const workspace_mod = @import("../workspace.zig");
const t = @import("types.zig");
const utils = @import("utils.zig");

const State = t.State;
const OutputBuf = t.OutputBuf;
const MAX_PARAMS = t.MAX_PARAMS;

fn setOutputTitle(allocator: std.mem.Allocator, state: *State, title: []const u8) void {
    if (state.output_title) |old| allocator.free(old);
    state.output_title = allocator.dupe(u8, title) catch null;
}

pub fn initParamInput(state: *State, snippet_idx: usize, snip: *const store.Snippet) void {
    state.param_input = .{};
    state.param_input.snippet_idx = snippet_idx;
    state.param_input.is_workflow = snip.kind == .workflow;
    const count = @min(snip.params.len, MAX_PARAMS);
    state.param_input.param_count = count;
    state.param_input.needs_reset = true;
    for (0..count) |i| {
        state.param_input.labels[i] = snip.params[i].prompt orelse snip.params[i].name;
        state.param_input.defaults[i] = snip.params[i].default;
    }
}

pub const FormValues = struct {
    name: []const u8,
    desc: []const u8,
    cmd: []const u8,
    tags_str: []const u8,
    namespace: []const u8,
    purpose: t.FormPurpose,
    editing_snip_idx: ?usize,
};

pub fn submitForm(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store, hist: *history_mod.History, values: FormValues) ?[]const u8 {
    if (values.name.len == 0) return "Name is required";
    if (values.cmd.len == 0) return "Command is required";

    const name = values.name;
    const cmd = values.cmd;
    const desc = values.desc;
    const tags_str = values.tags_str;
    const namespace = if (values.namespace.len > 0) values.namespace else "general";

    // Parse tags
    var tags: std.ArrayList([]const u8) = .{};
    if (tags_str.len > 0) {
        var iter = std.mem.splitScalar(u8, tags_str, ',');
        while (iter.next()) |tag| {
            const trimmed = std.mem.trim(u8, tag, " \t");
            if (trimmed.len > 0)
                tags.append(allocator, allocator.dupe(u8, trimmed) catch continue) catch {};
        }
    }

    // Detect params
    const detected = template.detectParams(allocator, cmd) catch &[_][]const u8{};
    var params: []template.Param = &.{};
    if (detected.len > 0) {
        if (allocator.alloc(template.Param, detected.len)) |p| {
            params = p;
            for (detected, 0..) |pname, i| {
                params[i] = .{ .name = pname, .prompt = null, .default = null, .options = null, .command = null };
            }
        } else |_| {}
    }

    if (values.purpose == .edit) {
        if (values.editing_snip_idx) |old_idx| {
            const old_name = snip_store.snippets.items[old_idx].name;
            snip_store.remove(old_name) catch {};
        }
    }

    const snippet = store.Snippet{
        .name = allocator.dupe(u8, name) catch return null,
        .desc = allocator.dupe(u8, desc) catch return null,
        .cmd = allocator.dupe(u8, cmd) catch return null,
        .tags = tags.toOwnedSlice(allocator) catch &.{},
        .params = params,
        .namespace = allocator.dupe(u8, namespace) catch return null,
        .kind = .snippet,
    };

    snip_store.add(snippet) catch {};
    allocator.free(state.filtered_indices);
    state.filtered_indices = utils.updateFilterFrecency(allocator, snip_store, state.searchQuery(), null, hist) catch &.{};
    state.message = switch (values.purpose) {
        .add => "✓ Snippet added",
        .edit => "✓ Snippet updated",
        .paste => "✓ Pasted as snippet",
    };
    state.mode = .normal;
    return null;
}

pub fn submitParamInput(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store, cfg: config.Config, hist: *history_mod.History, param_values: []const []const u8) !void {
    const pi = &state.param_input;
    const snip = &snip_store.snippets.items[pi.snippet_idx];

    var param_keys = try allocator.alloc([]const u8, pi.param_count);
    defer allocator.free(param_keys);

    // Apply defaults for empty values
    var resolved_values = try allocator.alloc([]const u8, pi.param_count);
    defer {
        for (resolved_values[0..pi.param_count]) |v| allocator.free(v);
        allocator.free(resolved_values);
    }

    for (0..pi.param_count) |i| {
        param_keys[i] = snip.params[i].name;
        const val = if (i < param_values.len) param_values[i] else "";
        if (val.len == 0 and pi.defaults[i] != null)
            resolved_values[i] = try allocator.dupe(u8, pi.defaults[i].?)
        else
            resolved_values[i] = try allocator.dupe(u8, val);
    }

    if (snip.kind == .workflow) {
        try executeWorkflow(allocator, state, snip, snip_store, param_keys, resolved_values, hist);
    } else {
        const rendered = try template.render(allocator, snip.cmd, param_keys, resolved_values);
        defer allocator.free(rendered);
        try executeAndShowOutput(allocator, state, snip.name, rendered, hist);
    }
    _ = cfg;
}

pub fn executeSnippetDirect(allocator: std.mem.Allocator, state: *State, snip: *const store.Snippet, cfg: config.Config, snip_store: *store.Store, hist: *history_mod.History) !void {
    _ = cfg;
    if (snip.kind == .workflow) {
        try executeWorkflow(allocator, state, snip, snip_store, &.{}, &.{}, hist);
    } else {
        const rendered = try template.render(allocator, snip.cmd, &.{}, &.{});
        defer allocator.free(rendered);
        try executeAndShowOutput(allocator, state, snip.name, rendered, hist);
    }
}

pub fn executeAndShowOutput(allocator: std.mem.Allocator, state: *State, name: []const u8, cmd: []const u8, hist: *history_mod.History) !void {
    state.output.deinit();
    state.output = OutputBuf.init(allocator);

    setOutputTitle(allocator, state, name);

    state.output.addFmt(allocator, "$ {s}", .{cmd}, .cmd);
    state.output.add("", .normal);

    var timer = std.time.Timer.start() catch null;

    const result = executor.run(allocator, cmd) catch |err| {
        state.output.addFmt(allocator, "Error: {}", .{err}, .err);
        state.mode = .output_view;
        // Record failed execution
        hist.record(name, 1, 0) catch {};
        return;
    };
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    const duration_ms: u64 = if (timer) |*t2| t2.read() / std.time.ns_per_ms else 0;

    // Record in history
    hist.record(name, result.exit_code, duration_ms) catch {};

    if (result.stdout.len > 0) state.output.addMultiline(result.stdout, .normal);

    if (result.stderr.len > 0) {
        state.output.add("", .normal);
        state.output.add("── stderr ──", .header);
        state.output.addMultiline(result.stderr, .err);
    }

    state.output.add("", .normal);
    if (result.exit_code == 0) {
        state.output.add("✓ Completed successfully", .success);
    } else {
        state.output.addFmt(allocator, "✗ Exit code: {d}", .{result.exit_code}, .err);
    }

    state.mode = .output_view;
}

pub fn executeWorkflow(allocator: std.mem.Allocator, state: *State, snip: *const store.Snippet, snip_store: *store.Store, param_keys: []const []const u8, param_values: []const []const u8, hist: *history_mod.History) !void {
    state.output.deinit();
    state.output = OutputBuf.init(allocator);
    setOutputTitle(allocator, state, snip.name);

    const wf = workflow_mod.getWorkflow(allocator, snip.name);
    if (wf == null) {
        state.output.add("Workflow not found in registry", .err);
        state.mode = .output_view;
        return;
    }

    state.output.addFmt(allocator, "⚡Workflow: {s}", .{snip.name}, .header);
    state.output.add(snip.desc, .dim);
    state.output.addFmt(allocator, "Running {d} steps...", .{wf.?.steps.len}, .dim);
    state.output.add("", .normal);

    const result = workflow_mod.executeSilent(allocator, wf.?, snip_store, param_keys, param_values) catch |err| {
        state.output.addFmt(allocator, "Workflow error: {}", .{err}, .err);
        state.mode = .output_view;
        return;
    };
    defer result.deinit();

    for (result.step_results, 0..) |sr, i| {
        state.output.addFmt(allocator, "[{d}/{d}] {s}", .{ i + 1, result.step_results.len, sr.step_name }, .header);

        if (sr.skipped) {
            state.output.add("  ⏭ Skipped", .dim);
        } else {
            if (sr.stdout.len > 0) state.output.addMultiline(sr.stdout, .normal);
            if (sr.stderr.len > 0) {
                state.output.addMultiline(sr.stderr, .err);
            }
            if (sr.exit_code == 0) {
                state.output.add("  ✓ OK", .success);
            } else {
                state.output.addFmt(allocator, "  ✗ Exit code: {d}", .{sr.exit_code}, .err);
            }
        }
        state.output.add("", .normal);
    }

    if (result.success) {
        state.output.add("✓ Workflow completed successfully", .success);
        hist.record(snip.name, 0, 0) catch {};
    } else {
        state.output.add("✗ Workflow completed with errors", .err);
        hist.record(snip.name, 1, 0) catch {};
    }

    state.mode = .output_view;
}

/// Show execution history in the output view.
pub fn showHistory(allocator: std.mem.Allocator, state: *State, hist: *history_mod.History) void {
    state.output.deinit();
    state.output = OutputBuf.init(allocator);
    setOutputTitle(allocator, state, "History");

    const entries = hist.recent(allocator, 100) catch {
        state.output.add("Failed to load history", .err);
        state.mode = .output_view;
        return;
    };
    defer allocator.free(entries);

    if (entries.len == 0) {
        state.output.add("No execution history yet.", .dim);
        state.output.add("Run some snippets and they'll appear here.", .dim);
        state.mode = .output_view;
        return;
    }

    state.output.addFmt(allocator, "── Recent Executions ({d} total) ──", .{hist.entries.items.len}, .header);
    state.output.add("", .normal);

    for (entries) |e| {
        const time_str = history_mod.formatRelativeTime(allocator, e.timestamp) catch allocator.dupe(u8, "?") catch "?";
        defer allocator.free(time_str);

        const status: []const u8 = if (e.exit_code == 0) "✓" else "✗";
        const style: t.LineStyle = if (e.exit_code == 0) .success else .err;

        if (e.duration_ms > 0) {
            state.output.addFmt(allocator, "  {s} {s}  ({s}, {d}ms)", .{ status, e.snippet_name, time_str, e.duration_ms }, style);
        } else {
            state.output.addFmt(allocator, "  {s} {s}  ({s})", .{ status, e.snippet_name, time_str }, style);
        }
    }

    state.output.add("", .normal);

    // Show frecency top 10
    const scores = hist.frecencyScores(allocator) catch {
        state.mode = .output_view;
        return;
    };
    defer allocator.free(scores);

    if (scores.len > 0) {
        state.output.add("── Frecency Rankings ──", .header);
        state.output.add("", .normal);
        const show = @min(scores.len, 10);
        for (scores[0..show], 0..) |s, i| {
            state.output.addFmt(allocator, "  {d}. {s}  (score: {d:.1}, runs: {d})", .{ i + 1, s.name, s.score, s.run_count }, .normal);
        }
    }

    state.mode = .output_view;
}

pub fn submitWorkflowForm(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store, cfg: config.Config) !void {
    const wf = &state.wf_form;

    const name = wf.info_fields[t.WorkflowFormState.F_NAME].text();
    if (name.len == 0) {
        wf.error_msg = "Name is required";
        return;
    }
    if (wf.step_count == 0) {
        wf.error_msg = "At least one step is required";
        return;
    }

    const desc = wf.info_fields[t.WorkflowFormState.F_DESC].text();
    const tags_str = wf.info_fields[t.WorkflowFormState.F_TAGS].text();
    const ns = wf.info_fields[t.WorkflowFormState.F_NS].text();
    const namespace = if (ns.len > 0) ns else "general";

    // Parse tags
    var tags: std.ArrayList([]const u8) = .{};
    if (tags_str.len > 0) {
        var iter = std.mem.splitScalar(u8, tags_str, ',');
        while (iter.next()) |tag| {
            const trimmed = std.mem.trim(u8, tag, " \t");
            if (trimmed.len > 0)
                tags.append(allocator, allocator.dupe(u8, trimmed) catch continue) catch {};
        }
    }

    // Build steps
    var steps: std.ArrayList(workflow_mod.Step) = .{};
    for (0..wf.step_count) |i| {
        const se = &wf.steps[i];
        const step_name_slice = se.nameSlice();
        const step_cmd_slice = se.cmdSlice();

        try steps.append(allocator, .{
            .name = try allocator.dupe(u8, step_name_slice),
            .cmd = if (!se.is_snippet) try allocator.dupe(u8, step_cmd_slice) else null,
            .snippet_ref = if (se.is_snippet) try allocator.dupe(u8, step_cmd_slice) else null,
            .on_fail = switch (se.on_fail) {
                .stop => .stop,
                .@"continue" => .@"continue",
                .skip_rest => .skip_rest,
                .ask => .ask,
            },
            .param_overrides = &.{},
        });
    }

    const owned_steps = try steps.toOwnedSlice(allocator);

    // Detect params from all steps
    var params_list: std.ArrayList(template.Param) = .{};
    for (owned_steps) |step| {
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

    const owned_tags = try tags.toOwnedSlice(allocator);

    const wf_data = workflow_mod.Workflow{
        .name = try allocator.dupe(u8, name),
        .desc = try allocator.dupe(u8, desc),
        .tags = owned_tags,
        .steps = owned_steps,
        .params = owned_params,
        .namespace = try allocator.dupe(u8, namespace),
    };

    // Save to file
    try workflow_mod.saveWorkflow(allocator, &wf_data, cfg);

    // Register in memory
    try workflow_mod.registerWorkflow(allocator, wf_data);

    // Add to store as a snippet entry
    try snip_store.snippets.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .desc = try allocator.dupe(u8, desc),
        .cmd = try cmd_buf.toOwnedSlice(allocator),
        .tags = wf_data.tags,
        .params = wf_data.params,
        .namespace = try allocator.dupe(u8, namespace),
        .kind = .workflow,
    });

    // Update filter and go back
    allocator.free(state.filtered_indices);
    state.filtered_indices = utils.updateFilter(allocator, snip_store, state.searchQuery()) catch &.{};
    state.message = "✓ Workflow created";
    state.mode = .normal;
}

pub fn openExternalEditor(allocator: std.mem.Allocator, snip: *const store.Snippet, cfg: config.Config) void {
    const dir = if (snip.kind == .workflow)
        cfg.getWorkflowsDir(allocator) catch return
    else
        cfg.getSnippetsDir(allocator) catch return;
    defer allocator.free(dir);

    const path = std.fmt.allocPrint(allocator, "{s}/{s}.toml", .{ dir, snip.namespace }) catch return;
    defer allocator.free(path);

    var child = std.process.Child.init(&.{ cfg.editor, path }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = child.spawnAndWait() catch {};
}

pub fn buildExportOutput(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store) void {
    state.output.deinit();
    state.output = OutputBuf.init(allocator);
    setOutputTitle(allocator, state, "Export");

    for (snip_store.snippets.items) |snip| {
        if (snip.kind == .workflow) continue;
        state.output.addFmt(allocator, "[snippets.{s}]", .{snip.name}, .header);
        state.output.addFmt(allocator, "desc = \"{s}\"", .{snip.desc}, .normal);

        var tags_buf: [256]u8 = undefined;
        var tl: usize = 0;
        const prefix = "tags = [";
        @memcpy(tags_buf[0..prefix.len], prefix);
        tl = prefix.len;
        for (snip.tags, 0..) |tag, ti| {
            if (ti > 0 and tl + 2 < 256) {
                tags_buf[tl] = ',';
                tags_buf[tl + 1] = ' ';
                tl += 2;
            }
            if (tl + tag.len + 2 < 256) {
                tags_buf[tl] = '"';
                tl += 1;
                @memcpy(tags_buf[tl .. tl + tag.len], tag);
                tl += tag.len;
                tags_buf[tl] = '"';
                tl += 1;
            }
        }
        if (tl < 255) {
            tags_buf[tl] = ']';
            tl += 1;
        }
        state.output.add(tags_buf[0..tl], .normal);

        state.output.addFmt(allocator, "cmd = \"{s}\"", .{snip.cmd}, .normal);
        state.output.add("", .normal);
    }
}

pub fn saveAll(allocator: std.mem.Allocator, snip_store: *store.Store) void {
    var ns_set = std.StringHashMap(void).init(allocator);
    defer ns_set.deinit();
    for (snip_store.snippets.items) |snip| {
        if (!ns_set.contains(snip.namespace)) {
            ns_set.put(snip.namespace, {}) catch {};
            snip_store.saveNamespace(snip.namespace) catch {};
        }
    }
}

pub fn openWorkspacePicker(allocator: std.mem.Allocator, state: *State, cfg: config.Config) !void {
    if (state.ws_loaded) {
        workspace_mod.freeWorkspaces(allocator, state.ws_list);
    }
    state.ws_list = try workspace_mod.list(allocator, cfg);
    state.ws_loaded = true;
    state.ws_cursor = 0;

    if (state.active_workspace) |aw| {
        for (state.ws_list, 0..) |ws, i| {
            if (std.mem.eql(u8, ws.name, aw)) {
                state.ws_cursor = i + 1;
                break;
            }
        }
    }

    state.mode = .workspace_picker;
}

pub fn executeSelectedParallel(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store) !void {
    const count = state.selectionCount();
    if (count == 0) return;

    state.output.deinit();
    state.output = OutputBuf.init(allocator);
    setOutputTitle(allocator, state, "Parallel Execution");

    // Collect items to run
    var items: std.ArrayList(executor.ParallelItem) = .{};
    defer items.deinit(allocator);

    var rendered_cmds: std.ArrayList([]const u8) = .{};
    defer {
        for (rendered_cmds.items) |c| allocator.free(c);
        rendered_cmds.deinit(allocator);
    }

    var sel_iter = state.selected_set.keyIterator();
    while (sel_iter.next()) |idx_ptr| {
        const si = idx_ptr.*;
        if (si >= snip_store.snippets.items.len) continue;
        const snip = &snip_store.snippets.items[si];
        if (snip.kind == .workflow) continue; // skip workflows for parallel
        if (snip.params.len > 0) continue; // skip snippets with params

        const rendered = template.render(allocator, snip.cmd, &.{}, &.{}) catch continue;
        try rendered_cmds.append(allocator, rendered);

        try items.append(allocator, .{
            .name = snip.name,
            .cmd = rendered,
        });
    }

    if (items.items.len == 0) {
        state.output.add("No executable snippets in selection", .err);
        state.output.add("(Snippets with parameters and workflows are skipped)", .dim);
        state.mode = .output_view;
        return;
    }

    state.output.addFmt(allocator, "⚡Running {d} snippets in parallel...", .{items.items.len}, .header);
    state.output.add("", .normal);

    const results = executor.runParallel(allocator, items.items) catch |err| {
        state.output.addFmt(allocator, "Parallel execution error: {}", .{err}, .err);
        state.mode = .output_view;
        return;
    };
    defer executor.freeParallelResults(allocator, results);

    var total_ok: usize = 0;
    var total_fail: usize = 0;

    for (results) |r| {
        state.output.addFmt(allocator, "── {s} ──", .{r.name}, .header);
        state.output.addFmt(allocator, "  Duration: {d}ms", .{r.duration_ms}, .dim);

        if (r.err) {
            state.output.add("  ✗ Failed to execute", .err);
            total_fail += 1;
        } else {
            if (r.stdout.len > 0) state.output.addMultiline(r.stdout, .normal);
            if (r.stderr.len > 0) {
                state.output.add("  stderr:", .dim);
                state.output.addMultiline(r.stderr, .err);
            }
            if (r.exit_code == 0) {
                state.output.add("  ✓ OK", .success);
                total_ok += 1;
            } else {
                state.output.addFmt(allocator, "  ✗ Exit code: {d}", .{r.exit_code}, .err);
                total_fail += 1;
            }
        }
        state.output.add("", .normal);
    }

    state.output.addFmt(allocator, "── Summary: {d} ok, {d} failed ──", .{ total_ok, total_fail }, if (total_fail == 0) .success else .err);
    state.clearSelection();
    state.mode = .output_view;
}

pub fn deleteSelected(allocator: std.mem.Allocator, state: *State, snip_store: *store.Store) void {
    const count = state.selectionCount();
    if (count == 0) return;

    // Collect indices in descending order to safely remove
    var indices: std.ArrayList(usize) = .{};
    defer indices.deinit(allocator);

    var sel_iter = state.selected_set.keyIterator();
    while (sel_iter.next()) |idx_ptr| {
        indices.append(allocator, idx_ptr.*) catch {};
    }

    // Sort descending so removal doesn't shift later indices
    std.mem.sort(usize, indices.items, {}, struct {
        fn cmp(_: void, a: usize, b: usize) bool {
            return a > b;
        }
    }.cmp);

    var removed: usize = 0;
    for (indices.items) |si| {
        if (si >= snip_store.snippets.items.len) continue;
        const name = snip_store.snippets.items[si].name;
        snip_store.remove(name) catch continue;
        removed += 1;
    }

    state.clearSelection();
    allocator.free(state.filtered_indices);
    state.filtered_indices = utils.updateFilter(allocator, snip_store, state.searchQuery()) catch &.{};

    if (state.filtered_indices.len == 0) {
        state.cursor = 0;
    } else if (state.cursor >= state.filtered_indices.len) {
        state.cursor = state.filtered_indices.len - 1;
    }

    if (removed > 0) {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "✓ Deleted {d} snippets", .{removed}) catch "✓ Deleted";
        state.message = allocator.dupe(u8, msg) catch "✓ Deleted";
    }
}

pub fn openPackPreview(allocator: std.mem.Allocator, state: *State) !void {
    if (state.pack_list.len == 0 or state.pack_cursor >= state.pack_list.len) return;
    const p = &state.pack_list[state.pack_cursor];

    // Free previous preview if any
    if (state.pack_preview_items.len > 0) {
        pack_mod.freePackPreview(allocator, state.pack_preview_items);
        state.pack_preview_items = &.{};
    }

    state.pack_preview_items = try pack_mod.getPackPreview(allocator, p.name);
    state.pack_preview_cursor = 0;
    state.pack_preview_scroll = 0;
    state.pack_preview_name = p.name;
    state.pack_preview_installed = p.installed;
    state.mode = .pack_preview;
}

pub fn openPackBrowser(allocator: std.mem.Allocator, state: *State, cfg: config.Config) !void {
    if (state.pack_list.len > 0) {
        pack_mod.freePackMetas(allocator, state.pack_list);
    }
    state.pack_list = try pack_mod.listAvailable(allocator, cfg);
    state.pack_cursor = 0;
    state.pack_scroll = 0;
    state.pack_search_len = 0;
    state.pack_search_active = false;
    if (state.pack_filtered_indices.len > 0) allocator.free(state.pack_filtered_indices);
    state.pack_filtered_indices = &.{};
    state.pack_community_loaded = false;
    state.mode = .pack_browser;
}

pub fn loadCommunityIntoPackList(allocator: std.mem.Allocator, state: *State) void {
    if (state.pack_community_loaded) return;

    const community = @import("../community.zig");
    const index = community.fetchIndexCached(allocator) catch return;
    defer community.freeIndex(allocator, index);

    if (!index.fetched or index.packs.len == 0) return;

    // Build a set of existing local pack names for dedup
    var existing = std.StringHashMap(void).init(allocator);
    defer existing.deinit();
    for (state.pack_list) |p| {
        existing.put(p.name, {}) catch {};
    }

    // Count new community packs
    var new_count: usize = 0;
    for (index.packs) |cp| {
        if (!existing.contains(cp.name)) new_count += 1;
    }

    if (new_count == 0) {
        state.pack_community_loaded = true;
        return;
    }

    // Build new combined list
    const local_count = state.pack_list.len;
    const combined = allocator.alloc(pack_mod.PackMeta, local_count + new_count) catch return;
    // Copy existing local packs
    @memcpy(combined[0..local_count], state.pack_list);
    // Free old slice (but not individual items — they're now in combined)
    allocator.free(state.pack_list);

    var ci: usize = local_count;
    for (index.packs) |cp| {
        if (existing.contains(cp.name)) continue;

        // Dupe all strings since index will be freed
        var tags_duped: []const []const u8 = &.{};
        if (cp.tags.len > 0) {
            const t_slice = allocator.alloc([]const u8, cp.tags.len) catch continue;
            var valid: usize = 0;
            for (cp.tags) |tag| {
                t_slice[valid] = allocator.dupe(u8, tag) catch continue;
                valid += 1;
            }
            tags_duped = t_slice[0..valid];
        }

        combined[ci] = .{
            .name = allocator.dupe(u8, cp.name) catch continue,
            .description = allocator.dupe(u8, cp.description) catch continue,
            .author = allocator.dupe(u8, cp.author) catch continue,
            .version = allocator.dupe(u8, cp.version) catch continue,
            .category = allocator.dupe(u8, cp.category) catch continue,
            .tags = tags_duped,
            .snippet_count = cp.snippet_count,
            .workflow_count = cp.workflow_count,
            .installed = false,
            .is_community = true,
        };
        ci += 1;
    }

    state.pack_list = combined[0..ci];
    state.pack_community_loaded = true;
}
