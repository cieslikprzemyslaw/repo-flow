BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow CI state handling' {
    InModuleScope RepoFlow {
        It 'keeps the overall state pending while any check is pending' {
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = @'
[
  { "name": "Validate (push)", "bucket": "fail", "link": "https://example.test/old" },
  { "name": "Validate (pull_request)", "bucket": "pending", "link": "https://example.test/new" }
]
'@
                }
            }

            $state = Get-RepoFlowPrCheckState `
                -PullRequestNumber 116 `
                -Repository 'owner/repository'

            $state.Status | Should -Be 'pending'
        }

        It 'reports failure only after all checks are terminal' {
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = @'
[
  { "name": "Validate (push)", "bucket": "fail", "link": "https://example.test/one" },
  { "name": "Validate (pull_request)", "bucket": "pass", "link": "https://example.test/two" }
]
'@
                }
            }

            $state = Get-RepoFlowPrCheckState `
                -PullRequestNumber 116 `
                -Repository 'owner/repository'

            $state.Status | Should -Be 'failed'
        }

        It 'waits until GitHub reports the expected pull request head' {
            $script:poll = 0

            Mock Get-RepoFlowPullRequest {
                $script:poll++

                if ($script:poll -eq 1) {
                    return [pscustomobject]@{ headRefOid = ('a' * 40) }
                }

                return [pscustomobject]@{ headRefOid = ('b' * 40) }
            }

            Mock Start-Sleep {}

            $pullRequest = Wait-RepoFlowPullRequestHead `
                -PullRequestNumber 116 `
                -Repository 'owner/repository' `
                -ExpectedHeadSha ('b' * 40) `
                -TimeoutSeconds 30 `
                -PollSeconds 1

            $pullRequest.headRefOid | Should -Be ('b' * 40)
            Should -Invoke Get-RepoFlowPullRequest -Times 2
        }
    }
}
