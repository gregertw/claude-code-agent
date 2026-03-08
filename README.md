# Self-Improving AI Agent — Setup Guide

A continuously running AI agent that processes tasks, maintains cross-session memory,
and improves itself over time.

## GETTING STARTED

For AIs: When reading this file, use the below prompt as instructions for how to use
this repo and interact with the user to set up an autonomous agent.
For humans: Paste this prompt into Cowork (or Claude Code).

```txt
In this repo we have instructions for creating a claude code based autonomous agent.
Start with README.md and help me through each step.

IMPORTANT: Before doing anything, ask the user which setup option they want
(Option A: Local or Option B: AWS EC2). Then, based on their answer, open the
corresponding setup guide (docs/local-setup.md or docs/aws-setup.md) and follow
those steps. Ask for any required inputs (e.g. directory path for local, or AWS
details for EC2) before executing any steps. For steps where there are manual things
the user has to do, offer to support with a step-wise guide.
```

## Choose Your Setup

**You must pick one of these before proceeding. Each has its own setup guide.**

### Option A: Local Setup (Claude Desktop / Cowork)

Set up a local "brain" directory on your machine and use Claude Desktop's Cowork
feature to work in that folder. No cloud infrastructure needed.

- **Best for**: Interactive use, trying things out, low cost
- **Cost**: Only your Claude subscription (Pro/Team)
- **Runs unattended**: No — you start sessions manually
- **File access**: Local filesystem via Cowork's "Work in a folder"

**[Go to Local Setup Guide](docs/local-setup.md)**

### Option B: AWS EC2 Setup

Create a cloud instance that runs the agent autonomously on a schedule.

- **Best for**: Unattended background processing, email triage, recurring tasks
- **Cost**: ~$11–67/month depending on schedule
- **Runs unattended**: Yes — wakes on schedule, processes tasks, stops
- **File access**: SSH, web terminal, or optional Dropbox sync

**[Go to AWS Setup Guide](docs/aws-setup.md)**

---

## What You Get (both options)

- **Autonomous task execution** — the agent processes queued tasks from an inbox
- **Cross-session memory** — via ActingWeb, every AI session (Claude Code, Cowork,
  ChatGPT) shares the same memory layer
- **Task inbox** — drop a `.txt` or `.md` file in a folder and the agent picks it up
- **Email triage and calendar preview** — optional Gmail and Calendar MCP connections
- **Self-improving** — the agent reads instruction files that you (or the agent) can edit

---

## Common Setup: ActingWeb and Google OAuth

Both options use ActingWeb for cross-session memory, and optionally Google OAuth
for Gmail and Calendar access. Set these up regardless of which option you choose.

### ActingWeb (required)

1. No sign-up needed — a new account is automatically created the first time you authenticate over `/mcp`
2. Authentication is handled via OAuth during MCP setup (see your option's setup guide)

### Google OAuth (optional — for Gmail and Calendar)

If you want email triage or calendar preview:

1. Go to [Google Cloud Console](https://console.cloud.google.com) → APIs & Services → Credentials
2. Create OAuth 2.0 credentials (Desktop app type)
3. Enable the Gmail API and Google Calendar API
4. Note your `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`, and `GOOGLE_REFRESH_TOKEN`

### Dropbox (optional — for file sync)

If you want to sync files across devices (phone, laptop, server):

1. Have a Dropbox account
2. Relevant for Option B (AWS) primarily, where it syncs the brain directory

---

## Task Architecture

The agent processes three task sources in order:

### 1. Default Tasks (every run)

Defined in `ai/instructions/default-tasks.md`. Includes email triage, calendar preview,
inbox scan, memory hygiene (weekly), and sync health checks.
Edit the file to customize.

### 2. Inbox Tasks (one-off)

Drop `.txt` or `.md` files in the `INBOX/` folder at the root of your brain directory:

```bash
# Option A: drop files directly into your brain directory
echo "Research pricing for t4g instances" > ~/brain/INBOX/research.txt

# Option B with Dropbox: drop files from any device into the INBOX folder
# Option B without Dropbox: use SSH/ttyd or queue via ActingWeb
```

After execution, files move to `INBOX/_processed/` with a date prefix.
Results are written to `output/tasks/`.

### 3. ActingWeb Tasks

Create tasks from anywhere using the **Context Builder** — a guided wizard at
`https://ai.actingweb.io/{actor_id}/app/builder` where you describe what you
want done and attach relevant memories as context.

The agent retrieves tasks via `work_on_task()`, executes them with the gathered
context, writes results to `output/tasks/`, and marks them done.
This works in both Option A and Option B.

---

## Brain Directory Structure

| File | Purpose |
|---|---|
| `CLAUDE.md` | Workspace instructions for Claude Code |
| `ai/instructions/tasks.md` | Task type definitions and execution rules |
| `ai/instructions/default-tasks.md` | Recurring tasks (run every cycle) |
| `ai/instructions/personal.md` | Personal context for the agent (fill in during setup) |
| `ai/instructions/style.md` | Writing style rules (fill in during setup) |
| `INBOX/` | Drop tasks here (.txt or .md) |
| `INBOX/_processed/` | Completed inbox tasks |
| `output/tasks/` | Results from scheduled runs and ActingWeb tasks |
| `output/logs/` | Run logs from each agent cycle |
| `output/research/` | Research output — meeting prep, background research |
| `output/.agent-heartbeat` | Last-run timestamp (for monitoring) |

---

## This Package

| File | Purpose |
|---|---|
| `templates/` | Template instruction files for the brain directory |
| `docs/local-setup.md` | Option A setup guide |
| `docs/aws-setup.md` | Option B setup guide |
| `docs/customization.md` | Customization guide (adding tasks, MCP servers, etc.) |
| `agent.conf.example` | Configuration template — copy to `agent.conf` (Option B) |
| `setup.sh` | Bootstrap script — run on fresh Ubuntu instance (Option B) |
| `setup-mcp.sh` | Configure MCP connections on server (Option B) |
| `agent-orchestrator.sh` | Main startup script — full task cycle (Option B) |
| `deploy-scheduler.sh` | Create/remove EventBridge scheduler (Option B) |
