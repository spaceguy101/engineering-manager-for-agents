#!/usr/bin/env bash
# em-bootstrap.sh — session-start detection: report missing toolchain pieces
# (one line each, with the exact install command), GitHub auth state, a
# harness override if configured, an unset/invalid IC window policy
# (config/ic-window), and registry drift (clones without a registry line,
# malformed registry lines); then run a bounded best-effort fleet sync.
#
# Usage:
#   em-bootstrap.sh
#
# Detect → consent → install: this script only DETECTS and prints. The EM
# lists problems to the Director with a one-line purpose each, waits for
# consent, and installs only the approved set — never install anything
# without this-session approval. Silence means all good. Always exits 0
# (report-only). Fleet sync is timeout-guarded
# (EM_FLEET_SYNC_BOOTSTRAP_TIMEOUT, default 20s) and non-fatal.
set -euo pipefail
# shellcheck source=bin/lib/common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/common.sh"

install_hint() { # <package>
  if [ "$(uname -s)" = "Darwin" ]; then
    printf 'brew install %s' "$1"
  else
    printf 'sudo apt-get install -y %s (or your distro equivalent)' "$1"
  fi
}

main() {
  case "${1:-}" in -h | --help) usage; exit 0 ;; esac

  command -v tmux >/dev/null ||
    printf 'missing: tmux (IC windows) — install: %s\n' "$(install_hint tmux)"

  if ! command -v git >/dev/null; then
    printf 'missing: git (everything) — install: %s\n' "$(install_hint git)"
  else
    local gv
    gv="$(git --version | awk '{print $3}')"
    case "$gv" in
      1.* | 2.[0-4] | 2.[0-4].*)
        printf 'outdated: git %s (need >= 2.5 for worktrees) — upgrade: %s\n' "$gv" "$(install_hint git)"
        ;;
    esac
  fi

  if ! command -v gh >/dev/null; then
    printf 'missing: gh (GitHub PRs) — install: %s\n' "$(install_hint gh)"
  elif ! gh auth status >/dev/null 2>&1; then
    printf 'NEEDS_GH_AUTH — ask the Director to run: gh auth login\n'
  fi

  command -v jq >/dev/null ||
    printf 'missing: jq (task event logs + budgets) — install: %s\n' "$(install_hint jq)"

  if [ -f "$EM_CONFIG/crew-harness" ]; then
    printf 'harness-override: %s\n' "$(head -n1 "$EM_CONFIG/crew-harness" | tr -d '[:space:]')"
  fi

  # IC window policy: whether new IC windows are surfaced into view or left
  # in background is the Director's standing choice (or per-dispatch, with
  # `ask`). em-spawn.sh refuses to dispatch without it — surface it here so
  # the question is asked at session start, not mid-dispatch.
  local winpol
  if winpol="$(ic_window_policy)"; then
    case "$winpol" in
      ask | surface | bg) ;;
      *) printf 'ic-window: invalid value %s in config/ic-window — want ask|surface|bg\n' "$winpol" ;;
    esac
  else
    printf 'ic-window: unset — ask the Director how IC windows should appear (ask each dispatch | surface always | background always) and record ask|surface|bg in config/ic-window\n'
  fi

  # The harness new ICs would launch on must exist on this machine —
  # otherwise the failure surfaces mid-dispatch instead of here. Check the
  # binary the harness launches as (cursor's is agent/cursor-agent; a plain
  # `cursor` on PATH is the IDE, not the harness).
  local ic_harness ic_bin
  ic_harness="$("$EM_BIN/em-harness.sh" resolve 2>/dev/null || printf 'claude')"
  ic_bin="$(harness_binary "$ic_harness")"
  command -v "$ic_bin" >/dev/null ||
    printf 'missing: %s (the IC harness new tasks launch on) — install it or change config/crew-harness\n' "$ic_bin"

  # Registry drift: every clone needs a registry line (an unregistered
  # project cannot take build tasks — delivery modes are Director-confirmed,
  # never guessed), and existing lines must parse. Rebuilding a lost
  # registry means re-registering each project with the Director.
  local reg="$EM_DATA/projects.md" d name
  if [ -d "$EM_PROJECTS" ]; then
    for d in "$EM_PROJECTS"/*/; do
      [ -e "$d" ] || continue
      name="$(basename "$d")"
      [ -d "$EM_PROJECTS/$name/.git" ] || continue
      if [ ! -f "$reg" ] ||
        ! awk -v n="- $name [" 'index($0, n) == 1 { found = 1 } END { exit !found }' "$reg"; then
        printf 'registry: projects/%s has no registry line — re-register it: em-project-add.sh %s --desc "…"\n' "$name" "$name"
      fi
    done
  fi
  if [ -f "$reg" ]; then
    "$EM_BIN/em-project-add.sh" --validate 2>&1 >/dev/null |
      grep -v 'registry OK' | sed 's/^/registry: /' || true
  fi

  # Bounded, best-effort fleet sync; only abnormal lines surface.
  local timeout="${EM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-20}" sync
  if sync="$(run_bounded "$timeout" "$EM_BIN/em-fleet-sync.sh" 2>/dev/null)"; then
    printf '%s\n' "$sync" |
      grep -Ev '^$|up to date|fast-forwarded|fetched only' |
      sed 's/^/fleet-sync: /' || true
  else
    printf 'fleet-sync: timed out or failed (non-fatal) — investigate only if it blocks a task\n'
  fi
  exit 0
}

main "$@"
