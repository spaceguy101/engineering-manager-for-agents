#!/usr/bin/env bash
# em-spawn.sh — hire an IC: tmux window + fresh worktree + turn-end hook +
# meta record, then launch the agent with its brief.
#
# Usage:
#   em-spawn.sh <id> <repo> [<harness>] [--research]
#              [--budget <spec>] [--on-exceed pause|kill|warn-only]
#
# Requires a filled brief at data/<id>/brief.md (no {TASK} placeholder left).
# Creates the window in the current tmux session, or in a dedicated 'em'
# session when running outside tmux. --research records kind=research (the
# worktree is scratch; teardown requires the report instead).
#
# Spawn is the budget guarantee point (BUD-4): --budget here overrides a
# brief-time declaration (and appends a Budget note to the brief); without
# either, the task gets an unlimited budget.json and a one-time
# budget_warning(unmetered) event. --on-exceed picks the hard-threshold
# action (default pause).
#
# Harness resolves via em-harness.sh (request > config/crew-harness >
# detected). claude ships verified; any other harness must be listed in
# config/verified-harnesses (one name per line, added after a supervised
# trial task — see AGENTS.md). Never dispatch on an unverified adapter.
# The turn-end hook is claude-only; other harnesses rely on stale/heartbeat
# supervision.
#
# The two writes into the worktree/clone (the Stop-hook settings file and one
# .git/info/exclude pattern) are sanctioned spawn provisioning (ADR-0003) —
# harness mechanics, never project content.
#
# The launch command is recorded in the task's meta (launch=) so
# em-relaunch.sh can replay it for a stuck IC. After launching, spawn looks
# at the pane once (EM_SPAWN_VERIFY seconds later, default 5; 0 disables)
# and prints a hint if a trust or bypass-permissions dialog is showing.
#
# Test seam: EM_LAUNCH_OVERRIDE replaces the harness launch command (the brief
# prompt is still appended as the final argument). It doubles as the
# raw-launch escape hatch for harness verification trials. Not
# Director-facing.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=bin/lib/budget.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/budget.sh"
"$EM_BIN/em-guard.sh"

# install_turn_end_hook <worktree> <id> — ADR-0003 spawn provisioning: a Stop
# hook that touches state/<id>.turn-ended, plus an idempotent exclude pattern
# in the clone's shared .git/info/exclude so the hook file can never leak
# into a commit.
install_turn_end_hook() {
  local wt="$1" id="$2" common exclude
  mkdir -p "$wt/.claude"
  cat > "$wt/.claude/settings.local.json" <<EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          { "type": "command", "command": "touch '$EM_STATE/$id.turn-ended'" }
        ]
      }
    ]
  }
}
EOF
  common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir)"
  exclude="$common/info/exclude"
  mkdir -p "$common/info"
  if ! grep -qxF '.claude/settings.local.json' "$exclude" 2>/dev/null; then
    printf '.claude/settings.local.json\n' >> "$exclude"
  fi
}

# harness_cmd <harness> — the launch command for a verified adapter. The
# non-claude commands are recorded from adapter research and are confirmed
# empirically during each harness's verification trial.
harness_cmd() {
  case "$1" in
    claude) printf 'claude --dangerously-skip-permissions\n' ;;
    codex) printf 'codex --dangerously-bypass-approvals-and-sandbox\n' ;;
    opencode) printf 'opencode --prompt\n' ;;
    pi) printf 'pi\n' ;;
    cursor) printf '%s --force\n' "$(harness_binary cursor)" ;;
    *) return 1 ;;
  esac
}

harness_verified() {
  [ "$1" = "claude" ] && return 0
  [ -f "$EM_CONFIG/verified-harnesses" ] &&
    grep -qx "$1" "$EM_CONFIG/verified-harnesses"
}

# verify_launch <id> <target> — EM_SPAWN_VERIFY seconds after launch
# (default 5; 0 disables), look at the pane once and print a hint: a trust
# or bypass-permissions dialog waiting to be accepted, or a reminder to peek.
verify_launch() {
  local id="$1" target="$2" secs="${EM_SPAWN_VERIFY:-5}" pane
  case "$secs" in *[!0-9]* | '') secs=5 ;; esac
  if [ "$secs" -eq 0 ]; then
    log "peek within ~20s (em-peek.sh $id) to confirm the IC is processing and accept any trust dialog"
    return 0
  fi
  sleep "$secs"
  pane="$(tmux_cmd capture-pane -p -t "$target" 2>/dev/null || true)"
  if printf '%s\n' "$pane" | grep -qiE 'trust the files|workspace trust'; then
    log "spawn-check: trust dialog showing — accept it: em-send.sh $id --key Enter"
  elif printf '%s\n' "$pane" | grep -qiE 'bypass ?permissions'; then
    log "spawn-check: bypass-permissions dialog showing (defaults to \"No, exit\") — accept it: em-send.sh $id --key Down, then em-send.sh $id --key Enter"
  else
    log "spawn-check: no dialog detected ${secs}s in — confirm progress with em-peek.sh $id"
  fi
}

main() {
  local id="" repo="" harness="" kind=build budget_spec="" on_exceed=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --research) kind=research ;;
      --budget)
        [ $# -ge 2 ] || die "--budget needs a value (e.g. wall=45m,tokens=1.5M)"
        shift
        budget_spec="$1"
        ;;
      --on-exceed)
        [ $# -ge 2 ] || die "--on-exceed needs a value (pause|kill|warn-only)"
        shift
        on_exceed="$1"
        case "$on_exceed" in
          pause | kill | warn-only) ;;
          *) die "unknown --on-exceed '$on_exceed' (pause|kill|warn-only)" ;;
        esac
        ;;
      -*) die "unknown option '$1'" ;;
      *)
        if [ -z "$id" ]; then id="$1"
        elif [ -z "$repo" ]; then repo="$1"
        elif [ -z "$harness" ]; then harness="$1"
        else usage >&2; exit 1
        fi
        ;;
    esac
    shift
  done
  [ -n "$id" ] && [ -n "$repo" ] || { usage >&2; exit 1; }
  require_id "$id"
  repo="${repo#projects/}"

  harness="$("$EM_BIN/em-harness.sh" resolve "$harness")"
  harness_cmd "$harness" >/dev/null ||
    die "unknown harness '$harness' (claude|codex|opencode|pi|cursor)"
  if [ -z "${EM_LAUNCH_OVERRIDE:-}" ] && ! harness_verified "$harness"; then
    die "harness '$harness' is unverified on this machine — run a supervised trial task first (AGENTS.md: harness verification), then add it to config/verified-harnesses"
  fi

  local brief="$EM_DATA/$id/brief.md"
  [ -f "$brief" ] || die "no brief at data/$id/brief.md — run em-brief.sh first"
  ! grep -qF '{TASK}' "$brief" ||
    die "brief still has the {TASK} placeholder — fill it in before spawning"

  [ ! -f "$(meta_path "$id")" ] || die "task $id already has a meta record"
  ! find_window "$id" >/dev/null || die "window $(window_name "$id") already exists"

  local mode auto
  if ! mode="$("$EM_BIN/em-project-mode.sh" "$repo" mode 2>/dev/null)"; then
    # Research worktrees are scratch — no delivery mode to resolve. Build
    # tasks never guess one.
    [ "$kind" = "research" ] ||
      die "project '$repo' is not in the registry — register it first (em-project-add.sh); delivery modes are Director-confirmed, never guessed"
    mode="-"
  fi
  auto="$("$EM_BIN/em-project-mode.sh" "$repo" auto 2>/dev/null || printf '0')"

  local wt
  wt="$("$EM_BIN/em-worktree.sh" add "$id" "$repo")"
  emit_event "$id" worktree_created --actor em --project "$repo" \
    --data "$(jq -cn --arg path "$wt" '{path: $path}' 2>/dev/null || true)"

  # Turn-end hook mechanics are claude-specific; other harnesses rely on
  # stale/heartbeat supervision.
  if [ "$harness" = "claude" ]; then
    install_turn_end_hook "$wt" "$id"
  fi

  local win prompt launch
  win="$(window_name "$id")"
  prompt="You are an IC agent. Read your brief at $brief and execute it. Work only in this directory."
  launch="${EM_LAUNCH_OVERRIDE:-$(harness_cmd "$harness")} \"$prompt\""

  mkdir -p "$EM_STATE"
  : > "$EM_STATE/$id.status"
  cat > "$(meta_path "$id")" <<EOF
window=$win
worktree=$wt
project=$repo
harness=$harness
kind=$kind
mode=$mode
auto=$auto
pr=
launch=$launch
spawned=$(date +%Y-%m-%dT%H:%M:%S)
EOF

  # Budget guarantee point (BUD-4/BUD-2): task override → brief-time
  # declaration → project default → global default → unlimited + notice.
  local bj oe_effective="$on_exceed"
  bj="$(budget_path "$id" "$repo")"
  if [ -z "$oe_effective" ]; then
    oe_effective="$(budget_conf_get on_exceed 2>/dev/null || printf 'pause')"
    case "$oe_effective" in pause | kill | warn-only) ;; *) oe_effective=pause ;; esac
  fi
  if [ -n "$budget_spec" ]; then
    local parsed
    parsed="$(declare_budget "$id" "$repo" "$budget_spec" task "$oe_effective")" ||
      die "invalid --budget '$budget_spec' (want e.g. wall=45m,tokens=1.5M,cost=2.00)"
    if ! grep -q '^## Budget' "$brief"; then
      printf '\n## Budget (declared at dispatch)\n\nThis task has a resource envelope: %s.\nPrefer the smallest correct change that meets the brief. At 80%% of any limit\nyou will be warned in this window; at 100%% enforcement kicks in.\n' \
        "$(budget_phrase "$parsed")" >> "$brief"
    fi
  elif [ ! -f "$bj" ]; then
    local def
    if def="$(resolve_default_budget_spec "$repo")"; then
      declare_budget "$id" "$repo" "${def% *}" "${def##* }" "$oe_effective" >/dev/null ||
        warn "default budget '${def% *}' is malformed — fix data/projects/$repo/budget or config/budgets.conf; task runs unmetered"
    fi
    if [ ! -f "$bj" ]; then
      write_budget_json "$id" "$repo" "" "" "" none "$oe_effective"
      emit_event "$id" budget_warning --actor em \
        --data '{"reason": "unmetered", "note": "task dispatched without a budget"}'
    fi
  elif [ -n "$on_exceed" ]; then
    budget_update "$id" "$repo" ".on_exceed = \"$on_exceed\"" || true
  fi

  create_task_window "$win" "$wt"
  local target
  target="$(find_window "$id")" || die "window $win vanished after creation"
  tmux_cmd send-keys -t "$target" -l -- "$launch"
  tmux_cmd send-keys -t "$target" Enter

  log "spawned $id in window $win"
  emit_event "$id" ic_spawned --actor em \
    --data "$(jq -cn --arg h "$harness" --arg w "$win" \
      --argjson b "$(jq -c '.limits' "$bj" 2>/dev/null || printf 'null')" \
      '{harness: $h, window: $w, budget: $b}' 2>/dev/null || true)"
  verify_launch "$id" "$target"
  printf '%s\n' "$wt"
}

main "$@"
