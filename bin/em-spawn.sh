#!/usr/bin/env bash
# em-spawn.sh — hire an IC: tmux window + fresh worktree + turn-end hook +
# meta record, then launch the agent with its brief.
#
# Usage:
#   em-spawn.sh <id> <repo> [<harness>] [--research]
#
# Requires a filled brief at data/<id>/brief.md (no {TASK} placeholder left).
# Creates the window in the current tmux session, or in a dedicated 'em'
# session when running outside tmux. --research records kind=research (the
# worktree is scratch; teardown requires the report instead).
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
# Test seam: EM_LAUNCH_OVERRIDE replaces the harness launch command (the brief
# prompt is still appended as the final argument). It doubles as the
# raw-launch escape hatch for harness verification trials. Not
# Director-facing.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

# Inside a usable tmux session? (The test socket seam never counts as inside:
# $TMUX points at the real server, not the isolated test one.)
inside_tmux() {
  [ -n "${TMUX:-}" ] && [ -z "${EM_TMUX_SOCKET:-}" ]
}

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
    *) return 1 ;;
  esac
}

harness_verified() {
  [ "$1" = "claude" ] && return 0
  [ -f "$EM_CONFIG/verified-harnesses" ] &&
    grep -qx "$1" "$EM_CONFIG/verified-harnesses"
}

main() {
  local id="" repo="" harness="" kind=build arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help) usage; exit 0 ;;
      --research) kind=research ;;
      -*) die "unknown option '$arg'" ;;
      *)
        if [ -z "$id" ]; then id="$arg"
        elif [ -z "$repo" ]; then repo="$arg"
        elif [ -z "$harness" ]; then harness="$arg"
        else usage >&2; exit 1
        fi
        ;;
    esac
  done
  [ -n "$id" ] && [ -n "$repo" ] || { usage >&2; exit 1; }
  require_id "$id"
  repo="${repo#projects/}"

  harness="$("$EM_BIN/em-harness.sh" resolve "$harness")"
  harness_cmd "$harness" >/dev/null ||
    die "unknown harness '$harness' (claude|codex|opencode|pi)"
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
    mode=direct-PR
  fi
  auto="$("$EM_BIN/em-project-mode.sh" "$repo" auto 2>/dev/null || printf '0')"

  local wt
  wt="$("$EM_BIN/em-worktree.sh" add "$id" "$repo")"

  # Turn-end hook mechanics are claude-specific; other harnesses rely on
  # stale/heartbeat supervision.
  if [ "$harness" = "claude" ]; then
    install_turn_end_hook "$wt" "$id"
  fi

  mkdir -p "$EM_STATE"
  : > "$EM_STATE/$id.status"
  cat > "$(meta_path "$id")" <<EOF
window=$(window_name "$id")
worktree=$wt
project=$repo
harness=$harness
kind=$kind
mode=$mode
auto=$auto
pr=
spawned=$(date +%Y-%m-%dT%H:%M:%S)
EOF

  local win
  win="$(window_name "$id")"
  if inside_tmux; then
    tmux_cmd new-window -d -n "$win" -c "$wt"
  else
    tmux_cmd has-session -t '=em' 2>/dev/null ||
      tmux_cmd new-session -d -s em -c "$EM_ROOT"
    tmux_cmd new-window -d -t '=em:' -n "$win" -c "$wt"
  fi

  local target prompt launch
  target="$(find_window "$id")" || die "window $win vanished after creation"
  prompt="You are an IC agent. Read your brief at $brief and execute it. Work only in this directory."
  launch="${EM_LAUNCH_OVERRIDE:-$(harness_cmd "$harness")} \"$prompt\""
  tmux_cmd send-keys -t "$target" -l -- "$launch"
  tmux_cmd send-keys -t "$target" Enter

  log "spawned $id in window $win — peek within ~20s (em-peek.sh $id) to confirm it is processing and accept any trust dialog"
  printf '%s\n' "$wt"
}

main "$@"
