function Get-RepoFlowQueueReviewRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositorySlug,

        [Parameter(Mandatory)]
        $PullRequest
    )

    $record = Get-RepoFlowPrReviewLoopRunRecord `
        -ConfigPath $ConfigPath `
        -Repository $RepositorySlug `
        -PullRequestNumber ([int]$PullRequest.number)

    if ($null -eq $record) {
        return [pscustomobject]@{
            Status = 'missing'
            Record = $null
        }
    }

    $sameHead = [string]::Equals(
        [string]$record.headSha,
        [string]$PullRequest.headRefOid,
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if (
        [string]$record.status -eq 'completed' -and
        [string]$record.currentPhase -eq 'review-passed' -and
        $sameHead
    ) {
        return [pscustomobject]@{
            Status = 'passed'
            Record = $record
        }
    }

    if ([string]$record.status -eq 'paused' -and $sameHead) {
        return [pscustomobject]@{
            Status = 'paused'
            Record = $record
        }
    }

    return [pscustomobject]@{
        Status = 'incomplete'
        Record = $record
    }
}

function New-RepoFlowQueueTaskResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('completed', 'merge-gate', 'paused')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Reason,

        [AllowNull()]
        $PullRequest = $null,

        [AllowNull()]
        $RunRecord = $null,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Phase = '',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RepositoryName = ''
    )

    $effectivePhase = if (-not [string]::IsNullOrWhiteSpace($Phase)) {
        $Phase
    }
    elseif ($Status -eq 'completed') {
        'cleanup-completed'
    }
    elseif ($Status -eq 'merge-gate') {
        'merge-gate'
    }
    else {
        'manual-review-required'
    }

    return [pscustomobject]@{
        Status = $Status
        Phase = $effectivePhase
        Reason = $Reason
        RepositoryName = $RepositoryName
        PullRequest = $PullRequest
        RunRecord = $RunRecord
    }
}
