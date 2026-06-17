function Get-RepoFlowAgentRunStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $gitPath = (Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'rev-parse',
        '--git-path',
        'repo-flow/agent-run.json'
    )).Text.Trim()

    if ([string]::IsNullOrWhiteSpace($gitPath)) {
        throw 'Could not resolve the RepoFlow agent-run state path.'
    }

    if ([System.IO.Path]::IsPathRooted($gitPath)) {
        return [System.IO.Path]::GetFullPath($gitPath)
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path $RepositoryRoot $gitPath)
    )
}

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

function Read-RepoFlowAgentRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $path = Get-RepoFlowAgentRunStatePath -RepositoryRoot $RepositoryRoot

    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $null
    }

    try {
        return Get-Content -LiteralPath $path -Raw -Encoding utf8 |
            ConvertFrom-Json
    }
    catch {
        throw "RepoFlow agent-run state is invalid: $path"
    }
}

function Write-RepoFlowAgentRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        $State
    )

    $path = Get-RepoFlowAgentRunStatePath -RepositoryRoot $RepositoryRoot
    $directory = Split-Path -Parent $path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $json = $State | ConvertTo-Json -Depth 8
    $temporaryPath = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)

    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            $utf8WithoutBom
        )
        [System.IO.File]::Move($temporaryPath, $path, $true)
    }
    finally {
        Remove-Item `
            -LiteralPath $temporaryPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Remove-RepoFlowAgentRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $path = Get-RepoFlowAgentRunStatePath -RepositoryRoot $RepositoryRoot
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}

function Get-RepoFlowRemoteBranchCommitHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch
    )

    Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'fetch',
        'origin',
        $Branch
    ) | Out-Null

    return (Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'rev-parse',
        "origin/$Branch"
    )).Text.Trim()
}

function Assert-RepoFlowReviewResumeAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [long]$PrCommentId
    )

    Assert-RepoFlowNoGitOperationInProgress -RepositoryRoot $RepositoryRoot

    $currentBranch = Get-RepoFlowCurrentBranch

    if ($currentBranch -ne $Branch) {
        throw (
            "Resume requires the issue branch '$Branch' to be checked out. " +
            "Current branch: '$currentBranch'. RepoFlow will not switch " +
            'branches while preserving a dirty working tree.'
        )
    }

    $status = Get-RepoFlowWorkingTreeStatus

    if ([string]::IsNullOrWhiteSpace($status)) {
        throw (
            'Resume requires existing uncommitted changes from an ' +
            'interrupted agent run, but the working tree is clean.'
        )
    }

    $currentHead = Get-RepoFlowCommitHash
    $remoteHead = Get-RepoFlowRemoteBranchCommitHash -Branch $Branch

    if ($currentHead -ne $remoteHead) {
        throw (
            "Resume requires local HEAD to match origin/$Branch. " +
            'Commit, push, or reconcile local commits before resuming.'
        )
    }

    $state = Read-RepoFlowAgentRunState -RepositoryRoot $RepositoryRoot

    if ($null -eq $state) {
        Write-Warning (
            'No previous RepoFlow checkpoint exists. -Resume will explicitly ' +
            'adopt the current uncommitted changes after validating the branch ' +
            'and remote HEAD. Review git status before continuing.'
        )
        return $null
    }

    $expectedRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $stateRoot = [System.IO.Path]::GetFullPath([string]$state.repositoryRoot)

    $rootsMatch = [string]::Equals(
        $stateRoot,
        $expectedRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )

    if (-not $rootsMatch) {
        throw 'The interrupted-run checkpoint belongs to a different repository root.'
    }

    if ([string]$state.repository -ne $Repository) {
        throw 'The interrupted-run checkpoint belongs to a different repository.'
    }

    if ([string]$state.branch -ne $Branch) {
        throw 'The interrupted-run checkpoint belongs to a different branch.'
    }

    if ([int]$state.issueNumber -ne $IssueNumber) {
        throw 'The interrupted-run checkpoint belongs to a different issue.'
    }

    if ([int]$state.pullRequestNumber -ne $PullRequestNumber) {
        throw 'The interrupted-run checkpoint belongs to a different pull request.'
    }

    if ([string]$state.prCommentId -ne [string]$PrCommentId) {
        throw (
            'The selected PR comment does not match the interrupted-run ' +
            'checkpoint. Resume with the original -PrCommentId.'
        )
    }

    if ([string]$state.baselineHead -ne $currentHead) {
        throw (
            'HEAD changed after the interrupted run started. RepoFlow will ' +
            'not combine the saved working tree with a different baseline.'
        )
    }

    if ([string]$state.status -notin @('running', 'interrupted')) {
        throw "The agent-run checkpoint cannot be resumed from status '$($state.status)'."
    }

    return $state
}

function Start-RepoFlowReviewAgentRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [long]$PrCommentId,

        [Parameter(Mandatory)]
        $Config,

        [switch]$AdoptedExistingChanges
    )

    $existing = Read-RepoFlowAgentRunState -RepositoryRoot $RepositoryRoot
    $attempts = if ($null -eq $existing) {
        1
    }
    else {
        [int]$existing.attempts + 1
    }
    $now = [DateTimeOffset]::UtcNow.ToString('o')
    $startedAt = if (
        $null -ne $existing -and
        -not [string]::IsNullOrWhiteSpace([string]$existing.startedAtUtc)
    ) {
        [string]$existing.startedAtUtc
    }
    else {
        $now
    }

    $state = [pscustomobject][ordered]@{
        schemaVersion = 1
        operation = 'issue-continue-review-feedback'
        status = 'running'
        repositoryRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
        repository = $Repository
        branch = $Branch
        issueNumber = $IssueNumber
        pullRequestNumber = $PullRequestNumber
        prCommentId = [string]$PrCommentId
        baselineHead = Get-RepoFlowCommitHash
        provider = [string]$Config.agent.provider
        model = [string]$Config.agent.model
        attempts = $attempts
        adoptedExistingChanges = [bool]$AdoptedExistingChanges
        startedAtUtc = $startedAt
        updatedAtUtc = $now
        changedFileCount = Get-RepoFlowChangedFileCount
        lastError = $null
    }

    Write-RepoFlowAgentRunState `
        -RepositoryRoot $RepositoryRoot `
        -State $state

    return $state
}

function Set-RepoFlowAgentRunInterrupted {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$ErrorMessage
    )

    $state = Read-RepoFlowAgentRunState -RepositoryRoot $RepositoryRoot

    if ($null -eq $state) {
        return
    }

    $state.status = 'interrupted'
    $state.updatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $state.changedFileCount = Get-RepoFlowChangedFileCount
    $state.lastError = Get-RepoFlowBoundedText `
        -Text $ErrorMessage `
        -MaximumCharacters 4000 `
        -HeadCharacters 1000

    Write-RepoFlowAgentRunState `
        -RepositoryRoot $RepositoryRoot `
        -State $state
}
