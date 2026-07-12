# ADR-0003: Spawn provisioning writes are not "the EM writing to a project"

**Status:** Accepted
**Date:** 2026-07-12
**Deciders:** Director
**Context grilling:** M1 build session, Decision 2

## Context

Prime directive #1 forbids the EM from writing to anything under `projects/`
or any worktree, and PRD §4.1 names "exactly two" exceptions (fleet-sync
fast-forward/prune, approved `local-only` merge). But installing the IC
turn-end hook requires two writes at spawn time:

1. `<worktree>/.claude/settings.local.json` — the Stop hook that touches
   `state/<id>.turn-ended`.
2. One idempotent pattern append (`.claude/settings.local.json`) to the
   project clone's shared `.git/info/exclude`, so the hook file can never
   leak into a commit or PR.

The alternative — passing hooks via a `claude --settings` launch flag, leaving
the worktree pristine — was rejected: unproven for hooks in this context, and
M2's stuck-IC relaunches would depend on perfectly reconstructing a flag
payload instead of a file already in place.

## Decision

These two writes are **spawn provisioning**: harness mechanics executed only
by `em-spawn.sh`, before the IC starts, in the IC's own workspace, touching
only agent-harness configuration and git *metadata* — never project content,
never anything git-tracked. They do not count against directive #1's
exception list, which governs the EM acting on *project content*. The EM
never performs these writes free-hand; they exist solely inside the spawn
script.

## Consequences

- Future harness adapters (M4) may add equivalent provisioning writes in
  `em-spawn.sh` under the same sanction; anything beyond harness config or
  git metadata still needs its own decision.
- The exclude append is visible clone-wide (shared `info/exclude`); the
  pattern is scoped to exactly the hook filename, so it is inert for the
  clone and other worktrees.
