# demo/demo.tape — VHS script for the README gif.
# Regenerate from the repo root:  vhs demo/demo.tape   (brew install vhs)
# The fixture stages a synthetic fleet under demo/.fleet (isolated tmux
# server, sandboxed EM_ROOT); every command below is the real toolbelt
# running over that state.

Output demo/demo.gif

Set Shell "bash"
Set FontSize 14
Set Width 1560
Set Height 700
Set Padding 16
Set TypingSpeed 25ms
Set Theme "Catppuccin Mocha"

Hide
Type "source demo/fixture.sh && clear"
Enter
Sleep 6s
Show

Type "# One EM agent runs a fleet of IC agents (tmux + git worktrees). The Director's view:"
Enter
Sleep 1.5s

Type "bin/em-status.sh"
Enter
Sleep 4s

Type "bin/em-timeline.sh fix-login-k3      # every task keeps an audit log"
Enter
Sleep 4s

Type "bin/em-budget.sh show fix-login-k3   # budgets pause runaways, never destroy work"
Enter
Sleep 3.5s

Type "bin/em-backlog.sh list               # the queue: scripted, machine-checkable"
Enter
Sleep 5s

Hide
Type "tmux -L em-demo kill-server"
Enter
