# Capabilities

Optional features that extend the agent's abilities. Each `.md` file in this
directory describes one capability with everything an AI needs to install it.

## How to install a capability

**Interactively**: Start a session in your brain directory and say:
```
Install the <capability-name> capability.
```

**Via INBOX**: Drop a file in `INBOX/` with:
```
Install the agentmail capability. API key: am_us_...
```

**Via ACTIONS.md**: Add an inline comment on any item:
```
> Install the agentmail capability
```

The AI reads the capability file, asks for any missing configuration values,
and makes all the necessary changes to your brain directory.

## What gets modified

Each capability file specifies exactly which files are created or updated.
Typical changes include:

- `ai/instructions/tasks.md` — new task type definition
- `ai/instructions/personal-tasks.md` — new recurring task
- `.claude/skills/<name>/SKILL.md` — new skill
- `.env` — environment variables
- `CLAUDE.md` — folder structure updates (if new output dirs are needed)

## Creating new capabilities

Use the same frontmatter format as existing files. The `config` section defines
what the user needs to provide. The body contains AI instructions for installation.

See `agentmail.md` for a complete example.
