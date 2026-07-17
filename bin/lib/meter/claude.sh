#!/usr/bin/env bash
# claude.sh — token meter adapter for the claude harness: prints the total
# input+output tokens the task's IC has consumed, summed from Claude Code's
# local session files (~/.claude/projects/<munged-worktree-path>/*.jsonl).
# No API calls, no network (D-2). Cache-creation/cache-read tokens are
# excluded from the count — they are priced differently and would dwarf the
# real spend; cost weighting belongs in the configured per-harness rate.
#
# Usage:
#   claude.sh <id>        prints an integer; exits 1 when unmeterable
#                         (no meta, no session directory yet)
#
# EM_CLAUDE_SESSIONS_DIR overrides the sessions root (test seam).
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../common.sh"

main() {
  local id="${1:-}"
  case "$id" in -h | --help)
    usage
    exit 0
    ;;
  esac
  [ -n "$id" ] || {
    usage >&2
    exit 1
  }
  require_id "$id"

  local wt munged dir total
  wt="$(meta_get "$id" worktree 2>/dev/null)" || exit 1
  [ -n "$wt" ] || exit 1
  # Claude Code names each project's session dir after its path with every
  # non-alphanumeric character replaced by '-'.
  munged="$(printf '%s' "$wt" | tr -c '[:alnum:]' '-')"
  dir="${EM_CLAUDE_SESSIONS_DIR:-$HOME/.claude/projects}/$munged"
  [ -d "$dir" ] || exit 1

  # An empty dir has no *.jsonl match — cat's failure is fine (0 tokens);
  # only a jq failure makes the task unmeterable.
  total="$( (cat "$dir"/*.jsonl 2>/dev/null || true) |
    jq -Rn '[inputs | fromjson? | select(.type == "assistant") | .message.usage
             | ((.input_tokens // 0) + (.output_tokens // 0))] | add // 0' 2>/dev/null)" || exit 1
  case "$total" in
    '' | *[!0-9]*) exit 1 ;;
  esac
  printf '%s\n' "$total"
}

main "$@"
