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
- For actionable emails that seem time-sensitive: create a brief summary note in the `output/emails` folder named `email-<sender>-<subject-slug>.md` with the key ask and suggested response approach, and a draft response. Write a frontmatter with status where the user can also change status to approved and add comments
- Check the `output/emails` folder for any approved emails. Send the approved email(s) and change the status to done
- For everything else: just include in the log summary

Do NOT create drafts in gmail.

### Newsletter & Promotional Digest

Do not log newsletters and promotional emails individually. Instead, accumulate them into a daily digest file at `output/emails/digest-YYYY-MM-DD.md`. If the file already exists (from a previous run today), append new entries — do not overwrite.

Each entry is one line: `- **<Sender>**: <subject> — <one-sentence summary of content if available>`

After listing all entries, add a **Worth reading** section: scan newsletter subjects and available content for matches against the interest keywords in [personal.md](personal.md) (see Interest Keywords for Email Filtering). List any matching entries with a brief reason. If none match, write "None this cycle."

In the run log, just write: `<N> newsletters/promos → digest. <M> flagged as worth reading.`

### Follow-up Tracking

Maintain a follow-up tracker at `output/emails/follow-ups.md`. This file tracks sent emails that expect a reply.

**Adding entries**: When an email with `status: approved` is sent, or when the agent observes a sent email in Gmail that appears to expect a reply (question asked, request made, action requested), add an entry:

```markdown
- **To**: <recipient> | **Subject**: <subject> | **Sent**: <YYYY-MM-DD> | **Follow-up after**: <N days> | **Status**: waiting
```

Default follow-up period is 5 business days. For service/support emails, use 3 business days.

**Checking entries**: Each triage cycle, for entries with `Status: waiting`:
1. Search the inbox for replies from that recipient on that subject/thread
2. If a reply is found: update status to `replied (<date>)` and remove from active tracking
3. If follow-up date has passed with no reply: add to `ACTIONS.md` as "No reply from <recipient> on '<subject>' — sent <date>. Draft a follow-up?" and update status to `nudge-suggested`
4. If the user changes status to `follow-up`: draft a polite follow-up email in `output/emails/`
5. If the user changes status to `closed`: remove from active tracking

### Unsubscribe Suggestions

Maintain a sender frequency log at `output/emails/sender-frequency.md`. Each triage cycle, for every promotional or newsletter email, increment the sender's count.

Format:
```markdown
| Sender | Count (30d) | Last actioned | Last seen |
|--------|-------------|---------------|-----------|
| Example Sender | 8 | never | 2026-03-24 |
```

- **"Last actioned"** means the user opened, replied to, or referenced the sender's email (check Gmail read status if available, otherwise default to "never")
- When a sender reaches **5+ emails in 30 days with "never" actioned**, add to `ACTIONS.md` under Pending decisions: "Unsubscribe suggestion: <Sender> has sent <N> emails in 30 days, none actioned. Unsubscribe?"
- Reset count monthly (on the 1st, clear entries older than 30 days)
- Keep the file concise — only track promotional/newsletter senders, not personal or transactional email

Skip this task if Gmail MCP is not connected (log a warning).

---

## 2. Calendar Preview

**Type**: Calendar
**MCP required**: Google Calendar

Check the calendar for today and tomorrow:
- List upcoming events with times
- Flag any conflicts or back-to-back meetings without breaks
- Note any events that need preparation

For meetings that involve external participants:
- **First run of the day (06:xx)**: prep all external meetings happening **today**
- **All other runs**: prep external meetings in the **next 6 hours**
- Do a quick web search on the participants and their companies
- Write a brief research note to `output/research/prep-<meeting-slug>.md` covering:
  who they are, their role, their company, and any recent news or context
- Search ActingWeb memories for any prior interactions or notes about these contacts
- **Email cross-reference**: Search Gmail for recent threads (last 30 days) involving the meeting participants. If found, add a section to the prep file:
  ```
  ## Recent Email Context
  - <date>: <subject> — <status: open thread / resolved / awaiting reply>
  ```
  This surfaces unresolved conversations before the meeting. If there are follow-up tracker entries (see `output/emails/follow-ups.md`) for any participant, note those too.
- Skip if a prep file for that meeting already exists

Include the calendar preview in the log.

**ACTIONS.md**: Add or update items for upcoming meetings with prep files, calendar conflicts, and notable events (birthdays, reminders). Remove past events.

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
- **ACTIONS.md**: When proposals are written, add an item under Pending decisions linking to the review file.

---

## 8. Daily News Report (daily)

**Type**: Research
**MCP required**: Gmail, ActingWeb
**Frequency**: Once per day — run on the first cycle of the day only (check if `output/news/news-YYYY-MM-DD.md` already exists; if so, skip)
**Time budget**: Up to 10 minutes (this task reads multiple full newsletters to extract article links and details)

Compile a daily news report from email newsletters, filtered by personal interests stored in ActingWeb memory.

### Step 1: Retrieve news preferences

Search ActingWeb memories with `search(query="in news: *")` to get all stored news preferences. These define what topics to prioritize and surface.

### Step 2: Gather newsletter content

Use the daily newsletter digest (`output/emails/digest-YYYY-MM-DD.md`) produced by Email Triage as the primary source. If the digest doesn't exist yet (news report runs before triage), search Gmail for unread newsletters received since yesterday.

**Include**: News newsletters, industry updates, curated content digests.
**Exclude**: Commercial offerings, service updates, promotional emails, transactional emails.

For each relevant newsletter, extract the key stories — follow links to article titles and descriptions where available in the email body.

### Step 3: Generate the report

Write to `output/news/news-YYYY-MM-DD.md`. Structure:

```markdown
# 📰 Daily News Report — YYYY-MM-DD

## Overview
- **Date range**: <earliest to latest newsletter processed>
- **Newsletters processed**: <count>
- **Top sources**: <top 5 newsletter names>

<2-3 paragraph summary of main themes and any breaking news>

## Top 10 Stories

| # | Topic | Description | Source |
|---|-------|-------------|--------|
| 1 | [Topic] | [Brief description] | [Link to original article] |

*Selection criteria: stories that are unusual/significant, repeated across multiple sources, or match stored news preferences.*

## In-Depth Reading List

5-10 articles worth reading in full:
- **[Title]** — *Publication* — [Link]
  Why: <one sentence on why it's worth reading>

## Preference Matches
Stories that matched stored news preferences, with the preference they matched.
```

**Important**: All links must point to the original articles/web pages, not to the email messages.

### Step 4: Update news preferences

Review the top 10 stories for emerging themes not covered by existing preferences. If a genuinely new interest area is discovered (not just a one-off story):
1. Check existing preferences to avoid duplicates
2. Save a new preference: `save(content="<one-paragraph description of the topic and why it matters>", memory_type="memory_news")`
3. Log what was added

Do **not** add preferences for transient news events — only for durable interest areas.

### Logging

In the run log: `News report generated: <N> newsletters, <M> stories, <K> preference matches. Output: output/news/news-YYYY-MM-DD.md`

**ACTIONS.md**: Add the news report under Reading with a link and a brief summary of the top theme.

---

## Adding New Default Tasks

To add a recurring task, add a new numbered section to this file following the same format:
- Give it a clear name and type
- Specify which MCP connections it requires
- Define what it should do and where output goes
- Add frequency constraints if it shouldn't run every cycle
- Keep tasks small — each should complete in under 2 minutes. Exception: the Daily News Report (task 8) may take up to 10 minutes due to reading multiple full newsletters
