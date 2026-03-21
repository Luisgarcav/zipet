# TUI Workspace Creation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Allow users to create new workspaces directly from the TUI workspace picker by pressing `n`.

**Architecture:** Extend the existing `workspace_picker.zig` widget with an inline form mode. When `ws_creating` is true, the picker renders a 3-field form (Name, Description, Path) instead of the workspace list. Uses the custom `TextField` from `types.zig` (same pattern as `FormState`, `WorkflowFormState`, `ParamInputState`) — no `vxfw.TextField` needed, so no lifecycle management in root.zig. On submit, calls the existing `workspace.create()` function, activates the new workspace, and reloads the store.

**Tech Stack:** Zig 0.15, libvaxis/vxfw widget framework

**Spec:** `docs/superpowers/specs/2026-03-21-tui-workspace-creation-design.md`

---

### Task 1: Add WorkspaceFormState to types.zig

**Files:**
- Modify: `src/tui/types.zig`

- [ ] **Step 1: Add WorkspaceFormState struct**

Add this struct after `WorkflowRunnerState` (around line 427), before the `State` struct:

```zig
// ── Workspace creation form state ──
pub const WorkspaceFormState = struct {
    pub const F_NAME = 0;
    pub const F_DESC = 1;
    pub const F_PATH = 2;
    pub const FIELD_COUNT = 3;

    fields: [FIELD_COUNT]TextField = [_]TextField{.{}} ** FIELD_COUNT,
    labels: [FIELD_COUNT][]const u8 = .{ "Name", "Description", "Path" },
    active: usize = 0,
    error_msg: ?[]const u8 = null,

    pub fn activeField(self: *WorkspaceFormState) *TextField {
        return &self.fields[self.active];
    }

    pub fn reset(self: *WorkspaceFormState) void {
        for (&self.fields) |*f| f.clear();
        self.active = 0;
        self.error_msg = null;
    }
};
```

- [ ] **Step 2: Add ws_creating and ws_form to State**

In the `State` struct, in the workspace state section (around line 461), add after `ws_loaded`:

```zig
    ws_creating: bool = false,
    ws_form: WorkspaceFormState = .{},
```

- [ ] **Step 3: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build (no errors)

- [ ] **Step 4: Commit**

```bash
git add src/tui/types.zig
git commit -m "feat: add WorkspaceFormState to TUI types"
```

---

### Task 2: Reset ws_creating in openWorkspacePicker

**Files:**
- Modify: `src/tui/actions.zig:513-531`

- [ ] **Step 1: Add reset in openWorkspacePicker**

In `openWorkspacePicker` (line 513), after `state.ws_cursor = 0;` (line 519), add:

```zig
    state.ws_creating = false;
    state.ws_form.reset();
```

This ensures the form sub-state (including text field contents) is clean every time the picker is opened.

- [ ] **Step 2: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 3: Commit**

```bash
git add src/tui/actions.zig
git commit -m "feat: reset workspace form state when opening picker"
```

---

### Task 3: Allow Space key passthrough when ws_creating in root.zig

**Files:**
- Modify: `src/tui/root.zig:64-65`

The root widget intercepts Space key presses for preview popup toggling (line 61). The skip list at line 64 includes text input modes (search, command, form, param_input, workflow_form, pack_search) but NOT `workspace_picker`. When `ws_creating` is true, Space must pass through to the form's text fields.

- [ ] **Step 1: Add workspace_picker check to Space key skip list**

In root.zig, line 64, change the condition from:

```zig
if (mode == .search or mode == .command or mode == .form or
    mode == .param_input or mode == .workflow_form or mode == .pack_search)
```

to:

```zig
if (mode == .search or mode == .command or mode == .form or
    mode == .param_input or mode == .workflow_form or mode == .pack_search or
    (mode == .workspace_picker and self.state.ws_creating))
```

- [ ] **Step 2: Verify it compiles**

Run: `zig build 2>&1 | head -20`
Expected: successful build

- [ ] **Step 3: Commit**

```bash
git add src/tui/root.zig
git commit -m "feat: allow Space passthrough in workspace creation form"
```

---

### Task 4: Extend workspace_picker.zig with form mode

**Files:**
- Modify: `src/tui/widgets/workspace_picker.zig`

This is the main task. We handle form events with the custom `TextField`, validate input, call `workspace_mod.create()`, and render the form.

- [ ] **Step 1: Update event handling — Esc/q for both modes**

Replace the existing Esc/q handler (lines 37-39) with:

```zig
if (key.matches(vaxis.Key.escape, .{}) or key.matches('q', .{})) {
    if (self.state.ws_creating) {
        self.state.ws_creating = false;
        self.state.ws_form.error_msg = null;
        return ctx.consumeAndRedraw();
    }
    self.state.mode = .normal;
    return ctx.consumeAndRedraw();
}
```

- [ ] **Step 2: Add form-mode event routing**

After the Esc handler, before the existing Enter handler (line 42), add:

```zig
if (self.state.ws_creating) {
    const form = &self.state.ws_form;

    // Ctrl+S: submit from any field
    if (key.matches('s', .{ .ctrl = true })) {
        self.handleFormSubmit();
        return ctx.consumeAndRedraw();
    }

    // Tab / Down: next field
    if (key.matches(vaxis.Key.tab, .{}) or key.matches(vaxis.Key.down, .{})) {
        form.active = if (form.active + 1 < t.WorkspaceFormState.FIELD_COUNT) form.active + 1 else 0;
        return ctx.consumeAndRedraw();
    }

    // Shift+Tab / Up: prev field
    if (key.matches(vaxis.Key.tab, .{ .shift = true }) or key.matches(vaxis.Key.up, .{})) {
        form.active = if (form.active > 0) form.active - 1 else t.WorkspaceFormState.FIELD_COUNT - 1;
        return ctx.consumeAndRedraw();
    }

    // Enter: submit
    if (key.matches(vaxis.Key.enter, .{})) {
        self.handleFormSubmit();
        return ctx.consumeAndRedraw();
    }

    // Backspace
    if (key.matches(vaxis.Key.backspace, .{})) {
        form.activeField().backspace();
        return ctx.consumeAndRedraw();
    }

    // Delete
    if (key.matches(vaxis.Key.delete, .{})) {
        form.activeField().deleteForward();
        return ctx.consumeAndRedraw();
    }

    // Left arrow
    if (key.matches(vaxis.Key.left, .{})) {
        form.activeField().moveLeft();
        return ctx.consumeAndRedraw();
    }

    // Right arrow
    if (key.matches(vaxis.Key.right, .{})) {
        form.activeField().moveRight();
        return ctx.consumeAndRedraw();
    }

    // Home
    if (key.matches(vaxis.Key.home, .{})) {
        form.activeField().moveHome();
        return ctx.consumeAndRedraw();
    }

    // End
    if (key.matches(vaxis.Key.end, .{})) {
        form.activeField().moveEnd();
        return ctx.consumeAndRedraw();
    }

    // Regular text input
    if (key.text) |txt| {
        form.activeField().insertSlice(txt);
        return ctx.consumeAndRedraw();
    } else if (key.codepoint != 0 and !key.mods.ctrl and !key.mods.alt and !key.mods.super) {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(key.codepoint, &buf) catch return;
        form.activeField().insertSlice(buf[0..len]);
        return ctx.consumeAndRedraw();
    }

    return;
}
```

- [ ] **Step 3: Add `n` key handler in list mode**

After the existing Enter handler (around line 61) but before forwarding to list_view (line 67), add:

```zig
if (key.matches('n', .{})) {
    self.state.ws_creating = true;
    self.state.ws_form.reset();
    return ctx.consumeAndRedraw();
}
```

- [ ] **Step 4: Add handleFormSubmit method**

Add this as a new method on WorkspacePicker (after `handleEvent`, before `draw`):

```zig
fn handleFormSubmit(self: *WorkspacePicker) void {
    const form = &self.state.ws_form;
    const name = form.fields[t.WorkspaceFormState.F_NAME].text();
    const desc = form.fields[t.WorkspaceFormState.F_DESC].text();
    const path_text = form.fields[t.WorkspaceFormState.F_PATH].text();

    if (name.len == 0) {
        form.error_msg = "Name is required";
        return;
    }

    // Validate name characters: alphanumeric, hyphens, underscores only
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
            form.error_msg = "Name: only letters, numbers, hyphens, underscores";
            return;
        }
    }

    const path: ?[]const u8 = if (path_text.len > 0) path_text else null;

    // Create workspace
    workspace_mod.create(self.allocator, self.cfg, name, desc, path) catch |err| {
        form.error_msg = switch (err) {
            error.AlreadyExists => "Workspace already exists",
            else => "Failed to create workspace",
        };
        return;
    };

    // Activate the new workspace (same logic as selecting from list)
    if (self.state.active_workspace) |ws| self.allocator.free(ws);
    self.state.active_workspace = self.allocator.dupe(u8, name) catch null;
    workspace_mod.setActiveWorkspace(self.allocator, self.cfg, name) catch {};
    self.snip_store.cfg.active_workspace = self.state.active_workspace;
    utils.reloadStore(self.allocator, self.state, self.snip_store);

    // Return to normal mode with success message
    self.state.ws_creating = false;
    self.state.message = "\xe2\x9c\x93 Created workspace";
    self.state.mode = .normal;
}
```

Note: `form.fields[F_NAME].text()` returns a slice into the fixed buffer — safe to pass to `workspace_mod.create()` which copies/uses the data before returning. `self.allocator.dupe(u8, name)` also copies it.

- [ ] **Step 5: Add form draw logic**

In the `draw` function, at the top after extracting `self`, `state`, `accent`, `width`, `height` (around line 76), add:

```zig
if (state.ws_creating) {
    return self.drawForm(ctx, accent, width, height);
}
```

Then add the `drawForm` method after `draw`:

```zig
fn drawForm(self: *WorkspacePicker, ctx: vxfw.DrawContext, accent: config.Color, width: u16, height: u16) std.mem.Allocator.Error!vxfw.Surface {
    const form = &self.state.ws_form;
    const has_error = form.error_msg != null;
    // title + blank + (label+value + spacer) * 3 + optional error + footer
    // Active field: label + cursor_line + spacer = 3; Inactive: label_value + spacer = 2
    // Max allocation: 2 + 3*3 + 1 + 1 = 13
    const child_count: usize = 2 + 3 * t.WorkspaceFormState.FIELD_COUNT + @as(usize, if (has_error) 1 else 0) + 1;
    const children = try ctx.arena.alloc(vxfw.FlexItem, child_count);
    var idx: usize = 0;

    // ── Title ──
    const title_w = try ctx.arena.create(vxfw.Text);
    title_w.* = .{ .text = "  New Workspace", .style = t.accentBoldStyle(accent) };
    children[idx] = .{ .widget = title_w.widget(), .flex = 0 };
    idx += 1;

    // ── Blank ──
    const blank_w = try ctx.arena.create(vxfw.Text);
    blank_w.* = .{ .text = " ", .style = .{} };
    children[idx] = .{ .widget = blank_w.widget(), .flex = 0 };
    idx += 1;

    // ── Fields ──
    const label_pad = 16;
    for (0..t.WorkspaceFormState.FIELD_COUNT) |fi| {
        const label = form.labels[fi];
        const is_active = fi == form.active;
        const content = form.fields[fi].text();

        const pad_after = if (label_pad > label.len + 3) label_pad - label.len - 3 else 1;
        const spaces = try ctx.arena.alloc(u8, pad_after);
        @memset(spaces, ' ');
        const label_str = try std.fmt.allocPrint(ctx.arena, "  {s}:{s}", .{ label, spaces });

        if (is_active) {
            // Active: label line, then content with cursor indicator
            const label_w = try ctx.arena.create(vxfw.Text);
            label_w.* = .{ .text = label_str, .style = .{ .fg = t.accentColor(accent), .bold = true } };
            children[idx] = .{ .widget = label_w.widget(), .flex = 0 };
            idx += 1;

            // Show content with cursor position indicated
            const display = if (content.len > 0) content else " ";
            const input_line = try std.fmt.allocPrint(ctx.arena, "  > {s}", .{display});
            const input_w = try ctx.arena.create(vxfw.Text);
            input_w.* = .{ .text = input_line, .style = .{ .fg = t.accentColor(accent) } };
            children[idx] = .{ .widget = input_w.widget(), .flex = 0 };
        } else {
            // Inactive: single line with label and value
            const display = if (content.len > 0) content else "\xe2\x80\x94";
            const line = try std.fmt.allocPrint(ctx.arena, "{s}{s}", .{ label_str, display });
            const field_w = try ctx.arena.create(vxfw.Text);
            field_w.* = .{ .text = line, .style = t.dim_style };
            children[idx] = .{ .widget = field_w.widget(), .flex = 0 };
        }
        idx += 1;

        // Spacer
        const spacer_w = try ctx.arena.create(vxfw.Text);
        spacer_w.* = .{ .text = " ", .style = .{} };
        children[idx] = .{ .widget = spacer_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Error message ──
    if (form.error_msg) |emsg| {
        const err_w = try ctx.arena.create(vxfw.Text);
        const err_line = try std.fmt.allocPrint(ctx.arena, "  {s}", .{emsg});
        err_w.* = .{ .text = err_line, .style = t.err_style };
        children[idx] = .{ .widget = err_w.widget(), .flex = 0 };
        idx += 1;
    }

    // ── Footer ──
    const footer_w = try ctx.arena.create(vxfw.Text);
    footer_w.* = .{ .text = "  Tab: next  Ctrl+S: save  Esc: cancel", .style = t.dim_style };
    children[idx] = .{ .widget = footer_w.widget(), .flex = 0 };
    idx += 1;

    var col = vxfw.FlexColumn{ .children = children[0..idx] };
    const labels = try ctx.arena.alloc(vxfw.Border.BorderLabel, 1);
    labels[0] = .{ .text = "New Workspace", .alignment = .top_center };
    var border = vxfw.Border{
        .child = col.widget(),
        .style = t.dim_style,
        .labels = labels,
    };
    return border.widget().draw(ctx.withConstraints(
        .{ .width = width, .height = height },
        .{ .width = width, .height = height },
    ));
}
```

- [ ] **Step 6: Update list-mode footer**

In the existing `draw` function, change the footer text (line 127):

From:
```zig
footer_w.* = .{ .text = "  Enter select  Esc/q cancel", .style = t.dim_style };
```

To:
```zig
footer_w.* = .{ .text = "  Enter select  n new  Esc/q cancel", .style = t.dim_style };
```

- [ ] **Step 7: Verify it compiles**

Run: `zig build 2>&1 | head -30`
Expected: successful build

- [ ] **Step 8: Commit**

```bash
git add src/tui/widgets/workspace_picker.zig
git commit -m "feat: add workspace creation form to workspace picker"
```

---

### Task 5: Manual smoke test

- [ ] **Step 1: Run the TUI**

Run: `zig build run`

- [ ] **Step 2: Test the happy path**

1. Press `W` to open workspace picker
2. Verify footer shows `Enter select  n new  Esc/q cancel`
3. Press `n` — form should appear with Name, Description, Path fields
4. Type a workspace name (e.g. `test-ws`)
5. Tab to Description, type something (including spaces)
6. Tab to Path, leave empty or type a path like `~/projects/test`
7. Press `Ctrl+S` — workspace should be created, TUI returns to normal mode with success message
8. Press `W` again — new workspace should appear in the list, marked as active

- [ ] **Step 3: Test the `:ws` command path**

1. Type `:ws` and press Enter to open workspace picker
2. Verify it opens cleanly (form is NOT showing)
3. Press `n`, verify form works the same way

- [ ] **Step 4: Test validation**

1. Open picker, press `n`, try to submit with empty name → error "Name is required"
2. Type `invalid/name` → error about invalid characters
3. Create a workspace, then try to create one with the same name → "Workspace already exists"

- [ ] **Step 5: Test cancellation**

1. Open picker, press `n`, type something, press `Esc` → returns to picker list (not normal mode)
2. Press `Esc` again → returns to normal mode
3. Open picker again → form should NOT be showing (clean state)

- [ ] **Step 6: Clean up test workspace**

Run: `zipet workspace rm test-ws` (or whatever name you used)

- [ ] **Step 7: Commit any fixes if needed**

```bash
git add -u
git commit -m "fix: workspace creation form adjustments from smoke test"
```
