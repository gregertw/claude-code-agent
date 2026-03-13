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

# Start Maestral daemon fresh. Called at the beginning of an orchestrator run.
# By starting/stopping per-run instead of running continuously, we avoid all
# hibernation recovery issues (daemon unreachable, stale state, etc.).
# Usage: start_dropbox_sync [home_dir]
start_dropbox_sync() {
  local home_dir="${1:-${HOME:-/home/ubuntu}}"
  local maestral_bin="${home_dir}/.local/bin/maestral"

  if [[ ! -x "${maestral_bin}" ]]; then
    return 0
  fi

  echo "Starting Maestral for Dropbox sync..."

  # Close the orchestrator lock fd so Maestral daemon doesn't inherit it.
  # If Maestral inherits the lock, it blocks future orchestrator runs after hibernate.
  local lock_fd="${_ORCH_LOCK_FD:-}"

  # Stop any stale daemon from a previous run or pre-hibernate state
  timeout 10 "${maestral_bin}" stop >/dev/null 2>&1 || true
  sleep 1

  # Start fresh
  if [[ -n "${lock_fd}" ]]; then
    eval "timeout 30 \"${maestral_bin}\" start ${lock_fd}>&- >/dev/null 2>&1 || true"
  else
    timeout 30 "${maestral_bin}" start >/dev/null 2>&1 || true
  fi

  # Wait for daemon to be reachable
  local maestral_ready=false
  for i in $(seq 1 12); do
    if timeout 10 "${maestral_bin}" status &>/dev/null; then
      maestral_ready=true
      break
    fi
    echo "  Waiting for maestral daemon... (attempt ${i})"
    sleep 5
  done

  if [[ "${maestral_ready}" != "true" ]]; then
    echo "WARNING: Maestral daemon not reachable after 60s. Skipping Dropbox sync."
    return 1
  fi

  echo "Maestral daemon started."
  return 0
}

# Wait for Maestral to finish syncing (download or upload). Polls until
# global status is "Up to date" / "Idle", then verifies no individual files
# under brain/ are still in transit.
# Usage: wait_for_dropbox_idle [home_dir]
wait_for_dropbox_idle() {
  local home_dir="${1:-${HOME:-/home/ubuntu}}"
  local maestral_bin="${home_dir}/.local/bin/maestral"
  local brain_dir="${home_dir}/brain"

  if [[ ! -x "${maestral_bin}" ]]; then
    return 0
  fi

  # Verify daemon is running
  if ! timeout 10 "${maestral_bin}" status &>/dev/null; then
    echo "WARNING: Maestral daemon not running. Cannot wait for sync."
    return 1
  fi

  echo "Waiting for Dropbox sync to complete..."
  local sync_wait=0
  local sync_timeout=120
  while [[ ${sync_wait} -lt ${sync_timeout} ]]; do
    local sync_status
    sync_status=$(timeout 10 "${maestral_bin}" status 2>/dev/null || echo "")
    if echo "${sync_status}" | grep -qi "up to date\|idle"; then
      break
    fi
    sleep 5
    sync_wait=$((sync_wait + 5))
  done

  if [[ ${sync_wait} -ge ${sync_timeout} ]]; then
    echo "WARNING: Dropbox sync did not complete within ${sync_timeout}s. Proceeding anyway."
    return 0
  fi

  # Global status says "Up to date" but individual files may still be in transit.
  # Check recently modified files under brain/ to catch the race.
  local file_timeout=60
  local file_wait=0
  local pending
  while [[ ${file_wait} -lt ${file_timeout} ]]; do
    pending=""
    while IFS= read -r f; do
      local fstatus
      fstatus=$(timeout 10 "${maestral_bin}" filestatus "${f}" 2>/dev/null || echo "")
      if echo "${fstatus}" | grep -qi "uploading\|syncing\|downloading"; then
        pending="${pending} $(basename "${f}")"
      fi
    done < <(find "${brain_dir}" -type f -mmin -10 2>/dev/null)

    if [[ -z "${pending}" ]]; then
      echo "Dropbox sync complete."
      return 0
    fi
    echo "  Waiting for file transfers:${pending}"
    sleep 5
    file_wait=$((file_wait + 5))
  done

  echo "WARNING: Some files still syncing after ${file_timeout}s:${pending}"
  return 0
}

# Stop Maestral daemon cleanly. Called after post-run sync before hibernation.
# Usage: stop_dropbox_sync [home_dir]
stop_dropbox_sync() {
  local home_dir="${1:-${HOME:-/home/ubuntu}}"
  local maestral_bin="${home_dir}/.local/bin/maestral"

  if [[ ! -x "${maestral_bin}" ]]; then
    return 0
  fi

  echo "Stopping Maestral daemon..."
  timeout 15 "${maestral_bin}" stop >/dev/null 2>&1 || true
  echo "Maestral stopped."
  return 0
}

# Legacy wrapper for backward compatibility (e.g. other scripts calling this).
# Starts daemon if needed, waits for idle, but does NOT stop.
# Usage: wait_for_dropbox_sync [home_dir]
wait_for_dropbox_sync() {
  local home_dir="${1:-${HOME:-/home/ubuntu}}"
  start_dropbox_sync "${home_dir}" && wait_for_dropbox_idle "${home_dir}"
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
