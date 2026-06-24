function Assert-RepoFlowReviewNoDuplicateJsonProperties {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.Json.JsonElement]$Element
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $names = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::Ordinal
        )

        foreach ($property in $Element.EnumerateObject()) {
            if (-not $names.Add($property.Name)) {
                throw 'RepoFlow review payload contains duplicate JSON property names.'
            }

            Assert-RepoFlowReviewNoDuplicateJsonProperties `
                -Element $property.Value
        }

        return
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($item in $Element.EnumerateArray()) {
            Assert-RepoFlowReviewNoDuplicateJsonProperties -Element $item
        }
    }
}

function Assert-RepoFlowReviewJsonDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Json,

        [Parameter(Mandatory)]
        [ValidateSet('request', 'result')]
        [string]$Kind
    )

    try {
        $document = [System.Text.Json.JsonDocument]::Parse($Json)
    }
    catch {
        throw "RepoFlow review $Kind payload is not valid JSON."
    }

    try {
        Assert-RepoFlowReviewNoDuplicateJsonProperties `
            -Element $document.RootElement
    }
    finally {
        $document.Dispose()
    }
}

function ConvertTo-RepoFlowReviewComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Envelope,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$HumanSummary
    )

    $kindValue = [string](
        Get-RepoFlowProperty -Object $Envelope -Name 'kind' -Default ''
    )

    $kind = switch ($kindValue) {
        'review_request' { 'request' }
        'review_result' { 'result' }
        default {
            throw "Unsupported RepoFlow review envelope kind: '$kindValue'."
        }
    }

    if ($kind -eq 'request') {
        Assert-RepoFlowReviewRequestEnvelope -Request $Envelope
    }
    else {
        Assert-RepoFlowReviewResultEnvelope -Result $Envelope
    }

    if (
        -not [string]::IsNullOrWhiteSpace($HumanSummary) -and
        $HumanSummary -match '(?im)^\s*<!--\s*rf-review-(?:request|result):v\d+\s*-->\s*$'
    ) {
        throw 'Human-readable review Markdown cannot contain a review contract marker.'
    }

    $json = ConvertTo-RepoFlowReviewJson -Envelope $Envelope

    if ($json.Length -gt $script:RepoFlowReviewEnvelopeMaximumCharacters) {
        throw (
            "RepoFlow review $kind payload exceeds the " +
            "$script:RepoFlowReviewEnvelopeMaximumCharacters-character limit."
        )
    }

    $fence = Get-RepoFlowReviewFence -Json $json
    $parts = [System.Collections.Generic.List[string]]::new()

    if (-not [string]::IsNullOrWhiteSpace($HumanSummary)) {
        $parts.Add($HumanSummary.Trim())
    }

    $parts.Add((Get-RepoFlowReviewMarker -Kind $kind))
    $parts.Add("${fence}json`n$json`n$fence")
    $comment = $parts -join "`n`n"

    if ($comment.Length -gt $script:RepoFlowReviewCommentMaximumCharacters) {
        throw (
            'RepoFlow review comment exceeds the ' +
            "$script:RepoFlowReviewCommentMaximumCharacters-character limit."
        )
    }

    return $comment
}

function ConvertFrom-RepoFlowReviewComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        [ValidateSet('request', 'result')]
        [string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw 'RepoFlow review comment is empty.'
    }

    if ($Text.Length -gt $script:RepoFlowReviewCommentMaximumCharacters) {
        throw (
            'RepoFlow review comment exceeds the ' +
            "$script:RepoFlowReviewCommentMaximumCharacters-character limit."
        )
    }

    $allMarkerPattern = (
        '(?im)^\s*<!--\s*rf-review-' +
        '(?<kind>request|result):v(?<version>\d+)\s*-->\s*$'
    )
    $allMarkers = [regex]::Matches($Text, $allMarkerPattern)

    if ($allMarkers.Count -eq 0) {
        throw 'RepoFlow review comment does not contain a contract marker.'
    }

    if ($allMarkers.Count -gt 1) {
        throw 'RepoFlow review comment contains duplicate contract markers.'
    }

    $marker = $allMarkers[0]
    $actualKind = $marker.Groups['kind'].Value
    $version = $marker.Groups['version'].Value

    if ($actualKind -ne $Kind) {
        throw "RepoFlow review comment contains a '$actualKind' envelope, not '$Kind'."
    }

    if ($version -ne $script:RepoFlowReviewContractVersion) {
        throw "RepoFlow review contract version '$version' is unsupported."
    }

    $afterMarker = $Text.Substring($marker.Index + $marker.Length)
    $blockPattern = (
        '(?ms)\A\s*(?<fence>`{3,})(?:json)?[ \t]*\r?\n' +
        '(?<json>.*?)(?:\r?\n)\k<fence>(?!`)[ \t]*(?=\r?\n|\z)'
    )
    $block = [regex]::Match($afterMarker, $blockPattern)

    if (-not $block.Success) {
        throw 'RepoFlow review marker must be followed by one fenced JSON object.'
    }

    $json = $block.Groups['json'].Value

    if ($json.Length -gt $script:RepoFlowReviewEnvelopeMaximumCharacters) {
        throw (
            "RepoFlow review $Kind payload exceeds the " +
            "$script:RepoFlowReviewEnvelopeMaximumCharacters-character limit."
        )
    }

    Assert-RepoFlowReviewJsonDocument -Json $json -Kind $Kind
    Assert-RepoFlowReviewJsonSchema -Json $json -Kind $Kind

    try {
        $envelope = $json | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    }
    catch {
        throw "RepoFlow review $Kind payload is not valid JSON."
    }

    if ($Kind -eq 'request') {
        Assert-RepoFlowReviewRequestEnvelope -Request $envelope
    }
    else {
        Assert-RepoFlowReviewResultEnvelope -Result $envelope
    }

    return $envelope
}
