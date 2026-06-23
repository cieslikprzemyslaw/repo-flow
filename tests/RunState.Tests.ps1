BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow persisted run state' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:repositoryA = Join-Path $TestDrive 'repo-a'
            $script:repositoryB = Join-Path $TestDrive 'repo-b'
            $script:configPath = Join-Path $TestDrive '.repo-flow.json'
            $script:statePath = Join-Path $TestDrive '.repo-flow.state.json'

            Remove-Item -LiteralPath $script:statePath -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath $TestDrive -Filter '.repo-flow.state.json*.tmp' -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue

            New-Item -ItemType Directory -Path $script:repositoryA -Force | Out-Null
            New-Item -ItemType Directory -Path $script:repositoryB -Force | Out-Null

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

            $config |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM
        }

        It 'migrates legacy repository-selection state while preserving the active repository' {
            Set-Content `
                -LiteralPath $script:statePath `
                -Value '{"activeRepository":"repo-b"}' `
                -Encoding utf8NoBOM

            Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryB `
                -Repository 'repo-b' `
                -RepositorySlug 'owner/repo-b' `
                -Operation 'issue-run' `
                -IssueNumber 4 `
                -Branch 'issue/4-state' `
                -BaseSha ('a' * 40) `
                -HeadSha ('a' * 40) `
                -Phase 'branch-created' `
                -Provider 'codex' `
                -Model 'gpt-5.5' |
                Out-Null

            $selectionState = Read-RepoFlowRepositoryState -ConfigPath $script:configPath
            $runs = Get-RepoFlowRunRecords -ConfigPath $script:configPath

            $selectionState.ActiveRepository | Should -Be 'repo-b'
            $runs.Count | Should -Be 1
        }

        It 'fails safely with an actionable message for corrupt state' {
            Set-Content `
                -LiteralPath $script:statePath `
                -Value '{broken' `
                -Encoding utf8NoBOM

            {
                Get-RepoFlowRunRecords -ConfigPath $script:configPath
            } | Should -Throw '*Move or delete the file and retry*'
        }

        It 'fails safely for an incompatible state schema version' {
            Set-Content `
                -LiteralPath $script:statePath `
                -Value '{"schemaVersion":99,"activeRepository":"repo-a","runs":[]}' `
                -Encoding utf8NoBOM

            {
                Get-RepoFlowRunRecords -ConfigPath $script:configPath
            } | Should -Throw '*schema is unsupported*'
        }

        It 'ignores orphaned temporary files and keeps the last complete state' {
            Write-RepoFlowActiveRepository `
                -ConfigPath $script:configPath `
                -RepositoryName 'repo-a' |
                Out-Null

            Set-Content `
                -LiteralPath "$script:statePath.orphan.tmp" `
                -Value '{broken' `
                -Encoding utf8NoBOM

            $selectionState = Read-RepoFlowRepositoryState -ConfigPath $script:configPath

            $selectionState.ActiveRepository | Should -Be 'repo-a'
        }

        It 'prevents concurrent state writers from silently overlapping' {
            $lock = Open-RepoFlowStateLock -StatePath $script:statePath

            try {
                {
                    Invoke-RepoFlowStateMutation `
                        -ConfigPath $script:configPath `
                        -Update { param($document) $document }
                } | Should -Throw '*could not be locked*'
            }
            finally {
                $lock.Dispose()
            }
        }

        It 'supports multiple repositories and deterministic pruning of terminal runs' {
            $recordA = Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryA `
                -Repository 'repo-a' `
                -RepositorySlug 'owner/repo-a' `
                -Operation 'issue-run' `
                -IssueNumber 4 `
                -Branch 'issue/4-state' `
                -BaseSha ('a' * 40) `
                -HeadSha ('a' * 40) `
                -Phase 'branch-created' `
                -Provider 'codex' `
                -Model 'gpt-5.5'
            $recordB = Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryB `
                -Repository 'repo-b' `
                -RepositorySlug 'owner/repo-b' `
                -Operation 'pr-repair' `
                -IssueNumber 9 `
                -Branch 'repair/9' `
                -PullRequestNumber 19 `
                -BaseSha ('b' * 40) `
                -HeadSha ('b' * 40) `
                -Phase 'repair-started' `
                -Provider 'codex' `
                -Model 'gpt-5.5'

            Complete-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RunId ([string]$recordA.runId) `
                -Outcome 'completed'
            Set-RepoFlowRunPaused `
                -ConfigPath $script:configPath `
                -RunId ([string]$recordB.runId) `
                -PauseReason 'waiting for manual review'

            $removed = Prune-RepoFlowRunRecords `
                -ConfigPath $script:configPath `
                -Repository 'repo-a'
            $remaining = Get-RepoFlowRunRecords -ConfigPath $script:configPath

            $removed | Should -Be 1
            $remaining.Count | Should -Be 1
            $remaining[0].repository | Should -Be 'repo-b'
            $remaining[0].lastSafePhase | Should -Be 'repair-started'
        }

        It 'retains the last safe phase while a newer phase is in progress' {
            $record = Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryA `
                -Repository 'repo-a' `
                -RepositorySlug 'owner/repo-a' `
                -Operation 'issue-run' `
                -IssueNumber 4 `
                -Branch 'issue/4-state' `
                -BaseSha ('a' * 40) `
                -HeadSha ('a' * 40) `
                -Phase 'branch-created' `
                -Provider 'codex' `
                -Model 'gpt-5.5'

            Set-RepoFlowRunCheckpoint `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId) `
                -CurrentPhase 'agent-running'

            $updated = Get-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId)

            $updated.currentPhase | Should -Be 'agent-running'
            $updated.lastSafePhase | Should -Be 'branch-created'
        }

        It 'rejects invalid timestamps before repository state is used' {
            $record = Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryA `
                -Repository 'repo-a' `
                -RepositorySlug 'owner/repo-a' `
                -Operation 'issue-run' `
                -IssueNumber 4 `
                -Branch 'issue/4-state' `
                -BaseSha ('a' * 40) `
                -HeadSha ('a' * 40) `
                -Phase 'branch-created' `
                -Provider 'codex' `
                -Model 'gpt-5.5'

            $state = Get-Content -LiteralPath $script:statePath -Raw |
                ConvertFrom-Json
            $state.runs[0].updatedAtUtc = 'not-a-timestamp'
            $state |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:statePath -Encoding utf8NoBOM

            {
                Read-RepoFlowRepositoryState -ConfigPath $script:configPath
            } | Should -Throw '*invalid or incompatible run record*'
        }

        It 'rejects inconsistent completed run records' {
            $record = Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryA `
                -Repository 'repo-a' `
                -RepositorySlug 'owner/repo-a' `
                -Operation 'issue-run' `
                -IssueNumber 4 `
                -Branch 'issue/4-state' `
                -BaseSha ('a' * 40) `
                -HeadSha ('a' * 40) `
                -Phase 'branch-created' `
                -Provider 'codex' `
                -Model 'gpt-5.5'

            $state = Get-Content -LiteralPath $script:statePath -Raw |
                ConvertFrom-Json
            $state.runs[0].status = 'completed'
            $state |
                ConvertTo-Json -Depth 20 |
                Set-Content -LiteralPath $script:statePath -Encoding utf8NoBOM

            {
                Get-RepoFlowRunRecords -ConfigPath $script:configPath
            } | Should -Throw '*invalid or incompatible run record*'
        }

        It 'clears stale CI identifiers when empty arrays are explicitly checkpointed' {
            $record = Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryA `
                -Repository 'repo-a' `
                -RepositorySlug 'owner/repo-a' `
                -Operation 'issue-run' `
                -IssueNumber 4 `
                -Branch 'issue/4-state' `
                -BaseSha ('a' * 40) `
                -HeadSha ('a' * 40) `
                -Phase 'branch-created' `
                -Provider 'codex' `
                -Model 'gpt-5.5'

            Set-RepoFlowRunCheckpoint `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId) `
                -CurrentPhase 'ci-failed' `
                -CiRunIds @('300') `
                -CiJobIds @('900')

            Set-RepoFlowRunCheckpoint `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId) `
                -CurrentPhase 'ci-pending' `
                -CiRunIds @() `
                -CiJobIds @()

            $updated = Get-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId)

            @($updated.ciRunIds).Count | Should -Be 0
            @($updated.ciJobIds).Count | Should -Be 0
        }

        It 'stores a bounded safe pause reason instead of raw output' {
            $record = Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryA `
                -Repository 'repo-a' `
                -RepositorySlug 'owner/repo-a' `
                -Operation 'issue-run' `
                -IssueNumber 4 `
                -Branch 'issue/4-state' `
                -BaseSha ('a' * 40) `
                -HeadSha ('a' * 40) `
                -Phase 'issue-agent-running' `
                -Provider 'codex' `
                -Model 'gpt-5.5'

            Set-RepoFlowRunPaused `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId) `
                -PauseReason "Agent failed: token=super-secret`nWrite-Host evil"

            $updated = Get-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId)

            $updated.pauseReason | Should -Match 'coding-agent failure'
            $updated.pauseReason | Should -Not -Match 'super-secret'
            $updated.pauseReason | Should -Not -Match 'Write-Host'
            $updated.pauseReason.Length | Should -BeLessThan 300
        }

        It 'reopens a terminal run only through the explicit resume mutation' {
            $record = Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryA `
                -Repository 'repo-a' `
                -RepositorySlug 'owner/repo-a' `
                -Operation 'issue-run' `
                -IssueNumber 5 `
                -Branch 'feature/5-resume' `
                -BaseSha ('a' * 40) `
                -HeadSha ('b' * 40) `
                -Phase 'ci-failed' `
                -Provider 'codex' `
                -Model 'gpt-5.5'

            Complete-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId) `
                -Outcome 'completed'

            Resume-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId) `
                -CurrentPhase 'ci-failed'

            $updated = Get-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RunId ([string]$record.runId)

            $updated.status | Should -Be 'running'
            $updated.currentPhase | Should -Be 'ci-failed'
            $updated.completedAtUtc | Should -BeNullOrEmpty
            $updated.terminalOutcome | Should -BeNullOrEmpty
            $updated.pauseReason | Should -BeNullOrEmpty
        }

        It 'keeps run records when active repository selection is reset' {
            $record = Start-RepoFlowRunRecord `
                -ConfigPath $script:configPath `
                -RepositoryRoot $script:repositoryA `
                -Repository 'repo-a' `
                -RepositorySlug 'owner/repo-a' `
                -Operation 'issue-run' `
                -IssueNumber 4 `
                -Branch 'issue/4-state' `
                -BaseSha ('a' * 40) `
                -HeadSha ('a' * 40) `
                -Phase 'branch-created' `
                -Provider 'codex' `
                -Model 'gpt-5.5'

            Write-RepoFlowActiveRepository `
                -ConfigPath $script:configPath `
                -RepositoryName 'repo-a' |
                Out-Null

            Remove-RepoFlowActiveRepository `
                -ConfigPath $script:configPath |
                Out-Null

            Test-Path -LiteralPath $script:statePath | Should -BeTrue
            (Read-RepoFlowRepositoryState -ConfigPath $script:configPath) |
                Should -BeNullOrEmpty

            $runs = Get-RepoFlowRunRecords -ConfigPath $script:configPath
            $runs.Count | Should -Be 1
            $runs[0].runId | Should -Be $record.runId
        }
    }
}
