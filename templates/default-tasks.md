---
type: ai-instruction
scope: recurring-tasks
tags:
  - ai/config
  - ai/instruction
  - ai/agent-server
---

# Default Tasks — Run Every Cycle

These tasks execute on every agent server wakeup, in order, before processing inbox or ActingWeb tasks. See [tasks](tasks.md) for execution patterns and logging format.

---

## 1. Email Triage

**Type**: Email
**MCP required**: Gmail

Check the inbox for unread messages received since the last run. For each:
- Categorize: actionable / FYI / spam-like / personal
- For actionable emails that seem time-sensitive: create a brief summary note in the INBOX folder named `email-<sender>-<subject-slug>.md` with the key ask and suggested response approach
- For everything else: just include in the log summary

Do NOT draft replies automatically. Only flag emails that need attention.

Skip this task if Gmail MCP is not connected (log a warning).

---

## 2. Calendar Preview

**Type**: Calendar
**MCP required**: Google Calendar

Check the calendar for today and tomorrow:
- List upcoming events with times
- Flag any conflicts or back-to-back meetings without breaks
- Note any events that need preparation

Include the preview in the log. If there are preparation-worthy meetings in the next 6 hours, create a note in the INBOX folder named `prep-<meeting-slug>.md`.

Skip this task if Calendar MCP is not connected (log a warning).

---

## 3. Inbox Folder Scan

**Type**: File Organization

Scan the INBOX folder for new `.txt` and `.md` files (excluding files starting with `_`). These are tasks from the owner or from other AI sessions. Report the count and filenames in the log. The orchestrator will execute them after default tasks.

---

## 4. Memory Hygiene (weekly)

**Type**: Memory Management
**MCP required**: ActingWeb
**Frequency**: Only run on Mondays (check the date)

Search ActingWeb memories modified in the last 7 days:
- Look for obvious duplicates
- Flag any that seem outdated based on context you have
- Log findings as recommendations (don't auto-delete)

On non-Monday runs, skip this task entirely.

---

## 5. Dropbox Sync Health

**Type**: Summary

Check Dropbox sync status (`dropbox-cli status`). If there are sync errors or conflicts, log them. If there are Dropbox conflict files (files with "conflicted copy" in the name) in the brain folder, list them in the log.

---

## 6. Heartbeat Check

**Type**: Summary

Read the heartbeat file (at the output folder root, named `.agent-heartbeat`) to see when the last successful run was. If it's been more than 24 hours since the last run, log a warning. Update the heartbeat is handled by the orchestrator — this task just verifies it.

---

## Adding New Default Tasks

To add a recurring task, add a new numbered section to this file following the same format:
- Give it a clear name and type
- Specify which MCP connections it requires
- Define what it should do and where output goes
- Add frequency constraints if it shouldn't run every cycle
- Keep tasks small — each should complete in under 2 minutes
