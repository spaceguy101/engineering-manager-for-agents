#!/usr/bin/env bash
# em-peek.sh — print a bounded tail of an IC's tmux pane.
#
# Usage:
#   em-peek.sh <id> [<lines>]      default 40 lines
#
# The cheap look before anything else: never stream a pane, peek it.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local id="${1:-}" lines="${2:-40}"
  case "$id" in -h | --help) usage; exit 0 ;; esac
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"
  case "$lines" in *[!0-9]* | '') die "lines must be a positive integer, got '$lines'" ;; esac

  local target
  target="$(find_window "$id")" || die "no window $(window_name "$id") — is the task running?"
  tmux_cmd capture-pane -p -t "$target" | tail -n "$lines"
}

main "$@"
