#!/usr/bin/env bash
# em-brief.sh — scaffold a per-task IC brief from the build template, with
# the delivery contract resolved from the project's registry mode.
#
# Usage:
#   em-brief.sh <id> <repo> [--force]
#
# Renders templates/brief-build.md to data/<id>/brief.md, splicing in the
# delivery section for the project's mode (templates/delivery-<mode>.md).
# The {TASK} placeholder is left for the EM to fill in (description,
# acceptance criteria, constraints) before spawning. A project missing from
# the registry defaults to direct-PR with a warning; a gated project without
# confirmed gate commands cannot be briefed. Refuses to overwrite an
# existing brief unless --force is given. --research is not available until
# M4.
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

  local mode
  if ! mode="$("$EM_BIN/em-project-mode.sh" "$repo" mode 2>/dev/null)"; then
    warn "project '$repo' is not in the registry — defaulting to direct-PR (record it in data/projects.md)"
    mode=direct-PR
  fi
  local dtpl="$EM_TEMPLATES/delivery-$mode.md"
  [ -f "$dtpl" ] || die "unknown delivery mode '$mode' for '$repo' (no $dtpl)"
  if [ "$mode" = "gated" ]; then
    local test_cmd lint_cmd
    test_cmd="$("$EM_BIN/em-project-mode.sh" "$repo" test)"
    lint_cmd="$("$EM_BIN/em-project-mode.sh" "$repo" lint)"
    [ -n "$test_cmd" ] || [ -n "$lint_cmd" ] ||
      die "gated project '$repo' has no confirmed gate commands — record test:/lint: in data/projects.md before dispatching build tasks"
  fi

  local branch base_ref
  branch="$(default_branch "$proj")" || die "cannot resolve default branch for projects/$repo"
  if git -C "$proj" remote get-url origin >/dev/null 2>&1; then
    base_ref="origin/$branch"
  else
    base_ref="$branch"
  fi

  local content
  content="$(<"$tpl")"
  content="${content//\{DELIVERY\}/$(<"$dtpl")}"
  content="${content//\{ID\}/$id}"
  content="${content//\{REPO\}/$repo}"
  content="${content//\{BRANCH\}/em/$id}"
  content="${content//\{DEFAULT_BRANCH\}/$branch}"
  content="${content//\{BASE_REF\}/$base_ref}"
  content="${content//\{STATUS_FILE\}/$EM_STATE/$id.status}"
  content="${content//\{EM_BIN\}/$EM_BIN}"

  mkdir -p "$EM_DATA/$id"
  printf '%s\n' "$content" > "$out"
  printf '%s\n' "$out"
}

main "$@"
