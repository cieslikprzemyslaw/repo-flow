BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow doctor diagnostics' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:repoPath = Join-Path $TestDrive 'target-repo'
            $script:configPath = Join-Path $TestDrive '.repo-flow.json'
            Remove-Item `
                -LiteralPath (Join-Path $TestDrive '.repo-flow.state.json') `
                -Force `
                -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $script:repoPath -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $script:repoPath '.github') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $script:repoPath 'AGENTS.md') -Value '# Agent rules'
            Set-Content -LiteralPath (Join-Path $script:repoPath '.github/pull_request_template.md') -Value '# PR'
            '{}' | Set-Content -LiteralPath (Join-Path $script:repoPath 'issues-manifest.json')

            $config = [ordered]@{
                defaultRepository = 'target'
                repositories = @(
                    [ordered]@{
                        name = 'target'
                        localPath = $script:repoPath
                        slug = 'owner/target'
                        expectedOrigins = @('https://github.com/owner/target.git')
                        baseBranch = 'main'
                    }
                )
                issues = [ordered]@{ manifestPath = './issues-manifest.json' }
                git = [ordered]@{
                    requireCleanWorkingTree = $true
                    deleteMergedLocalBranches = $true
                    pruneRemoteReferences = $true
                    signOffCommits = $false
                    preCommitFixAttempts = 1
                }
                agent = [ordered]@{
                    provider = 'codex'
                    command = 'codex'
                    model = 'gpt-5.5'
                    minimumCliVersion = '1.0.0'
                    heartbeatSeconds = 15
                    reasoningEffort = 'medium'
                    ciFixReasoningEffort = 'low'
                    preCommitFixReasoningEffort = 'low'
                    runProjectChecks = $false
                }
                pullRequest = [ordered]@{
                    createDraft = $true
                    templatePath = './.github/pull_request_template.md'
                    mergeMethod = 'squash'
                    deleteBranchOnMerge = $true
                }
                messages = [ordered]@{
                    initialCommit = '{verb} #{issueNumber}: {issueTitle}'
                    reviewCommit = 'Fix review feedback for #{issueNumber}'
                    ciFixCommit = 'Fix CI for #{issueNumber}'
                    pullRequestTitle = '{verb} #{issueNumber}: {issueTitle}'
                }
                ci = [ordered]@{
                    mode = 'require-passing'
                    pollSeconds = 30
                    timeoutSeconds = 1800
                    autoFixAttempts = 1
                }
                reviewFeedback = [ordered]@{
                    enabled = $true
                    confirmBeforeRun = $true
                    trustedAssociations = @('OWNER')
                }
            }

            $config | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM

            Mock Invoke-RepoFlowStateMutation { throw 'doctor must not mutate state' }
            Mock Write-RepoFlowStateDocument { throw 'doctor must not write state' }
            Mock Get-RepoFlowDoctorPowerShellVersion { [version]'7.5.0' }
            Mock Get-RepoFlowDoctorPesterVersion { [version]'5.7.1' }
            Mock Test-RepoFlowDoctorCommandAvailable { $true }
            Mock Get-RepoFlowDoctorAgentVersion {
                [pscustomobject]@{ Version = '2.1.154'; ExecutablePath = 'codex'; Text = 'codex 2.1.154' }
            }
            Mock Invoke-RepoFlowDoctorExternalCommand {
                param($Command, $Arguments)

                $joined = $Arguments -join ' '

                if ($Command -eq 'git' -and $joined -eq '--version') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'git version 2.50.0' }
                }

                if ($Command -eq 'gh' -and $joined -eq 'auth status') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'authenticated' }
                }

                if ($Command -eq 'git' -and $joined -match 'rev-parse --show-toplevel$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = $script:repoPath }
                }

                if ($Command -eq 'git' -and $joined -match 'remote get-url origin$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'https://github.com/owner/target.git' }
                }

                if ($Command -eq 'git' -and $joined -match 'show-ref --verify --quiet refs/heads/main$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = '' }
                }

                if ($Command -eq 'git' -and $joined -match 'show-ref --verify --quiet refs/remotes/origin/main$') {
                    return [pscustomobject]@{ ExitCode = 1; Text = '' }
                }

                if ($Command -eq 'git' -and $joined -match 'status --porcelain$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = '' }
                }

                if ($Command -eq 'gh' -and $joined -match '^api repos/owner/target') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'true' }
                }

                return [pscustomobject]@{ ExitCode = 1; Text = 'unexpected command' }
            }
        }

        It 'reports a successful read-only environment' {
            $results = @(Get-RepoFlowDoctorResults -ConfigPath $script:configPath)

            Get-RepoFlowDoctorFailureCount -Results $results | Should -Be 0
            Should -Invoke Invoke-RepoFlowStateMutation -Times 0
            Should -Invoke Write-RepoFlowStateDocument -Times 0
            $results | Where-Object Check -eq 'GitHub write access' |
                Select-Object -ExpandProperty Status |
                Should -Be PASS
            $results | Where-Object Check -eq 'Configuration schema' |
                Select-Object -ExpandProperty Status |
                Should -Be PASS
        }

        It 'reports missing required tools without invoking them' {
            Mock Test-RepoFlowDoctorCommandAvailable {
                param($Name)
                return $Name -notin @('git', 'gh', 'codex')
            }

            $results = @(Get-RepoFlowDoctorResults -ConfigPath $script:configPath)

            @($results | Where-Object { $_.Status -eq 'FAIL' }).Count |
                Should -BeGreaterThan 2
            Should -Invoke Invoke-RepoFlowDoctorExternalCommand `
                -ParameterFilter { $Command -eq 'git' } `
                -Times 0
        }

        It 'reports bad GitHub authentication' {
            Mock Invoke-RepoFlowDoctorExternalCommand {
                param($Command, $Arguments)
                $joined = $Arguments -join ' '

                if ($Command -eq 'gh' -and $joined -eq 'auth status') {
                    return [pscustomobject]@{ ExitCode = 1; Text = 'not logged in' }
                }

                if ($Command -eq 'git' -and $joined -eq '--version') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'git version 2.50.0' }
                }

                if ($Command -eq 'git' -and $joined -match 'rev-parse --show-toplevel$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = $script:repoPath }
                }

                if ($Command -eq 'git' -and $joined -match 'remote get-url origin$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'https://github.com/owner/target.git' }
                }

                if ($Command -eq 'git' -and $joined -match 'refs/heads/main$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = '' }
                }

                if ($Command -eq 'git' -and $joined -match 'status --porcelain$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = '' }
                }

                return [pscustomobject]@{ ExitCode = 1; Text = '' }
            }

            $results = @(Get-RepoFlowDoctorResults -ConfigPath $script:configPath)
            $gh = $results | Where-Object Check -eq 'GitHub CLI'

            $gh.Status | Should -Be FAIL
            $gh.Details | Should -Match 'gh auth login'
        }

        It 'reports an unexpected origin' {
            Mock Invoke-RepoFlowDoctorExternalCommand {
                param($Command, $Arguments)
                $joined = $Arguments -join ' '

                if ($Command -eq 'git' -and $joined -eq '--version') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'git version 2.50.0' }
                }

                if ($Command -eq 'gh' -and $joined -eq 'auth status') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'authenticated' }
                }

                if ($Command -eq 'git' -and $joined -match 'rev-parse --show-toplevel$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = $script:repoPath }
                }

                if ($Command -eq 'git' -and $joined -match 'remote get-url origin$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'https://example.test/wrong.git' }
                }

                if ($Command -eq 'git' -and $joined -match 'refs/heads/main$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = '' }
                }

                if ($Command -eq 'git' -and $joined -match 'status --porcelain$') {
                    return [pscustomobject]@{ ExitCode = 0; Text = '' }
                }

                if ($Command -eq 'gh') {
                    return [pscustomobject]@{ ExitCode = 0; Text = 'true' }
                }

                return [pscustomobject]@{ ExitCode = 1; Text = '' }
            }

            $results = @(Get-RepoFlowDoctorResults -ConfigPath $script:configPath)
            $origin = $results | Where-Object Check -eq Origin

            $origin.Status | Should -Be FAIL
            $origin.Details | Should -Match 'not one of the configured'
        }

        It 'continues after invalid configuration JSON' {
            '{invalid json' | Set-Content -LiteralPath $script:configPath

            { Get-RepoFlowDoctorResults -ConfigPath $script:configPath } |
                Should -Not -Throw

            $results = @(Get-RepoFlowDoctorResults -ConfigPath $script:configPath)
            $results | Where-Object Check -eq 'Configuration file' |
                Select-Object -ExpandProperty Status |
                Should -Be FAIL
        }


        It 'does not expose secret-like configuration values' {
            $raw = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
            $raw | Add-Member -NotePropertyName apiToken -NotePropertyValue 'super-secret-token'
            $raw | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM

            $results = @(Get-RepoFlowDoctorResults -ConfigPath $script:configPath)
            $report = Format-RepoFlowDoctorReport -Results $results

            $report | Should -Not -Match 'super-secret-token'
            $report | Should -Match 'apiToken'
        }

        It 'warns when optional capabilities and guidance files are missing' {
            Remove-Item -LiteralPath (Join-Path $script:repoPath 'AGENTS.md')
            $raw = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
            $raw.PSObject.Properties.Remove('issues')
            $raw | ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM
            Mock Get-RepoFlowDoctorPesterVersion { $null }

            $results = @(Get-RepoFlowDoctorResults -ConfigPath $script:configPath)

            ($results | Where-Object Check -eq Pester).Status | Should -Be WARN
            ($results | Where-Object Check -eq AGENTS.md).Status | Should -Be WARN
            ($results | Where-Object Check -eq 'Issue manifest').Status | Should -Be WARN
        }

        It 'reports corrupt local state without modifying it' {
            $statePath = Get-RepoFlowStatePath -ConfigPath $script:configPath
            '{broken' | Set-Content -LiteralPath $statePath
            $before = Get-Content -LiteralPath $statePath -Raw

            $results = @(Get-RepoFlowDoctorResults -ConfigPath $script:configPath)

            ($results | Where-Object Check -eq 'Local state').Status |
                Should -Be FAIL
            (Get-Content -LiteralPath $statePath -Raw) | Should -Be $before
        }

        It 'throws after printing when required checks fail' {
            Mock Get-RepoFlowDoctorResults {
                @(
                    New-RepoFlowDoctorResult `
                        -Status FAIL `
                        -Group Tools `
                        -Check Git `
                        -Details 'missing'
                )
            }
            Mock Write-Host { return }

            { Invoke-RepoFlowDoctorWorkflow } |
                Should -Throw '*found 1 required failure*'
        }
    }
}
