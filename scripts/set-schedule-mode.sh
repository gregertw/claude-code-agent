#!/usr/bin/env bash
# =============================================================================
# Toggle between always-on and scheduled mode.
# Usage: set-schedule-mode.sh <always-on|scheduled> [interval] [hours]
# =============================================================================

set -euo pipefail

# Detect home directory — handle sudo (where HOME=/root) by checking SUDO_USER
if [[ -n "${SUDO_USER:-}" ]]; then
  HOME_DIR=$(getent passwd "${SUDO_USER}" | cut -d: -f6)
else
  HOME_DIR="${HOME:-/home/ubuntu}"
fi

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
CRON_USER="${SUDO_USER:-$(whoami)}"

# Update orchestrator cron
sudo tee /etc/cron.d/agent-orchestrator > /dev/null << CRON
# Run agent orchestrator every ${CRON_INTERVAL} minutes during active hours
# flock in the orchestrator prevents concurrent runs
*/${CRON_INTERVAL} ${CRON_HOURS} * * * ${CRON_USER} ${HOME_DIR}/scripts/agent-orchestrator.sh >> ${HOME_DIR}/logs/cron-orchestrator.log 2>&1
CRON
sudo chmod 644 /etc/cron.d/agent-orchestrator

# Enable/disable systemd services and report
if [[ "$MODE" == "scheduled" ]]; then
  systemctl enable agent-boot-runner.service
  systemctl enable agent-resume-runner.service
  # Scheduled mode: orchestrator manages Maestral lifecycle per-run.
  # Disable the persistent service to avoid stale daemon after hibernation.
  if systemctl --user is-enabled maestral.service &>/dev/null 2>&1; then
    su - "${CRON_USER}" -c "systemctl --user stop maestral.service 2>/dev/null; systemctl --user disable maestral.service 2>/dev/null" || true
  fi
  echo "Switched to SCHEDULED mode."
  echo ""
  echo "  Server-side (updated now):"
  echo "    Cron: every ${CRON_INTERVAL} min during hours ${CRON_HOURS}"
  echo "    Boot runner: enabled"
  echo "    Resume runner: enabled"
  echo "    Maestral: per-run (orchestrator starts/stops)"
  echo "    Active guard: self-stops if woken outside hours ${CRON_HOURS}"
  echo "    Self-stop: enabled after each run"
  echo ""
  echo "  Client-side (run from local machine):"
  echo "    Run ./agent-manager.sh --scheduled to update EventBridge."
  echo "    To prevent self-stop during SSH: touch ~/agents/.keep-running"
else
  systemctl disable agent-boot-runner.service
  systemctl disable agent-resume-runner.service
  # Always-on mode: enable persistent Maestral service for continuous sync.
  if systemctl --user cat maestral.service &>/dev/null 2>&1; then
    su - "${CRON_USER}" -c "systemctl --user enable maestral.service 2>/dev/null; systemctl --user start maestral.service 2>/dev/null" || true
  fi
  echo "Switched to ALWAYS-ON mode (every ${CRON_INTERVAL} min)."
  echo "  Boot runner: disabled"
  echo "  Resume runner: disabled"
  echo "  Maestral: continuous (systemd service)"
  echo "  Cron: every ${CRON_INTERVAL} min"
  echo "  Self-stop: disabled"
fi

echo ""
cat "${HOME_DIR}/.agent-schedule"
