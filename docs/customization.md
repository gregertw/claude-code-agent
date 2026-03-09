# Customization Guide

## Adding Default Tasks

Edit `ai/instructions/default-tasks.md` in your brain directory. Follow the existing format:

```markdown
## N. Task Name

**Type**: <one of: Email, Calendar, Research, Writing, Memory Management, Summary, Code>
**MCP required**: <ActingWeb | Gmail | Google Calendar | none>
**Frequency**: <every run | Mondays only | first of month | etc.>

Description of what the task should do...
```

Keep each task small (under 2 minutes). The agent will defer tasks that seem too large.

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

Edit `~/.claude/settings.json` to control what Claude can do autonomously:

```json
{
  "permissions": {
    "allow": [
      "mcp__actingweb",
      "Read", "Write", "Edit", "Glob", "Grep",
      "Bash(cat *)", "Bash(mkdir *)", "Bash(mv *)",
      "WebSearch", "WebFetch"
    ],
    "deny": []
  }
}
```

Add tool patterns to `allow` for new capabilities. Be cautious with broad Bash permissions.

## Cost Optimization

| Approach | Monthly Cost |
|---|---|
| Scheduled, 2-hourly, t3.medium | ~$8 |
| Scheduled, hourly, t3.large | ~$18 |
| Always-on, t3.large, reserved 1yr | ~$33 |
| Always-on, t3.large, on-demand | ~$67 |
| Graviton (t4g.large), always-on, reserved | ~$24 |
