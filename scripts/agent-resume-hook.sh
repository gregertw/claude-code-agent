#!/bin/sh
# =============================================================================
# system-sleep hook — trigger agent orchestrator on resume from hibernation
# =============================================================================
# Installed to /usr/lib/systemd/system-sleep/agent-resume
# Called by systemd-sleep with: $1 = pre|post, $2 = suspend|hibernate|hybrid-sleep
#
# Uses systemd-run to launch the resume-check asynchronously (non-blocking)
# so the sleep hook returns quickly.  This is reliable on every hibernate/resume
# cycle, unlike a systemd oneshot service with WantedBy=hibernate.target which
# may not re-trigger on consecutive resumes within the same boot session.
# =============================================================================

if [ "$1" = "post" ] && { [ "$2" = "hibernate" ] || [ "$2" = "hybrid-sleep" ]; }; then
    sleep 5  # wait for network/clock sync
    systemd-run --no-block --uid=ubuntu --gid=ubuntu \
        --setenv=HOME=/home/ubuntu \
        --unit=agent-resume-runner \
        /home/ubuntu/scripts/agent-resume-check.sh
fi
