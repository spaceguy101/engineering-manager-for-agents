#!/usr/bin/env bash
# em-promote.sh — promote a research task in place into a protected build
# task (its scratch worktree becomes a real workspace: full unlanded-work
# teardown protection is restored).
#
# Usage:
#   em-promote.sh <id>
#
# Flips kind= to build in the task's meta and prints the instruction
# checklist the EM relays to the IC (PRD §4.7 promotion).
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

main() {
  local id="${1:-}"
  case "$id" in -h | --help) usage; exit 0 ;; esac
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"

  local kind
  kind="$(meta_get "$id" kind)" || die "no meta record for task $id"
  [ "$kind" = "research" ] || die "task $id is kind=$kind — only research tasks can be promoted"

  meta_set "$id" kind build
  log "task $id promoted to a build task (teardown protection restored)"
  cat <<'EOF'
Relay to the IC (one line at a time, or via a notes file):
1. Inventory your scratch state: what changed, what is worth keeping.
2. Reset to a clean base (fetch + hard reset to the default branch), then
   carry over only the changes you intend to ship.
3. Create your branch: git checkout -b em/<id>.
4. Implement properly — if you built a repro, turn it into a regression test.
5. From here this is a normal build task: gate (if configured), delivery per
   the project's mode, same status protocol.
EOF
}

main "$@"
