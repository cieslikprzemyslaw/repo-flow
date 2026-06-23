function Get-RepoFlowLocalBranchCommitHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch
    )

    $result = Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'rev-parse',
        "refs/heads/$Branch"
    ) -AllowFailure

    if ($result.ExitCode -ne 0) {
        return $null
    }

    return $result.Text.Trim()
}

function Get-RepoFlowRemoteBranchCommitHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch
    )

    $result = Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'ls-remote',
        '--heads',
        'origin',
        $Branch
    ) -AllowFailure

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return $null
    }

    $line = @(
        $result.Text -split '\r?\n' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ) | Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace([string]$line)) {
        return $null
    }

    return ([string]$line -split '\s+')[0]
}

function Test-RepoFlowCommitAncestor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Ancestor,

        [Parameter(Mandatory)]
        [string]$Descendant
    )

    $result = Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'merge-base',
        '--is-ancestor',
        $Ancestor,
        $Descendant
    ) -AllowFailure

    return $result.ExitCode -eq 0
}

function Get-RepoFlowCommitCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$FromExclusive,

        [Parameter(Mandatory)]
        [string]$ToInclusive
    )

    $result = Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'rev-list',
        '--count',
        "$FromExclusive..$ToInclusive"
    ) -AllowFailure

    if ($result.ExitCode -ne 0) {
        return -1
    }

    $count = -1
    if (-not [int]::TryParse($result.Text.Trim(), [ref]$count)) {
        return -1
    }

    return $count
}
