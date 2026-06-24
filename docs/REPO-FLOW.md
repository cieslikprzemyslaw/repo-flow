# RepoFlow

RepoFlow is a local PowerShell workflow manager for Git, GitHub Issues, pull requests, CI, and a coding agent.

It replaces the separate issue runner, issue-manifest updater, and local-branch cleanup scripts with one neutral command:

```powershell
.\repo-flow.ps1 <area> <action> [options]
```

## Requirements

- PowerShell 7.2 or newer
- Git
- GitHub CLI authenticated with `gh auth login`
- Codex CLI for `issue run`, `issue continue`, and automatic CI fixes
- Pester 5 for unit tests

## Configuration

Repository behaviour is defined in:

```text
.repo-flow.json
```

The committed JSON Schema is:

```text
scripts/RepoFlow/repo-flow.schema.json
```

Keep these responsibilities separate:

- `.repo-flow.json`: runner behaviour and repository identity
- `issues-manifest.json`: issues, labels, milestones, and issue updates
- `AGENTS.md` and `docs/*.md`: project and agent rules
- `.github/pull_request_template.md`: pull-request body structure

Do not store tokens, passwords, API keys, issue requirements, or executable PowerShell in the configuration file.

## Commands

### Diagnose the installation

```powershell
.\repo-flow.ps1 doctor
.\repo-flow.ps1 doctor -Repo flow
```

The doctor command is read-only and continues far enough to report multiple failures even when normal workflows cannot load the configuration. It prints PASS/WARN/FAIL results and exits non-zero only when required checks fail.

### Validate configuration

```powershell
.\repo-flow.ps1 config validate
.\repo-flow.ps1 config show
```

### Synchronise the issue manifest

Dry run:

```powershell
.\repo-flow.ps1 issue sync
```

Apply:

```powershell
.\repo-flow.ps1 issue sync -Apply
```

Skip creation entries while still applying updates:

```powershell
.\repo-flow.ps1 issue sync -Apply -SkipCreates
```

### Implement an issue

Plan:

```powershell
.\repo-flow.ps1 issue run -Number 66
```

Run:

```powershell
.\repo-flow.ps1 issue run -Number 66 -Apply
```

One-run CI override:

```powershell
.\repo-flow.ps1 issue run -Number 66 -Apply -CiMode skip
.\repo-flow.ps1 issue run -Number 66 -Apply -CiMode observe
.\repo-flow.ps1 issue run -Number 66 -Apply -CiMode require-passing
```

The workflow:

1. validates the repository and issue;
2. verifies dependencies;
3. prepares the configured base branch;
4. creates the issue branch;
5. supplies the complete issue body to the agent;
6. commits and pushes the implementation;
7. creates a draft or ready PR according to configuration;
8. applies the configured CI policy.

### Resume an interrupted issue or PR workflow

Plan the exact next safe phase:

```powershell
.\repo-flow.ps1 issue resume -Number 66
```

Apply it:

```powershell
.\repo-flow.ps1 issue resume -Number 66 -Apply
```

RepoFlow loads the persisted run checkpoint and validates it against the selected repository, deterministic issue branch, local and remote branch heads, pull request, PR head SHA, CI result, trusted top-level review comments, and current working tree. Plan mode displays the saved phase and exact next action without mutating Git, GitHub, the agent, or the state file.

Resume never creates a duplicate branch or pull request and does not replay completed phases. It stops on branch mismatches, dirty changes from another branch, divergent heads, multiple active runs, or other ambiguous state. A successful-but-uncheckpointed commit, push, or PR creation is adopted only when the live state agrees through explicit rules.

Pending and failed CI remain resumable. Merged and closed PRs produce a terminal result. A new trusted top-level PR comment can start the existing review-feedback continuation without requiring the operator to guess its ID.

### Execute an ordered issue queue

```powershell
.\repo-flow.ps1 queue run -Manifest .\queue.json
.\repo-flow.ps1 queue run -Manifest .\queue.json -Continuous -Apply
.\repo-flow.ps1 queue resume -Manifest .\queue.json -Continuous -Apply
.\repo-flow.ps1 queue pause -Manifest .\queue.json -Apply
.\repo-flow.ps1 queue stop -Manifest .\queue.json -Apply
```

The queue manifest is the only source of task order. RepoFlow processes one
issue at a time, persists task checkpoints, reuses deterministic issue resume,
requires passing CI, invokes bounded automated review, and pauses at the
human-confirmed merge gate. It never skips a failed task or merges a PR.

See [`ISSUE-QUEUE.md`](ISSUE-QUEUE.md) for the versioned manifest, dependency
ordering, state schema, continuous-mode behaviour, and recovery rules.

### Continue an open PR from review feedback

Use the newest trusted top-level PR comment:

```powershell
.\repo-flow.ps1 issue continue -Number 66 -LastPrComment
.\repo-flow.ps1 issue continue -Number 66 -LastPrComment -Apply
```

Use a specific top-level PR comment:

```powershell
.\repo-flow.ps1 issue continue -Number 66 -PrCommentId 123456789 -Apply
```

The selected comment is displayed before any mutation. When `reviewFeedback.confirmBeforeRun` is `true`, RepoFlow also asks for confirmation.

Only comments from configured trusted GitHub associations are accepted. Bot and external comments are rejected. The comment is passed to the agent as clearly delimited untrusted task data and cannot override `AGENTS.md`, repository security rules, or the original issue scope.

Inline review-thread comments are not supported in v0.1. Use a top-level PR comment.

#### Resume an interrupted review-feedback run

When an agent stops after modifying files, preserve the current working tree and resume the same PR comment explicitly:

```powershell
.\repo-flow.ps1 issue continue -Number 66 -PrCommentId 123456789 -Apply -Resume
```

`-Resume` is intentionally restricted to `issue continue`. RepoFlow requires the issue branch to already be checked out, requires uncommitted changes, rejects active merge/rebase/cherry-pick/revert operations, and verifies that local `HEAD` still matches the remote branch. It does not switch branches, pull, reset, restore, or stash.

RepoFlow persists local workflow run checkpoints in `.repo-flow.state.json` beside the configuration file. Failed runs are marked as paused with the last safe phase retained for inspection and resume decisions. A first resume after upgrading can explicitly adopt existing changes even when no earlier checkpoint exists, after the branch and remote-head checks pass.

### Pull requests

```powershell
.\repo-flow.ps1 pr status -Number 113
.\repo-flow.ps1 pr watch -Number 113
.\repo-flow.ps1 pr ready -Number 113
.\repo-flow.ps1 pr ready -Number 113 -Apply
```

There is intentionally no `pr preview` command.

### CI

```powershell
.\repo-flow.ps1 ci watch -Number 113
```

CI modes:

- `skip`: do not inspect checks
- `observe`: report results without automatic fixes or failure enforcement
- `require-passing`: require success and allow the configured number of focused automatic fixes

### Branch cleanup

Plan:

```powershell
.\repo-flow.ps1 branch cleanup
```

Apply:

```powershell
.\repo-flow.ps1 branch cleanup -Apply
```

RepoFlow deletes only local branches whose PR is confirmed merged into the configured base branch. The current branch, `main`, `master`, and the configured base branch are protected.

## Configurable messages

Commit and PR title templates live in `.repo-flow.json`:

```json
{
  "messages": {
    "initialCommit": "{verb} #{issueNumber}: {issueTitle}",
    "reviewCommit": "Fix review feedback for #{issueNumber}",
    "ciFixCommit": "Fix CI for #{issueNumber}",
    "pullRequestTitle": "{verb} #{issueNumber}: {issueTitle}"
  }
}
```

Supported placeholders:

- `{verb}`
- `{issueNumber}`
- `{issueTitle}`

Unknown placeholders are rejected.

## Progress telemetry

Agent heartbeats show only observable signals:

- persisted workflow phase;
- `active`, `waiting`, `no observable change`, or `possibly stalled`;
- elapsed time and time since the last observable activity;
- changed-file count and working-tree fingerprint transitions;
- last write time for changed repository files;
- detected agent process and CPU delta when available;
- an observable command when the provider event stream exposes it.

`agent.noActivityWarningSeconds` configures the warning threshold. A warning never terminates the agent automatically.

CI polling emits concise check transitions, for example `Validate: pending -> pass`, and uses the same no-activity states. Heartbeat and observable-activity timestamps are persisted in the run state.

## Automated review contract

The versioned request/result format used by future automated review workflows is documented in [`AUTOMATED-REVIEW-CONTRACT.md`](AUTOMATED-REVIEW-CONTRACT.md). The current task defines schemas, markers, parsing, matching, replay checks, limits, and truncation rules only; it does not publish or poll GitHub comments.

## Automated review transport

Use `rf review run -Number <pr> -Apply` to publish or reuse a request for the
exact current PR head and wait for a matching trusted result. Configuration,
trust rules, timeout behaviour, and the external bridge responsibilities are
documented in [`AUTOMATED-REVIEW-BRIDGE.md`](AUTOMATED-REVIEW-BRIDGE.md).

## Bounded PR review loop

`rf pr review -Number <pr> -Apply` orchestrates the transport into a bounded
review/repair workflow:

1. validate the open PR, checked-out branch, exact head, clean tree, and CI;
2. publish or reuse a request for that exact head;
3. consume only the matching trusted result;
4. record `pass`, or pause on `manual_review`;
5. for `changes_required`, pass only blockers to the configured coding agent
   as untrusted task data;
6. run local validation, commit, push, wait for the new head, observe CI, and
   request a fresh exact-head review.

The original issue remains authoritative. Warnings do not expand repair scope.
Repeated blocker fingerprints stop for manual review. Review and repair counts
are persisted and bounded by `reviewFeedback.maxReviewCycles` and
`reviewFeedback.maxRepairCycles`. No path in this workflow approves or merges
the PR.

## Validation

Run all local syntax, JSON, and Pester checks:

```powershell
.\test-repo-flow.ps1
```

The script always runs the PowerShell parser and JSON parsing checks. It runs Pester tests when Pester 5 is installed.
