function Start-RepoFlowRunRecord {
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
        [string]$Operation,

        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [string]$Branch,

        [AllowNull()]
        [int]$PullRequestNumber = 0,

        [AllowNull()]
        [string]$PrCommentId = $null,

        [Parameter(Mandatory)]
        [string]$BaseSha,

        [Parameter(Mandatory)]
        [string]$HeadSha,

        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Model,

        [int]$ReviewAttemptCount = 0,

        [int]$RepairAttemptCount = 0,

        [AllowNull()]
        [string]$RunId = $null
    )

    $now = New-RepoFlowRunTimestamp
    $effectiveRunId = if ([string]::IsNullOrWhiteSpace($RunId)) {
        New-RepoFlowRunId `
            -Repository $Repository `
            -Operation $Operation `
            -IssueNumber $IssueNumber
    }
    else {
        $RunId
    }

    $record = [pscustomobject][ordered]@{
        runId = $effectiveRunId
        operation = $Operation
        status = 'running'
        repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
        repository = $Repository
        repositorySlug = $RepositorySlug
        issueNumber = $IssueNumber
        branch = $Branch
        pullRequestNumber = if ($PullRequestNumber -gt 0) { $PullRequestNumber } else { $null }
        prCommentId = if ([string]::IsNullOrWhiteSpace($PrCommentId)) {
            $null
        }
        else {
            $PrCommentId
        }
        baseSha = $BaseSha
        headSha = $HeadSha
        currentPhase = $Phase
        lastSafePhase = $Phase
        provider = $Provider
        model = $Model
        ciRunIds = @()
        ciJobIds = @()
        reviewAttemptCount = $ReviewAttemptCount
        repairAttemptCount = $RepairAttemptCount
        createdAtUtc = $now
        updatedAtUtc = $now
        completedAtUtc = $null
        terminalOutcome = $null
        pauseReason = $null
    }

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $runs = [System.Collections.Generic.List[object]]::new()
        foreach ($existing in @($document.runs)) {
            if (
                -not [string]::Equals(
                    [string]$existing.runId,
                    $effectiveRunId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $runs.Add($existing)
            }
        }

        $runs.Add($record)
        $document.runs = $runs.ToArray()
        return $document
    } | Out-Null

    return $record
}

function Set-RepoFlowRunCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$CurrentPhase,

        [AllowNull()]
        [string]$SafePhase = $null,

        [AllowNull()]
        [string]$HeadSha = $null,

        [AllowNull()]
        [string]$BaseSha = $null,

        [int]$PullRequestNumber = 0,

        [AllowEmptyCollection()]
        [string[]]$CiRunIds = @(),

        [AllowEmptyCollection()]
        [string[]]$CiJobIds = @(),

        [AllowNull()]
        [int]$ReviewAttemptCount = -1,

        [AllowNull()]
        [int]$RepairAttemptCount = -1
    )

    $replaceCiRunIds = $PSBoundParameters.ContainsKey('CiRunIds')
    $replaceCiJobIds = $PSBoundParameters.ContainsKey('CiJobIds')
    $effectiveCiRunIds = @($CiRunIds)
    $effectiveCiJobIds = @($CiJobIds)

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $updated = $false

        foreach ($record in @($document.runs)) {
            if (
                [string]::Equals(
                    [string]$record.runId,
                    $RunId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $record.status = 'running'
                $record.currentPhase = $CurrentPhase

                if (-not [string]::IsNullOrWhiteSpace($SafePhase)) {
                    $record.lastSafePhase = $SafePhase
                }

                if (-not [string]::IsNullOrWhiteSpace($HeadSha)) {
                    $record.headSha = $HeadSha
                }

                if (-not [string]::IsNullOrWhiteSpace($BaseSha)) {
                    $record.baseSha = $BaseSha
                }

                if ($PullRequestNumber -gt 0) {
                    $record.pullRequestNumber = $PullRequestNumber
                }

                if ($ReviewAttemptCount -ge 0) {
                    $record.reviewAttemptCount = $ReviewAttemptCount
                }

                if ($RepairAttemptCount -ge 0) {
                    $record.repairAttemptCount = $RepairAttemptCount
                }

                if ($replaceCiRunIds) {
                    $record.ciRunIds = @($effectiveCiRunIds)
                }

                if ($replaceCiJobIds) {
                    $record.ciJobIds = @($effectiveCiJobIds)
                }

                $record.pauseReason = $null
                $record.updatedAtUtc = New-RepoFlowRunTimestamp
                $updated = $true
                break
            }
        }

        if (-not $updated) {
            throw "Unknown RepoFlow run record: $RunId"
        }

        return $document
    } | Out-Null
}

function Set-RepoFlowRunPaused {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$PauseReason,

        [AllowNull()]
        [string]$CurrentPhase = $null
    )

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $updated = $false

        foreach ($record in @($document.runs)) {
            if (
                [string]::Equals(
                    [string]$record.runId,
                    $RunId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $record.status = 'paused'
                if (-not [string]::IsNullOrWhiteSpace($CurrentPhase)) {
                    $record.currentPhase = $CurrentPhase
                }
                $effectivePhase = [string]$record.currentPhase
                $record.pauseReason = New-RepoFlowSafePauseReason `
                    -Reason $PauseReason `
                    -Phase $effectivePhase
                $record.updatedAtUtc = New-RepoFlowRunTimestamp
                $updated = $true
                break
            }
        }

        if (-not $updated) {
            throw "Unknown RepoFlow run record: $RunId"
        }

        return $document
    } | Out-Null
}

function Complete-RepoFlowRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [ValidateSet('completed', 'abandoned')]
        [string]$Outcome
    )

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $updated = $false
        $now = New-RepoFlowRunTimestamp

        foreach ($record in @($document.runs)) {
            if (
                [string]::Equals(
                    [string]$record.runId,
                    $RunId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $record.status = 'completed'
                $record.terminalOutcome = $Outcome
                $record.pauseReason = $null
                $record.completedAtUtc = $now
                $record.updatedAtUtc = $now
                $record.lastSafePhase = $record.currentPhase
                $updated = $true
                break
            }
        }

        if (-not $updated) {
            throw "Unknown RepoFlow run record: $RunId"
        }

        return $document
    } | Out-Null
}

function Prune-RepoFlowRunRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Repository = $null
    )

    $result = [pscustomobject]@{
        Removed = 0
    }

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $remaining = [System.Collections.Generic.List[object]]::new()

        foreach ($record in @($document.runs)) {
            $isRepositoryMatch = (
                [string]::IsNullOrWhiteSpace($Repository) -or
                [string]::Equals(
                    [string]$record.repository,
                    $Repository,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            )
            $isTerminal = -not [string]::IsNullOrWhiteSpace(
                [string]$record.terminalOutcome
            )

            if ($isRepositoryMatch -and $isTerminal) {
                $result.Removed++
                continue
            }

            $remaining.Add($record)
        }

        $document.runs = $remaining.ToArray()
        return $document
    } | Out-Null

    Remove-RepoFlowStateFileIfEmpty -ConfigPath $ConfigPath | Out-Null

    return [int]$result.Removed
}
