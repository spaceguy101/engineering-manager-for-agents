## Delivery (direct-PR)

When the task is complete:

1. Push your branch: `git push -u origin em/{ID}`
2. Open a PR against `{DEFAULT_BRANCH}`: `gh pr create` with a clear title and
   a body summarizing what changed and why.
3. Report it: `echo "done: PR <url>" >> {STATUS_FILE}` (full https URL).
4. Stop. Do NOT merge the PR; merging is the Director's call.

## Definition of done

- The acceptance criteria in the task above are met.
- All work is committed on `em/{ID}` and pushed; the PR is open.
- The `done: PR <url>` status line is reported.
