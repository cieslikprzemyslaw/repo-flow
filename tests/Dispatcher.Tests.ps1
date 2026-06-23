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

        It 'routes pr repair commands' {
            Mock Invoke-RepoFlowPrRepairWorkflow { return }
            Invoke-RepoFlow -Area pr -Action repair -Number 116
            Should -Invoke Invoke-RepoFlowPrRepairWorkflow -Times 1 -Exactly
        }

        It 'routes run show commands' {
            Mock Invoke-RepoFlowRunShowWorkflow { return }
            Invoke-RepoFlow -Area run -Action show -RunId run-123
            Should -Invoke Invoke-RepoFlowRunShowWorkflow -Times 1 -Exactly
        }

        It 'requires a run id for run show' {
            {
                Invoke-RepoFlow -Area run -Action show
            } | Should -Throw '*requires -RunId*'
        }

        It 'routes pr accept as a merge alias' {
            Mock Invoke-RepoFlowPrMergeWorkflow { return }
            Invoke-RepoFlow -Area pr -Action accept -Number 116
            Should -Invoke Invoke-RepoFlowPrMergeWorkflow -Times 1 -Exactly
        }

        It 'routes positional repository use commands' {
            Mock Invoke-RepoFlowRepositoryUseWorkflow {
                return
            }

            Invoke-RepoFlow repo use report -Apply

            Should -Invoke `
                Invoke-RepoFlowRepositoryUseWorkflow `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Repo -eq 'report' -and $Apply
                }
        }
        It 'does not expose a PR preview command' {
            {
                Invoke-RepoFlow -Area pr -Action preview -Number 66
            } | Should -Throw '*Unsupported RepoFlow command*'
        }
    }
}
