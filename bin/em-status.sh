#!/usr/bin/env bash
# em-status.sh — one-screen fleet overview: one line per in-flight task.
#
# Usage:
#   em-status.sh
#
# Columns: id, project, kind/mode, pane state (busy|idle|dead), and the
# task's last status line, with the recorded PR URL appended when one is
# armed. busy = the pane matches EM_BUSY_REGEX (the default covers claude's
# "esc to interrupt" and cursor's "Running <n> tokens" working indicators;
# extend it when verifying other harnesses).
# Cheap by design: pane content is only pattern-matched for the busy check,
# never printed (that's em-peek.sh). Prints "no tasks in flight" when the
# fleet is idle. The first stop for recovery and every heartbeat review.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

main() {
  case "${1:-}" in -h | --help) usage; exit 0 ;; esac
  [ $# -eq 0 ] || { usage >&2; exit 1; }

  local ids
  ids="$(in_flight_ids)"
  if [ -z "$ids" ]; then
    printf 'no tasks in flight\n'
    return 0
  fi

  local busy_re="${EM_BUSY_REGEX:-esc to interrupt|Running +[0-9]+ tokens}"

  printf '%-18s %-14s %-18s %-5s %s\n' ID PROJECT KIND/MODE PANE 'LAST STATUS'
  local id project kind mode pr target win last
  for id in $ids; do
    project="$(meta_get "$id" project || true)"
    kind="$(meta_get "$id" kind || true)"
    mode="$(meta_get "$id" mode || true)"
    pr="$(meta_get "$id" pr || true)"
    [ -n "$project" ] || project='?'
    [ -n "$kind" ] || kind='?'
    [ -n "$mode" ] || mode='?'
    if target="$(find_window "$id")"; then
      if tmux_cmd capture-pane -p -t "$target" 2>/dev/null | grep -qE "$busy_re"; then
        win=busy
      else
        win=idle
      fi
    else
      win=dead
    fi
    last="$(tail -n 1 "$EM_STATE/$id.status" 2>/dev/null || true)"
    [ -n "$last" ] || last='-'
    [ -z "$pr" ] || last="$last  [pr: $pr]"
    printf '%-18s %-14s %-18s %-5s %s\n' "$id" "$project" "$kind/$mode" "$win" "$last"
  done
}

main "$@"
