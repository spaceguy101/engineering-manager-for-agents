# Contributing / working on this repository

**Read this when your task is to modify this system itself** (the orchestrator,
`bin/` scripts, templates, docs, CI). If you are an agent launched here to *use*
the system, that is `AGENTS.md`'s job — and note `CLAUDE.md` is a symlink to it,
so a coding agent launched in this directory boots as the EM by default.

## Source of truth

[PRD.md](PRD.md) specifies the system; read the relevant section before
building or changing the corresponding piece. Design decisions that refine or
correct the PRD live in [docs/adr/](docs/adr/); canonical vocabulary lives in
[docs/glossary.md](docs/glossary.md) — use those terms in code, briefs, and
docs, and record new decisions/terms there.

Build order (PRD §7): all four milestones are built — M1 skeleton (see
ADR-0001 for why it was a dispatch slice), M2 supervision (watcher, guard,
recovery, lock), M3 delivery + fleet (registry, gate, local-only, PR
polling, fleet sync), M4 breadth (research, promotion, harness verification,
bootstrap, project memory). v1 is feature-complete per the PRD; changes now
follow the shared-material gate below.

## Non-negotiable invariants (PRD §4.1)

Enforced by scripts, not just prompts; every change must preserve them:

1. The EM never writes to a project (two narrow exceptions: fleet sync
   fast-forward/prune, approved `local-only` fast-forward merge).
2. Never merge a PR without the Director's explicit word (`+auto` routine
   approvals excepted; never a red PR).
3. Never tear down a worktree holding unlanded work (see ADR-0002 for the
   conservative check; `--force` only on explicit Director instruction).
4. ICs never address the Director.
5. Report outcomes faithfully, with evidence for failures.

## Toolbelt conventions

- 100% bash, macOS + Linux. Every script: `#!/usr/bin/env bash`,
  `set -euo pipefail`, and a header comment block that doubles as its help
  text (`usage()` prints it).
- **shellcheck-clean**, enforced by CI (`.github/workflows/ci.yml`). Run
  `shellcheck bin/em-*.sh bin/lib/*.sh tests/run.sh` locally if you have it.
- Shared helpers live in `bin/lib/common.sh` (path resolution, meta files,
  tmux target lookup). Scripts locate siblings via `EM_BIN`, and state roots
  via `EM_ROOT` (overridable — the test suite sandboxes state this way).
- Exit code **3** means a safety refusal (e.g. unlanded work); treat it as
  stop-and-investigate, never retry with `--force` on your own initiative.
- Runtime tuning env vars are listed in PRD §4.12; internal test seams
  (`EM_ROOT`, `EM_TMUX_SOCKET`, `EM_LAUNCH_OVERRIDE`) are documented in the
  scripts that honor them and are not Director-facing.

## Porting from firstmate

Most `bin/` scripts port one-to-one from
[firstmate](https://github.com/kunchenguid/firstmate) (`fm-*` → `em-*`, MIT,
attribution in [NOTICE](NOTICE)). Two locked replacements (PRD key scoping
decisions): `em-worktree.sh` (plain `git worktree`, no treehouse pool) and
`em-validate.sh` (M3; minimal test+lint gate, no no-mistakes). When porting,
swap treehouse calls for `em-worktree.sh` and no-mistakes hooks for
`em-validate.sh`.

## Tests

`bash tests/run.sh` — pure bash, no framework. tmux-dependent cases run on an
isolated server (`EM_TMUX_SOCKET`) and **skip** (not fail) when tmux is
missing. Every safety refusal path must have a test; the unlanded-work checks
are the flagship suite.

## Delivery of shared repo material

This repo ships behind its own gate: feature branch → shellcheck + tests green
→ PR → Director merges. While ICs are in flight, changes to shared material
(orchestrator, `bin/`, templates, skills, README) are delegated to an IC, not
hand-edited by the EM.
