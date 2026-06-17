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

Before each review-feedback agent run, RepoFlow writes a checkpoint under `.git/repo-flow/agent-run.json`. Failed runs are marked as interrupted. A first resume after upgrading can explicitly adopt existing changes even when no earlier checkpoint exists, after the branch and remote-head checks pass.

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

## Validation

Run all local syntax, JSON, and Pester checks:

```powershell
.\test-repo-flow.ps1
```

The script always runs the PowerShell parser and JSON parsing checks. It runs Pester tests when Pester 5 is installed.
