# ADR-0001: M1 is a dispatch slice, not an end-to-end loop

**Status:** Accepted
**Date:** 2026-07-12
**Deciders:** Director
**Context grilling:** Decision 1

## Context

The PRD (§7) sequences the build as M1→M4. M1 lists `em-teardown.sh` among its scripts and the prime directives require "never tear down a worktree holding unlanded work" and "tear down only after merge/report confirmed." But M1 deliberately omits the machinery that would *confirm a merge*:

- no watcher (`em-watch.sh`, M2),
- no merge polling (`em-pr-check.sh`, M3),
- delivery is `direct-PR` only: the IC pushes and opens the PR itself, then reports `done: PR <url>` and stops.

So in M1 a task ends with a PR open on GitHub and **no mechanism can tell the EM it merged.** If teardown required confirmed-merge, worktrees and windows would accumulate with no way to clean up.

## Decision

**M1 is a dispatch slice, not a task loop.** The live M1 flow is: brief → spawn → supervise-by-peek → **PR open, full stop.** There is no live teardown of merged work in M1.

- `em-teardown.sh` still ships in M1 (per PRD §7) but is exercised **only by the test suite**, never against a real merged PR.
- Real cleanup / merge-detection is deferred to M2 (watcher) and M3 (`em-pr-check`).

## Consequences

- The plan's language "smallest end-to-end loop" is corrected to "smallest **dispatch** slice." M1 is a one-way pipe.
- Plan verification step 4 (manual E2E "ending in `em-teardown`") is corrected: the live demo ends at "PR is open"; teardown is validated only in tests.
- Because the first *live* teardown won't occur until M2/M3 — when a fleet already depends on it — the unlanded-work safety check must be trustworthy from the start even though it's test-only now. This directly motivates [ADR-0002](0002-conservative-unlanded-work-check.md).
- New glossary term: **dispatch slice**.
