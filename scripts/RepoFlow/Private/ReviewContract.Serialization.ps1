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
