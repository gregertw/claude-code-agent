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
  echo -e "${BOLD}Step 1: Dropbox (via Maestral)${NC}"
  echo "────────────────────────────────────────"

  MAESTRAL_BIN="${HOME}/.local/bin/maestral"

  if ! command -v "${MAESTRAL_BIN}" &>/dev/null; then
    err "Maestral not installed. Run setup.sh first."
    exit 1
  fi

  # 1a. Link account
  MAESTRAL_AUTH=$("${MAESTRAL_BIN}" auth status 2>/dev/null || true)
  if echo "${MAESTRAL_AUTH}" | grep -qi "linked"; then
    LINKED_EMAIL=$(echo "${MAESTRAL_AUTH}" | grep -i "email" | sed 's/.*:[[:space:]]*//')
    ok "Account linked (${LINKED_EMAIL})"
  elif [[ "${VERIFY_ONLY}" == "true" ]]; then
    need "Account not linked"
    ISSUES=$((ISSUES + 1))
  else
    log "Linking Dropbox account..."
    echo ""
    echo "  Maestral will print a URL. Open it in your browser,"
    echo "  authorize the app, then paste the authorization code here."
    echo ""

    "${MAESTRAL_BIN}" auth link
    LINK_EXIT=$?
    if [[ $LINK_EXIT -ne 0 ]]; then
      err "Linking failed (exit code ${LINK_EXIT}). Run ~/agent-setup.sh again to retry."
      exit 1
    fi
    ok "Account linked successfully"
  fi

  # 1b. Configure sync directory
  CURRENT_PATH=$("${MAESTRAL_BIN}" config get path 2>/dev/null || true)
  if [[ -n "${CURRENT_PATH}" && -d "${CURRENT_PATH}" ]]; then
    ok "Sync directory: ${CURRENT_PATH}"
  elif [[ "${VERIFY_ONLY}" == "true" ]]; then
    need "Sync directory not configured"
    ISSUES=$((ISSUES + 1))
  else
    log "Configuring sync directory..."
    # Stop daemon if running (path changes require restart)
    "${MAESTRAL_BIN}" stop 2>/dev/null || true
    sleep 1

    mkdir -p "${DROPBOX_DIR}"
    "${MAESTRAL_BIN}" config set path "${DROPBOX_DIR}"
    ok "Sync directory: ${DROPBOX_DIR}"
  fi

  # 1c. Start Maestral daemon (paused, so it doesn't sync before exclusions are set)
  MAESTRAL_RUNNING=false
  NEEDS_EXCLUSIONS=false
  if "${MAESTRAL_BIN}" status 2>/dev/null | grep -qi "Status:"; then
    MAESTRAL_RUNNING=true
    ok "Maestral daemon running"
  elif [[ "${VERIFY_ONLY}" != "true" ]]; then
    log "Starting Maestral daemon (paused)..."
    "${MAESTRAL_BIN}" start 2>/dev/null || true
    sleep 3
    # Immediately pause to prevent syncing before exclusions are configured
    "${MAESTRAL_BIN}" pause 2>/dev/null || true
    NEEDS_EXCLUSIONS=true

    if "${MAESTRAL_BIN}" status 2>/dev/null | grep -qi "Status:"; then
      MAESTRAL_RUNNING=true
      ok "Maestral started (paused for exclusion setup)"
    else
      warn "Maestral failed to start"
      ISSUES=$((ISSUES + 1))
    fi
  else
    need "Maestral not running"
    ISSUES=$((ISSUES + 1))
  fi

  # 1d. Selective sync — exclude everything except brain folder
  # Uses maestral ls to query remote folders from the server BEFORE syncing them down.
  if [[ "${MAESTRAL_RUNNING}" == "true" ]]; then

    # Get current exclusion list
    EXCLUDED_LIST=$("${MAESTRAL_BIN}" excluded list 2>/dev/null || true)

    # Check if exclusions are already configured
    if echo "${EXCLUDED_LIST}" | grep -qi "excluded" && [[ "${NEEDS_EXCLUSIONS}" == "false" ]]; then
      # "No excluded files or folders." contains "excluded", real entries don't
      # So if grep matches, it means no exclusions exist yet
      NEEDS_EXCLUSIONS=true
    elif [[ "${NEEDS_EXCLUSIONS}" == "false" ]] && echo "${EXCLUDED_LIST}" | grep -q "/"; then
      # Has exclusion entries (paths start with /)
      EXCLUDED_COUNT=$(echo "${EXCLUDED_LIST}" | grep -c "/" || true)
      ok "Selective sync configured (${EXCLUDED_COUNT} folder(s) excluded)"
    fi

    if [[ "${NEEDS_EXCLUSIONS}" == "true" || "${VERIFY_ONLY}" == "true" ]]; then
      # List remote top-level entries (queries Dropbox server, no local sync needed)
      log "Querying Dropbox for folder listing..."
      REMOTE_OUTPUT=$("${MAESTRAL_BIN}" ls 2>&1 || true)
      echo "  Remote folders found:"
      echo "${REMOTE_OUTPUT}" | head -20 | sed 's/^/    /'

      EXCLUDED=0
      ALREADY_EXCLUDED=0
      while IFS= read -r item; do
        # Skip empty lines
        [[ -z "$item" ]] && continue
        # Strip whitespace and trailing slashes
        item=$(echo "$item" | xargs | sed 's/\/$//')
        [[ -z "$item" ]] && continue
        # Skip the brain folder
        [[ "${item,,}" == "${BRAIN_FOLDER,,}" ]] && continue

        if [[ "${VERIFY_ONLY}" == "true" ]]; then
          if ! echo "${EXCLUDED_LIST}" | grep -qi "$item" 2>/dev/null; then
            need "Not excluded: $item"
            ISSUES=$((ISSUES + 1))
          fi
        else
          # Check if already excluded
          if echo "${EXCLUDED_LIST}" | grep -qi "$item" 2>/dev/null; then
            ALREADY_EXCLUDED=$((ALREADY_EXCLUDED + 1))
          else
            if "${MAESTRAL_BIN}" excluded add "$item" 2>&1; then
              EXCLUDED=$((EXCLUDED + 1))
            fi
          fi
        fi
      done <<< "${REMOTE_OUTPUT}"

      if [[ $EXCLUDED -gt 0 ]]; then
        ok "Excluded ${EXCLUDED} folder(s) from sync"
      fi
      if [[ $ALREADY_EXCLUDED -gt 0 ]]; then
        skip "${ALREADY_EXCLUDED} folder(s) already excluded"
      fi
      if [[ $EXCLUDED -eq 0 && $ALREADY_EXCLUDED -eq 0 && "${VERIFY_ONLY}" != "true" ]]; then
        ok "Selective sync configured (only '${BRAIN_FOLDER}/' syncing)"
      fi
    fi
  else
    warn "Skipping selective sync — Maestral not running"
    ISSUES=$((ISSUES + 1))
  fi

  # 1e. Resume sync (if we paused it for exclusion setup)
  if [[ "${MAESTRAL_RUNNING}" == "true" ]]; then
    if "${MAESTRAL_BIN}" status 2>/dev/null | grep -qi "paused"; then
      log "Resuming sync..."
      "${MAESTRAL_BIN}" resume 2>/dev/null || true
      sleep 2
      ok "Sync resumed"
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
# Step 3: Claude Code authentication
# =============================================================================
STEP_NUM=$((STEP_NUM + 1))
echo -e "${BOLD}Step ${STEP_NUM}: Claude Code${NC}"
echo "────────────────────────────────────────"

# Check if Claude Code is authenticated
CLAUDE_AUTH="none"
CLAUDE_INITIALIZED=false
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  CLAUDE_AUTH="api_key"
  CLAUDE_INITIALIZED=true
  ok "Authentication: API key configured"
elif [[ -f "${HOME}/.claude/.credentials.json" ]] && \
     python3 -c "import json; d=json.load(open('${HOME}/.claude/.credentials.json')); assert d.get('claudeAiOauth',{}).get('accessToken')" 2>/dev/null; then
  CLAUDE_AUTH="account"
  CLAUDE_INITIALIZED=true
  ok "Authentication: account login"
else
  need "Claude Code not authenticated"
  need "Run 'claude' to complete initial setup (theme + login), then re-run ~/agent-setup.sh"
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
# Step 4: MCP servers
# =============================================================================
STEP_NUM=$((STEP_NUM + 1))
echo -e "${BOLD}Step ${STEP_NUM}: MCP servers${NC}"
echo "────────────────────────────────────────"

# MCP registration requires Claude Code to be initialized first
if [[ "${CLAUDE_INITIALIZED}" == "false" ]]; then
  warn "Skipping MCP registration — Claude Code must be initialized first."
  echo "  Complete Claude Code login (step above), then re-run ~/agent-setup.sh"
  MCP_NEEDS_AUTH=false
  ISSUES=$((ISSUES + 1))
else

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
  local json_config="{\"type\":\"http\",\"url\":\"${url}\",\"oauth\":{\"callbackPort\":${port}}}"

  if claude mcp add-json "$name" "$json_config" 2>&1; then
    return 0
  fi

  warn "claude mcp add-json failed, trying direct config write..."

  # Fallback: write directly to ~/.claude.json
  python3 -c "
import json, os
p = os.path.expanduser('~/.claude.json')
try:
    c = json.load(open(p))
except:
    c = {}
c.setdefault('mcpServers',{})['${name}'] = {'type':'http','url':'${url}','oauth':{'callbackPort':${port}}}
json.dump(c, open(p,'w'), indent=2)
print('  Written to ' + p)
" || {
    err "Failed to register ${name} MCP server"
    return 1
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

fi  # end CLAUDE_INITIALIZED check

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

NEXT_NUM=1

if [[ "${CLAUDE_AUTH}" == "none" ]]; then
  NEXT_STEPS=true
  echo ""
  echo -e "${BOLD}Next steps:${NC}"
  echo ""
  echo "  ${NEXT_NUM}. Log into Claude Code first:"
  echo "    claude"
  echo "    (Complete theme selection + login, then /exit)"
  NEXT_NUM=$((NEXT_NUM + 1))
  echo ""
  echo "  ${NEXT_NUM}. Re-run this script to register MCP servers:"
  echo "    ~/agent-setup.sh"
  NEXT_NUM=$((NEXT_NUM + 1))
fi

if [[ "${MCP_NEEDS_AUTH}" == "true" ]]; then
  NEXT_STEPS=true
  if [[ "${CLAUDE_AUTH}" != "none" ]]; then
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
  fi
  echo ""
  echo "  ${NEXT_NUM}. Authenticate MCP servers:"
  echo "    cd ${BRAIN_DIR} && claude"
  echo "    Run /mcp and authenticate each server, then /exit"
  NEXT_NUM=$((NEXT_NUM + 1))
fi

echo ""
if [[ "${NEXT_STEPS}" == "true" ]]; then
  echo "  ${NEXT_NUM}. Test the agent: ~/scripts/agent-orchestrator.sh --no-stop"
else
  echo "  Test the agent: ~/scripts/agent-orchestrator.sh --no-stop"
fi

echo ""
