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
command -v jq >/dev/null || { echo "SKIP: jq not installed — hard prerequisite (event log + budgets)" >&2; exit 0; }

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

# active_em_window — name of the active window in the detached 'em' session
# (surfaced spawns select their window; background spawns leave it alone).
active_em_window() {
  tmux_cmd list-windows -t '=em' -F '#{window_active} #{window_name}' |
    awk '$1 == 1 { print $2 }'
}

# events_in_order <events.jsonl> <ev1> <ev2>… — the named events appear in
# this order in the log (other events may interleave).
events_in_order() {
  local f="$1" pat
  shift
  pat="*$(printf '%s*' "$@")"
  # shellcheck disable=SC2254  # $pat is deliberately a glob
  case "$(jq -r .event "$f" 2>/dev/null | tr '\n' ' ')" in
    $pat) return 0 ;;
    *) return 1 ;;
  esac
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
expect "arming the poll logs pr_opened" \
  grep -q '"event":"pr_opened"' "$EM_ROOT/state/tasks/demo/tst-p1/events.jsonl"
mkdir -p "$SANDBOX/fakegh"
printf '#!/usr/bin/env bash\necho MERGED\n' > "$SANDBOX/fakegh/gh"
chmod +x "$SANDBOX/fakegh/gh"
PATH="$SANDBOX/fakegh:$PATH" bash "$EM_ROOT/state/tst-p1.check.sh" >/dev/null
expect "generated poll logs the merged event" \
  grep -q '"event":"merged"' "$EM_ROOT/state/tasks/demo/tst-p1/events.jsonl"
PATH="$SANDBOX/fakegh:$PATH" bash "$EM_ROOT/state/tst-p1.check.sh" >/dev/null
expect "marker prevents a duplicate merged event on re-poll" \
  test "$(grep -c '"event":"merged"' "$EM_ROOT/state/tasks/demo/tst-p1/events.jsonl")" = 1

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
expect "EVENT column header present" grep -q ' EVENT ' <<< "$out"
expect "no audit log yet: EVENT column shows -" \
  grep -qE 'tst-st1 +demo +build/direct-PR +dead +- ' <<< "$out"
"$BIN/em-log-event.sh" tst-st1 ic_spawned --actor em
expect "EVENT column shows the last event with its age" \
  grep -qE 'tst-st1 .* ic_spawned\+[0-9]+s ' <("$BIN/em-status.sh" 2>/dev/null)
rm -f "$EM_ROOT/state/tst-st1".*

note "em-dashboard.sh — Director live view (single frame)"
expect "idle fleet frame renders" grep -q 'no tasks in flight' <("$BIN/em-dashboard.sh" --once 2>/dev/null)
fake_meta tst-db1 demo
echo "blocked: gate failing" >> "$EM_ROOT/state/tst-db1.status"
printf '## Queued\n- [ ] tst-qq - queued task (repo: demo) blocked-by: tst-db1 - overlap\n\n## Done\n' > "$EM_ROOT/data/backlog.md"
rm -f "$EM_ROOT/state/.last-watcher-beat"
out="$("$BIN/em-dashboard.sh" --once 2>/dev/null)"
expect "frame lists the task" grep -q 'tst-db1' <<< "$out"
expect "frame shows the last status" grep -q 'blocked: gate failing' <<< "$out"
expect "frame includes the queued section" grep -q 'tst-qq' <<< "$out"
expect "supervision reported off without a watcher beacon" grep -q 'watcher not running' <<< "$out"
touch "$EM_ROOT/state/.last-watcher-beat"
expect "supervision active with a fresh beacon" \
  grep -q 'supervision: active' <("$BIN/em-dashboard.sh" --once 2>/dev/null)
expect_rc "no attach hint without the em session" 1 grep -q 'tmux attach' <<< "$out"
expect "colorize: dead pane turns red (forced color)" \
  grep -q $'\033\[31m.*tst-db1' <(EM_DASHBOARD_COLOR=1 "$BIN/em-dashboard.sh" --once 2>/dev/null)
if command -v tmux >/dev/null; then
  tmux_cmd new-session -d -s em -c "$EM_ROOT" 2>/dev/null || true
  expect "frame hints at tmux attach when the em session exists" \
    grep -q 'tmux attach -t em' <("$BIN/em-dashboard.sh" --once 2>/dev/null)
  # A live pane makes the row idle, so the attention tint must come from the
  # status column — this pins colorize's field index against column drift.
  tmux_cmd new-window -d -t '=em:' -n em-tst-db1 -c "$SANDBOX"
  expect "colorize: attention status turns yellow (column-shift pin)" \
    grep -q $'\033\[33m.*blocked: gate failing' \
    <(EM_DASHBOARD_COLOR=1 "$BIN/em-dashboard.sh" --once 2>/dev/null)
  tmux_cmd kill-session -t '=em' 2>/dev/null
else
  skip "tmux not installed — dashboard attach-hint case skipped"
  skip "tmux not installed — dashboard yellow-tint case skipped"
fi
expect_rc "rejects an unknown flag" 1 "$BIN/em-dashboard.sh" --nope
expect_rc "rejects a bad interval" 1 "$BIN/em-dashboard.sh" --interval xx --once
rm -f "$EM_ROOT/state/tst-db1".* "$EM_ROOT/state/.last-watcher-beat" "$EM_ROOT/data/backlog.md"

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

note "per-project memory + knowledge base (data/projects/<name>/)"
expect "add scaffolds the kb directory" test -d "$EM_ROOT/data/projects/padd/kb"
expect "add scaffolds memory.md" grep -q 'EM memory' "$EM_ROOT/data/projects/padd/memory.md"
expect_rc "the 'projects' task id is reserved" 1 "$BIN/em-brief.sh" projects demo
expect "brief without kb docs has no knowledge section" \
  test -z "$(grep 'Project knowledge' "$EM_ROOT/data/tst-b1/brief.md")"
mkdir -p "$EM_ROOT/data/projects/demo/kb"
echo '# arch' > "$EM_ROOT/data/projects/demo/kb/architecture.md"
"$BIN/em-brief.sh" tst-kb1 demo >/dev/null
expect "build brief gains the knowledge section" \
  grep -q 'Project knowledge' "$EM_ROOT/data/tst-kb1/brief.md"
expect "knowledge section lists the kb doc path" \
  grep -qF "$EM_ROOT/data/projects/demo/kb/architecture.md" "$EM_ROOT/data/tst-kb1/brief.md"
expect "no unrendered {KNOWLEDGE} placeholder" \
  test -z "$(grep -F '{KNOWLEDGE}' "$EM_ROOT/data/tst-kb1/brief.md")"
"$BIN/em-brief.sh" tst-kb2 demo --research >/dev/null
expect "research brief lists kb docs too" \
  grep -qF "kb/architecture.md" "$EM_ROOT/data/tst-kb2/brief.md"
rm -rf "$EM_ROOT/data/projects/demo" "$EM_ROOT/data/tst-kb1" "$EM_ROOT/data/tst-kb2"

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
expect "env marker detects cursor" test "$(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT \
  -u CODEX_SANDBOX -u CODEX_HOME -u OPENCODE -u OPENCODE_SERVER -u PI_SESSION \
  CURSOR_AGENT=1 "$BIN/em-harness.sh" detect)" = "cursor"
expect "per-task request wins" test "$(env CLAUDECODE=1 "$BIN/em-harness.sh" resolve codex)" = "codex"
expect "harness_binary passes plain names through" test "$(harness_binary claude)" = "claude"
case "$(harness_binary cursor)" in
  cursor-agent | agent) ok "harness_binary maps cursor to the agent binary" ;;
  *) fail "harness_binary maps cursor to the agent binary (got '$(harness_binary cursor)')" ;;
esac
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
echo cursor > "$EM_ROOT/config/crew-harness"
out="$("$BIN/em-bootstrap.sh" 2>&1)"
expect "cursor check targets the agent binary, never the IDE name" \
  test -z "$(grep -F 'missing: cursor (' <<< "$out")"
rm -f "$EM_ROOT/config/crew-harness"
out="$("$BIN/em-bootstrap.sh" 2>&1)"
expect "flags an unset IC window policy" grep -q 'ic-window: unset' <<< "$out"
echo bogus > "$EM_ROOT/config/ic-window"
out="$("$BIN/em-bootstrap.sh" 2>&1)"
expect "flags an invalid IC window policy" grep -q 'ic-window: invalid value bogus' <<< "$out"
echo surface > "$EM_ROOT/config/ic-window"
out="$("$BIN/em-bootstrap.sh" 2>&1)"
expect "a valid IC window policy is silent" test -z "$(grep 'ic-window:' <<< "$out")"
rm -f "$EM_ROOT/config/ic-window"
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

# ------------------------------------------------------- audit log (LOG-α)
note "em-log-event.sh — the single sanctioned writer"
TASKS="$EM_ROOT/state/tasks"
fake_meta tst-el1 demo
EL1="$TASKS/demo/tst-el1/events.jsonl"
expect "appends an event (project from meta)" "$BIN/em-log-event.sh" tst-el1 ic_spawned --actor em
expect "log created under state/tasks/<project>/<id>/" test -f "$EL1"
expect "line is valid JSON" jq -e . "$EL1"
expect "ts is ISO-8601 UTC" \
  grep -q '"ts":"20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z"' "$EL1"
expect "ts_epoch is numeric" jq -e '.ts_epoch | type == "number"' <(head -n 1 "$EL1")
expect "--project covers pre-meta events" "$BIN/em-log-event.sh" tst-el2 task_created --project demo --actor em
expect "pre-meta event landed" test -f "$TASKS/demo/tst-el2/events.jsonl"
expect_rc "rejects an unknown event type (2)" 2 "$BIN/em-log-event.sh" tst-el1 nonsense_event
expect_rc "rejects an unknown actor (2)" 2 "$BIN/em-log-event.sh" tst-el1 merged --actor boss
expect_rc "REFUSES (3) a path-escaping project" 3 "$BIN/em-log-event.sh" tst-el1 merged --project '../evil'
expect_rc "REFUSES (3) an invalid task id" 3 "$BIN/em-log-event.sh" 'Bad_ID' merged --project demo
expect "no project resolvable: event dropped, still exit 0" "$BIN/em-log-event.sh" tst-none merged
expect "dropped event wrote nothing" test -z "$(find "$TASKS" -name tst-none 2>/dev/null)"
"$BIN/em-log-event.sh" tst-el1 gate_failed --actor ic --data 'not json' 2>/dev/null
expect "invalid --data wrapped raw, never lost" grep -q '_invalid_json' "$EL1"
big="$(printf 'x%.0s' $(seq 1 8000))"
"$BIN/em-log-event.sh" tst-el1 gate_failed --actor ic --data "{\"tail\": \"$big\"}"
expect "oversized payload truncated with a marker" grep -q '"truncated":true' "$EL1"
# shellcheck disable=SC2016  # $0 is awk's, not shell's
expect "no line exceeds 4096 bytes" awk 'length($0) > 4096 { exit 1 }' "$EL1"
"$BIN/em-log-event.sh" tst-el1 merged --actor em
expect "merged auto-carries notify:true" jq -e '.notify == true' <(grep '"event":"merged"' "$EL1")

note "em-log-event.sh — notification hook (fire-and-forget)"
mkdir -p "$EM_ROOT/config/hooks"
printf '#!/usr/bin/env bash\ncat >> "%s/hook-events.jsonl"\n' "$SANDBOX" > "$EM_ROOT/config/hooks/on-event"
chmod +x "$EM_ROOT/config/hooks/on-event"
"$BIN/em-log-event.sh" tst-el1 task_paused --actor em
hook_ok=1
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q '"event":"task_paused"' "$SANDBOX/hook-events.jsonl" 2>/dev/null; then hook_ok=0; break; fi
  sleep 0.3
done
expect "hook received the event on stdin" test "$hook_ok" = 0
printf '#!/usr/bin/env bash\nexit 1\n' > "$EM_ROOT/config/hooks/on-event"
expect "a failing hook never fails the writer" "$BIN/em-log-event.sh" tst-el1 task_resumed --actor em
rm -rf "$EM_ROOT/config/hooks"

note "em-log-event.sh — concurrent appends"
(for i in $(seq 1 50); do
  "$BIN/em-log-event.sh" tst-el3 ic_signal --project demo --actor ic --data "{\"line\":\"a$i\"}"
done) &
W1PID=$!
(for i in $(seq 1 50); do
  "$BIN/em-log-event.sh" tst-el3 ic_signal --project demo --actor ic --data "{\"line\":\"b$i\"}"
done) &
W2PID=$!
wait "$W1PID" "$W2PID"
EL3="$TASKS/demo/tst-el3/events.jsonl"
expect "two concurrent writers: no line lost" test "$(wc -l < "$EL3" | tr -d ' ')" = 100
expect "two concurrent writers: no line torn" jq -e . "$EL3"

note "lifecycle instrumentation — events emitted by the sections above"
expect "brief logs task_created → brief_written, --force logs rebrief" \
  events_in_order "$TASKS/demo/tst-b1/events.jsonl" task_created brief_written rebrief brief_written
expect "green gate logs gate_started → gate_passed" \
  events_in_order "$TASKS/gp/tst-v1/events.jsonl" gate_started gate_passed
expect "red gate logs gate_failed naming the failing step" \
  jq -e '.data.failed == ["test"]' <(grep '"event":"gate_failed"' "$TASKS/gbad/tst-v2/events.jsonl")
expect "gate events carry actor=ic" \
  jq -e '.actor == "ic"' <(grep '"event":"gate_passed"' "$TASKS/gp/tst-v1/events.jsonl")
expect "local merge logs merge_approved → merged" \
  events_in_order "$TASKS/loco/tst-m1/events.jsonl" merge_approved merged
expect "promotion logs task_promoted" \
  grep -q '"event":"task_promoted"' "$TASKS/demo/tst-x2/events.jsonl"

note "em-timeline.sh — reader"
out="$("$BIN/em-timeline.sh" tst-b1 2>/dev/null)" # no meta left: glob lookup
expect "human timeline renders the events" grep -q 'task_created' <<< "$out"
expect "actor rendered" grep -q '(em)' <<< "$out"
expect "--json emits valid JSON per line" jq -e . <("$BIN/em-timeline.sh" tst-b1 --json)
B1_LINES="$(wc -l < "$TASKS/demo/tst-b1/events.jsonl" | tr -d ' ')"
expect "--json passes every line through" \
  test "$("$BIN/em-timeline.sh" tst-b1 --json | wc -l | tr -d ' ')" = "$B1_LINES"
expect "--since 0 (epoch) keeps everything" \
  test "$("$BIN/em-timeline.sh" tst-b1 --json --since 0 | wc -l | tr -d ' ')" = "$B1_LINES"
expect "--since a future ISO timestamp filters everything" \
  test -z "$("$BIN/em-timeline.sh" tst-b1 --since 2100-01-01)"
expect "--errors-only drops routine events" test -z "$("$BIN/em-timeline.sh" tst-b1 --errors-only)"
expect "--errors-only keeps gate_failed" \
  grep -q gate_failed <("$BIN/em-timeline.sh" tst-v2 --errors-only 2>/dev/null)
"$BIN/em-log-event.sh" tst-amb task_created --project demo --actor em
"$BIN/em-log-event.sh" tst-amb task_created --project loco --actor em
expect_rc "ambiguous id demands --project" 1 "$BIN/em-timeline.sh" tst-amb
expect "--project disambiguates" "$BIN/em-timeline.sh" tst-amb --project loco
expect_rc "task without a log fails plainly" 1 "$BIN/em-timeline.sh" tst-nolog
rm -f "$EM_ROOT/state/tst-el1.meta" # nothing in flight for the watcher cases

# ---------------------------------------------------------- budgets (BUD-α)
note "lib/budget.sh — spec parsing and formatting"
# shellcheck source=bin/lib/budget.sh
source "$BIN/lib/budget.sh"
expect "wall minutes parse" test "$(parse_budget_spec wall=45m)" = "wall_seconds=2700"
expect "wall hours parse" test "$(parse_budget_spec wall=2h)" = "wall_seconds=7200"
expect "wall seconds parse (test granularity)" test "$(parse_budget_spec wall=30s)" = "wall_seconds=30"
expect "bare wall number means minutes" test "$(parse_budget_spec wall=45)" = "wall_seconds=2700"
expect "fractional M tokens parse" test "$(parse_budget_spec tokens=1.5M)" = "tokens=1500000"
expect "k tokens parse" test "$(parse_budget_spec tokens=800k)" = "tokens=800000"
expect "cost normalized to a JSON number" test "$(parse_budget_spec cost=2)" = "cost_usd=2.00"
expect "combined spec parses" \
  test "$(parse_budget_spec wall=1m,tokens=800k | tr '\n' ' ')" = "wall_seconds=60 tokens=800000 "
expect_rc "unknown dimension fails" 1 parse_budget_spec speed=11
expect_rc "malformed wall fails" 1 parse_budget_spec wall=4x5
expect_rc "malformed pair fails" 1 parse_budget_spec wall
expect "fmt_duration humanizes hours" test "$(fmt_duration 3900)" = "1h05m"
expect "fmt_tokens humanizes M" test "$(fmt_tokens 1500000)" = "1.5M"

note "em-brief.sh --budget — envelope declared at brief time"
"$BIN/em-brief.sh" tst-bu1 demo --budget wall=45m,tokens=1.5M >/dev/null
BU1="$EM_ROOT/state/tasks/demo/tst-bu1/budget.json"
expect "budget.json written at brief" test -f "$BU1"
expect "limits recorded" \
  jq -e '.limits.wall_seconds == 2700 and .limits.tokens == 1500000 and .source == "task"' "$BU1"
expect "brief renders the budget section" \
  grep -q 'resource envelope: wall-clock 45m, tokens 1.5M' "$EM_ROOT/data/tst-bu1/brief.md"
expect "no unrendered {BUDGET} placeholder" \
  test -z "$(grep -F '{BUDGET}' "$EM_ROOT/data/tst-bu1/brief.md")"
expect "task_created carries the declared budget" \
  jq -e '.data.budget == "wall=45m,tokens=1.5M"' \
  <(grep '"event":"task_created"' "$EM_ROOT/state/tasks/demo/tst-bu1/events.jsonl")
expect "budgetless brief leaves no placeholder either" \
  test -z "$(grep -F '{BUDGET}' "$EM_ROOT/data/tst-b1/brief.md")"
expect_rc "malformed --budget dies" 1 "$BIN/em-brief.sh" tst-bu2 demo --budget wall=nope

note "em-status.sh — BUDGET column"
fake_meta tst-bc1 demo
write_budget_json tst-bc1 demo 2700 "" "" task pause
out="$("$BIN/em-status.sh" 2>/dev/null)"
expect "BUDGET column header present" grep -q ' BUDGET ' <<< "$out"
expect "budget cell shows used/limit" grep -qE 'tst-bc1 .* 0s/45m ' <<< "$out"
budget_update tst-bc1 demo '.warned.wall = true'
expect "soft-warned cell gains !" \
  grep -qE 'tst-bc1 .* 0s/45m! ' <("$BIN/em-status.sh" 2>/dev/null)
budget_update tst-bc1 demo '.state = "paused"'
expect "latched cell gains !!" \
  grep -qE 'tst-bc1 .* 0s/45m!! ' <("$BIN/em-status.sh" 2>/dev/null)
rm -f "$EM_ROOT/state/tst-bc1.meta"

note "budgets — soft threshold warns once (deterministic, crafted clock)"
fake_meta tst-sw1 demo
write_budget_json tst-sw1 demo 100 "" "" task pause
mkdir -p "$TASKS/demo/tst-sw1"
# 85s of the 100s limit already elapsed: past the 80% soft threshold.
jq -cn --argjson ep "$(($(date +%s) - 85))" \
  '{ts: "crafted", ts_epoch: $ep, task: "tst-sw1", project: "demo",
    event: "ic_spawned", actor: "em", data: {}}' >> "$TASKS/demo/tst-sw1/events.jsonl"
out="$(budget_pass tst-sw1 "$(date +%s)")"
expect "soft threshold warns without firing a wake" test -z "$out"
expect "budget_warning logged" \
  grep -q '"event":"budget_warning"' "$TASKS/demo/tst-sw1/events.jsonl"
expect "warned latch set" jq -e '.warned.wall == true' "$TASKS/demo/tst-sw1/budget.json"
rm -f "$EM_ROOT/state/.watch.budget.tst-sw1"
out="$(budget_pass tst-sw1 "$(date +%s)")"
expect "second pass never re-warns" \
  test "$(grep -c '"event":"budget_warning"' "$TASKS/demo/tst-sw1/events.jsonl")" = 1
expect "spend cached for cheap display" \
  jq -e '.spend.wall_seconds >= 85' "$TASKS/demo/tst-sw1/budget.json"
rm -f "$EM_ROOT/state/tst-sw1.meta"

note "budgets — claude token meter adapter (BUD-β)"
export EM_CLAUDE_SESSIONS_DIR="$SANDBOX/claude-sessions"
fake_meta tst-tk1 demo
printf 'harness=claude\n' >> "$EM_ROOT/state/tst-tk1.meta"
munged="$(printf '%s' "$EM_ROOT/worktrees/tst-tk1" | tr -c '[:alnum:]' '-')"
mkdir -p "$EM_CLAUDE_SESSIONS_DIR/$munged"
cat > "$EM_CLAUDE_SESSIONS_DIR/$munged/s1.jsonl" <<'EOF'
{"type":"assistant","message":{"usage":{"input_tokens":10,"output_tokens":40,"cache_read_input_tokens":9999,"cache_creation_input_tokens":5000}}}
{"type":"user","message":{"role":"user"}}
garbage not json
{"type":"assistant","message":{"usage":{"input_tokens":20,"output_tokens":30}}}
EOF
expect "meter sums assistant input+output, skips cache and garbage" \
  test "$("$BIN/lib/meter/claude.sh" tst-tk1)" = 100
fake_meta tst-tk2 demo
mkdir -p "$EM_CLAUDE_SESSIONS_DIR/$(printf '%s' "$EM_ROOT/worktrees/tst-tk2" | tr -c '[:alnum:]' '-')"
expect "empty session dir meters 0" test "$("$BIN/lib/meter/claude.sh" tst-tk2)" = 0
fake_meta tst-tk3 demo
expect_rc "missing session dir is unmeterable (1)" 1 "$BIN/lib/meter/claude.sh" tst-tk3

note "budgets — token and cost enforcement via the meter (BUD-β)"
write_budget_json tst-tk1 demo "" 80 "" task warn-only
out="$(budget_pass tst-tk1 "$(date +%s)")"
expect "token hard threshold fires" \
  test "$out" = "budget tst-tk1: tokens exceeded — warn-only (100/80)"
expect "token spend cached and unmeterable cleared" \
  jq -e '.spend.tokens == 100 and (.unmeterable | length) == 0' "$TASKS/demo/tst-tk1/budget.json"
write_budget_json tst-tk1 demo "" 120 "" task pause
rm -f "$EM_ROOT/state/.watch.budget.tst-tk1"
out="$(budget_pass tst-tk1 "$(date +%s)")"
expect "token soft threshold warns without a wake" test -z "$out"
expect "warned.tokens latched" jq -e '.warned.tokens == true' "$TASKS/demo/tst-tk1/budget.json"
mkdir -p "$EM_ROOT/config"
printf 'usd_per_mtok_claude=50000\n' > "$EM_ROOT/config/budgets.conf"
write_budget_json tst-tk1 demo "" "" 2.00 task warn-only
rm -f "$EM_ROOT/state/.watch.budget.tst-tk1"
out="$(budget_pass tst-tk1 "$(date +%s)")"
# shellcheck disable=SC2016  # the $ signs are literal USD amounts
expect "cost limit enforces with the configured rate" \
  test "$out" = 'budget tst-tk1: cost exceeded — warn-only ($5.00/$2.00)'
rm -f "$EM_ROOT/config/budgets.conf" "$EM_ROOT/state/tst-tk1.meta" \
  "$EM_ROOT/state/tst-tk2.meta" "$EM_ROOT/state/tst-tk3.meta"

note "budgets — default resolution order (BUD-2)"
mkdir -p "$EM_ROOT/data/projects/demo"
printf 'wall=30m\n' > "$EM_ROOT/data/projects/demo/budget"
expect "project default resolves" \
  test "$(resolve_default_budget_spec demo)" = "wall=30m project"
printf 'budget=wall=20m\n' > "$EM_ROOT/config/budgets.conf"
expect "project default beats the global" \
  test "$(resolve_default_budget_spec demo)" = "wall=30m project"
rm -f "$EM_ROOT/data/projects/demo/budget"
expect "global default when no project file" \
  test "$(resolve_default_budget_spec demo)" = "wall=20m global"
rm -f "$EM_ROOT/config/budgets.conf"
expect_rc "no defaults configured fails" 1 resolve_default_budget_spec demo
make_project pbud
expect "project-add records a default budget" \
  "$BIN/em-project-add.sh" pbud --desc 'budgeted project' --mode direct-PR --budget wall=25m
expect "default budget file written" \
  test "$(cat "$EM_ROOT/data/projects/pbud/budget")" = "wall=25m"
make_project pbud2
expect_rc "project-add refuses a malformed budget" 1 \
  "$BIN/em-project-add.sh" pbud2 --desc x --budget wall=zz

# ------------------------------------------------------------- M2: em-watch
note "em-watch.sh — signal/stale/check/heartbeat (fast timers)"
watch_fast() {
  env EM_POLL=1 EM_SIGNAL_GRACE=1 EM_HEARTBEAT=2 EM_HEARTBEAT_MAX=8 \
    EM_CHECK_INTERVAL=1 EM_CHECK_TIMEOUT=5 "$BIN/em-watch.sh"
}
out="$(watch_fast)"
expect "reports idle with no tasks in flight" test "$out" = "idle"
printf 'window=em-tst-w1\nproject=demo\n' > "$EM_ROOT/state/tst-w1.meta"
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
WEV="$EM_ROOT/state/tasks/demo/tst-w1/events.jsonl"
expect "watcher logs ic_signal per new status line" \
  test "$(grep -c '"event":"ic_signal"' "$WEV")" = 2
expect "ic_signal carries the status line text" grep -q '"line":"starting: warming up"' "$WEV"
expect "stale wake logs stall_detected" grep -q '"event":"stall_detected"' "$WEV"
rm -f "$EM_ROOT/state/tst-w1".* "$EM_ROOT/state/.watch."*
expect "event log survives the watcher-state wipe (LOG-8)" jq -e . "$WEV"

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
  expect_rc "spawn refuses without a window policy or flag" 1 \
    "$BIN/em-spawn.sh" tst-s1 demo
  echo ask > "$EM_ROOT/config/ic-window"
  expect_rc "spawn refuses under an 'ask' policy with no flag" 1 \
    "$BIN/em-spawn.sh" tst-s1 demo
  expect_rc "spawn refuses two conflicting visibility flags" 1 \
    "$BIN/em-spawn.sh" tst-s1 demo --surface --bg
  # A background standing policy covers the remaining lifecycle cases.
  echo bg > "$EM_ROOT/config/ic-window"

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
  expect "bg policy leaves the window unsurfaced" test "$(active_em_window)" != em-tst-s1
  expect "ic_spawned records surfaced=false under bg" \
    grep -q '"surfaced":false' "$EM_ROOT/state/tasks/demo/tst-s1/events.jsonl"
  expect_rc "spawn refuses a duplicate task" 1 "$BIN/em-spawn.sh" tst-s1 demo
  expect "budgetless dispatch writes an unlimited snapshot" \
    jq -e '.source == "none" and .limits.wall_seconds == null' \
    "$EM_ROOT/state/tasks/demo/tst-s1/budget.json"
  expect "one-time unmetered notice logged" \
    grep -q '"reason":"unmetered"' "$EM_ROOT/state/tasks/demo/tst-s1/events.jsonl"
  # PR events for the LOG-5 lifecycle-chain assertion at teardown.
  "$BIN/em-pr-check.sh" tst-s1 https://github.com/o/r/pull/11 >/dev/null 2>&1
  PATH="$SANDBOX/fakegh:$PATH" bash "$EM_ROOT/state/tst-s1.check.sh" >/dev/null

  note "em-spawn.sh — window visibility (flag overrides policy)"
  "$BIN/em-brief.sh" tst-sv demo >/dev/null
  fill_task tst-sv
  # Standing policy is bg, but the per-dispatch --surface flag wins.
  expect "spawn --surface succeeds despite the bg policy" \
    "$BIN/em-spawn.sh" tst-sv demo --surface
  expect "--surface makes the IC window active" test "$(active_em_window)" = em-tst-sv
  expect "ic_spawned records surfaced=true under --surface" \
    grep -q '"surfaced":true' "$EM_ROOT/state/tasks/demo/tst-sv/events.jsonl"
  "$BIN/em-brief.sh" tst-sb demo >/dev/null
  fill_task tst-sb
  # An 'ask' policy still dispatches when the flag decides it.
  echo ask > "$EM_ROOT/config/ic-window"
  expect "spawn --bg succeeds under an 'ask' policy" \
    "$BIN/em-spawn.sh" tst-sb demo --bg
  expect "--bg does not steal the active window" test "$(active_em_window)" = em-tst-sv
  echo bg > "$EM_ROOT/config/ic-window"

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
  expect_rc "refused teardown never purges (--purge-logs)" 3 "$BIN/em-teardown.sh" tst-s1 --purge-logs
  expect "audit log intact after the refused purge" \
    test -s "$EM_ROOT/state/tasks/demo/tst-s1/events.jsonl"
  rm "$WT/tst-s1/scratch.txt"
  expect "teardown succeeds once the worktree is clean" "$BIN/em-teardown.sh" tst-s1
  expect "worktree removed" test ! -e "$WT/tst-s1"
  expect_rc "window killed" 1 find_window tst-s1
  expect "volatile state cleared" test ! -e "$META"
  expect "durable data/<id>/ kept" test -f "$BRIEF" # tst-b1 untouched
  expect "brief of the torn-down task kept too" test -f "$EM_ROOT/data/tst-s1/brief.md"
  S1EV="$EM_ROOT/state/tasks/demo/tst-s1/events.jsonl"
  expect "event log retained after teardown (LOG-9)" jq -e . "$S1EV"
  expect "refusal logged before the clean teardown" \
    grep -q '"reason":"unlanded-work"' "$S1EV"
  expect "full lifecycle event chain in order (LOG-5)" events_in_order "$S1EV" \
    task_created brief_written worktree_created ic_spawned pr_opened merged \
    teardown_refused teardown_completed task_closed
  expect "em-budget show works on a closed task" \
    grep -q 'source: none' <("$BIN/em-budget.sh" show tst-s1 2>/dev/null)

  note "research lifecycle — scratch worktree, report-gated teardown"
  "$BIN/em-brief.sh" tst-x3 demo --research >/dev/null
  fill_task tst-x3
  expect "research spawn succeeds" "$BIN/em-spawn.sh" tst-x3 demo --research
  expect "meta records kind=research" grep -qx 'kind=research' "$EM_ROOT/state/tst-x3.meta"
  echo scratch-mess > "$WT/tst-x3/junk.txt"
  expect_rc "teardown REFUSES (3) without a report" 3 "$BIN/em-teardown.sh" tst-x3
  expect "no-report refusal logged" \
    grep -q '"reason":"no-report"' "$EM_ROOT/state/tasks/demo/tst-x3/events.jsonl"
  echo "# findings" > "$EM_ROOT/data/tst-x3/report.md"
  expect "with the report, scratch mess is no obstacle" "$BIN/em-teardown.sh" tst-x3
  expect "report survives teardown" test -f "$EM_ROOT/data/tst-x3/report.md"
  expect "research teardown logs report_delivered → task_closed" events_in_order \
    "$EM_ROOT/state/tasks/demo/tst-x3/events.jsonl" report_delivered teardown_completed task_closed

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
  "$BIN/em-brief.sh" tst-x5 demo >/dev/null
  fill_task tst-x5
  expect_rc "unverified cursor refused without the trial escape hatch" 1 \
    env -u EM_LAUNCH_OVERRIDE "$BIN/em-spawn.sh" tst-x5 demo cursor
  echo cursor > "$EM_ROOT/config/verified-harnesses"
  expect "verified cursor dispatches" \
    env -u EM_LAUNCH_OVERRIDE "$BIN/em-spawn.sh" tst-x5 demo cursor
  expect "meta records harness=cursor" grep -qx 'harness=cursor' "$EM_ROOT/state/tst-x5.meta"
  expect "cursor launch targets the agent binary with --force" \
    grep -qE '^launch=(cursor-)?agent --force ' "$EM_ROOT/state/tst-x5.meta"
  expect "cursor spawn installs no claude hook" test ! -e "$WT/tst-x5/.claude"
  expect "cursor task tears down cleanly" "$BIN/em-teardown.sh" tst-x5
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
  RLEV="$EM_ROOT/state/tasks/demo/tst-rl1/events.jsonl"
  expect "relaunch logged as rebrief with the note" \
    jq -e 'select(.event == "rebrief") | .data.note' "$RLEV"
  expect "relaunch never logs a second ic_spawned (wall-clock anchor)" \
    test "$(grep -c '"event":"ic_spawned"' "$RLEV")" = 1
  expect_rc "relaunch of an unknown task fails" 1 "$BIN/em-relaunch.sh" tst-zz
  "$BIN/em-teardown.sh" tst-rl1 --purge-logs >/dev/null 2>&1
  expect "--purge-logs removes the audit log after a clean teardown" \
    test ! -e "$EM_ROOT/state/tasks/demo/tst-rl1"

  note "em-status.sh — default busy regex covers cursor's working indicator"
  cat > "$SANDBOX/fakebin/cursorish" <<'EOF'
#!/usr/bin/env bash
echo "⠘⠣ Running  921 tokens"
exec sleep 600
EOF
  chmod +x "$SANDBOX/fakebin/cursorish"
  "$BIN/em-brief.sh" tst-cb1 demo >/dev/null
  fill_task tst-cb1
  env EM_LAUNCH_OVERRIDE="$SANDBOX/fakebin/cursorish" \
    "$BIN/em-spawn.sh" tst-cb1 demo cursor >/dev/null 2>&1
  expect "cursor-style busy line appears" wait_for_pane tst-cb1 'Running  921 tokens'
  expect "default regex classifies the cursor pane busy" \
    grep -qE 'tst-cb1 +demo +[^ ]+ +busy' <("$BIN/em-status.sh" 2>/dev/null)
  "$BIN/em-teardown.sh" tst-cb1 >/dev/null 2>&1

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

  note "budgets — compressed-time pause enforcement (BUD-α flagship)"
  watch_budget() {
    env EM_POLL=1 EM_BUDGET_INTERVAL=1 EM_HEARTBEAT=60 "$BIN/em-watch.sh"
  }
  "$BIN/em-brief.sh" tst-bw1 demo >/dev/null
  fill_task tst-bw1
  "$BIN/em-spawn.sh" tst-bw1 demo --budget wall=3s >/dev/null 2>&1
  BW1="$EM_ROOT/state/tasks/demo/tst-bw1/budget.json"
  BWEV="$EM_ROOT/state/tasks/demo/tst-bw1/events.jsonl"
  expect "spawn-time --budget recorded" jq -e '.limits.wall_seconds == 3' "$BW1"
  expect "dispatch budget note appended to the brief" \
    grep -q '## Budget (declared at dispatch)' "$EM_ROOT/data/tst-bw1/brief.md"
  expect "IC started" wait_for_pane tst-bw1 FAKE_IC_READY
  rm -f "$EM_ROOT/state/.watch."*
  bout=""
  for _ in 1 2 3 4 5; do
    out="$(run_bounded 20 watch_budget)"
    case "$out" in budget*)
      bout="$out"
      break
      ;;
    esac
  done
  expect "budget wake fires with the documented grammar" \
    grep -qE '^budget tst-bw1: wall exceeded — paused \([0-9]+[sm]/3s\)$' <<< "$bout"
  expect "budget_exceeded carries notify:true" \
    jq -e '.notify == true' <(grep '"event":"budget_exceeded"' "$BWEV" | head -n 1)
  expect "task_paused carries notify:true" \
    jq -e '.notify == true' <(grep '"event":"task_paused"' "$BWEV" | head -n 1)
  expect "snapshot latched to paused" jq -e '.state == "paused"' "$BW1"
  pane_tty="$(tmux_cmd display-message -p -t "$(find_window tst-bw1)" '#{pane_tty}')"
  ic_state() {
    ps -t "${pane_tty#/dev/}" -o state=,comm= 2>/dev/null |
      awk '$2 ~ /sleep/ { print substr($1, 1, 1); exit }'
  }
  expect "IC process actually stopped (SIGSTOP)" test "$(ic_state)" = "T"
  expect "enforcement preserves the worktree" test -d "$WT/tst-bw1"
  expect "enforcement preserves the meta" test -f "$EM_ROOT/state/tst-bw1.meta"
  rm -f "$EM_ROOT/state/.watch.next-beat"
  out="$(run_bounded 20 env EM_POLL=1 EM_BUDGET_INTERVAL=1 EM_HEARTBEAT=2 \
    EM_HEARTBEAT_MAX=8 "$BIN/em-watch.sh")"
  expect "latched task never re-fires the budget wake" test "$out" = "heartbeat"
  sleep 2 # guarantee a measurable paused interval for the elapsed check
  el1="$(budget_elapsed_seconds tst-bw1 demo)"
  t0="$(grep '"event":"ic_spawned"' "$BWEV" | head -n 1 | jq -r .ts_epoch)"
  expect "paused time excluded from elapsed (BUD-9)" \
    test "$el1" -lt "$(($(date +%s) - t0))"
  rm -f "$EM_ROOT/state/.watch."*
  el2="$(budget_elapsed_seconds tst-bw1 demo)"
  expect "elapsed never resets across a watcher/EM restart" test "$el2" -ge "$el1"
  expect "extend raises the limit and resumes" "$BIN/em-budget.sh" extend tst-bw1 wall=+1m
  expect "budget_extended then task_resumed logged (actor director)" \
    events_in_order "$BWEV" budget_extended task_resumed
  expect "IC process running again" grep -qE '^[SRI]' <(ic_state)
  expect "snapshot back to ok against the new limit" \
    jq -e '.state == "ok" and .limits.wall_seconds == 63' "$BW1"
  expect "show reports the new limit" grep -q '/ 1m' <("$BIN/em-budget.sh" show tst-bw1)
  expect "director pause works" "$BIN/em-budget.sh" pause tst-bw1
  expect "director pause logged with actor=director" \
    jq -e '.actor == "director"' <(grep '"event":"task_paused"' "$BWEV" | tail -n 1)
  expect "director resume works" "$BIN/em-budget.sh" resume tst-bw1
  "$BIN/em-teardown.sh" tst-bw1 >/dev/null 2>&1

  note "budgets — --on-exceed warn-only and kill"
  "$BIN/em-brief.sh" tst-bw2 demo >/dev/null
  fill_task tst-bw2
  "$BIN/em-spawn.sh" tst-bw2 demo --budget wall=2s --on-exceed warn-only >/dev/null 2>&1
  rm -f "$EM_ROOT/state/.watch."*
  bout=""
  for _ in 1 2 3 4 5; do
    out="$(run_bounded 20 watch_budget)"
    case "$out" in budget*)
      bout="$out"
      break
      ;;
    esac
  done
  expect "warn-only wake fires" \
    grep -qE '^budget tst-bw2: wall exceeded — warn-only ' <<< "$bout"
  expect "warn-only leaves the IC running" find_window tst-bw2
  expect "warn-only latches state=exceeded" \
    jq -e '.state == "exceeded"' "$EM_ROOT/state/tasks/demo/tst-bw2/budget.json"
  "$BIN/em-teardown.sh" tst-bw2 >/dev/null 2>&1
  "$BIN/em-brief.sh" tst-bw3 demo >/dev/null
  fill_task tst-bw3
  "$BIN/em-spawn.sh" tst-bw3 demo --budget wall=2s --on-exceed kill >/dev/null 2>&1
  rm -f "$EM_ROOT/state/.watch."*
  bout=""
  for _ in 1 2 3 4 5; do
    out="$(run_bounded 20 watch_budget)"
    case "$out" in budget*)
      bout="$out"
      break
      ;;
    esac
  done
  expect "kill wake fires" grep -qE '^budget tst-bw3: wall exceeded — killed ' <<< "$bout"
  expect_rc "kill removes the window" 1 find_window tst-bw3
  expect "kill preserves the worktree (never destroys work)" test -d "$WT/tst-bw3"
  expect "task_killed logged" \
    grep -q '"event":"task_killed"' "$EM_ROOT/state/tasks/demo/tst-bw3/events.jsonl"
  "$BIN/em-teardown.sh" tst-bw3 >/dev/null 2>&1

  note "budgets — dispatch picks up project/global defaults (BUD-β)"
  mkdir -p "$EM_ROOT/data/projects/demo"
  printf 'wall=30m\n' > "$EM_ROOT/data/projects/demo/budget"
  "$BIN/em-brief.sh" tst-bd1 demo >/dev/null
  fill_task tst-bd1
  "$BIN/em-spawn.sh" tst-bd1 demo >/dev/null 2>&1
  expect "project default applied at dispatch" \
    jq -e '.source == "project" and .limits.wall_seconds == 1800' \
    "$EM_ROOT/state/tasks/demo/tst-bd1/budget.json"
  "$BIN/em-teardown.sh" tst-bd1 >/dev/null 2>&1
  rm -f "$EM_ROOT/data/projects/demo/budget"
  printf 'budget=wall=20m\n' > "$EM_ROOT/config/budgets.conf"
  "$BIN/em-brief.sh" tst-bd2 demo >/dev/null
  fill_task tst-bd2
  "$BIN/em-spawn.sh" tst-bd2 demo >/dev/null 2>&1
  expect "global default applied when no project default" \
    jq -e '.source == "global" and .limits.wall_seconds == 1200' \
    "$EM_ROOT/state/tasks/demo/tst-bd2/budget.json"
  "$BIN/em-teardown.sh" tst-bd2 >/dev/null 2>&1
  rm -f "$EM_ROOT/config/budgets.conf"

  note "budgets — soft-threshold nudge reaches the IC pane (BUD-β)"
  tmux_cmd new-window -d -t '=em:' -n em-tst-nu1 -c "$SANDBOX" 'bash --norc -i' 2>/dev/null ||
    tmux_cmd new-window -d -t '=em:' -n em-tst-nu1 -c "$SANDBOX"
  fake_meta tst-nu1 demo
  write_budget_json tst-nu1 demo 100 "" "" task pause
  mkdir -p "$TASKS/demo/tst-nu1"
  jq -cn --argjson ep "$(($(date +%s) - 85))" \
    '{ts: "crafted", ts_epoch: $ep, task: "tst-nu1", project: "demo",
      event: "ic_spawned", actor: "em", data: {}}' >> "$TASKS/demo/tst-nu1/events.jsonl"
  budget_pass tst-nu1 "$(date +%s)" >/dev/null
  expect "nudge line typed into the pane" wait_for_pane tst-nu1 'EM notice:'
  rm -f "$EM_ROOT/state/.watch.budget.tst-nu1"
  budget_pass tst-nu1 "$(date +%s)" >/dev/null
  sleep 1
  expect "nudge sent exactly once" \
    test "$("$BIN/em-peek.sh" tst-nu1 200 2>/dev/null | grep -c 'EM notice:')" = 1
  tmux_cmd kill-window -t "$(find_window tst-nu1)" 2>/dev/null
  rm -f "$EM_ROOT/state/tst-nu1.meta"

  note "budgets — research grace: demand the report, then pause (BUD-10)"
  printf 'grace_seconds=2\n' > "$EM_ROOT/config/budgets.conf"
  "$BIN/em-brief.sh" tst-gr1 demo --research >/dev/null
  fill_task tst-gr1
  "$BIN/em-spawn.sh" tst-gr1 demo --research --budget wall=2s >/dev/null 2>&1
  rm -f "$EM_ROOT/state/.watch."*
  bout=""
  for _ in 1 2 3 4 5; do
    out="$(run_bounded 20 watch_budget)"
    case "$out" in budget*)
      bout="$out"
      break
      ;;
    esac
  done
  expect "grace wake demands the report" \
    grep -qE '^budget tst-gr1: wall exceeded — report demanded \(grace 2s\)$' <<< "$bout"
  expect "IC told to write the report" wait_for_pane tst-gr1 'write the report now'
  expect "IC still running during grace" find_window tst-gr1
  expect "budget_exceeded logged with action grace" \
    jq -e '.data.action == "grace"' \
    <(grep '"event":"budget_exceeded"' "$EM_ROOT/state/tasks/demo/tst-gr1/events.jsonl" | head -n 1)
  sleep 2
  rm -f "$EM_ROOT/state/.watch.budget.tst-gr1"
  bout=""
  for _ in 1 2 3 4 5; do
    out="$(run_bounded 20 watch_budget)"
    case "$out" in budget*)
      bout="$out"
      break
      ;;
    esac
  done
  expect "grace expiry pauses" test "$bout" = "budget tst-gr1: grace expired — paused"
  expect "snapshot latched paused after grace" \
    jq -e '.state == "paused"' "$EM_ROOT/state/tasks/demo/tst-gr1/budget.json"
  "$BIN/em-budget.sh" resume tst-gr1 >/dev/null 2>&1 # never leave a stopped IC behind
  echo "# findings" > "$EM_ROOT/data/tst-gr1/report.md"
  "$BIN/em-teardown.sh" tst-gr1 >/dev/null 2>&1
  rm -f "$EM_ROOT/config/budgets.conf"
fi

# ----------------------------------------------------------------- backlog
note "em-backlog.sh — scripted queue: add/start/done/unblocked/validate"
BLG="$EM_ROOT/data/backlog.md"
rm -f "$BLG"
expect "add creates the backlog with an in-flight entry" \
  "$BIN/em-backlog.sh" add tst-bl1 demo "first task"
expect "entry lands under In flight with a since date" \
  grep -qF -- '- [ ] tst-bl1 - first task (repo: demo, since ' "$BLG"
expect_rc "duplicate add refused" 1 "$BIN/em-backlog.sh" add tst-bl1 demo "again"
expect_rc "invalid task id refused" 1 "$BIN/em-backlog.sh" add 'Bad_ID' demo "x"
expect "blocked add goes to Queued" "$BIN/em-backlog.sh" add tst-bl2 demo \
  "second task" --blocked-by tst-bl1 --reason "same area"
expect "queued line records blocker and reason" test \
  "$("$BIN/em-backlog.sh" list queued)" = \
  '- [ ] tst-bl2 - second task (repo: demo) blocked-by: tst-bl1 - same area'
expect_rc "--reason without --blocked-by refused" 1 \
  "$BIN/em-backlog.sh" add tst-bl3 demo "x" --reason "orphan reason"
expect "unblocked prints nothing while the blocker is open" \
  test -z "$("$BIN/em-backlog.sh" unblocked)"
expect "validate passes a well-formed file" "$BIN/em-backlog.sh" validate
expect "done moves the entry to Done" \
  "$BIN/em-backlog.sh" 'done' tst-bl1 "https://example.test/pr/1"
expect "done line checked off with outcome and date" \
  grep -qF -- '- [x] tst-bl1 - first task - https://example.test/pr/1 (' "$BLG"
expect "blocker landed: the queued task is now unblocked" \
  test "$("$BIN/em-backlog.sh" unblocked)" = tst-bl2
expect "start moves queued to in flight" "$BIN/em-backlog.sh" start tst-bl2
expect "started entry carries a since date" \
  grep -qF -- '- [ ] tst-bl2 - second task (repo: demo, since ' "$BLG"
expect_rc "start on an in-flight entry refused" 1 "$BIN/em-backlog.sh" start tst-bl2
expect_rc "done on an already-done entry refused" 1 \
  "$BIN/em-backlog.sh" 'done' tst-bl1 "again"
for i in 1 2 3 4 5 6 7 8 9 10 11; do
  "$BIN/em-backlog.sh" add "tst-tr$i" demo "trim filler $i" >/dev/null
  "$BIN/em-backlog.sh" 'done' "tst-tr$i" "local main" >/dev/null
done
expect "Done keeps only the 10 most recent entries" \
  test "$(grep -c '^- \[x\] ' "$BLG")" = 10
expect "newest done entry is listed first" \
  grep -qF tst-tr11 <(grep -m 1 '^- \[x\] ' "$BLG")
echo '- [ ] not a valid line' >> "$BLG"
expect_rc "validate flags a malformed line" 1 "$BIN/em-backlog.sh" validate
grep -vF -- '- [ ] not a valid line' "$BLG" > "$BLG.fix" && mv "$BLG.fix" "$BLG"
expect "remove drops an entry" "$BIN/em-backlog.sh" remove tst-bl2
expect_rc "removed entry is gone" 1 grep -qF 'tst-bl2' "$BLG"
fake_meta tst-blx demo
expect "in-flight task missing from the backlog only warns" \
  grep -q "tst-blx" <("$BIN/em-backlog.sh" validate 2>&1)
expect "cross-check warnings do not fail validate" "$BIN/em-backlog.sh" validate
rm -f "$EM_ROOT/state/tst-blx.meta"
rm -f "$BLG"

# ------------------------------------------------- em-reset: runs dead last
# (a successful reset empties the sandbox fleet; nothing may run after it)
note "em-reset.sh — dry run, refusals, then the full factory reset"
mkdir -p "$EM_ROOT/data" "$EM_ROOT/config"
echo '# prefs' > "$EM_ROOT/data/director.md"
echo claude > "$EM_ROOT/config/crew-harness"
ln -s "$SANDBOX/seed-fs1" "$EM_ROOT/projects/linked"
out="$("$BIN/em-reset.sh" 2>&1)"
expect "dry run exits 0" "$BIN/em-reset.sh"
expect "dry run lists a clone" grep -q 'would remove: projects/demo' <<< "$out"
expect "dry run marks symlinks as unlink-only" grep -q 'projects/linked (symlink' <<< "$out"
expect "dry run flags a no-remote clone" grep -q 'projects/loco has no remote' <<< "$out"
expect "dry run changes nothing" test -d "$EM_ROOT/projects/demo/.git"
expect_rc "--force without --yes fails plainly" 1 "$BIN/em-reset.sh" --force
expect_rc "rejects an unknown flag" 1 "$BIN/em-reset.sh" --nope
fake_meta tst-rs1 demo
expect_rc "REFUSES (3) with a task in flight" 3 "$BIN/em-reset.sh" --yes
expect "refusal changes nothing" test -f "$EM_ROOT/state/tst-rs1.meta"
rm -f "$EM_ROOT/state/tst-rs1.meta"
expect_rc "REFUSES (3) while work exists nowhere else" 3 "$BIN/em-reset.sh" --yes
expect "--yes --force resets anyway" "$BIN/em-reset.sh" --yes --force
expect "projects emptied" test -z "$(ls -A "$EM_ROOT/projects")"
expect "worktrees emptied" test -z "$(ls -A "$EM_ROOT/worktrees" 2>/dev/null)"
expect "state emptied (lock and watch files gone)" test -z "$(ls -A "$EM_ROOT/state")"
expect "task records and registry gone" test ! -e "$EM_ROOT/data/tst-b1" -a ! -e "$EM_ROOT/data/projects.md"
expect "data/director.md kept" grep -q prefs "$EM_ROOT/data/director.md"
expect "config kept" test -f "$EM_ROOT/config/crew-harness"
expect "symlink target untouched" test -d "$SANDBOX/seed-fs1/.git"
if command -v tmux >/dev/null; then
  expect_rc "task windows killed" 1 find_window tst-io
fi
expect "reset instance reports an idle fleet" grep -q 'no tasks in flight' <("$BIN/em-status.sh" 2>/dev/null)
expect "second reset finds nothing to do" grep -q 'nothing to reset' <("$BIN/em-reset.sh" 2>&1)

# ------------------------------------------------------------------ summary
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
