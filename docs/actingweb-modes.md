# ActingWeb Modes — Memory-Only vs Agent OS

ActingWeb can be used in two modes. Pick one before setup.

## Memory-only (default)

ActingWeb stores cross-session memory. Everything else lives in your brain
directory: instructions in `ai/instructions/*.md`, outputs in `output/*`,
the dashboard in `ACTIONS.md`, the task queue in `INBOX/`.

- **Best for**: a single primary machine (your laptop, or one EC2), users who
  like editing markdown files, or anyone who wants the simplest possible setup.
- **What's needed**: connect the `actingweb` MCP and authenticate. That's it —
  the brain directory is created locally by `setup.sh` / the local-setup script.

## Agent OS

ActingWeb stores **memory + instructions + outputs**. The agent does a full
run by reading instructions and writing outputs entirely through MCP — no
filesystem required.

- **Best for**: running the same agent from multiple clients (Claude Code on
  EC2, Claude Desktop / Cowork, ChatGPT, the browser at `ai.actingweb.io`).
  Each client connects to the same ActingWeb account and sees the same
  instructions, dashboard, and outputs.
- **What's needed**:
  1. Open the ActingWeb web app at `https://ai.actingweb.io/{actor_id}` and
     turn Agent OS on. ActingWeb seeds the canonical instruction templates
     (`agents`, `tasks`, `default_tasks`, `personal`, `style`, `skills`) —
     these are the same templates this repo ships, so there is nothing to
     copy.
  2. Connect the `actingweb` MCP from whichever client you want to run from.
  3. Optionally connect Gmail, Calendar, and a binary-storage MCP.
- **No brain directory.** Skip `local-setup.md` Step 2 entirely. On EC2 the
  orchestrator still needs a working directory for scripts, but `INBOX/`,
  `ai/instructions/`, and `output/` are not used.

### The Instructions-Update Mode lock

ActingWeb gates writes to instructions behind a lock the user toggles in the
web app. When locked, `instruction_save` / `instruction_delete` fail with
JSON-RPC error `-32099`. The agent should surface the `action_required` field
to the user and stop — do not retry.

To personalize `personal` and `style` after enabling Agent OS, unlock once,
let the agent walk you through the questions and write back, then re-lock.
Reads always work regardless of state.

### Outputs are text/markdown only

ActingWeb outputs hold text and markdown. For binary artefacts (images, PDFs,
audio, attachments), connect a binary-storage MCP — see "Binary storage" in
the main README. Upload the binary there and reference it from the output by
URL or path.

## Switching modes later

**Memory-only → Agent OS**: enable Agent OS in the web app. If you customized
your local `tasks.md`, `default-tasks.md`, `personal.md`, or `style.md`, push
each one with `instruction_save(name="<canonical-name>", content=<file body>)`.
The local files become unused after that. Otherwise the canonical templates
are byte-for-byte the same content this repo ships, and there is nothing to
migrate.

**Agent OS → memory-only**: turn Agent OS off in the web app. The agent falls
back to local files — make sure they exist and are populated. You can dump
ActingWeb instructions to disk first with `instruction_load` if you want the
local copies to start from your customized state.
