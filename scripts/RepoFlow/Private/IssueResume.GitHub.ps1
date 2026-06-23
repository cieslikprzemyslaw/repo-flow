function Push-RepoFlowResumedBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resolved,

        [Parameter(Mandatory)]
        $Context,

        [Parameter(Mandatory)]
        [ValidateSet('initial', 'review')]
        [string]$Kind,

        [switch]$AlreadyPushed
    )

    Set-RepoFlowResumeBranch -BranchState $Resolved.BranchState

    if (-not $AlreadyPushed) {
        Write-Host '[GIT] Pushing resumed branch...'
        Push-RepoFlowBranch `
            -Branch ([string]$Resolved.BranchState.Branch) `
            -SetUpstream:(-not $Resolved.BranchState.RemoteExists)
    }

    $phase = if ($Kind -eq 'initial') {
        'branch-pushed'
    }
    else {
        'review-pushed'
    }

    $pullRequestNumber = if ($null -ne $Resolved.Plan.PullRequest) {
        [int]$Resolved.Plan.PullRequest.number
    }
    else {
        0
    }

    if ($Kind -eq 'review' -and $pullRequestNumber -gt 0) {
        Wait-RepoFlowPullRequestHead `
            -PullRequestNumber $pullRequestNumber `
            -Repository $Resolved.RepositorySlug `
            -ExpectedHeadSha (Get-RepoFlowCommitHash) `
            -TimeoutSeconds ([int]$Context.Config.ci.timeoutSeconds) `
            -PollSeconds ([int]$Context.Config.ci.pollSeconds) |
            Out-Null
    }

    Set-RepoFlowRunCheckpoint `
        -ConfigPath $Resolved.StateConfigPath `
        -RunId ([string]$Resolved.Plan.RunRecord.runId) `
        -CurrentPhase $phase `
        -SafePhase $phase `
        -HeadSha (Get-RepoFlowCommitHash) `
        -PullRequestNumber $pullRequestNumber
}

function New-RepoFlowResumedPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resolved,

        [Parameter(Mandatory)]
        $Context
    )

    $config = $Context.Config
    $templatePath = Resolve-RepoFlowPath `
        -RepositoryRoot $Context.RepositoryRoot `
        -Path ([string]$config.pullRequest.templatePath)

    if (-not (Test-Path -LiteralPath $templatePath -PathType Leaf)) {
        throw "Missing pull request template: $templatePath"
    }

    $template = Get-Content -LiteralPath $templatePath -Raw
    $body = Build-RepoFlowPullRequestBody `
        -Template $template `
        -Issue $Resolved.Issue `
        -AgentSummary ''
    $title = Get-RepoFlowPullRequestTitle `
        -Issue $Resolved.Issue `
        -Config $config

    Write-Host '[GH] Creating the missing pull request...'
    $pullRequest = New-RepoFlowPullRequest `
        -Repository $Resolved.RepositorySlug `
        -BaseBranch ([string]$config.repository.baseBranch) `
        -HeadBranch ([string]$Resolved.BranchState.Branch) `
        -Title $title `
        -Body $body `
        -Draft:([bool]$config.pullRequest.createDraft)

    Set-RepoFlowRunCheckpoint `
        -ConfigPath $Resolved.StateConfigPath `
        -RunId ([string]$Resolved.Plan.RunRecord.runId) `
        -CurrentPhase 'pull-request-created' `
        -SafePhase 'pull-request-created' `
        -PullRequestNumber ([int]$pullRequest.number) `
        -HeadSha (Get-RepoFlowCommitHash)
}

function Set-RepoFlowReconciledPullRequestCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resolved
    )

    Set-RepoFlowRunCheckpoint `
        -ConfigPath $Resolved.StateConfigPath `
        -RunId ([string]$Resolved.Plan.RunRecord.runId) `
        -CurrentPhase 'pull-request-created' `
        -SafePhase 'pull-request-created' `
        -PullRequestNumber ([int]$Resolved.Plan.PullRequest.number) `
        -HeadSha ([string]$Resolved.BranchState.LocalSha)
}
