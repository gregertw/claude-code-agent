#!/usr/bin/env bash
# =============================================================================
# Agent Resume Check — run orchestrator on resume from hibernation
# =============================================================================
# Runs the orchestrator if the last run was more than SCHEDULE_INTERVAL ago.
#
# No active-hours guard here — EventBridge already constrains its schedule to
# active hours, so any wake outside those hours is intentional (remote trigger,
# --wakeup, --run-agent). The orchestrator is called with --force to bypass its
# own hours guard for the same reason.
# =============================================================================

set -uo pipefail
HOME_DIR="${HOME:-/home/ubuntu}"
source "${HOME_DIR}/.agent-server.conf" 2>/dev/null || true
# Source schedule AFTER agent.conf so SCHEDULE_* from set-schedule-mode.sh wins
source "${HOME_DIR}/.agent-schedule" 2>/dev/null || true
SCRIPTS_DIR="${HOME_DIR}/scripts"

# Heartbeat interval check — skip if last run was within 20% of interval.
# E.g. 60min interval → threshold 12min. Prevents duplicate runs from rapid
# re-triggers while still allowing remote triggers shortly after a run.
INTERVAL_SEC=$(( ${SCHEDULE_INTERVAL:-60} * 60 ))
THRESHOLD_SEC=$(( INTERVAL_SEC * 20 / 100 ))
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
HEARTBEAT="${HOME_DIR}/brain/${OUTPUT_FOLDER}/.agent-heartbeat"

if [[ -f "${HEARTBEAT}" ]]; then
  LAST_RUN=$(grep '^last_run=' "${HEARTBEAT}" | cut -d= -f2)
  if [[ -n "${LAST_RUN}" ]]; then
    LAST_EPOCH=$(date -d "${LAST_RUN}" +%s 2>/dev/null || echo 0)
    NOW_EPOCH=$(date +%s)
    AGE=$(( NOW_EPOCH - LAST_EPOCH ))
    if [[ ${AGE} -lt ${THRESHOLD_SEC} ]]; then
      echo "Resume check: last run was ${AGE}s ago (< ${THRESHOLD_SEC}s threshold). Skipping."
      # Don't hibernate here — the instance may have been woken by --wakeup
      # (which sets .keep-running after SSH is ready, i.e. after this script runs).
      # The next cron run or --sleep will handle cleanup.
      exit 0
    fi
    echo "Resume check: last run was ${AGE}s ago (>= ${THRESHOLD_SEC}s threshold). Running orchestrator."
  fi
else
  echo "Resume check: no heartbeat file found. Running orchestrator."
fi
exec "${SCRIPTS_DIR}/agent-orchestrator.sh" --force
