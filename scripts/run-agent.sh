#!/usr/bin/env bash
# =============================================================================
# Run a Claude Code agent task with logging.
# Usage: ./run-agent.sh "Your prompt here" [working-directory]
# =============================================================================

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
