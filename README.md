# Self-Improving AI Agent — Setup Guide

A continuously running AI agent that processes tasks, maintains cross-session memory,
and improves itself over time.

## FOR AIs: Setup Instructions

**If you are an AI reading this file, follow these instructions exactly.**

You are helping a user set up an autonomous agent. Do NOT skip ahead, do NOT
auto-fill templates, and do NOT execute steps without user confirmation.

### Important rules

- **Ask before acting.** Every step needs user input or confirmation.
- **Do not auto-fill templates.** The personalization step exists for a reason.
- **Follow the guide in order.** Do not skip or combine steps.
- **If the repo is not local**, the scripts (`deploy.sh`, `setup.sh`, etc.)
  and template files need to exist in a local directory before setup can begin.
  Ask the user where they want to put the files, then download and extract:
  ```
  curl -L https://github.com/gregertw/claude-code-agent/archive/refs/heads/main.zip -o /tmp/claude-code-agent.zip
  unzip /tmp/claude-code-agent.zip -d <user-chosen-path>
  rm /tmp/claude-code-agent.zip
  ```
  The extracted directory will be `<user-chosen-path>/claude-code-agent-main/`.
  If running in Cowork, point Cowork to that directory ("Work in a folder")
  after downloading.

### Step 1: Choose setup option

Ask the user which option (A or B) they want before doing anything else.
Mention that it is strongly suggested to start with Option A (Local Setup)
first. Setting up an AWS hosted instance requires more technical insight,
including an AWS account.

- **Option A: Local Setup** — Brain directory on their machine, used via Claude
  Desktop Cowork. No cloud infrastructure. Best for trying things out.
- **Option B: AWS EC2 Setup** — Cloud instance that runs autonomously on a
  schedule. Best for unattended background processing.

### Step 2: Follow the setup guide

Based on their answer, open the corresponding guide and follow it step by step:

- **Option A**: `docs/local-setup.md`
- **Option B**: `docs/aws-setup.md`

Each guide ends with "Return to README.md for the personalization step."
When the user has completed all setup steps in the guide, continue here.

### Step 3: Personalize the agent

The `personal.md` and `style.md` files in the brain directory are **templates
with placeholders**. Do NOT fill them in yourself. Guide the user through
filling them in interactively using the prompt below.

**Where to run this:**

- **Option A**: The user should start a new **Cowork session** in Claude Desktop,
  choose "Work in a folder", and select their brain directory. Then paste the
  prompt below into that session. Output the full brain directory path so the
  user knows exactly which folder to select.
- **Option B**: The user should SSH into the server (`./agent-manager.sh --ssh`)
  and start Claude Code in the brain directory: `cd ~/brain && claude`. Then
  paste the prompt below.

**Prompt to paste** — output this as a code block for the user to copy:

```txt
Read the instruction files in ai/instructions/ and introduce yourself.
Then check if ActingWeb memory is connected by searching for any existing memories.
Walk me through filling in personal.md and style.md:
- Search ActingWeb memories for any existing personal context or preferences
- If Gmail is connected, analyze my recent sent emails to infer my writing style
- Then ask me questions to fill in the remaining gaps in the templates

After personalization, wrap up by doing the following:
1. Use ActingWeb's how_to_use() to get my actor_id, then give me a direct link
   to the Context Builder: https://ai.actingweb.io/{actor_id}/app/builder
   Explain that I can create tasks there from any device (phone, browser, another
   AI session) and the agent will pick them up on its next run.
2. Show me ACTIONS.md and explain that this is my dashboard — the agent updates
   it every run with action items, and I check off or annotate items.
3. Mention personal-tasks.md — I can add my own recurring tasks there and they
   will never be overwritten by upgrades.
4. Check templates/capabilities/ for available optional capabilities (like agent
   email) and briefly list them — offer to install any that interest me.
5. Give me a summary of what the agent can do now — what default tasks are
   configured, how to queue one-off tasks, and how to customize.
```

**Option A addition**: After the user pastes the prompt above, also suggest
setting up a recurring schedule for the default tasks. Suggest a sensible
schedule (e.g. every 2 hours on weekdays or every hour 6-22) and set it up
if the user agrees.
Cowork supports in-session scheduled tasks that run in the background.

**After personalization is complete, you are done.** The rest of this file is
reference material for humans — you can skip it.

---

## FOR HUMANS: Quick Start

Paste this into Claude Desktop Cowork or Claude Code:

```txt
Download https://github.com/gregertw/claude-code-agent/archive/refs/heads/main.zip
to /tmp/, unzip it, then read the README.md inside and follow the setup instructions.
```

The AI will download the repo, read the setup guide, and walk you through it step by step.

---

## Choose Your Setup

**Pick one of these. Each has its own step-by-step guide.**

> **Suggestion:** Start with Option A (Local Setup) first. Setting up an AWS
> hosted instance requires more technical insight, including an AWS account.

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
- **Cost**: ~$11–67/month depending on schedule (plus API usage if using API key)
- **Auth**: API key (usage-based) or account login (Pro/Max/Enterprise subscription)
- **Runs unattended**: Yes — wakes on schedule, processes tasks, stops
- **File access**: SSH, web terminal, or git

**[Go to AWS Setup Guide](docs/aws-setup.md)**

---

## What You Get (both options)

- **Autonomous task execution** — the agent processes queued tasks from an inbox
- **ACTIONS.md dashboard** — the agent updates a dashboard every run with action items;
  you check off items and add inline instructions
- **Cross-session memory** — via ActingWeb, every AI session (Claude Code, Cowork,
  ChatGPT) shares the same memory layer
- **Task inbox** — drop a `.txt` or `.md` file in a folder and the agent picks it up
- **Email triage** — Gmail integration with draft management, newsletter digest,
  follow-up tracking, and unsubscribe suggestions
- **Calendar preview** — Google Calendar integration with meeting prep and email cross-reference
- **Daily news report** — compiled from your email newsletters, filtered by your interests
- **Self-improving** — the agent reads instruction files that you (or the agent) can edit
- **Installable capabilities** — extend the agent with optional features (agent email,
  etc.) via guided installation from capability files
- **Upgrade-safe personalization** — your customizations (personal context, writing style,
  custom tasks) are preserved when system files are updated

---

## Common Setup: MCP Connections

Both options use remote MCP servers for memory and optional Google services.
All three are standard remote MCP servers that use OAuth — just add the URL
and sign in.

### ActingWeb (required — cross-session memory)

- **URL**: `https://ai.actingweb.io/mcp`
- No sign-up needed — account is auto-created on first authentication
- **Claude Desktop / Cowork**: Add in Settings → Connectors
- **Claude Code CLI**: `claude mcp add --transport http actingweb https://ai.actingweb.io/mcp`

### Gmail and Google Calendar (optional)

These use Anthropic's official hosted connectors — no Google Cloud project or
credentials needed.

- **Gmail**: `https://gmail.mcp.claude.com/mcp`
- **Google Calendar**: `https://gcal.mcp.claude.com/mcp`
- **Claude Desktop / Cowork**: Add in Settings → Connectors
- **Claude Code CLI**: `claude mcp add --transport http gmail https://gmail.mcp.claude.com/mcp`

After adding, authenticate via OAuth (browser sign-in). On headless servers,
Claude Code provides a URL to open manually — see your option's setup guide.

---

## Task Architecture

The agent processes four task sources in order:

### 1. Default Tasks (every run)

Defined in `ai/instructions/default-tasks.md`. Includes email triage (with newsletter
digest, follow-up tracking, unsubscribe suggestions), calendar preview (with meeting
prep), inbox scan, memory hygiene (weekly), daily news report, and self-review.
This is a system file — updated on upgrade, not meant for user edits.

### 2. Personal Tasks (every run)

Defined in `ai/instructions/personal-tasks.md`. Add your own recurring tasks here
using the same format as default-tasks.md. This file is never overwritten by upgrades.

### 3. Inbox Tasks (one-off)

Drop `.txt` or `.md` files in the `INBOX/` folder at the root of your brain directory:

```bash
# Option A: drop files directly into your brain directory
echo "Research pricing for t4g instances" > ~/brain/INBOX/research.txt

# Option B: use SSH/ttyd, or queue via ActingWeb from any device
```

After execution, files move to `INBOX/_processed/` with a date prefix.
Results are written to `output/tasks/`.

### 4. ActingWeb Tasks

Create tasks from anywhere using the **Context Builder** — a guided wizard at
`https://ai.actingweb.io/{actor_id}/app/builder` where you describe what you
want done and attach relevant memories as context.

The agent retrieves tasks via `work_on_task()`, executes them with the gathered
context, writes results to `output/tasks/`, and marks them done.
This works in both Option A and Option B.

---

## Brain Directory Structure

| File | Updated on upgrade? | Purpose |
|---|---|---|
| `CLAUDE.md` | Yes (system) | Workspace instructions for Claude Code |
| `ACTIONS.md` | No (user) | Owner's dashboard — action items, updated every run |
| `ai/instructions/tasks.md` | Yes (system) | Task execution rules |
| `ai/instructions/default-tasks.md` | Yes (system) | Built-in recurring tasks |
| `ai/instructions/personal-tasks.md` | No (user) | Your custom recurring tasks |
| `ai/instructions/personal.md` | No (user) | Personal context (fill in during setup) |
| `ai/instructions/style.md` | No (user) | Writing style rules (fill in during setup) |
| `templates/` | No | Obsidian document templates |
| `templates/capabilities/` | No | Optional installable capabilities |
| `INBOX/` | — | Drop tasks here (.txt or .md) |
| `INBOX/_processed/` | — | Completed inbox tasks |
| `output/tasks/` | — | Results from scheduled runs and ActingWeb tasks |
| `output/logs/` | — | Run logs from each agent cycle |
| `output/emails/` | — | Email drafts, daily digest, follow-up tracker |
| `output/news/` | — | Daily news reports from newsletters |
| `output/research/` | — | Research output — meeting prep, background research |
| `output/improvements/` | — | Self-review proposals — agent-suggested improvements |
| `output/.agent-heartbeat` | — | Last-run timestamp (for monitoring) |

---

## This Package

For a detailed look at how the components fit together, see
**[ARCHITECTURE.md](ARCHITECTURE.md)** — it covers the repo layout, both setup
paths, the server file layout after deployment, and the task execution flow.

| File | Purpose |
|---|---|
| `templates/` | Template files for the brain directory (system + user files) |
| `templates/capabilities/` | Optional installable capabilities (agent email, etc.) |
| `templates/obsidian/` | Obsidian document templates (installed to `brain/templates/`) |
| `docs/local-setup.md` | Option A setup guide |
| `docs/aws-setup.md` | Option B setup guide |
| `docs/customization.md` | Customization guide (adding tasks, MCP servers, etc.) |
| `agent.conf.example` | Configuration template — copy to `agent.conf` (Option B) |
| `agent-cli.sh` | Agent CLI helper — status, logs, run commands (Option B) |
| `setup.sh` | Bootstrap script — run on fresh Ubuntu instance (Option B) |
| `agent-setup.sh` | Post-deploy setup — brain dir, MCP servers (Option B) |
| `agent-orchestrator.sh` | Main startup script — full task cycle (Option B) |
| `deploy.sh` | One-command deploy — creates all AWS resources (Option B) |
| `teardown.sh` | One-command teardown — destroys all AWS resources (Option B) |
| `agent-manager.sh` | Local management — status, wakeup, sleep, mode switch, SSH (Option B) |
| `deploy-scheduler.sh` | Create/remove EventBridge scheduler (used by agent-manager.sh) |
| `setup-dropbox.sh` | Optional Dropbox sync setup (see below) |

---

## Optional: Syncing the Brain Directory

By default, the brain directory lives locally on the server at `~/brain/`.
You access files via SSH, the web terminal (ttyd), or ActingWeb tasks.

If you want to sync the brain directory across devices, you have two options:

### Git-managed brain

Initialize the brain directory as a git repo and push/pull from a remote:

```bash
cd ~/brain
git init && git add -A && git commit -m "Initial brain"
git remote add origin <your-repo-url>
git push -u origin main
```

This works well if you want version history and are comfortable with git.
You can edit files locally and push, or pull on the server before a run.

### Dropbox sync

For automatic file sync (including from phone/tablet), you can set up Dropbox
using Maestral (a lightweight headless Dropbox client).

On the server (Option B), run the setup script — it installs Maestral, links
your Dropbox account, configures selective sync (only the brain folder), and
symlinks `~/brain → ~/Dropbox/brain` so all scripts work unchanged. If
`~/brain` already has content, it offers to migrate or back up.

```bash
~/scripts/setup-dropbox.sh
```

Note that Dropbox sync adds complexity and is not required for the agent to
function.
