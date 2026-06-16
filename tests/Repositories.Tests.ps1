BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow multi-repository selection' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:repositoryA = Join-Path $TestDrive 'repo-a'
            $script:repositoryB = Join-Path $TestDrive 'repo-b'
            $script:nestedRepository = Join-Path $script:repositoryA 'nested'
            $script:configPath = Join-Path $TestDrive '.repo-flow.json'
            $script:statePath = Join-Path $TestDrive '.repo-flow.state.json'

            Remove-Item `
                -LiteralPath $script:statePath `
                -Force `
                -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $script:repositoryA -Force | Out-Null
            New-Item -ItemType Directory -Path $script:repositoryB -Force | Out-Null
            New-Item -ItemType Directory -Path $script:nestedRepository -Force | Out-Null

            $config = [ordered]@{
                defaultRepository = 'repo-a'
                repositories = @(
                    [ordered]@{
                        name = 'repo-a'
                        localPath = $script:repositoryA
                        slug = 'owner/repo-a'
                        expectedOrigins = @('https://github.com/owner/repo-a.git')
                        baseBranch = 'main'
                    }
                    [ordered]@{
                        name = 'repo-b'
                        localPath = $script:repositoryB
                        slug = 'owner/repo-b'
                        expectedOrigins = @('https://github.com/owner/repo-b.git')
                        baseBranch = 'master'
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
                    provider = 'claude'
                    command = 'claude'
                    model = 'claude-sonnet-4-6'
                    minimumCliVersion = $null
                    heartbeatSeconds = 15
                    reasoningEffort = 'low'
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

            $config |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM
        }

        It 'selects an explicit repository' {
            $selection = Get-RepoFlowRepositorySelection `
                -ConfigPath $script:configPath `
                -RepositoryName 'repo-b' `
                -CurrentDirectory $TestDrive

            $selection.Repository.name | Should -Be 'repo-b'
            $selection.Source | Should -Be 'explicit'
        }

        It 'uses the active repository before the current directory and default repository' {
            Write-RepoFlowActiveRepository `
                -ConfigPath $script:configPath `
                -RepositoryName 'repo-b' |
                Out-Null

            $selection = Get-RepoFlowRepositorySelection `
                -ConfigPath $script:configPath `
                -CurrentDirectory $script:repositoryA

            $selection.Repository.name | Should -Be 'repo-b'
            $selection.Source | Should -Be 'active'
        }
        It 'uses the longest matching path for nested repositories' {
            $raw = Get-Content -LiteralPath $script:configPath -Raw |
                ConvertFrom-Json

            $raw.repositories += [pscustomobject]@{
                name = 'nested'
                localPath = $script:nestedRepository
                slug = 'owner/nested'
                expectedOrigins = @('https://github.com/owner/nested.git')
                baseBranch = 'main'
            }

            $raw |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM

            $selection = Get-RepoFlowRepositorySelection `
                -ConfigPath $script:configPath `
                -CurrentDirectory (Join-Path $script:nestedRepository 'src')

            $selection.Repository.name | Should -Be 'nested'
        }

        It 'falls back to the active repository outside registered paths' {
            Write-RepoFlowActiveRepository `
                -ConfigPath $script:configPath `
                -RepositoryName 'repo-b' |
                Out-Null

            $selection = Get-RepoFlowRepositorySelection `
                -ConfigPath $script:configPath `
                -CurrentDirectory $TestDrive

            $selection.Repository.name | Should -Be 'repo-b'
            $selection.Source | Should -Be 'active'
        }

        It 'falls back to the default repository without active state' {
            $selection = Get-RepoFlowRepositorySelection `
                -ConfigPath $script:configPath `
                -CurrentDirectory $TestDrive

            $selection.Repository.name | Should -Be 'repo-a'
            $selection.Source | Should -Be 'default'
        }

        It 'rejects duplicate names case-insensitively' {
            $raw = Get-Content -LiteralPath $script:configPath -Raw |
                ConvertFrom-Json

            $raw.repositories[1].name = 'REPO-A'

            $raw |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM

            {
                Get-RepoFlowRepositoryRegistry -ConfigPath $script:configPath
            } | Should -Throw '*duplicated*'
        }

        It 'rejects an unknown default repository' {
            $raw = Get-Content -LiteralPath $script:configPath -Raw |
                ConvertFrom-Json

            $raw.defaultRepository = 'missing'

            $raw |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM

            {
                Get-RepoFlowRepositoryRegistry -ConfigPath $script:configPath
            } | Should -Throw '*defaultRepository*unknown*'
        }

        It 'rejects invalid active state JSON' {
            Set-Content `
                -LiteralPath $script:statePath `
                -Value '{broken' `
                -Encoding utf8NoBOM

            {
                Get-RepoFlowRepositorySelection `
                    -ConfigPath $script:configPath `
                    -CurrentDirectory $TestDrive
            } | Should -Throw '*state contains invalid JSON*'
        }

        It 'stores and resets active repository state only with Apply' {
            Invoke-RepoFlowRepositoryUseWorkflow `
                -Repo 'repo-b' `
                -ConfigPath $script:configPath

            Test-Path $script:statePath |
                Should -BeFalse

            Invoke-RepoFlowRepositoryUseWorkflow `
                -Repo 'repo-b' `
                -Apply `
                -ConfigPath $script:configPath

            $state = Read-RepoFlowRepositoryState -ConfigPath $script:configPath
            $state.ActiveRepository | Should -Be 'repo-b'

            Invoke-RepoFlowRepositoryResetWorkflow `
                -ConfigPath $script:configPath

            Test-Path $script:statePath |
                Should -BeTrue

            Invoke-RepoFlowRepositoryResetWorkflow `
                -Apply `
                -ConfigPath $script:configPath

            Test-Path $script:statePath |
                Should -BeFalse
        }

        It 'keeps legacy repository configuration working' {
            $legacy = [ordered]@{
                repository = [ordered]@{
                    localPath = $script:repositoryA
                    slug = 'owner/repo-a'
                    expectedOrigins = @('https://github.com/owner/repo-a.git')
                    baseBranch = 'main'
                }
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
                    minimumCliVersion = $null
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
                    mode = 'observe'
                    pollSeconds = 30
                    timeoutSeconds = 300
                    autoFixAttempts = 0
                }
                reviewFeedback = [ordered]@{
                    enabled = $true
                    confirmBeforeRun = $true
                    trustedAssociations = @('OWNER')
                }
            }

            $legacy |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM

            $selection = Get-RepoFlowRepositorySelection `
                -ConfigPath $script:configPath `
                -CurrentDirectory $TestDrive

            $selection.Source | Should -Be 'legacy'
            $selection.Repository.slug | Should -Be 'owner/repo-a'
        }
    }
}

Describe 'RepoFlow repository dispatcher and help' {
    InModuleScope RepoFlow {
        It 'routes repo list' {
            Mock Invoke-RepoFlowRepositoryListWorkflow { return }

            Invoke-RepoFlow -Area repo -Action list

            Should -Invoke Invoke-RepoFlowRepositoryListWorkflow -Times 1 -Exactly
        }

        It 'forwards explicit repository selection' {
            Mock Invoke-RepoFlowPrStatusWorkflow { return }

            Invoke-RepoFlow `
                -Area pr `
                -Action status `
                -Number 12 `
                -Repo repo-flow

            Should -Invoke Invoke-RepoFlowPrStatusWorkflow `
                -Times 1 `
                -Exactly `
                -ParameterFilter { $Repo -eq 'repo-flow' }
        }

        It 'requires a repository for repo use' {
            {
                Invoke-RepoFlow -Area repo -Action use
            } | Should -Throw '*requires -Repo*'
        }

        It 'documents repository commands' {
            $helpText = Get-RepoFlowHelpText
            $helpText | Should -Match 'repo list'
            $helpText | Should -Match 'repo use'
            $helpText | Should -Match '\-Repo'
        }
    }
}
