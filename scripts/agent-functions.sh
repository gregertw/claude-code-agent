#!/usr/bin/env bash
# =============================================================================
# Shared functions for agent server scripts.
# Sourced by agent-orchestrator.sh, agent-resume-check.sh, etc.
# =============================================================================

# Hibernate the instance (or fall back to shutdown).
do_hibernate() {
  local reason="${1:-Self-stop}"
  echo "${reason}: hibernating instance..."
  local inst_id region
  inst_id=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null || echo "")
  region=$(curl -s --max-time 3 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
  if [[ -n "${inst_id}" && -n "${region}" ]]; then
    aws ec2 stop-instances --instance-ids "${inst_id}" --region "${region}" --hibernate 2>/dev/null || sudo shutdown -h now
  else
    echo "Could not get instance metadata. Falling back to shutdown."
    sudo shutdown -h now
  fi
}

# Check if current hour is within active hours. Returns 0 if inside, 1 if outside.
check_active_hours() {
  local hours="${1:-6-22}"
  local current_hour
  current_hour=$(date +%-H)
  local hour_start="${hours%%-*}"
  local hour_end="${hours##*-}"
  if [[ ${current_hour} -lt ${hour_start} || ${current_hour} -gt ${hour_end} ]]; then
    return 1
  fi
  return 0
}
