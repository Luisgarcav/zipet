# TUI Workspace Creation

Create new workspaces directly from the TUI workspace picker, eliminating the need to drop to the CLI.

## Flow

1. User opens workspace picker (`W` or `:ws`)
2. Presses `n` — picker transitions to an inline 3-field form: **Name**, **Description**, **Path**
3. Navigate fields with `Tab` / `Shift+Tab`; type in each field
4. Submit with `Enter` on last field or `Ctrl+S` from any field
5. On success: activate the new workspace, reload store, return to normal mode with message `✓ Created workspace: <name>`
6. On error (duplicate name, empty name, invalid characters): show error inline, user corrects
7. `Esc` at any point — cancel, set `ws_creating = false`, return to picker list

## Validation

- **Name:** required, non-empty. Restricted to alphanumeric, hyphens, and underscores (filesystem safety — name becomes a directory).
- **Description:** optional, empty string is fine.
- **Path:** optional. Empty field means `null` (no auto-detection). Stored verbatim in `workspace.toml` — tilde expansion (`~/...`) is handled at read time by `detectWorkspaceByDir`.

## Changes

### `src/tui/types.zig`

Add `WorkspaceFormState` struct using the custom `TextField` (same pattern as `FormState`, `WorkflowFormState`, and `ParamInputState`):

```zig
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

Add to `State`:

```zig
ws_creating: bool = false,
ws_form: WorkspaceFormState = .{},
```

Note: using the custom `TextField` from `types.zig` (not `vxfw.TextField`) to match `FormState` and other state structs. The `form.zig` widget uses `vxfw.TextField` for its rendering, but that lives on the widget, not in state. For the workspace form we render inline within `workspace_picker.zig` using custom drawing, so the custom `TextField` is appropriate.

### `src/tui/widgets/workspace_picker.zig`

Extend the existing widget:

- **Event handling (list mode):** detect `n` key → set `state.ws_creating = true`, call `state.ws_form.reset()`
- **Event handling (form mode):** handle text input (insertChar/insertSlice), backspace, left/right cursor, `Tab`/`Shift+Tab` for field navigation, `Ctrl+S` for submit from any field, `Enter` for submit when on last field, `Esc` to cancel (set `ws_creating = false`, return to picker list)
- **Submit logic:**
  1. Validate name non-empty → error "Name is required"
  2. Validate name characters (alphanumeric, `-`, `_` only) → error "Name must be alphanumeric, hyphens, underscores"
  3. Call `workspace_mod.create(self.allocator, self.cfg, name, desc, path_or_null)` — pass `null` for path if field is empty
  4. Handle `AlreadyExists` → error "Workspace already exists"
  5. On success: activate workspace (same logic as selecting one in the list), `reloadStore()`, set message, return to normal mode
- **Draw (form mode):** when `state.ws_creating`, render a bordered form (FlexColumn + Border, same pattern as the picker itself) with title "New workspace", 3 labeled text fields with active field highlighted in accent color, error message in red if any, and footer: `Tab next  Ctrl+S save  Esc cancel`
- **Footer (list mode):** change from `"  Enter select  Esc/q cancel"` to `"  Enter select  n new  Esc/q cancel"`

### `src/tui/actions.zig` (minor)

In `openWorkspacePicker`: add `state.ws_creating = false` to ensure the form sub-state resets when the picker is opened fresh.

## What doesn't change

- `workspace.zig` — `create()` already exists and handles directory creation + metadata writing
- `root.zig` — continues delegating to workspace_picker, no changes needed
- No new `Mode` enum variant — reuse `workspace_picker` mode with the `ws_creating` flag as internal sub-state
