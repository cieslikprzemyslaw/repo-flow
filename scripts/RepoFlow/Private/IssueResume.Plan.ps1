function New-RepoFlowIssueResumePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RunHistory,

        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $BranchState,

        [AllowNull()]
        $PullRequest,

        [AllowNull()]
        $CiState,

        [AllowNull()]
        $TrustedComment,

        [Parameter(Mandatory)]
        $Config
    )

    $record = if ($null -ne $RunHistory.Active) {
        $RunHistory.Active
    }
    else {
        $RunHistory.Latest
    }

    if ($null -eq $record) {
        throw (
            "No saved RepoFlow run exists for issue #$($Issue.number). " +
            "Use 'issue run' for the first implementation."
        )
    }

    Assert-RepoFlowResumePullRequestIdentity `
        -PullRequest $PullRequest `
        -Branch ([string]$BranchState.Branch) `
        -BaseBranch ([string]$Config.repository.baseBranch)

    if ($null -ne $PullRequest -and [string]$PullRequest.state -in @('MERGED', 'CLOSED')) {
        return New-RepoFlowResumePlanResult `
            -RunRecord $record `
            -Action 'terminal' `
            -Reason "Pull request #$($PullRequest.number) is already $(([string]$PullRequest.state).ToLowerInvariant())." `
            -PullRequest $PullRequest `
            -TrustedComment $null `
            -CiState $CiState `
            -Terminal
    }

    if ($BranchState.IsDirty -and $BranchState.CurrentBranch -ne $BranchState.Branch) {
        throw (
            "Working tree changes exist on '$($BranchState.CurrentBranch)'. " +
            "RepoFlow will not switch to '$($BranchState.Branch)' or mix " +
            'uncommitted work during resume.'
        )
    }

    if ([string]$Issue.state -ne 'OPEN') {
        throw (
            "Issue #$($Issue.number) is '$($Issue.state)' while its workflow " +
            'is not represented by a merged or closed pull request.'
        )
    }

    if ($null -eq $RunHistory.Active) {
        if ($null -ne $TrustedComment -and $null -ne $PullRequest) {
            return New-RepoFlowResumePlanResult `
                -RunRecord $record `
                -Action 'process-review-feedback' `
                -Reason "Process trusted PR comment #$($TrustedComment.id)." `
                -PullRequest $PullRequest `
                -TrustedComment $TrustedComment `
                -CiState $CiState
        }

        if (
            [string]$record.currentPhase -in @('ci-pending', 'ci-failed') -and
            $null -ne $PullRequest
        ) {
            return New-RepoFlowResumePlanResult `
                -RunRecord $record `
                -Action 'observe-ci' `
                -Reason "Re-check saved $($record.currentPhase) state." `
                -PullRequest $PullRequest `
                -TrustedComment $null `
                -CiState $CiState `
                -ReopenRun
        }

        return New-RepoFlowResumePlanResult `
            -RunRecord $record `
            -Action 'terminal' `
            -Reason 'The latest saved run is terminal and no new trusted review feedback exists.' `
            -PullRequest $PullRequest `
            -TrustedComment $null `
            -CiState $CiState `
            -Terminal
    }

    $phase = [string]$record.currentPhase
    if (
        $null -ne $TrustedComment -and
        $null -ne $PullRequest -and
        $phase -in @(
            'pull-request-created',
            'review-pushed',
            'ci-pending',
            'ci-failed'
        )
    ) {
        return New-RepoFlowResumePlanResult `
            -RunRecord $record `
            -Action 'process-review-feedback' `
            -Reason "Trusted PR comment #$($TrustedComment.id) supersedes the saved PR or CI checkpoint." `
            -PullRequest $PullRequest `
            -TrustedComment $TrustedComment `
            -CiState $CiState `
            -AbandonActiveRun
    }

    if ($phase -in @('ci-passed', 'ci-skipped')) {
        return New-RepoFlowResumePlanResult `
            -RunRecord $record `
            -Action 'complete-run' `
            -Reason "The saved CI phase '$phase' is complete." `
            -PullRequest $PullRequest `
            -TrustedComment $null `
            -CiState $CiState
    }

    $plan = if ([string]$record.operation -eq 'issue-run') {
        Get-RepoFlowInitialIssueResumePlan `
            -RunRecord $record `
            -BranchState $BranchState `
            -PullRequest $PullRequest `
            -CiState $CiState
    }
    elseif ([string]$record.operation -eq 'issue-continue-review-feedback') {
        Get-RepoFlowReviewIssueResumePlan `
            -RunRecord $record `
            -BranchState $BranchState `
            -PullRequest $PullRequest `
            -CiState $CiState
    }
    else {
        $null
    }

    if ($null -ne $plan) {
        return $plan
    }

    $plan = Get-RepoFlowPullRequestPhaseResumePlan `
        -RunRecord $record `
        -BranchState $BranchState `
        -PullRequest $PullRequest `
        -CiState $CiState

    if ($null -ne $plan) {
        return $plan
    }

    throw (
        "Run '$($record.runId)' cannot be resumed from operation " +
        "'$($record.operation)' and phase '$phase'."
    )
}

function Show-RepoFlowIssueResumePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Plan,

        [Parameter(Mandatory)]
        $BranchState
    )

    $record = $Plan.RunRecord

    Write-Host ''
    Write-Host "Resume issue:    #$($record.issueNumber)"
    Write-Host "Run ID:          $($record.runId)"
    Write-Host "Operation:       $($record.operation)"
    Write-Host "Saved status:    $($record.status)"
    Write-Host "Saved phase:     $($record.currentPhase)"
    Write-Host "Last safe phase: $($record.lastSafePhase)"
    Write-Host "Branch:          $($record.branch)"
    Write-Host "Current branch:  $($BranchState.CurrentBranch)"
    Write-Host "Working tree:    $(if ($BranchState.IsDirty) { 'dirty' } else { 'clean' })"
    Write-Host "Local branch:    $(if ($BranchState.LocalExists) { $BranchState.LocalSha } else { '<missing>' })"
    Write-Host "Remote branch:   $(if ($BranchState.RemoteExists) { $BranchState.RemoteSha } else { '<missing>' })"

    if ($null -ne $Plan.PullRequest) {
        Write-Host "Pull request:    #$($Plan.PullRequest.number) [$($Plan.PullRequest.state)]"
        Write-Host "PR head SHA:     $($Plan.PullRequest.headRefOid)"
    }
    else {
        Write-Host 'Pull request:    <none>'
    }

    if ($null -ne $Plan.CiState) {
        Write-Host "CI status:       $($Plan.CiState.Status)"
    }

    Write-Host "Next action:     $($Plan.Action)"
    Write-Host "Reason:          $($Plan.Reason)"
    Write-Host ''
}
