BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow queue CLI' {
    InModuleScope RepoFlow {
        It 'routes queue run with manifest and continuous mode' {
            Mock Invoke-RepoFlowQueueRunWorkflow { return }

            Invoke-RepoFlow `
                -Area queue `
                -Action run `
                -Manifest '.\queue.json' `
                -Continuous `
                -Apply

            Should -Invoke Invoke-RepoFlowQueueRunWorkflow `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Manifest -eq '.\queue.json' -and
                    $Continuous -and
                    $Apply
                }
        }

        It 'prints the complete ordered plan without creating queue state' {
            $script:PlanRows = @(
                [pscustomobject]@{ Position = 1; Issue = 11 },
                [pscustomobject]@{ Position = 2; Issue = 12 }
            )
            $script:ShownRows = @()
            $script:QueueManifest = [pscustomobject]@{
                name = 'test queue'
                path = 'C:\repo\queue.json'
                hash = ('a' * 64)
                tasks = @(
                    [pscustomobject]@{ position = 0; issueNumber = 11 },
                    [pscustomobject]@{ position = 1; issueNumber = 12 }
                )
            }

            Mock Read-RepoFlowQueueManifest { return $script:QueueManifest }
            Mock Get-RepoFlowQueueStateConfigPath { return 'C:\repo\.repo-flow.json' }
            Mock Get-RepoFlowLatestQueueForManifest { return $null }
            Mock Get-RepoFlowQueuePlanRows { return $script:PlanRows }
            Mock Show-RepoFlowQueuePlan {
                param($Rows)
                $script:ShownRows = @($Rows)
            }
            Mock Start-RepoFlowQueueRecord { throw 'Plan mode must not mutate state.' }

            Invoke-RepoFlowQueueRunWorkflow -Manifest '.\queue.json'

            $script:ShownRows.Count | Should -Be 2
            ($script:ShownRows.Issue -join ',') | Should -Be '11,12'
            Should -Invoke Start-RepoFlowQueueRecord -Times 0 -Exactly
        }

        It 'routes queue resume' {
            Mock Invoke-RepoFlowQueueResumeWorkflow { return }

            Invoke-RepoFlow `
                -Area queue `
                -Action resume `
                -Manifest '.\queue.json'

            Should -Invoke Invoke-RepoFlowQueueResumeWorkflow `
                -Times 1 `
                -Exactly
        }

        It 'routes queue pause without continuous mode' {
            Mock Invoke-RepoFlowQueuePauseWorkflow { return }

            Invoke-RepoFlow `
                -Area queue `
                -Action pause `
                -Manifest '.\queue.json' `
                -Apply

            Should -Invoke Invoke-RepoFlowQueuePauseWorkflow `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Manifest -eq '.\queue.json' -and $Apply
                }
        }

        It 'routes queue stop without continuous mode' {
            Mock Invoke-RepoFlowQueueStopWorkflow { return }

            Invoke-RepoFlow `
                -Area queue `
                -Action stop `
                -Manifest '.\queue.json' `
                -Apply

            Should -Invoke Invoke-RepoFlowQueueStopWorkflow `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Manifest -eq '.\queue.json' -and $Apply
                }
        }

        It 'requires a manifest for queue run' {
            {
                Invoke-RepoFlow -Area queue -Action run
            } | Should -Throw '*requires -Manifest*'
        }

        It 'parses queue run arguments through the public CLI parser' {
            Mock Invoke-RepoFlow { return }
            $root = [System.IO.Path]::GetFullPath(
                (Join-Path $PSScriptRoot '..')
            )

            Invoke-RepoFlowCli `
                -Arguments @(
                    'queue',
                    'run',
                    '-Manifest',
                    '.\queue.json',
                    '-Continuous',
                    '-Apply'
                ) `
                -RepositoryRoot $root

            Should -Invoke Invoke-RepoFlow `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Area -eq 'queue' -and
                    $Action -eq 'run' -and
                    $Manifest -eq '.\queue.json' -and
                    $Continuous -and
                    $Apply
                }
        }

        It 'documents ordered execution and the merge gate' {
            $helpText = Get-RepoFlowHelpText -Topic 'queue run'

            $helpText | Should -Match 'full ordered queue plan'
            $helpText | Should -Match 'never merges a pull request'
            $helpText | Should -Match 'human-confirmed'
        }
    }
}
