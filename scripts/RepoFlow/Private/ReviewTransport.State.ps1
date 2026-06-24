function Get-RepoFlowAutomatedReviewResultRunId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RequestId
    )

    return "$RequestId.result"
}

function Get-RepoFlowAutomatedReviewRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RequestId
    )

    $record = Get-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RunId $RequestId

    if ($null -eq $record) {
        return $null
    }

    if ([string]$record.operation -ne 'automated-review-request') {
        throw "Run ID '$RequestId' belongs to a different workflow operation."
    }

    return $record
}

function Get-RepoFlowAutomatedReviewResultRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RequestId
    )

    $resultRunId = Get-RepoFlowAutomatedReviewResultRunId `
        -RequestId $RequestId
    $record = Get-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RunId $resultRunId

    if ($null -eq $record) {
        return $null
    }

    if ([string]$record.operation -ne 'automated-review-result') {
        throw "Run ID '$resultRunId' belongs to a different workflow operation."
    }

    return $record
}

function Start-RepoFlowAutomatedReviewRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$RepositoryName,

        [Parameter(Mandatory)]
        [string]$RepositorySlug,

        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        [string]$RequestId,

        [Parameter(Mandatory)]
        [long]$RequestCommentId
    )

    return Start-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RepositoryRoot $RepositoryRoot `
        -Repository $RepositoryName `
        -RepositorySlug $RepositorySlug `
        -Operation 'automated-review-request' `
        -IssueNumber ([int]$Issue.number) `
        -Branch ([string]$PullRequest.headRefName) `
        -PullRequestNumber ([int]$PullRequest.number) `
        -PrCommentId ([string]$RequestCommentId) `
        -BaseSha ([string]$PullRequest.baseRefOid) `
        -HeadSha ([string]$PullRequest.headRefOid) `
        -Phase 'review-result-waiting' `
        -Provider 'openai-review-bridge' `
        -Model 'review-contract-v1' `
        -RunId $RequestId
}

function Set-RepoFlowAutomatedReviewRequestComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RequestId,

        [Parameter(Mandatory)]
        [long]$RequestCommentId
    )

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $updated = $false

        foreach ($record in @($document.runs)) {
            if ([string]$record.runId -ceq $RequestId) {
                $record.prCommentId = [string]$RequestCommentId
                $record.status = 'running'
                $record.currentPhase = 'review-result-waiting'
                $record.lastSafePhase = 'review-request-published'
                $record.completedAtUtc = $null
                $record.terminalOutcome = $null
                $record.pauseReason = $null
                $now = New-RepoFlowRunTimestamp
                $record.updatedAtUtc = $now
                $record.lastHeartbeatAtUtc = $now
                $record.lastObservableActivityAtUtc = $now
                $updated = $true
                break
            }
        }

        if (-not $updated) {
            throw "Unknown automated-review run record: $RequestId"
        }

        return $document
    } | Out-Null
}

function Save-RepoFlowAutomatedReviewResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$RepositoryName,

        [Parameter(Mandatory)]
        [string]$RepositorySlug,

        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        [string]$RequestId,

        [Parameter(Mandatory)]
        [long]$ResultCommentId,

        [Parameter(Mandatory)]
        $Result
    )

    Assert-RepoFlowReviewResultEnvelope -Result $Result

    $resultRunId = Get-RepoFlowAutomatedReviewResultRunId `
        -RequestId $RequestId
    $existing = Get-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RunId $resultRunId
    $verdict = [string]$Result.verdict

    if ($null -eq $existing) {
        Start-RepoFlowRunRecord `
            -ConfigPath $ConfigPath `
            -RepositoryRoot $RepositoryRoot `
            -Repository $RepositoryName `
            -RepositorySlug $RepositorySlug `
            -Operation 'automated-review-result' `
            -IssueNumber ([int]$Issue.number) `
            -Branch ([string]$PullRequest.headRefName) `
            -PullRequestNumber ([int]$PullRequest.number) `
            -PrCommentId ([string]$ResultCommentId) `
            -BaseSha ([string]$PullRequest.baseRefOid) `
            -HeadSha ([string]$PullRequest.headRefOid) `
            -Phase "review-result-$verdict" `
            -Provider 'openai-review-bridge' `
            -Model 'review-contract-v1' `
            -RunId $resultRunId |
            Out-Null

        Complete-RepoFlowRunRecord `
            -ConfigPath $ConfigPath `
            -RunId $resultRunId `
            -Outcome completed
    }
    elseif (
        [string]$existing.prCommentId -ne [string]$ResultCommentId -or
        [string]$existing.currentPhase -ne "review-result-$verdict"
    ) {
        throw 'A different automated-review result is already persisted for this request.'
    }

    if ($verdict -eq 'pass') {
        Set-RepoFlowRunCheckpoint `
            -ConfigPath $ConfigPath `
            -RunId $RequestId `
            -CurrentPhase 'review-passed' `
            -SafePhase 'review-result-received'
        Complete-RepoFlowRunRecord `
            -ConfigPath $ConfigPath `
            -RunId $RequestId `
            -Outcome completed
        return
    }

    $requestPhase = if ($verdict -eq 'changes_required') {
        'review-changes-required'
    }
    else {
        'review-manual-review'
    }

    Set-RepoFlowRunPaused `
        -ConfigPath $ConfigPath `
        -RunId $RequestId `
        -CurrentPhase $requestPhase `
        -PauseReason (
            "Automated review returned '$verdict'. " +
            'Inspect the trusted result comment before continuing.'
        )
}

function Set-RepoFlowAutomatedReviewPaused {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RequestId,

        [Parameter(Mandatory)]
        [ValidateSet('timeout', 'malformed', 'stale')]
        [string]$ReasonCode
    )

    $phase = switch ($ReasonCode) {
        'timeout' { 'review-result-timeout' }
        'malformed' { 'review-result-malformed' }
        'stale' { 'review-head-changed' }
    }
    $reason = switch ($ReasonCode) {
        'timeout' {
            'Automated review timed out without a matching trusted result.'
        }
        'malformed' {
            'A trusted marked review result was malformed and was not accepted.'
        }
        'stale' {
            'The pull-request head changed while automated review was pending.'
        }
    }

    Set-RepoFlowRunPaused `
        -ConfigPath $ConfigPath `
        -RunId $RequestId `
        -CurrentPhase $phase `
        -PauseReason $reason
}

function Get-RepoFlowProcessedAutomatedReviewRequestIds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [AllowNull()]
        [string]$ExcludeRequestId
    )

    return @(
        Get-RepoFlowRunRecords -ConfigPath $ConfigPath |
        Where-Object {
            [string]$_.operation -eq 'automated-review-result' -and
            [string]$_.status -eq 'completed'
        } |
        ForEach-Object {
            $runId = [string]$_.runId

            if ($runId.EndsWith('.result')) {
                $runId.Substring(0, $runId.Length - '.result'.Length)
            }
        } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            (
                [string]::IsNullOrWhiteSpace($ExcludeRequestId) -or
                [string]$_ -cne $ExcludeRequestId
            )
        }
    )
}
