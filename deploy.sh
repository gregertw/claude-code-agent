#!/usr/bin/env bash
# =============================================================================
# Deploy Agent Server — Run from your LOCAL machine
# =============================================================================
# One command to create all AWS resources, configure the server, set up
# MCP connections (with local OAuth), and optionally deploy the scheduler.
#
# Prerequisites:
#   - AWS CLI installed and configured
#   - agent.conf in the same directory (copy from agent.conf.example)
#   - An Anthropic API key
#   - ActingWeb (for cross-session memory — account auto-created on first /mcp auth)
#   - Node.js + npm locally (for mcporter OAuth flow)
#
# Usage:
#   export ANTHROPIC_API_KEY="sk-ant-..."   # set before running to skip prompt
#   ./deploy.sh                    # interactive — prompts for missing values
#   ./deploy.sh --skip-mcp         # skip MCP/OAuth setup (do it later)
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
SKIP_MCP=false
SKIP_SCHEDULER=false
for arg in "$@"; do
  case "$arg" in
    --skip-mcp) SKIP_MCP=true ;;
    --skip-scheduler) SKIP_SCHEDULER=true ;;
    --help|-h)
      echo "Usage: ./deploy.sh [--skip-mcp] [--skip-scheduler]"
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
log "Region: ${AWS_REGION} | Mode: ${SCHEDULE_MODE}"
echo ""

# --- Prompt for API key ------------------------------------------------------
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo -n "Anthropic API key (from console.anthropic.com): "
  read -r -s ANTHROPIC_API_KEY
  echo ""
  if [[ -z "${ANTHROPIC_API_KEY}" ]]; then
    err "API key is required."
    exit 1
  fi
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
  --ip-permissions "${RULES}" 2>/dev/null || warn "Ingress rules may already exist (continuing)"

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
ssh "${SSH_HOST}" "cd ~/agent-server && chmod +x setup.sh && sudo ./setup.sh" 2>&1 | while IFS= read -r line; do
  # Show only [SETUP], [WARN], and [ERROR] lines to reduce noise
  if echo "$line" | grep -qE '\[(SETUP|WARN|ERROR)\]'; then
    echo "$line"
  fi
done

if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
  err "setup.sh failed. SSH in to debug: ssh ${SSH_HOST}"
  exit 1
fi
log "Server setup complete."

# =============================================================================
step 9 "Set API Key and Verify"
# =============================================================================
ssh "${SSH_HOST}" "echo 'export ANTHROPIC_API_KEY=\"${ANTHROPIC_API_KEY}\"' > ~/.agent-env && chmod 600 ~/.agent-env"
log "API key configured."

CLAUDE_VERSION=$(ssh "${SSH_HOST}" "source ~/.agent-env && export PATH=\"\$HOME/.local/bin:\$PATH\" && claude --version" 2>/dev/null)
log "Claude Code ${CLAUDE_VERSION} verified."

# =============================================================================
step 10 "Configure MCP Connections"
# =============================================================================
if [[ "${SKIP_MCP}" == "true" ]]; then
  warn "Skipping MCP setup (--skip-mcp). Run setup-mcp.sh on the server later."
else
  # --- ActingWeb OAuth (run locally, copy tokens to server) ---
  if [[ "${SETUP_ACTINGWEB:-true}" == "true" ]]; then
    log "Setting up ActingWeb MCP (OAuth runs in your local browser)..."

    # Ensure mcporter is available locally
    if ! command -v mcporter &>/dev/null; then
      log "Installing mcporter locally..."
      npm install -g mcporter 2>/dev/null
    fi

    # Configure mcporter locally (use a temp config to avoid polluting project)
    MCPORTER_TMP=$(mktemp -d)
    MCPORTER_CONFIG="${MCPORTER_TMP}/mcporter.json"
    cat > "${MCPORTER_CONFIG}" << 'MCPEOF'
{"mcpServers":{},"imports":[]}
MCPEOF

    mcporter config add actingweb https://ai.actingweb.io/mcp \
      --auth oauth --scope home \
      --persist "${MCPORTER_CONFIG}" 2>/dev/null || true

    echo ""
    echo "============================================================"
    echo "  ACTION REQUIRED: Browser sign-in"
    echo ""
    echo "  A browser window will open for ActingWeb OAuth sign-in."
    echo "  Please switch to your browser and complete the sign-in"
    echo "  when it appears."
    echo "============================================================"
    echo ""
    read -r -p "Press Enter to open the browser..."

    # Run mcporter auth locally (browser opens automatically)
    if mcporter auth actingweb --config "${MCPORTER_CONFIG}" --oauth-timeout 120000 2>/dev/null; then
      log "ActingWeb OAuth succeeded!"
    else
      # mcporter may crash but still save credentials — check
      if [[ -f "${HOME}/.mcporter/credentials.json" ]]; then
        if grep -q "tokens" "${HOME}/.mcporter/credentials.json" 2>/dev/null; then
          log "ActingWeb tokens found in credentials."
        else
          warn "OAuth may not have completed. Falling back to manual flow..."
          echo ""
          echo "The automated OAuth flow didn't complete cleanly."
          echo "We'll try a manual approach: capture the auth code and exchange tokens."
          echo ""

          # Read the registered client info
          CLIENT_ID=$(python3 -c "import json; d=json.load(open('${HOME}/.mcporter/credentials.json')); e=list(d['entries'].values())[0]; print(e['clientInfo']['client_id'])")
          CLIENT_SECRET=$(python3 -c "import json; d=json.load(open('${HOME}/.mcporter/credentials.json')); e=list(d['entries'].values())[0]; print(e['clientInfo']['client_secret'])")
          REDIRECT_PORT=$(python3 -c "import json,re; d=json.load(open('${HOME}/.mcporter/credentials.json')); e=list(d['entries'].values())[0]; m=re.search(r':(\d+)/', e['clientInfo']['redirect_uris'][0]); print(m.group(1))")
          REDIRECT_URI="http://127.0.0.1:${REDIRECT_PORT}/callback"
          CODE_VERIFIER=$(python3 -c "import json; d=json.load(open('${HOME}/.mcporter/credentials.json')); e=list(d['entries'].values())[0]; print(e['codeVerifier'])")
          STATE=$(python3 -c "import json; d=json.load(open('${HOME}/.mcporter/credentials.json')); e=list(d['entries'].values())[0]; print(e['state'])")
          CODE_CHALLENGE=$(echo -n "${CODE_VERIFIER}" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')

          ENCODED_REDIRECT=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${REDIRECT_URI}', safe=''))")
          AUTH_URL="https://ai.actingweb.io/oauth/authorize?response_type=code&client_id=${CLIENT_ID}&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256&redirect_uri=${ENCODED_REDIRECT}&state=${STATE}&scope=mcp&resource=https%3A%2F%2Fai.actingweb.io%2Fmcp"

          # Start a local callback server
          CALLBACK_CODE_FILE=$(mktemp)
          python3 -c "
import http.server, urllib.parse, threading, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if 'code' in params:
            with open('${CALLBACK_CODE_FILE}', 'w') as f: f.write(params['code'][0])
            self.send_response(200); self.send_header('Content-Type','text/html'); self.end_headers()
            self.wfile.write(b'<h1>Authorization successful!</h1><p>You can close this tab.</p>')
            threading.Thread(target=self.server.shutdown).start()
        else:
            self.send_response(400); self.end_headers(); self.wfile.write(b'No code')
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', ${REDIRECT_PORT}), H).serve_forever()
" &
          CALLBACK_PID=$!
          sleep 1

          # Open browser
          echo "============================================================"
          echo "  ACTION REQUIRED: Complete sign-in in your browser."
          echo "============================================================"
          echo ""
          open "${AUTH_URL}" 2>/dev/null || xdg-open "${AUTH_URL}" 2>/dev/null || {
            echo "Open this URL in your browser:"
            echo "  ${AUTH_URL}"
          }

          echo "Waiting for OAuth callback (up to 2 minutes)..."
          for i in $(seq 1 120); do
            if [[ -s "${CALLBACK_CODE_FILE}" ]]; then
              break
            fi
            sleep 1
          done
          kill ${CALLBACK_PID} 2>/dev/null || true

          if [[ -s "${CALLBACK_CODE_FILE}" ]]; then
            AUTH_CODE=$(cat "${CALLBACK_CODE_FILE}")
            log "Got authorization code. Exchanging for tokens..."

            TOKENS=$(curl -s -X POST "https://ai.actingweb.io/oauth/token" \
              -H "Content-Type: application/x-www-form-urlencoded" \
              -d "grant_type=authorization_code&code=${AUTH_CODE}&redirect_uri=${REDIRECT_URI}&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}&code_verifier=${CODE_VERIFIER}")

            if echo "${TOKENS}" | python3 -c "import json,sys; d=json.load(sys.stdin); assert 'access_token' in d" 2>/dev/null; then
              log "Tokens received!"

              # Inject tokens into credentials file
              python3 -c "
import json
creds = json.load(open('${HOME}/.mcporter/credentials.json'))
tokens = json.loads('''${TOKENS}''')
entry = list(creds['entries'].values())[0]
entry['tokens'] = {
    'access_token': tokens['access_token'],
    'token_type': tokens.get('token_type', 'Bearer'),
    'expires_in': tokens.get('expires_in', 3600),
    'refresh_token': tokens.get('refresh_token', ''),
    'scope': tokens.get('scope', 'mcp')
}
json.dump(creds, open('${HOME}/.mcporter/credentials.json', 'w'), indent=2)
"
              log "Credentials updated."
            else
              warn "Token exchange failed. You'll need to run setup-mcp.sh on the server later."
              echo "  Response: ${TOKENS}"
            fi
          else
            warn "OAuth callback timed out. Run setup-mcp.sh on the server later."
          fi
          rm -f "${CALLBACK_CODE_FILE}"
        fi
      else
        warn "No credentials saved. You'll need to run setup-mcp.sh on the server later."
      fi
    fi

    # Copy tokens to server and configure MCP as direct HTTP connection
    if [[ -f "${HOME}/.mcporter/credentials.json" ]] && grep -q "tokens\|access_token" "${HOME}/.mcporter/credentials.json" 2>/dev/null; then
      # Extract access token from mcporter credentials
      AW_ACCESS_TOKEN=$(python3 -c "
import json
d = json.load(open('${HOME}/.mcporter/credentials.json'))
e = list(d['entries'].values())[0]
print(e['tokens']['access_token'])
")

      # Write MCP config file for the orchestrator (direct HTTP, no mcporter needed)
      ssh "${SSH_HOST}" "cat > ~/.agent-mcp-config.json" << MCPCONF
{
  "mcpServers": {
    "actingweb": {
      "type": "http",
      "url": "https://ai.actingweb.io/mcp",
      "headers": {
        "Authorization": "Bearer ${AW_ACCESS_TOKEN}"
      }
    }
  }
}
MCPCONF
      ssh "${SSH_HOST}" "chmod 600 ~/.agent-mcp-config.json"

      log "ActingWeb MCP configured on server (direct HTTP)."
    fi

    # Clean up local temp config
    rm -rf "${MCPORTER_TMP}"
  fi
fi

# =============================================================================
step 11 "Deploy EventBridge Scheduler"
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
# Done
# =============================================================================
echo ""
echo "============================================================"
echo -e "${GREEN} DEPLOYMENT COMPLETE ${NC}"
echo "============================================================"
echo ""
echo "Instance:    ${INSTANCE_ID}"
echo "Elastic IP:  ${ELASTIC_IP}"
echo "SSH:         ssh ${SSH_HOST}"
if [[ "${INSTALL_TTYD}" == "true" ]]; then
  echo "Web terminal: https://${ELASTIC_IP} (self-signed cert)"
fi
echo "Mode:        ${SCHEDULE_MODE}"
echo ""
echo "State saved to: deploy-state.json"
echo "To tear down:   ./teardown.sh"
echo ""
echo "Next steps:"
echo "  ssh ${SSH_HOST}"
echo "  ~/scripts/agent-orchestrator.sh --no-stop   # test run"
echo "============================================================"
