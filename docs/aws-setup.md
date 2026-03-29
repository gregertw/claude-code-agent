# Option B: AWS EC2 Setup

Create a cloud instance that runs the agent autonomously.

## FOR AIs: Guided Setup

**If you are an AI guiding a user through this, follow these steps in order.**
Wait for the user to confirm each step before proceeding.

### B1: Check prerequisites

Ask the user to confirm they have:

- An **AWS account** with the **AWS CLI** installed and configured (`aws configure`)
- **One of:**
  - An Anthropic API key from console.anthropic.com, **or**
  - A Claude Pro, Max, or Enterprise subscription (they will log in on the server)

### B2: Configure `agent.conf`

Help the user create `agent.conf` from `agent.conf.example`. Ask them for:

- `OWNER_NAME` — their name
- `SCHEDULE_MODE` — `"always-on"` or `"scheduled"`
- `AWS_REGION` — which AWS region (default: `eu-north-1`)
- `INSTALL_TTYD` — want a web terminal? (`true`/`false`)
- If ttyd: `TTYD_USER` and `TTYD_PASSWORD` (must not be `changeme`)
- `SETUP_GMAIL` / `SETUP_GOOGLE_CALENDAR` — email/calendar integration?

### B3: Run deploy.sh

Ask the user which authentication method they want:

- **Account login** (Pro/Max/Enterprise subscription) — just run `./deploy.sh`.
  They will log into Claude Code interactively on the server during post-deploy setup.
- **API key** (usage-based billing from console.anthropic.com) — set the key first,
  then deploy:
  ```
  export ANTHROPIC_API_KEY="sk-ant-..."
  ```

Then tell them to run `./deploy.sh` and paste back the status output.

The script is fully automated — it creates AWS resources, sets up the server,
registers MCP servers, and deploys the scheduler. It takes a few minutes.

### B4: Review deploy status

The user should paste the deploy status output back. Check it for:
- `DEPLOY STATUS: SUCCESS`
- Note the `Post-deploy steps needed` list

Then guide the user through each remaining step below.

### B5–B9: Post-deploy setup

Follow the steps under **"Step 5: Post-Deploy Setup"** below. The order is:

1. **SSH in** with port forwarding: `./agent-manager.sh --ssh-mcp`
2. **Log into Claude Code** (if not using API key): run `claude`, complete
   theme + login, then `/exit`
3. **Run `~/agent-setup.sh`** — handles brain directory and MCP registration
4. **Authenticate MCP servers**: `cd ~/brain && claude`, then `/mcp`
   to authenticate each server, then `/exit`
5. **Test**: `agent run`

**Rules:**
- All post-deploy steps require SSH with port forwarding (not ttyd)
- If Claude Code asks for theme + login, guide based on API key vs account
- If `/mcp` shows no servers, re-run `~/agent-setup.sh`
- After setup, ttyd (if enabled) works for day-to-day access

### B10: Return to README.md for personalization

When the test run completes, return to **Step 3: Personalize the agent** in
README.md. For Option B, the user will SSH in and run `cd ~/brain && claude`
to paste the personalization prompt.

---

## Prerequisites

- An AWS account
- AWS CLI installed and configured on your local machine (`aws configure`)
- **One of:**
  - An Anthropic API key from [console.anthropic.com](https://console.anthropic.com), **or**
  - A Claude Pro, Max, or Enterprise subscription (logged into Claude Code locally)

## Quick Deploy (recommended)

The `deploy.sh` script creates all AWS infrastructure and configures the server.
After it completes, you follow guided steps to authenticate Claude Code and
MCP servers.

```bash
# 1. Configure
cp agent.conf.example agent.conf
nano agent.conf    # set OWNER_NAME, SCHEDULE_MODE, etc.

# 2. Deploy
./deploy.sh
# Auth options (choose one during post-deploy setup):
#   - Account login: run 'claude' on the server and log in interactively
#   - API key: export ANTHROPIC_API_KEY="sk-ant-..." before deploying

# 3. Follow the post-deploy steps printed at the end
#    (Claude Code auth, MCP auth, test run)
```

To tear everything down: `./teardown.sh`

State is saved to `deploy-state.json` so teardown knows what to remove.

If you prefer to set up each step manually, follow the manual steps below.

---

## Manual Setup

### Step 1: Configure

```bash
cp agent.conf.example agent.conf
nano agent.conf
```

Fill in at minimum:

- `OWNER_NAME` — your name
- `SCHEDULE_MODE` — `"always-on"` or `"scheduled"`

Optional:

- `INSTALL_TTYD=true` — enables browser-based terminal access
- `TTYD_USER` / `TTYD_PASSWORD` — credentials for the web terminal

### Step 2: Launch EC2 Instance

1. Open [AWS Console -> EC2 -> Launch Instance](https://console.aws.amazon.com/ec2/home#LaunchInstances:)
2. Configure:
   - **Name**: `agent-server`
   - **AMI**: Ubuntu 22.04 LTS
   - **Architecture**: x86_64
   - **Instance type**: `t3.large` (2 vCPU, 8GB RAM)
   - **Key pair**: Create new or select existing. Download the `.pem` file.
   - **Network**: Allow SSH from "My IP". If using ttyd, also allow port 443 from "My IP".
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

### Step 5: Post-Deploy Setup

Connect with SSH port forwarding (required for OAuth authentication):

```bash
# On your LOCAL machine:
./agent-manager.sh --ssh-mcp
# Or for manual setup: ssh -L 18850:127.0.0.1:18850 -L 18851:127.0.0.1:18851 -L 18852:127.0.0.1:18852 agent
```

**Authenticate Claude Code** (choose one):

- **Account login** (Pro/Max/Enterprise): run `claude`, complete theme selection
  and account login, then `/exit`
- **API key**: edit `~/.agent-env` and add your key, then `source ~/.agent-env`
  ```bash
  nano ~/.agent-env    # set ANTHROPIC_API_KEY="sk-ant-..."
  source ~/.agent-env
  ```

This initializes Claude Code so that `agent-setup.sh` can register MCP servers
in the same pass.

Then run the unified setup script:

```bash
~/agent-setup.sh
```

This handles everything in the right order based on `agent.conf`:

1. **Brain directory**: creates folders and installs template files
2. **Claude Code**: verifies authentication
3. **MCP servers**: registers servers configured in `agent.conf`

The script is safe to re-run — each step checks if it's already done and skips it.

### Step 6: Authenticate MCP Servers

Start Claude Code in the brain directory and authenticate each MCP server:

```bash
cd ~/brain
claude
# /mcp → select server → Authenticate → browser opens for sign-in
# Repeat for each server, then /exit
```

Port mapping: ActingWeb=18850, Gmail=18851, Calendar=18852

#### If `/mcp` shows "No MCP servers configured"

This means `agent-setup.sh` failed to register them (usually a `claude mcp add-json`
version mismatch). Re-run the setup script — it's safe to re-run:

```bash
~/agent-setup.sh
```

If it still fails, register them manually:

```bash
claude mcp add-json actingweb '{"type":"http","url":"https://ai.actingweb.io/mcp","oauth":{"callbackPort":18850}}'
claude mcp add-json gmail '{"type":"http","url":"https://gmail.mcp.claude.com/mcp","oauth":{"callbackPort":18851}}'
claude mcp add-json google-calendar '{"type":"http","url":"https://gcal.mcp.claude.com/mcp","oauth":{"callbackPort":18852}}'
```

Only add the servers enabled in your `agent.conf` (ActingWeb is always needed;
Gmail and Google Calendar are optional). Then start `claude` again and run `/mcp`
to authenticate each one.

#### Test the agent

```bash
# Still in the SSH session:
agent run
```

### Step 8: Set Up Local SSH Config

> **Note:** `deploy.sh` configures this automatically. Only needed for manual setup.

Add to `~/.ssh/config` on your local machine:

```text
Host agent
  HostName <elastic-ip>
  User ubuntu
  IdentityFile ~/.ssh/your-key.pem
  ServerAliveInterval 60
  ServerAliveCountMax 3
```

Now use `agent-manager.sh` or just: `ssh agent`

---

## Web Terminal (ttyd)

If you enabled `INSTALL_TTYD=true`, you get a browser-based terminal at:

```text
https://<elastic-ip>
```

Log in with the `TTYD_USER` and `TTYD_PASSWORD` from your `agent.conf`.
This gives full shell access — you can run `claude`, edit files, view logs, etc.

**Security notes:**

- ttyd uses HTTPS with a self-signed certificate on port 443
- Your browser will show a certificate warning — this is expected for self-signed certs
- The AWS security group restricts port 443 to your deploy IP
- The server firewall (UFW) only allows port 443 if ttyd is enabled

---

## Schedule Modes

### Always-On (default)

Instance runs 24/7. Use cron or manual `claude -p` for tasks.

**Cost**: ~$67/month on-demand, ~$33/month reserved.

### Scheduled (hourly wakeup)

Instance starts on a schedule, runs all tasks, then stops itself.

**Cost**: ~$18/month (hourly) including EBS and Elastic IP.

### Switching Modes

Use `agent-manager.sh` from your local machine — it handles both the server
config and the EventBridge scheduler in one command:

```bash
./agent-manager.sh --always-on       # switch to always-on, remove scheduler
./agent-manager.sh --scheduled       # switch to scheduled (every 60 min)
./agent-manager.sh --scheduled 30    # scheduled, every 30 min
```

### Manual Wakeup

In scheduled mode the instance is normally stopped between runs. To start it
manually (e.g., to SSH in, run a task, or debug):

```bash
# From your LOCAL machine:
./agent-manager.sh --wakeup     # starts instance and waits for SSH
./agent-manager.sh --sleep      # stops the instance
./agent-manager.sh              # show server status
```

Or use the AWS Console: EC2 → Instances → select `agent-server` → Instance
state → Start instance.

The instance will run the orchestrator automatically on start (bypassing the
active-hours guard, since any manual start is intentional). To prevent it from
self-stopping while you're working:

```bash
touch ~/agents/.keep-running      # prevents self-stop
# ... do your work ...
rm ~/agents/.keep-running         # re-enable self-stop
```

If you just want to trigger a one-off task run without keeping the instance
alive, use the `agent` CLI:

```bash
./agent-manager.sh --ssh
agent run                         # runs the full orchestrator
agent run "Your custom prompt"    # runs a one-off task
```

### Optional: Remote Trigger

You can set up a Lambda Function URL to trigger agent runs from any device
(phone, tablet, iOS Shortcuts). This starts the instance, which runs the
orchestrator and then self-stops — works at any time, even outside active hours.

```bash
# Deploy the trigger (creates Lambda + Function URL + Bearer token):
./deploy-trigger.sh --deploy

# View your URL and token (for setting up iOS Shortcuts, etc.):
./deploy-trigger.sh              # or: ./agent-manager.sh --trigger

# Remove the trigger:
./deploy-trigger.sh --remove
```

**iOS Shortcuts setup:**

1. Open the **Shortcuts** app → tap **+** to create a new shortcut
2. Tap **Add Action** → search for **Get Contents of URL**
3. Tap the URL field and paste your **Function URL** (from `--trigger` output)
4. Tap **Method** → change to **POST**
5. Tap **Headers** → **Add New Header**:
   - Key: `Authorization`
   - Value: `Bearer <your token>` (paste the full Bearer token from `--trigger` output)
6. Optional: rename the shortcut (e.g. "Run Agent") and add it to your Home Screen

The shortcut can also be triggered via Siri ("Hey Siri, Run Agent") or from
the share sheet.

> **Note:** `./teardown.sh` automatically cleans up trigger resources if deployed.
> This feature is for scheduled mode only — in always-on mode the instance is
> already running and `StartInstances` is a harmless no-op.

---

## Viewing Logs

From your local machine:
```bash
./agent-manager.sh --ssh             # connect to the server
agent logs                           # list recent run logs
agent log                            # view latest run log
agent log 2                          # view second-latest
```

Or directly:
```bash
ls -lt ~/logs/                     # recent logs
cat ~/logs/agent-run-*.md          # full run logs (markdown)
cat ~/logs/orchestrator-*.log      # orchestrator shell output
```

## Monitoring

The orchestrator writes a heartbeat file after each run:

```bash
cat ~/brain/output/.agent-heartbeat
```

## Debugging (prevent self-stop)

```bash
touch ~/agents/.keep-running      # prevents self-stop in scheduled mode
# ... do your work / check logs ...
rm ~/agents/.keep-running         # re-enable self-stop
```

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

# Process monitoring
htop
```

### If the instance reboots

- In scheduled mode with hibernation: the instance resumes from where it left off (~5-20s)
- ttyd restarts automatically (systemd) — if configured
- In scheduled mode without hibernation: full boot, then tasks, then stops
- Cron jobs persist
- Elastic IP stays attached
- tmux sessions are lost (recreated on next SSH)

---

## Rebuilding from Scratch

1. Launch new EC2 (same settings as Step 2)
2. Associate the Elastic IP with the new instance
3. Upload the agent-server directory and run `setup.sh`
4. Set API key, run `~/agent-setup.sh`, authenticate Claude Code and MCP
5. If using scheduled mode: `./agent-manager.sh --scheduled`

Keep this directory backed up — it's the source of truth for rebuilding.

---

## Server File Reference

| File | Purpose |
|---|---|
| `~/.agent-env` | API keys (chmod 600) |
| `~/.agent-server.conf` | Copy of agent.conf |
| `~/.agent-schedule` | Schedule mode config |
| `~/.claude.json` | MCP server connections |
| `~/.claude/settings.json` | Claude Code tool permissions |
| `~/agent-setup.sh` | Post-deploy setup (brain dir, MCP servers) |
| `~/scripts/agent-orchestrator.sh` | Orchestrator (copied from package) |
| `~/scripts/run-agent.sh` | Run a one-off agent task with logging |
| `~/scripts/set-schedule-mode.sh` | Toggle always-on / scheduled |
| `~/scripts/install-templates.sh` | Install template files |
