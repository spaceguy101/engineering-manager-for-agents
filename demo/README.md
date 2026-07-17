# README demo

`demo.gif` (embedded at the top of the repo README) is rendered with
[VHS](https://github.com/charmbracelet/vhs) from `demo.tape`.

The fixture (`fixture.sh`) stages a small **synthetic** fleet — a sandbox
project, two in-flight tasks with a plausible backdated event history, a
queued task, and staged tmux panes — under `demo/.fleet` (gitignored), on
an isolated tmux server (`tmux -L em-demo`). The commands shown in the gif
are the real toolbelt running over that state; no output is mocked.

Regenerate from the repo root:

```sh
brew install vhs   # or: go install github.com/charmbracelet/vhs@latest
vhs demo/demo.tape
```
