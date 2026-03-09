#!/usr/bin/env bash
# =============================================================================
# agent-manager — Manage your agent server from your LOCAL machine
# =============================================================================
# Usage:
#   ./agent-manager.sh                 Show server status (default)
#   ./agent-manager.sh --wakeup        Start a stopped instance, wait for SSH
#   ./agent-manager.sh --sleep         Stop a running instance
#   ./agent-manager.sh --always-on     Switch to always-on mode (remove scheduler)
#   ./agent-manager.sh --scheduled [N] Switch to scheduled mode (every N min, default 60)
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

  # Load agent.conf for schedule info
  if [[ -f "${SCRIPT_DIR}/agent.conf" ]]; then
    source "${SCRIPT_DIR}/agent.conf"
    local mode="${SCHEDULE_MODE:-unknown}"
    if [[ "$mode" == "scheduled" ]]; then
      echo -e "  Mode:       ${CYAN}scheduled${NC} (every ${SCHEDULE_INTERVAL:-60} min)"
    else
      echo -e "  Mode:       ${CYAN}${mode}${NC}"
    fi
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
  echo -e "  ${DIM}Commands: --wakeup, --sleep, --always-on, --scheduled, --ssh, --ssh-mcp${NC}"
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

  log "Stopping instance ${INSTANCE_ID}..."
  aws ec2 stop-instances --instance-ids "${INSTANCE_ID}" --region "${REGION}" >/dev/null
  log "Stop command sent. Instance will shut down shortly."
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
  local state
  state=$(get_instance_state)

  # Switch mode on the server
  if [[ "${state}" == "running" ]]; then
    log "Setting server to scheduled mode..."
    ssh -o ConnectTimeout=5 "${SSH_HOST}" "sudo ~/scripts/set-schedule-mode.sh scheduled" 2>/dev/null || true
  else
    warn "Instance is ${state}. Mode will be set on next boot."
  fi

  # Deploy EventBridge scheduler
  log "Deploying EventBridge scheduler (every ${interval} min)..."
  if [[ -f "${SCRIPT_DIR}/deploy-scheduler.sh" ]]; then
    bash "${SCRIPT_DIR}/deploy-scheduler.sh" "${INSTANCE_ID}" "${interval}" "${REGION}"
  else
    err "deploy-scheduler.sh not found."
    return 1
  fi

  # Update local agent.conf
  if [[ -f "${SCRIPT_DIR}/agent.conf" ]]; then
    sed -i.bak 's/^SCHEDULE_MODE=.*/SCHEDULE_MODE="scheduled"/' "${SCRIPT_DIR}/agent.conf"
    sed -i.bak "s/^SCHEDULE_INTERVAL=.*/SCHEDULE_INTERVAL=${interval}/" "${SCRIPT_DIR}/agent.conf"
    rm -f "${SCRIPT_DIR}/agent.conf.bak"
    log "Updated agent.conf: SCHEDULE_MODE=\"scheduled\", SCHEDULE_INTERVAL=${interval}"
  fi

  echo ""
  log "Mode switched to scheduled. Instance will wake every ${interval} min, run tasks, then stop."
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
  --scheduled|scheduled)     cmd_scheduled "${2:-60}" ;;
  --ssh|ssh)           cmd_ssh ;;
  --ssh-mcp|ssh-mcp)   cmd_ssh_mcp ;;
  --help|-h|help)      cmd_help ;;
  *)
    err "Unknown command: $1"
    cmd_help
    exit 1 ;;
esac
