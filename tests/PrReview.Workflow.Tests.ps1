BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow bounded PR review workflow' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:pullRequest = [pscustomobject]@{
                number = 25
                title = 'Add review loop'
                url = 'https://example.test/pull/25'
                state = 'OPEN'
                baseRefName = 'main'
                baseRefOid = ('a' * 40)
                headRefName = 'feature/10-review-loop'
                headRefOid = ('b' * 40)
                body = 'Closes #10'
            }
            $script:issue = [pscustomobject]@{
                number = 10
                title = 'Add review loop'
                body = "## Acceptance criteria`n- [ ] Review."
                url = 'https://example.test/issues/10'
            }
            $script:config = [pscustomobject]@{
                repository = [pscustomobject]@{
                    slug = 'owner/repo'
                    baseBranch = 'main'
                }
                ci = [pscustomobject]@{
                    mode = 'require-passing'
                    pollSeconds = 10
                    timeoutSeconds = 30
                }
                reviewFeedback = [pscustomobject]@{
                    enabled = $true
                    trustedAssociations = @('OWNER')
                    maxReviewCycles = 3
                    maxRepairCycles = 2
                }
                agent = [pscustomobject]@{
                    provider = 'codex'
                    command = 'codex'
                    model = 'gpt-5.5'
                    noActivityWarningSeconds = 180
                }
            }
            $script:runRecord = [pscustomobject]@{
                runId = 'rf-pr-review-v1-owner-repo-pr-25'
                operation = 'pr-review-loop'
                status = 'running'
                currentPhase = 'review-loop-started'
                baseSha = ('a' * 40)
                headSha = ('b' * 40)
                createdAtUtc = '2026-06-24T18:00:00Z'
                reviewAttemptCount = 0
                repairAttemptCount = 0
            }
            $script:passResult = [pscustomobject]@{
                verdict = 'pass'
                blockers = @()
                warnings = @()
            }
            $script:changesResult = [pscustomobject]@{
                verdict = 'changes_required'
                blockers = @(
                    [pscustomobject]@{
                        category = 'correctness'
                        explanation = 'Fix the result.'
                    }
                )
                warnings = @()
            }
            $script:manualResult = [pscustomobject]@{
                verdict = 'manual_review'
                blockers = @()
                warnings = @()
            }

            Mock New-RepoFlowContext {
                [pscustomobject]@{
                    RepositoryRoot = 'C:\repo'
                    Config = $script:config
                    RepositorySelection = [pscustomobject]@{
                        Registry = [pscustomobject]@{
                            ConfigPath = (Join-Path $TestDrive '.repo-flow.json')
                        }
                        Repository = [pscustomobject]@{ name = 'repo' }
                    }
                }
            }
            Mock Get-RepoFlowPullRequest { $script:pullRequest }
            Mock Assert-RepoFlowPrReviewPullRequest { return }
            Mock Assert-RepoFlowPrReviewLocalState { return }
            Mock Get-RepoFlowPullRequestIssueNumber { 10 }
            Mock Get-RepoFlowIssue { $script:issue }
            Mock Get-RepoFlowPrCheckState {
                [pscustomobject]@{ Status = 'passed'; Checks = @() }
            }
            Mock Resolve-RepoFlowPrReviewCiState {
                [pscustomobject]@{ Status = 'passed'; Checks = @() }
            }
            Mock Initialize-RepoFlowPrReviewLoopRun {
                [pscustomobject]@{
                    Record = $script:runRecord
                    AlreadyPassed = $false
                    Paused = $false
                }
            }
            Mock Set-RepoFlowRunCheckpoint { return }
            Mock Complete-RepoFlowRunRecord { return }
            Mock Set-RepoFlowPrReviewLoopPaused { return }
            Mock Invoke-RepoFlowAutomatedReviewWorkflow { return }
            Mock Get-RepoFlowRunRecord { $script:runRecord }
            Mock Get-RepoFlowReviewBlockerFingerprint { 'f' * 64 }
            Mock Test-RepoFlowReviewBlockerFingerprintRecorded { $false }
            Mock Save-RepoFlowReviewBlockerFingerprint { return }
            Mock Invoke-RepoFlowPrMergeWorkflow {
                throw 'Merge must never run.'
            }
        }

        It 'does not resume a paused human-decision state automatically' {
            Mock Initialize-RepoFlowPrReviewLoopRun {
                $script:runRecord.status = 'paused'
                $script:runRecord.currentPhase = 'review-manual-review'

                [pscustomobject]@{
                    Record = $script:runRecord
                    AlreadyPassed = $false
                    Paused = $true
                }
            }
            Mock Get-RepoFlowAcceptedPrReviewResult {
                throw 'A paused run must not consume another result.'
            }

            Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply

            Should -Invoke Invoke-RepoFlowAutomatedReviewWorkflow `
                -Times 0 `
                -Exactly
            Should -Invoke Get-RepoFlowAcceptedPrReviewResult `
                -Times 0 `
                -Exactly
        }

        It 'stops if the PR base changes while CI is being observed' {
            $script:prReads = 0

            Mock Get-RepoFlowPullRequest {
                $script:prReads++

                if ($script:prReads -ge 4) {
                    return [pscustomobject]@{
                        number = 25
                        title = 'Add review loop'
                        url = 'https://example.test/pull/25'
                        state = 'OPEN'
                        baseRefName = 'main'
                        baseRefOid = ('d' * 40)
                        headRefName = 'feature/10-review-loop'
                        headRefOid = ('b' * 40)
                        body = 'Closes #10'
                    }
                }

                return $script:pullRequest
            }

            {
                Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply
            } | Should -Throw '*base SHA changed*'

            Should -Invoke Invoke-RepoFlowAutomatedReviewWorkflow `
                -Times 0 `
                -Exactly
            Should -Invoke Set-RepoFlowPrReviewLoopPaused `
                -Times 1 `
                -Exactly
        }

        It 'records pass without repair or merge' {
            Mock Get-RepoFlowAcceptedPrReviewResult {
                [pscustomobject]@{ Result = $script:passResult }
            }
            Mock Invoke-RepoFlowPrReviewRepairCycle {
                throw 'Repair must not run.'
            }

            Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply

            Should -Invoke Complete-RepoFlowRunRecord -Times 1 -Exactly
            Should -Invoke Invoke-RepoFlowPrReviewRepairCycle -Times 0 -Exactly
            Should -Invoke Invoke-RepoFlowPrMergeWorkflow -Times 0 -Exactly
        }

        It 'pauses on manual review without running a repair' {
            Mock Get-RepoFlowAcceptedPrReviewResult {
                [pscustomobject]@{ Result = $script:manualResult }
            }
            Mock Invoke-RepoFlowPrReviewRepairCycle {
                throw 'Repair must not run.'
            }

            Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply

            Should -Invoke Set-RepoFlowPrReviewLoopPaused `
                -Times 1 `
                -Exactly `
                -ParameterFilter { $Phase -eq 'review-manual-review' }
            Should -Invoke Invoke-RepoFlowPrReviewRepairCycle -Times 0 -Exactly
        }

        It 'repairs changes and requests a fresh review for the new head' {
            $script:resultCalls = 0

            Mock Get-RepoFlowAcceptedPrReviewResult {
                $script:resultCalls++

                if ($script:resultCalls -eq 1) {
                    return [pscustomobject]@{
                        Result = $script:changesResult
                    }
                }

                return [pscustomobject]@{ Result = $script:passResult }
            }
            Mock Invoke-RepoFlowPrReviewRepairCycle {
                $script:pullRequest = [pscustomobject]@{
                    number = 25
                    title = 'Add review loop'
                    url = 'https://example.test/pull/25'
                    state = 'OPEN'
                    baseRefName = 'main'
                    baseRefOid = ('a' * 40)
                    headRefName = 'feature/10-review-loop'
                    headRefOid = ('c' * 40)
                    body = 'Closes #10'
                }
                $script:runRecord.headSha = 'c' * 40
                $script:runRecord.repairAttemptCount = 1

                return [pscustomobject]@{
                    PullRequest = $script:pullRequest
                    Checks = [pscustomobject]@{
                        Status = 'passed'
                        Checks = @()
                    }
                    HeadSha = ('c' * 40)
                }
            }

            Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply

            Should -Invoke Invoke-RepoFlowAutomatedReviewWorkflow `
                -Times 2 `
                -Exactly
            Should -Invoke Invoke-RepoFlowPrReviewRepairCycle `
                -Times 1 `
                -Exactly
            Should -Invoke Complete-RepoFlowRunRecord -Times 1 -Exactly
        }

        It 'stops when the same blockers are returned again' {
            Mock Get-RepoFlowAcceptedPrReviewResult {
                [pscustomobject]@{ Result = $script:changesResult }
            }
            Mock Test-RepoFlowReviewBlockerFingerprintRecorded { $true }
            Mock Invoke-RepoFlowPrReviewRepairCycle {
                throw 'Repair must not run for repeated blockers.'
            }

            Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply

            Should -Invoke Set-RepoFlowPrReviewLoopPaused `
                -Times 1 `
                -Exactly `
                -ParameterFilter { $Phase -eq 'review-repeated-blockers' }
            Should -Invoke Invoke-RepoFlowPrReviewRepairCycle -Times 0 -Exactly
        }

        It 'pauses when the repair limit is exhausted' {
            $script:config.reviewFeedback.maxRepairCycles = 0

            Mock Get-RepoFlowAcceptedPrReviewResult {
                [pscustomobject]@{ Result = $script:changesResult }
            }
            Mock Invoke-RepoFlowPrReviewRepairCycle {
                throw 'Repair must not run after limit exhaustion.'
            }

            Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply

            Should -Invoke Set-RepoFlowPrReviewLoopPaused `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Phase -eq 'review-repair-limit-exhausted'
                }
            Should -Invoke Invoke-RepoFlowPrReviewRepairCycle -Times 0 -Exactly
        }

        It 'pauses and preserves failure when an accepted result becomes stale' {
            Mock Get-RepoFlowAcceptedPrReviewResult {
                throw 'Automated review result is stale.'
            }

            {
                Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply
            } | Should -Throw '*stale*'

            Should -Invoke Set-RepoFlowPrReviewLoopPaused -Times 1 -Exactly
            Should -Invoke Invoke-RepoFlowPrMergeWorkflow -Times 0 -Exactly
        }

        It 'pauses before repair when no fresh review cycle remains' {
            $script:config.reviewFeedback.maxReviewCycles = 1
            $script:config.reviewFeedback.maxRepairCycles = 1

            Mock Get-RepoFlowAcceptedPrReviewResult {
                [pscustomobject]@{ Result = $script:changesResult }
            }
            Mock Invoke-RepoFlowPrReviewRepairCycle {
                throw 'Repair must not run without a fresh review cycle.'
            }

            Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply

            Should -Invoke Set-RepoFlowPrReviewLoopPaused `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Phase -eq 'review-cycle-limit-exhausted'
                }
            Should -Invoke Invoke-RepoFlowPrReviewRepairCycle `
                -Times 0 `
                -Exactly
        }
    }
}
