# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Mar 27, 2026]

### Added

- Add prompt injection defense section to task execution rules — treat all external content as untrusted, block exfiltration of infrastructure data
- Add security guardrails to email triage — email body content explicitly marked as untrusted input
- Add security note to meeting prep email cross-reference — thread content from external participants treated as untrusted
- Add installable capabilities system — optional features defined in `templates/capabilities/` with guided AI installation
- Add agentmail capability — agent email address for sending notifications and receiving instructions
- Add PreToolUse hook to protect settings files, hooks, and `.env` from agent edits
- Add deadline detection to email triage — emails with deadlines within 14 days are flagged as actionable regardless of sender type
- Add sender whitelisting to unsubscribe suggestions — senders matching interest keywords in 2+ of last 5 digests are never suggested for unsubscribe
- Add article link extraction to newsletter digest entries
- Add inline comment mechanism (`>` lines) to ACTIONS.md for quick owner-to-agent instructions on individual items
- Add "Last updated" timestamp to ACTIONS.md header, updated by the agent each run

### Changed

- Expand default permissions to allow curl, source, python3, cp, jq, and other common commands for autonomous operation
- Add explicit deny list for destructive commands (rm -rf, git push --force, git reset --hard, etc.)
- Preserve existing `settings.json` when `setup.sh` is re-run on an existing server
- `agent upgrade` now copies capabilities, hooks, and project settings from the repo

## [Mar 25, 2026]

### Added

- Add ACTIONS.md owner dashboard — agent updates it every run with action items, owner checks off or annotates
- Add personal-tasks.md for user-defined recurring tasks that are preserved on upgrade
- Add newsletter digest, follow-up tracking, and unsubscribe suggestions to email triage
- Add email cross-reference to calendar meeting prep (surfaces unresolved threads before meetings)
- Add daily news report task — compiles news from email newsletters filtered by personal interests
- Add Obsidian document templates (ai instruction, daily note, email, scratchpad, task)
- Add interest keywords and professional influences sections to personal.md template
- Add `--upgrade` flag to install-templates.sh — overwrites system files while preserving user customizations
- Add configurable Claude CLI flags in agent.conf (model, max-turns, output-format, permission-mode, max-budget, verbose, extra flags)
- Support CLI flag configuration in both orchestrator and run-agent.sh

### Changed

- `--wakeup` now auto-sets keep-running lock in scheduled mode so server stays up for manual work
- `--sleep` removes the keep-running lock before hibernating
- Split template files into system files (CLAUDE.md, tasks.md, default-tasks.md) and user files (personal.md, style.md, personal-tasks.md, ACTIONS.md)
- Replace `_agent-attention-needed` files with ACTIONS.md dashboard workflow
- Expand task sources from 3 to 4 (default tasks → personal tasks → inbox → ActingWeb)
- Increase per-task time budget from 5 to 10 minutes
- Condense logging format to audit-trail style (decisions and changes, not routine checks)
- Update ARCHITECTURE.md and README.md to reflect new dashboard, task sources, and directory structure

### Fixed

- Fix `--history` ignoring CloudWatch data when AWS returns non-UTC timezone offsets (e.g. `+01:00`)
- Fix server immediately hibernating on manual wakeup outside active hours — keep-running lock now bypasses the active-hours guard

## 2026-03-24

### Added

- Add `SCHEDULE_WEEKEND_HOURS` config for separate weekend schedules (e.g. `"8,17"` for 8am and 5pm only)
- Generate separate weekday/weekend cron lines and EventBridge schedules when weekend hours are configured
- Show cost estimate in `--status` with month-to-date actual (Cost Explorer) and projected monthly cost (based on current schedule)
- Derive projected cost from actual per-hour compute rate (CloudWatch) and measured run duration (orchestrator logs)

### Changed

- Replace systemd oneshot resume service with system-sleep hook for reliable hibernate resume on every cycle
- Clean up legacy agent-resume-runner.service on deploy and mode switch

## 2026-03-13

### Added

- Add CloudTrail fallback for `--history` — show run counts and events even when server is stopped
- Distinguish scheduled runs from manual wakeups in `--history` using CloudTrail userAgent

### Changed

- Start/stop Maestral per orchestrator run in scheduled mode instead of running continuously — eliminates all hibernation daemon recovery issues
- Split `wait_for_dropbox_sync()` into `start_dropbox_sync()`, `wait_for_dropbox_idle()`, and `stop_dropbox_sync()` functions
- Keep Maestral as a persistent systemd service in always-on mode for continuous sync
- `set-schedule-mode.sh` now enables/disables the Maestral systemd service based on mode
- Mark run counts as estimated (`~`) when using CloudTrail fallback instead of server logs

### Fixed

- Fix Maestral daemon inheriting orchestrator lock fd, blocking all subsequent runs after hibernate
- Close lock file descriptor before launching Maestral and MCP warm-up background processes
- Fix Dropbox post-run sync reporting complete before files are actually uploaded — verify individual file status after global sync
- Increase post-resume sleep from 2s to 5s to give Maestral time to detect new files

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
