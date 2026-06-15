# RepoFlow v0.1.7 configuration additions

## repository.localPath

Local path to the Git repository managed by RepoFlow. It allows the RepoFlow script and module to live outside the target repository.

Absolute example:

```json
"localPath": "C:\\Projects\\repo-flow"
```

A relative path is resolved from the directory containing `.repo-flow.json`.

## git.preCommitFixAttempts

Number of focused agent attempts after a commit hook blocks `git commit`.

- `0`: disabled
- `1`: recommended
- maximum: `3`

## agent.preCommitFixReasoningEffort

Reasoning effort for the narrow pre-commit repair run. `low` is recommended.

## pullRequest.mergeMethod

One of `squash`, `merge`, or `rebase`. This project uses `squash`.

## pullRequest.deleteBranchOnMerge

When `true`, RepoFlow deletes the pull-request branch only after GitHub confirms that the PR was merged.

## Manual merge decision

Manual-review confirmation is intentionally not configurable.

No issue, agent, or CI workflow can automatically merge a pull request. After reviewing the diff and validating the application, the project owner must explicitly run:

```powershell
.\repo-flow.ps1 pr merge -Number <pr> -Apply
```

RepoFlow then waits for required CI checks and requires the exact terminal confirmation `MERGE` before it marks a draft ready or performs the merge.
