function Get-RepoFlowGitPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $gitPath = (Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'rev-parse',
        '--git-path',
        $Path
    )).Text.Trim()

    if ([System.IO.Path]::IsPathRooted($gitPath)) {
        return [System.IO.Path]::GetFullPath($gitPath)
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path $RepositoryRoot $gitPath)
    )
}

function Assert-RepoFlowNoGitOperationInProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $operationPaths = @(
        'MERGE_HEAD',
        'CHERRY_PICK_HEAD',
        'REVERT_HEAD',
        'rebase-merge',
        'rebase-apply'
    )

    foreach ($operationPath in $operationPaths) {
        $resolvedPath = Get-RepoFlowGitPath `
            -RepositoryRoot $RepositoryRoot `
            -Path $operationPath

        if (Test-Path -LiteralPath $resolvedPath) {
            throw (
                "Cannot resume while a Git merge, rebase, cherry-pick, or " +
                'revert is in progress.'
            )
        }
    }
}

function New-RepoFlowRunTimestamp {
    [CmdletBinding()]
    param()

    return [DateTimeOffset]::UtcNow.ToString('o')
}

function New-RepoFlowRunId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$Operation,

        [Parameter(Mandatory)]
        [int]$IssueNumber
    )

    $repositoryToken = (
        $Repository.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    ).Trim('-')
    $operationToken = (
        $Operation.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    ).Trim('-')
    $timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)

    return "$repositoryToken-$operationToken-$IssueNumber-$timestamp-$suffix"
}

function Assert-RepoFlowRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Record,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $allowed = @(
        'runId',
        'operation',
        'status',
        'repositoryRoot',
        'repository',
        'repositorySlug',
        'issueNumber',
        'branch',
        'pullRequestNumber',
        'prCommentId',
        'baseSha',
        'headSha',
        'currentPhase',
        'lastSafePhase',
        'provider',
        'model',
        'ciRunIds',
        'ciJobIds',
        'reviewAttemptCount',
        'repairAttemptCount',
        'createdAtUtc',
        'updatedAtUtc',
        'completedAtUtc',
        'terminalOutcome',
        'pauseReason'
    )

    Assert-RepoFlowAllowedProperties `
        -Object $Record `
        -Allowed $allowed `
        -Path $Path

    foreach ($propertyName in @(
        'runId',
        'operation',
        'status',
        'repositoryRoot',
        'repository',
        'repositorySlug',
        'branch',
        'baseSha',
        'headSha',
        'currentPhase',
        'lastSafePhase',
        'provider',
        'model',
        'createdAtUtc',
        'updatedAtUtc'
    )) {
        Assert-RepoFlowString `
            -Value (Get-RepoFlowProperty -Object $Record -Name $propertyName -Default $null) `
            -Path "$Path.$propertyName"
    }

    if ($null -ne $Record.completedAtUtc) {
        Assert-RepoFlowString `
            -Value $Record.completedAtUtc `
            -Path "$Path.completedAtUtc"
    }

    if ($null -ne $Record.terminalOutcome) {
        Assert-RepoFlowString `
            -Value $Record.terminalOutcome `
            -Path "$Path.terminalOutcome"
    }

    if ($null -ne $Record.pauseReason) {
        Assert-RepoFlowString `
            -Value $Record.pauseReason `
            -Path "$Path.pauseReason"
    }

    Assert-RepoFlowArray -Value $Record.ciRunIds -Path "$Path.ciRunIds"
    Assert-RepoFlowArray -Value $Record.ciJobIds -Path "$Path.ciJobIds"

    foreach ($value in @($Record.ciRunIds + $Record.ciJobIds)) {
        Assert-RepoFlowString -Value $value -Path "$Path.ciIdentifiers[]"
    }

    if ([int]$Record.issueNumber -le 0) {
        throw "RepoFlow state run record is invalid at '$Path.issueNumber'."
    }

    if ([string]$Record.status -notin @('running', 'paused', 'completed')) {
        throw "RepoFlow state run record is invalid at '$Path.status'."
    }

    if ($null -ne $Record.pullRequestNumber -and [int]$Record.pullRequestNumber -le 0) {
        throw "RepoFlow state run record is invalid at '$Path.pullRequestNumber'."
    }

    if ($null -ne $Record.prCommentId -and [string]::IsNullOrWhiteSpace([string]$Record.prCommentId)) {
        throw "RepoFlow state run record is invalid at '$Path.prCommentId'."
    }

    if (
        $null -ne $Record.terminalOutcome -and
        [string]$Record.terminalOutcome -notin @('completed', 'abandoned')
    ) {
        throw "RepoFlow state run record is invalid at '$Path.terminalOutcome'."
    }

    if ([int]$Record.reviewAttemptCount -lt 0) {
        throw "RepoFlow state run record is invalid at '$Path.reviewAttemptCount'."
    }

    if ([int]$Record.repairAttemptCount -lt 0) {
        throw "RepoFlow state run record is invalid at '$Path.repairAttemptCount'."
    }
}

function Get-RepoFlowRunRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Repository = $null
    )

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath
    $document = Read-RepoFlowStateDocument -ConfigPath $ConfigPath

    if ($null -eq $document) {
        return @()
    }

    $records = @($document.runs)

    try {
        for ($index = 0; $index -lt $records.Count; $index++) {
            Assert-RepoFlowRunRecord `
                -Record $records[$index] `
                -Path ("$.runs[{0}]" -f $index)
        }
    }
    catch {
        throw (
            'RepoFlow state contains an invalid or incompatible run record. ' +
            "Move or delete the file and retry: $statePath"
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($Repository)) {
        $records = @(
            $records |
            Where-Object {
                [string]::Equals(
                    [string]$_.repository,
                    $Repository,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
        )
    }

    return @(
        $records |
        Sort-Object -Property updatedAtUtc -Descending
    )
}

function Get-RepoFlowRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RunId
    )

    return @(
        Get-RepoFlowRunRecords -ConfigPath $ConfigPath |
        Where-Object {
            [string]::Equals(
                [string]$_.runId,
                $RunId,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    ) | Select-Object -First 1
}

function Get-RepoFlowLatestRepositoryRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Operation
    )

    $expectedRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)

    return @(
        Get-RepoFlowRunRecords -ConfigPath $ConfigPath |
        Where-Object {
            [string]::Equals(
                [System.IO.Path]::GetFullPath([string]$_.repositoryRoot),
                $expectedRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]::Equals(
                [string]$_.operation,
                $Operation,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [string]$_.status -in @('running', 'paused')
        }
    ) | Select-Object -First 1
}

function Get-RepoFlowCiIdentifiersFromChecks {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Checks = @()
    )

    $runIds = [System.Collections.Generic.HashSet[string]]::new()
    $jobIds = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($check in @($Checks)) {
        $link = [string]$check.link

        if ($link -match '/actions/runs/(?<runId>\d+)') {
            $runIds.Add($Matches['runId']) | Out-Null
        }

        if ($link -match '/jobs/(?<jobId>\d+)') {
            $jobIds.Add($Matches['jobId']) | Out-Null
        }
    }

    return [pscustomobject]@{
        RunIds = @($runIds.ToArray() | Sort-Object)
        JobIds = @($jobIds.ToArray() | Sort-Object)
    }
}

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
        prCommentId = $PrCommentId
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

                if (@($CiRunIds).Count -gt 0) {
                    $record.ciRunIds = @($CiRunIds)
                }

                if (@($CiJobIds).Count -gt 0) {
                    $record.ciJobIds = @($CiJobIds)
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
                $record.pauseReason = Get-RepoFlowBoundedText `
                    -Text $PauseReason `
                    -MaximumCharacters 4000 `
                    -HeadCharacters 1000
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

    $removed = 0

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
            $isTerminal = -not [string]::IsNullOrWhiteSpace([string]$record.terminalOutcome)

            if ($isRepositoryMatch -and $isTerminal) {
                $removed++
                continue
            }

            $remaining.Add($record)
        }

        $document.runs = $remaining.ToArray()
        return $document
    } | Out-Null

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath
    $document = Read-RepoFlowStateDocument -ConfigPath $ConfigPath

    if (
        $removed -gt 0 -and
        $null -ne $document -and
        [string]::IsNullOrWhiteSpace([string]$document.activeRepository) -and
        @($document.runs).Count -eq 0
    ) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    }

    return $removed
}

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
