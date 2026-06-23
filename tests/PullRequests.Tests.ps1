BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow pull request body generation' {
    InModuleScope RepoFlow {
        It 'fills the project pull request template' {
            $template = @'
## Summary

<!-- Briefly describe what this PR implements. -->

Closes #

## Changes

Placeholder.

## Acceptance criteria

Placeholder.

## Scope deviations

Placeholder.

## Security impact

Placeholder.
'@
            $issue = [pscustomobject]@{
                number = 66
                title = 'Add user identity'
                body = "## Acceptance criteria`n`n- [ ] Identity is shown."
            }
            $summary = @'
## Changes

- Added identity.

## Acceptance criteria

- [x] Identity is shown.

## Scope deviations

None.

## Security impact

None.
'@

            $body = Build-RepoFlowPullRequestBody `
                -Template $template `
                -Issue $issue `
                -AgentSummary $summary

            $body | Should -Match 'Implements #66: Add user identity\.'
            $body | Should -Match 'Closes #66'
            $body | Should -Match '- Added identity\.'
            $body | Should -Match '- \[x\] Identity is shown\.'
        }

        It 'extracts the originating issue number from a pull request body' {
            $pullRequest = [pscustomobject]@{
                body = @'
Summary

Closes #88
'@
            }

            Get-RepoFlowPullRequestIssueNumber -PullRequest $pullRequest |
                Should -Be 88
        }
    }
}

