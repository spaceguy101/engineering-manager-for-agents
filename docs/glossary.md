# Glossary — ubiquitous language

The shared vocabulary of this system. Terms here are canonical; use them consistently in code, briefs, prompts, and docs. Sourced from [PRD.md](../PRD.md) §3 and refined during design grilling.

## Roles
- **Director** — the human user. The only human in the loop; makes decisions, approves merges, watches when curious. Talks *only* to the EM.
- **EM (Engineering Manager)** — the single agent the Director talks to. Delegates all project work; **never writes to a project** (two narrow exceptions). Driven entirely by `AGENTS.md`.
- **IC (Individual Contributor)** — an autonomous agent spawned per task, one tmux window + one disposable worktree each. **Never addresses the Director**; all communication routes through the EM.

## Work items
- **Build task** — deliverable is a *change* to a project; ships via the project's delivery mode. Default task shape.
- **Research task** — deliverable is *knowledge* (investigation, plan, repro, audit); ends in `data/<id>/report.md`, never a PR. (M4.)
- **Task id** — short kebab slug + random suffix, e.g. `fix-login-k3`. Namespaces the window, worktree, brief, and state files.
- **Brief** — per-task instruction file (`data/<id>/brief.md`) that is the IC's contract: branch setup, status protocol, delivery rules, definition of done.

## Delivery
- **Delivery mode** — per-project setting for how finished work lands: **`gated`** (default; IC must pass the test+lint gate, then PR → Director merge — M3), **`direct-PR`** (IC pushes + opens PR, no gate — M1), **`local-only`** (local branch, EM reviews + fast-forward merges on approval — M3).
- **Gate** — the test+lint check (`em-validate.sh`) an IC must pass before delivering in `gated` mode. (M3.)
- **Autonomy flag (`+auto`)** — optional per-project flag letting the EM make routine approval calls itself; destructive/irreversible/security-sensitive decisions still escalate. Default off. (M3.)
- **Landed** — work that exists on a durable remote/base ref (pushed branch, merged commit) and therefore survives worktree destruction.
- **Unlanded work** — work that exists *only* locally in a worktree: uncommitted/untracked changes, or commits reachable from the worktree `HEAD` or its `em/<id>` branch that no landed ref (remote ref, or the clone's default branch) reaches. Teardown must refuse to destroy it (prime directive #3; scope and blind spots in [ADR-0002](adr/0002-conservative-unlanded-work-check.md)).

## Execution & isolation
- **Worktree** — a disposable `git worktree` under `worktrees/<id>/`, detached at the fetched default branch, where one IC does its work. Plain `git worktree` (no pool).
- **Window** — the tmux window for a task, always named `em-<id>`. The Director can watch or type into it directly at any time.
- **Harness / adapter** — the terminal agent program an EM or IC runs on (claude, codex, opencode, pi). An *adapter* = launch mechanics (in `em-spawn.sh`) + supervision knowledge (in `AGENTS.md`). M1 supports **claude only**.

## Supervision (M2+)
- **Watcher** — background bash process (`em-watch.sh`) that sleeps on the fleet at zero token cost and wakes the EM with exactly one reason line: `signal | stale | check | heartbeat`.
- **Heartbeat** — periodic mandatory full-fleet review wake, with exponential backoff while idle.
- **Guard / beacon** — liveness mechanism: watcher touches a beacon file each poll; `em-guard.sh` warns if tasks are in flight but the beacon is stale.
- **Session lock** — single-EM-per-machine lock (`em-lock.sh`).

## Lifecycle operations
- **Spawn** — create window + worktree + turn-end hook + meta, launch the IC with its brief (`em-spawn.sh`). Its hook-install writes are sanctioned *spawn provisioning*, distinct from "the EM writing to a project" ([ADR-0003](adr/0003-spawn-provisioning-writes.md)).
- **Teardown** — return the worktree and kill the window (`em-teardown.sh`); refuses on unlanded work; keeps `data/<id>/`.
- **Fleet sync** — fetch clones, clean fast-forward default branches, prune gone branches (`em-fleet-sync.sh`). M3.
- **Promotion** — convert a research task in place into a protected build task (`em-promote.sh`). M4.

## Coined during design
- **Dispatch slice** — the M1 subset: brief → spawn → supervise-by-peek → *PR open, full stop*. A one-way pipe, **not** a full task loop; live teardown and merge-detection arrive in M2/M3. (See [ADR-0001](adr/0001-m1-is-a-dispatch-slice.md).)
