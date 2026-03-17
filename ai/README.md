# zipet MCP Server — AI Agent Interface

> Boceto / Sketch — Servidor MCP para que agentes de código (Claude, Copilot, etc.)
> puedan acceder a snippets, workflows, packs y workspaces de zipet de manera segura.

## Arquitectura

```
┌─────────────────────────────────────────────────────────┐
│                    AI Coding Agent                       │
│              (Claude, Copilot, Cursor, etc.)             │
└──────────────────────┬──────────────────────────────────┘
                       │ MCP Protocol (stdio/SSE)
                       ▼
┌─────────────────────────────────────────────────────────┐
│                  zipet-mcp-server                        │
│                                                         │
│  Tools:                                                 │
│  ├── zipet_search        → Buscar snippets/workflows    │
│  ├── zipet_list          → Listar por categoría/tags    │
│  ├── zipet_get           → Detalle de un snippet        │
│  ├── zipet_run           → Ejecutar snippet (seguro)    │
│  ├── zipet_run_workflow  → Ejecutar workflow completo   │
│  ├── zipet_packs         → Listar/instalar packs       │
│  ├── zipet_workspaces    → Gestionar workspaces         │
│  └── zipet_preview       → Preview de comando expandido │
│                                                         │
│  Resources:                                             │
│  ├── zipet://snippets    → Catálogo completo            │
│  ├── zipet://workflows   → Workflows disponibles        │
│  ├── zipet://packs       → Packs registry               │
│  └── zipet://config      → Configuración actual         │
│                                                         │
│  Safety Layer:                                          │
│  ├── Sandboxing          → Restricción de comandos      │
│  ├── Allowlist/Denylist  → Comandos permitidos/bloqueados│
│  ├── Dry-run mode        → Preview sin ejecutar         │
│  ├── Confirmation gate   → Requiere aprobación humana   │
│  └── Audit log           → Registro de todo lo ejecutado│
└──────────────────────┬──────────────────────────────────┘
                       │ subprocess / IPC
                       ▼
┌─────────────────────────────────────────────────────────┐
│                    zipet CLI (Zig)                       │
│     ~/.config/zipet/{snippets,workflows,packs,...}       │
└─────────────────────────────────────────────────────────┘
```

## ¿Por qué MCP?

- **Estándar abierto**: funciona con cualquier agente que soporte MCP
- **Seguridad**: el servidor controla qué puede y qué no puede hacer la IA
- **Contexto rico**: la IA puede explorar tu colección antes de ejecutar
- **Composable**: la IA puede encadenar snippets en workflows ad-hoc

## Flujo típico

1. Agente pregunta: "necesito limpiar Docker"
2. MCP `zipet_search("docker clean")` → encuentra snippets relevantes
3. MCP `zipet_preview("docker-cleanup", {prune_volumes: "yes"})` → muestra comando
4. MCP `zipet_run("docker-cleanup", {prune_volumes: "yes"})` → ejecuta con safety gate
5. Resultado vuelve al agente con stdout/stderr/exit_code

## Configuración

```json
{
  "mcpServers": {
    "zipet": {
      "command": "uv",
      "args": ["run", "--project", "/path/to/zipet/ai", "python", "server.py"],
      "env": {
        "ZIPET_SAFETY_MODE": "confirm",
        "ZIPET_ALLOWED_TAGS": "*",
        "ZIPET_DENY_COMMANDS": "rm -rf /,mkfs,dd if="
      }
    }
  }
}
```

> `uv` se encarga de crear el venv, instalar deps y ejecutar — sin setup manual.

## Safety Modes

| Modo | Descripción |
|------|-------------|
| `open` | Ejecuta todo sin confirmar (solo para dev/sandbox) |
| `confirm` | Requiere confirmación humana antes de ejecutar |
| `dry-run` | Solo preview, nunca ejecuta |
| `allowlist` | Solo ejecuta snippets/tags en la allowlist |

## Desarrollo

```bash
cd ai/

# uv maneja todo: venv, deps, ejecución
uv run python server.py --test

# Correr tests
uv run pytest

# Agregar dependencia
uv add <package>

# Agregar dep de desarrollo
uv add --dev <package>

# Sync (instalar todo desde lockfile)
uv sync
```
