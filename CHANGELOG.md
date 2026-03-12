# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## 2026-03-12

### Added

- Add pre-run Dropbox sync to orchestrator — ensure remote files are downloaded before Claude starts
- Start maestral daemon explicitly if not running after hibernate resume
- Add `--log [N]` command to agent-manager.sh — show Nth most recent orchestrator and agent run log
- Add feedback callout header to task output files

### Changed

- Extract Dropbox sync into shared `wait_for_dropbox_sync()` with timeouts on all maestral commands
- Source `.agent-schedule` after `.agent-server.conf` so schedule-specific settings always win
- Use 80% of schedule interval as resume-check threshold to avoid skipping runs on wake
- Switch EventBridge from `rate()` to `cron()` expressions with active hours and timezone
- Move server-side scripts into `scripts/` directory, keeping deploy/manager scripts in root
- Extract 4 inline heredoc scripts from setup.sh into standalone files
- Update `agent upgrade` to pull server scripts from `scripts/` subdirectory
- Update set-schedule-mode.sh to accept interval and hours arguments

### Fixed

- Fix Dropbox sync skipped after hibernate resume — wait up to 60s for maestral daemon
- Fix resume-check skipping runs due to tight interval threshold and boot time
- Fix `.agent-server.conf` overriding schedule settings from `set-schedule-mode.sh`
- Fix cron job running as root instead of ubuntu under sudo
- Fix set-schedule-mode.sh failing under sudo — detect `SUDO_USER` for correct home directory
- Fix `--run-agent` falsely reporting orchestrator already running — use flock check

## 2026-03-11

### Added

- Add `SCHEDULE_HOURS` config to restrict cron and EventBridge to active hours
- Add resume-from-hibernation systemd service with staleness check
- Add active-hours guard — self-stop immediately if woken outside `SCHEDULE_HOURS`
- Add shared `agent-functions.sh` with `do_hibernate()` and `check_active_hours()`

### Fixed

- Fix MCP warm-up hanging indefinitely — use `--kill-after` with timeout and `disown`

## 2026-03-10

### Added

- Add MCP warm-up step — background Claude call to initialize MCP connections before main run
- Add cron job to run orchestrator every SCHEDULE_INTERVAL minutes
- Add flock-based locking to prevent concurrent orchestrator runs
- Wait for Dropbox sync before self-stopping (polls maestral status, 120s timeout)
- Add `--run-agent` command to agent-manager.sh — wake instance and trigger a run
- Add `--history [N]` command to agent-manager.sh — ASCII timeline of activity
- Add pre-flight tool check to agent-manager.sh
- Set server timezone to match local machine during deploy
- Add ARCHITECTURE.md documenting repo structure and task execution flow
- Copy setup-dropbox.sh into ~/scripts/ during server setup

### Changed

- Rewrite Dropbox selective sync to pause maestral and parse `maestral ls -l` output
- Update quick-start prompt to tell AI to download the zip directly
- Link ARCHITECTURE.md from README.md
- Consolidate setup-mcp.sh into agent-setup.sh
- Consolidate run logs to single location (`output/logs/`)

### Fixed

- Fix Dropbox sync race — pause+resume maestral to force local rescan of new files
- Fix duplicate run logs — write directly to `output/logs/` instead of copy
- Fix Dropbox sync check always timing out (blank line in `maestral status` output)
- Fix orchestrator not running periodically when instance stays up
- Fix Dropbox setup failing to exclude folders (maestral not paused during changes)

### Removed

- Remove setup-mcp.sh (merged into agent-setup.sh)

## 2026-03-09

### Added

- Add agent-manager.sh for managing the server from a local machine
- Add unified agent-setup.sh replacing separate setup scripts
- Replace Dropbox daemon with Maestral for reliable selective sync

### Changed

- Simplify post-deploy flow: Claude login before agent-setup.sh

## 2026-03-08

### Added

- Add daily self-review task and improvement proposals workflow
- Add output/research/ folder and meeting prep research to calendar task

### Changed

- Restructure brain directory, add templates and ActingWeb docs
- Rewrite README for clearer AI-guided setup flow

## 2026-03-07

### Added

- Initial release: AWS-based Claude Code agent for autonomous 24x7 operation
- Deploy/teardown scripts for EC2 with hibernate support
