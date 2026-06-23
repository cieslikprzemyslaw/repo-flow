BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow CI diagnostics review regressions' {
    BeforeAll {
        $env:REPO_FLOW_CI_FIXTURE_DIRECTORY = Join-Path $PSScriptRoot 'fixtures/ci'
    }

    AfterAll {
        Remove-Item Env:REPO_FLOW_CI_FIXTURE_DIRECTORY -ErrorAction SilentlyContinue
    }

    InModuleScope RepoFlow {
        It 'does not hide a later build failure after successful tests' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'passed-tests-then-build-failure.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics `
                    -Text $text `
                    -CheckName 'Validate'
            )

            $records | Should -HaveCount 1
            $records[0].Category | Should -Be 'build'
            $records[0].Summary | Should -Match 'Could not resolve'
            $records[0].StepName | Should -Be 'Run npm run build'
            $records[0].Command | Should -Be 'npm run build'
        }

        It 'preserves a later build failure after a failed test section' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'failed-test-then-build-failure.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics `
                    -Text $text `
                    -CheckName 'Validate'
            )

            $records | Should -HaveCount 2
            $records[0].Category | Should -Be 'test'
            $records[0].StepName | Should -Be 'Run npm test'
            $records[1].Category | Should -Be 'build'
            $records[1].Summary | Should -Match 'Could not resolve'
            $records[1].StepName | Should -Be 'Run npm run build'
            $records[1].Command | Should -Be 'npm run build'
        }

        It 'uses the matching run section metadata for later failures' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'lint-then-build-failure.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics `
                    -Text $text `
                    -CheckName 'Validate'
            )

            $records | Should -HaveCount 2
            $records[0].Category | Should -Be 'lint'
            $records[0].StepName | Should -Be 'Run npm run lint'
            $records[0].Command | Should -Be 'npm run lint'
            $records[1].Category | Should -Be 'build'
            $records[1].StepName | Should -Be 'Run npm run build'
            $records[1].Command | Should -Be 'npm run build'
            $records[1].Summary | Should -Match 'Could not resolve'
        }

        It 'extracts project suite and Vitest source markers from prefixed logs' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'vitest-prefixed-project-failure.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics `
                    -Text $text `
                    -CheckName 'Tests'
            )

            $records | Should -HaveCount 1
            $records[0].Category | Should -Be 'test'
            $records[0].Project | Should -Be 'web'
            $records[0].Suite | Should -Be 'LoginForm'
            $records[0].TestFile |
                Should -Be 'src/components/loginForm/loginForm.test.tsx'
            $records[0].SourcePath |
                Should -Be 'src/components/loginForm/loginForm.test.tsx'
            $records[0].SourceLine | Should -Be 55
            $records[0].Stack | Should -Match '❯'
        }

        It 'bounds raw output globally and excludes RawContext from JSON' {
            $outputPath = Join-Path $TestDrive 'ci-context-global-bound.md'
            $logText = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'unknown-failure.log')
            )
            $checks = @(
                [pscustomobject]@{
                    name = 'Validate one'
                    bucket = 'fail'
                    link = 'https://github.com/owner/repository/actions/runs/111'
                }
                [pscustomobject]@{
                    name = 'Validate two'
                    bucket = 'fail'
                    link = 'https://github.com/owner/repository/actions/runs/222'
                }
            )

            Mock Get-RepoFlowPullRequestChangedFiles {
                @('src/app/page.tsx')
            }
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = $logText
                }
            }

            Write-RepoFlowFailedCiContext `
                -IssueNumber 2 `
                -PullRequestNumber 16 `
                -Checks $checks `
                -Repository 'owner/repository' `
                -BaseBranch 'main' `
                -OutputPath $outputPath

            $context = Get-Content -LiteralPath $outputPath -Raw

            $context | Should -Not -Match '"RawContext"'
            ([regex]::Matches(
                $context,
                '### Raw failed log fallback'
            )).Count | Should -Be 2
            $context.Length | Should -BeLessThan 30000
        }
    }
}
