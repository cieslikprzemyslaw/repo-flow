function Get-RepoFlowIssueRunHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [int]$IssueNumber
    )

    $expectedRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)

    $records = @(
        Get-RepoFlowRunRecords -ConfigPath $ConfigPath |
        Where-Object {
            [string]::Equals(
                [System.IO.Path]::GetFullPath([string]$_.repositoryRoot),
                $expectedRoot,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -and
            [int]$_.issueNumber -eq $IssueNumber -and
            [string]$_.operation -in @(
                'issue-run',
                'issue-continue-review-feedback'
            )
        }
    )

    $activeRecords = @(
        $records |
        Where-Object { [string]$_.status -in @('running', 'paused') }
    )

    if ($activeRecords.Count -gt 1) {
        $runIds = @($activeRecords | ForEach-Object { [string]$_.runId }) -join ', '
        throw (
            "Issue #$IssueNumber has multiple active RepoFlow runs: $runIds. " +
            'Complete or abandon the stale run explicitly before resuming.'
        )
    }

    $latest = $records | Select-Object -First 1

    return [pscustomobject]@{
        Records = $records
        Active = if ($activeRecords.Count -eq 1) { $activeRecords[0] } else { $null }
        Latest = $latest
    }
}

function Get-RepoFlowIssueResumeBranchState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch
    )

    $localExists = Test-RepoFlowLocalBranch -Branch $Branch
    $remoteExists = Test-RepoFlowRemoteBranch -Branch $Branch

    return [pscustomobject]@{
        Branch = $Branch
        CurrentBranch = Get-RepoFlowCurrentBranch
        IsDirty = -not [string]::IsNullOrWhiteSpace(
            (Get-RepoFlowWorkingTreeStatus)
        )
        LocalExists = $localExists
        RemoteExists = $remoteExists
        LocalSha = if ($localExists) {
            Get-RepoFlowLocalBranchCommitHash -Branch $Branch
        }
        else {
            $null
        }
        RemoteSha = if ($remoteExists) {
            Get-RepoFlowRemoteBranchCommitHash -Branch $Branch
        }
        else {
            $null
        }
    }
}

function Get-RepoFlowResumePullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RunRecord,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $branchPullRequest = Get-RepoFlowLatestPullRequestForBranch `
        -Branch $Branch `
        -Repository $Repository

    if ([int]$RunRecord.pullRequestNumber -le 0) {
        if ($null -eq $branchPullRequest) {
            return $null
        }

        return Get-RepoFlowPullRequest `
            -Number ([int]$branchPullRequest.number) `
            -Repository $Repository
    }

    $savedPullRequest = Get-RepoFlowPullRequest `
        -Number ([int]$RunRecord.pullRequestNumber) `
        -Repository $Repository

    if ([string]$savedPullRequest.headRefName -ne $Branch) {
        throw (
            "Saved PR #$($savedPullRequest.number) uses branch " +
            "'$($savedPullRequest.headRefName)', not '$Branch'."
        )
    }

    if (
        $null -ne $branchPullRequest -and
        [int]$branchPullRequest.number -ne [int]$savedPullRequest.number
    ) {
        throw (
            "Saved PR #$($savedPullRequest.number) conflicts with PR " +
            "#$($branchPullRequest.number) discovered for branch '$Branch'."
        )
    }

    return $savedPullRequest
}

function Get-RepoFlowLatestUnprocessedTrustedComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Config,

        [AllowEmptyCollection()]
        [object[]]$RunRecords = @()
    )

    if (-not [bool]$Config.reviewFeedback.enabled) {
        return $null
    }

    $processedIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($record in @($RunRecords)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$record.prCommentId)) {
            $processedIds.Add([string]$record.prCommentId) | Out-Null
        }
    }

    $comments = @(
        Get-RepoFlowPullRequestComments `
            -PullRequestNumber ([int]$PullRequest.number) `
            -Repository ([string]$Config.repository.slug) |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_.body) -and
            (Test-RepoFlowTrustedComment -Comment $_ -Config $Config) -and
            -not $processedIds.Contains([string]$_.id)
        } |
        Sort-Object -Property created_at -Descending
    )

    if ($comments.Count -eq 0) {
        return $null
    }

    return $comments[0]
}

function Assert-RepoFlowResumeRecordIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RunRecord,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$RepositorySlug,

        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [string]$Branch
    )

    $expectedRoot = [System.IO.Path]::GetFullPath($RepositoryRoot)
    $actualRoot = [System.IO.Path]::GetFullPath(
        [string]$RunRecord.repositoryRoot
    )

    if (-not [string]::Equals(
        $actualRoot,
        $expectedRoot,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The saved run belongs to a different repository root.'
    }

    if (-not [string]::Equals(
        [string]$RunRecord.repository,
        $Repository,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The saved run belongs to a different configured repository.'
    }

    if (-not [string]::Equals(
        [string]$RunRecord.repositorySlug,
        $RepositorySlug,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw 'The saved run belongs to a different GitHub repository.'
    }

    if ([int]$RunRecord.issueNumber -ne $IssueNumber) {
        throw 'The saved run belongs to a different issue.'
    }

    if ([string]$RunRecord.branch -ne $Branch) {
        throw (
            "The saved branch '$($RunRecord.branch)' conflicts with the " +
            "current deterministic issue branch '$Branch'."
        )
    }
}

function Assert-RepoFlowResumePullRequestIdentity {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $PullRequest,

        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$BaseBranch
    )

    if ($null -eq $PullRequest) {
        return
    }

    if ([string]$PullRequest.headRefName -ne $Branch) {
        throw (
            "Pull request #$($PullRequest.number) uses head branch " +
            "'$($PullRequest.headRefName)', not '$Branch'."
        )
    }

    if ([string]$PullRequest.baseRefName -ne $BaseBranch) {
        throw (
            "Pull request #$($PullRequest.number) targets " +
            "'$($PullRequest.baseRefName)', not '$BaseBranch'."
        )
    }
}

function Test-RepoFlowResumeLiveHeadConsensus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $BranchState,

        [AllowNull()]
        $PullRequest
    )

    if (-not $BranchState.LocalExists -or -not $BranchState.RemoteExists) {
        return $false
    }

    if ([string]$BranchState.LocalSha -ne [string]$BranchState.RemoteSha) {
        return $false
    }

    if (
        $null -ne $PullRequest -and
        -not [string]::IsNullOrWhiteSpace([string]$PullRequest.headRefOid) -and
        [string]$PullRequest.headRefOid -ne [string]$BranchState.RemoteSha
    ) {
        return $false
    }

    return $true
}
