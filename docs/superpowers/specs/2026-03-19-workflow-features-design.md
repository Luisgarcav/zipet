# Workflow Engine — Phase 4 Features Design

**Date:** 2026-03-19
**Status:** Draft
**Scope:** 8 new features for the zipet workflow engine

## Overview

This spec covers the remaining workflow features needed to complete Phase 4 of zipet's development. The current workflow engine executes steps sequentially with basic failure policies (`stop`, `continue`, `skip_rest`) and inter-step data passing via `{{prev_stdout}}`/`{{prev_exit}}`. These 8 features bring dependency-based execution, conditional logic, interactive failure recovery, retries, variable capture, confirmations, dry-run simulation, and a dedicated TUI runner.

## 1. Data Model Changes

### New fields on `Step`

All fields are optional and backward-compatible with existing workflows.

```toml
[workflows.deploy.steps.1]
name = "Get version"
cmd = "cat VERSION"
on_fail = "stop"            # existing — now also accepts "ask"
capture = "version"         # captures stdout to {{version}}
depends_on = ["step-name"]  # DAG dependency (list of step names)
when = "{{env}} == prod"    # conditional expression
retry = 3                   # max retry attempts
retry_delay = 2             # seconds between retries (default: 0)
confirm = false             # if true, pause for user confirmation before executing
```

### Rules

- `depends_on` is optional. Without it, a step implicitly depends on the previous step (index - 1), preserving backward compatibility with all existing workflows.
- `when` is evaluated after dependencies resolve and before execution. If false, the step is marked `skipped`.
- `capture` stores trimmed stdout in the variable context, available as `{{name}}` to subsequent steps.
- `confirm` is a boolean flag on the step, not a separate step type.
- `retry` only triggers on failure (exit != 0). `retry_delay` defaults to 0.
- `on_fail = "ask"` without a TTY behaves as `stop`.

### TOML Serialization

New fields are serialized alongside existing ones in `~/.config/zipet/workflows/<namespace>.toml`. Missing fields use defaults (capture = null, depends_on = empty, when = null, retry = 0, retry_delay = 0, confirm = false).

## 2. Expression Evaluator for `when` Clauses

### Module

New file: `src/condition.zig`

### Interface

```
evaluate(expr: []const u8, vars: VarContext) -> bool
```

### Supported Operators

**Comparison:**
- `==` — string equality (numeric if both sides parse to number)
- `!=` — string inequality
- `contains` — substring check: `"{{tags}} contains deploy"`
- `empty` — value is empty string: `"{{error}} empty"`
- `not_empty` — value is non-empty: `"{{version}} not_empty"`

**Logical:**
- `and` — logical AND
- `or` — logical OR
- `not` — logical NOT (prefix)

**Precedence:** `not` > `and` > `or`. No parentheses supported.

### Evaluation Process

1. Resolve template variables (`{{var}}` → value) using the current variable context.
2. Tokenize into: string literals, operators, keywords.
3. Evaluate respecting operator precedence.

### Examples

```
"{{env}} == production"
"{{prev_exit}} != 0"
"{{version}} not_empty"
"{{env}} == prod and {{region}} != us-east"
"{{debug}} == true or {{verbose}} == true"
"not {{skip}} == true"
"{{output}} contains error and {{strict}} == true"
```

## 3. Dependency Graph Resolution

### Module

New file: `src/dag.zig`

### Interface

```
buildGraph(steps: []Step) -> Graph
detectCycle(graph: Graph) -> ?[]const u8
topologicalSort(graph: Graph) -> []Step
```

### Behavior

1. At workflow start, a DAG is built from step `depends_on` fields.
2. Steps without explicit `depends_on` depend on the previous step (index - 1), maintaining backward compatibility.
3. Cycles are detected before execution. If a cycle exists, the workflow fails with a descriptive error naming the offending step.

### Execution Order

- Steps are executed in topological order. **No automatic parallelism** — the DAG only defines ordering.
- If a step fails (and its `on_fail = stop`), all steps that transitively depend on it are marked `skipped`.

### Example

```toml
[workflows.deploy.steps.1]
name = "build"
cmd = "make build"

[workflows.deploy.steps.2]
name = "test"
cmd = "make test"
# no depends_on → depends on "build" (previous)

[workflows.deploy.steps.3]
name = "package"
cmd = "tar czf app.tar.gz dist/"
depends_on = ["build"]
# depends on build, not test

[workflows.deploy.steps.4]
name = "deploy"
cmd = "deploy app.tar.gz"
depends_on = ["test", "package"]
```

Resolved order: build → test → package → deploy.

## 4. Retry Logic

### Behavior

- When a step fails (exit != 0) and `retry > 0`, the step is re-executed up to `retry` times.
- Between retries, the engine waits `retry_delay` seconds.
- Interactive output shows: `⟳ Retry 2/3 for "build" (waiting 2s...)`
- If all retries fail, `on_fail` is applied normally.
- `{{prev_exit}}` and `{{prev_stdout}}` reflect the last attempt.

### Non-interactive

Retry works identically in non-interactive mode (no TTY dependency).

## 5. Capture Variables

### Behavior

- When a step has `capture = "var_name"`, its stdout (trimmed of leading/trailing whitespace) is stored in the variable context under that name.
- The variable is available as `{{var_name}}` in all subsequent steps.
- Overwrites `{{prev_stdout}}` behavior: `{{prev_stdout}}` still works and reflects the most recent step, but `capture` provides named access that persists across multiple steps.

### Interaction with Retry

If a step with `capture` is retried, the captured value reflects the last attempt (whether successful or not — capture happens on any execution, not only on success).

### Interaction with `when`

If a step is skipped due to `when` evaluating to false, no capture occurs. Steps depending on that variable will see it as empty.

## 6. Confirm Step

### Behavior

- Before executing a step with `confirm = true`, the engine displays:
  ```
  ⏸ Step "deploy to prod" — proceed? [y/N]
  ```
- If the user answers `n` (or presses Enter, since default is No), the step is marked `skipped` and `on_fail` logic applies.
- If the user answers `y`, the step executes normally.

### Non-interactive (no TTY)

The step fails. This is the safest default — if no human is present, confirmation cannot be granted.

## 7. on_fail = "ask"

### Behavior

When a step fails and `on_fail = "ask"`, the engine displays:

```
✗ Step "build" failed (exit 1). [r]etry / [s]kip / [a]bort?
```

- `r` — re-executes the step once. If it fails again, the prompt re-appears.
- `s` — marks the step as skipped, continues to the next step.
- `a` — aborts the workflow immediately.

### Non-interactive (no TTY)

Behaves as `on_fail = "stop"`.

## 8. Dry-Run Mode

### CLI

```
zipet workflow run deploy --dry
```

### Behavior

For each step, displays what would happen without executing:

```
[dry] Step 1: "build"
      cmd: make build
      on_fail: stop
      retry: 3 (delay: 2s)

[dry] Step 2: "deploy"
      cmd: deploy --version={{version}}
      when: {{env}} == production → (not evaluated)
      depends_on: [build]
      confirm: true
```

### Rules

- `when` clauses are NOT evaluated (variables may not exist without execution). The raw expression is displayed.
- Capture variables are shown as pending.
- Step order IS resolved via DAG (topological sort works without execution).
- `confirm` and `on_fail = "ask"` are displayed but not triggered.

## 9. Workflow Runner TUI

### Activation

- From TUI: selecting "Run" on a workflow opens the runner view.
- From CLI: `zipet workflow run <name> --tui`

### Layout

```
┌─ Workflow: deploy ──────────────────────────────┐
│                                                  │
│  ✓ build .............. ok (0.8s)                │
│  ✓ test ............... ok (2.1s)                │
│  ● package ............ running...               │
│  ○ deploy ............. pending                  │
│  ○ notify ............. pending                  │
│                                                  │
├──────────────────────────────────────────────────┤
│ $ tar czf app.tar.gz dist/                       │
│ adding: dist/main.js                             │
│ adding: dist/index.html                          │
│ ...                                              │
│                                                  │
├──────────────────────────────────────────────────┤
│ [r] retry  [s] skip  [c] cancel  [q] quit       │
└──────────────────────────────────────────────────┘
```

### Pipeline Panel (top)

- List of steps with status icons: `✓` ok, `✗` fail, `●` running, `○` pending, `⊘` skipped
- Elapsed time per completed step
- Current step highlighted

### Output Panel (bottom)

- Live stdout/stderr of the current step using the existing `OutputView` widget
- Scrollable with j/k or arrow keys

### Controls

Active only when a step has failed or the workflow is paused:
- `r` — retry failed step
- `s` — skip failed step, continue
- `c` — cancel workflow
- `q` — quit the view (also cancels the workflow)

### Interactive Prompts in TUI

- `confirm = true`: pipeline pauses, output panel shows confirmation prompt with `y/n`.
- `on_fail = "ask"`: controls `[r] retry [s] skip [a] abort` are highlighted, workflow waits for input.

### Event System

The workflow engine emits events consumed by the TUI widget:
- `step_started { name, index }`
- `step_completed { name, index, exit_code, duration_ms }`
- `step_failed { name, index, exit_code, duration_ms }`
- `step_skipped { name, index, reason }`
- `confirm_requested { name, index }`
- `ask_requested { name, index, exit_code }`
- `retry_started { name, index, attempt, max_attempts }`

### Implementation

- New widget: `src/tui/widgets/workflow_runner.zig`
- Connects to the workflow engine via an event channel/callback interface.
- The engine runs in a separate thread; the TUI polls events on each frame.

## 10. Integration Points

### Workflow Engine (`src/workflow.zig`)

- `execute()` and `executeSilent()` are refactored to use the DAG resolver for step ordering.
- A new `VarContext` (StringHashMap) holds captured variables alongside `prev_stdout`/`prev_exit`.
- Before each step: evaluate `when`, handle `confirm`, resolve retry loop.
- After each step: store `capture`, update `prev_stdout`/`prev_exit`.
- New event emission interface for TUI integration.

### CLI (`src/cli.zig`)

- `workflow run` accepts `--dry` flag.
- `workflow run` accepts `--tui` flag to launch the runner TUI view.
- `workflow add` wizard updated with prompts for new fields (capture, depends_on, when, retry, retry_delay, confirm).

### TOML Parsing (`src/workflow.zig` or `src/store.zig`)

- Parse new fields from TOML. Unknown/missing fields use defaults.
- Serialize new fields when saving workflows.

### Pack System (`src/pack.zig`)

- No changes required. Packs already bundle workflow TOML — new fields are transparently supported.

## 11. New Files

| File | Purpose |
|------|---------|
| `src/condition.zig` | Expression evaluator for `when` clauses |
| `src/dag.zig` | DAG builder, cycle detection, topological sort |
| `src/tui/widgets/workflow_runner.zig` | TUI workflow runner widget |

## 12. Modified Files

| File | Changes |
|------|---------|
| `src/workflow.zig` | New Step fields, VarContext, DAG integration, retry/confirm/ask logic, event emission, dry-run |
| `src/cli.zig` | `--dry` and `--tui` flags, updated `workflow add` wizard |
| `src/tui/root.zig` | Route to workflow runner view |
| `src/tui/types.zig` | New event types for workflow runner |
