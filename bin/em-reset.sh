#!/usr/bin/env bash
# em-reset.sh — factory-reset this EM instance: remove every project, worktree,
# task record, and piece of fleet state so the next session starts from scratch.
#
# Usage:
#   em-reset.sh                dry run: list what a reset would remove, flag
#                              anything unsafe, change nothing
#   em-reset.sh --yes          reset. REFUSES (exit 3) while any task is in
#                              flight (meta record or live em-* window) or any
#                              work exists nowhere else: a no-remote clone, a
#                              dirty clone or worktree, commits on no remote.
#   em-reset.sh --yes --force  discard all of that too — only on an explicit
#                              Director instruction.
#
# Removed: projects/* (symlinks are unlinked, their targets untouched),
# worktrees/*, state/* (including the session lock and every task's event log
# under state/tasks/ — the one sanctioned way logs are deleted), every data/
# entry except director.md, and every em-* tmux window (plus the dedicated
# 'em' session).
# Kept: data/director.md (about the Director, not a project) and config/
# (machine-level harness setup) — delete those by hand if a bare instance is
# wanted.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

# em_windows — "name|target" for every live em-* task window; silent without tmux.
em_windows() {
  command -v tmux >/dev/null 2>&1 || return 0
  tmux_cmd list-windows -a -F '#{window_name}|#{session_id}:#{window_index}' 2>/dev/null |
    awk -F '|' '$1 ~ /^em-/ { print }' || true
}

state_entry_count() {
  find "$EM_STATE" -mindepth 1 2>/dev/null | wc -l | tr -d ' '
}

# plan_list — one line per thing a reset removes; empty when already clean.
plan_list() {
  local e n
  em_windows | while IFS='|' read -r name _; do
    printf 'tmux window %s\n' "$name"
  done
  for e in "$EM_WORKTREES"/*; do
    if [ -e "$e" ] || [ -L "$e" ]; then printf 'worktrees/%s\n' "${e##*/}"; fi
  done
  for e in "$EM_PROJECTS"/*; do
    if [ -L "$e" ]; then
      printf 'projects/%s (symlink — target untouched)\n' "${e##*/}"
    elif [ -e "$e" ]; then
      printf 'projects/%s\n' "${e##*/}"
    fi
  done
  n="$(state_entry_count)"
  if [ "$n" -gt 0 ]; then printf 'state/ (%s entries, including task event logs)\n' "$n"; fi
  for e in "$EM_DATA"/*; do
    if { [ -e "$e" ] || [ -L "$e" ]; } && [ "${e##*/}" != director.md ]; then
      printf 'data/%s\n' "${e##*/}"
    fi
  done
}

# unsafe_evidence — one line per piece of work a reset would destroy for good.
unsafe_evidence() {
  local id e
  for id in $(in_flight_ids); do
    printf 'task %s is in flight (state/%s.meta)\n' "$id" "$id"
  done
  em_windows | while IFS='|' read -r name _; do
    printf 'live task window %s\n' "$name"
  done
  for e in "$EM_WORKTREES"/*; do
    [ -d "$e" ] || continue
    if [ -n "$(git -C "$e" status --porcelain 2>/dev/null | head -n 1)" ]; then
      printf 'worktrees/%s has uncommitted changes\n' "${e##*/}"
    fi
  done
  for e in "$EM_PROJECTS"/*; do
    [ -d "$e/.git" ] || continue
    [ -L "$e" ] && continue # only the link is removed; the target survives
    if ! git -C "$e" remote get-url origin >/dev/null 2>&1; then
      printf 'projects/%s has no remote — deleting the clone destroys the project\n' "${e##*/}"
      continue
    fi
    if [ -n "$(git -C "$e" status --porcelain 2>/dev/null | head -n 1)" ]; then
      printf 'projects/%s has uncommitted changes\n' "${e##*/}"
    fi
    if [ -n "$(git -C "$e" log --oneline --branches --not --remotes 2>/dev/null | head -n 1)" ]; then
      printf 'projects/%s has commits on no remote\n' "${e##*/}"
    fi
  done
}

do_reset() {
  local name target e
  while IFS='|' read -r name target; do
    [ -n "$target" ] || continue
    tmux_cmd kill-window -t "$target" 2>/dev/null || true
    log "killed $name"
  done <<< "$(em_windows)"
  # The dedicated background session is ours too — unless we're inside it.
  if command -v tmux >/dev/null 2>&1 && tmux_cmd has-session -t '=em' 2>/dev/null; then
    if ! { inside_tmux && [ "$(tmux_cmd display-message -p '#{session_name}' 2>/dev/null)" = em ]; }; then
      tmux_cmd kill-session -t '=em' 2>/dev/null || true
    fi
  fi

  for e in "$EM_WORKTREES"/*; do
    { [ -e "$e" ] || [ -L "$e" ]; } || continue
    "$EM_BIN/em-worktree.sh" remove "${e##*/}" --force >/dev/null 2>&1 || rm -rf "$e"
    log "removed worktrees/${e##*/}"
  done

  for e in "$EM_PROJECTS"/*; do
    if [ -L "$e" ]; then
      # Clear our worktree records from the target before letting it go.
      git -C "$e" worktree prune 2>/dev/null || true
      rm -f "$e"
      log "unlinked projects/${e##*/} (target untouched)"
    elif [ -e "$e" ]; then
      rm -rf "$e"
      log "removed projects/${e##*/}"
    fi
  done

  rm -rf "$EM_STATE"
  mkdir -p "$EM_STATE" "$EM_PROJECTS" "$EM_WORKTREES"

  for e in "$EM_DATA"/*; do
    { [ -e "$e" ] || [ -L "$e" ]; } || continue
    [ "${e##*/}" = director.md ] && continue
    rm -rf "$e"
  done

  log "reset complete — projects, worktrees, tasks, and fleet state removed (data/director.md and config/ kept)"
}

main() {
  local yes="" force="" arg plan evidence
  for arg in "$@"; do
    case "$arg" in
      -h | --help) usage; exit 0 ;;
      --yes) yes=1 ;;
      --force) force=1 ;;
      *) die "unknown option '$arg' (only --yes, --force)" ;;
    esac
  done
  if [ -n "$force" ] && [ -z "$yes" ]; then
    die "--force needs --yes"
  fi

  plan="$(plan_list)"
  evidence="$(unsafe_evidence)"

  if [ -z "$yes" ]; then
    if [ -z "$plan" ]; then
      log "nothing to reset — the instance is already clean"
      exit 0
    fi
    while IFS= read -r arg; do
      printf 'would remove: %s\n' "$arg"
    done <<< "$plan"
    if [ -n "$evidence" ]; then
      while IFS= read -r arg; do
        warn "would destroy work that exists nowhere else: $arg"
      done <<< "$evidence"
    fi
    log "dry run — re-run with --yes to reset${evidence:+; the flagged work also needs --force, only on an explicit Director instruction to discard}"
    exit 0
  fi

  if [ -n "$evidence" ] && [ -z "$force" ]; then
    {
      printf 'REFUSED: a reset would destroy work that exists nowhere else:\n%s\n' "$evidence"
      printf 'Land or tear down that work first. Only on an explicit Director instruction to discard may this be re-run with --force.\n'
    } >&2
    exit 3
  fi

  do_reset
}

main "$@"
