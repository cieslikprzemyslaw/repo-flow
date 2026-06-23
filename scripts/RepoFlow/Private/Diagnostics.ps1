function Get-RepoFlowBoundedText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [ValidateRange(256, 1000000)]
        [int]$MaximumCharacters = 24000,

        [ValidateRange(0, 1000000)]
        [int]$HeadCharacters = 4000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    if ($Text.Length -le $MaximumCharacters) {
        return $Text
    }

    $omittedCharacters = $Text.Length - $MaximumCharacters
    $marker = (
        "{0}... [RepoFlow omitted {1:N0} characters] ...{0}" -f
        [Environment]::NewLine,
        $omittedCharacters
    )
    $availableCharacters = [Math]::Max(0, $MaximumCharacters - $marker.Length)
    $effectiveHeadLength = [Math]::Min($HeadCharacters, $availableCharacters)
    $tailLength = $availableCharacters - $effectiveHeadLength
    $head = if ($effectiveHeadLength -gt 0) {
        $Text.Substring(0, $effectiveHeadLength)
    }
    else {
        ''
    }
    $tail = if ($tailLength -gt 0) {
        $Text.Substring($Text.Length - $tailLength, $tailLength)
    }
    else {
        ''
    }

    return "$head$marker$tail"
}

function Get-RepoFlowPullRequestChangedFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseBranch
    )

    $result = Invoke-RepoFlowCommand `
        -Command 'git' `
        -Arguments @(
            'diff',
            '--name-only',
            '--diff-filter=ACMRTUXB',
            "origin/$BaseBranch...HEAD"
        ) `
        -AllowFailure

    if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
        return @()
    }

    $files = [System.Collections.Generic.List[string]]::new()

    foreach ($line in @($result.Text -split '\r?\n')) {
        $path = $line.Trim()

        if (-not [string]::IsNullOrWhiteSpace($path) -and -not $files.Contains($path)) {
            $files.Add($path)
        }
    }

    return $files.ToArray()
}

function Get-RepoFlowWorkingTreeChangedFiles {
    [CmdletBinding()]
    param()

    $files = [System.Collections.Generic.List[string]]::new()
    $commands = @(
        @('diff', '--name-only', '--diff-filter=ACMRTUXB'),
        @('diff', '--cached', '--name-only', '--diff-filter=ACMRTUXB'),
        @('ls-files', '--others', '--exclude-standard')
    )

    foreach ($arguments in $commands) {
        $result = Invoke-RepoFlowCommand `
            -Command 'git' `
            -Arguments $arguments `
            -AllowFailure

        if ($result.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
            continue
        }

        foreach ($line in @($result.Text -split '\r?\n')) {
            $path = $line.Trim()

            if (-not [string]::IsNullOrWhiteSpace($path) -and -not $files.Contains($path)) {
                $files.Add($path)
            }
        }
    }

    return $files.ToArray()
}

function Format-RepoFlowChangedFiles {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Files
    )

    $normalisedFiles = @(
        $Files |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique
    )

    if ($normalisedFiles.Count -eq 0) {
        return '- No changed files were reported.'
    }

    return (
        $normalisedFiles |
        ForEach-Object { "- $_" }
    ) -join [Environment]::NewLine
}

function Get-RepoFlowPullRequestDiffStat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseBranch
    )

    $result = Invoke-RepoFlowCommand `
        -Command 'git' `
        -Arguments @(
            'diff',
            '--stat',
            "origin/$BaseBranch...HEAD"
        ) `
        -AllowFailure

    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return ''
    }

    return Get-RepoFlowBoundedText `
        -Text $result.Text `
        -MaximumCharacters 8000 `
        -HeadCharacters 3000
}
