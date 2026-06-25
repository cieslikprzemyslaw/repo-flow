function Initialize-RepoFlowLocalReviewBridgeRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        $Context,

        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Request,

        [Parameter(Mandatory)]
        $Reviewer
    )

    $runId = Get-RepoFlowLocalReviewBridgeRunId -RequestId ([string]$Request.requestId)
    $existing = Get-RepoFlowRunRecord -ConfigPath $ConfigPath -RunId $runId

    if ($null -eq $existing) {
        Start-RepoFlowRunRecord `
            -ConfigPath $ConfigPath `
            -RepositoryRoot ([string]$Context.RepositoryRoot) `
            -Repository ([string]$Context.RepositorySelection.Repository.name) `
            -RepositorySlug ([string]$Request.repository) `
            -Operation 'automated-review-local-bridge' `
            -IssueNumber ([int]$Issue.number) `
            -Branch ([string]$PullRequest.headRefName) `
            -PullRequestNumber ([int]$PullRequest.number) `
            -BaseSha ([string]$Request.baseSha) `
            -HeadSha ([string]$Request.headSha) `
            -Phase 'local-reviewer-starting' `
            -Provider ([string]$Reviewer.provider) `
            -Model ([string]$Reviewer.model) `
            -RunId $runId |
            Out-Null
    }
    else {
        if (
            [string]$existing.operation -ne 'automated-review-local-bridge' -or
            [int]$existing.pullRequestNumber -ne [int]$PullRequest.number -or
            -not [string]::Equals([string]$existing.baseSha, [string]$Request.baseSha, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$existing.headSha, [string]$Request.headSha, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            throw 'Persisted local-reviewer state does not match the current request.'
        }

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $ConfigPath `
            -RunId $runId `
            -CurrentPhase 'local-reviewer-restarting' `
            -SafePhase 'local-reviewer-starting'
    }

    return $runId
}

function Set-RepoFlowLocalReviewBridgePaused {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RequestId,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    Set-RepoFlowRunPaused `
        -ConfigPath $ConfigPath `
        -RunId $RunId `
        -CurrentPhase 'local-reviewer-paused' `
        -PauseReason $Reason

    Set-RepoFlowRunPaused `
        -ConfigPath $ConfigPath `
        -RunId $RequestId `
        -CurrentPhase 'review-local-bridge-paused' `
        -PauseReason $Reason
}


function Complete-RepoFlowLocalReviewBridgeIfPresent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RequestId
    )

    try {
        $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath
    }
    catch {
        return
    }

    try {
        $stateExists = Test-Path -LiteralPath $statePath -PathType Leaf
    }
    catch {
        $stateExists = $false
    }

    if (-not $stateExists) {
        return
    }

    $runId = Get-RepoFlowLocalReviewBridgeRunId -RequestId $RequestId
    $record = Get-RepoFlowRunRecord -ConfigPath $ConfigPath -RunId $runId

    if ($null -eq $record -or [string]$record.status -eq 'completed') {
        return
    }

    if ([string]$record.operation -ne 'automated-review-local-bridge') {
        throw "Run ID '$runId' belongs to a different workflow operation."
    }

    Set-RepoFlowRunCheckpoint `
        -ConfigPath $ConfigPath `
        -RunId $runId `
        -CurrentPhase 'local-reviewer-result-published' `
        -SafePhase 'local-reviewer-result-published'
    Complete-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RunId $runId `
        -Outcome completed
}
