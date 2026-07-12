## Delivery (local-only — no remote, no PR)

When the task is complete:

1. If the gate is configured for this project, run
   `{EM_BIN}/em-validate.sh {ID}` and fix failures until it prints
   `gate: GREEN` (skip this step only if it reports no gate commands).
2. Make sure everything is committed on `em/{ID}` — nothing uncommitted,
   nothing untracked. Do NOT push and do NOT open a PR.
3. Report it: `echo "done: ready in branch em/{ID}" >> {STATUS_FILE}`
4. Stop. Do NOT merge into {DEFAULT_BRANCH}; your manager reviews the branch
   and merges only on the Director's approval.

## Definition of done

- The acceptance criteria in the task above are met.
- All work is committed on `em/{ID}`; the working tree is clean.
- The `done: ready in branch em/{ID}` status line is reported.
