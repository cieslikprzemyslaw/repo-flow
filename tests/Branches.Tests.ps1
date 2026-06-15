BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow merged branch cleanup' {
    InModuleScope RepoFlow {
        BeforeEach {
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{
                    slug = 'owner/repository'
                    baseBranch = 'master'
                }
                git = [pscustomobject]@{
                    requireCleanWorkingTree = $true
                    pruneRemoteReferences = $false
                }
            }

            Mock Get-RepoFlowCurrentBranch { 'master' }
            Mock Assert-RepoFlowCleanWorkingTree {}
        }

        It 'returns multiple merged branches as a normal array' {
            Mock Get-RepoFlowLocalBranches {
                @('master', 'feature/one', 'feature/two')
            }
            Mock Get-RepoFlowLatestPullRequestForBranch {
                [pscustomobject]@{
                    number = 10
                    state = 'MERGED'
                    baseRefName = 'master'
                    mergedAt = '2026-06-15T10:00:00Z'
                }
            }

            $branches = @(Get-RepoFlowMergedLocalBranches -Config $config)

            $branches | Should -HaveCount 2
            $branches.branch | Should -Contain 'feature/one'
            $branches.branch | Should -Contain 'feature/two'
        }

        It 'force-deletes only branches with confirmed merged pull requests' {
            Mock Get-RepoFlowLocalBranches {
                @('master', 'feature/merged', 'feature/open')
            }
            Mock Get-RepoFlowLatestPullRequestForBranch {
                param($Branch)

                if ($Branch -eq 'feature/merged') {
                    return [pscustomobject]@{
                        number = 11
                        state = 'MERGED'
                        baseRefName = 'master'
                        mergedAt = '2026-06-15T10:00:00Z'
                    }
                }

                return [pscustomobject]@{
                    number = 12
                    state = 'OPEN'
                    baseRefName = 'master'
                    mergedAt = $null
                }
            }
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                }
            }

            Invoke-RepoFlowBranchCleanup -Config $config -Apply

            Should -Invoke Invoke-RepoFlowCommand `
                -Times 1 `
                -Exactly `
                -ParameterFilter {
                    $Command -eq 'git' -and
                    $Arguments[0] -eq 'branch' -and
                    $Arguments[1] -eq '-D' -and
                    $Arguments[2] -eq 'feature/merged'
                }
        }
    }
}
