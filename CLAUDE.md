# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Current state

This repo is greenfield: only [PRD.md](PRD.md) exists. Everything below describes the system that PRD.md specifies and that this repo is being built to become. When implementing, PRD.md is the source of truth — read the relevant section before building the corresponding piece.

## What this repo is

Not an app, harness, skill, or CLI. It is a **repository** that turns any terminal coding agent launched inside it into an "Engineering Manager" (EM) for a fleet of autonomous IC (individual-contributor) agents. Install = `git clone` + launch your agent harness in the directory.

- **Director** — the human user. Talks only to the EM.
- **EM** — the single agent the Director talks to. Delegates all project work; **never edits projects itself**.
- **IC** — an autonomous agent spawned per task, each in its own tmux window (`em-<id>`) against its own disposable `git worktree`.

The behavior of the EM is defined entirely by a prompt file (`AGENTS.md`, with `CLAUDE.md` symlinked to it), not by code. The `bin/` scripts are the levers that prompt drives.

## Architecture

Three planes, deliberately separated:

1. **Orchestrator prompt** — `AGENTS.md` (the EM's instructions; edit like any prompt). Harness-specific supervision knowledge (busy-pane regex, interrupt keys, trust-dialog quirks) lives here as documentation; harness *mechanics* (launch command, hooks) live in `em-spawn.sh`.
2. **`bin/` toolbelt** — small, composable, shellcheck-clean bash scripts (see PRD §4.11 for the full table). Committed. The EM never touches project code directly; it acts only through these scripts.
3. **On-disk state** — the system is restart-proof because **disk + tmux are truth; conversation memory is a cache.** Killing and relaunching the EM must be a non-event (bootstrap → recovery reconciles reality with records).
   - `data/` — personal fleet records: `backlog.md`, `director.md`, `projects.md`, `<id>/brief.md`, `<id>/report.md` (gitignored).
   - `state/` — volatile runtime signals: `<id>.status`, `<id>.meta`, `<id>.turn-ended`, `<id>.check.sh`, watcher internals (gitignored).
   - `projects/` — cloned repos, flat, **READ-ONLY to the EM** (gitignored).
   - `config/crew-harness` — IC harness override (gitignored).

Committed vs. local: the orchestrator, README, `.github/workflows/`, `.agents/skills/` (`.claude/skills` symlinks here), and `bin/` are git-tracked. `data/`, `state/`, `projects/`, `config/` are gitignored personal state.

## Non-negotiable invariants (PRD §4.1)

These are enforced by scripts, not just prompt, and any change must preserve them:

1. **The EM never writes to a project.** Only two exceptions: fleet sync (clean fast-forward + safe branch prune) and the approved `local-only` fast-forward merge. Project `AGENTS.md` files are written **only by ICs** through the delivery pipeline.
2. **Never merge a PR without the Director's explicit word** (except routine approvals on `+auto` projects; never a red PR even under `+auto`).
3. **Never tear down a worktree holding unlanded work.** `em-teardown.sh` enforces this; treat a refusal as stop-and-investigate, never `--force` without explicit Director instruction to discard.
4. **ICs never address the Director.** All communication routes through the EM.
5. **Report outcomes faithfully**, with evidence for failures.

## Two things intentionally NOT built (locked scoping decisions)

The project is modeled on [firstmate](https://github.com/kunchenguid/firstmate) and ports its `bin/` scripts one-to-one (`fm-*` → `em-*`, MIT attribution preserved). Two pieces are replaced with simpler in-house versions:

- **`em-validate.sh`** replaces firstmate's external `no-mistakes`. It is a minimal **test + lint gate only** — runs the project's configured test and lint commands in the IC's worktree, exits non-zero on failure. No structured review findings, risk labels, or evidence DBs.
- **`em-worktree.sh`** replaces firstmate's `treehouse` pool. Plain `git worktree add --detach` / `remove` / `prune`, no pooling.

Every other `bin/` script is a direct port; when porting, swap `treehouse` calls for `em-worktree.sh`/raw `git worktree` and `no-mistakes` hooks for `em-validate.sh`.

## Delivery modes (per project, PRD §4.6)

Chosen at project-add time; default `gated`. Faster modes and `+auto` only on explicit Director say-so.

- **`gated`** (default) — IC runs `em-validate.sh` until the test+lint gate is green, *then* pushes and opens the PR → Director merges. A `gated` project with no confirmed gate commands cannot dispatch build tasks. Gate commands are recorded in the `data/projects.md` registry line (auto-detected + Director-confirmed at add time), read via `em-project-mode.sh`.
- **`direct-PR`** — IC pushes and opens the PR itself; no gate.
- **`local-only`** — no remote/PR; IC stops at "ready in branch", EM reviews (`em-review-diff.sh`), Director approves, EM fast-forward merges (`em-merge-local.sh`, refuses anything but a clean fast-forward).

## Task lifecycle

Build task (default) → change delivered via mode. Research task (`--research`, triggered by "what's wrong", "how would we", "find out why") → ends in `data/<id>/report.md`, never a PR. Flow: intake (resolve project first, classify shape + readiness) → `em-brief.sh` → `em-spawn.sh` → supervise → validate (gated) → PR/local/report → `em-teardown.sh` (only after merge/report confirmed). Research can be promoted to a protected build task in place via `em-promote.sh`. Task ids are short kebab slugs with a random suffix (`fix-login-k3`); tmux window is always `em-<id>`.

## Supervision (PRD §4.8) — the watcher is the backbone

Whenever ≥1 task is in flight, `em-watch.sh` runs in the background at **zero token cost** and exits with exactly one reason line: `signal | stale | check | heartbeat`. Restart it after handling every wake and before ending any turn. Handle wakes cheapest-first: `signal` → read status files; `stale` → `em-peek.sh` the pane; `check` → per-task slow poll fired; `heartbeat` → mandatory full-fleet review. Liveness is guarded by a beacon file + `em-guard.sh` (called first by every supervision script). Never foreground-block while tasks are in flight — background long work so wakes interleave.

## Conventions

- **Toolbelt is 100% bash, shellcheck-clean (CI-enforced via `.github/workflows/`), each script self-documenting via a header.** Platforms: macOS + Linux only.
- **This repo ships behind its own gate:** shared repo material (orchestrator, `bin/`, skills, README) is delivered `gated` (feature branch, shellcheck + script smoke tests, PR, Director merge). When ICs are in flight, changes to shared material are **delegated to an IC**, not hand-edited.
- **Director-facing language describes outcomes, never internal machinery** (no watcher, heartbeat, worktree, brief, task id, harness, mode, teardown, session lock). Translate, don't expose. Always full clickable `https://…` PR URLs, never bare `#number`.
- **Runtime tuning via env vars** (PRD §4.12): `EM_POLL=15`, `EM_HEARTBEAT=600`, `EM_HEARTBEAT_MAX=7200`, `EM_CHECK_INTERVAL=300`, `EM_CHECK_TIMEOUT=30`, `EM_GUARD_GRACE=300`, `EM_SIGNAL_GRACE=30`, `EM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=20`, `EM_FLEET_PRUNE=1`, `EM_BUSY_REGEX`.
- **Harness adapters** at parity: claude, codex, opencode, pi. **Never dispatch on an unverified adapter** — verify via a supervised trivial trial task first, then record its mechanics/knowledge.

## Build order (PRD §7)

M1 skeleton (layout, orchestrator v1, `em-worktree`/`em-brief`/`em-spawn`/`em-send`/`em-peek`/`em-teardown`, claude harness, `direct-PR` only) → M2 supervision (`em-watch`, `em-guard`, backlog, recovery + lock) → M3 delivery + fleet (registry, `em-validate` + `gated`, `local-only`, `em-pr-check`, fleet sync, `+auto`) → M4 breadth (research + promotion, project-memory contract, remaining harnesses, bootstrap installs, CI, docs).
