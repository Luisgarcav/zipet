/// Command executor — runs snippets with parameter prompting and output capture.
const std = @import("std");
const template = @import("template.zig");
const store = @import("store.zig");
const config = @import("config.zig");

pub const ExecResult = struct {
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    allocator: std.mem.Allocator,

    pub fn deinit(self: ExecResult) void {
        self.allocator.free(self.stdout);
        self.allocator.free(self.stderr);
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

/// Prompt user for parameter values, then execute the snippet command.
pub fn execute(allocator: std.mem.Allocator, snip: *const store.Snippet, cfg: config.Config) !ExecResult {
    _ = cfg;

    var param_keys = try allocator.alloc([]const u8, snip.params.len);
    defer allocator.free(param_keys);
    var param_values = try allocator.alloc([]const u8, snip.params.len);
    defer {
        for (param_values[0..snip.params.len]) |v| allocator.free(v);
        allocator.free(param_values);
    }

    for (snip.params, 0..) |p, i| {
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

        // Static options
        if (p.options) |opts| {
            printOut(allocator, "\n{s}:\n", .{p.prompt orelse p.name});
            for (opts, 1..) |opt, n| {
                const is_default = if (p.default) |d| std.mem.eql(u8, opt, d) else false;
                if (is_default) {
                    printOut(allocator, "  {d}) {s} (default)\n", .{ n, opt });
                } else {
                    printOut(allocator, "  {d}) {s}\n", .{ n, opt });
                }
            }
            printOut(allocator, "Choose (1-{d}): ", .{opts.len});

            var buf: [256]u8 = undefined;
            const input = readLine(&buf);

            if (input) |inp| {
                if (inp.len == 0) {
                    param_values[i] = try allocator.dupe(u8, p.default orelse opts[0]);
                } else {
                    const choice = std.fmt.parseInt(usize, inp, 10) catch {
                        param_values[i] = try allocator.dupe(u8, p.default orelse opts[0]);
                        continue;
                    };
                    if (choice > 0 and choice <= opts.len) {
                        param_values[i] = try allocator.dupe(u8, opts[choice - 1]);
                    } else {
                        param_values[i] = try allocator.dupe(u8, p.default orelse opts[0]);
                    }
                }
            } else {
                param_values[i] = try allocator.dupe(u8, p.default orelse opts[0]);
            }
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

    // Render the command
    const rendered = try template.render(allocator, snip.cmd, param_keys, param_values);
    defer allocator.free(rendered);

    printOut(allocator, "\n\x1b[2m$ {s}\x1b[0m\n\n", .{rendered});

    return try run(allocator, rendered);
}

/// Run a shell command and capture output.
pub fn run(allocator: std.mem.Allocator, cmd: []const u8) !ExecResult {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "/bin/sh", "-c", cmd },
    });

    return ExecResult{
        .exit_code = result.term.Exited,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .allocator = allocator,
    };
}

/// Execute in the foreground — inherits stdio.
pub fn execForeground(cmd: []const u8) !u8 {
    var child = std.process.Child.init(&.{ "/bin/sh", "-c", cmd }, std.heap.page_allocator);
    const term = try child.spawnAndWait();
    return term.Exited;
}

// ── Parallel execution ──

pub const ParallelItem = struct {
    name: []const u8,
    cmd: []const u8,
};

pub const ParallelResult = struct {
    name: []const u8,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
    duration_ms: u64,
    err: bool,
};

const ThreadContext = struct {
    item: ParallelItem,
    allocator: std.mem.Allocator,
    result: ParallelResult,
};

fn parallelWorker(ctx: *ThreadContext) void {
    var timer = std.time.Timer.start() catch {
        ctx.result = .{
            .name = ctx.item.name,
            .exit_code = 1,
            .stdout = "",
            .stderr = "",
            .duration_ms = 0,
            .err = true,
        };
        return;
    };

    const result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "/bin/sh", "-c", ctx.item.cmd },
    }) catch {
        ctx.result = .{
            .name = ctx.item.name,
            .exit_code = 1,
            .stdout = "",
            .stderr = "",
            .duration_ms = timer.read() / std.time.ns_per_ms,
            .err = true,
        };
        return;
    };

    ctx.result = .{
        .name = ctx.item.name,
        .exit_code = result.term.Exited,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .duration_ms = timer.read() / std.time.ns_per_ms,
        .err = false,
    };
}

/// Run multiple commands in parallel using threads.
/// Returns results in the same order as the input items.
pub fn runParallel(allocator: std.mem.Allocator, items: []const ParallelItem) ![]ParallelResult {
    if (items.len == 0) {
        return try allocator.alloc(ParallelResult, 0);
    }

    // Single item — just run it directly
    if (items.len == 1) {
        const results = try allocator.alloc(ParallelResult, 1);
        var ctx = ThreadContext{
            .item = items[0],
            .allocator = allocator,
            .result = undefined,
        };
        parallelWorker(&ctx);
        results[0] = ctx.result;
        return results;
    }

    // Allocate thread contexts
    var contexts = try allocator.alloc(ThreadContext, items.len);
    defer allocator.free(contexts);

    for (items, 0..) |item, i| {
        contexts[i] = .{
            .item = item,
            .allocator = allocator,
            .result = undefined,
        };
    }

    // Spawn threads
    var threads = try allocator.alloc(std.Thread, items.len);
    defer allocator.free(threads);

    for (0..items.len) |i| {
        threads[i] = try std.Thread.spawn(.{}, parallelWorker, .{&contexts[i]});
    }

    // Wait for all threads
    for (threads) |t| {
        t.join();
    }

    // Collect results
    const results = try allocator.alloc(ParallelResult, items.len);
    for (0..items.len) |i| {
        results[i] = contexts[i].result;
    }

    return results;
}

/// Free results from runParallel
pub fn freeParallelResults(allocator: std.mem.Allocator, results: []ParallelResult) void {
    for (results) |r| {
        if (!r.err) {
            allocator.free(r.stdout);
            allocator.free(r.stderr);
        }
    }
    allocator.free(results);
}
