BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow PR review CLI' {
    BeforeAll {
        $script:TestRepositoryRoot = [System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..')
        )
    }

    It 'maps pr review to the dispatcher' {
        Mock -CommandName Invoke-RepoFlow -ModuleName RepoFlow

        Invoke-RepoFlowCli `
            -Arguments @('pr', 'review', '-Number', '25', '-Apply') `
            -RepositoryRoot $script:TestRepositoryRoot

        Should -Invoke -CommandName Invoke-RepoFlow `
            -ModuleName RepoFlow `
            -Times 1 `
            -Exactly `
            -ParameterFilter {
                $Area -eq 'pr' -and
                $Action -eq 'review' -and
                $Number -eq 25 -and
                $Apply
            }
    }

    InModuleScope RepoFlow {
        It 'routes pr review without routing merge' {
            Mock Invoke-RepoFlowPrReviewWorkflow { return }
            Mock Invoke-RepoFlowPrMergeWorkflow {
                throw 'Merge must never run.'
            }

            Invoke-RepoFlow -Area pr -Action review -Number 25 -Apply

            Should -Invoke Invoke-RepoFlowPrReviewWorkflow `
                -Times 1 `
                -Exactly `
                -ParameterFilter { $Number -eq 25 -and $Apply }
            Should -Invoke Invoke-RepoFlowPrMergeWorkflow -Times 0 -Exactly
        }

        It 'requires a PR number' {
            {
                Invoke-RepoFlow -Area pr -Action review
            } | Should -Throw "*'pr review' requires -Number*"
        }

        It 'documents the bounded loop and no-merge boundary' {
            $help = Get-RepoFlowHelpText -Topic 'pr review'

            $help | Should -Match 'bounded automated-review'
            $help | Should -Match 'Repeated blockers'
            $help | Should -Match 'never approves or merges'
        }
    }
}
