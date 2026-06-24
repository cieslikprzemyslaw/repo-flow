function Assert-RepoFlowReviewUniqueStrings {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Values,

        [Parameter(Mandatory)]
        [string]$Path,

        [switch]$CaseSensitive
    )

    $comparison = if ($CaseSensitive) {
        [System.StringComparer]::Ordinal
    }
    else {
        [System.StringComparer]::OrdinalIgnoreCase
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new($comparison)

    foreach ($value in @($Values)) {
        $text = [string]$value

        if (-not $seen.Add($text)) {
            throw "RepoFlow review payload contains a duplicate value at '$Path'."
        }
    }
}

function Assert-RepoFlowReviewRepositoryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    $segments = @($Value -split '/')

    if (
        $Value.StartsWith('/') -or
        $Value.StartsWith('\') -or
        $Value -match '^[A-Za-z]:' -or
        $Value.Contains('\') -or
        $Value.Contains([char]0) -or
        $Value.Contains("`r") -or
        $Value.Contains("`n") -or
        @($segments | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0
    ) {
        throw "RepoFlow review value '$Path' must be a safe repository-relative path."
    }
}

function ConvertTo-RepoFlowReviewTimestamp {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Value -is [datetimeoffset]) {
        return $Value.ToUniversalTime()
    }

    if ($Value -is [datetime]) {
        return [datetimeoffset]::new($Value.ToUniversalTime())
    }

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "RepoFlow review value '$Path' must contain a valid timestamp."
    }

    $parsed = [DateTimeOffset]::MinValue
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::RoundtripKind

    if (
        -not [DateTimeOffset]::TryParse(
            $Value,
            $culture,
            $styles,
            [ref]$parsed
        ) -or
        $Value -notmatch '(?:Z|\+00:00)$' -or
        $parsed.Offset -ne [TimeSpan]::Zero
    ) {
        throw "RepoFlow review value '$Path' must contain a valid UTC timestamp."
    }

    return $parsed
}

function Assert-RepoFlowReviewRequestEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Request
    )

    Assert-RepoFlowReviewSchema -Envelope $Request -Kind 'request'
    ConvertTo-RepoFlowReviewTimestamp `
        -Value $Request.createdAtUtc `
        -Path '$.createdAtUtc' |
        Out-Null

    Assert-RepoFlowReviewUniqueStrings `
        -Values @($Request.acceptanceCriteria) `
        -Path '$.acceptanceCriteria[]' `
        -CaseSensitive

    Assert-RepoFlowReviewUniqueStrings `
        -Values @($Request.sourceLinks) `
        -Path '$.sourceLinks[]' `
        -CaseSensitive

    Assert-RepoFlowReviewUniqueStrings `
        -Values @($Request.changedFiles | ForEach-Object { [string]$_.path }) `
        -Path '$.changedFiles[].path' `
        -CaseSensitive

    $changedFileIndex = 0

    foreach ($changedFile in @($Request.changedFiles)) {
        Assert-RepoFlowReviewRepositoryPath `
            -Value ([string]$changedFile.path) `
            -Path "$.changedFiles[$changedFileIndex].path"
        $changedFileIndex++
    }
}

function Assert-RepoFlowReviewResultEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Result
    )

    Assert-RepoFlowReviewSchema -Envelope $Result -Kind 'result'
    ConvertTo-RepoFlowReviewTimestamp `
        -Value $Result.completedAtUtc `
        -Path '$.completedAtUtc' |
        Out-Null

    $blockers = @($Result.blockers)
    $verdict = [string]$Result.verdict

    if ($verdict -eq 'pass' -and $blockers.Count -gt 0) {
        throw "RepoFlow review result verdict 'pass' cannot contain blockers."
    }

    if ($verdict -eq 'changes_required' -and $blockers.Count -eq 0) {
        throw "RepoFlow review result verdict 'changes_required' requires a blocker."
    }

    foreach ($collectionName in @('blockers', 'warnings')) {
        $index = 0

        foreach ($finding in @($Result.$collectionName)) {
            $startLine = Get-RepoFlowProperty `
                -Object $finding `
                -Name 'startLine' `
                -Default $null
            $endLine = Get-RepoFlowProperty `
                -Object $finding `
                -Name 'endLine' `
                -Default $null
            $findingPath = Get-RepoFlowProperty `
                -Object $finding `
                -Name 'path' `
                -Default $null

            if ($null -ne $findingPath) {
                Assert-RepoFlowReviewRepositoryPath `
                    -Value ([string]$findingPath) `
                    -Path "$.${collectionName}[$index].path"
            }

            if (
                $null -ne $endLine -and
                [int]$endLine -lt [int]$startLine
            ) {
                throw (
                    "RepoFlow review result has an invalid line range at " +
                    "'$.${collectionName}[$index]'."
                )
            }

            $index++
        }
    }
}
