#!/usr/bin/env bash
# =============================================================================
# AWS Ubuntu Agent Server — Teardown Script
# =============================================================================
# Destroys all AWS resources created by deploy.sh.
# Reads state from deploy-state.json in the same directory.
#
# Usage:
#   ./teardown.sh              # interactive — confirms before destroying
#   ./teardown.sh --yes        # skip confirmation prompt
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/deploy-state.json"
CONF_FILE="${SCRIPT_DIR}/agent.conf"

# --- Load config for defaults ------------------------------------------------
if [[ -f "${CONF_FILE}" ]]; then
  source "${CONF_FILE}"
fi

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[TEARDOWN]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Parse flags -------------------------------------------------------------
AUTO_YES=false
for arg in "$@"; do
  case "$arg" in
    --yes|-y) AUTO_YES=true ;;
    *)        err "Unknown argument: $arg"; exit 1 ;;
  esac
done

# --- Read state file ---------------------------------------------------------
if [[ ! -f "${STATE_FILE}" ]]; then
  err "State file not found: ${STATE_FILE}"
  echo ""
  echo "  This script reads deploy-state.json to know which resources to destroy."
  echo "  If you deployed manually or the file was deleted, you will need to"
  echo "  remove resources by hand using the AWS Console or CLI."
  exit 1
fi

# Parse JSON values (using python3 for portability — available on macOS & Ubuntu)
json_get() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],''))" \
    "${STATE_FILE}" "$1"
}

INSTANCE_ID="$(json_get instance_id)"
ELASTIC_IP_ALLOC="$(json_get elastic_ip_allocation_id)"
ELASTIC_IP="$(json_get elastic_ip)"
SECURITY_GROUP_ID="$(json_get security_group_id)"
KEY_PAIR_NAME="$(json_get key_pair_name)"
REGION="$(json_get region)"
SSH_CONFIG_HOST="$(json_get ssh_config_host)"

# Fall back to agent.conf / default for region
REGION="${REGION:-${AWS_REGION:-eu-north-1}}"

# --- Show what will be destroyed ---------------------------------------------
echo ""
echo -e "${RED}============================================================${NC}"
echo -e "${RED} TEARDOWN — The following resources will be DESTROYED${NC}"
echo -e "${RED}============================================================${NC}"
echo ""
echo "  Region:             ${REGION}"
[[ -n "${INSTANCE_ID}" ]]      && echo "  EC2 Instance:       ${INSTANCE_ID}"
[[ -n "${ELASTIC_IP}" ]]       && echo "  Elastic IP:         ${ELASTIC_IP} (${ELASTIC_IP_ALLOC})"
[[ -n "${SECURITY_GROUP_ID}" ]] && echo "  Security Group:     ${SECURITY_GROUP_ID}"
[[ -n "${KEY_PAIR_NAME}" ]]    && echo "  Key Pair:           ${KEY_PAIR_NAME} + ~/.ssh/${KEY_PAIR_NAME}.pem"
[[ -n "${SSH_CONFIG_HOST}" ]]  && echo "  SSH Config Host:    ${SSH_CONFIG_HOST} (in ~/.ssh/config)"
TRIGGER_FUNCTION="$(json_get trigger_function_name)"
[[ -n "${TRIGGER_FUNCTION}" ]] && echo "  Lambda Trigger:     ${TRIGGER_FUNCTION}"
echo "  EventBridge:        agent-server-start scheduler"
echo "  IAM Roles:          agent-server-scheduler-role, agent-server-role"
echo "  IAM Profile:        agent-server-profile"
echo ""
echo -e "${RED}  This action is irreversible.${NC}"
echo ""

# --- Confirm -----------------------------------------------------------------
if [[ "${AUTO_YES}" != true ]]; then
  read -r -p "Are you sure you want to destroy all resources? (yes/no): " CONFIRM
  if [[ "${CONFIRM}" != "yes" ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# --- Helper: run AWS command, swallow "not found" errors ---------------------
aws_ignore_missing() {
  local output
  if output=$("$@" 2>&1); then
    return 0
  else
    # Treat common "not found / already deleted" errors as non-fatal
    if echo "$output" | grep -qiE "not found|does not exist|NoSuchEntity|InvalidGroup\.NotFound|InvalidInstanceID\.NotFound|InvalidAllocationID\.NotFound|InvalidKeyPair\.NotFound|ResourceNotFoundException"; then
      warn "Resource already removed or not found — skipping."
      return 0
    else
      err "AWS command failed: $output"
      return 1
    fi
  fi
}

# --- 1. Remove EventBridge Scheduler ----------------------------------------
log "Removing EventBridge Scheduler..."
SCHEDULER_SCRIPT="${SCRIPT_DIR}/deploy-scheduler.sh"
if [[ -x "${SCHEDULER_SCRIPT}" ]]; then
  "${SCHEDULER_SCRIPT}" --remove "${REGION}" || warn "Scheduler removal had issues (may already be gone)."
else
  # Try direct removal if script not available
  aws_ignore_missing aws scheduler delete-schedule \
    --name "agent-server-start" \
    --region "${REGION}"
fi

# --- 1b. Remove Lambda Trigger -----------------------------------------------
TRIGGER_FUNCTION="$(json_get trigger_function_name)"
TRIGGER_ROLE="$(json_get trigger_role_name)"
if [[ -n "${TRIGGER_FUNCTION}" ]]; then
  log "Removing Lambda trigger function..."
  aws_ignore_missing aws lambda delete-function-url-config \
    --function-name "${TRIGGER_FUNCTION}" --region "${REGION}"
  aws_ignore_missing aws lambda delete-function \
    --function-name "${TRIGGER_FUNCTION}" --region "${REGION}"
fi
if [[ -n "${TRIGGER_ROLE}" ]]; then
  log "Removing Lambda trigger IAM role..."
  aws_ignore_missing aws iam detach-role-policy \
    --role-name "${TRIGGER_ROLE}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
  aws_ignore_missing aws iam delete-role-policy \
    --role-name "${TRIGGER_ROLE}" --policy-name "ec2-trigger"
  aws_ignore_missing aws iam delete-role \
    --role-name "${TRIGGER_ROLE}"
fi

# --- 2. Delete IAM role policy and role --------------------------------------
SCHEDULER_ROLE_NAME="agent-server-scheduler-role"
log "Deleting IAM role policy and role (${SCHEDULER_ROLE_NAME})..."
aws_ignore_missing aws iam delete-role-policy \
  --role-name "${SCHEDULER_ROLE_NAME}" \
  --policy-name "ec2-start"
aws_ignore_missing aws iam delete-role \
  --role-name "${SCHEDULER_ROLE_NAME}"

# --- 2b. Delete instance IAM role and profile (for self-hibernate) ----------
INSTANCE_ROLE_NAME="$(json_get iam_role_name)"
INSTANCE_PROFILE_NAME="$(json_get iam_instance_profile_name)"
INSTANCE_ROLE_NAME="${INSTANCE_ROLE_NAME:-agent-server-role}"
INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-agent-server-profile}"
log "Deleting instance IAM role and profile (${INSTANCE_ROLE_NAME})..."
aws_ignore_missing aws iam remove-role-from-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE_NAME}" \
  --role-name "${INSTANCE_ROLE_NAME}"
aws_ignore_missing aws iam delete-instance-profile \
  --instance-profile-name "${INSTANCE_PROFILE_NAME}"
aws_ignore_missing aws iam delete-role-policy \
  --role-name "${INSTANCE_ROLE_NAME}" \
  --policy-name "ec2-self-hibernate"
aws_ignore_missing aws iam delete-role \
  --role-name "${INSTANCE_ROLE_NAME}"

# --- 3. Terminate EC2 instance -----------------------------------------------
if [[ -n "${INSTANCE_ID}" ]]; then
  log "Terminating EC2 instance ${INSTANCE_ID}..."
  if aws_ignore_missing aws ec2 terminate-instances \
      --instance-ids "${INSTANCE_ID}" \
      --region "${REGION}"; then
    log "Waiting for instance to terminate (this may take a minute)..."
    aws ec2 wait instance-terminated \
      --instance-ids "${INSTANCE_ID}" \
      --region "${REGION}" 2>/dev/null || warn "Wait timed out or instance already gone."
    log "Instance terminated."
  fi
else
  warn "No instance_id in state — skipping EC2 termination."
fi

# --- 4. Release Elastic IP ---------------------------------------------------
if [[ -n "${ELASTIC_IP_ALLOC}" ]]; then
  log "Releasing Elastic IP ${ELASTIC_IP} (${ELASTIC_IP_ALLOC})..."
  aws_ignore_missing aws ec2 release-address \
    --allocation-id "${ELASTIC_IP_ALLOC}" \
    --region "${REGION}"
else
  warn "No elastic_ip_allocation_id in state — skipping Elastic IP release."
fi

# --- 5. Delete Security Group (with retry/backoff) ---------------------------
if [[ -n "${SECURITY_GROUP_ID}" ]]; then
  log "Deleting security group ${SECURITY_GROUP_ID}..."
  MAX_RETRIES=5
  RETRY_DELAY=10
  for (( i=1; i<=MAX_RETRIES; i++ )); do
    if aws ec2 delete-security-group \
        --group-id "${SECURITY_GROUP_ID}" \
        --region "${REGION}" 2>/dev/null; then
      log "Security group deleted."
      break
    else
      if (( i == MAX_RETRIES )); then
        err "Failed to delete security group after ${MAX_RETRIES} attempts."
        err "It may still be in use. Try manually:"
        err "  aws ec2 delete-security-group --group-id ${SECURITY_GROUP_ID} --region ${REGION}"
      else
        warn "Security group still in use (instance may still be shutting down). Retry ${i}/${MAX_RETRIES} in ${RETRY_DELAY}s..."
        sleep "${RETRY_DELAY}"
        RETRY_DELAY=$(( RETRY_DELAY * 2 ))
      fi
    fi
  done
else
  warn "No security_group_id in state — skipping security group deletion."
fi

# --- 6. Delete Key Pair ------------------------------------------------------
if [[ -n "${KEY_PAIR_NAME}" ]]; then
  log "Deleting key pair ${KEY_PAIR_NAME} from AWS..."
  aws_ignore_missing aws ec2 delete-key-pair \
    --key-name "${KEY_PAIR_NAME}" \
    --region "${REGION}"

  PEM_FILE="${HOME}/.ssh/${KEY_PAIR_NAME}.pem"
  if [[ -f "${PEM_FILE}" ]]; then
    log "Removing local key file ${PEM_FILE}..."
    rm -f "${PEM_FILE}"
  else
    warn "Local key file ${PEM_FILE} not found — skipping."
  fi
else
  warn "No key_pair_name in state — skipping key pair deletion."
fi

# --- 7. Remove SSH config entry ----------------------------------------------
SSH_CONFIG="${HOME}/.ssh/config"
if [[ -n "${SSH_CONFIG_HOST}" && -f "${SSH_CONFIG}" ]]; then
  log "Removing SSH config entry for Host ${SSH_CONFIG_HOST}..."
  # Remove the Host block: from "Host <name>" to the next "Host " line or EOF
  if grep -q "^Host ${SSH_CONFIG_HOST}$" "${SSH_CONFIG}" 2>/dev/null; then
    # Use awk to remove the block
    awk -v host="${SSH_CONFIG_HOST}" '
      BEGIN { skip=0 }
      /^Host / {
        if ($2 == host) { skip=1; next }
        else { skip=0 }
      }
      !skip { print }
    ' "${SSH_CONFIG}" > "${SSH_CONFIG}.tmp"
    mv "${SSH_CONFIG}.tmp" "${SSH_CONFIG}"
    chmod 600 "${SSH_CONFIG}"
    log "SSH config entry removed."
  else
    warn "No 'Host ${SSH_CONFIG_HOST}' block found in ${SSH_CONFIG} — skipping."
  fi
elif [[ -n "${SSH_CONFIG_HOST}" ]]; then
  warn "No ~/.ssh/config file found — skipping SSH config cleanup."
fi

# --- 8. Remove state file ----------------------------------------------------
log "Removing state file ${STATE_FILE}..."
rm -f "${STATE_FILE}"

# --- Done --------------------------------------------------------------------
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} TEARDOWN COMPLETE${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "  All resources have been destroyed (or were already gone)."
echo "  State file removed."
echo ""
