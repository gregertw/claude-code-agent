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
│   ├── CLAUDE.md               #   Workspace instructions (system — updated on upgrade)
│   ├── ACTIONS.md              #   Owner's dashboard (user — preserved on upgrade)
│   ├── tasks.md                #   Task execution rules (system — updated on upgrade)
│   ├── default-tasks.md        #   Recurring tasks (system — updated on upgrade)
│   ├── personal-tasks.md       #   User's custom recurring tasks (user — preserved)
│   ├── personal.md             #   Personal context (user — preserved on upgrade)
│   ├── style.md                #   Writing style rules (user — preserved on upgrade)
│   ├── capabilities/           #   Optional installable capabilities
│   │   ├── README.md           #     How capabilities work
│   │   └── agentmail.md        #     Agent email via Agentmail
│   ├── hooks/                  #   Claude Code hook scripts
│   │   └── protect-settings.sh #     Blocks Edit/Write to settings and .env
│   ├── settings.local.json     #   Project-level Claude settings (hooks config)
│   ├── trigger-lambda.py       #   Lambda code for remote trigger
│   └── obsidian/               #   Obsidian document templates
│       ├── ai instruction.md   #     Template for new AI instruction files
│       ├── daily note.md       #     Template for daily notes
│       ├── email.md            #     Template for email drafts
│       ├── scratchpad.md       #     Template for scratchpad notes
│       └── task.md             #     Template for task files
│
├── docs/                       # Setup and customization guides
│   ├── local-setup.md          #   Option A step-by-step
│   ├── aws-setup.md            #   Option B step-by-step
│   └── customization.md        #   Adding tasks, MCP servers, etc.
│
├── deploy.sh                   # One-command AWS deploy (creates all infra)
├── teardown.sh                 # One-command AWS teardown
├── deploy-scheduler.sh         # EventBridge scheduler create/remove
├── deploy-trigger.sh           # Optional: Lambda remote trigger
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
| `deploy-trigger.sh` | Local machine | Optional. Creates Lambda Function URL for remote agent triggering. Standalone — not called by `deploy.sh`. |
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
├── ACTIONS.md                    Owner's dashboard — action items, updated every run
├── ai/instructions/
│   ├── tasks.md                  Task execution rules
│   ├── default-tasks.md          Built-in recurring tasks
│   ├── personal-tasks.md         Your custom recurring tasks (add your own here)
│   ├── personal.md               Your personal context
│   └── style.md                  Your writing style
├── ai/scratchpad/                Agent scratch space
├── .claude/
│   ├── settings.local.json      Project-level settings (hooks)
│   └── hooks/
│       └── protect-settings.sh  Blocks edits to settings and .env
├── INBOX/                        Drop .txt/.md files here for one-off tasks
│   └── _processed/               Completed inbox tasks (moved here with date prefix)
├── templates/                    Obsidian document templates
│   └── capabilities/            Optional installable capabilities
└── output/
    ├── tasks/                    Task results
    ├── logs/                     Run logs
    ├── emails/                   Email drafts, daily digest, follow-up tracker
    ├── news/                     Daily news reports from newsletters
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
│   ├── ACTIONS.md                        Owner's dashboard
│   ├── ai/instructions/
│   │   ├── tasks.md
│   │   ├── default-tasks.md
│   │   ├── personal-tasks.md             User's custom recurring tasks
│   │   ├── personal.md
│   │   └── style.md
│   ├── .claude/
│   │   ├── settings.local.json          Project-level settings (hooks)
│   │   └── hooks/
│   │       └── protect-settings.sh      Blocks edits to settings and .env
│   ├── ai/scratchpad/
│   ├── INBOX/
│   │   └── _processed/
│   ├── templates/                        Obsidian document templates
│   │   └── capabilities/                Optional installable capabilities
│   └── output/
│       ├── tasks/
│       ├── logs/                         Symlinks to ~/logs/agent-run-*.md
│       ├── emails/                       Email drafts, digest, follow-ups
│       ├── news/                         Daily news reports
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
| Lambda Function URL | (Optional) Remote trigger — starts the instance via Bearer-token-authenticated HTTPS endpoint |
| Key pair | SSH key, `.pem` stored locally in `~/.ssh/` |

### Runtime: how the agent executes

```
EventBridge / remote trigger wakes instance (scheduled mode)
  or instance is already running (always-on mode)
         │
         ▼
  agent-orchestrator.sh
    Boot/resume: systemd runs with --force (bypasses active-hours guard)
    Cron: runs without flags (active-hours guard applies)
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
         ├─ Process ACTIONS.md (resolve checked items, read inline instructions)
         ├─ Execute default-tasks.md (email, calendar, inbox, tasks, etc.)
         ├─ Execute personal-tasks.md (user's custom recurring tasks)
         ├─ Scan INBOX/ for one-off tasks
         ├─ Call work_on_task() for ActingWeb tasks
         ├─ Write results to output/tasks/
         │
         ▼
  Post-run
         ├─ Update ACTIONS.md (new items, refreshed dates, run log link)
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

### Wake/run behavior by trigger source

How the orchestrator behaves depends on **what started it** and **which mode** the server is in.

**Scheduled mode:**

| Trigger | Entry path | Hours guard | Runs agent? | Self-stops? |
|---|---|---|---|---|
| EventBridge (scheduled wake) | resume-hook → resume-check → orchestrator `--force` | Bypassed | Yes, if heartbeat interval elapsed | Yes (hibernate) |
| Remote trigger (Lambda) | Lambda → StartInstances → same as above | Bypassed | Yes, if heartbeat interval elapsed | Yes (hibernate) |
| `--run-agent` | StartInstances → boot/resume runs orchestrator `--force`; or SSH → orchestrator `--force` if already running | Bypassed | Yes | Yes (hibernate) |
| `--wakeup` | StartInstances → resume path runs + `.keep-running` set | Bypassed | Yes (side effect of wake) | No (`.keep-running`) |
| Cron (instance already running) | cron → orchestrator (no flag) | **Active** | Only during active hours | Yes (hibernate) |
| Cold boot (rare) | boot-runner → orchestrator `--force` | Bypassed | Yes | Yes (hibernate) |

**Always-on mode:**

| Trigger | Entry path | Hours guard | Runs agent? | Self-stops? |
|---|---|---|---|---|
| Cron | cron → orchestrator (no flag) | Skipped (mode=always-on) | Yes (cron only fires during active hours) | No |
| Manual (`agent run`) | CLI → orchestrator | Skipped (mode=always-on) | Yes | No |

**Safeguards:**

| Safeguard | Where | Purpose |
|---|---|---|
| `flock` | Orchestrator | Prevents concurrent runs — cron or resume silently exits if orchestrator is already running |
| Heartbeat interval check | `agent-resume-check.sh` | Prevents duplicate runs if woken too soon after last run (20% of interval = 12min for hourly). If skipped, instance hibernates. |
| Hours guard in orchestrator | `agent-orchestrator.sh` | Last-resort safety net for cron runs outside active hours; bypassed by `--force` and `.keep-running` |
| `.keep-running` file | Orchestrator + resume-check | Created by `--wakeup`; bypasses hours guard and prevents self-stop for interactive sessions |
| 10-second hibernate grace | Orchestrator (end) | Allows `touch .keep-running` to cancel self-stop just before hibernate |

### Security

- UFW firewall: only SSH (22) and optional HTTPS (443) open, restricted to deploy IP
- fail2ban: SSH brute-force protection
- unattended-upgrades: automatic security patches
- Secrets in `~/.agent-env` with `chmod 600`
- PreToolUse hook blocks agent from editing settings, hooks, and `.env`
- Destructive Bash commands (`rm -rf`, `git push --force`, etc.) explicitly denied
- IAM role scoped to EC2 self-stop only

---

## Task Architecture

Both options process the same four task sources, in order:

### 1. Default tasks (`ai/instructions/default-tasks.md`)

Run every cycle. Includes email triage (with newsletter digest, follow-up tracking,
unsubscribe suggestions), calendar preview (with meeting prep and email cross-reference),
inbox scan, ActingWeb task check, memory hygiene (weekly), self-review (daily),
heartbeat check, and daily news report. Tasks that require an unconnected MCP
server are skipped automatically.

### 2. Personal tasks (`ai/instructions/personal-tasks.md`)

User-defined recurring tasks. This file is never overwritten by upgrades — add
your own custom recurring tasks here following the same format as default-tasks.md.

### 3. Inbox tasks (`INBOX/` folder)

Drop a `.txt` or `.md` file in `INBOX/`. The agent reads it as a task prompt,
executes it, moves the file to `INBOX/_processed/<date>-<filename>`, and writes
the result to `output/tasks/<filename>.result.md`.

### 4. ActingWeb tasks

Created via the Context Builder web UI (`https://ai.actingweb.io/{actor_id}/app/builder`)
from any device. The agent retrieves tasks via `work_on_task()`, executes them
with gathered context, writes results, and marks them done.

### ACTIONS.md — the owner's dashboard

Every run, the agent updates `ACTIONS.md` with action items: upcoming meetings,
email drafts needing approval, calendar conflicts, news reports, stale drafts,
follow-up nudges, and self-review proposals. The owner marks items done (checkbox
or strikethrough) and the agent clears them on the next run. Inline annotations
on items are treated as instructions.

### Execution constraints

- Max 10 minutes per task (most complete in under 2 minutes)
- Fail gracefully and continue to the next task
- Never send emails or messages without explicit instruction
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
