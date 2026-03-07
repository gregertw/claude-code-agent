#!/usr/bin/env bash
# =============================================================================
# Deploy EventBridge Scheduler — Run from your LOCAL machine
# =============================================================================
# Prerequisites:
#   - AWS CLI installed and configured (aws configure)
#   - Your EC2 instance ID (from AWS Console or: aws ec2 describe-instances)
#   - agent.conf in the same directory (for AWS_REGION default)
#
# Usage:
#   ./deploy-scheduler.sh <instance-id> [interval-minutes] [region]
#
# Examples:
#   ./deploy-scheduler.sh i-0abc123def456789          # hourly, default region
#   ./deploy-scheduler.sh i-0abc123def456789 30       # every 30 min
#   ./deploy-scheduler.sh i-0abc123def456789 120      # every 2 hours
#
# To remove the scheduler:
#   ./deploy-scheduler.sh --remove [region]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config for defaults (optional — region can also be passed as arg)
if [[ -f "${SCRIPT_DIR}/agent.conf" ]]; then
  source "${SCRIPT_DIR}/agent.conf"
fi

SCHEDULER_NAME="agent-server-start"
SCHEDULER_ROLE_NAME="agent-server-scheduler-role"

# --- Remove mode -------------------------------------------------------------
if [[ "${1:-}" == "--remove" ]]; then
  REGION="${2:-${AWS_REGION:-eu-north-1}}"
  echo "Removing EventBridge Scheduler in ${REGION}..."

  aws scheduler delete-schedule \
    --name "$SCHEDULER_NAME" \
    --region "$REGION" 2>/dev/null || echo "  (Schedule not found or already removed)"

  echo "Done. Scheduler removed."
  echo "  Note: IAM role '${SCHEDULER_ROLE_NAME}' left intact (harmless, reusable)."
  echo "  To delete it:"
  echo "    aws iam delete-role-policy --role-name ${SCHEDULER_ROLE_NAME} --policy-name ec2-start"
  echo "    aws iam delete-role --role-name ${SCHEDULER_ROLE_NAME}"
  exit 0
fi

# --- Create mode --------------------------------------------------------------
INSTANCE_ID="${1:?Usage: deploy-scheduler.sh <instance-id> [interval-minutes] [region]}"
INTERVAL="${2:-60}"
REGION="${3:-${AWS_REGION:-eu-north-1}}"

echo "Setting up EventBridge Scheduler to start instance ${INSTANCE_ID}"
echo "  Region: ${REGION}"
echo "  Interval: every ${INTERVAL} minutes"
echo ""

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account: ${ACCOUNT_ID}"

# --- 1. Create IAM role for Scheduler ----------------------------------------
echo "Creating IAM role..."

TRUST_POLICY=$(cat << 'TRUST'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "scheduler.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
TRUST
)

aws iam create-role \
  --role-name "$SCHEDULER_ROLE_NAME" \
  --assume-role-policy-document "$TRUST_POLICY" \
  --description "Allows EventBridge Scheduler to start agent EC2 instance" \
  2>/dev/null || echo "  (Role already exists, reusing)"

# Inline policy scoped to this instance
EC2_POLICY=$(cat << POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:StartInstances"],
      "Resource": "arn:aws:ec2:${REGION}:${ACCOUNT_ID}:instance/${INSTANCE_ID}"
    }
  ]
}
POLICY
)

aws iam put-role-policy \
  --role-name "$SCHEDULER_ROLE_NAME" \
  --policy-name "ec2-start" \
  --policy-document "$EC2_POLICY"

echo "  IAM role configured (scoped to instance ${INSTANCE_ID})"

# Wait for IAM propagation
echo "  Waiting for IAM role propagation..."
sleep 10

SCHEDULER_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${SCHEDULER_ROLE_NAME}"

# --- 2. Create EventBridge Schedule ------------------------------------------
echo "Creating EventBridge Schedule..."

aws scheduler create-schedule \
  --name "$SCHEDULER_NAME" \
  --schedule-expression "rate(${INTERVAL} minutes)" \
  --target "{
    \"Arn\": \"arn:aws:scheduler:::aws-sdk:ec2:startInstances\",
    \"RoleArn\": \"${SCHEDULER_ROLE_ARN}\",
    \"Input\": \"{\\\"InstanceIds\\\":[\\\"${INSTANCE_ID}\\\"]}\"
  }" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --state ENABLED \
  --region "$REGION" \
  2>/dev/null || \
aws scheduler update-schedule \
  --name "$SCHEDULER_NAME" \
  --schedule-expression "rate(${INTERVAL} minutes)" \
  --target "{
    \"Arn\": \"arn:aws:scheduler:::aws-sdk:ec2:startInstances\",
    \"RoleArn\": \"${SCHEDULER_ROLE_ARN}\",
    \"Input\": \"{\\\"InstanceIds\\\":[\\\"${INSTANCE_ID}\\\"]}\"
  }" \
  --flexible-time-window '{"Mode":"OFF"}' \
  --state ENABLED \
  --region "$REGION"

echo "  EventBridge Schedule created/updated."

# --- Done --------------------------------------------------------------------
echo ""
echo "============================================================"
echo " SCHEDULER DEPLOYED"
echo "============================================================"
echo ""
echo "Instance ${INSTANCE_ID} will be started every ${INTERVAL} minutes."
echo "The instance self-stops after running tasks (if SCHEDULE_MODE=scheduled)."
echo ""
echo "Estimated monthly cost:"
echo "  ~10-15 min runtime/hr x \$0.0834/hr = ~\$12-18/month compute"
echo "  + EBS: \$2.40/month + Elastic IP: \$3.65/month"
echo "  Total: ~\$18-24/month"
echo ""
echo "To pause:  aws scheduler update-schedule --name ${SCHEDULER_NAME} --state DISABLED --region ${REGION} ..."
echo "To remove: ./deploy-scheduler.sh --remove"
echo "============================================================"
