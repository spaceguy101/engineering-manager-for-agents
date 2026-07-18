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
  local status

  [ -n "$(in_flight_ids)" ] || exit 0

  # Shared predicate with em-turnend-guard.sh: fresh beacon means supervision is
  # live and this is a silent no-op. em-guard warns; the turn-end hook blocks.
  status="$(watcher_beacon_status "${EM_GUARD_GRACE:-300}")" && exit 0
  warn "tasks are in flight but the watcher beacon is $status — restart bin/em-watch.sh before anything else"
  exit 0
}

main "$@"
