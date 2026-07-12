#!/usr/bin/env bash
# em-review-diff.sh — review an IC's branch against the authoritative base
# (the fetched origin default branch, or the local default when the project
# has no remote — a clone's local default ref can lag origin, so never trust
# it when a remote exists).
#
# Usage:
#   em-review-diff.sh <id> [--stat]
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

main() {
  local id="" stat="" arg
  for arg in "$@"; do
    case "$arg" in
      -h | --help) usage; exit 0 ;;
      --stat) stat="--stat" ;;
      -*) die "unknown option '$arg' (only --stat)" ;;
      *)
        [ -z "$id" ] || { usage >&2; exit 1; }
        id="$arg"
        ;;
    esac
  done
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"

  local project proj branch base
  project="$(meta_get "$id" project)" || die "no meta record for task $id"
  proj="$EM_PROJECTS/$project"
  [ -d "$proj/.git" ] || die "no project clone at projects/$project"
  git -C "$proj" show-ref --verify --quiet "refs/heads/em/$id" ||
    die "no branch em/$id in projects/$project — has the IC committed anything?"

  branch="$(default_branch "$proj")" || die "cannot resolve default branch for projects/$project"
  if git -C "$proj" remote get-url origin >/dev/null 2>&1; then
    git -C "$proj" fetch --quiet origin || die "fetch failed for projects/$project"
    base="origin/$branch"
  else
    base="$branch"
  fi

  if [ "$stat" = "--stat" ]; then
    git -C "$proj" diff --stat "$base...em/$id"
  else
    git -C "$proj" diff "$base...em/$id"
  fi
}

main "$@"
