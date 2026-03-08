# CLAUDE.md — Agent Workspace

This workspace is managed by an AI agent. It can also be used as an
[Obsidian](https://obsidian.md) vault — the folder structure is compatible.

## Folder Structure

| Path | Purpose |
|---|---|
| `ai/instructions/` | Task execution rules, default tasks, personal context, writing style. Read these before any task. |
| `ai/scratchpad/` | Temporary working area for drafts, intermediate outputs, research notes. Safe to overwrite. |
| `INBOX/` | Task inbox. Drop `.txt` or `.md` files here to queue work for the agent. |
| `INBOX/_processed/` | Completed inbox tasks (moved here after execution). |
| `{OUTPUT_FOLDER}/` | Final deliverables, documents, and content. Treat as persistent — do not delete or overwrite without instruction. |
| `{OUTPUT_FOLDER}/tasks/` | Results from scheduled task runs and ActingWeb tasks. |
| `{OUTPUT_FOLDER}/logs/` | Run logs from each agent cycle. |
| `{OUTPUT_FOLDER}/research/` | Research output — meeting prep, background checks, topic research. |
| `{OUTPUT_FOLDER}/improvements/` | Self-review proposals — agent-suggested improvements to its own instructions. |

## How to Work

1. **Before any task**: Read `ai/instructions/tasks.md` for execution rules.
2. **Use `ai/scratchpad/`** for any intermediate work.
3. **Save final outputs** to `{OUTPUT_FOLDER}/`.
4. **Save task results** to `{OUTPUT_FOLDER}/tasks/`.
5. **Save run logs** to `{OUTPUT_FOLDER}/logs/`.
6. **Use ActingWeb memories actively** — search before starting, save decisions and discoveries.

## Memory Protocol (ActingWeb)

ActingWeb memories persist across conversations and across different AI tools. Use them to:
- **Search** for relevant context before starting work
- **Save** decisions with rationale, confirmed preferences, durable facts
- **Update** existing memories rather than creating duplicates
- **Skip** saving transient state, full documents, or speculative information

## Recurring Schedule

When the user asks to set up a schedule (or during first-session setup), offer to
create recurring scheduled tasks for the default task cycle. Use these guidelines:

- **Suggest a sensible default**: e.g. every hour on weekdays, or once each morning
- **Let the user choose** which tasks to include and the frequency
- **Explain** that schedules run while the session is open — when starting a new session,
  the schedule needs to be set up again (or included in the opening prompt)
- **Use the default-tasks prompt**: "Run the default task cycle. Read ai/instructions/tasks.md
  and ai/instructions/default-tasks.md, then execute all applicable default tasks.
  Write the log to {OUTPUT_FOLDER}/logs/."

## Key Rules

- Never send emails or messages without explicit instruction. Default to drafting.
- Never delete files. Move to `_processed/` or `_archive/`.
- Log everything. Fail gracefully — if one task fails, continue to the next.
- Default to brevity.
