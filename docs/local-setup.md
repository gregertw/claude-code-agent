# Option A: Local Setup

Set up a brain directory on your local machine and use Claude Desktop's Cowork
feature to work in it.

## Prerequisites

- Claude Desktop app installed

## Step 1: Choose a directory

Pick where the brain directory should be created. This is where the agent stores
its instructions, scratchpad, inbox, and outputs. For example:

- `~/brain/` — simple default
- `~/Documents/agent-brain/` — inside Documents

> **Tip**: The brain directory is also compatible with [Obsidian](https://obsidian.md),
> a free knowledge management app. If you use Obsidian, you can open the brain
> folder as a vault to browse and edit your instruction files, task outputs, and
> scratchpad notes with a nice UI. No extra setup required — just open the folder
> in Obsidian.

## Step 2: Install template files

From the root of this repo, run the following (replacing the path if you chose
a different directory):

```bash
# Set your brain directory
BRAIN_DIR="$HOME/brain"

# Create the directory structure
mkdir -p "$BRAIN_DIR/ai/instructions"
mkdir -p "$BRAIN_DIR/ai/scratchpad"
mkdir -p "$BRAIN_DIR/INBOX/_processed"
mkdir -p "$BRAIN_DIR/output/tasks"
mkdir -p "$BRAIN_DIR/output/logs"
mkdir -p "$BRAIN_DIR/output/research"
mkdir -p "$BRAIN_DIR/output/improvements"

# Copy templates
cp templates/CLAUDE.md "$BRAIN_DIR/CLAUDE.md"
cp templates/tasks.md "$BRAIN_DIR/ai/instructions/tasks.md"
cp templates/default-tasks.md "$BRAIN_DIR/ai/instructions/default-tasks.md"
cp templates/personal.md "$BRAIN_DIR/ai/instructions/personal.md"
cp templates/style.md "$BRAIN_DIR/ai/instructions/style.md"

# Replace placeholder in CLAUDE.md
sed -i '' 's/{OUTPUT_FOLDER}/output/g' "$BRAIN_DIR/CLAUDE.md"
```

> **Note**: The `sed -i ''` syntax is for macOS. On Linux, use `sed -i` (without
> the empty quotes).

The `personal.md` and `style.md` files are templates with placeholder sections.
The agent will help you fill them in during your first session.

## Step 3: Set up MCP connections

Add the following MCP servers in Claude Desktop's settings (Settings → Connectors → Add):

- **ActingWeb** (required): `https://ai.actingweb.io/mcp` — account is auto-created on first auth
- **Gmail** (optional): `https://gmail.mcp.claude.com/mcp` — Anthropic hosted connector, signs in via Google
- **Google Calendar** (optional): `https://gcal.mcp.claude.com/mcp` — Anthropic hosted connector, signs in via Google

No Google Cloud project or OAuth credentials needed — just add the URL and
complete the Google sign-in when prompted.

## Step 4: Return to README.md for personalization

Setup is complete. Now return to the **Step 3: Personalize the agent** section
in README.md for the common personalization step — it will guide you through
starting a Cowork session in your brain folder and filling in `personal.md`
and `style.md`.

---

## What's Next

After personalization, your agent is ready to work. Here's a quick reference.

### Default Tasks

These run on every scheduled cycle (or when you say "Run the default task cycle now"):

| Task | What it does | Requires |
|---|---|---|
| **Email Triage** | Scans inbox, categorizes messages, flags time-sensitive items | Gmail MCP |
| **Calendar Preview** | Shows today's/tomorrow's events, flags conflicts | Google Calendar MCP |
| **Inbox Folder Scan** | Executes `.txt` and `.md` files dropped in `INBOX/` | — |
| **ActingWeb Task Check** | Executes tasks queued via the Context Builder | ActingWeb MCP |
| **Memory Hygiene** | Weekly — scans for duplicate or outdated memories | ActingWeb MCP |
| **Self-Review** | Daily — reviews logs, writes improvement proposals | ActingWeb MCP |
| **Heartbeat Check** | Verifies the agent ran recently | — |

Tasks that require an MCP connection you haven't set up are skipped automatically.

### Queue Tasks

**Inbox folder**: Drop a `.txt` or `.md` file into `INBOX/` — the agent picks
it up on its next run.

**Context Builder**: Create tasks from any device at
`https://ai.actingweb.io/{actor_id}/app/builder` (get your `actor_id` from
`how_to_use()` in any session with ActingWeb connected).

### Recurring Schedule

Cowork supports in-session scheduled tasks. During personalization, the agent
will offer to set this up. Scheduled tasks run while your Cowork session is open.

### Self-Improvement

The agent reviews its performance daily and writes proposals to
`output/improvements/`. It never auto-modifies its own instructions — it
proposes and waits for your approval.

### Customize

See the [Customization Guide](customization.md) for adding tasks, MCP servers,
and more.
