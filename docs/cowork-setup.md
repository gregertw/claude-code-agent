# Running the Self-Improving Agent with Claude Cowork

The simplest way to run this agent is with Claude Desktop's Cowork feature,
using "Work in a folder" pointed at your brain directory.

## What Works

- **ActingWeb memories** — fully supported via MCP
- **Instruction files** — Claude reads `CLAUDE.md` and instruction files directly from the brain folder
- **INBOX tasks** — drop `.txt` or `.md` files into the `output/INBOX/` folder
- **File persistence** — everything lives on your local filesystem

## What's Different from AWS

| Feature | AWS Agent Server | Claude Cowork |
|---|---|---|
| Runs unattended | Yes (cron/EventBridge) | No — requires you to start a session |
| Dropbox sync | Automatic | Use Dropbox as the brain directory |
| Gmail/Calendar | MCP servers (headless) | MCP servers (browser-based OAuth) |
| File persistence | Dropbox syncs everything | Local filesystem |
| Cost | ~$16-67/month AWS | Included in Claude Pro/Team plan |

## Setup Steps

1. **Set up the brain directory** — follow Steps A1–A2 in the main [README](../README.md#step-a1-choose-a-directory)
2. **Add MCP servers** in Claude Desktop settings (Settings → MCP Servers):
   - ActingWeb: `https://ai.actingweb.io/mcp` (account auto-created on first auth)
   - Gmail/Calendar: optional, requires Google OAuth credentials
3. **Start Cowork** — open Claude Desktop, start a Cowork session, choose **"Work in a folder"**, and select your brain directory
4. Claude reads `CLAUDE.md` automatically and follows the agent instructions

## Recurring Runs

Since Cowork can't auto-schedule, you have two options:

1. **Manual trigger**: Start a new session and paste "Run the default task cycle" — Claude will read `tasks.md` and execute
2. **ActingWeb task queue**: Queue tasks from any AI tool; when you open Cowork, tell it to check for queued tasks

## Recommended Workflow

Use Cowork as your primary interactive environment and optionally the AWS server as a background worker:
- Cowork for: conversations, complex tasks, interactive work
- AWS for: email triage, calendar checks, inbox processing, memory hygiene
- Both share: ActingWeb memories, Dropbox files (if synced)
