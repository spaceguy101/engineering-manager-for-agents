#!/usr/bin/env bash
# em-lock.sh — single-EM session lock (one EM per machine, PRD §2.2).
#
# Usage:
#   em-lock.sh acquire     take the lock; REFUSES (exit 3) if another live
#                          session holds it (then: report and go read-only)
#   em-lock.sh release     drop the lock
#   em-lock.sh status      print the holder, or "unlocked"
#
# The lock records the owning session's process id (EM_SESSION_PID if set,
# else this script's parent). A lock whose process is dead is stale and is
# taken over silently — a crashed EM must not brick the machine.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

LOCK="$EM_STATE/.session-lock"
SELF="${EM_SESSION_PID:-$PPID}"

holder_pid() {
  [ -f "$LOCK" ] || return 1
  awk -F= '$1 == "pid" { print $2; exit }' "$LOCK"
}

cmd_acquire() {
  local pid
  if pid="$(holder_pid)" && [ -n "$pid" ] && [ "$pid" != "$SELF" ] && kill -0 "$pid" 2>/dev/null; then
    die_refuse "another EM session (pid $pid, since $(awk -F= '$1=="since"{print $2}' "$LOCK")) holds the lock — go read-only or stop the other session"
  fi
  mkdir -p "$EM_STATE"
  printf 'pid=%s\nsince=%s\n' "$SELF" "$(date +%Y-%m-%dT%H:%M:%S)" > "$LOCK"
  log "session lock acquired (pid $SELF)"
}

cmd_release() {
  rm -f "$LOCK"
}

cmd_status() {
  if [ -f "$LOCK" ]; then
    cat "$LOCK"
  else
    printf 'unlocked\n'
  fi
}

case "${1:-}" in
  acquire) cmd_acquire ;;
  release) cmd_release ;;
  status) cmd_status ;;
  -h | --help) usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
