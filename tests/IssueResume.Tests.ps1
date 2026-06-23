BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow deterministic issue resume planning' {
    InModuleScope RepoFlow {
        BeforeAll {
            function New-TestResumeRecord {
                param(
                    [string]$Phase,
                    [string]$Operation = 'issue-run',
                    [string]$Status = 'paused',
                    [string]$HeadSha = ('b' * 40),
                    [string]$BaseSha = ('a' * 40),
                    [AllowNull()]
                    [string]$PrCommentId = $null
                )

                return [pscustomobject]@{
                    runId = 'run-5'
                    operation = $Operation
                    status = $Status
                    repositoryRoot = '/repo'
                    repository = 'flow'
                    repositorySlug = 'owner/repo-flow'
                    issueNumber = 5
                    branch = 'feature/5-deterministic-resume'
                    pullRequestNumber = 15
                    prCommentId = $PrCommentId
                    baseSha = $BaseSha
                    headSha = $HeadSha
                    currentPhase = $Phase
                    lastSafePhase = $Phase
                }
            }

            function New-TestResumeHistory {
                param(
                    [AllowNull()]
                    $Active,
                    [AllowNull()]
                    $Latest = $Active
                )

                return [pscustomobject]@{
                    Active = $Active
                    Latest = $Latest
                    Records = if ($null -eq $Latest) { @() } else { @($Latest) }
                }
            }

            function New-TestBranchState {
                param(
                    [bool]$Dirty = $false,
                    [string]$CurrentBranch = 'feature/5-deterministic-resume',
                    [bool]$LocalExists = $true,
                    [bool]$RemoteExists = $true,
                    [AllowNull()]
                    [string]$LocalSha = ('b' * 40),
                    [AllowNull()]
                    [string]$RemoteSha = ('b' * 40)
                )

                return [pscustomobject]@{
                    Branch = 'feature/5-deterministic-resume'
                    CurrentBranch = $CurrentBranch
                    IsDirty = $Dirty
                    LocalExists = $LocalExists
                    RemoteExists = $RemoteExists
                    LocalSha = $LocalSha
                    RemoteSha = $RemoteSha
                }
            }
        }

        BeforeEach {
            $script:issue = [pscustomobject]@{
                number = 5
                state = 'OPEN'
            }
            $script:config = [pscustomobject]@{
                repository = [pscustomobject]@{ baseBranch = 'main' }
            }
            $script:pullRequest = [pscustomobject]@{
                number = 15
                state = 'OPEN'
                headRefName = 'feature/5-deterministic-resume'
                baseRefName = 'main'
                headRefOid = ('b' * 40)
            }
            $script:ciState = [pscustomobject]@{
                Status = 'pending'
                Checks = @()
            }
        }

        It 'commits changes after the initial agent completed' {
            $record = New-TestResumeRecord -Phase 'issue-agent-completed'
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState -Dirty $true -RemoteExists $false -RemoteSha $null

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $null `
                -CiState $null `
                -TrustedComment $null `
                -Config $script:config

            $plan.Action | Should -Be 'commit-initial-changes'
        }

        It 'reconciles a commit that succeeded before checkpoint persistence' {
            Mock Test-RepoFlowCommitAncestor { return $true }
            Mock Get-RepoFlowCommitCount { return 1 }
            $record = New-TestResumeRecord `
                -Phase 'issue-agent-completed' `
                -HeadSha ('a' * 40) `
                -BaseSha ('a' * 40)
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState `
                -LocalSha ('b' * 40) `
                -RemoteExists $false `
                -RemoteSha $null

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $null `
                -CiState $null `
                -TrustedComment $null `
                -Config $script:config

            $plan.Action | Should -Be 'reconcile-initial-commit'
        }

        It 'pushes after a committed checkpoint when the remote branch is missing' {
            $record = New-TestResumeRecord -Phase 'changes-committed'
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState -RemoteExists $false -RemoteSha $null

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $null `
                -CiState $null `
                -TrustedComment $null `
                -Config $script:config

            $plan.Action | Should -Be 'push-initial-branch'
        }

        It 'does not push twice when local and remote heads already match' {
            $record = New-TestResumeRecord -Phase 'changes-committed'
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $null `
                -CiState $null `
                -TrustedComment $null `
                -Config $script:config

            $plan.Action | Should -Be 'reconcile-initial-push'
        }

        It 'creates a PR only after the pushed branch is validated' {
            $record = New-TestResumeRecord -Phase 'branch-pushed'
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $null `
                -CiState $null `
                -TrustedComment $null `
                -Config $script:config

            $plan.Action | Should -Be 'create-pull-request'
        }

        It 'adopts an existing PR instead of creating a duplicate' {
            $record = New-TestResumeRecord -Phase 'branch-pushed'
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $script:pullRequest `
                -CiState $script:ciState `
                -TrustedComment $null `
                -Config $script:config

            $plan.Action | Should -Be 'reconcile-pull-request'
        }

        It 'continues pending and failed CI checkpoints' -ForEach @(
            @{ Phase = 'ci-pending'; Status = 'pending' }
            @{ Phase = 'ci-failed'; Status = 'failed' }
        ) {
            $record = New-TestResumeRecord -Phase $Phase
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState
            $ci = [pscustomobject]@{ Status = $Status; Checks = @() }

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $script:pullRequest `
                -CiState $ci `
                -TrustedComment $null `
                -Config $script:config

            $plan.Action | Should -Be 'observe-ci'
        }

        It 'resumes the exact saved trusted review comment' {
            $record = New-TestResumeRecord `
                -Phase 'review-agent-running' `
                -Operation 'issue-continue-review-feedback' `
                -PrCommentId '9001'
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState -Dirty $true

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $script:pullRequest `
                -CiState $script:ciState `
                -TrustedComment $null `
                -Config $script:config

            $plan.Action | Should -Be 'resume-review-agent'
            $plan.Reason | Should -Match '9001'
        }

        It 'discovers new trusted feedback after a terminal run' {
            $record = New-TestResumeRecord `
                -Phase 'ci-passed' `
                -Status 'completed'
            $history = New-TestResumeHistory -Active $null -Latest $record
            $comment = [pscustomobject]@{ id = 12345 }
            $branch = New-TestBranchState

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $script:pullRequest `
                -CiState ([pscustomobject]@{ Status = 'passed'; Checks = @() }) `
                -TrustedComment $comment `
                -Config $script:config

            $plan.Action | Should -Be 'process-review-feedback'
            $plan.TrustedComment.id | Should -Be 12345
        }

        It 'returns a terminal result for merged and closed PRs' -ForEach @(
            @{ State = 'MERGED' }
            @{ State = 'CLOSED' }
        ) {
            $record = New-TestResumeRecord -Phase 'ci-pending'
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState -LocalExists $false -RemoteExists $false -LocalSha $null -RemoteSha $null
            $pr = $script:pullRequest.PSObject.Copy()
            $pr.state = $State

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $pr `
                -CiState $null `
                -TrustedComment $null `
                -Config $script:config

            $plan.Terminal | Should -BeTrue
            $plan.Action | Should -Be 'terminal'
        }

        It 'stops when dirty changes belong to another branch' {
            $record = New-TestResumeRecord -Phase 'issue-agent-running'
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState -Dirty $true -CurrentBranch 'main'

            {
                New-RepoFlowIssueResumePlan `
                    -RunHistory $history `
                    -Issue $script:issue `
                    -BranchState $branch `
                    -PullRequest $null `
                    -CiState $null `
                    -TrustedComment $null `
                    -Config $script:config
            } | Should -Throw '*will not switch*'
        }

        It 'stops when local, remote, and PR heads conflict' {
            $record = New-TestResumeRecord -Phase 'pull-request-created'
            $history = New-TestResumeHistory -Active $record
            $branch = New-TestBranchState -RemoteSha ('c' * 40)

            {
                New-RepoFlowIssueResumePlan `
                    -RunHistory $history `
                    -Issue $script:issue `
                    -BranchState $branch `
                    -PullRequest $script:pullRequest `
                    -CiState $script:ciState `
                    -TrustedComment $null `
                    -Config $script:config
            } | Should -Throw '*do not agree*'
        }

        It 'reopens legacy terminal CI checkpoints only through an explicit plan rule' {
            $record = New-TestResumeRecord `
                -Phase 'ci-failed' `
                -Status 'completed'
            $history = New-TestResumeHistory -Active $null -Latest $record
            $branch = New-TestBranchState

            $plan = New-RepoFlowIssueResumePlan `
                -RunHistory $history `
                -Issue $script:issue `
                -BranchState $branch `
                -PullRequest $script:pullRequest `
                -CiState ([pscustomobject]@{ Status = 'failed'; Checks = @() }) `
                -TrustedComment $null `
                -Config $script:config

            $plan.Action | Should -Be 'observe-ci'
            $plan.ReopenRun | Should -BeTrue
        }
    }
}

Describe 'RepoFlow trusted feedback discovery for issue resume' {
    InModuleScope RepoFlow {
        It 'selects the latest trusted comment that was not already processed' {
            $config = [pscustomobject]@{
                repository = [pscustomobject]@{ slug = 'owner/repo-flow' }
                reviewFeedback = [pscustomobject]@{
                    enabled = $true
                    trustedAssociations = @('OWNER')
                }
            }
            $pullRequest = [pscustomobject]@{ number = 15 }
            $records = @(
                [pscustomobject]@{ prCommentId = '2' }
            )

            Mock Get-RepoFlowPullRequestComments {
                return @(
                    [pscustomobject]@{
                        id = 1
                        body = 'older'
                        created_at = '2026-06-23T10:00:00Z'
                        author_association = 'OWNER'
                        user = [pscustomobject]@{ type = 'User' }
                    }
                    [pscustomobject]@{
                        id = 2
                        body = 'already processed'
                        created_at = '2026-06-23T11:00:00Z'
                        author_association = 'OWNER'
                        user = [pscustomobject]@{ type = 'User' }
                    }
                    [pscustomobject]@{
                        id = 3
                        body = 'external'
                        created_at = '2026-06-23T12:00:00Z'
                        author_association = 'NONE'
                        user = [pscustomobject]@{ type = 'User' }
                    }
                )
            }

            $comment = Get-RepoFlowLatestUnprocessedTrustedComment `
                -PullRequest $pullRequest `
                -Config $config `
                -RunRecords $records

            $comment.id | Should -Be 1
        }
    }
}
