# CODEX.md — running ICs on the codex harness

Field notes from verifying and operating **codex** (OpenAI's `codex-cli`) as
an IC harness in this system. This is a companion to the "Harness adapters"
section in `CLAUDE.md`: that file holds the canonical per-harness notes; this
file records the concrete problems hit while bringing codex online and the
solution for each, so the next person setting up (or debugging) a codex IC has
the full picture in one place.

Verified end-to-end on this machine on 2026-07-19 with `codex-cli` v0.144.x.
Codex is listed in `config/verified-harnesses`.

## TL;DR launch contract

- **Launch command:** `codex --dangerously-bypass-approvals-and-sandbox`
  (already wired into `em-spawn.sh` `harness_cmd`).
- **Trust dialog:** every spawn shows one — accept with
  `em-send <id> --key Enter`.
- **Interrupt key:** `Escape` (`em-send <id> --key Escape`).
- **Busy indicator:** `Working (<n>s • esc to interrupt)` — matches the
  default `EM_BUSY_REGEX` out of the box.
- **No turn-end hook** (non-claude) — lean on heartbeat + peek for stale
  detection.

## Problems faced and solutions

### 1. Auth is separate and must be done by the Director

**Problem.** A fresh codex install reports `Not logged in`. Codex auth is
user-level and completely separate from the Cursor/VS Code IDE or from the
`claude` login. An IC launched before auth is settled would sit at a login
wall instead of working.

**Solution.** The Director authenticates once per machine, interactively:
`codex login` (ChatGPT / browser flow). The EM cannot do this on their
behalf. Verify with `codex login status` or the broader `codex doctor`
(diagnoses install, config, auth, and runtime health). Auth persists across
sessions, so this is a one-time setup step.

### 2. Codex is an unverified adapter — dispatch is blocked until a trial passes

**Problem.** `em-spawn.sh` refuses any non-`claude` harness that is not listed
in `config/verified-harnesses` (`Never dispatch on an unverified adapter`).
The Director confirming codex "works" interactively is not sufficient: it
proves the CLI runs by hand, not that the *dispatch path* works (window +
worktree + brief + status reporting under EM supervision).

**Solution.** Run one supervised verification trial, then record the result:

1. Create a disposable scratch git repo, register it `local-only`, and write a
   trivial harmless brief (e.g. "add one file with one line").
2. Launch through the sanctioned escape hatch so spawn's verified-harness
   check is bypassed for the trial only:
   `EM_LAUNCH_OVERRIDE="codex --dangerously-bypass-approvals-and-sandbox" \
    bin/em-spawn.sh <id> <scratch-repo> codex --surface --budget wall=20m`
3. Supervise closely: confirm the trust dialog is handled, the brief is read,
   the branch is created, the change is made, and `starting:` / `done:` status
   lines arrive in `state/<id>.status`.
4. On a clean pass, append `codex` to `config/verified-harnesses` (one name
   per line). From then on plain
   `bin/em-spawn.sh <id> <repo> codex` works with no override.

In our trial codex did all of the above correctly, including following the
status protocol verbatim.

### 3. Workspace-trust dialog on *every* spawn

**Problem.** On launch codex prompts:

```
Do you trust the contents of this directory? ...
  1. Yes, continue
  2. No, quit
```

This is not a first-run-only dialog — a fresh worktree is always an untrusted
directory, so it appears on **every** spawn. The IC does nothing until it is
answered. Note the prompt says trust will apply to the *repository root*, not
the worktree subdirectory, which can look surprising in a peek.

**Solution.** The default selection is `1. Yes, continue`, so
`em-send <id> --key Enter` accepts it. Spawn's ~5s post-launch check now
recognises this prompt: its trust-dialog matcher was widened to cover codex's
"Do you trust the contents of this directory?" wording (it previously matched
only claude's "trust the files" and cursor's "Workspace Trust Required", so
codex trust dialogs slipped through). Still `em-peek.sh <id>` shortly after
spawn as a backstop — the single post-launch look can miss a dialog that
paints a beat later.

### 4. Sandbox / approval flags — why we bypass both

**Problem.** By default codex sandboxes model-generated shell commands and
asks for approval before running them. An IC working in an isolated worktree
needs to freely create files, run `git`, and run the gate; per-command
approval prompts would stall it and sandboxing can block legitimate writes.

**Solution.** The adapter launches with
`--dangerously-bypass-approvals-and-sandbox`, which skips both. This is
appropriate here because the **worktree is the isolation boundary**: the IC
is confined to a disposable worktree and cannot touch the read-only project
clone or anything outside it. If you ever want a lighter touch, the finer-
grained equivalent is `--sandbox workspace-write --ask-for-approval never`
(writable workspace, no approval prompts) — but the current bypass matches how
`claude` runs with `--dangerously-skip-permissions`.

### 5. No turn-end hook — weaker stale detection

**Problem.** The push-based turn-end signal (`state/<id>.turn-ended`, touched
by a Stop hook) is **claude-only**. Codex can finish a turn silently without
tripping the turn-end guard, so an IC that stops without reporting is not
caught by the push path.

**Solution.** Fall back to the pull path, exactly as documented for every
non-claude harness: lean on the watcher's `heartbeat` and on `em-peek.sh`.
The status protocol itself works fine on codex (it appended its `starting:`
and `done:` lines correctly), so status lines plus periodic heartbeats are the
supervision backbone. Do not expect `stale` detection to be as tight as with
claude.

### 6. Busy / idle classification — confirmed working

**Problem (checked, not a blocker).** `em-status.sh` classifies a pane as busy
by matching `EM_BUSY_REGEX` (default
`esc to interrupt|Running +[0-9]+ tokens`). A new harness can show a different
working indicator and be misclassified as idle.

**Finding.** A working codex pane shows `Working (<n>s • esc to interrupt)`.
That contains `esc to interrupt`, so the **default regex already matches** —
codex busy/idle detection works with no configuration change. No override
needed today.

### 7. Version drift and auto-update

**Problem.** Codex auto-updates itself. We observed v0.139.0 on `PATH` in one
shell and v0.144.6 in the Director's interactive shell at the same time. A TUI
text change across versions could silently break the busy/idle regex (item 6)
or shift dialog wording (item 3).

**Solution.** If busy/idle classification or dialog handling starts looking
wrong for codex panes, re-check the live indicator with `em-peek.sh` and, if
needed, update `EM_BUSY_REGEX`. `codex --version` and `codex doctor` report the
running build.

### 8. Interrupt and relaunch mechanics

- **Interrupt:** `Escape` (the pane literally shows `esc to interrupt` while
  working). Use `em-send <id> --key Escape` before a corrective line.
- **Relaunch:** `em-relaunch.sh` replays the recorded fresh launch command
  (brief + appended progress note) in the existing window and worktree, the
  same recovery contract as every harness. Codex ships `resume` / `fork`
  subcommands, but the system does not use them — brief-plus-note is the
  recovery contract.

## Quick reference

| Concern            | codex                                                     |
| ------------------ | --------------------------------------------------------- |
| Launch command     | `codex --dangerously-bypass-approvals-and-sandbox`        |
| Auth               | `codex login` (Director, once per machine)                |
| Auth check         | `codex login status` / `codex doctor`                     |
| Trust dialog       | every spawn; accept with `--key Enter` (default = Yes)    |
| Interrupt          | `Escape` (`--key Escape`)                                  |
| Busy indicator     | `Working (<n>s • esc to interrupt)` (default regex works) |
| Turn-end hook      | none (non-claude) — heartbeat + peek                      |
| Verified list      | add `codex` to `config/verified-harnesses` after a trial  |
