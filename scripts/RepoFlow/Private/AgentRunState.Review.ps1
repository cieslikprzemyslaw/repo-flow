function Read-RepoFlowAgentRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    return Get-RepoFlowLatestRepositoryRunRecord `
        -ConfigPath $ConfigPath `
        -RepositoryRoot $RepositoryRoot `
        -Operation 'issue-continue-review-feedback'
}

function Assert-RepoFlowReviewResumeAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [long]$PrCommentId
    )

    Assert-RepoFlowNoGitOperationInProgress -RepositoryRoot $RepositoryRoot

    $currentBranch = Get-RepoFlowCurrentBranch

    if ($currentBranch -ne $Branch) {
        throw (
            "Resume requires the issue branch '$Branch' to be checked out. " +
            "Current branch: '$currentBranch'. RepoFlow will not switch " +
            'branches while preserving a dirty working tree.'
        )
    }

    $status = Get-RepoFlowWorkingTreeStatus

    if ([string]::IsNullOrWhiteSpace($status)) {
        throw (
            'Resume requires existing uncommitted changes from an ' +
            'interrupted agent run, but the working tree is clean.'
        )
    }

    $currentHead = Get-RepoFlowCommitHash
    $remoteHead = Get-RepoFlowRemoteBranchCommitHash -Branch $Branch

    if ($currentHead -ne $remoteHead) {
        throw (
            "Resume requires local HEAD to match origin/$Branch. " +
            'Commit, push, or reconcile local commits before resuming.'
        )
    }

    $state = Read-RepoFlowAgentRunState `
        -ConfigPath $ConfigPath `
        -RepositoryRoot $RepositoryRoot

    if ($null -eq $state) {
        Write-Warning (
            'No previous RepoFlow checkpoint exists. -Resume will explicitly ' +
            'adopt the current uncommitted changes after validating the branch ' +
            'and remote HEAD. Review git status before continuing.'
        )
        return $null
    }

    $expectedRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $stateRoot = [System.IO.Path]::GetFullPath([string]$state.repositoryRoot)

    $rootsMatch = [string]::Equals(
        $stateRoot,
        $expectedRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if (-not $rootsMatch) {
        throw 'The interrupted-run checkpoint belongs to a different repository root.'
    }

    if ([string]$state.repository -ne $Repository) {
        throw 'The interrupted-run checkpoint belongs to a different repository.'
    }

    if ([string]$state.branch -ne $Branch) {
        throw 'The interrupted-run checkpoint belongs to a different branch.'
    }

    if ([int]$state.issueNumber -ne $IssueNumber) {
        throw 'The interrupted-run checkpoint belongs to a different issue.'
    }

    if ([int]$state.pullRequestNumber -ne $PullRequestNumber) {
        throw 'The interrupted-run checkpoint belongs to a different pull request.'
    }

    if ([string]$state.prCommentId -ne [string]$PrCommentId) {
        throw (
            'The selected PR comment does not match the interrupted-run ' +
            'checkpoint. Resume with the original -PrCommentId.'
        )
    }

    if ([string]$state.baseSha -ne $currentHead) {
        throw (
            'HEAD changed after the interrupted run started. RepoFlow will ' +
            'not combine the saved working tree with a different baseline.'
        )
    }

    if ([string]$state.status -notin @('running', 'paused')) {
        throw "The agent-run checkpoint cannot be resumed from status '$($state.status)'."
    }

    return $state
}

function Start-RepoFlowReviewAgentRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$RepositorySlug,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [long]$PrCommentId,

        [Parameter(Mandatory)]
        $Config,

        [switch]$AdoptedExistingChanges
    )

    $existing = if ($AdoptedExistingChanges) {
        Read-RepoFlowAgentRunState `
            -ConfigPath $ConfigPath `
            -RepositoryRoot $RepositoryRoot
    }
    else {
        $null
    }

    $attempts = if ($null -eq $existing) {
        1
    }
    else {
        [int]$existing.reviewAttemptCount + 1
    }

    if ($null -ne $existing) {
        Set-RepoFlowRunCheckpoint `
            -ConfigPath $ConfigPath `
            -RunId ([string]$existing.runId) `
            -CurrentPhase 'review-agent-running' `
            -HeadSha (Get-RepoFlowCommitHash) `
            -ReviewAttemptCount $attempts

        return Get-RepoFlowRunRecord `
            -ConfigPath $ConfigPath `
            -RunId ([string]$existing.runId)
    }

    return Start-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RepositoryRoot $RepositoryRoot `
        -Repository $Repository `
        -RepositorySlug $RepositorySlug `
        -Operation 'issue-continue-review-feedback' `
        -IssueNumber $IssueNumber `
        -Branch $Branch `
        -PullRequestNumber $PullRequestNumber `
        -PrCommentId ([string]$PrCommentId) `
        -BaseSha (Get-RepoFlowCommitHash) `
        -HeadSha (Get-RepoFlowCommitHash) `
        -Phase 'review-agent-running' `
        -Provider ([string]$Config.agent.provider) `
        -Model ([string]$Config.agent.model) `
        -ReviewAttemptCount $attempts
}

function Set-RepoFlowAgentRunInterrupted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$ErrorMessage
    )

    $state = Read-RepoFlowAgentRunState `
        -ConfigPath $ConfigPath `
        -RepositoryRoot $RepositoryRoot

    if ($null -eq $state) {
        return
    }

    Set-RepoFlowRunPaused `
        -ConfigPath $ConfigPath `
        -RunId ([string]$state.runId) `
        -CurrentPhase ([string]$state.currentPhase) `
        -PauseReason $ErrorMessage
}

function Show-RepoFlowRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RunRecord
    )

    Write-Host "Run ID:          $($RunRecord.runId)"
    Write-Host "Operation:       $($RunRecord.operation)"
    Write-Host "Status:          $($RunRecord.status)"
    Write-Host "Repository:      $($RunRecord.repository)"
    Write-Host "GitHub:          $($RunRecord.repositorySlug)"
    Write-Host "Issue:           #$($RunRecord.issueNumber)"
    Write-Host "Branch:          $($RunRecord.branch)"
    Write-Host "PR:              $($RunRecord.pullRequestNumber)"
    Write-Host "Current phase:   $($RunRecord.currentPhase)"
    Write-Host "Last safe phase: $($RunRecord.lastSafePhase)"
    Write-Host "Provider/model:  $($RunRecord.provider) / $($RunRecord.model)"
    Write-Host "Base SHA:        $($RunRecord.baseSha)"
    Write-Host "Head SHA:        $($RunRecord.headSha)"
    Write-Host "Review attempts: $($RunRecord.reviewAttemptCount)"
    Write-Host "Repair attempts: $($RunRecord.repairAttemptCount)"
    Write-Host "Updated:         $($RunRecord.updatedAtUtc)"

    if (-not [string]::IsNullOrWhiteSpace([string]$RunRecord.pauseReason)) {
        Write-Host "Pause reason:    $($RunRecord.pauseReason)"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$RunRecord.terminalOutcome)) {
        Write-Host "Outcome:         $($RunRecord.terminalOutcome)"
    }
}

function Invoke-RepoFlowRunListWorkflow {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,

        [Alias('Repository', 'RepositoryName')]
        [string]$Repo
    )

    $resolvedRepository = $null

    if (-not [string]::IsNullOrWhiteSpace($Repo)) {
        $selection = Get-RepoFlowRepositorySelection `
            -ConfigPath $ConfigPath `
            -RepositoryName $Repo
        $resolvedRepository = [string]$selection.Repository.name
    }

    $registry = Get-RepoFlowRepositoryRegistry -ConfigPath $ConfigPath
    $records = Get-RepoFlowRunRecords `
        -ConfigPath $registry.ConfigPath `
        -Repository $resolvedRepository

    if ($records.Count -eq 0) {
        Write-Host 'No persisted RepoFlow runs were found.'
        return
    }

    Write-Host 'Persisted runs'
    Write-Host ''

    foreach ($record in $records) {
        $summary = (
            '{0} [{1}] {2} #{3} {4} ({5})' -f
            $record.runId,
            $record.status,
            $record.repository,
            $record.issueNumber,
            $record.currentPhase,
            $record.updatedAtUtc
        )
        Write-Host $summary
    }
}

function Invoke-RepoFlowRunShowWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RunId,

        [string]$ConfigPath
    )

    $registry = Get-RepoFlowRepositoryRegistry -ConfigPath $ConfigPath
    $record = Get-RepoFlowRunRecord `
        -ConfigPath $registry.ConfigPath `
        -RunId $RunId

    if ($null -eq $record) {
        throw "Unknown RepoFlow run record: $RunId"
    }

    Show-RepoFlowRunRecord -RunRecord $record
}

function Invoke-RepoFlowRunCompleteWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RunId,

        [switch]$Apply,

        [ValidateSet('completed', 'abandoned')]
        [string]$Outcome = 'completed',

        [string]$ConfigPath
    )

    $registry = Get-RepoFlowRepositoryRegistry -ConfigPath $ConfigPath
    $record = Get-RepoFlowRunRecord `
        -ConfigPath $registry.ConfigPath `
        -RunId $RunId

    if ($null -eq $record) {
        throw "Unknown RepoFlow run record: $RunId"
    }

    Show-RepoFlowRunRecord -RunRecord $record
    Write-Host ''

    if (-not $Apply) {
        Write-Host 'PLAN ONLY - the run record was not changed.'
        Write-Host "Run again with -Apply to mark this run as '$Outcome'."
        return
    }

    Complete-RepoFlowRunRecord `
        -ConfigPath $registry.ConfigPath `
        -RunId $RunId `
        -Outcome $Outcome

    Write-Host "Run record updated: $RunId ($Outcome)"
}

function Invoke-RepoFlowRunPruneWorkflow {
    [CmdletBinding()]
    param(
        [switch]$Apply,

        [string]$ConfigPath,

        [Alias('Repository', 'RepositoryName')]
        [string]$Repo
    )

    $resolvedRepository = $null

    if (-not [string]::IsNullOrWhiteSpace($Repo)) {
        $selection = Get-RepoFlowRepositorySelection `
            -ConfigPath $ConfigPath `
            -RepositoryName $Repo
        $resolvedRepository = [string]$selection.Repository.name
    }

    $registry = Get-RepoFlowRepositoryRegistry -ConfigPath $ConfigPath
    $records = @(
        Get-RepoFlowRunRecords `
            -ConfigPath $registry.ConfigPath `
            -Repository $resolvedRepository |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.terminalOutcome)
        }
    )

    Write-Host "Prunable run records: $($records.Count)"

    if (-not $Apply) {
        Write-Host 'PLAN ONLY - terminal run records were not removed.'
        Write-Host 'Run again with -Apply to prune completed and abandoned runs.'
        return
    }

    $removed = Prune-RepoFlowRunRecords `
        -ConfigPath $registry.ConfigPath `
        -Repository $resolvedRepository

    Write-Host "Pruned run records: $removed"
}
