#!/usr/bin/env bash
# em-timeline.sh — human-readable timeline of a task's audit log
# (state/tasks/<project>/<id>/events.jsonl). Read-only; safe for the
# Director to run at any time, on in-flight and closed tasks alike.
#
# Usage:
#   em-timeline.sh <id> [--project <name>] [--json] [--since <iso|epoch>]
#                  [--follow] [--errors-only]
#
# Default output: one line per event — local HH:MM:SS, event type, actor,
# and a plain-text summary of the event's data (rendered as text only,
# never interpreted). Flags:
#   --project      disambiguate when the same task id exists in several
#                  projects (needed for closed tasks whose meta is gone)
#   --json         raw JSONL passthrough (filters still apply)
#   --since <t>    only events at/after <t>: an ISO-8601 UTC prefix
#                  (e.g. 2026-07-16T14:00) or an epoch-seconds integer
#   --follow       keep the file open and print events as they arrive
#   --errors-only  only gate_failed, stall_detected, budget_warning,
#                  budget_exceeded, task_paused, task_killed,
#                  teardown_refused
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

# resolve_log <id> <project> — print the task's events.jsonl path. Meta wins;
# otherwise search state/tasks/*/<id>/ (closed tasks), demanding --project
# when the id is ambiguous across projects.
resolve_log() {
  local id="$1" project="$2" hits=() f
  if [ -z "$project" ]; then
    project="$(meta_get "$id" project 2>/dev/null || true)"
  fi
  if [ -n "$project" ]; then
    printf '%s/events.jsonl\n' "$(task_dir "$id" "$project")"
    return 0
  fi
  for f in "$EM_STATE"/tasks/*/"$id"/events.jsonl; do
    [ -f "$f" ] && hits+=("$f")
  done
  case "${#hits[@]}" in
    0) die "no event log for task $id (state/tasks/*/$id/events.jsonl)" ;;
    1) printf '%s\n' "${hits[0]}" ;;
    *) die "task id $id exists in several projects — pass --project <name>" ;;
  esac
}

main() {
  local id="" project="" json=0 since="" follow=0 errors_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      --project | --since)
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --project) project="$2" ;;
          --since) since="$2" ;;
        esac
        shift
        ;;
      --json) json=1 ;;
      --follow) follow=1 ;;
      --errors-only) errors_only=1 ;;
      -*) die "unknown option '$1'" ;;
      *)
        [ -z "$id" ] || {
          usage >&2
          exit 1
        }
        id="$1"
        ;;
    esac
    shift
  done
  [ -n "$id" ] || {
    usage >&2
    exit 1
  }
  require_id "$id"
  command -v jq >/dev/null 2>&1 || die "jq is required (see em-bootstrap.sh)"

  local file
  file="$(resolve_log "$id" "$project")"
  [ -f "$file" ] || die "no event log at $file"

  local since_epoch=null since_iso=""
  if [ -n "$since" ]; then
    case "$since" in
      *[!0-9]*) since_iso="$since" ;;
      *) since_epoch="$since" ;;
    esac
  fi

  # Local-time display needs jq >= 1.6; older jq falls back to the UTC ts.
  local localtime=false
  if jq -n '0 | strflocaltime("%H")' >/dev/null 2>&1; then localtime=true; fi

  # Malformed lines are skipped (fromjson?); data is rendered as plain text
  # only — first line of each value, length-capped — never interpreted.
  # shellcheck disable=SC2016  # $vars below are jq variables, not shell
  local prog='
    def pad(n): . + " " * ([n - length, 1] | max);
    def dsum:
      (.data // {}) as $d |
      if ($d | type) != "object" then ($d | tojson)
      elif $d == {} then ""
      else
        $d | to_entries
           | map("\(.key)=\(.value | tostring | split("\n")[0] | .[0:80])")
           | join("  ")
      end;
    def tdisp:
      if $localtime and (.ts_epoch | type) == "number"
      then (.ts_epoch | strflocaltime("%H:%M:%S"))
      else (.ts // "?") end;
    fromjson? // empty
    | select($since_epoch == null or ((.ts_epoch // 0) >= $since_epoch))
    | select($since_iso == "" or ((.ts // "") >= $since_iso))
    | .event as $e
    | select(($errors_only | not) or
        (["gate_failed", "stall_detected", "budget_warning",
          "budget_exceeded", "task_paused", "task_killed",
          "teardown_refused"] | index($e)))
    | if $json then . else
        "\(tdisp)  \(.event | pad(18))\("(" + (.actor // "?") + ")" | pad(10))\(dsum)"
      end'

  local -a jq_args=(
    -cr --argjson since_epoch "$since_epoch" --arg since_iso "$since_iso"
    --argjson errors_only "$([ "$errors_only" -eq 1 ] && echo true || echo false)"
    --argjson json "$([ "$json" -eq 1 ] && echo true || echo false)"
    --argjson localtime "$localtime"
  )

  if [ "$follow" -eq 1 ]; then
    tail -n +1 -f "$file" | jq -R --unbuffered "${jq_args[@]}" "$prog"
  else
    jq -R "${jq_args[@]}" "$prog" < "$file"
  fi
}

main "$@"
