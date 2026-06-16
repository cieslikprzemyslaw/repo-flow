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
  .\repo-flow.ps1 <area> <action> [options]
  .\repo-flow.ps1 help [topic]

Commands:
  issue sync
      Synchronise labels, milestones, and issues from issues-manifest.json.

  issue run
      Plan or implement a GitHub issue.

  issue continue
      Continue an open pull request using a selected PR comment.

  pr status
      Display pull-request details and checks.

  pr watch
      Wait for pull-request CI checks.

  pr ready
      Mark a draft pull request as ready for review.

  pr merge
      After manual review, explicitly confirm and merge the pull request.
      'pr accept' is an alias for this command.

  branch cleanup
      Find or delete safely merged local branches.

  ci watch
      Wait for pull-request CI checks.

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
  -Number <number>
  -Apply
  -CiMode skip|observe|require-passing
  -Repo <name>
  -ConfigPath <path>

Aliases:
  -IssueNumber and -PrNumber are aliases for -Number.
  -Run is an alias for -Apply.
  -Repository and -RepositoryName are aliases for -Repo.
  'pr accept' is an alias for 'pr merge'.

Help examples:
  .\repo-flow.ps1 help issue
  .\repo-flow.ps1 help "issue run"
  .\repo-flow.ps1 help pr
  .\repo-flow.ps1 help "pr merge"
  .\repo-flow.ps1 help "branch cleanup"
'@
        }

        'issue' {
            return @'
RepoFlow issue commands

  .\repo-flow.ps1 issue sync
  .\repo-flow.ps1 issue sync -Apply

  .\repo-flow.ps1 issue run -Number <issue>
  .\repo-flow.ps1 issue run -Number <issue> -Apply

  .\repo-flow.ps1 issue continue -Number <issue> -LastPrComment
  .\repo-flow.ps1 issue continue -Number <issue> -LastPrComment -Apply

  .\repo-flow.ps1 issue continue -Number <issue> -PrCommentId <id>
  .\repo-flow.ps1 issue continue -Number <issue> -PrCommentId <id> -Apply
'@
        }

        'issue/sync' {
            return @'
issue sync

Synchronises GitHub labels, milestones, issue updates, and issue creation
from issues-manifest.json.

Plan:
  .\repo-flow.ps1 issue sync

Apply:
  .\repo-flow.ps1 issue sync -Apply

Skip new issue creation:
  .\repo-flow.ps1 issue sync -Apply -SkipCreates
'@
        }

        'issue/run' {
            return @'
issue run

Implements a GitHub issue using the configured coding agent.

Plan:
  .\repo-flow.ps1 issue run -Number 67

Apply:
  .\repo-flow.ps1 issue run -Number 67 -Apply

Optional CI override:
  .\repo-flow.ps1 issue run -Number 67 -Apply -CiMode observe
'@
        }

        'issue/continue' {
            return @'
issue continue

Continues an existing open pull request using trusted review feedback.

Latest PR comment:
  .\repo-flow.ps1 issue continue -Number 66 -LastPrComment -Apply

Specific PR comment:
  .\repo-flow.ps1 issue continue -Number 66 -PrCommentId 123456789 -Apply

Use either -LastPrComment or -PrCommentId, not both.
'@
        }

        'pr' {
            return @'
RepoFlow pull-request commands

  .\repo-flow.ps1 pr status -Number <pr>
  .\repo-flow.ps1 pr watch -Number <pr>
  .\repo-flow.ps1 pr ready -Number <pr> -Apply
  .\repo-flow.ps1 pr merge -Number <pr> -Apply

'pr accept' is an alias for 'pr merge'.
'@
        }

        'pr/status' {
            return @'
pr status

Displays the pull-request state and current check results.

Example:
  .\repo-flow.ps1 pr status -Number 116
'@
        }

        'pr/watch' {
            return @'
pr watch

Waits for checks associated with the current pull-request head commit.

Example:
  .\repo-flow.ps1 pr watch -Number 116
'@
        }

        'pr/ready' {
            return @'
pr ready

Validates a draft pull request and marks it ready for review.

Plan:
  .\repo-flow.ps1 pr ready -Number 116

Apply:
  .\repo-flow.ps1 pr ready -Number 116 -Apply
'@
        }

        { $_ -in @('pr/merge', 'pr/accept') } {
            return @'
pr merge

Use this only after you manually review the pull-request diff and validate
the application. RepoFlow waits for CI, then requires you to type MERGE before
it marks a draft ready or performs any merge mutation.

Plan:
  .\repo-flow.ps1 pr merge -Number 116

Apply:
  .\repo-flow.ps1 pr merge -Number 116 -Apply

Alias:
  .\repo-flow.ps1 pr accept -Number 116 -Apply

This command does not submit a GitHub review approval. It records your
manual decision through an explicit terminal confirmation, then performs the
mechanical ready, merge, base-branch update, and optional branch cleanup steps.

No issue, agent, or CI workflow invokes this command automatically.
'@
        }

        'branch' {
            return @'
RepoFlow branch commands

  .\repo-flow.ps1 branch cleanup
  .\repo-flow.ps1 branch cleanup -Apply
'@
        }

        'branch/cleanup' {
            return @'
branch cleanup

Finds local branches whose pull requests are confirmed as merged.

Plan:
  .\repo-flow.ps1 branch cleanup

Delete safe merged branches:
  .\repo-flow.ps1 branch cleanup -Apply
'@
        }

        'ci' {
            return @'
RepoFlow CI commands

  .\repo-flow.ps1 ci watch -Number <pr>
'@
        }

        'ci/watch' {
            return @'
ci watch

Waits for GitHub checks associated with the current PR head commit.

Example:
  .\repo-flow.ps1 ci watch -Number 116
'@
        }

        'repo' {
            return @'
RepoFlow repository commands

  .\repo-flow.ps1 repo list
  .\repo-flow.ps1 repo current
  .\repo-flow.ps1 repo current -Repo <name>
  .\repo-flow.ps1 repo use -Repo <name>
  .\repo-flow.ps1 repo use -Repo <name> -Apply
  .\repo-flow.ps1 repo reset
  .\repo-flow.ps1 repo reset -Apply

Selection precedence:
  explicit -Repo
  current working directory
  stored active repository
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
  .\repo-flow.ps1 repo list
'@
        }

        'repo/current' {
            return @'
repo current

Displays the effective selected repository and selection source.

Examples:
  .\repo-flow.ps1 repo current
  .\repo-flow.ps1 repo current -Repo repo-flow
'@
        }

        'repo/use' {
            return @'
repo use

Stores an active repository selection beside .repo-flow.json.
It does not change the shell working directory.

Plan:
  .\repo-flow.ps1 repo use -Repo repo-flow

Apply:
  .\repo-flow.ps1 repo use -Repo repo-flow -Apply
'@
        }

        'repo/reset' {
            return @'
repo reset

Removes the stored active repository selection.

Plan:
  .\repo-flow.ps1 repo reset

Apply:
  .\repo-flow.ps1 repo reset -Apply
'@
        }

        'config' {
            return @'
RepoFlow configuration commands

  .\repo-flow.ps1 config validate
  .\repo-flow.ps1 config show

The default configuration file is .repo-flow.json beside repo-flow.ps1.
Use either legacy repository.localPath or defaultRepository with repositories[].
'@
        }

        'config/validate' {
            return @'
config validate

Loads and validates .repo-flow.json before any repository mutation.

Example:
  .\repo-flow.ps1 config validate

Custom configuration:
  .\repo-flow.ps1 config validate -ConfigPath C:\configs\repo-flow.json
'@
        }

        'config/show' {
            return @'
config show

Displays the effective non-sensitive RepoFlow configuration.

Example:
  .\repo-flow.ps1 config show
'@
        }

        default {
            throw (
                "Unknown RepoFlow help topic: '{0}'. " +
                "Run '.\repo-flow.ps1 help' to see available topics."
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
