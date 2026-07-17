#!/usr/bin/env bash
# em-status.sh — one-screen fleet overview: one line per in-flight task.
#
# Usage:
#   em-status.sh
#
# Columns: id, project, kind/mode, pane state (busy|idle|dead), the last
# audit-log event with its age (e.g. gate_failed+3m, from
# state/tasks/<project>/<id>/events.jsonl; "-" without a log), and the
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

# age_fmt <seconds> — compact age: 42s, 7m, 3h, 2d.
age_fmt() {
  local s="$1"
  if [ "$s" -lt 60 ]; then printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%sm' $((s / 60))
  elif [ "$s" -lt 86400 ]; then printf '%sh' $((s / 3600))
  else printf '%sd' $((s / 86400)); fi
}

# last_event_cell <id> <project> — "<event>+<age>" from the task's audit
# log; "-" when there is no log (or no jq). Never fails the row.
last_event_cell() {
  local f="$EM_STATE/tasks/$2/$1/events.jsonl" ev ep
  if [ ! -f "$f" ] || ! command -v jq >/dev/null 2>&1; then
    printf -- '-\n'
    return 0
  fi
  ev="$(tail -n 1 "$f" 2>/dev/null | jq -r '.event // "-"' 2>/dev/null)" || ev=""
  ep="$(tail -n 1 "$f" 2>/dev/null | jq -r '.ts_epoch // 0' 2>/dev/null)" || ep=0
  [ -n "$ev" ] || {
    printf -- '-\n'
    return 0
  }
  if [ "$ep" -gt 0 ] 2>/dev/null; then
    printf '%s+%s\n' "$ev" "$(age_fmt $(($(date +%s) - ep)))"
  else
    printf '%s\n' "$ev"
  fi
}

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

  printf '%-18s %-14s %-18s %-5s %-20s %s\n' ID PROJECT KIND/MODE PANE EVENT 'LAST STATUS'
  local id project kind mode pr target win last event
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
    event="$(last_event_cell "$id" "$project")"
    last="$(tail -n 1 "$EM_STATE/$id.status" 2>/dev/null || true)"
    [ -n "$last" ] || last='-'
    [ -z "$pr" ] || last="$last  [pr: $pr]"
    printf '%-18s %-14s %-18s %-5s %-20s %s\n' "$id" "$project" "$kind/$mode" "$win" "$event" "$last"
  done
}

main "$@"
