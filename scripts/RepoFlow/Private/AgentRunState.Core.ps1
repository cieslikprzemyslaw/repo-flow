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

        throw "RepoFlow state value '$Path' must contain a valid timestamp."
    }

    if ($Value -is [datetime] -or $Value -is [datetimeoffset]) {
        return
    }

    Assert-RepoFlowString -Value $Value -Path $Path

    $parsed = [DateTimeOffset]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    if (
        -not [DateTimeOffset]::TryParse(
            [string]$Value,
            $culture,
            $styles,
            [ref]$parsed
        )
    ) {
        throw "RepoFlow state value '$Path' must contain a valid timestamp."
    }
}

function New-RepoFlowSafePauseReason {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Reason,

        [Parameter(Mandatory)]
        [string]$Phase
    )

    $category = 'workflow'

    if ($Reason -match '(?i)\bagent\b|\bcodex\b|\bclaude\b') {
        $category = 'coding-agent'
    }
    elseif ($Reason -match '(?i)\bCI\b|\bcheck(s)?\b') {
        $category = 'CI'
    }
    elseif ($Reason -match '(?i)\bvalidation\b|\btest(s)?\b|\blint\b|\btypecheck\b') {
        $category = 'local-validation'
    }
    elseif ($Reason -match '(?i)\bcommit\b|\bpush\b|\bbranch\b|\bpull request\b|\bGitHub\b') {
        $category = 'Git-or-GitHub'
    }

    return (
        "RepoFlow paused during phase '$Phase' after a $category failure. " +
        'Inspect the console output and local repository state before resuming.'
    )
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
        -Value (Get-RepoFlowProperty -Object $Record -Name 'completedAtUtc' -Default $null) `
        -Path "$Path.completedAtUtc" `
        -AllowNull

    $terminalOutcome = Get-RepoFlowProperty `
        -Object $Record `
        -Name 'terminalOutcome' `
        -Default $null
    $pauseReason = Get-RepoFlowProperty `
        -Object $Record `
        -Name 'pauseReason' `
        -Default $null

    if ($null -ne $terminalOutcome) {
        Assert-RepoFlowString `
            -Value $terminalOutcome `
            -Path "$Path.terminalOutcome"
    }

    if ($null -ne $pauseReason) {
        Assert-RepoFlowString `
            -Value $pauseReason `
            -Path "$Path.pauseReason"
    }

    Assert-RepoFlowArray -Value $Record.ciRunIds -Path "$Path.ciRunIds"
    Assert-RepoFlowArray -Value $Record.ciJobIds -Path "$Path.ciJobIds"

    foreach ($value in @($Record.ciRunIds + $Record.ciJobIds)) {
        Assert-RepoFlowString -Value $value -Path "$Path.ciIdentifiers[]"

        if ([string]$value -notmatch '^\d+$') {
            throw "RepoFlow state run record is invalid at '$Path.ciIdentifiers[]'."
        }
    }

    $issueNumber = 0
    if (
        -not [int]::TryParse(
            [string]$Record.issueNumber,
            [ref]$issueNumber
        ) -or
        $issueNumber -le 0
    ) {
        throw "RepoFlow state run record is invalid at '$Path.issueNumber'."
    }

    $status = [string]$Record.status

    if ($status -notin @('running', 'paused', 'completed')) {
        throw "RepoFlow state run record is invalid at '$Path.status'."
    }

    if ($null -ne $Record.pullRequestNumber) {
        $pullRequestNumber = 0

        if (
            -not [int]::TryParse(
                [string]$Record.pullRequestNumber,
                [ref]$pullRequestNumber
            ) -or
            $pullRequestNumber -le 0
        ) {
            throw "RepoFlow state run record is invalid at '$Path.pullRequestNumber'."
        }
    }

    if ($null -ne $Record.prCommentId) {
        Assert-RepoFlowString `
            -Value $Record.prCommentId `
            -Path "$Path.prCommentId"

        if ([string]$Record.prCommentId -notmatch '^\d+$') {
            throw "RepoFlow state run record is invalid at '$Path.prCommentId'."
        }
    }

    foreach ($shaProperty in @('baseSha', 'headSha')) {
        $shaValue = [string]$Record.$shaProperty

        if ($shaValue -notmatch '^(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})$') {
            throw "RepoFlow state run record is invalid at '$Path.$shaProperty'."
        }
    }

    if (
        $null -ne $terminalOutcome -and
        [string]$terminalOutcome -notin @('completed', 'abandoned')
    ) {
        throw "RepoFlow state run record is invalid at '$Path.terminalOutcome'."
    }

    foreach ($attemptProperty in @(
        'reviewAttemptCount',
        'repairAttemptCount'
    )) {
        $attemptCount = -1

        if (
            -not [int]::TryParse(
                [string]$Record.$attemptProperty,
                [ref]$attemptCount
            ) -or
            $attemptCount -lt 0
        ) {
            throw "RepoFlow state run record is invalid at '$Path.$attemptProperty'."
        }
    }

    $hasCompletedAt = $null -ne $Record.completedAtUtc
    $hasTerminalOutcome = -not [string]::IsNullOrWhiteSpace(
        [string]$terminalOutcome
    )
    $hasPauseReason = -not [string]::IsNullOrWhiteSpace(
        [string]$pauseReason
    )

    switch ($status) {
        'running' {
            if ($hasCompletedAt -or $hasTerminalOutcome -or $hasPauseReason) {
                throw "RepoFlow state run record has inconsistent running state at '$Path'."
            }
        }

        'paused' {
            if ($hasCompletedAt -or $hasTerminalOutcome -or -not $hasPauseReason) {
                throw "RepoFlow state run record has inconsistent paused state at '$Path'."
            }
        }

        'completed' {
            if (-not $hasCompletedAt -or -not $hasTerminalOutcome -or $hasPauseReason) {
                throw "RepoFlow state run record has inconsistent completed state at '$Path'."
            }
        }
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

