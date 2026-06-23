BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow PR repair workflow' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:hostOutput = [System.Collections.Generic.List[string]]::new()
            $script:contextDiagnostics = @(
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
            $script:issue = [pscustomobject]@{
                number = 22
                title = 'Fix CI'
                body = "## Acceptance criteria`n`n- [ ] CI passes."
                labels = @()
                url = 'https://example.test/issues/22'
                state = 'OPEN'
            }
            $script:config = [pscustomobject]@{
                repository = [pscustomobject]@{
                    slug = 'owner/repository'
                    baseBranch = 'main'
                }
                ci = [pscustomobject]@{
                    autoFixAttempts = 2
                    timeoutSeconds = 30
                    pollSeconds = 1
                    mode = 'require-passing'
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
                messages = [pscustomobject]@{
                    ciFixCommit = 'Fix CI for #{issueNumber}'
                    initialCommit = '{verb} #{issueNumber}: {issueTitle}'
                    reviewCommit = 'Fix review feedback for #{issueNumber}'
                    pullRequestTitle = '{verb} #{issueNumber}: {issueTitle}'
                }
                git = [pscustomobject]@{
                    signOffCommits = $false
                }
            }
            $script:initialPullRequest = [pscustomobject]@{
                number = 116
                title = 'Fix CI'
                url = 'https://example.test/pull/116'
                state = 'OPEN'
                baseRefName = 'main'
                headRefName = 'repair/116-fix-ci'
                headRefOid = ('a' * 40)
                body = "## Summary`n`nCloses #22"
            }
        }

        It 'shows the repair plan without applying changes' {
            Mock New-RepoFlowContext {
                [pscustomobject]@{
                    RepositoryRoot = 'C:\repo'
                    Config = $script:config
                    RepositorySelection = $null
                }
            }
            Mock Get-RepoFlowPullRequest { $script:initialPullRequest }
            Mock Get-RepoFlowPullRequestIssueNumber { 22 }
            Mock Get-RepoFlowIssue { $script:issue }
            Mock Get-RepoFlowCurrentBranch { 'repair/116-fix-ci' }
            Mock Get-RepoFlowCommitHash { 'a' * 40 }
            Mock Get-RepoFlowWorkingTreeStatus { '' }
            Mock Get-RepoFlowPrCheckState {
                [pscustomobject]@{
                    Status = 'failed'
                    Checks = @(
                        [pscustomobject]@{
                            name = 'Validate'
                            bucket = 'fail'
                            link = 'https://example.test/run/1'
                        }
                    )
                }
            }
            Mock Get-RepoFlowPullRequestChangedFiles { @('src/app/page.tsx') }
            Mock Get-RepoFlowPullRequestDiff { 'diff --git a/src/app/page.tsx b/src/app/page.tsx' }
            Mock Write-RepoFlowFailedCiContext {
                [pscustomobject]@{
                    OutputPath = 'C:\temp\repair.md'
                    FailedChecks = @(
                        [pscustomobject]@{
                            name = 'Validate'
                            bucket = 'fail'
                            link = 'https://example.test/run/1'
                        }
                    )
                    Diagnostics = $script:contextDiagnostics
                }
            }
            Mock Invoke-RepoFlowAgent { return }
            Mock Complete-RepoFlowCommit { return }
            Mock Push-RepoFlowBranch { return }
            Mock Write-Host {
                param($Object)
                if ($PSBoundParameters.ContainsKey('Object')) {
                    $script:hostOutput.Add([string]$Object)
                }
            }

            Invoke-RepoFlowPrRepairWorkflow -Number 116

            ($script:hostOutput -join [Environment]::NewLine) | Should -Match 'PR:\s+#116'
            ($script:hostOutput -join [Environment]::NewLine) | Should -Match 'Head:'
            ($script:hostOutput -join [Environment]::NewLine) | Should -Match 'Failed checks:'
            ($script:hostOutput -join [Environment]::NewLine) | Should -Match 'Diagnostics:'
            ($script:hostOutput -join [Environment]::NewLine) | Should -Match 'Validation:'
            ($script:hostOutput -join [Environment]::NewLine) | Should -Match 'git diff --check'
            ($script:hostOutput -join [Environment]::NewLine) | Should -Match 'Fix CI for #22'

            Should -Invoke Invoke-RepoFlowAgent -Times 0 -Exactly
            Should -Invoke Complete-RepoFlowCommit -Times 0 -Exactly
            Should -Invoke Push-RepoFlowBranch -Times 0 -Exactly
        }

        It 'refuses stale PR heads before repairing' {
            Mock New-RepoFlowContext {
                [pscustomobject]@{
                    RepositoryRoot = 'C:\repo'
                    Config = $script:config
                    RepositorySelection = $null
                }
            }
            Mock Get-RepoFlowPullRequest { $script:initialPullRequest }
            Mock Get-RepoFlowPullRequestIssueNumber { 22 }
            Mock Get-RepoFlowIssue { $script:issue }
            Mock Get-RepoFlowCurrentBranch { 'repair/116-fix-ci' }
            Mock Get-RepoFlowCommitHash { 'b' * 40 }
            Mock Get-RepoFlowWorkingTreeStatus { '' }

            {
                Invoke-RepoFlowPrRepairWorkflow -Number 116 -Apply
            } | Should -Throw '*head changed before repair started*'
        }

        It 'refuses dirty trees before repairing' {
            Mock New-RepoFlowContext {
                [pscustomobject]@{
                    RepositoryRoot = 'C:\repo'
                    Config = $script:config
                    RepositorySelection = $null
                }
            }
            Mock Get-RepoFlowPullRequest { $script:initialPullRequest }
            Mock Get-RepoFlowPullRequestIssueNumber { 22 }
            Mock Get-RepoFlowIssue { $script:issue }
            Mock Get-RepoFlowCurrentBranch { 'repair/116-fix-ci' }
            Mock Get-RepoFlowCommitHash { 'a' * 40 }
            Mock Get-RepoFlowWorkingTreeStatus { ' M dirty.ps1' }

            {
                Invoke-RepoFlowPrRepairWorkflow -Number 116 -Apply
            } | Should -Throw '*clean working tree*'
        }
    }
}
