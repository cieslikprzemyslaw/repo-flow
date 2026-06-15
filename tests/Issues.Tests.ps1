BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow issue helpers' {
    InModuleScope RepoFlow {
        It 'creates the expected feature branch name' {
            $issue = [pscustomobject]@{
                number = 65
                title = 'Redesign sidebar navigation and display application version'
                labels = @(
                    [pscustomobject]@{ name = 'type: feature' }
                )
            }

            Get-RepoFlowIssueBranchName -Issue $issue |
                Should -Be 'feature/65-redesign-sidebar-navigation-and-display-application-ver'
        }

        It 'uses a fix branch for bug issues' {
            $issue = [pscustomobject]@{
                number = 111
                title = 'Close mobile sidebar after company switcher navigation'
                labels = @(
                    [pscustomobject]@{ name = 'type: bug' }
                )
            }

            Get-RepoFlowIssueBranchName -Issue $issue |
                Should -Match '^fix/111-'
        }

        It 'extracts unique dependencies' {
            $body = @'
## Dependencies

- #63
- #64
- #63
'@

            @(Get-RepoFlowIssueDependencies -IssueBody $body) |
                Should -Be @(63, 64)
        }
    }
}

