BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    $global:RepoFlowReviewResultFixtureDirectory = Join-Path $PSScriptRoot 'fixtures/review'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow automated review result transport' {

    AfterAll {
        Remove-Variable -Name RepoFlowReviewResultFixtureDirectory -Scope Global -ErrorAction SilentlyContinue
    }

    InModuleScope RepoFlow {
        BeforeEach {
            $script:request = Get-Content -LiteralPath (
                Join-Path $global:RepoFlowReviewResultFixtureDirectory 'valid-request.json'
            ) -Raw | ConvertFrom-Json -Depth 30
            $script:result = Get-Content -LiteralPath (
                Join-Path $global:RepoFlowReviewResultFixtureDirectory 'valid-pass-result.json'
            ) -Raw | ConvertFrom-Json -Depth 30
            $script:config = [pscustomobject]@{
                ci = [pscustomobject]@{
                    pollSeconds = 10
                    timeoutSeconds = 30
                }
                reviewFeedback = [pscustomobject]@{
                    enabled = $true
                    trustedAssociations = @('OWNER', 'MEMBER', 'COLLABORATOR')
                }
            }
        }

        It 'ignores untrusted and mismatched results and accepts the matching trusted result' {
            $validBody = ConvertTo-RepoFlowReviewComment -Envelope $script:result
            $mismatched = $script:result.PSObject.Copy()
            $mismatched.requestId = 'different-request-0002'
            $mismatchedBody = ConvertTo-RepoFlowReviewComment -Envelope $mismatched
            $comments = @(
                [pscustomobject]@{
                    id = 10
                    created_at = '2026-06-24T09:36:00Z'
                    body = $validBody
                    author_association = 'NONE'
                    user = [pscustomobject]@{ login = 'outsider'; type = 'User' }
                }
                [pscustomobject]@{
                    id = 11
                    created_at = '2026-06-24T09:36:10Z'
                    body = $mismatchedBody
                    author_association = 'COLLABORATOR'
                    user = [pscustomobject]@{
                        login = 'review-service'; type = 'User'
                    }
                }
                [pscustomobject]@{
                    id = 12
                    created_at = '2026-06-24T09:36:20Z'
                    body = $validBody
                    author_association = 'COLLABORATOR'
                    user = [pscustomobject]@{
                        login = 'review-service'; type = 'User'
                    }
                }
            )

            $resolved = Resolve-RepoFlowAutomatedReviewResultComment `
                -Request $script:request `
                -Comments $comments `
                -CurrentHeadSha ([string]$script:request.headSha) `
                -Config $script:config

            $resolved.Status | Should -Be 'accepted'
            $resolved.Comment.id | Should -Be 12
        }

        It 'accepts GitHub comment timestamps materialized as DateTime values' {
            $body = ConvertTo-RepoFlowReviewComment `
                -Envelope $script:result
            $createdAt = [datetime]::SpecifyKind(
                [datetime]'2026-06-24T09:36:20',
                [System.DateTimeKind]::Utc
            )
            $comment = [pscustomobject]@{
                id = 13
                created_at = $createdAt
                body = $body
                author_association = 'OWNER'
                user = [pscustomobject]@{
                    login = 'repository-owner'
                    type = 'User'
                }
            }

            $resolved = Resolve-RepoFlowAutomatedReviewResultComment `
                -Request $script:request `
                -Comments @($comment) `
                -CurrentHeadSha ([string]$script:request.headSha) `
                -Config $script:config

            $resolved.Status | Should -Be 'accepted'
            $resolved.Comment.id | Should -Be 13
        }
        It 'ignores stale results for an earlier head' {
            $stale = $script:result.PSObject.Copy()
            $stale.reviewedHeadSha = '3333333333333333333333333333333333333333'
            $comment = [pscustomobject]@{
                id = 20
                created_at = '2026-06-24T09:36:00Z'
                body = ConvertTo-RepoFlowReviewComment -Envelope $stale
                author_association = 'COLLABORATOR'
                user = [pscustomobject]@{
                    login = 'review-service'; type = 'User'
                }
            }

            $resolved = Resolve-RepoFlowAutomatedReviewResultComment `
                -Request $script:request `
                -Comments @($comment) `
                -CurrentHeadSha ([string]$script:request.headSha) `
                -Config $script:config

            $resolved.Status | Should -Be 'none'
        }

        It 'uses the first matching result and ignores later duplicates' {
            $body = ConvertTo-RepoFlowReviewComment -Envelope $script:result
            $comments = @(
                [pscustomobject]@{
                    id = 30; created_at = '2026-06-24T09:36:00Z'; body = $body
                    author_association = 'COLLABORATOR'
                    user = [pscustomobject]@{
                        login = 'review-service'; type = 'User'
                    }
                }
                [pscustomobject]@{
                    id = 31; created_at = '2026-06-24T09:36:01Z'; body = $body
                    author_association = 'COLLABORATOR'
                    user = [pscustomobject]@{
                        login = 'review-service'; type = 'User'
                    }
                }
            )

            $resolved = Resolve-RepoFlowAutomatedReviewResultComment `
                -Request $script:request `
                -Comments $comments `
                -CurrentHeadSha ([string]$script:request.headSha) `
                -Config $script:config

            $resolved.Status | Should -Be 'accepted'
            $resolved.Comment.id | Should -Be 30
        }

        It 'returns none for an empty result comment collection' {
            $resolved = Resolve-RepoFlowAutomatedReviewResultComment `
                -Request $script:request `
                -Comments @() `
                -CurrentHeadSha ([string]$script:request.headSha) `
                -Config $script:config

            $resolved.Status | Should -Be 'none'
            $resolved.Comment | Should -BeNullOrEmpty
            $resolved.Result | Should -BeNullOrEmpty
        }

        It 'pauses safely when only a trusted malformed marked result exists' {
            $comment = [pscustomobject]@{
                id = 40
                created_at = '2026-06-24T09:36:00Z'
                body = @(
                    '<!-- rf-review-result:v1 -->'
                    '```json'
                    '{broken'
                    '```'
                ) -join "`n"
                author_association = 'COLLABORATOR'
                user = [pscustomobject]@{
                    login = 'review-service'; type = 'User'
                }
            }

            $resolved = Resolve-RepoFlowAutomatedReviewResultComment `
                -Request $script:request `
                -Comments @($comment) `
                -CurrentHeadSha ([string]$script:request.headSha) `
                -Config $script:config

            $resolved.Status | Should -Be 'malformed'
        }

        It 'times out deterministically without invoking an agent or merge' {
            Mock Get-RepoFlowPullRequest {
                [pscustomobject]@{
                    state = 'OPEN'
                    baseRefOid = $script:request.baseSha
                    headRefOid = $script:request.headSha
                }
            }
            Mock Get-RepoFlowAllPullRequestComments { @() }
            Mock Invoke-RepoFlowAgent { throw 'Agent must not run.' }
            Mock Merge-RepoFlowPullRequest { throw 'Merge must not run.' }

            $resolved = Wait-RepoFlowAutomatedReviewResult `
                -Request $script:request `
                -Repository 'cieslikprzemyslaw/repo-flow' `
                -Config $script:config `
                -MaximumPolls 1

            $resolved.Status | Should -Be 'timeout'
            Should -Invoke Invoke-RepoFlowAgent -Times 0 -Exactly
            Should -Invoke Merge-RepoFlowPullRequest -Times 0 -Exactly
        }

        It 'persists request and result comment identifiers as review run records' {
            $repositoryRoot = Join-Path $TestDrive 'repository'
            $configPath = Join-Path $TestDrive '.repo-flow.json'
            New-Item -ItemType Directory -Path $repositoryRoot -Force |
                Out-Null

            $issue = [pscustomobject]@{ number = 9 }
            $pullRequest = [pscustomobject]@{
                number = 24
                headRefName = 'feature/9-review'
                baseRefOid = ('a' * 40)
                headRefOid = ('b' * 40)
            }
            $requestId = Get-RepoFlowAutomatedReviewRequestId `
                -PullRequestNumber 24 `
                -BaseSha ([string]$pullRequest.baseRefOid) `
                -HeadSha ([string]$pullRequest.headRefOid)

            Start-RepoFlowAutomatedReviewRunRecord `
                -ConfigPath $configPath `
                -RepositoryRoot $repositoryRoot `
                -RepositoryName 'repo-flow' `
                -RepositorySlug 'owner/repo-flow' `
                -Issue $issue `
                -PullRequest $pullRequest `
                -RequestId $requestId `
                -RequestCommentId 1001 |
                Out-Null

            $persistedResult = $script:result.PSObject.Copy()
            $persistedResult.requestId = $requestId
            $persistedResult.reviewedHeadSha = [string]$pullRequest.headRefOid
            $persistedResult.completedAtUtc = '2026-06-24T10:30:00Z'

            Save-RepoFlowAutomatedReviewResult `
                -ConfigPath $configPath `
                -RepositoryRoot $repositoryRoot `
                -RepositoryName 'repo-flow' `
                -RepositorySlug 'owner/repo-flow' `
                -Issue $issue `
                -PullRequest $pullRequest `
                -RequestId $requestId `
                -ResultCommentId 1002 `
                -Result $persistedResult

            $requestRun = Get-RepoFlowRunRecord `
                -ConfigPath $configPath `
                -RunId $requestId
            $resultRun = Get-RepoFlowAutomatedReviewResultRunRecord `
                -ConfigPath $configPath `
                -RequestId $requestId

            $requestRun.prCommentId | Should -Be '1001'
            $requestRun.status | Should -Be 'completed'
            $resultRun.prCommentId | Should -Be '1002'
            $resultRun.currentPhase | Should -Be 'review-result-pass'
        }
    }
}
