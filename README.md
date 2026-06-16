# RepoFlow

RepoFlow is a local PowerShell workflow manager for Git, GitHub Issues, pull requests, CI, and coding-agent iterations.

It turns a GitHub issue into a controlled development workflow:

```text
GitHub issue
  -> plan
  -> feature branch
  -> coding agent
  -> commit and push
  -> draft pull request
  -> CI
  -> human review
  -> optional PR-comment correction
  -> explicit human-confirmed merge
```

> **Project status:** experimental / early alpha. RepoFlow is already used on real work, but the command surface and configuration may still change before `v1.0`.

## Why RepoFlow exists

RepoFlow combines several repetitive repository tasks behind one command:

- synchronising labels, milestones, and issues from a manifest;
- creating issue branches using repository conventions;
- passing the full issue scope to a coding agent;
- creating commits and draft pull requests;
- observing CI and performing a limited focused CI-fix attempt;
- recovering from pre-commit hook failures with one focused agent correction;
- continuing the same pull request from a trusted PR comment;
- safely cleaning merged branches;
- merging only after explicit human review and confirmation.

The goal is not to remove human review. The goal is to automate the mechanical work around it.

## Safety model

RepoFlow is intentionally conservative:

- commands are **plan-only by default**;
- `-Apply` is required for mutations;
- repository identity and remote origin are validated before work starts;
- a clean working tree can be required;
- issue scope is supplied directly to the agent;
- PR comments are treated as untrusted task data;
- only trusted GitHub author associations can provide review feedback;
- commit hooks are never bypassed with `--no-verify`;
- CI auto-fix and pre-commit auto-fix attempts are bounded;
- no issue, agent, or CI workflow can merge a PR automatically;
- `pr merge -Apply` requires the user to type exactly `MERGE`.

## Requirements

- Windows, Linux, or macOS with PowerShell 7.2+
- Git
- GitHub CLI (`gh`), authenticated
- Codex CLI or Claude Code for agent-backed workflows
- Pester 5+ for tests

Check the tools:

```powershell
pwsh --version
git --version
gh --version
gh auth status
codex --version
# or
claude --version
```

Install Pester for the current user when needed:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force
```

## Project structure

```text
repo-flow/
├── repo-flow.ps1
├── test-repo-flow.ps1
├── repo-flow.example.json
├── .gitignore
├── README.md
├── docs/
│   └── GITHUB-SETUP.md
├── scripts/
│   └── RepoFlow/
│       ├── RepoFlow.psd1
│       ├── RepoFlow.psm1
│       ├── repo-flow.schema.json
│       ├── Public/
│       └── Private/
└── tests/
    └── *.Tests.ps1
```

## Installation

Clone the project:

```powershell
gh repo clone <owner>/repo-flow
Set-Location .\repo-flow
```

Create a local configuration:

```powershell
Copy-Item .\repo-flow.example.json .\.repo-flow.json
```

Edit `.repo-flow.json` and configure either:

- the legacy `repository` object; or
- `defaultRepository` with `repositories[]`.

Each registered repository defines `name`, `localPath`, `slug`,
`expectedOrigins`, and `baseBranch`.

The local `.repo-flow.json` is ignored by Git because it can contain machine-specific paths. The example file is committed instead.

On Windows, downloaded scripts may need to be unblocked once:

```powershell
Get-ChildItem . -Recurse -File |
    Where-Object {
        $_.Extension -in '.ps1', '.psm1', '.psd1'
    } |
    Unblock-File
```

Validate the installation:

```powershell
Remove-Module RepoFlow -Force -ErrorAction SilentlyContinue
.\test-repo-flow.ps1
.\repo-flow.ps1 config validate
.\repo-flow.ps1 config show
```

## Configuration

RepoFlow loads `.repo-flow.json` from the directory containing `repo-flow.ps1`, unless `-ConfigPath` is provided.

A minimal workflow configuration looks like this:

```json
{
  "$schema": "./scripts/RepoFlow/repo-flow.schema.json",
  "repository": {
    "localPath": "C:\\Projects\\repo-flow",
    "slug": "owner/repository",
    "expectedOrigins": [
      "https://github.com/owner/repository.git",
      "git@github.com:owner/repository.git"
    ],
    "baseBranch": "main"
  },
  "issues": {
    "manifestPath": "./issues-manifest.json"
  },
  "git": {
    "requireCleanWorkingTree": true,
    "deleteMergedLocalBranches": true,
    "pruneRemoteReferences": true,
    "signOffCommits": false,
    "preCommitFixAttempts": 1
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
    "templatePath": "./.github/pull_request_template.md",
    "mergeMethod": "squash",
    "deleteBranchOnMerge": true
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
    ]
  }
}
```

Do not store tokens, passwords, API keys, or executable PowerShell in the configuration.

### Multiple repositories

One configuration can register several target repositories:

```json
{
  "defaultRepository": "example-app",
  "repositories": [
    {
      "name": "example-app",
      "localPath": "C:\\Projects\\RepoFlow\\example-app",
      "slug": "owner/example-app",
      "expectedOrigins": [
        "https://github.com/owner/example-app.git",
        "git@github.com:owner/example-app.git"
      ],
      "baseBranch": "main"
    },
    {
      "name": "repo-flow",
      "localPath": "C:\\Projects\\RepoFlow\\repo-flow",
      "slug": "owner/repo-flow",
      "expectedOrigins": [
        "https://github.com/owner/repo-flow.git",
        "git@github.com:owner/repo-flow.git"
      ],
      "baseBranch": "main"
    }
  ]
}
```

Repository selection uses this order:

1. explicit `-Repo`;
2. the repository stored by `repo use`;
3. the registered repository containing the current directory;
4. `defaultRepository`;
5. the legacy `repository` object.

The active selection is stored locally in `.repo-flow.state.json` beside the
configuration file. It is ignored by Git and contains only the selected name.

```powershell
repo-flow repo list
repo-flow repo current
repo-flow repo use repo-flow
repo-flow repo use repo-flow -Apply
repo-flow repo reset -Apply

repo-flow issue run -Number 12 -Repo repo-flow -Apply
repo-flow pr status -Number 12 -Repo repo-flow
```

The named `-Repo` form remains supported for scripts and one-run repository overrides.

Selecting a repository does not change the caller's working directory.
RepoFlow still validates the configured path and Git remote before running a
repository workflow.

Issue manifests, `AGENTS.md`, repository documentation, issue templates, and
pull-request templates stay inside each target repository. RepoFlow does not
copy project-specific frontend or backend rules into the shared configuration.

### Agent provider

RepoFlow supports Codex and Claude Code through the same workflow commands. The provider selects the adapter, the command selects the executable name or path, and the model is always passed explicitly to the CLI with `--model`.

Use Codex:

```json
"agent": {
  "provider": "codex",
  "command": "codex",
  "model": "gpt-5.5",
  "minimumCliVersion": null
}
```

Use Claude Code:

```json
"agent": {
  "provider": "claude",
  "command": "claude",
  "model": "claude-sonnet-4-6",
  "minimumCliVersion": null
}
```

`model` is the agent model name used for a run. `minimumCliVersion` is an optional lower bound for the installed CLI executable, checked through `command --version` before the agent starts; set it to `null` to skip the lower-bound check.

## Target repository contract

The target repository should normally contain:

```text
AGENTS.md
.github/pull_request_template.md
issues-manifest.json              # only when issue sync is used
```

GitHub Issues remain the source of task scope. `AGENTS.md` and repository documentation remain the source of stable project rules.

RepoFlow deliberately does not contain project-specific frontend, backend, design-system, testing, or pull-request wording. Keep those rules in the target repository instead of duplicating them in PowerShell prompts. The agent prompts stay generic and provide the issue scope, applicable diagnostics, and changed-file hints.

### Prompt and token strategy

RepoFlow keeps agent context focused without weakening the issue boundary:

- the full issue body is supplied as the authoritative scope;
- review, CI, and pre-commit prompts prioritise files already changed by the branch;
- long diagnostics preserve both the beginning and end while omitting the noisy middle;
- repository-wide rules are read from `AGENTS.md`, not copied into every prompt;
- Git, GitHub, commit, push, PR, CI, and merge operations remain controlled by RepoFlow.

## Commands

Show help:

```powershell
.\repo-flow.ps1
.\repo-flow.ps1 help
.\repo-flow.ps1 help issue
.\repo-flow.ps1 help "issue run"
.\repo-flow.ps1 help "pr merge"
```

### Configuration

```powershell
.\repo-flow.ps1 config validate
.\repo-flow.ps1 config show
```

### Synchronise issues

Plan only:

```powershell
.\repo-flow.ps1 issue sync
```

Apply manifest changes:

```powershell
.\repo-flow.ps1 issue sync -Apply
```

Apply updates but skip new issue creation:

```powershell
.\repo-flow.ps1 issue sync -Apply -SkipCreates
```

### Implement an issue

Plan:

```powershell
.\repo-flow.ps1 issue run -Number 67
```

Run:

```powershell
.\repo-flow.ps1 issue run -Number 67 -Apply
```

One-run CI override:

```powershell
.\repo-flow.ps1 issue run -Number 67 -Apply -CiMode skip
.\repo-flow.ps1 issue run -Number 67 -Apply -CiMode observe
.\repo-flow.ps1 issue run -Number 67 -Apply -CiMode require-passing
```

The workflow can:

1. validate the repository and issue;
2. verify issue dependencies;
3. prepare the base branch;
4. create the issue branch;
5. pass the full issue body to the agent;
6. retry one focused pre-commit correction when configured;
7. commit and push;
8. create a draft PR;
9. observe CI and optionally attempt a focused CI fix.

It stops after CI. It does not merge.

### Continue an open PR from a comment

Use the newest trusted top-level PR comment:

```powershell
.\repo-flow.ps1 issue continue `
    -Number 67 `
    -LastPrComment `
    -Apply
```

Use a specific top-level PR comment:

```powershell
.\repo-flow.ps1 issue continue `
    -Number 67 `
    -PrCommentId 123456789 `
    -Apply
```

Use either `-LastPrComment` or `-PrCommentId`, not both.

Inline review-thread comments are not currently supported. Add a top-level PR comment instead.

### Pull-request status and CI

```powershell
.\repo-flow.ps1 pr status -Number 116
.\repo-flow.ps1 pr watch -Number 116
.\repo-flow.ps1 ci watch -Number 116
```

### Mark a PR ready

Plan:

```powershell
.\repo-flow.ps1 pr ready -Number 116
```

Apply:

```powershell
.\repo-flow.ps1 pr ready -Number 116 -Apply
```

### Merge after manual review

First inspect and validate the PR yourself.

Show the merge plan:

```powershell
.\repo-flow.ps1 pr merge -Number 116
```

Apply only after manual review:

```powershell
.\repo-flow.ps1 pr merge -Number 116 -Apply
```

`pr accept` is an alias:

```powershell
.\repo-flow.ps1 pr accept -Number 116 -Apply
```

RepoFlow then:

1. checks that the PR is open and targets the configured base branch;
2. waits for required CI checks;
3. displays the merge plan;
4. requires typing exactly `MERGE`;
5. marks a draft ready when necessary;
6. performs the configured merge method;
7. updates the local base branch;
8. deletes the branch only after GitHub confirms the merge and cleanup is enabled.

No other command invokes this workflow automatically.

### Clean merged branches

Plan:

```powershell
.\repo-flow.ps1 branch cleanup
```

Apply:

```powershell
.\repo-flow.ps1 branch cleanup -Apply
```

RepoFlow protects the current branch, `main`, `master`, and the configured base branch.

## Run RepoFlow from anywhere

Use the full script path:

```powershell
C:\Tools\RepoFlow\repo-flow.ps1 issue run -Number 67 -Apply
```

Or add a helper function to your PowerShell profile:

```powershell
function repo-flow {
    & 'C:\Tools\RepoFlow\repo-flow.ps1' @args
}
```

Open the profile:

```powershell
notepad $PROFILE
```

Reload it:

```powershell
. $PROFILE
```

Then run:

```powershell
repo-flow repo list
repo-flow repo current
repo-flow issue run -Number 67
repo-flow issue run -Number 12 -Repo repo-flow -Apply
repo-flow pr status -Number 116
```

## Testing

Run syntax checks, JSON checks, and Pester tests:

```powershell
.\test-repo-flow.ps1
```

Run Pester directly:

```powershell
Invoke-Pester .\tests
```

## Security considerations

RepoFlow crosses several trust boundaries:

- GitHub issue bodies;
- pull-request comments;
- command output from Git, GitHub CLI, hooks, and CI;
- coding-agent output;
- local repository state.

The implementation should continue to treat all external text as data, pass process arguments without shell evaluation, validate repository identity, limit automated retries, and require a human decision for merge.

## Current limitations

- PR feedback supports top-level comments, not inline review threads.
- RepoFlow is designed around GitHub and GitHub CLI.
- The project is pre-`v1.0` and may introduce breaking changes.

## Roadmap

- retained execution reports for agent runs;
- richer run diagnostics;
- improved resume/recovery after interrupted local workflows;
- full CLI packaging and installation as a reusable PowerShell module (deferred until the workflows stabilise);
- broader integration and security testing.

## Contributing

Issues and pull requests are welcome while the project is experimental. Keep changes narrowly scoped, add or update Pester coverage, and preserve the plan-first and human-confirmed safety model.
