#!/usr/bin/env bash
# =============================================================================
# AWS Ubuntu Agent Server — Bootstrap Script
# =============================================================================
# Run this on a fresh Ubuntu 22.04 LTS EC2 instance:
#   chmod +x setup.sh && sudo ./setup.sh
#
# Reads configuration from agent.conf in the same directory.
# After running, complete the manual steps printed at the end.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_SCRIPTS="${SCRIPT_DIR}/scripts"
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
INSTALL_TTYD="${INSTALL_TTYD:-false}"
TTYD_USER="${TTYD_USER:-agent}"
TTYD_PASSWORD="${TTYD_PASSWORD:-changeme}"
UBUNTU_USER="${UBUNTU_USER:-ubuntu}"
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
HOME_DIR="/home/${UBUNTU_USER}"
BRAIN_DIR="${HOME_DIR}/brain"

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

# --- 7. Glow (terminal markdown renderer) ------------------------------------
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

# --- 10. Brain Directory -----------------------------------------------------
log "Creating brain directory at ${BRAIN_DIR}..."
sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/ai/instructions"
sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/ai/scratchpad"
sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/INBOX/_processed"
sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/tasks"
sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/logs"
sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/research"
sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/improvements"

# --- 11. ttyd Web Terminal (optional) ----------------------------------------
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

# --- 12. Environment Setup ---------------------------------------------------
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
# Detect server timezone for schedule alignment
SERVER_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")

cat > "${HOME_DIR}/.agent-schedule" << EOF
# Agent Server Schedule Mode
SCHEDULE_MODE="${SCHEDULE_MODE}"
SCHEDULE_INTERVAL="${SCHEDULE_INTERVAL}"
SCHEDULE_HOURS="${SCHEDULE_HOURS:-6-22}"
SCHEDULE_WEEKEND_HOURS="${SCHEDULE_WEEKEND_HOURS:-}"
SCHEDULE_TZ="${SERVER_TZ}"
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

# --- 13. Claude Code Settings ------------------------------------------------
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
      "mcp__claude_ai_Actingweb",
      "mcp__claude_ai_Gmail",
      "mcp__claude_ai_Google_Calendar",
      "mcp__claude_ai_notion",
      "Read",
      "Write",
      "Edit",
      "Glob",
      "Grep",
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

# --- 14. Agent Orchestrator --------------------------------------------------
log "Installing agent orchestrator..."
if [[ -f "${SERVER_SCRIPTS}/agent-orchestrator.sh" ]]; then
  cp "${SERVER_SCRIPTS}/agent-orchestrator.sh" "${HOME_DIR}/scripts/agent-orchestrator.sh"
  log "Orchestrator copied to ~/scripts/"
else
  warn "agent-orchestrator.sh not found in ${SERVER_SCRIPTS}. Upload it manually to ~/scripts/"
fi
chmod +x "${HOME_DIR}/scripts/agent-orchestrator.sh" 2>/dev/null || true
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/agent-orchestrator.sh" 2>/dev/null || true

# Copy shared functions (sourced by orchestrator and resume-check)
if [[ -f "${SERVER_SCRIPTS}/agent-functions.sh" ]]; then
  cp "${SERVER_SCRIPTS}/agent-functions.sh" "${HOME_DIR}/scripts/agent-functions.sh"
  log "Shared functions copied to ~/scripts/"
else
  warn "agent-functions.sh not found in ${SERVER_SCRIPTS}."
fi
chmod +x "${HOME_DIR}/scripts/agent-functions.sh" 2>/dev/null || true
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/agent-functions.sh" 2>/dev/null || true

# Copy agent runner helper
log "Installing agent runner helper script..."
if [[ -f "${SERVER_SCRIPTS}/run-agent.sh" ]]; then
  cp "${SERVER_SCRIPTS}/run-agent.sh" "${HOME_DIR}/scripts/run-agent.sh"
else
  warn "run-agent.sh not found in ${SERVER_SCRIPTS}."
fi
chmod +x "${HOME_DIR}/scripts/run-agent.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/run-agent.sh"

# Create systemd service for agent orchestrator
cat > /etc/systemd/system/agent-boot-runner.service << EOF
[Unit]
Description=Agent Orchestrator — runs tasks on boot
After=network-online.target
Wants=network-online.target

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

# Install resume-check script for triggering orchestrator on wake from hibernation.
# Hibernation resumes do NOT re-run boot services (multi-user.target is already
# active) and cron does NOT catch up on missed jobs, so without this the first
# run after wake would be up to 60 minutes later.
# The wrapper script checks the heartbeat file — if the last run was recent
# enough (within SCHEDULE_INTERVAL), it skips the run to avoid unnecessary
# double-runs when wake happens mid-cycle.
if [[ -f "${SERVER_SCRIPTS}/agent-resume-check.sh" ]]; then
  cp "${SERVER_SCRIPTS}/agent-resume-check.sh" "${HOME_DIR}/scripts/agent-resume-check.sh"
else
  warn "agent-resume-check.sh not found in ${SERVER_SCRIPTS}."
fi
chmod +x "${HOME_DIR}/scripts/agent-resume-check.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/agent-resume-check.sh"

# Install system-sleep hook for hibernate resume (from template file).
# A systemd oneshot service with WantedBy=hibernate.target is unreliable:
# it may not re-trigger on every resume within the same boot session.
# The system-sleep hook runs reliably on every hibernate/resume cycle.
if [[ -f "${SERVER_SCRIPTS}/agent-resume-hook.sh" ]]; then
  cp "${SERVER_SCRIPTS}/agent-resume-hook.sh" /usr/lib/systemd/system-sleep/agent-resume
else
  warn "agent-resume-hook.sh not found in ${SERVER_SCRIPTS}."
fi
chmod 755 /usr/lib/systemd/system-sleep/agent-resume

# Remove legacy systemd service if present (replaced by system-sleep hook above)
if [[ -f /etc/systemd/system/agent-resume-runner.service ]]; then
  systemctl disable agent-resume-runner.service 2>/dev/null || true
  rm -f /etc/systemd/system/agent-resume-runner.service
fi

systemctl daemon-reload
if [[ "${SCHEDULE_MODE}" == "scheduled" ]]; then
  systemctl enable agent-boot-runner.service
  log "Boot runner ENABLED (scheduled mode)."
  log "Resume hook ENABLED (system-sleep, triggers orchestrator on wake from hibernation)."
else
  systemctl disable agent-boot-runner.service
  # Remove resume hook in always-on mode (cron handles everything)
  rm -f /usr/lib/systemd/system-sleep/agent-resume
  log "Boot runner DISABLED (always-on mode)."
  log "Resume hook DISABLED (always-on mode)."
fi

# Create systemd service for agent code upgrade (runs before orchestrator)
cat > /etc/systemd/system/agent-upgrade.service << EOF
[Unit]
Description=Agent Code Upgrade — pulls latest from GitHub
After=network-online.target
Wants=network-online.target
Before=agent-boot-runner.service

[Service]
Type=oneshot
User=${UBUNTU_USER}
Group=${UBUNTU_USER}
ExecStart=${HOME_DIR}/scripts/agent-cli.sh upgrade
Environment=HOME=${HOME_DIR}
TimeoutStartSec=120
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

AUTO_UPGRADE="${AUTO_UPGRADE:-true}"
if [[ "${AUTO_UPGRADE}" == "true" ]]; then
  systemctl enable agent-upgrade.service
  # Daily cron job at 4am
  cat > /etc/cron.d/agent-upgrade << CRON
# Auto-upgrade agent code daily
0 4 * * * ${UBUNTU_USER} ${HOME_DIR}/scripts/agent-cli.sh upgrade >> ${HOME_DIR}/logs/upgrade.log 2>&1
CRON
  chmod 644 /etc/cron.d/agent-upgrade
  log "Auto-upgrade ENABLED (boot + daily 4am cron)."
else
  systemctl disable agent-upgrade.service 2>/dev/null || true
  rm -f /etc/cron.d/agent-upgrade
  log "Auto-upgrade DISABLED."
fi

# --- 14b. Hourly Orchestrator Cron ------------------------------------------
# Run the orchestrator every SCHEDULE_INTERVAL minutes (or every 60 if unset).
# This ensures the agent runs periodically regardless of schedule mode:
#   - Scheduled mode: EventBridge wakes the instance, cron keeps it running
#     while awake (e.g. if the user does a manual wakeup and stays connected)
#   - Always-on mode: cron is the primary trigger since the instance never stops
# The orchestrator uses flock to prevent concurrent runs, so overlapping cron
# triggers (or cron + boot runner) are harmless.
log "Installing orchestrator cron job..."
CRON_INTERVAL="${SCHEDULE_INTERVAL:-60}"
CRON_HOURS="${SCHEDULE_HOURS:-6-22}"
CRON_WEEKEND_HOURS="${SCHEDULE_WEEKEND_HOURS:-}"
CRON_CMD="${HOME_DIR}/scripts/agent-orchestrator.sh >> ${HOME_DIR}/logs/cron-orchestrator.log 2>&1"
if [[ -n "${CRON_WEEKEND_HOURS}" ]]; then
  cat > /etc/cron.d/agent-orchestrator << CRON
# Weekdays: every ${CRON_INTERVAL} min during hours ${CRON_HOURS}
*/${CRON_INTERVAL} ${CRON_HOURS} * * 1-5 ${UBUNTU_USER} ${CRON_CMD}
# Weekends: specific hours ${CRON_WEEKEND_HOURS}
0 ${CRON_WEEKEND_HOURS} * * 0,6 ${UBUNTU_USER} ${CRON_CMD}
CRON
  log "Orchestrator cron installed (weekdays every ${CRON_INTERVAL} min ${CRON_HOURS}, weekends at ${CRON_WEEKEND_HOURS})."
else
  cat > /etc/cron.d/agent-orchestrator << CRON
# Run agent orchestrator every ${CRON_INTERVAL} minutes during active hours
# flock in the orchestrator prevents concurrent runs
*/${CRON_INTERVAL} ${CRON_HOURS} * * * ${UBUNTU_USER} ${CRON_CMD}
CRON
  log "Orchestrator cron installed (every ${CRON_INTERVAL} min)."
fi
chmod 644 /etc/cron.d/agent-orchestrator

# --- 15. Schedule Mode Toggle Script ----------------------------------------
log "Installing schedule mode toggle..."
if [[ -f "${SERVER_SCRIPTS}/set-schedule-mode.sh" ]]; then
  cp "${SERVER_SCRIPTS}/set-schedule-mode.sh" "${HOME_DIR}/scripts/set-schedule-mode.sh"
else
  warn "set-schedule-mode.sh not found in ${SERVER_SCRIPTS}."
fi
chmod +x "${HOME_DIR}/scripts/set-schedule-mode.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/set-schedule-mode.sh"

# --- 16. Agent README -------------------------------------------------------
log "Setting up agent infrastructure..."
cat > "${HOME_DIR}/agents/README.md" << EOF
# Agent Server — ${OWNER_NAME}

## Brain directory: ${BRAIN_DIR}

## Manual run
  agent run                                    # full run, stays on
  agent status                                 # show agent status

## Task Inbox
Drop .txt or .md files in: ${BRAIN_DIR}/INBOX/

## Preventing self-stop (for debugging)
  touch ~/agents/.keep-running
  rm ~/agents/.keep-running
EOF

chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/agents"

# --- 17. Agent CLI Helper ---------------------------------------------------
log "Installing agent CLI helper..."
if [[ -f "${SERVER_SCRIPTS}/agent-cli.sh" ]]; then
  cp "${SERVER_SCRIPTS}/agent-cli.sh" "${HOME_DIR}/scripts/agent-cli.sh"
  chmod +x "${HOME_DIR}/scripts/agent-cli.sh"
  chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/agent-cli.sh"
  # Symlink so auto-updates to ~/scripts/agent-cli.sh take effect immediately
  ln -sf "${HOME_DIR}/scripts/agent-cli.sh" /usr/local/bin/agent
  log "Agent CLI installed. Use: agent status, agent run, agent logs, etc."
else
  warn "agent-cli.sh not found in ${SERVER_SCRIPTS}. Upload it manually."
fi

# --- 17b. Dropbox Setup Script ---------------------------------------------
if [[ -f "${SERVER_SCRIPTS}/setup-dropbox.sh" ]]; then
  cp "${SERVER_SCRIPTS}/setup-dropbox.sh" "${HOME_DIR}/scripts/setup-dropbox.sh"
  chmod +x "${HOME_DIR}/scripts/setup-dropbox.sh"
  chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/setup-dropbox.sh"
  log "Dropbox setup script copied to ~/scripts/"
fi

# --- 18. Login Banner (MOTD) -----------------------------------------------
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

OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"
OWNER_NAME="${OWNER_NAME:-Agent}"
BRAIN_DIR="${HOME_DIR}/brain"
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

# --- 19. Install template files ----------------------------------------------
log "Installing template files..."

# Copy agent-setup.sh (unified post-deploy setup)
if [[ -f "${SERVER_SCRIPTS}/agent-setup.sh" ]]; then
  cp "${SERVER_SCRIPTS}/agent-setup.sh" "${HOME_DIR}/agent-setup.sh"
  chmod +x "${HOME_DIR}/agent-setup.sh"
  chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/agent-setup.sh"
  log "agent-setup.sh copied to home directory."
fi

# Create output subdirectories
mkdir -p "${BRAIN_DIR}/ai/scratchpad"
mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/emails"
mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/news"
chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${BRAIN_DIR}/ai/scratchpad"
chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${BRAIN_DIR}/${OUTPUT_FOLDER}/emails"
chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${BRAIN_DIR}/${OUTPUT_FOLDER}/news"

# Install templates directly into brain directory
# System files (CLAUDE.md, tasks.md, default-tasks.md) are always installed/overwritten.
# User files (personal.md, style.md, personal-tasks.md, ACTIONS.md) are only
# installed if they don't exist — never overwritten.
TEMPLATES_DIR="${SCRIPT_DIR}/templates"
if [[ -d "${TEMPLATES_DIR}" ]]; then
  log "Installing templates into brain directory..."
  for f in "${TEMPLATES_DIR}"/*.md; do
    BASENAME=$(basename "$f")
    if [[ "$BASENAME" == "CLAUDE.md" || "$BASENAME" == "ACTIONS.md" ]]; then
      TARGET="${BRAIN_DIR}/${BASENAME}"
    else
      TARGET="${BRAIN_DIR}/ai/instructions/${BASENAME}"
    fi

    # Determine if this is a system file (safe to overwrite) or user file (preserve)
    case "$BASENAME" in
      CLAUDE.md|tasks.md|default-tasks.md)
        # System file — always install
        cp "$f" "${TARGET}"
        chown "${UBUNTU_USER}:${UBUNTU_USER}" "${TARGET}"
        log "  Installed: ${TARGET}"
        ;;
      *)
        # User file — only install if missing
        if [[ ! -f "${TARGET}" ]]; then
          cp "$f" "${TARGET}"
          chown "${UBUNTU_USER}:${UBUNTU_USER}" "${TARGET}"
          log "  Installed: ${TARGET}"
        else
          log "  Preserved: ${TARGET}"
        fi
        ;;
    esac
  done

  # Install Obsidian document templates (never overwrite)
  if [[ -d "${TEMPLATES_DIR}/obsidian" ]]; then
    mkdir -p "${BRAIN_DIR}/templates"
    for f in "${TEMPLATES_DIR}/obsidian/"*.md; do
      [[ ! -f "$f" ]] && continue
      BASENAME=$(basename "$f")
      TARGET="${BRAIN_DIR}/templates/${BASENAME}"
      if [[ ! -f "${TARGET}" ]]; then
        cp "$f" "${TARGET}"
        chown "${UBUNTU_USER}:${UBUNTU_USER}" "${TARGET}"
        log "  Installed: ${TARGET}"
      fi
    done
    chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${BRAIN_DIR}/templates"
  fi
fi

# Copy template installer script (useful for re-installing)
if [[ -f "${SERVER_SCRIPTS}/install-templates.sh" ]]; then
  cp "${SERVER_SCRIPTS}/install-templates.sh" "${HOME_DIR}/scripts/install-templates.sh"
else
  warn "install-templates.sh not found in ${SERVER_SCRIPTS}."
fi
chmod +x "${HOME_DIR}/scripts/install-templates.sh"
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/scripts/install-templates.sh"

# --- 20. Tools Manifest ------------------------------------------------------
log "Writing tools manifest..."
cat > "${HOME_DIR}/tools-manifest.txt" << MANIFEST
# Agent Server Tools Manifest — $(date +%Y-%m-%d)
# Owner: ${OWNER_NAME}
# Instance: $(hostname) | Region: ${AWS_REGION:-eu-north-1}
# Ubuntu: $(lsb_release -ds)
# Schedule mode: ${SCHEDULE_MODE}
# Brain dir: ${BRAIN_DIR}
#
# Core Tools:
python3: $(python3 --version 2>/dev/null || echo "not installed")
git: $(git --version 2>/dev/null || echo "not installed")
aws-cli: $(aws --version 2>/dev/null || echo "not installed")
claude: installed (run 'claude --version' to check)
glow: $(glow --version 2>/dev/null || echo "not installed")
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
$(if [[ "${INSTALL_TTYD}" == "true" ]]; then echo "ttyd.service: enabled (HTTPS, port 443)"; fi)
agent-boot-runner.service: $(systemctl is-enabled agent-boot-runner.service 2>/dev/null || echo "unknown")
MANIFEST
chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/tools-manifest.txt"

# --- 21. Clone repo and clean up staging ------------------------------------
log "Setting up agent code repo..."
REPO_DIR="${HOME_DIR}/.agent-repo"
REPO_URL="https://github.com/gregertw/claude-code-agent.git"

if [[ ! -d "${REPO_DIR}/.git" ]]; then
  sudo -u "${UBUNTU_USER}" git clone --depth 1 --quiet "${REPO_URL}" "${REPO_DIR}" 2>/dev/null && \
    log "Cloned agent repo to ${REPO_DIR}" || \
    warn "Could not clone repo (no internet?). Auto-updates will clone on first run."
fi

# Copy templates to durable location
if [[ -d "${REPO_DIR}/templates" ]]; then
  mkdir -p "${HOME_DIR}/.agent-templates"
  cp "${REPO_DIR}/templates/"*.md "${HOME_DIR}/.agent-templates/" 2>/dev/null || true
  if [[ -d "${REPO_DIR}/templates/obsidian" ]]; then
    mkdir -p "${HOME_DIR}/.agent-templates/obsidian"
    cp "${REPO_DIR}/templates/obsidian/"*.md "${HOME_DIR}/.agent-templates/obsidian/" 2>/dev/null || true
  fi
  chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/.agent-templates"
fi

# Clean up staging directory — everything is now in its permanent location
if [[ -d "${HOME_DIR}/agent-server" ]]; then
  rm -rf "${HOME_DIR}/agent-server"
  log "Removed staging directory ~/agent-server/"
fi

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
echo "   (Handles brain directory, MCP servers, and verification)"
echo ""
STEP=$((STEP + 1))

echo "${STEP}. PERSONALIZE YOUR AGENT"
echo "   Edit ${BRAIN_DIR}/ai/instructions/personal.md — fill in your identity and preferences"
echo "   Edit ${BRAIN_DIR}/ai/instructions/style.md — define your writing voice"
echo "   Add custom recurring tasks in ${BRAIN_DIR}/ai/instructions/personal-tasks.md"
echo ""
STEP=$((STEP + 1))

echo "${STEP}. TEST THE AGENT"
echo "   agent run"
echo ""
echo "   YOUR WORKSPACE:"
echo "   - ACTIONS.md    — your dashboard; the agent updates it, you act on items"
echo "   - INBOX/        — drop .md files here to give the agent tasks"
echo "   - ${OUTPUT_FOLDER}/emails/  — email drafts with status: frontmatter (approve to send)"
echo "   - ${OUTPUT_FOLDER}/news/    — daily news reports from your newsletters"
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
