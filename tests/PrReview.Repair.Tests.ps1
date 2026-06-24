BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow PR review repair cycle' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:config = [pscustomobject]@{
                repository = [pscustomobject]@{ baseBranch = 'main' }
                ci = [pscustomobject]@{
                    pollSeconds = 10
                    timeoutSeconds = 30
                }
                agent = [pscustomobject]@{
                    reasoningEffort = 'medium'
                    noActivityWarningSeconds = 180
                }
            }
            $script:context = [pscustomobject]@{
                RepositoryRoot = 'C:\repo'
                Config = $script:config
            }
            $script:issue = [pscustomobject]@{
                number = 10
                title = 'Add review loop'
                body = 'Scope'
            }
            $script:pullRequest = [pscustomobject]@{
                number = 25
                url = 'https://example.test/pull/25'
                headRefName = 'feature/10-review-loop'
                headRefOid = ('b' * 40)
            }
            $script:result = [pscustomobject]@{
                verdict = 'changes_required'
                blockers = @(
                    [pscustomobject]@{
                        category = 'correctness'
                        explanation = 'Fix blocker.'
                    }
                )
            }
            $script:runRecord = [pscustomobject]@{
                runId = 'review-loop'
                reviewAttemptCount = 1
            }

            Mock Assert-RepoFlowPrReviewLocalState { return }
            Mock Assert-RepoFlowPrRepairLiveHead { $script:pullRequest }
            Mock Get-RepoFlowPullRequestChangedFiles { @('src/a.ps1') }
            Mock Write-RepoFlowReviewRepairContext { 'C:\temp\context.json' }
            Mock New-RepoFlowReviewRepairPrompt { 'repair prompt' }
            Mock Set-RepoFlowRunCheckpoint { return }
            Mock Invoke-RepoFlowAgent {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                    Usage = New-RepoFlowAgentUsage
                    DurationSeconds = 0
                }
            }
            Mock Get-RepoFlowAgentFinalMessage { 'done' }
            Mock Get-RepoFlowWorkingTreeStatus { ' M src/a.ps1' }
            Mock Invoke-RepoFlowLocalValidation {
                [pscustomobject]@{ ExitCode = 0; Text = '' }
            }
            Mock Get-RepoFlowReviewCommitMessage { 'Fix review feedback for #10' }
            Mock Complete-RepoFlowCommit { return }
            Mock Get-RepoFlowCommitHash { 'c' * 40 }
            Mock Push-RepoFlowBranch { return }
            Mock Wait-RepoFlowPullRequestHead {
                [pscustomobject]@{
                    number = 25
                    headRefName = 'feature/10-review-loop'
                    headRefOid = ('c' * 40)
                }
            }
            Mock Wait-RepoFlowPrChecks {
                [pscustomobject]@{
                    Status = 'passed'
                    Checks = @()
                }
            }
            Mock Get-RepoFlowCiIdentifiersFromChecks {
                [pscustomobject]@{ RunIds = @(); JobIds = @() }
            }
            Mock Invoke-RepoFlowPrMergeWorkflow {
                throw 'Merge must never run.'
            }
        }

        It 'validates, commits, pushes, observes CI, and returns the new head' {
            $repair = Invoke-RepoFlowPrReviewRepairCycle `
                -Number 25 `
                -Context $script:context `
                -StateConfigPath (Join-Path $TestDrive '.repo-flow.json') `
                -RepositoryName 'repo' `
                -Repository 'owner/repo' `
                -Issue $script:issue `
                -PullRequest $script:pullRequest `
                -Result $script:result `
                -RunRecord $script:runRecord `
                -RepairAttempt 1 `
                -RepairAttemptLimit 2 `
                -RequirePassingCi $true

            $repair.HeadSha | Should -Be ('c' * 40)
            Should -Invoke Complete-RepoFlowCommit -Times 1 -Exactly
            Should -Invoke Push-RepoFlowBranch -Times 1 -Exactly
            Should -Invoke Wait-RepoFlowPrChecks -Times 1 -Exactly
            Should -Invoke Invoke-RepoFlowPrMergeWorkflow -Times 0 -Exactly
        }

        It 'leaves changes unpushed when local validation fails' {
            Mock Invoke-RepoFlowLocalValidation {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = 'validation failed'
                }
            }

            {
                Invoke-RepoFlowPrReviewRepairCycle `
                    -Number 25 `
                    -Context $script:context `
                    -StateConfigPath (Join-Path $TestDrive '.repo-flow.json') `
                    -RepositoryName 'repo' `
                    -Repository 'owner/repo' `
                    -Issue $script:issue `
                    -PullRequest $script:pullRequest `
                    -Result $script:result `
                    -RunRecord $script:runRecord `
                    -RepairAttempt 1 `
                    -RepairAttemptLimit 2 `
                    -RequirePassingCi $true
            } | Should -Throw '*Local validation failed*'

            Should -Invoke Complete-RepoFlowCommit -Times 0 -Exactly
            Should -Invoke Push-RepoFlowBranch -Times 0 -Exactly
        }

        It 'does not commit after an agent failure' {
            Mock Invoke-RepoFlowAgent {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = 'agent failed'
                    Usage = New-RepoFlowAgentUsage
                    DurationSeconds = 0
                }
            }

            {
                Invoke-RepoFlowPrReviewRepairCycle `
                    -Number 25 `
                    -Context $script:context `
                    -StateConfigPath (Join-Path $TestDrive '.repo-flow.json') `
                    -RepositoryName 'repo' `
                    -Repository 'owner/repo' `
                    -Issue $script:issue `
                    -PullRequest $script:pullRequest `
                    -Result $script:result `
                    -RunRecord $script:runRecord `
                    -RepairAttempt 1 `
                    -RepairAttemptLimit 2 `
                    -RequirePassingCi $true
            } | Should -Throw '*agent failed*'

            Should -Invoke Complete-RepoFlowCommit -Times 0 -Exactly
            Should -Invoke Push-RepoFlowBranch -Times 0 -Exactly
        }

        It 'requires passing CI before requesting another review' {
            Mock Wait-RepoFlowPrChecks {
                [pscustomobject]@{
                    Status = 'failed'
                    Checks = @()
                }
            }

            {
                Invoke-RepoFlowPrReviewRepairCycle `
                    -Number 25 `
                    -Context $script:context `
                    -StateConfigPath (Join-Path $TestDrive '.repo-flow.json') `
                    -RepositoryName 'repo' `
                    -Repository 'owner/repo' `
                    -Issue $script:issue `
                    -PullRequest $script:pullRequest `
                    -Result $script:result `
                    -RunRecord $script:runRecord `
                    -RepairAttempt 1 `
                    -RepairAttemptLimit 2 `
                    -RequirePassingCi $true
            } | Should -Throw '*fresh review request was not published*'
        }
    }
}
