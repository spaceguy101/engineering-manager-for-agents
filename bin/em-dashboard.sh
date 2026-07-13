#!/usr/bin/env bash
# em-dashboard.sh — Director-facing live fleet view (read-only).
#
# Usage:
#   em-dashboard.sh [--interval <seconds>] [--once]
#
# Redraws a single frame every <seconds> (default 2): the fleet overview
# (em-status.sh's table), a supervision-liveness line, and the backlog's
# Queued section. --once prints one frame and exits (for scripting/tests).
# Pure renderer: reads state/, data/, and tmux; writes nothing, and is safe
# for the Director to leave running in any terminal. Ctrl-C to quit.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

COLOR=0

# Tint the status table when on a terminal: red for a dead pane, yellow for
# a task waiting on attention. Field 4 is PANE, field 5 starts LAST STATUS
# (ids/projects/kind-mode never contain spaces).
colorize() {
  if [ "$COLOR" -ne 1 ]; then
    cat
    return
  fi
  awk '
    NR == 1 { print; next }
    $4 == "dead" { printf "\033[31m%s\033[0m\n", $0; next }
    $5 ~ /^(blocked|failed|needs-decision):/ { printf "\033[33m%s\033[0m\n", $0; next }
    { print }'
}

# One line on whether anyone is supervising: mirrors em-guard.sh's beacon
# check, but display-only (the guard's stderr warning is EM-facing).
supervision_line() {
  [ -n "$(in_flight_ids)" ] || return 0
  local beacon="$EM_STATE/.last-watcher-beat" grace="${EM_GUARD_GRACE:-300}" age
  printf '\n'
  if [ ! -f "$beacon" ]; then
    printf 'supervision: OFF — watcher not running\n'
    return 0
  fi
  age=$(($(date +%s) - $(mtime "$beacon" || echo 0)))
  if [ "$age" -gt "$grace" ]; then
    printf 'supervision: STALE — last watcher check %ss ago\n' "$age"
  else
    printf 'supervision: active — last watcher check %ss ago\n' "$age"
  fi
}

# When ICs run in the dedicated detached 'em' session (EM launched outside
# tmux), nothing on screen betrays their existence — tell the Director how
# to look. Windows in the EM's own session already show in the status bar.
attach_hint() {
  [ -n "$(in_flight_ids)" ] || return 0
  tmux_cmd has-session -t '=em' 2>/dev/null || return 0
  printf '\nwatch an IC live: tmux attach -t em   (Ctrl-b n next window, Ctrl-b d detach)\n'
}

queued_section() {
  local backlog="$EM_DATA/backlog.md" lines
  [ -f "$backlog" ] || return 0
  lines="$(awk '/^## Queued/ { f = 1; next } f && /^## / { exit } f && NF { print }' "$backlog")"
  [ -n "$lines" ] || return 0
  printf '\nQueued:\n%s\n' "$lines"
}

render() {
  printf 'EM fleet — %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S')"
  "$EM_BIN/em-status.sh" 2>/dev/null | colorize
  supervision_line
  queued_section
  attach_hint
}

main() {
  local interval=2 once=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --once) once=1 ;;
      --interval)
        [ $# -ge 2 ] || die "--interval requires a value"
        shift
        interval="$1"
        ;;
      *) usage >&2; exit 1 ;;
    esac
    shift
  done
  case "$interval" in
    *[!0-9]* | '' | 0) die "interval must be a positive integer, got '$interval'" ;;
  esac
  [ -t 1 ] && COLOR=1

  if [ "$once" -eq 1 ]; then
    render
    return 0
  fi

  trap 'printf "\n"; exit 0' INT TERM
  printf '\033[2J' # start from a clean screen
  local frame
  while :; do
    frame="$(render)"
    # home the cursor, draw the frame, erase whatever the last frame left
    printf '\033[H%s\n\033[0J' "$frame"
    sleep "$interval"
  done
}

main "$@"
