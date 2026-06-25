BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    $env:REPO_FLOW_REVIEW_BRIDGE_FIXTURE_DIRECTORY = Join-Path $PSScriptRoot 'fixtures/review'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow local automated review bridge' {
    InModuleScope RepoFlow {
        BeforeAll {
            $script:fixtureDirectory = $env:REPO_FLOW_REVIEW_BRIDGE_FIXTURE_DIRECTORY

            function New-TestLocalReviewResult {
                param(
                    [string]$Verdict = 'pass',
                    [string]$HeadSha = $script:request.headSha,
                    [string]$RequestId = $script:request.requestId,
                    [string]$ReviewerId = $script:reviewerId
                )

                $blockers = if ($Verdict -eq 'changes_required') {
                    @([pscustomobject]@{
                        category = 'correctness'
                        explanation = 'The checkpoint is not persisted.'
                        path = 'scripts/RepoFlow/Private/example.ps1'
                        startLine = 10
                        endLine = 12
                    })
                }
                else { @() }

                return [pscustomobject][ordered]@{
                    contractVersion = '1'
                    kind = 'review_result'
                    requestId = $RequestId
                    reviewedHeadSha = $HeadSha
                    verdict = $Verdict
                    blockers = @($blockers)
                    warnings = @()
                    reviewFlags = [pscustomobject]@{
                        testsReviewed = $true
                        scopeReviewed = $true
                        securityReviewed = $true
                    }
                    reviewerId = $ReviewerId
                    completedAtUtc = '2026-06-24T09:35:00.0000000+00:00'
                }
            }
        }

        BeforeEach {
            $script:request = Get-Content -LiteralPath (
                Join-Path $script:fixtureDirectory 'valid-request.json'
            ) -Raw | ConvertFrom-Json -Depth 30
            $script:reviewer = [pscustomobject]@{
                mode = 'local'
                provider = 'codex'
                command = 'codex'
                model = 'gpt-5.5'
                reasoningEffort = 'high'
                heartbeatSeconds = 15
                noActivityWarningSeconds = 180
                timeoutSeconds = 900
            }
            $script:reviewerId = Get-RepoFlowLocalReviewerId -Reviewer $script:reviewer
            $script:issue = [pscustomobject]@{
                number = 8
                title = 'Add review contract'
                body = "## Acceptance criteria`n`n- Preserve exact-head review."
            }
            $script:pullRequest = [pscustomobject]@{
                number = 21
                title = 'Add review contract'
                body = 'Implements the versioned review contract.'
                state = 'OPEN'
                baseRefOid = [string]$script:request.baseSha
                headRefOid = [string]$script:request.headSha
                headRefName = 'feature/8-review-contract'
            }
            $script:config = [pscustomobject]@{
                reviewer = $script:reviewer
                ci = [pscustomobject]@{
                    pollSeconds = 10
                    timeoutSeconds = 30
                }
                reviewFeedback = [pscustomobject]@{
                    enabled = $true
                    trustedAssociations = @('OWNER')
                }
            }
            $script:context = [pscustomobject]@{
                RepositoryRoot = 'C:\repo'
                Config = $script:config
                RepositorySelection = [pscustomobject]@{
                    Repository = [pscustomobject]@{ name = 'flow' }
                }
            }
        }


        It 'builds read-only provider arguments for isolated reviewers' {
            $codex = New-RepoFlowCodexArguments `
                -RepositoryRoot 'C:\repo' `
                -FinalMessagePath 'C:\temp\result.json' `
                -Model 'gpt-5.5' `
                -ReasoningEffort high `
                -SandboxMode read-only
            $claude = New-RepoFlowClaudeArguments `
                -Model 'claude-sonnet-4-6' `
                -ReasoningEffort high `
                -PermissionMode plan

            $codex | Should -Contain 'read-only'
            $codex | Should -Not -Contain 'workspace-write'
            $claude | Should -Contain 'plan'
            $claude | Should -Not -Contain 'acceptEdits'
        }

        It 'accepts pass changes-required and manual-review result envelopes' -ForEach @(
            @{ Verdict = 'pass' }
            @{ Verdict = 'changes_required' }
            @{ Verdict = 'manual_review' }
        ) {
            $json = New-TestLocalReviewResult -Verdict $Verdict |
                ConvertTo-Json -Depth 20

            $parsed = ConvertFrom-RepoFlowLocalReviewerOutput `
                -Text $json `
                -Request $script:request `
                -CurrentHeadSha ([string]$script:request.headSha) `
                -ExpectedReviewerId $script:reviewerId

            $parsed.verdict | Should -Be $Verdict
        }

        It 'accepts one complete fenced JSON result and rejects extra prose' {
            $json = New-TestLocalReviewResult | ConvertTo-Json -Depth 20
            $fenced = '```json' + "`n" + $json + "`n" + '```'

            {
                ConvertFrom-RepoFlowLocalReviewerOutput `
                    -Text $fenced `
                    -Request $script:request `
                    -CurrentHeadSha ([string]$script:request.headSha) `
                    -ExpectedReviewerId $script:reviewerId
            } | Should -Not -Throw

            {
                ConvertFrom-RepoFlowLocalReviewerOutput `
                    -Text "review complete`n$json" `
                    -Request $script:request `
                    -CurrentHeadSha ([string]$script:request.headSha) `
                    -ExpectedReviewerId $script:reviewerId
            } | Should -Throw
        }

        It 'rejects malformed mismatched and stale reviewer output' {
            {
                ConvertFrom-RepoFlowLocalReviewerOutput `
                    -Text '{bad json' `
                    -Request $script:request `
                    -CurrentHeadSha ([string]$script:request.headSha) `
                    -ExpectedReviewerId $script:reviewerId
            } | Should -Throw '*valid JSON*'

            $wrongRequest = New-TestLocalReviewResult -RequestId 'different-request' |
                ConvertTo-Json -Depth 20
            {
                ConvertFrom-RepoFlowLocalReviewerOutput `
                    -Text $wrongRequest `
                    -Request $script:request `
                    -CurrentHeadSha ([string]$script:request.headSha) `
                    -ExpectedReviewerId $script:reviewerId
            } | Should -Throw '*request ID*'

            $stale = New-TestLocalReviewResult -HeadSha ('3' * 40) |
                ConvertTo-Json -Depth 20
            {
                ConvertFrom-RepoFlowLocalReviewerOutput `
                    -Text $stale `
                    -Request $script:request `
                    -CurrentHeadSha ([string]$script:request.headSha) `
                    -ExpectedReviewerId $script:reviewerId
            } | Should -Throw '*head SHA*'
        }

        It 'restarts an interrupted persisted bridge run without creating a second record' {
            Mock Get-RepoFlowRunRecord {
                [pscustomobject]@{
                    operation = 'automated-review-local-bridge'
                    status = 'paused'
                    pullRequestNumber = 21
                    baseSha = [string]$script:request.baseSha
                    headSha = [string]$script:request.headSha
                }
            }
            Mock Start-RepoFlowRunRecord {}
            Mock Set-RepoFlowRunCheckpoint {}

            $runId = Initialize-RepoFlowLocalReviewBridgeRun `
                -ConfigPath 'C:\repo\.repo-flow.json' `
                -Context $script:context `
                -Issue $script:issue `
                -PullRequest $script:pullRequest `
                -Request $script:request `
                -Reviewer $script:reviewer

            $runId | Should -Be 'review-request-0001.bridge'
            Should -Invoke Start-RepoFlowRunRecord -Times 0
            Should -Invoke Set-RepoFlowRunCheckpoint -Times 1
        }

        It 'does not read persisted bridge state when no state file exists' {
            Mock Get-RepoFlowRunRecord {}
            Mock Set-RepoFlowRunCheckpoint {}
            Mock Complete-RepoFlowRunRecord {}

            {
                Complete-RepoFlowLocalReviewBridgeIfPresent `
                    -ConfigPath (Join-Path $TestDrive 'missing/.repo-flow.json') `
                    -RequestId ([string]$script:request.requestId)
            } | Should -Not -Throw

            Should -Invoke Get-RepoFlowRunRecord -Times 0
            Should -Invoke Set-RepoFlowRunCheckpoint -Times 0
            Should -Invoke Complete-RepoFlowRunRecord -Times 0
        }

        It 'ignores an unreachable config drive when checking for persisted bridge state' {
            Mock Get-RepoFlowRunRecord {}
            Mock Set-RepoFlowRunCheckpoint {}
            Mock Complete-RepoFlowRunRecord {}

            {
                Complete-RepoFlowLocalReviewBridgeIfPresent `
                    -ConfigPath 'C:\repo\.repo-flow.json' `
                    -RequestId ([string]$script:request.requestId)
            } | Should -Not -Throw

            Should -Invoke Get-RepoFlowRunRecord -Times 0
            Should -Invoke Set-RepoFlowRunCheckpoint -Times 0
            Should -Invoke Complete-RepoFlowRunRecord -Times 0
        }

        It 'publishes one matching result and returns an accepted transport resolution' {
            $script:publishedComment = $null
            $resultJson = New-TestLocalReviewResult | ConvertTo-Json -Depth 20

            Mock Enter-RepoFlowLocalReviewBridgeLock { [pscustomobject]@{ Path = 'lock'; Stream = $null } }
            Mock Exit-RepoFlowLocalReviewBridgeLock {}
            Mock Assert-RepoFlowLocalReviewScope {}
            Mock Initialize-RepoFlowLocalReviewBridgeRun { 'review-request-0001.bridge' }
            Mock Get-RepoFlowLocalGitHeadSha { [string]$script:request.headSha }
            Mock Get-RepoFlowWorkingTreeStatus { '' }
            Mock Set-RepoFlowRunCheckpoint {}
            Mock Complete-RepoFlowRunRecord {}
            Mock Set-RepoFlowLocalReviewBridgePaused {}
            Mock Invoke-RepoFlowLocalReviewerAgent {
                [pscustomobject]@{
                    ExitCode = 0
                    TimedOut = $false
                    Text = ''
                    FinalMessage = $resultJson
                }
            }
            Mock Get-RepoFlowPullRequest { $script:pullRequest }
            Mock Get-RepoFlowAllPullRequestComments {
                if ($null -eq $script:publishedComment) { return @() }
                return @($script:publishedComment)
            }
            Mock New-RepoFlowPullRequestComment {
                param($PullRequestNumber, $Repository, $Body)
                $script:publishedComment = [pscustomobject]@{
                    id = 501
                    body = $Body
                    created_at = '2026-06-24T09:36:00Z'
                    author_association = 'OWNER'
                    user = [pscustomobject]@{
                        login = 'cieslikprzemyslaw'
                        type = 'User'
                    }
                }
                return $script:publishedComment
            }

            $resolution = Invoke-RepoFlowLocalReviewBridge `
                -Request $script:request `
                -Issue $script:issue `
                -PullRequest $script:pullRequest `
                -Context $script:context `
                -StateConfigPath 'C:\repo\.repo-flow.json'

            $resolution.Status | Should -Be accepted
            $resolution.Comment.id | Should -Be 501
            $resolution.Result.verdict | Should -Be pass
            Should -Invoke Invoke-RepoFlowLocalReviewerAgent -Times 1
            Should -Invoke New-RepoFlowPullRequestComment -Times 1
        }

        It 'does not invoke or publish when a matching result already exists' {
            Mock Get-RepoFlowAllPullRequestComments { @([pscustomobject]@{ id = 88 }) }
            Mock Resolve-RepoFlowAutomatedReviewResultComment {
                [pscustomobject]@{
                    Status = 'accepted'
                    Comment = [pscustomobject]@{ id = 88 }
                    Result = New-TestLocalReviewResult
                }
            }
            Mock Invoke-RepoFlowLocalReviewerAgent {}
            Mock New-RepoFlowPullRequestComment {}

            Invoke-RepoFlowLocalReviewBridge `
                -Request $script:request `
                -Issue $script:issue `
                -PullRequest $script:pullRequest `
                -Context $script:context `
                -StateConfigPath 'C:\repo\.repo-flow.json' |
                Out-Null

            Should -Invoke Invoke-RepoFlowLocalReviewerAgent -Times 0
            Should -Invoke New-RepoFlowPullRequestComment -Times 0
        }

        It 'reconciles a duplicate concurrent execution by waiting for the active reviewer' {
            Mock Get-RepoFlowAllPullRequestComments { @() }
            Mock Resolve-RepoFlowAutomatedReviewResultComment {
                [pscustomobject]@{ Status = 'none'; Comment = $null; Result = $null }
            }
            Mock Enter-RepoFlowLocalReviewBridgeLock { $null }
            Mock Invoke-RepoFlowLocalReviewerAgent {}
            Mock New-RepoFlowPullRequestComment {}
            Mock Set-RepoFlowRunPaused {}
            Mock Set-RepoFlowLocalReviewBridgePaused {}

            Invoke-RepoFlowLocalReviewBridge `
                -Request $script:request `
                -Issue $script:issue `
                -PullRequest $script:pullRequest `
                -Context $script:context `
                -StateConfigPath 'C:\repo\.repo-flow.json' |
                Should -BeNullOrEmpty

            Should -Invoke Invoke-RepoFlowLocalReviewerAgent -Times 0
            Should -Invoke New-RepoFlowPullRequestComment -Times 0
            Should -Invoke Set-RepoFlowRunPaused -Times 0
            Should -Invoke Set-RepoFlowLocalReviewBridgePaused -Times 0
        }

        It 'pauses safely on timeout unavailable reviewer stale head process and publish failure' -ForEach @(
            @{ Case = 'timeout' }
            @{ Case = 'unavailable' }
            @{ Case = 'stale' }
            @{ Case = 'process' }
            @{ Case = 'publish' }
        ) {
            $script:caseName = $Case
            $script:pauseReason = ''
            $resultJson = New-TestLocalReviewResult | ConvertTo-Json -Depth 20
            Mock Get-RepoFlowAllPullRequestComments { @() }
            Mock Resolve-RepoFlowAutomatedReviewResultComment {
                [pscustomobject]@{ Status = 'none'; Comment = $null; Result = $null }
            }
            Mock Enter-RepoFlowLocalReviewBridgeLock { [pscustomobject]@{ Path = 'lock'; Stream = $null } }
            Mock Exit-RepoFlowLocalReviewBridgeLock {}
            Mock Assert-RepoFlowLocalReviewScope {}
            Mock Initialize-RepoFlowLocalReviewBridgeRun { 'review-request-0001.bridge' }
            Mock Get-RepoFlowLocalGitHeadSha { [string]$script:request.headSha }
            Mock Get-RepoFlowWorkingTreeStatus { '' }
            Mock Set-RepoFlowRunCheckpoint {}
            Mock Complete-RepoFlowRunRecord {}
            Mock Set-RepoFlowLocalReviewBridgePaused {
                param($ConfigPath, $RequestId, $RunId, $Reason)
                $script:pauseReason = $Reason
            }
            Mock Get-RepoFlowPullRequest {
                if ($script:caseName -eq 'stale') {
                    return [pscustomobject]@{
                        number = 21
                        state = 'OPEN'
                        baseRefOid = [string]$script:request.baseSha
                        headRefOid = ('4' * 40)
                        headRefName = 'feature/8-review-contract'
                    }
                }
                return $script:pullRequest
            }
            Mock Invoke-RepoFlowLocalReviewerAgent {
                if ($script:caseName -eq 'unavailable') {
                    throw 'Required agent command not found: codex'
                }
                [pscustomobject]@{
                    ExitCode = if ($script:caseName -eq 'process') { 7 } else { 0 }
                    TimedOut = ($script:caseName -eq 'timeout')
                    Text = 'SENSITIVE FULL PROCESS OUTPUT'
                    FinalMessage = $resultJson
                }
            }
            Mock New-RepoFlowPullRequestComment {
                if ($script:caseName -eq 'publish') { throw 'GitHub publish failed' }
                [pscustomobject]@{ id = 502 }
            }

            {
                Invoke-RepoFlowLocalReviewBridge `
                    -Request $script:request `
                    -Issue $script:issue `
                    -PullRequest $script:pullRequest `
                    -Context $script:context `
                    -StateConfigPath 'C:\repo\.repo-flow.json'
            } | Should -Throw

            Should -Invoke Set-RepoFlowLocalReviewBridgePaused -Times 1
            if ($script:caseName -eq 'process') {
                $script:pauseReason | Should -Not -Match 'SENSITIVE FULL PROCESS OUTPUT'
                $script:pauseReason | Should -Match 'code 7'
            }
        }
    }

    AfterAll {
        Remove-Item Env:REPO_FLOW_REVIEW_BRIDGE_FIXTURE_DIRECTORY -ErrorAction SilentlyContinue
    }
}
