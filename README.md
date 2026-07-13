# Engineering Manager for AI Agents

Talk to one agent; ship with a team. This repository turns any terminal coding
agent launched inside it into an **Engineering Manager (EM)** for a fleet of
autonomous IC (individual-contributor) agents. You — the **Director** — talk
only to the EM. The EM hires, briefs, supervises, and offboards ICs, each
running in its own tmux window against its own disposable git worktree.
Finished work comes back as ready-to-review pull requests, approved local
merges, or investigation reports.

This is not an app, harness, skill, or CLI — it is a repository. Installing it
is cloning it.

## Why

**The problem.** Running one coding agent is easy. The moment you want three or
more project tasks running in parallel — bug fixes, investigations, plans,
audits — you become a tab-juggler: babysitting sessions, copy-pasting context
between repos, and forgetting which terminal had the failing test. There is no
supervision layer, no isolation between parallel tasks, and no single place
where outcomes surface.

**The solution.** An Engineering Manager (EM) for AI agents: you — the
Director — talk to exactly one agent, the EM. The EM never writes project code
itself. It hires, briefs, supervises, and offboards a team of autonomous IC
(individual contributor) agents, each running in its own tmux window against
its own disposable git worktree. Finished work comes back to you as
ready-to-review PRs, approved local merges, or standalone investigation
reports.

## Install

Prerequisites: `git` (≥ 2.5), `tmux`, a supported terminal coding agent
(currently **Claude Code**), and the GitHub CLI (`gh`, authenticated) for PR
delivery.

```sh
git clone <this-repo> engineering-manager-for-agents
cd engineering-manager-for-agents
claude   # or your harness — the agent boots as the EM
```

Then just tell the EM what you want done and in which repo. Clone project
repositories into `projects/` (the EM can do this for you).

## How it works

- **You (Director)** make decisions, approve merges, and can watch or type
  into any IC's tmux window at any time.
- **The EM** never edits project code itself. It briefs an IC per task, spawns
  it in an isolated `git worktree` (parallel tasks on the same repo cannot
  collide), supervises it, and reports outcomes.
- **Safety is script-enforced**, not just prompted: the EM is read-only over
  `projects/`, never merges without your word, and teardown refuses to destroy
  work that hasn't landed on a remote.
- All durable state lives on disk (`data/`, `state/`) — killing and
  relaunching the EM is a non-event.
- **Per-project memory and knowledge base:** the EM keeps what it learns
  about each project in `data/projects/<name>/memory.md`, and you can drop
  architecture docs and standing instructions into
  `data/projects/<name>/kb/` (or hand them to the EM to file) — every IC
  brief for that project lists those docs as required reading.
- **Visibility without asking:** `bin/em-status.sh` prints a one-screen fleet
  overview and `bin/em-dashboard.sh` is its live, self-refreshing version —
  both read-only and safe for the Director to run in any terminal. To watch
  an IC work, attach to its tmux window (`tmux attach -t em` when the fleet
  runs in the dedicated background session).

## Status

**v1 is feature-complete** (all four PRD milestones):

- **Dispatch** — brief → isolated worktree + tmux window → IC works → ships.
- **Supervision** — a zero-token background watcher wakes the EM on status
  signals, silent stalls, merge events, and periodic heartbeats; an idle
  fleet costs nothing. Restart-proof recovery and a single-session lock.
- **Delivery modes** — `gated` (test+lint gate, then PR), `direct-PR`, and
  `local-only` (EM reviews, Director approves, fast-forward merge). Merge
  polling and fleet sync (fetch, fast-forward, safe branch pruning).
- **Research tasks** — investigations end in a report, never a PR, and can
  be promoted in place into protected build tasks.
- **Harnesses** — Claude Code verified out of the box; codex/opencode/pi/
  cursor (the Cursor agent CLI) dispatch only after a supervised per-machine
  verification trial.

## Repository layout

```
AGENTS.md      the EM's instructions (CLAUDE.md symlinks to it)
bin/           the toolbelt the EM drives
templates/     IC brief scaffolds
tests/         pure-bash test suite
data/, state/, projects/, worktrees/, config/   local, gitignored
```

## Contributing

Note that a coding agent launched in this repo boots as the EM by default, so
developing the repo itself is a distinct mode of work. When your task is to
modify the system (the `bin/` toolbelt, `AGENTS.md`, templates, CI), a few
conventions apply:

- **Toolbelt:** 100% bash, macOS + Linux. Every script uses
  `#!/usr/bin/env bash`, `set -euo pipefail`, and a header comment that
  doubles as its `--help` text. Scripts are **shellcheck-clean**, enforced by
  CI (`.github/workflows/ci.yml`). Shared helpers live in `bin/lib/common.sh`.
  Exit code **3** always means a safety refusal — stop and investigate, never
  retry with `--force` on your own initiative.
- **Tests:** `bash tests/run.sh` — pure bash, no framework. tmux-dependent
  cases run on an isolated server and skip (not fail) when tmux is missing.
  Every safety-refusal path has a test; the unlanded-work checks are the
  flagship suite.
- **Shared material** (the orchestrator, `bin/`, templates, README) ships
  behind its own gate: feature branch → shellcheck + tests green → PR →
  merge. The invariants in `AGENTS.md` are script-enforced; every change must
  preserve them.

## License

MIT — see [LICENSE](LICENSE).
