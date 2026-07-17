#!/usr/bin/env bash
# em-log-event.sh — append one event to a task's append-only audit log at
# state/tasks/<project>/<id>/events.jsonl. The only sanctioned writer.
#
# Usage:
#   em-log-event.sh <id> <event-type> [--actor em|watcher|ic|director|script]
#                   [--data '<json>'] [--project <name>] [--notify]
#
# One JSON object per line, built with jq (never hand-rolled): ts (ISO-8601
# UTC), ts_epoch, task, project, event, actor, data, and notify:true on
# Director-attention-worthy events (--notify, or automatic for
# budget_exceeded/task_paused/task_killed/stall_detected/merged/
# teardown_refused). Consumers must tolerate unknown extra keys.
#
# The project is read from the task's meta; --project covers events that
# fire before the meta exists (task_created, brief_written). Oversized
# --data payloads are truncated with a {"truncated":true} marker so a line
# never exceeds 4096 bytes (one atomic O_APPEND write; flock is used as
# belt-and-braces where the binary exists). Invalid --data JSON is wrapped
# as {"_invalid_json":true,"_raw":…} rather than lost.
#
# After a successful append, config/hooks/on-event (if executable) gets the
# event JSON on stdin — backgrounded, fire-and-forget, failures invisible.
#
# Logging is best-effort by design: runtime failures (missing jq, unwritable
# state/, hook errors) warn on stderr and still exit 0 so the operation
# being logged always proceeds. Exit 2 = calling error (bad usage, unknown
# event type). Exit 3 = safety refusal (id/project that would write outside
# state/tasks/). Scripts call this via emit_event (bin/lib/common.sh).
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

MAX_LINE_BYTES=4095 # + trailing newline = 4096, within PIPE_BUF

valid_event_type() {
  case "$1" in
    task_created | brief_written | worktree_created | ic_spawned | \
      ic_signal | stall_detected | heartbeat | gate_started | gate_passed | \
      gate_failed | rebrief | pr_opened | merge_requested | merge_approved | \
      merged | report_delivered | task_promoted | budget_warning | \
      budget_exceeded | budget_extended | task_paused | task_resumed | \
      task_killed | teardown_refused | teardown_completed | task_closed)
      return 0
      ;;
    *) return 1 ;;
  esac
}

auto_notify() {
  case "$1" in
    budget_exceeded | task_paused | task_killed | stall_detected | merged | \
      teardown_refused)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# Kebab-slug check for path components (same shape require_id enforces, but
# refusing instead of dying: a bad component here is a path-escape risk).
refuse_bad_slug() { # <value> <label>
  case "$1" in
    '' | -* | *- | *[!a-z0-9-]*)
      die_refuse "$2 '$1' is not a kebab slug — refusing to build a path outside state/tasks/"
      ;;
  esac
}

# append_line <file> <line> — one O_APPEND write; opportunistic flock.
append_line() {
  local file="$1" line="$2"
  exec 9>>"$file" || return 1
  if command -v flock >/dev/null 2>&1; then flock -x 9 || true; fi
  printf '%s\n' "$line" >&9 || {
    exec 9>&-
    return 1
  }
  exec 9>&-
}

main() {
  local id="" event="" actor="script" data="" project="" notify=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --actor | --data | --project)
        [ $# -ge 2 ] || {
          printf 'error: %s needs a value\n' "$1" >&2
          exit 2
        }
        case "$1" in
          --actor) actor="$2" ;;
          --data) data="$2" ;;
          --project) project="$2" ;;
        esac
        shift
        ;;
      --notify) notify=1 ;;
      -*)
        printf "error: unknown option '%s'\n" "$1" >&2
        exit 2
        ;;
      *)
        if [ -z "$id" ]; then
          id="$1"
        elif [ -z "$event" ]; then
          event="$1"
        else
          usage >&2
          exit 2
        fi
        ;;
    esac
    shift
  done
  [ -n "$id" ] && [ -n "$event" ] || {
    usage >&2
    exit 2
  }
  valid_event_type "$event" || {
    printf "error: unknown event type '%s' — the enum is frozen; see em-log-event.sh --help\n" "$event" >&2
    exit 2
  }
  case "$actor" in
    em | watcher | ic | director | script) ;;
    *)
      printf "error: unknown actor '%s' (em|watcher|ic|director|script)\n" "$actor" >&2
      exit 2
      ;;
  esac
  refuse_bad_slug "$id" "task id"

  if [ -z "$project" ]; then
    project="$(meta_get "$id" project 2>/dev/null || true)"
  fi
  if [ -z "$project" ]; then
    warn "cannot resolve project for task $id (no meta, no --project) — event $event dropped"
    exit 0
  fi
  refuse_bad_slug "$project" "project"

  if ! command -v jq >/dev/null 2>&1; then
    warn "jq not installed — event $event for $id not logged (see em-bootstrap.sh)"
    exit 0
  fi

  # Everything below is best-effort: warn and exit 0 on failure.
  local ts ts_epoch
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ts_epoch="$(date +%s)"

  [ -n "$data" ] || data='{}'
  if ! printf '%s' "$data" | jq -e . >/dev/null 2>&1; then
    warn "--data is not valid JSON — wrapping it raw"
    data="$(jq -cn --arg raw "$data" '{_invalid_json: true, _raw: $raw}')"
  fi

  build_line() { # <data-json>
    jq -cn \
      --arg ts "$ts" --argjson ts_epoch "$ts_epoch" \
      --arg task "$id" --arg project "$project" \
      --arg event "$event" --arg actor "$actor" \
      --argjson data "$1" --argjson notify "$notify_json" \
      '{ts: $ts, ts_epoch: $ts_epoch, task: $task, project: $project,
        event: $event, actor: $actor, data: $data}
       + (if $notify then {notify: true} else {} end)'
  }

  local notify_json=false
  if [ "$notify" -eq 1 ] || auto_notify "$event"; then notify_json=true; fi

  local line cap
  if ! line="$(build_line "$data")"; then
    warn "failed to build event JSON — event $event for $id not logged"
    exit 0
  fi
  # Cap the line at MAX_LINE_BYTES (LOG-10): shrink data until it fits.
  # Escaping can inflate the raw payload, so step down and finally drop it.
  for cap in 3500 1500 0; do
    [ "$(printf '%s' "$line" | wc -c)" -gt "$MAX_LINE_BYTES" ] || break
    if [ "$cap" -eq 0 ]; then
      data='{"truncated": true}'
    else
      data="$(printf '%s' "$data" | head -c "$cap" |
        jq -cnR --slurp '{truncated: true, raw: input}' 2>/dev/null ||
        printf '{"truncated": true}')"
    fi
    if ! line="$(build_line "$data")"; then
      warn "failed to build event JSON — event $event for $id not logged"
      exit 0
    fi
  done

  local dir file
  dir="$(task_dir "$id" "$project")"
  file="$dir/events.jsonl"
  if ! mkdir -p "$dir" 2>/dev/null || ! append_line "$file" "$line"; then
    warn "failed to append event $event to $file"
    exit 0
  fi

  local hook="$EM_CONFIG/hooks/on-event"
  if [ -x "$hook" ]; then
    printf '%s\n' "$line" | "$hook" >/dev/null 2>&1 &
  fi
  exit 0
}

main "$@"
