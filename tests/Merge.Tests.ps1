BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow pull request merge workflow' {
    InModuleScope RepoFlow {
        BeforeEach {
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{
                    slug = 'owner/repository'
                    baseBranch = 'master'
                }
                git = [pscustomobject]@{
                    requireCleanWorkingTree = $true
                }
                pullRequest = [pscustomobject]@{
                    mergeMethod = 'squash'
                    deleteBranchOnMerge = $true
                }
                ci = [pscustomobject]@{
                    mode = 'require-passing'
                    timeoutSeconds = 30
                    pollSeconds = 10
                }
            }

            $openPr = [pscustomobject]@{
                number = 116
                title = 'Example PR'
                state = 'OPEN'
                isDraft = $true
                baseRefName = 'master'
                headRefName = 'feature/116-example'
                url = 'https://example.test/pr/116'
            }

            $mergedPr = [pscustomobject]@{
                number = 116
                title = 'Example PR'
                state = 'MERGED'
                isDraft = $false
                baseRefName = 'master'
                headRefName = 'feature/116-example'
                url = 'https://example.test/pr/116'
            }

            Mock New-RepoFlowContext {
                [pscustomobject]@{
                    RepositoryRoot = 'C:\repo'
                    Config = $config
                }
            }
            Mock Get-RepoFlowEffectiveCiMode { 'require-passing' }
            Mock Assert-RepoFlowCleanWorkingTree {}
            Mock Wait-RepoFlowPrChecks {
                [pscustomobject]@{ Status = 'passed'; Checks = @() }
            }
            Mock Show-RepoFlowPullRequestStatus {}
            Mock Confirm-RepoFlowManualReview { $true }
            Mock Set-RepoFlowPullRequestReady {}
            Mock Merge-RepoFlowPullRequest {}
            Mock Complete-RepoFlowPostMergeCleanup {}
        }

        It 'requires explicit manual-review confirmation before mutation' {
            $script:readCount = 0
            Mock Get-RepoFlowPullRequest {
                $script:readCount++
                if ($script:readCount -eq 1) { return $openPr }
                return $mergedPr
            }

            Invoke-RepoFlowPrMergeWorkflow -Number 116 -Apply

            Should -Invoke Confirm-RepoFlowManualReview -Times 1 -Exactly -ParameterFilter {
                $PullRequestNumber -eq 116
            }
            Should -Invoke Set-RepoFlowPullRequestReady -Times 1 -Exactly
            Should -Invoke Merge-RepoFlowPullRequest -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'squash'
            }
            Should -Invoke Complete-RepoFlowPostMergeCleanup -Times 1 -Exactly
        }

        It 'does not mutate when manual review is not confirmed' {
            Mock Get-RepoFlowPullRequest { $openPr }
            Mock Confirm-RepoFlowManualReview { $false }

            Invoke-RepoFlowPrMergeWorkflow -Number 116 -Apply

            Should -Invoke Confirm-RepoFlowManualReview -Times 1 -Exactly
            Should -Invoke Set-RepoFlowPullRequestReady -Times 0 -Exactly
            Should -Invoke Merge-RepoFlowPullRequest -Times 0 -Exactly
            Should -Invoke Complete-RepoFlowPostMergeCleanup -Times 0 -Exactly
        }

        It 'does not mutate in plan mode' {
            Mock Get-RepoFlowPullRequest { $openPr }

            Invoke-RepoFlowPrMergeWorkflow -Number 116

            Should -Invoke Confirm-RepoFlowManualReview -Times 0 -Exactly
            Should -Invoke Merge-RepoFlowPullRequest -Times 0 -Exactly
            Should -Invoke Set-RepoFlowPullRequestReady -Times 0 -Exactly
        }
    }
}
