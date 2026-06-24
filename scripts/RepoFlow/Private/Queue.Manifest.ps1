function Resolve-RepoFlowQueueManifestPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath
    )

    if ([System.IO.Path]::IsPathRooted($ManifestPath)) {
        return [System.IO.Path]::GetFullPath($ManifestPath)
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path (Get-Location).Path $ManifestPath)
    )
}

function Get-RepoFlowQueueManifestHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath
    )

    $bytes = [System.IO.File]::ReadAllBytes($ManifestPath)
    $digest = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($digest).ToLowerInvariant()
}

function Read-RepoFlowQueueManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath
    )

    $resolvedPath = Resolve-RepoFlowQueueManifestPath -ManifestPath $ManifestPath

    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "RepoFlow queue manifest was not found: $resolvedPath"
    }

    try {
        $raw = Get-Content -LiteralPath $resolvedPath -Raw -Encoding utf8 |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "RepoFlow queue manifest contains invalid JSON: $resolvedPath"
    }

    Assert-RepoFlowAllowedProperties `
        -Object $raw `
        -Allowed @('$schema', 'schemaVersion', 'name', 'repository', 'tasks') `
        -Path '$'

    $schemaVersion = Get-RepoFlowProperty `
        -Object $raw `
        -Name 'schemaVersion' `
        -Default $null

    if ($schemaVersion -ne 1) {
        throw "Queue manifest '$resolvedPath' must use schemaVersion 1."
    }

    $name = Get-RepoFlowProperty -Object $raw -Name 'name' -Default $null
    if ($null -ne $name) {
        Assert-RepoFlowString -Value $name -Path '$.name'
    }

    $defaultRepository = Get-RepoFlowProperty `
        -Object $raw `
        -Name 'repository' `
        -Default $null
    if ($null -ne $defaultRepository) {
        Assert-RepoFlowString -Value $defaultRepository -Path '$.repository'
    }

    $tasks = Get-RepoFlowProperty -Object $raw -Name 'tasks' -Default $null
    Assert-RepoFlowArray -Value $tasks -Path '$.tasks'

    if (@($tasks).Count -eq 0) {
        throw "Queue manifest '$resolvedPath' must contain at least one task."
    }

    $normalisedTasks = [System.Collections.Generic.List[object]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    for ($index = 0; $index -lt @($tasks).Count; $index++) {
        $task = @($tasks)[$index]
        $path = '$.tasks[{0}]' -f $index

        Assert-RepoFlowAllowedProperties `
            -Object $task `
            -Allowed @(
                'issueNumber',
                'repository',
                'ciMode',
                'automatedReview'
            ) `
            -Path $path

        $issueNumber = 0
        $rawIssueNumber = Get-RepoFlowProperty `
            -Object $task `
            -Name 'issueNumber' `
            -Default $null

        if (
            -not [int]::TryParse([string]$rawIssueNumber, [ref]$issueNumber) -or
            $issueNumber -le 0
        ) {
            throw "Queue manifest value '$path.issueNumber' must be a positive integer."
        }

        $repository = Get-RepoFlowProperty `
            -Object $task `
            -Name 'repository' `
            -Default $defaultRepository
        if ($null -ne $repository) {
            Assert-RepoFlowString -Value $repository -Path "$path.repository"
        }

        $ciMode = Get-RepoFlowProperty `
            -Object $task `
            -Name 'ciMode' `
            -Default $null
        if (
            $null -ne $ciMode -and
            [string]$ciMode -notin @('skip', 'observe', 'require-passing')
        ) {
            throw (
                "Queue manifest value '$path.ciMode' must be skip, " +
                'observe, or require-passing.'
            )
        }

        $automatedReview = Get-RepoFlowProperty `
            -Object $task `
            -Name 'automatedReview' `
            -Default $true
        Assert-RepoFlowBoolean `
            -Value $automatedReview `
            -Path "$path.automatedReview"

        $identity = '{0}#{1}' -f ([string]$repository), $issueNumber
        if (-not $seen.Add($identity)) {
            throw (
                "Queue manifest contains duplicate task '$identity'. " +
                'Each repository and issue pair may appear only once.'
            )
        }

        $normalisedTasks.Add([pscustomobject][ordered]@{
            position = $index
            issueNumber = $issueNumber
            repository = if ($null -eq $repository) { $null } else { [string]$repository }
            ciMode = if ($null -eq $ciMode) { $null } else { [string]$ciMode }
            automatedReview = [bool]$automatedReview
        }) | Out-Null
    }

    return [pscustomobject][ordered]@{
        schemaVersion = 1
        name = if ($null -eq $name) {
            [System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)
        }
        else {
            [string]$name
        }
        path = $resolvedPath
        hash = Get-RepoFlowQueueManifestHash -ManifestPath $resolvedPath
        tasks = $normalisedTasks.ToArray()
    }
}
