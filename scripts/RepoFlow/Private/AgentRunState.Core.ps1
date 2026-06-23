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

function Assert-RepoFlowTimestampField {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$AllowNull
    )

    if ($null -eq $Value) {
        if ($AllowNull) {
            return
        }

        throw "Configuration value '$Path' must be a non-empty string."
    }

    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        return
    }

    Assert-RepoFlowString -Value $Value -Path $Path
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
        'model'
    )) {
        Assert-RepoFlowString `
            -Value (Get-RepoFlowProperty -Object $Record -Name $propertyName -Default $null) `
            -Path "$Path.$propertyName"
    }

    foreach ($propertyName in @('createdAtUtc', 'updatedAtUtc')) {
        Assert-RepoFlowTimestampField `
            -Value (Get-RepoFlowProperty -Object $Record -Name $propertyName -Default $null) `
            -Path "$Path.$propertyName"
    }

    Assert-RepoFlowTimestampField `
        -Value $Record.completedAtUtc `
        -Path "$Path.completedAtUtc" `
        -AllowNull

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
        RunIds = @($runIds | Sort-Object)
        JobIds = @($jobIds | Sort-Object)
    }
}

