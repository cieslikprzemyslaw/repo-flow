# RepoFlow configuration

RepoFlow reads repository-specific settings from `.repo-flow.json` in the repository root.

## Why the configuration file has no comments

`.repo-flow.json` is standard JSON. Standard JSON does not support comments, so adding `//` or `/* ... */` would make the file invalid and prevent RepoFlow from loading it.

Documentation is kept in this file, while property descriptions are also stored in `scripts/RepoFlow/repo-flow.schema.json`. Editors such as VS Code can use the `$schema` property to provide validation, autocomplete, and hover descriptions.

## Complete example

```json
{
  "$schema": "./scripts/RepoFlow/repo-flow.schema.json",
  "repository": {
    "slug": "owner/repository",
    "expectedOrigins": [
      "https://github.com/owner/repository.git",
      "git@github.com:owner/repository.git"
    ],
    "baseBranch": "master"
  },
  "issues": {
    "manifestPath": "./issues-manifest.json"
  },
  "git": {
    "requireCleanWorkingTree": true,
    "deleteMergedLocalBranches": true,
    "pruneRemoteReferences": true,
    "signOffCommits": false
  },
  "agent": {
    "provider": "codex",
    "command": "codex",
    "model": "gpt-5.5",
    "minimumCliVersion": null,
    "heartbeatSeconds": 15,
    "reasoningEffort": "medium",
    "ciFixReasoningEffort": "low",
    "preCommitFixReasoningEffort": "low",
    "runProjectChecks": false
  },
  "pullRequest": {
    "createDraft": true,
    "templatePath": "./.github/pull_request_template.md"
  },
  "messages": {
    "initialCommit": "{verb} #{issueNumber}: {issueTitle}",
    "reviewCommit": "Fix review feedback for #{issueNumber}",
    "ciFixCommit": "Fix CI for #{issueNumber}",
    "pullRequestTitle": "{verb} #{issueNumber}: {issueTitle}"
  },
  "ci": {
    "mode": "require-passing",
    "pollSeconds": 30,
    "timeoutSeconds": 1800,
    "autoFixAttempts": 1
  },
  "reviewFeedback": {
    "enabled": true,
    "confirmBeforeRun": true,
    "trustedAssociations": [
      "OWNER",
      "MEMBER",
      "COLLABORATOR"
    ],
    "maxReviewCycles": 3,
    "maxRepairCycles": 2
  }
}
```

## `$schema`

```json
"$schema": "./scripts/RepoFlow/repo-flow.schema.json"
```

Points the editor to RepoFlow's JSON Schema. It enables validation, autocomplete, allowed-value suggestions, and property descriptions. RepoFlow also performs its own validation before mutating Git or GitHub state.

## `repository`

### `slug`

```json
"slug": "owner/repository"
```

The GitHub repository used by `gh` commands. It must use the `owner/repository` format.

### `expectedOrigins`

```json
"expectedOrigins": [
  "https://github.com/owner/repository.git",
  "git@github.com:owner/repository.git"
]
```

The accepted Git remote URLs for `origin`. This prevents RepoFlow from modifying the wrong local repository. Include every origin format that is legitimately used by the project, normally HTTPS and SSH.

### `baseBranch`

```json
"baseBranch": "master"
```

The branch from which issue branches are created and into which pull requests are expected to merge. Common values are `main` or `master`.

## `issues`

### `manifestPath`

```json
"manifestPath": "./issues-manifest.json"
```

The repository-relative path to the issue manifest used by `issue sync`. The manifest remains the source of truth for managed labels, milestones, issue updates, and issue creation entries.

## `git`

### `requireCleanWorkingTree`

```json
"requireCleanWorkingTree": true
```

When enabled, RepoFlow stops before switching branches or making changes if tracked or untracked files are present. Keep this enabled unless there is a very specific reason not to; it prevents unrelated work from being committed accidentally.

### `deleteMergedLocalBranches`

```json
"deleteMergedLocalBranches": true
```

When RepoFlow starts from a feature branch whose pull request is confirmed as merged into the configured base branch, it switches to the base branch and deletes that local feature branch using safe Git deletion.

It does not delete an unmerged branch.

### `pruneRemoteReferences`

```json
"pruneRemoteReferences": true
```

Allows branch-cleanup operations to prune stale remote-tracking references, such as `origin/feature/...`, after the remote branch has been removed.

### `signOffCommits`

```json
"signOffCommits": false
```

When enabled, RepoFlow runs `git commit -s` and adds a `Signed-off-by` trailer to every generated commit.

Enable this only when the project intentionally uses Developer Certificate of Origin sign-off. It is not the same as a cryptographic GPG/SSH commit signature. For this project, `false` is the less surprising default unless DCO sign-off is deliberately required.

## `agent`

### `provider`

```json
"provider": "codex"
```

Selects the coding-agent adapter. Supported values are `codex` and `claude`.

### `command`

```json
"command": "codex"
```

The executable name or path used to start the configured agent. Use a full path only when the command is not available through `PATH`.

### `model`

```json
"model": "gpt-5.5"
```

The model passed explicitly to the selected CLI with `--model`. For Claude Code, use the corresponding Claude model name, such as `claude-sonnet-4-6`.

### `minimumCliVersion`

```json
"minimumCliVersion": null
```

Optional minimum semantic version for the configured CLI executable. RepoFlow checks this with `command --version` before starting the agent. This is separate from `model`: `model` chooses the remote model for a run, while `minimumCliVersion` gates the installed local CLI version.

### `heartbeatSeconds`

```json
"heartbeatSeconds": 15
```

How often RepoFlow prints progress while the agent is working. Supported range: 5 to 300 seconds.

This affects only status output, not the agent timeout.

### `reasoningEffort`

```json
"reasoningEffort": "medium"
```

Controls agent reasoning effort for initial issue implementation and PR-comment continuation. Supported RepoFlow values are `minimal`, `low`, `medium`, `high`, and `xhigh`. Claude Code receives `low` when RepoFlow is configured with `minimal`; the other values are passed through unchanged.

`medium` is the recommended default for normal repository tasks: it keeps the run bounded without forcing every task into the most expensive reasoning mode.

### `ciFixReasoningEffort`

```json
"ciFixReasoningEffort": "low"
```

Controls reasoning effort for focused automatic CI fixes. CI fixes already receive failed logs and the current branch diff, so `low` is the recommended default. Increase it only when focused fixes repeatedly fail to diagnose a complex error.

RepoFlow prints agent token usage after each run when the CLI reports it, allowing initial implementation and CI-fix usage to be compared separately.

### `runProjectChecks`

```json
"runProjectChecks": false
```

Controls the instruction sent to the coding agent:

- `false`: the agent is told not to run project checks;
- `true`: the agent may run checks required by `AGENTS.md`.

For the current workflow, keep this `false` because project checks are run separately by the project owner and CI.

## `pullRequest`

### `createDraft`

```json
"createDraft": true
```

Controls whether new pull requests are created as drafts. A draft PR is recommended for the human-review workflow because it clearly indicates that local validation and review are still pending.

### `templatePath`

```json
"templatePath": "./.github/pull_request_template.md"
```

The repository-relative path to the pull-request template. RepoFlow combines this template with issue information and the agent's final summary instead of storing PR body text in configuration.

## `messages`

The `messages` section controls generated commit messages and pull-request titles.

### `initialCommit`

```json
"initialCommit": "{verb} #{issueNumber}: {issueTitle}"
```

Used for the first implementation commit.

### `reviewCommit`

```json
"reviewCommit": "Fix review feedback for #{issueNumber}"
```

Used when `issue continue` applies a selected PR comment.

### `ciFixCommit`

```json
"ciFixCommit": "Fix CI for #{issueNumber}"
```

Used for a focused automatic CI-fix commit.

### `pullRequestTitle`

```json
"pullRequestTitle": "{verb} #{issueNumber}: {issueTitle}"
```

Used as the title of a newly created pull request.

### Supported placeholders

- `{verb}`: selected from the issue/branch type, for example `Implement`, `Fix`, `Refactor`, or `Document`;
- `{issueNumber}`: the GitHub issue number;
- `{issueTitle}`: the current GitHub issue title.

Unknown placeholders are rejected.

## `ci`

### `mode`

```json
"mode": "require-passing"
```

Supported values:

| Mode | Behaviour |
| --- | --- |
| `skip` | Does not inspect PR checks. |
| `observe` | Waits for checks and reports the result, but does not fail the workflow or ask the agent to repair CI. |
| `require-passing` | Requires checks to pass and may perform the configured number of focused automatic fix attempts. |

`require-passing` is the safest default for automated issue execution.

### `pollSeconds`

```json
"pollSeconds": 30
```

How often RepoFlow asks GitHub for updated CI status. Supported range: 10 to 300 seconds.

### `timeoutSeconds`

```json
"timeoutSeconds": 1800
```

Maximum time RepoFlow waits for one CI observation cycle. Supported range: 30 to 7200 seconds.

A value of `1800` gives CI up to 30 minutes. The earlier value `300` allowed only five minutes and may be too short for queued or slower GitHub Actions runs.

### `autoFixAttempts`

```json
"autoFixAttempts": 1
```

Maximum number of focused automatic CI-fix attempts made by the agent after failed checks.

Use `0` to disable automatic repair. A value greater than `0` is valid only when `mode` is `require-passing`.

## `reviewFeedback`

### `enabled`

```json
"enabled": true
```

Enables continuation of an existing open pull request through `issue continue` with `-LastPrComment` or `-PrCommentId`.

### `confirmBeforeRun`

```json
"confirmBeforeRun": true
```

When enabled, RepoFlow displays the selected PR comment and asks for confirmation before the agent receives it and files can be changed.

Keep this enabled for the normal human-in-the-loop workflow.

### `trustedAssociations`

```json
"trustedAssociations": [
  "OWNER",
  "MEMBER",
  "COLLABORATOR"
]
```

Only top-level PR comments whose GitHub `author_association` is in this list may be used as review instructions. Comments from bots, external users, and untrusted associations are rejected.

Supported values in v0.1 are:

- `OWNER`
- `MEMBER`
- `COLLABORATOR`

This is one trust check, not a replacement for displaying and manually confirming the comment.

### `maxReviewCycles`

```json
"maxReviewCycles": 3
```

Maximum number of exact-head automated review requests in one `pr review`
workflow. The allowed range is 1 to 10.

### `maxRepairCycles`

```json
"maxRepairCycles": 2
```

Maximum number of coding-agent repairs in one `pr review` workflow. Use `0`
to allow review and pass/manual-review handling without automatic repair. The
allowed range is 0 to 10.

`pr review` requires passing checks when `ci.mode` is `require-passing`.
Selecting `observe` or `skip` explicitly allows a review request without a
passing-CI gate, but every performed repair still observes the new head's CI
before another review request.

## Recommended profiles

### Fast local iteration

```json
"ci": {
  "mode": "skip",
  "pollSeconds": 30,
  "timeoutSeconds": 1800,
  "autoFixAttempts": 0
}
```

Use only when CI observation is intentionally handled elsewhere.

### Observe without automatic repair

```json
"ci": {
  "mode": "observe",
  "pollSeconds": 30,
  "timeoutSeconds": 1800,
  "autoFixAttempts": 0
}
```

Useful when RepoFlow should report CI but never ask the agent to change code automatically.

### Strict workflow

```json
"ci": {
  "mode": "require-passing",
  "pollSeconds": 30,
  "timeoutSeconds": 1800,
  "autoFixAttempts": 1
}
```

Recommended for the current AppSec Report Builder workflow.

## Validation commands

Validate the configuration:

```powershell
.\repo-flow.ps1 config validate
```

Show the effective non-sensitive configuration:

```powershell
.\repo-flow.ps1 config show
```

Run RepoFlow's local syntax, JSON, and Pester checks:

```powershell
.\test-repo-flow.ps1
```

## Security rules

Do not store any of the following in `.repo-flow.json`:

- GitHub tokens;
- passwords or API keys;
- executable PowerShell;
- issue requirements;
- Codex prompts;
- pull-request body templates;
- secrets of any kind.

The configuration file should describe behaviour, not contain credentials or executable instructions.
