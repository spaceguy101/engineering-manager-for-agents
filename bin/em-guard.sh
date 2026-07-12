#!/usr/bin/env bash
# em-guard.sh — liveness guard: warn (stderr) when tasks are in flight but the
# watcher beacon is stale or missing.
#
# Usage:
#   em-guard.sh
#
# Called first by every supervision script. A warning means: restart
# bin/em-watch.sh before doing anything else. Always exits 0 — it warns,
# never blocks. The grace window (EM_GUARD_GRACE, default 300s) keeps normal
# watcher-restart gaps silent.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  case "${1:-}" in -h | --help) usage; exit 0 ;; esac
  local grace="${EM_GUARD_GRACE:-300}" beacon="$EM_STATE/.last-watcher-beat" age

  [ -n "$(in_flight_ids)" ] || exit 0

  if [ ! -f "$beacon" ]; then
    warn "tasks are in flight but the watcher beacon is missing — restart bin/em-watch.sh before anything else"
    exit 0
  fi
  age=$(($(date +%s) - $(mtime "$beacon")))
  if [ "$age" -gt "$grace" ]; then
    warn "tasks are in flight but the watcher beacon is ${age}s old (grace ${grace}s) — restart bin/em-watch.sh before anything else"
  fi
  exit 0
}

main "$@"
