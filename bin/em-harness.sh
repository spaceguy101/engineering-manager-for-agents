#!/usr/bin/env bash
# em-harness.sh — detect the harness this session runs on, and resolve the
# effective harness for a new IC.
#
# Usage:
#   em-harness.sh detect                 print claude|codex|opencode|pi|cursor|unknown
#   em-harness.sh resolve [<requested>] [--project <name>]
#                                        effective IC harness, in priority:
#                                        per-task request > per-project choice
#                                        (data/projects/<name>/harness, set at
#                                        onboarding) > config/crew-harness
#                                        > detected (unknown → claude)
#
# Detection: environment markers first, then process ancestry.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

detect() {
  if [ -n "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ]; then
    printf 'claude\n'
    return
  fi
  if [ -n "${CODEX_SANDBOX:-}${CODEX_HOME:-}" ]; then
    printf 'codex\n'
    return
  fi
  if [ -n "${OPENCODE:-}${OPENCODE_SERVER:-}" ]; then
    printf 'opencode\n'
    return
  fi
  if [ -n "${PI_SESSION:-}" ]; then
    printf 'pi\n'
    return
  fi
  if [ -n "${CURSOR_AGENT:-}" ]; then
    printf 'cursor\n'
    return
  fi

  # Walk the process ancestry looking for a known harness binary.
  local pid="$$" comm hops=0
  while [ "$pid" -gt 1 ] && [ "$hops" -lt 15 ]; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    case "${comm##*/}" in
      claude*) printf 'claude\n'; return ;;
      codex*) printf 'codex\n'; return ;;
      opencode*) printf 'opencode\n'; return ;;
      pi) printf 'pi\n'; return ;;
      cursor-agent* | agent) printf 'cursor\n'; return ;;
    esac
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
    [ -n "$pid" ] || break
    hops=$((hops + 1))
  done
  printf 'unknown\n'
}

resolve() {
  local requested="" project=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --project)
        [ $# -ge 2 ] || die "--project needs a value"
        project="$2"
        shift
        ;;
      -*) die "unknown option '$1'" ;;
      *)
        [ -z "$requested" ] || { usage >&2; exit 1; }
        requested="$1"
        ;;
    esac
    shift
  done
  if [ -n "$requested" ]; then
    printf '%s\n' "$requested"
    return
  fi
  if [ -n "$project" ]; then
    local pref
    if pref="$(project_harness "$project")"; then
      printf '%s\n' "$pref"
      return
    fi
  fi
  if [ -f "$EM_CONFIG/crew-harness" ]; then
    local override
    override="$(head -n1 "$EM_CONFIG/crew-harness" | tr -d '[:space:]')"
    if [ -n "$override" ]; then
      printf '%s\n' "$override"
      return
    fi
  fi
  local detected
  detected="$(detect)"
  if [ "$detected" = "unknown" ]; then detected="claude"; fi
  printf '%s\n' "$detected"
}

case "${1:-}" in
  detect) detect ;;
  resolve) shift; resolve "$@" ;;
  -h | --help) usage ;;
  *)
    usage >&2
    exit 1
    ;;
esac
