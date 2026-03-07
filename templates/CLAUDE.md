# CLAUDE.md — Agent Server Workspace

This workspace is managed by an autonomous AI agent. It syncs via Dropbox and is used as both an Obsidian vault and a working environment for AI agents.

## Folder Structure

| Path | Purpose |
|---|---|
| `ai/instructions/` | Task execution rules, default tasks, personal context, writing style. Read these before any task. |
| `ai/scratchpad/` | Temporary working area for drafts, intermediate outputs, research notes. Safe to overwrite. |
| `{OUTPUT_FOLDER}/` | Final deliverables, documents, and content. Treat as persistent — do not delete or overwrite without instruction. |
| `{OUTPUT_FOLDER}/INBOX/` | Task inbox. Drop `.txt` or `.md` files here to queue work for the agent. |
| `{OUTPUT_FOLDER}/INBOX/_processed/` | Completed inbox tasks (moved here after execution). |

## How to Work

1. **Before any task**: Read `ai/instructions/tasks.md` for execution rules.
2. **Use `ai/scratchpad/`** for any intermediate work.
3. **Save final outputs** to the output folder.
4. **Use ActingWeb memories actively** — search before starting, save decisions and discoveries.

## Memory Protocol (ActingWeb)

ActingWeb memories persist across conversations and across different AI tools. Use them to:
- **Search** for relevant context before starting work
- **Save** decisions with rationale, confirmed preferences, durable facts
- **Update** existing memories rather than creating duplicates
- **Skip** saving transient state, full documents, or speculative information

## Key Rules

- Never send emails or messages without explicit instruction. Default to drafting.
- Never delete files. Move to `_processed/` or `_archive/`.
- Log everything. Fail gracefully — if one task fails, continue to the next.
- Default to brevity.
