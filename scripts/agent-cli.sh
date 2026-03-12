#!/usr/bin/env bash
# =============================================================================
# agent — Helper CLI for the agent server
# =============================================================================
# Usage:
#   agent status              Show agent status and last run info
#   agent run                 Run the agent now (stays on after)
#   agent activities           List default tasks (one-liner each)
#   agent activity [N]        Show details of task N
#   agent activity-add        Add a new default task (opens editor)
#   agent activity-edit [N]   Edit task N (opens editor)
#   agent activity-del [N]    Delete task N (use --yes to skip confirmation)
#   agent logs                List recent run logs
#   agent log [N]             Show the Nth most recent log (default: latest)
#   agent research            List research outputs
#   agent research <file>     View a research file
#   agent tasks               List task outputs
#   agent task <file>         View a task output
#   agent inbox               List inbox files
#   agent improvements        List improvement proposals
#   agent improve [N]         View Nth most recent proposal (1=latest)
#   agent upgrade             Pull latest agent code from GitHub
#   agent heartbeat           Show heartbeat info
#   agent help                Show this help
# =============================================================================

set -uo pipefail

# --- Global flags ---
AUTO_YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
  esac
done
# Strip --yes/-y from positional args
ARGS=()
for arg in "$@"; do
  case "$arg" in
    --yes|-y) ;;
    *) ARGS+=("$arg") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

# --- Configuration ---
source "${HOME}/.agent-server.conf" 2>/dev/null || true
source "${HOME}/.agent-schedule" 2>/dev/null || true

OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
BRAIN_DIR="${HOME}/brain"

LOG_DIR="${BRAIN_DIR}/${OUTPUT_FOLDER}/logs"
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
    inbox_count=$(find "$INBOX_DIR" -maxdepth 1 \( -name '*.txt' -o -name '*.md' \) ! -name '_*' 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo -e "  Inbox:      ${inbox_count} pending task(s)"

  # Recent logs
  local log_count
  log_count=$(ls -1 "${LOG_DIR}"/agent-run-*.md 2>/dev/null | wc -l | tr -d ' ')
  echo -e "  Run logs:   ${log_count} total"

  # MCP config (read from Claude Code's config file)
  if [[ -f "${HOME}/.claude.json" ]]; then
    local mcp_servers
    mcp_servers=$(python3 -c "
import json
d=json.load(open('${HOME}/.claude.json'))
names = list(d.get('mcpServers',{}).keys())
for s in d.get('claudeAiMcpEverConnected',[]):
    names.append(s.replace('claude.ai ',''))
print(', '.join(names) if names else '')
" 2>/dev/null || echo "")
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

TASKS_FILE="${BRAIN_DIR}/ai/instructions/default-tasks.md"

# Parse default-tasks.md into task sections.
# Outputs: number|title|type|mcp|frequency  (one line per task)
parse_tasks() {
  python3 -c "
import re, sys

try:
    with open('${TASKS_FILE}') as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(0)

# Split on ## N. headings
sections = re.split(r'^## (\d+)\. ', content, flags=re.MULTILINE)
# sections[0] is preamble, then pairs of (number, body)
i = 1
while i < len(sections) - 1:
    num = sections[i]
    body = sections[i+1]
    title = body.split('\n', 1)[0].strip()
    # Extract metadata
    type_match = re.search(r'\*\*Type\*\*:\s*(.+)', body)
    mcp_match = re.search(r'\*\*MCP required\*\*:\s*(.+)', body)
    freq_match = re.search(r'\*\*Frequency\*\*:\s*(.+)', body)
    task_type = type_match.group(1).strip() if type_match else ''
    mcp = mcp_match.group(1).strip() if mcp_match else ''
    freq = freq_match.group(1).strip() if freq_match else ''
    print(f'{num}|{title}|{task_type}|{mcp}|{freq}')
    i += 2
" 2>/dev/null
}

# Extract the full text of task N (just the section body, no ## heading)
extract_task_body() {
  local n="$1"
  python3 -c "
import re, sys

with open('${TASKS_FILE}') as f:
    content = f.read()

sections = re.split(r'^(## \d+\. )', content, flags=re.MULTILINE)
# sections: [preamble, '## 1. ', body1, '## 2. ', body2, ...]
i = 1
while i < len(sections) - 1:
    heading = sections[i]
    body = sections[i+1]
    num = re.match(r'## (\d+)\.', heading).group(1)
    if num == '${n}':
        # Print heading + body (without trailing ---)
        full = heading + body
        full = full.rstrip()
        if full.endswith('---'):
            full = full[:-3].rstrip()
        print(full)
        sys.exit(0)
    i += 2
sys.exit(1)
" 2>/dev/null
}

cmd_activity() {
  local n="${1:-}"

  if [[ ! -f "${TASKS_FILE}" ]]; then
    echo "No default-tasks.md found at ${TASKS_FILE}"
    return 1
  fi

  if [[ -n "$n" ]]; then
    # Show details of task N
    local body
    body=$(extract_task_body "$n")
    if [[ -z "$body" ]]; then
      echo "No task #${n} found."
      return 1
    fi
    echo ""
    echo "$body" | if has_glow; then
      local width
      width=$(tput cols 2>/dev/null || echo 100)
      glow -w "$width" - 2>/dev/null || cat
    else
      cat
    fi
    echo ""
    return 0
  fi

  # List all tasks
  echo ""
  echo -e "${BOLD}Default Tasks${NC}"
  echo "─────────────────────────────────"

  local found=false
  while IFS='|' read -r num title task_type mcp freq; do
    [[ -z "$num" ]] && continue
    found=true
    local meta=""
    [[ -n "$task_type" ]] && meta="${task_type}"
    [[ -n "$mcp" ]] && meta="${meta:+${meta}, }requires ${mcp}"
    [[ -n "$freq" ]] && meta="${meta:+${meta}, }${freq}"
    printf "  ${CYAN}%2s.${NC} %-28s ${DIM}(%s)${NC}\n" "$num" "$title" "$meta"
  done < <(parse_tasks)

  if [[ "$found" == false ]]; then
    echo "  No tasks defined."
  fi
  echo ""
  echo -e "${DIM}Use: agent activity N to view details${NC}"
  echo ""
}

cmd_activity_del() {
  local n="${1:-}"
  if [[ -z "$n" ]]; then
    echo "Usage: agent activity-del N"
    return 1
  fi

  if [[ ! -f "${TASKS_FILE}" ]]; then
    echo "No default-tasks.md found."
    return 1
  fi

  # Verify task exists
  local body
  body=$(extract_task_body "$n")
  if [[ -z "$body" ]]; then
    echo "No task #${n} found."
    return 1
  fi

  local title
  title=$(echo "$body" | head -1 | sed 's/^## [0-9]*\. //')
  if [[ "${AUTO_YES}" != "true" ]]; then
    echo -e "Delete task ${CYAN}#${n}: ${title}${NC}?"
    read -r -p "Confirm (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
      echo "Cancelled."
      return 0
    fi
  fi

  # Remove section and renumber
  python3 -c "
import re

with open('${TASKS_FILE}') as f:
    content = f.read()

# Split into preamble + sections
sections = re.split(r'^(## \d+\. )', content, flags=re.MULTILINE)
# [preamble, '## 1. ', body1, '## 2. ', body2, ...]

preamble = sections[0]
result = preamble
new_num = 1
i = 1
while i < len(sections) - 1:
    heading = sections[i]
    body = sections[i+1]
    old_num = re.match(r'## (\d+)\.', heading).group(1)
    if old_num == '${n}':
        i += 2
        continue
    new_heading = re.sub(r'## \d+\.', f'## {new_num}.', heading)
    result += new_heading + body
    new_num += 1
    i += 2

with open('${TASKS_FILE}', 'w') as f:
    f.write(result)
"
  echo -e "${GREEN}Deleted task #${n}: ${title}${NC}"
  echo "Remaining tasks renumbered."
}

cmd_activity_add() {
  if [[ ! -f "${TASKS_FILE}" ]]; then
    echo "No default-tasks.md found."
    return 1
  fi

  # Find next task number
  local next_num
  next_num=$(parse_tasks | tail -1 | cut -d'|' -f1)
  next_num=$(( ${next_num:-0} + 1 ))

  local user_content

  if [[ ! -t 0 ]]; then
    # Reading from pipe/stdin
    user_content=$(cat)
  else
    # Interactive — open editor with template
    local tmpfile
    tmpfile=$(mktemp /tmp/agent-task-XXXXXX.md)
    cat > "$tmpfile" << 'TMPL'
## TITLE

**Type**: TaskType
**MCP required**: None

Describe what this task should do.

TMPL

    local editor="${EDITOR:-nano}"
    "$editor" "$tmpfile"

    if [[ ! -s "$tmpfile" ]]; then
      echo "Empty file — cancelled."
      rm -f "$tmpfile"
      return 0
    fi

    user_content=$(cat "$tmpfile")
    rm -f "$tmpfile"
  fi

  if [[ -z "$user_content" ]]; then
    echo "Empty input — cancelled."
    return 0
  fi

  # Extract the title from the first line (strip any ## prefix the user may have added)
  local title
  title=$(echo "$user_content" | head -1 | sed 's/^#* *//')

  # Remove the title line from the body
  local body
  body=$(echo "$user_content" | tail -n +2)

  # Append to file
  python3 -c "
with open('${TASKS_FILE}') as f:
    content = f.read()

# Ensure file ends with proper separator
content = content.rstrip()
if not content.endswith('---'):
    content += '\n\n---\n'
else:
    content += '\n'

import sys
title = sys.stdin.readline().strip()
body = sys.stdin.read()

content += '\n## ${next_num}. ' + title + '\n' + body + '\n\n---\n'

with open('${TASKS_FILE}', 'w') as f:
    f.write(content)
" <<< "${title}
${body}"

  echo -e "${GREEN}Added task #${next_num}: ${title}${NC}"
}

cmd_activity_edit() {
  local n="${1:-}"
  if [[ -z "$n" ]]; then
    echo "Usage: agent activity-edit N"
    return 1
  fi

  if [[ ! -f "${TASKS_FILE}" ]]; then
    echo "No default-tasks.md found."
    return 1
  fi

  # Extract task body
  local body
  body=$(extract_task_body "$n")
  if [[ -z "$body" ]]; then
    echo "No task #${n} found."
    return 1
  fi

  local new_content

  if [[ ! -t 0 ]]; then
    # Reading from pipe/stdin
    new_content=$(cat)
  else
    # Interactive — open editor with current content
    local tmpfile
    tmpfile=$(mktemp /tmp/agent-task-XXXXXX.md)
    echo "$body" | sed '1s/^## [0-9]*\. //' > "$tmpfile"

    local editor="${EDITOR:-nano}"
    "$editor" "$tmpfile"

    if [[ ! -s "$tmpfile" ]]; then
      echo "Empty file — cancelled (task unchanged)."
      rm -f "$tmpfile"
      return 0
    fi

    new_content=$(cat "$tmpfile")
    rm -f "$tmpfile"
  fi

  if [[ -z "$new_content" ]]; then
    echo "Empty input — cancelled."
    return 0
  fi

  # Extract new title from first line
  local new_title
  new_title=$(echo "$new_content" | head -1 | sed 's/^#* *//')

  local new_body
  new_body=$(echo "$new_content" | tail -n +2)

  # Replace section in file
  python3 -c "
import re, sys

with open('${TASKS_FILE}') as f:
    content = f.read()

sections = re.split(r'^(## \d+\. )', content, flags=re.MULTILINE)

result = sections[0]
i = 1
while i < len(sections) - 1:
    heading = sections[i]
    body = sections[i+1]
    old_num = re.match(r'## (\d+)\.', heading).group(1)
    if old_num == '${n}':
        # Read replacement from stdin
        replacement = sys.stdin.read()
        title_line = replacement.split('\n', 1)[0].strip()
        rest = replacement.split('\n', 1)[1] if '\n' in replacement else ''
        result += '## ${n}. ' + title_line + '\n' + rest
        # Ensure section ends with separator
        if not result.rstrip().endswith('---'):
            result = result.rstrip() + '\n\n---\n'
    else:
        result += heading + body
    i += 2

with open('${TASKS_FILE}', 'w') as f:
    f.write(result)
" <<< "${new_content}"

  echo -e "${GREEN}Updated task #${n}: ${new_title}${NC}"
}

cmd_upgrade() {
  local REPO_DIR="${HOME}/.agent-repo"
  local REPO_URL="https://github.com/gregertw/claude-code-agent.git"
  local SCRIPTS="${HOME}/scripts"

  echo ""
  echo -e "${BOLD}Agent Code Upgrade${NC}"
  echo "─────────────────────────────────"

  # Pull or clone
  if [[ -d "${REPO_DIR}/.git" ]]; then
    local before after
    before=$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
    if git -C "${REPO_DIR}" pull --quiet 2>/dev/null; then
      after=$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
      if [[ "$before" == "$after" ]]; then
        echo -e "  ${DIM}Already up to date (${after})${NC}"
      else
        echo -e "  ${GREEN}Updated: ${before} → ${after}${NC}"
      fi
    else
      echo -e "  ${RED}git pull failed${NC}"
      return 1
    fi
  else
    echo "  Cloning repo..."
    if git clone --depth 1 --quiet "${REPO_URL}" "${REPO_DIR}" 2>/dev/null; then
      local rev
      rev=$(git -C "${REPO_DIR}" rev-parse --short HEAD 2>/dev/null || echo "unknown")
      echo -e "  ${GREEN}Cloned (${rev})${NC}"
    else
      echo -e "  ${RED}git clone failed${NC}"
      return 1
    fi
  fi

  # Update scripts (server-side scripts live in scripts/ in the repo)
  local REPO_SCRIPTS="${REPO_DIR}/scripts"
  local updated=0
  for script in agent-orchestrator.sh agent-cli.sh agent-functions.sh agent-resume-check.sh set-schedule-mode.sh run-agent.sh install-templates.sh setup-dropbox.sh; do
    if [[ -f "${REPO_SCRIPTS}/${script}" ]]; then
      if ! cmp -s "${REPO_SCRIPTS}/${script}" "${SCRIPTS}/${script}" 2>/dev/null; then
        cp "${REPO_SCRIPTS}/${script}" "${SCRIPTS}/${script}"
        chmod +x "${SCRIPTS}/${script}"
        updated=$((updated + 1))
        echo -e "  ${GREEN}✓${NC} ${script}"
      fi
    fi
  done

  # agent-setup.sh (lives in scripts/ in repo, installed to ~/agent-setup.sh)
  if [[ -f "${REPO_SCRIPTS}/agent-setup.sh" ]]; then
    if ! cmp -s "${REPO_SCRIPTS}/agent-setup.sh" "${HOME}/agent-setup.sh" 2>/dev/null; then
      cp "${REPO_SCRIPTS}/agent-setup.sh" "${HOME}/agent-setup.sh"
      chmod +x "${HOME}/agent-setup.sh"
      updated=$((updated + 1))
      echo -e "  ${GREEN}✓${NC} agent-setup.sh"
    fi
  fi

  # Templates (source for install-templates.sh, NOT overwriting brain/)
  if [[ -d "${REPO_DIR}/templates" ]]; then
    mkdir -p "${HOME}/.agent-templates"
    cp "${REPO_DIR}/templates/"*.md "${HOME}/.agent-templates/" 2>/dev/null || true
  fi

  if [[ $updated -eq 0 ]]; then
    echo -e "  ${DIM}All scripts already current${NC}"
  else
    echo -e "  ${updated} script(s) updated"
  fi

  echo ""
}

cmd_help() {
  echo ""
  echo -e "${BOLD}agent${NC} — Agent server helper"
  echo ""
  echo "Commands:"
  echo -e "  ${CYAN}agent status${NC}              Show agent status and last run"
  echo -e "  ${CYAN}agent run${NC}                 Run the agent now"
  echo -e "  ${CYAN}agent activities${NC}           List default tasks"
  echo -e "  ${CYAN}agent activity N${NC}          Show details of task N"
  echo -e "  ${CYAN}agent activity-add${NC}        Add a new default task"
  echo -e "  ${CYAN}agent activity-edit N${NC}     Edit task N"
  echo -e "  ${CYAN}agent activity-del N${NC}      Delete task N (--yes to skip prompt)"
  echo -e "  ${CYAN}agent logs${NC}                List recent run logs"
  echo -e "  ${CYAN}agent log [N]${NC}             Show Nth most recent log (1=latest)"
  echo -e "  ${CYAN}agent research${NC}            List research outputs"
  echo -e "  ${CYAN}agent research <file>${NC}     View a research file"
  echo -e "  ${CYAN}agent tasks${NC}               List task outputs"
  echo -e "  ${CYAN}agent task <file>${NC}         View a task output"
  echo -e "  ${CYAN}agent inbox${NC}               List inbox files"
  echo -e "  ${CYAN}agent improvements${NC}        List improvement proposals"
  echo -e "  ${CYAN}agent improve [N]${NC}         View Nth most recent proposal (1=latest)"
  echo -e "  ${CYAN}agent upgrade${NC}             Pull latest agent code from GitHub"
  echo -e "  ${CYAN}agent heartbeat${NC}           Show heartbeat details"
  echo -e "  ${CYAN}agent help${NC}                Show this help"
  echo ""
  echo "Flags:"
  echo -e "  ${CYAN}--yes, -y${NC}                 Skip confirmations (for scripting)"
  echo ""
  echo "Piping:"
  echo -e "  echo 'task content' | ${CYAN}agent activity-add${NC}"
  echo -e "  echo 'new content' | ${CYAN}agent activity-edit N${NC}"
  echo ""
}

# --- Main dispatch -----------------------------------------------------------
case "${1:-status}" in
  status)         cmd_status ;;
  run)            cmd_run ;;
  activities)     cmd_activity "" ;;
  activity)       cmd_activity "${2:-}" ;;
  activity-add)   cmd_activity_add ;;
  activity-edit)  cmd_activity_edit "${2:-}" ;;
  activity-del)   cmd_activity_del "${2:-}" ;;
  logs)           cmd_logs ;;
  log)       cmd_log "${2:-1}" ;;
  research)  cmd_research "${2:-}" ;;
  tasks)     cmd_tasks "${2:-}" ;;
  task)      cmd_tasks "${2:-}" ;;
  inbox)     cmd_inbox ;;
  improvements) cmd_improvements ;;
  improve)   cmd_improve "${2:-1}" ;;
  upgrade)   cmd_upgrade ;;
  heartbeat) cmd_heartbeat ;;
  help|-h|--help) cmd_help ;;
  *)
    echo "Unknown command: $1"
    cmd_help
    exit 1
    ;;
esac
