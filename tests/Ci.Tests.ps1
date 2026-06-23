BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow CI state handling' {
    InModuleScope RepoFlow {
        It 'keeps the overall state pending while any check is pending' {
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = @"
[
  { "name": "Validate (push)", "bucket": "fail", "link": "https://example.test/old" },
  { "name": "Validate (pull_request)", "bucket": "pending", "link": "https://example.test/new" }
]
"@
                }
            }

            $state = Get-RepoFlowPrCheckState `
                -PullRequestNumber 116 `
                -Repository 'owner/repository'

            $state.Status | Should -Be 'pending'
        }

        It 'reports failure only after all checks are terminal' {
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = @"
[
  { "name": "Validate (push)", "bucket": "fail", "link": "https://example.test/one" },
  { "name": "Validate (pull_request)", "bucket": "pass", "link": "https://example.test/two" }
]
"@
                }
            }

            $state = Get-RepoFlowPrCheckState `
                -PullRequestNumber 116 `
                -Repository 'owner/repository'

            $state.Status | Should -Be 'failed'
        }

        It 'waits until GitHub reports the expected pull request head' {
            $script:poll = 0

            Mock Get-RepoFlowPullRequest {
                $script:poll++

                if ($script:poll -eq 1) {
                    return [pscustomobject]@{ headRefOid = ('a' * 40) }
                }

                return [pscustomobject]@{ headRefOid = ('b' * 40) }
            }

            Mock Start-Sleep {}

            $pullRequest = Wait-RepoFlowPullRequestHead `
                -PullRequestNumber 116 `
                -Repository 'owner/repository' `
                -ExpectedHeadSha ('b' * 40) `
                -TimeoutSeconds 30 `
                -PollSeconds 1

            $pullRequest.headRefOid | Should -Be ('b' * 40)
            Should -Invoke Get-RepoFlowPullRequest -Times 2
        }
    }
}

Describe 'RepoFlow CI diagnostics' {
    BeforeAll {
        $env:REPO_FLOW_CI_FIXTURE_DIRECTORY = Join-Path $PSScriptRoot 'fixtures/ci'
    }

    AfterAll {
        Remove-Item Env:REPO_FLOW_CI_FIXTURE_DIRECTORY -ErrorAction SilentlyContinue
    }

    InModuleScope RepoFlow {
        It 'writes structured human and machine-readable diagnostics' {
            $outputPath = Join-Path $TestDrive 'ci-context.md'
            $logText = [System.IO.File]::ReadAllText(
                (Join-Path $env:REPO_FLOW_CI_FIXTURE_DIRECTORY 'vitest-multiple-failures.log')
            )
            $checks = @(
                [pscustomobject]@{
                    name = 'Validate'
                    bucket = 'fail'
                    link = 'https://github.com/owner/repository/actions/runs/12345'
                }
            )

            Mock Get-RepoFlowPullRequestChangedFiles {
                @('src/app/page.tsx', 'src/app/page.test.tsx')
            }
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = $logText
                }
            }

            Write-RepoFlowFailedCiContext `
                -IssueNumber 22 `
                -PullRequestNumber 121 `
                -Checks $checks `
                -Repository 'owner/repository' `
                -BaseBranch 'master' `
                -OutputPath $outputPath

            $context = Get-Content -LiteralPath $outputPath -Raw

            $context | Should -Match '### Structured diagnostics'
            $context | Should -Match '\[test\] LoginForm > shows validation error'
            $context | Should -Match 'loginForm\.test\.tsx:42'
            $context | Should -Match 'authenticate > rejects an expired token'
            $context | Should -Match 'auth\.service\.test\.ts:87'
            $context | Should -Match '### Machine-readable diagnostics'
            $context | Should -Match '"Category":\s*"test"'
            $context | Should -Match '"TestFile":\s*"src/components/loginForm/loginForm\.test\.tsx"'
            $context | Should -Match '### Bounded raw context'
        }

        It 'cleans ANSI sequences and GitHub prefixes in final raw context output' {
            $outputPath = Join-Path $TestDrive 'ci-context-clean-raw.md'
            $escape = [string][char]27
            $logText = @(
                "Tests`tRun npm test`t2026-06-23T14:00:00.5000000Z`t${escape}[31mFAIL${escape}[0m src/utils/date.test.ts > formatDate > rejects invalid input"
                'Tests`tRun npm test`t2026-06-23T14:00:00.6000000Z`tAssertionError: expected "2026-01-01" to be "2026-01-02"'
                'Tests`tRun npm test`t2026-06-23T14:00:00.7000000Z`t'
                'Tests`tRun npm test`t2026-06-23T14:00:00.8000000Z`tExpected: "2026-01-02"'
                'Tests`tRun npm test`t2026-06-23T14:00:00.9000000Z`tReceived: "2026-01-01"'
                'Tests`tRun npm test`t2026-06-23T14:00:01.0000000Z`t'
                'Tests`tRun npm test`t2026-06-23T14:00:01.1000000Z`t at src/utils/date.test.ts:12:4'
                'Tests`tRun npm test`t2026-06-23T14:00:01.2000000Z`tTests 1 failed (1)'
                'Tests`tRun npm test`t2026-06-23T14:00:01.3000000Z`tProcess completed with exit code 1.'
            ) -join "`n"
            $checks = @(
                [pscustomobject]@{
                    name = 'Tests'
                    bucket = 'fail'
                    link = 'https://github.com/owner/repository/actions/runs/12345'
                }
            )

            Mock Get-RepoFlowPullRequestChangedFiles {
                @('src/utils/date.test.ts')
            }
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = $logText
                }
            }

            Write-RepoFlowFailedCiContext `
                -IssueNumber 22 `
                -PullRequestNumber 121 `
                -Checks $checks `
                -Repository 'owner/repository' `
                -BaseBranch 'master' `
                -OutputPath $outputPath

            $context = Get-Content -LiteralPath $outputPath -Raw

            $context | Should -Match '### Bounded raw context'
            $context | Should -Not -Match ([regex]::Escape($escape))
            $context | Should -Not -Match 'Tests\tRun npm test\t2026-06-23'
            $context | Should -Match 'FAIL src/utils/date.test.ts > formatDate > rejects invalid input'
            $context | Should -Match 'Run npm test'
        }

        It 'keeps bounded raw fallback for unknown failed output' {
            $outputPath = Join-Path $TestDrive 'ci-context-unknown.md'
            $longLog = ('HEAD' + ('A' * 16000) + ('B' * 16000) + 'TAIL')
            $checks = @(
                [pscustomobject]@{
                    name = 'Validate'
                    bucket = 'fail'
                    link = 'https://github.com/owner/repository/actions/runs/12345'
                }
            )

            Mock Get-RepoFlowPullRequestChangedFiles {
                @('src/app/page.tsx', 'src/app/page.test.tsx')
            }
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = $longLog
                }
            }

            Write-RepoFlowFailedCiContext `
                -IssueNumber 22 `
                -PullRequestNumber 121 `
                -Checks $checks `
                -Repository 'owner/repository' `
                -BaseBranch 'master' `
                -OutputPath $outputPath

            $context = Get-Content -LiteralPath $outputPath -Raw

            $context | Should -Match 'src/app/page.tsx'
            $context | Should -Match 'HEAD'
            $context | Should -Match 'TAIL'
            $context | Should -Match 'RepoFlow omitted'
        }
    }
}
