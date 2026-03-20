# Workflow Phase 4 Features — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add dependency graphs, conditional steps, retry, capture, confirm, on_fail=ask, dry-run, and TUI runner to the workflow engine.

**Architecture:** Three new modules (`condition.zig`, `dag.zig`, `workflow_runner.zig`) plus modifications to the existing workflow engine, CLI, and TUI routing. The engine gains a `VarContext` (StringHashMap) for named variable capture, uses DAG-based step ordering, and emits events for TUI consumption. New modules are pure/testable with no global state.

**Tech Stack:** Zig, vxfw (TUI framework), TOML (existing parser), std.Thread for TUI runner.

**Spec:** `docs/superpowers/specs/2026-03-19-workflow-features-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `src/condition.zig` | Create | Expression evaluator for `when` clauses — tokenizer, parser, evaluator |
| `src/dag.zig` | Create | DAG builder, cycle detection, topological sort |
| `src/workflow.zig` | Modify | New Step fields, VarContext, retry/confirm/ask/when/capture/dry-run logic, event emission |
| `src/cli.zig` | Modify | `--dry` and `--tui` flags, updated `workflow add` wizard for new fields |
| `src/tui/widgets/workflow_runner.zig` | Create | TUI workflow runner widget (pipeline + output + controls) |
| `src/tui/root.zig` | Modify | Route `workflow_runner` mode to new widget |
| `src/tui/types.zig` | Modify | Add `workflow_runner` to Mode enum, add WorkflowEvent union type |
| `src/main.zig` | Modify | Add `_ = @import("condition.zig")` and `_ = @import("dag.zig")` to test block |

---

### Task 1: Expression Evaluator (`src/condition.zig`)

**Files:**
- Create: `src/condition.zig`
- Modify: `src/main.zig` (add test import)

- [ ] **Step 1: Write tokenizer tests**

```zig
// src/condition.zig
const std = @import("std");

pub const TokenKind = enum {
    literal,    // string value (already resolved from {{var}})
    op_eq,      // ==
    op_neq,     // !=
    op_contains, // contains
    op_empty,   // empty
    op_not_empty, // not_empty
    op_and,     // and
    op_or,      // or
    op_not,     // not
};

pub const Token = struct {
    kind: TokenKind,
    value: []const u8, // only meaningful for .literal
};

pub fn tokenize(allocator: std.mem.Allocator, expr: []const u8) ![]Token {
    _ = allocator;
    _ = expr;
    return &.{};
}

test "tokenize simple equality" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "prod == production");
    defer alloc.free(tokens);
    try std.testing.expectEqual(3, tokens.len);
    try std.testing.expectEqual(TokenKind.literal, tokens[0].kind);
    try std.testing.expectEqualStrings("prod", tokens[0].value);
    try std.testing.expectEqual(TokenKind.op_eq, tokens[1].kind);
    try std.testing.expectEqual(TokenKind.literal, tokens[2].kind);
    try std.testing.expectEqualStrings("production", tokens[2].value);
}

test "tokenize with logical operators" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "prod == production and us-east != us-west");
    defer alloc.free(tokens);
    try std.testing.expectEqual(7, tokens.len);
    try std.testing.expectEqual(TokenKind.op_and, tokens[3].kind);
}

test "tokenize empty and not_empty" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "somevalue not_empty");
    defer alloc.free(tokens);
    try std.testing.expectEqual(2, tokens.len);
    try std.testing.expectEqual(TokenKind.op_not_empty, tokens[1].kind);
}

test "tokenize not prefix" {
    const alloc = std.testing.allocator;
    const tokens = try tokenize(alloc, "not prod == staging");
    defer alloc.free(tokens);
    try std.testing.expectEqual(4, tokens.len);
    try std.testing.expectEqual(TokenKind.op_not, tokens[0].kind);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -20`
Expected: Tests fail because `tokenize` returns empty slice.

- [ ] **Step 3: Implement tokenizer**

Implement `tokenize()`: split on whitespace, map keywords (`==`, `!=`, `contains`, `empty`, `not_empty`, `and`, `or`, `not`) to their TokenKind, everything else is a `.literal`. Return allocated slice of Token.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | head -20`
Expected: All tokenizer tests pass.

- [ ] **Step 5: Write evaluator tests**

```zig
pub const VarContext = std.StringHashMap([]const u8);

/// Resolve {{var}} placeholders in expr using vars, then tokenize and evaluate.
pub fn evaluate(allocator: std.mem.Allocator, expr: []const u8, vars: *const VarContext) !bool {
    _ = allocator;
    _ = expr;
    _ = vars;
    return false;
}

test "evaluate simple equality — true" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("env", "production");
    const result = try evaluate(alloc, "{{env}} == production", &vars);
    try std.testing.expect(result);
}

test "evaluate simple equality — false" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("env", "staging");
    const result = try evaluate(alloc, "{{env}} == production", &vars);
    try std.testing.expect(!result);
}

test "evaluate not_empty" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("version", "1.0");
    try std.testing.expect(try evaluate(alloc, "{{version}} not_empty", &vars));
}

test "evaluate empty — missing var" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try std.testing.expect(try evaluate(alloc, "{{missing}} empty", &vars));
}

test "evaluate contains" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("tags", "deploy,ci,test");
    try std.testing.expect(try evaluate(alloc, "{{tags}} contains deploy", &vars));
}

test "evaluate and — both true" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("env", "prod");
    try vars.put("region", "us-east");
    try std.testing.expect(try evaluate(alloc, "{{env}} == prod and {{region}} == us-east", &vars));
}

test "evaluate and — one false" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("env", "prod");
    try vars.put("region", "eu-west");
    try std.testing.expect(!try evaluate(alloc, "{{env}} == prod and {{region}} == us-east", &vars));
}

test "evaluate or" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("debug", "false");
    try vars.put("verbose", "true");
    try std.testing.expect(try evaluate(alloc, "{{debug}} == true or {{verbose}} == true", &vars));
}

test "evaluate not" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("skip", "false");
    try std.testing.expect(try evaluate(alloc, "not {{skip}} == true", &vars));
}

test "evaluate precedence — not binds tighter than or" {
    // not {{a}} == 1 or {{b}} == 2  →  ((not (a==1)) or (b==2))
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("a", "1");
    try vars.put("b", "2");
    // not (1==1) = false, (2==2) = true → false or true = true
    try std.testing.expect(try evaluate(alloc, "not {{a}} == 1 or {{b}} == 2", &vars));
}

test "evaluate numeric comparison" {
    const alloc = std.testing.allocator;
    var vars = VarContext.init(alloc);
    defer vars.deinit();
    try vars.put("exit", "0");
    try std.testing.expect(try evaluate(alloc, "{{exit}} != 0", &vars) == false);
}
```

- [ ] **Step 6: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -20`
Expected: Evaluator tests fail.

- [ ] **Step 7: Implement evaluator**

Implement `evaluate()`:
1. Resolve `{{var}}` placeholders: scan for `{{`, find `}}`, look up var in `VarContext`, replace with value (or empty string if missing). Use an allocated buffer.
2. Call `tokenize()` on the resolved expression.
3. Parse with precedence: `parseOr() -> parseAnd() -> parseNot() -> parseComparison()`.
   - `parseComparison()`: consume literal, then check for `==`/`!=`/`contains`/`empty`/`not_empty`.
   - `parseNot()`: if next token is `not`, consume and negate `parseComparison()`.
   - `parseAnd()`: `parseNot()` then while `and` → `parseNot()`, combine with AND.
   - `parseOr()`: `parseAnd()` then while `or` → `parseAnd()`, combine with OR.

- [ ] **Step 8: Run tests to verify they pass**

Run: `zig build test 2>&1 | head -20`
Expected: All condition tests pass.

- [ ] **Step 9: Add test import to main.zig**

Add `_ = @import("condition.zig");` to the test block in `src/main.zig`.

- [ ] **Step 10: Commit**

```bash
git add src/condition.zig src/main.zig
git commit -m "feat(workflow): add expression evaluator for when clauses"
```

---

### Task 2: DAG Module (`src/dag.zig`)

**Files:**
- Create: `src/dag.zig`
- Modify: `src/main.zig` (add test import)

- [ ] **Step 1: Write DAG tests**

```zig
// src/dag.zig
const std = @import("std");

pub const Node = struct {
    name: []const u8,
    index: usize,
    depends_on: []const []const u8, // explicit dependencies (step names)
};

pub const GraphError = error{
    CycleDetected,
    UnknownDependency,
};

/// Build execution order from nodes. Steps without explicit depends_on
/// depend on the previous step (index - 1). Step 0 with no depends_on has
/// no dependencies. Returns indices in topological order.
pub fn topologicalSort(
    allocator: std.mem.Allocator,
    nodes: []const Node,
) ![]usize {
    _ = allocator;
    _ = nodes;
    return &.{};
}

test "toposort — sequential (no depends_on)" {
    const alloc = std.testing.allocator;
    const nodes = &[_]Node{
        .{ .name = "a", .index = 0, .depends_on = &.{} },
        .{ .name = "b", .index = 1, .depends_on = &.{} },
        .{ .name = "c", .index = 2, .depends_on = &.{} },
    };
    const order = try topologicalSort(alloc, nodes);
    defer alloc.free(order);
    // Implicit deps: b→a, c→b. Order: 0, 1, 2
    try std.testing.expectEqual(3, order.len);
    try std.testing.expectEqual(@as(usize, 0), order[0]);
    try std.testing.expectEqual(@as(usize, 1), order[1]);
    try std.testing.expectEqual(@as(usize, 2), order[2]);
}

test "toposort — explicit depends_on reorders" {
    const alloc = std.testing.allocator;
    // build(0) → test(1, implicit dep on build) → package(2, depends_on build) → deploy(3, depends_on test+package)
    const nodes = &[_]Node{
        .{ .name = "build", .index = 0, .depends_on = &.{} },
        .{ .name = "test", .index = 1, .depends_on = &.{} },
        .{ .name = "package", .index = 2, .depends_on = &.{"build"} },
        .{ .name = "deploy", .index = 3, .depends_on = &.{ "test", "package" } },
    };
    const order = try topologicalSort(alloc, nodes);
    defer alloc.free(order);
    try std.testing.expectEqual(4, order.len);
    // build must be first, deploy must be last
    try std.testing.expectEqual(@as(usize, 0), order[0]); // build
    // test and package can be in any order, but deploy must be after both
    try std.testing.expectEqual(@as(usize, 3), order[3]); // deploy
}

test "toposort — cycle detected" {
    const alloc = std.testing.allocator;
    const nodes = &[_]Node{
        .{ .name = "a", .index = 0, .depends_on = &.{"b"} },
        .{ .name = "b", .index = 1, .depends_on = &.{"a"} },
    };
    const result = topologicalSort(alloc, nodes);
    try std.testing.expectError(GraphError.CycleDetected, result);
}

test "toposort — unknown dependency" {
    const alloc = std.testing.allocator;
    const nodes = &[_]Node{
        .{ .name = "a", .index = 0, .depends_on = &.{"nonexistent"} },
    };
    const result = topologicalSort(alloc, nodes);
    try std.testing.expectError(GraphError.UnknownDependency, result);
}

test "toposort — single step no deps" {
    const alloc = std.testing.allocator;
    const nodes = &[_]Node{
        .{ .name = "only", .index = 0, .depends_on = &.{} },
    };
    const order = try topologicalSort(alloc, nodes);
    defer alloc.free(order);
    try std.testing.expectEqual(1, order.len);
    try std.testing.expectEqual(@as(usize, 0), order[0]);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | head -20`
Expected: Tests fail.

- [ ] **Step 3: Implement topologicalSort**

Implementation approach:
1. Build adjacency list: for each node, if it has `depends_on`, resolve names to indices; if not and index > 0, add implicit edge from index-1.
2. Validate: unknown dependency names → `GraphError.UnknownDependency`.
3. Kahn's algorithm: compute in-degrees, BFS from nodes with in-degree 0, detect cycle if result length != node count.
4. Return allocated slice of indices in topological order.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | head -20`
Expected: All DAG tests pass.

- [ ] **Step 5: Write `dependentsOf` function + tests**

```zig
/// Given a node index, return all indices that transitively depend on it.
/// Used to mark dependents as skipped when a step fails with on_fail=stop.
pub fn dependentsOf(
    allocator: std.mem.Allocator,
    nodes: []const Node,
    failed_index: usize,
) ![]usize {
    // ...
}

test "dependentsOf — transitive" {
    const alloc = std.testing.allocator;
    const nodes = &[_]Node{
        .{ .name = "build", .index = 0, .depends_on = &.{} },
        .{ .name = "test", .index = 1, .depends_on = &.{} },  // implicit dep on build
        .{ .name = "deploy", .index = 2, .depends_on = &.{"test"} },
    };
    const deps = try dependentsOf(alloc, nodes, 0);
    defer alloc.free(deps);
    // build fails → test (depends on build) and deploy (depends on test) are affected
    try std.testing.expectEqual(2, deps.len);
}
```

- [ ] **Step 6: Implement dependentsOf, run tests**

Run: `zig build test 2>&1 | head -20`
Expected: Pass.

- [ ] **Step 7: Add test import to main.zig and commit**

Add `_ = @import("dag.zig");` to the test block in `src/main.zig`.

```bash
git add src/dag.zig src/main.zig
git commit -m "feat(workflow): add DAG module for dependency graph resolution"
```

---

### Task 3: Extend Step Data Model

**Files:**
- Modify: `src/workflow.zig:11-46` (OnFail enum, Step struct, Workflow struct)

- [ ] **Step 1: Add `ask` to OnFail enum**

```zig
pub const OnFail = enum {
    stop,
    @"continue",
    skip_rest,
    ask,

    pub fn fromString(s: []const u8) OnFail {
        if (std.mem.eql(u8, s, "continue")) return .@"continue";
        if (std.mem.eql(u8, s, "skip_rest")) return .skip_rest;
        if (std.mem.eql(u8, s, "ask")) return .ask;
        return .stop;
    }
};
```

- [ ] **Step 2: Add new fields to Step struct**

```zig
pub const Step = struct {
    name: []const u8,
    cmd: ?[]const u8,
    snippet_ref: ?[]const u8,
    on_fail: OnFail,
    param_overrides: []const ParamOverride,
    // New fields:
    capture: ?[]const u8 = null,
    depends_on: []const []const u8 = &.{},
    when: ?[]const u8 = null,
    retry: u8 = 0,
    retry_delay: u16 = 0,
    confirm: bool = false,

    pub const ParamOverride = struct {
        key: []const u8,
        value: []const u8,
    };
};
```

- [ ] **Step 3: Verify project compiles**

Run: `zig build 2>&1 | head -20`
Expected: Compiles (new fields have defaults, so existing code is unaffected).

- [ ] **Step 4: Commit**

```bash
git add src/workflow.zig
git commit -m "feat(workflow): add new Step fields (capture, depends_on, when, retry, confirm)"
```

---

### Task 4: TOML Parsing & Serialization of New Fields

**Files:**
- Modify: `src/workflow.zig:484-706` (loadWorkflowFile, saveWorkflow)

- [ ] **Step 1: Update loadWorkflowFile to parse new fields**

In the step-parsing loop (around line 544-576), after parsing `on_fail`, add parsing for:
- `capture`: `table.getString("workflows.<name>.steps.<N>.capture")`
- `depends_on`: `table.getArray("workflows.<name>.steps.<N>.depends_on")` → collect string values
- `when`: `table.getString("workflows.<name>.steps.<N>.when")`
- `retry`: `table.getString("workflows.<name>.steps.<N>.retry")` → parse to u8
- `retry_delay`: `table.getString("workflows.<name>.steps.<N>.retry_delay")` → parse to u16
- `confirm`: `table.getString("workflows.<name>.steps.<N>.confirm")` → equals "true"

Allocate and dupe all string values. For `depends_on`, build an `ArrayList([]const u8)`, collect strings, then `toOwnedSlice`.

- [ ] **Step 2: Update saveWorkflow to serialize new fields**

In the step-writing loop (around line 785-803), after writing `on_fail`, add:
```zig
if (step.capture) |cap| {
    try writer.print("capture = \"{s}\"\n", .{cap});
}
if (step.depends_on.len > 0) {
    try writer.writeAll("depends_on = [");
    for (step.depends_on, 0..) |dep, di| {
        if (di > 0) try writer.writeAll(", ");
        try writer.print("\"{s}\"", .{dep});
    }
    try writer.writeAll("]\n");
}
if (step.when) |w| {
    try writer.print("when = \"{s}\"\n", .{w});
}
if (step.retry > 0) {
    try writer.print("retry = {d}\n", .{step.retry});
    if (step.retry_delay > 0) {
        try writer.print("retry_delay = {d}\n", .{step.retry_delay});
    }
}
if (step.confirm) {
    try writer.writeAll("confirm = true\n");
}
```

- [ ] **Step 3: Update on_fail serialization to handle `ask`**

In `saveWorkflow`, update the `on_fail_str` switch to include:
```zig
.ask => "ask",
```

- [ ] **Step 4: Update deinitRegistry to free new fields**

In `deinitRegistry` (around line 748), after freeing `step.name`/`cmd`/`snippet_ref`, add:
```zig
if (step.capture) |c| allocator.free(c);
if (step.when) |w| allocator.free(w);
for (step.depends_on) |dep| allocator.free(dep);
if (step.depends_on.len > 0) allocator.free(step.depends_on);
```

Also update the duplicate-cleanup block (around line 669-682) with the same frees.

- [ ] **Step 5: Verify project compiles and existing tests pass**

Run: `zig build test 2>&1 | head -20`
Expected: Pass.

- [ ] **Step 6: Commit**

```bash
git add src/workflow.zig
git commit -m "feat(workflow): parse and serialize new Step fields from TOML"
```

---

### Task 5: VarContext & Capture in Workflow Engine

**Files:**
- Modify: `src/workflow.zig:96-212` (executeSilent) and `src/workflow.zig:214-473` (execute)

- [ ] **Step 1: Add VarContext type and integrate into executeSilent**

Replace `prev_stdout`/`prev_exit` tracking with a `VarContext` (StringHashMap):

```zig
// At top of executeSilent, after step_results declaration:
var var_ctx = std.StringHashMap([]const u8).init(allocator);
defer {
    var vit = var_ctx.iterator();
    while (vit.next()) |entry| {
        allocator.free(entry.value_ptr.*);
    }
    var_ctx.deinit();
}
```

- After step execution, if `step.capture != null` and `result.exit_code == 0`:
```zig
if (step.capture) |cap_name| {
    if (result.exit_code == 0) {
        const trimmed = std.mem.trim(u8, result.stdout, "\n\r \t");
        const owned = try allocator.dupe(u8, trimmed);
        // Remove old value if exists
        if (var_ctx.fetchRemove(cap_name)) |old| {
            allocator.free(old.value);
        }
        try var_ctx.put(cap_name, owned);
    }
}
```

- When building `all_keys`/`all_vals` for template rendering, include `var_ctx` entries alongside `prev_stdout`/`prev_exit`.

- [ ] **Step 2: Apply same changes to execute()**

Mirror the VarContext integration in `execute()` (the interactive version).

- [ ] **Step 3: Verify project compiles and tests pass**

Run: `zig build test 2>&1 | head -20`
Expected: Pass.

- [ ] **Step 4: Commit**

```bash
git add src/workflow.zig
git commit -m "feat(workflow): add VarContext for captured variables"
```

---

### Task 6: Retry Logic

**Files:**
- Modify: `src/workflow.zig` (execute and executeSilent functions)

- [ ] **Step 1: Add retry loop in executeSilent**

Wrap the `executor.run()` call and result handling in a retry loop:

```zig
var attempt: u8 = 0;
const max_attempts: u8 = step.retry + 1; // 1 initial + N retries
var result: ExecResult = undefined;

while (attempt < max_attempts) : (attempt += 1) {
    if (attempt > 0 and step.retry_delay > 0) {
        std.time.sleep(@as(u64, step.retry_delay) * std.time.ns_per_s);
    }
    result = try executor.run(allocator, rendered);
    if (result.exit_code == 0) break;
    if (attempt + 1 < max_attempts) {
        // Will retry — free this result
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }
}
```

Then use `result` for the rest of the step handling as before.

- [ ] **Step 2: Add retry loop in execute() with user feedback**

Same retry logic but with printed output:

```zig
if (attempt > 0) {
    if (step.retry_delay > 0) {
        printOut(allocator, "  \x1b[33m⟳ Retry {d}/{d} for \"{s}\" (waiting {d}s...)\x1b[0m\n",
            .{ attempt, step.retry, step.name, step.retry_delay });
        std.time.sleep(@as(u64, step.retry_delay) * std.time.ns_per_s);
    } else {
        printOut(allocator, "  \x1b[33m⟳ Retry {d}/{d} for \"{s}\"\x1b[0m\n",
            .{ attempt, step.retry, step.name });
    }
}
```

- [ ] **Step 3: Verify project compiles**

Run: `zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 4: Commit**

```bash
git add src/workflow.zig
git commit -m "feat(workflow): add retry logic with configurable delay"
```

---

### Task 7: Confirm Step & on_fail="ask"

**Files:**
- Modify: `src/workflow.zig` (execute function)

- [ ] **Step 1: Add confirm logic before step execution in execute()**

Before the command is executed (after rendering, before `executor.run()`):

```zig
if (step.confirm) {
    printOut(allocator, "  \x1b[33m⏸ Step \"{s}\" — proceed? [y/N]\x1b[0m ", .{step.name});
    var confirm_buf: [8]u8 = undefined;
    const confirm_input = readLine(&confirm_buf);
    if (confirm_input) |inp| {
        if (!std.mem.eql(u8, inp, "y") and !std.mem.eql(u8, inp, "Y")) {
            // User declined — skip step
            printOut(allocator, "  \x1b[2m⊘ Skipped by user\x1b[0m\n\n", .{});
            try step_results.append(allocator, .{
                .step_name = step.name,
                .exit_code = 0,
                .stdout = try allocator.dupe(u8, ""),
                .stderr = try allocator.dupe(u8, ""),
                .skipped = true,
            });
            continue; // next step
        }
    } else {
        // No input (pipe/no TTY) — fail
        // ... append failed result, handle on_fail
    }
}
```

- [ ] **Step 2: Add on_fail="ask" handling after step failure in execute()**

In the failure handling switch block, add the `.ask` case:

```zig
.ask => {
    while (true) {
        printOut(allocator, "\x1b[31m✗ Step \"{s}\" failed (exit {d}). [r]etry / [s]kip / [a]bort?\x1b[0m ",
            .{ step.name, result.exit_code });
        var ask_buf: [8]u8 = undefined;
        const ask_input = readLine(&ask_buf);
        if (ask_input) |inp| {
            if (std.mem.eql(u8, inp, "r")) {
                // Re-execute the step
                allocator.free(result.stdout);
                allocator.free(result.stderr);
                result = try executor.run(allocator, rendered);
                if (result.exit_code == 0) {
                    // Retry succeeded — continue normally
                    printOut(allocator, "  \x1b[32m✓ OK on retry\x1b[0m\n\n", .{});
                    break;
                }
                continue; // ask again
            } else if (std.mem.eql(u8, inp, "s")) {
                printOut(allocator, "\x1b[33m⏭ Skipping step\x1b[0m\n", .{});
                break; // continue to next step
            } else if (std.mem.eql(u8, inp, "a")) {
                printOut(allocator, "\x1b[31m⏹ Workflow aborted\x1b[0m\n", .{});
                break; // break out of step loop too (need outer break)
            }
        } else {
            // No TTY — behave as stop
            printOut(allocator, "\x1b[31m⏹ Workflow stopped (non-interactive)\x1b[0m\n", .{});
            break;
        }
    }
},
```

Note: The "abort" case needs to also break the outer step loop. Use a `var should_abort = false;` flag checked after the switch.

- [ ] **Step 3: Handle confirm and ask in executeSilent**

In `executeSilent` (non-interactive):
- `confirm = true` → fail the step (exit_code = 1, stderr = "confirm required but non-interactive").
- `on_fail = .ask` → behave as `.stop`.

- [ ] **Step 4: Verify project compiles**

Run: `zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 5: Commit**

```bash
git add src/workflow.zig
git commit -m "feat(workflow): add confirm step and on_fail=ask interactive recovery"
```

---

### Task 8: DAG Integration in Workflow Engine

**Files:**
- Modify: `src/workflow.zig` (execute and executeSilent)

- [ ] **Step 1: Import dag module**

Add at top of `workflow.zig`:
```zig
const dag = @import("dag.zig");
```

- [ ] **Step 2: Build DAG nodes from steps and get execution order**

At the start of execution (before the step loop), build DAG nodes and sort:

```zig
// Build DAG nodes
var dag_nodes = try allocator.alloc(dag.Node, wf.steps.len);
defer allocator.free(dag_nodes);
for (wf.steps, 0..) |step, i| {
    dag_nodes[i] = .{
        .name = step.name,
        .index = i,
        .depends_on = step.depends_on,
    };
}

const exec_order = dag.topologicalSort(allocator, dag_nodes) catch |err| switch (err) {
    dag.GraphError.CycleDetected => {
        printOut(allocator, "\x1b[31m✗ Workflow has circular dependencies\x1b[0m\n", .{});
        return WorkflowResult{ .step_results = &.{}, .success = false, .allocator = allocator };
    },
    dag.GraphError.UnknownDependency => {
        printOut(allocator, "\x1b[31m✗ Workflow references unknown step in depends_on\x1b[0m\n", .{});
        return WorkflowResult{ .step_results = &.{}, .success = false, .allocator = allocator };
    },
    else => return err,
};
defer allocator.free(exec_order);
```

- [ ] **Step 3: Replace sequential loop with DAG-ordered loop**

Change `for (wf.steps, 0..) |step, step_idx|` to:
```zig
for (exec_order) |step_idx| {
    const step = wf.steps[step_idx];
    // ... rest of step execution
}
```

- [ ] **Step 4: Add failure propagation — skip dependents on stop**

When a step fails with `on_fail = .stop`, mark all transitive dependents as skipped:

```zig
.stop => {
    // Mark all dependents as skipped
    const dependents = try dag.dependentsOf(allocator, dag_nodes, step_idx);
    defer allocator.free(dependents);
    for (dependents) |dep_idx| {
        try step_results.append(allocator, .{
            .step_name = wf.steps[dep_idx].name,
            .exit_code = 0,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, ""),
            .skipped = true,
        });
    }
    // Track skipped indices to skip them in the loop
}
```

Use a `skipped_set` (a boolean array or hash set) to track which step indices to skip in the main loop.

- [ ] **Step 5: Apply same changes to executeSilent**

- [ ] **Step 6: Verify project compiles and tests pass**

Run: `zig build test 2>&1 | head -20`
Expected: Pass.

- [ ] **Step 7: Commit**

```bash
git add src/workflow.zig
git commit -m "feat(workflow): integrate DAG-based execution order with failure propagation"
```

---

### Task 9: When Clause Integration

**Files:**
- Modify: `src/workflow.zig` (execute and executeSilent)

- [ ] **Step 1: Import condition module**

Add at top of `workflow.zig`:
```zig
const condition = @import("condition.zig");
```

- [ ] **Step 2: Add when evaluation before step execution**

After resolving the step command but before confirm/execute, add:

```zig
if (step.when) |when_expr| {
    const should_run = condition.evaluate(allocator, when_expr, &var_ctx) catch |err| {
        printOut(allocator, "  \x1b[31m✗ Error evaluating when clause: {}\x1b[0m\n\n", .{err});
        // Treat evaluation error as "skip"
        try step_results.append(allocator, .{
            .step_name = step.name,
            .exit_code = 0,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, "when evaluation error"),
            .skipped = true,
        });
        continue;
    };
    if (!should_run) {
        printOut(allocator, "  \x1b[2m⊘ Skipped (when: {s})\x1b[0m\n\n", .{when_expr});
        try step_results.append(allocator, .{
            .step_name = step.name,
            .exit_code = 0,
            .stdout = try allocator.dupe(u8, ""),
            .stderr = try allocator.dupe(u8, ""),
            .skipped = true,
        });
        continue; // No capture occurs for skipped steps
    }
}
```

Note: The `var_ctx` must include `prev_stdout`, `prev_exit`, workflow params, and all captured variables for the `when` expression to reference them.

- [ ] **Step 3: Apply same to executeSilent**

- [ ] **Step 4: Verify project compiles**

Run: `zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 5: Commit**

```bash
git add src/workflow.zig
git commit -m "feat(workflow): evaluate when clauses before step execution"
```

---

### Task 10: Dry-Run Mode

**Files:**
- Modify: `src/workflow.zig` (new function)
- Modify: `src/cli.zig` (add --dry flag)

- [ ] **Step 1: Add executeDryRun function to workflow.zig**

```zig
/// Display what a workflow would do without executing.
pub fn executeDryRun(
    allocator: std.mem.Allocator,
    wf: *const Workflow,
    snip_store: *store.Store,
) !void {
    // Build DAG and get execution order
    var dag_nodes = try allocator.alloc(dag.Node, wf.steps.len);
    defer allocator.free(dag_nodes);
    for (wf.steps, 0..) |step, i| {
        dag_nodes[i] = .{ .name = step.name, .index = i, .depends_on = step.depends_on };
    }

    const exec_order = dag.topologicalSort(allocator, dag_nodes) catch |err| switch (err) {
        dag.GraphError.CycleDetected => {
            printOut(allocator, "\x1b[31m✗ Workflow has circular dependencies\x1b[0m\n", .{});
            return;
        },
        dag.GraphError.UnknownDependency => {
            printOut(allocator, "\x1b[31m✗ Unknown step in depends_on\x1b[0m\n", .{});
            return;
        },
        else => return err,
    };
    defer allocator.free(exec_order);

    printOut(allocator, "\n\x1b[1;36m━━━ Dry Run: {s} ({d} steps) ━━━\x1b[0m\n\n", .{ wf.name, wf.steps.len });

    for (exec_order, 0..) |step_idx, display_num| {
        const step = wf.steps[step_idx];
        printOut(allocator, "\x1b[1m[dry] Step {d}: \"{s}\"\x1b[0m\n", .{ display_num + 1, step.name });

        // Show command
        if (step.cmd) |cmd| {
            printOut(allocator, "      cmd: {s}\n", .{cmd});
        } else if (step.snippet_ref) |ref| {
            const snip = findSnippet(snip_store, ref);
            if (snip) |s| {
                printOut(allocator, "      snippet: {s} → {s}\n", .{ ref, s.cmd });
            } else {
                printOut(allocator, "      snippet: {s} (not found!)\n", .{ref});
            }
        }

        // Show on_fail
        const on_fail_str: []const u8 = switch (step.on_fail) {
            .stop => "stop", .@"continue" => "continue", .skip_rest => "skip_rest", .ask => "ask",
        };
        printOut(allocator, "      on_fail: {s}\n", .{on_fail_str});

        // Show new fields if set
        if (step.retry > 0) {
            printOut(allocator, "      retry: {d} (delay: {d}s)\n", .{ step.retry, step.retry_delay });
        }
        if (step.when) |w| {
            printOut(allocator, "      when: {s} → (not evaluated)\n", .{w});
        }
        if (step.depends_on.len > 0) {
            printOut(allocator, "      depends_on: [", .{});
            for (step.depends_on, 0..) |dep, di| {
                if (di > 0) printOut(allocator, ", ", .{});
                printOut(allocator, "{s}", .{dep});
            }
            printOut(allocator, "]\n", .{});
        }
        if (step.capture) |cap| {
            printOut(allocator, "      capture: {{{{s}}}} (pending)\n", .{cap});
        }
        if (step.confirm) {
            printOut(allocator, "      confirm: true\n", .{});
        }
        writeOut("\n");
    }
}
```

- [ ] **Step 2: Add --dry flag to CLI**

In `src/cli.zig`, in the `workflow run` command handler, check for `--dry` in args. If present, call `executeDryRun()` instead of `execute()`.

Find where `workflow run` is handled (look for the command dispatch that calls `workflow.execute()`), and add before it:

```zig
// Check for --dry flag
var dry_run = false;
for (remaining_args) |arg| {
    if (std.mem.eql(u8, arg, "--dry")) {
        dry_run = true;
        break;
    }
}

if (dry_run) {
    try workflow.executeDryRun(allocator, wf, &snip_store);
    return;
}
```

- [ ] **Step 3: Verify project compiles**

Run: `zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 4: Commit**

```bash
git add src/workflow.zig src/cli.zig
git commit -m "feat(workflow): add dry-run mode (--dry flag)"
```

---

### Task 11: CLI Wizard Updates

**Files:**
- Modify: `src/cli.zig` (workflow add wizard)

- [ ] **Step 1: Find the workflow add wizard in cli.zig**

Search for the section that collects step data in the interactive wizard (where it asks for step name, type cmd/snippet, command text, on_fail).

- [ ] **Step 2: Add prompts for new step fields after on_fail**

After the on_fail prompt for each step, add:

```zig
// Capture variable
printOut(allocator, "  Capture stdout to variable (empty to skip): ", .{});
var cap_buf: [128]u8 = undefined;
const cap_input = readLine(&cap_buf);
const capture: ?[]const u8 = if (cap_input) |inp| (if (inp.len > 0) try allocator.dupe(u8, inp) else null) else null;

// When condition
printOut(allocator, "  When condition (empty for always): ", .{});
var when_buf: [256]u8 = undefined;
const when_input = readLine(&when_buf);
const when: ?[]const u8 = if (when_input) |inp| (if (inp.len > 0) try allocator.dupe(u8, inp) else null) else null;

// Retry
printOut(allocator, "  Retry count (0 for none): ", .{});
var retry_buf: [8]u8 = undefined;
const retry_input = readLine(&retry_buf);
const retry: u8 = if (retry_input) |inp| (std.fmt.parseInt(u8, inp, 10) catch 0) else 0;

var retry_delay: u16 = 0;
if (retry > 0) {
    printOut(allocator, "  Retry delay in seconds (0 for none): ", .{});
    var delay_buf: [8]u8 = undefined;
    const delay_input = readLine(&delay_buf);
    retry_delay = if (delay_input) |inp| (std.fmt.parseInt(u16, inp, 10) catch 0) else 0;
}

// Confirm
printOut(allocator, "  Require confirmation before running? [y/N]: ", .{});
var confirm_buf: [8]u8 = undefined;
const confirm_input = readLine(&confirm_buf);
const confirm = if (confirm_input) |inp| (std.mem.eql(u8, inp, "y") or std.mem.eql(u8, inp, "Y")) else false;

// Depends on
printOut(allocator, "  Depends on steps (comma-separated names, empty for sequential): ", .{});
var deps_buf: [256]u8 = undefined;
const deps_input = readLine(&deps_buf);
var depends_on: []const []const u8 = &.{};
if (deps_input) |inp| {
    if (inp.len > 0) {
        // Parse comma-separated list
        var deps_list: std.ArrayList([]const u8) = .{};
        var iter = std.mem.splitScalar(u8, inp, ',');
        while (iter.next()) |dep| {
            const trimmed = std.mem.trim(u8, dep, " ");
            if (trimmed.len > 0) {
                try deps_list.append(allocator, try allocator.dupe(u8, trimmed));
            }
        }
        depends_on = try deps_list.toOwnedSlice(allocator);
    }
}
```

Then include these fields in the Step struct literal when appending to the steps list.

- [ ] **Step 3: Verify project compiles**

Run: `zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 4: Commit**

```bash
git add src/cli.zig
git commit -m "feat(cli): add prompts for new workflow step fields in wizard"
```

---

### Task 12: Workflow Event System

**Files:**
- Modify: `src/tui/types.zig` (add new types)
- Modify: `src/workflow.zig` (add event emission)

- [ ] **Step 1: Add WorkflowEvent type to types.zig**

```zig
pub const WorkflowEvent = union(enum) {
    step_started: StepEventInfo,
    step_completed: StepCompletedInfo,
    step_failed: StepCompletedInfo,
    step_skipped: StepSkippedInfo,
    confirm_requested: StepEventInfo,
    ask_requested: StepFailedAskInfo,
    retry_started: RetryInfo,
    workflow_done: WorkflowDoneInfo,
    output_line: OutputLineInfo,

    pub const StepEventInfo = struct {
        name: []const u8,
        index: usize,
    };
    pub const StepCompletedInfo = struct {
        name: []const u8,
        index: usize,
        exit_code: u8,
        duration_ms: u64,
    };
    pub const StepSkippedInfo = struct {
        name: []const u8,
        index: usize,
        reason: []const u8,
    };
    pub const StepFailedAskInfo = struct {
        name: []const u8,
        index: usize,
        exit_code: u8,
    };
    pub const RetryInfo = struct {
        name: []const u8,
        index: usize,
        attempt: u8,
        max_attempts: u8,
    };
    pub const WorkflowDoneInfo = struct {
        success: bool,
    };
    pub const OutputLineInfo = struct {
        text: []const u8,
        is_stderr: bool,
    };
};
```

- [ ] **Step 2: Add `workflow_runner` to Mode enum**

```zig
pub const Mode = enum {
    // ... existing modes ...
    workflow_runner,
};
```

- [ ] **Step 3: Add WorkflowRunnerState to State struct**

```zig
pub const WorkflowRunnerState = struct {
    workflow_name: []const u8 = "",
    total_steps: usize = 0,
    events: std.ArrayList(WorkflowEvent) = undefined,
    user_response: ?u8 = null, // 'r', 's', 'a', 'y', 'n'
    is_running: bool = false,

    pub fn init(alloc: std.mem.Allocator) WorkflowRunnerState {
        return .{ .events = std.ArrayList(WorkflowEvent).init(alloc) };
    }
    pub fn deinit(self: *WorkflowRunnerState) void {
        self.events.deinit();
    }
};
```

Add `wf_runner: WorkflowRunnerState` to the State struct. Initialize it in `root.zig:run()` alongside `state.output` using `WorkflowRunnerState.init(allocator)`. Call `state.wf_runner.deinit()` in cleanup.

- [ ] **Step 4: Define EventCallback type in workflow.zig**

```zig
pub const EventCallback = *const fn (WorkflowEvent) void;
// Where WorkflowEvent = @import("tui/types.zig").WorkflowEvent;
```

This will be used by the TUI runner to receive events from the engine.

- [ ] **Step 5: Commit**

```bash
git add src/tui/types.zig src/workflow.zig
git commit -m "feat(workflow): add event system types for TUI runner"
```

---

### Task 13: Workflow Runner TUI Widget

**Files:**
- Create: `src/tui/widgets/workflow_runner.zig`
- Modify: `src/tui/root.zig` (add routing)

- [ ] **Step 1: Create widget scaffold**

```zig
// src/tui/widgets/workflow_runner.zig
const std = @import("std");
const vxfw = @import("vaxis").vxfw;
const vaxis = @import("vaxis");
const t = @import("../types.zig");
const config = @import("../../config.zig");

const WorkflowRunner = @This();

state: *t.State,
cfg: config.Config,
scroll_offset: usize = 0,

const StepStatus = enum { pending, running, completed, failed, skipped };

const StepDisplay = struct {
    name: []const u8,
    status: StepStatus,
    duration_ms: u64,
    exit_code: u8,
};

pub fn widget(self: *WorkflowRunner) vxfw.Widget {
    return .{
        .userdata = self,
        .eventHandler = handleEvent,
        .drawFn = draw,
    };
}

fn handleEvent(userdata: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
    const self: *WorkflowRunner = @ptrCast(@alignCast(userdata));
    _ = self;

    switch (event) {
        .key_press => |key| {
            if (key.codepoint) |cp| {
                switch (cp) {
                    'q' => {
                        // Cancel and quit
                        self.state.mode = .normal;
                        ctx.consumeAndRedraw();
                    },
                    'r' => {
                        // Retry failed step
                        self.state.wf_runner.user_response = 'r';
                        ctx.consumeAndRedraw();
                    },
                    's' => {
                        // Skip failed step
                        self.state.wf_runner.user_response = 's';
                        ctx.consumeAndRedraw();
                    },
                    'c', 'a' => {
                        // Cancel/abort
                        self.state.wf_runner.user_response = 'a';
                        ctx.consumeAndRedraw();
                    },
                    'y' => {
                        self.state.wf_runner.user_response = 'y';
                        ctx.consumeAndRedraw();
                    },
                    'n' => {
                        self.state.wf_runner.user_response = 'n';
                        ctx.consumeAndRedraw();
                    },
                    'j' => {
                        self.scroll_offset +|= 1;
                        ctx.consumeAndRedraw();
                    },
                    'k' => {
                        self.scroll_offset -|= 1;
                        ctx.consumeAndRedraw();
                    },
                    else => {},
                }
            }
        },
        else => {},
    }
}

fn draw(userdata: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
    const self: *WorkflowRunner = @ptrCast(@alignCast(userdata));
    _ = self;

    // Build the three-panel layout:
    // 1. Pipeline panel (step list with status icons)
    // 2. Output panel (live stdout/stderr)
    // 3. Controls bar

    const max_w = ctx.max.width orelse 80;
    const max_h = ctx.max.height orelse 24;

    var surface = try vxfw.Surface.init(ctx.arena, self.widget(), max_w, max_h);

    // TODO: Render pipeline steps, output, and controls
    // This will be filled in during implementation

    return surface;
}
```

- [ ] **Step 2: Implement pipeline panel rendering**

Draw each step as a line with status icon, name, dots, and status text:
- `✓` (green) for completed
- `✗` (red) for failed
- `●` (yellow) for running
- `○` (dim) for pending
- `⊘` (dim) for skipped

Use the events stored in `state.wf_runner.events` to determine each step's status.

- [ ] **Step 3: Implement output panel**

Reuse the `OutputView` widget pattern or render output lines directly from events with `output_line` type.

- [ ] **Step 4: Implement controls bar**

Render `[r] retry  [s] skip  [c] cancel  [q] quit` at the bottom. Highlight active controls based on whether a step is in failed/confirm/ask state.

- [ ] **Step 5: Add routing in root.zig**

In `src/tui/root.zig`:
- Import `workflow_runner` module
- Add `WorkflowRunner` widget instance to ZipetRoot struct
- In `handleEvent()`, add `.workflow_runner` case that dispatches to the widget
- In `draw()`, add `.workflow_runner` case that draws the widget

- [ ] **Step 6: Verify project compiles**

Run: `zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 7: Commit**

```bash
git add src/tui/widgets/workflow_runner.zig src/tui/root.zig
git commit -m "feat(tui): add workflow runner widget with pipeline view and controls"
```

---

### Task 14: Wire TUI Runner to Engine (Threading)

**Files:**
- Modify: `src/workflow.zig` (add executeWithEvents function)
- Modify: `src/tui/widgets/workflow_runner.zig` (spawn engine thread)
- Modify: `src/cli.zig` (add --tui flag)

- [ ] **Step 1: Add executeWithEvents to workflow.zig**

A new execution function that emits events instead of printing to stdout. It takes an event callback and a response-polling callback:

```zig
pub fn executeWithEvents(
    allocator: std.mem.Allocator,
    wf: *const Workflow,
    snip_store: *store.Store,
    param_keys: []const []const u8,
    param_values: []const []const u8,
    event_queue: *std.ArrayList(t.WorkflowEvent),
    event_mutex: *std.Thread.Mutex,
    response_ptr: *?u8,
) !WorkflowResult {
    // Same logic as executeSilent but:
    // 1. Instead of printOut, push WorkflowEvent to event_queue (under mutex)
    // 2. For confirm/ask, poll response_ptr until non-null
    // 3. After each step, emit step_completed/step_failed events
}
```

- [ ] **Step 2: Spawn engine in separate thread from TUI widget**

In `workflow_runner.zig`, when the runner is activated (mode switches to `.workflow_runner`):

```zig
pub fn startWorkflow(self: *WorkflowRunner, wf: *const Workflow, ...) !void {
    self.state.wf_runner.is_running = true;
    self.engine_thread = try std.Thread.spawn(.{}, runEngine, .{ self, wf, ... });
}

fn runEngine(self: *WorkflowRunner, wf: *const Workflow, ...) void {
    const result = workflow.executeWithEvents(...) catch { ... };
    // Push workflow_done event
    self.state.wf_runner.is_running = false;
}
```

- [ ] **Step 3: Poll events in draw()**

On each frame/draw, read new events from the queue (under mutex) and update the step display state. This is the mechanism by which the TUI stays in sync with the engine thread.

- [ ] **Step 4: Add --tui flag to CLI**

In `src/cli.zig`, in the `workflow run` handler, check for `--tui`. If present, launch the vxfw app with the workflow runner widget instead of calling `execute()`.

- [ ] **Step 5: Verify project compiles**

Run: `zig build 2>&1 | head -20`
Expected: Compiles.

- [ ] **Step 6: Manual test**

Run a simple workflow with `--tui` flag and verify the pipeline view appears, steps execute, and controls work.

- [ ] **Step 7: Commit**

```bash
git add src/workflow.zig src/tui/widgets/workflow_runner.zig src/cli.zig
git commit -m "feat(tui): wire workflow runner to engine with threaded execution"
```

---

### Task 15: Final Integration & Manual Testing

**Files:**
- All modified files

- [ ] **Step 1: Run full test suite**

Run: `zig build test 2>&1`
Expected: All tests pass.

- [ ] **Step 2: Create a test workflow TOML with all new features**

Create a test workflow file that exercises: depends_on, when, capture, retry, confirm, on_fail=ask.

```toml
[workflows.test-features]
desc = "Test all new workflow features"
tags = ["test"]

[workflows.test-features.steps.1]
name = "get-env"
cmd = "echo production"
capture = "env"

[workflows.test-features.steps.2]
name = "check-env"
cmd = "echo Deploying to {{env}}"
when = "{{env}} == production"

[workflows.test-features.steps.3]
name = "build"
cmd = "echo building..."
retry = 2
retry_delay = 1

[workflows.test-features.steps.4]
name = "deploy"
cmd = "echo deploying..."
depends_on = ["build", "check-env"]
confirm = true
on_fail = "ask"
```

- [ ] **Step 3: Test dry-run**

Run: `zipet workflow run test-features --dry`
Expected: Shows all steps with their config, no execution.

- [ ] **Step 4: Test interactive execution**

Run: `zipet workflow run test-features`
Expected: Steps execute in DAG order, capture works, when evaluates, confirm prompts.

- [ ] **Step 5: Test TUI runner**

Run: `zipet workflow run test-features --tui`
Expected: Pipeline view with live output and controls.

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "feat(workflow): complete Phase 4 — all 8 workflow features implemented"
```

---

## Notes for Implementer

- **OnFailOption in TUI form:** `src/tui/types.zig` has an `OnFailOption` enum used by `WorkflowFormState` that doesn't include `ask`. Update it when adding `ask` to `OnFail` (Task 3).
- **TUI workflow form:** The `workflow_form.zig` widget doesn't get new-field prompts in this plan (only the CLI wizard in Task 11). The TUI form can be extended in a follow-up.
- **vxfw redraw from thread:** The TUI runner (Task 14) needs to trigger redraws from the engine thread. Investigate vxfw's event loop — may need to write to the event fd or use `app.postEvent()` if available. Fallback: rely on the 60fps framerate polling.
- **Line numbers:** Tasks reference line numbers for orientation only. Search by content patterns since earlier tasks shift line numbers.
