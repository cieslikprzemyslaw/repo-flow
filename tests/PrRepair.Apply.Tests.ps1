BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow PR repair apply workflow' {
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

        It 'stops without pushing when local validation fails' {
            $script:workingTreeCalls = 0

            Mock New-RepoFlowContext {
                [pscustomobject]@{
                    RepositoryRoot = 'C:\repo'
                    Config = $script:config
                    RepositorySelection = [pscustomobject]@{
                        Registry = [pscustomobject]@{
                            ConfigPath = (Join-Path $TestDrive '.repo-flow.json')
                        }
                        Repository = [pscustomobject]@{
                            name = 'repo'
                        }
                    }                }
            }
            Mock Get-RepoFlowPullRequest { $script:initialPullRequest }
            Mock Get-RepoFlowPullRequestIssueNumber { 22 }
            Mock Get-RepoFlowIssue { $script:issue }
            Mock Get-RepoFlowCurrentBranch { 'repair/116-fix-ci' }
            Mock Get-RepoFlowCommitHash { 'a' * 40 }
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
            Mock Invoke-RepoFlowAgent {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                    Usage = New-RepoFlowAgentUsage
                    DurationSeconds = 0
                }
            }
            Mock Get-RepoFlowAgentFinalMessage { 'done' }
            Mock Get-RepoFlowWorkingTreeStatus {
                $script:workingTreeCalls++

                if ($script:workingTreeCalls -eq 1) {
                    return ''
                }

                return ' M src/app/page.tsx'
            }
            Mock Invoke-RepoFlowLocalValidation {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = 'validation failed'
                }
            }
            Mock Complete-RepoFlowCommit { return }
            Mock Push-RepoFlowBranch { return }

            {
                Invoke-RepoFlowPrRepairWorkflow -Number 116 -Apply
            } | Should -Throw '*Local validation failed*'

            Should -Invoke Complete-RepoFlowCommit -Times 0 -Exactly
            Should -Invoke Push-RepoFlowBranch -Times 0 -Exactly
        }

        It 'stops on agent failure without committing' {
            Mock New-RepoFlowContext {
                [pscustomobject]@{
                    RepositoryRoot = 'C:\repo'
                    Config = $script:config
                    RepositorySelection = [pscustomobject]@{
                        Registry = [pscustomobject]@{
                            ConfigPath = (Join-Path $TestDrive '.repo-flow.json')
                        }
                        Repository = [pscustomobject]@{
                            name = 'repo'
                        }
                    }                }
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
            Mock Invoke-RepoFlowAgent {
                [pscustomobject]@{
                    ExitCode = 1
                    Text = 'agent failed'
                    Usage = New-RepoFlowAgentUsage
                    DurationSeconds = 0
                }
            }
            Mock Complete-RepoFlowCommit { return }
            Mock Push-RepoFlowBranch { return }

            {
                Invoke-RepoFlowPrRepairWorkflow -Number 116 -Apply
            } | Should -Throw '*agent failed*'

            Should -Invoke Complete-RepoFlowCommit -Times 0 -Exactly
            Should -Invoke Push-RepoFlowBranch -Times 0 -Exactly
        }

        It 'retries a failed CI repair cycle up to the configured limit' {
            $script:pullRequestCalls = 0
            $script:commitHashCalls = 0
            $script:agentCalls = 0
            $script:validationCalls = 0
            $script:commitCalls = 0
            $script:pushCalls = 0
            $script:waitHeadCalls = 0
            $script:waitCheckCalls = 0
            $script:workingTreeCalls = 0

            Mock New-RepoFlowContext {
                [pscustomobject]@{
                    RepositoryRoot = 'C:\repo'
                    Config = $script:config
                    RepositorySelection = [pscustomobject]@{
                        Registry = [pscustomobject]@{
                            ConfigPath = (Join-Path $TestDrive '.repo-flow.json')
                        }
                        Repository = [pscustomobject]@{
                            name = 'repo'
                        }
                    }                }
            }
            Mock Get-RepoFlowPullRequestIssueNumber { 22 }
            Mock Get-RepoFlowIssue { $script:issue }
            Mock Get-RepoFlowCurrentBranch { 'repair/116-fix-ci' }
            Mock Get-RepoFlowWorkingTreeStatus {
                $script:workingTreeCalls++

                if ($script:workingTreeCalls -eq 1) {
                    return ''
                }

                return ' M src/app/page.tsx'
            }
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
            Mock Invoke-RepoFlowAgent {
                $script:agentCalls++
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                    Usage = New-RepoFlowAgentUsage
                    DurationSeconds = 0
                }
            }
            Mock Get-RepoFlowAgentFinalMessage { 'done' }
            Mock Invoke-RepoFlowLocalValidation {
                $script:validationCalls++
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                }
            }
            Mock Complete-RepoFlowCommit {
                $script:commitCalls++
                return
            }
            Mock Push-RepoFlowBranch {
                $script:pushCalls++
                return
            }
            Mock Wait-RepoFlowPullRequestHead {
                $script:waitHeadCalls++

                if ($script:waitHeadCalls -eq 1) {
                    return [pscustomobject]@{
                        number = 116
                        title = 'Fix CI'
                        url = 'https://example.test/pull/116'
                        state = 'OPEN'
                        baseRefName = 'main'
                        headRefName = 'repair/116-fix-ci'
                        headRefOid = ('b' * 40)
                        body = "## Summary`n`nCloses #22"
                    }
                }

                return [pscustomobject]@{
                    number = 116
                    title = 'Fix CI'
                    url = 'https://example.test/pull/116'
                    state = 'OPEN'
                    baseRefName = 'main'
                    headRefName = 'repair/116-fix-ci'
                    headRefOid = ('c' * 40)
                    body = "## Summary`n`nCloses #22"
                }
            }
            Mock Wait-RepoFlowPrChecks {
                $script:waitCheckCalls++
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
            Mock Get-RepoFlowPullRequest {
                $script:pullRequestCalls++

                if ($script:pullRequestCalls -lt 3) {
                    return [pscustomobject]@{
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

                return [pscustomobject]@{
                    number = 116
                    title = 'Fix CI'
                    url = 'https://example.test/pull/116'
                    state = 'OPEN'
                    baseRefName = 'main'
                    headRefName = 'repair/116-fix-ci'
                    headRefOid = ('b' * 40)
                    body = "## Summary`n`nCloses #22"
                }
            }
            Mock Get-RepoFlowCommitHash {
                $script:commitHashCalls++

                switch ($script:commitHashCalls) {
                    1 { return ('a' * 40) }
                    2 { return ('b' * 40) }
                    3 { return ('b' * 40) }
                    default { return ('c' * 40) }
                }
            }

            {
                Invoke-RepoFlowPrRepairWorkflow -Number 116 -Apply
            } | Should -Throw '*after 2 repair attempt(s)*'

            Should -Invoke Invoke-RepoFlowAgent -Times 2 -Exactly
            Should -Invoke Complete-RepoFlowCommit -Times 2 -Exactly
            Should -Invoke Push-RepoFlowBranch -Times 2 -Exactly
            Should -Invoke Wait-RepoFlowPrChecks -Times 2 -Exactly
        }

        It 'completes a clean repair cycle without merging' {
            $script:pullRequestCalls = 0
            $script:workingTreeCalls = 0
            $script:commitHashCalls = 0

            Mock New-RepoFlowContext {
                [pscustomobject]@{
                    RepositoryRoot = 'C:\repo'
                    Config = $script:config
                    RepositorySelection = [pscustomobject]@{
                        Registry = [pscustomobject]@{
                            ConfigPath = (Join-Path $TestDrive '.repo-flow.json')
                        }
                        Repository = [pscustomobject]@{
                            name = 'repo'
                        }
                    }                }
            }
            Mock Get-RepoFlowPullRequestIssueNumber { 22 }
            Mock Get-RepoFlowIssue { $script:issue }
            Mock Get-RepoFlowCurrentBranch { 'repair/116-fix-ci' }
            Mock Get-RepoFlowWorkingTreeStatus {
                $script:workingTreeCalls++

                if ($script:workingTreeCalls -eq 1) {
                    return ''
                }

                return ' M src/app/page.tsx'
            }
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
            Mock Invoke-RepoFlowAgent {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                    Usage = New-RepoFlowAgentUsage
                    DurationSeconds = 0
                }
            }
            Mock Get-RepoFlowAgentFinalMessage { 'done' }
            Mock Get-RepoFlowPullRequest {
                $script:pullRequestCalls++

                return [pscustomobject]@{
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
            Mock Get-RepoFlowCommitHash {
                $script:commitHashCalls++

                if ($script:commitHashCalls -eq 1) {
                    return ('a' * 40)
                }

                return ('b' * 40)
            }
            Mock Invoke-RepoFlowLocalValidation {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                }
            }
            Mock Complete-RepoFlowCommit { return }
            Mock Push-RepoFlowBranch { return }
            Mock Wait-RepoFlowPullRequestHead {
                [pscustomobject]@{
                    number = 116
                    title = 'Fix CI'
                    url = 'https://example.test/pull/116'
                    state = 'OPEN'
                    baseRefName = 'main'
                    headRefName = 'repair/116-fix-ci'
                    headRefOid = ('b' * 40)
                    body = "## Summary`n`nCloses #22"
                }
            }
            Mock Wait-RepoFlowPrChecks {
                [pscustomobject]@{
                    Status = 'passed'
                    Checks = @(
                        [pscustomobject]@{
                            name = 'Validate'
                            bucket = 'pass'
                            link = 'https://example.test/run/1'
                        }
                    )
                }
            }
            Mock Merge-RepoFlowPullRequest { }

            Invoke-RepoFlowPrRepairWorkflow -Number 116 -Apply

            Should -Invoke Complete-RepoFlowCommit -Times 1 -Exactly
            Should -Invoke Push-RepoFlowBranch -Times 1 -Exactly
            Should -Invoke Wait-RepoFlowPullRequestHead -Times 1 -Exactly
            Should -Invoke Wait-RepoFlowPrChecks -Times 1 -Exactly
            Should -Invoke Merge-RepoFlowPullRequest -Times 0 -Exactly
            Should -Invoke Get-RepoFlowPullRequest -Times 2 -Exactly
        }
    }
}
