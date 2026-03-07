---
type: ai-instruction
scope: task-execution
tags:
  - ai/config
  - ai/instruction
  - ai/agent-server
---

# Task Execution Reference — Agent Server

This document defines how the agent server executes tasks. It is read by Claude Code at startup before processing any task queue.

For personal context, see [personal](personal.md). For writing style, see [style](style.md). For recurring tasks, see [default-tasks](default-tasks.md).

---

## Execution Context

You are running as an autonomous Claude Code agent on the owner's server. You have:
- Access to `~/Dropbox/` (synced via Dropbox CLI, contains the owner's Obsidian vault)
- MCP connections configured in `~/.claude.json` (ActingWeb memories, and optionally Gmail, Calendar)
- Internet access for web search and API calls
- No human in the loop — you must make reasonable judgments and log what you did

### Key Constraints
- **Never send emails, messages, or calendar invites** without explicit instruction in the task. Default to drafting, not sending.
- **Never delete files or data.** Move to a `_processed/` or `_archive/` subfolder instead.
- **Log everything.** Every task execution writes to the session log.
- **Fail gracefully.** If a task fails, log the error and continue to the next task. Don't halt the entire run.
- **Time budget.** Each individual task should complete within 5 minutes. If a task is too large, log it as "deferred" with a reason and move on.

---

## Task Sources (in execution order)

### 1. Default Tasks (`ai/instructions/default-tasks.md`)
Recurring tasks that run every cycle. These are defined in the companion file and should be executed first. They include things like checking email, reviewing the inbox folder, and memory hygiene.

### 2. Inbox Tasks (INBOX folder)
One-off tasks dropped as `.txt` or `.md` files. Each file contains a prompt/instruction. After execution:
- Move the task file to the `_processed/` subfolder with a timestamp prefix
- Write the result summary to the log

### 3. ActingWeb Tasks
Retrieved via the ActingWeb `work_on_task` MCP tool. These are tasks queued from other AI sessions or scheduled via the ActingWeb dashboard. After execution:
- Mark the task as done via `work_on_task(mark_done=true, task_id=...)`
- Write the result summary to the log

---

## Task Types

Each task file or instruction can be categorized. The agent should identify the type and follow the corresponding execution pattern.

### Type: Research
**Trigger words**: "research", "find out", "look up", "what is", "compare"
**Execution**:
1. Use web search and/or MCP tools to gather information
2. Write findings to a markdown file in the scratchpad area
3. If findings are durable facts, save as ActingWeb memories
4. Log: summary of what was found

### Type: Email
**Trigger words**: "email", "draft", "reply", "inbox", "gmail"
**MCP required**: Gmail
**Execution**:
1. Use Gmail MCP to read/search emails as instructed
2. For replies or new emails: **create a draft only** (never send)
3. Write a summary to the log noting what was drafted and for whom
4. If the task explicitly says "send" — still only draft, and note in the log that sending was skipped per safety rules

### Type: Writing
**Trigger words**: "write", "draft", "create document", "blog post", "article"
**Execution**:
1. Read style instructions before writing anything (if style.md exists)
2. Write output to the location specified in the task, or default to the scratchpad area
3. Log: filename and brief description of what was written

### Type: File Organization
**Trigger words**: "organize", "sort", "clean up", "move", "rename"
**Execution**:
1. Never delete — move to `_archive/` subfolder
2. Log every file operation (from -> to)
3. If uncertain about a file's importance, skip it and log the skip

### Type: Calendar
**Trigger words**: "schedule", "calendar", "meeting", "free time", "availability"
**MCP required**: Google Calendar
**Execution**:
1. Use Google Calendar MCP to check/create events
2. For new events: create as tentative/draft if possible
3. Never accept or decline invitations without explicit instruction
4. Log: what was checked or created

### Type: Memory Management
**Trigger words**: "remember", "save to memory", "update memory", "memory hygiene"
**Execution**:
1. Use ActingWeb MCP tools to search, save, update, or clean memories
2. One idea per memory. Atomic, searchable, factual.
3. Include rationale for decisions.
4. Log: what memories were created, updated, or flagged for cleanup

### Type: Code / Technical
**Trigger words**: "script", "code", "fix", "build", "deploy", "debug"
**Execution**:
1. Work in the scratchpad area for drafts
2. Final outputs to the location specified in the task
3. Log: what was created or modified, any test results

### Type: Summary / Report
**Trigger words**: "summarize", "report", "digest", "overview", "status"
**Execution**:
1. Gather data from the specified sources
2. Write report to the output folder or scratchpad
3. Keep it concise
4. Log: filename and scope of the summary

---

## Logging Format

Structure your output as a markdown log. Each task should be logged in this format:

```markdown
## [HH:MM] Task: <task name or source>
- **Type**: <task type>
- **Source**: default | inbox:<filename> | actingweb:<task_id>
- **Status**: completed | failed | deferred
- **Summary**: <1-3 sentences describing what was done>
- **Output**: <file path if applicable>
- **Errors**: <error details if failed>
```

---

## Error Handling

- **MCP connection failure**: Log the error, skip tasks requiring that MCP, continue with remaining tasks.
- **Dropbox not synced**: Wait up to 3 minutes at startup. If still syncing, proceed with available files and log a warning.
- **API rate limit**: Wait 30 seconds and retry once. If still failing, log as deferred.
- **Ambiguous task**: If a task instruction is unclear, log it as deferred with "needs clarification" and move on.
- **Large task**: If a task would take more than 5 minutes, log as deferred with scope estimate.

---

## Post-Run

After all tasks are processed:
1. Write a final summary section in the log
2. If any tasks were deferred or failed, create a summary note in the INBOX named `_agent-attention-needed-YYYYMMDD.md` listing items that need attention
3. If in scheduled mode, the orchestrator will handle shutdown
