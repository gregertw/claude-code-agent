#!/usr/bin/env bash
# =============================================================================
# agent-setup — Post-deploy setup for the agent server
# =============================================================================
# Run this ON THE SERVER after deploy.sh to complete setup.
# Handles all post-deploy steps in the right order based on agent.conf.
# Safe to re-run — each step checks if it's already done and skips/verifies.
#
# Steps (in order):
#   1. Brain directory: create if missing, install template files
#   2. Claude Code: verify authentication
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

OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
SETUP_ACTINGWEB="${SETUP_ACTINGWEB:-true}"
SETUP_GMAIL="${SETUP_GMAIL:-false}"
SETUP_GOOGLE_CALENDAR="${SETUP_GOOGLE_CALENDAR:-false}"
BRAIN_DIR="${HOME}/brain"

export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/bin:$PATH"

echo ""
echo -e "${BOLD}Agent Server Setup${NC}"
echo "════════════════════════════════════════"
echo ""

# Track overall status
ISSUES=0

# =============================================================================
# Step 1: Brain directory and templates
# =============================================================================
echo -e "${BOLD}Step 1: Brain directory${NC}"
echo "────────────────────────────────────────"

# 1a. Brain directory exists
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

# 1b. Template files installed
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

# 1c. Output directories
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
# Step 2: Claude Code authentication
# =============================================================================
echo -e "${BOLD}Step 2: Claude Code${NC}"
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
# Step 3: MCP servers
# =============================================================================
echo -e "${BOLD}Step 3: MCP servers${NC}"
echo "────────────────────────────────────────"

# MCP registration requires Claude Code to be initialized first
if [[ "${CLAUDE_INITIALIZED}" == "false" ]]; then
  warn "Skipping MCP registration — Claude Code must be initialized first."
  echo "  Complete Claude Code login (step above), then re-run ~/agent-setup.sh"
  MCP_NEEDS_AUTH=false
  ISSUES=$((ISSUES + 1))
else

# Check existing MCP connections — both local and cloud-synced
# Local servers are in mcpServers{}, cloud-synced are in claudeAiMcpEverConnected[]
CLAUDE_JSON="${HOME}/.claude.json"

is_registered_local() {
  # Check if server URL appears in local mcpServers
  python3 -c "
import json, sys
d = json.load(open('${CLAUDE_JSON}'))
for s in d.get('mcpServers', {}).values():
    if '${1}' in s.get('url', ''):
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

is_cloud_synced() {
  # Check if server name appears in claudeAiMcpEverConnected
  python3 -c "
import json, sys
d = json.load(open('${CLAUDE_JSON}'))
for name in d.get('claudeAiMcpEverConnected', []):
    if '${1}'.lower() in name.lower():
        sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# Test if an MCP server actually works by running a minimal Claude prompt.
# Tries both local and cloud-synced tool prefixes.
verify_mcp() {
  local local_prefix="$1"
  local cloud_prefix="$2"
  local test_prompt="$3"
  local result

  # Try with both tool prefixes — one will match depending on how the server is connected
  result=$(cd "${BRAIN_DIR}" && claude -p "${test_prompt}" \
    --max-turns 2 \
    --allowedTools "${local_prefix}" "${cloud_prefix}" \
    --output-format text 2>/dev/null) || return 1

  # Check that the result doesn't contain common error indicators
  if echo "${result}" | grep -qiE "permission denied|not authenticated|failed to connect|error.*mcp|could not|unable to"; then
    return 1
  fi
  return 0
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

# Helper: register if needed (skip if cloud-synced), then verify with a real MCP call
setup_mcp_server() {
  local label="$1" url_pattern="$2" cloud_name="$3" local_name="$4" url="$5" port="$6"
  local local_prefix="$7" cloud_prefix="$8" test_prompt="$9"

  # Check if already available (locally registered or cloud-synced)
  local registered=false
  if is_registered_local "${url_pattern}"; then
    registered=true
  elif is_cloud_synced "${cloud_name}"; then
    registered=true
  fi

  if [[ "${registered}" == "false" ]]; then
    if [[ "${VERIFY_ONLY}" == "true" ]]; then
      need "${label}: not configured"
      ISSUES=$((ISSUES + 1))
      return
    fi
    log "Registering ${label}..."
    add_mcp_server "${local_name}" "${url}" "${port}"
  fi

  # Verify with a real MCP call
  echo -ne "  ${DIM}  verifying ${label}...${NC}\r"
  if verify_mcp "${local_prefix}" "${cloud_prefix}" "${test_prompt}"; then
    ok "${label}: authenticated"
  else
    need "${label}: needs /mcp authentication"
    MCP_NEEDS_AUTH=true
  fi
}

# ActingWeb
if [[ "${SETUP_ACTINGWEB}" == "true" ]]; then
  setup_mcp_server "ActingWeb" "ai.actingweb.io" "Actingweb" \
    "actingweb" "https://ai.actingweb.io/mcp" 18850 \
    "mcp__actingweb" "mcp__claude_ai_Actingweb" \
    "Use the ActingWeb how_to_use tool and return the result."
fi

# Gmail
if [[ "${SETUP_GMAIL}" == "true" ]]; then
  setup_mcp_server "Gmail" "gmail.mcp.claude.com" "Gmail" \
    "gmail" "https://gmail.mcp.claude.com/mcp" 18851 \
    "mcp__gmail" "mcp__claude_ai_Gmail" \
    "Use the Gmail get_profile tool and return the result."
fi

# Google Calendar
if [[ "${SETUP_GOOGLE_CALENDAR}" == "true" ]]; then
  setup_mcp_server "Google Calendar" "gcal.mcp.claude.com" "Google Calendar" \
    "google-calendar" "https://gcal.mcp.claude.com/mcp" 18852 \
    "mcp__google-calendar" "mcp__claude_ai_Google_Calendar" \
    "Use the Google Calendar list_calendars tool and return the result."
fi

fi  # end CLAUDE_INITIALIZED check

echo ""

# =============================================================================
# Summary
# =============================================================================
echo "════════════════════════════════════════"

if [[ $ISSUES -eq 0 && "${MCP_NEEDS_AUTH}" == "false" ]]; then
  echo -e "${GREEN}Setup complete — all checks passed.${NC}"
else
  if [[ "${VERIFY_ONLY}" == "true" ]]; then
    echo -e "${YELLOW}${ISSUES} issue(s) found.${NC}"
  else
    echo -e "${YELLOW}Setup incomplete — see next steps below.${NC}"
  fi
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
  echo "  ${NEXT_NUM}. Test the agent: agent run"
else
  echo "  Test the agent: agent run"
fi

echo ""
