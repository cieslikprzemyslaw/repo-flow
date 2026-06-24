BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow queue dependency planning' {
    InModuleScope RepoFlow {
        BeforeAll {
            function New-TestQueuePlanEntry {
                param(
                    [int]$Position,
                    [int]$IssueNumber,
                    [string]$Body = '',
                    [string]$State = 'OPEN',
                    [string]$Repository = 'owner/repo'
                )

                return [pscustomobject]@{
                    Task = [pscustomobject]@{
                        position = $Position
                        issueNumber = $IssueNumber
                    }
                    Snapshot = [pscustomobject]@{
                        RepositorySlug = $Repository
                        Issue = [pscustomobject]@{
                            number = $IssueNumber
                            title = "Issue $IssueNumber"
                            body = $Body
                            state = $State
                        }
                        PullRequest = $null
                    }
                }
            }
        }

        It 'allows an open dependency scheduled earlier in the same repository queue' {
            $entries = @(
                New-TestQueuePlanEntry -Position 0 -IssueNumber 11
                New-TestQueuePlanEntry `
                    -Position 1 `
                    -IssueNumber 12 `
                    -Body "## Dependencies`n`n- #11"
            )

            {
                Assert-RepoFlowQueuePlanDependencies -Entries $entries
            } | Should -Not -Throw
        }

        It 'rejects an open dependency scheduled later in the queue' {
            $entries = @(
                New-TestQueuePlanEntry `
                    -Position 0 `
                    -IssueNumber 12 `
                    -Body "## Dependencies`n`n- #11"
                New-TestQueuePlanEntry -Position 1 -IssueNumber 11
            )

            {
                Assert-RepoFlowQueuePlanDependencies -Entries $entries
            } | Should -Throw '*not earlier in the queue*'
        }

        It 'rejects an open dependency missing from the queue' {
            $entries = @(
                New-TestQueuePlanEntry `
                    -Position 0 `
                    -IssueNumber 12 `
                    -Body "## Dependencies`n`n- #9"
            )

            Mock Get-RepoFlowIssue {
                return [pscustomobject]@{
                    number = 9
                    title = 'Still open'
                    state = 'OPEN'
                }
            }

            {
                Assert-RepoFlowQueuePlanDependencies -Entries $entries
            } | Should -Throw '*not scheduled earlier*'
        }

        It 'accepts a closed dependency that is not in the queue' {
            $entries = @(
                New-TestQueuePlanEntry `
                    -Position 0 `
                    -IssueNumber 12 `
                    -Body "## Dependencies`n`n- #9"
            )

            Mock Get-RepoFlowIssue {
                return [pscustomobject]@{
                    number = 9
                    title = 'Already done'
                    state = 'CLOSED'
                }
            }

            {
                Assert-RepoFlowQueuePlanDependencies -Entries $entries
            } | Should -Not -Throw
        }

        It 'rejects duplicate tasks that resolve to the same repository and issue' {
            $entries = @(
                New-TestQueuePlanEntry -Position 0 -IssueNumber 11
                New-TestQueuePlanEntry -Position 1 -IssueNumber 11
            )

            {
                Assert-RepoFlowQueuePlanDependencies -Entries $entries
            } | Should -Throw '*more than one task*'
        }
    }
}
