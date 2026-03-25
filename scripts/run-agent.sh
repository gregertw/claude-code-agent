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

# Load agent config for Claude CLI settings
AGENT_CONF="${HOME}/.agent-server.conf"
[[ -f "${AGENT_CONF}" ]] && source "${AGENT_CONF}"

echo "[$(date)] Starting agent in ${WORKDIR}" | tee -a "${LOGFILE}"
echo "[$(date)] Prompt: ${PROMPT}" | tee -a "${LOGFILE}"

cd "${WORKDIR}"

# Build CLI flags from agent.conf settings
CLAUDE_FLAGS=(-p "${PROMPT}")
CLAUDE_FLAGS+=(--max-turns "${CLAUDE_MAX_TURNS:-50}")

[[ -n "${CLAUDE_MODEL:-}" ]] && CLAUDE_FLAGS+=(--model "${CLAUDE_MODEL}")
[[ -n "${CLAUDE_OUTPUT_FORMAT:-}" ]] && CLAUDE_FLAGS+=(--output-format "${CLAUDE_OUTPUT_FORMAT}")
[[ -n "${CLAUDE_PERMISSION_MODE:-}" ]] && CLAUDE_FLAGS+=(--permission-mode "${CLAUDE_PERMISSION_MODE}")
[[ -n "${CLAUDE_MAX_BUDGET_USD:-}" ]] && CLAUDE_FLAGS+=(--max-budget-usd "${CLAUDE_MAX_BUDGET_USD}")
[[ "${CLAUDE_VERBOSE:-false}" == "true" ]] && CLAUDE_FLAGS+=(--verbose)

if [[ -n "${CLAUDE_EXTRA_FLAGS:-}" ]]; then
  read -ra _extra <<< "${CLAUDE_EXTRA_FLAGS}"
  CLAUDE_FLAGS+=("${_extra[@]}")
fi

claude "${CLAUDE_FLAGS[@]}" 2>&1 | tee -a "${LOGFILE}"

echo "[$(date)] Agent finished." | tee -a "${LOGFILE}"
