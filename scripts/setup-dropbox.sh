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

# 3b. Start daemon and pause for exclusion setup
# Maestral must be paused to add excluded folders reliably.
MAESTRAL_RUNNING=false
if "${MAESTRAL_BIN}" status 2>/dev/null | grep -qi "^Status"; then
  MAESTRAL_RUNNING=true
else
  log "Starting Maestral daemon..."
  "${MAESTRAL_BIN}" start 2>/dev/null || true
  sleep 3
  if "${MAESTRAL_BIN}" status 2>/dev/null | grep -qi "^Status"; then
    MAESTRAL_RUNNING=true
  else
    err "Maestral failed to start. Check: maestral status"
    exit 1
  fi
fi

log "Pausing sync for exclusion setup..."
"${MAESTRAL_BIN}" pause 2>/dev/null || true
ok "Maestral paused"

# 3c. Apply exclusions — exclude everything except brain folder
# Use `maestral ls -l` to get folder names with their sync status, then only
# add exclusions for folders currently marked as syncing (✓).
log "Querying Dropbox for folder listing..."
LS_OUTPUT=$("${MAESTRAL_BIN}" ls -l 2>&1 || true)
echo "  Dropbox root contents:"
echo "${LS_OUTPUT}" | sed 's/^/    /'
echo ""

EXCLUDED=0
ALREADY_EXCLUDED=0
# Parse `maestral ls -l` output. Columns: Name, Type, Size, Shared, Syncing, Last Modified
# Skip the header line and any blank lines. We look for "folder" type entries.
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  # Skip the header and separator lines
  [[ "$line" =~ ^Name ]] && continue
  [[ "$line" =~ ^-+$ ]] && continue

  # Extract folder name (first column — everything before two or more spaces)
  folder_name=$(echo "$line" | sed 's/  .*//' | xargs)
  [[ -z "$folder_name" ]] && continue

  # Only process folders
  echo "$line" | grep -q "folder" || continue

  # Skip the brain folder — that's the one we want to sync
  [[ "${folder_name,,}" == "${BRAIN_FOLDER,,}" ]] && continue

  # Check sync status — skip folders already excluded
  if echo "$line" | grep -q "excluded"; then
    ALREADY_EXCLUDED=$((ALREADY_EXCLUDED + 1))
    continue
  fi

  # Exclude this folder
  if "${MAESTRAL_BIN}" excluded add "${folder_name}" 2>/dev/null; then
    ok "Excluded: ${folder_name}"
    EXCLUDED=$((EXCLUDED + 1))
  fi
done <<< "${LS_OUTPUT}"

if [[ $EXCLUDED -gt 0 ]]; then
  ok "Excluded ${EXCLUDED} new folder(s)"
fi
if [[ $ALREADY_EXCLUDED -gt 0 ]]; then
  ok "${ALREADY_EXCLUDED} folder(s) were already excluded"
fi
ok "Only '${BRAIN_FOLDER}/' will sync"

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

# Wait for initial sync to complete — the brain folder needs to be fully
# downloaded before the agent can run. Show progress so the user knows
# what's happening.
echo ""
log "Waiting for initial sync to complete..."
echo "  This downloads your '${BRAIN_FOLDER}/' folder from Dropbox."
echo "  Duration depends on folder size and connection speed."
echo ""

SYNC_TIMEOUT=300
SYNC_WAIT=0
LAST_STATUS=""
while [[ ${SYNC_WAIT} -lt ${SYNC_TIMEOUT} ]]; do
  SYNC_STATUS=$("${MAESTRAL_BIN}" status 2>/dev/null | grep -i "^Status" | sed 's/^[^:]*:[[:space:]]*//' || echo "unknown")
  if echo "${SYNC_STATUS}" | grep -qi "up to date\|idle"; then
    break
  fi
  # Only print when status changes to avoid spam
  if [[ "${SYNC_STATUS}" != "${LAST_STATUS}" ]]; then
    echo "  Status: ${SYNC_STATUS}"
    LAST_STATUS="${SYNC_STATUS}"
  fi
  sleep 5
  SYNC_WAIT=$((SYNC_WAIT + 5))
  # Print a dot every 30s as a heartbeat
  if (( SYNC_WAIT % 30 == 0 )); then
    echo "  ... still syncing (${SYNC_WAIT}s elapsed)"
  fi
done

if [[ ${SYNC_WAIT} -ge ${SYNC_TIMEOUT} ]]; then
  warn "Sync did not complete within ${SYNC_TIMEOUT}s."
  echo "  Maestral is still syncing in the background."
  echo "  Check progress with: maestral status"
else
  ok "Initial sync complete (${SYNC_WAIT}s)."
fi

SYNC_STATUS=$("${MAESTRAL_BIN}" status 2>/dev/null | grep -i "^Status" | sed 's/^[^:]*:[[:space:]]*//' || echo "unknown")
echo ""

# =============================================================================
# Step 6: Install systemd user service (used in always-on mode)
# =============================================================================
# The service file is always installed but only enabled in always-on mode.
# In scheduled mode, the orchestrator starts/stops Maestral per-run instead.
# The set-schedule-mode.sh script handles enabling/disabling this service.
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
SERVICE_FILE="${SYSTEMD_USER_DIR}/maestral.service"

echo -e "${BOLD}Step 6: Systemd service${NC}"
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

# Enable linger so user services start at boot without login
if command -v loginctl &>/dev/null; then
  sudo loginctl enable-linger "$(whoami)" 2>/dev/null || true
fi

# Don't enable by default — set-schedule-mode.sh manages this based on mode.
# In scheduled mode: orchestrator starts/stops Maestral per-run.
# In always-on mode: this service runs continuously.
ok "Maestral service installed (enable via set-schedule-mode.sh)"
echo ""

# =============================================================================
# Summary
# =============================================================================

# Load schedule mode to give relevant guidance
source "${HOME}/.agent-server.conf" 2>/dev/null || true
source "${HOME}/.agent-schedule" 2>/dev/null || true

echo "════════════════════════════════════════"
echo -e "${GREEN}Dropbox sync configured.${NC}"
echo ""
echo "  Brain:      ~/brain → ~/Dropbox/${BRAIN_FOLDER}"
echo "  Sync:       Only '${BRAIN_FOLDER}/' syncs (everything else excluded)"
echo "  Status:     ${SYNC_STATUS}"
echo ""
echo -e "${BOLD}How sync works:${NC}"
if [[ "${SCHEDULE_MODE:-always-on}" == "scheduled" ]]; then
  echo "  You are in scheduled mode. The orchestrator handles Maestral:"
  echo "    - Starts Maestral and waits for sync before each agent run"
  echo "    - Waits for uploads to complete after the run"
  echo "    - Stops Maestral before hibernating"
  echo "  The server will not sleep until Dropbox sync is done."
else
  echo "  You are in always-on mode. Maestral runs continuously"
  echo "  as a systemd service — files sync automatically."
fi
echo ""
echo -e "${BOLD}Useful commands:${NC}"
echo "  maestral status           Show sync status"
echo "  maestral filestatus FILE  Check a specific file"
echo "  ls ~/brain/               View synced files"
echo "  maestral excluded list    Show excluded folders"
echo ""
echo "  All agent scripts continue to use ~/brain — no config changes needed."
echo ""
echo "════════════════════════════════════════"
