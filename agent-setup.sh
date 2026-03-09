#!/usr/bin/env bash
# =============================================================================
# agent-setup — Post-deploy setup for the agent server
# =============================================================================
# Run this ON THE SERVER after deploy.sh to complete setup.
# Handles all post-deploy steps in the right order based on agent.conf.
# Safe to re-run — each step checks if it's already done and skips/verifies.
#
# Steps (in order):
#   1. Dropbox: link account, selective sync, brain folder (if FILE_SYNC=dropbox)
#   2. Brain directory: create if missing, install template files
#   3. MCP servers: register any that aren't already connected
#   4. Summary: show status and next steps
#
# Usage:
#   ~/agent-setup.sh           # full setup (follows agent.conf)
#   ~/agent-setup.sh --verify  # just verify everything, don't change anything
# =============================================================================

set -euo pipefail

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SETUP]${NC} $1"; }
warn() { echo -e "${YELLOW}[NOTE]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
skip() { echo -e "  ${DIM}– $1 (already done)${NC}"; }
need() { echo -e "  ${YELLOW}!${NC} $1"; }

VERIFY_ONLY=false
[[ "${1:-}" == "--verify" ]] && VERIFY_ONLY=true

# --- Load configuration -----------------------------------------------------
source "${HOME}/.agent-server.conf" 2>/dev/null || {
  err "~/.agent-server.conf not found. Run setup.sh first."
  exit 1
}

FILE_SYNC="${FILE_SYNC:-none}"
BRAIN_FOLDER="${BRAIN_FOLDER:-brain}"
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
SETUP_ACTINGWEB="${SETUP_ACTINGWEB:-true}"
SETUP_GMAIL="${SETUP_GMAIL:-false}"
SETUP_GOOGLE_CALENDAR="${SETUP_GOOGLE_CALENDAR:-false}"

if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  DROPBOX_DIR="${HOME}/Dropbox"
  BRAIN_DIR="${DROPBOX_DIR}/${BRAIN_FOLDER}"
else
  BRAIN_DIR="${HOME}/brain"
fi

export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/bin:$PATH"

echo ""
echo -e "${BOLD}Agent Server Setup${NC}"
echo "════════════════════════════════════════"
echo ""

# Track overall status
ISSUES=0

# =============================================================================
# Step 1: Dropbox (if configured)
# =============================================================================
if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  echo -e "${BOLD}Step 1: Dropbox${NC}"
  echo "────────────────────────────────────────"

  # 1a. Link account
  if [[ -d "${DROPBOX_DIR}" ]]; then
    ok "Account linked (~/Dropbox exists)"
  elif [[ "${VERIFY_ONLY}" == "true" ]]; then
    need "Account not linked"
    ISSUES=$((ISSUES + 1))
  else
    log "Linking Dropbox account..."
    echo ""
    echo "  Dropbox will print a URL. Open it in your browser."
    echo "  Ignore 'load fq extension' warnings — they are normal."
    echo "  The script continues automatically once linked."
    echo ""
    read -r -p "  Press Enter to start..."

    LINK_LOG=$(mktemp /tmp/dropbox-link.XXXXXX)
    "${HOME}/.dropbox-dist/dropboxd" > "${LINK_LOG}" 2>&1 &
    DBPID=$!
    tail -f "${LINK_LOG}" &
    TAILPID=$!

    LINK_TIMEOUT=300
    LINK_START=$(date +%s)
    LINKED=false
    while true; do
      ELAPSED=$(( $(date +%s) - LINK_START ))
      [[ $ELAPSED -ge $LINK_TIMEOUT ]] && break
      if grep -q "linked to Dropbox" "${LINK_LOG}" 2>/dev/null; then
        LINKED=true
        sleep 2
        break
      fi
      sleep 1
    done

    kill $TAILPID 2>/dev/null; wait $TAILPID 2>/dev/null || true
    kill $DBPID 2>/dev/null; wait $DBPID 2>/dev/null || true
    rm -f "${LINK_LOG}"

    if [[ "${LINKED}" != "true" ]]; then
      err "Linking timed out. Run ~/agent-setup.sh again to retry."
      exit 1
    fi
    ok "Account linked successfully"
  fi

  # 1b. Selective sync
  if [[ -d "${DROPBOX_DIR}" ]]; then
    # Count non-brain folders
    OTHER_FOLDERS=0
    for dir in "${DROPBOX_DIR}"/*/; do
      [[ ! -d "$dir" ]] && continue
      dirname=$(basename "$dir")
      [[ "$dirname" != "${BRAIN_FOLDER}" ]] && OTHER_FOLDERS=$((OTHER_FOLDERS + 1))
    done

    if [[ $OTHER_FOLDERS -eq 0 ]]; then
      ok "Selective sync configured (only '${BRAIN_FOLDER}/' syncing)"
    elif [[ "${VERIFY_ONLY}" == "true" ]]; then
      need "Found ${OTHER_FOLDERS} non-brain folder(s) syncing"
      ISSUES=$((ISSUES + 1))
    else
      log "Configuring selective sync..."

      # Stop Dropbox to prevent syncing everything
      sudo systemctl stop dropbox 2>/dev/null || true
      pkill -f dropboxd 2>/dev/null || true
      sleep 2

      # Start daemon temporarily for exclude API
      "${HOME}/.dropbox-dist/dropboxd" > /dev/null 2>&1 &
      DBPID=$!
      for i in $(seq 1 15); do
        dropbox-cli status 2>/dev/null | grep -qv "isn't running" && break
        sleep 1
      done
      sleep 5

      # Apply exclusions
      EXCLUDED=0
      for dir in "${DROPBOX_DIR}"/*/; do
        [[ ! -d "$dir" ]] && continue
        dirname=$(basename "$dir")
        if [[ "$dirname" != "${BRAIN_FOLDER}" ]]; then
          dropbox-cli exclude add "$dir" >/dev/null 2>&1 || true
          EXCLUDED=$((EXCLUDED + 1))
        fi
      done

      # Stop daemon and clean up downloaded excluded folders
      kill $DBPID 2>/dev/null; wait $DBPID 2>/dev/null || true
      pkill -f dropboxd 2>/dev/null || true
      sleep 2

      CLEANED=0
      for dir in "${DROPBOX_DIR}"/*/; do
        [[ ! -d "$dir" ]] && continue
        dirname=$(basename "$dir")
        if [[ "$dirname" != "${BRAIN_FOLDER}" ]]; then
          rm -rf "$dir"
          CLEANED=$((CLEANED + 1))
        fi
      done

      ok "Excluded ${EXCLUDED} folder(s), cleaned up ${CLEANED}"
    fi
  fi

  # 1c. Start Dropbox service
  if systemctl is-active --quiet dropbox.service 2>/dev/null; then
    ok "Dropbox service running"
  elif [[ "${VERIFY_ONLY}" == "true" ]]; then
    need "Dropbox service not running"
    ISSUES=$((ISSUES + 1))
  else
    log "Starting Dropbox service..."
    sudo systemctl enable dropbox.service 2>/dev/null || true
    sudo systemctl start dropbox 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet dropbox.service 2>/dev/null; then
      ok "Dropbox service started"
    else
      warn "Dropbox service failed to start"
      ISSUES=$((ISSUES + 1))
    fi
  fi

  echo ""
fi

# =============================================================================
# Step 2: Brain directory and templates
# =============================================================================
STEP_NUM=2
[[ "${FILE_SYNC}" != "dropbox" ]] && STEP_NUM=1

echo -e "${BOLD}Step ${STEP_NUM}: Brain directory${NC}"
echo "────────────────────────────────────────"

# 2a. Brain directory exists
if [[ -d "${BRAIN_DIR}" ]]; then
  ok "Brain directory exists: ${BRAIN_DIR}"
elif [[ "${VERIFY_ONLY}" == "true" ]]; then
  need "Brain directory missing: ${BRAIN_DIR}"
  ISSUES=$((ISSUES + 1))
else
  log "Creating brain directory..."
  mkdir -p "${BRAIN_DIR}"
  ok "Created: ${BRAIN_DIR}"
fi

# 2b. Template files installed
TEMPLATES_INSTALLED=true
for tmpl in tasks.md default-tasks.md personal.md style.md; do
  if [[ ! -f "${BRAIN_DIR}/ai/instructions/${tmpl}" ]]; then
    TEMPLATES_INSTALLED=false
    break
  fi
done
if [[ ! -f "${BRAIN_DIR}/CLAUDE.md" ]]; then
  TEMPLATES_INSTALLED=false
fi

if [[ "${TEMPLATES_INSTALLED}" == "true" ]]; then
  ok "Template files installed"
elif [[ "${VERIFY_ONLY}" == "true" ]]; then
  need "Template files missing"
  ISSUES=$((ISSUES + 1))
else
  if [[ -x "${HOME}/scripts/install-templates.sh" ]]; then
    log "Installing template files..."
    "${HOME}/scripts/install-templates.sh"
    ok "Templates installed"
  else
    warn "install-templates.sh not found"
    ISSUES=$((ISSUES + 1))
  fi
fi

# 2c. Output directories
DIRS_OK=true
for subdir in tasks logs research improvements; do
  if [[ ! -d "${BRAIN_DIR}/${OUTPUT_FOLDER}/${subdir}" ]]; then
    DIRS_OK=false
    break
  fi
done
[[ ! -d "${BRAIN_DIR}/INBOX/_processed" ]] && DIRS_OK=false

if [[ "${DIRS_OK}" == "true" ]]; then
  ok "Output directories exist"
elif [[ "${VERIFY_ONLY}" == "true" ]]; then
  need "Some output directories missing"
  ISSUES=$((ISSUES + 1))
else
  mkdir -p "${BRAIN_DIR}/ai/instructions"
  mkdir -p "${BRAIN_DIR}/INBOX/_processed"
  mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/tasks"
  mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/logs"
  mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/research"
  mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/improvements"
  ok "Output directories created"
fi

echo ""

# =============================================================================
# Step 3: MCP servers
# =============================================================================
STEP_NUM=$((STEP_NUM + 1))
echo -e "${BOLD}Step ${STEP_NUM}: MCP servers${NC}"
echo "────────────────────────────────────────"

# Check existing MCP connections
EXISTING_MCP=""
if command -v claude &>/dev/null; then
  EXISTING_MCP=$(claude mcp list 2>/dev/null || true)
fi

is_connected() {
  echo "${EXISTING_MCP}" | grep -q "${1}.*Connected" 2>/dev/null
}

is_registered() {
  echo "${EXISTING_MCP}" | grep -q "${1}" 2>/dev/null
}

add_mcp_server() {
  local name="$1" url="$2" port="$3"
  claude mcp add-json "$name" "{\"type\":\"http\",\"url\":\"${url}\",\"oauth\":{\"callbackPort\":${port}}}" 2>/dev/null || {
    # Fallback: write directly to ~/.claude.json
    python3 -c "
import json, os
p = os.path.expanduser('~/.claude.json')
try:
    c = json.load(open(p))
except: c = {}
c.setdefault('mcpServers',{})['${name}'] = {'type':'http','url':'${url}','oauth':{'callbackPort':${port}}}
json.dump(c, open(p,'w'), indent=2)
" 2>/dev/null
  }
}

MCP_NEEDS_AUTH=false

# ActingWeb
if [[ "${SETUP_ACTINGWEB}" == "true" ]]; then
  if is_connected "ai.actingweb.io"; then
    ok "ActingWeb: connected"
  elif is_registered "ai.actingweb.io"; then
    need "ActingWeb: registered but needs authentication"
    MCP_NEEDS_AUTH=true
  elif [[ "${VERIFY_ONLY}" == "true" ]]; then
    need "ActingWeb: not configured"
    ISSUES=$((ISSUES + 1))
  else
    log "Registering ActingWeb..."
    add_mcp_server "actingweb" "https://ai.actingweb.io/mcp" 18850
    ok "ActingWeb: registered (needs authentication)"
    MCP_NEEDS_AUTH=true
  fi
fi

# Gmail
if [[ "${SETUP_GMAIL}" == "true" ]]; then
  if is_connected "gmail.mcp.claude.com"; then
    ok "Gmail: connected"
  elif is_registered "gmail.mcp.claude.com"; then
    need "Gmail: registered but needs authentication"
    MCP_NEEDS_AUTH=true
  elif [[ "${VERIFY_ONLY}" == "true" ]]; then
    need "Gmail: not configured"
    ISSUES=$((ISSUES + 1))
  else
    log "Registering Gmail..."
    add_mcp_server "gmail" "https://gmail.mcp.claude.com/mcp" 18851
    ok "Gmail: registered (needs authentication)"
    MCP_NEEDS_AUTH=true
  fi
fi

# Google Calendar
if [[ "${SETUP_GOOGLE_CALENDAR}" == "true" ]]; then
  if is_connected "gcal.mcp.claude.com"; then
    ok "Google Calendar: connected"
  elif is_registered "gcal.mcp.claude.com"; then
    need "Google Calendar: registered but needs authentication"
    MCP_NEEDS_AUTH=true
  elif [[ "${VERIFY_ONLY}" == "true" ]]; then
    need "Google Calendar: not configured"
    ISSUES=$((ISSUES + 1))
  else
    log "Registering Google Calendar..."
    add_mcp_server "google-calendar" "https://gcal.mcp.claude.com/mcp" 18852
    ok "Google Calendar: registered (needs authentication)"
    MCP_NEEDS_AUTH=true
  fi
fi

echo ""

# =============================================================================
# Step 4: Claude Code authentication
# =============================================================================
STEP_NUM=$((STEP_NUM + 1))
echo -e "${BOLD}Step ${STEP_NUM}: Claude Code${NC}"
echo "────────────────────────────────────────"

# Check if Claude Code is authenticated
CLAUDE_AUTH="none"
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  CLAUDE_AUTH="api_key"
  ok "Authentication: API key configured"
elif [[ -f "${HOME}/.claude/.credentials.json" ]] && \
     python3 -c "import json; d=json.load(open('${HOME}/.claude/.credentials.json')); assert d.get('claudeAiOauth',{}).get('accessToken')" 2>/dev/null; then
  CLAUDE_AUTH="account"
  ok "Authentication: account login"
else
  need "Claude Code not authenticated (run 'claude' to log in)"
  ISSUES=$((ISSUES + 1))
fi

# Check settings.json
if [[ -f "${HOME}/.claude/settings.json" ]]; then
  ok "Permissions: settings.json exists"
else
  need "Permissions: settings.json missing"
  ISSUES=$((ISSUES + 1))
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "════════════════════════════════════════"

if [[ "${VERIFY_ONLY}" == "true" ]]; then
  if [[ $ISSUES -eq 0 && "${MCP_NEEDS_AUTH}" == "false" ]]; then
    echo -e "${GREEN}All checks passed.${NC}"
  else
    echo -e "${YELLOW}${ISSUES} issue(s) found.${NC}"
  fi
else
  echo -e "${GREEN}Setup complete.${NC}"
fi

# Show next steps if needed
NEXT_STEPS=false

if [[ "${CLAUDE_AUTH}" == "none" || "${MCP_NEEDS_AUTH}" == "true" ]]; then
  NEXT_STEPS=true
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo ""
  echo "  Make sure you connected with SSH port forwarding:"
  echo "    ./agent-manager.sh --ssh-mcp"
  echo ""
  echo "  Start Claude Code in the brain directory:"
  echo "    cd ${BRAIN_DIR} && claude"
  echo ""

  NEXT_NUM=1
  if [[ "${CLAUDE_AUTH}" == "none" ]]; then
    echo "  ${NEXT_NUM}. Complete Claude Code login (theme + API key or account)"
    NEXT_NUM=$((NEXT_NUM + 1))
  fi

  if [[ "${MCP_NEEDS_AUTH}" == "true" ]]; then
    echo "  ${NEXT_NUM}. Run /mcp and authenticate each server that needs it"
  fi

  echo ""
  echo "  Then /exit and test: ~/scripts/agent-orchestrator.sh --no-stop"
fi

if [[ "${NEXT_STEPS}" == "false" ]]; then
  echo ""
  echo "  Test the agent: ~/scripts/agent-orchestrator.sh --no-stop"
fi

echo ""
