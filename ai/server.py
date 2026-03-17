#!/usr/bin/env python3
"""
zipet MCP Server — Expone snippets, workflows y packs a agentes de código.

Protocolo: MCP (Model Context Protocol) sobre stdio.
Seguridad: Safety layer configurable (confirm/dry-run/allowlist/open).

BOCETO / SKETCH — Estructura base para implementación completa.
"""

import json
import sys
import os
import subprocess
import logging
from pathlib import Path
from typing import Any, Optional
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

ZIPET_BIN = os.environ.get("ZIPET_BIN", "zipet")
ZIPET_CONFIG_DIR = os.environ.get(
    "ZIPET_CONFIG_DIR",
    os.path.expanduser("~/.config/zipet"),
)
SAFETY_MODE = os.environ.get("ZIPET_SAFETY_MODE", "confirm")  # open|confirm|dry-run|allowlist
ALLOWED_TAGS = os.environ.get("ZIPET_ALLOWED_TAGS", "*")
DENY_COMMANDS = [
    c.strip()
    for c in os.environ.get("ZIPET_DENY_COMMANDS", "rm -rf /,mkfs,dd if=").split(",")
    if c.strip()
]
AUDIT_LOG = os.environ.get("ZIPET_AUDIT_LOG", os.path.expanduser("~/.config/zipet/ai-audit.log"))

logging.basicConfig(
    filename=AUDIT_LOG,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("zipet-mcp")


# ---------------------------------------------------------------------------
# Safety Layer
# ---------------------------------------------------------------------------

@dataclass
class SafetyGate:
    """Controla qué puede ejecutarse y qué no."""
    mode: str = "confirm"
    deny_patterns: list = field(default_factory=list)
    allowed_tags: str = "*"

    def check_command(self, cmd: str) -> tuple[bool, str]:
        """Retorna (allowed, reason)."""
        # Always block deny patterns
        for pattern in self.deny_patterns:
            if pattern in cmd:
                return False, f"Comando bloqueado por denylist: contiene '{pattern}'"

        if self.mode == "dry-run":
            return False, "Modo dry-run: solo preview, no se ejecuta"

        if self.mode == "open":
            return True, "Modo open: ejecución permitida"

        if self.mode == "confirm":
            # En MCP real, esto envía un prompt de confirmación al usuario
            # Por ahora, siempre permite (el agente host maneja confirmación)
            return True, "Requiere confirmación del usuario"

        if self.mode == "allowlist":
            # TODO: verificar tags del snippet contra allowed_tags
            return True, "Verificado contra allowlist"

        return False, "Modo desconocido"


safety = SafetyGate(
    mode=SAFETY_MODE,
    deny_patterns=DENY_COMMANDS,
    allowed_tags=ALLOWED_TAGS,
)


# ---------------------------------------------------------------------------
# Zipet Bridge — Interfaz con el CLI de zipet
# ---------------------------------------------------------------------------

class ZipetBridge:
    """Wrapper sobre el CLI de zipet para acceso programático."""

    def __init__(self, bin_path: str = ZIPET_BIN, config_dir: str = ZIPET_CONFIG_DIR):
        self.bin = bin_path
        self.config_dir = Path(config_dir)

    def _run_cli(self, *args: str, timeout: int = 30) -> dict:
        """Ejecuta zipet CLI y captura resultado."""
        cmd = [self.bin] + list(args)
        logger.info(f"CLI call: {' '.join(cmd)}")
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            return {
                "exit_code": result.returncode,
                "stdout": result.stdout,
                "stderr": result.stderr,
            }
        except subprocess.TimeoutExpired:
            return {"exit_code": -1, "stdout": "", "stderr": "Timeout"}
        except FileNotFoundError:
            return {"exit_code": -1, "stdout": "", "stderr": f"zipet binary not found: {self.bin}"}

    def _parse_toml_snippets(self, directory: str) -> list[dict]:
        """Lee snippets directamente de los archivos TOML."""
        snippets = []
        snippets_dir = Path(directory)
        if not snippets_dir.exists():
            return snippets

        for toml_file in snippets_dir.glob("*.toml"):
            try:
                content = toml_file.read_text()
                snippet = self._parse_snippet_toml(content, toml_file.stem)
                if snippet:
                    snippets.append(snippet)
            except Exception as e:
                logger.warning(f"Error parsing {toml_file}: {e}")
        return snippets

    def _parse_snippet_toml(self, content: str, fallback_name: str = "") -> Optional[dict]:
        """Parser TOML minimalista para snippets de zipet."""
        # Parser básico — en producción usar tomllib (Python 3.11+) o tomli
        snippet = {"name": fallback_name, "desc": "", "cmd": "", "tags": [], "params": []}

        for line in content.splitlines():
            line = line.strip()
            if line.startswith("name"):
                snippet["name"] = self._extract_toml_string(line)
            elif line.startswith("desc"):
                snippet["desc"] = self._extract_toml_string(line)
            elif line.startswith("cmd"):
                snippet["cmd"] = self._extract_toml_string(line)
            elif line.startswith("tags"):
                # Basic array parse: tags = ["a", "b"]
                if "[" in line:
                    inner = line.split("[", 1)[1].rsplit("]", 1)[0]
                    snippet["tags"] = [
                        t.strip().strip('"').strip("'") for t in inner.split(",") if t.strip()
                    ]
        return snippet if snippet["cmd"] else None

    @staticmethod
    def _extract_toml_string(line: str) -> str:
        """Extrae valor string de una línea TOML key = 'value'."""
        if "=" not in line:
            return ""
        val = line.split("=", 1)[1].strip()
        if val.startswith('"') and val.endswith('"'):
            return val[1:-1]
        if val.startswith("'") and val.endswith("'"):
            return val[1:-1]
        # Multiline strings marcados con triple quote se manejan en producción
        return val.strip('"').strip("'")

    # -- Operaciones de alto nivel --

    def list_snippets(self, tag: str = "", workspace: str = "") -> list[dict]:
        """Lista todos los snippets disponibles."""
        args = ["ls"]
        if tag:
            args.extend(["--tag", tag])
        if workspace:
            args.extend(["--workspace", workspace])

        result = self._run_cli(*args)
        if result["exit_code"] != 0:
            # Fallback: leer directamente del filesystem
            return self._parse_toml_snippets(str(self.config_dir / "snippets"))

        # Parse CLI output
        snippets = []
        for line in result["stdout"].strip().splitlines():
            line = line.strip()
            if line and not line.startswith("─") and not line.startswith("╭"):
                snippets.append({"raw": line})
        return snippets

    def get_snippet(self, name: str) -> Optional[dict]:
        """Obtiene detalle completo de un snippet."""
        result = self._run_cli("show", name)
        if result["exit_code"] == 0:
            return {"name": name, "detail": result["stdout"]}

        # Fallback: buscar en archivos
        snippet_file = self.config_dir / "snippets" / f"{name}.toml"
        if snippet_file.exists():
            return self._parse_snippet_toml(snippet_file.read_text(), name)
        return None

    def search(self, query: str) -> list[dict]:
        """Búsqueda fuzzy de snippets y workflows."""
        result = self._run_cli("search", query)
        if result["exit_code"] == 0:
            return [{"raw": line} for line in result["stdout"].strip().splitlines() if line.strip()]
        return []

    def preview_command(self, name: str, params: dict[str, str] = None) -> str:
        """Preview del comando expandido con parámetros, sin ejecutar."""
        args = ["run", "--dry-run", name]
        if params:
            for k, v in params.items():
                args.extend([f"--param", f"{k}={v}"])

        result = self._run_cli(*args)
        return result.get("stdout", "") or result.get("stderr", "")

    def run_snippet(self, name: str, params: dict[str, str] = None) -> dict:
        """Ejecuta un snippet con safety checks."""
        # Primero obtener el comando para safety check
        preview = self.preview_command(name, params)

        allowed, reason = safety.check_command(preview)
        if not allowed:
            logger.warning(f"Blocked execution of '{name}': {reason}")
            return {
                "blocked": True,
                "reason": reason,
                "preview": preview,
                "exit_code": -1,
            }

        logger.info(f"Executing snippet '{name}' with params {params}")

        args = ["run", name]
        if params:
            for k, v in params.items():
                args.extend([f"--param", f"{k}={v}"])

        result = self._run_cli(*args, timeout=120)
        result["blocked"] = False
        return result

    def list_workflows(self) -> list[dict]:
        """Lista workflows disponibles."""
        result = self._run_cli("workflow", "ls")
        if result["exit_code"] == 0:
            return [{"raw": line} for line in result["stdout"].strip().splitlines() if line.strip()]
        return []

    def run_workflow(self, name: str, params: dict[str, str] = None) -> dict:
        """Ejecuta un workflow completo."""
        args = ["workflow", "run", name]
        if params:
            for k, v in params.items():
                args.extend([f"--param", f"{k}={v}"])

        # Safety check on workflow name (can't preview all steps easily)
        allowed, reason = safety.check_command(f"workflow:{name}")
        if not allowed:
            return {"blocked": True, "reason": reason, "exit_code": -1}

        logger.info(f"Executing workflow '{name}' with params {params}")
        result = self._run_cli(*args, timeout=300)
        result["blocked"] = False
        return result

    def list_packs(self, installed_only: bool = False) -> list[dict]:
        """Lista packs disponibles/instalados."""
        args = ["pack", "ls"]
        if installed_only:
            args.append("--installed")
        result = self._run_cli(*args)
        if result["exit_code"] == 0:
            return [{"raw": line} for line in result["stdout"].strip().splitlines() if line.strip()]
        return []

    def install_pack(self, name: str, workspace: str = "") -> dict:
        """Instala un pack."""
        args = ["pack", "install", name]
        if workspace:
            args.extend(["--workspace", workspace])
        return self._run_cli(*args)

    def list_workspaces(self) -> list[dict]:
        """Lista workspaces."""
        result = self._run_cli("workspace", "ls")
        if result["exit_code"] == 0:
            return [{"raw": line} for line in result["stdout"].strip().splitlines() if line.strip()]
        return []


# ---------------------------------------------------------------------------
# MCP Protocol Handler
# ---------------------------------------------------------------------------

bridge = ZipetBridge()

# Tool definitions for MCP
TOOLS = [
    {
        "name": "zipet_search",
        "description": (
            "Search for snippets and workflows in zipet using fuzzy matching. "
            "Use this to find relevant commands before running them. "
            "Returns matching snippets with names, descriptions, and tags."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search query (fuzzy matched against names, descriptions, tags)",
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "zipet_list",
        "description": (
            "List all available snippets, optionally filtered by tag or workspace. "
            "Good for exploring what's available before searching for something specific."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "tag": {
                    "type": "string",
                    "description": "Filter by tag (e.g., 'docker', 'git', 'network')",
                },
                "workspace": {
                    "type": "string",
                    "description": "Filter by workspace name",
                },
            },
        },
    },
    {
        "name": "zipet_get",
        "description": (
            "Get full details of a specific snippet: command template, parameters, "
            "description, tags. Use this before running to understand what it does."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Snippet name (exact match)",
                },
            },
            "required": ["name"],
        },
    },
    {
        "name": "zipet_preview",
        "description": (
            "Preview what command would be executed for a snippet with given parameters, "
            "WITHOUT actually running it. Safe to call anytime. Use this to verify "
            "the expanded command before executing."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Snippet name",
                },
                "params": {
                    "type": "object",
                    "description": "Parameter key-value pairs (e.g., {\"path\": \"/var/log\", \"size\": \"50M\"})",
                    "additionalProperties": {"type": "string"},
                },
            },
            "required": ["name"],
        },
    },
    {
        "name": "zipet_run",
        "description": (
            "Execute a snippet with the given parameters. The command goes through a "
            "safety layer that may block dangerous operations. Always preview first "
            "with zipet_preview to verify the command. Returns stdout, stderr, and exit code."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Snippet name to execute",
                },
                "params": {
                    "type": "object",
                    "description": "Parameter key-value pairs for template expansion",
                    "additionalProperties": {"type": "string"},
                },
            },
            "required": ["name"],
        },
    },
    {
        "name": "zipet_list_workflows",
        "description": (
            "List all available workflows. Workflows are multi-step pipelines that "
            "chain multiple snippets/commands together."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
    {
        "name": "zipet_run_workflow",
        "description": (
            "Execute a complete workflow (multi-step pipeline). Workflows chain "
            "multiple snippets with data passing between steps. May take longer to complete."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Workflow name",
                },
                "params": {
                    "type": "object",
                    "description": "Workflow-level parameters",
                    "additionalProperties": {"type": "string"},
                },
            },
            "required": ["name"],
        },
    },
    {
        "name": "zipet_packs",
        "description": (
            "List available packs (curated collections of snippets & workflows). "
            "Packs cover categories like sysadmin, devops, git, web-dev, pentesting. "
            "Can also install a pack to make its snippets available."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": ["list", "install"],
                    "description": "Action to perform",
                },
                "name": {
                    "type": "string",
                    "description": "Pack name (required for install)",
                },
                "workspace": {
                    "type": "string",
                    "description": "Target workspace for installation",
                },
            },
            "required": ["action"],
        },
    },
    {
        "name": "zipet_workspaces",
        "description": (
            "List available workspaces. Workspaces organize snippets by project or context."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {},
        },
    },
]

# Resources for MCP
RESOURCES = [
    {
        "uri": "zipet://snippets",
        "name": "Zipet Snippets Catalog",
        "description": "Complete catalog of all available snippets",
        "mimeType": "application/json",
    },
    {
        "uri": "zipet://workflows",
        "name": "Zipet Workflows",
        "description": "All available multi-step workflows",
        "mimeType": "application/json",
    },
    {
        "uri": "zipet://packs",
        "name": "Zipet Packs Registry",
        "description": "Available and installed snippet packs",
        "mimeType": "application/json",
    },
    {
        "uri": "zipet://config",
        "name": "Zipet Configuration",
        "description": "Current zipet configuration and safety settings",
        "mimeType": "application/json",
    },
]


def handle_tool_call(name: str, arguments: dict) -> Any:
    """Despacha llamada a tool y retorna resultado."""

    if name == "zipet_search":
        results = bridge.search(arguments["query"])
        return results

    elif name == "zipet_list":
        return bridge.list_snippets(
            tag=arguments.get("tag", ""),
            workspace=arguments.get("workspace", ""),
        )

    elif name == "zipet_get":
        snippet = bridge.get_snippet(arguments["name"])
        return snippet or {"error": f"Snippet '{arguments['name']}' not found"}

    elif name == "zipet_preview":
        preview = bridge.preview_command(
            arguments["name"],
            arguments.get("params", {}),
        )
        return {"command": preview, "note": "This is a preview. Use zipet_run to execute."}

    elif name == "zipet_run":
        return bridge.run_snippet(
            arguments["name"],
            arguments.get("params", {}),
        )

    elif name == "zipet_list_workflows":
        return bridge.list_workflows()

    elif name == "zipet_run_workflow":
        return bridge.run_workflow(
            arguments["name"],
            arguments.get("params", {}),
        )

    elif name == "zipet_packs":
        action = arguments["action"]
        if action == "list":
            return bridge.list_packs()
        elif action == "install":
            if "name" not in arguments:
                return {"error": "Pack name required for install"}
            return bridge.install_pack(
                arguments["name"],
                workspace=arguments.get("workspace", ""),
            )

    elif name == "zipet_workspaces":
        return bridge.list_workspaces()

    return {"error": f"Unknown tool: {name}"}


def handle_resource(uri: str) -> Any:
    """Lee un resource MCP."""
    if uri == "zipet://snippets":
        return bridge.list_snippets()
    elif uri == "zipet://workflows":
        return bridge.list_workflows()
    elif uri == "zipet://packs":
        return bridge.list_packs()
    elif uri == "zipet://config":
        return {
            "safety_mode": SAFETY_MODE,
            "allowed_tags": ALLOWED_TAGS,
            "deny_commands": DENY_COMMANDS,
            "config_dir": ZIPET_CONFIG_DIR,
        }
    return {"error": f"Unknown resource: {uri}"}


# ---------------------------------------------------------------------------
# MCP stdio transport
# ---------------------------------------------------------------------------

def send_response(response: dict):
    """Envía respuesta JSON-RPC por stdout."""
    msg = json.dumps(response)
    sys.stdout.write(msg + "\n")
    sys.stdout.flush()


def handle_message(message: dict) -> dict:
    """Procesa un mensaje JSON-RPC del MCP."""
    method = message.get("method", "")
    msg_id = message.get("id")
    params = message.get("params", {})

    # -- Initialize --
    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {},
                    "resources": {},
                },
                "serverInfo": {
                    "name": "zipet-mcp",
                    "version": "0.1.0",
                },
            },
        }

    # -- Notifications (no response needed) --
    if method == "notifications/initialized":
        return None

    # -- List tools --
    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"tools": TOOLS},
        }

    # -- Call tool --
    if method == "tools/call":
        tool_name = params.get("name", "")
        tool_args = params.get("arguments", {})
        try:
            result = handle_tool_call(tool_name, tool_args)
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(result, indent=2, default=str),
                        }
                    ]
                },
            }
        except Exception as e:
            logger.error(f"Tool call error: {e}")
            return {
                "jsonrpc": "2.0",
                "id": msg_id,
                "result": {
                    "content": [{"type": "text", "text": f"Error: {e}"}],
                    "isError": True,
                },
            }

    # -- List resources --
    if method == "resources/list":
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {"resources": RESOURCES},
        }

    # -- Read resource --
    if method == "resources/read":
        uri = params.get("uri", "")
        result = handle_resource(uri)
        return {
            "jsonrpc": "2.0",
            "id": msg_id,
            "result": {
                "contents": [
                    {
                        "uri": uri,
                        "mimeType": "application/json",
                        "text": json.dumps(result, indent=2, default=str),
                    }
                ]
            },
        }

    # -- Unknown method --
    return {
        "jsonrpc": "2.0",
        "id": msg_id,
        "error": {
            "code": -32601,
            "message": f"Method not found: {method}",
        },
    }


def main():
    """Main loop — lee JSON-RPC de stdin, responde por stdout."""
    logger.info("zipet MCP server starting")
    logger.info(f"Safety mode: {SAFETY_MODE}")

    # Test mode
    if "--test" in sys.argv:
        print("zipet MCP server — test mode")
        print(f"Safety: {SAFETY_MODE}")
        print(f"Tools: {len(TOOLS)}")
        print(f"Resources: {len(RESOURCES)}")
        print(f"Config dir: {ZIPET_CONFIG_DIR}")

        # Quick self-test
        print("\n--- Tool list ---")
        for tool in TOOLS:
            print(f"  {tool['name']}: {tool['description'][:60]}...")

        print("\n--- Safety check ---")
        ok, reason = safety.check_command("echo hello")
        print(f"  'echo hello': allowed={ok}, reason={reason}")
        ok, reason = safety.check_command("rm -rf /")
        print(f"  'rm -rf /': allowed={ok}, reason={reason}")

        print("\nTest passed ✓")
        return

    # Stdio MCP loop
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            message = json.loads(line)
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON: {e}")
            continue

        response = handle_message(message)
        if response is not None:
            send_response(response)


if __name__ == "__main__":
    main()
