function Get-RepoFlowReviewIssueResumePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RunRecord,

        [Parameter(Mandatory)]
        $BranchState,

        [AllowNull()]
        $PullRequest,

        [AllowNull()]
        $CiState
    )

    $phase = [string]$RunRecord.currentPhase

    if ($phase -eq 'review-agent-running') {
        if ([string]::IsNullOrWhiteSpace([string]$RunRecord.prCommentId)) {
            throw 'The saved review run does not contain its PR comment ID.'
        }

        if (
            -not $BranchState.LocalExists -or
            [string]$BranchState.LocalSha -ne [string]$RunRecord.headSha
        ) {
            throw 'Local branch HEAD changed after the saved review-agent checkpoint.'
        }

        return New-RepoFlowResumePlanResult `
            -RunRecord $RunRecord `
            -Action 'resume-review-agent' `
            -Reason "Continue trusted PR comment #$($RunRecord.prCommentId)." `
            -PullRequest $PullRequest `
            -TrustedComment $null `
            -CiState $CiState
    }

    if ($phase -eq 'review-agent-completed') {
        if (
            $BranchState.IsDirty -and
            [string]$BranchState.LocalSha -ne [string]$RunRecord.headSha
        ) {
            throw 'Local HEAD changed while review changes remain uncommitted.'
        }

        if ($BranchState.IsDirty) {
            return New-RepoFlowResumePlanResult `
                -RunRecord $RunRecord `
                -Action 'commit-review-changes' `
                -Reason 'The review agent completed and its changes are uncommitted.' `
                -PullRequest $PullRequest `
                -TrustedComment $null `
                -CiState $CiState
        }

        if (
            $BranchState.LocalExists -and
            [string]$BranchState.LocalSha -ne [string]$RunRecord.headSha -and
            (Test-RepoFlowCommitAncestor `
                -Ancestor ([string]$RunRecord.headSha) `
                -Descendant ([string]$BranchState.LocalSha)) -and
            (Get-RepoFlowCommitCount `
                -FromExclusive ([string]$RunRecord.headSha) `
                -ToInclusive ([string]$BranchState.LocalSha)) -eq 1
        ) {
            return New-RepoFlowResumePlanResult `
                -RunRecord $RunRecord `
                -Action 'reconcile-review-commit' `
                -Reason 'The review commit exists locally, but its checkpoint was not persisted.' `
                -PullRequest $PullRequest `
                -TrustedComment $null `
                -CiState $CiState
        }

        throw (
            "Saved phase '$phase' expects uncommitted changes or a " +
            'single reconciliable local commit, but neither was found.'
        )
    }

    if ($phase -eq 'review-committed') {
        if ($BranchState.IsDirty) {
            throw 'Review committed-phase resume requires a clean working tree.'
        }

        if (
            -not $BranchState.LocalExists -or
            [string]$BranchState.LocalSha -ne [string]$RunRecord.headSha
        ) {
            throw 'Local branch HEAD conflicts with the saved review commit.'
        }

        if (
            $BranchState.RemoteExists -and
            [string]$BranchState.RemoteSha -eq [string]$BranchState.LocalSha
        ) {
            return New-RepoFlowResumePlanResult `
                -RunRecord $RunRecord `
                -Action 'reconcile-review-push' `
                -Reason 'The review commit is already pushed, but its checkpoint was not persisted.' `
                -PullRequest $PullRequest `
                -TrustedComment $null `
                -CiState $CiState
        }

        if (
            -not $BranchState.RemoteExists -or
            [string]$BranchState.RemoteSha -ne [string]$RunRecord.baseSha
        ) {
            throw 'Remote branch HEAD conflicts with the saved review baseline.'
        }

        return New-RepoFlowResumePlanResult `
            -RunRecord $RunRecord `
            -Action 'push-review-branch' `
            -Reason 'Push the committed review correction.' `
            -PullRequest $PullRequest `
            -TrustedComment $null `
            -CiState $CiState
    }

    return $null
}

function Get-RepoFlowPullRequestPhaseResumePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RunRecord,

        [Parameter(Mandatory)]
        $BranchState,

        [AllowNull()]
        $PullRequest,

        [AllowNull()]
        $CiState
    )

    $phase = [string]$RunRecord.currentPhase
    if ($phase -notin @(
        'pull-request-created',
        'review-pushed',
        'ci-pending',
        'ci-failed'
    )) {
        return $null
    }

    if ($null -eq $PullRequest) {
        throw "Saved phase '$phase' requires a pull request, but none exists."
    }

    if ($BranchState.IsDirty) {
        throw "Saved phase '$phase' requires a clean working tree."
    }

    if (-not (Test-RepoFlowResumeLiveHeadConsensus `
        -BranchState $BranchState `
        -PullRequest $PullRequest
    )) {
        throw 'Local branch, remote branch, and PR head do not agree.'
    }

    $liveHead = [string]$BranchState.LocalSha
    if (
        [string]$RunRecord.headSha -ne $liveHead -and
        -not (Test-RepoFlowCommitAncestor `
            -Ancestor ([string]$RunRecord.headSha) `
            -Descendant $liveHead)
    ) {
        throw 'Live PR head is not a descendant of the saved checkpoint.'
    }

    return New-RepoFlowResumePlanResult `
        -RunRecord $RunRecord `
        -Action 'observe-ci' `
        -Reason "Continue CI handling from saved phase '$phase'." `
        -PullRequest $PullRequest `
        -TrustedComment $null `
        -CiState $CiState
}
