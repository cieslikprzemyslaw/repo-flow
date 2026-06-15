BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow pre-commit recovery' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:commitAttempt = 0

            $config = [pscustomobject]@{
                git = [pscustomobject]@{
                    preCommitFixAttempts = 1
                }
            }

            $issue = [pscustomobject]@{
                number = 67
                title = 'Add company workspace switcher'
                body = 'Implement the company workspace switcher.'
            }
        }

        It 'does not invoke an agent fix when the commit succeeds' {
            Mock Invoke-RepoFlowCommitAttempt {
                [pscustomobject]@{ ExitCode = 0; Text = '' }
            }
            Mock Invoke-RepoFlowPreCommitFixAttempt { $true }

            Complete-RepoFlowCommit `
                -Issue $issue `
                -Message 'Implement #67' `
                -RepositoryRoot 'C:\repo' `
                -Config $config

            Should -Invoke Invoke-RepoFlowCommitAttempt -Times 1 -Exactly
            Should -Invoke Invoke-RepoFlowPreCommitFixAttempt -Times 0 -Exactly
        }

        It 'runs one focused fix and retries the commit' {
            Mock Invoke-RepoFlowCommitAttempt {
                $script:commitAttempt++

                if ($script:commitAttempt -eq 1) {
                    return [pscustomobject]@{
                        ExitCode = 1
                        Text = 'eslint failed'
                    }
                }

                return [pscustomobject]@{ ExitCode = 0; Text = '' }
            }
            Mock Invoke-RepoFlowPreCommitFixAttempt { $true }

            Complete-RepoFlowCommit `
                -Issue $issue `
                -Message 'Implement #67' `
                -RepositoryRoot 'C:\repo' `
                -Config $config

            Should -Invoke Invoke-RepoFlowCommitAttempt -Times 2 -Exactly
            Should -Invoke Invoke-RepoFlowPreCommitFixAttempt -Times 1 -Exactly
        }

        It 'stops after the configured retry still fails' {
            Mock Invoke-RepoFlowCommitAttempt {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = 'eslint still failed'
                }
            }
            Mock Invoke-RepoFlowPreCommitFixAttempt { $true }

            {
                Complete-RepoFlowCommit `
                    -Issue $issue `
                    -Message 'Implement #67' `
                    -RepositoryRoot 'C:\repo' `
                    -Config $config
            } | Should -Throw '*still failed after 1*'
        }

        It 'keeps the pre-commit prompt inside the issue scope' {
            $prompt = New-RepoFlowPreCommitFixPrompt `
                -Issue $issue `
                -ContextPath 'C:\temp\pre-commit.md'

            $prompt.Contains($issue.body) | Should -BeTrue
            $prompt | Should -Match 'smallest correction'
            $prompt | Should -Match 'Do not commit'
            $prompt | Should -Match 'commit hook will run again'
        }
    }
}

Describe 'RepoFlow pre-commit diagnostics' {
    InModuleScope RepoFlow {
        It 'lists changed files and keeps both ends of long hook output' {
            $outputPath = Join-Path $TestDrive 'pre-commit-context.md'
            $issue = [pscustomobject]@{
                number = 67
                title = 'Add company workspace switcher'
            }
            $failureText = 'HOOK-START' + ('A' * 16000) + ('B' * 16000) + 'HOOK-END'

            Mock Get-RepoFlowWorkingTreeChangedFiles {
                @('src/app/workspace.tsx')
            }
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = 'diagnostic summary'
                }
            }

            Write-RepoFlowPreCommitFailureContext `
                -Issue $issue `
                -FailureText $failureText `
                -OutputPath $outputPath

            $context = Get-Content -LiteralPath $outputPath -Raw

            $context | Should -Match 'src/app/workspace.tsx'
            $context | Should -Match 'HOOK-START'
            $context | Should -Match 'HOOK-END'
            $context | Should -Match 'RepoFlow omitted'
        }
    }
}
