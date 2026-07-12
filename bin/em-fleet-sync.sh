#!/usr/bin/env bash
# em-fleet-sync.sh — bring project clones up to date: fetch, clean
# fast-forward of the checked-out default branch, safe pruning of local
# branches whose upstream is gone. One of the two sanctioned exceptions to
# "the EM never writes to a project" (PRD §4.1).
#
# Usage:
#   em-fleet-sync.sh [<name>…]     default: every project under projects/
#
# Prints one line per project. Never touches: symlinked projects (a live
# working copy — fetch only), dirty clones, clones checked out off their
# default branch, diverged branches (reported, skipped). Never prunes: the
# default branch, branches used by any worktree, em/<id> branches of
# in-flight tasks. Set EM_FLEET_PRUNE=0 to disable pruning.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
"$EM_BIN/em-guard.sh"

PRUNE="${EM_FLEET_PRUNE:-1}"

sync_one() {
  local name="$1" proj="$EM_PROJECTS/$1" note="" pruned=""
  [ -d "$proj/.git" ] || {
    printf '%s: skipped (not a git clone)\n' "$name"
    return 0
  }

  if ! git -C "$proj" remote get-url origin >/dev/null 2>&1; then
    printf '%s: skipped (no remote)\n' "$name"
    return 0
  fi

  git -C "$proj" fetch --quiet --prune origin || {
    printf '%s: skipped (fetch failed)\n' "$name"
    return 0
  }

  if [ -L "$EM_PROJECTS/$name" ]; then
    printf '%s: fetched only (symlinked working copy — never fast-forwarded or pruned)\n' "$name"
    return 0
  fi

  local branch current
  branch="$(default_branch "$proj")" || {
    printf '%s: skipped (cannot resolve default branch)\n' "$name"
    return 0
  }
  current="$(git -C "$proj" symbolic-ref --quiet --short HEAD || true)"

  if [ "$current" != "$branch" ]; then
    note="checked out on '$current' — not fast-forwarded"
  elif [ -n "$(git -C "$proj" status --porcelain)" ]; then
    note="dirty working tree — not fast-forwarded"
  elif git -C "$proj" merge-base --is-ancestor "origin/$branch" "$branch" 2>/dev/null; then
    note="up to date"
  elif git -C "$proj" merge --ff-only --quiet "origin/$branch" 2>/dev/null; then
    note="fast-forwarded $branch to $(git -C "$proj" rev-parse --short HEAD)"
  else
    note="$branch diverged from origin — not fast-forwarded"
  fi

  if [ "$PRUNE" = "1" ]; then
    local in_use ref track b
    in_use="$(git -C "$proj" worktree list --porcelain 2>/dev/null | awk '/^branch /{print $2}')"
    while IFS='|' read -r ref track; do
      case "$track" in *'[gone]'*) ;; *) continue ;; esac
      b="${ref#refs/heads/}"
      [ "$b" = "$branch" ] && continue
      case "$in_use" in *"refs/heads/$b"*) continue ;; esac
      case "$b" in
        em/*)
          [ -f "$(meta_path "${b#em/}")" ] && continue
          ;;
      esac
      git -C "$proj" branch -D --quiet "$b" 2>/dev/null && pruned="$pruned $b"
    done < <(git -C "$proj" for-each-ref refs/heads --format='%(refname)|%(upstream:track)')
  fi
  git -C "$proj" worktree prune 2>/dev/null || true

  if [ -n "$pruned" ]; then
    printf '%s: %s; pruned%s\n' "$name" "$note" "$pruned"
  else
    printf '%s: %s\n' "$name" "$note"
  fi
}

main() {
  case "${1:-}" in -h | --help) usage; exit 0 ;; esac
  local names=("$@") d
  if [ ${#names[@]} -eq 0 ]; then
    [ -d "$EM_PROJECTS" ] || return 0
    for d in "$EM_PROJECTS"/*/; do
      [ -e "$d" ] || continue
      names+=("$(basename "$d")")
    done
  fi
  local n
  for n in "${names[@]}"; do
    sync_one "${n#projects/}"
  done
}

main "$@"
