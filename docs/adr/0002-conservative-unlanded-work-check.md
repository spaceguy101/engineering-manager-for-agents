# ADR-0002: The unlanded-work check is conservative, and scoped to the task's own refs

**Status:** Accepted (amended 2026-07-12: the clone's default branch counts as landed)
**Date:** 2026-07-12
**Deciders:** Director
**Context grilling:** M1 build session, Decision 1

## Context

Prime directive #3 ("never tear down a worktree holding unlanded work") is
enforced by `em-worktree.sh remove` / `em-teardown.sh`. Per [ADR-0001](0001-m1-is-a-dispatch-slice.md),
the first *live* teardown won't happen until M2/M3 — when a fleet already
depends on it — so this check must be trustworthy from day one even while it
is exercised only by tests. "Unlanded" needed a precise, script-enforceable
definition. Three candidate semantics were considered:

1. **Loss-prevention only** — refuse only what `git worktree remove` would
   actually destroy: uncommitted changes and commits reachable *only* from the
   worktree's detached HEAD. (Commits on a branch survive removal, since
   branch refs live in the clone.)
2. **Conservative, task-scoped** — additionally refuse when the task's own
   work is merely *unpushed*: any commit reachable from the worktree `HEAD`
   or its `em/<id>` branch that no remote ref reaches.
3. **Clone-wide** — also hunt for commits on any other local branch created
   from the worktree.

## Decision

**Option 2.** `em-worktree.sh remove` (and therefore `em-teardown.sh`) refuses
— exit code 3 — when the worktree has (a) uncommitted or untracked changes, or
(b) commits reachable from `HEAD` or `refs/heads/em/<id>` that no remote ref
reaches. `--force` is the only override, used solely on an explicit Director
instruction to discard the work.

Stricter than loss-prevention on purpose: an unpushed `em/<id>` branch
stranded in a clone nobody inspects is work lost *in practice*, even though
git keeps the ref. Teardown marks a task's end of life; nothing may silently
survive only as a local ref.

## Consequences

- **Known blind spot, accepted:** commits an IC parks on some *other* local
  branch (not `em/<id>`, not reachable from `HEAD`) are invisible to the
  check. They survive in the clone, but nothing flags them. Catching them
  would require clone-wide scans that false-positive on parallel tasks'
  branches. Briefs therefore instruct ICs to work on `em/<id>` only.
- **False refusals are acceptable and expected** (e.g. squash-merged PRs make
  branch commits look unpushed until M3's fleet sync can reconcile). A
  refusal is stop-and-investigate, never an invitation to `--force`.
- Exit code 3 is reserved fleet-wide as the safety-refusal signal.

## Amendment (2026-07-12): the clone's default branch is a landed ref

The original decision defined landed as "reachable from a remote ref". That
made every commit in a **no-remote (`local-only`) project** permanently
unlanded, and refused teardown even after work was merged into the clone's
local default branch. The landed set is therefore: **any remote ref, plus the
clone's default branch** (`origin/HEAD`'s target, or the checked-out branch
when there is no remote) — matching the glossary's "durable remote/base ref".
The default branch of a fleet clone only moves via fleet sync or an approved
`local-only` merge, so reachability from it is as durable as this system gets.
The conservative posture is unchanged: everything else still refuses.
