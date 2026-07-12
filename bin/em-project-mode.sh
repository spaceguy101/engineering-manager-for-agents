#!/usr/bin/env bash
# em-project-mode.sh — resolve a project's delivery mode, autonomy flag and
# gate commands from the registry (data/projects.md).
#
# Usage:
#   em-project-mode.sh <name> [mode|auto|test|lint|entry]
#
# Fields (default: mode):
#   mode    gated | direct-PR | local-only
#   auto    1 if the project carries +auto, else 0
#   test    the project's test command (empty if unset)
#   lint    the project's lint command (empty if unset)
#   entry   the raw registry line
#
# Registry line format, one per project:
#   - <name> [<mode>[ +auto]] - <description> (added <date>) [| test: <cmd>] [| lint: <cmd>]
# e.g.
#   - webapp [gated +auto] - main SaaS app (added 2026-07-12) | test: npm test | lint: npm run lint
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local name="${1:-}" field="${2:-mode}"
  case "$name" in -h | --help) usage; exit 0 ;; esac
  [ -n "$name" ] || { usage >&2; exit 1; }

  local registry="$EM_DATA/projects.md" line brackets
  [ -f "$registry" ] || die "no registry at data/projects.md — add the project first"
  line="$(grep -m1 -E "^- $name \[" "$registry" || true)"
  [ -n "$line" ] || die "project '$name' is not in the registry (data/projects.md)"

  brackets="${line#*[}"
  brackets="${brackets%%]*}"

  case "$field" in
    entry)
      printf '%s\n' "$line"
      ;;
    mode)
      printf '%s\n' "${brackets%% *}"
      ;;
    auto)
      case " $brackets " in
        *' +auto '*) printf '1\n' ;;
        *) printf '0\n' ;;
      esac
      ;;
    test | lint)
      printf '%s\n' "$line" | awk -F' \\| ' -v want="$field" '{
        for (i = 2; i <= NF; i++) {
          if (index($i, want ": ") == 1) {
            print substr($i, length(want) + 3)
            exit
          }
        }
      }'
      ;;
    *)
      die "unknown field '$field' (mode|auto|test|lint|entry)"
      ;;
  esac
}

main "$@"
