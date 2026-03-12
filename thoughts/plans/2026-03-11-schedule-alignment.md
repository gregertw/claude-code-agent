# Implementation Plan: Schedule Alignment — EventBridge + Cron + Active Hours

**Date:** 2026-03-11
**Status:** Implemented
**Research:** docs/superpowers/plans/2026-03-11-schedule-alignment.md
**Branch:** main

## Overview

Align the EventBridge scheduler with the server-side cron job so the EC2 instance only wakes during active hours and at times that match when cron will run the orchestrator. Currently EventBridge uses `rate(60 minutes)` which fires at an arbitrary offset 24/7, causing ~40 min of idle time per cycle and overnight running. The fix switches to `cron()` expressions with active hours, adds defense-in-depth guards in the orchestrator and resume-check scripts, and reports both systems to the user when schedule changes are made.

## Decisions Made

- **Timezone handling**: Use the server's timezone (set during deploy) everywhere. Store the IANA timezone in `deploy-state.json` for local scripts and in `.agent-schedule` for server-side scripts. On the server, use `date +%-H` (local time), not `date -u`. Pass the timezone to EventBridge via `--schedule-expression-timezone`.
- **Intervals > 59 min**: Enumerate specific hours in the EventBridge cron expression (e.g. 120 min → `cron(0 6,8,10,12,14,16,18,20,22 * * ? *)`) for true spacing. No unnecessary wake-stop cycles.
- **Resume-check behavior**: Only add the active-hours guard (stop if outside hours). Do NOT add a self-stop when skipping due to interval — the user may have manually woken the server.
- **Self-stop duplication**: Extract `do_hibernate()` function within `agent-orchestrator.sh` to avoid duplicating the hibernate logic. For `agent-resume-check.sh` (separate script), duplicate the hibernate logic inline — no shared-functions file exists and adding one isn't worth the complexity.
- **Heredoc extraction** [Added 2026-03-12]: Extract script files from setup.sh heredocs into standalone files in the repo. Scripts should be self-contained (detect their own HOME_DIR at runtime) so setup.sh just copies them.

## What We're NOT Doing

- ~~Creating a shared bash functions file sourced by both orchestrator and resume-check~~ [Reconsidered — see Phase 5]
- Changing the cron job itself (it already uses `SCHEDULE_HOURS` correctly)
- Adding timezone config to `agent.conf` (it's derived from the server at deploy time)

---

## Phase 1: Config Propagation

Store `SCHEDULE_HOURS` and timezone where they need to be.

### Changes

- `agent.conf:34-35` — Add `SCHEDULE_HOURS` variable after `SCHEDULE_INTERVAL`
- `deploy.sh:354-355` — Store timezone in `deploy-state.json` after setting it on the server
- `setup.sh:279-283` — Add `SCHEDULE_HOURS` and `SCHEDULE_TZ` to `.agent-schedule` heredoc
- `setup.sh:567-622` — Update `set-schedule-mode.sh` heredoc to accept and persist hours

### Detailed Steps

#### 1a. Add SCHEDULE_HOURS to agent.conf

In `agent.conf`, after line 35 (`SCHEDULE_INTERVAL=60`), add:

```bash
# Active hours for cron and EventBridge (hour range, e.g. "6-22" or "0-23" for all)
# Both cron and EventBridge scheduler use this to avoid waking the server outside these hours.
SCHEDULE_HOURS="6-22"
```

#### 1b. Store timezone in deploy-state.json

In `deploy.sh`, after line 355 (`log "Timezone set to ${LOCAL_TZ}"`), add a line to store the timezone in deploy-state.json:

```bash
# Store timezone in deploy-state.json for scheduler alignment
python3 -c "
import json
with open('${STATE_FILE}') as f: d = json.load(f)
d['timezone'] = '${LOCAL_TZ}'
with open('${STATE_FILE}', 'w') as f: json.dump(d, f, indent=2)
"
```

Also handle the fallback case (line 357, when TZ can't be detected) — store `"UTC"` as the timezone.

#### 1c. Add SCHEDULE_HOURS and SCHEDULE_TZ to .agent-schedule

In `setup.sh`, update the heredoc at line 279-283:

```bash
# Detect server timezone for schedule alignment
SERVER_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")

cat > "${HOME_DIR}/.agent-schedule" << EOF
# Agent Server Schedule Mode
SCHEDULE_MODE="${SCHEDULE_MODE}"
SCHEDULE_INTERVAL="${SCHEDULE_INTERVAL}"
SCHEDULE_HOURS="${SCHEDULE_HOURS:-6-22}"
SCHEDULE_TZ="${SERVER_TZ}"
EOF
```

#### 1d. Update set-schedule-mode.sh to accept hours

In `setup.sh`, in the `set-schedule-mode.sh` heredoc (line 567-622):

Add third argument handling after line 585:

```bash
# Update hours if provided
HOURS="${3:-}"
if [[ -n "$HOURS" ]]; then
  if grep -q '^SCHEDULE_HOURS=' "${HOME_DIR}/.agent-schedule"; then
    sed -i "s/^SCHEDULE_HOURS=.*/SCHEDULE_HOURS=\"${HOURS}\"/" "${HOME_DIR}/.agent-schedule"
  else
    echo "SCHEDULE_HOURS=\"${HOURS}\"" >> "${HOME_DIR}/.agent-schedule"
  fi
fi
```

Update the cron update section to re-source and use current hours. Update the output to report both systems (see Phase 4 for exact output text).

### Verification

- [ ] `grep SCHEDULE_HOURS agent.conf` returns the new line
- [ ] `grep timezone deploy.sh` shows the deploy-state.json update
- [ ] `grep -A5 'agent-schedule' setup.sh | head -10` shows SCHEDULE_HOURS and SCHEDULE_TZ in the heredoc
- [ ] `grep -A5 'HOURS.*3' setup.sh` shows the third argument handling in set-schedule-mode.sh
- [ ] `bash -n agent.conf` — no syntax errors
- [ ] `bash -n deploy.sh` — no syntax errors
- [ ] `bash -n setup.sh` — no syntax errors

### Implementation Status: Complete

---

## Phase 2: EventBridge Cron Expression

Rewrite `deploy-scheduler.sh` to use `cron()` with active hours and proper timezone.

### Changes

- `deploy-scheduler.sh:5-19` — Update usage header and examples
- `deploy-scheduler.sh:32` — Add `build_cron_expression()` function
- `deploy-scheduler.sh:52-58` — Update argument parsing to accept hours, read timezone from deploy-state.json
- `deploy-scheduler.sh:121-143` — Replace `rate()` with `cron()` and add `--schedule-expression-timezone`
- `deploy-scheduler.sh:147-163` — Update summary output

### Detailed Steps

#### 2a. Add build_cron_expression function

After line 32 (`SCHEDULER_ROLE_NAME=...`), add:

```bash
# --- Build EventBridge cron expression from interval + hours ----------------
# EventBridge cron: cron(minutes hours day-of-month month day-of-week year)
# rate() fires at arbitrary offsets and 24/7. cron() aligns with :00 and
# restricts to active hours — matching the server-side cron job.
build_cron_expression() {
  local interval="$1"
  local hours="$2"
  if [[ "${interval}" -le 59 ]]; then
    # Sub-hourly: use step syntax (e.g. 0/30 = :00 and :30)
    echo "cron(0/${interval} ${hours} * * ? *)"
  elif [[ "${interval}" -eq 60 ]]; then
    # Hourly: fire at :00 every hour in range
    echo "cron(0 ${hours} * * ? *)"
  else
    # Multi-hour: enumerate specific hours
    local hour_start="${hours%%-*}"
    local hour_end="${hours##*-}"
    local hour_step=$(( interval / 60 ))
    local hour_list=""
    for (( h=hour_start; h<=hour_end; h+=hour_step )); do
      [[ -n "${hour_list}" ]] && hour_list+=","
      hour_list+="${h}"
    done
    echo "cron(0 ${hour_list} * * ? *)"
  fi
}
```

#### 2b. Update argument parsing

Replace lines 52-58:

```bash
INSTANCE_ID="${1:?Usage: deploy-scheduler.sh <instance-id> [interval-minutes] [region] [hours]}"
INTERVAL="${2:-60}"
REGION="${3:-${AWS_REGION:-eu-north-1}}"
HOURS="${4:-${SCHEDULE_HOURS:-6-22}}"

# Read timezone from deploy-state.json (set during deploy.sh)
TIMEZONE="UTC"
if [[ -f "${SCRIPT_DIR}/deploy-state.json" ]]; then
  TIMEZONE=$(python3 -c "import json; print(json.load(open('${SCRIPT_DIR}/deploy-state.json')).get('timezone', 'UTC'))" 2>/dev/null || echo "UTC")
fi

echo "Setting up EventBridge Scheduler to start instance ${INSTANCE_ID}"
echo "  Region: ${REGION}"
echo "  Interval: every ${INTERVAL} minutes"
echo "  Active hours: ${HOURS} (${TIMEZONE})"
echo ""
```

#### 2c. Replace rate() with cron() in schedule create/update

Replace lines 118-143:

```bash
# --- 2. Create EventBridge Schedule ------------------------------------------
CRON_EXPR=$(build_cron_expression "${INTERVAL}" "${HOURS}")
echo "Creating EventBridge Schedule..."
echo "  Expression: ${CRON_EXPR}"
echo "  Timezone: ${TIMEZONE}"

aws scheduler create-schedule \
  --name "$SCHEDULER_NAME" \
  --schedule-expression "${CRON_EXPR}" \
  --schedule-expression-timezone "${TIMEZONE}" \
  --target "{
    \"Arn\": \"arn:aws:scheduler:::aws-sdk:ec2:startInstances\",
    \"RoleArn\": \"${SCHEDULER_ROLE_ARN}\",
    \"Input\": \"{\\\"InstanceIds\\\":[\\\"${INSTANCE_ID}\\\"]}\"
  }" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --state ENABLED \
  --region "$REGION" \
  2>/dev/null || \
aws scheduler update-schedule \
  --name "$SCHEDULER_NAME" \
  --schedule-expression "${CRON_EXPR}" \
  --schedule-expression-timezone "${TIMEZONE}" \
  --target "{
    \"Arn\": \"arn:aws:scheduler:::aws-sdk:ec2:startInstances\",
    \"RoleArn\": \"${SCHEDULER_ROLE_ARN}\",
    \"Input\": \"{\\\"InstanceIds\\\":[\\\"${INSTANCE_ID}\\\"]}\"
  }" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --state ENABLED \
  --region "$REGION"

echo "  EventBridge Schedule created/updated."
```

Note: `update-schedule` requires ALL parameters re-specified (confirmed by AWS docs). The identical params in both calls is intentional and correct.

#### 2d. Update done summary

Replace lines 147-163:

```bash
echo ""
echo "============================================================"
echo " SCHEDULER DEPLOYED"
echo "============================================================"
echo ""
echo "Instance ${INSTANCE_ID} will be started on schedule:"
echo "  Expression:   ${CRON_EXPR}"
echo "  Timezone:     ${TIMEZONE}"
echo "  Active hours: ${HOURS}"
echo "  Interval:     every ${INTERVAL} minutes"
echo ""
echo "The instance self-stops after running tasks (if SCHEDULE_MODE=scheduled)."
echo ""
echo "To pause:  aws scheduler update-schedule --name ${SCHEDULER_NAME} --state DISABLED --region ${REGION} ..."
echo "To remove: ./deploy-scheduler.sh --remove"
echo "============================================================"
```

#### 2e. Update usage header

Replace lines 10-16:

```bash
# Usage:
#   ./deploy-scheduler.sh <instance-id> [interval-minutes] [region] [hours]
#
# Examples:
#   ./deploy-scheduler.sh i-0abc123def456789              # hourly 6-22, default region
#   ./deploy-scheduler.sh i-0abc123def456789 30           # every 30 min, 6-22
#   ./deploy-scheduler.sh i-0abc123def456789 60 eu-north-1 8-20  # hourly, 8am-8pm
```

### Verification

- [ ] `bash -n deploy-scheduler.sh` — no syntax errors
- [ ] Manually test `build_cron_expression` logic:
  - `build_cron_expression 30 6-22` → `cron(0/30 6-22 * * ? *)`
  - `build_cron_expression 60 6-22` → `cron(0 6-22 * * ? *)`
  - `build_cron_expression 120 6-22` → `cron(0 6,8,10,12,14,16,18,20,22 * * ? *)`
  - `build_cron_expression 180 6-22` → `cron(0 6,9,12,15,18,21 * * ? *)`
- [ ] Verify timezone is read from deploy-state.json correctly

### Implementation Status: Complete

---

## Phase 3: Active-Hours Guard

Add defense-in-depth to self-stop if the server is woken outside active hours.

### Changes

- `agent-orchestrator.sh:323-343` — Extract `do_hibernate()` function
- `agent-orchestrator.sh:61` — Add active-hours guard after config loading (uses `do_hibernate()`)
- `setup.sh:444-471` — Add active-hours guard to `agent-resume-check.sh` heredoc (inline hibernate)

### Detailed Steps

#### 3a. Extract do_hibernate() in agent-orchestrator.sh

Add near the top of the file (after line 30, before the lock section), a function:

```bash
# --- Hibernate helper --------------------------------------------------------
# Hibernate the instance (or fall back to shutdown). Used by the active-hours
# guard and the end-of-run self-stop.
do_hibernate() {
  local reason="${1:-Self-stop}"
  echo "${reason}: hibernating instance..."
  local inst_id region
  inst_id=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
  region=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
  if [[ -n "${inst_id}" && -n "${region}" ]]; then
    aws ec2 stop-instances --instance-ids "${inst_id}" --region "${region}" --hibernate 2>/dev/null || sudo shutdown -h now
  else
    echo "Could not get instance metadata. Falling back to shutdown."
    sudo shutdown -h now
  fi
}
```

Then update the existing self-stop at lines 335-343 to call `do_hibernate "Scheduled mode self-stop"` instead of duplicating the logic.

#### 3b. Add active-hours guard to agent-orchestrator.sh

Insert after line 61 (after config loading, before path derivation):

```bash
# --- Active-hours guard (scheduled mode only) --------------------------------
# If running in scheduled mode outside active hours, skip the run and self-stop.
# This prevents the server from staying awake if woken by a stale schedule,
# manual start, or hibernation resume outside active hours.
if [[ "${SCHEDULE_MODE:-always-on}" == "scheduled" && "${NO_STOP}" != "--no-stop" ]]; then
  ACTIVE_HOURS="${SCHEDULE_HOURS:-6-22}"
  CURRENT_HOUR=$(date +%-H)
  HOUR_START="${ACTIVE_HOURS%%-*}"
  HOUR_END="${ACTIVE_HOURS##*-}"
  if [[ ${CURRENT_HOUR} -lt ${HOUR_START} || ${CURRENT_HOUR} -gt ${HOUR_END} ]]; then
    echo "Outside active hours (${ACTIVE_HOURS}, current: ${CURRENT_HOUR}). Skipping run."
    do_hibernate "Outside active hours"
    exit 0
  fi
  echo "Active hours check: OK (${ACTIVE_HOURS}, current: ${CURRENT_HOUR})"
fi
```

Note: uses `date +%-H` (server local time), not `date -u`.

#### 3c. Add active-hours guard to agent-resume-check.sh

In `setup.sh`, in the resume-check heredoc (lines 444-471), insert after the `INTERVAL_SEC` line (line 451) and before the heartbeat check:

```bash
# Check active hours — if outside, stop the instance instead of running
ACTIVE_HOURS="${SCHEDULE_HOURS:-6-22}"
CURRENT_HOUR=$(date +%-H)
HOUR_START="${ACTIVE_HOURS%%-*}"
HOUR_END="${ACTIVE_HOURS##*-}"
if [[ ${CURRENT_HOUR} -lt ${HOUR_START} || ${CURRENT_HOUR} -gt ${HOUR_END} ]]; then
  echo "Resume check: outside active hours (${ACTIVE_HOURS}, current: ${CURRENT_HOUR}). Stopping."
  INSTANCE_ID=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
  REGION=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
  if [[ -n "${INSTANCE_ID}" && -n "${REGION}" ]]; then
    aws ec2 stop-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" --hibernate 2>/dev/null || sudo shutdown -h now
  else
    sudo shutdown -h now
  fi
  exit 0
fi
```

Hibernate logic is inline here (no shared function file exists for this standalone script).

#### 3d. Update existing self-stop to use do_hibernate()

Replace lines 335-343 in `agent-orchestrator.sh`:

```bash
  else
    do_hibernate "Scheduled mode self-stop"
  fi
```

Remove the old inline curl/aws/shutdown block.

### New Tests

No automated tests (bash scripts, no test framework). Manual verification steps below.

### Verification

- [ ] `bash -n agent-orchestrator.sh` — no syntax errors
- [ ] `bash -n setup.sh` — no syntax errors
- [ ] Verify `do_hibernate` function is defined before the lock section
- [ ] Verify active-hours guard is placed after config loading but before path derivation
- [ ] Verify the existing self-stop section now calls `do_hibernate` instead of inline logic
- [ ] Verify resume-check heredoc has the active-hours guard after `INTERVAL_SEC`
- [ ] Confirm all `date` calls use `+%-H` (local time), not `-u`

### Implementation Status: Complete

---

## Phase 4: Manager Integration and Reporting

Update `agent-manager.sh` to pass hours through and report both cron + EventBridge changes to the user.

### Changes

- `agent-manager.sh:5-13` — Update usage header to include hours parameter
- `agent-manager.sh:80-89` — Update `cmd_status` to show hours
- `agent-manager.sh:228-260` — Rewrite `cmd_scheduled` to pass hours to both server and EventBridge
- `agent-manager.sh:275-289` — Update `cmd_help` to show hours syntax
- `agent-manager.sh:300` — Update dispatch to pass third arg
- `setup.sh:600-618` — Update `set-schedule-mode.sh` output to report both systems

### Detailed Steps

#### 4a. Update cmd_status

In `agent-manager.sh`, replace lines 84-88:

```bash
    if [[ "$mode" == "scheduled" ]]; then
      local hours="${SCHEDULE_HOURS:-6-22}"
      echo -e "  Mode:       ${CYAN}scheduled${NC} (every ${SCHEDULE_INTERVAL:-60} min, hours ${hours})"
    else
      echo -e "  Mode:       ${CYAN}${mode}${NC}"
    fi
```

#### 4b. Rewrite cmd_scheduled

Replace lines 228-260:

```bash
cmd_scheduled() {
  local interval="${1:-60}"
  local hours="${2:-${SCHEDULE_HOURS:-6-22}}"
  local state
  state=$(get_instance_state)

  # Switch mode on the server (pass interval and hours)
  if [[ "${state}" == "running" ]]; then
    log "Setting server to scheduled mode..."
    ssh -o ConnectTimeout=5 "${SSH_HOST}" "sudo ~/scripts/set-schedule-mode.sh scheduled ${interval} ${hours}" 2>/dev/null || true
  else
    warn "Instance is ${state}. Mode will be set on next boot."
  fi

  # Deploy EventBridge scheduler (with hours)
  log "Deploying EventBridge scheduler (every ${interval} min, hours ${hours})..."
  if [[ -f "${SCRIPT_DIR}/deploy-scheduler.sh" ]]; then
    bash "${SCRIPT_DIR}/deploy-scheduler.sh" "${INSTANCE_ID}" "${interval}" "${REGION}" "${hours}"
  else
    err "deploy-scheduler.sh not found."
    return 1
  fi

  # Update local agent.conf
  if [[ -f "${SCRIPT_DIR}/agent.conf" ]]; then
    sed -i.bak 's/^SCHEDULE_MODE=.*/SCHEDULE_MODE="scheduled"/' "${SCRIPT_DIR}/agent.conf"
    sed -i.bak "s/^SCHEDULE_INTERVAL=.*/SCHEDULE_INTERVAL=${interval}/" "${SCRIPT_DIR}/agent.conf"
    if grep -q '^SCHEDULE_HOURS=' "${SCRIPT_DIR}/agent.conf"; then
      sed -i.bak "s/^SCHEDULE_HOURS=.*/SCHEDULE_HOURS=\"${hours}\"/" "${SCRIPT_DIR}/agent.conf"
    fi
    rm -f "${SCRIPT_DIR}/agent.conf.bak"
    log "Updated agent.conf"
  fi

  echo ""
  log "Mode switched to scheduled."
  echo ""
  echo -e "  ${BOLD}Both systems updated:${NC}"
  echo -e "  ${CYAN}EventBridge:${NC} wakes instance every ${interval} min during hours ${hours}"
  echo -e "  ${CYAN}Server cron:${NC} runs orchestrator every ${interval} min during hours ${hours}"
  echo -e "  ${CYAN}Active guard:${NC} self-stops immediately if woken outside hours ${hours}"
  echo ""
}
```

#### 4c. Update usage header, help, and dispatch

Header (line 10):
```bash
#   ./agent-manager.sh --scheduled [N] [H]  Switch to scheduled mode (every N min, hours H, default 60/6-22)
```

Help (add after line 285):
```bash
echo -e "  ${CYAN}./agent-manager.sh --scheduled 60 8-20${NC}  Scheduled, every 60 min, 8am-8pm"
```

Dispatch (line 300):
```bash
  --scheduled|scheduled)     cmd_scheduled "${2:-60}" "${3:-}" ;;
```

#### 4d. Update set-schedule-mode.sh output

In `setup.sh`, in the `set-schedule-mode.sh` heredoc, replace the scheduled-mode echo block (lines 600-609):

```bash
if [[ "$MODE" == "scheduled" ]]; then
  systemctl enable agent-boot-runner.service
  systemctl enable agent-resume-runner.service
  echo "Switched to SCHEDULED mode."
  echo ""
  echo "  Server-side (updated now):"
  echo "    Cron: every ${CRON_INTERVAL} min during hours ${CRON_HOURS}"
  echo "    Boot runner: enabled"
  echo "    Resume runner: enabled"
  echo "    Active guard: self-stops if woken outside hours ${CRON_HOURS}"
  echo "    Self-stop: enabled after each run"
  echo ""
  echo "  Client-side (run from local machine):"
  echo "    Run ./agent-manager.sh --scheduled to update EventBridge."
  echo "    To prevent self-stop during SSH: touch ~/agents/.keep-running"
```

### Verification

- [ ] `bash -n agent-manager.sh` — no syntax errors
- [ ] `bash -n setup.sh` — no syntax errors
- [ ] Verify `cmd_scheduled` passes hours to both SSH and deploy-scheduler calls
- [ ] Verify dispatch line passes `${3:-}` to cmd_scheduled
- [ ] Verify set-schedule-mode.sh output mentions both cron and EventBridge

### Implementation Status: Complete

---

## Phase 5: Extract Heredoc Scripts to Standalone Files

Replace inline heredoc scripts in `setup.sh` with standalone files that `setup.sh` copies into place. This makes server-side scripts independently testable, editable, and upgradeable.

### Scope

Extract these 4 script files (they contain real logic):

| Heredoc in setup.sh | Target on server | Description |
|---|---|---|
| `RESUME_SCRIPT` (line ~449) | `~/scripts/agent-resume-check.sh` | Active-hours guard + heartbeat interval check |
| `TOGGLE_SCRIPT` (line ~589) | `~/scripts/set-schedule-mode.sh` | Mode toggle, cron update, systemd enable/disable |
| `AGENT_SCRIPT` (line ~396) | `~/scripts/run-agent.sh` | Simple Claude Code runner with logging |
| `INSTALL_TMPL` (line ~825) | `~/scripts/install-templates.sh` | Template file installer |

**NOT extracting** (config templates that need deploy-time variable substitution):
- Systemd service files (boot-runner, resume-runner, upgrade, ttyd)
- Cron files (`/etc/cron.d/agent-orchestrator`, `/etc/cron.d/agent-upgrade`)
- Config files (`.agent-env`, `.agent-schedule`, MOTD, bashrc additions)
- `README.md`, `tools-manifest.txt`

### Design Decisions

- **Self-contained scripts**: Each extracted script detects `HOME_DIR` at runtime (`${HOME:-/home/ubuntu}`) and sources its own config files. No variables need to be substituted at copy time.
- **Shared functions file**: Create `scripts/agent-functions.sh` sourced by both `agent-orchestrator.sh` and the extracted scripts. Contains `do_hibernate()` and active-hours check logic, eliminating duplication.
- **Config sourcing pattern**: All scripts follow the same pattern at the top:
  ```bash
  HOME_DIR="${HOME:-/home/ubuntu}"
  source "${HOME_DIR}/.agent-schedule" 2>/dev/null || true
  source "${HOME_DIR}/.agent-server.conf" 2>/dev/null || true
  ```
- **setup.sh becomes a copier**: For these 4 scripts, `setup.sh` replaces heredocs with simple `cp` + `chmod` + `chown` lines, matching how it already handles `agent-orchestrator.sh` and `agent-cli.sh`.

### Changes

#### 5a. Create `scripts/agent-functions.sh`

New file in the repo root. Contains shared utilities:

```bash
#!/usr/bin/env bash
# Shared functions for agent server scripts.
# Sourced by agent-orchestrator.sh, agent-resume-check.sh, etc.

# Hibernate the instance (or fall back to shutdown).
do_hibernate() {
  local reason="${1:-Self-stop}"
  echo "${reason}: hibernating instance..."
  local inst_id region
  inst_id=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
  region=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
  if [[ -n "${inst_id}" && -n "${region}" ]]; then
    aws ec2 stop-instances --instance-ids "${inst_id}" --region "${region}" --hibernate 2>/dev/null || sudo shutdown -h now
  else
    echo "Could not get instance metadata. Falling back to shutdown."
    sudo shutdown -h now
  fi
}

# Check if current hour is within active hours. Returns 0 if inside, 1 if outside.
check_active_hours() {
  local hours="${1:-6-22}"
  local current_hour
  current_hour=$(date +%-H)
  local hour_start="${hours%%-*}"
  local hour_end="${hours##*-}"
  if [[ ${current_hour} -lt ${hour_start} || ${current_hour} -gt ${hour_end} ]]; then
    return 1
  fi
  return 0
}
```

#### 5b. Create standalone `agent-resume-check.sh`

New file in repo root (alongside `agent-orchestrator.sh`):

```bash
#!/usr/bin/env bash
# Run orchestrator on resume from hibernation — only if last run was long enough ago
# and we're within active hours.
set -uo pipefail
HOME_DIR="${HOME:-/home/ubuntu}"
source "${HOME_DIR}/.agent-schedule" 2>/dev/null || true
source "${HOME_DIR}/.agent-server.conf" 2>/dev/null || true
SCRIPTS_DIR="${HOME_DIR}/scripts"

# Source shared functions
if [[ -f "${SCRIPTS_DIR}/agent-functions.sh" ]]; then
  source "${SCRIPTS_DIR}/agent-functions.sh"
fi

# Active-hours guard
if ! check_active_hours "${SCHEDULE_HOURS:-6-22}"; then
  echo "Resume check: outside active hours (${SCHEDULE_HOURS:-6-22}). Stopping."
  do_hibernate "Outside active hours (resume)"
  exit 0
fi

# Heartbeat interval check
INTERVAL_SEC=$(( ${SCHEDULE_INTERVAL:-60} * 60 ))
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
HEARTBEAT="${HOME_DIR}/brain/${OUTPUT_FOLDER}/.agent-heartbeat"

if [[ -f "${HEARTBEAT}" ]]; then
  LAST_RUN=$(grep '^last_run=' "${HEARTBEAT}" | cut -d= -f2)
  if [[ -n "${LAST_RUN}" ]]; then
    LAST_EPOCH=$(date -d "${LAST_RUN}" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE=$(( NOW_EPOCH - LAST_EPOCH ))
    if [[ ${AGE} -lt ${INTERVAL_SEC} ]]; then
      echo "Resume check: last run was ${AGE}s ago (< ${INTERVAL_SEC}s). Skipping."
      exit 0
    fi
    echo "Resume check: last run was ${AGE}s ago (>= ${INTERVAL_SEC}s). Running orchestrator."
  fi
else
  echo "Resume check: no heartbeat file found. Running orchestrator."
fi
exec "${SCRIPTS_DIR}/agent-orchestrator.sh"
```

#### 5c. Create standalone `set-schedule-mode.sh`

New file in repo root:

```bash
#!/usr/bin/env bash
# Toggle between always-on and scheduled mode.
# Usage: set-schedule-mode.sh <always-on|scheduled> [interval] [hours]
set -euo pipefail
HOME_DIR="${HOME:-/home/ubuntu}"

MODE="${1:?Usage: set-schedule-mode.sh <always-on|scheduled> [interval] [hours]}"
if [[ "$MODE" != "always-on" && "$MODE" != "scheduled" ]]; then
  echo "ERROR: Mode must be 'always-on' or 'scheduled'"
  exit 1
fi

# Update .agent-schedule
sed -i "s/^SCHEDULE_MODE=.*/SCHEDULE_MODE=\"${MODE}\"/" "${HOME_DIR}/.agent-schedule"

INTERVAL="${2:-}"
if [[ -n "$INTERVAL" ]]; then
  sed -i "s/^SCHEDULE_INTERVAL=.*/SCHEDULE_INTERVAL=\"${INTERVAL}\"/" "${HOME_DIR}/.agent-schedule"
fi

HOURS="${3:-}"
if [[ -n "$HOURS" ]]; then
  if grep -q '^SCHEDULE_HOURS=' "${HOME_DIR}/.agent-schedule"; then
    sed -i "s/^SCHEDULE_HOURS=.*/SCHEDULE_HOURS=\"${HOURS}\"/" "${HOME_DIR}/.agent-schedule"
  else
    echo "SCHEDULE_HOURS=\"${HOURS}\"" >> "${HOME_DIR}/.agent-schedule"
  fi
fi

# Re-source for cron update
source "${HOME_DIR}/.agent-schedule" 2>/dev/null || true
CRON_INTERVAL="${SCHEDULE_INTERVAL:-60}"
CRON_HOURS="${SCHEDULE_HOURS:-6-22}"

# Update orchestrator cron
sudo tee /etc/cron.d/agent-orchestrator > /dev/null << CRON
# Run agent orchestrator every ${CRON_INTERVAL} minutes during active hours
*/${CRON_INTERVAL} ${CRON_HOURS} * * * $(whoami) ${HOME_DIR}/scripts/agent-orchestrator.sh >> ${HOME_DIR}/logs/cron-orchestrator.log 2>&1
CRON
sudo chmod 644 /etc/cron.d/agent-orchestrator

# Enable/disable systemd services and report
if [[ "$MODE" == "scheduled" ]]; then
  systemctl enable agent-boot-runner.service
  systemctl enable agent-resume-runner.service
  echo "Switched to SCHEDULED mode."
  echo ""
  echo "  Server-side (updated now):"
  echo "    Cron: every ${CRON_INTERVAL} min during hours ${CRON_HOURS}"
  echo "    Boot runner: enabled"
  echo "    Resume runner: enabled"
  echo "    Active guard: self-stops if woken outside hours ${CRON_HOURS}"
  echo "    Self-stop: enabled after each run"
  echo ""
  echo "  Client-side (run from local machine):"
  echo "    Run ./agent-manager.sh --scheduled to update EventBridge."
  echo "    To prevent self-stop during SSH: touch ~/agents/.keep-running"
else
  systemctl disable agent-boot-runner.service
  systemctl disable agent-resume-runner.service
  echo "Switched to ALWAYS-ON mode (every ${CRON_INTERVAL} min)."
  echo "  Boot runner: disabled"
  echo "  Resume runner: disabled"
  echo "  Cron: every ${CRON_INTERVAL} min"
  echo "  Self-stop: disabled"
fi

echo ""
cat "${HOME_DIR}/.agent-schedule"
```

#### 5d. Create standalone `run-agent.sh`

New file in repo root:

```bash
#!/usr/bin/env bash
# Run a Claude Code agent task with logging.
# Usage: ./run-agent.sh "Your prompt here" [working-directory]
set -euo pipefail

PROMPT="${1:?Usage: run-agent.sh \"prompt\" [working-dir]}"
WORKDIR="${2:-$HOME/agents}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOGFILE="$HOME/logs/agent-${TIMESTAMP}.log"

[[ -z "${ANTHROPIC_API_KEY:-}" ]] && source ~/.agent-env 2>/dev/null

echo "[$(date)] Starting agent in ${WORKDIR}" | tee -a "${LOGFILE}"
echo "[$(date)] Prompt: ${PROMPT}" | tee -a "${LOGFILE}"

cd "${WORKDIR}"
claude -p "${PROMPT}" --max-turns 50 2>&1 | tee -a "${LOGFILE}"

echo "[$(date)] Agent finished." | tee -a "${LOGFILE}"
```

#### 5e. Create standalone `install-templates.sh`

New file in repo root:

```bash
#!/usr/bin/env bash
# Install template files into the brain directory.
# Usage: ./install-templates.sh
set -euo pipefail

BRAIN="${HOME}/brain"

# Try pending-templates first, fall back to .agent-templates, then repo
if [[ -d "${HOME}/pending-templates" ]]; then
  TEMPLATES="${HOME}/pending-templates"
elif [[ -d "${HOME}/.agent-templates" ]]; then
  TEMPLATES="${HOME}/.agent-templates"
elif [[ -d "${HOME}/.agent-repo/templates" ]]; then
  TEMPLATES="${HOME}/.agent-repo/templates"
else
  echo "No templates found. Nothing to install."
  exit 0
fi

if [[ ! -d "${BRAIN}" ]]; then
  echo "ERROR: ${BRAIN} not found."
  exit 1
fi

source "${HOME}/.agent-server.conf" 2>/dev/null || true
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"

mkdir -p "${BRAIN}/ai/instructions"
mkdir -p "${BRAIN}/INBOX/_processed"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/tasks"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/logs"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/research"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/improvements"

for f in "${TEMPLATES}"/*.md; do
  [[ ! -f "$f" ]] && continue
  BASENAME=$(basename "$f")
  if [[ "$BASENAME" == "CLAUDE.md" ]]; then
    TARGET="${BRAIN}/CLAUDE.md"
  else
    TARGET="${BRAIN}/ai/instructions/${BASENAME}"
  fi
  if [[ ! -f "${TARGET}" ]]; then
    cp "$f" "${TARGET}"
    echo "  Installed: ${TARGET}"
  else
    echo "  Skipped (exists): ${TARGET}"
  fi
done

echo ""
echo "Done. You can remove ~/pending-templates/ now."
```

#### 5f. Update `agent-orchestrator.sh` to source shared functions

Replace the inline `do_hibernate()` function with:

```bash
# Source shared functions (hibernate, active-hours check)
SCRIPTS_DIR="${HOME_DIR}/scripts"
if [[ -f "${SCRIPTS_DIR}/agent-functions.sh" ]]; then
  source "${SCRIPTS_DIR}/agent-functions.sh"
fi
```

Replace the inline active-hours guard with:

```bash
if [[ "${SCHEDULE_MODE:-always-on}" == "scheduled" && "${NO_STOP}" != "--no-stop" ]]; then
  if ! check_active_hours "${SCHEDULE_HOURS:-6-22}"; then
    echo "Outside active hours (${SCHEDULE_HOURS:-6-22}, current: $(date +%-H)). Skipping run."
    do_hibernate "Outside active hours"
    exit 0
  fi
  echo "Active hours check: OK (${SCHEDULE_HOURS:-6-22}, current: $(date +%-H))"
fi
```

#### 5g. Update `setup.sh` — replace heredocs with copies

Replace each heredoc block with a copy pattern. Example for `agent-resume-check.sh`:

```bash
# Before (heredoc):
# cat > ${HOME_DIR}/scripts/agent-resume-check.sh << 'RESUME_SCRIPT'
# ... 25 lines of script ...
# RESUME_SCRIPT

# After (copy from repo):
if [[ -f "${SCRIPT_DIR}/agent-resume-check.sh" ]]; then
  cp "${SCRIPT_DIR}/agent-resume-check.sh" "${HOME_DIR}/scripts/agent-resume-check.sh"
else
  warn "agent-resume-check.sh not found in ${SCRIPT_DIR}."
fi
chmod +x "${HOME_DIR}/scripts/agent-resume-check.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/agent-resume-check.sh"
```

Repeat for: `set-schedule-mode.sh`, `run-agent.sh`, `install-templates.sh`, `agent-functions.sh`.

### Verification

- [ ] `bash -n agent-functions.sh` — no syntax errors
- [ ] `bash -n agent-resume-check.sh` — no syntax errors
- [ ] `bash -n set-schedule-mode.sh` — no syntax errors
- [ ] `bash -n run-agent.sh` — no syntax errors
- [ ] `bash -n install-templates.sh` — no syntax errors
- [ ] `bash -n agent-orchestrator.sh` — no syntax errors (after sourcing change)
- [ ] `bash -n setup.sh` — no syntax errors (after heredoc removal)
- [ ] Verify all extracted scripts source `.agent-schedule` and `.agent-server.conf`
- [ ] Verify `agent-functions.sh` contains `do_hibernate()` and `check_active_hours()`
- [ ] Verify `agent-orchestrator.sh` no longer has inline `do_hibernate()` — uses sourced version
- [ ] Deploy to server and run `set-schedule-mode.sh scheduled 60 6-20` — should work identically

### Implementation Status: Complete

---

## Evaluation Notes

### Architecture
- Config flow follows established pattern: `agent.conf` → `setup.sh` → `.agent-schedule` → runtime scripts
- Timezone stored in `deploy-state.json` (for local scripts) and `.agent-schedule` (for server scripts) matches the existing two-file pattern
- `do_hibernate()` extraction reduces duplication within `agent-orchestrator.sh`; inline duplication in `agent-resume-check.sh` is acceptable (no shared-functions file exists)
- `build_cron_expression()` is the first utility function in `deploy-scheduler.sh` — consistent with the script's self-contained nature

### Security
- No new attack surface. EventBridge permissions unchanged (scoped to `ec2:StartInstances` on one instance)
- Timezone string comes from deploy-state.json written by deploy.sh, not user input

### Scalability
- N/A — single instance scheduling

### Usability
- User sees both cron and EventBridge changes reported together when running `--scheduled`
- `set-schedule-mode.sh` on the server also reports both systems
- Hours parameter is optional everywhere with `6-22` default — existing workflows unchanged

---

## Post-Verification Changes (2026-03-12)

After the initial implementation was completed, the following enhancements were added during iteration.

### 1. Add --run-agent command

**Category**: New functionality

**What changed**: Added `cmd_run_agent()` to `agent-manager.sh` that wakes the instance if needed, triggers the orchestrator in the background via SSH (`nohup`), and reports the PID. Does not follow execution to completion.

**Files affected**:
- `agent-manager.sh` — new function, updated header/help/dispatch

**Rationale**: Users need a quick way to trigger an agent run without SSHing in and waiting for it to finish.

### 2. Add --history command

**Category**: New functionality

**What changed**: Added `cmd_history()` to `agent-manager.sh` that renders an ASCII timeline of instance activity. Uses CloudWatch CPUUtilization (hourly) for wake/sleep detection and orchestrator log filenames for run detection. Renders with python3, converts CloudWatch UTC timestamps to local timezone (from deploy-state.json). Each hour is 2 chars wide, green for runs, yellow for awake-idle, dim dots for stopped.

**Files affected**:
- `agent-manager.sh` — new function, updated header/help/dispatch

**Rationale**: Users need visibility into when the server was active and when the agent ran, especially to verify the new schedule alignment is working correctly.

### 3. Granular single-day history + stats bug fix

**Category**: UX refinement + Bug fix

**What changed**:
- **Bug fix**: Stats (awake hours, runs) were counting all data from log files regardless of display range. Added date-range filtering so only displayed days are counted.
- **Enhancement**: When `--history 1`, an **Events** section is appended below the bar chart showing precise HH:MM timestamps for each wake-up, orchestrator start, agent finish (with exit code), and hibernate event. Timestamps come from log filenames (start) and file mtime (end/hibernate).

**Files affected**:
- `agent-manager.sh` — enhanced SSH data collection for single-day mode (ENDTIME via `stat`), date-range filtering in python renderer, new event timeline rendering block

**Rationale**: The hourly bar chart is too coarse for a single day. Users need exact times to debug schedule alignment. The stats bug was misleading (showing 21 runs when only 3 were visible).

### 4. Pre-flight tool checks, config loading, UX fixes

**Category**: Bug fix + UX refinement

**What changed**:
- **Tool checks**: Added `check_tools()` at startup that verifies `aws`, `python3`, `ssh`, `scp` are available, with clear error messages and install links if missing.
- **Config loading**: Moved `source agent.conf` to top level so `SCHEDULE_HOURS` and other config vars are available to all commands (fixes hard-coded `6-22` fallback in `cmd_scheduled`).
- **Run-agent output**: Message now reflects scheduled vs always-on mode ("will self-stop" vs "stays running").
- **History stats**: Replaced misleading "Awake hours" with "Hours with wake-ups" and "Total runs". Added per-day run count next to each bar (e.g. "3 runs"). Shows idle hours only when there are some.

**Files affected**:
- `agent-manager.sh` — new `check_tools()`, global config load, updated `cmd_run_agent`, updated python renderer

---

## Implementation Summary

**Phases 1-5:** Completed 2026-03-12
**Test status:** All syntax checks passing

### Deviations from Plan
- Phase 5 added after initial implementation to address maintainability of heredoc scripts
- Shared functions file (`agent-functions.sh`) added — reverses the earlier "What We're NOT Doing" decision, now that multiple scripts need `do_hibernate()` and `check_active_hours()`

### Learnings
- Heredoc-generated scripts are a maintenance burden: changes require editing quoting-sensitive code inside heredocs, can't be syntax-checked independently, and don't benefit from the auto-upgrade mechanism
- The plan's line references were close enough despite minor shifts from earlier edits
