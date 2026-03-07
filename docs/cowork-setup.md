# Running the Self-Improving Agent in Claude Cowork

You don't need AWS to run this agent system. Claude Cowork (claude.ai projects) can serve as the execution environment with some adaptations.

## What Works the Same

- **ActingWeb memories** — fully supported via MCP in Cowork
- **Instruction files** — upload `ai/instructions/tasks.md`, `default-tasks.md`, `personal.md`, and `style.md` to your project
- **INBOX tasks** — drop files into the project or use ActingWeb `work_on_task`
- **Skills** — install the `managing-actingweb-memory` skill for memory management

## What's Different

| Feature | AWS Agent Server | Claude Cowork |
|---|---|---|
| Runs unattended | Yes (cron/EventBridge) | No — requires you to start a session |
| Dropbox sync | Automatic | Manual upload or use Dropbox MCP |
| Gmail/Calendar | MCP servers (headless) | MCP servers (browser-based OAuth) |
| File persistence | Dropbox syncs everything | Project files persist, but no filesystem |
| Cost | ~$16-67/month AWS | Included in Claude Pro/Team plan |

## Setup Steps

1. **Create a Cowork project** at claude.ai
2. **Upload instruction files** from the `templates/` directory
3. **Add MCP connections**:
   - ActingWeb: Add `https://ai.actingweb.io/mcp` as an MCP server (OAuth)
   - Gmail/Calendar: Add via Cowork's MCP settings
4. **Install the ActingWeb skill**: Download from https://ai.actingweb.io and install in Cowork
5. **Start a session** and paste the orchestrator prompt (from `agent-orchestrator.sh`, the `MASTER_PROMPT` section)

## Recurring Runs

Since Cowork can't auto-schedule, you have two options:

1. **Manual trigger**: Start a new session and paste "Run the default task cycle" — Claude will read `tasks.md` and execute
2. **ActingWeb task queue**: Queue tasks from any AI tool; when you open Cowork, tell it to check for queued tasks

## Recommended Workflow

Use Cowork as your primary interactive environment and the AWS server as the background worker:
- Cowork for: conversations, complex tasks, interactive work
- AWS for: email triage, calendar checks, inbox processing, memory hygiene
- Both share: ActingWeb memories, Dropbox files (if synced)
