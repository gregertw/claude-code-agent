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
- `~/Dropbox/brain/` — if you want Dropbox sync

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

Add the following MCP servers in Claude Desktop's settings (Settings → MCP Servers):

- **ActingWeb** (required): `https://ai.actingweb.io/mcp` — account is auto-created on first auth
- **Gmail** (optional) — requires Google OAuth credentials (see [README](../README.md#google-oauth-optional--for-gmail-and-calendar))
- **Google Calendar** (optional) — requires Google OAuth credentials

## Step 4: Open your brain folder in Cowork

1. Open Claude Desktop
2. Start a new **Cowork** session
3. Choose **"Work in a folder"** and select your brain directory (e.g. `~/brain`)
4. Claude will read the `CLAUDE.md` file automatically

You're now working inside your agent workspace. Continue to Step 5.

## Step 5: Personalize and set up schedule

Send this prompt in your new Cowork session:

```txt
Read the instruction files in ai/instructions/ and introduce yourself.
Then check if ActingWeb memory is connected by searching for any existing memories.
If this is our first session, walk me through filling in personal.md and style.md:
- Search ActingWeb memories for any existing personal context or preferences
- If Gmail is connected, analyze my recent sent emails to infer my writing style
- Then ask me questions to fill in the remaining gaps in the templates

After personalization, wrap up by doing the following:
1. Offer to set up a recurring schedule for the default tasks. Suggest a sensible
   schedule (e.g. every 2 hours on weekdays) and set it up if I agree.
2. Use ActingWeb's how_to_use() to get my actor_id, then give me a direct link
   to the Context Builder: https://ai.actingweb.io/{actor_id}/app/builder
   Explain that I can create tasks there from any device (phone, browser, another
   AI session) and the agent will pick them up on its next run.
3. Give me a summary of what the agent can do now — what default tasks are
   configured, how to queue one-off tasks, and how to customize.
```

This verifies your setup works (MCP connection, file access), walks you through
personalizing the templates, and sets you up to use the agent going forward.

---

## What's Next

After setup, your agent is ready to work. Here's what it can do and how to use it.

### Default Tasks

These run automatically on every scheduled cycle (or when you say
"Run the default task cycle now"):

| Task | What it does | Requires |
|---|---|---|
| **Email Triage** | Scans your inbox for unread messages, categorizes them (actionable / FYI / spam / personal), and flags time-sensitive emails by creating summary notes in `INBOX/` | Gmail MCP |
| **Calendar Preview** | Shows today's and tomorrow's events, flags conflicts, and researches external meeting participants | Google Calendar MCP |
| **Inbox Folder Scan** | Checks `INBOX/` for new `.txt` and `.md` files you've dropped in, then executes them as tasks | — |
| **ActingWeb Task Check** | Checks for tasks you've queued via the Context Builder and executes them | ActingWeb MCP |
| **Memory Hygiene** | Runs weekly (Mondays only) — scans recent memories for duplicates or outdated entries | ActingWeb MCP |
| **Heartbeat Check** | Verifies the agent ran recently; warns if it's been more than 24 hours | — |

Tasks that require an MCP connection you haven't set up are skipped with a warning —
they won't cause errors.

### Queue Tasks from Anywhere

**Inbox folder**: Drop a `.txt` or `.md` file into `INBOX/` describing what you want done.
The agent picks it up on its next run, executes it, moves the file to `INBOX/_processed/`,
and writes results to `output/tasks/`.

```bash
echo "Research the top 3 project management tools for small teams" > ~/brain/INBOX/research-pm-tools.txt
```

**Context Builder**: Create tasks from any device — phone, browser, or another AI session.
Open the Context Builder at:

```
https://ai.actingweb.io/{actor_id}/app/builder
```

Find your `actor_id` by calling `how_to_use()` in any Cowork session with ActingWeb
connected. The Context Builder wizard lets you describe what you want done and attach
relevant memories as context. When you mark the task as ready, the agent picks it up
on its next run via `work_on_task()`.

### Recurring Schedule

Cowork supports in-session scheduled tasks that run your default tasks automatically
in the background while you work. During first-session setup, the agent will offer
to configure this for you.

Typical schedules:

- **Every 2 hours on weekdays**: email triage, calendar preview, inbox scan
- **Every morning**: full default task cycle
- **Custom**: choose what runs and when

Scheduled tasks run while your Cowork session is open. When you start a new session,
just ask the agent to set up the schedule again, or include it in your opening prompt.

### Customize

- **Add default tasks**: Edit `ai/instructions/default-tasks.md` to add new recurring tasks
- **Change task rules**: Edit `ai/instructions/tasks.md` to modify execution patterns
- **Update personal context**: Edit `ai/instructions/personal.md` as your preferences evolve
- **Adjust writing style**: Edit `ai/instructions/style.md` to refine how the agent writes
- **Add MCP connections**: Add Gmail, Google Calendar, or other MCP servers in Claude Desktop settings

See the [Customization Guide](customization.md) for more details.
