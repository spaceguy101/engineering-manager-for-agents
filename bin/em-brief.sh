#!/usr/bin/env bash
# em-brief.sh — scaffold a per-task IC brief: a build brief with the
# delivery contract resolved from the project's registry mode, or a
# report-only research brief with --research.
#
# Usage:
#   em-brief.sh <id> <repo> [--research] [--force]
#              [--budget <spec>]   e.g. --budget wall=45m,tokens=1.5M,cost=2.00
#
# Build: renders templates/brief-build.md to data/<id>/brief.md, splicing in
# the delivery section for the project's mode (templates/delivery-<mode>.md).
# A project missing from the registry cannot take a build brief — delivery
# modes are Director-confirmed, never guessed; register it first
# (em-project-add.sh). A gated project without confirmed gate commands
# cannot be briefed either. Research briefs need only the clone.
# Research: renders templates/brief-research.md — deliverable is
# data/<id>/report.md, never a PR; no mode resolution.
# Both kinds splice a "Project knowledge" section listing every file in the
# Director's knowledge base (data/projects/<repo>/kb/) when it is non-empty,
# so ICs always see the project's architecture docs and standing
# instructions.
# The {TASK} placeholder is left for the EM to fill in (description,
# acceptance criteria, constraints) before spawning. Refuses to overwrite an
# existing brief unless --force is given.
# --budget declares the task's resource envelope (BUD-4): it is written to
# state/tasks/<repo>/<id>/budget.json and rendered into the brief's {BUDGET}
# section so the IC knows its limits. Spawn is the guarantee point — a task
# briefed without a budget can still get one at em-spawn.sh time.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"
# shellcheck source=bin/lib/budget.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/budget.sh"

main() {
  local id="" repo="" force=0 research=0 budget_spec=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --research) research=1 ;;
      --force) force=1 ;;
      --budget)
        [ $# -ge 2 ] || die "--budget needs a value (e.g. wall=45m,tokens=1.5M)"
        shift
        budget_spec="$1"
        ;;
      -h | --help) usage; exit 0 ;;
      -*) die "unknown option '$1'" ;;
      *)
        if [ -z "$id" ]; then id="$1"
        elif [ -z "$repo" ]; then repo="$1"
        else usage >&2; exit 1
        fi
        ;;
    esac
    shift
  done
  [ -n "$id" ] && [ -n "$repo" ] || { usage >&2; exit 1; }
  require_id "$id"

  repo="${repo#projects/}"
  local proj="$EM_PROJECTS/$repo"
  [ -d "$proj/.git" ] || die "no project clone at projects/$repo"

  local tpl="$EM_TEMPLATES/brief-build.md"
  [ "$research" -eq 1 ] && tpl="$EM_TEMPLATES/brief-research.md"
  [ -f "$tpl" ] || die "missing template: $tpl"

  local out="$EM_DATA/$id/brief.md" existed=0
  if [ -e "$out" ]; then
    [ "$force" -eq 1 ] || die "brief already exists: $out (use --force to overwrite)"
    existed=1
  fi

  local dtpl=""
  if [ "$research" -eq 0 ]; then
    local mode
    mode="$("$EM_BIN/em-project-mode.sh" "$repo" mode 2>/dev/null)" ||
      die "project '$repo' is not in the registry — register it first (em-project-add.sh $repo --desc \"…\"); delivery modes are Director-confirmed, never guessed"
    dtpl="$EM_TEMPLATES/delivery-$mode.md"
    [ -f "$dtpl" ] || die "unknown delivery mode '$mode' for '$repo' (no $dtpl)"
    if [ "$mode" = "gated" ]; then
      local test_cmd lint_cmd
      test_cmd="$("$EM_BIN/em-project-mode.sh" "$repo" test)"
      lint_cmd="$("$EM_BIN/em-project-mode.sh" "$repo" lint)"
      [ -n "$test_cmd" ] || [ -n "$lint_cmd" ] ||
        die "gated project '$repo' has no confirmed gate commands — record test:/lint: in data/projects.md before dispatching build tasks"
    fi
  fi

  local branch base_ref
  branch="$(default_branch "$proj")" || die "cannot resolve default branch for projects/$repo"
  if git -C "$proj" remote get-url origin >/dev/null 2>&1; then
    base_ref="origin/$branch"
  else
    base_ref="$branch"
  fi

  local kb_dir="$EM_DATA/projects/$repo/kb" knowledge="" kb_files
  if [ -d "$kb_dir" ]; then
    kb_files="$(find "$kb_dir" -type f ! -name '.*' | sort)"
    if [ -n "$kb_files" ]; then
      knowledge=$'\n## Project knowledge\n\nThe Director maintains a knowledge base for this project (architecture,\ndocumentation, standing instructions). Read every file listed below before\nyou start; it is binding context for this task:\n\n'
      knowledge+="$(printf '%s\n' "$kb_files" | sed 's/^/- /')"$'\n'
    fi
  fi

  local budget_section=""
  if [ -n "$budget_spec" ]; then
    local parsed
    parsed="$(declare_budget "$id" "$repo" "$budget_spec" task pause)" ||
      die "invalid --budget '$budget_spec' (want e.g. wall=45m,tokens=1.5M,cost=2.00)"
    budget_section="$(printf '\n## Budget\n\nThis task has a resource envelope: %s.\nPrefer the smallest correct change that meets the brief. At 80%% of any limit\nyou will be warned in this window; at 100%% enforcement kicks in (default:\nthe task is paused until your manager extends the budget).\n' \
      "$(budget_phrase "$parsed")")"
  fi

  local content
  content="$(<"$tpl")"
  [ -n "$dtpl" ] && content="${content//\{DELIVERY\}/$(<"$dtpl")}"
  content="${content//\{KNOWLEDGE\}/$knowledge}"
  content="${content//\{BUDGET\}/$budget_section}"
  content="${content//\{ID\}/$id}"
  content="${content//\{REPO\}/$repo}"
  content="${content//\{BRANCH\}/em/$id}"
  content="${content//\{DEFAULT_BRANCH\}/$branch}"
  content="${content//\{BASE_REF\}/$base_ref}"
  content="${content//\{STATUS_FILE\}/$EM_STATE/$id.status}"
  content="${content//\{REPORT_FILE\}/$EM_DATA/$id/report.md}"
  content="${content//\{EM_BIN\}/$EM_BIN}"

  mkdir -p "$EM_DATA/$id"
  printf '%s\n' "$content" > "$out"

  local kind=build
  [ "$research" -eq 1 ] && kind=research
  if [ "$existed" -eq 1 ]; then
    emit_event "$id" rebrief --actor em --project "$repo" --data '{"force": true}'
  else
    emit_event "$id" task_created --actor em --project "$repo" \
      --data "$(jq -cn --arg kind "$kind" --arg mode "${mode:-}" --arg budget "$budget_spec" \
        '{kind: $kind, mode: (if $mode == "" then null else $mode end),
          budget: (if $budget == "" then null else $budget end)}' 2>/dev/null || true)"
  fi
  emit_event "$id" brief_written --actor em --project "$repo" \
    --data "$(jq -cn --arg t "$(basename "$tpl")" '{template: $t}' 2>/dev/null || true)"

  printf '%s\n' "$out"
}

main "$@"
