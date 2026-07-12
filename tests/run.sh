#!/usr/bin/env bash
# tests/run.sh — pure-bash test suite for the em-* toolbelt (no framework).
#
# Sandboxes all fleet state under a temp EM_ROOT and runs tmux-dependent
# cases on an isolated server (EM_TMUX_SOCKET); those cases SKIP (not fail)
# when tmux is missing. Safety refusal paths (exit 3, ADR-0002) are the
# flagship assertions. Exits non-zero if any case fails.
set -uo pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "$TESTS_DIR/.." && pwd -P)"
BIN="$REPO_DIR/bin"

command -v git >/dev/null || { echo "SKIP: git not installed — cannot test anything" >&2; exit 0; }

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/em-tests.XXXXXX")"
export EM_ROOT="$SANDBOX/fleet"
export EM_TMUX_SOCKET="em-test-$$"
mkdir -p "$EM_ROOT/projects"

# Hermetic git: identity via env, no user/system config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=em-test GIT_AUTHOR_EMAIL=em-test@example.invalid
export GIT_COMMITTER_NAME=em-test GIT_COMMITTER_EMAIL=em-test@example.invalid

# shellcheck source=bin/lib/common.sh
source "$BIN/lib/common.sh"

cleanup() {
  tmux_cmd kill-server 2>/dev/null
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

PASS=0 FAIL=0 SKIP=0
ok() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$*"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip - %s\n' "$*"; }
note() { printf '# %s\n' "$*"; }

# expect <desc> <cmd...>          — pass iff cmd exits 0
expect() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

# expect_rc <desc> <want> <cmd...> — pass iff cmd exits with code <want>
expect_rc() {
  local desc="$1" want="$2" rc=0
  shift 2
  "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq "$want" ]; then ok "$desc"; else fail "$desc (rc=$rc, want $want)"; fi
}

# make_project <name> — bare "origin" + seeded projects/<name> clone
make_project() {
  local name="$1" bare="$SANDBOX/remotes/$1.git" seed="$SANDBOX/seed-$1"
  git init -q --bare -b main "$bare"
  git clone -q "$bare" "$seed" 2>/dev/null
  (
    cd "$seed" &&
      git checkout -qb main &&
      echo hello > README.md &&
      git add . && git commit -qm init &&
      git push -q -u origin main
  )
  git clone -q "$bare" "$EM_ROOT/projects/$name" 2>/dev/null
}

# fill_task <id> — replace the {TASK} placeholder in a scaffolded brief
fill_task() {
  local f="$EM_ROOT/data/$1/brief.md" c
  c="$(<"$f")"
  printf '%s\n' "${c//\{TASK\}/Do nothing; this is a test task.}" > "$f"
}

# wait_for_pane <id> <needle> [tries] — poll em-peek until needle appears
wait_for_pane() {
  for _ in $(seq 1 "${3:-15}"); do
    if "$BIN/em-peek.sh" "$1" 200 2>/dev/null | grep -qF "$2"; then return 0; fi
    sleep 1
  done
  return 1
}

# ---------------------------------------------------------------- worktree
note "em-worktree.sh — lifecycle and the unlanded-work refusals (ADR-0002)"
make_project demo
WT="$EM_ROOT/worktrees"

out="$("$BIN/em-worktree.sh" add tst-a1 demo)"
expect "add prints the worktree path" test "$out" = "$WT/tst-a1"
expect "worktree exists and is a worktree" git -C "$WT/tst-a1" rev-parse --is-inside-work-tree
head_sha="$(git -C "$WT/tst-a1" rev-parse HEAD)"
base_sha="$(git -C "$EM_ROOT/projects/demo" rev-parse origin/main)"
expect "worktree is detached at fetched origin/main" test "$head_sha" = "$base_sha"
expect_rc "add refuses a duplicate id" 1 "$BIN/em-worktree.sh" add tst-a1 demo
expect_rc "add validates task ids" 1 "$BIN/em-worktree.sh" add 'Bad_ID' demo
expect_rc "add wants an existing clone" 1 "$BIN/em-worktree.sh" add tst-a2 nosuch

expect "clean worktree removes without --force" "$BIN/em-worktree.sh" remove tst-a1
expect "worktree directory is gone" test ! -e "$WT/tst-a1"

"$BIN/em-worktree.sh" add tst-a1 demo >/dev/null
echo dirt > "$WT/tst-a1/scratch.txt"
expect_rc "REFUSES (3) on uncommitted/untracked changes" 3 "$BIN/em-worktree.sh" remove tst-a1
expect "refused worktree is untouched" test -e "$WT/tst-a1/scratch.txt"
expect "--force removes it anyway" "$BIN/em-worktree.sh" remove tst-a1 --force

"$BIN/em-worktree.sh" add tst-a1 demo >/dev/null
echo dirt > "$WT/tst-a1/junk.txt"
expect "remove accepts --force before the id" "$BIN/em-worktree.sh" remove --force tst-a1

"$BIN/em-worktree.sh" add tst-a1 demo >/dev/null
(
  cd "$WT/tst-a1" &&
    git checkout -qb em/tst-a1 &&
    echo change > file.txt &&
    git add . && git commit -qm work
)
expect_rc "REFUSES (3) on unpushed em/<id> commits" 3 "$BIN/em-worktree.sh" remove tst-a1
git -C "$WT/tst-a1" push -q -u origin em/tst-a1
expect "removes once the branch is pushed (landed)" "$BIN/em-worktree.sh" remove tst-a1

note "em-worktree.sh — merged-to-default-branch counts as landed (ADR-0002 amendment)"
"$BIN/em-worktree.sh" add tst-a3 demo >/dev/null
(
  cd "$WT/tst-a3" &&
    git checkout -qb em/tst-a3 &&
    echo merged > merged.txt &&
    git add . && git commit -qm merged-work
)
expect_rc "REFUSES (3) before the merge" 3 "$BIN/em-worktree.sh" remove tst-a3
git -C "$EM_ROOT/projects/demo" merge -q --ff-only em/tst-a3
expect "removes once merged into the clone's default branch" "$BIN/em-worktree.sh" remove tst-a3

note "em-worktree.sh — no-remote (local-only) projects"
git init -q -b main "$EM_ROOT/projects/loco"
(
  cd "$EM_ROOT/projects/loco" &&
    echo local > README.md &&
    git add . && git commit -qm init
)
out="$("$BIN/em-worktree.sh" add tst-l1 loco)"
expect "add works without a remote" test "$out" = "$WT/tst-l1"
head_sha="$(git -C "$WT/tst-l1" rev-parse HEAD)"
base_sha="$(git -C "$EM_ROOT/projects/loco" rev-parse main)"
expect "worktree is detached at the local default branch" test "$head_sha" = "$base_sha"
(
  cd "$WT/tst-l1" &&
    git checkout -qb em/tst-l1 &&
    echo work > work.txt &&
    git add . && git commit -qm work
)
expect_rc "REFUSES (3) on unmerged local commits" 3 "$BIN/em-worktree.sh" remove tst-l1
git -C "$EM_ROOT/projects/loco" merge -q --ff-only em/tst-l1
expect "removes once merged into local main" "$BIN/em-worktree.sh" remove tst-l1

# ------------------------------------------------------------------- brief
# The registry comes first: build briefs refuse unregistered projects.
mkdir -p "$EM_ROOT/data"
cat > "$EM_ROOT/data/projects.md" <<'REG'
# Projects
- demo [direct-PR] - throwaway test project (added 2026-07-12)
- loco [local-only] - remote-less project (added 2026-07-12)
- gp [gated +auto] - gated project (added 2026-07-12) | test: bash -c 'exit 0' | lint: echo lint-ok
- gbad [gated] - failing gate (added 2026-07-12) | test: bash -c 'exit 1'
- gnone [gated] - gated without commands (added 2026-07-12)
REG

note "em-brief.sh — template rendering"
out="$("$BIN/em-brief.sh" tst-b1 demo)"
BRIEF="$EM_ROOT/data/tst-b1/brief.md"
expect "prints the brief path" test "$out" = "$BRIEF"
expect "renders the branch name" grep -q 'em/tst-b1' "$BRIEF"
expect "renders the absolute status file path" grep -qF "$EM_ROOT/state/tst-b1.status" "$BRIEF"
expect "renders the default branch" grep -q 'origin/main' "$BRIEF"
expect "leaves {TASK} for the EM to fill" grep -qF '{TASK}' "$BRIEF"
expect "no unrendered {ID}/{REPO}/{BRANCH} placeholders" test -z "$(grep -E '\{(ID|REPO|BRANCH|DEFAULT_BRANCH|STATUS_FILE)\}' "$BRIEF")"
expect_rc "refuses to overwrite an existing brief" 1 "$BIN/em-brief.sh" tst-b1 demo
expect "--force overwrites" "$BIN/em-brief.sh" tst-b1 demo --force
expect "--research scaffolds a research brief" "$BIN/em-brief.sh" tst-b2 demo --research
expect_rc "wants an existing clone" 1 "$BIN/em-brief.sh" tst-b3 nosuch

# -------------------------------------------------- M3: registry and modes
note "em-project-mode.sh — registry parsing"
expect "resolves mode" test "$("$BIN/em-project-mode.sh" demo)" = "direct-PR"
expect "resolves local-only" test "$("$BIN/em-project-mode.sh" loco mode)" = "local-only"
expect "resolves gated" test "$("$BIN/em-project-mode.sh" gp mode)" = "gated"
expect "+auto detected" test "$("$BIN/em-project-mode.sh" gp auto)" = "1"
expect "no +auto means 0" test "$("$BIN/em-project-mode.sh" demo auto)" = "0"
expect "extracts the test command" test "$("$BIN/em-project-mode.sh" gp test)" = "bash -c 'exit 0'"
expect "extracts the lint command" test "$("$BIN/em-project-mode.sh" gp lint)" = "echo lint-ok"
expect "unset gate command is empty" test -z "$("$BIN/em-project-mode.sh" loco test)"
expect_rc "unknown project fails" 1 "$BIN/em-project-mode.sh" nosuch

note "em-validate.sh — the test+lint gate"
fake_meta() { # <id> <project>
  mkdir -p "$EM_ROOT/state"
  printf 'window=em-%s\nworktree=%s\nproject=%s\nkind=build\nmode=direct-PR\n' \
    "$1" "$EM_ROOT/worktrees/$1" "$2" > "$EM_ROOT/state/$1.meta"
}
make_project gp
make_project gbad
make_project gnone
"$BIN/em-worktree.sh" add tst-v1 gp >/dev/null && fake_meta tst-v1 gp
out="$("$BIN/em-validate.sh" tst-v1 2>&1)"
expect "green gate passes" grep -q 'gate: GREEN' <<< "$out"
"$BIN/em-worktree.sh" add tst-v2 gbad >/dev/null && fake_meta tst-v2 gbad
expect_rc "red gate fails non-zero" 1 "$BIN/em-validate.sh" tst-v2
"$BIN/em-worktree.sh" add tst-v3 gnone >/dev/null && fake_meta tst-v3 gnone
expect_rc "gated with no commands fails" 1 "$BIN/em-validate.sh" tst-v3

note "em-brief.sh — delivery contract follows the registry mode"
"$BIN/em-brief.sh" tst-b8 gp >/dev/null
expect "gated brief requires the gate" grep -q 'em-validate.sh tst-b8' "$EM_ROOT/data/tst-b8/brief.md"
expect "gated brief reports gate green" grep -q 'gate green' "$EM_ROOT/data/tst-b8/brief.md"
"$BIN/em-brief.sh" tst-b9 loco >/dev/null
expect "local-only brief stops at the branch" grep -q 'ready in branch em/tst-b9' "$EM_ROOT/data/tst-b9/brief.md"
expect "local-only brief never opens a PR" test -z "$(grep 'gh pr create' "$EM_ROOT/data/tst-b9/brief.md")"
expect "no-remote brief bases on the local branch" grep -q "detached at \`main\`" "$EM_ROOT/data/tst-b9/brief.md"
expect_rc "gated project without gate commands cannot be briefed" 1 "$BIN/em-brief.sh" tst-b7 gnone
make_project unreg
expect_rc "unregistered project cannot take a build brief" 1 "$BIN/em-brief.sh" tst-b6 unreg
expect "research briefs need only the clone" "$BIN/em-brief.sh" tst-b6 unreg --research

note "em-review-diff.sh — branch vs authoritative base"
"$BIN/em-worktree.sh" add tst-r1 demo >/dev/null && fake_meta tst-r1 demo
(
  cd "$EM_ROOT/worktrees/tst-r1" &&
    git checkout -qb em/tst-r1 &&
    echo reviewed > review.txt &&
    git add . && git commit -qm review-me
)
expect "diff shows the branch change" grep -q 'review.txt' <("$BIN/em-review-diff.sh" tst-r1)
expect "--stat summarizes" grep -q '1 file' <("$BIN/em-review-diff.sh" tst-r1 --stat)
expect "--stat accepted before the id" grep -q '1 file' <("$BIN/em-review-diff.sh" --stat tst-r1)
"$BIN/em-worktree.sh" add tst-r2 demo >/dev/null && fake_meta tst-r2 demo
expect_rc "no branch yet fails plainly" 1 "$BIN/em-review-diff.sh" tst-r2

note "em-merge-local.sh — approved fast-forward only"
"$BIN/em-worktree.sh" add tst-m1 loco >/dev/null && fake_meta tst-m1 loco
(
  cd "$EM_ROOT/worktrees/tst-m1" &&
    git checkout -qb em/tst-m1 &&
    echo feature > feature.txt &&
    git add . && git commit -qm feature
)
expect_rc "refuses non-local-only projects" 1 "$BIN/em-merge-local.sh" tst-r1
echo dirt > "$EM_ROOT/projects/loco/dirt.txt"
expect_rc "REFUSES (3) a dirty clone" 3 "$BIN/em-merge-local.sh" tst-m1
rm "$EM_ROOT/projects/loco/dirt.txt"
expect "fast-forwards local main on approval" "$BIN/em-merge-local.sh" tst-m1
expect "main now at the IC's commit" test \
  "$(git -C "$EM_ROOT/projects/loco" rev-parse main)" = \
  "$(git -C "$EM_ROOT/projects/loco" rev-parse em/tst-m1)"
"$BIN/em-worktree.sh" add tst-m2 loco >/dev/null && fake_meta tst-m2 loco
(
  cd "$EM_ROOT/worktrees/tst-m2" &&
    git checkout -qb em/tst-m2 &&
    echo other > other.txt &&
    git add . && git commit -qm other
)
(
  cd "$EM_ROOT/projects/loco" &&
    echo drift >> README.md &&
    git add . && git commit -qm drift
)
expect_rc "REFUSES (3) a non-fast-forward" 3 "$BIN/em-merge-local.sh" tst-m2

note "em-pr-check.sh — arm the merge poll"
fake_meta tst-p1 demo
expect_rc "rejects a non-PR url" 1 "$BIN/em-pr-check.sh" tst-p1 https://example.com/nope
expect "records the PR and writes the check" "$BIN/em-pr-check.sh" tst-p1 https://github.com/o/r/pull/7
expect "meta carries the PR url" grep -qx 'pr=https://github.com/o/r/pull/7' "$EM_ROOT/state/tst-p1.meta"
expect "check script is executable" test -x "$EM_ROOT/state/tst-p1.check.sh"
expect "check script polls that PR" grep -q 'github.com/o/r/pull/7' "$EM_ROOT/state/tst-p1.check.sh"

note "em-fleet-sync.sh — fetch, fast-forward, safe prune"
make_project fs1
expect "fresh clone is up to date" grep -q 'up to date' <("$BIN/em-fleet-sync.sh" fs1)
(
  cd "$SANDBOX/seed-fs1" &&
    echo more > more.txt &&
    git add . && git commit -qm more && git push -q origin main
)
expect "fast-forwards a clone behind origin" grep -q 'fast-forwarded' <("$BIN/em-fleet-sync.sh" fs1)
(
  cd "$EM_ROOT/projects/fs1" &&
    git checkout -qb dead && git push -qu origin dead 2>/dev/null &&
    git checkout -q main && git push -q origin :dead 2>/dev/null
)
expect "prunes a branch whose upstream is gone" grep -q 'pruned dead' <("$BIN/em-fleet-sync.sh" fs1)
expect "branch really deleted" test -z "$(git -C "$EM_ROOT/projects/fs1" branch --list dead)"
(
  cd "$EM_ROOT/projects/fs1" &&
    git checkout -qb em/tst-pp && git push -qu origin em/tst-pp 2>/dev/null &&
    git checkout -q main && git push -q origin :em/tst-pp 2>/dev/null
)
fake_meta tst-pp fs1
"$BIN/em-fleet-sync.sh" fs1 >/dev/null
expect "never prunes an in-flight task's branch" \
  git -C "$EM_ROOT/projects/fs1" show-ref --verify --quiet refs/heads/em/tst-pp
rm "$EM_ROOT/state/tst-pp.meta"
"$BIN/em-fleet-sync.sh" fs1 >/dev/null
expect "prunes it once the task is gone" test -z "$(git -C "$EM_ROOT/projects/fs1" branch --list 'em/tst-pp')"
expect "no-remote projects are skipped" grep -q 'no remote' <("$BIN/em-fleet-sync.sh" loco)
ln -s "$SANDBOX/seed-fs1" "$EM_ROOT/projects/simu"
expect "symlinked working copies are fetch-only" grep -q 'symlinked' <("$BIN/em-fleet-sync.sh" simu)
rm "$EM_ROOT/projects/simu"
rm -f "$EM_ROOT/state/"*.meta "$EM_ROOT/state/"*.check.sh # M3 fixtures: nothing in flight for the M2 cases

note "em-status.sh — fleet overview"
expect "reports an idle fleet" grep -q 'no tasks in flight' <("$BIN/em-status.sh" 2>/dev/null)
fake_meta tst-st1 demo
echo "working: poking around" >> "$EM_ROOT/state/tst-st1.status"
meta_set tst-st1 pr https://github.com/o/r/pull/9
out="$("$BIN/em-status.sh" 2>/dev/null)"
expect "lists the task" grep -q 'tst-st1' <<< "$out"
expect "shows kind/mode" grep -q 'build/direct-PR' <<< "$out"
expect "shows the last status line" grep -q 'working: poking around' <<< "$out"
expect "window reported dead" grep -q 'dead' <<< "$out"
expect "shows the armed PR" grep -q 'pull/9' <<< "$out"
rm -f "$EM_ROOT/state/tst-st1".*

note "em-project-add.sh — registry add + validate"
make_project padd
out="$("$BIN/em-project-add.sh" padd --desc 'registry test project' --mode direct-PR)"
expect "prints the registry line" grep -q '^- padd \[direct-PR\] - registry test project' <<< "$out"
expect "line resolves via em-project-mode" test "$("$BIN/em-project-mode.sh" padd mode)" = "direct-PR"
expect_rc "refuses a duplicate" 1 "$BIN/em-project-add.sh" padd --desc 'again'
expect_rc "wants an existing clone" 1 "$BIN/em-project-add.sh" padd-nope --desc 'no clone'
make_project padd2
expect_rc "refuses ' | ' in a gate command" 1 "$BIN/em-project-add.sh" padd2 --desc x --test 'a | b'
expect_rc "refuses an unknown mode" 1 "$BIN/em-project-add.sh" padd2 --desc x --mode yolo
expect_rc "refuses an invalid name" 1 "$BIN/em-project-add.sh" 'bad name' --desc x
expect "gated default with commands and +auto" \
  "$BIN/em-project-add.sh" padd2 --desc 'gated project' --auto --test 'true' --lint 'echo ok'
expect "auto flag recorded" test "$("$BIN/em-project-mode.sh" padd2 auto)" = "1"
expect "test command round-trips" test "$("$BIN/em-project-mode.sh" padd2 test)" = "true"
expect "--validate passes the registry" "$BIN/em-project-add.sh" --validate
echo '- broken [nosuchmode] - bad line' >> "$EM_ROOT/data/projects.md"
expect_rc "--validate flags a malformed line" 1 "$BIN/em-project-add.sh" --validate
grep -v 'nosuchmode' "$EM_ROOT/data/projects.md" > "$EM_ROOT/data/projects.md.tmp" &&
  mv "$EM_ROOT/data/projects.md.tmp" "$EM_ROOT/data/projects.md"
expect "--validate green again after the fix" "$BIN/em-project-add.sh" --validate

# --------------------------------------------------- M4: research and tools
note "em-brief.sh --research — report-only contract"
"$BIN/em-brief.sh" tst-x1 demo --research >/dev/null
XB="$EM_ROOT/data/tst-x1/brief.md"
expect "research brief targets the report file" grep -qF "$EM_ROOT/data/tst-x1/report.md" "$XB"
expect "worktree declared scratch" grep -qi 'scratch' "$XB"
expect "never opens a PR" test -z "$(grep 'gh pr create' "$XB")"
expect "no gate in research briefs" test -z "$(grep 'em-validate' "$XB")"
expect "leaves {TASK} for the EM" grep -qF '{TASK}' "$XB"

note "em-harness.sh — detection and resolution"
expect "env marker detects claude" test "$(env CLAUDECODE=1 "$BIN/em-harness.sh" detect)" = "claude"
expect "per-task request wins" test "$(env CLAUDECODE=1 "$BIN/em-harness.sh" resolve codex)" = "codex"
mkdir -p "$EM_ROOT/config"
echo opencode > "$EM_ROOT/config/crew-harness"
expect "crew-harness override applies" test "$("$BIN/em-harness.sh" resolve)" = "opencode"
rm "$EM_ROOT/config/crew-harness"
expect "falls back to the detected harness" test "$(env CLAUDECODE=1 "$BIN/em-harness.sh" resolve)" = "claude"

note "em-promote.sh — research → protected build task"
fake_meta tst-x2 demo
expect_rc "refuses to promote a build task" 1 "$BIN/em-promote.sh" tst-x2
printf 'window=em-tst-x2\nworktree=%s\nproject=demo\nkind=research\n' \
  "$EM_ROOT/worktrees/tst-x2" > "$EM_ROOT/state/tst-x2.meta"
expect "promotes a research task" "$BIN/em-promote.sh" tst-x2
expect "kind flipped to build" grep -qx 'kind=build' "$EM_ROOT/state/tst-x2.meta"
rm -f "$EM_ROOT/state/tst-x2.meta"

note "em-ensure-agents-md.sh — project memory contract"
MEM="$SANDBOX/mem1"
mkdir -p "$MEM"
expect "creates AGENTS.md where none exists" "$BIN/em-ensure-agents-md.sh" "$MEM"
expect "AGENTS.md is a regular file" test -f "$MEM/AGENTS.md"
expect "CLAUDE.md symlinks to it" test "$(readlink "$MEM/CLAUDE.md")" = "AGENTS.md"
expect "idempotent" "$BIN/em-ensure-agents-md.sh" "$MEM"
MEM2="$SANDBOX/mem2"
mkdir -p "$MEM2"
echo "# existing knowledge" > "$MEM2/CLAUDE.md"
"$BIN/em-ensure-agents-md.sh" "$MEM2" >/dev/null 2>&1
expect "existing CLAUDE.md content becomes AGENTS.md" grep -q 'existing knowledge' "$MEM2/AGENTS.md"
MEM3="$SANDBOX/mem3"
mkdir -p "$MEM3"
echo a > "$MEM3/AGENTS.md"
echo b > "$MEM3/CLAUDE.md"
expect_rc "refuses when both are regular files" 1 "$BIN/em-ensure-agents-md.sh" "$MEM3"

note "em-bootstrap.sh — detect-and-report only"
out="$("$BIN/em-bootstrap.sh" 2>&1)"
expect "always exits 0" "$BIN/em-bootstrap.sh"
expect "git present, not reported missing" test -z "$(grep 'missing: git' <<< "$out")"
mkdir -p "$EM_ROOT/config"
echo 'no-such-harness-zz9' > "$EM_ROOT/config/crew-harness"
out="$("$BIN/em-bootstrap.sh" 2>&1)"
expect "reports a missing IC harness" grep -q 'missing: no-such-harness-zz9' <<< "$out"
rm -f "$EM_ROOT/config/crew-harness"
out="$("$BIN/em-bootstrap.sh" 2>&1)"
expect "flags an unregistered clone" grep -q 'registry: projects/unreg has no registry line' <<< "$out"
expect "registered clones are not flagged" test -z "$(grep 'registry: projects/demo ' <<< "$out")"
echo '- broken2 [nope] - bad line' >> "$EM_ROOT/data/projects.md"
out="$("$BIN/em-bootstrap.sh" 2>&1)"
expect "surfaces malformed registry lines" grep -q 'registry: ERROR' <<< "$out"
grep -v 'broken2' "$EM_ROOT/data/projects.md" > "$EM_ROOT/data/projects.md.tmp" &&
  mv "$EM_ROOT/data/projects.md.tmp" "$EM_ROOT/data/projects.md"

# ------------------------------------------------------- M2: guard and lock
note "em-guard.sh — beacon liveness warnings"
BEACON="$EM_ROOT/state/.last-watcher-beat"
expect "silent when nothing is in flight" \
  test -z "$("$BIN/em-guard.sh" 2>&1)"
mkdir -p "$EM_ROOT/state"
printf 'window=em-tst-g1\n' > "$EM_ROOT/state/tst-g1.meta"
rm -f "$BEACON"
out="$("$BIN/em-guard.sh" 2>&1)"
expect "warns when tasks in flight and beacon missing" grep -q beacon <<< "$out"
touch "$BEACON"
expect "silent when the beacon is fresh" test -z "$("$BIN/em-guard.sh" 2>&1)"
sleep 1
out="$(EM_GUARD_GRACE=0 "$BIN/em-guard.sh" 2>&1)"
expect "warns when the beacon is older than the grace" grep -q beacon <<< "$out"
rm -f "$EM_ROOT/state/tst-g1.meta"

note "em-lock.sh — single-EM session lock"
expect "acquire when unlocked" env EM_SESSION_PID=$$ "$BIN/em-lock.sh" acquire
expect "status shows the holder" grep -q "pid=$$" <(env EM_SESSION_PID=$$ "$BIN/em-lock.sh" status)
expect "re-acquire by the same session is fine" env EM_SESSION_PID=$$ "$BIN/em-lock.sh" acquire
sleep 30 &
OTHER=$!
printf 'pid=%s\nsince=now\n' "$OTHER" > "$EM_ROOT/state/.session-lock"
expect_rc "REFUSES (3) when a live session holds it" 3 env EM_SESSION_PID=$$ "$BIN/em-lock.sh" acquire
kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null
expect "takes over a dead session's stale lock" env EM_SESSION_PID=$$ "$BIN/em-lock.sh" acquire
"$BIN/em-lock.sh" release
expect "release unlocks" grep -q unlocked <("$BIN/em-lock.sh" status)

# ------------------------------------------------------------- M2: em-watch
note "em-watch.sh — signal/stale/check/heartbeat (fast timers)"
watch_fast() {
  env EM_POLL=1 EM_SIGNAL_GRACE=1 EM_HEARTBEAT=2 EM_HEARTBEAT_MAX=8 \
    EM_CHECK_INTERVAL=1 EM_CHECK_TIMEOUT=5 "$BIN/em-watch.sh"
}
out="$(watch_fast)"
expect "reports idle with no tasks in flight" test "$out" = "idle"
printf 'window=em-tst-w1\n' > "$EM_ROOT/state/tst-w1.meta"
echo "starting: warming up" >> "$EM_ROOT/state/tst-w1.status"
out="$(run_bounded 20 watch_fast)"
expect "fires signal on a new status line" test "$out" = "signal tst-w1"
expect "records the surfaced line count" test "$(cat "$EM_ROOT/state/.watch.seen.tst-w1")" = "1"
expect "touches the liveness beacon" test -f "$BEACON"
sleep 2
touch "$EM_ROOT/state/tst-w1.turn-ended"
rm -f "$EM_ROOT/state/.watch.next-beat" # fast timers: don't let a due heartbeat preempt the stale case
out="$(run_bounded 20 watch_fast)"
expect "fires stale when a turn ends silently" test "$out" = "stale tst-w1"
out="$(run_bounded 25 watch_fast)"
expect "no stale refire; heartbeat fires next" test "$out" = "heartbeat"
expect "heartbeat streak recorded" test "$(cat "$EM_ROOT/state/.watch.streak")" = "1"
echo "working: phase two" >> "$EM_ROOT/state/tst-w1.status"
out="$(run_bounded 20 watch_fast)"
expect "second signal fires" test "$out" = "signal tst-w1"
expect "non-heartbeat wake resets the backoff streak" test "$(cat "$EM_ROOT/state/.watch.streak")" = "0"
printf 'echo "PR merged"\n' > "$EM_ROOT/state/tst-w1.check.sh"
out="$(run_bounded 20 watch_fast)"
expect "per-task check fires with its output" test "$out" = "check tst-w1: PR merged"
rm -f "$EM_ROOT/state/tst-w1".* "$EM_ROOT/state/.watch."*

# ----------------------------------------------------------- tmux-dependent
if ! command -v tmux >/dev/null; then
  skip "tmux not installed — em-spawn/em-send/em-peek/em-teardown cases skipped"
else
  note "em-spawn.sh — window + hook + meta + launch (isolated tmux server)"
  mkdir -p "$SANDBOX/fakebin"
  cat > "$SANDBOX/fakebin/claude" <<'EOF'
#!/usr/bin/env bash
echo "FAKE_IC_READY brief=$*"
exec sleep 600
EOF
  chmod +x "$SANDBOX/fakebin/claude"
  export EM_LAUNCH_OVERRIDE="$SANDBOX/fakebin/claude"
  export EM_SPAWN_VERIFY=0 # keep spawns fast; the pane check has its own case below

  "$BIN/em-brief.sh" tst-s1 demo >/dev/null
  expect_rc "spawn refuses an unfilled {TASK} brief" 1 "$BIN/em-spawn.sh" tst-s1 demo
  fill_task tst-s1
  expect_rc "spawn refuses a missing brief" 1 "$BIN/em-spawn.sh" tst-s9 demo
  expect_rc "spawn refuses unverified harnesses" 1 \
    env -u EM_LAUNCH_OVERRIDE "$BIN/em-spawn.sh" tst-s1 demo codex

  expect "spawn succeeds with a filled brief" "$BIN/em-spawn.sh" tst-s1 demo
  META="$EM_ROOT/state/tst-s1.meta"
  expect "meta records mode=direct-PR" grep -qx 'mode=direct-PR' "$META"
  expect "meta records kind=build" grep -qx 'kind=build' "$META"
  expect "meta records the launch command" grep -q '^launch=' "$META"
  expect "meta records the worktree path" grep -qx "worktree=$WT/tst-s1" "$META"
  expect "status file pre-created" test -f "$EM_ROOT/state/tst-s1.status"
  expect "turn-end Stop hook installed in the worktree" \
    grep -q 'tst-s1.turn-ended' "$WT/tst-s1/.claude/settings.local.json"
  expect "hook file excluded via the clone's info/exclude" \
    grep -qxF '.claude/settings.local.json' "$EM_ROOT/projects/demo/.git/info/exclude"
  expect "window em-tst-s1 exists" find_window tst-s1
  expect "IC launched with the brief prompt" wait_for_pane tst-s1 FAKE_IC_READY
  expect_rc "spawn refuses a duplicate task" 1 "$BIN/em-spawn.sh" tst-s1 demo

  note "em-send.sh / em-peek.sh — against a plain shell window"
  tmux_cmd new-window -d -t '=em:' -n em-tst-io -c "$SANDBOX" 'bash --norc -i' 2>/dev/null ||
    tmux_cmd new-window -d -t '=em:' -n em-tst-io -c "$SANDBOX"
  expect "send types a line and submits it" "$BIN/em-send.sh" tst-io 'echo pong-42'
  expect "peek shows the pane output" wait_for_pane tst-io pong-42
  expect "send --key delivers a key" "$BIN/em-send.sh" tst-io --key Enter
  expect_rc "send to a missing window fails" 1 "$BIN/em-send.sh" tst-nope 'hi'
  expect_rc "peek of a missing window fails" 1 "$BIN/em-peek.sh" tst-nope
  expect_rc "peek validates the line count" 1 "$BIN/em-peek.sh" tst-io five

  note "em-teardown.sh — refusal first, then clean offboarding"
  echo dirt > "$WT/tst-s1/scratch.txt"
  expect_rc "teardown REFUSES (3) while unlanded work exists" 3 "$BIN/em-teardown.sh" tst-s1
  expect "refusal keeps the window alive" find_window tst-s1
  expect "refusal keeps the meta record" test -f "$META"
  rm "$WT/tst-s1/scratch.txt"
  expect "teardown succeeds once the worktree is clean" "$BIN/em-teardown.sh" tst-s1
  expect "worktree removed" test ! -e "$WT/tst-s1"
  expect_rc "window killed" 1 find_window tst-s1
  expect "volatile state cleared" test ! -e "$META"
  expect "durable data/<id>/ kept" test -f "$BRIEF" # tst-b1 untouched
  expect "brief of the torn-down task kept too" test -f "$EM_ROOT/data/tst-s1/brief.md"

  note "research lifecycle — scratch worktree, report-gated teardown"
  "$BIN/em-brief.sh" tst-x3 demo --research >/dev/null
  fill_task tst-x3
  expect "research spawn succeeds" "$BIN/em-spawn.sh" tst-x3 demo --research
  expect "meta records kind=research" grep -qx 'kind=research' "$EM_ROOT/state/tst-x3.meta"
  echo scratch-mess > "$WT/tst-x3/junk.txt"
  expect_rc "teardown REFUSES (3) without a report" 3 "$BIN/em-teardown.sh" tst-x3
  echo "# findings" > "$EM_ROOT/data/tst-x3/report.md"
  expect "with the report, scratch mess is no obstacle" "$BIN/em-teardown.sh" tst-x3
  expect "report survives teardown" test -f "$EM_ROOT/data/tst-x3/report.md"

  note "harness verification gate"
  "$BIN/em-brief.sh" tst-x4 demo >/dev/null
  fill_task tst-x4
  expect_rc "unverified codex refused without the trial escape hatch" 1 \
    env -u EM_LAUNCH_OVERRIDE "$BIN/em-spawn.sh" tst-x4 demo codex
  mkdir -p "$EM_ROOT/config"
  echo codex > "$EM_ROOT/config/verified-harnesses"
  expect "verified codex dispatches" \
    env -u EM_LAUNCH_OVERRIDE "$BIN/em-spawn.sh" tst-x4 demo codex
  expect "meta records the harness" grep -qx 'harness=codex' "$EM_ROOT/state/tst-x4.meta"
  expect "non-claude spawn installs no claude hook" test ! -e "$WT/tst-x4/.claude"
  expect "teardown accepts --force before the id" "$BIN/em-teardown.sh" --force tst-x4
  rm -f "$EM_ROOT/config/verified-harnesses"

  note "em-relaunch.sh — stuck-IC relaunch in place"
  "$BIN/em-brief.sh" tst-rl1 demo >/dev/null
  fill_task tst-rl1
  "$BIN/em-spawn.sh" tst-rl1 demo >/dev/null 2>&1
  expect "IC starts" wait_for_pane tst-rl1 FAKE_IC_READY
  expect "status classifies a quiet pane idle" grep -q 'idle' <("$BIN/em-status.sh" 2>/dev/null)
  expect "EM_BUSY_REGEX classifies a matching pane busy" \
    grep -q 'busy' <(env EM_BUSY_REGEX='FAKE_IC_READY' "$BIN/em-status.sh" 2>/dev/null)
  tmux_cmd kill-window -t "$(find_window tst-rl1)"
  expect_rc "window really dead" 1 find_window tst-rl1
  expect "relaunch recreates the window and replays the launch" \
    "$BIN/em-relaunch.sh" tst-rl1 --note 'resumed after test kill'
  expect "note appended to the brief" grep -q 'resumed after test kill' "$EM_ROOT/data/tst-rl1/brief.md"
  expect "IC running again" wait_for_pane tst-rl1 FAKE_IC_READY
  expect_rc "relaunch of an unknown task fails" 1 "$BIN/em-relaunch.sh" tst-zz
  "$BIN/em-teardown.sh" tst-rl1 >/dev/null 2>&1

  note "em-spawn.sh — post-launch pane check"
  cat > "$SANDBOX/fakebin/trusty" <<'EOF'
#!/usr/bin/env bash
echo "Do you trust the files in this folder?"
exec sleep 600
EOF
  chmod +x "$SANDBOX/fakebin/trusty"
  "$BIN/em-brief.sh" tst-tv1 demo >/dev/null
  fill_task tst-tv1
  out="$(env EM_LAUNCH_OVERRIDE="$SANDBOX/fakebin/trusty" EM_SPAWN_VERIFY=3 \
    "$BIN/em-spawn.sh" tst-tv1 demo 2>&1)"
  expect "spawn-check flags a trust dialog" grep -q 'trust dialog' <<< "$out"
  "$BIN/em-teardown.sh" tst-tv1 >/dev/null 2>&1
fi

# ------------------------------------------------------------------ summary
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
