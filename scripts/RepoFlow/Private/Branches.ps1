function Get-RepoFlowLocalBranches {
    [CmdletBinding()]
    param()

    $result = Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        'branch',
        '--format=%(refname:short)'
    )

    return @(
        $result.Text -split '\r?\n' |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

function Get-RepoFlowMergedLocalBranches {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $repository = [string]$Config.repository.slug
    $baseBranch = [string]$Config.repository.baseBranch
    $currentBranch = Get-RepoFlowCurrentBranch
    $protected = @('main', 'master', $baseBranch, $currentBranch) | Sort-Object -Unique
    $candidates = @(
        Get-RepoFlowLocalBranches |
        Where-Object { $protected -notcontains $_ }
    )

    $merged = New-Object System.Collections.Generic.List[object]

    foreach ($branch in $candidates) {
        $pullRequest = Get-RepoFlowLatestPullRequestForBranch -Branch $branch -Repository $repository

        if (
            $null -ne $pullRequest -and
            $pullRequest.state -eq 'MERGED' -and
            $pullRequest.baseRefName -eq $baseBranch -and
            -not [string]::IsNullOrWhiteSpace([string]$pullRequest.mergedAt)
        ) {
            $merged.Add([pscustomobject]@{
                branch = $branch
                pullRequest = $pullRequest
            })
        }
    }

    return @($merged)
}

function Invoke-RepoFlowBranchCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config,

        [switch]$Apply
    )

    Assert-RepoFlowCleanWorkingTree -Config $Config
    $branches = @(Get-RepoFlowMergedLocalBranches -Config $Config)

    if ($branches.Count -eq 0) {
        Write-Host 'No merged local branches are safe to delete.'
        return
    }

    Write-Host 'Merged local branches:'
    foreach ($item in $branches) {
        Write-Host " - $($item.branch) (PR #$($item.pullRequest.number))"
    }

    if (-not $Apply) {
        Write-Host ''
        Write-Host 'PLAN ONLY - no branches were deleted.'
        Write-Host 'Run again with -Apply to delete these merged branches.'
        return
    }

    foreach ($item in $branches) {
        Write-Host "[GIT] Deleting $($item.branch)..."
        Invoke-RepoFlowCommand -Command 'git' -Arguments @(
            'branch',
            '-d',
            $item.branch
        ) | Out-Null
    }

    if ($Config.git.pruneRemoteReferences) {
        Write-Host '[GIT] Pruning remote references...'
        Invoke-RepoFlowCommand -Command 'git' -Arguments @('fetch', '--prune') | Out-Null
    }

    Write-Host 'Merged local branches deleted.'
}
