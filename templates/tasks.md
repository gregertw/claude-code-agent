---
type: ai-instruction
scope: task-execution
tags:
  - ai/config
  - ai/instruction
---

# Task Execution Reference

This document defines how the agent executes tasks. It is read at startup before processing any task queue.

For personal context, see [personal](personal.md). For writing style, see [style](style.md). For recurring tasks, see [default-tasks](default-tasks.md).

---

## Execution Context

You are running as an AI agent in the owner's workspace. You have:
- Access to the brain directory (local filesystem or synced via Dropbox)
- MCP connections (ActingWeb memories, and optionally Gmail, Calendar)
- Internet access for web search and API calls

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
One-off tasks dropped as `.txt` or `.md` files in the `INBOX/` folder at the root of the brain directory. Each file contains a prompt/instruction. After execution:
- Move the task file to `INBOX/_processed/` with a timestamp prefix
- Write the result to `output/tasks/`

### 3. ActingWeb Tasks
Retrieved via the ActingWeb `work_on_task` MCP tool. These are tasks created through the ActingWeb Context Builder — a guided wizard where users describe what they want done and gather relevant personal context (memories, preferences, notes) to enrich the task.

**How to create a task**: Open the Context Builder at `https://ai.actingweb.io/{actor_id}/app/builder` (find your actor_id via the `how_to_use()` MCP tool). The wizard helps you:
1. Describe what you want accomplished
2. Explore and attach relevant memories as context
3. Mark the task as ready for the agent to pick up

**How the agent processes ActingWeb tasks**:
- Call `work_on_task()` to retrieve the next ready task (includes gathered context automatically)
- Execute the task using the included context for personalized results
- Write the result to `output/tasks/`
- Mark as done via `work_on_task(mark_done=true, task_id=...)`

**Other work_on_task operations**:
- `work_on_task(list_only=true)` — list all ready and completed tasks
- `work_on_task(task_id=42)` — retrieve a specific task by ID

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
2. Write report to `output/` or scratchpad
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
- **API rate limit**: Wait 30 seconds and retry once. If still failing, log as deferred.
- **Ambiguous task**: If a task instruction is unclear, log it as deferred with "needs clarification" and move on.
- **Large task**: If a task would take more than 5 minutes, log as deferred with scope estimate.

---

## Post-Run

After all tasks are processed:
1. Write the run log to `output/logs/` with filename `run-YYYY-MM-DD-HHMM.md`
2. If any tasks were deferred or failed, create a summary note in `INBOX/` named `_agent-attention-needed-YYYYMMDD.md` listing items that need attention
3. If in scheduled mode, the orchestrator will handle shutdown
