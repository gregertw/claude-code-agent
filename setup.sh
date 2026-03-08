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
INSTALL_DOCKER="${INSTALL_DOCKER:-true}"
INSTALL_CODE_SERVER="${INSTALL_CODE_SERVER:-false}"
NODE_MAJOR="${NODE_MAJOR:-22}"
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
  ufw allow 7681/tcp comment 'ttyd web terminal'
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

# --- 7. Node.js (for MCP servers) --------------------------------------------
log "Installing Node.js ${NODE_MAJOR}..."
mkdir -p /etc/apt/keyrings
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
  > /etc/apt/sources.list.d/nodesource.list
apt-get update -qq
apt-get install -y -qq nodejs
log "Node.js $(node --version) installed."

# --- 8. Python tooling (uv) --------------------------------------------------
log "Installing uv (fast Python package manager)..."
sudo -u "${UBUNTU_USER}" bash -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
log "uv installed."

# --- 9. Claude Code CLI ------------------------------------------------------
log "Installing Claude Code..."
sudo -u "${UBUNTU_USER}" bash -c 'curl -fsSL https://claude.ai/install.sh | bash'
log "Claude Code installed."

# --- 10. mcporter (for ActingWeb MCP) ----------------------------------------
log "Installing mcporter (MCP proxy for headless environments)..."
npm install -g mcporter
log "mcporter installed."

# --- 11. Dropbox Headless CLI (optional) -------------------------------------
if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  log "Installing Dropbox headless daemon..."
  cd /tmp
  if [[ $(uname -m) == "x86_64" ]]; then
    wget -q "https://www.dropbox.com/download?plat=lnx.x86_64" -O dropbox.tar.gz
  else
    wget -q "https://www.dropbox.com/download?plat=lnx.aarch64" -O dropbox.tar.gz
  fi
  tar xzf dropbox.tar.gz -C "${HOME_DIR}"
  rm dropbox.tar.gz

  # Install Dropbox CLI helper
  wget -q "https://www.dropbox.com/download?dl=packages/dropbox.py" -O /usr/local/bin/dropbox-cli
  chmod +x /usr/local/bin/dropbox-cli

  # Create systemd service for Dropbox
  cat > /etc/systemd/system/dropbox.service << EOF
[Unit]
Description=Dropbox Daemon
After=network-online.target
Wants=network-online.target

[Service]
User=${UBUNTU_USER}
Group=${UBUNTU_USER}
Type=simple
ExecStart=${HOME_DIR}/.dropbox-dist/dropboxd
Restart=on-failure
RestartSec=10
Environment=DISPLAY=
Environment=HOME=${HOME_DIR}

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable dropbox.service
  log "Dropbox installed (not started — requires account linking)."
else
  log "File sync: none. Brain directory will be local at ${BRAIN_DIR}"
  # Create the local brain directory structure
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/ai/instructions"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/ai/scratchpad"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/INBOX/_processed"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/tasks"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/logs"
  sudo -u "${UBUNTU_USER}" mkdir -p "${BRAIN_DIR}/${OUTPUT_FOLDER}/research"
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
      warn "TTYD_PASSWORD is still 'changeme'. Change it in agent.conf!"
    fi

    # Create systemd service for ttyd
    cat > /etc/systemd/system/ttyd.service << EOF
[Unit]
Description=ttyd Web Terminal
After=network-online.target
Wants=network-online.target

[Service]
User=${UBUNTU_USER}
Group=${UBUNTU_USER}
Type=simple
ExecStart=/usr/local/bin/ttyd --port 7681 --credential ${TTYD_USER}:${TTYD_PASSWORD} --writable bash --login
Restart=on-failure
RestartSec=5
Environment=HOME=${HOME_DIR}

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ttyd.service
    log "ttyd installed and running on port 7681."
    log "Access at: http://<your-ip>:7681 (user: ${TTYD_USER})"
  fi
fi

# --- 13. Docker (optional) ---------------------------------------------------
if [[ "${INSTALL_DOCKER}" == "true" ]]; then
  log "Installing Docker..."
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  usermod -aG docker "${UBUNTU_USER}"
  log "Docker installed. User ${UBUNTU_USER} added to docker group."
fi

# --- 14. VS Code Server (optional) -------------------------------------------
if [[ "${INSTALL_CODE_SERVER}" == "true" ]]; then
  log "Installing code-server (VS Code in browser)..."
  curl -fsSL https://code-server.dev/install.sh | sh
  systemctl enable --now code-server@"${UBUNTU_USER}"
  warn "code-server is running on port 8080. Add UFW rule if you want remote access."
  log "code-server installed."
fi

# --- 15. Environment Setup ---------------------------------------------------
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
alias gs='git status'
alias dc='docker compose'
alias claude-run='claude -p'
alias agent-mode='cat ~/.agent-schedule'
alias agent-logs='ls -lt ~/logs/ | head -20'

# Path additions
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

# tmux: auto-attach or create session on SSH login
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

# --- 16. Claude Code Settings ------------------------------------------------
log "Configuring Claude Code permissions for autonomous mode..."
CLAUDE_SETTINGS_DIR="${HOME_DIR}/.claude"
sudo -u "${UBUNTU_USER}" mkdir -p "${CLAUDE_SETTINGS_DIR}"

cat > "${CLAUDE_SETTINGS_DIR}/settings.json" << 'SETTINGS'
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
      "Bash(dropbox-cli *)",
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
chown -R "${UBUNTU_USER}:${UBUNTU_USER}" "${CLAUDE_SETTINGS_DIR}"
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
# Conditionally depend on dropbox.service if Dropbox is enabled
if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  AFTER_DEPS="After=network-online.target dropbox.service"
  WANTS_DEPS="Wants=network-online.target dropbox.service"
else
  AFTER_DEPS="After=network-online.target"
  WANTS_DEPS="Wants=network-online.target"
fi

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
  echo "  Use deploy-scheduler.sh to set up EventBridge."
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

# --- 20. Install template files ----------------------------------------------
log "Installing template files..."

# Copy MCP setup script
if [[ -f "${SCRIPT_DIR}/setup-mcp.sh" ]]; then
  cp "${SCRIPT_DIR}/setup-mcp.sh" "${HOME_DIR}/setup-mcp.sh"
  chmod +x "${HOME_DIR}/setup-mcp.sh"
  chown "${UBUNTU_USER}:${UBUNTU_USER}" "${HOME_DIR}/setup-mcp.sh"
  log "setup-mcp.sh copied to home directory."
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

TEMPLATES="\${HOME}/pending-templates"

if [[ ! -d "\${BRAIN}" ]]; then
  echo "ERROR: \${BRAIN} not found."
  [[ "\${FILE_SYNC}" == "dropbox" ]] && echo "Is Dropbox synced?"
  exit 1
fi

if [[ ! -d "\${TEMPLATES}" ]]; then
  echo "No pending templates found. Nothing to install."
  exit 0
fi

mkdir -p "\${BRAIN}/ai/instructions"
mkdir -p "\${BRAIN}/INBOX/_processed"
mkdir -p "\${BRAIN}/\${OUTPUT_FOLDER}/tasks"
mkdir -p "\${BRAIN}/\${OUTPUT_FOLDER}/logs"
mkdir -p "\${BRAIN}/\${OUTPUT_FOLDER}/research"

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
node: $(node --version 2>/dev/null || echo "not installed")
npm: $(npm --version 2>/dev/null || echo "not installed")
python3: $(python3 --version 2>/dev/null || echo "not installed")
git: $(git --version 2>/dev/null || echo "not installed")
aws-cli: $(aws --version 2>/dev/null || echo "not installed")
mcporter: $(mcporter --version 2>/dev/null || echo "installed")
claude: installed (run 'claude --version' to check)
dropbox: $(if [[ "${FILE_SYNC}" == "dropbox" ]]; then echo "installed (headless daemon)"; else echo "not installed (FILE_SYNC=none)"; fi)
ttyd: $(if [[ "${INSTALL_TTYD}" == "true" ]]; then ttyd --version 2>/dev/null || echo "installed"; else echo "not installed"; fi)
docker: $(docker --version 2>/dev/null || echo "not installed")
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
$(if [[ "${FILE_SYNC}" == "dropbox" ]]; then echo "dropbox.service: enabled (systemd)"; fi)
$(if [[ "${INSTALL_TTYD}" == "true" ]]; then echo "ttyd.service: enabled (port 7681, basic auth)"; fi)
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

if [[ "${FILE_SYNC}" == "dropbox" ]]; then
  echo "${STEP}. LINK DROPBOX"
  echo "   ~/.dropbox-dist/dropboxd"
  echo "   -> Open the URL it prints in your browser"
  echo "   -> After linking, Ctrl-C then: sudo systemctl start dropbox"
  echo ""
  STEP=$((STEP + 1))

  echo "${STEP}. CONFIGURE DROPBOX SELECTIVE SYNC (optional)"
  echo "   dropbox-cli exclude add ~/Dropbox/folder-you-dont-need"
  echo ""
  STEP=$((STEP + 1))

  echo "${STEP}. INSTALL TEMPLATE FILES (after Dropbox syncs)"
  echo "   ~/scripts/install-templates.sh"
  echo ""
  STEP=$((STEP + 1))
else
  echo "   (No Dropbox setup needed — brain directory is local at ${BRAIN_DIR})"
  echo "   Template files have been installed automatically."
  echo ""
fi

echo "${STEP}. VERIFY CLAUDE CODE"
echo "   claude --version"
echo "   echo 'Reply: Hello' | claude -p"
echo ""
STEP=$((STEP + 1))

echo "${STEP}. CONFIGURE MCP CONNECTIONS"
echo "   ~/setup-mcp.sh"
echo "   (ActingWeb is required; Gmail and Calendar are optional)"
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
  echo "   ./deploy-scheduler.sh <instance-id>"
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
