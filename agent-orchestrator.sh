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
INBOX_DIR="${BRAIN_DIR}/INBOX"

echo "Owner: ${OWNER_NAME}"
echo "Brain dir: ${BRAIN_DIR}"
echo "Inbox dir: ${INBOX_DIR}"
echo "Run log: ${RUN_LOG}"

# --- Pre-flight checks -------------------------------------------------------
# Claude Code can authenticate via API key OR account login (Pro/Max/Enterprise).
# Check that at least one method is available.
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  # No API key — check if Claude Code has stored credentials (account login)
  CRED_FILE="${HOME_DIR}/.claude/.credentials.json"
  if [[ -f "${CRED_FILE}" ]] && python3 -c "import json; d=json.load(open('${CRED_FILE}')); assert d.get('claudeAiOauth',{}).get('accessToken')" 2>/dev/null; then
    echo "Using account login (no API key)."
  else
    echo "ERROR: No authentication found. Set ANTHROPIC_API_KEY or log in via 'claude' first."
    exit 1
  fi
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

  # Ensure Maestral daemon is running and not paused
  MAESTRAL_FULL=$(maestral status 2>/dev/null || echo "")
  if [[ -z "${MAESTRAL_FULL}" ]]; then
    echo "  Maestral not running, starting..."
    maestral start 2>/dev/null || true
    sleep 3
  fi
  if maestral status 2>/dev/null | grep -qi "paused"; then
    echo "  Maestral paused, resuming..."
    maestral resume 2>/dev/null || true
    sleep 2
  fi

  SYNC_TIMEOUT=180
  SYNC_START=$(date +%s)
  SEEN_UP_TO_DATE=false
  while true; do
    ELAPSED=$(( $(date +%s) - SYNC_START ))
    if [[ $ELAPSED -ge $SYNC_TIMEOUT ]]; then
      echo "WARNING: Dropbox sync timeout (${SYNC_TIMEOUT}s). Proceeding."
      break
    fi
    # Extract just the Status field value
    SYNC_STATUS=$(maestral status 2>/dev/null | grep -i "^Status" | awk '{$1=""; print $0}' | xargs || echo "not running")
    if [[ "${SYNC_STATUS}" == *"Up to date"* ]]; then
      if [[ "$SEEN_UP_TO_DATE" == true ]]; then
        echo "Dropbox synced (confirmed stable)."
        break
      else
        SEEN_UP_TO_DATE=true
        echo "  Dropbox up to date — verifying stability..."
        sleep 15
        continue
      fi
    else
      SEEN_UP_TO_DATE=false
    fi
    echo "  Dropbox: ${SYNC_STATUS} (${ELAPSED}s elapsed)"
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
RUN_DATE=$(date '+%Y-%m-%d %H:%M')
RUN_DATE_SHORT=$(date +%Y%m%d)

read -r -d '' MASTER_PROMPT << PROMPT_END || true
You are running as an autonomous agent on ${OWNER_NAME}'s server. This is an unattended scheduled run.

## Your Instructions

1. First, read the task execution instructions:
   - Read the file at: ai/instructions/tasks.md
   - Read the file at: ai/instructions/default-tasks.md
   - Read the file at: ai/instructions/personal.md (for context about the owner)

2. The orchestrator is capturing your output as the run log at: ${RUN_LOG}
   Structure your output as a markdown log. Start with: "# Agent Run — ${RUN_DATE}"
   Use the logging format defined in tasks.md for each task.

3. Execute the DEFAULT TASKS defined in default-tasks.md, in order.
   If an MCP connection is unavailable, log it as skipped and continue.

4. Scan the INBOX folder (at "INBOX/") for .txt and .md files.
   Skip files starting with "_".
   For each task file found:
   - Read the file contents (this is the task prompt)
   - Execute the task following the patterns in tasks.md
   - Write the result to "${OUTPUT_FOLDER}/tasks/"
   - Log the result
   - Move the file to "INBOX/_processed/" with today's date prefix

5. Check ActingWeb for queued tasks using the work_on_task MCP tool (list_only=true first).
   For each ready task:
   - Execute it following the patterns in tasks.md
   - Write the result to "${OUTPUT_FOLDER}/tasks/"
   - Mark it as done via work_on_task(mark_done=true, task_id=...)
   - Log the result

6. Write a final summary section:
   - Total tasks: X (completed: Y, failed: Z, deferred: W)
   - Notable items that need ${OWNER_NAME}'s attention
   - Next recommended actions

7. If any tasks were deferred or need attention, create a summary file at:
   "INBOX/_agent-attention-needed-${RUN_DATE_SHORT}.md"

IMPORTANT RULES:
- Never send emails or messages. Only draft.
- Never delete files. Move to _processed/ or _archive/.
- Fail gracefully — if one task fails, continue to the next.
- Each task should take under 5 minutes. Defer if too large.
- Be concise in logs. ${OWNER_NAME} will review them quickly.
PROMPT_END

# --- 5. Run Claude Code with the master prompt -------------------------------
echo ""
echo "=== Handing control to Claude Code ==="
echo "Working directory: ${BRAIN_DIR}"
echo ""

cd "${BRAIN_DIR}"

# Build allowed tools list — explicit CLI flags are more reliable than
# settings.json alone in non-interactive mode (see GitHub issue #581)
ALLOWED_TOOLS=()

# Core tools for file operations
ALLOWED_TOOLS+=("Read" "Write" "Edit" "Glob" "Grep" "WebSearch" "WebFetch")
ALLOWED_TOOLS+=("Bash(cat *)" "Bash(mkdir *)" "Bash(mv *)" "Bash(ls *)" "Bash(date *)")
if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  ALLOWED_TOOLS+=("Bash(maestral *)")
fi

# MCP tools from Claude Code's config
CLAUDE_CONFIG="${HOME_DIR}/.claude.json"
if [[ -f "${CLAUDE_CONFIG}" ]]; then
  while IFS= read -r server; do
    [[ -n "$server" ]] && ALLOWED_TOOLS+=("mcp__${server}")
  done < <(python3 -c "
import json
with open('${CLAUDE_CONFIG}') as f:
    d = json.load(f)
for name in d.get('mcpServers', {}):
    print(name)
" 2>/dev/null || true)
fi

# Run Claude in non-interactive mode with the master prompt
# --max-turns prevents infinite loops in autonomous mode
claude -p "${MASTER_PROMPT}" \
  --output-format text \
  --max-turns 50 \
  --allowedTools "${ALLOWED_TOOLS[@]}" \
  2>&1 | tee "${RUN_LOG}"

CLAUDE_EXIT=$?
echo ""
echo "=== Claude Code finished (exit code: ${CLAUDE_EXIT}) ==="

# --- 6. Post-run: wait for Dropbox to sync output ---------------------------
if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  echo "Waiting for Dropbox to sync outputs..."
  sleep 30
  FINAL_STATUS=$(maestral status 2>/dev/null | grep -i "^Status" | awk '{$1=""; print $0}' | xargs || echo "unknown")
  echo "Dropbox status: ${FINAL_STATUS}"
fi

# --- 7. Copy run log to brain output/logs/ -----------------------------------
BRAIN_LOG_DIR="${BRAIN_DIR}/${OUTPUT_FOLDER}/logs"
mkdir -p "${BRAIN_LOG_DIR}"
cp "${RUN_LOG}" "${BRAIN_LOG_DIR}/" 2>/dev/null || true

# --- 8. Write heartbeat file (for monitoring) ---------------------------------
HEARTBEAT_FILE="${BRAIN_DIR}/${OUTPUT_FOLDER}/.agent-heartbeat"
cat > "${HEARTBEAT_FILE}" << EOF
last_run=$(date -u +%Y-%m-%dT%H:%M:%SZ)
exit_code=${CLAUDE_EXIT}
log=${RUN_LOG}
EOF

# --- 9. Log cleanup (keep last 100 logs) ------------------------------------
LOG_COUNT=$(ls -1 "${LOG_DIR}"/agent-run-*.md 2>/dev/null | wc -l)
if [[ ${LOG_COUNT} -gt 100 ]]; then
  echo "Cleaning old logs (keeping last 100)..."
  ls -1t "${LOG_DIR}"/agent-run-*.md | tail -n +101 | xargs rm -f
  ls -1t "${LOG_DIR}"/orchestrator-*.log | tail -n +101 | xargs rm -f
fi

# --- 10. Print status summary (paste-friendly for AI) -----------------------
echo ""
echo "============================================================"
echo "AGENT RUN COMPLETE"
echo "============================================================"
echo ""
echo "Finished: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Exit code: ${CLAUDE_EXIT}"
echo "Run log: $(basename "${RUN_LOG}")"
echo "Mode: ${SCHEDULE_MODE:-always-on}"

# Count inbox files (remaining)
INBOX_REMAINING=0
if [[ -d "${INBOX_DIR}" ]]; then
  INBOX_REMAINING=$(find "${INBOX_DIR}" -maxdepth 1 \( -name '*.txt' -o -name '*.md' \) ! -name '_*' 2>/dev/null | wc -l | tr -d ' ')
fi
echo "Inbox remaining: ${INBOX_REMAINING}"

if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  echo "Dropbox: ${FINAL_STATUS:-not checked}"
fi

if [[ ${CLAUDE_EXIT} -ne 0 ]]; then
  echo ""
  echo "WARNING: Claude Code exited with error code ${CLAUDE_EXIT}."
  echo "Check the run log: agent log"
fi

echo ""
echo "============================================================"

# --- 11. Self-stop (scheduled mode) -----------------------------------------
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
