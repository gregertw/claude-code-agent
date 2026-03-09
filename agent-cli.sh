#!/usr/bin/env bash
# =============================================================================
# agent — Helper CLI for the agent server
# =============================================================================
# Usage:
#   agent status          Show agent status and last run info
#   agent run             Run the agent now (stays on after)
#   agent logs            List recent run logs
#   agent log [N]         Show the Nth most recent log (default: latest)
#   agent research        List research outputs
#   agent research <file> View a research file
#   agent tasks           List task outputs
#   agent task <file>     View a task output
#   agent inbox           List inbox files
#   agent improvements    List improvement proposals
#   agent improve [N]     View Nth most recent proposal (1=latest)
#   agent heartbeat       Show heartbeat info
#   agent help            Show this help
# =============================================================================

set -uo pipefail

# --- Configuration ---
source "${HOME}/.agent-server.conf" 2>/dev/null || true
source "${HOME}/.agent-schedule" 2>/dev/null || true

FILE_SYNC="${FILE_SYNC:-none}"
BRAIN_FOLDER="${BRAIN_FOLDER:-brain}"
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"

if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  BRAIN_DIR="${HOME}/Dropbox/${BRAIN_FOLDER}"
else
  BRAIN_DIR="${HOME}/brain"
fi

LOG_DIR="${HOME}/logs"
OUTPUT_DIR="${BRAIN_DIR}/${OUTPUT_FOLDER}"
INBOX_DIR="${BRAIN_DIR}/INBOX"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Check for glow
has_glow() { command -v glow &>/dev/null; }

# Render markdown (use glow if available, otherwise cat)
render_md() {
  if has_glow; then
    local width
    width=$(tput cols 2>/dev/null || echo "")
    if [[ -z "$width" || "$width" -lt 10 ]]; then
      width=100
    fi
    cat "$1" | glow -w "$width" - 2>/dev/null || cat "$1"
  else
    cat "$1"
  fi
}

# --- Commands ----------------------------------------------------------------

cmd_status() {
  echo ""
  echo -e "${BOLD}Agent Server Status${NC}"
  echo "─────────────────────────────────"

  # Mode
  local mode="${SCHEDULE_MODE:-unknown}"
  if [[ "$mode" == "scheduled" ]]; then
    echo -e "  Mode:       ${CYAN}scheduled${NC} (every ${SCHEDULE_INTERVAL:-60} min)"
  else
    echo -e "  Mode:       ${CYAN}${mode}${NC}"
  fi

  # Brain dir
  echo -e "  Brain:      ${BRAIN_DIR}"

  # Heartbeat
  local hb="${OUTPUT_DIR}/.agent-heartbeat"
  if [[ -f "$hb" ]]; then
    local last_run exit_code
    last_run=$(grep '^last_run=' "$hb" | cut -d= -f2)
    exit_code=$(grep '^exit_code=' "$hb" | cut -d= -f2)
    local ago=""
    if [[ -n "$last_run" ]]; then
      local ts now diff
      ts=$(date -d "$last_run" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$last_run" +%s 2>/dev/null || echo "")
      if [[ -n "$ts" ]]; then
        now=$(date +%s)
        diff=$(( now - ts ))
        if (( diff < 60 )); then ago="${diff}s ago"
        elif (( diff < 3600 )); then ago="$(( diff / 60 ))m ago"
        elif (( diff < 86400 )); then ago="$(( diff / 3600 ))h ago"
        else ago="$(( diff / 86400 ))d ago"
        fi
      fi
    fi
    if [[ "$exit_code" == "0" ]]; then
      echo -e "  Last run:   ${GREEN}${last_run}${NC} (${ago}, exit ${exit_code})"
    else
      echo -e "  Last run:   ${RED}${last_run}${NC} (${ago}, exit ${exit_code})"
    fi
  else
    echo -e "  Last run:   ${DIM}no heartbeat yet${NC}"
  fi

  # Inbox count
  local inbox_count=0
  if [[ -d "$INBOX_DIR" ]]; then
    inbox_count=$(find "$INBOX_DIR" -maxdepth 1 -name '*.txt' -o -name '*.md' 2>/dev/null | grep -cv '^$' || echo 0)
    # Subtract files starting with _
    local skip_count
    skip_count=$(find "$INBOX_DIR" -maxdepth 1 \( -name '_*.txt' -o -name '_*.md' \) 2>/dev/null | grep -cv '^$' || echo 0)
    inbox_count=$(( inbox_count - skip_count ))
  fi
  echo -e "  Inbox:      ${inbox_count} pending task(s)"

  # Recent logs
  local log_count
  log_count=$(ls -1 "${LOG_DIR}"/agent-run-*.md 2>/dev/null | wc -l | tr -d ' ')
  echo -e "  Run logs:   ${log_count} total"

  # MCP config (read from Claude Code's config file)
  if [[ -f "${HOME}/.claude.json" ]]; then
    local mcp_servers
    mcp_servers=$(python3 -c "import json; d=json.load(open('${HOME}/.claude.json')); servers=d.get('mcpServers',{}); print(', '.join(servers.keys()) if servers else '')" 2>/dev/null || echo "")
    if [[ -n "${mcp_servers}" ]]; then
      echo -e "  MCP:        ${mcp_servers}"
    else
      echo -e "  MCP:        ${DIM}not configured${NC}"
    fi
  else
    echo -e "  MCP:        ${DIM}not configured${NC}"
  fi

  echo ""
}

cmd_run() {
  echo "Starting agent run..."
  "${HOME}/scripts/agent-orchestrator.sh" --no-stop
}

cmd_logs() {
  echo ""
  echo -e "${BOLD}Recent Run Logs${NC}"
  echo "─────────────────────────────────"
  if ls "${LOG_DIR}"/agent-run-*.md 1>/dev/null 2>&1; then
    ls -1t "${LOG_DIR}"/agent-run-*.md | head -20 | while read -r f; do
      local basename ts
      basename=$(basename "$f")
      # Extract timestamp from filename: agent-run-YYYYMMDD-HHMMSS.md
      ts=$(echo "$basename" | sed 's/agent-run-\([0-9]\{8\}\)-\([0-9]\{6\}\)\.md/\1 \2/' | sed 's/\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/\1-\2-\3/' | sed 's/ \([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)/ \1:\2:\3/')
      echo -e "  ${CYAN}${ts}${NC}  ${basename}"
    done
  else
    echo "  No logs found."
  fi
  echo ""
  echo -e "${DIM}Use: agent log [N] to view a log (N=1 for latest)${NC}"
  echo ""
}

cmd_log() {
  local n="${1:-1}"
  local brain_log_dir="${OUTPUT_DIR}/logs"

  # Prefer brain output logs (more detailed) over orchestrator capture logs
  local file=""
  if [[ -d "$brain_log_dir" ]]; then
    file=$(ls -1t "${brain_log_dir}"/run-*.md 2>/dev/null | sed -n "${n}p")
  fi
  if [[ -z "$file" ]]; then
    file=$(ls -1t "${LOG_DIR}"/agent-run-*.md 2>/dev/null | sed -n "${n}p")
  fi

  if [[ -z "$file" ]]; then
    echo "No log found at position ${n}."
    return 1
  fi
  echo -e "${DIM}── $(basename "$file") ──${NC}"
  echo ""
  render_md "$file"
}

cmd_research() {
  local research_dir="${OUTPUT_DIR}/research"
  if [[ -n "${1:-}" ]]; then
    # View specific file
    local file="${research_dir}/${1}"
    if [[ ! -f "$file" ]]; then
      # Try with .md extension
      file="${research_dir}/${1}.md"
    fi
    if [[ -f "$file" ]]; then
      render_md "$file"
    else
      echo "File not found: ${1}"
      return 1
    fi
  else
    echo ""
    echo -e "${BOLD}Research Outputs${NC}"
    echo "─────────────────────────────────"
    if [[ -d "$research_dir" ]] && ls "$research_dir"/*.md 1>/dev/null 2>&1; then
      ls -1t "$research_dir" | while read -r f; do
        echo -e "  ${CYAN}${f}${NC}"
      done
    else
      echo "  No research files found."
    fi
    echo ""
    echo -e "${DIM}Use: agent research <filename> to view${NC}"
    echo ""
  fi
}

cmd_tasks() {
  local tasks_dir="${OUTPUT_DIR}/tasks"
  if [[ -n "${1:-}" ]]; then
    local file="${tasks_dir}/${1}"
    if [[ ! -f "$file" ]]; then
      file="${tasks_dir}/${1}.md"
    fi
    if [[ -f "$file" ]]; then
      render_md "$file"
    else
      echo "File not found: ${1}"
      return 1
    fi
  else
    echo ""
    echo -e "${BOLD}Task Outputs${NC}"
    echo "─────────────────────────────────"
    if [[ -d "$tasks_dir" ]] && ls "$tasks_dir"/ 1>/dev/null 2>&1; then
      ls -1t "$tasks_dir" | head -20 | while read -r f; do
        echo -e "  ${CYAN}${f}${NC}"
      done
    else
      echo "  No task output files found."
    fi
    echo ""
    echo -e "${DIM}Use: agent task <filename> to view${NC}"
    echo ""
  fi
}

cmd_inbox() {
  echo ""
  echo -e "${BOLD}Inbox${NC}"
  echo "─────────────────────────────────"
  if [[ -d "$INBOX_DIR" ]]; then
    local found=false
    while IFS= read -r f; do
      [[ -z "$f" ]] && continue
      found=true
      local basename
      basename=$(basename "$f")
      if [[ "$basename" == _* ]]; then
        echo -e "  ${DIM}${basename} (skipped — _ prefix)${NC}"
      else
        echo -e "  ${CYAN}${basename}${NC}"
      fi
    done < <(find "$INBOX_DIR" -maxdepth 1 \( -name '*.txt' -o -name '*.md' \) | sort)
    if [[ "$found" == false ]]; then
      echo "  Empty — drop .txt or .md files here to queue tasks."
    fi
  else
    echo "  Inbox directory not found."
  fi
  echo ""
  echo -e "  Path: ${INBOX_DIR}"
  echo ""
}

cmd_improvements() {
  local improve_dir="${OUTPUT_DIR}/improvements"
  echo ""
  echo -e "${BOLD}Improvement Proposals${NC}"
  echo "─────────────────────────────────"
  if [[ -d "$improve_dir" ]] && ls "$improve_dir"/review-*.md 1>/dev/null 2>&1; then
    ls -1t "$improve_dir"/review-*.md | head -20 | while read -r f; do
      local basename
      basename=$(basename "$f")
      # Extract date from filename: review-YYYY-MM-DD.md
      local date_part
      date_part=$(echo "$basename" | sed 's/review-\(.*\)\.md/\1/')
      # Count proposals in file
      local count
      count=$(grep -c '^### [0-9]' "$f" 2>/dev/null || echo "0")
      echo -e "  ${CYAN}${date_part}${NC}  ${count} proposal(s)  ${DIM}${basename}${NC}"
    done
  else
    echo "  No improvement proposals yet."
    echo ""
    echo -e "  ${DIM}The agent's daily Self-Review task writes proposals here.${NC}"
  fi
  echo ""
  echo -e "${DIM}Use: agent improve [N] to view (N=1 for latest)${NC}"
  echo ""
}

cmd_improve() {
  local n="${1:-1}"
  local improve_dir="${OUTPUT_DIR}/improvements"

  local file=""
  if [[ -d "$improve_dir" ]]; then
    file=$(ls -1t "${improve_dir}"/review-*.md 2>/dev/null | sed -n "${n}p")
  fi

  if [[ -z "$file" ]]; then
    echo "No improvement proposal found at position ${n}."
    return 1
  fi
  echo -e "${DIM}── $(basename "$file") ──${NC}"
  echo ""
  render_md "$file"
}

cmd_heartbeat() {
  local hb="${OUTPUT_DIR}/.agent-heartbeat"
  if [[ -f "$hb" ]]; then
    echo ""
    echo -e "${BOLD}Heartbeat${NC}"
    echo "─────────────────────────────────"
    while IFS='=' read -r key val; do
      [[ -z "$key" || "$key" == \#* ]] && continue
      echo -e "  ${key}: ${CYAN}${val}${NC}"
    done < "$hb"
    echo ""
  else
    echo "No heartbeat file found. Agent may not have run yet."
  fi
}

cmd_help() {
  echo ""
  echo -e "${BOLD}agent${NC} — Agent server helper"
  echo ""
  echo "Commands:"
  echo -e "  ${CYAN}agent status${NC}            Show agent status and last run"
  echo -e "  ${CYAN}agent run${NC}               Run the agent now"
  echo -e "  ${CYAN}agent logs${NC}              List recent run logs"
  echo -e "  ${CYAN}agent log [N]${NC}           Show Nth most recent log (1=latest)"
  echo -e "  ${CYAN}agent research${NC}          List research outputs"
  echo -e "  ${CYAN}agent research <file>${NC}   View a research file"
  echo -e "  ${CYAN}agent tasks${NC}             List task outputs"
  echo -e "  ${CYAN}agent task <file>${NC}       View a task output"
  echo -e "  ${CYAN}agent inbox${NC}             List inbox files"
  echo -e "  ${CYAN}agent improvements${NC}      List improvement proposals"
  echo -e "  ${CYAN}agent improve [N]${NC}       View Nth most recent proposal (1=latest)"
  echo -e "  ${CYAN}agent heartbeat${NC}         Show heartbeat details"
  echo -e "  ${CYAN}agent help${NC}              Show this help"
  echo ""
}

# --- Main dispatch -----------------------------------------------------------
case "${1:-status}" in
  status)    cmd_status ;;
  run)       cmd_run ;;
  logs)      cmd_logs ;;
  log)       cmd_log "${2:-1}" ;;
  research)  cmd_research "${2:-}" ;;
  tasks)     cmd_tasks "${2:-}" ;;
  task)      cmd_tasks "${2:-}" ;;
  inbox)     cmd_inbox ;;
  improvements) cmd_improvements ;;
  improve)   cmd_improve "${2:-1}" ;;
  heartbeat) cmd_heartbeat ;;
  help|-h|--help) cmd_help ;;
  *)
    echo "Unknown command: $1"
    cmd_help
    exit 1
    ;;
esac
