# Self-Improving AI Agent — Setup Guide

A continuously running AI agent that processes tasks, maintains cross-session memory,
and improves itself over time.

## GETTING STARTED

For AIs: When reading this file, use the below prompt as instructions for how to use this repo and interact with the user to set up an autonomous agent.
For humans: Paste this prompt into Cowork (or Claude Code).

```txt
In this repo we have instructions
for creating a claude code based autonomous agent. Start with README.md and help me
through each step by asking me questions on where I need to decide or give input,
but mostly just execute on the steps given without giving me too much detail.
For steps where there are manual things the user has to do, offer to support with
a step-wise guide.
```

## Choose Your Setup

There are two ways to set up this agent. **Start by choosing one:**

### Option A: Local Setup (Claude Desktop / Cowork)

Set up a local "brain" directory on your machine and use Claude Desktop's Cowork
feature to work in that folder. No cloud infrastructure needed.

- **Best for**: Interactive use, trying things out, low cost
- **Cost**: Only your Claude subscription (Pro/Team)
- **Runs unattended**: No — you start sessions manually
- **File access**: Local filesystem via Cowork's "Work in a folder"

**[Go to Option A instructions](#option-a-local-setup)**

### Option B: AWS EC2 Setup

Create a cloud instance that runs the agent autonomously on a schedule.

- **Best for**: Unattended background processing, email triage, recurring tasks
- **Cost**: ~$11–67/month depending on schedule
- **Runs unattended**: Yes — wakes on schedule, processes tasks, stops
- **File access**: SSH, web terminal, or optional Dropbox sync

**[Go to Option B instructions](#option-b-aws-ec2-setup)**

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
2. Authentication is handled via OAuth during MCP setup (see option-specific steps)

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

## Option A: Local Setup

Set up a brain directory on your local machine and use Claude Desktop's Cowork
feature to work in it.

### Prerequisites

- Claude Desktop app installed

### Step A1: Choose a directory

Pick where the brain directory should be created. This is where the agent stores
its instructions, scratchpad, inbox, and outputs. For example:

- `~/brain/` — simple default
- `~/Documents/agent-brain/` — inside Documents
- `~/Dropbox/brain/` — if you want Dropbox sync

> **Tip**: The brain directory is also compatible with [Obsidian](https://obsidian.md),
> a free knowledge management app. If you use Obsidian, you can open the brain
> folder as a vault to browse and edit your instruction files, task outputs, and
> scratchpad notes with a nice UI. No extra setup required — just open the folder
> in Obsidian.

### Step A2: Install template files

Clone this repo (or download it), then copy the templates into your chosen directory:

```bash
# Set your brain directory
BRAIN_DIR="$HOME/brain"

# Create the directory structure
mkdir -p "$BRAIN_DIR/ai/instructions"
mkdir -p "$BRAIN_DIR/ai/scratchpad"
mkdir -p "$BRAIN_DIR/INBOX/_processed"
mkdir -p "$BRAIN_DIR/output/tasks"
mkdir -p "$BRAIN_DIR/output/logs"

# Copy templates
cp templates/CLAUDE.md "$BRAIN_DIR/CLAUDE.md"
cp templates/tasks.md "$BRAIN_DIR/ai/instructions/tasks.md"
cp templates/default-tasks.md "$BRAIN_DIR/ai/instructions/default-tasks.md"
cp templates/personal.md "$BRAIN_DIR/ai/instructions/personal.md"
cp templates/style.md "$BRAIN_DIR/ai/instructions/style.md"

# Replace placeholder in CLAUDE.md
sed -i '' 's/{OUTPUT_FOLDER}/output/g' "$BRAIN_DIR/CLAUDE.md"
```

The `personal.md` and `style.md` files are templates with placeholder sections.
The agent will help you fill them in during your first session.

### Step A3: Set up MCP connections

Add the following MCP servers in Claude Desktop's settings (Settings → MCP Servers):

- **ActingWeb** (required): `https://ai.actingweb.io/mcp` — account is auto-created on first auth
- **Gmail** (optional) — requires Google OAuth credentials
- **Google Calendar** (optional) — requires Google OAuth credentials

### Step A4: Open your brain folder in Cowork

Steps A1–A3 set up the brain directory, templates, and MCP connections.
Now switch to working **in** the brain folder:

1. Open Claude Desktop
2. Start a new **Cowork** session
3. Choose **"Work in a folder"** and select your brain directory (e.g. `~/brain`)
4. Claude will read the `CLAUDE.md` file automatically

You're now working inside your agent workspace. Continue to Step A5.

### Step A5: Personalize and set up schedule

Send this prompt in your new Cowork session:

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

This verifies your setup works (MCP connection, file access), walks you through
personalizing the templates, and optionally sets up a recurring schedule so the
agent runs your default tasks automatically in the background.

### Queuing tasks via ActingWeb

You can create tasks for the agent from anywhere — your phone, another AI session,
or the web. Open the **Context Builder** at:

```
https://ai.actingweb.io/{actor_id}/app/builder
```

(Find your `actor_id` by calling `how_to_use()` in any session with ActingWeb connected.)

The Context Builder wizard lets you describe what you want done and attach relevant
memories as context. When you mark the task as ready, the agent picks it up on its
next run via `work_on_task()`.

See [docs/cowork-setup.md](docs/cowork-setup.md) for more details on the Cowork setup.

---

## Option B: AWS EC2 Setup

Create a cloud instance that runs the agent autonomously.

### Two Modes of File Access

| | With Dropbox | Without Dropbox |
|---|---|---|
| File access | Synced everywhere — edit from any device | SSH, web terminal (ttyd), or ActingWeb only |
| Task inbox | Drop files from phone/laptop via Dropbox | Drop files via SSH/ttyd, or queue via ActingWeb |
| Best for | Users who already use Dropbox/Obsidian | Minimal setup, server-only workflows |
| Config | `FILE_SYNC="dropbox"` | `FILE_SYNC="none"` + `INSTALL_TTYD=true` |

### Prerequisites

- An AWS account
- An Anthropic API key from [console.anthropic.com](https://console.anthropic.com)
- An ActingWeb account (automatically created on first `/mcp` authentication)
- AWS CLI installed on your local machine (for the scheduler)
- A Dropbox account (only if using Dropbox sync)

### Step B1: Configure

```bash
cp agent.conf.example agent.conf
nano agent.conf
```

Fill in at minimum:

- `OWNER_NAME` — your name
- `FILE_SYNC` — `"dropbox"` or `"none"`
- `SCHEDULE_MODE` — `"always-on"` or `"scheduled"`

If using Dropbox:

- `BRAIN_FOLDER` — name of the Dropbox subfolder containing your vault

If not using Dropbox:

- `INSTALL_TTYD=true` — enables browser-based terminal access
- `TTYD_USER` / `TTYD_PASSWORD` — credentials for the web terminal

### Step B2: Launch EC2 Instance

1. Open [AWS Console -> EC2 -> Launch Instance](https://console.aws.amazon.com/ec2/home#LaunchInstances:)
2. Configure:
   - **Name**: `agent-server`
   - **AMI**: Ubuntu 24.04 LTS
   - **Architecture**: x86_64
   - **Instance type**: `t3.large` (2 vCPU, 8GB RAM)
   - **Key pair**: Create new or select existing. Download the `.pem` file.
   - **Network**: Allow SSH from "My IP"
   - **Storage**: 30 GB gp3
3. Click **Launch Instance**
4. Note the **Instance ID**

### Step B3: Allocate Elastic IP

1. EC2 -> **Elastic IPs** -> **Allocate** -> **Allocate**
2. Select the new IP -> **Actions** -> **Associate** -> choose `agent-server`
3. Note the Elastic IP address

### Step B4: Upload and Run Setup

```bash
# Fix key permissions
chmod 400 ~/Downloads/your-key.pem

# Upload the entire agent-server directory
scp -i ~/Downloads/your-key.pem -r ./ ubuntu@<elastic-ip>:~/agent-server/

# SSH in
ssh -i ~/Downloads/your-key.pem ubuntu@<elastic-ip>

# Run setup
cd ~/agent-server
chmod +x setup.sh
sudo ./setup.sh
```

### Step B5: Post-Setup (with Dropbox)

```bash
# a) Set API key
nano ~/.agent-env    # paste your ANTHROPIC_API_KEY
source ~/.agent-env

# b) Link Dropbox
~/.dropbox-dist/dropboxd
# -> Open the URL in browser, authorize, then Ctrl-C
sudo systemctl start dropbox

# c) Configure selective sync (optional)
dropbox-cli exclude add ~/Dropbox/Photos
dropbox-cli exclude list

# d) Install template files (after Dropbox syncs)
~/scripts/install-templates.sh

# e) Verify Claude Code
claude --version
echo 'Reply: Hello' | claude -p

# f) Configure MCP connections
~/setup-mcp.sh

# g) Test the orchestrator
~/scripts/agent-orchestrator.sh --no-stop
```

### Step B5: Post-Setup (without Dropbox)

```bash
# a) Set API key
nano ~/.agent-env    # paste your ANTHROPIC_API_KEY
source ~/.agent-env

# b) Verify Claude Code
claude --version
echo 'Reply: Hello' | claude -p

# c) Configure MCP connections
~/setup-mcp.sh

# d) Test the orchestrator
~/scripts/agent-orchestrator.sh --no-stop
```

Template files are installed automatically into `~/brain/` when not using Dropbox.

### Step B6: Set Up Local SSH Config

Add to `~/.ssh/config` on your local machine:

```text
Host agent
  HostName <elastic-ip>
  User ubuntu
  IdentityFile ~/.ssh/your-key.pem
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

Now just: `ssh agent`

---

## Web Terminal (ttyd)

If you enabled `INSTALL_TTYD=true`, you get a browser-based terminal at:

```text
http://<elastic-ip>:7681
```

Log in with the `TTYD_USER` and `TTYD_PASSWORD` from your `agent.conf`.
This gives full shell access — you can run `claude`, edit files, view logs, etc.

ttyd is especially useful when not using Dropbox, as it provides easy access to the
brain directory and logs without needing an SSH client.

**Security notes:**

- ttyd uses HTTP basic auth — adequate for personal use behind UFW
- For production use, consider putting it behind an nginx reverse proxy with TLS
- The firewall only allows port 7681 if ttyd is enabled

---

## Schedule Modes (Option B only)

### Always-On (default)

Instance runs 24/7. Use cron or manual `claude -p` for tasks.

**Cost**: ~$67/month on-demand, ~$33/month reserved.

### Scheduled (hourly wakeup)

Instance starts on a schedule, runs all tasks, then stops itself.

**Cost**: ~$18/month (hourly) including EBS and Elastic IP.

### Switching Modes

```bash
# SSH into the instance first
sudo ~/scripts/set-schedule-mode.sh scheduled    # or always-on
cat ~/.agent-schedule                             # check current mode
```

When switching to scheduled mode, deploy the scheduler from your local machine:

```bash
./deploy-scheduler.sh <instance-id>           # every 60 min (default)
./deploy-scheduler.sh <instance-id> 30        # every 30 min
./deploy-scheduler.sh <instance-id> 120       # every 2 hours
```

When switching to always-on:

```bash
./deploy-scheduler.sh --remove
```

---

## Task Architecture

The orchestrator processes three task sources in order:

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

### Viewing Logs (Option B)

```bash
ls -lt ~/logs/                     # recent logs
cat ~/logs/agent-run-*.md          # full run logs (markdown)
cat ~/logs/orchestrator-*.log      # orchestrator shell output
```

### Monitoring

The orchestrator writes a heartbeat file after each run:

```bash
cat ~/brain/output/.agent-heartbeat       # without Dropbox
cat ~/Dropbox/brain/output/.agent-heartbeat  # with Dropbox
```

### Debugging (prevent self-stop, Option B)

```bash
touch ~/agents/.keep-running      # prevents self-stop in scheduled mode
# ... do your work / check logs ...
rm ~/agents/.keep-running         # re-enable self-stop
```

---

## MCP Connections

### ActingWeb (required)

Cross-session memory that persists across all your AI tools.
- **Option A**: Set up via `claude mcp add` (see Step A3)
- **Option B**: Set up via `setup-mcp.sh` on the server

### Gmail (optional)

Enables email triage in default tasks. Requires Google OAuth credentials.
Set `SETUP_GMAIL=true` in `agent.conf` (Option B) or add MCP manually (Option A).

### Google Calendar (optional)

Enables calendar preview. Same Google OAuth credentials.
Set `SETUP_GOOGLE_CALENDAR=true` in `agent.conf` (Option B) or add MCP manually (Option A).

### Adding More MCP Servers

See [docs/customization.md](docs/customization.md).

---

## Cost Comparison (Option B)

| Mode | Compute | EBS | Elastic IP | Total |
|---|---|---|---|---|
| Always-on (on-demand) | $61 | $2.40 | $3.65 | ~$67/month |
| Always-on (1yr reserved) | $27 | $2.40 | $3.65 | ~$33/month |
| Scheduled hourly (10min) | $10 | $2.40 | $3.65 | ~$16/month |
| Scheduled 2-hourly (10min) | $5 | $2.40 | $3.65 | ~$11/month |

---

## Maintenance (Option B)

```bash
# System updates (security patches are automatic)
sudo apt update && sudo apt upgrade -y

# Claude Code (auto-updates)
claude --version

# Disk usage
df -h

# Dropbox health (if configured)
dropbox-cli status

# Process monitoring
htop
```

### If the instance reboots

- Dropbox restarts automatically (systemd) — if configured
- ttyd restarts automatically (systemd) — if configured
- In scheduled mode: boot runner executes tasks, then stops
- Cron jobs persist
- Elastic IP stays attached
- tmux sessions are lost (recreated on next SSH)

---

## Rebuilding from Scratch (Option B)

1. Launch new EC2 (same settings as Step B2)
2. Associate the Elastic IP with the new instance
3. Upload the agent-server directory and run `setup.sh`
4. Set API key, link Dropbox (if using), run `setup-mcp.sh`
5. If using scheduled mode: `deploy-scheduler.sh` with new instance ID

Keep this directory in your Dropbox or backed up — it's the source of truth for rebuilding.

---

## File Reference

### This Package

| File | Purpose |
|---|---|
| `agent.conf.example` | Configuration template — copy to `agent.conf` (Option B) |
| `setup.sh` | Bootstrap script — run on fresh Ubuntu instance (Option B) |
| `setup-mcp.sh` | Configure MCP connections on server (Option B) |
| `agent-orchestrator.sh` | Main startup script — full task cycle (Option B) |
| `deploy-scheduler.sh` | Create/remove EventBridge scheduler (Option B) |
| `templates/` | Template instruction files for the brain directory |
| `docs/` | Additional guides (Cowork setup, customization) |

### Brain Directory (created by setup or manually)

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
| `output/.agent-heartbeat` | Last-run timestamp (for monitoring) |

### On the Server (Option B, created by setup.sh)

| File | Purpose |
|---|---|
| `~/.agent-env` | API keys (chmod 600) |
| `~/.agent-server.conf` | Copy of agent.conf |
| `~/.agent-schedule` | Schedule mode config |
| `~/.claude.json` | MCP server connections |
| `~/.claude/settings.json` | Claude Code tool permissions |
| `~/scripts/agent-orchestrator.sh` | Orchestrator (copied from package) |
| `~/scripts/run-agent.sh` | Run a one-off agent task with logging |
| `~/scripts/set-schedule-mode.sh` | Toggle always-on / scheduled |
| `~/scripts/install-templates.sh` | Install template files |
