function ConvertTo-RepoFlowSlug {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value,

        [ValidateRange(10, 120)]
        [int]$MaximumLength = 55
    )

    $slug = $Value.ToLowerInvariant()
    $slug = [regex]::Replace($slug, '[^a-z0-9]+', '-').Trim('-')

    if ($slug.Length -gt $MaximumLength) {
        $slug = $slug.Substring(0, $MaximumLength).TrimEnd('-')
    }

    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw "Cannot create a branch slug from '$Value'."
    }

    return $slug
}

function Get-RepoFlowMarkdownSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Body,

        [Parameter(Mandatory)]
        [string]$Heading
    )

    $escapedHeading = [regex]::Escape($Heading)
    $pattern = "(?ms)^##\s+$escapedHeading\s*\r?\n(?<content>.*?)(?=^##\s+|\z)"
    $match = [regex]::Match($Body, $pattern)

    if (-not $match.Success) {
        return ''
    }

    return $match.Groups['content'].Value.Trim()
}

function Expand-RepoFlowMessageTemplate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Template,

        [Parameter(Mandatory)]
        [hashtable]$Values,

        [ValidateRange(20, 250)]
        [int]$MaximumLength = 100
    )

    $value = $Template

    foreach ($key in $Values.Keys) {
        $value = $value.Replace("{$key}", [string]$Values[$key])
    }

    $unknownPlaceholder = [regex]::Match($value, '\{[A-Za-z][A-Za-z0-9]*\}')
    if ($unknownPlaceholder.Success) {
        throw "Unknown message placeholder: $($unknownPlaceholder.Value)"
    }

    $value = $value.Trim()

    if ($value.Length -gt $MaximumLength) {
        $value = $value.Substring(0, $MaximumLength).TrimEnd()
    }

    return $value
}
