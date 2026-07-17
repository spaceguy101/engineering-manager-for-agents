#!/usr/bin/env bash
# default.sh — the default pause adapter: SIGSTOP/SIGCONT every process
# group on the task window's tty. Preserves all IC state (in-flight network
# requests may time out on resume; the IC retries). A harness that
# misbehaves under SIGSTOP gets its own bin/lib/pause/<harness>.sh with the
# same interface.
#
# Usage:
#   default.sh <pause|resume> <id>
#
# Callers (lib/budget.sh pause_task/resume_task) emit the task_paused/
# task_resumed events — this adapter only signals.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../common.sh"

main() {
  local action="${1:-}" id="${2:-}" sig target tty pgids pg
  case "$action" in
    -h | --help)
      usage
      exit 0
      ;;
    pause) sig=STOP ;;
    resume) sig=CONT ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
  [ -n "$id" ] || {
    usage >&2
    exit 1
  }
  require_id "$id"

  target="$(find_window "$id")" || die "no window for task $id"
  tty="$(tmux_cmd display-message -p -t "$target" '#{pane_tty}')"
  [ -n "$tty" ] || die "cannot resolve the pane tty for $id"
  # Every process group on the pane's tty: the pane shell and the harness's
  # own foreground group. ps -t wants the tty without /dev/ (macOS + Linux).
  pgids="$(ps -t "${tty#/dev/}" -o pgid= 2>/dev/null | tr -d ' ' | sort -u)"
  [ -n "$pgids" ] || die "no processes on ${tty#/dev/} for $id"
  for pg in $pgids; do
    kill "-$sig" "-$pg" 2>/dev/null || true
  done
  log "${action}d $id (SIG$sig to process groups on ${tty#/dev/})"
}

main "$@"
