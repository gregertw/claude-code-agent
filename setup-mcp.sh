#!/usr/bin/env bash
# =============================================================================
# MCP Server Setup — Configure Claude Code MCP connections
# =============================================================================
# Run this AFTER the main setup.sh, as the ubuntu user (not root).
#
# This script configures MCP servers so that Claude Code can access:
#   - ActingWeb Personal AI Memory (required — via mcporter + OAuth PKCE)
#   - Gmail (optional — via headless MCP server + Google OAuth tokens)
#   - Google Calendar (optional — via headless MCP server + Google OAuth tokens)
#
# Prerequisites:
#   - Claude Code installed
#   - Node.js installed
#   - mcporter installed (npm install -g mcporter)
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

echo "============================================================"
echo " MCP Server Configuration for Agent Server"
echo "============================================================"
echo ""

# =============================================================================
# 1. ActingWeb Personal AI Memory (via mcporter)
# =============================================================================
if [[ "$FILTER" == "all" || "$FILTER" == "--actingweb" ]]; then

echo "--- ActingWeb Personal AI Memory ---"
echo ""
echo "ActingWeb provides cross-session memory that persists across all your"
echo "AI tools (Claude Code, Cowork, ChatGPT, etc.)."
echo ""
echo "This will:"
echo "  1. Register the ActingWeb MCP server with mcporter"
echo "  2. Run the OAuth flow (you'll open a URL in your browser)"
echo "  3. Configure Claude Code to use mcporter as a proxy"
echo ""

SHOULD_SETUP_AW="${SETUP_ACTINGWEB}"
if [[ "$FILTER" != "--actingweb" && "$SETUP_ACTINGWEB" != "true" ]]; then
  read -r -p "Configure ActingWeb? (y/n): " RESP
  [[ "$RESP" == "y" ]] && SHOULD_SETUP_AW="true"
fi

if [[ "$SHOULD_SETUP_AW" == "true" ]]; then
  # Check mcporter is installed
  if ! command -v mcporter &> /dev/null; then
    err "mcporter not found. Install with: npm install -g mcporter"
    exit 1
  fi

  # Register the ActingWeb server
  log "Registering ActingWeb MCP server with mcporter..."
  mcporter config add actingweb https://ai.actingweb.io/mcp --auth oauth 2>/dev/null || \
    warn "Already registered (continuing)"

  # Try browser auth first
  log "Attempting OAuth authentication..."
  echo ""

  if mcporter auth actingweb 2>/dev/null; then
    log "Authentication succeeded!"
  else
    warn "Browser auth failed (expected on headless server)."
    echo ""
    echo "Using manual OAuth flow."
    echo ""
    echo "------------------------------------------------------------"
    echo "IMPORTANT: The OAuth callback needs to reach this server."
    echo ""
    echo "Open a NEW terminal on your local machine and run:"
    echo ""
    echo "  ssh -L 18850:127.0.0.1:18850 agent"
    echo ""
    echo "This forwards port 18850 so the browser callback works."
    echo "------------------------------------------------------------"
    echo ""
    read -r -p "Press Enter when SSH tunnel is ready..."

    # Look for manual-oauth.sh in multiple locations
    OAUTH_SCRIPT=""
    BRAIN_FOLDER="${BRAIN_FOLDER:-brain}"
    for CANDIDATE in \
      "${HOME}/Dropbox/${BRAIN_FOLDER}/.claude/skills/managing-actingweb-memory/scripts/manual-oauth.sh" \
      "${HOME}/pending-templates/manual-oauth.sh" \
      "./manual-oauth.sh"; do
      if [[ -f "$CANDIDATE" ]]; then
        OAUTH_SCRIPT="$CANDIDATE"
        break
      fi
    done

    if [[ -n "$OAUTH_SCRIPT" ]]; then
      log "Found manual-oauth.sh at: ${OAUTH_SCRIPT}"
      log "Running manual OAuth flow..."
      echo ""
      bash "$OAUTH_SCRIPT"
    else
      warn "manual-oauth.sh not found."
      echo ""
      echo "Run the OAuth flow manually:"
      echo "  1. mcporter auth actingweb --log-level debug"
      echo "  2. Copy the 'visit https://...' URL from the output"
      echo "  3. Open that URL in your browser (with SSH tunnel active)"
      echo "  4. Complete Google sign-in"
      echo ""
      read -r -p "Try mcporter auth with debug output? (y/n): " TRY_DEBUG
      if [[ "$TRY_DEBUG" == "y" ]]; then
        mcporter auth actingweb --log-level debug
      fi
    fi
  fi

  # Verify mcporter connection
  echo ""
  log "Verifying ActingWeb connection..."
  if mcporter list actingweb --schema 2>/dev/null | head -5; then
    log "ActingWeb verified — tools available via mcporter."
  else
    warn "Could not verify. You may need to re-run authentication."
  fi

  # Configure Claude Code to use mcporter as the MCP transport
  log "Adding ActingWeb to Claude Code (via mcporter)..."
  claude mcp add actingweb \
    -- mcporter run actingweb 2>/dev/null || {
    warn "claude mcp add failed. Adding manually to ~/.claude.json..."
    python3 << 'PYEOF'
import json, os, shutil

config_path = os.path.expanduser("~/.claude.json")
try:
    with open(config_path) as f:
        config = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    config = {}

if "mcpServers" not in config:
    config["mcpServers"] = {}

mcporter_path = shutil.which("mcporter") or "mcporter"

config["mcpServers"]["actingweb"] = {
    "type": "stdio",
    "command": mcporter_path,
    "args": ["run", "actingweb"]
}

with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"    Written to {config_path}")
PYEOF
  }
  log "ActingWeb configured for Claude Code."
  echo ""
fi

fi # end actingweb

# =============================================================================
# 2. Gmail + Google Calendar
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
echo "These require Google OAuth credentials."
echo ""
echo "To get them:"
echo "  1. Go to https://console.cloud.google.com"
echo "  2. Create a project (or use existing)"
echo "  3. Enable APIs: Gmail API, Google Calendar API"
echo "  4. Create OAuth 2.0 credentials -> 'Desktop app' type"
echo "  5. Get a refresh token via the OAuth Playground:"
echo ""
echo "     https://developers.google.com/oauthplayground/"
echo ""
echo "     -> Click the gear icon -> check 'Use your own OAuth credentials'"
echo "     -> Paste your Client ID and Client Secret"
echo "     -> In Step 1, select these scopes:"
echo "         Gmail API v1: .../gmail.readonly, .../gmail.compose, .../gmail.modify"
echo "         Calendar API v3: .../calendar, .../calendar.events"
echo "     -> Authorize APIs -> Exchange code for tokens"
echo "     -> Copy the Refresh Token"
echo ""

# Use credentials from agent.conf if present
GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID:-}"
GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET:-}"
GOOGLE_REFRESH_TOKEN="${GOOGLE_REFRESH_TOKEN:-}"

if [[ -z "$GOOGLE_CLIENT_ID" ]]; then
  read -r -p "Google Client ID: " GOOGLE_CLIENT_ID
fi
if [[ -z "$GOOGLE_CLIENT_SECRET" ]]; then
  read -r -s -p "Google Client Secret: " GOOGLE_CLIENT_SECRET
  echo ""
fi
if [[ -z "$GOOGLE_REFRESH_TOKEN" ]]; then
  read -r -s -p "Google Refresh Token: " GOOGLE_REFRESH_TOKEN
  echo ""
fi

# Store credentials securely
cat > "${HOME}/.mcp-google-credentials" << EOF
# Google OAuth credentials for MCP servers
# Generated by setup-mcp.sh on $(date)
GOOGLE_CLIENT_ID=${GOOGLE_CLIENT_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_CLIENT_SECRET}
GOOGLE_REFRESH_TOKEN=${GOOGLE_REFRESH_TOKEN}
EOF
chmod 600 "${HOME}/.mcp-google-credentials"
log "Google credentials saved to ~/.mcp-google-credentials"

# --- Gmail ---
if [[ "$SETUP_GMAIL" == "true" || "$FILTER" == "--google" ]]; then
  log "Adding Gmail MCP server to Claude Code..."
  claude mcp add gmail \
    -e GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID}" \
    -e GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET}" \
    -e GOOGLE_REFRESH_TOKEN="${GOOGLE_REFRESH_TOKEN}" \
    -- npx @peakmojo/mcp-server-headless-gmail 2>/dev/null || {
    warn "claude mcp add failed for Gmail. Adding manually..."
    python3 << PYEOF
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
    "type": "stdio",
    "command": "npx",
    "args": ["@peakmojo/mcp-server-headless-gmail"],
    "env": {
        "GOOGLE_CLIENT_ID": "${GOOGLE_CLIENT_ID}",
        "GOOGLE_CLIENT_SECRET": "${GOOGLE_CLIENT_SECRET}",
        "GOOGLE_REFRESH_TOKEN": "${GOOGLE_REFRESH_TOKEN}"
    }
}
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"    Written to {config_path}")
PYEOF
  }
  log "Gmail configured."
fi

# --- Google Calendar ---
if [[ "$SETUP_GOOGLE_CALENDAR" == "true" || "$FILTER" == "--google" ]]; then
  log "Adding Google Calendar MCP server to Claude Code..."
  claude mcp add google-calendar \
    -e GOOGLE_CLIENT_ID="${GOOGLE_CLIENT_ID}" \
    -e GOOGLE_CLIENT_SECRET="${GOOGLE_CLIENT_SECRET}" \
    -e GOOGLE_REFRESH_TOKEN="${GOOGLE_REFRESH_TOKEN}" \
    -- npx @anthropic/mcp-server-google-calendar 2>/dev/null || {
    warn "claude mcp add failed for Calendar. Adding manually..."
    python3 << PYEOF
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
    "type": "stdio",
    "command": "npx",
    "args": ["@anthropic/mcp-server-google-calendar"],
    "env": {
        "GOOGLE_CLIENT_ID": "${GOOGLE_CLIENT_ID}",
        "GOOGLE_CLIENT_SECRET": "${GOOGLE_CLIENT_SECRET}",
        "GOOGLE_REFRESH_TOKEN": "${GOOGLE_REFRESH_TOKEN}"
    }
}
with open(config_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"    Written to {config_path}")
PYEOF
  }
  log "Google Calendar configured."
fi

echo ""
fi # end want_google

fi # end google

# =============================================================================
# 3. Verify
# =============================================================================
echo ""
echo "============================================================"
echo " MCP Configuration Summary"
echo "============================================================"
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
echo "Credentials:"
echo "  ~/.mcporter/credentials.json       ActingWeb tokens (auto-managed by mcporter)"
echo "  ~/.mcp-google-credentials          Google OAuth (chmod 600)"
echo ""
echo "Token refresh:"
echo "  ActingWeb: auto-refreshes via mcporter"
echo "  Google: tokens may expire after 6 months of inactivity."
echo "          Regenerate via OAuth Playground and re-run:"
echo "          ./setup-mcp.sh --google"
echo "============================================================"
