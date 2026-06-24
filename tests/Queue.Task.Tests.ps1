BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow queue task orchestration' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:Task = [pscustomobject]@{
                position = 0
                issueNumber = 11
                repository = 'flow'
                ciMode = 'require-passing'
                automatedReview = $true
            }
            $script:PullRequest = [pscustomobject]@{
                number = 91
                state = 'OPEN'
                headRefOid = ('a' * 40)
            }
            $script:Snapshot = [pscustomobject]@{
                Config = [pscustomobject]@{}
                RepositoryName = 'flow'
                RepositorySlug = 'owner/repo-flow'
                LocalBranchExists = $false
                RemoteBranchExists = $false
                PullRequest = $script:PullRequest
            }

            Mock Invoke-RepoFlowQueueLocalValidation { return }
            Mock Get-RepoFlowQueueLatestIssueRun {
                return [pscustomobject]@{ runId = 'issue-run' }
            }
            Mock Invoke-RepoFlowIssueResumeWorkflow { return }
        }

        It 'starts a new issue when no branch, PR, or saved run exists' {
            $script:SnapshotCalls = 0
            $script:Task.automatedReview = $false

            Mock Get-RepoFlowQueueTaskSnapshot {
                $script:SnapshotCalls++

                if ($script:SnapshotCalls -eq 1) {
                    return [pscustomobject]@{
                        Config = [pscustomobject]@{}
                        RepositoryName = 'flow'
                        RepositorySlug = 'owner/repo-flow'
                        LocalBranchExists = $false
                        RemoteBranchExists = $false
                        PullRequest = $null
                    }
                }

                return $script:Snapshot
            }
            Mock Get-RepoFlowQueueLatestIssueRun { return $null }
            Mock Invoke-RepoFlowIssueRunWorkflow { return }
            Mock Get-RepoFlowPrCheckState {
                return [pscustomobject]@{ Status = 'passed'; Checks = @() }
            }

            $result = Invoke-RepoFlowQueueTask `
                -Task $script:Task `
                -StateConfigPath '.repo-flow.json' `
                -ConfigPath '.repo-flow.json'

            $result.Status | Should -Be 'merge-gate'
            Should -Invoke Invoke-RepoFlowIssueRunWorkflow -Times 1 -Exactly
            Should -Invoke Invoke-RepoFlowIssueResumeWorkflow -Times 0 -Exactly
        }

        It 'reuses deterministic issue resume when the issue branch already exists' {
            $script:SnapshotCalls = 0
            $script:Task.automatedReview = $false

            Mock Get-RepoFlowQueueTaskSnapshot {
                $script:SnapshotCalls++

                if ($script:SnapshotCalls -eq 1) {
                    return [pscustomobject]@{
                        Config = [pscustomobject]@{}
                        RepositoryName = 'flow'
                        RepositorySlug = 'owner/repo-flow'
                        LocalBranchExists = $true
                        RemoteBranchExists = $true
                        PullRequest = $null
                    }
                }

                return $script:Snapshot
            }
            Mock Get-RepoFlowQueueLatestIssueRun { return $null }
            Mock Invoke-RepoFlowIssueResumeWorkflow { return }
            Mock Invoke-RepoFlowIssueRunWorkflow { throw 'Must not start again.' }
            Mock Get-RepoFlowPrCheckState {
                return [pscustomobject]@{ Status = 'passed'; Checks = @() }
            }

            $result = Invoke-RepoFlowQueueTask `
                -Task $script:Task `
                -StateConfigPath '.repo-flow.json' `
                -ConfigPath '.repo-flow.json'

            $result.Status | Should -Be 'merge-gate'
            Should -Invoke Invoke-RepoFlowIssueResumeWorkflow -Times 1 -Exactly
            Should -Invoke Invoke-RepoFlowIssueRunWorkflow -Times 0 -Exactly
        }

        It 'reconciles a saved issue run even when an open PR already exists' {
            $script:SnapshotCalls = 0
            $script:Task.automatedReview = $false
            $script:UpdatedPullRequest = [pscustomobject]@{
                number = 91
                state = 'OPEN'
                headRefOid = ('b' * 40)
            }

            Mock Get-RepoFlowQueueTaskSnapshot {
                $script:SnapshotCalls++
                $currentPullRequest = if ($script:SnapshotCalls -eq 1) {
                    $script:PullRequest
                }
                else {
                    $script:UpdatedPullRequest
                }

                return [pscustomobject]@{
                    Config = [pscustomobject]@{}
                    RepositoryName = 'flow'
                    RepositorySlug = 'owner/repo-flow'
                    LocalBranchExists = $true
                    RemoteBranchExists = $true
                    PullRequest = $currentPullRequest
                }
            }
            Mock Get-RepoFlowQueueLatestIssueRun {
                return [pscustomobject]@{ runId = 'issue-run' }
            }
            Mock Invoke-RepoFlowIssueResumeWorkflow { return }
            Mock Invoke-RepoFlowIssueRunWorkflow { throw 'Must not start again.' }
            Mock Get-RepoFlowPrCheckState {
                return [pscustomobject]@{ Status = 'passed'; Checks = @() }
            }

            $result = Invoke-RepoFlowQueueTask `
                -Task $script:Task `
                -StateConfigPath '.repo-flow.json' `
                -ConfigPath '.repo-flow.json'

            $result.Status | Should -Be 'merge-gate'
            $result.PullRequest.headRefOid | Should -Be ('b' * 40)
            Should -Invoke Invoke-RepoFlowIssueResumeWorkflow -Times 1 -Exactly
            Should -Invoke Invoke-RepoFlowIssueRunWorkflow -Times 0 -Exactly
            $script:SnapshotCalls | Should -Be 2
        }

        It 'pauses when an open PR has no saved deterministic issue run' {
            Mock Get-RepoFlowQueueTaskSnapshot { return $script:Snapshot }
            Mock Get-RepoFlowQueueLatestIssueRun { return $null }
            Mock Invoke-RepoFlowPrReviewWorkflow { throw 'Review must not run.' }

            $result = Invoke-RepoFlowQueueTask `
                -Task $script:Task `
                -StateConfigPath '.repo-flow.json' `
                -ConfigPath '.repo-flow.json'

            $result.Status | Should -Be 'paused'
            $result.Phase | Should -Be 'missing-run-state'
            $result.Reason | Should -Match 'cannot resume it deterministically'
            Should -Invoke Invoke-RepoFlowIssueResumeWorkflow -Times 0 -Exactly
            Should -Invoke Invoke-RepoFlowPrReviewWorkflow -Times 0 -Exactly
        }

        It 'pauses on CI that is still not passing after deterministic handling' {
            Mock Get-RepoFlowQueueTaskSnapshot { return $script:Snapshot }
            Mock Get-RepoFlowPrCheckState {
                return [pscustomobject]@{ Status = 'failed'; Checks = @() }
            }
            Mock Invoke-RepoFlowIssueResumeWorkflow { return }
            Mock Get-RepoFlowPullRequest { return $script:PullRequest }
            Mock Invoke-RepoFlowPrReviewWorkflow { throw 'Review must not run.' }

            $result = Invoke-RepoFlowQueueTask `
                -Task $script:Task `
                -StateConfigPath '.repo-flow.json' `
                -ConfigPath '.repo-flow.json'

            $result.Status | Should -Be 'paused'
            $result.Phase | Should -Be 'ci-not-passing'
            $result.Reason | Should -Match 'Passing CI is required'
            Should -Invoke Invoke-RepoFlowPrReviewWorkflow -Times 0 -Exactly
        }

        It 'persists the automated review pause outcome' {
            Mock Get-RepoFlowQueueTaskSnapshot { return $script:Snapshot }
            Mock Get-RepoFlowPrCheckState {
                return [pscustomobject]@{ Status = 'passed'; Checks = @() }
            }
            Mock Get-RepoFlowQueueReviewRunState {
                if ($script:ReviewChecked) {
                    return [pscustomobject]@{
                        Status = 'paused'
                        Record = [pscustomobject]@{
                            runId = 'review-run'
                            currentPhase = 'manual-review'
                            pauseReason = 'Human decision required.'
                        }
                    }
                }

                $script:ReviewChecked = $true
                return [pscustomobject]@{ Status = 'missing'; Record = $null }
            }
            Mock Invoke-RepoFlowPrReviewWorkflow { return }
            Mock Get-RepoFlowPullRequest { return $script:PullRequest }

            $script:ReviewChecked = $false
            $result = Invoke-RepoFlowQueueTask `
                -Task $script:Task `
                -StateConfigPath '.repo-flow.json' `
                -ConfigPath '.repo-flow.json'

            $result.Status | Should -Be 'paused'
            $result.Phase | Should -Be 'review-paused'
            $result.RunRecord.runId | Should -Be 'review-run'
            $result.Reason | Should -Match 'Human decision required'
        }

        It 'does not reuse a paused review checkpoint from a stale head' {
            Mock Get-RepoFlowPrReviewLoopRunRecord {
                return [pscustomobject]@{
                    status = 'paused'
                    currentPhase = 'manual-review'
                    headSha = ('b' * 40)
                    pauseReason = 'Old head requires a decision.'
                }
            }

            $state = Get-RepoFlowQueueReviewRunState `
                -ConfigPath '.repo-flow.json' `
                -RepositorySlug 'owner/repo-flow' `
                -PullRequest $script:PullRequest

            $state.Status | Should -Be 'incomplete'
            $state.Record.pauseReason | Should -Match 'Old head'
        }

        It 'reuses an exact-head passing review checkpoint' {
            Mock Get-RepoFlowQueueTaskSnapshot { return $script:Snapshot }
            Mock Get-RepoFlowPrCheckState {
                return [pscustomobject]@{ Status = 'passed'; Checks = @() }
            }
            Mock Get-RepoFlowQueueReviewRunState {
                return [pscustomobject]@{
                    Status = 'passed'
                    Record = [pscustomobject]@{ runId = 'review-pass' }
                }
            }
            Mock Invoke-RepoFlowPrReviewWorkflow { throw 'Must not rerun review.' }

            $result = Invoke-RepoFlowQueueTask `
                -Task $script:Task `
                -StateConfigPath '.repo-flow.json' `
                -ConfigPath '.repo-flow.json'

            $result.Status | Should -Be 'merge-gate'
            $result.Phase | Should -Be 'merge-gate'
            $result.RunRecord.runId | Should -Be 'review-pass'
            Should -Invoke Invoke-RepoFlowPrReviewWorkflow -Times 0 -Exactly
        }

        It 'rechecks CI after automated review or repair changes the head' {
            $script:CiChecks = 0
            Mock Get-RepoFlowQueueTaskSnapshot { return $script:Snapshot }
            Mock Get-RepoFlowPrCheckState {
                $script:CiChecks++

                if ($script:CiChecks -eq 1) {
                    return [pscustomobject]@{ Status = 'passed'; Checks = @() }
                }

                return [pscustomobject]@{ Status = 'pending'; Checks = @() }
            }
            Mock Get-RepoFlowQueueReviewRunState {
                return [pscustomobject]@{
                    Status = 'passed'
                    Record = [pscustomobject]@{ runId = 'review-pass' }
                }
            }

            $result = Invoke-RepoFlowQueueTask `
                -Task $script:Task `
                -StateConfigPath '.repo-flow.json' `
                -ConfigPath '.repo-flow.json'

            $result.Status | Should -Be 'paused'
            $result.Phase | Should -Be 'post-review-ci-not-passing'
            $result.Reason | Should -Match 'CI changed after automated review'
            $script:CiChecks | Should -Be 2
        }

        It 'completes cleanup for an already merged pull request' {
            $script:PullRequest.state = 'MERGED'
            Mock Get-RepoFlowQueueTaskSnapshot { return $script:Snapshot }
            Mock Complete-RepoFlowPostMergeCleanup { return }

            $result = Invoke-RepoFlowQueueTask `
                -Task $script:Task `
                -StateConfigPath '.repo-flow.json' `
                -ConfigPath '.repo-flow.json'

            $result.Status | Should -Be 'completed'
            $result.Phase | Should -Be 'cleanup-completed'
            Should -Invoke Complete-RepoFlowPostMergeCleanup -Times 1 -Exactly
        }
    }
}
