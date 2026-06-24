BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow PR review loop core' {
    InModuleScope RepoFlow {
        It 'uses explicit review and repair limits' {
            $config = [pscustomobject]@{
                ci = [pscustomobject]@{ mode = 'require-passing' }
                reviewFeedback = [pscustomobject]@{
                    maxReviewCycles = 5
                    maxRepairCycles = 4
                }
            }

            $options = Get-RepoFlowPrReviewOptions -Config $config

            $options.RequirePassingCi | Should -BeTrue
            $options.MaxReviewCycles | Should -Be 5
            $options.MaxRepairCycles | Should -Be 4
        }

        It 'uses safe defaults and honours a non-blocking CI mode' {
            $config = [pscustomobject]@{
                ci = [pscustomobject]@{ mode = 'observe' }
                reviewFeedback = [pscustomobject]@{}
            }

            $options = Get-RepoFlowPrReviewOptions -Config $config

            $options.RequirePassingCi | Should -BeFalse
            $options.MaxReviewCycles | Should -Be 3
            $options.MaxRepairCycles | Should -Be 2
        }

        It 'requires passing CI before publishing a review request' {
            $config = [pscustomobject]@{
                ci = [pscustomobject]@{
                    timeoutSeconds = 30
                    pollSeconds = 10
                }
                agent = [pscustomobject]@{}
            }

            Mock Get-RepoFlowPrCheckState {
                [pscustomobject]@{ Status = 'failed'; Checks = @() }
            }

            {
                Resolve-RepoFlowPrReviewCiState `
                    -PullRequestNumber 25 `
                    -Repository 'owner/repo' `
                    -Config $config `
                    -RequirePassingCi $true
            } | Should -Throw '*requires passing CI*'
        }

        It 'does not reuse a completed pass after the PR head changes' {
            $configPath = Join-Path $TestDrive '.repo-flow.json'
            $existing = [pscustomobject]@{
                runId = 'rf-pr-review-v1-owner-repo-pr-25'
                operation = 'pr-review-loop'
                status = 'completed'
                currentPhase = 'review-passed'
                headSha = ('b' * 40)
            }
            $pullRequest = [pscustomobject]@{
                number = 25
                headRefName = 'feature/10-review-loop'
                headRefOid = ('c' * 40)
            }
            $issue = [pscustomobject]@{ number = 10 }
            $config = [pscustomobject]@{
                agent = [pscustomobject]@{
                    provider = 'codex'
                    model = 'gpt-5.5'
                }
            }

            Mock Get-RepoFlowRunRecord { $existing }
            Mock Start-RepoFlowRunRecord {
                [pscustomobject]@{
                    runId = 'rf-pr-review-v1-owner-repo-pr-25'
                    status = 'running'
                    headSha = ('c' * 40)
                }
            }

            $initialised = Initialize-RepoFlowPrReviewLoopRun `
                -ConfigPath $configPath `
                -RepositoryRoot 'C:\repo' `
                -RepositoryName 'repo' `
                -RepositorySlug 'owner/repo' `
                -Issue $issue `
                -PullRequest $pullRequest `
                -Config $config

            $initialised.AlreadyPassed | Should -BeFalse
            Should -Invoke Start-RepoFlowRunRecord -Times 1 -Exactly
        }

        It 'creates the same blocker fingerprint regardless of blocker order' {
            $first = [pscustomobject]@{
                category = 'correctness'
                explanation = 'Fix first issue.'
                path = 'src/a.ps1'
                startLine = 10
            }
            $second = [pscustomobject]@{
                category = 'tests'
                explanation = 'Add regression coverage.'
                path = 'tests/a.Tests.ps1'
                startLine = 20
            }

            $forward = Get-RepoFlowReviewBlockerFingerprint `
                -Blockers @($first, $second)
            $reverse = Get-RepoFlowReviewBlockerFingerprint `
                -Blockers @($second, $first)

            $forward | Should -Be $reverse
            $forward | Should -Match '^[0-9a-f]{64}$'
        }

        It 'writes blockers but excludes warnings from repair context' {
            $path = Join-Path $TestDrive 'review-context.json'
            $result = [pscustomobject]@{
                contractVersion = '1'
                kind = 'review_result'
                requestId = 'request-123'
                reviewedHeadSha = ('a' * 40)
                verdict = 'changes_required'
                blockers = @(
                    [pscustomobject]@{
                        category = 'correctness'
                        explanation = 'Fix the blocker.'
                    }
                )
                warnings = @(
                    [pscustomobject]@{
                        category = 'maintainability'
                        explanation = 'Do unrelated cleanup.'
                    }
                )
                reviewFlags = [pscustomobject]@{
                    testsReviewed = $true
                    scopeReviewed = $true
                    securityReviewed = $true
                }
                reviewerId = 'review-service'
                completedAtUtc = '2026-06-24T14:00:00Z'
            }

            Write-RepoFlowReviewRepairContext `
                -Result $result `
                -HeadSha ('a' * 40) `
                -OutputPath $path |
                Out-Null

            $context = Get-Content -LiteralPath $path -Raw |
                ConvertFrom-Json -Depth 20

            @($context.blockers) | Should -HaveCount 1
            $context.PSObject.Properties.Name | Should -Not -Contain 'warnings'
            ($context | ConvertTo-Json -Depth 20) |
                Should -Not -Match 'Do unrelated cleanup'
        }

        It 'keeps the original issue authoritative in the repair prompt' {
            $issue = [pscustomobject]@{
                number = 10
                title = 'Review loop'
                body = "## Acceptance criteria`n- [ ] Keep scope."
            }
            $pullRequest = [pscustomobject]@{
                number = 25
                url = 'https://example.test/pull/25'
            }
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{ baseBranch = 'main' }
                agent = [pscustomobject]@{ runProjectChecks = $false }
            }

            $prompt = New-RepoFlowReviewRepairPrompt `
                -Issue $issue `
                -PullRequest $pullRequest `
                -HeadSha ('a' * 40) `
                -ContextPath 'C:\temp\blockers.json' `
                -ChangedFiles @('src/a.ps1') `
                -Config $config `
                -RepairAttempt 1 `
                -RepairAttemptLimit 2

            $prompt | Should -Match 'Original issue scope'
            $prompt | Should -Match 'untrusted task data'
            $prompt | Should -Match 'Warnings are deliberately excluded'
            $prompt | Should -Match 'Never merge|Do not commit, push, merge'
        }
    }
}
