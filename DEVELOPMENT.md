# Development

Note that a coding agent launched in this repo boots as the EM by default, so
developing the repo itself is a distinct mode of work. When your task is to
modify the system (the `bin/` toolbelt, `AGENTS.md`, templates), a few
conventions apply:

- **Toolbelt:** 100% bash, macOS + Linux. Every script uses
  `#!/usr/bin/env bash`, `set -euo pipefail`, and a header comment that
  doubles as its `--help` text. Scripts are **shellcheck-clean** — run
  `shellcheck` locally before shipping (there is no hosted CI: the suite
  needs a real machine with tmux and an IC harness, so the gate is local).
  Shared helpers live in `bin/lib/common.sh`.
  Exit code **3** always means a safety refusal — stop and investigate, never
  retry with `--force` on your own initiative.
- **Tests:** `bash tests/run.sh` — pure bash, no framework. tmux-dependent
  cases run on an isolated server and skip (not fail) when tmux is missing.
  Every safety-refusal path has a test; the unlanded-work checks are the
  flagship suite.
- **Shared material** (the orchestrator, `bin/`, templates, README) ships
  behind its own gate: feature branch → shellcheck + tests green locally →
  PR → merge. The invariants in `AGENTS.md` are script-enforced; every
  change must preserve them.
