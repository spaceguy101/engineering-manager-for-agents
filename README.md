# Engineering Manager for AI Agents

Talk to one agent; ship with a team. This repository turns any terminal coding
agent launched inside it into an **Engineering Manager (EM)** for a fleet of
autonomous IC (individual-contributor) agents. You — the **Director** — talk
only to the EM. The EM hires, briefs, supervises, and offboards ICs, each
running in its own tmux window against its own disposable git worktree.
Finished work comes back as ready-to-review pull requests, approved local
merges, or investigation reports.

This is not an app, harness, or CLI — it is a repository. Installing it is
cloning it. Prefer to stay inside your existing setup? The same repo also
installs as a **Claude Code plugin** with an `/em` skill — see
[Install](#install).

![The Director's view of a running fleet: status, task timeline, budgets, queue](demo/demo.gif)

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

Prerequisites: `git` (≥ 2.5), `tmux`, `jq` (task event logs and budgets), a
supported terminal coding agent (currently **Claude Code**), and the GitHub
CLI (`gh`, authenticated) for PR delivery.

```sh
git clone <this-repo> engineering-manager-for-agents
cd engineering-manager-for-agents
claude   # or your harness — the agent boots as the EM
```

Then just tell the EM what you want done and in which repo. Clone project
repositories into `projects/` (the EM can do this for you).

### As a Claude Code plugin

To adopt the EM inside an existing Claude Code setup — no repo-as-home-base
commitment — install it as a plugin:

```
/plugin marketplace add spaceguy101/engineering-manager-for-agents
/plugin install engineering-manager@engineering-manager-for-agents
```

Then invoke the `/em` skill in any session. Fleet state (projects, task
records, logs) lives in `~/em-fleet` (override with `$EM_HOME`); the
toolbelt and templates run from the installed plugin. Same scripts, same
safety rails — only the home base moves.

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
  runs in the dedicated background session). Whether new IC windows are
  surfaced into view or kept in the background is your standing call —
  `config/ic-window` records it (`ask` per dispatch, `surface` always, or
  `bg` always), and the EM asks you before the first dispatch if it is
  unset.

### Task timeline

Every task writes an append-only audit log
(`state/tasks/<project>/<task>/events.jsonl`) from brief to teardown — one
JSON event per lifecycle moment, kept after the task closes.
`bin/em-timeline.sh <task>` renders it:

```
14:32:07  task_created      (em)      kind=build  mode=gated
14:32:09  brief_written     (em)      template=brief-build.md
14:32:11  ic_spawned        (em)      harness=claude  window=em-fix-login-k3
15:01:44  gate_failed       (ic)      failed=test
15:09:30  pr_opened         (em)      url=https://github.com/o/r/pull/41
```

`--errors-only` filters to failures and stalls, `--follow` tails a running
task, `--json` is the raw stream, and `--since <iso|epoch>` bounds it. The
log is the durable record for post-mortems and dashboards; deleting it takes
an explicit `em-teardown.sh --purge-logs` (or a factory reset).

### Budgets

Every task can carry a resource envelope, so the fleet is safe to run
unattended: `--budget wall=45m,tokens=1.5M,cost=2.00` at brief or dispatch
time (units `s`/`m`/`h` and `k`/`M`). Defaults resolve task → project
(`em-project-add.sh --budget`) → global (`config/budgets.conf`: `budget=`,
`soft_pct=`, `on_exceed=`, `grace_seconds=`, `usd_per_mtok_<harness>=`) →
unlimited. The zero-cost watcher meters spend on its existing wake-ups:
wall-clock for every harness, tokens/cost wherever a meter adapter exists —
Claude Code ships one that sums usage from its local session files (no API
calls); other harnesses enforce wall-clock only and show
`tokens: unmeterable`. At 80% of any limit the task's status column turns
loud, a `budget_warning` is logged, and the IC gets a one-line wrap-up
nudge; at 100% the IC is **paused** (SIGSTOP — no work is ever destroyed)
and the EM reports with a recommendation. `--on-exceed kill|warn-only`
picks a different action, and a research task at its limit is told to
write the report now, with a grace window before the pause.

```sh
bin/em-budget.sh show <task>            # limits, live spend, %, state
bin/em-budget.sh extend <task> wall=+30m   # raise the limit, resume the IC
```

Elapsed time derives from the task's event log, so restarting the EM or the
watcher never resets the clock.

### Task queue

`data/backlog.md` is the human-readable queue (In flight / Queued / Done),
written exclusively through `bin/em-backlog.sh` so it stays as
machine-checkable and restart-proof as the rest of the fleet state: `add`
(with `--blocked-by` for work that must wait its turn), `start` at dispatch,
`done` with the durable outcome (PR URL, local merge, report path),
`unblocked` to list queued tasks whose blocker has landed, and `validate`
(line grammar, duplicate ids, cross-check against live task records).

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
skills/        the /em skill for the Claude Code plugin install
.claude-plugin/  plugin + marketplace manifests
demo/          the README demo (VHS tape + staged fixture)
data/, state/, projects/, worktrees/, config/   local, gitignored
```

## Contributing

Developing the repo itself is a distinct mode of work from running it as the
EM — see [DEVELOPMENT.md](DEVELOPMENT.md) for the conventions.

## License

MIT — see [LICENSE](LICENSE).
