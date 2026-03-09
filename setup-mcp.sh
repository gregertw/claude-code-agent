#!/usr/bin/env bash
# =============================================================================
# MCP Server Setup — Configure Claude Code MCP connections
# =============================================================================
# Run this AFTER the main setup.sh, as the ubuntu user (not root).
#
# This script configures MCP servers so that Claude Code can access:
#   - ActingWeb Personal AI Memory (required — remote MCP with OAuth)
#   - Gmail (optional — Anthropic hosted connector + Google sign-in)
#   - Google Calendar (optional — Anthropic hosted connector + Google sign-in)
#
# All servers use Claude Code's built-in OAuth support. No external
# dependencies (mcporter, npm, Node.js) are needed.
#
# Prerequisites:
#   - Claude Code installed
#   - agent.conf available (for SETUP_* flags)
#
# Usage:
#   ./setup-mcp.sh              # interactive — follows agent.conf settings
#   ./setup-mcp.sh --actingweb  # just ActingWeb
#   ./setup-mcp.sh --google     # just Gmail + Calendar
# =============================================================================

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[MCP]${NC} $1"; }
warn() { echo -e "${YELLOW}[NOTE]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

FILTER="${1:-all}"

# Load config if available
CONF_FILE="${HOME}/.agent-server.conf"
if [[ -f "${CONF_FILE}" ]]; then
  source "${CONF_FILE}"
fi

SETUP_ACTINGWEB="${SETUP_ACTINGWEB:-true}"
SETUP_GMAIL="${SETUP_GMAIL:-false}"
SETUP_GOOGLE_CALENDAR="${SETUP_GOOGLE_CALENDAR:-false}"

# Check which MCP servers are already connected (e.g. from Claude account)
export PATH="${HOME}/.local/bin:$PATH"
EXISTING_MCP=""
if command -v claude &>/dev/null; then
  EXISTING_MCP=$(claude mcp list 2>/dev/null || true)
fi

# Helper: check if an MCP server URL is already connected
is_connected() {
  local url="$1"
  echo "${EXISTING_MCP}" | grep -q "${url}.*Connected" 2>/dev/null
}

echo "============================================================"
echo " MCP Server Configuration for Agent Server"
echo "============================================================"
echo ""

# =============================================================================
# 1. ActingWeb Personal AI Memory (remote MCP with OAuth)
# =============================================================================
if [[ "$FILTER" == "all" || "$FILTER" == "--actingweb" ]]; then

echo "--- ActingWeb Personal AI Memory ---"
echo ""
echo "ActingWeb provides cross-session memory that persists across all your"
echo "AI tools (Claude Code, Cowork, ChatGPT, etc.)."
echo ""
echo "This will register the ActingWeb remote MCP server with Claude Code."
echo "Authentication is handled via OAuth when you first use it."
echo ""

SHOULD_SETUP_AW="${SETUP_ACTINGWEB}"
if [[ "$FILTER" != "--actingweb" && "$SETUP_ACTINGWEB" != "true" ]]; then
  read -r -p "Configure ActingWeb? (y/n): " RESP
  [[ "$RESP" == "y" ]] && SHOULD_SETUP_AW="true"
fi

if [[ "$SHOULD_SETUP_AW" == "true" ]]; then
  if is_connected "ai.actingweb.io"; then
    log "ActingWeb is already connected (from Claude account). Skipping."
  else
  log "Adding ActingWeb MCP server (remote HTTP with OAuth)..."
  claude mcp add-json actingweb '{"type":"http","url":"https://ai.actingweb.io/mcp","oauth":{"callbackPort":18850}}' 2>/dev/null || {
    warn "claude mcp add-json failed. Adding manually to ~/.claude.json..."
    python3 << 'PYEOF'
import json, os

config_path = os.path.expanduser("~/.claude.json")
try:
    with open(config_path) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

if "mcpServers" not in config:
    config["mcpServers"] = {}

config["mcpServers"]["actingweb"] = {
    "type": "http",
    "url": "https://ai.actingweb.io/mcp",
    "oauth": {"callbackPort": 18850}
}

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"    Written to {config_path}")
PYEOF
  }
  log "ActingWeb configured for Claude Code."
  echo ""
  fi # end is_connected check
fi

fi # end actingweb

# =============================================================================
# 2. Gmail + Google Calendar (Anthropic hosted connectors)
# =============================================================================
if [[ "$FILTER" == "all" || "$FILTER" == "--google" ]]; then

WANT_GOOGLE=false
if [[ "$SETUP_GMAIL" == "true" || "$SETUP_GOOGLE_CALENDAR" == "true" ]]; then
  WANT_GOOGLE=true
elif [[ "$FILTER" == "--google" ]]; then
  WANT_GOOGLE=true
fi

if [[ "$WANT_GOOGLE" == "true" ]]; then

echo "--- Gmail + Google Calendar MCP Servers ---"
echo ""
echo "These use Anthropic's official hosted connectors."
echo "No Google Cloud project or OAuth credentials needed — authentication"
echo "is handled via interactive Google sign-in through Claude Code."
echo ""

# --- Gmail ---
if [[ "$SETUP_GMAIL" == "true" || "$FILTER" == "--google" ]]; then
  if is_connected "gmail.mcp.claude.com"; then
    log "Gmail is already connected (from Claude account). Skipping."
  else
  log "Adding Gmail MCP server (Anthropic hosted connector)..."
  claude mcp add-json gmail '{"type":"http","url":"https://gmail.mcp.claude.com/mcp","oauth":{"callbackPort":18851}}' 2>/dev/null || {
    warn "claude mcp add-json failed for Gmail. Adding manually..."
    python3 << 'PYEOF'
import json, os
config_path = os.path.expanduser("~/.claude.json")
try:
    with open(config_path) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}
if "mcpServers" not in config:
    config["mcpServers"] = {}
config["mcpServers"]["gmail"] = {
    "type": "http",
    "url": "https://gmail.mcp.claude.com/mcp",
    "oauth": {"callbackPort": 18851}
}
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"    Written to {config_path}")
PYEOF
  }
  log "Gmail configured."
  fi # end is_connected check
fi

# --- Google Calendar ---
if [[ "$SETUP_GOOGLE_CALENDAR" == "true" || "$FILTER" == "--google" ]]; then
  if is_connected "gcal.mcp.claude.com"; then
    log "Google Calendar is already connected (from Claude account). Skipping."
  else
  log "Adding Google Calendar MCP server (Anthropic hosted connector)..."
  claude mcp add-json google-calendar '{"type":"http","url":"https://gcal.mcp.claude.com/mcp","oauth":{"callbackPort":18852}}' 2>/dev/null || {
    warn "claude mcp add-json failed for Calendar. Adding manually..."
    python3 << 'PYEOF'
import json, os
config_path = os.path.expanduser("~/.claude.json")
try:
    with open(config_path) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}
if "mcpServers" not in config:
    config["mcpServers"] = {}
config["mcpServers"]["google-calendar"] = {
    "type": "http",
    "url": "https://gcal.mcp.claude.com/mcp",
    "oauth": {"callbackPort": 18852}
}
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"    Written to {config_path}")
PYEOF
  }
  log "Google Calendar configured."
  fi # end is_connected check
fi

echo ""

fi # end want_google

fi # end google

# =============================================================================
# 3. Authenticate and Verify
# =============================================================================
echo ""
echo "============================================================"
echo " MCP Configuration Summary"
echo "============================================================"
echo ""
echo "------------------------------------------------------------"
echo "IMPORTANT: Authenticate MCP servers"
echo ""
echo "The MCP servers are registered but need OAuth authentication."
echo ""
echo "On a local machine:"
echo "  claude"
echo "  /mcp    # select a server, then Authenticate — browser opens"
echo ""
echo "On a headless server (EC2), use SSH tunneling:"
echo ""
echo "  1. Open a NEW terminal on your local machine and run:"
echo ""
echo "     ssh -L 18850:127.0.0.1:18850 -L 18851:127.0.0.1:18851 -L 18852:127.0.0.1:18852 agent"
echo ""
echo "  2. In that session, run:"
echo "     claude"
echo "     /mcp    # select a server, then Authenticate"
echo ""
echo "  3. A browser opens on your local machine for sign-in."
echo "     After sign-in, the callback reaches the server via"
echo "     the SSH tunnel. Repeat /mcp for each server."
echo ""
echo "Each server only needs to be authenticated once — tokens"
echo "are refreshed automatically."
echo "------------------------------------------------------------"
echo ""

if command -v claude &> /dev/null; then
  log "Configured MCP servers:"
  claude mcp list 2>/dev/null || warn "Could not list MCP servers."
fi

echo ""
echo "Quick verification commands:"
echo ""
echo "  # Test ActingWeb"
echo "  echo 'Search my memories for recent' | claude -p"
echo ""
if [[ "${SETUP_GMAIL}" == "true" ]]; then
  echo "  # Test Gmail"
  echo "  echo 'List my 3 most recent unread emails' | claude -p"
  echo ""
fi
if [[ "${SETUP_GOOGLE_CALENDAR}" == "true" ]]; then
  echo "  # Test Calendar"
  echo "  echo 'What is on my calendar today?' | claude -p"
  echo ""
fi
echo "---"
echo ""
echo "If a connection fails:"
echo "  claude mcp list                    # see configured servers"
echo "  claude mcp remove <name>           # remove broken one"
echo "  ./setup-mcp.sh --actingweb         # reconfigure ActingWeb"
echo "  ./setup-mcp.sh --google            # reconfigure Google"
echo ""
echo "Token refresh:"
echo "  All MCP servers use Claude Code's built-in OAuth with auto-refresh."
echo "  If auth expires, re-authenticate with /mcp in Claude Code."
echo "============================================================"
