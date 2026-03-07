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

```bash
# Switch modes
sudo ~/scripts/set-schedule-mode.sh scheduled   # or always-on

# Change interval (from your local machine)
./deploy-scheduler.sh <instance-id> 30           # every 30 min
./deploy-scheduler.sh <instance-id> 120          # every 2 hours

# Pause scheduling
aws scheduler update-schedule --name agent-server-start --state DISABLED --region <region> ...

# Resume
aws scheduler update-schedule --name agent-server-start --state ENABLED --region <region> ...
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
      "Bash(dropbox-cli *)",
      "WebSearch", "WebFetch"
    ],
    "deny": []
  }
}
```

Add tool patterns to `allow` for new capabilities. Be cautious with broad Bash permissions.

## Using a Different Cloud Sync

The system uses Dropbox but any sync service works if it:
1. Has a headless Linux CLI
2. Supports selective sync
3. Reports sync status (so the orchestrator knows when files are ready)

To adapt: replace the Dropbox sections in `setup.sh` and the sync-wait logic in `agent-orchestrator.sh`.

## Cost Optimization

| Approach | Monthly Cost |
|---|---|
| Scheduled, 2-hourly, t3.medium | ~$8 |
| Scheduled, hourly, t3.large | ~$18 |
| Always-on, t3.large, reserved 1yr | ~$33 |
| Always-on, t3.large, on-demand | ~$67 |
| Graviton (t4g.large), always-on, reserved | ~$24 |

For Graviton (ARM): change the AMI to Ubuntu ARM64 and the Dropbox download URL in setup.sh (already handled automatically).
