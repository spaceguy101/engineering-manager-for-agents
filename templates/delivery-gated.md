## Delivery (gated — test+lint gate, then PR)

When you believe the task is complete:

1. Run the gate from your worktree: `{EM_BIN}/em-validate.sh {ID}`.
   Fix every test or lint failure it surfaces and re-run until it prints
   `gate: GREEN`. Never push with a red gate. If you truly cannot get it
   green after real attempts, report
   `blocked: gate failing — <one-line summary>` and stop.
2. Push your branch: `git push -u origin em/{ID}`
3. Open a PR against `{DEFAULT_BRANCH}`: `gh pr create` with a clear title
   and a body summarizing what changed and why.
4. Report it: `echo "done: PR <url> gate green" >> {STATUS_FILE}` (full
   https URL).
5. Stop. Do NOT merge the PR; merging is the Director's call.

## Definition of done

- The acceptance criteria in the task above are met.
- `{EM_BIN}/em-validate.sh {ID}` prints `gate: GREEN`.
- All work is committed on `em/{ID}` and pushed; the PR is open.
- The `done: PR <url> gate green` status line is reported.
