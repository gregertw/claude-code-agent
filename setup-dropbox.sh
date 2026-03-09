#!/usr/bin/env bash
# =============================================================================
# Dropbox Setup — Optional sync for the brain directory via Maestral
# =============================================================================
# Run this on the server AFTER setup.sh and agent-setup.sh to add Dropbox sync.
# All scripts use ~/brain as the brain directory. This script:
#   1. Installs Maestral (lightweight headless Dropbox client)
#   2. Links your Dropbox account
#   3. Configures selective sync (only the brain folder syncs)
#   4. Handles existing ~/brain content (migrate, skip, or start fresh)
#   5. Symlinks ~/brain → ~/Dropbox/<brain-folder> so all scripts work unchanged
#
# Safe to re-run — each step checks if it's already done.
#
# Usage: ~/setup-dropbox.sh [brain-folder-name]
#   brain-folder-name: Dropbox subfolder to sync (default: "brain")
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

log()  { echo -e "${GREEN}[DROPBOX]${NC} $1"; }
warn() { echo -e "${YELLOW}[NOTE]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }

BRAIN_FOLDER="${1:-brain}"
DROPBOX_DIR="${HOME}/Dropbox"
BRAIN_DROPBOX="${DROPBOX_DIR}/${BRAIN_FOLDER}"
BRAIN_LINK="${HOME}/brain"
MAESTRAL_BIN="${HOME}/.local/bin/maestral"

export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/bin:$PATH"

echo ""
echo -e "${BOLD}Dropbox Sync Setup${NC}"
echo "════════════════════════════════════════"
echo ""
echo "Brain folder in Dropbox: ${BRAIN_FOLDER}/"
echo "Local symlink:           ~/brain → ~/Dropbox/${BRAIN_FOLDER}"
echo ""

# =============================================================================
# Step 1: Install Maestral (if not present)
# =============================================================================
echo -e "${BOLD}Step 1: Maestral${NC}"
echo "────────────────────────────────────────"

if command -v "${MAESTRAL_BIN}" &>/dev/null; then
  ok "Maestral installed: $(${MAESTRAL_BIN} --version 2>/dev/null || echo 'ok')"
else
  log "Installing Maestral (lightweight Dropbox client)..."

  # Install pipx if not present
  if ! command -v pipx &>/dev/null; then
    log "Installing pipx..."
    sudo apt-get install -y -qq pipx 2>/dev/null || {
      pip3 install --user pipx
    }
  fi

  PIPX_HOME="${HOME}/.local/pipx" PIPX_BIN_DIR="${HOME}/.local/bin" pipx install maestral

  if [[ -x "${MAESTRAL_BIN}" ]]; then
    ok "Maestral installed"
  else
    err "Maestral installation failed."
    exit 1
  fi
fi

echo ""

# =============================================================================
# Step 2: Link Dropbox account
# =============================================================================
echo -e "${BOLD}Step 2: Link account${NC}"
echo "────────────────────────────────────────"

MAESTRAL_AUTH=$("${MAESTRAL_BIN}" auth status 2>/dev/null || true)
if echo "${MAESTRAL_AUTH}" | grep -qi "linked"; then
  LINKED_EMAIL=$(echo "${MAESTRAL_AUTH}" | grep -i "email" | sed 's/.*:[[:space:]]*//')
  ok "Account linked (${LINKED_EMAIL})"
else
  log "Linking Dropbox account..."
  echo ""
  echo "  Maestral will print a URL. Open it in your browser,"
  echo "  authorize the app, then paste the authorization code here."
  echo ""

  "${MAESTRAL_BIN}" auth link
  LINK_EXIT=$?
  if [[ $LINK_EXIT -ne 0 ]]; then
    err "Linking failed (exit code ${LINK_EXIT}). Try again."
    exit 1
  fi
  ok "Account linked"
fi

echo ""

# =============================================================================
# Step 3: Configure sync directory and selective sync
# =============================================================================
echo -e "${BOLD}Step 3: Selective sync${NC}"
echo "────────────────────────────────────────"

# 3a. Set sync directory
CURRENT_PATH=$("${MAESTRAL_BIN}" config get path 2>/dev/null || true)
if [[ "${CURRENT_PATH}" == "${DROPBOX_DIR}" ]]; then
  ok "Sync directory: ${DROPBOX_DIR}"
else
  log "Configuring sync directory..."
  "${MAESTRAL_BIN}" stop 2>/dev/null || true
  sleep 1
  mkdir -p "${DROPBOX_DIR}"
  "${MAESTRAL_BIN}" config set path "${DROPBOX_DIR}"
  ok "Sync directory: ${DROPBOX_DIR}"
fi

# 3b. Start daemon (paused) for exclusion setup
MAESTRAL_RUNNING=false
if "${MAESTRAL_BIN}" status 2>/dev/null | grep -qi "^Status"; then
  MAESTRAL_RUNNING=true
  # Pause if running so we can apply exclusions safely
  "${MAESTRAL_BIN}" pause 2>/dev/null || true
  ok "Maestral daemon running (paused for exclusion setup)"
else
  log "Starting Maestral daemon (paused)..."
  "${MAESTRAL_BIN}" start 2>/dev/null || true
  sleep 3
  "${MAESTRAL_BIN}" pause 2>/dev/null || true
  if "${MAESTRAL_BIN}" status 2>/dev/null | grep -qi "^Status"; then
    MAESTRAL_RUNNING=true
    ok "Maestral started (paused)"
  else
    err "Maestral failed to start. Check: maestral status"
    exit 1
  fi
fi

# 3c. Apply exclusions — exclude everything except brain folder
log "Querying Dropbox for folder listing..."
REMOTE_OUTPUT=$("${MAESTRAL_BIN}" ls 2>&1 || true)
echo "  Remote folders found:"
echo "${REMOTE_OUTPUT}" | head -20 | sed 's/^/    /'

EXCLUDED=0
while IFS= read -r item; do
  [[ -z "$item" ]] && continue
  item=$(echo "$item" | xargs | sed 's/\/$//')
  [[ -z "$item" ]] && continue
  # Skip the brain folder — that's the one we want to sync
  [[ "${item,,}" == "${BRAIN_FOLDER,,}" ]] && continue
  if "${MAESTRAL_BIN}" excluded add "$item" 2>/dev/null; then
    EXCLUDED=$((EXCLUDED + 1))
  fi
done <<< "${REMOTE_OUTPUT}"

if [[ $EXCLUDED -gt 0 ]]; then
  ok "Excluded ${EXCLUDED} folder(s) — only '${BRAIN_FOLDER}/' will sync"
else
  ok "Selective sync configured (only '${BRAIN_FOLDER}/' syncing)"
fi

echo ""

# =============================================================================
# Step 4: Handle existing ~/brain content
# =============================================================================
echo -e "${BOLD}Step 4: Brain directory${NC}"
echo "────────────────────────────────────────"

if [[ -L "${BRAIN_LINK}" ]]; then
  # Already a symlink
  LINK_TARGET=$(readlink -f "${BRAIN_LINK}")
  if [[ "${LINK_TARGET}" == "${BRAIN_DROPBOX}" ]]; then
    ok "~/brain is already symlinked to ~/Dropbox/${BRAIN_FOLDER}"
  else
    warn "~/brain is a symlink to ${LINK_TARGET} (expected ${BRAIN_DROPBOX})"
    echo ""
    echo "  Options:"
    echo "    1) Repoint symlink to ~/Dropbox/${BRAIN_FOLDER}"
    echo "    2) Abort — fix manually"
    echo ""
    read -r -p "  Choose [1/2]: " CHOICE
    case "${CHOICE}" in
      1)
        rm "${BRAIN_LINK}"
        ln -s "${BRAIN_DROPBOX}" "${BRAIN_LINK}"
        ok "Symlink updated: ~/brain → ~/Dropbox/${BRAIN_FOLDER}"
        ;;
      *)
        echo "  Aborted. Fix ~/brain manually, then re-run this script."
        exit 1
        ;;
    esac
  fi
elif [[ -d "${BRAIN_LINK}" ]]; then
  # ~/brain is a real directory with content
  BRAIN_FILES=$(find "${BRAIN_LINK}" -type f 2>/dev/null | wc -l | tr -d ' ')
  echo ""
  echo "  ~/brain exists as a directory (${BRAIN_FILES} file(s))."
  echo ""
  echo "  Options:"
  echo "    1) Migrate — move ~/brain content into ~/Dropbox/${BRAIN_FOLDER}, then symlink"
  echo "    2) Skip — don't touch ~/brain content (Dropbox brain already has content)"
  echo "       This will back up ~/brain to ~/brain.bak and create the symlink."
  echo "    3) Abort — do nothing, fix manually"
  echo ""
  read -r -p "  Choose [1/2/3]: " CHOICE
  case "${CHOICE}" in
    1)
      log "Migrating ~/brain → ~/Dropbox/${BRAIN_FOLDER}..."
      mkdir -p "${BRAIN_DROPBOX}"
      # Copy content preserving structure (don't overwrite existing Dropbox files)
      cp -rn "${BRAIN_LINK}/"* "${BRAIN_DROPBOX}/" 2>/dev/null || true
      cp -rn "${BRAIN_LINK}/".[!.]* "${BRAIN_DROPBOX}/" 2>/dev/null || true
      # Back up original and create symlink
      mv "${BRAIN_LINK}" "${BRAIN_LINK}.bak"
      ln -s "${BRAIN_DROPBOX}" "${BRAIN_LINK}"
      ok "Content migrated. Original backed up to ~/brain.bak"
      ok "Symlink: ~/brain → ~/Dropbox/${BRAIN_FOLDER}"
      ;;
    2)
      log "Backing up ~/brain to ~/brain.bak..."
      mv "${BRAIN_LINK}" "${BRAIN_LINK}.bak"
      mkdir -p "${BRAIN_DROPBOX}"
      ln -s "${BRAIN_DROPBOX}" "${BRAIN_LINK}"
      ok "Original backed up to ~/brain.bak"
      ok "Symlink: ~/brain → ~/Dropbox/${BRAIN_FOLDER}"
      ;;
    *)
      echo "  Aborted. Re-run this script when ready."
      exit 1
      ;;
  esac
else
  # ~/brain doesn't exist — create Dropbox folder and symlink
  mkdir -p "${BRAIN_DROPBOX}"
  ln -s "${BRAIN_DROPBOX}" "${BRAIN_LINK}"
  ok "Created: ~/brain → ~/Dropbox/${BRAIN_FOLDER}"
fi

# Ensure brain has the expected directory structure
mkdir -p "${BRAIN_LINK}/ai/instructions" 2>/dev/null || true
mkdir -p "${BRAIN_LINK}/ai/scratchpad" 2>/dev/null || true
mkdir -p "${BRAIN_LINK}/INBOX/_processed" 2>/dev/null || true
mkdir -p "${BRAIN_LINK}/output/tasks" 2>/dev/null || true
mkdir -p "${BRAIN_LINK}/output/logs" 2>/dev/null || true
mkdir -p "${BRAIN_LINK}/output/research" 2>/dev/null || true
mkdir -p "${BRAIN_LINK}/output/improvements" 2>/dev/null || true

echo ""

# =============================================================================
# Step 5: Resume sync
# =============================================================================
echo -e "${BOLD}Step 5: Start sync${NC}"
echo "────────────────────────────────────────"

log "Resuming Maestral sync..."
if ! "${MAESTRAL_BIN}" resume 2>&1; then
  warn "Resume failed, trying stop + start..."
  "${MAESTRAL_BIN}" stop 2>/dev/null || true
  sleep 2
  "${MAESTRAL_BIN}" start 2>/dev/null || true
  sleep 3
fi

SYNC_STATUS=$("${MAESTRAL_BIN}" status 2>/dev/null | grep -i "^Status" | awk '{$1=""; print $0}' | xargs || echo "unknown")
ok "Maestral status: ${SYNC_STATUS}"

echo ""

# =============================================================================
# Step 6: Create systemd user service (optional — for auto-start on boot)
# =============================================================================
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/maestral.service"

if [[ ! -f "${SERVICE_FILE}" ]]; then
  echo -e "${BOLD}Step 6: Auto-start service${NC}"
  echo "────────────────────────────────────────"

  mkdir -p "${SYSTEMD_USER_DIR}"
  cat > "${SERVICE_FILE}" << EOF
[Unit]
Description=Maestral Dropbox Sync
After=network-online.target
Wants=network-online.target

[Service]
Type=notify
ExecStart=${MAESTRAL_BIN} start -f
ExecStop=${MAESTRAL_BIN} stop
WatchdogSec=30
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable maestral.service
  ok "Maestral systemd service installed and enabled"

  # Enable linger so user services start at boot without login
  if command -v loginctl &>/dev/null; then
    sudo loginctl enable-linger "$(whoami)" 2>/dev/null || true
  fi

  echo ""
fi

# =============================================================================
# Summary
# =============================================================================
echo "════════════════════════════════════════"
echo -e "${GREEN}Dropbox sync configured.${NC}"
echo ""
echo "  Brain:      ~/brain → ~/Dropbox/${BRAIN_FOLDER}"
echo "  Sync:       Only '${BRAIN_FOLDER}/' syncs (everything else excluded)"
echo "  Status:     ${SYNC_STATUS}"
echo ""
echo "  Check sync: maestral status"
echo "  View files: ls ~/brain/"
echo "  Exclusions: maestral excluded list"
echo ""
echo "  All agent scripts continue to use ~/brain — no config changes needed."
echo ""
echo "════════════════════════════════════════"
