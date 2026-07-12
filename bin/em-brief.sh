#!/usr/bin/env bash
# em-brief.sh — scaffold a per-task IC brief from the build template.
#
# Usage:
#   em-brief.sh <id> <repo> [--force]
#
# Renders templates/brief-build.md to data/<id>/brief.md, filling {ID},
# {REPO}, {BRANCH}, {DEFAULT_BRANCH} and {STATUS_FILE}. The {TASK} placeholder
# is left for the EM to fill in (description, acceptance criteria,
# constraints) before spawning. Refuses to overwrite an existing brief unless
# --force is given. --research is not available until M4.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local id="" repo="" force=0 arg
  for arg in "$@"; do
    case "$arg" in
      --research) die "research tasks are not available yet (M4 — PRD §4.7)" ;;
      --force) force=1 ;;
      -h | --help) usage; exit 0 ;;
      -*) die "unknown option '$arg'" ;;
      *)
        if [ -z "$id" ]; then id="$arg"
        elif [ -z "$repo" ]; then repo="$arg"
        else usage >&2; exit 1
        fi
        ;;
    esac
  done
  [ -n "$id" ] && [ -n "$repo" ] || { usage >&2; exit 1; }
  require_id "$id"

  repo="${repo#projects/}"
  local proj="$EM_PROJECTS/$repo"
  [ -d "$proj/.git" ] || die "no project clone at projects/$repo"

  local tpl="$EM_TEMPLATES/brief-build.md"
  [ -f "$tpl" ] || die "missing template: $tpl"

  local out="$EM_DATA/$id/brief.md"
  if [ -e "$out" ] && [ "$force" -ne 1 ]; then
    die "brief already exists: $out (use --force to overwrite)"
  fi

  local branch
  branch="$(default_branch "$proj")" || die "cannot resolve default branch for projects/$repo"

  local content
  content="$(<"$tpl")"
  content="${content//\{ID\}/$id}"
  content="${content//\{REPO\}/$repo}"
  content="${content//\{BRANCH\}/em/$id}"
  content="${content//\{DEFAULT_BRANCH\}/$branch}"
  content="${content//\{STATUS_FILE\}/$EM_STATE/$id.status}"

  mkdir -p "$EM_DATA/$id"
  printf '%s\n' "$content" > "$out"
  printf '%s\n' "$out"
}

main "$@"
