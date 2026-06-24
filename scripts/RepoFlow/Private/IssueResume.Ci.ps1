function Invoke-RepoFlowResumedCi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resolved,

        [Parameter(Mandatory)]
        $Context,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$CiMode
    )

    $plan = $Resolved.Plan
    $record = $plan.RunRecord
    $pullRequest = $plan.PullRequest
    $config = $Context.Config

    if ($null -eq $pullRequest) {
        throw 'Cannot resume CI without a pull request.'
    }

    Set-RepoFlowResumeBranch -BranchState $Resolved.BranchState
    Assert-RepoFlowCleanWorkingTree -Config $config

    if ($plan.ReopenRun) {
        Resume-RepoFlowRunRecord `
            -ConfigPath $Resolved.StateConfigPath `
            -RunId ([string]$record.runId) `
            -CurrentPhase ([string]$record.currentPhase)
    }

    $liveHead = Get-RepoFlowCommitHash
    Set-RepoFlowRunCheckpoint `
        -ConfigPath $Resolved.StateConfigPath `
        -RunId ([string]$record.runId) `
        -CurrentPhase ([string]$record.currentPhase) `
        -SafePhase ([string]$record.lastSafePhase) `
        -PullRequestNumber ([int]$pullRequest.number) `
        -HeadSha $liveHead

    $effectiveCiMode = Get-RepoFlowEffectiveCiMode `
        -Config $config `
        -Override $CiMode

    try {
        $ciState = Invoke-RepoFlowCiPolicy `
            -Issue $Resolved.Issue `
            -PullRequest $pullRequest `
            -RepositoryRoot $Context.RepositoryRoot `
            -Config $config `
            -Mode $effectiveCiMode `
            -StateConfigPath $Resolved.StateConfigPath `
            -RunId ([string]$record.runId) `
            -Phase 'ci-watching'

        $headSha = Get-RepoFlowCommitHash
        $identifiers = Get-RepoFlowCiIdentifiersFromChecks `
            -Checks $ciState.Checks
        $phase = "ci-$($ciState.Status)"

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $Resolved.StateConfigPath `
            -RunId ([string]$record.runId) `
            -CurrentPhase $phase `
            -SafePhase $phase `
            -PullRequestNumber ([int]$pullRequest.number) `
            -CiRunIds @($identifiers.RunIds) `
            -CiJobIds @($identifiers.JobIds) `
            -HeadSha $headSha

        if ($ciState.Status -in @('passed', 'skipped')) {
            Complete-RepoFlowRunRecord `
                -ConfigPath $Resolved.StateConfigPath `
                -RunId ([string]$record.runId) `
                -Outcome 'completed'
            Write-Host "[CI] Resume completed with status '$($ciState.Status)'."
            return
        }

        Set-RepoFlowRunPaused `
            -ConfigPath $Resolved.StateConfigPath `
            -RunId ([string]$record.runId) `
            -CurrentPhase $phase `
            -PauseReason "CI status is '$($ciState.Status)'."
        Write-Warning (
            "RepoFlow remains resumable because CI status is " +
            "'$($ciState.Status)'."
        )
    }
    catch {
        $failure = $_
        $phase = [string]$record.currentPhase

        try {
            $ciState = Get-RepoFlowPrCheckState `
                -PullRequestNumber ([int]$pullRequest.number) `
                -Repository $Resolved.RepositorySlug
            $headSha = Get-RepoFlowCommitHash
            $identifiers = Get-RepoFlowCiIdentifiersFromChecks `
                -Checks $ciState.Checks
            $phase = "ci-$($ciState.Status)"

            Set-RepoFlowRunCheckpoint `
                -ConfigPath $Resolved.StateConfigPath `
                -RunId ([string]$record.runId) `
                -CurrentPhase $phase `
                -SafePhase $phase `
                -PullRequestNumber ([int]$pullRequest.number) `
                -CiRunIds @($identifiers.RunIds) `
                -CiJobIds @($identifiers.JobIds) `
                -HeadSha $headSha
        }
        catch {
            Write-Warning (
                'CI state could not be refreshed after the resume failure. ' +
                'The previous deterministic checkpoint will be preserved.'
            )
        }

        Set-RepoFlowRunPaused `
            -ConfigPath $Resolved.StateConfigPath `
            -RunId ([string]$record.runId) `
            -CurrentPhase $phase `
            -PauseReason $failure.Exception.Message
        throw $failure
    }
}
