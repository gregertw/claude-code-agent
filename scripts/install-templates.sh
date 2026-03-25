#!/usr/bin/env bash
# =============================================================================
# Install template files into the brain directory.
# Usage: ./install-templates.sh [--upgrade]
#
# On first install: creates all files.
# On upgrade (--upgrade or files already exist): overwrites system files,
# preserves user-customized files.
#
# System files (overwritten on upgrade):
#   CLAUDE.md, tasks.md, default-tasks.md
#
# User files (never overwritten):
#   personal.md, style.md, personal-tasks.md, ACTIONS.md
# =============================================================================

set -euo pipefail

BRAIN="${HOME}/brain"
UPGRADE=false

if [[ "${1:-}" == "--upgrade" ]]; then
  UPGRADE=true
fi

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

# --- Create directory structure -----------------------------------------------
mkdir -p "${BRAIN}/ai/instructions"
mkdir -p "${BRAIN}/ai/scratchpad"
mkdir -p "${BRAIN}/INBOX/_processed"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/tasks"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/logs"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/research"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/improvements"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/emails"
mkdir -p "${BRAIN}/${OUTPUT_FOLDER}/news"

# --- File classification ------------------------------------------------------
# System files: core agent instructions that improve with each release.
# These are safe to overwrite because users should not edit them directly.
# User files: templates for personalization. Only installed once, never overwritten.

is_system_file() {
  case "$1" in
    CLAUDE.md|tasks.md|default-tasks.md) return 0 ;;
    *) return 1 ;;
  esac
}

is_root_file() {
  case "$1" in
    CLAUDE.md|ACTIONS.md) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Install AI instruction templates ----------------------------------------
for f in "${TEMPLATES}"/*.md; do
  [[ ! -f "$f" ]] && continue
  BASENAME=$(basename "$f")

  if is_root_file "$BASENAME"; then
    TARGET="${BRAIN}/${BASENAME}"
  else
    TARGET="${BRAIN}/ai/instructions/${BASENAME}"
  fi

  if [[ ! -f "${TARGET}" ]]; then
    # First install — always copy
    cp "$f" "${TARGET}"
    echo "  Installed: ${TARGET}"
  elif is_system_file "$BASENAME"; then
    # System file exists — overwrite on upgrade, skip otherwise
    if [[ "$UPGRADE" == true ]]; then
      cp "$f" "${TARGET}"
      echo "  Updated: ${TARGET}"
    else
      echo "  Skipped (exists): ${TARGET}"
    fi
  else
    # User file — never overwrite
    echo "  Preserved: ${TARGET}"
  fi
done

# --- Install Obsidian document templates --------------------------------------
OBSIDIAN_TEMPLATES="${TEMPLATES}/obsidian"
if [[ -d "${OBSIDIAN_TEMPLATES}" ]]; then
  mkdir -p "${BRAIN}/templates"
  for f in "${OBSIDIAN_TEMPLATES}"/*.md; do
    [[ ! -f "$f" ]] && continue
    BASENAME=$(basename "$f")
    TARGET="${BRAIN}/templates/${BASENAME}"
    if [[ ! -f "${TARGET}" ]]; then
      cp "$f" "${TARGET}"
      echo "  Installed: ${TARGET}"
    else
      echo "  Skipped (exists): ${TARGET}"
    fi
  done
fi

# --- Summary ------------------------------------------------------------------
echo ""
if [[ "$UPGRADE" == true ]]; then
  echo "Upgrade complete. System files updated, user files preserved."
  echo "You can remove ~/pending-templates/ now."
else
  echo "Done. You can remove ~/pending-templates/ now."
  echo ""
  echo "NEXT STEPS:"
  echo "  1. Edit ai/instructions/personal.md — fill in your identity and preferences"
  echo "  2. Edit ai/instructions/style.md — define your writing voice"
  echo "  3. Add custom recurring tasks in ai/instructions/personal-tasks.md"
  echo "  4. Review ACTIONS.md — this is your dashboard for agent action items"
  echo "  5. Drop tasks in INBOX/ as .md files to give the agent work"
  echo "  6. Email drafts appear in ${OUTPUT_FOLDER}/emails/ with status: frontmatter"
  echo "     Change status to 'approved' and the agent sends on next run"
fi
