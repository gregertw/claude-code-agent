#!/usr/bin/env bash
# =============================================================================
# agent-manager — Manage your agent server from your LOCAL machine
# =============================================================================
# Usage:
#   ./agent-manager.sh                 Show server status (default)
#   ./agent-manager.sh --wakeup        Start a stopped instance, wait for SSH
#   ./agent-manager.sh --sleep         Stop a running instance
#   ./agent-manager.sh --always-on     Switch to always-on mode (remove scheduler)
#   ./agent-manager.sh --scheduled [N] [H]  Switch to scheduled mode (every N min, hours H, default 60/6-22)
#   ./agent-manager.sh --run-agent     Trigger an agent run (fire and forget)
#   ./agent-manager.sh --history [N]   Show wake/sleep/run timeline (last N days, default 7)
#   ./agent-manager.sh --ssh           SSH into the server
#   ./agent-manager.sh --ssh-mcp       SSH with MCP port forwarding (for auth)
#   ./agent-manager.sh --help          Show this help
#
# Reads deploy-state.json (created by deploy.sh) for instance details.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/deploy-state.json"

# --- Colors ------------------------------------------------------------------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()  { echo -e "${GREEN}[AGENT]${NC} $1"; }
warn() { echo -e "${YELLOW}[NOTE]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Pre-flight: required tools ---------------------------------------------
check_tools() {
  local missing=()
  command -v aws &>/dev/null    || missing+=("aws (AWS CLI — https://aws.amazon.com/cli/)")
  command -v python3 &>/dev/null || missing+=("python3")
  command -v ssh &>/dev/null     || missing+=("ssh")
  command -v scp &>/dev/null     || missing+=("scp")
  if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing required tools:"
    for tool in "${missing[@]}"; do
      echo -e "  ${RED}✗${NC} ${tool}"
    done
    echo ""
    echo "Install the missing tools and try again."
    exit 1
  fi
}
check_tools

# --- Load configuration -----------------------------------------------------
# Source agent.conf so SCHEDULE_* variables are available to all commands.
if [[ -f "${SCRIPT_DIR}/agent.conf" ]]; then
  source "${SCRIPT_DIR}/agent.conf"
fi

# --- Load state --------------------------------------------------------------
load_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    err "deploy-state.json not found. Run deploy.sh first."
    exit 1
  fi
  INSTANCE_ID=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['instance_id'])")
  REGION=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['region'])")
  SSH_HOST=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['ssh_config_host'])")
  ELASTIC_IP=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['elastic_ip'])")
  OWNER=$(python3 -c "import json; print(json.load(open('${STATE_FILE}'))['owner'])")
}

# --- Get instance state ------------------------------------------------------
get_instance_state() {
  aws ec2 describe-instances \
    --instance-ids "${INSTANCE_ID}" \
    --region "${REGION}" \
    --query 'Reservations[0].Instances[0].State.Name' \
    --output text 2>/dev/null || echo "unknown"
}

# --- Commands ----------------------------------------------------------------

cmd_status() {
  local state
  state=$(get_instance_state)

  echo ""
  echo -e "${BOLD}  Agent Server — ${OWNER}${NC}"
  echo "  ─────────────────────────────────"
  echo -e "  Instance:   ${INSTANCE_ID}"
  echo -e "  Region:     ${REGION}"
  echo -e "  Elastic IP: ${ELASTIC_IP}"

  # Instance state with color
  case "${state}" in
    running)  echo -e "  State:      ${GREEN}running${NC}" ;;
    stopped)  echo -e "  State:      ${DIM}stopped${NC}" ;;
    stopping) echo -e "  State:      ${YELLOW}stopping${NC}" ;;
    pending)  echo -e "  State:      ${YELLOW}starting${NC}" ;;
    *)        echo -e "  State:      ${RED}${state}${NC}" ;;
  esac

  # Schedule info (agent.conf sourced at top level)
  local mode="${SCHEDULE_MODE:-unknown}"
  if [[ "$mode" == "scheduled" ]]; then
    echo -e "  Mode:       ${CYAN}scheduled${NC} (every ${SCHEDULE_INTERVAL:-60} min, hours ${SCHEDULE_HOURS:-6-22})"
  else
    echo -e "  Mode:       ${CYAN}${mode}${NC}"
  fi

  # If running, try to get on-server status
  if [[ "${state}" == "running" ]]; then
    echo ""
    local remote_status
    remote_status=$(ssh -o ConnectTimeout=5 "${SSH_HOST}" "agent status" 2>/dev/null) || true
    if [[ -n "${remote_status}" ]]; then
      echo "${remote_status}"
    else
      echo -e "  ${DIM}(could not reach server via SSH)${NC}"
    fi
  fi

  echo ""
  echo -e "  ${DIM}Commands: --wakeup, --sleep, --run-agent, --history, --scheduled, --ssh${NC}"
  echo ""
}

cmd_wakeup() {
  local state
  state=$(get_instance_state)

  if [[ "${state}" == "running" ]]; then
    log "Instance is already running."
    log "SSH: ssh ${SSH_HOST}"
    return 0
  elif [[ "${state}" == "pending" ]]; then
    log "Instance is already starting up..."
  elif [[ "${state}" == "stopping" ]]; then
    warn "Instance is still stopping. Waiting for it to fully stop..."
    aws ec2 wait instance-stopped --instance-ids "${INSTANCE_ID}" --region "${REGION}"
    log "Instance stopped. Starting it now..."
    aws ec2 start-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" >/dev/null
  elif [[ "${state}" == "stopped" ]]; then
    log "Starting instance ${INSTANCE_ID}..."
    aws ec2 start-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" >/dev/null
  else
    err "Instance is in unexpected state: ${state}"
    return 1
  fi

  log "Waiting for instance to be running..."
  aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${REGION}"
  log "Instance is running."

  log "Waiting for SSH..."
  for i in $(seq 1 30); do
    if ssh -o ConnectTimeout=5 "${SSH_HOST}" "echo ready" 2>/dev/null; then
      break
    fi
    if [[ $i -eq 30 ]]; then
      warn "SSH not available after 150 seconds. Try manually: ssh ${SSH_HOST}"
      return 1
    fi
    sleep 5
  done

  echo ""
  log "Server is ready."
  log "SSH: ssh ${SSH_HOST}"
  echo ""
  warn "In scheduled mode, the boot runner may have already started."
  warn "To prevent self-stop: ssh ${SSH_HOST} 'touch ~/agents/.keep-running'"
  echo ""
}

cmd_sleep() {
  local state
  state=$(get_instance_state)

  if [[ "${state}" == "stopped" ]]; then
    log "Instance is already stopped."
    return 0
  elif [[ "${state}" == "stopping" ]]; then
    log "Instance is already stopping..."
    return 0
  elif [[ "${state}" != "running" ]]; then
    err "Instance is in state '${state}' — can only stop a running instance."
    return 1
  fi

  log "Hibernating instance ${INSTANCE_ID}..."
  aws ec2 stop-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" --hibernate >/dev/null 2>&1 || {
    warn "Hibernate not available, falling back to stop..."
    aws ec2 stop-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" >/dev/null
  }
  log "Hibernate/stop command sent. Instance will freeze shortly."
}

cmd_ssh() {
  local state
  state=$(get_instance_state)

  if [[ "${state}" != "running" ]]; then
    err "Instance is ${state}. Use --wakeup first."
    return 1
  fi

  exec ssh "${SSH_HOST}"
}

cmd_always_on() {
  local state
  state=$(get_instance_state)

  # Switch mode on the server
  if [[ "${state}" == "running" ]]; then
    log "Setting server to always-on mode..."
    ssh -o ConnectTimeout=5 "${SSH_HOST}" "sudo ~/scripts/set-schedule-mode.sh always-on" 2>/dev/null || true
  else
    warn "Instance is ${state}. Mode will be set on next boot."
  fi

  # Remove EventBridge scheduler
  log "Removing EventBridge scheduler..."
  if [[ -f "${SCRIPT_DIR}/deploy-scheduler.sh" ]]; then
    bash "${SCRIPT_DIR}/deploy-scheduler.sh" --remove "${REGION}"
  else
    warn "deploy-scheduler.sh not found. Remove scheduler manually."
  fi

  # Update local agent.conf
  if [[ -f "${SCRIPT_DIR}/agent.conf" ]]; then
    sed -i.bak 's/^SCHEDULE_MODE=.*/SCHEDULE_MODE="always-on"/' "${SCRIPT_DIR}/agent.conf"
    rm -f "${SCRIPT_DIR}/agent.conf.bak"
    log "Updated agent.conf: SCHEDULE_MODE=\"always-on\""
  fi

  # Ensure instance is running
  if [[ "${state}" == "stopped" ]]; then
    log "Starting instance (always-on means it should be running)..."
    cmd_wakeup
  fi

  echo ""
  log "Mode switched to always-on. Instance will run 24/7."
}

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

cmd_run_agent() {
  local state
  state=$(get_instance_state)

  # Wake up if needed
  if [[ "${state}" != "running" ]]; then
    cmd_wakeup
  fi

  # Check if orchestrator is already running
  local existing_pid
  existing_pid=$(ssh -o ConnectTimeout=5 "${SSH_HOST}" "pgrep -f 'agent-orchestrator.sh' 2>/dev/null" || echo "")
  if [[ -n "${existing_pid}" ]]; then
    warn "Orchestrator is already running (pid ${existing_pid})."
    echo -e "  Monitor: ${CYAN}ssh ${SSH_HOST} 'tail -f ~/logs/orchestrator-*.log'${NC}"
    return 0
  fi

  # Trigger orchestrator in background
  log "Starting agent orchestrator..."
  local pid
  pid=$(ssh -o ConnectTimeout=5 "${SSH_HOST}" \
    "nohup ~/scripts/agent-orchestrator.sh </dev/null >> ~/logs/cron-orchestrator.log 2>&1 & echo \$!" 2>/dev/null)

  # Brief wait, then confirm
  sleep 2
  local running
  running=$(ssh -o ConnectTimeout=5 "${SSH_HOST}" "pgrep -f 'agent-orchestrator.sh' 2>/dev/null" || echo "")
  if [[ -n "${running}" ]]; then
    log "Orchestrator started (pid ${running})."
    echo ""
    echo -e "  The agent is running in the background."
    if [[ "${SCHEDULE_MODE:-always-on}" == "scheduled" ]]; then
      echo -e "  It will self-stop (hibernate) after completing tasks."
    else
      echo -e "  Instance stays running after tasks complete (always-on mode)."
    fi
    echo ""
    echo -e "  Monitor: ${CYAN}ssh ${SSH_HOST} 'tail -f ~/logs/orchestrator-*.log'${NC}"
  else
    err "Orchestrator may not have started. Check: ssh ${SSH_HOST} 'agent status'"
  fi
  echo ""
}

cmd_ssh_mcp() {
  local state
  state=$(get_instance_state)

  if [[ "${state}" != "running" ]]; then
    err "Instance is ${state}. Use --wakeup first."
    return 1
  fi

  log "Connecting with MCP port forwarding (18850-18852)..."
  exec ssh -L 18850:127.0.0.1:18850 -L 18851:127.0.0.1:18851 -L 18852:127.0.0.1:18852 "${SSH_HOST}"
}

cmd_history() {
  local days="${1:-7}"

  # Compute time range (python3 for cross-platform date math)
  local start_time end_time
  end_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  start_time=$(python3 -c "from datetime import datetime,timedelta,timezone; print((datetime.now(timezone.utc)-timedelta(days=${days})).strftime('%Y-%m-%dT00:00:00Z'))")

  # Read timezone from deploy-state.json
  local tz_name="UTC"
  if [[ -f "${STATE_FILE}" ]]; then
    tz_name=$(python3 -c "import json; print(json.load(open('${STATE_FILE}')).get('timezone','UTC'))" 2>/dev/null || echo "UTC")
  fi

  log "Fetching instance activity for the last ${days} days (${tz_name})..."

  # Get CloudWatch CPUUtilization (hourly) — data point exists = instance was awake
  local cw_file
  cw_file=$(mktemp)
  aws cloudwatch get-metric-statistics \
    --namespace AWS/EC2 \
    --metric-name CPUUtilization \
    --dimensions "Name=InstanceId,Value=${INSTANCE_ID}" \
    --start-time "${start_time}" \
    --end-time "${end_time}" \
    --period 3600 \
    --statistics Maximum \
    --region "${REGION}" \
    --output json > "${cw_file}" 2>/dev/null || echo '{"Datapoints":[]}' > "${cw_file}"

  # Get orchestrator run timestamps from server (if running)
  local run_file events_file
  run_file=$(mktemp)
  events_file=$(mktemp)
  local state
  state=$(get_instance_state)
  if [[ "${state}" == "running" ]]; then
    ssh -o ConnectTimeout=5 "${SSH_HOST}" \
      "ls -1 ~/logs/orchestrator-*.log 2>/dev/null | sed 's/.*orchestrator-//' | sed 's/\.log//' | tail -500" \
      > "${run_file}" 2>/dev/null || true

    # For single-day view, get detailed event timestamps from logs
    if [[ "${days}" -eq 1 ]]; then
      local today_str
      today_str=$(date +%Y%m%d)
      ssh -o ConnectTimeout=10 "${SSH_HOST}" "
        for f in ~/logs/orchestrator-${today_str}*.log; do
          [ -f \"\$f\" ] || continue
          ts=\$(basename \"\$f\" .log | sed 's/orchestrator-//')
          echo \"START:\${ts}\"
          # File modification time as proxy for end/hibernate time
          echo \"ENDTIME:\$(stat -c '%Y' \"\$f\" 2>/dev/null || stat -f '%m' \"\$f\" 2>/dev/null)\"
          # Get the 'Claude Code finished' line with exit code
          grep -m1 'Claude Code finished' \"\$f\" 2>/dev/null && true
          # Check for hibernate/stop events
          grep -m1 'hibernating instance\|Falling back to shutdown\|Outside active hours' \"\$f\" 2>/dev/null && true
        done
      " > "${events_file}" 2>/dev/null || true
    fi
  fi

  # Render timeline with python3
  python3 - "${days}" "${cw_file}" "${run_file}" "${tz_name}" "${events_file}" << 'PYEOF'
import json, sys, re
from datetime import datetime, timedelta, timezone

days = int(sys.argv[1])
with open(sys.argv[2]) as f:
    cw_raw = json.load(f)
with open(sys.argv[3]) as f:
    run_raw = f.read().strip()
tz_name = sys.argv[4]
events_file = sys.argv[5] if len(sys.argv) > 5 else ""

# Set up timezone
try:
    from zoneinfo import ZoneInfo
    local_tz = ZoneInfo(tz_name)
except (ImportError, KeyError):
    local_tz = timezone.utc

# Compute displayed date range
now = datetime.now(local_tz)
display_dates = set()
for d in range(days):
    day = now - timedelta(days=d)
    display_dates.add(day.strftime("%Y-%m-%d"))

# Parse CloudWatch → set of (date_str, hour) in local time
awake = set()
for dp in cw_raw.get("Datapoints", []):
    ts = dp["Timestamp"]
    for fmt in ("%Y-%m-%dT%H:%M:%S+00:00", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            dt = datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
            break
        except ValueError:
            continue
    else:
        continue
    local_dt = dt.astimezone(local_tz)
    ds = local_dt.strftime("%Y-%m-%d")
    if ds in display_dates:
        awake.add((ds, local_dt.hour))

# Parse orchestrator log filenames → set of (date_str, hour) + count per day
runs = set()
from collections import Counter
runs_per_day = Counter()
for line in run_raw.split("\n"):
    line = line.strip()
    if len(line) >= 15:
        try:
            dt = datetime.strptime(line[:15], "%Y%m%d-%H%M%S")
            ds = dt.strftime("%Y-%m-%d")
            if ds in display_dates:
                runs.add((ds, dt.hour))
                runs_per_day[ds] += 1
        except ValueError:
            pass

# Merge: hours with runs are also awake
awake |= runs

# Colors
G = "\033[0;32m"; Y = "\033[1;33m"; D = "\033[2m"; B = "\033[1m"
C = "\033[0;36m"; NC = "\033[0m"

# --- Render bar chart -------------------------------------------------------
print()
print(f"  {B}Agent History — last {days} day(s){NC}")
print(f"  {'─' * 56}")

for d in range(days - 1, -1, -1):
    day = now - timedelta(days=d)
    ds = day.strftime("%Y-%m-%d")
    label = day.strftime("%b %d")

    bar = ""
    for h in range(24):
        k = (ds, h)
        if k in runs:
            bar += f"{G}██{NC}"
        elif k in awake:
            bar += f"{Y}░░{NC}"
        else:
            bar += f"{D}··{NC}"
    rc = runs_per_day.get(ds, 0)
    suffix = f"  {D}{rc} run{'s' if rc != 1 else ''}{NC}" if rc > 0 else ""
    print(f"  {label}  {bar}{suffix}")

# Hour axis
axis = ""
for h in range(0, 24, 3):
    label = str(h)
    axis += label + " " * (6 - len(label))
print(f"  {'':8}{axis}")

print()
print(f"  {G}██{NC} agent ran   {Y}░░{NC} awake (idle)   {D}··{NC} stopped")

total_active_hours = len(awake)
total_run_hours = len(runs)
total_runs = sum(runs_per_day.values())
print()
print(f"  Hours with wake-ups: {total_active_hours}  |  Total runs: {total_runs}")
if total_active_hours > 0 and total_active_hours != total_run_hours:
    idle_hours = total_active_hours - total_run_hours
    print(f"  Hours idle (awake, no run): {idle_hours}")

# --- Detailed event timeline (single-day only) ------------------------------
if days == 1 and events_file:
    try:
        with open(events_file) as f:
            raw = f.read().strip()
    except (FileNotFoundError, IOError):
        raw = ""

    if raw:
        events = []  # list of (HH:MM, symbol, description)
        current_start = None
        end_hm = None  # from ENDTIME (file mtime)

        for line in raw.split("\n"):
            line = line.strip()
            if line.startswith("START:"):
                ts_str = line[6:]
                try:
                    dt = datetime.strptime(ts_str[:15], "%Y%m%d-%H%M%S")
                    hm = dt.strftime("%H:%M")
                    # If this is the first event or previous run ended, infer wake
                    if not events or events[-1][1] == "▼":
                        events.append((hm, "▲", "instance woke up"))
                    current_start = hm
                    end_hm = None
                    events.append((hm, "▶", "orchestrator started"))
                except ValueError:
                    pass
            elif line.startswith("ENDTIME:"):
                try:
                    epoch = int(line[8:])
                    dt = datetime.fromtimestamp(epoch, tz=local_tz)
                    end_hm = dt.strftime("%H:%M")
                except (ValueError, OSError):
                    end_hm = None
            elif "Claude Code finished" in line:
                m = re.search(r"exit code: (\d+)", line)
                code = m.group(1) if m else "?"
                hm = end_hm or current_start or "??:??"
                events.append((hm, "■", f"agent finished (exit {code})"))
            elif "hibernating instance" in line or "Falling back to shutdown" in line:
                hm = end_hm or "??:??"
                events.append((hm, "▼", "instance hibernated"))
            elif "Outside active hours" in line:
                hm = end_hm or "??:??"
                events.append((hm, "▼", "stopped (outside active hours)"))

        if events:
            print()
            print(f"  {B}Events{NC}")
            print(f"  {'─' * 40}")
            for hm, sym, desc in events:
                if sym == "▲":
                    color = Y
                elif sym == "▶" or sym == "■":
                    color = G
                else:
                    color = D
                print(f"  {color}{hm}  {sym}{NC}  {desc}")
            print()
    elif not raw:
        print()
        print(f"  {D}(no detailed log data — server may be stopped){NC}")
        print()

print()
PYEOF

  rm -f "${cw_file}" "${run_file}"
}

cmd_help() {
  echo ""
  echo -e "${BOLD}agent-manager${NC} — Manage your agent server"
  echo ""
  echo "Commands:"
  echo -e "  ${CYAN}./agent-manager.sh${NC}              Show server status (default)"
  echo -e "  ${CYAN}./agent-manager.sh --wakeup${NC}     Start a stopped instance, wait for SSH"
  echo -e "  ${CYAN}./agent-manager.sh --sleep${NC}      Stop a running instance"
  echo -e "  ${CYAN}./agent-manager.sh --always-on${NC}  Switch to always-on mode (remove scheduler)"
  echo -e "  ${CYAN}./agent-manager.sh --scheduled${NC}  Switch to scheduled mode (default: every 60 min)"
  echo -e "  ${CYAN}./agent-manager.sh --scheduled 30${NC} Scheduled mode, every 30 min"
  echo -e "  ${CYAN}./agent-manager.sh --scheduled 60 8-20${NC}  Scheduled, every 60 min, 8am-8pm"
  echo -e "  ${CYAN}./agent-manager.sh --run-agent${NC}  Trigger an agent run (fire and forget)"
  echo -e "  ${CYAN}./agent-manager.sh --history${NC}   Show wake/sleep/run timeline (last 7 days)"
  echo -e "  ${CYAN}./agent-manager.sh --history 14${NC} Timeline for the last 14 days"
  echo -e "  ${CYAN}./agent-manager.sh --ssh${NC}        SSH into the server"
  echo -e "  ${CYAN}./agent-manager.sh --ssh-mcp${NC}    SSH with MCP port forwarding (for auth)"
  echo -e "  ${CYAN}./agent-manager.sh --help${NC}       Show this help"
  echo ""
}

# --- Main dispatch -----------------------------------------------------------
load_state

case "${1:---status}" in
  --status|status)     cmd_status ;;
  --wakeup|wakeup)     cmd_wakeup ;;
  --sleep|sleep)       cmd_sleep ;;
  --always-on|always-on)     cmd_always_on ;;
  --scheduled|scheduled)     cmd_scheduled "${2:-60}" "${3:-}" ;;
  --run-agent|run-agent)     cmd_run_agent ;;
  --history|history)         cmd_history "${2:-7}" ;;
  --ssh|ssh)           cmd_ssh ;;
  --ssh-mcp|ssh-mcp)   cmd_ssh_mcp ;;
  --help|-h|help)      cmd_help ;;
  *)
    err "Unknown command: $1"
    cmd_help
    exit 1 ;;
esac
