#!/usr/bin/env bash
# em-teardown.sh — offboard an IC: return the worktree, kill the window,
# clear volatile state. Keeps data/<id>/ (brief/report are durable).
#
# Usage:
#   em-teardown.sh <id> [--force]
#
# Build tasks: REFUSES (exit 3) if the worktree holds unlanded work
# (ADR-0002, via em-worktree.sh remove) — treat a refusal as
# stop-and-investigate. --force discards that work and is only for an
# explicit Director instruction.
# Research tasks (kind=research in meta): the worktree is declared scratch —
# teardown requires only that data/<id>/report.md exists, and REFUSES (exit
# 3) without it.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

main() {
  local id="${1:-}" force="${2:-}"
  case "$id" in -h | --help) usage; exit 0 ;; esac
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"
  [ -z "$force" ] || [ "$force" = "--force" ] || die "unknown option '$force' (only --force)"

  # Research worktrees are scratch: the report is the deliverable, and the
  # only teardown precondition.
  local kind
  kind="$(meta_get "$id" kind 2>/dev/null || printf 'build')"
  if [ "$kind" = "research" ] && [ "$force" != "--force" ]; then
    [ -s "$EM_DATA/$id/report.md" ] ||
      die_refuse "research task $id has no report at data/$id/report.md — get the report written first (or --force on an explicit Director instruction to discard)"
    force="--force" # report exists; the scratch worktree may go regardless of unlanded work
  fi

  # Worktree first: if the unlanded-work check refuses, nothing else is
  # touched — the window and state stay for investigation.
  if [ -d "$EM_WORKTREES/$id" ]; then
    local rc=0
    if [ "$force" = "--force" ]; then
      "$EM_BIN/em-worktree.sh" remove "$id" --force
    else
      "$EM_BIN/em-worktree.sh" remove "$id" || rc=$?
      if [ "$rc" -eq 3 ]; then
        log "teardown of $id aborted — window and state kept for investigation"
        exit 3
      elif [ "$rc" -ne 0 ]; then
        die "worktree removal failed for $id (exit $rc)"
      fi
    fi
  else
    warn "no worktree at worktrees/$id — cleaning up window and state only"
  fi

  local target
  if target="$(find_window "$id")"; then
    tmux_cmd kill-window -t "$target"
  fi

  rm -f "$EM_STATE/$id".* "$EM_STATE/.watch."*".$id"
  log "teardown of $id complete (data/$id/ kept)"
}

main "$@"
