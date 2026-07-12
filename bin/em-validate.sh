#!/usr/bin/env bash
# em-validate.sh — the gate: run the project's configured test and lint
# commands inside the task's worktree; exit non-zero on any failure.
# Replaces firstmate's no-mistakes (PRD key scoping decision 1): test + lint
# enforcement only — no review findings, risk labels, or evidence databases.
#
# Usage:
#   em-validate.sh <id>
#
# Run by the IC (per its gated brief) until green, before pushing. Commands
# come from the project's registry line via em-project-mode.sh. At least one
# of test/lint must be configured; if only one is, the other is skipped with
# a note (PRD §8.2 decision).
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

main() {
  local id="${1:-}"
  case "$id" in -h | --help) usage; exit 0 ;; esac
  [ -n "$id" ] || { usage >&2; exit 1; }
  require_id "$id"

  local wt project test_cmd lint_cmd
  wt="$(meta_get "$id" worktree)" || die "no meta record for task $id"
  project="$(meta_get "$id" project)" || die "no project recorded for task $id"
  [ -d "$wt" ] || die "no worktree at $wt"

  test_cmd="$("$EM_BIN/em-project-mode.sh" "$project" test)"
  lint_cmd="$("$EM_BIN/em-project-mode.sh" "$project" lint)"
  [ -n "$test_cmd" ] || [ -n "$lint_cmd" ] ||
    die "no gate commands configured for '$project' — record test:/lint: in data/projects.md first"

  local red=0
  run_step() { # <label> <cmd>
    local label="$1" cmd="$2"
    if [ -z "$cmd" ]; then
      log "gate: no $label command configured — skipped"
      return 0
    fi
    log "gate: $label — $cmd"
    if (cd "$wt" && bash -c "$cmd"); then
      log "gate: $label PASSED"
    else
      log "gate: $label FAILED"
      red=1
    fi
  }
  run_step test "$test_cmd"
  run_step lint "$lint_cmd"

  if [ "$red" -ne 0 ]; then
    log "gate: RED — fix the failures above and re-run"
    exit 1
  fi
  log "gate: GREEN"
}

main "$@"
