#!/usr/bin/env bash
# =============================================================================
# Deploy Agent Server — Run from your LOCAL machine
# =============================================================================
# Creates all AWS resources, configures the server, and registers MCP servers.
# After this script completes, follow the guided post-deploy steps to:
#   - Link Dropbox (if using)
#   - Authenticate Claude Code (API key or account login)
#   - Authenticate MCP servers (ActingWeb, Gmail, Calendar)
#
# Prerequisites:
#   - AWS CLI installed and configured (`aws configure`)
#   - agent.conf in the same directory (copy from agent.conf.example)
#
# Usage:
#   ./deploy.sh                    # full deploy
#   ./deploy.sh --skip-scheduler   # skip EventBridge scheduler setup
#
# State is saved to deploy-state.json for teardown.sh to use.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="${SCRIPT_DIR}/agent.conf"
STATE_FILE="${SCRIPT_DIR}/deploy-state.json"

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[DEPLOY]${NC} $1"; }
warn() { echo -e "${YELLOW}[NOTE]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }
step() { echo -e "\n${GREEN}--- Step $1: $2 ---${NC}"; }

# --- Parse flags -------------------------------------------------------------
SKIP_SCHEDULER=false
for arg in "$@"; do
  case "$arg" in
    --skip-scheduler) SKIP_SCHEDULER=true ;;
    --help|-h)
      echo "Usage: ./deploy.sh [--skip-scheduler]"
      exit 0 ;;
  esac
done

# --- Load configuration -----------------------------------------------------
if [[ ! -f "${CONF_FILE}" ]]; then
  err "agent.conf not found. Copy agent.conf.example to agent.conf first."
  exit 1
fi
source "${CONF_FILE}"

if [[ -z "${OWNER_NAME:-}" || "${OWNER_NAME}" == "Your Name" ]]; then
  err "Set OWNER_NAME in agent.conf before deploying."
  exit 1
fi

AWS_REGION="${AWS_REGION:-eu-north-1}"
SCHEDULE_MODE="${SCHEDULE_MODE:-always-on}"
SCHEDULE_INTERVAL="${SCHEDULE_INTERVAL:-60}"
INSTALL_TTYD="${INSTALL_TTYD:-false}"
FILE_SYNC="${FILE_SYNC:-dropbox}"
KEY_NAME="agent-server-key"
SG_NAME="agent-server-sg"
INSTANCE_NAME="agent-server"
SSH_HOST="agent"

# --- Pre-flight checks -------------------------------------------------------
if [[ -f "${STATE_FILE}" ]]; then
  err "deploy-state.json already exists. An instance may be running."
  echo "  To redeploy, first run: ./teardown.sh"
  exit 1
fi

if ! command -v aws &>/dev/null; then
  err "AWS CLI not found. Install it first."
  exit 1
fi

if ! aws sts get-caller-identity &>/dev/null; then
  err "AWS CLI not configured. Run 'aws configure' first."
  exit 1
fi

log "Deploying agent server for ${OWNER_NAME}"
log "Region: ${AWS_REGION} | Mode: ${SCHEDULE_MODE} | File sync: ${FILE_SYNC}"
echo ""

# --- Optional: set API key early if provided --------------------------------
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  log "API key found in environment — will configure on server."
fi

# =============================================================================
step 1 "Create EC2 Key Pair"
# =============================================================================
KEY_FILE="${HOME}/.ssh/${KEY_NAME}.pem"
if aws ec2 describe-key-pairs --key-names "${KEY_NAME}" --region "${AWS_REGION}" &>/dev/null; then
  warn "Key pair '${KEY_NAME}' already exists in AWS."
  if [[ ! -f "${KEY_FILE}" ]]; then
    err "But local .pem file not found at ${KEY_FILE}. Delete the key pair first:"
    echo "  aws ec2 delete-key-pair --key-name ${KEY_NAME} --region ${AWS_REGION}"
    exit 1
  fi
  log "Reusing existing key pair."
else
  aws ec2 create-key-pair \
    --key-name "${KEY_NAME}" \
    --region "${AWS_REGION}" \
    --query 'KeyMaterial' \
    --output text > "${KEY_FILE}"
  chmod 400 "${KEY_FILE}"
  log "Key pair created: ${KEY_FILE}"
fi

# =============================================================================
step 2 "Create Security Group"
# =============================================================================
MY_IP=$(curl -s --max-time 5 https://checkip.amazonaws.com)
if [[ -z "${MY_IP}" ]]; then
  err "Could not determine your public IP."
  exit 1
fi
log "Your public IP: ${MY_IP}"

VPC_ID=$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
  --filters "Name=isDefault,Values=true" \
  --query 'Vpcs[0].VpcId' --output text)

# Check if SG already exists
SG_ID=$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo "None")

if [[ "${SG_ID}" != "None" && -n "${SG_ID}" ]]; then
  log "Security group already exists: ${SG_ID}"
else
  SG_ID=$(aws ec2 create-security-group \
    --group-name "${SG_NAME}" \
    --description "Agent server - SSH and ttyd" \
    --vpc-id "${VPC_ID}" \
    --region "${AWS_REGION}" \
    --query 'GroupId' --output text)
  log "Security group created: ${SG_ID}"
fi

# Build ingress rules
RULES='[{"IpProtocol":"tcp","FromPort":22,"ToPort":22,"IpRanges":[{"CidrIp":"'"${MY_IP}/32"'","Description":"SSH from deploy IP"}]}'
if [[ "${INSTALL_TTYD}" == "true" ]]; then
  RULES="${RULES}"',{"IpProtocol":"tcp","FromPort":443,"ToPort":443,"IpRanges":[{"CidrIp":"'"${MY_IP}/32"'","Description":"ttyd HTTPS from deploy IP"}]}'
fi
RULES="${RULES}]"

aws ec2 authorize-security-group-ingress \
  --group-id "${SG_ID}" \
  --region "${AWS_REGION}" \
  --ip-permissions "${RULES}" >/dev/null 2>/dev/null || warn "Ingress rules may already exist (continuing)"

# =============================================================================
step 3 "Find Ubuntu 24.04 AMI"
# =============================================================================
AMI_ID=$(aws ec2 describe-images --region "${AWS_REGION}" \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
             "Name=state,Values=available" \
  --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' --output text)
log "AMI: ${AMI_ID}"

# =============================================================================
step 4 "Launch EC2 Instance"
# =============================================================================
INSTANCE_ID=$(aws ec2 run-instances --region "${AWS_REGION}" \
  --image-id "${AMI_ID}" \
  --instance-type t3.large \
  --key-name "${KEY_NAME}" \
  --security-group-ids "${SG_ID}" \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}}]" \
  --query 'Instances[0].InstanceId' --output text)
log "Instance launched: ${INSTANCE_ID}"

log "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
log "Instance is running."

# =============================================================================
step 5 "Allocate and Associate Elastic IP"
# =============================================================================
ALLOC_ID=$(aws ec2 allocate-address --region "${AWS_REGION}" \
  --query 'AllocationId' --output text)

aws ec2 associate-address \
  --instance-id "${INSTANCE_ID}" \
  --allocation-id "${ALLOC_ID}" \
  --region "${AWS_REGION}" >/dev/null

ELASTIC_IP=$(aws ec2 describe-addresses \
  --allocation-ids "${ALLOC_ID}" \
  --region "${AWS_REGION}" \
  --query 'Addresses[0].PublicIp' --output text)
log "Elastic IP: ${ELASTIC_IP}"

# =============================================================================
# Save state for teardown (early, so we can clean up even if later steps fail)
# =============================================================================
cat > "${STATE_FILE}" << STATEOF
{
  "instance_id": "${INSTANCE_ID}",
  "elastic_ip_allocation_id": "${ALLOC_ID}",
  "elastic_ip": "${ELASTIC_IP}",
  "security_group_id": "${SG_ID}",
  "key_pair_name": "${KEY_NAME}",
  "region": "${AWS_REGION}",
  "ssh_config_host": "${SSH_HOST}",
  "deployed_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "owner": "${OWNER_NAME}"
}
STATEOF
log "State saved to deploy-state.json"

# =============================================================================
step 6 "Configure SSH"
# =============================================================================
SSH_CONFIG="${HOME}/.ssh/config"
SSH_BLOCK="Host ${SSH_HOST}
  HostName ${ELASTIC_IP}
  User ubuntu
  IdentityFile ${KEY_FILE}
  ServerAliveInterval 60
  ServerAliveCountMax 3"

# Remove existing block if present, then add
if grep -q "^Host ${SSH_HOST}$" "${SSH_CONFIG}" 2>/dev/null; then
  # Remove old block (Host line through next Host line or EOF)
  python3 -c "
import re, sys
with open('${SSH_CONFIG}') as f:
    content = f.read()
pattern = r'Host ${SSH_HOST}\n(?:  [^\n]*\n)*\n?'
content = re.sub(pattern, '', content)
with open('${SSH_CONFIG}', 'w') as f:
    f.write(content)
"
  warn "Replaced existing SSH config for '${SSH_HOST}'"
fi

# Find insertion point (after Include lines, before first Host block)
python3 -c "
import sys
with open('${SSH_CONFIG}') as f:
    lines = f.readlines()

insert_after = 0
for i, line in enumerate(lines):
    if line.strip().startswith('Include '):
        insert_after = i + 1
    elif line.strip().startswith('Host ') and insert_after > 0:
        break

block = '''${SSH_BLOCK}

'''
lines.insert(insert_after, block)
with open('${SSH_CONFIG}', 'w') as f:
    f.writelines(lines)
"
log "SSH config updated. Use: ssh ${SSH_HOST}"

# =============================================================================
step 7 "Wait for SSH and Upload"
# =============================================================================
log "Waiting for SSH to become available..."
for i in $(seq 1 30); do
  if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "${SSH_HOST}" "echo ready" 2>/dev/null; then
    break
  fi
  if [[ $i -eq 30 ]]; then
    err "SSH connection timed out after 150 seconds."
    echo "Instance and resources are created. Try manually:"
    echo "  ssh ${SSH_HOST}"
    exit 1
  fi
  sleep 5
done

log "Uploading agent-server files..."
ssh "${SSH_HOST}" "mkdir -p ~/agent-server"
scp -q -r "${SCRIPT_DIR}"/* "${SSH_HOST}:~/agent-server/"
log "Files uploaded."

# =============================================================================
step 8 "Run Server Setup"
# =============================================================================
log "Running setup.sh on server (this takes a few minutes)..."
set +eo pipefail
ssh "${SSH_HOST}" "cd ~/agent-server && chmod +x setup.sh && sudo ./setup.sh" 2>&1 | while IFS= read -r line; do
  # Show only [SETUP], [WARN], and [ERROR] lines to reduce noise
  if echo "$line" | grep -qE '\[(SETUP|WARN|ERROR)\]'; then
    echo "$line"
  fi
done
SSH_EXIT=${PIPESTATUS[0]}
set -eo pipefail

if [[ ${SSH_EXIT} -ne 0 ]]; then
  err "setup.sh failed (exit code ${SSH_EXIT})."
  echo ""
  echo "  setup.sh is safe to re-run (idempotent). To retry with full output:"
  echo "    ssh ${SSH_HOST} \"cd ~/agent-server && sudo ./setup.sh\""
  echo ""
  echo "  Look for the '[SETUP] SETUP COMPLETE' message to confirm success."
  echo "  If it fails again, check the full output for errors above the failure point."
  exit 1
fi
log "Server setup complete."

# =============================================================================
step 9 "Set API Key (if provided)"
# =============================================================================
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  ssh "${SSH_HOST}" "echo 'export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\"' > ~/.agent-env && chmod 600 ~/.agent-env"
  log "API key configured on server."
else
  ssh "${SSH_HOST}" "touch ~/.agent-env && chmod 600 ~/.agent-env"
  log "No API key provided — will be configured during post-deploy setup."
fi

# Verify Claude Code is installed
CLAUDE_VERSION=$(ssh "${SSH_HOST}" "export PATH=\"\$HOME/.local/bin:\$PATH\" && claude --version" 2>/dev/null || echo "unknown")
log "Claude Code ${CLAUDE_VERSION} installed on server."

# =============================================================================
step 10 "Deploy EventBridge Scheduler"
# =============================================================================
if [[ "${SCHEDULE_MODE}" == "scheduled" && "${SKIP_SCHEDULER}" == "false" ]]; then
  log "Deploying EventBridge scheduler (every ${SCHEDULE_INTERVAL} minutes)..."
  if [[ -f "${SCRIPT_DIR}/deploy-scheduler.sh" ]]; then
    bash "${SCRIPT_DIR}/deploy-scheduler.sh" "${INSTANCE_ID}" "${SCHEDULE_INTERVAL}" "${AWS_REGION}"
  else
    warn "deploy-scheduler.sh not found. Deploy it manually later."
  fi
else
  if [[ "${SCHEDULE_MODE}" == "scheduled" ]]; then
    warn "Skipping scheduler (--skip-scheduler). Deploy later with:"
    echo "  ./deploy-scheduler.sh ${INSTANCE_ID}"
  else
    log "Always-on mode — no scheduler needed."
  fi
fi

# =============================================================================
# Done — Print status summary
# =============================================================================

# Build list of post-deploy steps needed
POST_STEPS=""
STEP_NUM=1

POST_STEPS="${POST_STEPS}\n   Connect with: ./agent-manager.sh --ssh-mcp (use one session for all steps)\n"

POST_STEPS="${POST_STEPS}\n${STEP_NUM}. Run post-deploy setup: ~/agent-setup.sh"
POST_STEPS="${POST_STEPS}\n   (Handles Dropbox, brain directory, templates, and MCP registration)"
STEP_NUM=$((STEP_NUM + 1))

if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  POST_STEPS="${POST_STEPS}\n${STEP_NUM}. Authenticate Claude Code and MCP servers:"
  POST_STEPS="${POST_STEPS}\n   Follow the next-steps printed by agent-setup.sh"
else
  POST_STEPS="${POST_STEPS}\n${STEP_NUM}. Authenticate MCP servers (if needed):"
  POST_STEPS="${POST_STEPS}\n   Follow the next-steps printed by agent-setup.sh"
fi
STEP_NUM=$((STEP_NUM + 1))

POST_STEPS="${POST_STEPS}\n${STEP_NUM}. Test the orchestrator: ~/scripts/agent-orchestrator.sh --no-stop"

if [[ "${INSTALL_TTYD}" == "true" ]]; then
  POST_STEPS="${POST_STEPS}\n\n   After setup, use the web terminal at https://${ELASTIC_IP} for day-to-day access."
fi

echo ""
echo "============================================================"
echo ""
echo "DEPLOY STATUS: SUCCESS"
echo ""
echo "Instance ID:  ${INSTANCE_ID}"
echo "Elastic IP:   ${ELASTIC_IP}"
echo "Region:       ${AWS_REGION}"
echo "Mode:         ${SCHEDULE_MODE}"
echo "File sync:    ${FILE_SYNC}"
echo "Claude Code:  ${CLAUDE_VERSION}"
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "API key:      configured"
else
  echo "API key:      not set (use login or set manually)"
fi
if [[ "${INSTALL_TTYD}" == "true" ]]; then
  echo "Web terminal: https://${ELASTIC_IP}"
fi
echo ""
echo "Management commands (from this directory):"
echo "  ./agent-manager.sh              Show server status"
echo "  ./agent-manager.sh --ssh        SSH into the server"
echo "  ./agent-manager.sh --ssh-mcp    SSH with MCP port forwarding"
echo "  ./agent-manager.sh --wakeup     Start a stopped instance"
echo "  ./agent-manager.sh --sleep      Stop the instance"
echo "  ./agent-manager.sh --always-on  Switch to always-on mode"
echo "  ./agent-manager.sh --scheduled  Switch to scheduled mode"
echo ""
echo "Post-deploy steps needed:"
echo -e "${POST_STEPS}"
echo ""
echo "To tear down: ./teardown.sh"
echo ""
echo "============================================================"
