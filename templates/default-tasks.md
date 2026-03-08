---
type: ai-instruction
scope: recurring-tasks
tags:
  - ai/config
  - ai/instruction
---

# Default Tasks — Run Every Cycle

These tasks execute on every scheduled run, in order, before processing inbox or ActingWeb tasks. See [tasks](tasks.md) for execution patterns and logging format.

---

## 1. Email Triage

**Type**: Email
**MCP required**: Gmail

Check the inbox for unread messages received since the last run. For each:
- Categorize: actionable / FYI / spam-like / personal
- For actionable emails that seem time-sensitive: create a brief summary note in the `INBOX/` folder named `email-<sender>-<subject-slug>.md` with the key ask and suggested response approach
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

For meetings in the next 6 hours that involve external participants:
- Do a quick web search on the participants and their companies
- Write a brief research note to `output/research/prep-<meeting-slug>.md` covering:
  who they are, their role, their company, and any recent news or context
- Search ActingWeb memories for any prior interactions or notes about these contacts

Include the calendar preview in the log.

Skip this task if Calendar MCP is not connected (log a warning).

---

## 3. Inbox Folder Scan

**Type**: File Organization

Scan the `INBOX/` folder for new `.txt` and `.md` files (excluding files starting with `_`). These are tasks from the owner or from other AI sessions. Report the count and filenames in the log. The agent will execute them after default tasks.

---

## 4. ActingWeb Task Check

**Type**: Memory Management
**MCP required**: ActingWeb

Check for queued tasks via `work_on_task(list_only=true)`. Report the count and task summaries in the log. The agent will execute them after inbox tasks.

---

## 5. Memory Hygiene (weekly)

**Type**: Memory Management
**MCP required**: ActingWeb
**Frequency**: Only run on Mondays (check the date)

Search ActingWeb memories modified in the last 7 days:
- Look for obvious duplicates
- Flag any that seem outdated based on context you have
- Log findings as recommendations (don't auto-delete)

On non-Monday runs, skip this task entirely.

---

## 6. Heartbeat Check

**Type**: Summary

Read the heartbeat file (at the output folder root, named `.agent-heartbeat`) to see when the last successful run was. If it's been more than 24 hours since the last run, log a warning. Updating the heartbeat is handled by the orchestrator — this task just verifies it.

---

## 7. Self-Review (daily)

**Type**: Self-Improvement
**MCP required**: ActingWeb
**Frequency**: Only run once per day (check date against last review in `output/improvements/`)

Review recent activity and propose improvements. This is how the agent gets better over time.

### What to review

1. **Run logs** — Read the last 3–5 logs from `output/logs/`. Look for:
   - Tasks that failed or were deferred repeatedly
   - Warnings or errors that keep recurring
   - Tasks that consistently take too long
   - Patterns in what the agent is being asked to do

2. **Inbox and ActingWeb task history** — Check `INBOX/_processed/` and recent task outputs. Look for:
   - Recurring task themes that could become default tasks
   - Task types the agent handles poorly or doesn't support
   - Gaps between what the user asks for and what the agent delivers

3. **Instruction quality** — Briefly review `ai/instructions/` files. Look for:
   - Rules that conflict with observed behavior
   - Missing guidance for task types the agent has encountered
   - Outdated information

4. **ActingWeb memories** — Search for recent learnings, corrections, and preferences. Look for:
   - Preferences that should be reflected in instruction files
   - Knowledge that could improve default task execution

### What to produce

Write a proposals file to `output/improvements/review-YYYY-MM-DD.md` with this structure:

```markdown
# Self-Review — YYYY-MM-DD

## Summary
<2-3 sentence overview of findings>

## Proposed Changes

### 1. <title>
- **File**: <which instruction file to change>
- **Type**: new-task | task-fix | instruction-update | workflow
- **What**: <specific change to make>
- **Why**: <evidence from logs or patterns>

### 2. <title>
...

## Learnings Saved
<list of memories saved to ActingWeb during this review>
```

### Rules

- **Never auto-modify instruction files.** Always propose; let the user decide.
- **Save durable learnings to ActingWeb memory** — e.g. "agent frequently fails at X because Y" or "user prefers Z approach for research tasks"
- **Be specific.** Don't propose vague improvements like "be better at email." Propose concrete changes: "Add a rule to default-tasks.md email triage to always flag emails from @important-domain.com as actionable."
- **Skip if nothing to improve.** Don't generate noise — if the last few runs were clean and the agent is working well, just log "No improvements needed" and move on.
- **Keep it brief.** 3–5 proposals maximum per review.

---

## Adding New Default Tasks

To add a recurring task, add a new numbered section to this file following the same format:
- Give it a clear name and type
- Specify which MCP connections it requires
- Define what it should do and where output goes
- Add frequency constraints if it shouldn't run every cycle
- Keep tasks small — each should complete in under 2 minutes
