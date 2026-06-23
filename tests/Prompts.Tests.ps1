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

        It 'keeps PR repairs focused on the live head, diagnostics, and validation' {
            $pullRequest = [pscustomobject]@{
                number = 116
                title = 'Fix CI'
                url = 'https://example.test/pull/116'
            }
            $diagnostics = @(
                [pscustomobject]@{
                    Category = 'test'
                    CheckName = 'Validate'
                    StepName = 'Run tests'
                    Command = 'npm test'
                    Project = 'web'
                    Suite = 'LoginForm'
                    TestFile = 'src/components/loginForm/loginForm.test.tsx'
                    TestName = 'shows validation error'
                    Summary = 'expected true to be false'
                    Expected = 'true'
                    Received = 'false'
                    SourcePath = 'src/components/loginForm/loginForm.test.tsx'
                    SourceLine = 55
                    Stack = 'stack'
                }
            )

            $prompt = New-RepoFlowPrRepairPrompt `
                -Issue $issue `
                -PullRequest $pullRequest `
                -HeadSha ('a' * 40) `
                -ContextPath 'C:\temp\repair.md' `
                -CurrentDiff ' src/app/company.tsx | 2 ++' `
                -ChangedFiles @('src/app/company.tsx') `
                -Diagnostics $diagnostics `
                -Config $config `
                -RepairAttemptLimit 2

            $prompt | Should -Match 'PR head SHA'
            $prompt | Should -Match 'Repair attempts allowed: 2'
            $prompt | Should -Match 'git diff --check'
            $prompt | Should -Match 'AGENTS.md'
            $prompt | Should -Match 'Do not run project checks'
            $prompt | Should -Match 'src/app/company.tsx'
            $prompt | Should -Match 'expected true to be false'
            $prompt | Should -Match 'Current diff'
        }
    }
}
