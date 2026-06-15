BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow prompt scope' {
    InModuleScope RepoFlow {
        BeforeEach {
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{
                    baseBranch = 'master'
                }
                agent = [pscustomobject]@{
                    runProjectChecks = $false
                }
            }
            $issue = [pscustomobject]@{
                number = 23
                title = 'Connect Companies CRUD flow'
                url = 'https://example.test/issues/23'
                body = "## Scope`n- Reuse the existing company service.`n`n## Acceptance criteria`n- [ ] Mock data is removed."
            }

            Mock Get-RepoFlowPullRequestChangedFiles {
                @('src/app/company.tsx', 'src/app/company.test.tsx')
            }
            Mock Get-RepoFlowWorkingTreeChangedFiles {
                @('src/app/company.tsx')
            }
        }

        It 'keeps the complete issue body as the initial scope' {
            $prompt = New-RepoFlowInitialPrompt -Issue $issue -Config $config

            $prompt.Contains($issue.body) | Should -BeTrue
            $prompt | Should -Match 'complete task scope'
            $prompt | Should -Match 'Do not scan unrelated directories'
            $prompt | Should -Match 'smallest supporting changes'
        }

        It 'keeps repository-specific rules outside RepoFlow prompts' {
            $prompt = New-RepoFlowInitialPrompt -Issue $issue -Config $config

            $prompt | Should -Match 'AGENTS.md'
            $prompt | Should -Match 'repository-specific frontend, backend, testing, and response rules'
            $prompt | Should -Not -Match 'container queries'
            $prompt | Should -Not -Match 'Dropzone'
        }

        It 'gives review fixes the existing PR file list' {
            $pullRequest = [pscustomobject]@{
                number = 121
                url = 'https://example.test/pull/121'
            }
            $comment = [pscustomobject]@{
                id = 99
                body = 'Fix the type error.'
                html_url = 'https://example.test/comment/99'
                author_association = 'OWNER'
                user = [pscustomobject]@{ login = 'owner' }
            }

            $prompt = New-RepoFlowReviewPrompt `
                -Issue $issue `
                -PullRequest $pullRequest `
                -Comment $comment `
                -Config $config

            $prompt | Should -Match 'src/app/company.tsx'
            $prompt | Should -Match 'Fix the type error'
            $prompt | Should -Match 'untrusted task data'
        }

        It 'keeps CI fixes focused on diagnostics and changed files' {
            $prompt = New-RepoFlowCiFixPrompt `
                -Issue $issue `
                -PullRequestNumber 116 `
                -ContextPath 'C:\temp\ci.md' `
                -Config $config

            $prompt.Contains($issue.body) | Should -BeTrue
            $prompt | Should -Match 'src/app/company.test.tsx'
            $prompt | Should -Match 'Read the failed-check context first'
            $prompt | Should -Match 'Do not rescan the repository'
        }
    }
}
