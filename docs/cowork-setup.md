# Running the Self-Improving Agent with Claude Cowork

The simplest way to run this agent is with Claude Desktop's Cowork feature,
using "Work in a folder" pointed at your brain directory.

## What Works

- **ActingWeb memories** — fully supported via MCP
- **Instruction files** — Claude reads `CLAUDE.md` and instruction files directly from the brain folder
- **INBOX tasks** — drop `.txt` or `.md` files into the `INBOX/` folder
- **ActingWeb tasks** — create tasks via the Context Builder, agent picks them up automatically
- **File persistence** — everything lives on your local filesystem
- **Obsidian compatible** — the brain directory works as an Obsidian vault

## What's Different from AWS

| Feature | AWS Agent Server | Claude Cowork |
|---|---|---|
| Runs unattended | Yes (cron/EventBridge) | No — requires you to start a session |
| Dropbox sync | Automatic | Use Dropbox as the brain directory |
| Gmail/Calendar | MCP servers (headless) | MCP servers (browser-based OAuth) |
| File persistence | Dropbox syncs everything | Local filesystem |
| Cost | ~$16-67/month AWS | Included in Claude Pro/Team plan |

## Setup Steps

1. **Set up the brain directory** — follow Steps A1–A3 in the main [README](../README.md#step-a1-choose-a-directory)

2. **Open your brain folder in Cowork**:
   - Open Claude Desktop
   - Start a new **Cowork** session
   - Choose **"Work in a folder"** and select your brain directory
   - Claude reads `CLAUDE.md` automatically

3. **Personalize and set up schedule** — send this prompt in your new Cowork session:

```txt
Read the instruction files in ai/instructions/ and introduce yourself.
Then check if ActingWeb memory is connected by searching for any existing memories.
If this is our first session, walk me through filling in personal.md and style.md:
- Search ActingWeb memories for any existing personal context or preferences
- If Gmail is connected, analyze my recent sent emails to infer my writing style
- Then ask me questions to fill in the remaining gaps in the templates
Finally, offer to set up a recurring schedule for the default tasks (email triage,
calendar preview, inbox scan). Suggest a sensible schedule and set it up if I agree.
```

This verifies your setup (MCP connection, file access), walks you through
personalizing the templates, and optionally sets up a recurring schedule.

## Recurring Task Schedule

Cowork supports in-session scheduled tasks that run your default tasks automatically
in the background while you work. During first-session setup, the agent will offer
to configure this for you.

Typical schedules:

- **Every 2 hours on weekdays**: email triage, calendar preview, inbox scan
- **Every morning**: full default task cycle
- **Custom**: choose what runs and when

Scheduled tasks run while your Cowork session is open. When you start a new session,
just ask the agent to set up the schedule again, or include it in your opening prompt.

You can also trigger a one-off run at any time:

```txt
Run the default task cycle now.
```

## Queuing Tasks via ActingWeb

You can create tasks for the agent from anywhere — your phone, another AI session,
or the web. Open the **Context Builder** at:

```
https://ai.actingweb.io/{actor_id}/app/builder
```

Find your `actor_id` by calling `how_to_use()` in any session with ActingWeb connected.

The wizard helps you describe what you want done and attach relevant memories as
context. When you mark the task as ready, the agent picks it up on its next run
via `work_on_task()`. Results are written to `output/tasks/`.

### Other ways to trigger tasks

- **INBOX folder**: Drop `.txt` or `.md` files into `INBOX/` — the agent picks them up during inbox scan
- **Direct prompt**: Just ask the agent to do something in your Cowork session

## Recommended Workflow

Use Cowork as your primary interactive environment and optionally the AWS server as a background worker:
- Cowork for: conversations, complex tasks, interactive work
- AWS for: email triage, calendar checks, inbox processing, memory hygiene
- Both share: ActingWeb memories, Dropbox files (if synced)
