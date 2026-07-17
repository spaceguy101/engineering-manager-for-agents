#!/usr/bin/env bash
# demo/fixture.sh — stage a small synthetic fleet for the README demo.
# Source it (the VHS tape does): it sandboxes all fleet state under
# demo/.fleet on an isolated tmux server, then replays a plausible task
# history through the real toolbelt formats. Every command shown in the
# demo gif produces genuine toolbelt output over this staged state; no
# output is mocked. Not part of the production toolbelt.
#
#   source demo/fixture.sh   # exports EM_ROOT + EM_TMUX_SOCKET
#   bin/em-status.sh         # …then drive the real scripts

DEMO_REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
export EM_ROOT="$DEMO_REPO/demo/.fleet"
export EM_TMUX_SOCKET="em-demo"

tmux -L "$EM_TMUX_SOCKET" kill-server 2>/dev/null
rm -rf "$EM_ROOT"
mkdir -p "$EM_ROOT/projects" "$EM_ROOT/state" "$EM_ROOT/data"

# shellcheck source=bin/lib/common.sh
source "$DEMO_REPO/bin/lib/common.sh"
# shellcheck source=bin/lib/budget.sh
source "$DEMO_REPO/bin/lib/budget.sh"

# --- a tiny project with an origin, like the test suite builds ------------
git init -q --bare -b main "$EM_ROOT/.origin/webapp.git"
git clone -q "$EM_ROOT/.origin/webapp.git" "$EM_ROOT/projects/webapp" 2>/dev/null
(
  cd "$EM_ROOT/projects/webapp" &&
    git checkout -qb main &&
    echo "# webapp" > README.md &&
    GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.invalid \
      GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.invalid \
      git add . && GIT_AUTHOR_NAME=demo GIT_AUTHOR_EMAIL=demo@example.invalid \
      GIT_COMMITTER_NAME=demo GIT_COMMITTER_EMAIL=demo@example.invalid \
      git commit -qm init &&
    git push -q -u origin main
)
"$DEMO_REPO/bin/em-project-add.sh" webapp --desc "the demo web app" \
  --test "npm test" --lint "npm run lint" > /dev/null

# --- helpers --------------------------------------------------------------
NOW="$(date +%s)"

iso_utc() { # <epoch>
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

past_event() { # <id> <event> <minutes-ago> <actor> [<data-json>]
  local ep=$((NOW - $3 * 60)) dir
  dir="$(task_dir "$1" webapp)"
  mkdir -p "$dir"
  jq -cn --arg ts "$(iso_utc "$ep")" --argjson ep "$ep" --arg task "$1" \
    --arg event "$2" --arg actor "$4" --argjson data "${5:-{\}}" \
    '{ts: $ts, ts_epoch: $ep, task: $task, project: "webapp",
      event: $event, actor: $actor, data: $data}' >> "$dir/events.jsonl"
}

demo_meta() { # <id> <kind> <mode>
  printf 'window=em-%s\nworktree=%s\nproject=webapp\nkind=%s\nmode=%s\nharness=claude\n' \
    "$1" "$EM_ROOT/worktrees/$1" "$2" "$3" > "$EM_ROOT/state/$1.meta"
}

demo_window() { # <name> <busy|idle>
  local keep='exec sleep 600'
  if [ "$2" = busy ]; then
    keep='printf "  ✻ Working… (esc to interrupt)\n"; exec sleep 600'
  fi
  tmux -L "$EM_TMUX_SOCKET" has-session -t '=em' 2>/dev/null ||
    tmux -L "$EM_TMUX_SOCKET" new-session -d -s em -c "$EM_ROOT"
  tmux -L "$EM_TMUX_SOCKET" new-window -d -t '=em:' -n "$1" \
    bash -c "$keep"
}

# --- task 1: build task, gate green, PR open, 38m into a 45m budget -------
PR_URL="https://github.com/acme/webapp/pull/41"
demo_meta fix-login-k3 build gated
past_event fix-login-k3 task_created 40 em '{"kind":"build","mode":"gated"}'
past_event fix-login-k3 brief_written 40 em '{"template":"brief-build.md"}'
past_event fix-login-k3 worktree_created 39 em '{"branch":"em/fix-login-k3"}'
past_event fix-login-k3 ic_spawned 38 em '{"harness":"claude","window":"em-fix-login-k3"}'
past_event fix-login-k3 gate_failed 9 ic '{"failed":"test","note":"2 failed — race persists under load"}'
past_event fix-login-k3 gate_passed 3 ic '{}'
past_event fix-login-k3 pr_opened 2 em "{\"url\":\"$PR_URL\"}"
write_budget_json fix-login-k3 webapp 2700 1500000 "" task pause
budget_update fix-login-k3 webapp \
  '.spend.tokens = 1180000 | .unmeterable = [] | .warned.wall = true'
printf 'working: reproducing the login race\nworking: fix in, running the gate\ndone: PR %s gate green\n' \
  "$PR_URL" > "$EM_ROOT/state/fix-login-k3.status"
demo_window em-fix-login-k3 idle

# --- task 2: research task, 12m into a 30m budget, still digging ----------
demo_meta audit-deps-x1 research -
past_event audit-deps-x1 task_created 13 em '{"kind":"research"}'
past_event audit-deps-x1 brief_written 13 em '{"template":"brief-research.md"}'
past_event audit-deps-x1 worktree_created 12 em '{}'
past_event audit-deps-x1 ic_spawned 12 em '{"harness":"claude","window":"em-audit-deps-x1"}'
write_budget_json audit-deps-x1 webapp 1800 "" "" task pause
printf 'working: auditing dependency freshness\n' \
  > "$EM_ROOT/state/audit-deps-x1.status"
demo_window em-audit-deps-x1 busy

# --- the queue, via the real tooling --------------------------------------
"$DEMO_REPO/bin/em-backlog.sh" add fix-login-k3 webapp "fix the login race" > /dev/null
"$DEMO_REPO/bin/em-backlog.sh" add audit-deps-x1 webapp "audit dependency freshness" > /dev/null
"$DEMO_REPO/bin/em-backlog.sh" add add-oauth-b4 webapp "add OAuth sign-in" \
  --blocked-by fix-login-k3 --reason "touches the same auth module" > /dev/null

touch "$EM_ROOT/state/.last-watcher-beat" # the demo has no live watcher
cd "$DEMO_REPO" || return 1
