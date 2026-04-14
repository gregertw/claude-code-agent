---
name: todoist
description: >
  Integrate Todoist task management with the agent workspace. The agent reads
  Todoist tasks into ACTIONS.md each cycle and can create/complete tasks in
  Todoist from inbox instructions or agent-generated action items.
prerequisites:
  - Todoist MCP server connected (official hosted MCP at https://ai.todoist.net/mcp)
config:
  - key: TODOIST_MCP
    prompt: "Is the Todoist MCP server connected?"
    description: "The official Todoist MCP must be available as a connected tool"
    required: true
  - key: TODOIST_PROJECTS
    prompt: "Which projects to sync? (all / comma-separated names)"
    description: "Projects whose tasks appear in ACTIONS.md"
    required: false
    default: "all"
installs:
  creates: []
  modifies:
    - "ai/instructions/tasks.md — adds 'Type: Todoist' task type"
    - "ai/instructions/personal-tasks.md — adds 'Todoist Sync' recurring task"
---

# Todoist — Task Management Integration

## Overview

This capability connects Todoist to the agent workspace via the official Todoist
MCP server. The agent can:
- **Read** tasks from all Todoist projects and surface them in ACTIONS.md
- **Create** tasks in Todoist from inbox instructions or agent-generated items
- **Complete** tasks in Todoist when the owner checks them off in ACTIONS.md
- **Search** Todoist for context when processing other tasks

## For the user

After installation, the agent checks Todoist every cycle. Tasks due today or
overdue appear in ACTIONS.md under a dedicated Todoist section. You can also
ask the agent to create Todoist tasks from INBOX files, agentmail, or inline
ACTIONS.md comments (e.g. `> add to todoist: call dentist tomorrow`).

---

## Installation Instructions (for AI)

### Prerequisites

The Todoist MCP server must be connected. Verify by calling `user-info` — if it
returns user data, the connection is live.

### Step 1: Add task type to tasks.md

Add the "Type: Todoist" section to `ai/instructions/tasks.md` after the
"Type: Calendar" section. See the task type definition in this file's
installation payload below.

### Step 2: Add recurring task to personal-tasks.md

Add the "Todoist Sync" task to `ai/instructions/personal-tasks.md` as the
next numbered section. See the recurring task definition below.

### Step 3: Verify and report

1. Test the connection by calling `user-info` and `find-projects`
2. Add an item to ACTIONS.md confirming installation
3. Log the installation

---

## Task Type Definition (for tasks.md)

```markdown
### Type: Todoist
**Trigger words**: "todoist", "add task", "create task", "todo", "task list"
**MCP required**: Todoist
**Execution**:
1. Use Todoist MCP tools to read, create, update, or complete tasks
2. When creating tasks: infer project from context, set due dates from natural language, apply labels and priority
3. When reading tasks: surface in ACTIONS.md or return in task output
4. Log: action taken, task content, project, and Todoist task ID

**Task creation rules**:
- Infer the best project from task content. Work-related -> "Work", personal errands -> "Personal To-Dos", unclear -> "Inbox"
- Preserve any due date, priority, or label hints from the instruction
- Always log the created task ID for reference

**Completing tasks from ACTIONS.md**:
- When the owner checks off a Todoist item in ACTIONS.md (marked [x] or ~~strikethrough~~), complete it in Todoist too using the task ID stored in the item's metadata
- Log: "Completed in Todoist: <task content> (ID: <id>)"
```

## Recurring Task Definition (for personal-tasks.md)

````markdown
## N. Todoist Sync

**Type**: Todoist
**MCP required**: Todoist
**Frequency**: Every cycle

Sync Todoist tasks with ACTIONS.md. This runs in four phases.

### Phase 1: Process ACTIONS.md completions

Check ACTIONS.md for any Todoist items the owner has checked off ([x] or
strikethrough). For each, extract the Todoist task ID from the item text
(format: `(ID: <taskId>)`) and complete it in Todoist via `complete-tasks`.
Then remove the item from ACTIONS.md as usual.

Also check for inline comments on Todoist items (the `>` line). Supported
commands:
- `> done` — complete the task in Todoist
- `> reschedule <date>` — update the due date via `update-tasks`
- `> add to todoist: <task description>` — create a new task (can appear on any ACTIONS.md item)
- `> move to <project>` — move task to a different Todoist project

### Phase 2: Read Todoist tasks

Fetch tasks due today and overdue using `find-tasks-by-date`:
- `startDate: "today"`, `daysCount: 1`, `limit: 50`
- This automatically includes overdue tasks

Also fetch tasks due this week (next 7 days) for the "Coming up" preview:
- `startDate: "today"`, `daysCount: 7`, `limit: 30`

### Phase 3: Update ACTIONS.md

Add or update a **Todoist** section in ACTIONS.md. Place it after "This week"
and before "Reading". Group items as:

**Overdue + today** (these need attention now):
```markdown
- [ ] **<task content>** — <project name>, due <date>. (ID: <taskId>)
  >
```

**Coming up this week** (awareness only):
```markdown
- [ ] **<task content>** — <project>, <due date>. (ID: <taskId>)
  >
```

Formatting rules:
- Include the Todoist task ID in parentheses so completions can sync back
- Show the project name for context
- Show priority only for p1/p2 tasks (prefix with 🔴 for p1, 🟡 for p2)
- If a task has a description, include the first 80 chars after a dash
- Remove Todoist items from ACTIONS.md that no longer appear in Todoist
  (completed elsewhere, deleted, or rescheduled beyond the window)
- Do not duplicate items already in ACTIONS.md from other sources (e.g. if
  a calendar event or email already covers the same action)

### Phase 4: Create tasks from other agent sources (optional)

When other tasks in the cycle produce action items with clear deadlines
and concrete actions, the agent MAY create a corresponding Todoist task.
Be conservative — prefer ACTIONS.md only unless the item clearly belongs
in Todoist (e.g. "pay invoice by April 20" from email triage).

Project mapping for new tasks:
- Work-related -> "Work"
- Personal errands -> "Personal To-Dos"
- Unclear -> "Inbox"

Note: Todoist project IDs are user-specific. During installation, use
`find-projects` to discover the correct IDs and record them.

### Logging

Compact: `Todoist sync: <N> active, <M> completed, <K> created.`
If nothing changed: `Todoist sync — no changes`
````

## Uninstallation

To remove this capability:
1. Remove the "Type: Todoist" section from `tasks.md`
2. Remove the "Todoist Sync" task from `personal-tasks.md`
3. Remove the Todoist section from `ACTIONS.md`
4. Disconnect the Todoist MCP server
