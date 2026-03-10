# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Add ARCHITECTURE.md documenting repo structure, setup paths, server layout, and task execution flow
- Add cron job to run the orchestrator every SCHEDULE_INTERVAL minutes while the instance is up
- Add flock-based locking to the orchestrator to prevent concurrent runs
- Copy setup-dropbox.sh into ~/scripts/ during server setup
- Wait for Dropbox sync to complete before self-stopping the instance (polls maestral status, 120s timeout)

### Changed
- Rewrite Dropbox selective sync to pause maestral, parse `maestral ls -l` output for sync status, and skip already-excluded folders
- Update quick-start prompt to tell AI to download the zip directly instead of web-fetching GitHub
- Link ARCHITECTURE.md from the reference section in README.md
- Update set-schedule-mode.sh to accept an optional interval argument and update the cron job when switching modes
- Consolidate setup-mcp.sh into agent-setup.sh

### Fixed
- Fix orchestrator not running periodically when instance stays up (boot runner only fires once)
- Fix Dropbox setup failing to exclude folders because maestral was not paused during exclusion changes

### Removed
- Remove setup-mcp.sh (functionality merged into agent-setup.sh)
