BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow configuration validation' {
    InModuleScope RepoFlow {
        It 'rejects unknown properties' {
            $object = [pscustomobject]@{
                known = 'value'
                unexpected = 'value'
            }

            {
                Assert-RepoFlowAllowedProperties `
                    -Object $object `
                    -Allowed @('known') `
                    -Path '$.example'
            } | Should -Throw '*$.example.unexpected*'
        }

        It 'rejects non-array values' {
            {
                Assert-RepoFlowArray `
                    -Value 'OWNER' `
                    -Path '$.reviewFeedback.trustedAssociations'
            } | Should -Throw '*must be an array*'
        }

        It 'uses a command-line CI override' {
            $config = [pscustomobject]@{
                ci = [pscustomobject]@{ mode = 'require-passing' }
            }

            Get-RepoFlowEffectiveCiMode -Config $config -Override 'skip' |
                Should -Be 'skip'
        }

        It 'accepts repository path, pre-commit, and merge settings' {
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{
                    localPath = 'C:\repo'
                    slug = 'owner/repository'
                    expectedOrigins = @(
                        'https://github.com/owner/repository.git'
                    )
                    baseBranch = 'main'
                }
                issues = [pscustomobject]@{
                    manifestPath = './issues-manifest.json'
                }
                git = [pscustomobject]@{
                    requireCleanWorkingTree = $true
                    deleteMergedLocalBranches = $true
                    pruneRemoteReferences = $true
                    signOffCommits = $false
                    preCommitFixAttempts = 1
                }
                agent = [pscustomobject]@{
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
                pullRequest = [pscustomobject]@{
                    createDraft = $true
                    templatePath = './.github/pull_request_template.md'
                    mergeMethod = 'squash'
                    deleteBranchOnMerge = $true
                }
                messages = [pscustomobject]@{
                    initialCommit = '{verb} #{issueNumber}: {issueTitle}'
                    reviewCommit = 'Fix review feedback for #{issueNumber}'
                    ciFixCommit = 'Fix CI for #{issueNumber}'
                    pullRequestTitle = '{verb} #{issueNumber}: {issueTitle}'
                }
                ci = [pscustomobject]@{
                    mode = 'require-passing'
                    pollSeconds = 30
                    timeoutSeconds = 1800
                    autoFixAttempts = 1
                }
                reviewFeedback = [pscustomobject]@{
                    enabled = $true
                    confirmBeforeRun = $true
                    trustedAssociations = @('OWNER')
                }
            }

            { Assert-RepoFlowConfiguration -Config $config } |
                Should -Not -Throw
        }

        It 'accepts the claude agent provider' {
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{
                    localPath = 'C:\repo'
                    slug = 'owner/repository'
                    expectedOrigins = @('https://github.com/owner/repository.git')
                    baseBranch = 'main'
                }
                issues = [pscustomobject]@{ manifestPath = './issues-manifest.json' }
                git = [pscustomobject]@{
                    requireCleanWorkingTree = $true
                    deleteMergedLocalBranches = $true
                    pruneRemoteReferences = $true
                    signOffCommits = $false
                    preCommitFixAttempts = 1
                }
                agent = [pscustomobject]@{
                    provider = 'claude'
                    command = 'claude'
                    model = 'claude-sonnet-4-6'
                    minimumCliVersion = $null
                    heartbeatSeconds = 15
                    reasoningEffort = 'medium'
                    ciFixReasoningEffort = 'low'
                    preCommitFixReasoningEffort = 'low'
                    runProjectChecks = $false
                }
                pullRequest = [pscustomobject]@{
                    createDraft = $true
                    templatePath = './.github/pull_request_template.md'
                    mergeMethod = 'squash'
                    deleteBranchOnMerge = $true
                }
                messages = [pscustomobject]@{
                    initialCommit = '{verb} #{issueNumber}: {issueTitle}'
                    reviewCommit = 'Fix review feedback for #{issueNumber}'
                    ciFixCommit = 'Fix CI for #{issueNumber}'
                    pullRequestTitle = '{verb} #{issueNumber}: {issueTitle}'
                }
                ci = [pscustomobject]@{
                    mode = 'observe'
                    pollSeconds = 30
                    timeoutSeconds = 1800
                    autoFixAttempts = 0
                }
                reviewFeedback = [pscustomobject]@{
                    enabled = $true
                    confirmBeforeRun = $true
                    trustedAssociations = @('OWNER')
                }
            }

            { Assert-RepoFlowConfiguration -Config $config } |
                Should -Not -Throw
        }

        It 'rejects unsupported agent providers' {
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{
                    localPath = 'C:\repo'
                    slug = 'owner/repository'
                    expectedOrigins = @('https://github.com/owner/repository.git')
                    baseBranch = 'main'
                }
                issues = [pscustomobject]@{ manifestPath = './issues-manifest.json' }
                git = [pscustomobject]@{
                    requireCleanWorkingTree = $true
                    deleteMergedLocalBranches = $true
                    pruneRemoteReferences = $true
                    signOffCommits = $false
                    preCommitFixAttempts = 1
                }
                agent = [pscustomobject]@{
                    provider = 'other'
                    command = 'other'
                    model = 'example-model'
                    minimumCliVersion = $null
                    heartbeatSeconds = 15
                    reasoningEffort = 'medium'
                    ciFixReasoningEffort = 'low'
                    preCommitFixReasoningEffort = 'low'
                    runProjectChecks = $false
                }
                pullRequest = [pscustomobject]@{
                    createDraft = $true
                    templatePath = './.github/pull_request_template.md'
                    mergeMethod = 'squash'
                    deleteBranchOnMerge = $true
                }
                messages = [pscustomobject]@{
                    initialCommit = '{verb} #{issueNumber}: {issueTitle}'
                    reviewCommit = 'Fix review feedback for #{issueNumber}'
                    ciFixCommit = 'Fix CI for #{issueNumber}'
                    pullRequestTitle = '{verb} #{issueNumber}: {issueTitle}'
                }
                ci = [pscustomobject]@{
                    mode = 'observe'
                    pollSeconds = 30
                    timeoutSeconds = 1800
                    autoFixAttempts = 0
                }
                reviewFeedback = [pscustomobject]@{
                    enabled = $true
                    confirmBeforeRun = $true
                    trustedAssociations = @('OWNER')
                }
            }

            { Assert-RepoFlowConfiguration -Config $config } |
                Should -Throw '*provider*codex or claude*'
        }

        It 'rejects empty agent model values' {
            {
                Assert-RepoFlowString -Value '' -Path '$.agent.model'
            } | Should -Throw '*non-empty string*'
        }

        It 'accepts null and semantic minimum CLI versions' {
            { Assert-RepoFlowNullableSemanticVersionString -Value $null -Path '$.agent.minimumCliVersion' } |
                Should -Not -Throw
            { Assert-RepoFlowNullableSemanticVersionString -Value '1.2.3' -Path '$.agent.minimumCliVersion' } |
                Should -Not -Throw
        }

        It 'rejects invalid minimum CLI versions' {
            {
                Assert-RepoFlowNullableSemanticVersionString `
                    -Value '1.2' `
                    -Path '$.agent.minimumCliVersion'
            } | Should -Throw '*semantic version*'
        }

        It 'rejects unsupported merge methods' {
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{
                    localPath = 'C:\repo'
                    slug = 'owner/repository'
                    expectedOrigins = @('https://github.com/owner/repository.git')
                    baseBranch = 'main'
                }
                issues = [pscustomobject]@{ manifestPath = './issues-manifest.json' }
                git = [pscustomobject]@{
                    requireCleanWorkingTree = $true
                    deleteMergedLocalBranches = $true
                    pruneRemoteReferences = $true
                    signOffCommits = $false
                    preCommitFixAttempts = 1
                }
                agent = [pscustomobject]@{
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
                pullRequest = [pscustomobject]@{
                    createDraft = $true
                    templatePath = './.github/pull_request_template.md'
                    mergeMethod = 'banana'
                    deleteBranchOnMerge = $true
                }
                messages = [pscustomobject]@{
                    initialCommit = '{verb} #{issueNumber}: {issueTitle}'
                    reviewCommit = 'Fix review feedback for #{issueNumber}'
                    ciFixCommit = 'Fix CI for #{issueNumber}'
                    pullRequestTitle = '{verb} #{issueNumber}: {issueTitle}'
                }
                ci = [pscustomobject]@{
                    mode = 'require-passing'
                    pollSeconds = 30
                    timeoutSeconds = 1800
                    autoFixAttempts = 1
                }
                reviewFeedback = [pscustomobject]@{
                    enabled = $true
                    confirmBeforeRun = $true
                    trustedAssociations = @('OWNER')
                }
            }

            { Assert-RepoFlowConfiguration -Config $config } |
                Should -Throw '*mergeMethod*'
        }
    }
}
