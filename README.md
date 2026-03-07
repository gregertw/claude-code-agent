# Self-Improving AI Agent Server — Launch Guide

A continuously running AI agent that processes tasks, maintains cross-session memory,
and improves itself over time. Runs on an AWS EC2 instance with optional Dropbox sync.

## GETTING STARTED 

Paste this prompt into claude code:

```txt
In this repo, we have instructions for creating a claude code based autonomous agent running in
AWS. Start with README.md and help me through each step by asking me questions on where I need to
decide or give input, but mostly just execute on the steps given without giving me too much detail.
```

## What You Get

- **Autonomous task execution** — the agent wakes up on a schedule, processes queued tasks,
  and goes back to sleep
- **Cross-session memory** — via ActingWeb, every AI session (Claude Code, Cowork, ChatGPT)
  shares the same memory layer
- **Task inbox** — drop a `.txt` or `.md` file in a folder and the agent picks it up
- **Email triage and calendar preview** — optional Gmail and Calendar MCP connections
- **Self-improving** — the agent reads instruction files that you (or the agent) can edit

Works with both AWS (unattended) and Claude Cowork (interactive).
See [docs/cowork-setup.md](docs/cowork-setup.md) for the Cowork path.

## Two Modes of Operation

| | With Dropbox | Without Dropbox |
|---|---|---|
| File access | Synced everywhere — edit from any device | SSH, web terminal (ttyd), or ActingWeb only |
| Task inbox | Drop files from phone/laptop via Dropbox | Drop files via SSH/ttyd, or queue via ActingWeb |
| Best for | Users who already use Dropbox/Obsidian | Minimal setup, server-only workflows |
| Config | `FILE_SYNC="dropbox"` | `FILE_SYNC="none"` + `INSTALL_TTYD=true` |

---

## Prerequisites

- An AWS account
- An Anthropic API key from [console.anthropic.com](https://console.anthropic.com)
- An ActingWeb account — sign up at [ai.actingweb.io](https://ai.actingweb.io)
- AWS CLI installed on your local machine (for the scheduler)
- A Dropbox account (only if using Dropbox sync)

---

## Quick Start (~15 minutes)

### Step 1: Configure

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

### Step 2: Launch EC2 Instance

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

### Step 3: Allocate Elastic IP

1. EC2 -> **Elastic IPs** -> **Allocate** -> **Allocate**
2. Select the new IP -> **Actions** -> **Associate** -> choose `agent-server`
3. Note the Elastic IP address

### Step 4: Upload and Run Setup

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

### Step 5: Post-Setup (with Dropbox)

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

### Step 5: Post-Setup (without Dropbox)

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

### Step 6: Set Up Local SSH Config

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

## Schedule Modes

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

Drop `.txt` or `.md` files in the INBOX folder:

```bash
# With Dropbox: drop files from any device into the INBOX folder
# Without Dropbox: use SSH/ttyd or queue via ActingWeb
echo "Research pricing for t4g instances" > ~/brain/output/INBOX/research.txt
```

After execution, files move to `INBOX/_processed/` with a date prefix.

### 3. ActingWeb Tasks

Tasks queued from other AI sessions (Cowork, ChatGPT, etc.) via ActingWeb.
The orchestrator retrieves and executes them automatically, then marks them done.
This works regardless of whether Dropbox is configured.

### Viewing Logs

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

### Debugging (prevent self-stop)

```bash
touch ~/agents/.keep-running      # prevents self-stop in scheduled mode
# ... do your work / check logs ...
rm ~/agents/.keep-running         # re-enable self-stop
```

---

## MCP Connections

### ActingWeb (required)

Cross-session memory that persists across all your AI tools.
Set up via `setup-mcp.sh`. Uses mcporter as a proxy for headless OAuth.

### Gmail (optional)

Enables email triage in default tasks. Requires Google OAuth credentials.
Set `SETUP_GMAIL=true` in `agent.conf`.

### Google Calendar (optional)

Enables calendar preview. Same Google OAuth credentials.
Set `SETUP_GOOGLE_CALENDAR=true` in `agent.conf`.

### Adding More MCP Servers

See [docs/customization.md](docs/customization.md).

---

## Cost Comparison

| Mode | Compute | EBS | Elastic IP | Total |
|---|---|---|---|---|
| Always-on (on-demand) | $61 | $2.40 | $3.65 | ~$67/month |
| Always-on (1yr reserved) | $27 | $2.40 | $3.65 | ~$33/month |
| Scheduled hourly (10min) | $10 | $2.40 | $3.65 | ~$16/month |
| Scheduled 2-hourly (10min) | $5 | $2.40 | $3.65 | ~$11/month |

---

## Maintenance

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

## Rebuilding from Scratch

1. Launch new EC2 (same settings as Step 2)
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
| `agent.conf.example` | Configuration template — copy to `agent.conf` |
| `setup.sh` | Bootstrap script — run on fresh Ubuntu instance |
| `setup-mcp.sh` | Configure MCP connections (ActingWeb, Gmail, Calendar) |
| `agent-orchestrator.sh` | Main startup script — full task cycle |
| `deploy-scheduler.sh` | Create/remove EventBridge scheduler (from local machine) |
| `templates/` | Template instruction files for new setups |
| `docs/` | Additional guides (Cowork setup, customization) |

### On the Server (created by setup.sh)

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

### In the Brain Directory (synced or local)

| File | Purpose |
|---|---|
| `ai/instructions/tasks.md` | Task type definitions and execution rules |
| `ai/instructions/default-tasks.md` | Recurring tasks (run every cycle) |
| `ai/instructions/personal.md` | Personal context for the agent (create yours) |
| `ai/instructions/style.md` | Writing style rules (create yours) |
| `{output}/INBOX/` | Drop tasks here (.txt or .md) |
| `{output}/INBOX/_processed/` | Completed inbox tasks |
| `{output}/.agent-heartbeat` | Last-run timestamp (for monitoring) |
| `CLAUDE.md` | Workspace instructions for Claude Code |
