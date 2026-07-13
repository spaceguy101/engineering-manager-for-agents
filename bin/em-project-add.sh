#!/usr/bin/env bash
# em-project-add.sh — add a project to the registry (data/projects.md), or
# validate the registry.
#
# Usage:
#   em-project-add.sh <name> --desc "<text>" [--mode gated|direct-PR|local-only]
#                     [--auto] [--test "<cmd>"] [--lint "<cmd>"]
#   em-project-add.sh --validate
#
# Writes one registry line (the format em-project-mode.sh parses):
#   - <name> [<mode>[ +auto]] - <desc> (added <date>) [| test: <cmd>] [| lint: <cmd>]
# Also scaffolds the project's long-term store, data/projects/<name>/:
# memory.md (the EM's accumulated knowledge of the project) and kb/ (the
# Director's knowledge base — architecture docs, standing instructions —
# spliced into every IC brief by em-brief.sh). Idempotent for existing files.
# The clone/symlink must already exist at projects/<name>. Default mode:
# gated. A gated project with no gate commands is registered with a warning —
# it cannot take build tasks until test:/lint: are recorded. Values must not
# contain " | " (the registry field delimiter) or newlines; wrap a piped gate
# command in a script inside the project instead.
#
# --validate lints every registry line: format, known mode, duplicate names
# (errors, exit 1); missing clones and gated projects without gate commands
# (warnings only).
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

REGISTRY="$EM_DATA/projects.md"
LINE_RE='^- [A-Za-z0-9][A-Za-z0-9._-]* \[(gated|direct-PR|local-only)( \+auto)?\] - .+ \(added [0-9]{4}-[0-9]{2}-[0-9]{2}\)( \| (test|lint): .+)*$'

check_value() { # <flag> <value> — refuse registry-delimiter collisions
  case "$2" in
    *' | '*) die "$1 value must not contain ' | ' (the registry field delimiter) — wrap piped commands in a script inside the project" ;;
    *$'\n'*) die "$1 value must not contain newlines" ;;
  esac
}

has_entry() { # <name> — is the project already registered?
  [ -f "$REGISTRY" ] &&
    awk -v n="- $1 [" 'index($0, n) == 1 { found = 1 } END { exit !found }' "$REGISTRY"
}

cmd_add() {
  local name="$1" mode="$2" auto="$3" desc="$4" test_cmd="$5" lint_cmd="$6"
  case "$name" in
    '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
      die "invalid project name '$name' — letters, digits, dots, dashes, underscores; must start alphanumeric"
      ;;
  esac
  case "$mode" in
    gated | direct-PR | local-only) ;;
    *) die "unknown mode '$mode' (gated|direct-PR|local-only)" ;;
  esac
  [ -n "$desc" ] || die "--desc is required (one line: what the project is)"
  check_value --desc "$desc"
  [ -z "$test_cmd" ] || check_value --test "$test_cmd"
  [ -z "$lint_cmd" ] || check_value --lint "$lint_cmd"
  [ -d "$EM_PROJECTS/$name/.git" ] ||
    die "no clone at projects/$name — clone (or symlink) the project first"
  ! has_entry "$name" || die "project '$name' is already in the registry"

  local flags="$mode" line
  if [ "$auto" -eq 1 ]; then flags="$mode +auto"; fi
  line="- $name [$flags] - $desc (added $(date +%Y-%m-%d))"
  [ -z "$test_cmd" ] || line="$line | test: $test_cmd"
  [ -z "$lint_cmd" ] || line="$line | lint: $lint_cmd"

  mkdir -p "$EM_DATA"
  [ -f "$REGISTRY" ] || printf '# Projects\n' > "$REGISTRY"
  printf '%s\n' "$line" >> "$REGISTRY"

  local store="$EM_DATA/projects/$name"
  mkdir -p "$store/kb"
  [ -f "$store/memory.md" ] || printf '# %s — EM memory\n\nDurable, fleet-side knowledge the EM has accumulated about this project:\ntask-history lessons, recurring failure modes, Director rulings. EM-written;\nnever shown to ICs verbatim. Director docs (architecture, documentation,\nstanding instructions) belong in kb/ instead — briefs list those for ICs.\n' \
    "$name" > "$store/memory.md"
  if [ "$mode" = "gated" ] && [ -z "$test_cmd" ] && [ -z "$lint_cmd" ]; then
    warn "gated project with no gate commands — it cannot take build tasks until test:/lint: are recorded"
  fi
  printf '%s\n' "$line"
}

cmd_validate() {
  [ -f "$REGISTRY" ] || die "no registry at data/projects.md"
  local errors=0 line name seen=$'\n' gate
  while IFS= read -r line; do
    case "$line" in '- '*) ;; *) continue ;; esac
    if ! printf '%s\n' "$line" | grep -Eq "$LINE_RE"; then
      log "ERROR: malformed registry line: $line"
      errors=1
      continue
    fi
    name="${line#- }"
    name="${name%% *}"
    case "$seen" in
      *$'\n'"$name"$'\n'*)
        log "ERROR: duplicate registry entry for '$name'"
        errors=1
        ;;
    esac
    seen="$seen$name"$'\n'
    [ -d "$EM_PROJECTS/$name/.git" ] ||
      warn "registry entry '$name' has no clone at projects/$name"
    case "$line" in
      *'[gated'*)
        gate="$(printf '%s\n' "$line" |
          awk -F' \\| ' '{ for (i = 2; i <= NF; i++) if ($i ~ /^(test|lint): /) { print "y"; exit } }')"
        [ -n "$gate" ] ||
          warn "gated project '$name' has no gate commands — it cannot take build tasks"
        ;;
    esac
  done < "$REGISTRY"
  [ "$errors" -eq 0 ] || exit 1
  log "registry OK"
}

main() {
  local name="" mode="gated" auto=0 desc="" test_cmd="" lint_cmd="" validate=0
  while [ $# -gt 0 ]; do
    case "$1" in
      -h | --help) usage; exit 0 ;;
      --validate) validate=1 ;;
      --auto) auto=1 ;;
      --mode | --desc | --test | --lint)
        [ $# -ge 2 ] || die "$1 needs a value"
        case "$1" in
          --mode) mode="$2" ;;
          --desc) desc="$2" ;;
          --test) test_cmd="$2" ;;
          --lint) lint_cmd="$2" ;;
        esac
        shift
        ;;
      -*) die "unknown option '$1'" ;;
      *)
        [ -z "$name" ] || { usage >&2; exit 1; }
        name="$1"
        ;;
    esac
    shift
  done

  if [ "$validate" -eq 1 ]; then
    [ -z "$name" ] || die "--validate takes no project name"
    cmd_validate
    return 0
  fi
  [ -n "$name" ] || { usage >&2; exit 1; }
  cmd_add "$name" "$mode" "$auto" "$desc" "$test_cmd" "$lint_cmd"
}

main "$@"
