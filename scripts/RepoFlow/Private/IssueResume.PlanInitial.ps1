function New-RepoFlowResumePlanResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RunRecord,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Reason,

        [AllowNull()]
        $PullRequest,

        [AllowNull()]
        $TrustedComment,

        [AllowNull()]
        $CiState,

        [switch]$Terminal,

        [switch]$ReopenRun,

        [switch]$AbandonActiveRun
    )

    return [pscustomobject]@{
        RunRecord = $RunRecord
        Action = $Action
        Terminal = [bool]$Terminal
        Reason = $Reason
        PullRequest = $PullRequest
        TrustedComment = $TrustedComment
        CiState = $CiState
        ReopenRun = [bool]$ReopenRun
        AbandonActiveRun = [bool]$AbandonActiveRun
    }
}

function Get-RepoFlowInitialIssueResumePlan {
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

    if ($phase -in @('branch-created', 'issue-agent-running')) {
        if (-not $BranchState.LocalExists) {
            throw (
                "Saved phase '$phase' requires local branch " +
                "'$($BranchState.Branch)', but it does not exist."
            )
        }

        if ([string]$BranchState.LocalSha -ne [string]$RunRecord.headSha) {
            throw 'Local branch HEAD changed after the saved agent checkpoint.'
        }

        return New-RepoFlowResumePlanResult `
            -RunRecord $RunRecord `
            -Action 'resume-initial-agent' `
            -Reason 'Continue the initial agent phase without recreating the branch.' `
            -PullRequest $PullRequest `
            -TrustedComment $null `
            -CiState $CiState
    }

    if ($phase -eq 'issue-agent-completed') {
        if (
            $BranchState.IsDirty -and
            [string]$BranchState.LocalSha -ne [string]$RunRecord.headSha
        ) {
            throw 'Local HEAD changed while agent changes remain uncommitted.'
        }

        if ($BranchState.IsDirty) {
            return New-RepoFlowResumePlanResult `
                -RunRecord $RunRecord `
                -Action 'commit-initial-changes' `
                -Reason 'The agent completed and the implementation is still uncommitted.' `
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
                -Action 'reconcile-initial-commit' `
                -Reason 'The commit exists locally, but its checkpoint was not persisted.' `
                -PullRequest $PullRequest `
                -TrustedComment $null `
                -CiState $CiState
        }

        throw (
            "Saved phase '$phase' expects uncommitted changes or a " +
            'single reconciliable local commit, but neither was found.'
        )
    }

    if ($phase -eq 'changes-committed') {
        if ($BranchState.IsDirty) {
            throw 'Committed-phase resume requires a clean working tree.'
        }

        if (
            -not $BranchState.LocalExists -or
            [string]$BranchState.LocalSha -ne [string]$RunRecord.headSha
        ) {
            throw 'Local branch HEAD conflicts with the saved committed checkpoint.'
        }

        if (
            $BranchState.RemoteExists -and
            [string]$BranchState.RemoteSha -eq [string]$BranchState.LocalSha
        ) {
            return New-RepoFlowResumePlanResult `
                -RunRecord $RunRecord `
                -Action 'reconcile-initial-push' `
                -Reason 'The branch is already pushed, but its checkpoint was not persisted.' `
                -PullRequest $PullRequest `
                -TrustedComment $null `
                -CiState $CiState
        }

        if (
            $BranchState.RemoteExists -and
            [string]$BranchState.RemoteSha -ne [string]$RunRecord.baseSha
        ) {
            throw 'Remote branch HEAD conflicts with the saved push checkpoint.'
        }

        return New-RepoFlowResumePlanResult `
            -RunRecord $RunRecord `
            -Action 'push-initial-branch' `
            -Reason 'Push the committed issue branch.' `
            -PullRequest $PullRequest `
            -TrustedComment $null `
            -CiState $CiState
    }

    if ($phase -eq 'branch-pushed') {
        if ($BranchState.IsDirty) {
            throw 'Pushed-phase resume requires a clean working tree.'
        }

        if (-not (Test-RepoFlowResumeLiveHeadConsensus `
            -BranchState $BranchState `
            -PullRequest $PullRequest
        )) {
            throw 'Local and remote branch heads do not match the saved pushed phase.'
        }

        if ([string]$BranchState.LocalSha -ne [string]$RunRecord.headSha) {
            throw 'Live branch HEAD conflicts with the saved pushed checkpoint.'
        }

        if ($null -ne $PullRequest) {
            return New-RepoFlowResumePlanResult `
                -RunRecord $RunRecord `
                -Action 'reconcile-pull-request' `
                -Reason "PR #$($PullRequest.number) already exists, but its checkpoint was not persisted." `
                -PullRequest $PullRequest `
                -TrustedComment $null `
                -CiState $CiState
        }

        return New-RepoFlowResumePlanResult `
            -RunRecord $RunRecord `
            -Action 'create-pull-request' `
            -Reason 'Create the missing pull request for the pushed branch.' `
            -PullRequest $null `
            -TrustedComment $null `
            -CiState $null
    }

    return $null
}
