#!/usr/bin/env bash
# em-watch.sh — the supervision backbone: block (at zero token cost) until
# supervision work is due, then exit printing exactly one reason line.
#
# Usage:
#   em-watch.sh          run in the background; handle its exit, restart it
#
# Reason lines (stdout):
#   idle                    no tasks in flight — don't restart until dispatch
#   signal <id> [<id>…]     new status line(s); read the listed status files
#   stale <id>              IC's turn ended without a status report; peek it
#   check <id>: <output>    the task's state/<id>.check.sh fired; act on it
#   heartbeat               mandatory full-fleet review
#
# Priority per poll: due per-task checks run before signal scanning (so
# chatty ICs can't starve merge detection), then signals (coalesced within
# EM_SIGNAL_GRACE), then stale detection, then the heartbeat. Heartbeats
# back off exponentially (EM_HEARTBEAT doubling to EM_HEARTBEAT_MAX) while
# they are the only wakes; any other wake resets the cadence. Touches the
# liveness beacon (state/.last-watcher-beat) every poll — em-guard.sh warns
# when it goes stale.
#
# Tuning env vars (defaults): EM_POLL=15, EM_SIGNAL_GRACE=30,
# EM_CHECK_INTERVAL=300, EM_CHECK_TIMEOUT=30, EM_HEARTBEAT=600,
# EM_HEARTBEAT_MAX=7200.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

POLL="${EM_POLL:-15}"
SIGNAL_GRACE="${EM_SIGNAL_GRACE:-30}"
CHECK_INTERVAL="${EM_CHECK_INTERVAL:-300}"
CHECK_TIMEOUT="${EM_CHECK_TIMEOUT:-30}"
HEARTBEAT="${EM_HEARTBEAT:-600}"
HEARTBEAT_MAX="${EM_HEARTBEAT_MAX:-7200}"

BEACON="$EM_STATE/.last-watcher-beat"

status_lines() { # <id> — count of status lines
  local f="$EM_STATE/$1.status"
  if [ -f "$f" ]; then wc -l < "$f" | tr -d ' '; else printf '0\n'; fi
}

seen_lines() { # <id> — count already surfaced to the EM
  local f="$EM_STATE/.watch.seen.$1"
  if [ -f "$f" ]; then cat "$f"; else printf '0\n'; fi
}

# fire <reason line…> — reset the heartbeat cadence (non-heartbeat wakes) and
# exit with the reason.
fire() {
  printf '0\n' > "$EM_STATE/.watch.streak"
  printf '%s\n' "$(($(date +%s) + HEARTBEAT))" > "$EM_STATE/.watch.next-beat"
  printf '%s\n' "$*"
  exit 0
}

heartbeat_interval() { # <streak> — base * 2^streak, capped
  local streak="$1" interval
  if [ "$streak" -gt 16 ]; then
    printf '%s\n' "$HEARTBEAT_MAX"
    return
  fi
  interval=$((HEARTBEAT << streak))
  if [ "$interval" -gt "$HEARTBEAT_MAX" ]; then interval="$HEARTBEAT_MAX"; fi
  printf '%s\n' "$interval"
}

main() {
  case "${1:-}" in -h | --help) usage; exit 0 ;; esac
  mkdir -p "$EM_STATE"

  local now ids id
  while :; do
    touch "$BEACON"
    now="$(date +%s)"
    ids="$(in_flight_ids)"
    if [ -z "$ids" ]; then
      printf 'idle\n'
      exit 0
    fi

    # 1. Due per-task checks (before signals).
    for id in $ids; do
      local check="$EM_STATE/$id.check.sh" stamp last out
      [ -f "$check" ] || continue
      stamp="$EM_STATE/.watch.check.$id"
      last="$( [ -f "$stamp" ] && cat "$stamp" || printf '0' )"
      [ $((now - last)) -ge "$CHECK_INTERVAL" ] || continue
      printf '%s\n' "$now" > "$stamp"
      out="$(run_bounded "$CHECK_TIMEOUT" bash "$check" 2>/dev/null || true)"
      if [ -n "$out" ]; then
        fire "check $id: ${out%%$'\n'*}"
      fi
    done

    # 2. Signals: new status lines, coalesced within the grace window.
    local changed=""
    for id in $ids; do
      if [ "$(status_lines "$id")" -gt "$(seen_lines "$id")" ]; then
        changed="$changed $id"
      fi
    done
    if [ -n "$changed" ]; then
      sleep "$SIGNAL_GRACE"
      changed=""
      for id in $ids; do
        local lines
        lines="$(status_lines "$id")"
        if [ "$lines" -gt "$(seen_lines "$id")" ]; then
          changed="$changed $id"
          printf '%s\n' "$lines" > "$EM_STATE/.watch.seen.$id"
        fi
      done
      touch "$BEACON"
      # shellcheck disable=SC2086  # word-splitting the id list is intended
      fire signal${changed}
    fi

    # 3. Stale: a turn ended and no status line came with it.
    for id in $ids; do
      local te="$EM_STATE/$id.turn-ended" marker te_m st_m marker_m
      [ -f "$te" ] || continue
      marker="$EM_STATE/.watch.stale.$id"
      te_m="$(mtime "$te")"
      marker_m="$( [ -f "$marker" ] && mtime "$marker" || printf '0' )"
      st_m="$( [ -f "$EM_STATE/$id.status" ] && mtime "$EM_STATE/$id.status" || printf '0' )"
      if [ "$te_m" -gt "$marker_m" ] &&
        [ $((now - te_m)) -ge "$SIGNAL_GRACE" ] &&
        [ $((te_m - st_m)) -gt "$SIGNAL_GRACE" ]; then
        touch -r "$te" "$marker"
        fire "stale $id"
      fi
    done

    # 4. Heartbeat with exponential backoff.
    local next streak
    next="$( [ -f "$EM_STATE/.watch.next-beat" ] && cat "$EM_STATE/.watch.next-beat" || printf '0' )"
    streak="$( [ -f "$EM_STATE/.watch.streak" ] && cat "$EM_STATE/.watch.streak" || printf '0' )"
    if [ "$next" -eq 0 ]; then
      printf '%s\n' "$((now + $(heartbeat_interval "$streak")))" > "$EM_STATE/.watch.next-beat"
    elif [ "$now" -ge "$next" ]; then
      streak=$((streak + 1))
      printf '%s\n' "$streak" > "$EM_STATE/.watch.streak"
      printf '%s\n' "$((now + $(heartbeat_interval "$streak")))" > "$EM_STATE/.watch.next-beat"
      printf 'heartbeat\n'
      exit 0
    fi

    sleep "$POLL"
  done
}

main "$@"
