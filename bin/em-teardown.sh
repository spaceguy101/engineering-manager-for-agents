#!/usr/bin/env bash
# em-teardown.sh — offboard an IC: return the worktree, kill the window,
# clear volatile state. Keeps data/<id>/ (brief/report are durable).
#
# Usage:
#   em-teardown.sh <id> [--force] [--purge-logs]
#
# Build tasks: REFUSES (exit 3) if the worktree holds unlanded work
# (ADR-0002, via em-worktree.sh remove) — treat a refusal as
# stop-and-investigate. --force discards that work and is only for an
# explicit Director instruction.
# Research tasks (kind=research in meta): the worktree is declared scratch —
# teardown requires only that data/<id>/report.md exists, and REFUSES (exit
# 3) without it.
# The task's audit log (state/tasks/<project>/<id>/) is kept by default;
# --purge-logs removes it after a successful teardown only — a refused
# teardown never purges anything.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

main() {
  local id="" force="" purge_logs=0 arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help) usage; exit 0 ;;
      --force) force="--force" ;;
      --purge-logs) purge_logs=1 ;;
      -*) die "unknown option '$arg' (only --force, --purge-logs)" ;;
      *)
        [ -z "$id" ] || { usage >&2; exit 1; }
        id="$arg"
        ;;
    esac
  done
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"

  # Research worktrees are scratch: the report is the deliverable, and the
  # only teardown precondition.
  local kind
  kind="$(meta_get "$id" kind 2>/dev/null || printf 'build')"
  if [ "$kind" = "research" ] && [ "$force" != "--force" ]; then
    [ -s "$EM_DATA/$id/report.md" ] || {
      emit_event "$id" teardown_refused --actor em --data '{"reason": "no-report"}'
      die_refuse "research task $id has no report at data/$id/report.md — get the report written first (or --force on an explicit Director instruction to discard)"
    }
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
        emit_event "$id" teardown_refused --actor em --data '{"reason": "unlanded-work"}'
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

  # Events before the meta goes (the writer resolves the project from it).
  # The rm glob never touches state/tasks/ — event logs are retained.
  local project
  project="$(meta_get "$id" project 2>/dev/null || true)"
  if [ "$kind" = "research" ] && [ -s "$EM_DATA/$id/report.md" ]; then
    emit_event "$id" report_delivered --actor em \
      --data "$(jq -cn --arg r "data/$id/report.md" '{report: $r}' 2>/dev/null || true)"
  fi
  emit_event "$id" teardown_completed --actor em
  emit_event "$id" task_closed --actor em

  rm -f "$EM_STATE/$id".* "$EM_STATE/.watch."*".$id"
  if [ "$purge_logs" -eq 1 ]; then
    if [ -n "$project" ]; then
      rm -rf "$(task_dir "$id" "$project")"
      log "purged the audit log of $id"
    else
      warn "cannot resolve project for $id — audit log not purged"
    fi
  fi
  log "teardown of $id complete (data/$id/ kept)"
}

main "$@"
