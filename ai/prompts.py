"""
zipet MCP Prompts — Instrucciones contextuales para agentes de IA.

MCP Prompts permiten que el servidor sugiera al agente cómo usar las tools
de manera óptima y segura. Es la guía de "cómo usar zipet" que el agente
recibe como contexto.

BOCETO — Define los prompts estáticos y dinámicos.
"""


# ---------------------------------------------------------------------------
# System Prompt — Instrucción base para el agente
# ---------------------------------------------------------------------------

SYSTEM_PROMPT = """\
You have access to **zipet**, a terminal snippet & workflow manager. Use it to find
and execute pre-built, tested commands instead of writing raw shell commands.

## How to use zipet tools

1. **Search first**: Always use `zipet_search` or `zipet_list` to find existing snippets
   before writing custom commands. zipet has curated collections for sysadmin, devops,
   git, web development, pentesting, and more.

2. **Preview before running**: Use `zipet_preview` to see the expanded command with
   parameters before executing. This lets you verify the command is correct.

3. **Execute safely**: Use `zipet_run` to execute. The safety layer will block
   dangerous commands. Always provide all required parameters.

4. **Use workflows for multi-step tasks**: If a task involves multiple sequential
   commands, check `zipet_list_workflows` for existing pipelines.

5. **Install packs for new domains**: If you need snippets for a specific domain
   (e.g., kubernetes, terraform), use `zipet_packs` to install curated collections.

## Parameter conventions
- Parameters use `{{param}}` syntax in templates
- Provide params as key-value objects: `{"path": "/var/log", "size": "100M"}`
- Common params: `{{path}}`, `{{name}}`, `{{count}}`, `{{port}}`, `{{host}}`

## Safety rules
- NEVER bypass the safety layer
- ALWAYS preview commands with destructive potential
- If a command is blocked, suggest alternatives or ask the user
- Prefer zipet snippets over raw shell commands — they're tested and parameterized

## Available packs
- **sysadmin**: disk, network, services, users, logs
- **devops**: docker, systemd, monitoring, deployment
- **git-power**: advanced git operations, history, recovery
- **web-dev**: HTTP testing, SSL, DNS, performance
- **pentesting**: recon, scanning, enumeration (use responsibly)
"""


# ---------------------------------------------------------------------------
# MCP Prompt Templates — Contextuales según la tarea
# ---------------------------------------------------------------------------

PROMPTS = [
    {
        "name": "zipet_guide",
        "description": (
            "General guide for using zipet tools effectively. "
            "Include this when the user wants to run terminal commands."
        ),
        "arguments": [],
        "messages": [
            {
                "role": "system",
                "content": {"type": "text", "text": SYSTEM_PROMPT},
            }
        ],
    },
    {
        "name": "zipet_task_runner",
        "description": (
            "Structured approach for executing a terminal task using zipet. "
            "Guides the agent through search → preview → confirm → execute flow."
        ),
        "arguments": [
            {
                "name": "task",
                "description": "Description of the terminal task to accomplish",
                "required": True,
            }
        ],
        "messages": [
            {
                "role": "system",
                "content": {
                    "type": "text",
                    "text": (
                        "Follow this workflow to accomplish the terminal task:\n\n"
                        "1. **Search**: Use `zipet_search` with keywords from the task\n"
                        "2. **Evaluate**: Review results, pick the best snippet\n"
                        "3. **Inspect**: Use `zipet_get` to see full details and required params\n"
                        "4. **Preview**: Use `zipet_preview` with params to verify the command\n"
                        "5. **Confirm**: Show the user the command and ask for confirmation\n"
                        "6. **Execute**: Use `zipet_run` with the confirmed params\n"
                        "7. **Report**: Show the result (stdout/stderr/exit_code)\n\n"
                        "If no snippet exists, tell the user and suggest creating one.\n"
                        "If the task needs multiple steps, check for a workflow first."
                    ),
                },
            },
            {
                "role": "user",
                "content": {
                    "type": "text",
                    "text": "Task: {{task}}",
                },
            },
        ],
    },
    {
        "name": "zipet_explorer",
        "description": (
            "Explore what's available in zipet for a specific domain or topic. "
            "Good for discovery and onboarding."
        ),
        "arguments": [
            {
                "name": "domain",
                "description": "Domain to explore (e.g., 'docker', 'networking', 'git')",
                "required": True,
            }
        ],
        "messages": [
            {
                "role": "system",
                "content": {
                    "type": "text",
                    "text": (
                        "The user wants to explore zipet's capabilities for a specific domain.\n\n"
                        "1. Use `zipet_list` with relevant tags\n"
                        "2. Use `zipet_search` with domain keywords\n"
                        "3. Check `zipet_packs` for installable collections\n"
                        "4. Present a organized summary of what's available\n"
                        "5. Suggest the most useful snippets for common tasks in that domain"
                    ),
                },
            },
            {
                "role": "user",
                "content": {
                    "type": "text",
                    "text": "Show me what zipet has for: {{domain}}",
                },
            },
        ],
    },
]


def get_prompt(name: str, arguments: dict = None) -> dict:
    """Obtiene un prompt por nombre, con argumentos expandidos."""
    for prompt in PROMPTS:
        if prompt["name"] == name:
            if arguments:
                # Expand arguments in messages
                import copy
                expanded = copy.deepcopy(prompt)
                for msg in expanded["messages"]:
                    if isinstance(msg["content"], dict) and "text" in msg["content"]:
                        text = msg["content"]["text"]
                        for key, value in arguments.items():
                            text = text.replace(f"{{{{{key}}}}}", value)
                        msg["content"]["text"] = text
                return expanded
            return prompt
    return None
