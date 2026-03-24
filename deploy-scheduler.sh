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
#   ./deploy-scheduler.sh <instance-id> [interval-minutes] [region] [hours] [weekend-hours]
#
# Examples:
#   ./deploy-scheduler.sh i-0abc123def456789              # hourly 6-22, default region
#   ./deploy-scheduler.sh i-0abc123def456789 30           # every 30 min, 6-22
#   ./deploy-scheduler.sh i-0abc123def456789 60 eu-north-1 6-18 8,17  # hourly weekdays, 8am+5pm weekends
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
SCHEDULER_NAME_WEEKEND="agent-server-start-weekend"
SCHEDULER_ROLE_NAME="agent-server-scheduler-role"

# --- Build EventBridge cron expression from interval + hours ----------------
# EventBridge cron: cron(minutes hours day-of-month month day-of-week year)
# rate() fires at arbitrary offsets and 24/7. cron() aligns with :00 and
# restricts to active hours — matching the server-side cron job.
build_cron_expression() {
  local interval="$1"
  local hours="$2"
  local dow="${3:-?}"  # day-of-week field, default ? (any)

  # EventBridge doesn't support range syntax (e.g. "6-18") when day-of-week
  # is specified. Always enumerate hours to be safe.
  local hour_list=""
  if [[ "${hours}" == *-* ]]; then
    local hour_start="${hours%%-*}"
    local hour_end="${hours##*-}"
    local hour_step=$(( interval / 60 ))
    [[ ${hour_step} -lt 1 ]] && hour_step=1
    for (( h=hour_start; h<=hour_end; h+=hour_step )); do
      [[ -n "${hour_list}" ]] && hour_list+=","
      hour_list+="${h}"
    done
  else
    # Already a list (e.g. "8,17")
    hour_list="${hours}"
  fi

  # EventBridge: when day-of-week is specified, day-of-month must be "?"
  local dom="*"
  [[ "${dow}" != "?" ]] && dom="?"

  if [[ "${interval}" -le 59 && "${dow}" == "?" ]]; then
    # Sub-hourly without day-of-week filter: use step syntax
    echo "cron(0/${interval} ${hour_list} ${dom} * ${dow} *)"
  else
    # Hourly or with day-of-week: fire at :00 for each listed hour
    echo "cron(0 ${hour_list} ${dom} * ${dow} *)"
  fi
}

# Helper: create or update an EventBridge schedule
create_or_update_schedule() {
  local name="$1"
  local cron_expr="$2"
  local timezone="$3"
  local role_arn="$4"
  local instance_id="$5"
  local region="$6"

  aws scheduler create-schedule \
    --name "${name}" \
    --schedule-expression "${cron_expr}" \
    --schedule-expression-timezone "${timezone}" \
    --target "{
      \"Arn\": \"arn:aws:scheduler:::aws-sdk:ec2:startInstances\",
      \"RoleArn\": \"${role_arn}\",
      \"Input\": \"{\\\"InstanceIds\\\":[\\\"${instance_id}\\\"]}\"
    }" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --state ENABLED \
    --region "${region}" \
    2>/dev/null || \
  aws scheduler update-schedule \
    --name "${name}" \
    --schedule-expression "${cron_expr}" \
    --schedule-expression-timezone "${timezone}" \
    --target "{
      \"Arn\": \"arn:aws:scheduler:::aws-sdk:ec2:startInstances\",
      \"RoleArn\": \"${role_arn}\",
      \"Input\": \"{\\\"InstanceIds\\\":[\\\"${instance_id}\\\"]}\"
    }" \
    --flexible-time-window '{"Mode":"OFF"}' \
    --state ENABLED \
    --region "${region}"
}

# --- Remove mode -------------------------------------------------------------
if [[ "${1:-}" == "--remove" ]]; then
  REGION="${2:-${AWS_REGION:-eu-north-1}}"
  echo "Removing EventBridge Scheduler in ${REGION}..."

  aws scheduler delete-schedule \
    --name "$SCHEDULER_NAME" \
    --region "$REGION" 2>/dev/null || echo "  (Schedule '${SCHEDULER_NAME}' not found or already removed)"
  aws scheduler delete-schedule \
    --name "$SCHEDULER_NAME_WEEKEND" \
    --region "$REGION" 2>/dev/null || echo "  (Schedule '${SCHEDULER_NAME_WEEKEND}' not found or already removed)"

  echo "Done. Scheduler removed."
  echo "  Note: IAM role '${SCHEDULER_ROLE_NAME}' left intact (harmless, reusable)."
  echo "  To delete it:"
  echo "    aws iam delete-role-policy --role-name ${SCHEDULER_ROLE_NAME} --policy-name ec2-start"
  echo "    aws iam delete-role --role-name ${SCHEDULER_ROLE_NAME}"
  exit 0
fi

# --- Create mode --------------------------------------------------------------
INSTANCE_ID="${1:?Usage: deploy-scheduler.sh <instance-id> [interval-minutes] [region] [hours] [weekend-hours]}"
INTERVAL="${2:-60}"
REGION="${3:-${AWS_REGION:-eu-north-1}}"
HOURS="${4:-${SCHEDULE_HOURS:-6-22}}"
WEEKEND_HOURS="${5:-${SCHEDULE_WEEKEND_HOURS:-}}"

# Read timezone from deploy-state.json (set during deploy.sh)
TIMEZONE="UTC"
if [[ -f "${SCRIPT_DIR}/deploy-state.json" ]]; then
  TIMEZONE=$(python3 -c "import json; print(json.load(open('${SCRIPT_DIR}/deploy-state.json')).get('timezone', 'UTC'))" 2>/dev/null || echo "UTC")
fi

echo "Setting up EventBridge Scheduler to start instance ${INSTANCE_ID}"
echo "  Region: ${REGION}"
echo "  Interval: every ${INTERVAL} minutes"
echo "  Active hours (weekdays): ${HOURS} (${TIMEZONE})"
if [[ -n "${WEEKEND_HOURS}" ]]; then
  echo "  Active hours (weekends): ${WEEKEND_HOURS} (${TIMEZONE})"
fi
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

# --- 2. Create EventBridge Schedule(s) ----------------------------------------
if [[ -n "${WEEKEND_HOURS}" ]]; then
  # Weekday schedule (Mon-Fri)
  CRON_EXPR_WEEKDAY=$(build_cron_expression "${INTERVAL}" "${HOURS}" "MON-FRI")
  echo "Creating EventBridge Schedule (weekdays)..."
  echo "  Expression: ${CRON_EXPR_WEEKDAY}"
  create_or_update_schedule "${SCHEDULER_NAME}" "${CRON_EXPR_WEEKDAY}" "${TIMEZONE}" "${SCHEDULER_ROLE_ARN}" "${INSTANCE_ID}" "${REGION}"
  echo "  Weekday schedule created/updated."

  # Weekend schedule (Sat-Sun)
  CRON_EXPR_WEEKEND="cron(0 ${WEEKEND_HOURS} ? * SAT,SUN *)"
  echo "Creating EventBridge Schedule (weekends)..."
  echo "  Expression: ${CRON_EXPR_WEEKEND}"
  create_or_update_schedule "${SCHEDULER_NAME_WEEKEND}" "${CRON_EXPR_WEEKEND}" "${TIMEZONE}" "${SCHEDULER_ROLE_ARN}" "${INSTANCE_ID}" "${REGION}"
  echo "  Weekend schedule created/updated."

  CRON_EXPR="${CRON_EXPR_WEEKDAY} / ${CRON_EXPR_WEEKEND}"
else
  # Single schedule for all days (backward compatible)
  CRON_EXPR=$(build_cron_expression "${INTERVAL}" "${HOURS}")
  echo "Creating EventBridge Schedule..."
  echo "  Expression: ${CRON_EXPR}"
  create_or_update_schedule "${SCHEDULER_NAME}" "${CRON_EXPR}" "${TIMEZONE}" "${SCHEDULER_ROLE_ARN}" "${INSTANCE_ID}" "${REGION}"
  echo "  EventBridge Schedule created/updated."

  # Remove weekend schedule if it exists from a previous config
  aws scheduler delete-schedule \
    --name "$SCHEDULER_NAME_WEEKEND" \
    --region "$REGION" 2>/dev/null || true
fi

echo "  Timezone: ${TIMEZONE}"

# --- Done --------------------------------------------------------------------
echo ""
echo "============================================================"
echo " SCHEDULER DEPLOYED"
echo "============================================================"
echo ""
echo "Instance ${INSTANCE_ID} will be started on schedule:"
echo "  Expression:   ${CRON_EXPR}"
echo "  Timezone:     ${TIMEZONE}"
echo "  Active hours: ${HOURS}"
if [[ -n "${WEEKEND_HOURS}" ]]; then
  echo "  Weekend:      ${WEEKEND_HOURS}"
fi
echo "  Interval:     every ${INTERVAL} minutes"
echo ""
echo "The instance self-stops after running tasks (if SCHEDULE_MODE=scheduled)."
echo ""
echo "To pause:  aws scheduler update-schedule --name ${SCHEDULER_NAME} --state DISABLED --region ${REGION} ..."
echo "To remove: ./deploy-scheduler.sh --remove"
echo "============================================================"
