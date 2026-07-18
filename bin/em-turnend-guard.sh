#!/usr/bin/env bash
# em-turnend-guard.sh — push-based turn-end supervision backstop for the EM's
# OWN (primary) claude session. Registered as a Stop hook in this repo's tracked
# .claude/settings.json; reads the claude Stop payload on stdin.
#
# em-guard.sh is pull-based: it only warns when some other supervision script
# happens to run, and prints nothing otherwise. If the EM ends a turn after
# handling wakes without restarting the watcher, and then runs no further
# fleet-touching command, the fleet sits blind indefinitely. This hook closes
# that gap: it fires on every turn end, and when tasks are in flight but the
# watcher beacon is missing or stale it BLOCKS the stop (exit 2) and feeds the
# reason back to the model, so the EM restarts bin/em-watch.sh before the turn
# actually ends.
#
# Loop guard: claude Stop payloads carry stop_hook_active=true when the current
# stop was itself already forced by an earlier block this turn. On that signal
# we always allow the stop — at most one forced continuation per turn, never a
# wedged, un-endable session, while still nagging again on a later turn if the
# problem persists.
#
# Scope: this is a TRACKED hook, so it is checked out into every worktree of
# this repo — including a task worktree if an IC is ever dispatched to work on
# the EM system itself. It scopes itself to the PRIMARY checkout and is a silent
# no-op in a linked worktree. It fails OPEN (exit 0) on any ambiguity — a hook
# must never wedge a session.
#
# Usage:
#   em-turnend-guard.sh        reads the Stop hook payload on stdin
set -u
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

case "${1:-}" in -h | --help) usage; exit 0 ;; esac

GRACE="${EM_GUARD_GRACE:-300}"

# Read the whole hook payload once; never block on unreadable/absent stdin.
PAYLOAD="$(cat 2>/dev/null || true)"
[ -n "$PAYLOAD" ] || exit 0

# jq is a hard EM prerequisite (event log + budgets). Without it we cannot read
# the loop-guard field safely, so fail open rather than risk a wedge.
command -v jq >/dev/null 2>&1 || exit 0
stop_active="$(printf '%s' "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" || exit 0
[ "$stop_active" = "true" ] && exit 0

# Scope to the PRIMARY checkout: inert in a linked worktree (an IC working on
# EM itself), which is the only other place this tracked hook is checked out. A
# linked worktree's git-dir differs from the shared git-common-dir; the primary
# checkout has them equal. A non-git EM_ROOT is not a linked worktree, so we
# only bail when we can positively prove one.
git_dir="$(git -C "$EM_ROOT" rev-parse --git-dir 2>/dev/null || true)"
common_dir="$(git -C "$EM_ROOT" rev-parse --git-common-dir 2>/dev/null || true)"
if [ -n "$git_dir" ] && [ -n "$common_dir" ] && [ "$git_dir" != "$common_dir" ]; then
  exit 0
fi
[ -d "$EM_STATE" ] || exit 0

# The predicate: work in flight AND no live watcher → block the turn end.
ids="$(in_flight_ids)"
[ -n "$ids" ] || exit 0
status="$(watcher_beacon_status "$GRACE")" && exit 0

count="$(printf '%s\n' "$ids" | grep -c .)"
rule='━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
{
  printf '%s\n' "$rule"
  printf 'TURN WOULD END BLIND — SUPERVISION IS OFF\n'
  printf '%s task(s) in flight, but the watcher beacon is %s.\n' "$count" "$status"
  printf 'Restart bin/em-watch.sh in the background before ending this turn.\n'
  printf '%s\n' "$rule"
} >&2
exit 2
