# Self-Improving AI Agent — Setup Guide

A continuously running AI agent that processes tasks, maintains cross-session memory,
and improves itself over time.

## FOR AIs: Setup Instructions

**If you are an AI reading this file, follow these instructions exactly.**

You are helping a user set up an autonomous agent. Do NOT skip ahead, do NOT
auto-fill templates, and do NOT execute steps without user confirmation.

### Step 1: Ask which setup option

Ask the user which option they want before doing anything else.
Mention that it is strongly suggested to start with Option A (Local Setup)
first. Setting up an AWS hosted instance requires more technical insight,
including an AWS account.

- **Option A: Local Setup** — Brain directory on their machine, used via Claude
  Desktop Cowork. No cloud infrastructure. Best for trying things out.
- **Option B: AWS EC2 Setup** — Cloud instance that runs autonomously on a
  schedule. Best for unattended background processing.

### Step 2: Open the setup guide and follow it

Based on their answer, open the corresponding guide:

- Option A: `docs/local-setup.md` (in this repo, or fetch from GitHub)
- Option B: Follow the AWS guided setup below.

For Option A, follow the steps in `docs/local-setup.md` sequentially.
When you reach Step 4, you MUST give the user an explicit, copy-pasteable
block that tells them exactly:
1. The full path to open in Cowork (the brain directory they chose)
2. The exact prompt to paste in the new session (from the guide's Step 4)
Do NOT paraphrase — output the actual prompt as a code block they can copy.

### AWS Guided Setup (Option B)

Follow these steps **in order**, one at a time. Wait for the user to confirm
each step before proceeding.

#### B1: Check prerequisites

Ask the user to confirm they have:

- An **AWS account** with the **AWS CLI** installed and configured (`aws configure`)
- **One of:**
  - An Anthropic API key from console.anthropic.com, **or**
  - A Claude Pro, Max, or Enterprise subscription (they will log in on the server)

#### B2: Configure `agent.conf`

Help the user create `agent.conf` from `agent.conf.example`. Ask them for:

- `OWNER_NAME` — their name
- `SCHEDULE_MODE` — `"always-on"` or `"scheduled"`
- `AWS_REGION` — which AWS region (default: `eu-north-1`)
- `INSTALL_TTYD` — want a web terminal? (`true`/`false`)
- If ttyd: `TTYD_USER` and `TTYD_PASSWORD` (must not be `changeme`)
- `SETUP_GMAIL` / `SETUP_GOOGLE_CALENDAR` — email/calendar integration?

#### B3: Run deploy.sh

If the user has an API key, tell them to set it first:
```
export ANTHROPIC_API_KEY="sk-ant-..."
```
Then tell them to run `./deploy.sh` and paste back the status output.

The script is fully automated — it creates AWS resources, sets up the server,
registers MCP servers, and deploys the scheduler. It takes a few minutes.

#### B4: Review deploy status

The user should paste the deploy status output back. Check it for:
- `DEPLOY STATUS: SUCCESS`
- Note the `Post-deploy steps needed` list

Then guide the user through each remaining step below.

#### B5–B9: Post-deploy setup

Follow the steps in `docs/aws-setup.md` under **"Step 5: Post-Deploy Setup"**
through **"Test the orchestrator"**. The order is:

1. **SSH in** with port forwarding: `./agent-manager.sh --ssh-mcp`
2. **Log into Claude Code** (if not using API key): run `claude`, complete
   theme + login, then `/exit`
3. **Run `~/agent-setup.sh`** — handles brain directory
   and MCP registration in one pass
4. **Authenticate MCP servers**: `cd ~/brain && claude`, then `/mcp`
   to authenticate each server, then `/exit`
5. **Test**: `~/scripts/agent-orchestrator.sh --no-stop`

**Important rules for guiding the user:**
- All post-deploy steps require SSH with port forwarding (not ttyd)
- If Claude Code asks for theme + login, guide based on API key vs account
- If `/mcp` shows no servers, re-run `~/agent-setup.sh`
- After setup, ttyd (if enabled) works for day-to-day access

#### Personalize (optional)

The `personal.md` and `style.md` files are **templates with placeholders**.
Do NOT fill them in yourself. Instead, guide the user through filling them
in interactively. For Option B, this must be done **on the server** — SSH in
and run Claude Code in the brain directory (`cd ~/brain && claude`)
to edit the files there.

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

---

## FOR HUMANS: Quick Start

Paste this into Claude Desktop Cowork or Claude Code:

```txt
Follow the instructions at https://github.com/gregertw/claude-code-agent
to set up an autonomous AI agent. Start with the README.md.
```

The AI will download the repo for you and guide you through setup step by step.

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
- **Cross-session memory** — via ActingWeb, every AI session (Claude Code, Cowork,
  ChatGPT) shares the same memory layer
- **Task inbox** — drop a `.txt` or `.md` file in a folder and the agent picks it up
- **Email triage and calendar preview** — optional Gmail and Calendar MCP connections
- **Self-improving** — the agent reads instruction files that you (or the agent) can edit

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

# Option B: use SSH/ttyd, or queue via ActingWeb from any device
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
on the server using Maestral (a lightweight headless Dropbox client).

Run `setup-dropbox.sh` on the server — it installs Maestral, links your account,
configures selective sync, and symlinks `~/brain → ~/Dropbox/brain` so all
scripts work unchanged. If `~/brain` already has content, it offers to migrate
or back up.

Note that Dropbox sync adds complexity and is not required for the agent to
function.
