BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow structured CI diagnostics' {
    BeforeAll {
        $env:REPO_FLOW_CI_FIXTURE_DIRECTORY = Join-Path $PSScriptRoot 'fixtures/ci'
    }

    AfterAll {
        Remove-Item Env:REPO_FLOW_CI_FIXTURE_DIRECTORY -ErrorAction SilentlyContinue
    }

    InModuleScope RepoFlow {
        It 'extracts multiple Vitest failures as separate ordered records' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'vitest-multiple-failures.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics `
                    -Text $text `
                    -CheckName 'Tests' `
                    -StepName 'Run npm test' `
                    -Command 'npm test'
            )

            $records | Should -HaveCount 2

            $records[0].Category | Should -Be 'test'
            $records[0].CheckName | Should -Be 'Tests'
            $records[0].StepName | Should -Be 'Run npm test'
            $records[0].Command | Should -Be 'npm test'
            $records[0].TestFile |
                Should -Be 'src/components/loginForm/loginForm.test.tsx'
            $records[0].TestName |
                Should -Be 'LoginForm > shows validation error'
            $records[0].Expected |
                Should -Be '"Enter an email address"'
            $records[0].Received |
                Should -Be '"Email is required"'
            $records[0].SourcePath |
                Should -Be 'src/components/loginForm/loginForm.test.tsx'
            $records[0].SourceLine | Should -Be 42

            $records[1].Category | Should -Be 'test'
            $records[1].TestFile |
                Should -Be 'src/services/auth/auth.service.test.ts'
            $records[1].TestName |
                Should -Be 'authenticate > rejects an expired token'
            $records[1].Expected | Should -Be '401'
            $records[1].Received | Should -Be '500'
            $records[1].SourcePath |
                Should -Be 'src/services/auth/auth.service.test.ts'
            $records[1].SourceLine | Should -Be 87
        }

        It 'returns equivalent records for LF and CRLF logs' {
            $lfText = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'vitest-multiple-failures.log')
            )
            $crlfText = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'vitest-multiple-failures-crlf.log')
            )

            $lf = @(
                Get-RepoFlowCiDiagnostics -Text $lfText -CheckName 'Tests'
            )
            $crlf = @(
                Get-RepoFlowCiDiagnostics -Text $crlfText -CheckName 'Tests'
            )

            ($lf | ConvertTo-Json -Depth 6) |
                Should -Be ($crlf | ConvertTo-Json -Depth 6)
        }

        It 'removes ANSI control sequences before extraction' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'vitest-ansi-failure.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics -Text $text -CheckName 'Tests'
            )

            $records | Should -HaveCount 1
            $records[0].Category | Should -Be 'test'
            $records[0].TestFile | Should -Be 'src/utils/date.test.ts'
            $records[0].Summary | Should -Not -Match ([char]27)
            $records[0].RawContext | Should -Not -Match ([char]27)
        }

        It 'does not report intentional stderr from a successful test run' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'vitest-success-with-stderr.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics -Text $text -CheckName 'Tests'
            )

            $records | Should -HaveCount 0
        }

        It 'classifies supported non-test failures' {
            $cases = @(
                @{ Fixture = 'formatting-failure.log'; Category = 'formatting' }
                @{ Fixture = 'lint-failure.log'; Category = 'lint' }
                @{ Fixture = 'typecheck-failure.log'; Category = 'typecheck' }
                @{ Fixture = 'build-failure.log'; Category = 'build' }
                @{
                    Fixture = 'infrastructure-failure.log'
                    Category = 'infrastructure/unknown'
                }
            )

            foreach ($case in $cases) {
                $text = [System.IO.File]::ReadAllText(
                    (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY $case.Fixture)
                )

                $records = @(
                    Get-RepoFlowCiDiagnostics `
                        -Text $text `
                        -CheckName 'Validate'
                )

                $records | Should -HaveCount 1
                $records[0].Category | Should -Be $case.Category
                $records[0].Summary | Should -Not -BeNullOrEmpty
            }
        }

        It 'bounds a large DOM snapshot while preserving useful context' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'vitest-large-dom-failure.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics `
                    -Text $text `
                    -CheckName 'Tests' `
                    -MaximumRawCharacters 1200 `
                    -HeadCharacters 500
            )

            $records | Should -HaveCount 1
            $records[0].Category | Should -Be 'test'
            $records[0].Summary | Should -Match 'Unable to find'
            $records[0].SourcePath |
                Should -Be 'src/components/modal/modal.test.tsx'
            $records[0].SourceLine | Should -Be 64
            $records[0].RawContext.Length | Should -BeLessOrEqual 1200
            $records[0].RawContext | Should -Match 'RepoFlow omitted'
        }

        It 'falls back safely for an unknown failed format' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'unknown-failure.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics `
                    -Text $text `
                    -CheckName 'Custom validator' `
                    -MaximumRawCharacters 1200 `
                    -HeadCharacters 400
            )

            $records | Should -HaveCount 1
            $records[0].Category | Should -Be 'infrastructure/unknown'
            $records[0].Summary | Should -Match 'ZX-991'
            $records[0].RawContext.Length | Should -BeLessOrEqual 1200
            $records[0].RawContext | Should -Match 'RepoFlow omitted'
        }

        It 'returns a stable machine-readable record shape' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'lint-failure.log')
            )

            $record = @(
                Get-RepoFlowCiDiagnostics -Text $text -CheckName 'Lint'
            )[0]

            $expectedProperties = @(
                'Category'
                'CheckName'
                'StepName'
                'Command'
                'Project'
                'TestFile'
                'TestName'
                'Summary'
                'Expected'
                'Received'
                'SourcePath'
                'SourceLine'
                'Stack'
                'RawContext'
            )

            foreach ($property in $expectedProperties) {
                $record.PSObject.Properties.Name | Should -Contain $property
            }
        }

        It 'formats a concise human-readable summary from records' {
            $text = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'vitest-multiple-failures.log')
            )

            $records = @(
                Get-RepoFlowCiDiagnostics -Text $text -CheckName 'Tests'
            )

            $summary = Format-RepoFlowCiDiagnostics -Diagnostics $records

            $summary | Should -Match 'LoginForm'
            $summary | Should -Match 'authenticate'
            $summary | Should -Match 'loginForm.test.tsx:42'
            $summary | Should -Match 'auth.service.test.ts:87'
        }
    }
}
