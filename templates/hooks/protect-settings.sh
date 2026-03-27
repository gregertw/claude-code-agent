#!/bin/bash
# Blocks Edit/Write to settings files, hooks, and .env
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

for pattern in "settings.json" "settings.local.json" ".claude/hooks/" ".env"; do
  if [[ "$FILE_PATH" == *"$pattern"* ]]; then
    echo "BLOCKED: Cannot edit '$FILE_PATH' — protected file. Edit manually." >&2
    exit 2
  fi
done

exit 0
