#!/usr/bin/env bash
# common.sh — shared helpers for the em-* toolbelt. Source, don't execute.
#
# Exposes:
#   EM_BIN         directory holding the em-* scripts (this install)
#   EM_ROOT        fleet root holding data/ state/ projects/ worktrees/;
#                  defaults to the repo containing EM_BIN. Overriding it via
#                  the EM_ROOT env var relocates all fleet state (the test
#                  suite sandboxes itself this way).
#   EM_DATA EM_STATE EM_PROJECTS EM_WORKTREES EM_TEMPLATES
#   log/warn/die   stderr messaging; die exits 1
#   die_refuse     safety refusal; exits 3 — treat as stop-and-investigate
#   usage          print the calling script's header comment block
#   require_id     validate a task id (kebab slug, e.g. fix-login-k3)
#   window_name    canonical tmux window name for a task: em-<id>
#   harness_binary executable a harness launches as (cursor → agent)
#   tmux_cmd       tmux, honoring EM_TMUX_SOCKET (test isolation seam)
#   inside_tmux    running inside a usable tmux session
#   create_task_window   new detached window for a task, in the current
#                        session or the dedicated 'em' session
#   find_window    print a tmux target for a task's window, in any session
#   meta_path/meta_get/meta_set   accessors for state/<id>.meta (key=value)
#   default_branch       resolve origin's default branch name for a clone
#   mtime                file modification epoch (portable macOS/Linux)
#   run_bounded          run a command with a kill-after timeout (no GNU
#                        timeout dependency)
#   in_flight_ids        ids of every task with a state/<id>.meta record

# shellcheck disable=SC2034  # path vars are consumed by the sourcing scripts

EM_BIN="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
EM_ROOT="${EM_ROOT:-$(cd -- "$EM_BIN/.." && pwd -P)}"
EM_DATA="$EM_ROOT/data"
EM_STATE="$EM_ROOT/state"
EM_PROJECTS="$EM_ROOT/projects"
EM_WORKTREES="$EM_ROOT/worktrees"
EM_CONFIG="$EM_ROOT/config"
EM_TEMPLATES="$(cd -- "$EM_BIN/.." && pwd -P)/templates"

log() { printf '%s\n' "$*" >&2; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Safety refusal (distinct from ordinary errors): exit 3. Callers seeing exit 3
# must stop and investigate, never retry with --force on their own initiative.
die_refuse() {
  printf 'REFUSED: %s\n' "$*" >&2
  exit 3
}

# Print the calling script's header comment block (self-documentation).
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

require_id() {
  case "${1:-}" in
    '' | -* | *- | *[!a-z0-9-]*)
      die "invalid task id '${1:-}' — want a kebab slug like fix-login-k3"
      ;;
    projects)
      die "task id 'projects' is reserved — data/projects/ holds per-project memory"
      ;;
  esac
}

window_name() {
  printf 'em-%s\n' "$1"
}

# harness_binary <harness> — the executable a harness launches as. Only
# cursor's differs from the harness name: current installs ship `agent`,
# older ones `cursor-agent` (never `cursor` — that's the IDE launcher).
harness_binary() {
  case "$1" in
    cursor)
      if command -v cursor-agent >/dev/null 2>&1; then
        printf 'cursor-agent\n'
      else
        printf 'agent\n'
      fi
      ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# tmux, on the isolated test socket when EM_TMUX_SOCKET is set (test-only seam).
tmux_cmd() {
  if [ -n "${EM_TMUX_SOCKET:-}" ]; then
    command tmux -L "$EM_TMUX_SOCKET" "$@"
  else
    command tmux "$@"
  fi
}

# Inside a usable tmux session? (The test socket seam never counts as inside:
# $TMUX points at the real server, not the isolated test one.)
inside_tmux() {
  [ -n "${TMUX:-}" ] && [ -z "${EM_TMUX_SOCKET:-}" ]
}

# create_task_window <win> <dir> — new detached window named <win> starting
# at <dir>, in the current session, or in a dedicated 'em' session when
# running outside tmux.
create_task_window() {
  local win="$1" dir="$2"
  if inside_tmux; then
    tmux_cmd new-window -d -n "$win" -c "$dir"
  else
    tmux_cmd has-session -t '=em' 2>/dev/null ||
      tmux_cmd new-session -d -s em -c "$EM_ROOT"
    tmux_cmd new-window -d -t '=em:' -n "$win" -c "$dir"
  fi
}

# Print "<session_id>:<window_index>" for a task's window, searching all
# sessions (the window lives in the EM's session or the dedicated 'em' one).
# Fails silently (status 1) when the window does not exist.
find_window() {
  local name out
  name="$(window_name "$1")"
  out="$(tmux_cmd list-windows -a -F '#{window_name}|#{session_id}:#{window_index}' 2>/dev/null |
    awk -F '|' -v n="$name" '$1 == n { print $2; exit }')"
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}

meta_path() {
  printf '%s/%s.meta\n' "$EM_STATE" "$1"
}

# meta_get <id> <key> — print the value recorded in state/<id>.meta, or fail.
meta_get() {
  local file
  file="$(meta_path "$1")"
  [ -f "$file" ] || return 1
  awk -v k="$2" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$file"
}

# meta_set <id> <key> <value> — rewrite (or append) one key in state/<id>.meta.
meta_set() {
  local file tmp
  file="$(meta_path "$1")"
  [ -f "$file" ] || return 1
  tmp="$file.tmp.$$"
  awk -v k="$2" -v v="$3" '
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# mtime <file> — modification time as epoch seconds (BSD and GNU stat).
mtime() {
  stat -f %m -- "$1" 2>/dev/null || stat -c %Y -- "$1" 2>/dev/null
}

# run_bounded <seconds> <cmd…> — run a command, killing it after <seconds>.
# Returns the command's status (or the kill status on timeout).
run_bounded() {
  local secs="$1" pid watchdog rc=0
  shift
  "$@" &
  pid=$!
  (
    sleep "$secs"
    kill "$pid" 2>/dev/null
  ) &
  watchdog=$!
  wait "$pid" || rc=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null || true
  return "$rc"
}

# in_flight_ids — print the id of every task with a meta record, one per line.
in_flight_ids() {
  local f
  for f in "$EM_STATE"/*.meta; do
    [ -f "$f" ] || continue
    f="${f##*/}"
    printf '%s\n' "${f%.meta}"
  done
}

# default_branch <repo-dir> — name of origin's default branch (e.g. "main").
# Falls back to asking the remote when origin/HEAD is unset locally. For a
# repo with no origin remote (local-only projects), falls back to the clone's
# checked-out branch — only call this on the clone itself, never a worktree
# (a worktree's HEAD is the task branch, not the default).
default_branch() {
  local repo="$1" ref
  if ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD)"; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    git -C "$repo" symbolic-ref --quiet --short HEAD
    return
  fi
  if git -C "$repo" remote set-head origin --auto >/dev/null 2>&1 &&
    ref="$(git -C "$repo" symbolic-ref --quiet --short refs/remotes/origin/HEAD)"; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  return 1
}
