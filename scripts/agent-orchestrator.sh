#!/usr/bin/env bash
# =============================================================================
# Agent Orchestrator — Main startup script for the agent server
# =============================================================================
# This script runs at boot (scheduled mode) or manually (always-on mode).
# It orchestrates the full agent cycle:
#   1. Wait for network
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
ORCH_LOG_DIR="${HOME_DIR}/logs"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ORCHESTRATOR_LOG="${ORCH_LOG_DIR}/orchestrator-${TIMESTAMP}.log"
NO_STOP="${1:-}"
LOCK_FILE="${HOME_DIR}/.agent-orchestrator.lock"

# --- Source shared functions --------------------------------------------------
# Contains do_hibernate() and check_active_hours().
if [[ -f "${SCRIPTS_DIR}/agent-functions.sh" ]]; then
  source "${SCRIPTS_DIR}/agent-functions.sh"
fi

# --- Lock: prevent concurrent runs ------------------------------------------
# Use a lock file with flock to ensure only one orchestrator runs at a time.
# If another instance is already running, exit silently (cron will retry next interval).
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  echo "Another orchestrator is already running. Exiting."
  exit 0
fi
# Lock is held for the lifetime of this process (fd 9 stays open).

# --- Setup -------------------------------------------------------------------
mkdir -p "${ORCH_LOG_DIR}"

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

# --- Active-hours guard (scheduled mode only) --------------------------------
# If running in scheduled mode outside active hours, skip the run and self-stop.
# This prevents the server from staying awake if woken by a stale schedule,
# manual start, or hibernation resume outside active hours.
if [[ "${SCHEDULE_MODE:-always-on}" == "scheduled" && "${NO_STOP}" != "--no-stop" ]]; then
  if ! check_active_hours "${SCHEDULE_HOURS:-6-22}"; then
    echo "Outside active hours (${SCHEDULE_HOURS:-6-22}, current: $(date +%-H)). Skipping run."
    do_hibernate "Outside active hours"
    exit 0
  fi
  echo "Active hours check: OK (${SCHEDULE_HOURS:-6-22}, current: $(date +%-H))"
fi

# Derive paths from config
OWNER_NAME="${OWNER_NAME:-Agent}"
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
BRAIN_DIR="${HOME_DIR}/brain"
INBOX_DIR="${BRAIN_DIR}/INBOX"
LOG_DIR="${BRAIN_DIR}/${OUTPUT_FOLDER}/logs"
RUN_LOG="${LOG_DIR}/agent-run-${TIMESTAMP}.md"

mkdir -p "${LOG_DIR}"

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

# --- 2. Ensure brain dir exists ----------------------------------------------
if [[ ! -d "${BRAIN_DIR}" ]]; then
  echo "ERROR: Brain directory not found at ${BRAIN_DIR}"
  exit 1
fi

# Ensure INBOX and _processed dirs exist
mkdir -p "${INBOX_DIR}/_processed" 2>/dev/null || true

# --- 3. MCP warm-up ----------------------------------------------------------
# Fire a quick Claude call that touches MCP servers to wake up connections.
# Runs in the background so it doesn't block startup — the main run benefits
# from connections already being initialized.
CLAUDE_CONFIG="${HOME_DIR}/.claude.json"
MCP_SERVERS=()

if [[ -f "${CLAUDE_CONFIG}" ]]; then
  while IFS= read -r server; do
    [[ -n "$server" ]] && MCP_SERVERS+=("${server}")
  done < <(python3 -c "
import json
with open('${CLAUDE_CONFIG}') as f:
    d = json.load(f)
seen = set()
for name in d.get('mcpServers', {}):
    print(name)
    seen.add(name.lower())
for name in d.get('claudeAiMcpEverConnected', []):
    sanitized = name.replace('.', '_').replace(' ', '_')
    if sanitized.lower() not in seen:
        print(sanitized)
" 2>/dev/null || true)
fi

if [[ ${#MCP_SERVERS[@]} -gt 0 ]]; then
  echo "Warming up ${#MCP_SERVERS[@]} MCP server(s) in background: ${MCP_SERVERS[*]}"
  WARMUP_TOOLS=()
  for server in "${MCP_SERVERS[@]}"; do
    WARMUP_TOOLS+=("mcp__${server}")
  done
  (
    cd "${BRAIN_DIR}" && timeout --kill-after=5 30 claude -p \
      "Call one tool from each available MCP server to warm up connections. Be quick, just confirm each works." \
      --max-turns 5 \
      --allowedTools "${WARMUP_TOOLS[@]}" \
      --output-format text >/dev/null 2>&1
  ) &
  WARMUP_PID=$!
  disown ${WARMUP_PID}
  echo "  Warm-up running (pid ${WARMUP_PID}), waiting 10s for connections..."
  sleep 10
else
  echo "No MCP servers configured."
fi
echo ""

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

# MCP tools — all configured servers
for server in "${MCP_SERVERS[@]}"; do
  ALLOWED_TOOLS+=("mcp__${server}")
done

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

# --- 6. Write heartbeat file (for monitoring) ---------------------------------
HEARTBEAT_FILE="${BRAIN_DIR}/${OUTPUT_FOLDER}/.agent-heartbeat"
cat > "${HEARTBEAT_FILE}" << EOF
last_run=$(date -u +%Y-%m-%dT%H:%M:%SZ)
exit_code=${CLAUDE_EXIT}
log=${RUN_LOG}
EOF

# --- 7. Log cleanup (keep last 100 logs) ------------------------------------
LOG_COUNT=$(ls -1 "${LOG_DIR}"/agent-run-*.md 2>/dev/null | wc -l)
if [[ ${LOG_COUNT} -gt 100 ]]; then
  echo "Cleaning old run logs (keeping last 100)..."
  ls -1t "${LOG_DIR}"/agent-run-*.md | tail -n +101 | xargs rm -f
fi
ORCH_LOG_COUNT=$(ls -1 "${ORCH_LOG_DIR}"/orchestrator-*.log 2>/dev/null | wc -l)
if [[ ${ORCH_LOG_COUNT} -gt 100 ]]; then
  echo "Cleaning old orchestrator logs (keeping last 100)..."
  ls -1t "${ORCH_LOG_DIR}"/orchestrator-*.log | tail -n +101 | xargs rm -f
fi

# --- 8. Print status summary (paste-friendly for AI) -----------------------
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

if [[ ${CLAUDE_EXIT} -ne 0 ]]; then
  echo ""
  echo "WARNING: Claude Code exited with error code ${CLAUDE_EXIT}."
  echo "Check the run log: agent log"
fi

echo ""
echo "============================================================"

# --- 9. Wait for Dropbox sync (if Maestral is installed) -------------------
MAESTRAL_BIN="${HOME_DIR}/.local/bin/maestral"
if [[ -x "${MAESTRAL_BIN}" ]]; then
  # Wait for maestral daemon to be reachable (may still be starting after resume)
  echo "Checking Dropbox sync (maestral)..."
  MAESTRAL_READY=false
  for i in $(seq 1 12); do
    if "${MAESTRAL_BIN}" status &>/dev/null; then
      MAESTRAL_READY=true
      break
    fi
    echo "  Waiting for maestral daemon... (attempt ${i})"
    sleep 5
  done

  if [[ "${MAESTRAL_READY}" == "true" ]]; then
    # Kick maestral to rescan local changes — avoids a race where status reports
    # "Up to date" before it notices newly written files.
    "${MAESTRAL_BIN}" pause >/dev/null 2>&1 || true
    sleep 1
    "${MAESTRAL_BIN}" resume >/dev/null 2>&1 || true
    sleep 2
    echo "Waiting for Dropbox sync to complete..."
    SYNC_WAIT=0
    SYNC_TIMEOUT=120
    while [[ ${SYNC_WAIT} -lt ${SYNC_TIMEOUT} ]]; do
      SYNC_STATUS=$("${MAESTRAL_BIN}" status 2>/dev/null || echo "")
      if echo "${SYNC_STATUS}" | grep -qi "up to date\|idle"; then
        echo "Dropbox sync complete."
        break
      fi
      sleep 5
      SYNC_WAIT=$((SYNC_WAIT + 5))
    done
    if [[ ${SYNC_WAIT} -ge ${SYNC_TIMEOUT} ]]; then
      echo "WARNING: Dropbox sync did not complete within ${SYNC_TIMEOUT}s. Proceeding anyway."
    fi
  else
    echo "WARNING: Maestral daemon not reachable after 60s. Skipping Dropbox sync."
  fi
fi

# --- 10. Self-stop (scheduled mode) ----------------------------------------
if [[ "${SCHEDULE_MODE:-always-on}" == "scheduled" && "${NO_STOP}" != "--no-stop" ]]; then
  echo "Scheduled mode: hibernating instance in 10 seconds..."
  echo "(Cancel with: touch ~/agents/.keep-running)"
  sleep 10
  # Final check for lock file
  if [[ -f "${HOME_DIR}/agents/.keep-running" ]]; then
    echo "Lock file appeared. Cancelling hibernate."
  else
    do_hibernate "Scheduled mode self-stop"
  fi
else
  echo "Always-on mode (or --no-stop). Instance stays running."
fi
