#!/usr/bin/env bash
# =============================================================================
# Install template files into the brain directory.
# Usage: ./install-templates.sh
# =============================================================================

set -euo pipefail

BRAIN="${HOME}/brain"

# Try pending-templates first, fall back to .agent-templates, then repo
if [[ -d "${HOME}/pending-templates" ]]; then
  TEMPLATES="${HOME}/pending-templates"
elif [[ -d "${HOME}/.agent-templates" ]]; then
  TEMPLATES="${HOME}/.agent-templates"
elif [[ -d "${HOME}/.agent-repo/templates" ]]; then
  TEMPLATES="${HOME}/.agent-repo/templates"
else
  echo "No templates found. Nothing to install."
  exit 0
fi

if [[ ! -d "${BRAIN}" ]]; then
  echo "ERROR: ${BRAIN} not found."
  exit 1
fi

source "${HOME}/.agent-server.conf" 2>/dev/null || true
OUTPUT_FOLDER="${OUTPUT_FOLDER:-output}"

mkdir -p "${BRAIN}/ai/instructions"
mkdir -p "${BRAIN}/INBOX/_processed"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/tasks"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/logs"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/research"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/improvements"

for f in "${TEMPLATES}"/*.md; do
  [[ ! -f "$f" ]] && continue
  BASENAME=$(basename "$f")
  if [[ "$BASENAME" == "CLAUDE.md" ]]; then
    TARGET="${BRAIN}/CLAUDE.md"
  else
    TARGET="${BRAIN}/ai/instructions/${BASENAME}"
  fi
  if [[ ! -f "${TARGET}" ]]; then
    cp "$f" "${TARGET}"
    echo "  Installed: ${TARGET}"
  else
    echo "  Skipped (exists): ${TARGET}"
  fi
done

echo ""
echo "Done. You can remove ~/pending-templates/ now."
