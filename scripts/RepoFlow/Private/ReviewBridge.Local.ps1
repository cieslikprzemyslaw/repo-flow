function Invoke-RepoFlowLocalReviewBridge {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Request,

        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Context,

        [Parameter(Mandatory)]
        [string]$StateConfigPath
    )

    $reviewer = $Context.Config.reviewer
    if ([string]$reviewer.mode -ne 'local') {
        return $null
    }

    $repository = [string]$Request.repository
    $comments = @(Get-RepoFlowAllPullRequestComments `
        -PullRequestNumber ([int]$PullRequest.number) `
        -Repository $repository)
    $existingResolution = Resolve-RepoFlowAutomatedReviewResultComment `
        -Request $Request `
        -Comments $comments `
        -CurrentHeadSha ([string]$PullRequest.headRefOid) `
        -Config $Context.Config `
        -ProcessedRequestIds @()

    if ($existingResolution.Status -ne 'none') {
        if ($existingResolution.Status -eq 'accepted') {
            Complete-RepoFlowLocalReviewBridgeIfPresent `
                -ConfigPath $StateConfigPath `
                -RequestId ([string]$Request.requestId)
        }
        return $existingResolution
    }

    $lock = $null
    $runId = $null

    try {
        $lock = Enter-RepoFlowLocalReviewBridgeLock `
            -ConfigPath $StateConfigPath `
            -RequestId ([string]$Request.requestId)

        if ($null -eq $lock) {
            return $null
        }

        Assert-RepoFlowLocalReviewScope -Request $Request -PullRequest $PullRequest
        $runId = Initialize-RepoFlowLocalReviewBridgeRun `
            -ConfigPath $StateConfigPath `
            -Context $Context `
            -Issue $Issue `
            -PullRequest $PullRequest `
            -Request $Request `
            -Reviewer $reviewer

        $initialHead = Get-RepoFlowLocalGitHeadSha
        $initialWorkingTree = Get-RepoFlowWorkingTreeStatus
        $reviewerId = Get-RepoFlowLocalReviewerId -Reviewer $reviewer
        $prompt = New-RepoFlowLocalReviewerPrompt `
            -Request $Request `
            -Issue $Issue `
            -PullRequest $PullRequest `
            -ReviewerId $reviewerId

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $StateConfigPath `
            -RunId $runId `
            -CurrentPhase 'local-reviewer-running' `
            -SafePhase 'local-reviewer-starting'

        $agentResult = Invoke-RepoFlowLocalReviewerAgent `
            -RepositoryRoot ([string]$Context.RepositoryRoot) `
            -Prompt $prompt `
            -Reviewer $reviewer `
            -StateConfigPath $StateConfigPath `
            -RunId $runId

        if ($agentResult.TimedOut) {
            throw "Local reviewer timed out after $($reviewer.timeoutSeconds) seconds."
        }
        if ($agentResult.ExitCode -ne 0) {
            throw (
                "Local reviewer process exited with code " +
                "$($agentResult.ExitCode). Inspect the live console output and retry."
            )
        }

        $livePullRequest = Get-RepoFlowPullRequest `
            -Number ([int]$PullRequest.number) `
            -Repository $repository
        if (
            [string]$livePullRequest.state -ne 'OPEN' -or
            -not [string]::Equals([string]$livePullRequest.baseRefOid, [string]$Request.baseSha, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$livePullRequest.headRefOid, [string]$Request.headSha, [System.StringComparison]::OrdinalIgnoreCase)
        ) {
            throw 'The pull-request base or head changed while the local reviewer was running.'
        }

        if (
            -not [string]::Equals((Get-RepoFlowLocalGitHeadSha), $initialHead, [System.StringComparison]::OrdinalIgnoreCase) -or
            (Get-RepoFlowWorkingTreeStatus) -cne $initialWorkingTree
        ) {
            throw 'The local reviewer changed the repository despite read-only mode.'
        }

        $result = ConvertFrom-RepoFlowLocalReviewerOutput `
            -Text ([string]$agentResult.FinalMessage) `
            -Request $Request `
            -CurrentHeadSha ([string]$livePullRequest.headRefOid) `
            -ExpectedReviewerId $reviewerId

        $comments = @(Get-RepoFlowAllPullRequestComments `
            -PullRequestNumber ([int]$PullRequest.number) `
            -Repository $repository)
        $existingResolution = Resolve-RepoFlowAutomatedReviewResultComment `
            -Request $Request `
            -Comments $comments `
            -CurrentHeadSha ([string]$livePullRequest.headRefOid) `
            -Config $Context.Config `
            -ProcessedRequestIds @()

        if ($existingResolution.Status -eq 'none') {
            $body = ConvertTo-RepoFlowReviewComment `
                -Envelope $result `
                -HumanSummary (
                    "Local automated review completed with verdict " +
                    "'$($result.verdict)' for exact head $($Request.headSha)."
                )
            $comment = New-RepoFlowPullRequestComment `
                -PullRequestNumber ([int]$PullRequest.number) `
                -Repository $repository `
                -Body $body
            Write-Host "[REVIEWER] Published result comment #$($comment.id)."

            $resolution = Resolve-RepoFlowAutomatedReviewResultComment `
                -Request $Request `
                -Comments @($comment) `
                -CurrentHeadSha ([string]$livePullRequest.headRefOid) `
                -Config $Context.Config `
                -ProcessedRequestIds @()

            if ($resolution.Status -ne 'accepted') {
                throw (
                    'The published local review result could not be consumed: ' +
                    "$($resolution.Status)."
                )
            }
        }
        elseif ($existingResolution.Status -eq 'accepted') {
            Write-Host (
                "[REVIEWER] Reusing result comment " +
                "#$($existingResolution.Comment.id)."
            )
            $resolution = $existingResolution
        }
        else {
            throw (
                "Existing review-result resolution is " +
                "'$($existingResolution.Status)'."
            )
        }

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $StateConfigPath `
            -RunId $runId `
            -CurrentPhase 'local-reviewer-result-published' `
            -SafePhase 'local-reviewer-result-published'
        Complete-RepoFlowRunRecord `
            -ConfigPath $StateConfigPath `
            -RunId $runId `
            -Outcome completed

        return $resolution
    }
    catch {
        if (-not [string]::IsNullOrWhiteSpace($runId)) {
            Set-RepoFlowLocalReviewBridgePaused `
                -ConfigPath $StateConfigPath `
                -RequestId ([string]$Request.requestId) `
                -RunId $runId `
                -Reason $_.Exception.Message
        }
        elseif ($null -ne (Get-RepoFlowAutomatedReviewRunRecord `
            -ConfigPath $StateConfigPath `
            -RequestId ([string]$Request.requestId))) {
            Set-RepoFlowRunPaused `
                -ConfigPath $StateConfigPath `
                -RunId ([string]$Request.requestId) `
                -CurrentPhase 'review-local-bridge-paused' `
                -PauseReason $_.Exception.Message
        }
        throw
    }
    finally {
        Exit-RepoFlowLocalReviewBridgeLock -Lock $lock
    }
}
