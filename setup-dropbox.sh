#!/usr/bin/env bash
# =============================================================================
# Dropbox Setup — Link account and configure selective sync
# =============================================================================
# Run this on the server after setup.sh to:
#   1. Link the Dropbox account (opens a URL to authorize)
#   2. Configure selective sync so ONLY the brain folder syncs
#   3. Create the brain folder if it doesn't exist
#   4. Install template files
#
# Safe to re-run — skips linking if already linked, re-applies exclusions.
#
# Usage: ~/setup-dropbox.sh
# =============================================================================

set -euo pipefail

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[DROPBOX]${NC} $1"; }
warn() { echo -e "${YELLOW}[NOTE]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Load configuration -----------------------------------------------------
source "${HOME}/.agent-server.conf" 2>/dev/null || true
BRAIN_FOLDER="${BRAIN_FOLDER:-brain}"

DROPBOX_DIR="${HOME}/Dropbox"
BRAIN_DIR="${DROPBOX_DIR}/${BRAIN_FOLDER}"

# =============================================================================
# Step 1: Link account (skip if already linked)
# =============================================================================
if [[ -d "${DROPBOX_DIR}" ]]; then
  log "Dropbox is already linked (~/Dropbox exists)."
else
  log "Linking Dropbox account..."
  echo ""
  echo "============================================================"
  echo "  Dropbox will print a URL. Open it in your browser and"
  echo "  authorize this computer."
  echo ""
  echo "  Ignore the 'load fq extension' and deprecation warnings"
  echo "  — they are normal."
  echo ""
  echo "  The script will continue automatically once linked."
  echo "============================================================"
  echo ""
  read -r -p "Press Enter to start Dropbox linking..."

  # Run dropboxd in background, tail output so the user sees the URL.
  # Automatically detect the "linked" message and stop dropboxd.
  LINK_LOG=$(mktemp /tmp/dropbox-link.XXXXXX)
  "${HOME}/.dropbox-dist/dropboxd" > "${LINK_LOG}" 2>&1 &
  DBPID=$!

  tail -f "${LINK_LOG}" &
  TAILPID=$!

  # Wait for the "linked to Dropbox" message (timeout after 5 minutes)
  LINK_TIMEOUT=300
  LINK_START=$(date +%s)
  LINKED=false
  while true; do
    ELAPSED=$(( $(date +%s) - LINK_START ))
    if [[ $ELAPSED -ge $LINK_TIMEOUT ]]; then
      break
    fi
    if grep -q "linked to Dropbox" "${LINK_LOG}" 2>/dev/null; then
      LINKED=true
      sleep 2  # let any final output appear
      break
    fi
    sleep 1
  done

  # Stop tail and dropboxd
  kill $TAILPID 2>/dev/null; wait $TAILPID 2>/dev/null || true
  kill $DBPID 2>/dev/null; wait $DBPID 2>/dev/null || true
  rm -f "${LINK_LOG}"

  if [[ "${LINKED}" != "true" ]]; then
    err "Dropbox linking timed out after ${LINK_TIMEOUT}s."
    echo "  Try running ~/setup-dropbox.sh again."
    exit 1
  fi

  log "Account linked successfully."
fi

# =============================================================================
# Step 2: Stop Dropbox before configuring exclusions
# =============================================================================
# Exclusions must be applied while Dropbox is running (it's an API call to
# the daemon). But we need to stop it first to prevent it from syncing
# everything, then start it briefly just for the exclude commands, then
# restart cleanly.
log "Stopping Dropbox to configure selective sync..."
sudo systemctl stop dropbox 2>/dev/null || true
# Also kill any stray dropboxd processes
pkill -f dropboxd 2>/dev/null || true
sleep 2

# =============================================================================
# Step 3: Start Dropbox briefly, apply exclusions immediately, then restart
# =============================================================================
log "Starting Dropbox daemon for exclusion configuration..."
"${HOME}/.dropbox-dist/dropboxd" > /dev/null 2>&1 &
DBPID=$!

# Wait for the daemon to be responsive
for i in $(seq 1 15); do
  if dropbox-cli status 2>/dev/null | grep -qv "isn't running"; then
    break
  fi
  sleep 1
done

# Wait for ~/Dropbox to appear
log "Waiting for ~/Dropbox/..."
for i in $(seq 1 30); do
  if [[ -d "${DROPBOX_DIR}" ]]; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    err "~/Dropbox/ did not appear after 30 seconds."
    kill $DBPID 2>/dev/null || true
    exit 1
  fi
  sleep 1
done
log "~/Dropbox/ exists."

# Give Dropbox a moment to populate the top-level folder list
sleep 5

# --- Apply exclusions: exclude everything except brain folder ----------------
log "Configuring selective sync (only syncing '${BRAIN_FOLDER}/')..."

EXCLUDED=0
for dir in "${DROPBOX_DIR}"/*/; do
  [[ ! -d "$dir" ]] && continue
  dirname=$(basename "$dir")
  if [[ "$dirname" != "${BRAIN_FOLDER}" ]]; then
    dropbox-cli exclude add "$dir" >/dev/null 2>&1 || true
    EXCLUDED=$((EXCLUDED + 1))
  fi
done

if [[ $EXCLUDED -gt 0 ]]; then
  log "Excluded ${EXCLUDED} folder(s) from sync."
else
  log "No other folders to exclude."
fi

echo ""
log "Current exclusion list:"
dropbox-cli exclude list 2>/dev/null || warn "Could not list exclusions (dropbox-cli bug — harmless)."
echo ""

# Stop the temporary daemon
log "Stopping temporary daemon..."
kill $DBPID 2>/dev/null; wait $DBPID 2>/dev/null || true
pkill -f dropboxd 2>/dev/null || true
sleep 2

# Clean up any excluded folders that were already synced
log "Cleaning up excluded folders that were already downloaded..."
CLEANED=0
for dir in "${DROPBOX_DIR}"/*/; do
  [[ ! -d "$dir" ]] && continue
  dirname=$(basename "$dir")
  if [[ "$dirname" != "${BRAIN_FOLDER}" ]]; then
    rm -rf "$dir"
    CLEANED=$((CLEANED + 1))
  fi
done
if [[ $CLEANED -gt 0 ]]; then
  log "Removed ${CLEANED} excluded folder(s)."
fi

# =============================================================================
# Step 4: Create brain folder if it doesn't exist
# =============================================================================
if [[ ! -d "${BRAIN_DIR}" ]]; then
  log "Brain folder '${BRAIN_FOLDER}/' not found. Creating it..."
  mkdir -p "${BRAIN_DIR}"
fi

# =============================================================================
# Step 5: Install template files
# =============================================================================
if [[ -x "${HOME}/scripts/install-templates.sh" ]]; then
  log "Installing template files into ${BRAIN_DIR}..."
  "${HOME}/scripts/install-templates.sh"
else
  warn "install-templates.sh not found. Templates not installed."
fi

# =============================================================================
# Step 6: Enable and start Dropbox service (with exclusions applied)
# =============================================================================
log "Starting Dropbox service (with exclusions applied)..."
sudo systemctl enable dropbox.service 2>/dev/null || true
sudo systemctl start dropbox

# Wait briefly and show status
sleep 3
echo ""
log "Dropbox status:"
dropbox-cli status 2>/dev/null || true
echo ""
log "Brain directory: ${BRAIN_DIR}"
if [[ -d "${BRAIN_DIR}" ]]; then
  log "Contents:"
  ls -la "${BRAIN_DIR}/"
fi

echo ""
echo "============================================================"
echo -e "${GREEN} DROPBOX SETUP COMPLETE ${NC}"
echo "============================================================"
echo ""
echo "Only '${BRAIN_FOLDER}/' is syncing. Everything else is excluded."
echo "To check sync status: dropbox-cli status"
echo "To see exclusions:    dropbox-cli exclude list"
echo "============================================================"
