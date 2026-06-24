function Get-RepoFlowHelpText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Topic
    )

    $normalisedTopic = if ([string]::IsNullOrWhiteSpace($Topic)) {
        'all'
    }
    else {
        $Topic.Trim().ToLowerInvariant() -replace '\s+', '/'
    }

    switch ($normalisedTopic) {
        { $_ -in @('all', 'help', 'commands') } {
            return @'
RepoFlow

Usage:
  rf <area> <action> [options]
  rf doctor [-Repo <name>]
  rf help [topic]
  rf -h | --help
  rf --version

Launchers:
  rf is the recommended short command.
  repo-flow and repo-flow.ps1 remain backward-compatible entrypoints.

Commands:
  doctor
      Run read-only installation, configuration, repository, and access diagnostics.

  issue sync
      Synchronise labels, milestones, and issues from issues-manifest.json.

  issue run
      Plan or implement a GitHub issue.

  issue continue
      Continue an open pull request using a selected PR comment.

  issue resume
      Reconstruct and continue the last validated issue workflow checkpoint.

  pr status
      Display pull-request details and checks.

  pr watch
      Wait for pull-request CI checks.

  pr ready
      Mark a draft pull request as ready for review.

  pr merge
      After manual review, explicitly confirm and merge the pull request.
      'pr accept' is an alias for this command.

  pr repair
      Repair a failed open pull request without merging it.

  pr review
      Run a bounded automated review and repair loop without merging.

  review run
      Publish or reuse an automated-review request and wait for a trusted result.

  branch cleanup
      Find or delete safely merged local branches.

  ci watch
      Wait for pull-request CI checks.

  run list
      Display persisted workflow run records.

  run show
      Display one persisted workflow run record.

  run complete
      Plan or mark a persisted run as completed or abandoned.

  run prune
      Plan or prune completed and abandoned run records.

  config validate
      Validate .repo-flow.json.

  config show
      Display the effective non-sensitive configuration.

  repo list
      Display registered repositories and selection markers.

  repo current
      Display the effective repository and selection source.

  repo use
      Plan or store an active repository selection.

  repo reset
      Plan or remove the active repository selection.

Safety:
  Commands are plan-only by default.
  Add -Apply to perform Git or GitHub mutations.
  PR merge always requires explicit manual-review confirmation.

Common options:
  -h, --help
  --version
  -Number <number>
  -Apply
  -CiMode skip|observe|require-passing
  -Repo <name>
  -ConfigPath <path>

Aliases:
  -IssueNumber and -PrNumber are aliases for -Number.
  -Run is an alias for -Apply.
  -Repository and -RepositoryName are aliases for -Repo.
  pr accept is an alias for pr merge.

Help examples:
  rf help issue
  rf help "issue run"
  rf help pr
  rf help "pr merge"
  rf help "branch cleanup"
'@
        }

        'doctor' {
            return @'
doctor

Runs read-only diagnostics for the RepoFlow runtime, tools, authentication,
configuration, registered repositories, local state, workflow files, and
working trees. It never changes configuration, Git, GitHub, branches, files,
or state.

Run all checks:
  rf doctor

Check with an explicit target repository selection:
  rf doctor -Repo flow

The command prints a concise PASS/WARN/FAIL table. WARN results do not change
the exit code. Required FAIL results produce a non-zero process exit code.
'@
        }

        'issue' {
            return @'
RepoFlow issue commands

  rf issue sync
  rf issue sync -Apply

  rf issue run -Number <issue>
  rf issue run -Number <issue> -Apply

  rf issue continue -Number <issue> -LastPrComment
  rf issue continue -Number <issue> -LastPrComment -Apply

  rf issue continue -Number <issue> -PrCommentId <id>
  rf issue continue -Number <issue> -PrCommentId <id> -Apply
  rf issue continue -Number <issue> -PrCommentId <id> -Apply -Resume

  rf issue resume -Number <issue>
  rf issue resume -Number <issue> -Apply
'@
        }

        'issue/sync' {
            return @'
issue sync

Synchronises GitHub labels, milestones, issue updates, and issue creation
from issues-manifest.json.

Plan:
  rf issue sync

Apply:
  rf issue sync -Apply

Skip new issue creation:
  rf issue sync -Apply -SkipCreates
'@
        }

        'issue/run' {
            return @'
issue run

Implements a GitHub issue using the configured coding agent.

Plan:
  rf issue run -Number 67

Apply:
  rf issue run -Number 67 -Apply

Optional CI override:
  rf issue run -Number 67 -Apply -CiMode observe
'@
        }

        'issue/continue' {
            return @'
issue continue

Continues an existing open pull request using trusted review feedback.

Latest PR comment:
  rf issue continue -Number 66 -LastPrComment -Apply

Specific PR comment:
  rf issue continue -Number 66 -PrCommentId 123456789 -Apply

Resume an interrupted agent run while preserving existing changes:
  rf issue continue -Number 66 -PrCommentId 123456789 -Apply -Resume

-Resume requires the issue branch to be checked out, a dirty working tree,
and local HEAD to match the remote branch. It never switches branches,
resets, restores, or stashes existing work.

Use either -LastPrComment or -PrCommentId, not both.
'@
        }
        'issue/resume' {
            return @'
issue resume

Reconstructs an existing issue or PR workflow from persisted run state and
validates the configured repository, local and remote branches, pull request,
head SHA, CI status, trusted review comments, and working-tree state.

Plan:
  rf issue resume -Number 67

Apply:
  rf issue resume -Number 67 -Apply

The command never creates a duplicate branch or pull request. Conflicting or
ambiguous state stops with an actionable error. Existing `issue continue
-Resume` remains available for scripts that explicitly resume one interrupted
review-comment agent run.
'@
        }

        'pr' {
            return @'
RepoFlow pull-request commands

  rf pr status -Number <pr>
  rf pr watch -Number <pr>
  rf pr ready -Number <pr> -Apply
  rf pr merge -Number <pr> -Apply
  rf pr repair --help
  rf pr review -Number <pr> [-Apply]

pr accept is an alias for pr merge.
'@
        }


        'pr/status' {
            return @'
pr status

Displays the pull-request state and current check results.

Example:
  rf pr status -Number 116
'@
        }

        'pr/watch' {
            return @'
pr watch

Waits for checks associated with the current pull-request head commit.

Example:
  rf pr watch -Number 116
'@
        }

        'pr/ready' {
            return @'
pr ready

Validates a draft pull request and marks it ready for review.

Plan:
  rf pr ready -Number 116

Apply:
  rf pr ready -Number 116 -Apply
'@
        }

        { $_ -in @('pr/merge', 'pr/accept') } {
            return @'
pr merge

Use this only after you manually review the pull-request diff and validate
the application. RepoFlow waits for CI, then requires you to type MERGE before
it marks a draft ready or performs any merge mutation.

Plan:
  rf pr merge -Number 116

Apply:
  rf pr merge -Number 116 -Apply

Alias:
  rf pr accept -Number 116 -Apply

This command does not submit a GitHub review approval. It records your
manual decision through an explicit terminal confirmation, then performs the
mechanical ready, merge, base-branch update, and optional branch cleanup steps.

No issue, agent, or CI workflow invokes this command automatically.
'@
        }
        'pr/repair' {
            return @'
pr repair

Repairs a failed, open pull request using the configured coding agent.

Usage:
  rf pr repair -Number <pr> -Apply

The command is plan-only by default. Add -Apply to run one bounded repair
cycle and observe the repaired PR checks.
'@
        }

        'pr/review' {
            return @'
pr review

Runs a bounded automated-review and repair loop for one open pull request.

Plan:
  rf pr review -Number 24

Apply:
  rf pr review -Number 24 -Apply

The command requires the PR branch and exact head to be checked out locally.
It waits for configured CI, publishes an exact-head review request, accepts
only a matching trusted result, and records pass, manual-review, or repair
outcomes in run state.

For changes_required, only blockers are passed to the configured coding agent
as untrusted task data. The original issue remains authoritative. Each repair
must pass local validation, create a new head, rerun CI, and receive a fresh
review. Repeated blockers and configured cycle limits pause safely.

This workflow never approves or merges the pull request.
'@
        }

        'review' {
            return @'
RepoFlow automated-review commands

  rf review run -Number <pr>
  rf review run -Number <pr> -Apply
'@
        }

        'review/run' {
            return @'
review run

Publishes one idempotent automated-review request for the exact current PR
head, then waits for a matching trusted review-result comment.

Plan:
  rf review run -Number 24

Publish and wait:
  rf review run -Number 24 -Apply

The command never starts a coding agent, approves a pull request, marks it
ready, or merges it. A timeout, malformed trusted result, or changed PR head
pauses the persisted run safely.
'@
        }

        'branch' {
            return @'
RepoFlow branch commands

  rf branch cleanup
  rf branch cleanup -Apply
'@
        }

        'branch/cleanup' {
            return @'
branch cleanup

Finds local branches whose pull requests are confirmed as merged.

Plan:
  rf branch cleanup

Delete safe merged branches:
  rf branch cleanup -Apply
'@
        }

        'ci' {
            return @'
RepoFlow CI commands

  rf ci watch -Number <pr>
'@
        }

        'run' {
            return @'
RepoFlow run commands

  rf run list
  rf run list -Repo <name>
  rf run show -RunId <id>
  rf run complete -RunId <id>
  rf run complete -RunId <id> -Apply
  rf run prune
  rf run prune -Apply
'@
        }

        'run/list' {
            return @'
run list

Displays persisted workflow run records stored in .repo-flow.state.json.

Examples:
  rf run list
  rf run list -Repo repo-flow
'@
        }

        'run/show' {
            return @'
run show

Displays one persisted workflow run record by ID.

Example:
  rf run show -RunId repo-flow-issue-run-4-20260623T120000Z-abc12345
'@
        }

        'run/complete' {
            return @'
run complete

Marks a persisted workflow run record as completed or abandoned.

Plan:
  rf run complete -RunId <id>

Apply:
  rf run complete -RunId <id> -Apply
  rf run complete -RunId <id> -Apply -Outcome abandoned
'@
        }

        'run/prune' {
            return @'
run prune

Prunes completed and abandoned persisted workflow run records.

Plan:
  rf run prune

Apply:
  rf run prune -Apply
  rf run prune -Apply -Repo repo-flow
'@
        }

        'ci/watch' {
            return @'
ci watch

Waits for GitHub checks associated with the current PR head commit.

Example:
  rf ci watch -Number 116
'@
        }

        'repo' {
            return @'
RepoFlow repository commands

  rf repo list
  rf repo current
  rf repo current -Repo <name>
  rf repo use <name>
  rf repo use <name> -Apply
  rf repo reset
  rf repo reset -Apply

Selection precedence:
explicit -Repo
stored active repository
current working directory
configured default repository
legacy repository configuration
'@
        }

        'repo/list' {
            return @'
repo list

Displays every registered repository with default, active, current-directory,
and legacy markers.

Example:
  rf repo list
'@
        }

        'repo/current' {
            return @'
repo current

Displays the effective selected repository and selection source.

Examples:
  rf repo current
  rf repo current -Repo repo-flow
'@
        }

        'repo/use' {
            return @'
repo use

Stores an active repository selection beside .repo-flow.json.
It does not change the shell working directory.

Plan:
  rf repo use repo-flow

Apply:
  rf repo use repo-flow -Apply
'@
        }

        'repo/reset' {
            return @'
repo reset

Removes the stored active repository selection.

Plan:
  rf repo reset

Apply:
  rf repo reset -Apply
'@
        }

        'config' {
            return @'
RepoFlow configuration commands

  rf config validate
  rf config show

The default configuration file is .repo-flow.json beside repo-flow.ps1.
Use either legacy repository.localPath or defaultRepository with repositories[].
'@
        }

        'config/validate' {
            return @'
config validate

Loads and validates .repo-flow.json before any repository mutation.

Example:
  rf config validate

Custom configuration:
  rf config validate -ConfigPath C:\configs\repo-flow.json
'@
        }

        'config/show' {
            return @'
config show

Displays the effective non-sensitive RepoFlow configuration.

Example:
  rf config show
'@
        }

        default {
            throw (
                "Unknown RepoFlow help topic: '{0}'. " +
                "Run 'rf --help' to see available topics."
            ) -f $Topic
        }
    }
}

function Show-RepoFlowHelp {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Topic
    )

    Get-RepoFlowHelpText -Topic $Topic
}
