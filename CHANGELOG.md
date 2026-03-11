# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Add `SCHEDULE_HOURS` config variable to restrict cron runs to active hours (default `6-22`)
- Add resume-from-hibernation systemd service — triggers orchestrator on wake, with staleness check to skip if the last run is recent enough
- Set server timezone to match local machine during deploy
- Add MCP warm-up step to orchestrator — fires a background Claude call to initialize all MCP connections before the main run
- Add ARCHITECTURE.md documenting repo structure, setup paths, server layout, and task execution flow
- Add cron job to run the orchestrator every SCHEDULE_INTERVAL minutes while the instance is up
- Add flock-based locking to the orchestrator to prevent concurrent runs
- Copy setup-dropbox.sh into ~/scripts/ during server setup
- Wait for Dropbox sync to complete before self-stopping the instance (polls maestral status, 120s timeout)

### Changed
- Consolidate run logs to single location (`output/logs/`) — remove `~/logs/` copy step, update CLI to read from brain dir
- Rewrite Dropbox selective sync to pause maestral, parse `maestral ls -l` output for sync status, and skip already-excluded folders
- Update quick-start prompt to tell AI to download the zip directly instead of web-fetching GitHub
- Link ARCHITECTURE.md from the reference section in README.md
- Update set-schedule-mode.sh to accept an optional interval argument and update the cron job when switching modes
- Consolidate setup-mcp.sh into agent-setup.sh

### Fixed
- Fix MCP warm-up hanging indefinitely — use `--kill-after` with timeout, `disown` the subshell, and wait 10s for connections to initialize before starting the main run
- Fix Dropbox sync race — pause+resume maestral before waiting to force a local rescan of newly written files
- Fix duplicate run logs — write directly to `output/logs/` instead of `~/logs/` + copy; Claude no longer writes a separate log file
- Fix Dropbox sync check always timing out (`maestral status` output starts with a blank line)
- Fix orchestrator not running periodically when instance stays up (boot runner only fires once)
- Fix Dropbox setup failing to exclude folders because maestral was not paused during exclusion changes

### Removed
- Remove setup-mcp.sh (functionality merged into agent-setup.sh)
