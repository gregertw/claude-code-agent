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

# --- Check if already linked ------------------------------------------------
if [[ -d "${DROPBOX_DIR}" ]] && dropbox-cli status 2>/dev/null | grep -q "Up to date"; then
  log "Dropbox is already linked and running."
else
  # --- Step 1: Link account --------------------------------------------------
  log "Linking Dropbox account..."
  echo ""
  echo "============================================================"
  echo "  Dropbox will print a URL. Open it in your browser and"
  echo "  authorize this computer."
  echo ""
  echo "  Ignore the 'load fq extension' and deprecation warnings"
  echo "  — they are normal."
  echo ""
  echo "  Wait until you see:"
  echo "    'This computer is now linked to Dropbox. Welcome ...'"
  echo ""
  echo "  Then press Ctrl-C to stop the foreground process."
  echo "============================================================"
  echo ""
  read -r -p "Press Enter to start Dropbox linking..."

  # Run dropboxd in foreground for account linking
  "${HOME}/.dropbox-dist/dropboxd" || true

  echo ""
  log "Starting Dropbox service..."
  sudo systemctl start dropbox
fi

# --- Step 2: Wait for ~/Dropbox to appear -----------------------------------
log "Waiting for Dropbox to create ~/Dropbox/..."
for i in $(seq 1 30); do
  if [[ -d "${DROPBOX_DIR}" ]]; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    err "~/Dropbox/ did not appear after 30 seconds."
    echo "  Check: dropbox-cli status"
    exit 1
  fi
  sleep 1
done
log "~/Dropbox/ exists."

# Give Dropbox a moment to populate the top-level folder list
sleep 3

# --- Step 3: Selective sync — exclude everything except brain ----------------
log "Configuring selective sync (only syncing '${BRAIN_FOLDER}/')..."

EXCLUDED=0
for dir in "${DROPBOX_DIR}"/*/; do
  [[ ! -d "$dir" ]] && continue
  dirname=$(basename "$dir")
  if [[ "$dirname" != "${BRAIN_FOLDER}" ]]; then
    dropbox-cli exclude add "$dir" >/dev/null 2>&1
    EXCLUDED=$((EXCLUDED + 1))
  fi
done

if [[ $EXCLUDED -gt 0 ]]; then
  log "Excluded ${EXCLUDED} folder(s) from sync."
else
  log "No other folders to exclude."
fi

# Show what's being synced
echo ""
log "Current exclusion list:"
dropbox-cli exclude list
echo ""

# --- Step 4: Create brain folder if it doesn't exist -------------------------
if [[ ! -d "${BRAIN_DIR}" ]]; then
  log "Brain folder '${BRAIN_FOLDER}/' not found in Dropbox. Creating it..."
  mkdir -p "${BRAIN_DIR}"
  # Give Dropbox a moment to sync the new folder
  sleep 2
fi

# --- Step 5: Install template files -----------------------------------------
if [[ -x "${HOME}/scripts/install-templates.sh" ]]; then
  log "Installing template files into ${BRAIN_DIR}..."
  "${HOME}/scripts/install-templates.sh"
else
  warn "install-templates.sh not found. Templates not installed."
fi

# --- Step 6: Verify ---------------------------------------------------------
echo ""
log "Dropbox status:"
dropbox-cli status
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
