#!/usr/bin/env bash
# =============================================================================
# Agent Orchestrator — Main startup script for the agent server
# =============================================================================
# This script runs at boot (scheduled mode) or manually (always-on mode).
# It orchestrates the full agent cycle:
#   1. Wait for Dropbox sync (if configured)
#   2. Run Claude Code with the master prompt that handles all task sources
#   3. Write logs
#   4. Self-stop if in scheduled mode
#
# Usage:
#   ~/scripts/agent-orchestrator.sh              # full run
#   ~/scripts/agent-orchestrator.sh --no-stop    # skip self-stop (for testing)
#
# The actual task logic (reading default-tasks, inbox, ActingWeb) lives in
# the Claude prompt — not in bash. This script just bootstraps the environment
# and hands control to Claude Code.
# =============================================================================

set -uo pipefail

# --- Configuration -----------------------------------------------------------
HOME_DIR="${HOME:-/home/ubuntu}"
SCRIPTS_DIR="${HOME_DIR}/scripts"
LOG_DIR="${HOME_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
RUN_LOG="${LOG_DIR}/agent-run-${TIMESTAMP}.md"
ORCHESTRATOR_LOG="${LOG_DIR}/orchestrator-${TIMESTAMP}.log"
NO_STOP="${1:-}"

# --- Setup -------------------------------------------------------------------
mkdir -p "${LOG_DIR}"

exec > >(tee -a "${ORCHESTRATOR_LOG}") 2>&1

echo "=== Agent Orchestrator started at $(date) ==="

# Load environment
source "${HOME_DIR}/.agent-env" 2>/dev/null || true
source "${HOME_DIR}/.agent-schedule" 2>/dev/null || true
export PATH="${HOME_DIR}/.local/bin:${HOME_DIR}/.cargo/bin:/usr/local/bin:$PATH"

# Load agent.conf (installed during setup)
AGENT_CONF="${HOME_DIR}/.agent-server.conf"
if [[ -f "${AGENT_CONF}" ]]; then
  source "${AGENT_CONF}"
else
  echo "WARNING: ${AGENT_CONF} not found. Using defaults."
fi

# Derive paths from config
OWNER_NAME="${OWNER_NAME:-Agent}"
BRAIN_FOLDER="${BRAIN_FOLDER:-brain}"
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
FILE_SYNC="${FILE_SYNC:-dropbox}"

if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  BRAIN_DIR="${HOME_DIR}/Dropbox/${BRAIN_FOLDER}"
else
  BRAIN_DIR="${HOME_DIR}/brain"
fi
INBOX_DIR="${BRAIN_DIR}/${OUTPUT_FOLDER}/INBOX"

echo "Owner: ${OWNER_NAME}"
echo "Brain dir: ${BRAIN_DIR}"
echo "Inbox dir: ${INBOX_DIR}"
echo "Run log: ${RUN_LOG}"

# --- Pre-flight checks -------------------------------------------------------
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "ERROR: ANTHROPIC_API_KEY not set. Aborting."
  exit 1
fi

# Check for keep-running lock (in scheduled mode)
if [[ "${SCHEDULE_MODE:-always-on}" == "scheduled" && -f "${HOME_DIR}/agents/.keep-running" ]]; then
  echo "Lock file found (~/.keep-running). Skipping self-stop."
  NO_STOP="--no-stop"
fi

# --- 1. Wait for network ----------------------------------------------------
echo "Checking network..."
for i in $(seq 1 30); do
  if curl -s --max-time 3 https://api.anthropic.com > /dev/null 2>&1; then
    echo "Network ready."
    break
  fi
  echo "  Waiting for network... (attempt ${i})"
  sleep 2
done

# --- 2. Wait for Dropbox sync (if configured) --------------------------------
if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  echo "Waiting for Dropbox sync..."
  SYNC_TIMEOUT=180
  SYNC_START=$(date +%s)
  SEEN_UP_TO_DATE=false
  while true; do
    ELAPSED=$(( $(date +%s) - SYNC_START ))
    if [[ $ELAPSED -ge $SYNC_TIMEOUT ]]; then
      echo "WARNING: Dropbox sync timeout (${SYNC_TIMEOUT}s). Proceeding."
      break
    fi
    STATUS=$(dropbox-cli status 2>/dev/null || echo "not running")
    if [[ "$STATUS" == *"Up to date"* ]]; then
      if [[ "$SEEN_UP_TO_DATE" == true ]]; then
        echo "Dropbox synced (confirmed stable)."
        break
      else
        SEEN_UP_TO_DATE=true
        echo "  Dropbox reports up to date. Verifying stability..."
        sleep 15
        continue
      fi
    else
      SEEN_UP_TO_DATE=false
    fi
    echo "  Dropbox: ${STATUS} (${ELAPSED}s elapsed)"
    sleep 10
  done
else
  echo "File sync: none (local brain directory)."
fi

# --- 3. Ensure brain dir exists ----------------------------------------------
if [[ ! -d "${BRAIN_DIR}" ]]; then
  echo "ERROR: Brain directory not found at ${BRAIN_DIR}"
  exit 1
fi

# Ensure INBOX and _processed dirs exist
mkdir -p "${INBOX_DIR}/_processed" 2>/dev/null || true

# --- 4. Build the master prompt ---------------------------------------------
MASTER_PROMPT=$(cat << PROMPT_END
You are running as an autonomous agent on ${OWNER_NAME}'s server. This is an unattended scheduled run.

## Your Instructions

1. First, read the task execution instructions:
   - Read the file at: ai/instructions/tasks.md
   - Read the file at: ai/instructions/default-tasks.md
   - Read the file at: ai/instructions/personal.md (for context about the owner)

2. The orchestrator is capturing your output as the run log at: ${RUN_LOG}
   Structure your output as a markdown log. Start with: "# Agent Run — $(date '+%Y-%m-%d %H:%M')"
   Use the logging format defined in tasks.md for each task.

3. Execute the DEFAULT TASKS defined in default-tasks.md, in order.
   If an MCP connection is unavailable, log it as skipped and continue.

4. Scan the INBOX folder (at "${OUTPUT_FOLDER}/INBOX/") for .txt and .md files.
   Skip files starting with "_".
   For each task file found:
   - Read the file contents (this is the task prompt)
   - Execute the task following the patterns in tasks.md
   - Log the result
   - Move the file to "${OUTPUT_FOLDER}/INBOX/_processed/" with today's date prefix

5. Check ActingWeb for queued tasks using the work_on_task MCP tool (list_only=true first).
   For each ready task:
   - Execute it following the patterns in tasks.md
   - Mark it as done via work_on_task(mark_done=true, task_id=...)
   - Log the result

6. Write a final summary section:
   - Total tasks: X (completed: Y, failed: Z, deferred: W)
   - Notable items that need ${OWNER_NAME}'s attention
   - Next recommended actions

7. If any tasks were deferred or need attention, create a summary file at:
   "${OUTPUT_FOLDER}/INBOX/_agent-attention-needed-$(date +%Y%m%d).md"

IMPORTANT RULES:
- Never send emails or messages. Only draft.
- Never delete files. Move to _processed/ or _archive/.
- Fail gracefully — if one task fails, continue to the next.
- Each task should take under 5 minutes. Defer if too large.
- Be concise in logs. ${OWNER_NAME} will review them quickly.
PROMPT_END
)

# --- 5. Run Claude Code with the master prompt -------------------------------
echo ""
echo "=== Handing control to Claude Code ==="
echo "Working directory: ${BRAIN_DIR}"
echo ""

cd "${BRAIN_DIR}"

# Run Claude in non-interactive mode with the master prompt
# --max-turns prevents infinite loops in autonomous mode
claude -p "${MASTER_PROMPT}" \
  --output-format text \
  --max-turns 50 \
  2>&1 | tee "${RUN_LOG}"

CLAUDE_EXIT=$?
echo ""
echo "=== Claude Code finished (exit code: ${CLAUDE_EXIT}) ==="

# --- 6. Post-run: wait for Dropbox to sync output ---------------------------
if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  echo "Waiting for Dropbox to sync outputs..."
  sleep 30
  FINAL_STATUS=$(dropbox-cli status 2>/dev/null || echo "unknown")
  echo "Dropbox status: ${FINAL_STATUS}"
fi

# --- 7. Write heartbeat file (for monitoring) --------------------------------
HEARTBEAT_FILE="${BRAIN_DIR}/${OUTPUT_FOLDER}/.agent-heartbeat"
cat > "${HEARTBEAT_FILE}" << EOF
last_run=$(date -u +%Y-%m-%dT%H:%M:%SZ)
exit_code=${CLAUDE_EXIT}
log=${RUN_LOG}
EOF

# --- 8. Log cleanup (keep last 100 logs) ------------------------------------
LOG_COUNT=$(ls -1 "${LOG_DIR}"/agent-run-*.md 2>/dev/null | wc -l)
if [[ ${LOG_COUNT} -gt 100 ]]; then
  echo "Cleaning old logs (keeping last 100)..."
  ls -1t "${LOG_DIR}"/agent-run-*.md | tail -n +101 | xargs rm -f
  ls -1t "${LOG_DIR}"/orchestrator-*.log | tail -n +101 | xargs rm -f
fi

# --- 9. Self-stop (scheduled mode) ------------------------------------------
echo ""
echo "=== Orchestrator finished at $(date) ==="

if [[ "${SCHEDULE_MODE:-always-on}" == "scheduled" && "${NO_STOP}" != "--no-stop" ]]; then
  echo "Scheduled mode: shutting down instance in 10 seconds..."
  echo "(Cancel with: touch ~/agents/.keep-running)"
  sleep 10
  # Final check for lock file
  if [[ -f "${HOME_DIR}/agents/.keep-running" ]]; then
    echo "Lock file appeared. Cancelling shutdown."
  else
    sudo shutdown -h now
  fi
else
  echo "Always-on mode (or --no-stop). Instance stays running."
fi
