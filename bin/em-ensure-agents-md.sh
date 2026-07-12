#!/usr/bin/env bash
# em-ensure-agents-md.sh — ensure a project's memory file is real: AGENTS.md
# is a regular file and CLAUDE.md is a symlink to it.
#
# Usage:
#   em-ensure-agents-md.sh [<dir>]     default: current directory
#
# Run by ICs inside their worktree (project memory is written only by ICs
# through the delivery pipeline — PRD §4.6). Idempotent. If CLAUDE.md is a
# regular file and AGENTS.md is missing, CLAUDE.md's content becomes
# AGENTS.md; if both exist as regular files, this refuses so a human/IC can
# merge them deliberately.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  case "${1:-}" in -h | --help) usage; exit 0 ;; esac
  local dir="${1:-$PWD}" name
  [ -d "$dir" ] || die "no such directory: $dir"
  name="$(basename "$(cd "$dir" && pwd -P)")"

  local agents="$dir/AGENTS.md" claude="$dir/CLAUDE.md"

  if [ ! -e "$agents" ]; then
    if [ -f "$claude" ] && [ ! -L "$claude" ]; then
      mv "$claude" "$agents"
      log "moved CLAUDE.md content to AGENTS.md"
    else
      printf '# %s — project memory\n\nDurable, project-intrinsic knowledge: build/test/release mechanics,\nconventions, sharp edges. Added lazily as it is learned.\n' \
        "$name" > "$agents"
      log "created AGENTS.md"
    fi
  elif [ -f "$claude" ] && [ ! -L "$claude" ]; then
    die "both AGENTS.md and CLAUDE.md exist as regular files in $dir — merge CLAUDE.md into AGENTS.md, then re-run"
  fi

  if [ -L "$claude" ]; then
    rm "$claude"
  fi
  ln -s AGENTS.md "$claude"
  log "CLAUDE.md -> AGENTS.md"
}

main "$@"
