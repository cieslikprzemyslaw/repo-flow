BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow command dispatcher' {
    InModuleScope RepoFlow {
        It 'routes issue run commands' {
            Mock Invoke-RepoFlowIssueRunWorkflow { return }
            Invoke-RepoFlow -Area issue -Action run -Number 66
            Should -Invoke Invoke-RepoFlowIssueRunWorkflow -Times 1 -Exactly
        }

        It 'requires a PR comment source for issue continue' {
            {
                Invoke-RepoFlow -Area issue -Action continue -Number 66
            } | Should -Throw '*requires -LastPrComment or -PrCommentId*'
        }

        It 'routes pr merge commands' {
            Mock Invoke-RepoFlowPrMergeWorkflow { return }
            Invoke-RepoFlow -Area pr -Action merge -Number 116
            Should -Invoke Invoke-RepoFlowPrMergeWorkflow -Times 1 -Exactly
        }

        It 'routes pr accept as a merge alias' {
            Mock Invoke-RepoFlowPrMergeWorkflow { return }
            Invoke-RepoFlow -Area pr -Action accept -Number 116
            Should -Invoke Invoke-RepoFlowPrMergeWorkflow -Times 1 -Exactly
        }

        It 'does not expose a PR preview command' {
            {
                Invoke-RepoFlow -Area pr -Action preview -Number 66
            } | Should -Throw '*Unsupported RepoFlow command*'
        }
    }
}
