function Get-RepoFlowCurrentBranch {
    [CmdletBinding()]
    param()

    $branch = (Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'branch',
        '--show-current'
    )).Text.Trim()

    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw 'RepoFlow does not support a detached HEAD.'
    }

    return $branch
}

function Get-RepoFlowGitOrigin {
    [CmdletBinding()]
    param()

    return (Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'remote',
        'get-url',
        'origin'
    )).Text.Trim()
}

function Normalize-RepoFlowGitOrigin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Origin
    )

    $value = $Origin.Trim()

    if ($value -match '^git@(?<host>[^:]+):(?<path>.+)$') {
        $value = "$($Matches.host)/$($Matches.path)"
    }
    elseif ($value -match '^ssh://git@(?<host>[^/]+)/(?<path>.+)$') {
        $value = "$($Matches.host)/$($Matches.path)"
    }
    elseif ($value -match '^https?://(?<host>[^/]+)/(?<path>.+)$') {
        $value = "$($Matches.host)/$($Matches.path)"
    }

    $value = $value.TrimEnd('/')
    $value = [regex]::Replace($value, '\.git$', '', 'IgnoreCase')

    return $value.ToLowerInvariant()
}

function Assert-RepoFlowRepositoryIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $actualOrigin = Get-RepoFlowGitOrigin
    $actualNormalised = Normalize-RepoFlowGitOrigin -Origin $actualOrigin
    $expectedNormalised = @(
        $Config.repository.expectedOrigins |
        ForEach-Object { Normalize-RepoFlowGitOrigin -Origin ([string]$_) }
    )

    if ($expectedNormalised -notcontains $actualNormalised) {
        throw "This is not the configured repository. Origin: $actualOrigin"
    }

    $slugOrigin = Normalize-RepoFlowGitOrigin -Origin "https://github.com/$($Config.repository.slug).git"

    if ($actualNormalised -ne $slugOrigin) {
        throw "Configured repository slug '$($Config.repository.slug)' does not match origin '$actualOrigin'."
    }
}

function Get-RepoFlowWorkingTreeStatus {
    [CmdletBinding()]
    param()

    return (Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'status',
        '--porcelain'
    )).Text.Trim()
}

function Invoke-RepoFlowLocalValidation {
    [CmdletBinding()]
    param()

    return Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'diff',
        '--check'
    ) -AllowFailure
}

function Assert-RepoFlowCleanWorkingTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    if (-not $Config.git.requireCleanWorkingTree) {
        return
    }

    $status = Get-RepoFlowWorkingTreeStatus

    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw 'Working tree is not clean. Commit, stash, or discard changes first.'
    }
}

function Get-RepoFlowChangedFileCount {
    [CmdletBinding()]
    param()

    $status = Get-RepoFlowWorkingTreeStatus

    if ([string]::IsNullOrWhiteSpace($status)) {
        return 0
    }

    return @(
        $status -split '\r?\n' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    ).Count
}

function Test-RepoFlowLocalBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch
    )

    $result = Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'show-ref',
        '--verify',
        '--quiet',
        "refs/heads/$Branch"
    ) -AllowFailure

    return $result.ExitCode -eq 0
}

function Test-RepoFlowRemoteBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch
    )

    $result = Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'ls-remote',
        '--exit-code',
        '--heads',
        'origin',
        $Branch
    ) -AllowFailure

    return $result.ExitCode -eq 0
}

function Update-RepoFlowBaseBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BaseBranch
    )

    Write-Host "[GIT] Updating $BaseBranch..."

    Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'fetch',
        'origin',
        $BaseBranch
    ) | Out-Null

    Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'pull',
        '--ff-only',
        'origin',
        $BaseBranch
    ) | Out-Null
}

function Prepare-RepoFlowBaseBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    Assert-RepoFlowCleanWorkingTree -Config $Config

    $baseBranch = [string]$Config.repository.baseBranch
    $repository = [string]$Config.repository.slug
    $currentBranch = Get-RepoFlowCurrentBranch

    if ($currentBranch -eq $baseBranch) {
        Update-RepoFlowBaseBranch -BaseBranch $baseBranch
        return
    }

    Write-Host "[GIT] Checking whether $currentBranch was merged..."
    $pullRequest = Get-RepoFlowLatestPullRequestForBranch -Branch $currentBranch -Repository $repository

    if ($null -eq $pullRequest) {
        throw "Could not find a pull request for branch '$currentBranch'. Switch to '$baseBranch' manually."
    }

    if ($pullRequest.state -ne 'MERGED' -or [string]::IsNullOrWhiteSpace([string]$pullRequest.mergedAt)) {
        throw "Branch '$currentBranch' has not been merged. PR: $($pullRequest.url)"
    }

    if ($pullRequest.baseRefName -ne $baseBranch) {
        throw "Branch '$currentBranch' was merged into '$($pullRequest.baseRefName)', not '$baseBranch'."
    }

    Write-Host "[GIT] Switching to $baseBranch..."
    Invoke-RepoFlowCommand -Command 'git' -Arguments @('switch', $baseBranch) | Out-Null
    Update-RepoFlowBaseBranch -BaseBranch $baseBranch

    if ($Config.git.deleteMergedLocalBranches) {
        Write-Host "[GIT] Removing merged local branch $currentBranch..."
        Invoke-RepoFlowCommand -Command 'git' -Arguments @('branch', '-D', $currentBranch) | Out-Null
    }
}

function New-RepoFlowBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch
    )

    Write-Host "[GIT] Creating $Branch..."
    Invoke-RepoFlowCommand -Command 'git' -Arguments @('switch', '-c', $Branch) | Out-Null
}

function Switch-RepoFlowExistingBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch
    )

    if (Test-RepoFlowLocalBranch -Branch $Branch) {
        Invoke-RepoFlowCommand -Command 'git' -Arguments @('switch', $Branch) | Out-Null
    }
    elseif (Test-RepoFlowRemoteBranch -Branch $Branch) {
        Invoke-RepoFlowCommand -Command 'git' -Arguments @(
            'fetch',
            'origin',
            $Branch
        ) | Out-Null

        Invoke-RepoFlowCommand -Command 'git' -Arguments @(
            'switch',
            '-c',
            $Branch,
            '--track',
            "origin/$Branch"
        ) | Out-Null
    }
    else {
        throw "Branch does not exist locally or on origin: $Branch"
    }

    Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'pull',
        '--ff-only',
        'origin',
        $Branch
    ) | Out-Null
}

function New-RepoFlowCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        $Config
    )

    Invoke-RepoFlowCommand -Command 'git' -Arguments @('add', '--all') | Out-Null

    $arguments = @('commit')

    if ($Config.git.signOffCommits) {
        $arguments += '-s'
    }

    $arguments += @('-m', $Message)
    Invoke-RepoFlowCommand -Command 'git' -Arguments $arguments | Out-Null
}

function Push-RepoFlowBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [switch]$SetUpstream
    )

    $arguments = @('push')

    if ($SetUpstream) {
        $arguments += @('-u', 'origin', $Branch)
    }
    else {
        $arguments += @('origin', $Branch)
    }

    Invoke-RepoFlowCommand -Command 'git' -Arguments $arguments | Out-Null
}

function Get-RepoFlowCommitHash {
    [CmdletBinding()]
    param()

    return (Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'rev-parse',
        'HEAD'
    )).Text.Trim()
}

function Get-RepoFlowShortCommitHash {
    [CmdletBinding()]
    param()

    return (Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'rev-parse',
        '--short',
        'HEAD'
    )).Text.Trim()
}


function Complete-RepoFlowPostMergeCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Config
    )

    $headBranch = [string]$PullRequest.headRefName
    $baseBranch = [string]$Config.repository.baseBranch
    $currentBranch = Get-RepoFlowCurrentBranch

    if ($currentBranch -eq $headBranch) {
        Write-Host "[GIT] Switching to $baseBranch..."
        Invoke-RepoFlowCommand `
            -Command 'git' `
            -Arguments @('switch', $baseBranch) |
            Out-Null

        Update-RepoFlowBaseBranch -BaseBranch $baseBranch
    }
    elseif ($currentBranch -eq $baseBranch) {
        Update-RepoFlowBaseBranch -BaseBranch $baseBranch
    }
    else {
        Write-Warning (
            "Current branch '$currentBranch' is neither '$headBranch' nor " +
            "'$baseBranch'. Local checkout was left unchanged."
        )
    }

    if (
        [bool]$Config.git.deleteMergedLocalBranches -and
        $currentBranch -ne $headBranch -and
        (Test-RepoFlowLocalBranch -Branch $headBranch)
    ) {
        Write-Host "[GIT] Removing merged local branch $headBranch..."
        Invoke-RepoFlowCommand `
            -Command 'git' `
            -Arguments @('branch', '-D', $headBranch) |
            Out-Null
    }
    elseif (
        [bool]$Config.git.deleteMergedLocalBranches -and
        $currentBranch -eq $headBranch -and
        (Test-RepoFlowLocalBranch -Branch $headBranch)
    ) {
        Write-Host "[GIT] Removing merged local branch $headBranch..."
        Invoke-RepoFlowCommand `
            -Command 'git' `
            -Arguments @('branch', '-D', $headBranch) |
            Out-Null
    }

    if (
        [bool]$Config.pullRequest.deleteBranchOnMerge -and
        (Test-RepoFlowRemoteBranch -Branch $headBranch)
    ) {
        Write-Host "[GIT] Removing merged remote branch $headBranch..."
        $deleteResult = Invoke-RepoFlowCommand `
            -Command 'git' `
            -Arguments @('push', 'origin', '--delete', $headBranch) `
            -AllowFailure

        if ($deleteResult.ExitCode -ne 0) {
            Write-Warning (
                "Remote branch '$headBranch' could not be deleted: " +
                $deleteResult.Text
            )
        }
    }

    if ([bool]$Config.git.pruneRemoteReferences) {
        Invoke-RepoFlowCommand `
            -Command 'git' `
            -Arguments @('fetch', '--prune', 'origin') `
            -AllowFailure |
            Out-Null
    }
}
