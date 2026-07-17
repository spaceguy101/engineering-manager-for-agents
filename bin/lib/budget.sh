#!/usr/bin/env bash
# budget.sh — shared budget helpers for the em-* toolbelt. Source after
# common.sh, don't execute.
#
# Exposes:
#   budget_path            state/tasks/<project>/<id>/budget.json
#   parse_budget_spec      "wall=45m,tokens=1.5M,cost=2.00" → key=value lines
#   write_budget_json      create/replace a task's budget.json (jq, tmp+mv)
#   budget_update          atomic read-modify-write with a jq filter
#   budget_elapsed_seconds wall-clock used: first ic_spawned event → now,
#                          minus task_paused/task_resumed intervals (the
#                          event log is the clock — restart-proof, BUD-9)
#   fmt_duration           seconds → 42s / 38m / 1h05m
#   fmt_tokens             count → 800k / 1.5M
#   budget_cell            status-column cell: 38m/45m, ! past the soft
#                          threshold, !! once enforcement latched; - unmetered
#   pause_task/resume_task adapter dispatch: bin/lib/pause/<harness>.sh,
#                          falling back to pause/default.sh (SIGSTOP/SIGCONT).
#                          Callers emit the task_paused/task_resumed events —
#                          the adapter only signals.
#   budget_pass            one watcher metering/enforcement pass for a task;
#                          prints the wake reason line when the hard
#                          threshold fires, nothing otherwise
#
# budget.json schema (current snapshot only — history lives in events.jsonl):
#   {"limits": {"wall_seconds": 2700, "tokens": null, "cost_usd": null},
#    "on_exceed": "pause", "soft_pct": 80, "source": "task",
#    "spend": {"wall_seconds": 0, "tokens": null, "cost_usd": null},
#    "state": "ok", "warned": {"wall": false, "tokens": false},
#    "unmeterable": ["tokens", "cost_usd"]}

budget_path() { # <id> <project>
  printf '%s/budget.json\n' "$(task_dir "$1" "$2")"
}

# budget_conf_get <key> — value from config/budgets.conf (key=value lines:
# budget=, soft_pct=, on_exceed=, grace_seconds=, usd_per_mtok_<harness>=).
budget_conf_get() {
  local f="$EM_CONFIG/budgets.conf" v
  [ -f "$f" ] || return 1
  v="$(awk -F= -v k="$1" '$1 == k { print $2; exit }' "$f" | tr -d '[:space:]')"
  [ -n "$v" ] || return 1
  printf '%s\n' "$v"
}

# resolve_default_budget_spec <project> — prints "<spec> <source>" from the
# project default (data/projects/<name>/budget, one spec line) or the
# global default (budget= in config/budgets.conf); fails when neither is
# set (BUD-2: task override wins upstream of this call).
resolve_default_budget_spec() {
  local f="$EM_DATA/projects/$1/budget" spec
  if [ -s "$f" ]; then
    spec="$(head -n 1 "$f" | tr -d '[:space:]')"
    if [ -n "$spec" ]; then
      printf '%s project\n' "$spec"
      return 0
    fi
  fi
  if spec="$(budget_conf_get budget)"; then
    printf '%s global\n' "$spec"
    return 0
  fi
  return 1
}

# parse_budget_spec <spec> — comma-separated dimension=value pairs. Units:
# wall: s/m/h (bare number = minutes); tokens: k/M (bare = tokens); cost:
# bare USD. Prints wall_seconds=/tokens=/cost_usd= lines; fails (1) with a
# message on stderr for anything malformed.
parse_budget_spec() {
  local spec="$1" pair key val n
  local IFS=','
  for pair in $spec; do
    key="${pair%%=*}"
    val="${pair#*=}"
    if [ -z "$val" ] || [ "$key" = "$pair" ]; then
      warn "budget: malformed pair '$pair' (want dimension=value)"
      return 1
    fi
    case "$key" in
      wall)
        case "$val" in
          *[!0-9smh.]* | '' | *.*)
            warn "budget: bad wall value '$val' (want e.g. 45m, 2h, 30s)"
            return 1
            ;;
        esac
        n="${val%[smh]}"
        case "$n" in '' | *[!0-9]*)
          warn "budget: bad wall value '$val'"
          return 1
          ;;
        esac
        case "$val" in
          *s) printf 'wall_seconds=%s\n' "$n" ;;
          *h) printf 'wall_seconds=%s\n' $((n * 3600)) ;;
          *) printf 'wall_seconds=%s\n' $((n * 60)) ;; # bare or m: minutes
        esac
        ;;
      tokens)
        case "$val" in
          *[!0-9.kM]* | '' | . | *.*.*)
            warn "budget: bad tokens value '$val' (want e.g. 800k, 1.5M)"
            return 1
            ;;
        esac
        n="${val%[kM]}"
        case "$val" in
          *k) n="$(awk -v n="$n" 'BEGIN { printf "%d", n * 1000 }')" ;;
          *M) n="$(awk -v n="$n" 'BEGIN { printf "%d", n * 1000000 }')" ;;
          *)
            case "$n" in *.*)
              warn "budget: bad tokens value '$val' (fractions need k/M)"
              return 1
              ;;
            esac
            ;;
        esac
        printf 'tokens=%s\n' "$n"
        ;;
      cost)
        case "$val" in
          '' | *[!0-9.]* | . | *.*.*)
            warn "budget: bad cost value '$val' (want USD, e.g. 2.00)"
            return 1
            ;;
        esac
        # Normalize so the value is always a valid JSON number ("2." → 2.00).
        printf 'cost_usd=%s\n' "$(awk -v n="$val" 'BEGIN { printf "%.2f", n + 0 }')"
        ;;
      *)
        warn "budget: unknown dimension '$key' (wall|tokens|cost)"
        return 1
        ;;
    esac
  done
}

# write_budget_json <id> <project> <wall_seconds|''> <tokens|''> <cost|''>
#                   <source> <on_exceed> — create/replace the snapshot.
write_budget_json() {
  local id="$1" project="$2" wall="$3" tokens="$4" cost="$5" source="$6" on_exceed="$7"
  local dir bj tmp soft
  soft="$(budget_conf_get soft_pct 2>/dev/null || printf '80')"
  case "$soft" in '' | *[!0-9]*) soft=80 ;; esac
  dir="$(task_dir "$id" "$project")"
  bj="$dir/budget.json"
  tmp="$bj.tmp.$$"
  mkdir -p "$dir"
  jq -n \
    --argjson wall "${wall:-null}" --argjson tokens "${tokens:-null}" \
    --argjson cost "${cost:-null}" --arg source "$source" --arg oe "$on_exceed" \
    --argjson soft "$soft" \
    '{limits: {wall_seconds: $wall, tokens: $tokens, cost_usd: $cost},
      on_exceed: $oe, soft_pct: $soft, source: $source,
      spend: {wall_seconds: 0, tokens: null, cost_usd: null},
      state: "ok", warned: {wall: false, tokens: false, cost: false},
      unmeterable: ["tokens", "cost_usd"]}' > "$tmp" && mv "$tmp" "$bj"
}

# declare_budget <id> <project> <spec> <source> <on_exceed> — parse a spec
# and write the budget snapshot; prints the parsed key=value lines for
# callers that render text. Fails (1) on a malformed spec.
declare_budget() {
  local id="$1" project="$2" spec="$3" source="$4" on_exceed="$5"
  local parsed wall tokens cost
  parsed="$(parse_budget_spec "$spec")" || return 1
  wall="$(awk -F= '$1 == "wall_seconds" { print $2 }' <<< "$parsed")"
  tokens="$(awk -F= '$1 == "tokens" { print $2 }' <<< "$parsed")"
  cost="$(awk -F= '$1 == "cost_usd" { print $2 }' <<< "$parsed")"
  write_budget_json "$id" "$project" "$wall" "$tokens" "$cost" "$source" "$on_exceed" || return 1
  printf '%s\n' "$parsed"
}

# budget_phrase <parsed-lines> — human phrase: "wall-clock 45m, tokens 1.5M,
# cost $2.00" (or "unlimited").
budget_phrase() {
  local parsed="$1" wall tokens cost out
  local parts=()
  wall="$(awk -F= '$1 == "wall_seconds" { print $2 }' <<< "$parsed")"
  tokens="$(awk -F= '$1 == "tokens" { print $2 }' <<< "$parsed")"
  cost="$(awk -F= '$1 == "cost_usd" { print $2 }' <<< "$parsed")"
  [ -z "$wall" ] || parts+=("wall-clock $(fmt_duration "$wall")")
  [ -z "$tokens" ] || parts+=("tokens $(fmt_tokens "$tokens")")
  [ -z "$cost" ] || parts+=("cost \$$cost")
  if [ ${#parts[@]} -eq 0 ]; then
    printf 'unlimited\n'
    return 0
  fi
  out="$(printf '%s, ' "${parts[@]}")"
  printf '%s\n' "${out%, }"
}

# budget_update <id> <project> <jq filter> [jq args…] — atomic RMW.
budget_update() {
  local id="$1" project="$2" filter="$3" bj tmp
  shift 3
  bj="$(budget_path "$id" "$project")"
  [ -f "$bj" ] || return 1
  tmp="$bj.tmp.$$"
  if jq "$@" "$filter" "$bj" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$bj"
  else
    rm -f "$tmp"
    return 1
  fi
}

# budget_elapsed_seconds <id> <project> [now] — wall-clock charged to the
# task. Anchored at the FIRST ic_spawned event (relaunches never reset the
# clock); task_paused/task_resumed pairs are excluded, an open pause counts
# up to now. Prints 0 when the task never spawned.
budget_elapsed_seconds() {
  local id="$1" project="$2" now="${3:-$(date +%s)}" f
  f="$(task_dir "$id" "$project")/events.jsonl"
  [ -f "$f" ] || {
    printf '0\n'
    return 0
  }
  jq -s --argjson now "$now" '
    ([.[] | select(.event == "ic_spawned")] | first | .ts_epoch) as $t0 |
    if $t0 == null then 0 else
      (reduce (.[] | select(.event == "task_paused" or .event == "task_resumed")) as $e
        ({paused: 0, since: null};
         if $e.event == "task_paused" and .since == null
         then .since = $e.ts_epoch
         elif $e.event == "task_resumed" and .since != null
         then {paused: (.paused + $e.ts_epoch - .since), since: null}
         else . end)) as $p |
      ($p.paused + (if $p.since == null then 0 else $now - $p.since end)) as $paused |
      ([$now - $t0 - $paused, 0] | max)
    end' "$f" 2>/dev/null || printf '0\n'
}

fmt_duration() { # <seconds>
  local s="$1"
  if [ "$s" -lt 60 ]; then
    printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%sm' $((s / 60))
  else
    printf '%dh%02dm' $((s / 3600)) $(((s % 3600) / 60))
  fi
}

fmt_tokens() { # <count>
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) { v = n / 1000000; s = "M" }
    else if (n >= 1000) { v = n / 1000; s = "k" }
    else { printf "%d", n; exit }
    if (v == int(v)) printf "%d%s", v, s
    else printf "%.1f%s", v, s
  }'
}

# budget_cell <id> <project> — space-free status cell: -, 38m/45m
# (plus ,1.2M/1.5M when tokens are metered), ! once soft-warned, !! once
# enforcement latched.
budget_cell() {
  local id="$1" project="$2" bj limit_w limit_t spend_t state warned cell=""
  bj="$(budget_path "$id" "$project")"
  if [ ! -f "$bj" ] || ! command -v jq >/dev/null 2>&1; then
    printf -- '-\n'
    return 0
  fi
  limit_w="$(jq -r '.limits.wall_seconds // empty' "$bj" 2>/dev/null)" || limit_w=""
  limit_t="$(jq -r '.limits.tokens // empty' "$bj" 2>/dev/null)" || limit_t=""
  if [ -n "$limit_w" ]; then
    cell="$(fmt_duration "$(budget_elapsed_seconds "$id" "$project")")/$(fmt_duration "$limit_w")"
  fi
  if [ -n "$limit_t" ]; then
    spend_t="$(jq -r '.spend.tokens // 0' "$bj" 2>/dev/null)" || spend_t=0
    cell="${cell:+$cell,}$(fmt_tokens "$spend_t")/$(fmt_tokens "$limit_t")"
  fi
  if [ -z "$cell" ]; then
    printf -- '-\n'
    return 0
  fi
  state="$(jq -r '.state // "ok"' "$bj" 2>/dev/null)" || state=ok
  warned="$(jq -r '[.warned[]] | any' "$bj" 2>/dev/null)" || warned=false
  if [ "$state" != "ok" ]; then
    cell="$cell!!"
  elif [ "$warned" = "true" ]; then
    cell="$cell!"
  fi
  printf '%s\n' "$cell"
}

# pause_task / resume_task <id> — signal via the harness's pause adapter
# (bin/lib/pause/<harness>.sh, else pause/default.sh). Event emission is the
# caller's job so the actor is recorded correctly (watcher vs director).
pause_adapter() { # <id>
  local h a
  h="$(meta_get "$1" harness 2>/dev/null || true)"
  a="$EM_BIN/lib/pause/${h:-default}.sh"
  [ -x "$a" ] || a="$EM_BIN/lib/pause/default.sh"
  printf '%s\n' "$a"
}
pause_task() { "$(pause_adapter "$1")" pause "$1"; }
resume_task() { "$(pause_adapter "$1")" resume "$1"; }

# budget_pass <id> <now> — one metering/enforcement pass, called by the
# watcher on every poll and rate-limited by state/.watch.budget.<id>
# (EM_BUDGET_INTERVAL, default 60s). Caches spend into budget.json, warns
# once at the soft threshold, enforces at the hard threshold per on_exceed,
# and prints the wake reason line:
#   budget <id>: wall exceeded — <paused|killed|warn-only|pause-failed> (<used>/<limit>)
# Prints nothing otherwise. Enforcement never touches the worktree.
budget_pass() {
  local id="$1" now="$2" project bj stamp last interval
  project="$(meta_get "$id" project 2>/dev/null)" || return 0
  [ -n "$project" ] || return 0
  bj="$(budget_path "$id" "$project")"
  [ -f "$bj" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  stamp="$EM_STATE/.watch.budget.$id"
  interval="${EM_BUDGET_INTERVAL:-60}"
  last="$([ -f "$stamp" ] && cat "$stamp" || printf '0')"
  [ $((now - last)) -ge "$interval" ] || return 0
  printf '%s\n' "$now" > "$stamp"

  local state limit
  state="$(jq -r '.state // "ok"' "$bj" 2>/dev/null)" || return 0
  [ "$state" = "ok" ] || return 0 # already latched: never re-fire
  limit="$(jq -r '.limits.wall_seconds // empty' "$bj" 2>/dev/null)" || return 0
  [ -n "$limit" ] || return 0 # unmetered

  local used
  used="$(budget_elapsed_seconds "$id" "$project" "$now")"
  # shellcheck disable=SC2016  # $u is a jq variable
  budget_update "$id" "$project" '.spend.wall_seconds = $u' --argjson u "$used" || true

  local fu fl data
  fu="$(fmt_duration "$used")"
  fl="$(fmt_duration "$limit")"
  if [ "$used" -ge "$limit" ]; then
    local action outcome
    action="$(jq -r '.on_exceed // "pause"' "$bj" 2>/dev/null)"
    data="$(jq -cn --argjson u "$used" --argjson l "$limit" --arg a "$action" \
      '{dimension: "wall", used_seconds: $u, limit_seconds: $l, action: $a}' 2>/dev/null)"
    emit_event "$id" budget_exceeded --actor watcher --data "$data"
    case "$action" in
      kill)
        local target
        if target="$(find_window "$id")"; then
          tmux_cmd kill-window -t "$target" 2>/dev/null || true
        fi
        emit_event "$id" task_killed --actor watcher --data "$data"
        budget_update "$id" "$project" '.state = "killed"' || true
        outcome=killed
        ;;
      warn-only)
        budget_update "$id" "$project" '.state = "exceeded"' || true
        outcome=warn-only
        ;;
      *)
        if pause_task "$id" 2>/dev/null; then
          emit_event "$id" task_paused --actor watcher --data "$data"
          budget_update "$id" "$project" '.state = "paused"' || true
          outcome=paused
        else
          budget_update "$id" "$project" '.state = "exceeded"' || true
          outcome=pause-failed
        fi
        ;;
    esac
    printf 'budget %s: wall exceeded — %s (%s/%s)\n' "$id" "$outcome" "$fu" "$fl"
    return 0
  fi

  local soft warned pct
  soft="$(jq -r '.soft_pct // 80' "$bj" 2>/dev/null)"
  warned="$(jq -r '.warned.wall // false' "$bj" 2>/dev/null)"
  pct=$((used * 100 / limit))
  if [ "$pct" -ge "$soft" ] && [ "$warned" != "true" ]; then
    data="$(jq -cn --argjson u "$used" --argjson l "$limit" --argjson p "$pct" \
      '{dimension: "wall", used_seconds: $u, limit_seconds: $l, pct: $p}' 2>/dev/null)"
    emit_event "$id" budget_warning --actor watcher --data "$data"
    budget_update "$id" "$project" '.warned.wall = true' || true
  fi
  return 0
}
