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
