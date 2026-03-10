# Architecture

This document describes the repository structure, the two installation paths
(local and AWS), and the resulting server layout after setup.

---

## Repository Structure

```
claude-code-agent/
├── README.md                   # Setup guide (AI-readable + human quick-start)
├── ARCHITECTURE.md             # This file
├── agent.conf.example          # Configuration template (Option B)
│
├── templates/                  # Brain directory templates
│   ├── CLAUDE.md               #   Workspace instructions for Claude Code
│   ├── tasks.md                #   Task type definitions and execution rules
│   ├── default-tasks.md        #   Recurring tasks (email, calendar, inbox, etc.)
│   ├── personal.md             #   Personal context (filled in during setup)
│   └── style.md                #   Writing style rules (filled in during setup)
│
├── docs/                       # Setup and customization guides
│   ├── local-setup.md          #   Option A step-by-step
│   ├── aws-setup.md            #   Option B step-by-step
│   └── customization.md        #   Adding tasks, MCP servers, etc.
│
├── deploy.sh                   # One-command AWS deploy (creates all infra)
├── teardown.sh                 # One-command AWS teardown
├── deploy-scheduler.sh         # EventBridge scheduler create/remove
├── setup.sh                    # Server bootstrap (packages, firewall, security)
├── agent-setup.sh              # Post-deploy setup (brain dir, MCP registration)
├── agent-orchestrator.sh       # Main runtime — builds prompt, runs Claude Code
├── agent-cli.sh                # Server-side CLI (status, logs, run, inbox, etc.)
├── agent-manager.sh            # Local CLI (instance status, wakeup, sleep, SSH)
└── setup-dropbox.sh            # Optional Dropbox sync
```

### What each script does

| Script | Runs on | Purpose |
|---|---|---|
| `deploy.sh` | Local machine | Creates EC2 instance, security group, IAM role, Elastic IP, EventBridge scheduler. Uploads repo and runs `setup.sh` on the server. Saves state to `deploy-state.json`. |
| `teardown.sh` | Local machine | Destroys all AWS resources listed in `deploy-state.json`. |
| `deploy-scheduler.sh` | Local machine | Creates or removes the EventBridge scheduler rule (used by `agent-manager.sh`). |
| `agent-manager.sh` | Local machine | Day-to-day management: show status, wakeup/sleep instance, switch schedule mode, SSH with port forwarding. |
| `setup.sh` | EC2 server | System-level bootstrap: installs packages, configures UFW firewall, fail2ban, unattended-upgrades, optional ttyd web terminal. |
| `agent-setup.sh` | EC2 server | Creates brain directory from templates, verifies Claude Code auth, registers MCP servers. Safe to re-run. |
| `agent-orchestrator.sh` | EC2 server | The main runtime loop: loads config, builds a master prompt, invokes `claude -p`, captures output, writes heartbeat, optionally self-stops the instance. |
| `agent-cli.sh` | EC2 server | Convenience CLI (`agent status`, `agent logs`, `agent run`, etc.). Installed as `agent` alias. |

---

## Option A: Local Setup

Local setup creates a brain directory on your machine. Claude Desktop's Cowork
feature opens that directory as a workspace. No cloud infrastructure is needed.

### Flow

```
1. Choose brain directory (e.g. ~/brain/)
2. Run mkdir + cp commands to install templates from this repo
3. Add MCP servers in Claude Desktop Settings → Connectors
4. Start Cowork session in the brain folder
5. Personalize personal.md and style.md interactively
```

### Result

```
~/brain/                          (your chosen location)
├── CLAUDE.md                     Workspace instructions (read by Claude on session start)
├── ai/instructions/
│   ├── tasks.md                  Task definitions and execution rules
│   ├── default-tasks.md          Recurring tasks
│   ├── personal.md               Your personal context
│   └── style.md                  Your writing style
├── ai/scratchpad/                Agent scratch space
├── INBOX/                        Drop .txt/.md files here for one-off tasks
│   └── _processed/               Completed inbox tasks (moved here with date prefix)
└── output/
    ├── tasks/                    Task results
    ├── logs/                     Run logs
    ├── research/                 Meeting prep, background research
    ├── improvements/             Self-review proposals
    └── .agent-heartbeat          Last-run timestamp
```

### MCP connections (Claude Desktop Connectors)

| Server | URL | Purpose |
|---|---|---|
| ActingWeb (required) | `https://ai.actingweb.io/mcp` | Cross-session memory |
| Gmail (optional) | `https://gmail.mcp.claude.com/mcp` | Email triage |
| Google Calendar (optional) | `https://gcal.mcp.claude.com/mcp` | Calendar preview |

All use OAuth — just add the URL and sign in when prompted.

### How it runs

The user starts a Cowork session in Claude Desktop, pointing it at the brain
directory. Claude reads `CLAUDE.md` and the instruction files, then executes
tasks interactively or on a recurring in-session schedule.

---

## Option B: AWS EC2 Setup

A cloud instance runs the agent autonomously — either on a schedule (wake,
process tasks, stop) or continuously (always-on).

### Deployment flow

```
Local machine                              AWS
─────────────                              ───
1. cp agent.conf.example agent.conf
2. Edit agent.conf (name, region, mode)
3. export ANTHROPIC_API_KEY=...  (optional)
4. ./deploy.sh ──────────────────────────→ Creates:
                                            • EC2 key pair
                                            • Security group (SSH + optional HTTPS)
                                            • IAM role (self-stop permission)
                                            • t3.large instance (Ubuntu 22.04, 30GB)
                                            • Elastic IP
                                            • Uploads repo, runs setup.sh
                                            • (If scheduled) EventBridge scheduler
   ← deploy-state.json saved locally

5. ./agent-manager.sh --ssh-mcp ─────────→ SSH with port forwarding (18850-18852)
6. claude → theme + login → /exit          (if not using API key)
7. ~/agent-setup.sh ─────────────────────→ Creates brain dir, registers MCP servers
8. cd ~/brain && claude → /mcp → auth      Authenticate each MCP server via OAuth
9. agent run                               Test run
```

### Post-setup: server file layout

```
/home/ubuntu/
├── brain/                                Agent working directory
│   ├── CLAUDE.md
│   ├── ai/instructions/
│   │   ├── tasks.md
│   │   ├── default-tasks.md
│   │   ├── personal.md
│   │   └── style.md
│   ├── ai/scratchpad/
│   ├── INBOX/
│   │   └── _processed/
│   └── output/
│       ├── tasks/
│       ├── logs/                         Symlinks to ~/logs/agent-run-*.md
│       ├── research/
│       ├── improvements/
│       └── .agent-heartbeat
│
├── logs/                                 Run logs
│   ├── agent-run-<timestamp>.md          Full Claude output (markdown)
│   └── orchestrator-<timestamp>.log      Orchestrator shell output
│
├── scripts/                              Runtime scripts (copied from repo)
│   ├── agent-orchestrator.sh
│   ├── run-agent.sh
│   ├── set-schedule-mode.sh
│   └── install-templates.sh
│
├── agent-setup.sh                        Post-deploy setup (re-runnable)
├── agents/                               Runtime state
│   └── .keep-running                     Touch to prevent self-stop
│
├── .agent-env                            API keys (chmod 600)
├── .agent-server.conf                    Copy of agent.conf
├── .agent-schedule                       Schedule mode config
├── .claude.json                          MCP server connections
└── .claude/
    ├── settings.json                     Claude Code tool permissions
    └── .credentials.json                 Account login (if not using API key)
```

### AWS infrastructure

| Resource | Details |
|---|---|
| EC2 instance | `t3.large` (2 vCPU, 8 GB RAM), Ubuntu 22.04, 30 GB gp3, hibernation enabled |
| Security group | SSH (22) from deploy IP; optional HTTPS (443) for ttyd |
| Elastic IP | Static IP for consistent SSH/web access |
| IAM role | `agent-server-role` — allows the instance to stop itself |
| EventBridge scheduler | (Scheduled mode only) Wakes the instance every N minutes |
| Key pair | SSH key, `.pem` stored locally in `~/.ssh/` |

### Runtime: how the agent executes

```
EventBridge wakes instance (scheduled mode)
  or instance is already running (always-on mode)
         │
         ▼
  agent-orchestrator.sh (runs at boot via systemd or cron)
         │
         ├─ Load ~/.agent-server.conf and ~/.agent-env
         ├─ Network connectivity check (30 attempts, 2s intervals)
         ├─ Pre-flight auth check (API key or Claude Code credentials)
         ├─ Build master prompt from config + instruction files
         │
         ▼
  claude -p "<master prompt>" --max-turns 50 --output-format text
         │
         ├─ Read ai/instructions/*.md
         ├─ Execute default-tasks.md (email, calendar, inbox, tasks, etc.)
         ├─ Scan INBOX/ for one-off tasks
         ├─ Call work_on_task() for ActingWeb tasks
         ├─ Write results to output/tasks/
         │
         ▼
  Post-run
         ├─ Capture output to ~/logs/agent-run-<timestamp>.md
         ├─ Write heartbeat to ~/brain/output/.agent-heartbeat
         └─ (If scheduled mode) sudo shutdown -h now
```

### MCP servers on the server

Registered via `claude mcp add-json` with OAuth callback ports for headless auth:

| Server | URL | OAuth callback port |
|---|---|---|
| ActingWeb | `https://ai.actingweb.io/mcp` | 18850 |
| Gmail | `https://gmail.mcp.claude.com/mcp` | 18851 |
| Google Calendar | `https://gcal.mcp.claude.com/mcp` | 18852 |

SSH port forwarding (`agent-manager.sh --ssh-mcp`) maps these ports from the
server to `localhost` so OAuth redirects work during initial authentication.

### Schedule modes

| Mode | Behavior | Cost |
|---|---|---|
| Always-on (on-demand) | Instance runs 24/7 | ~$67/month |
| Always-on (reserved) | Same, with 1-year commitment | ~$33/month |
| Scheduled hourly | Wake, run tasks (~10 min), stop | ~$16/month |
| Scheduled 2-hourly | Wake, run tasks (~10 min), stop | ~$11/month |

Switch with `./agent-manager.sh --always-on` or `./agent-manager.sh --scheduled [minutes]`.

### Security

- UFW firewall: only SSH (22) and optional HTTPS (443) open, restricted to deploy IP
- fail2ban: SSH brute-force protection
- unattended-upgrades: automatic security patches
- Secrets in `~/.agent-env` with `chmod 600`
- IAM role scoped to EC2 self-stop only

---

## Task Architecture

Both options process the same three task sources, in order:

### 1. Default tasks (`ai/instructions/default-tasks.md`)

Run every cycle. Includes email triage, calendar preview, inbox scan, ActingWeb
task check, memory hygiene (weekly), self-review (daily), and heartbeat check.
Tasks that require an unconnected MCP server are skipped automatically.

### 2. Inbox tasks (`INBOX/` folder)

Drop a `.txt` or `.md` file in `INBOX/`. The agent reads it as a task prompt,
executes it, moves the file to `INBOX/_processed/<date>-<filename>`, and writes
the result to `output/tasks/<filename>.result.md`.

### 3. ActingWeb tasks

Created via the Context Builder web UI (`https://ai.actingweb.io/{actor_id}/app/builder`)
from any device. The agent retrieves tasks via `work_on_task()`, executes them
with gathered context, writes results, and marks them done.

### Execution constraints

- Max 5 minutes per task
- Fail gracefully and continue to the next task
- Never send emails or messages without review
- Never delete files (move to `_processed/` or `_archive/`)
- Log everything

---

## Option A vs Option B

| Aspect | Option A (Local) | Option B (AWS) |
|---|---|---|
| Host | Local machine | AWS EC2 |
| How it starts | User opens Cowork session | EventBridge schedule or always-on |
| Unattended | No | Yes |
| Cost | Claude subscription only | $11-67/month AWS + API usage |
| Brain storage | Local filesystem | EC2 `/home/ubuntu/brain/` |
| File access | Direct (local) | SSH, ttyd, git, or Dropbox |
| MCP auth | Claude Desktop UI | SSH port forwarding |
| Scheduling | Cowork in-session recurring | EventBridge Scheduler |
| Web terminal | Cowork UI | Optional ttyd (HTTPS, port 443) |
