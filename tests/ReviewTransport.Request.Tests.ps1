BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow automated review request transport' {
    BeforeAll {
        $env:REPO_FLOW_REVIEW_FIXTURE_DIRECTORY = Join-Path $PSScriptRoot 'fixtures/review'
    }

    AfterAll {
        Remove-Item Env:REPO_FLOW_REVIEW_FIXTURE_DIRECTORY -ErrorAction SilentlyContinue
    }

    InModuleScope RepoFlow {
        BeforeEach {
            $script:request = Get-Content -LiteralPath (
                Join-Path $env:REPO_FLOW_REVIEW_FIXTURE_DIRECTORY 'valid-request.json'
            ) -Raw | ConvertFrom-Json -Depth 30
            $script:result = Get-Content -LiteralPath (
                Join-Path $env:REPO_FLOW_REVIEW_FIXTURE_DIRECTORY 'valid-pass-result.json'
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

        It 'creates a deterministic request ID for one exact base and head' {
            $first = Get-RepoFlowAutomatedReviewRequestId `
                -PullRequestNumber 24 `
                -BaseSha ('a' * 40) `
                -HeadSha ('b' * 40)
            $same = Get-RepoFlowAutomatedReviewRequestId `
                -PullRequestNumber 24 `
                -BaseSha ('A' * 40) `
                -HeadSha ('B' * 40)
            $changedHead = Get-RepoFlowAutomatedReviewRequestId `
                -PullRequestNumber 24 `
                -BaseSha ('a' * 40) `
                -HeadSha ('c' * 40)
            $changedBase = Get-RepoFlowAutomatedReviewRequestId `
                -PullRequestNumber 24 `
                -BaseSha ('d' * 40) `
                -HeadSha ('b' * 40)

            $first | Should -Be $same
            $changedHead | Should -Not -Be $first
            $changedBase | Should -Not -Be $first
        }

        It 'builds a schema-valid request from live PR context' {
            $issue = [pscustomobject]@{
                number = 9
                url = 'https://github.com/owner/repo/issues/9'
                body = @(
                    '## Acceptance criteria'
                    ''
                    '- [ ] Publish one request per head.'
                    '- [ ] Ignore stale results.'
                ) -join "`n"
            }
            $pullRequest = [pscustomobject]@{
                number = 24
                url = 'https://github.com/owner/repo/pull/24'
                baseRefOid = ('a' * 40)
                headRefOid = ('b' * 40)
            }
            $checks = [pscustomobject]@{
                Status = 'passed'
                Checks = @(
                    [pscustomobject]@{
                        name = 'Validate'
                        bucket = 'pass'
                    }
                )
            }

            $request = New-RepoFlowAutomatedReviewRequestEnvelope `
                -Issue $issue `
                -PullRequest $pullRequest `
                -Repository 'owner/repo' `
                -ChangedFiles @(
                    [pscustomobject]@{
                        filename = 'scripts/review.ps1'
                        status = 'added'
                    }
                ) `
                -CheckState $checks `
                -CreatedAtUtc '2026-06-24T10:00:00Z'

            $request.kind | Should -Be 'review_request'
            $request.headSha | Should -Be ('b' * 40)
            @($request.acceptanceCriteria) | Should -HaveCount 2
            $request.ciSummary.status | Should -Be 'passing'
            { Assert-RepoFlowReviewRequestEnvelope -Request $request } |
                Should -Not -Throw
        }

        It 'trusts a configured repository association' {
            $comment = [pscustomobject]@{
                author_association = 'COLLABORATOR'
                user = [pscustomobject]@{
                    login = 'review-service'
                    type = 'User'
                }
            }

            Test-RepoFlowAutomatedReviewTrustedComment `
                -Comment $comment `
                -Config $script:config |
                Should -BeTrue
        }

        It 'rejects bot comments even when the association is trusted' {
            $comment = [pscustomobject]@{
                author_association = 'OWNER'
                user = [pscustomobject]@{
                    login = 'unknown[bot]'
                    type = 'Bot'
                }
            }

            Test-RepoFlowAutomatedReviewTrustedComment `
                -Comment $comment `
                -Config $script:config |
                Should -BeFalse
        }

        It 'reuses the authenticated users existing request for the same head' {
            $body = ConvertTo-RepoFlowReviewComment -Envelope $script:request
            $comment = [pscustomobject]@{
                id = 101
                body = $body
                user = [pscustomobject]@{
                    login = 'cieslikprzemyslaw'
                    type = 'User'
                }
            }

            $selected = Find-RepoFlowAutomatedReviewRequestComment `
                -Comments @($comment) `
                -AuthenticatedLogin 'cieslikprzemyslaw' `
                -RequestId ([string]$script:request.requestId) `
                -Repository ([string]$script:request.repository) `
                -IssueNumber ([int]$script:request.issue.number) `
                -PullRequestNumber ([int]$script:request.pullRequest.number) `
                -BaseSha ([string]$script:request.baseSha) `
                -HeadSha ([string]$script:request.headSha)

            $selected.Comment.id | Should -Be 101
            $selected.Envelope.requestId | Should -Be $script:request.requestId
        }

        It 'accepts an empty request comment collection' {
            $selected = Find-RepoFlowAutomatedReviewRequestComment `
                -Comments @() `
                -AuthenticatedLogin 'cieslikprzemyslaw' `
                -RequestId ([string]$script:request.requestId) `
                -Repository ([string]$script:request.repository) `
                -IssueNumber ([int]$script:request.issue.number) `
                -PullRequestNumber ([int]$script:request.pullRequest.number) `
                -BaseSha ([string]$script:request.baseSha) `
                -HeadSha ([string]$script:request.headSha)

            $selected | Should -BeNullOrEmpty
        }

        It 'does not reuse a request bound to a different issue or base SHA' {
            $body = ConvertTo-RepoFlowReviewComment -Envelope $script:request
            $comment = [pscustomobject]@{
                id = 102
                body = $body
                user = [pscustomobject]@{
                    login = 'cieslikprzemyslaw'
                    type = 'User'
                }
            }

            $wrongIssue = Find-RepoFlowAutomatedReviewRequestComment `
                -Comments @($comment) `
                -AuthenticatedLogin 'cieslikprzemyslaw' `
                -RequestId ([string]$script:request.requestId) `
                -Repository ([string]$script:request.repository) `
                -IssueNumber 999 `
                -PullRequestNumber ([int]$script:request.pullRequest.number) `
                -BaseSha ([string]$script:request.baseSha) `
                -HeadSha ([string]$script:request.headSha)

            $wrongBase = Find-RepoFlowAutomatedReviewRequestComment `
                -Comments @($comment) `
                -AuthenticatedLogin 'cieslikprzemyslaw' `
                -RequestId ([string]$script:request.requestId) `
                -Repository ([string]$script:request.repository) `
                -IssueNumber ([int]$script:request.issue.number) `
                -PullRequestNumber ([int]$script:request.pullRequest.number) `
                -BaseSha ('f' * 40) `
                -HeadSha ([string]$script:request.headSha)

            $wrongIssue | Should -BeNullOrEmpty
            $wrongBase | Should -BeNullOrEmpty
        }

    }
}
