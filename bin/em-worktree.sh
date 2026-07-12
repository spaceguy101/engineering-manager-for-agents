#!/usr/bin/env bash
# em-worktree.sh — plain `git worktree` wrapper with em naming and safety
# conventions. Uses git worktrees directly, no pool (PRD key scoping decision 2).
#
# Usage:
#   em-worktree.sh add <id> <repo>        create worktrees/<id> for projects/<repo>,
#                                         detached at fetched origin/<default>
#                                         (or the local default branch when the
#                                         project has no remote); prints the path
#   em-worktree.sh remove <id> [--force]  remove worktrees/<id>; REFUSES (exit 3)
#                                         if the worktree holds unlanded work
#   em-worktree.sh prune <repo>           git worktree prune in projects/<repo>
#   em-worktree.sh list                   list task worktrees
#
# Unlanded work (ADR-0002, conservative): uncommitted or untracked changes, or
# any commit reachable from the worktree HEAD or its em/<id> branch that
# neither a remote ref nor the clone's default branch reaches. A refusal means
# stop and investigate; --force is only for an explicit Director instruction
# to discard the work.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

# clone_of <wt> — print the project clone directory owning a worktree.
clone_of() {
  (cd "$1" && cd "$(git rev-parse --git-common-dir)/.." && pwd -P)
}

# Print human-readable evidence of unlanded work in <wt> for task <id>;
# prints nothing when everything has landed on a remote or the clone's
# default branch (the durable base refs — ADR-0002 as amended).
unlanded_evidence() {
  local wt="$1" id="$2" dirty unlanded clone base
  local -a heads=(HEAD) landed=(--remotes)
  dirty="$(git -C "$wt" status --porcelain 2>/dev/null | head -n 10 || true)"
  if [ -n "$dirty" ]; then
    printf 'uncommitted changes:\n%s\n' "$dirty"
  fi
  if git -C "$wt" show-ref --verify --quiet "refs/heads/em/$id"; then
    heads+=("em/$id")
  fi
  if clone="$(clone_of "$wt")" && base="$(default_branch "$clone")" &&
    git -C "$wt" show-ref --verify --quiet "refs/heads/$base"; then
    landed+=("refs/heads/$base")
  fi
  unlanded="$(git -C "$wt" log --oneline "${heads[@]}" --not "${landed[@]}" 2>/dev/null | head -n 10 || true)"
  if [ -n "$unlanded" ]; then
    printf 'commits not on any remote or the default branch:\n%s\n' "$unlanded"
  fi
}

cmd_add() {
  local id="$1" repo="$2" proj wt branch
  require_id "$id"
  repo="${repo#projects/}"
  proj="$EM_PROJECTS/$repo"
  [ -d "$proj/.git" ] || die "no project clone at projects/$repo"
  wt="$EM_WORKTREES/$id"
  [ -e "$wt" ] && die "worktree already exists: $wt"
  mkdir -p "$EM_WORKTREES"
  local base
  if git -C "$proj" remote get-url origin >/dev/null 2>&1; then
    git -C "$proj" fetch --quiet origin || die "fetch failed for projects/$repo"
    branch="$(default_branch "$proj")" || die "cannot resolve default branch for projects/$repo"
    base="origin/$branch"
  else
    # local-only project: no remote to fetch; base on the local default branch
    branch="$(default_branch "$proj")" || die "cannot resolve default branch for projects/$repo"
    base="$branch"
  fi
  git -C "$proj" worktree add --quiet --detach "$wt" "$base"
  printf '%s\n' "$wt"
}

cmd_remove() {
  local id="" force="" arg wt proj evidence
  for arg in "$@"; do
    case "$arg" in
      --force) force="--force" ;;
      -*) die "unknown option '$arg' (only --force)" ;;
      *)
        [ -z "$id" ] || { usage >&2; exit 1; }
        id="$arg"
        ;;
    esac
  done
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"
  wt="$EM_WORKTREES/$id"
  [ -d "$wt" ] || die "no worktree at worktrees/$id"
  proj="$(clone_of "$wt")" ||
    die "cannot resolve the project clone for worktrees/$id"
  if [ "$force" != "--force" ]; then
    evidence="$(unlanded_evidence "$wt" "$id")"
    if [ -n "$evidence" ]; then
      {
        printf 'REFUSED: worktrees/%s holds unlanded work:\n%s\n' "$id" "$evidence"
        printf 'Land it (push / merge) first. Only on an explicit Director instruction to discard may this be re-run with --force.\n'
      } >&2
      exit 3
    fi
    git -C "$proj" worktree remove "$wt"
  else
    git -C "$proj" worktree remove --force "$wt"
  fi
  git -C "$proj" worktree prune
}

cmd_prune() {
  local repo="$1"
  repo="${repo#projects/}"
  [ -d "$EM_PROJECTS/$repo/.git" ] || die "no project clone at projects/$repo"
  git -C "$EM_PROJECTS/$repo" worktree prune
}

cmd_list() {
  [ -d "$EM_WORKTREES" ] || return 0
  ls -1 "$EM_WORKTREES"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    add)
      shift
      [ $# -eq 2 ] || { usage >&2; exit 1; }
      cmd_add "$@"
      ;;
    remove)
      shift
      [ $# -ge 1 ] && [ $# -le 2 ] || { usage >&2; exit 1; }
      cmd_remove "$@"
      ;;
    prune)
      shift
      [ $# -eq 1 ] || { usage >&2; exit 1; }
      cmd_prune "$@"
      ;;
    list)
      cmd_list
      ;;
    -h | --help | help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
