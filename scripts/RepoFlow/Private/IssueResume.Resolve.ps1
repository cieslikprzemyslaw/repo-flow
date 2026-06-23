function Resolve-RepoFlowIssueResumePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Context,

        [Parameter(Mandatory)]
        [int]$Number
    )

    $config = $Context.Config
    $stateConfigPath = [string]$Context.RepositorySelection.Registry.ConfigPath
    $repositoryName = [string]$Context.RepositorySelection.Repository.name
    $repositorySlug = [string]$config.repository.slug
    $issue = Get-RepoFlowIssue -Number $Number -Repository $repositorySlug
    $branch = Get-RepoFlowIssueBranchName -Issue $issue
    $history = Get-RepoFlowIssueRunHistory `
        -ConfigPath $stateConfigPath `
        -RepositoryRoot $Context.RepositoryRoot `
        -IssueNumber $Number

    $record = if ($null -ne $history.Active) {
        $history.Active
    }
    else {
        $history.Latest
    }

    if ($null -eq $record) {
        throw (
            "No saved RepoFlow run exists for issue #$Number. " +
            "Use 'issue run' for the first implementation."
        )
    }

    Assert-RepoFlowResumeRecordIdentity `
        -RunRecord $record `
        -RepositoryRoot $Context.RepositoryRoot `
        -Repository $repositoryName `
        -RepositorySlug $repositorySlug `
        -IssueNumber $Number `
        -Branch $branch

    $branchState = Get-RepoFlowIssueResumeBranchState -Branch $branch
    $pullRequest = Get-RepoFlowResumePullRequest `
        -RunRecord $record `
        -Branch $branch `
        -Repository $repositorySlug

    $ciState = $null
    $trustedComment = $null

    if ($null -ne $pullRequest -and [string]$pullRequest.state -eq 'OPEN') {
        $ciState = Get-RepoFlowPrCheckState `
            -PullRequestNumber ([int]$pullRequest.number) `
            -Repository $repositorySlug
        $trustedComment = Get-RepoFlowLatestUnprocessedTrustedComment `
            -PullRequest $pullRequest `
            -Config $config `
            -RunRecords @($history.Records)
    }

    $plan = New-RepoFlowIssueResumePlan `
        -RunHistory $history `
        -Issue $issue `
        -BranchState $branchState `
        -PullRequest $pullRequest `
        -CiState $ciState `
        -TrustedComment $trustedComment `
        -Config $config

    return [pscustomobject]@{
        Plan = $plan
        Issue = $issue
        BranchState = $branchState
        History = $history
        StateConfigPath = $stateConfigPath
        RepositoryName = $repositoryName
        RepositorySlug = $repositorySlug
    }
}

function Set-RepoFlowResumeBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $BranchState
    )

    if ([string]$BranchState.CurrentBranch -eq [string]$BranchState.Branch) {
        return
    }

    if ($BranchState.IsDirty) {
        throw (
            "Cannot switch from '$($BranchState.CurrentBranch)' to " +
            "'$($BranchState.Branch)' while the working tree is dirty."
        )
    }

    if (-not $BranchState.LocalExists) {
        throw (
            "Cannot resume because local branch '$($BranchState.Branch)' " +
            'does not exist.'
        )
    }

    Write-Host "[GIT] Switching to $($BranchState.Branch)..."
    Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'switch',
        [string]$BranchState.Branch
    ) | Out-Null
}
