# PRD: Engineering Manager for AI Agents

**Status:** Draft v0.3
**Inspiration:** [firstmate](https://github.com/kunchenguid/firstmate) — we aim for functional parity with that project, reframed around an "Engineering Manager" metaphor.

**Key scoping decisions (locked):**
1. **Simple built-in validation pipeline instead of no-mistakes.** firstmate's external `no-mistakes` tool is replaced by our own minimal `gated` mode: **test + lint enforcement only** — a script that runs the project's configured test and lint commands and blocks the PR until both pass. No structured review findings, risk labels, or evidence databases.
2. **Plain git worktrees, no pooling.** We use `git worktree add` / `git worktree remove` directly instead of firstmate's treehouse worktree pool. Our spawn/teardown scripts wrap these commands.
3. **The rest of the toolbelt is a direct port.** All other `bin/` helper scripts are copied/adapted from firstmate one-to-one (renamed `fm-*` → `em-*`), preserving MIT attribution.

This document describes v1 only; nothing beyond it is planned yet.

---

## 1. Overview

### 1.1 Problem

Running one coding agent is easy. The moment you want three or more project tasks running in parallel — bug fixes, investigations, plans, audits — you become a tab-juggler: babysitting sessions, copy-pasting context between repos, and forgetting which terminal had the failing test. There is no supervision layer, no isolation between parallel tasks, and no single place where outcomes surface.

### 1.2 Solution

An **Engineering Manager (EM) for AI agents**: the user (the "Director") talks to exactly one agent — the EM. The EM never writes project code itself. It hires, briefs, supervises, and offboards a team of autonomous IC (individual contributor) agents, each running in its own tmux window against its own disposable git worktree. Finished work comes back to the Director as ready-to-review PRs, approved local merges, or standalone investigation reports.

### 1.3 What this is (and is not)

This is **not** an app, an agent harness, a skill, or a CLI. It is a **repository** containing:

1. A single orchestrator instruction file (`AGENTS.md`, with `CLAUDE.md` as a symlink) that turns any terminal coding agent (Claude Code, Codex, OpenCode, pi, etc.) into the EM the moment it is launched inside the repo.
2. A `bin/` toolbelt of small, composable shell scripts the EM drives (spawn, watch, brief, teardown, etc.).
3. Local, gitignored state directories (`data/`, `state/`, `projects/`, `config/`) that make the whole system restart-proof.

The entire install is `git clone` + launch your agent harness in the directory.

### 1.4 Target user

An individual developer (the Director) who works across one or more git repositories, uses a terminal coding agent daily, has tmux and GitHub CLI available, and wants to parallelize agent work without losing control or safety.

---

## 2. Goals and Non-Goals

### 2.1 Goals

- One conversation. The Director only ever talks to the EM; the EM is the sole liaison for all software work across all projects.
- Parallel, isolated execution. Every task runs in its own tmux window and its own clean git worktree; parallel tasks on the same repo cannot collide.
- Full observability. Every IC is visible in a tmux window the Director can watch or type into at any time; the EM reconciles any manual intervention.
- Safety by construction. The EM is read-only over projects (with three narrow, explicit exceptions), never merges without approval, and never destroys unlanded work.
- Near-zero idle cost. Supervision is event-driven via a zero-token bash watcher; an idle team costs nothing.
- Restart-proof. All truth lives on disk and in tmux; killing and relaunching the EM is a non-event.
- Harness-agnostic. Works as the EM and as ICs on any verified terminal agent harness, with a documented path to verify new ones.

### 2.2 Non-Goals (v1)

- No GUI, web dashboard, or app.
- No cloud/hosted execution — everything is local (macOS / Linux).
- No multi-user / team mode — one Director, one EM session per machine (enforced by a session lock).
- No CI system of its own — it integrates with GitHub Actions / existing CI via PR checks.

---

## 3. Core Concepts and Terminology

| Concept | Description |
|---|---|
| **Director** | The human user. Makes decisions, approves merges, watches when curious. |
| **EM (Engineering Manager)** | The single agent the Director talks to. Delegates all project work; never edits projects itself. |
| **IC (Individual Contributor)** | An autonomous agent spawned per task in a tmux window + disposable worktree. Never addresses the Director directly. |
| **Build task** | Deliverable is a change to a project. Ships via the project's delivery mode (PR or local merge). (firstmate: "ship") |
| **Research task** | Deliverable is knowledge: an investigation, plan, bug repro, or audit. Ends in a report file, never a PR. (firstmate: "scout") |
| **Delivery mode** | Per-project setting for how finished work lands: `gated` (default — IC must pass the project's test + lint gate, then PR → Director merge), `direct-PR` (push + PR, no gate), or `local-only` (local branch, EM reviews + fast-forward merges on approval). |
| **Autonomy flag (`+auto`)** | Optional per-project flag: EM makes routine approval calls itself; destructive/irreversible/security-sensitive decisions still escalate. Default off. (firstmate: "+yolo") |
| **Brief** | Per-task instruction file given to an IC: task, acceptance criteria, branch/reporting/delivery contract. |
| **Watcher** | Background bash process that sleeps on the fleet and wakes the EM only when something needs it. |

---

## 4. Functional Requirements

### 4.1 The EM's prime directives (hard rules, priority order)

1. **Never write to a project.** The EM must not edit, commit to, or run state-changing commands in anything under `projects/` or any worktree. Exactly two sanctioned exceptions: (a) fleet sync — clean fast-forward of a clone's checked-out default branch to match origin plus safe pruning of local branches whose upstream is gone and no worktree needs, (b) the approved `local-only` fast-forward merge. (Our gated mode needs no in-project initialization — see §4.6 — so firstmate's third exception does not apply.) Project memory files (`AGENTS.md`) are created/updated only by ICs through the normal delivery path.
2. **Never merge a PR without the Director's explicit word**, except routine approvals on `+auto` projects (destructive/irreversible/security-sensitive items always escalate; never merge a red PR even under `+auto`; post a one-line FYI after any autonomous merge).
3. **Never tear down a worktree holding unlanded work.** The teardown script enforces this; `--force` only on explicit Director instruction to discard. Research-task worktrees are declared scratch — teardown requires only that the report exists.
4. **ICs never address the Director.** All communication flows through the EM. If the Director types into an IC's window directly, that is authoritative; the EM reconciles at the next heartbeat.
5. **Report outcomes faithfully.** Failures are reported plainly with evidence.

The EM may freely write to its own repo (backlog, briefs, state). Shared repo material (the orchestrator file, README, workflows, `bin/`, skills) is git-tracked and itself ships `gated` — feature branch, test + lint gate (shellcheck + script smoke tests), PR, Director merge; personal state (`data/`, `state/`, `config/`, `projects/`) is gitignored. When ICs are in flight, changes to shared repo material are delegated to an IC rather than hand-edited.

### 4.2 Repository layout and state

```
AGENTS.md            the orchestrator (CLAUDE.md symlinks to it)
README.md / CONTRIBUTING.md
.github/workflows/   shared CI / PR enforcement (committed)
.agents/skills/      shared skills (committed); .claude/skills symlinks here
bin/                 the toolbelt (committed)
config/crew-harness  IC harness override (local, gitignored)
data/                personal fleet records (local, gitignored)
  backlog.md         task queue, dependencies, done history
  director.md        Director's curated preferences/working style (canonical, harness-portable)
  projects.md        thin registry: one line per project — name, mode, optional +auto, description
  <id>/brief.md      per-task IC brief
  <id>/report.md     research deliverable (survives teardown)
projects/            cloned repos (gitignored, READ-ONLY for the EM)
state/               volatile runtime signals (gitignored)
  <id>.status        appended by ICs: "<state>: <note>" lines
  <id>.turn-ended    touched by turn-end hooks
  <id>.meta          window=, worktree=, project=, harness=, kind=, mode=, auto=, pr=
  <id>.check.sh      optional per-task slow poll (e.g. merged-PR check)
  .last-watcher-beat watcher liveness beacon
  (plus watcher internals: hash/count/stale/seen/heartbeat-streak files)
```

Task ids are short kebab slugs with a random suffix (e.g. `fix-login-k3`); the tmux window for a task is always `em-<id>`.

### 4.3 Bootstrap (every session start)

Detect → consent → install. Never install anything without this-session approval.

- Run `bin/em-bootstrap.sh`. It detects missing toolchain pieces (tmux, git ≥ 2.5 for worktree support, `gh` CLI, and any ported helper tools) and prints one line per problem with the exact install command; the EM lists them with a one-line purpose each, waits for consent, then installs only the approved set. Note the toolchain is deliberately small: worktree management is plain `git worktree` (no external pool tool) and the `gated` validation is our own built-in script — nothing external to install for it.
- Bootstrap also runs a bounded, best-effort fleet sync (fetch clones, clean fast-forward default branches, prune gone branches; timeout-guarded, non-fatal; pruning disable-able via env var).
- Handles: `NEEDS_GH_AUTH` (ask the Director to run `gh auth login` interactively), harness override lines (record silently), fleet-sync skips (investigate only if blocking).
- Then load `data/projects.md` (rebuild from clones if missing/stale) and `data/director.md` (preferences).
- No work is dispatched until required tools and GitHub auth are good. Silence means all good.

### 4.4 Recovery (every session start, after bootstrap)

The EM may have been killed mid-flight; reconcile reality with records before doing anything:

1. List live `em-*` tmux windows.
2. Read `data/backlog.md`, every `state/*.meta` and `state/*.status`.
3. Orphan windows (no meta): peek, identify, ask the Director if unclear.
4. Dead ICs (meta, no window): check worktree status; salvage or report.
5. Acquire the single-session lock (`bin/em-lock.sh`); if another live session holds it, report and go read-only.
6. Surface only what needs the Director (pending decisions, mergeable PRs, failures, credentials); otherwise say nothing and resume.
7. Restart the watcher.

A restart must be a non-event; conversation memory is a cache, disk + tmux are truth.

### 4.5 Harness adapters

- ICs default to the same harness the EM runs on; the Director can override globally (`config/crew-harness`) or per task ("run this one on codex").
- Each adapter = mechanics (launch command, autonomy flag, turn-end hook — lives in `em-spawn.sh`) + supervision knowledge (busy-pane regex, exit command, interrupt key, trust-dialog quirks — documented in the orchestrator file).
- Launch targets at parity: **claude, codex, opencode, pi**, each empirically verified, including per-harness quirks (trust dialogs to auto-accept, resume commands, auto-upgrade flakiness, interrupt semantics).
- **Never dispatch on an unverified adapter.** New harnesses are verified via a supervised trivial trial task using a raw-launch escape hatch, then their mechanics/knowledge get recorded and committed.
- `bin/em-harness.sh` detects the current harness (env markers, then process ancestry) and resolves the effective IC harness.

### 4.6 Project management

- All projects live flat under `projects/`. `data/projects.md` holds one registry line per project: `- <name> [<mode>] - <description> (added <date>)`, with optional `+auto`. It stays a thin navigation registry, never a knowledge dump.
- **Project memory ownership:** durable project-intrinsic knowledge (build/test/release mechanics, conventions, sharp edges) lives in the project's committed `AGENTS.md` (`CLAUDE.md` symlinked), created lazily on first need and written **only by ICs** through the delivery pipeline (`bin/em-ensure-agents-md.sh` supports this). Fleet/Director-private knowledge (modes, autonomy posture, strategy, in-flight state) stays in the EM's `data/`.
- **Delivery modes** (chosen at add time; default `gated`; faster modes / `+auto` only on explicit Director say-so):
  - `gated` (default) — the IC must pass the project's **test + lint gate** before pushing: `bin/em-validate.sh` runs the project's configured test and lint commands inside the IC's worktree and exits non-zero on any failure. Only after a green gate does the IC push and open the PR, reporting `done: PR <url> gate green`. That is the whole pipeline — no structured review findings, risk labels, or evidence trails.
  - `direct-PR` — IC pushes and opens the PR itself; no gate.
  - `local-only` — no remote, no PR; IC stops at "ready in branch" (after passing the gate if gate commands are configured), EM reviews the diff, Director approves, EM fast-forward merges local main.
- **Gate configuration:** each project's test and lint commands are recorded in its registry entry in `data/projects.md` (e.g. `test: npm test`, `lint: npm run lint`). At project add time the EM auto-detects sensible defaults from the repo (package.json scripts, Makefile targets, pyproject config, etc.), proposes them, and records what the Director confirms. A `gated` project with no confirmed commands cannot dispatch build tasks until they're set. `em-validate.sh` reads these commands via `em-project-mode.sh`; no initialization inside the project is needed, so cloning a `gated` project is just `git clone` + registry line.
- **Worktree management (plain git, no pool):** each task gets `git worktree add <path> --detach origin/<default>` under a local `worktrees/<id>/` directory (gitignored); teardown uses `git worktree remove` after safety checks, plus `git worktree prune` during fleet sync. No external pooling tool — creation is fast enough per-task, and disposability is guaranteed by teardown's unlanded-work protection rather than by pool hygiene.
- **Clone existing:** clone into `projects/<name>`, add registry line with mode and (for `gated`) confirmed gate commands.
- **Create new:** creating a GitHub repo is outward-facing → propose name/owner/visibility(default private)/mode and create only after Director consent; `local-only` projects skip GitHub entirely.

### 4.7 Task lifecycle

**Intake.**
- *Resolve the project first*, per message, never by habit: explicit name wins → clear follow-up inherits its referent's project → content matching against clones/backlog/READMEs → one confident match proceeds (stating the project so a wrong guess costs one correction) → multiple/zero matches asks a one-line question.
- *Classify shape:* Build (default) vs Research ("what's wrong", "how would we", "find out why" → research; the EM dispatches instead of digging itself).
- *Classify readiness:* dispatchable (no overlap; no concurrency cap) vs blocked (same repo + overlapping area, or depends on an unmerged PR → record in backlog with `blocked-by`). Dependency judgment stays coarse; research tasks almost never block.

**Brief.** Scaffold with `bin/em-brief.sh <id> <repo> [--research]`. The scaffold is the contract: branch setup, sparse status-reporting protocol (append only supervisor-actionable phase changes and `needs-decision` / `blocked` / `done` / `failed` — every append wakes the EM), delivery rules resolved from the project's mode, definition of done, and (build tasks only) the project-memory contract. The EM fills in `{TASK}` with description, acceptance criteria, and constraints.

**Spawn.** `bin/em-spawn.sh <id> projects/<repo> [harness|--research]` creates the tmux window (in the current session, or a dedicated `em` session when outside tmux), creates a fresh git worktree for the task (`git worktree add`, detached at the fetched default branch), installs the turn-end hook, writes `state/<id>.meta`, and launches the IC with its brief. Worktrees start detached on a clean default branch; build briefs have the IC create branch `em/<id>`, research worktrees stay scratch. After spawn, peek within ~20s to confirm processing and auto-accept any trust dialog. Add to backlog "In flight".

**Supervise.** See 4.8. Steering happens only via short single lines through `bin/em-send.sh`; anything long goes in a file the IC can read.

**Validate (gated mode).** The gate runs IC-side: the build brief instructs the IC to run `bin/em-validate.sh <id>` before pushing, fix any test or lint failures it surfaces, and re-run until green. If the IC cannot get the gate green after reasonable attempts it reports `blocked: gate failing — <summary>`, which the EM relays with evidence. The EM never bypasses a red gate; only the Director can explicitly waive it for a specific task.

**PR ready.** On `done: PR <url> gate green` (gated) or `done: PR <url>` (direct-PR), run `bin/em-pr-check.sh <id> <url>` to record the PR and arm the watcher's merge poll. Report to the Director: full `https://…` PR URL (never a bare `#number`), a one-paragraph summary, and gate/CI status. "Merge it" from the Director = explicit approval; the EM merges via the GitHub tool.

**Local-only path.** IC stops at `done: ready in branch em/<id>`; EM reviews via `bin/em-review-diff.sh <id>` (always compares against the authoritative fetched base, since a clone's local default ref can lag origin), relays a one-paragraph summary, and on approval runs `bin/em-merge-local.sh <id>` (refuses anything but a clean fast-forward — if refused, have the IC rebase).

**Teardown (only after merge/report confirmed).** `bin/em-teardown.sh <id>` returns the worktree and kills the window; it refuses if unlanded work exists (treat refusals as stop-and-investigate — e.g. squash-merged fork branches need the fork fetched, never `--force`). After PR-based teardown it fleet-syncs that project so the clone catches up and the merged branch is pruned. Then move the task to Done in the backlog and dispatch anything unblocked.

**Research flow.** Same intake/spawn/supervise; no validate/PR stage. On `done`, read `data/<id>/report.md`, relay findings (plain chat for focused answers; a rich review surface for multi-finding reports), tear down immediately (teardown refuses if the report is missing), record Done with the report path.

**Promotion.** When research reveals shippable work, promote in place with `bin/em-promote.sh <id>` (flips `kind=` to build, restoring full teardown protection) and instruct the IC: inventory scratch state, reset to a clean base, carry over only intended changes, branch `em/<id>`, implement (the repro becomes the regression test), then proceed as a normal build task.

### 4.8 Supervision protocol

- **The watcher is the backbone.** Whenever ≥1 task is in flight, `bin/em-watch.sh` runs in the background at zero token cost and exits with exactly one reason line: `signal | stale | check | heartbeat`. Restart it after handling every wake and before ending any turn. Waiting is intentionally silent — no idle progress updates.
- **Wake handling, cheapest first:** `signal` → read the listed status files (each ~30 tokens, usually sufficient; wakes coalesce signals within a grace window). `stale` → IC stopped without reporting; peek the pane (`bin/em-peek.sh`, default 40-line bounded tail). `check` → a per-task slow poll fired (usually PR merged); act. `heartbeat` → mandatory full-fleet review: skim status files, peek panes that look off, check PR-ready tasks, reconcile the backlog, restart the watcher. Unchanged heartbeats are internal — never reported.
- **Heartbeat backoff:** base interval (default 600s) doubling to a cap (default 2h) while heartbeats are the only wakes; any signal/stale/check resets the cadence. Due per-task checks run before signal scanning so chatty ICs can't starve merge detection.
- **Liveness is guarded, not just disciplined:** the watcher touches a beacon file every poll; every supervision script calls `bin/em-guard.sh` first, which warns via stderr when tasks are in flight but the beacon is stale/missing (grace window keeps normal restart gaps silent). A guard warning means: restart the watcher before anything else.
- **Never foreground-block while tasks are in flight** (own pipelines, long builds) — background such work so wakes can interleave.
- **Custom check contract:** `state/<id>.check.sh` prints one line only when the EM should wake, nothing otherwise, and finishes within the check timeout.
- **Token discipline:** status files before panes; bounded peeks; never stream a pane through the EM; batch Director updates. tmux is ground truth — hooks and status files alone are never trusted over the mandatory heartbeat review.

**Stuck-IC playbook (escalate in order):** (1) peek the pane; (2) waiting on a question the brief answers → answer in one line; (3) confused/looping → interrupt with the adapter's interrupt key + one corrective line; (4) context-exhausted/wedged → exit and relaunch with the same brief plus an appended progress note (worktree and commits persist; cheap); (5) second relaunch fails → mark `failed` in the backlog and tell the Director with evidence.

### 4.9 Escalation and Director etiquette

- **Outcomes, not mechanics.** Director-facing messages describe the work — being investigated, built, ready, blocked, needing a decision — never internal machinery (watcher, heartbeats, worktrees, briefs, task ids, harness names, mode labels, teardown, session lock, etc.). Translate, don't expose.
- **Reaches the Director immediately:** work ready for review (full PR URL), finished research findings (as findings, not "done"), decisions needed, real blockers/failures after the playbook is exhausted (with evidence), anything destructive/irreversible/security-sensitive, needed credentials.
- **Never reaches the Director:** auto-fixes, retries, routine progress, internal vocabulary. Non-urgent items batch into the next natural reply.
- Rich review surface for multi-option decisions and structured reports; plain chat for yes/no. Always full clickable PR URLs. Courtesy cost mention when unusually much work runs concurrently (>~8 jobs), never blocking on it.

### 4.10 Backlog format

`data/backlog.md` is the durable queue, updated on every dispatch, completion, and decision:

```
## In flight
- [ ] <id> - <one line> (repo: <name>, since <date>)

## Queued
- [ ] <id> - <one line> (repo: <name>) blocked-by: <id> - <reason>

## Done
- [x] <id> - <one line> - <PR URL | local main | data/<id>/report.md> (<date>)
```

Queued is re-evaluated on every teardown and heartbeat; Done keeps only the 10 most recent entries (PRs, local main, and report files are the durable record).

### 4.11 The `bin/` toolbelt (deliverable scripts)

| Script | Function |
|---|---|
| `em-bootstrap.sh` | Detect missing toolchain; best-effort clone refresh; consent-gated installs |
| `em-fleet-sync.sh` | Fetch clones, clean fast-forward default branches, safely prune gone branches |
| `em-brief.sh` | Scaffold a build brief, or a report-only research brief with `--research` |
| `em-ensure-agents-md.sh` | Ensure project `AGENTS.md` is real and `CLAUDE.md` symlinks to it |
| `em-guard.sh` | Warn when tasks are in flight but the watcher beacon is stale/missing |
| `em-worktree.sh` | Thin wrapper over `git worktree add / remove / prune` with our naming and safety conventions (replaces treehouse) |
| `em-validate.sh` | The gate: run the project's configured test + lint commands in the task worktree; non-zero on any failure (replaces no-mistakes) |
| `em-spawn.sh` | Window → fresh `git worktree` → agent launched with its brief; records task kind/mode |
| `em-project-mode.sh` | Resolve a project's delivery mode and `+auto` flag from the registry |
| `em-merge-local.sh` | Approved fast-forward merge of a `local-only` project's local default branch |
| `em-review-diff.sh` | Review an IC branch against the authoritative base (optional `--stat`) |
| `em-watch.sh` | Block until supervision work is due; exit with one reason line |
| `em-send.sh` | Send one literal line (or a key, e.g. `--key Escape`) to an IC window |
| `em-peek.sh` | Print a bounded tail of an IC pane |
| `em-pr-check.sh` | Record a PR-ready task and arm the watcher's merge poll |
| `em-promote.sh` | Promote a research task in place into a protected build task |
| `em-teardown.sh` | Return the worktree, kill the window; protects unlanded work; requires research reports |
| `em-harness.sh` | Detect the running harness; resolve the effective IC harness |
| `em-lock.sh` | Single-EM session lock |

All scripts: bash, shellcheck-clean (CI-enforced), each self-documenting via a header.

**Porting strategy:** every script above except `em-worktree.sh` and `em-validate.sh` (our two new pieces) is a direct port of its firstmate counterpart (`fm-*` → `em-*`), with treehouse calls swapped for `em-worktree.sh` / raw `git worktree` and no-mistakes hooks replaced by `em-validate.sh` calls in the brief scaffold and mode resolution. Preserve firstmate's MIT attribution in the LICENSE/NOTICE for ported code.

### 4.12 Configuration

- Orchestrator behavior lives in `AGENTS.md` (edit like any prompt when the fleet is empty; delegate to an IC while tasks are in flight).
- Director-personal preferences in `data/director.md` (gitignored; read after the project registry at bootstrap; canonical over any harness memory).
- Runtime tuning via environment variables (defaults): `EM_POLL=15`, `EM_HEARTBEAT=600` (exponential backoff), `EM_HEARTBEAT_MAX=7200`, `EM_CHECK_INTERVAL=300`, `EM_CHECK_TIMEOUT=30`, `EM_GUARD_GRACE=300`, `EM_SIGNAL_GRACE=30`, `EM_FLEET_SYNC_BOOTSTRAP_TIMEOUT=20`, `EM_FLEET_PRUNE=1`, `EM_BUSY_REGEX` (extendable per harness).

### 4.13 Persona and tone

The EM addresses the user with light "engineering org" flavor (e.g., occasional "boss" / manager-speak) where firstmate uses nautical flavor — kept optional, never in commits/briefs/PRs or anything ICs read, and dropped entirely for bad news or serious findings. Every Director-facing message is a plain outcome about the Director's work.

---

## 5. Dependencies and Prerequisites

- **Required from the user:** a verified agent harness (claude / codex / opencode / pi), git (≥ 2.5 for `git worktree`) + GitHub auth (`gh auth login`), tmux (offered for install if missing).
- **Detected/installed with consent:** tmux, `gh` CLI, and any helper tools we port alongside the toolbelt (GitHub helper, browser-automation helper, rich-review-surface helper — ported from firstmate's ecosystem as-is).
- **Deliberately NOT dependencies (locked decisions):** *treehouse* — replaced by plain `git worktree` via `em-worktree.sh`; *no-mistakes* — replaced by our minimal built-in `em-validate.sh` gate (test + lint enforcement only).
- **Platforms:** macOS and Linux.
- **Language:** the toolbelt is 100% shell; the orchestrator is markdown prompt-ware.

---

## 6. Success Metrics

- Time-to-first-PR from a fresh clone under 10 minutes (including consent-gated installs).
- N parallel tasks on the same repo complete without worktree/branch collisions.
- Idle fleet consumes zero tokens between wakes; an EM kill + relaunch mid-flight loses no work and requires no Director re-explanation.
- Zero incidents of the EM writing to a project outside the sanctioned exceptions, merging without approval, or destroying unlanded work (script-enforced, not just prompt-enforced).
- All four launch harnesses verified end-to-end on a trivial task.

## 7. Milestones (build order, later)

1. **M1 — Skeleton:** repo layout, orchestrator file v1, `em-worktree` (plain `git worktree` wrapper), `em-brief` / `em-spawn` / `em-send` / `em-peek` / `em-teardown`, single harness (claude), `direct-PR` mode only.
2. **M2 — Supervision:** port `em-watch` (signal/stale/check/heartbeat + backoff), `em-guard` liveness beacon, stuck-IC playbook, backlog, recovery + session lock.
3. **M3 — Delivery + fleet:** project registry + `em-project-mode` (modes and gate commands), `em-validate` gate + `gated` mode wiring into briefs, `local-only` (`em-review-diff`, `em-merge-local`), `em-pr-check` merge polling, fleet sync, `+auto`.
4. **M4 — Breadth (completes v1):** research tasks + promotion, project-memory contract (`em-ensure-agents-md`), remaining harness adapters + verification flow, bootstrap consent installs, CI (shellcheck), docs; move this repo itself behind its own gate.

## 8. Open Questions

1. **Gate command detection:** how smart should auto-detection at project-add time be (package.json / Makefile / pyproject heuristics) versus simply asking the Director for the two commands?
2. **Gate scope edge cases:** projects with no tests or no linter — allow a `gated` project with only one of the two commands, or require `direct-PR` instead?
3. **Naming:** final product name, and final terminology (EM/IC/Director vs. other framings).
4. **Persona intensity:** how much manager-flavor, if any, versus fully plain tone.
5. **License/attribution:** firstmate is MIT; since we are porting its scripts directly, retain its copyright notice per MIT.
6. **Windows support:** out of scope like firstmate (macOS/Linux only), or WSL-documented?
7. **Helper-tool porting order:** the gh/browser/review helpers are "copy exactly" — confirm which are actually needed for M1–M2 vs. deferrable.