#!/usr/bin/env bash
# em-merge-local.sh — the approved local-only merge: fast-forward the
# project's local default branch to the IC's em/<id> branch. One of the two
# sanctioned exceptions to "the EM never writes to a project" (PRD §4.1),
# run only after the Director approves the reviewed diff.
#
# Usage:
#   em-merge-local.sh <id>
#
# REFUSES (exit 3) anything but a clean fast-forward on a clean clone — if
# refused because of divergence, have the IC rebase onto the default branch.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

main() {
  local id="${1:-}"
  case "$id" in -h | --help) usage; exit 0 ;; esac
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"

  local project proj mode branch current
  project="$(meta_get "$id" project)" || die "no meta record for task $id"
  mode="$("$EM_BIN/em-project-mode.sh" "$project" mode)"
  [ "$mode" = "local-only" ] ||
    die "'$project' is $mode, not local-only — this merge path is only for local-only projects"

  proj="$EM_PROJECTS/$project"
  [ -d "$proj/.git" ] || die "no project clone at projects/$project"
  git -C "$proj" show-ref --verify --quiet "refs/heads/em/$id" ||
    die "no branch em/$id in projects/$project"

  branch="$(default_branch "$proj")" || die "cannot resolve default branch for projects/$project"
  current="$(git -C "$proj" symbolic-ref --quiet --short HEAD || true)"
  [ "$current" = "$branch" ] ||
    die_refuse "projects/$project is checked out on '$current', not '$branch' — not touching it"
  [ -z "$(git -C "$proj" status --porcelain)" ] ||
    die_refuse "projects/$project has uncommitted changes — not merging into a dirty tree"

  if ! git -C "$proj" merge --ff-only --quiet "em/$id" 2>/dev/null; then
    die_refuse "em/$id is not a clean fast-forward of $branch — have the IC rebase onto $branch, then retry"
  fi
  log "fast-forwarded $branch to em/$id ($(git -C "$proj" rev-parse --short HEAD))"
}

main "$@"
