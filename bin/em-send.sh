#!/usr/bin/env bash
# em-send.sh — send one literal line (submitted with Enter) or one key to an
# IC's tmux window.
#
# Usage:
#   em-send.sh <id> <text…>        type <text> into the IC's pane, then Enter
#   em-send.sh <id> --key <Key>    send a single tmux key name (e.g. Escape,
#                                  Enter, C-c) without any text
#
# Steering stays short: one line. Anything long goes in a file the IC reads.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

main() {
  local id="${1:-}"
  case "$id" in -h | --help) usage; exit 0 ;; esac
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"
  shift

  local target
  target="$(find_window "$id")" || die "no window $(window_name "$id") — is the task running?"

  if [ "${1:-}" = "--key" ]; then
    [ $# -eq 2 ] || { usage >&2; exit 1; }
    tmux_cmd send-keys -t "$target" "$2"
  else
    [ $# -ge 1 ] || { usage >&2; exit 1; }
    tmux_cmd send-keys -t "$target" -l -- "$*"
    tmux_cmd send-keys -t "$target" Enter
  fi
}

main "$@"
