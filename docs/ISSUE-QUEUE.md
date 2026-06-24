# Issue queue and continuous runner

RepoFlow can execute an explicit ordered list of GitHub issues while reusing
the existing deterministic issue, CI, review, and merge workflows.

The queue is an orchestrator. It does not duplicate issue implementation,
resume, CI repair, automated review, or merge logic.

## Safety properties

- The manifest is the only source of task order.
- RepoFlow never selects the next issue from GitHub automatically.
- Commands remain plan-only unless `-Apply` is supplied.
- Only one task is active at a time.
- A failed task is never skipped silently.
- Passing CI is required before the review gate.
- Automated review and repair use the configured bounded limits.
- RepoFlow never merges from a queue workflow.
- A human must validate and merge the pull request explicitly.
- Queue and task checkpoints are persisted as machine-readable JSON.
- Resume reconciles the existing branch, PR, CI, review, and run state rather
  than creating replacements.

## Manifest

Use the committed schema:

```text
scripts/RepoFlow/Schemas/queue-manifest.v1.schema.json
```

Example:

```json
{
  "$schema": "./scripts/RepoFlow/Schemas/queue-manifest.v1.schema.json",
  "schemaVersion": 1,
  "name": "repo-flow implementation queue",
  "repository": "flow",
  "tasks": [
    {
      "issueNumber": 11,
      "ciMode": "require-passing",
      "automatedReview": true
    },
    {
      "issueNumber": 12,
      "repository": "report",
      "ciMode": "require-passing",
      "automatedReview": true
    }
  ]
}
```

Root properties:

- `schemaVersion`: required; currently `1`.
- `name`: optional human-readable queue name.
- `repository`: optional default registered repository name.
- `tasks`: required non-empty ordered array.

Task properties:

- `issueNumber`: required positive GitHub issue number.
- `repository`: optional registered repository override.
- `ciMode`: optional existing CI-mode override. The queue still requires a
  passing live CI result before review and never treats `skip` or `observe` as
  permission to bypass that gate.
- `automatedReview`: optional boolean; defaults to `true`. When `false`, the
  queue pauses at a manual review and merge gate after passing CI.

Unknown properties and duplicate repository/issue pairs are rejected.
Repository aliases that resolve to the same live repository and issue are also
rejected during planning.

## Dependency planning

Every issue is validated before execution.

An open dependency is accepted when it appears earlier in the same queue for
the same resolved repository. This permits an ordered manifest such as:

```text
#11 implementation
#12 depends on #11
```

An open dependency appearing later in the queue, or missing from the queue,
causes planning to fail. Closed dependencies do not need to be listed.

Before the dependent task actually starts, the normal deterministic issue
workflow validates the live dependency state again. This prevents a stale
queue checkpoint from overriding GitHub state.

## Commands

Print and validate the complete plan:

```powershell
.\rf.ps1 queue run -Manifest .\queue.json
```

Start the queue and process the current task:

```powershell
.\rf.ps1 queue run -Manifest .\queue.json -Apply
```

Continue automatically between tasks after each earlier pull request has been
manually merged and the queue has been resumed:

```powershell
.\rf.ps1 queue run -Manifest .\queue.json -Continuous -Apply
```

Resume from the persisted task checkpoint:

```powershell
.\rf.ps1 queue resume -Manifest .\queue.json
.\rf.ps1 queue resume -Manifest .\queue.json -Continuous -Apply
```

Request a pause or permanent stop:

```powershell
.\rf.ps1 queue pause -Manifest .\queue.json -Apply
.\rf.ps1 queue stop -Manifest .\queue.json -Apply
```

The short installed launcher can be used instead:

```powershell
rf queue run -Manifest .\queue.json -Continuous -Apply
```

## Execution lifecycle

For each task, RepoFlow:

1. validates the manifest, repository health, issue, and dependencies;
2. finds the deterministic issue branch and any existing pull request;
3. starts `issue run` or invokes `issue resume` when state already exists;
4. requires a pull request and a passing current-head CI result;
5. runs local `git diff --check` validation;
6. runs or reuses the exact-head bounded automated-review result;
7. pauses on review failure, manual-review outcome, repeated blockers, or
   exhausted limits;
8. pauses at the explicit merge gate when CI and review pass;
9. after the operator merges through `rf pr merge`, reconciles post-merge
   cleanup on the next queue resume;
10. marks the task complete and advances to the next explicit manifest item.

Without `-Continuous`, the queue pauses after a completed task before starting
the next one. With `-Continuous`, it advances immediately after a confirmed
merge and cleanup. It still pauses at every merge gate because queue workflows
never merge.

## Resume and idempotency

The queue stores the manifest fingerprint and rejects a changed file for an
existing active queue. This prevents edited task order or overrides from being
silently applied to saved state.

Resume delegates implementation recovery to the deterministic issue-resume
workflow. It therefore reuses existing branches, pull requests, commits,
trusted comments, CI checkpoints, and exact-head review results. Conflicting
or ambiguous live state pauses instead of creating duplicates.

A stopped queue cannot be resumed. Use `queue run` to create a fresh queue
after intentionally updating or replacing the manifest.

## State

Queue records are stored beside `.repo-flow.json` in:

```text
.repo-flow.state.json
```

State schema version `3` adds a top-level `queues` array while preserving
existing `activeRepository` and `runs` data. Version `2` state is migrated in
memory and written as version `3` on the next state mutation.

Each queue records:

- queue ID, name, status, timestamps, and manifest path/hash;
- continuous-mode setting and current task index;
- queue pause or stop reason;
- every task's position, issue, repository, CI/review overrides, status,
  phase, run ID, PR number, head SHA, timestamps, and pause reason.

Writes use the existing state lock and atomic temporary-file replacement.

## Pause and stop semantics

`queue pause` and `queue stop` identify the persisted queue by manifest path and
do not require the current file contents to match its saved fingerprint. They
update persisted state but do not terminate a currently running agent process,
Git command, or CI polling operation in the middle of that operation. The
active runner observes the request at the next durable queue checkpoint.

- Pause is resumable.
- Stop is terminal.
- Neither operation advances `currentIndex`.
- Later tasks remain pending and are not silently skipped.

## Failure handling

The queue pauses on, among other conditions:

- failed repository diagnostics;
- invalid or changed manifest state;
- unresolved or incorrectly ordered dependencies;
- branch, PR, or run-state conflicts, including an open PR without saved run state;
- agent, commit, push, or PR creation failure;
- non-passing CI after deterministic handling;
- local validation failure;
- automated-review failure or manual-review outcome;
- review/repair limit exhaustion;
- closed but unmerged pull requests;
- explicit pause or stop requests.

The task remains at the same queue position with an auditable phase and reason.
