#!/usr/bin/env bash
# em-budget.sh — inspect and adjust a task's resource budget.
#
# Usage:
#   em-budget.sh show <id|project>          limits, live spend, %, state
#   em-budget.sh extend <id> <spec> [--no-resume]
#                                           raise limits by +deltas, e.g.
#                                           wall=+30m — resumes a paused
#                                           task unless --no-resume
#   em-budget.sh set <id> <spec> [--on-exceed pause|kill|warn-only]
#                                           re-declare absolute limits
#   em-budget.sh pause <id>                 pause the IC now (Director call)
#   em-budget.sh resume <id>                resume a paused IC
#
# show is read-only and works on closed tasks (the audit log and budget
# snapshot are retained after teardown); given a project name it lists every
# in-flight task of that project instead. Spend is recomputed live from the
# event log, so it is correct even when the watcher has not run — and an EM
# restart never resets the clock (BUD-9).
# extend/set/pause/resume act on in-flight tasks and log budget_extended/
# task_paused/task_resumed events with actor=director. After a plain resume
# (no extend) the next watcher pass will re-pause an over-budget task.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=bin/lib/budget.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/budget.sh"

# resolve_project <id> — meta first, then the retained state/tasks/ glob.
resolve_project() {
  local id="$1" project hits=() d
  if project="$(meta_get "$id" project 2>/dev/null)" && [ -n "$project" ]; then
    printf '%s\n' "$project"
    return 0
  fi
  for d in "$EM_STATE"/tasks/*/"$id"; do
    [ -d "$d" ] || continue
    d="${d%/*}"
    hits+=("${d##*/}")
  done
  case "${#hits[@]}" in
    1) printf '%s\n' "${hits[0]}" ;;
    *) return 1 ;;
  esac
}

pct_of() { # <used> <limit>
  printf '%s\n' $(($1 * 100 / $2))
}

show_task() {
  local id="$1" project="$2" bj
  bj="$(budget_path "$id" "$project")"
  if [ ! -f "$bj" ]; then
    printf 'task %s (%s): no budget declared — unmetered\n' "$id" "$project"
    return 0
  fi
  local source on_exceed state limit used harness
  source="$(jq -r '.source // "?"' "$bj")"
  on_exceed="$(jq -r '.on_exceed // "pause"' "$bj")"
  state="$(jq -r '.state // "ok"' "$bj")"
  limit="$(jq -r '.limits.wall_seconds // empty' "$bj")"
  harness="$(meta_get "$id" harness 2>/dev/null || printf '?')"
  printf 'task %s (%s) — source: %s, on-exceed: %s, state: %s\n' \
    "$id" "$project" "$source" "$on_exceed" "$state"
  if [ -n "$limit" ]; then
    used="$(budget_elapsed_seconds "$id" "$project")"
    printf '  wall:   %s / %s (%s%%)\n' \
      "$(fmt_duration "$used")" "$(fmt_duration "$limit")" "$(pct_of "$used" "$limit")"
  else
    printf '  wall:   unlimited (used %s)\n' \
      "$(fmt_duration "$(budget_elapsed_seconds "$id" "$project")")"
  fi
  if jq -e '.unmeterable | index("tokens")' "$bj" >/dev/null 2>&1; then
    printf '  tokens: unmeterable (no meter adapter for %s)\n' "$harness"
  else
    local tl tu
    tl="$(jq -r '.limits.tokens // empty' "$bj")"
    tu="$(jq -r '.spend.tokens // 0' "$bj")"
    if [ -n "$tl" ]; then
      printf '  tokens: %s / %s (%s%%)\n' \
        "$(fmt_tokens "$tu")" "$(fmt_tokens "$tl")" "$(pct_of "$tu" "$tl")"
    else
      printf '  tokens: unlimited (used %s)\n' "$(fmt_tokens "$tu")"
    fi
  fi
}

cmd_show() {
  local arg="$1" project id any=0
  # A resolvable task id wins; otherwise treat the argument as a project
  # name and list its in-flight tasks.
  if project="$(resolve_project "$arg" 2>/dev/null)"; then
    show_task "$arg" "$project"
    return 0
  fi
  for id in $(in_flight_ids); do
    if [ "$(meta_get "$id" project 2>/dev/null || true)" = "$arg" ]; then
      any=1
      show_task "$id" "$arg"
    fi
  done
  [ "$any" -eq 1 ] || die "'$arg' is neither a known task nor a project with in-flight tasks"
}

# apply_spec <id> <project> <spec> <mode:set|extend> — update limits.
apply_spec() {
  local id="$1" project="$2" spec="$3" mode="$4" parsed key val old new dim
  parsed="$(parse_budget_spec "${spec//=+/=}")" ||
    die "invalid budget spec '$spec' (want e.g. wall=45m,tokens=1.5M,cost=2.00)"
  [ -f "$(budget_path "$id" "$project")" ] ||
    die "task $id has no budget snapshot — dispatch wrote none? (spawn guarantees one)"
  while IFS='=' read -r key val; do
    [ -n "$key" ] || continue
    case "$key" in
      wall_seconds) dim=wall ;;
      tokens) dim=tokens ;;
      cost_usd) dim=cost ;;
    esac
    old="$(jq -r ".limits.$key // 0" "$(budget_path "$id" "$project")")"
    if [ "$mode" = "extend" ]; then
      new="$(awk -v a="$old" -v b="$val" 'BEGIN {
        s = a + b
        if (s == int(s)) printf "%d", s; else printf "%.2f", s
      }')"
    else
      new="$val"
    fi
    budget_update "$id" "$project" \
      ".limits.$key = \$n | .warned.$dim = false | .state = \"ok\"" \
      --argjson n "$new" ||
      die "failed to update budget.json for $id"
    emit_event "$id" budget_extended --actor director \
      --data "$(jq -cn --arg d "$dim" --argjson old "${old:-0}" --argjson new "$new" \
        '{dimension: $d, old: $old, new: $new}' 2>/dev/null || true)"
  done <<< "$parsed"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    -h | --help | '')
      usage
      exit 0
      ;;
  esac
  shift

  case "$cmd" in
    show)
      [ $# -ge 1 ] || {
        usage >&2
        exit 1
      }
      cmd_show "$1"
      ;;
    extend | set)
      "$EM_BIN/em-guard.sh"
      local id="" spec="" no_resume=0 on_exceed=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --no-resume) no_resume=1 ;;
          --on-exceed)
            [ $# -ge 2 ] || die "--on-exceed needs a value"
            shift
            on_exceed="$1"
            case "$on_exceed" in
              pause | kill | warn-only) ;;
              *) die "unknown --on-exceed '$on_exceed' (pause|kill|warn-only)" ;;
            esac
            ;;
          -*) die "unknown option '$1'" ;;
          *)
            if [ -z "$id" ]; then id="$1"; else spec="$1"; fi
            ;;
        esac
        shift
      done
      [ -n "$id" ] && [ -n "$spec" ] || {
        usage >&2
        exit 1
      }
      require_id "$id"
      local project was_paused
      project="$(resolve_project "$id")" || die "no task $id (no meta, no retained budget)"
      was_paused="$(jq -r '.state // "ok"' "$(budget_path "$id" "$project")" 2>/dev/null || printf 'ok')"
      apply_spec "$id" "$project" "$spec" "$cmd"
      [ -z "$on_exceed" ] || budget_update "$id" "$project" ".on_exceed = \"$on_exceed\"" || true
      log "budget ${cmd}ed for $id: $spec"
      if [ "$was_paused" = "paused" ] && [ "$no_resume" -eq 0 ]; then
        if resume_task "$id"; then
          emit_event "$id" task_resumed --actor director
          log "resumed $id against the new limit"
        else
          warn "could not resume $id (window gone?) — relaunch it if needed"
        fi
      fi
      ;;
    pause | resume)
      "$EM_BIN/em-guard.sh"
      local id="${1:-}"
      [ -n "$id" ] || {
        usage >&2
        exit 1
      }
      require_id "$id"
      local project
      project="$(resolve_project "$id")" || die "no task $id"
      if [ "$cmd" = "pause" ]; then
        pause_task "$id" || die "pause failed for $id"
        emit_event "$id" task_paused --actor director
        budget_update "$id" "$project" '.state = "paused"' 2>/dev/null || true
      else
        resume_task "$id" || die "resume failed for $id"
        emit_event "$id" task_resumed --actor director
        budget_update "$id" "$project" '.state = "ok"' 2>/dev/null || true
        warn "resumed without extending — the next watcher pass re-pauses an over-budget task (em-budget.sh extend raises the limit)"
      fi
      ;;
    *)
      die "unknown subcommand '$cmd' (show|extend|set|pause|resume)"
      ;;
  esac
}

main "$@"
