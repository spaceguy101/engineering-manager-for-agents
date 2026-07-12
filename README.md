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
- **Harnesses** — Claude Code verified out of the box; codex/opencode/pi
  dispatch only after a supervised per-machine verification trial.

See [PRD.md](PRD.md) for the full specification and [docs/adr/](docs/adr/)
for design decisions.

## Repository layout

```
AGENTS.md      the EM's instructions (CLAUDE.md symlinks to it)
bin/           the toolbelt the EM drives
templates/     IC brief scaffolds
docs/          glossary + architecture decision records
tests/         pure-bash test suite
data/, state/, projects/, worktrees/, config/   local, gitignored
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — note that an agent launched in this
repo becomes the EM, so repo development has its own workflow.

## License

MIT — see [LICENSE](LICENSE). Ports code from
[firstmate](https://github.com/kunchenguid/firstmate) (MIT); see
[NOTICE](NOTICE).
