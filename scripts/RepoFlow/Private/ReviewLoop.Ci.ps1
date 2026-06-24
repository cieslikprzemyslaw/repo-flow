function Assert-RepoFlowPrReviewPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Config
    )

    if ([string]$PullRequest.state -ne 'OPEN') {
        throw "Pull request #$($PullRequest.number) is not open."
    }

    if (
        [string]$PullRequest.baseRefName -ne
        [string]$Config.repository.baseBranch
    ) {
        throw (
            "Pull request #$($PullRequest.number) targets " +
            "'$($PullRequest.baseRefName)', not " +
            "'$($Config.repository.baseBranch)'."
        )
    }

    if ([string]::IsNullOrWhiteSpace([string]$PullRequest.baseRefOid)) {
        throw "Pull request #$($PullRequest.number) did not report a base SHA."
    }
}

function Resolve-RepoFlowPrReviewCiState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        $Config,

        [Parameter(Mandatory)]
        [bool]$RequirePassingCi,

        [switch]$Wait,

        [AllowNull()]
        [string]$StateConfigPath,

        [AllowNull()]
        [string]$RunId,

        [string]$Phase = 'review-ci'
    )

    $checks = Get-RepoFlowPrCheckState `
        -PullRequestNumber $PullRequestNumber `
        -Repository $Repository

    if ($Wait -and [string]$checks.Status -eq 'pending') {
        $checks = Wait-RepoFlowPrChecks `
            -PullRequestNumber $PullRequestNumber `
            -Repository $Repository `
            -TimeoutSeconds ([int]$Config.ci.timeoutSeconds) `
            -PollSeconds ([int]$Config.ci.pollSeconds) `
            -StateConfigPath $StateConfigPath `
            -RunId $RunId `
            -Phase $Phase `
            -NoActivityWarningSeconds ([int](Get-RepoFlowProperty `
                -Object $Config.agent `
                -Name noActivityWarningSeconds `
                -Default 180))
    }

    if ($Wait -and [string]$checks.Status -eq 'pending') {
        throw 'CI remained pending until the PR-review timeout.'
    }

    if ($RequirePassingCi -and [string]$checks.Status -ne 'passed') {
        throw (
            "PR review requires passing CI, but the current status is " +
            "'$($checks.Status)'."
        )
    }

    return $checks
}

function Show-RepoFlowPrReviewPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Checks,

        [Parameter(Mandatory)]
        $Options
    )

    Write-Host ''
    Write-Host "PR:                #$($PullRequest.number) $($PullRequest.title)"
    Write-Host "URL:               $($PullRequest.url)"
    Write-Host "Head SHA:          $($PullRequest.headRefOid)"
    Write-Host "CI status:         $($Checks.Status)"
    Write-Host "Require CI pass:   $($Options.RequirePassingCi)"
    Write-Host "Max review cycles: $($Options.MaxReviewCycles)"
    Write-Host "Max repair cycles: $($Options.MaxRepairCycles)"
    Write-Host ''
}
