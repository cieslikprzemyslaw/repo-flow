BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow bounded PR review workflow' {
    InModuleScope RepoFlow {
        BeforeAll {
            $script:realAutomatedReviewWorkflow = (
                Get-Command Invoke-RepoFlowAutomatedReviewWorkflow
            ).ScriptBlock
        }

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
            Mock Invoke-RepoFlowPrRepairWorkflow { return }
            Mock Get-RepoFlowRunRecord { $script:runRecord }
            Mock Get-RepoFlowReviewBlockerFingerprint { 'f' * 64 }
            Mock Test-RepoFlowReviewBlockerFingerprintRecorded { $false }
            Mock Save-RepoFlowReviewBlockerFingerprint { return }
            Mock Invoke-RepoFlowPrMergeWorkflow {
                throw 'Merge must never run.'
            }
        }

        It 'hands failed pre-review CI to AI repair before requesting review' {
            $script:ciReads = 0

            Mock Resolve-RepoFlowPrReviewCiState {
                $script:ciReads++

                if ($script:ciReads -eq 1) {
                    return [pscustomobject]@{
                        Status = 'failed'
                        Checks = @(
                            [pscustomobject]@{
                                name = 'test (ubuntu-latest)'
                                bucket = 'fail'
                            }
                        )
                    }
                }

                return [pscustomobject]@{
                    Status = 'passed'
                    Checks = @()
                }
            }

            Mock Get-RepoFlowAcceptedPrReviewResult {
                [pscustomobject]@{
                    Result = $script:passResult
                }
            }

            Invoke-RepoFlowPrReviewWorkflow `
                -Number 25 `
                -Apply `
                -Repo repo

            Should -Invoke Invoke-RepoFlowPrRepairWorkflow `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Number -eq 25 -and
                    $Apply -and
                    $Repo -eq 'repo'
                }

            Should -Invoke Invoke-RepoFlowAutomatedReviewWorkflow `
                -Times 1 `
                -Exactly

            Should -Invoke Resolve-RepoFlowPrReviewCiState `
                -Times 3 `
                -Exactly
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

        It 'runs the local bridge result through the automated review loop' {
            $script:config.reviewer = [pscustomobject]@{
                mode = 'local'
                provider = 'codex'
                command = 'codex'
                model = 'gpt-5.5'
                reasoningEffort = 'high'
                heartbeatSeconds = 15
                noActivityWarningSeconds = 180
                timeoutSeconds = 900
            }
            $script:records = @{}
            $script:comments = [System.Collections.Generic.List[object]]::new()
            $script:nextCommentId = 1000
            $script:publishedRequest = $null

            Mock Invoke-RepoFlowAutomatedReviewWorkflow {
                param(
                    [int]$Number,
                    [switch]$Apply,
                    [string]$ConfigPath,
                    [string]$Repo
                )

                & $script:realAutomatedReviewWorkflow `
                    -Number $Number `
                    -Apply:$Apply `
                    -ConfigPath $ConfigPath `
                    -Repo $Repo
            }
            Mock Get-RepoFlowPullRequestFiles {
                @([pscustomobject]@{
                    filename = 'scripts/RepoFlow/Private/ReviewBridge.Local.ps1'
                    status = 'modified'
                })
            }
            Mock Get-RepoFlowAuthenticatedGitHubLogin { 'repo-owner' }
            Mock Get-RepoFlowAllPullRequestComments { @($script:comments) }
            Mock New-RepoFlowPullRequestComment {
                param($PullRequestNumber, $Repository, $Body)

                $script:nextCommentId++
                $marker = if ($Body -match 'rf-review-request:v1') {
                    $script:publishedRequest = ConvertFrom-RepoFlowReviewComment `
                        -Text $Body `
                        -Kind request
                    'request'
                }
                else {
                    'result'
                }
                $comment = [pscustomobject]@{
                    id = $script:nextCommentId
                    body = $Body
                    created_at = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o')
                    author_association = 'OWNER'
                    issue_url = "https://api.github.test/repos/owner/repo/issues/$PullRequestNumber"
                    html_url = "https://example.test/pull/$PullRequestNumber#issuecomment-$script:nextCommentId"
                    marker = $marker
                    user = [pscustomobject]@{
                        login = 'repo-owner'
                        type = 'User'
                    }
                }
                $script:comments.Add($comment)
                return $comment
            }
            Mock Get-RepoFlowPullRequestComment {
                param($CommentId, $Repository)

                return @($script:comments |
                    Where-Object { [long]$_.id -eq [long]$CommentId } |
                    Select-Object -First 1)
            }
            Mock Enter-RepoFlowLocalReviewBridgeLock {
                [pscustomobject]@{ Path = 'lock'; Stream = $null }
            }
            Mock Exit-RepoFlowLocalReviewBridgeLock {}
            Mock Get-RepoFlowLocalGitHeadSha { [string]$script:pullRequest.headRefOid }
            Mock Get-RepoFlowWorkingTreeStatus { '' }
            Mock Invoke-RepoFlowLocalReviewerAgent {
                $reviewerId = Get-RepoFlowLocalReviewerId `
                    -Reviewer $script:config.reviewer
                $result = [pscustomobject][ordered]@{
                    contractVersion = '1'
                    kind = 'review_result'
                    requestId = [string]$script:publishedRequest.requestId
                    reviewedHeadSha = [string]$script:publishedRequest.headSha
                    verdict = 'pass'
                    blockers = @()
                    warnings = @()
                    reviewFlags = [pscustomobject]@{
                        testsReviewed = $true
                        scopeReviewed = $true
                        securityReviewed = $true
                    }
                    reviewerId = $reviewerId
                    completedAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(1).ToString('o')
                }

                [pscustomobject]@{
                    ExitCode = 0
                    TimedOut = $false
                    Text = ''
                    FinalMessage = ($result | ConvertTo-Json -Depth 20)
                }
            }
            Mock Get-RepoFlowRunRecord {
                param($ConfigPath, $RunId)

                if ($script:records.ContainsKey([string]$RunId)) {
                    return $script:records[[string]$RunId]
                }

                if ([string]$RunId -eq [string]$script:runRecord.runId) {
                    return $script:runRecord
                }

                return $null
            }
            Mock Get-RepoFlowRunRecords { @($script:records.Values) }
            Mock Start-RepoFlowRunRecord {
                param(
                    [string]$ConfigPath,
                    [string]$RepositoryRoot,
                    [string]$Repository,
                    [string]$RepositorySlug,
                    [string]$Operation,
                    [int]$IssueNumber,
                    [string]$Branch,
                    [int]$PullRequestNumber = 0,
                    [string]$PrCommentId = $null,
                    [string]$BaseSha,
                    [string]$HeadSha,
                    [string]$Phase,
                    [string]$Provider,
                    [string]$Model,
                    [int]$ReviewAttemptCount = 0,
                    [int]$RepairAttemptCount = 0,
                    [string]$RunId = $null
                )

                $record = [pscustomobject]@{
                    runId = $RunId
                    operation = $Operation
                    status = 'running'
                    repositoryRoot = $RepositoryRoot
                    repository = $Repository
                    repositorySlug = $RepositorySlug
                    issueNumber = $IssueNumber
                    branch = $Branch
                    pullRequestNumber = $PullRequestNumber
                    prCommentId = $PrCommentId
                    baseSha = $BaseSha
                    headSha = $HeadSha
                    currentPhase = $Phase
                    lastSafePhase = $Phase
                    provider = $Provider
                    model = $Model
                    reviewAttemptCount = $ReviewAttemptCount
                    repairAttemptCount = $RepairAttemptCount
                    completedAtUtc = $null
                    terminalOutcome = $null
                    pauseReason = $null
                }
                $script:records[[string]$RunId] = $record
                return $record
            }
            Mock Set-RepoFlowRunCheckpoint {
                param(
                    [string]$ConfigPath,
                    [string]$RunId,
                    [string]$CurrentPhase,
                    [string]$SafePhase = $null
                )

                if ($script:records.ContainsKey([string]$RunId)) {
                    $script:records[[string]$RunId].status = 'running'
                    $script:records[[string]$RunId].currentPhase = $CurrentPhase
                    if (-not [string]::IsNullOrWhiteSpace($SafePhase)) {
                        $script:records[[string]$RunId].lastSafePhase = $SafePhase
                    }
                }
            }
            Mock Complete-RepoFlowRunRecord {
                param($ConfigPath, $RunId, $Outcome)

                if ($script:records.ContainsKey([string]$RunId)) {
                    $script:records[[string]$RunId].status = 'completed'
                    $script:records[[string]$RunId].terminalOutcome = $Outcome
                    $script:records[[string]$RunId].completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
                }
            }
            Mock Set-RepoFlowRunPaused {
                param($ConfigPath, $RunId, $CurrentPhase, $PauseReason)

                if ($script:records.ContainsKey([string]$RunId)) {
                    $script:records[[string]$RunId].status = 'paused'
                    $script:records[[string]$RunId].currentPhase = $CurrentPhase
                    $script:records[[string]$RunId].pauseReason = $PauseReason
                }
            }
            Mock Invoke-RepoFlowPrReviewRepairCycle {
                throw 'Repair must not run for a passing local review.'
            }

            Invoke-RepoFlowPrReviewWorkflow -Number 25 -Apply -Repo repo

            $resultRun = $script:records.Values |
                Where-Object { [string]$_.operation -eq 'automated-review-result' } |
                Select-Object -First 1
            $requestComment = $script:comments |
                Where-Object { [string]$_.marker -eq 'request' } |
                Select-Object -First 1
            $resultComment = $script:comments |
                Where-Object { [string]$_.marker -eq 'result' } |
                Select-Object -First 1

            $requestComment | Should -Not -BeNullOrEmpty
            $resultComment | Should -Not -BeNullOrEmpty
            $resultRun | Should -Not -BeNullOrEmpty
            $resultRun.prCommentId | Should -Be ([string]$resultComment.id)
            Should -Invoke Invoke-RepoFlowLocalReviewerAgent -Times 1 -Exactly
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
