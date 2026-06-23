BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow issue resume phase coverage' {
    InModuleScope RepoFlow {
        BeforeAll {
            function New-PhaseRecord {
                param(
                    [Parameter(Mandatory)]
                    [string]$Phase,
                    [string]$Operation = 'issue-run',
                    [string]$Status = 'paused',
                    [string]$HeadSha = ('b' * 40),
                    [string]$BaseSha = ('a' * 40),
                    [AllowNull()]
                    [string]$CommentId = $null
                )

                [pscustomobject]@{
                    runId = "run-$Phase"
                    operation = $Operation
                    status = $Status
                    repositoryRoot = '/repo'
                    repository = 'flow'
                    repositorySlug = 'owner/repo-flow'
                    issueNumber = 5
                    branch = 'feature/5-deterministic-resume'
                    pullRequestNumber = 15
                    prCommentId = $CommentId
                    baseSha = $BaseSha
                    headSha = $HeadSha
                    currentPhase = $Phase
                    lastSafePhase = $Phase
                }
            }

            function New-PhaseBranchState {
                param(
                    [bool]$Dirty = $false,
                    [bool]$RemoteExists = $true,
                    [AllowNull()]
                    [string]$LocalSha = ('b' * 40),
                    [AllowNull()]
                    [string]$RemoteSha = ('b' * 40)
                )

                [pscustomobject]@{
                    Branch = 'feature/5-deterministic-resume'
                    CurrentBranch = 'feature/5-deterministic-resume'
                    IsDirty = $Dirty
                    LocalExists = $true
                    RemoteExists = $RemoteExists
                    LocalSha = $LocalSha
                    RemoteSha = $RemoteSha
                }
            }

            function New-PhasePlan {
                param(
                    [Parameter(Mandatory)]
                    $Record,
                    [Parameter(Mandatory)]
                    $BranchState,
                    [AllowNull()]
                    $PullRequest = $null,
                    [AllowNull()]
                    $TrustedComment = $null
                )

                $history = [pscustomobject]@{
                    Active = $Record
                    Latest = $Record
                    Records = @($Record)
                }
                $issue = [pscustomobject]@{ number = 5; state = 'OPEN' }
                $config = [pscustomobject]@{
                    repository = [pscustomobject]@{ baseBranch = 'main' }
                }
                $ciState = [pscustomobject]@{ Status = 'pending'; Checks = @() }

                New-RepoFlowIssueResumePlan `
                    -RunHistory $history `
                    -Issue $issue `
                    -BranchState $BranchState `
                    -PullRequest $PullRequest `
                    -CiState $ciState `
                    -TrustedComment $TrustedComment `
                    -Config $config
            }

            function New-PhasePullRequest {
                param(
                    [string]$State = 'OPEN',
                    [string]$HeadSha = ('b' * 40)
                )

                [pscustomobject]@{
                    number = 15
                    state = $State
                    headRefName = 'feature/5-deterministic-resume'
                    baseRefName = 'main'
                    headRefOid = $HeadSha
                }
            }
        }

        BeforeEach {
            Mock Test-RepoFlowCommitAncestor { return $true }
            Mock Get-RepoFlowCommitCount { return 1 }
        }

        It 'maps every initial workflow checkpoint to the next deterministic action' -ForEach @(
            @{ Phase = 'branch-created'; Dirty = $false; Remote = $false; Local = ('b' * 40); RemoteSha = $null; Pr = $false; Action = 'resume-initial-agent'; Head = ('b' * 40) }
            @{ Phase = 'issue-agent-running'; Dirty = $true; Remote = $false; Local = ('b' * 40); RemoteSha = $null; Pr = $false; Action = 'resume-initial-agent'; Head = ('b' * 40) }
            @{ Phase = 'issue-agent-completed'; Dirty = $true; Remote = $false; Local = ('b' * 40); RemoteSha = $null; Pr = $false; Action = 'commit-initial-changes'; Head = ('b' * 40) }
            @{ Phase = 'issue-agent-completed'; Dirty = $false; Remote = $false; Local = ('c' * 40); RemoteSha = $null; Pr = $false; Action = 'reconcile-initial-commit'; Head = ('b' * 40) }
            @{ Phase = 'changes-committed'; Dirty = $false; Remote = $false; Local = ('b' * 40); RemoteSha = $null; Pr = $false; Action = 'push-initial-branch'; Head = ('b' * 40) }
            @{ Phase = 'changes-committed'; Dirty = $false; Remote = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Pr = $false; Action = 'reconcile-initial-push'; Head = ('b' * 40) }
            @{ Phase = 'branch-pushed'; Dirty = $false; Remote = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Pr = $false; Action = 'create-pull-request'; Head = ('b' * 40) }
            @{ Phase = 'branch-pushed'; Dirty = $false; Remote = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Pr = $true; Action = 'reconcile-pull-request'; Head = ('b' * 40) }
            @{ Phase = 'pull-request-created'; Dirty = $false; Remote = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Pr = $true; Action = 'observe-ci'; Head = ('b' * 40) }
            @{ Phase = 'ci-pending'; Dirty = $false; Remote = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Pr = $true; Action = 'observe-ci'; Head = ('b' * 40) }
            @{ Phase = 'ci-failed'; Dirty = $false; Remote = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Pr = $true; Action = 'observe-ci'; Head = ('b' * 40) }
            @{ Phase = 'ci-passed'; Dirty = $false; Remote = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Pr = $true; Action = 'complete-run'; Head = ('b' * 40) }
            @{ Phase = 'ci-skipped'; Dirty = $false; Remote = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Pr = $true; Action = 'complete-run'; Head = ('b' * 40) }
        ) {
            $head = if ($null -ne $Head) { $Head } else { 'b' * 40 }
            $record = New-PhaseRecord -Phase $Phase -HeadSha $head
            $branch = New-PhaseBranchState `
                -Dirty $Dirty `
                -RemoteExists $Remote `
                -LocalSha $Local `
                -RemoteSha $RemoteSha
            $pr = if ($Pr) { New-PhasePullRequest -HeadSha $RemoteSha } else { $null }

            $plan = New-PhasePlan `
                -Record $record `
                -BranchState $branch `
                -PullRequest $pr

            $plan.Action | Should -Be $Action
        }

        It 'maps every review workflow checkpoint to the next deterministic action' -ForEach @(
            @{ Phase = 'review-agent-running'; Dirty = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Action = 'resume-review-agent'; Head = ('b' * 40) }
            @{ Phase = 'review-agent-completed'; Dirty = $true; Local = ('b' * 40); RemoteSha = ('b' * 40); Action = 'commit-review-changes'; Head = ('b' * 40) }
            @{ Phase = 'review-agent-completed'; Dirty = $false; Local = ('c' * 40); RemoteSha = ('b' * 40); Action = 'reconcile-review-commit'; Head = ('b' * 40) }
            @{ Phase = 'review-committed'; Dirty = $false; Local = ('b' * 40); RemoteSha = ('a' * 40); Action = 'push-review-branch'; Head = ('b' * 40) }
            @{ Phase = 'review-committed'; Dirty = $false; Local = ('b' * 40); RemoteSha = ('b' * 40); Action = 'reconcile-review-push'; Head = ('b' * 40) }
            @{ Phase = 'review-pushed'; Dirty = $false; Local = ('b' * 40); RemoteSha = ('b' * 40); Action = 'observe-ci'; Head = ('b' * 40) }
        ) {
            $record = New-PhaseRecord `
                -Phase $Phase `
                -Operation 'issue-continue-review-feedback' `
                -HeadSha $Head `
                -CommentId '9001'
            $branch = New-PhaseBranchState `
                -Dirty $Dirty `
                -LocalSha $Local `
                -RemoteSha $RemoteSha
            $pr = New-PhasePullRequest -HeadSha $RemoteSha

            $plan = New-PhasePlan `
                -Record $record `
                -BranchState $branch `
                -PullRequest $pr

            $plan.Action | Should -Be $Action
        }

        It 'lets new trusted feedback supersede paused PR and CI phases' -ForEach @(
            @{ Phase = 'pull-request-created'; Operation = 'issue-run' }
            @{ Phase = 'review-pushed'; Operation = 'issue-continue-review-feedback' }
            @{ Phase = 'ci-pending'; Operation = 'issue-run' }
            @{ Phase = 'ci-failed'; Operation = 'issue-run' }
        ) {
            $record = New-PhaseRecord -Phase $Phase -Operation $Operation
            $branch = New-PhaseBranchState
            $comment = [pscustomobject]@{ id = 777 }

            $plan = New-PhasePlan `
                -Record $record `
                -BranchState $branch `
                -PullRequest (New-PhasePullRequest) `
                -TrustedComment $comment

            $plan.Action | Should -Be 'process-review-feedback'
            $plan.AbandonActiveRun | Should -BeTrue
        }
    }
}

Describe 'RepoFlow issue resume conflict coverage' {
    InModuleScope RepoFlow {
        It 'rejects multiple active records for the same local issue workflow' {
            $root = [System.IO.Path]::GetFullPath($TestDrive)
            $records = @(
                [pscustomobject]@{
                    runId = 'run-a'; operation = 'issue-run'; status = 'paused'
                    repositoryRoot = $root; issueNumber = 5
                }
                [pscustomobject]@{
                    runId = 'run-b'; operation = 'issue-continue-review-feedback'; status = 'running'
                    repositoryRoot = $root; issueNumber = 5
                }
            )
            Mock Get-RepoFlowRunRecords { return $records }

            {
                Get-RepoFlowIssueRunHistory `
                    -ConfigPath (Join-Path $TestDrive '.repo-flow.json') `
                    -RepositoryRoot $root `
                    -IssueNumber 5
            } | Should -Throw '*multiple active RepoFlow runs*'
        }

        It 'keeps conflicting repository identity visible instead of hiding the saved record' {
            $root = [System.IO.Path]::GetFullPath($TestDrive)
            $record = [pscustomobject]@{
                runId = 'run-a'; operation = 'issue-run'; status = 'paused'
                repositoryRoot = $root; repository = 'old-name'
                repositorySlug = 'owner/old-repo'; issueNumber = 5
                branch = 'feature/5-deterministic-resume'
            }
            Mock Get-RepoFlowRunRecords { return @($record) }

            $history = Get-RepoFlowIssueRunHistory `
                -ConfigPath (Join-Path $TestDrive '.repo-flow.json') `
                -RepositoryRoot $root `
                -IssueNumber 5

            {
                Assert-RepoFlowResumeRecordIdentity `
                    -RunRecord $history.Active `
                    -RepositoryRoot $root `
                    -Repository 'flow' `
                    -RepositorySlug 'owner/repo-flow' `
                    -IssueNumber 5 `
                    -Branch 'feature/5-deterministic-resume'
            } | Should -Throw '*different configured repository*'
        }

        It 'rejects dirty state after a pushed or PR checkpoint' -ForEach @(
            @{ Phase = 'branch-pushed'; PullRequest = $null }
            @{ Phase = 'pull-request-created'; PullRequest = [pscustomobject]@{
                number = 15; state = 'OPEN'
                headRefName = 'feature/5-deterministic-resume'
                baseRefName = 'main'; headRefOid = ('b' * 40)
            } }
        ) {
            $record = [pscustomobject]@{
                runId = 'run-a'; operation = 'issue-run'; status = 'paused'
                issueNumber = 5; branch = 'feature/5-deterministic-resume'
                currentPhase = $Phase; lastSafePhase = $Phase
                headSha = ('b' * 40); baseSha = ('a' * 40)
            }
            $history = [pscustomobject]@{
                Active = $record; Latest = $record; Records = @($record)
            }
            $branch = [pscustomobject]@{
                Branch = 'feature/5-deterministic-resume'
                CurrentBranch = 'feature/5-deterministic-resume'
                IsDirty = $true; LocalExists = $true; RemoteExists = $true
                LocalSha = ('b' * 40); RemoteSha = ('b' * 40)
            }
            $issue = [pscustomobject]@{ number = 5; state = 'OPEN' }
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{ baseBranch = 'main' }
            }

            {
                New-RepoFlowIssueResumePlan `
                    -RunHistory $history `
                    -Issue $issue `
                    -BranchState $branch `
                    -PullRequest $PullRequest `
                    -CiState $null `
                    -TrustedComment $null `
                    -Config $config
            } | Should -Throw '*clean working tree*'
        }

        It 'returns a terminal PR result even when unrelated local changes exist' {
            $record = [pscustomobject]@{
                runId = 'run-a'; operation = 'issue-run'; status = 'paused'
                issueNumber = 5; branch = 'feature/5-deterministic-resume'
                currentPhase = 'ci-pending'; lastSafePhase = 'ci-pending'
                headSha = ('b' * 40); baseSha = ('a' * 40)
            }
            $history = [pscustomobject]@{
                Active = $record; Latest = $record; Records = @($record)
            }
            $branch = [pscustomobject]@{
                Branch = 'feature/5-deterministic-resume'; CurrentBranch = 'main'
                IsDirty = $true; LocalExists = $false; RemoteExists = $false
                LocalSha = $null; RemoteSha = $null
            }
            $pr = [pscustomobject]@{
                number = 15; state = 'MERGED'
                headRefName = 'feature/5-deterministic-resume'
                baseRefName = 'main'; headRefOid = ('b' * 40)
            }
            $issue = [pscustomobject]@{ number = 5; state = 'CLOSED' }
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{ baseBranch = 'main' }
            }

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $issue `
                -BranchState $branch `
                -PullRequest $pr `
                -CiState $null `
                -TrustedComment $null `
                -Config $config

            $plan.Action | Should -Be 'terminal'
            $plan.Terminal | Should -BeTrue
        }

        It 'rejects a live PR head that is not a descendant of the saved checkpoint' {
            Mock Test-RepoFlowCommitAncestor { return $false }
            $record = [pscustomobject]@{
                runId = 'run-a'; operation = 'issue-run'; status = 'paused'
                issueNumber = 5; branch = 'feature/5-deterministic-resume'
                currentPhase = 'ci-pending'; lastSafePhase = 'ci-pending'
                headSha = ('a' * 40); baseSha = ('0' * 40)
            }
            $history = [pscustomobject]@{
                Active = $record; Latest = $record; Records = @($record)
            }
            $branch = [pscustomobject]@{
                Branch = 'feature/5-deterministic-resume'
                CurrentBranch = 'feature/5-deterministic-resume'
                IsDirty = $false; LocalExists = $true; RemoteExists = $true
                LocalSha = ('b' * 40); RemoteSha = ('b' * 40)
            }
            $pr = [pscustomobject]@{
                number = 15; state = 'OPEN'
                headRefName = 'feature/5-deterministic-resume'
                baseRefName = 'main'; headRefOid = ('b' * 40)
            }
            $issue = [pscustomobject]@{ number = 5; state = 'OPEN' }
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{ baseBranch = 'main' }
            }

            {
                New-RepoFlowIssueResumePlan `
                    -RunHistory $history `
                    -Issue $issue `
                    -BranchState $branch `
                    -PullRequest $pr `
                    -CiState $null `
                    -TrustedComment $null `
                    -Config $config
            } | Should -Throw '*not a descendant*'
        }
    }
}
