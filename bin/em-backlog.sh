#!/usr/bin/env bash
# em-backlog.sh — manage the task queue (data/backlog.md): scripted writes
# and a validator, so the queue is as restart-proof and machine-checkable
# as the rest of the fleet state instead of hand-edited markdown.
#
# Usage:
#   em-backlog.sh add <id> <repo> "<one line>"
#                 [--blocked-by <id> --reason "<why>"]
#   em-backlog.sh start <id>
#   em-backlog.sh done <id> "<outcome>"
#   em-backlog.sh remove <id>
#   em-backlog.sh list [in-flight|queued|done]
#   em-backlog.sh unblocked
#   em-backlog.sh validate
#
# add      → "## In flight", or "## Queued" with --blocked-by (both flags
#            together; the reason says why it must wait).
# start    → queued entry moves to In flight (call it at dispatch time).
# done     → entry moves to the top of Done; <outcome> is the durable
#            pointer: a PR URL, "local main <sha>", data/<id>/report.md, or
#            "failed: <why>". Done keeps only the 10 most recent entries.
# remove   → drop an entry outright (accepted by mistake, superseded).
# list     → entry lines of one section, or the whole file.
# unblocked→ ids of queued tasks whose blocker no longer has an open entry
#            (landed or removed) — ready to dispatch, checked on every
#            teardown and heartbeat.
# validate → line grammar per section, duplicate ids, entries outside a
#            known section (errors, exit 1); in-flight entries without a
#            task record and task records missing from In flight (warnings).
#
# The file keeps the human-readable format documented in AGENTS.md:
#   ## In flight   - [ ] <id> - <one line> (repo: <name>, since <date>)
#   ## Queued      - [ ] <id> - <one line> (repo: <name>) blocked-by: <id> - <reason>
#   ## Done        - [x] <id> - <one line> - <outcome> (<date>)
# Writes are atomic (tmp + mv). Free-text fields must not contain newlines.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

BACKLOG="$EM_DATA/backlog.md"
DONE_KEEP=10

IN_FLIGHT_RE='^- \[ \] [a-z0-9][a-z0-9-]* - .+ \(repo: [A-Za-z0-9][A-Za-z0-9._-]*, since [0-9]{4}-[0-9]{2}-[0-9]{2}\)$'
QUEUED_RE='^- \[ \] [a-z0-9][a-z0-9-]* - .+ \(repo: [A-Za-z0-9][A-Za-z0-9._-]*\) blocked-by: [a-z0-9][a-z0-9-]* - .+$'
DONE_RE='^- \[x\] [a-z0-9][a-z0-9-]* - .+ - .+ \([0-9]{4}-[0-9]{2}-[0-9]{2}\)$'

ensure_file() {
  [ -f "$BACKLOG" ] && return 0
  mkdir -p "$EM_DATA"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$BACKLOG"
}

check_text() { # <label> <value> — one non-empty line of free text
  [ -n "$2" ] || die "$1 must not be empty"
  case "$2" in *$'\n'*) die "$1 must not contain newlines" ;; esac
}

# rewrite <awk-args…> — atomic in-place edit of the backlog via awk
rewrite() {
  local tmp="$BACKLOG.tmp.$$"
  awk "$@" "$BACKLOG" > "$tmp" && mv "$tmp" "$BACKLOG"
}

has_entry() { # <id> — any entry, open or done
  [ -f "$BACKLOG" ] && grep -Eq "^- \[( |x)\] $1 - " "$BACKLOG"
}

open_entry() { # <id> — print the In flight/Queued line, fail when absent
  [ -f "$BACKLOG" ] && grep -E "^- \[ \] $1 - " "$BACKLOG" | head -n 1 | grep .
}

# section_of <id> — in-flight | queued | done; fails when absent
section_of() {
  [ -f "$BACKLOG" ] || return 1
  awk -v id="$1" '
    /^## In flight$/ { s = "in-flight"; next }
    /^## Queued$/ { s = "queued"; next }
    /^## Done$/ { s = "done"; next }
    index($0, "- [ ] " id " - ") == 1 || index($0, "- [x] " id " - ") == 1 {
      print s; found = 1; exit
    }
    END { exit !found }
  ' "$BACKLOG"
}

# line_summary <line> <id> — the free text between "<id> - " and " (repo: "
line_summary() {
  local rest="${1#"- [ ] $2 - "}"
  printf '%s\n' "${rest% (repo: *}"
}

line_repo() { # <line> — the repo name from "(repo: <name>[,)]…"
  local t="${1##* (repo: }"
  printf '%s\n' "${t%%[,)]*}"
}

# insert_entry <section header> <line> — remove any old entry for the line's
# id and insert the new line at the top of the section; then trim Done to
# the DONE_KEEP most recent entries.
insert_entry() {
  local hdr="$1" line="$2" id
  id="${line#- \[*\] }"
  id="${id%% *}"
  # shellcheck disable=SC2016  # awk programs, not shell expansions
  rewrite -v hdr="$hdr" -v line="$line" -v id="$id" '
    index($0, "- [ ] " id " - ") == 1 || index($0, "- [x] " id " - ") == 1 { next }
    { print }
    $0 == hdr { print line }
  '
  rewrite -v keep="$DONE_KEEP" '
    /^## Done$/ { d = 1 }
    d && /^- \[x\] / { if (++n > keep) next }
    { print }
  '
}

cmd_add() {
  local id="$1" repo="$2" summary="$3" blocked_by="$4" reason="$5" line
  require_id "$id"
  case "$repo" in
    '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._-]*)
      die "invalid project name '$repo'"
      ;;
  esac
  check_text summary "$summary"
  ensure_file
  ! has_entry "$id" || die "'$id' is already in the backlog ($(section_of "$id"))"
  if [ -n "$blocked_by" ]; then
    require_id "$blocked_by"
    check_text --reason "$reason"
    line="- [ ] $id - $summary (repo: $repo) blocked-by: $blocked_by - $reason"
    insert_entry '## Queued' "$line"
  else
    [ -z "$reason" ] || die "--reason needs --blocked-by"
    line="- [ ] $id - $summary (repo: $repo, since $(date +%Y-%m-%d))"
    insert_entry '## In flight' "$line"
  fi
  printf '%s\n' "$line"
}

cmd_start() {
  local id="$1" old section summary repo line
  require_id "$id"
  section="$(section_of "$id")" || die "'$id' is not in the backlog"
  [ "$section" = "queued" ] || die "'$id' is $section, not queued"
  old="$(open_entry "$id")"
  summary="$(line_summary "$old" "$id")"
  repo="$(line_repo "$old")"
  line="- [ ] $id - $summary (repo: $repo, since $(date +%Y-%m-%d))"
  insert_entry '## In flight' "$line"
  printf '%s\n' "$line"
}

cmd_done() {
  local id="$1" outcome="$2" old section summary line
  require_id "$id"
  check_text outcome "$outcome"
  section="$(section_of "$id")" || die "'$id' is not in the backlog"
  [ "$section" != "done" ] || die "'$id' is already done"
  old="$(open_entry "$id")"
  summary="$(line_summary "$old" "$id")"
  line="- [x] $id - $summary - $outcome ($(date +%Y-%m-%d))"
  insert_entry '## Done' "$line"
  printf '%s\n' "$line"
}

cmd_remove() {
  local id="$1"
  require_id "$id"
  has_entry "$id" || die "'$id' is not in the backlog"
  # shellcheck disable=SC2016  # awk program, not a shell expansion
  rewrite -v id="$id" '
    index($0, "- [ ] " id " - ") == 1 || index($0, "- [x] " id " - ") == 1 { next }
    { print }
  '
}

cmd_list() {
  [ -f "$BACKLOG" ] || die "no backlog at data/backlog.md"
  local section="${1:-}" hdr
  if [ -z "$section" ]; then
    cat "$BACKLOG"
    return 0
  fi
  case "$section" in
    in-flight) hdr='## In flight' ;;
    queued) hdr='## Queued' ;;
    done) hdr='## Done' ;;
    *) die "unknown section '$section' (in-flight|queued|done)" ;;
  esac
  awk -v hdr="$hdr" '
    $0 == hdr { s = 1; next }
    /^## / { s = 0 }
    s && /^- / { print }
  ' "$BACKLOG"
}

cmd_unblocked() {
  [ -f "$BACKLOG" ] || return 0
  local line id blocker
  while IFS= read -r line; do
    id="${line#- \[ \] }"
    id="${id%% *}"
    blocker="${line##* blocked-by: }"
    blocker="${blocker%% *}"
    [ "$blocker" != "$line" ] || continue
    open_entry "$blocker" >/dev/null || printf '%s\n' "$id"
  done < <(cmd_list queued)
}

cmd_validate() {
  [ -f "$BACKLOG" ] || die "no backlog at data/backlog.md"
  local errors=0 section="" line id seen=$'\n' in_flight_seen=$'\n'
  while IFS= read -r line; do
    case "$line" in
      '## In flight') section=in-flight; continue ;;
      '## Queued') section=queued; continue ;;
      '## Done') section='done'; continue ;;
      '## '* | '# '*) section=""; continue ;;
      '- '*) ;;
      *) continue ;;
    esac
    case "$section" in
      in-flight) printf '%s\n' "$line" | grep -Eq "$IN_FLIGHT_RE" ||
        { log "ERROR: malformed in-flight line: $line"; errors=1; continue; } ;;
      queued) printf '%s\n' "$line" | grep -Eq "$QUEUED_RE" ||
        { log "ERROR: malformed queued line: $line"; errors=1; continue; } ;;
      done) printf '%s\n' "$line" | grep -Eq "$DONE_RE" ||
        { log "ERROR: malformed done line: $line"; errors=1; continue; } ;;
      *)
        log "ERROR: entry outside a known section: $line"
        errors=1
        continue
        ;;
    esac
    id="${line#- \[*\] }"
    id="${id%% *}"
    case "$seen" in
      *$'\n'"$id"$'\n'*)
        log "ERROR: duplicate backlog entry for '$id'"
        errors=1
        ;;
    esac
    seen="$seen$id"$'\n'
    [ "$section" != "in-flight" ] || in_flight_seen="$in_flight_seen$id"$'\n'
    if [ "$section" = "in-flight" ] && [ ! -f "$(meta_path "$id")" ]; then
      warn "in-flight entry '$id' has no task record (not dispatched yet?)"
    fi
  done < "$BACKLOG"
  for id in $(in_flight_ids); do
    case "$in_flight_seen" in
      *$'\n'"$id"$'\n'*) ;;
      *) warn "task '$id' is in flight but has no backlog entry" ;;
    esac
  done
  [ "$errors" -eq 0 ] || exit 1
  log "backlog OK"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    -h | --help) usage; exit 0 ;;
    '') usage >&2; exit 1 ;;
  esac
  shift
  case "$cmd" in
    add)
      local id="" repo="" summary="" blocked_by="" reason=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --blocked-by | --reason)
            [ $# -ge 2 ] || die "$1 needs a value"
            case "$1" in
              --blocked-by) blocked_by="$2" ;;
              --reason) reason="$2" ;;
            esac
            shift
            ;;
          -*) die "unknown option '$1'" ;;
          *)
            if [ -z "$id" ]; then id="$1"
            elif [ -z "$repo" ]; then repo="$1"
            elif [ -z "$summary" ]; then summary="$1"
            else usage >&2; exit 1; fi
            ;;
        esac
        shift
      done
      [ -n "$summary" ] || { usage >&2; exit 1; }
      cmd_add "$id" "$repo" "$summary" "$blocked_by" "$reason"
      ;;
    start | remove)
      [ $# -eq 1 ] || { usage >&2; exit 1; }
      "cmd_$cmd" "$1"
      ;;
    done)
      [ $# -eq 2 ] || { usage >&2; exit 1; }
      cmd_done "$1" "$2"
      ;;
    list)
      [ $# -le 1 ] || { usage >&2; exit 1; }
      cmd_list "${1:-}"
      ;;
    unblocked | validate)
      [ $# -eq 0 ] || { usage >&2; exit 1; }
      "cmd_$cmd"
      ;;
    *) die "unknown command '$cmd' (add|start|done|remove|list|unblocked|validate)" ;;
  esac
}

main "$@"
