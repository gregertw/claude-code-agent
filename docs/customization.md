# Customization Guide

## Installing Capabilities

Capabilities are optional features that extend what the agent can do. Each
capability is defined in a single file under `templates/capabilities/` in the
repo (or `templates/capabilities/` in your brain directory after setup).

**Available capabilities:**

| Capability | Description |
|---|---|
| `agentmail` | Agent email address for sending notifications and receiving instructions |

**How to install:**

Start a session in your brain directory and say:
```
Install the <name> capability.
```

The AI reads the capability file, asks for any required configuration (API keys,
preferences), and makes all necessary changes to your brain directory — adding
task types, recurring tasks, skills, and environment variables as needed.

You can also trigger installation by dropping a file in `INBOX/`:
```
Install the agentmail capability. My API key is am_us_...
```

Or by adding an inline comment on an ACTIONS.md item:
```
> Install the agentmail capability
```

Each capability file documents exactly what gets created and modified, and
includes uninstallation instructions.

---

## Adding Your Own Recurring Tasks

Add custom recurring tasks to `ai/instructions/personal-tasks.md` in your brain
directory. This file is never overwritten by upgrades — it's your space for custom
recurring work.

Follow the same format as `default-tasks.md`:

```markdown
## N. Task Name

**Type**: <one of: Email, Calendar, Research, Writing, Memory Management, Summary, Code>
**MCP required**: <ActingWeb | Gmail | Google Calendar | none>
**Frequency**: <every run | Mondays only | first of month | etc.>

Description of what the task should do...
```

Keep each task small (under 2 minutes). The agent will defer tasks that seem too large.

> **Note**: Do not edit `default-tasks.md` directly — it is a system file that gets
> updated on upgrade. Use `personal-tasks.md` for your additions instead.

## Template Upgrade Strategy

Template files are divided into **system files** and **user files**:

| Type | Files | On upgrade |
|---|---|---|
| System | `CLAUDE.md`, `tasks.md`, `default-tasks.md` | Overwritten with latest version |
| User | `personal.md`, `style.md`, `personal-tasks.md`, `ACTIONS.md` | Preserved — never overwritten |

To upgrade system files on an existing brain, run:

```bash
~/scripts/install-templates.sh --upgrade
```

This updates the agent's core instructions while preserving all your customizations.

## Adding MCP Servers

1. Install the MCP server (usually via `npx` or `npm install -g`)
2. Add to Claude Code: `claude mcp add <name> -- <command> <args>`
3. Update `~/.claude/settings.json` to allow the new tools:
   ```json
   "mcp__<name>"
   ```
4. Update your default-tasks.md if the new MCP enables new recurring tasks

## Changing the Schedule

Use `agent-manager.sh` from your local machine — it handles both the server
config and the EventBridge scheduler in one command:

```bash
# Switch modes
./agent-manager.sh --always-on        # run 24/7, remove scheduler
./agent-manager.sh --scheduled        # wake every 60 min (default)
./agent-manager.sh --scheduled 30     # wake every 30 min
./agent-manager.sh --scheduled 120    # wake every 2 hours
```

## Customizing the Master Prompt

The orchestrator prompt is in `agent-orchestrator.sh` (the `MASTER_PROMPT` variable). You can customize it to change how the agent behaves — add personality, change priorities, add new task sources.

The prompt is templated with variables from `agent.conf`:
- `${OWNER_NAME}` — your name
- `${OUTPUT_FOLDER}` — where outputs and INBOX live

## Customizing Claude Code Permissions

Permissions are split across two files:

- **`~/.claude/settings.json`** (user-level) — tool permissions (allow/deny lists).
  On Option B, this is installed by `setup.sh`.
- **`<brain>/.claude/settings.local.json`** (project-level) — hooks and
  project-specific overrides. Installed by `install-templates.sh`.

The default permissions allow the agent to work autonomously for typical tasks
(file operations, web search, curl for API calls, Python scripts) while blocking
destructive operations:

```json
{
  "permissions": {
    "allow": [
      "mcp__actingweb", "mcp__gmail", "mcp__google-calendar",
      "Read", "Write", "Edit", "Glob", "Grep",
      "WebSearch", "WebFetch(domain:*)",
      "Bash(curl:*)", "Bash(source:*)", "Bash(python3:*)",
      "Bash(ls:*)", "Bash(cat:*)", "Bash(mkdir:*)", "Bash(cp:*)", "Bash(mv:*)",
      "..."
    ],
    "deny": [
      "Bash(rm -rf:*)", "Bash(rm -r:*)",
      "Bash(git push --force:*)", "Bash(git reset --hard:*)"
    ]
  }
}
```

A **PreToolUse hook** (`protect-settings.sh`) prevents the agent from editing
settings files, hooks, or `.env` — these must be edited manually.

Add tool patterns to `allow` for new capabilities. Be cautious with broad Bash permissions.

## Cost Optimization

| Approach | Monthly Cost |
|---|---|
| Scheduled, 2-hourly, t3.medium | ~$8 |
| Scheduled, hourly, t3.large | ~$18 |
| Always-on, t3.large, reserved 1yr | ~$33 |
| Always-on, t3.large, on-demand | ~$67 |
| Graviton (t4g.large), always-on, reserved | ~$24 |
