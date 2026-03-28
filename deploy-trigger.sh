#!/usr/bin/env bash
# =============================================================================
# Deploy Remote Trigger — Run from your LOCAL machine
# =============================================================================
# Creates a Lambda Function URL that starts the agent server instance.
# Designed for triggering agent runs from any device (e.g., iPhone via
# iOS Shortcuts). Requires deploy-state.json from a prior deploy.sh run.
#
# Usage:
#   ./deploy-trigger.sh            # show current trigger URL and token
#   ./deploy-trigger.sh --deploy   # deploy or update the trigger
#   ./deploy-trigger.sh --remove   # remove all trigger resources
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="${SCRIPT_DIR}/deploy-state.json"
CONF_FILE="${SCRIPT_DIR}/agent.conf"

TRIGGER_FUNCTION_NAME="agent-server-trigger"
TRIGGER_ROLE_NAME="agent-server-trigger-role"

# --- Load config for defaults ------------------------------------------------
if [[ -f "${CONF_FILE}" ]]; then
  source "${CONF_FILE}"
fi

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[TRIGGER]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Read state file ---------------------------------------------------------
if [[ ! -f "${STATE_FILE}" ]]; then
  err "State file not found: ${STATE_FILE}"
  echo ""
  echo "  Run deploy.sh first to create the agent server infrastructure."
  exit 1
fi

json_get() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],''))" \
    "${STATE_FILE}" "$1"
}

json_set() {
  python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
d[sys.argv[2]] = sys.argv[3]
json.dump(d, open(f, 'w'), indent=2)
" "${STATE_FILE}" "$1" "$2"
}

json_delete() {
  python3 -c "
import json, sys
f = sys.argv[1]
d = json.load(open(f))
for k in sys.argv[2:]:
    d.pop(k, None)
json.dump(d, open(f, 'w'), indent=2)
" "${STATE_FILE}" "$@"
}

INSTANCE_ID="$(json_get instance_id)"
REGION="$(json_get region)"
REGION="${REGION:-${AWS_REGION:-eu-north-1}}"

if [[ -z "${INSTANCE_ID}" ]]; then
  err "No instance_id found in deploy-state.json. Run deploy.sh first."
  exit 1
fi

# --- Show mode (default) -----------------------------------------------------
show_trigger() {
  local trigger_url trigger_token
  trigger_url="$(json_get trigger_function_url)"
  trigger_token="$(json_get trigger_token)"

  if [[ -z "${trigger_url}" ]]; then
    echo "No remote trigger deployed."
    echo "  Run ./deploy-trigger.sh --deploy to set one up."
    exit 0
  fi

  echo ""
  echo "============================================================"
  echo " REMOTE TRIGGER"
  echo "============================================================"
  echo ""
  echo "  Function URL:"
  echo "    ${trigger_url}"
  echo ""
  echo "  Bearer Token:"
  echo "    ${trigger_token}"
  echo ""
  echo "  Test:"
  echo "    curl -s -X POST '${trigger_url}' \\"
  echo "      -H 'Authorization: Bearer ${trigger_token}' | python3 -m json.tool"
  echo ""
  echo "  iOS Shortcuts:"
  echo "    Action:  Get Contents of URL"
  echo "    URL:     ${trigger_url}"
  echo "    Method:  POST"
  echo "    Headers: Authorization = Bearer ${trigger_token}"
  echo ""
  echo "============================================================"
}

if [[ "${1:-}" == "--show" || -z "${1:-}" ]]; then
  show_trigger
  exit 0
fi

# --- Remove mode -------------------------------------------------------------
if [[ "${1:-}" == "--remove" ]]; then
  log "Removing remote trigger resources..."

  # Delete Function URL config
  aws lambda delete-function-url-config \
    --function-name "${TRIGGER_FUNCTION_NAME}" \
    --region "${REGION}" > /dev/null 2>&1 || true

  # Delete Lambda function
  aws lambda delete-function \
    --function-name "${TRIGGER_FUNCTION_NAME}" \
    --region "${REGION}" > /dev/null 2>&1 || true
  log "Lambda function removed."

  # Delete IAM role
  aws iam detach-role-policy \
    --role-name "${TRIGGER_ROLE_NAME}" \
    --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
    2>/dev/null || true
  aws iam delete-role-policy \
    --role-name "${TRIGGER_ROLE_NAME}" \
    --policy-name "ec2-trigger" \
    2>/dev/null || true
  aws iam delete-role \
    --role-name "${TRIGGER_ROLE_NAME}" \
    2>/dev/null || true
  log "IAM role removed."

  # Remove keys from state
  json_delete trigger_function_name trigger_function_url trigger_token trigger_role_name

  log "Done. Remote trigger removed."
  exit 0
fi

# --- Deploy mode (requires --deploy) -----------------------------------------
if [[ "${1:-}" != "--deploy" ]]; then
  err "Unknown argument: ${1}"
  echo ""
  echo "Usage:"
  echo "  ./deploy-trigger.sh            Show current trigger URL and token"
  echo "  ./deploy-trigger.sh --deploy   Deploy or update the trigger"
  echo "  ./deploy-trigger.sh --remove   Remove all trigger resources"
  exit 1
fi

echo ""
echo "============================================================"
echo " DEPLOYING REMOTE TRIGGER"
echo "============================================================"
echo ""
log "Instance: ${INSTANCE_ID}"
log "Region:   ${REGION}"
echo ""

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# --- 1. Create IAM role for Lambda -------------------------------------------
log "Creating IAM role..."

TRUST_POLICY=$(cat << 'TRUST'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
TRUST
)

aws iam create-role \
  --role-name "${TRIGGER_ROLE_NAME}" \
  --assume-role-policy-document "${TRUST_POLICY}" \
  --description "Allows Lambda to start agent EC2 instance" \
  > /dev/null 2>&1 || log "  (Role already exists, reusing)"

# Inline policy scoped to this instance
EC2_POLICY=$(cat << POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:StartInstances", "ec2:DescribeInstances"],
      "Resource": "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}"
    },
    {
      "Effect": "Allow",
      "Action": "ec2:DescribeInstances",
      "Resource": "*"
    }
  ]
}
POLICY
)

aws iam put-role-policy \
  --role-name "${TRIGGER_ROLE_NAME}" \
  --policy-name "ec2-trigger" \
  --policy-document "${EC2_POLICY}"

# Attach managed policy for CloudWatch Logs
aws iam attach-role-policy \
  --role-name "${TRIGGER_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" \
  2>/dev/null || true

log "IAM role configured."

# Wait for IAM propagation
log "Waiting for IAM role propagation..."
sleep 10

ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${TRIGGER_ROLE_NAME}"

# --- 2. Generate Bearer token ------------------------------------------------
EXISTING_TOKEN="$(json_get trigger_token)"
if [[ -n "${EXISTING_TOKEN}" ]]; then
  BEARER_TOKEN="${EXISTING_TOKEN}"
  log "Reusing existing Bearer token."
else
  BEARER_TOKEN=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))")
  log "Generated new Bearer token."
fi

# --- 3. Create Lambda function ------------------------------------------------
log "Packaging Lambda function..."

LAMBDA_TEMPLATE="${SCRIPT_DIR}/templates/trigger-lambda.py"
if [[ ! -f "${LAMBDA_TEMPLATE}" ]]; then
  err "Lambda template not found: ${LAMBDA_TEMPLATE}"
  exit 1
fi

TMPDIR=$(mktemp -d)
cp "${LAMBDA_TEMPLATE}" "${TMPDIR}/lambda_function.py"
(cd "${TMPDIR}" && zip -q lambda.zip lambda_function.py)

log "Creating Lambda function..."
if aws lambda create-function \
  --function-name "${TRIGGER_FUNCTION_NAME}" \
  --runtime python3.12 \
  --handler "lambda_function.lambda_handler" \
  --role "${ROLE_ARN}" \
  --zip-file "fileb://${TMPDIR}/lambda.zip" \
  --environment "Variables={SHARED_SECRET=${BEARER_TOKEN},INSTANCE_ID=${INSTANCE_ID},REGION=${REGION}}" \
  --timeout 15 \
  --memory-size 128 \
  --region "${REGION}" \
  > /dev/null 2>&1; then
  log "Lambda function created."
else
  log "Lambda function exists, updating..."
  aws lambda update-function-code \
    --function-name "${TRIGGER_FUNCTION_NAME}" \
    --zip-file "fileb://${TMPDIR}/lambda.zip" \
    --region "${REGION}" > /dev/null

  # Wait for update to complete before updating configuration
  aws lambda wait function-updated \
    --function-name "${TRIGGER_FUNCTION_NAME}" \
    --region "${REGION}" 2>/dev/null || sleep 5

  aws lambda update-function-configuration \
    --function-name "${TRIGGER_FUNCTION_NAME}" \
    --runtime python3.12 \
    --handler "lambda_function.lambda_handler" \
    --role "${ROLE_ARN}" \
    --environment "Variables={SHARED_SECRET=${BEARER_TOKEN},INSTANCE_ID=${INSTANCE_ID},REGION=${REGION}}" \
    --timeout 15 \
    --memory-size 128 \
    --region "${REGION}" > /dev/null
  log "Lambda function updated."
fi

rm -rf "${TMPDIR}"

# Wait for Lambda to become Active before creating Function URL
log "Waiting for Lambda function to become active..."
aws lambda wait function-active-v2 \
  --function-name "${TRIGGER_FUNCTION_NAME}" \
  --region "${REGION}" 2>/dev/null || sleep 5

# --- 4. Create Function URL ---------------------------------------------------
log "Configuring Function URL..."
FUNCTION_URL=$(aws lambda get-function-url-config \
  --function-name "${TRIGGER_FUNCTION_NAME}" \
  --region "${REGION}" \
  --query 'FunctionUrl' --output text 2>/dev/null || true)

if [[ -z "${FUNCTION_URL}" || "${FUNCTION_URL}" == "None" ]]; then
  FUNCTION_URL=$(aws lambda create-function-url-config \
    --function-name "${TRIGGER_FUNCTION_NAME}" \
    --auth-type NONE \
    --region "${REGION}" \
    --query 'FunctionUrl' --output text)

  # Add public invoke permissions (both required since Oct 2025)
  aws lambda add-permission \
    --function-name "${TRIGGER_FUNCTION_NAME}" \
    --statement-id "FunctionURLAllowPublicAccess" \
    --action "lambda:InvokeFunctionUrl" \
    --principal "*" \
    --function-url-auth-type NONE \
    --region "${REGION}" > /dev/null 2>&1 || true

  aws lambda add-permission \
    --function-name "${TRIGGER_FUNCTION_NAME}" \
    --statement-id "FunctionURLInvokeAllowPublicAccess" \
    --action "lambda:InvokeFunction" \
    --principal "*" \
    --region "${REGION}" > /dev/null 2>&1 || true

  log "Function URL created."
else
  log "Function URL already exists."
fi

# --- 5. Save state -----------------------------------------------------------
json_set trigger_function_name "${TRIGGER_FUNCTION_NAME}"
json_set trigger_function_url "${FUNCTION_URL}"
json_set trigger_token "${BEARER_TOKEN}"
json_set trigger_role_name "${TRIGGER_ROLE_NAME}"

# --- Done --------------------------------------------------------------------
echo ""
echo "============================================================"
echo " REMOTE TRIGGER DEPLOYED"
echo "============================================================"
echo ""
echo "  Function URL:"
echo "    ${FUNCTION_URL}"
echo ""
echo "  Bearer Token:"
echo "    ${BEARER_TOKEN}"
echo ""
echo "  Test:"
echo "    curl -s -X POST '${FUNCTION_URL}' \\"
echo "      -H 'Authorization: Bearer ${BEARER_TOKEN}' | python3 -m json.tool"
echo ""
echo "  iOS Shortcuts:"
echo "    Action:  Get Contents of URL"
echo "    URL:     ${FUNCTION_URL}"
echo "    Method:  POST"
echo "    Headers: Authorization = Bearer ${BEARER_TOKEN}"
echo ""
echo "============================================================"
