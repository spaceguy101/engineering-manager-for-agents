#!/usr/bin/env bash
# em-relaunch.sh — relaunch a stuck task's harness in its existing worktree
# (stuck-IC playbook step 4): optionally append a progress note to the
# brief, recreate the window if it died, then replay the launch command
# recorded at spawn time. The worktree and its commits persist — a relaunch
# is cheap and loses nothing.
#
# Usage:
#   em-relaunch.sh <id> [--note "<one line of progress context>"]
#
# The old harness must have exited first (pane at a shell prompt, or the
# window gone entirely) — the launch command is typed into the window, so a
# still-running harness would swallow it as chat. Interrupt/exit it first
# (em-send.sh <id> --key Escape, then have it exit).
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

main() {
  local id="" note=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --note)
        [ $# -ge 2 ] || die "--note needs a value"
        note="$2"
        shift
        ;;
      -*) die "unknown option '$1' (only --note)" ;;
      *)
        [ -z "$id" ] || { usage >&2; exit 1; }
        id="$1"
        ;;
    esac
    shift
  done
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"

  local wt launch brief="$EM_DATA/$id/brief.md"
  wt="$(meta_get "$id" worktree)" || die "no meta record for task $id"
  [ -d "$wt" ] || die "worktree $wt is gone — cannot relaunch; respawn the task instead"
  launch="$(meta_get "$id" launch || true)"
  [ -n "$launch" ] ||
    die "no launch command recorded for $id (spawned before relaunch support) — send the harness launch command manually with em-send.sh"
  [ -f "$brief" ] || die "no brief at data/$id/brief.md"

  if [ -n "$note" ]; then
    printf '\n## Progress note (%s)\n\n%s\n' "$(date +%Y-%m-%d)" "$note" >> "$brief"
  fi

  local target
  if ! target="$(find_window "$id")"; then
    create_task_window "$(window_name "$id")" "$wt"
    target="$(find_window "$id")" || die "window $(window_name "$id") vanished after creation"
  fi
  tmux_cmd send-keys -t "$target" -l -- "$launch"
  tmux_cmd send-keys -t "$target" Enter
  log "relaunched $id — peek within ~20s (em-peek.sh $id) to confirm it picked the brief back up"
}

main "$@"
