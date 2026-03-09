#!/usr/bin/env bash
# =============================================================================
# AWS Ubuntu Agent Server — Bootstrap Script
# =============================================================================
# Run this on a fresh Ubuntu 24.04 LTS EC2 instance:
#   chmod +x setup.sh && sudo ./setup.sh
#
# Reads configuration from agent.conf in the same directory.
# After running, complete the manual steps printed at the end.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/agent.conf"

# --- Load configuration ------------------------------------------------------
if [[ ! -f "${CONF_FILE}" ]]; then
  echo "ERROR: agent.conf not found in ${SCRIPT_DIR}"
  echo "Copy agent.conf.example to agent.conf and fill in your values."
  exit 1
fi

source "${CONF_FILE}"

# Validate required fields
if [[ -z "${OWNER_NAME:-}" || "${OWNER_NAME}" == "Your Name" ]]; then
  echo "ERROR: Set OWNER_NAME in agent.conf before running setup."
  exit 1
fi

# Apply defaults for optional fields
SCHEDULE_MODE="${SCHEDULE_MODE:-always-on}"
SCHEDULE_INTERVAL="${SCHEDULE_INTERVAL:-60}"
FILE_SYNC="${FILE_SYNC:-dropbox}"
INSTALL_TTYD="${INSTALL_TTYD:-false}"
TTYD_USER="${TTYD_USER:-agent}"
TTYD_PASSWORD="${TTYD_PASSWORD:-changeme}"
UBUNTU_USER="${UBUNTU_USER:-ubuntu}"
BRAIN_FOLDER="${BRAIN_FOLDER:-brain}"
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
HOME_DIR="/home/${UBUNTU_USER}"

# Derive brain directory path based on sync mode
if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  BRAIN_DIR="${HOME_DIR}/Dropbox/${BRAIN_FOLDER}"
else
  BRAIN_DIR="${HOME_DIR}/brain"
fi

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[SETUP]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Pre-flight checks -------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root (use sudo)."
  exit 1
fi

log "Starting agent server bootstrap on $(hostname)..."
log "Owner: ${OWNER_NAME}"
log "Target user: ${UBUNTU_USER}"
log "Schedule mode: ${SCHEDULE_MODE}"
log "File sync: ${FILE_SYNC}"
log "Brain directory: ${BRAIN_DIR}"

# --- 1. System Update --------------------------------------------------------
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

# --- 2. Core System Packages -------------------------------------------------
log "Installing core packages..."
apt-get install -y -qq \
  build-essential \
  curl \
  wget \
  git \
  tmux \
  htop \
  jq \
  ripgrep \
  tree \
  unzip \
  zip \
  ca-certificates \
  gnupg \
  lsb-release \
  software-properties-common \
  python3 \
  python3-pip \
  python3-venv \
  apt-transport-https \
  fail2ban \
  ufw \
  unattended-upgrades \
  apt-listchanges

# Install AWS CLI v2 (not available via apt on Ubuntu 24.04)
log "Installing AWS CLI v2..."
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
unzip -qo /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/awscliv2.zip /tmp/aws

# --- 3. Firewall (UFW) -------------------------------------------------------
log "Configuring firewall..."
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
if [[ "${INSTALL_TTYD}" == "true" ]]; then
  ufw allow 443/tcp comment 'ttyd web terminal (HTTPS)'
fi
ufw --force enable
log "Firewall enabled — SSH allowed."

# --- 4. Fail2ban -------------------------------------------------------------
log "Configuring fail2ban..."
cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
bantime = 3600
findtime = 600
EOF
systemctl enable fail2ban
systemctl restart fail2ban
log "Fail2ban configured for SSH."

# --- 5. Automatic Security Updates -------------------------------------------
log "Configuring unattended-upgrades..."
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
log "Automatic security updates enabled."

# --- 6. SSH Hardening --------------------------------------------------------
log "Hardening SSH..."
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart ssh
log "SSH hardened — password auth disabled, root login disabled."

# --- 7. (Node.js removed — install manually if needed for MCP servers) -------

# --- 7b. Glow (terminal markdown renderer) -----------------------------------
log "Installing glow (terminal markdown renderer)..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
  > /etc/apt/sources.list.d/charm.list
apt-get update -qq
apt-get install -y -qq glow
log "glow $(glow --version 2>/dev/null || echo 'installed')."

# --- 8. Python tooling (uv) --------------------------------------------------
log "Installing uv (fast Python package manager)..."
sudo -u "${UBUNTU_USER}" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
log "uv installed."

# --- 9. Claude Code CLI ------------------------------------------------------
log "Installing Claude Code..."
sudo -u "${UBUNTU_USER}" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
log "Claude Code installed."


# --- 11. Maestral Dropbox Client (optional) -----------------------------------
if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  log "Installing Maestral (lightweight Dropbox client)..."

  # Install pipx if not present, then install Maestral
  apt-get install -y -qq pipx
  sudo -u "${UBUNTU_USER}" bash -c 'PIPX_HOME="${HOME}/.local/pipx" PIPX_BIN_DIR="${HOME}/.local/bin" pipx install maestral'

  # Verify installation
  MAESTRAL_BIN="${HOME_DIR}/.local/bin/maestral"
  if [[ -x "${MAESTRAL_BIN}" ]]; then
    log "Maestral installed: $(sudo -u "${UBUNTU_USER}" "${MAESTRAL_BIN}" --version 2>/dev/null || echo 'ok')"
  else
    err "Maestral installation failed. Check pipx output above."
    exit 1
  fi

  # Enable linger so the user's systemd services start at boot
  loginctl enable-linger "${UBUNTU_USER}"

  # Create systemd user service for Maestral
  SYSTEMD_USER_DIR="${HOME_DIR}/.config/systemd/user"
  sudo -u "${UBUNTU_USER}" mkdir -p "${SYSTEMD_USER_DIR}"
  cat > "${SYSTEMD_USER_DIR}/maestral.service" << EOF
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
  chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/.config/systemd"

  # NOTE: Do not enable/start service here — it needs account linking first.
  # The agent-setup.sh script will link, configure selective sync, and start it.

  log "Maestral installed (not started — requires account linking)."
  log "Run ~/agent-setup.sh to link, configure selective sync, and install templates."
else
  log "File sync: none. Brain directory will be local at ${BRAIN_DIR}"
  # Create the local brain directory structure
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/ai/instructions"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/ai/scratchpad"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/INBOX/_processed"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/tasks"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/logs"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/research"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/improvements"
fi

# --- 12. ttyd Web Terminal (optional) ----------------------------------------
if [[ "${INSTALL_TTYD}" == "true" ]]; then
  log "Installing ttyd (web terminal)..."

  # Download latest ttyd binary
  TTYD_VERSION="1.7.7"
  ARCH=$(uname -m)
  if [[ "$ARCH" == "x86_64" ]]; then
    TTYD_ARCH="x86_64"
  elif [[ "$ARCH" == "aarch64" ]]; then
    TTYD_ARCH="aarch64"
  else
    warn "Unsupported architecture ${ARCH} for ttyd. Skipping."
    INSTALL_TTYD=false
  fi

  if [[ "${INSTALL_TTYD}" == "true" ]]; then
    wget -q "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${TTYD_ARCH}" \
      -O /usr/local/bin/ttyd
    chmod +x /usr/local/bin/ttyd

    # Validate credentials
    if [[ "${TTYD_PASSWORD}" == "changeme" ]]; then
      err "TTYD_PASSWORD is still 'changeme'. Set a secure password in agent.conf before deploying."
      exit 1
    fi

    # Generate self-signed TLS certificate for HTTPS
    TTYD_CERT_DIR="${HOME_DIR}/.ttyd-certs"
    mkdir -p "${TTYD_CERT_DIR}"
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${TTYD_CERT_DIR}/key.pem" \
      -out "${TTYD_CERT_DIR}/cert.pem" \
      -days 3650 \
      -subj "/CN=agent-server" 2>/dev/null
    chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${TTYD_CERT_DIR}"
    chmod 600 "${TTYD_CERT_DIR}/key.pem"
    log "Self-signed TLS certificate generated (valid 10 years)."

    # Create systemd service for ttyd with HTTPS on port 443
    cat > /etc/systemd/system/ttyd.service << EOF
[Unit]
Description=ttyd Web Terminal (HTTPS)
After=network-online.target
Wants=network-online.target

[Service]
User=root
Group=root
Type=simple
ExecStart=/usr/local/bin/ttyd --port 443 --ssl --ssl-cert ${TTYD_CERT_DIR}/cert.pem --ssl-key ${TTYD_CERT_DIR}/key.pem --credential ${TTYD_USER}:${TTYD_PASSWORD} --uid $(id -u ${UBUNTU_USER}) --gid $(id -g ${UBUNTU_USER}) --writable bash --login
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ttyd.service
    log "ttyd installed and running on port 443 (HTTPS with self-signed cert)."
    log "Access at: https://<your-ip> (user: ${TTYD_USER})"
  fi
fi

# --- 13. Environment Setup ---------------------------------------------------
log "Setting up environment..."

# Create .env file for API keys
cat > "${HOME_DIR}/.agent-env" << 'EOF'
# Agent Server Environment Variables
# Fill in your keys after setup, then run: source ~/.agent-env

# Claude Code — API key from console.anthropic.com
export ANTHROPIC_API_KEY=""

# Optional: override Claude model
# export CLAUDE_MODEL="claude-sonnet-4-6"
EOF
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/.agent-env"
chmod 600 "${HOME_DIR}/.agent-env"

# Copy agent.conf to home directory for scripts to find
cp "${CONF_FILE}" "${HOME_DIR}/.agent-server.conf"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/.agent-server.conf"

# Create schedule mode config file
cat > "${HOME_DIR}/.agent-schedule" << EOF
# Agent Server Schedule Mode
SCHEDULE_MODE="${SCHEDULE_MODE}"
SCHEDULE_INTERVAL="${SCHEDULE_INTERVAL}"
EOF
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/.agent-schedule"

# Add to bashrc (idempotent — check sentinel first)
BASHRC_SENTINEL="# --- Agent Server Config ---"
if ! grep -qF "${BASHRC_SENTINEL}" "${HOME_DIR}/.bashrc" 2>/dev/null; then
  cat >> "${HOME_DIR}/.bashrc" << 'BASHRC'

# --- Agent Server Config ---
# Load API keys
if [[ -f ~/.agent-env ]]; then
  source ~/.agent-env
fi

# Load schedule config
if [[ -f ~/.agent-schedule ]]; then
  source ~/.agent-schedule
fi

# Aliases
alias ll='ls -lah'

# Path additions
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# tmux: auto-attach or create session on SSH login (skip for ttyd)
if [[ -z "${TMUX:-}" ]] && [[ -n "${SSH_CONNECTION:-}" ]]; then
  tmux attach-session -t main 2>/dev/null || tmux new-session -s main
fi
BASHRC

  chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/.bashrc"
  log "Bashrc updated."
else
  log "Bashrc already configured (skipping)."
fi

# Create working directories
sudo -u "${UBUNTU_USER}" mkdir -p "${HOME_DIR}/agents"
sudo -u "${UBUNTU_USER}" mkdir -p "${HOME_DIR}/scripts"
sudo -u "${UBUNTU_USER}" mkdir -p "${HOME_DIR}/logs"

log "Environment configured."

# Add MOTD to .profile (runs on login for both SSH and ttyd)
PROFILE_SENTINEL="# --- Agent MOTD ---"
if ! grep -qF "${PROFILE_SENTINEL}" "${HOME_DIR}/.profile" 2>/dev/null; then
  cat >> "${HOME_DIR}/.profile" << 'PROFILE_MOTD'

# --- Agent MOTD ---
# Show agent status on login (works for ttyd and SSH)
if [[ -z "${AGENT_MOTD_SHOWN:-}" ]]; then
  export AGENT_MOTD_SHOWN=1
  run-parts /etc/update-motd.d/ 2>/dev/null
fi
PROFILE_MOTD
  chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/.profile"
  log "MOTD added to .profile."
fi

# --- 16. Claude Code Settings ------------------------------------------------
log "Configuring Claude Code permissions for autonomous mode..."
CLAUDE_SETTINGS_DIR="${HOME_DIR}/.claude"
sudo -u "${UBUNTU_USER}" mkdir -p "${CLAUDE_SETTINGS_DIR}"

sudo -u "${UBUNTU_USER}" tee "${CLAUDE_SETTINGS_DIR}/settings.json" > /dev/null << 'SETTINGS'
{
  "permissions": {
    "allow": [
      "mcp__actingweb",
      "mcp__gmail",
      "mcp__google-calendar",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
      "Bash(maestral *)",
      "Bash(cat *)",
      "Bash(mkdir *)",
      "Bash(mv *)",
      "Bash(ls *)",
      "Bash(date *)",
      "WebSearch",
      "WebFetch"
    ],
    "deny": []
  }
}
SETTINGS
log "Claude Code permissions configured."

# --- 17. Agent Orchestrator --------------------------------------------------
log "Installing agent orchestrator..."
if [[ -f "${SCRIPT_DIR}/agent-orchestrator.sh" ]]; then
  cp "${SCRIPT_DIR}/agent-orchestrator.sh" "${HOME_DIR}/scripts/agent-orchestrator.sh"
  log "Orchestrator copied to ~/scripts/"
else
  warn "agent-orchestrator.sh not found in ${SCRIPT_DIR}. Upload it manually to ~/scripts/"
fi
chmod +x "${HOME_DIR}/scripts/agent-orchestrator.sh" 2>/dev/null || true
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/agent-orchestrator.sh" 2>/dev/null || true

# Create agent runner helper
log "Creating agent runner helper script..."
cat > "${HOME_DIR}/scripts/run-agent.sh" << 'AGENT_SCRIPT'
#!/usr/bin/env bash
# Run a Claude Code agent task with logging
# Usage: ./run-agent.sh "Your prompt here" [working-directory]

set -euo pipefail

PROMPT="${1:?Usage: run-agent.sh \"prompt\" [working-dir]}"
WORKDIR="${2:-$HOME/agents}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOGFILE="$HOME/logs/agent-${TIMESTAMP}.log"

[[ -z "${ANTHROPIC_API_KEY:-}" ]] && source ~/.agent-env 2>/dev/null

echo "[$(date)] Starting agent in ${WORKDIR}" | tee -a "${LOGFILE}"
echo "[$(date)] Prompt: ${PROMPT}" | tee -a "${LOGFILE}"

cd "${WORKDIR}"
claude -p "${PROMPT}" --max-turns 50 2>&1 | tee -a "${LOGFILE}"

echo "[$(date)] Agent finished." | tee -a "${LOGFILE}"
AGENT_SCRIPT

chmod +x "${HOME_DIR}/scripts/run-agent.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/run-agent.sh"

# Create systemd service for agent orchestrator
# Network dependency only — Maestral runs as a user service which
# system services cannot depend on. The orchestrator script handles
# checking/starting Maestral itself.
AFTER_DEPS="After=network-online.target"
WANTS_DEPS="Wants=network-online.target"

cat > /etc/systemd/system/agent-boot-runner.service << EOF
[Unit]
Description=Agent Orchestrator — runs tasks on boot
${AFTER_DEPS}
${WANTS_DEPS}

[Service]
Type=oneshot
User=${UBUNTU_USER}
Group=${UBUNTU_USER}
ExecStart=${HOME_DIR}/scripts/agent-orchestrator.sh
Environment=HOME=${HOME_DIR}
TimeoutStartSec=900
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
if [[ "${SCHEDULE_MODE}" == "scheduled" ]]; then
  systemctl enable agent-boot-runner.service
  log "Boot runner ENABLED (scheduled mode)."
else
  systemctl disable agent-boot-runner.service
  log "Boot runner DISABLED (always-on mode)."
fi

# --- 18. Schedule Mode Toggle Script ----------------------------------------
log "Creating schedule mode toggle..."
cat > "${HOME_DIR}/scripts/set-schedule-mode.sh" << 'TOGGLE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

MODE="${1:?Usage: set-schedule-mode.sh <always-on|scheduled>}"
HOME_DIR="/home/ubuntu"

if [[ "$MODE" != "always-on" && "$MODE" != "scheduled" ]]; then
  echo "ERROR: Mode must be 'always-on' or 'scheduled'"
  exit 1
fi

sed -i "s/^SCHEDULE_MODE=.*/SCHEDULE_MODE=\"${MODE}\"/" "${HOME_DIR}/.agent-schedule"

if [[ "$MODE" == "scheduled" ]]; then
  systemctl enable agent-boot-runner.service
  echo "Switched to SCHEDULED mode."
  echo "  Instance will run tasks at boot and then stop itself."
  echo "  Use ./agent-manager.sh --scheduled from your local machine to set up EventBridge."
  echo "  To prevent self-stop during SSH: touch ~/agents/.keep-running"
else
  systemctl disable agent-boot-runner.service
  echo "Switched to ALWAYS-ON mode."
  echo "  Instance runs 24/7. Boot runner disabled."
fi

echo ""
cat "${HOME_DIR}/.agent-schedule"
TOGGLE_SCRIPT

chmod +x "${HOME_DIR}/scripts/set-schedule-mode.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/set-schedule-mode.sh"

# --- 19. Agent README -------------------------------------------------------
log "Setting up agent infrastructure..."
cat > "${HOME_DIR}/agents/README.md" << EOF
# Agent Server — ${OWNER_NAME}

## Brain directory: ${BRAIN_DIR}

## Manual run
  ~/scripts/agent-orchestrator.sh              # full run (may self-stop)
  ~/scripts/agent-orchestrator.sh --no-stop    # full run, stays on

## Task Inbox
Drop .txt or .md files in: ${BRAIN_DIR}/INBOX/

## Preventing self-stop (for debugging)
  touch ~/agents/.keep-running
  rm ~/agents/.keep-running
EOF

chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/agents"

# --- 19b. Agent CLI Helper ---------------------------------------------------
log "Installing agent CLI helper..."
if [[ -f "${SCRIPT_DIR}/agent-cli.sh" ]]; then
  cp "${SCRIPT_DIR}/agent-cli.sh" "${HOME_DIR}/scripts/agent-cli.sh"
  chmod +x "${HOME_DIR}/scripts/agent-cli.sh"
  chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/agent-cli.sh"
  # Install as a copy (not symlink) so permissions are independent
  cp "${HOME_DIR}/scripts/agent-cli.sh" /usr/local/bin/agent
  chmod +x /usr/local/bin/agent
  log "Agent CLI installed. Use: agent status, agent run, agent logs, etc."
else
  warn "agent-cli.sh not found in ${SCRIPT_DIR}. Upload it manually."
fi

# --- 19c. Login Banner (MOTD) -----------------------------------------------
log "Setting up login banner..."

# Disable default Ubuntu MOTD noise
chmod -x /etc/update-motd.d/* 2>/dev/null || true

# Create custom MOTD script
cat > /etc/update-motd.d/99-agent-status << 'MOTD_SCRIPT'
#!/usr/bin/env bash
# Agent server login banner

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

HOME_DIR="/home/ubuntu"
source "${HOME_DIR}/.agent-server.conf" 2>/dev/null || true
source "${HOME_DIR}/.agent-schedule" 2>/dev/null || true

FILE_SYNC="${FILE_SYNC:-none}"
BRAIN_FOLDER="${BRAIN_FOLDER:-brain}"
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
OWNER_NAME="${OWNER_NAME:-Agent}"

if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  BRAIN_DIR="${HOME_DIR}/Dropbox/${BRAIN_FOLDER}"
else
  BRAIN_DIR="${HOME_DIR}/brain"
fi
OUTPUT_DIR="${BRAIN_DIR}/${OUTPUT_FOLDER}"

echo ""
echo -e "${BOLD}  ┌──────────────────────────────────┐${NC}"
echo -e "${BOLD}  │      Agent Server — ${OWNER_NAME}${NC}"
echo -e "${BOLD}  └──────────────────────────────────┘${NC}"
echo ""

# Mode
MODE="${SCHEDULE_MODE:-unknown}"
if [[ "$MODE" == "scheduled" ]]; then
  echo -e "  Mode:     ${CYAN}scheduled${NC} (every ${SCHEDULE_INTERVAL:-60} min)"
else
  echo -e "  Mode:     ${CYAN}${MODE}${NC}"
fi

# Last run
HB="${OUTPUT_DIR}/.agent-heartbeat"
if [[ -f "$HB" ]]; then
  LAST_RUN=$(grep '^last_run=' "$HB" | cut -d= -f2)
  EXIT_CODE=$(grep '^exit_code=' "$HB" | cut -d= -f2)
  AGO=""
  if [[ -n "$LAST_RUN" ]]; then
    TS=$(date -d "$LAST_RUN" +%s 2>/dev/null || echo "")
    if [[ -n "$TS" ]]; then
      NOW=$(date +%s)
      DIFF=$(( NOW - TS ))
      if (( DIFF < 60 )); then AGO="${DIFF}s ago"
      elif (( DIFF < 3600 )); then AGO="$(( DIFF / 60 ))m ago"
      elif (( DIFF < 86400 )); then AGO="$(( DIFF / 3600 ))h ago"
      else AGO="$(( DIFF / 86400 ))d ago"
      fi
    fi
  fi
  if [[ "$EXIT_CODE" == "0" ]]; then
    echo -e "  Last run: ${GREEN}${AGO}${NC} (exit 0)"
  else
    echo -e "  Last run: ${RED}${AGO}${NC} (exit ${EXIT_CODE})"
  fi
else
  echo -e "  Last run: ${DIM}never${NC}"
fi

# Inbox
INBOX_DIR="${BRAIN_DIR}/INBOX"
if [[ -d "$INBOX_DIR" ]]; then
  COUNT=$(find "$INBOX_DIR" -maxdepth 1 \( -name '*.txt' -o -name '*.md' \) ! -name '_*' 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$COUNT" -gt 0 ]]; then
    echo -e "  Inbox:    ${YELLOW}${COUNT} pending task(s)${NC}"
  else
    echo -e "  Inbox:    ${DIM}empty${NC}"
  fi
fi

echo ""
echo -e "  ${DIM}Type 'agent' for commands (status, run, logs, research, tasks)${NC}"
echo ""
MOTD_SCRIPT

chmod +x /etc/update-motd.d/99-agent-status
log "Login banner installed."

# --- 20. Install template files ----------------------------------------------
log "Installing template files..."

# Copy agent-setup.sh (unified post-deploy setup)
if [[ -f "${SCRIPT_DIR}/agent-setup.sh" ]]; then
  cp "${SCRIPT_DIR}/agent-setup.sh" "${HOME_DIR}/agent-setup.sh"
  chmod +x "${HOME_DIR}/agent-setup.sh"
  chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/agent-setup.sh"
  log "agent-setup.sh copied to home directory."
fi

# Handle template installation based on sync mode
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
if [[ -d "${TEMPLATES_DIR}" ]]; then
  if [[ "${FILE_SYNC}" == "dropbox" ]]; then
    # Dropbox mode: stage templates for installation after Dropbox links
    if [[ ! -d "${BRAIN_DIR}" ]]; then
      log "Dropbox not linked yet. Templates staged for later installation."
      sudo -u "${UBUNTU_USER}" mkdir -p "${HOME_DIR}/pending-templates"
      cp -r "${TEMPLATES_DIR}"/* "${HOME_DIR}/pending-templates/"
      chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/pending-templates"
    fi
  else
    # No-sync mode: install templates directly into local brain dir
    log "Installing templates into local brain directory..."
    for f in "${TEMPLATES_DIR}"/*.md; do
      BASENAME=$(basename "$f")
      if [[ "$BASENAME" == "CLAUDE.md" ]]; then
        TARGET="${BRAIN_DIR}/CLAUDE.md"
      else
        TARGET="${BRAIN_DIR}/ai/instructions/${BASENAME}"
      fi
      if [[ ! -f "${TARGET}" ]]; then
        cp "$f" "${TARGET}"
        chown "${UBUNTU_USER}:${UBUNTU_USER}" "${TARGET}"
        log "  Installed: ${TARGET}"
      fi
    done
  fi
fi

# Create template installer script (useful for both modes)
cat > "${HOME_DIR}/scripts/install-templates.sh" << INSTALL_TMPL
#!/usr/bin/env bash
# Install template files into the brain directory.
# Usage: ./install-templates.sh

set -euo pipefail

source "\${HOME}/.agent-server.conf" 2>/dev/null || true
FILE_SYNC="\${FILE_SYNC:-dropbox}"
BRAIN_FOLDER="\${BRAIN_FOLDER:-brain}"
OUTPUT_FOLDER="\${OUTPUT_FOLDER:-output}"

if [[ "\${FILE_SYNC}" == "dropbox" ]]; then
  BRAIN="\${HOME}/Dropbox/\${BRAIN_FOLDER}"
else
  BRAIN="\${HOME}/brain"
fi

# Try pending-templates first, fall back to agent-server/templates
if [[ -d "\${HOME}/pending-templates" ]]; then
  TEMPLATES="\${HOME}/pending-templates"
elif [[ -d "\${HOME}/agent-server/templates" ]]; then
  TEMPLATES="\${HOME}/agent-server/templates"
else
  echo "No templates found. Nothing to install."
  exit 0
fi

if [[ ! -d "\${BRAIN}" ]]; then
  echo "ERROR: \${BRAIN} not found."
  [[ "\${FILE_SYNC}" == "dropbox" ]] && echo "Is Dropbox synced?"
  exit 1
fi

mkdir -p "\${BRAIN}/ai/instructions"
mkdir -p "\${BRAIN}/INBOX/_processed"
mkdir -p "\${BRAIN}/\${OUTPUT_FOLDER}/tasks"
mkdir -p "\${BRAIN}/\${OUTPUT_FOLDER}/logs"
mkdir -p "\${BRAIN}/\${OUTPUT_FOLDER}/research"
mkdir -p "\${BRAIN}/\${OUTPUT_FOLDER}/improvements"

for f in "\${TEMPLATES}"/*.md; do
  [[ ! -f "\$f" ]] && continue
  BASENAME=\$(basename "\$f")
  if [[ "\$BASENAME" == "CLAUDE.md" ]]; then
    TARGET="\${BRAIN}/CLAUDE.md"
  else
    TARGET="\${BRAIN}/ai/instructions/\${BASENAME}"
  fi
  if [[ ! -f "\${TARGET}" ]]; then
    cp "\$f" "\${TARGET}"
    echo "  Installed: \${TARGET}"
  else
    echo "  Skipped (exists): \${TARGET}"
  fi
done

echo ""
echo "Done. You can remove ~/pending-templates/ now."
INSTALL_TMPL
chmod +x "${HOME_DIR}/scripts/install-templates.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/install-templates.sh"

# --- 21. Tools Manifest ------------------------------------------------------
log "Writing tools manifest..."
cat > "${HOME_DIR}/tools-manifest.txt" << MANIFEST
# Agent Server Tools Manifest — $(date +%Y-%m-%d)
# Owner: ${OWNER_NAME}
# Instance: $(hostname) | Region: ${AWS_REGION:-eu-north-1}
# Ubuntu: $(lsb_release -ds)
# Schedule mode: ${SCHEDULE_MODE}
# File sync: ${FILE_SYNC}
# Brain dir: ${BRAIN_DIR}
#
# Core Tools:
python3: $(python3 --version 2>/dev/null || echo "not installed")
git: $(git --version 2>/dev/null || echo "not installed")
aws-cli: $(aws --version 2>/dev/null || echo "not installed")
claude: installed (run 'claude --version' to check)
glow: $(glow --version 2>/dev/null || echo "not installed")
maestral: $(if [[ "${FILE_SYNC}" == "dropbox" ]]; then echo "installed (Dropbox sync via Maestral)"; else echo "not installed (FILE_SYNC=none)"; fi)
ttyd: $(if [[ "${INSTALL_TTYD}" == "true" ]]; then echo "installed (HTTPS, port 443)"; else echo "not installed"; fi)
tmux: $(tmux -V 2>/dev/null || echo "not installed")
uv: installed (run 'uv --version' to check)
ripgrep: $(rg --version 2>/dev/null | head -1 || echo "not installed")
jq: $(jq --version 2>/dev/null || echo "not installed")

# Security:
ufw: active
fail2ban: active
unattended-upgrades: enabled
ssh: key-only, root disabled

# Services:
$(if [[ "${FILE_SYNC}" == "dropbox" ]]; then echo "maestral.service: enabled (systemd user service)"; fi)
$(if [[ "${INSTALL_TTYD}" == "true" ]]; then echo "ttyd.service: enabled (HTTPS, port 443)"; fi)
agent-boot-runner.service: $(systemctl is-enabled agent-boot-runner.service 2>/dev/null || echo "unknown")
MANIFEST
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/tools-manifest.txt"

# =============================================================================
# Done — Print manual steps
# =============================================================================
echo ""
echo "============================================================"
echo -e "${GREEN} SETUP COMPLETE ${NC}"
echo "============================================================"
echo ""
echo "OWNER: ${OWNER_NAME}"
echo "MODE: ${SCHEDULE_MODE}"
echo "FILE SYNC: ${FILE_SYNC}"
echo "BRAIN DIR: ${BRAIN_DIR}"
echo ""
echo "MANUAL STEPS REQUIRED:"
echo ""

STEP=1
echo "${STEP}. SET API KEY"
echo "   nano ~/.agent-env"
echo "   Add your ANTHROPIC_API_KEY from console.anthropic.com"
echo "   Then: source ~/.agent-env"
echo ""
STEP=$((STEP + 1))

echo "${STEP}. RUN POST-DEPLOY SETUP"
echo "   ~/agent-setup.sh"
echo "   (Handles Dropbox, brain directory, MCP servers, and verification)"
echo ""
STEP=$((STEP + 1))

echo "${STEP}. ALLOCATE ELASTIC IP (in AWS Console)"
echo "   EC2 -> Elastic IPs -> Allocate -> Associate with this instance"
echo ""
STEP=$((STEP + 1))

echo "${STEP}. TEST THE ORCHESTRATOR"
echo "   ~/scripts/agent-orchestrator.sh --no-stop"
echo ""
STEP=$((STEP + 1))

if [[ "${SCHEDULE_MODE}" == "scheduled" ]]; then
  echo "${STEP}. SET UP EVENTBRIDGE SCHEDULER (from your local machine)"
  echo "   ./agent-manager.sh --scheduled"
  echo ""
  STEP=$((STEP + 1))
fi

if [[ "${INSTALL_TTYD}" == "true" ]]; then
  echo "WEB TERMINAL: http://<elastic-ip>:7681"
  echo "   User: ${TTYD_USER}"
  echo "   (Change password in agent.conf if still using default)"
  echo ""
fi

echo "SSH CONFIG (add to ~/.ssh/config on your local machine):"
echo "   Host agent"
echo "     HostName <elastic-ip>"
echo "     User ubuntu"
echo "     IdentityFile ~/.ssh/your-key.pem"
echo ""
echo "Tools manifest: ~/tools-manifest.txt"
echo "============================================================"
