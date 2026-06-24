$script:RepoFlowReviewContractVersion = '1'
$script:RepoFlowReviewCommentMaximumCharacters = 65536
$script:RepoFlowReviewEnvelopeMaximumCharacters = 49152
$script:RepoFlowReviewSchemaDirectory = Join-Path (
    Split-Path -Parent $PSScriptRoot
) 'Schemas'

function Get-RepoFlowReviewSchemaPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('request', 'result')]
        [string]$Kind
    )

    $fileName = "review-$Kind.v$script:RepoFlowReviewContractVersion.schema.json"
    $path = Join-Path $script:RepoFlowReviewSchemaDirectory $fileName

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "RepoFlow review contract schema was not found: $path"
    }

    return $path
}

function ConvertTo-RepoFlowReviewJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Envelope,

        [switch]$Compress
    )

    $normalised = [ordered]@{}

    if ($Envelope -is [System.Collections.IDictionary]) {
        foreach ($key in $Envelope.Keys) {
            $normalised[[string]$key] = $Envelope[$key]
        }
    }
    else {
        foreach ($property in $Envelope.PSObject.Properties) {
            $normalised[$property.Name] = $property.Value
        }
    }

    foreach ($timestampName in @('createdAtUtc', 'completedAtUtc')) {
        if (-not $normalised.Contains($timestampName)) {
            continue
        }

        $value = $normalised[$timestampName]

        if ($value -is [datetime]) {
            $normalised[$timestampName] = $value.ToUniversalTime().ToString(
                'o',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
        elseif ($value -is [datetimeoffset]) {
            $normalised[$timestampName] = $value.ToUniversalTime().ToString(
                'o',
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        }
    }

    $parameters = @{
        Depth       = 30
        ErrorAction = 'Stop'
    }

    if ($Compress) {
        $parameters.Compress = $true
    }

    return ($normalised | ConvertTo-Json @parameters)
}

function Assert-RepoFlowReviewJsonSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [ValidateSet('request', 'result')]
        [string]$Kind
    )

    if ($Json.Length -gt $script:RepoFlowReviewEnvelopeMaximumCharacters) {
        throw (
            "RepoFlow review $Kind payload exceeds the " +
            "$script:RepoFlowReviewEnvelopeMaximumCharacters-character limit."
        )
    }

    $schemaPath = Get-RepoFlowReviewSchemaPath -Kind $Kind

    try {
        $isValid = Test-Json `
            -Json $Json `
            -SchemaFile $schemaPath `
            -ErrorAction Stop
    }
    catch {
        throw "RepoFlow review $Kind payload failed JSON schema validation."
    }

    if (-not $isValid) {
        throw "RepoFlow review $Kind payload failed JSON schema validation."
    }
}

function Assert-RepoFlowReviewSchema {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Envelope,

        [Parameter(Mandatory)]
        [ValidateSet('request', 'result')]
        [string]$Kind
    )

    try {
        $json = ConvertTo-RepoFlowReviewJson `
            -Envelope $Envelope `
            -Compress
    }
    catch {
        throw "RepoFlow review $Kind payload could not be serialised as JSON."
    }

    Assert-RepoFlowReviewJsonSchema -Json $json -Kind $Kind
}

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

function Assert-RepoFlowReviewResultMatchesRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Request,

        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        [ValidatePattern('^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$')]
        [string]$CurrentHeadSha,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ProcessedRequestIds
    )

    Assert-RepoFlowReviewRequestEnvelope -Request $Request
    Assert-RepoFlowReviewResultEnvelope -Result $Result

    if ([string]$Result.requestId -cne [string]$Request.requestId) {
        throw 'RepoFlow review result request ID does not match the request.'
    }

    if (
        -not [string]::Equals(
            [string]$Result.reviewedHeadSha,
            [string]$Request.headSha,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'RepoFlow review result head SHA does not match the requested head SHA.'
    }

    if (
        -not [string]::Equals(
            [string]$Result.reviewedHeadSha,
            $CurrentHeadSha,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'RepoFlow review result is stale because the pull-request head has changed.'
    }

    if (
        @($ProcessedRequestIds) |
            Where-Object {
                [string]::Equals(
                    [string]$_,
                    [string]$Result.requestId,
                    [System.StringComparison]::Ordinal
                )
            }
    ) {
        throw 'RepoFlow review result is a duplicate for an already processed request.'
    }

    $requestCreatedAt = ConvertTo-RepoFlowReviewTimestamp `
        -Value $Request.createdAtUtc `
        -Path '$.createdAtUtc'
    $resultCompletedAt = ConvertTo-RepoFlowReviewTimestamp `
        -Value $Result.completedAtUtc `
        -Path '$.completedAtUtc'

    if ($resultCompletedAt -lt $requestCreatedAt) {
        throw 'RepoFlow review result completion time predates its request.'
    }
}

function Get-RepoFlowReviewMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('request', 'result')]
        [string]$Kind
    )

    return "<!-- rf-review-$Kind`:v$script:RepoFlowReviewContractVersion -->"
}

function Get-RepoFlowReviewFence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Json
    )

    $maximumRun = 0

    foreach ($match in [regex]::Matches($Json, '`+')) {
        $maximumRun = [Math]::Max($maximumRun, $match.Length)
    }

    $length = [Math]::Max(3, $maximumRun + 1)
    return -join (@('`') * $length)
}
