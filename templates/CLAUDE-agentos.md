# CLAUDE.md — Agent Workspace (ActingWeb Agent OS mode)

This server runs in **Agent OS mode**. Your operational instructions, the
owner's dashboard, and your work outputs all live in ActingWeb — not in this
filesystem.

## How to start any run

1. Call `how_to_use()` on the ActingWeb MCP server to discover what's
   installed and get the actor_id.
2. Call `instruction_list()`, then `instruction_load()` for at minimum
   `agents`, `tasks`, `default_tasks`, `personal`, and `style`. Treat
   `agents` as the operational brief and `tasks` as the per-cycle queue.
3. Follow the standard run pattern documented in those instructions:
   process the actions dashboard via `output_list(category="actions")` →
   `output_get` → `output_update`, run the per-cycle tasks, drain the
   one-off queue with `work_on_task()`, write a `log` output, update the
   dashboard, save durable insights via `save()`.

## What lives on this filesystem

Only the orchestrator's run logs (`output/logs/`) and the heartbeat
(`output/.agent-heartbeat`). There is no `ai/instructions/`, no `INBOX/`,
no `output/tasks/` — those concepts live in ActingWeb.

If you find local files like `personal.md`, `tasks.md`, or `default-tasks.md`
in this directory, ignore them — they are leftovers from a prior memory-only
configuration. The ActingWeb instructions are authoritative.

## Binaries

ActingWeb outputs hold text/markdown. For images, PDFs, audio, or
attachments, use a connected binary-storage MCP (Dropbox, Google Drive,
OneDrive, S3) and reference uploaded files by URL or path from your text
outputs. Never inline binary into ActingWeb outputs.

## Lock state

If a write to instructions fails with JSON-RPC error -32099, the
Instructions-Update Mode is locked. Surface the `action_required` field
to the owner and continue with reads only — do not retry the write.
