#!/usr/bin/env bash
# =============================================================================
# Agent Resume Check — run orchestrator on resume from hibernation
# =============================================================================
# Only runs if the last run was more than SCHEDULE_INTERVAL ago and we're
# within active hours.
# =============================================================================

set -uo pipefail
HOME_DIR="${HOME:-/home/ubuntu}"
source "${HOME_DIR}/.agent-server.conf" 2>/dev/null || true
# Source schedule AFTER agent.conf so SCHEDULE_* from set-schedule-mode.sh wins
source "${HOME_DIR}/.agent-schedule" 2>/dev/null || true
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

# Heartbeat interval check — use 80% of interval to account for boot time
# and the fact that the heartbeat records completion time, not start time.
# E.g. 60min interval → threshold 48min, so a run completing at :01 won't
# block the next wake at :00 of the following hour.
INTERVAL_SEC=$(( ${SCHEDULE_INTERVAL:-60} * 60 ))
THRESHOLD_SEC=$(( INTERVAL_SEC * 80 / 100 ))
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
      exit 0
    fi
    echo "Resume check: last run was ${AGE}s ago (>= ${THRESHOLD_SEC}s threshold). Running orchestrator."
  fi
else
  echo "Resume check: no heartbeat file found. Running orchestrator."
fi
exec "${SCRIPTS_DIR}/agent-orchestrator.sh"
