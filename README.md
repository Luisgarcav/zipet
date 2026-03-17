<p align="center">
  <img src="assets/logo.svg" alt="zipet logo" width="180" />
</p>

<h1 align="center">⚡ zipet</h1>
<p align="center"><strong>Snippets that grow with you</strong></p>
<p align="center">
  A blazing-fast command snippet manager with TUI, workflows, packs, and fuzzy search — written in Zig.
</p>

<p align="center">
  <img alt="Version" src="https://img.shields.io/badge/version-0.1.0-cyan?style=flat-square" />
  <img alt="Zig" src="https://img.shields.io/badge/zig-0.15.1-orange?style=flat-square&logo=zig" />
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green?style=flat-square" />
  <img alt="Platform" src="https://img.shields.io/badge/platform-linux-blue?style=flat-square" />
</p>

---

## 📥 Install

```bash
curl -sSL https://raw.githubusercontent.com/Luisgarcav/zipet/main/scripts/install.sh | bash
```

That's it. The script detects your OS and architecture, downloads the right binary, and places it in `~/.local/bin/`.

> Supports **Linux** (x86_64) and **macOS** (x86_64 / Apple Silicon).

---

## ✨ Why zipet?

You type the same commands over and over. You forget that perfect `find` incantation. Your `~/.bash_history` is a graveyard of useful one-liners you'll never find again.

**zipet** saves, organizes, and executes your commands — with parameters, workflows, fuzzy search, and a beautiful TUI. All stored as simple TOML files. Zero dependencies at runtime.

---

## 🎬 Quick Start

```bash
# Initialize zipet (creates ~/.config/zipet with examples)
zipet init

# Add your first snippet
zipet add "docker build -t {{image}}:{{tag}} ."

# Run it with fuzzy search
zipet run docker

# Or just open the TUI
zipet
```

---

## 🚀 Features

### 🔍 Fuzzy Search

Find any snippet instantly. zipet uses an intelligent scoring algorithm with bonuses for word boundaries, camelCase, consecutive matches, and exact prefixes.

```bash
zipet run dk        # matches "docker-build", "disk-usage", etc.
zipet run "find lg" # matches "find-large"
```

Unknown commands are treated as implicit `run` — just type `zipet docker` and go.

---

### 📝 Smart Templates with `{{params}}`

Snippets support parameterized placeholders that are prompted at execution time:

```toml
[snippets.find-large]
desc = "Find large files"
tags = ["system", "find"]
cmd = "find {{path}} -type f -size +{{size}} -exec ls -lh {} \\;"

[snippets.find-large.params]
path = { prompt = "Search path", default = "." }
size = { prompt = "Minimum size", default = "100M" }
```

**Parameter types:**
| Type | Description |
|------|-------------|
| `prompt` + `default` | Simple text input with default value |
| `options` | Predefined list — user picks from numbered menu |
| `command` | Dynamic options — runs a shell command to populate choices |

#### 🧠 Built-in Variables

Use these anywhere in your commands — they resolve automatically:

| Variable | Value |
|---|---|
| `{{user}}` | Current username |
| `{{hostname}}` | Machine hostname |
| `{{cwd}}` | Current working directory |
| `{{date}}` | Today's date (`YYYY-MM-DD`) |
| `{{datetime}}` | ISO 8601 datetime |
| `{{timestamp}}` | Unix timestamp |
| `{{os}}` | Operating system |
| `{{arch}}` | CPU architecture |
| `{{git_branch}}` | Current git branch |
| `{{git_sha}}` | Short git commit SHA |
| `{{git_root}}` | Git repository root path |
| `{{clipboard}}` | Clipboard contents (X11/Wayland/macOS) |

---

### 🖥️ Terminal UI (TUI)

Launch with just `zipet` — a vim-native interface powered by [libvaxis](https://github.com/rockorager/libvaxis):

```
┌──────────────────────────────────────────────────┐
│  zipet                              [global] ? │
│  / search...                                     │
│                                                   │
│  ▸ ● docker-build     Build Docker image          │
│    ● find-large       Find large files            │
│    ● disk-usage       Show disk usage sorted      │
│    ⚡ deploy-all      [workflow] Deploy pipeline   │
│                                                   │
│  ──── Preview ────                                │
│  $ docker build -t {{image}}:{{tag}} .            │
│  Tags: docker, build                              │
│                                                   │
│  j/k Navigate  Enter Run  a Add  / Search  ? Help│
└──────────────────────────────────────────────────┘
```

**Keybindings:**

| Key | Action |
|-----|--------|
| `j` / `k` | Navigate up / down |
| `gg` / `G` | Jump to first / last |
| `Ctrl-D` / `Ctrl-U` | Page down / up |
| `/` | Focus search bar |
| `Enter` | Run selected snippet |
| `a` | Add new snippet (inline form) |
| `e` | Edit snippet in `$EDITOR` |
| `d` | Delete (with confirmation) |
| `y` | Yank command to clipboard |
| `p` | Paste from clipboard |
| `o` | Open TOML file in editor |
| `i` | Full info panel |
| `Space` | Toggle preview pane |
| `t` | Filter by tag |
| `W` | Workspace picker |
| `P` | Pack browser |
| `?` | Toggle help sidebar |
| `:q` | Quit |
| `:w` | Save all |
| `:wq` | Save & quit |
| `:tags` | Tag picker |
| `:export` | Export snippets |
| `:ws` | Workspace picker |
| `:packs` | Pack browser |

---

### ⚡ Workflows

Chain multiple commands and snippets into sequential pipelines with error handling and data passing between steps:

```bash
# Create a workflow interactively
zipet workflow add

# Run it
zipet workflow run deploy-all

# List all workflows
zipet wf ls

# Inspect workflow details
zipet wf show deploy-all
```

**Workflow features:**
- 🔗 **Step chaining** — inline commands or snippet references
- 🔄 **Inter-step data** — `{{prev_stdout}}` and `{{prev_exit}}` pass data between steps
- 🛡️ **Failure policies** — `stop`, `continue`, or `skip_rest` per step
- 📝 **Workflow-level params** — shared parameters prompted once for all steps
- ✏️ **Edit in `$EDITOR`** — `zipet wf edit <name>`

---

### 🔀 Parallel Execution

Run multiple snippets or workflows simultaneously with threaded execution:

```bash
# Run three health checks in parallel
zipet parallel check-disk check-mem check-net

# Short alias with param overrides
zipet par deploy-api deploy-web -- env=prod

# Mix snippets and workflows
zipet par build-frontend build-backend run-tests
```

Each parallel item runs in its own thread. Results show exit codes, duration, stdout/stderr for each.

---

### 📦 Packs

Shareable collections of snippets and workflows. Install from built-in registry, local files, or URLs:

```bash
# Browse available packs
zipet pack ls

# Install a built-in pack
zipet pack install pentesting
zipet pack install devops

# Install into a specific workspace
zipet pack install web-dev --workspace=myproject

# Install from file or URL
zipet pack install ./my-snippets.toml
zipet pack install https://example.com/pack.toml

# Create a pack from your snippets
zipet pack create my-tools --namespace=general

# View pack details
zipet pack info pentesting

# Remove a pack
zipet pack uninstall devops
```

**Built-in packs:**

| Pack | Description |
|------|-------------|
| `pentesting` | Nmap, gobuster, sqlmap, hydra, hashcat... |
| `devops` | Docker, Kubernetes, deployment, monitoring |
| `git-power` | Advanced Git workflows and shortcuts |
| `sysadmin` | Linux system administration essentials |
| `web-dev` | HTTP testing, API debugging, JWT, encoding |

---

### 📂 Workspaces

Organize snippets by project, context, or environment. Each workspace has isolated snippets and workflows:

```bash
# Create a workspace (optionally linked to a project directory)
zipet workspace create backend --path=/home/user/projects/api

# Switch to it
zipet ws use backend

# See which workspace is active
zipet ws current

# List all workspaces
zipet ws ls

# Switch back to global
zipet ws use --global

# Delete a workspace
zipet ws rm backend
```

Workspaces are also accessible from the TUI with `W` or `:ws`.

---

### 🐚 Shell Integration

Bind zipet to keyboard shortcuts in your shell:

```bash
# Bash — add to ~/.bashrc
eval "$(zipet shell bash)"

# Zsh — add to ~/.zshrc
eval "$(zipet shell zsh)"

# Fish — add to ~/.config/fish/config.fish
zipet shell fish | source
```

| Shortcut | Action |
|----------|--------|
| `Ctrl-S` | Open snippet picker and insert into command line |
| `Ctrl-X Ctrl-S` | Save current command as a snippet (bash/zsh) |

---

### 🤖 AI Agent Integration (MCP)

zipet includes a **Model Context Protocol (MCP) server** so AI coding agents (Claude, Copilot, Cursor, etc.) can search, preview, and execute your snippets securely.

```
┌──────────────────────┐
│   AI Coding Agent    │  "I need to clean up Docker"
└──────────┬───────────┘
           │ MCP Protocol (stdio/SSE)
           ▼
┌──────────────────────┐
│  zipet-mcp-server    │  search → preview → run (with safety gate)
└──────────┬───────────┘
           │ subprocess
           ▼
┌──────────────────────┐
│     zipet CLI        │  ~/.config/zipet/
└──────────────────────┘
```

**Available MCP tools:**

| Tool | Description |
|------|-------------|
| `zipet_search` | Fuzzy search snippets and workflows |
| `zipet_list` | List by category or tags |
| `zipet_get` | Get full snippet details |
| `zipet_run` | Execute a snippet (with safety gate) |
| `zipet_run_workflow` | Execute a full workflow |
| `zipet_preview` | Preview expanded command without executing |
| `zipet_packs` | Browse and install packs |
| `zipet_workspaces` | Manage workspaces |

**MCP resources** — `zipet://snippets`, `zipet://workflows`, `zipet://packs`, `zipet://config`

**Setup** — add to your agent's MCP config:

```json
{
  "mcpServers": {
    "zipet": {
      "command": "uv",
      "args": ["run", "--project", "/path/to/zipet/ai", "python", "server.py"],
      "env": {
        "ZIPET_SAFETY_MODE": "confirm",
        "ZIPET_DENY_COMMANDS": "rm -rf /,mkfs,dd if="
      }
    }
  }
}
```

**Safety modes:**

| Mode | Description |
|------|-------------|
| `open` | Execute without confirmation (dev/sandbox only) |
| `confirm` | Requires human approval before executing |
| `dry-run` | Preview only, never executes |
| `allowlist` | Only runs snippets/tags in the allowlist |

> See [`ai/README.md`](ai/README.md) for full MCP server documentation.

---

### 📤 Import & Export

```bash
# Export all snippets as TOML (default)
zipet export > my-snippets.toml

# Export as JSON
zipet export --json > my-snippets.json

# Import from local file
zipet import ./shared-snippets.toml

# Import from URL
zipet import https://example.com/team-snippets.toml
```

Duplicate snippets are automatically detected and skipped during import.

---

### 🏷️ Tags & Filtering

Organize with tags and filter instantly:

```bash
# List all tags with counts
zipet tags

# Filter by tag
zipet ls --tags=docker

# In the TUI: press 't' for the tag picker
```

---

## ⚙️ Configuration

zipet stores everything under `~/.config/zipet/` (respects `$XDG_CONFIG_HOME`):

```
~/.config/zipet/
├── config.toml          # Global configuration
├── snippets/            # Snippet TOML files (by namespace)
│   ├── general.toml
│   └── docker.toml
├── workflows/           # Workflow definitions
│   └── general.toml
├── packs/               # Installed pack metadata
│   └── registry/        # Built-in pack definitions
├── workspaces/          # Workspace directories
│   └── myproject/
│       ├── workspace.toml
│       ├── snippets/
│       └── workflows/
└── active_workspace     # Currently active workspace
```

**`config.toml`:**

```toml
[general]
accent_color = "cyan"    # cyan, green, yellow, magenta, red, blue, white
preview = true           # Show preview pane in TUI

[shell]
shell = "/bin/sh"        # Shell for executing commands
editor = "vim"           # Editor for 'edit' command
```

---

## 📋 All Commands

| Command | Description |
|---------|-------------|
| `zipet` | Open the TUI |
| `zipet add [cmd]` | Add a snippet interactively |
| `zipet add --last` | Save last shell command as snippet |
| `zipet run <query>` | Fuzzy search and execute |
| `zipet edit <name>` | Edit snippet in `$EDITOR` |
| `zipet rm <name>` | Delete a snippet |
| `zipet ls [--tags=x]` | List snippets |
| `zipet tags` | List all tags with counts |
| `zipet workflow add\|run\|ls\|show\|rm\|edit` | Workflow management |
| `zipet wf` | Alias for `workflow` |
| `zipet parallel <names...> [-- key=val]` | Run in parallel |
| `zipet par` | Alias for `parallel` |
| `zipet pack ls\|install\|uninstall\|create\|info` | Pack management |
| `zipet workspace ls\|create\|use\|rm\|current` | Workspace management |
| `zipet ws` | Alias for `workspace` |
| `zipet export [--json]` | Export all snippets |
| `zipet import <file\|url>` | Import snippets |
| `zipet init` | Initialize config directory |
| `zipet shell <bash\|zsh\|fish>` | Output shell integration |
| `zipet help` | Show help |
| `zipet version` | Show version |
| MCP server | `uv run --project ai python server.py` — AI agent interface |

---

## 🛠️ Building from Source

**Requirements:** Zig ≥ 0.15.1

```bash
git clone https://github.com/Luisgarcav/zipet.git
cd zipet
zig build -Doptimize=ReleaseFast

# The binary is at ./zig-out/bin/zipet
# Copy it somewhere in your $PATH:
cp zig-out/bin/zipet ~/.local/bin/
```

**Run tests:**
```bash
zig build test
```

**Run directly:**
```bash
zig build run -- ls
zig build run -- add "echo hello"
zig build run           # opens TUI
```

---

## 🧩 Snippet Format (TOML)

```toml
[snippets.my-command]
desc = "Description of what this does"
tags = ["tag1", "tag2"]
cmd = "command --with {{param1}} and {{param2}}"

[snippets.my-command.params]
param1 = { prompt = "Enter value", default = "foo" }
param2 = { prompt = "Pick one", options = ["a", "b", "c"] }
# Or dynamic options from a command:
# param2 = { prompt = "Pick branch", command = "git branch --format='%(refname:short)'" }
```

---

## 🤝 Philosophy

- **Fast** — Zig gives us zero-overhead abstractions and instant startup
- **Simple** — TOML files you can read, edit, and version control
- **Portable** — Single static binary, no runtime dependencies
- **Composable** — Snippets → Workflows → Packs → Workspaces
- **Vim-native** — TUI keybindings that feel natural

---

<p align="center">
  <strong>Stop rewriting commands. Start zipet-ing.</strong>
</p>

<p align="center">
  <code>zipet init && zipet</code>
</p>
