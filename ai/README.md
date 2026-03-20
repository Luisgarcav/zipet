# zipet MCP Server — AI Agent Interface

> MCP server that lets AI coding agents (Claude, Cursor, Copilot, pi, etc.)
> search, preview, and execute zipet snippets, workflows, and packs — safely.

## What Is This?

This is a [Model Context Protocol (MCP)](https://modelcontextprotocol.io/) server that acts as a bridge between AI agents and the **zipet** CLI. Instead of writing raw shell commands, AI agents can use your curated, tested snippet collection through a safety-controlled interface.

```
┌─────────────────────────────────────────────────────────┐
│                    AI Coding Agent                       │
│              (Claude, Cursor, Copilot, pi, etc.)        │
└──────────────────────┬──────────────────────────────────┘
                       │ MCP Protocol (stdio)
                       ▼
┌─────────────────────────────────────────────────────────┐
│                  zipet-mcp-server                        │
│                                                         │
│  Tools:                                                 │
│  ├── zipet_search        → Fuzzy search snippets        │
│  ├── zipet_list          → List by tag/workspace        │
│  ├── zipet_get           → Full snippet details         │
│  ├── zipet_run           → Execute snippet (safe)       │
│  ├── zipet_run_workflow  → Run multi-step workflow      │
│  ├── zipet_packs         → List/install packs           │
│  ├── zipet_workspaces    → Manage workspaces            │
│  └── zipet_preview       → Dry-run command preview      │
│                                                         │
│  Resources:                                             │
│  ├── zipet://snippets    → Full snippet catalog         │
│  ├── zipet://workflows   → Available workflows          │
│  ├── zipet://packs       → Packs registry               │
│  └── zipet://config      → Current configuration        │
│                                                         │
│  Safety Layer:                                          │
│  ├── Risk classification → safe/moderate/dangerous      │
│  ├── Allowlist/Denylist  → Command filtering            │
│  ├── Dry-run mode        → Preview without executing    │
│  ├── Confirmation gate   → Requires human approval      │
│  └── Audit log           → Full execution history       │
└──────────────────────┬──────────────────────────────────┘
                       │ subprocess / IPC
                       ▼
┌─────────────────────────────────────────────────────────┐
│                    zipet CLI (Zig)                       │
│     ~/.config/zipet/{snippets,workflows,packs,...}       │
└─────────────────────────────────────────────────────────┘
```

## Prerequisites

- **zipet** CLI installed and available in your `PATH`
- **[uv](https://docs.astral.sh/uv/)** — the fast Python package manager (handles everything: venv, deps, execution)
- **Python 3.10+** (managed by `uv`, no manual install needed)

To install `uv`:

```bash
# macOS / Linux
curl -LsSf https://astral.sh/uv/install.sh | sh

# Or with Homebrew
brew install uv
```

---

## Connecting to the MCP Server

The server communicates over **stdio** using the JSON-RPC-based MCP protocol. Each AI client has its own configuration file where you register MCP servers.

> **Important:** Replace `/path/to/zipet/ai` with the **absolute path** to this `ai/` directory on your machine.

### Claude Desktop

Edit your Claude Desktop config file:

- **macOS**: `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Linux**: `~/.config/Claude/claude_desktop_config.json`
- **Windows**: `%APPDATA%\Claude\claude_desktop_config.json`

Add the `zipet` server:

```json
{
  "mcpServers": {
    "zipet": {
      "command": "uv",
      "args": ["run", "--project", "/path/to/zipet/ai", "python", "server.py"],
      "env": {
        "ZIPET_SAFETY_MODE": "confirm",
        "ZIPET_BIN": "zipet",
        "ZIPET_ALLOWED_TAGS": "*",
        "ZIPET_DENY_COMMANDS": "rm -rf /,mkfs,dd if="
      }
    }
  }
}
```

After saving, **restart Claude Desktop**. You should see the zipet tools appear in the tools menu (hammer icon).

### Cursor

Open Cursor Settings → Features → MCP Servers, or edit:

- `~/.cursor/mcp.json` (global)
- `.cursor/mcp.json` (per-project)

```json
{
  "mcpServers": {
    "zipet": {
      "command": "uv",
      "args": ["run", "--project", "/path/to/zipet/ai", "python", "server.py"],
      "env": {
        "ZIPET_SAFETY_MODE": "confirm"
      }
    }
  }
}
```

Restart Cursor and the tools will be available in Agent mode.

### VS Code (GitHub Copilot)

Add to your VS Code `settings.json` or `.vscode/mcp.json`:

```json
{
  "mcp": {
    "servers": {
      "zipet": {
        "command": "uv",
        "args": ["run", "--project", "/path/to/zipet/ai", "python", "server.py"],
        "env": {
          "ZIPET_SAFETY_MODE": "confirm"
        }
      }
    }
  }
}
```

### Windsurf

Edit `~/.codeium/windsurf/mcp_config.json`:

```json
{
  "mcpServers": {
    "zipet": {
      "command": "uv",
      "args": ["run", "--project", "/path/to/zipet/ai", "python", "server.py"],
      "env": {
        "ZIPET_SAFETY_MODE": "confirm"
      }
    }
  }
}
```

### pi (Coding Agent)

Add to your pi MCP configuration:

```json
{
  "mcpServers": {
    "zipet": {
      "command": "uv",
      "args": ["run", "--project", "/path/to/zipet/ai", "python", "server.py"],
      "env": {
        "ZIPET_SAFETY_MODE": "open"
      }
    }
  }
}
```

### Generic / Custom MCP Client

Any MCP-compatible client can connect. The server uses **stdio transport**:

```bash
# Launch the server (it reads JSON-RPC from stdin, writes to stdout)
uv run --project /path/to/zipet/ai python server.py
```

The protocol follows the [MCP specification (2024-11-05)](https://spec.modelcontextprotocol.io/). The server responds to:

| Method                     | Description                        |
| -------------------------- | ---------------------------------- |
| `initialize`               | Handshake, returns capabilities    |
| `tools/list`               | Lists all available tools          |
| `tools/call`               | Executes a tool by name            |
| `resources/list`           | Lists available resources          |
| `resources/read`           | Reads a resource by URI            |

---

## Verify the Connection

Run the built-in test to make sure everything works:

```bash
cd ai/
uv run python server.py --test
```

Expected output:

```
zipet MCP server — test mode
Safety: confirm
Tools: 9
Resources: 4
Config dir: ~/.config/zipet

--- Tool list ---
  zipet_search: Search for snippets and workflows in zipet using fuzz...
  zipet_list: List all available snippets, optionally filtered by tag...
  ...

--- Safety check ---
  'echo hello': allowed=True, reason=Requiere confirmación del usuario
  'rm -rf /': allowed=False, reason=Comando bloqueado por denylist: contiene 'rm -rf /'

Test passed ✓
```

You can also test the MCP protocol directly by piping JSON-RPC messages:

```bash
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | uv run --project /path/to/zipet/ai python server.py
```

---

## Environment Variables

All configuration is done through environment variables (set in the `env` block of your MCP config):

| Variable               | Default                          | Description                                        |
| ---------------------- | -------------------------------- | -------------------------------------------------- |
| `ZIPET_SAFETY_MODE`    | `confirm`                        | Safety mode: `open`, `confirm`, `dry-run`, `allowlist` |
| `ZIPET_BIN`            | `zipet`                          | Path to the zipet binary                           |
| `ZIPET_CONFIG_DIR`     | `~/.config/zipet`                | Path to zipet config directory                     |
| `ZIPET_ALLOWED_TAGS`   | `*`                              | Comma-separated tags to allow (or `*` for all)     |
| `ZIPET_DENY_COMMANDS`  | `rm -rf /,mkfs,dd if=`          | Comma-separated patterns to always block           |
| `ZIPET_AUDIT_LOG`      | `~/.config/zipet/ai-audit.log`   | Path to the audit log file                         |

---

## Safety Modes

The safety layer controls what the AI agent can execute:

| Mode        | Behavior                                                            |
| ----------- | ------------------------------------------------------------------- |
| `open`      | Executes everything (only for local dev / sandboxed environments)   |
| `confirm`   | Allows execution but flags it for human confirmation by the host    |
| `dry-run`   | Preview only — never executes any command                           |
| `allowlist` | Only executes snippets whose tags match `ZIPET_ALLOWED_TAGS`       |

**Recommended profiles:**

```jsonc
// Development (local machine, trusted agent)
{ "ZIPET_SAFETY_MODE": "open", "ZIPET_ALLOWED_TAGS": "*" }

// Production (server, CI/CD)
{ "ZIPET_SAFETY_MODE": "confirm", "ZIPET_ALLOWED_TAGS": "sysadmin,monitoring,docker", "ZIPET_DENY_COMMANDS": "rm -rf,mkfs,dd if=,shutdown,reboot" }

// Read-only (demos, auditing)
{ "ZIPET_SAFETY_MODE": "dry-run" }
```

---

## Available Tools

| Tool                    | Description                                                          |
| ----------------------- | -------------------------------------------------------------------- |
| `zipet_search`          | Fuzzy search across snippets, workflows, names, descriptions, tags   |
| `zipet_list`            | List snippets filtered by tag and/or workspace                       |
| `zipet_get`             | Get full details of a specific snippet (command, params, tags)       |
| `zipet_preview`         | Preview the expanded command without executing — always safe         |
| `zipet_run`             | Execute a snippet with parameters (goes through safety layer)        |
| `zipet_list_workflows`  | List available multi-step workflows                                  |
| `zipet_run_workflow`    | Execute a complete workflow pipeline                                 |
| `zipet_packs`           | List or install curated snippet packs                                |
| `zipet_workspaces`      | List available workspaces                                            |

### Typical Agent Flow

```
User: "I need to clean up Docker"

Agent:
  1. zipet_search("docker clean")         → finds matching snippets
  2. zipet_get("docker-cleanup")          → reads full details & params
  3. zipet_preview("docker-cleanup", {"prune_volumes": "yes"})  → sees the command
  4. zipet_run("docker-cleanup", {"prune_volumes": "yes"})      → executes safely
  5. Returns stdout/stderr/exit_code to user
```

---

## Development

```bash
cd ai/

# Run the test suite
uv run python server.py --test

# Run the safety layer self-test
uv run python safety.py

# Run tests (pytest)
uv run pytest

# Add a dependency
uv add <package>

# Add a dev dependency
uv add --dev <package>

# Sync all dependencies from lockfile
uv sync
```

### Project Structure

```
ai/
├── server.py              # MCP server — main entry point (stdio transport)
├── safety.py              # Safety layer — risk classification & policy engine
├── prompts.py             # MCP prompts — contextual instructions for agents
├── security_policy.json   # Default security policy
├── mcp_config_example.json # Example configs for different AI clients
├── pyproject.toml         # Python project config (managed by uv)
├── uv.lock                # Locked dependencies
└── README.md              # This file
```

---

## Troubleshooting

### "zipet binary not found"

The server calls the `zipet` CLI as a subprocess. Make sure it's in your PATH:

```bash
which zipet        # should print the path
zipet --version    # should print the version
```

If it's installed elsewhere, set `ZIPET_BIN` in your MCP config's `env` block:

```json
"env": { "ZIPET_BIN": "/home/user/.local/bin/zipet" }
```

### "uv: command not found"

Your MCP client can't find `uv`. Either:

1. Use the full path to `uv` in the `command` field:
   ```json
   "command": "/home/user/.cargo/bin/uv"
   ```
2. Or ensure `uv` is in the PATH that your MCP client inherits.

### Server doesn't appear in Claude Desktop / Cursor

- Make sure you edited the **correct config file** (paths listed above).
- Make sure the JSON is valid (no trailing commas, correct brackets).
- **Restart the application** after editing the config.
- Check the audit log at `~/.config/zipet/ai-audit.log` for errors.

### Testing the raw protocol

You can interact with the server directly to debug:

```bash
# Send initialize
echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  | uv run --project /path/to/zipet/ai python server.py

# List tools
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
  | uv run --project /path/to/zipet/ai python server.py

# Call a tool
echo '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"zipet_search","arguments":{"query":"docker"}}}' \
  | uv run --project /path/to/zipet/ai python server.py
```

---

## Why MCP?

- **Open standard** — works with any agent that supports MCP (Claude, Cursor, Copilot, Windsurf, pi, and more)
- **Safety first** — the server controls what the AI can and cannot execute
- **Rich context** — the AI can explore your snippet collection before running anything
- **Composable** — the AI can chain snippets into ad-hoc workflows

## License

Same as the main zipet project — see [LICENSE](../LICENSE).
