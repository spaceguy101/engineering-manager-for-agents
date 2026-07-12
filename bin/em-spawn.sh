#!/usr/bin/env bash
# em-spawn.sh — hire an IC: tmux window + fresh worktree + turn-end hook +
# meta record, then launch the agent with its brief.
#
# Usage:
#   em-spawn.sh <id> <repo> [<harness>]
#
# Requires a filled brief at data/<id>/brief.md (no {TASK} placeholder left).
# Creates the window in the current tmux session, or in a dedicated 'em'
# session when running outside tmux. M1 supports the claude harness only.
#
# The two writes into the worktree/clone (the Stop-hook settings file and one
# .git/info/exclude pattern) are sanctioned spawn provisioning (ADR-0003) —
# harness mechanics, never project content.
#
# Test seam: EM_LAUNCH_OVERRIDE replaces the harness launch command (the brief
# prompt is still appended as the final argument). Not Director-facing.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

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

main() {
  local id="${1:-}" repo="${2:-}" harness="${3:-claude}"
  case "$id" in -h | --help) usage; exit 0 ;; esac
  [ -n "$id" ] && [ -n "$repo" ] || { usage >&2; exit 1; }
  require_id "$id"
  repo="${repo#projects/}"

  [ "$harness" = "claude" ] ||
    die "harness '$harness' is unverified — M1 supports claude only (adapters arrive in M4)"

  local brief="$EM_DATA/$id/brief.md"
  [ -f "$brief" ] || die "no brief at data/$id/brief.md — run em-brief.sh first"
  ! grep -qF '{TASK}' "$brief" ||
    die "brief still has the {TASK} placeholder — fill it in before spawning"

  [ ! -f "$(meta_path "$id")" ] || die "task $id already has a meta record"
  ! find_window "$id" >/dev/null || die "window $(window_name "$id") already exists"

  local wt
  wt="$("$EM_BIN/em-worktree.sh" add "$id" "$repo")"

  install_turn_end_hook "$wt" "$id"

  mkdir -p "$EM_STATE"
  : > "$EM_STATE/$id.status"
  cat > "$(meta_path "$id")" <<EOF
window=$(window_name "$id")
worktree=$wt
project=$repo
harness=$harness
kind=build
mode=direct-PR
auto=0
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
  launch="${EM_LAUNCH_OVERRIDE:-claude --dangerously-skip-permissions} \"$prompt\""
  tmux_cmd send-keys -t "$target" -l -- "$launch"
  tmux_cmd send-keys -t "$target" Enter

  log "spawned $id in window $win — peek within ~20s (em-peek.sh $id) to confirm it is processing and accept any trust dialog"
  printf '%s\n' "$wt"
}

main "$@"
