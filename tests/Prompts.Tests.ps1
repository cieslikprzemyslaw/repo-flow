BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow prompt scope' {
    InModuleScope RepoFlow {
        BeforeAll {
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{ baseBranch = 'master' }
                agent = [pscustomobject]@{ runProjectChecks = $false }
            }

            $issue = [pscustomobject]@{
                number = 23
                title = 'Connect Companies CRUD flow'
                url = 'https://example.test/issues/23'
                body = "## Scope`n- Reuse the existing company service.`n`n## Acceptance criteria`n- [ ] Mock data is removed."
            }
        }

        It 'includes the complete issue body in the initial prompt' {
            $prompt = New-RepoFlowInitialPrompt -Issue $issue -Config $config

            $prompt.Contains($issue.body) | Should -BeTrue
            $prompt | Should -Match 'authoritative task scope'
        }

        It 'instructs the agent to avoid broad repository exploration' {
            $prompt = New-RepoFlowInitialPrompt -Issue $issue -Config $config

            $prompt | Should -Match 'Do not scan unrelated directories'
            $prompt | Should -Match 'smallest coherent diff'
            $prompt | Should -Match 'Do not add opportunistic UX enhancements'
        }

        It 'keeps CI fixes inside the original issue scope' {
            $prompt = New-RepoFlowCiFixPrompt `
                -Issue $issue `
                -PullRequestNumber 116 `
                -ContextPath 'C:\temp\ci.md' `
                -Config $config

            $prompt.Contains($issue.body) | Should -BeTrue
            $prompt | Should -Match 'Read the failed-check context first'
            $prompt | Should -Match 'origin/master'
            $prompt | Should -Match 'Do not rescan the whole repository'
        }
    }
}
