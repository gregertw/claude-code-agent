# Self-Improving AI Agent — Setup Guide

A continuously running AI agent that processes tasks, maintains cross-session memory,
and improves itself over time.

## FOR AIs: Setup Instructions

**If you are an AI reading this file, follow these instructions exactly.**

You are helping a user set up an autonomous agent. Do NOT skip ahead, do NOT
auto-fill templates, and do NOT execute steps without user confirmation.

### Step 1: Ask which setup option

Ask the user which option they want before doing anything else:

- **Option A: Local Setup** — Brain directory on their machine, used via Claude
  Desktop Cowork. No cloud infrastructure. Best for trying things out.
- **Option B: AWS EC2 Setup** — Cloud instance that runs autonomously on a
  schedule. Best for unattended background processing. Requires AWS account
  and Anthropic API key.

### Step 2: Open the setup guide and follow it

Based on their answer, open the corresponding guide:

- Option A: `docs/local-setup.md` (in this repo, or fetch from GitHub)
- Option B: `docs/aws-setup.md` (in this repo, or fetch from GitHub)

**Follow the steps in that guide sequentially.** For each step:

1. Explain what the step does
2. Ask for any required inputs (directory path, config values, etc.)
3. Execute the step only after the user confirms
4. For manual steps (AWS Console, browser OAuth), provide a clear walkthrough

### Step 3: Personalize (local setup only)

The `personal.md` and `style.md` files are **templates with placeholders**.
Do NOT fill them in yourself. Instead, follow Step 5 in the local setup guide
which has a prompt that walks the user through filling them in interactively.

### Important rules

- **Ask before acting.** Every step needs user input or confirmation.
- **Do not auto-fill templates.** The personalization step exists for a reason.
- **Follow the guide in order.** Do not skip or combine steps.
- **If the repo is not local**, fetch files from
  `https://github.com/gregertw/claude-code-agent` as needed.

---

## FOR HUMANS: Quick Start

Paste this into Claude Desktop Cowork or Claude Code:

```txt
Follow the instructions at https://github.com/gregertw/claude-code-agent to
set up an autonomous AI agent. Start with the README.md.
```

Or if you have the repo cloned locally:

```txt
Read README.md in this repo and help me set up the autonomous agent.
```

---

## Choose Your Setup

**Pick one of these. Each has its own step-by-step guide.**

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
for Gmail and Calendar access.

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
| `output/improvements/` | Self-review proposals — agent-suggested improvements |
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
| `agent-cli.sh` | Agent CLI helper — status, logs, run commands (Option B) |
| `setup.sh` | Bootstrap script — run on fresh Ubuntu instance (Option B) |
| `setup-mcp.sh` | Configure MCP connections on server (Option B) |
| `agent-orchestrator.sh` | Main startup script — full task cycle (Option B) |
| `deploy.sh` | One-command deploy — creates all AWS resources (Option B) |
| `teardown.sh` | One-command teardown — destroys all AWS resources (Option B) |
| `deploy-scheduler.sh` | Create/remove EventBridge scheduler (Option B) |
