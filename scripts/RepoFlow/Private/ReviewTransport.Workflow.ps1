function Show-RepoFlowAutomatedReviewRequestSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Request
    )

    Write-Host ''
    Write-Host 'Automated review request'
    Write-Host '------------------------'
    Write-Host "Request ID: $($Request.requestId)"
    Write-Host "PR:         #$($Request.pullRequest.number)"
    Write-Host "Head SHA:   $($Request.headSha)"
    Write-Host "Files:      $(@($Request.changedFiles).Count)"
    Write-Host "CI status:  $($Request.ciSummary.status)"
    Write-Host ''
}

function Wait-RepoFlowAutomatedReviewResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Request,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        $Config,

        [AllowEmptyCollection()]
        [string[]]$ProcessedRequestIds = @(),

        [ValidateRange(0, 100000)]
        [int]$MaximumPolls = 0
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds(
        [int]$Config.ci.timeoutSeconds
    )
    $pollCount = 0

    while ($true) {
        $livePullRequest = Get-RepoFlowPullRequest `
            -Number ([int]$Request.pullRequest.number) `
            -Repository $Repository

        if (
            [string]$livePullRequest.state -ne 'OPEN' -or
            -not [string]::Equals(
                [string]$livePullRequest.baseRefOid,
                [string]$Request.baseSha,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            -not [string]::Equals(
                [string]$livePullRequest.headRefOid,
                [string]$Request.headSha,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            return [pscustomobject]@{
                Status = 'stale'
                Comment = $null
                Result = $null
                Reason = 'The pull-request state, base, or head changed.'
            }
        }

        $comments = @(
            Get-RepoFlowAllPullRequestComments `
                -PullRequestNumber ([int]$Request.pullRequest.number) `
                -Repository $Repository
        )
        $resolution = Resolve-RepoFlowAutomatedReviewResultComment `
            -Request $Request `
            -Comments $comments `
            -CurrentHeadSha ([string]$livePullRequest.headRefOid) `
            -Config $Config `
            -ProcessedRequestIds $ProcessedRequestIds

        if ($resolution.Status -ne 'none') {
            return $resolution
        }

        $pollCount++

        if (
            ($MaximumPolls -gt 0 -and $pollCount -ge $MaximumPolls) -or
            [DateTimeOffset]::UtcNow -ge $deadline
        ) {
            return [pscustomobject]@{
                Status = 'timeout'
                Comment = $null
                Result = $null
                Reason = 'No matching trusted result was received before timeout.'
            }
        }

        Write-Host '[REVIEW] Waiting for a matching trusted result comment...'
        Start-Sleep -Seconds ([int]$Config.ci.pollSeconds)
    }
}

function Invoke-RepoFlowAutomatedReviewWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [switch]$Apply,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext `
        -ConfigPath $ConfigPath `
        -Repo $Repo `
        -RequireGitHub
    $config = $context.Config
    $repository = [string]$config.repository.slug
    $stateConfigPath = [string]$context.RepositorySelection.Registry.ConfigPath

    if (-not [bool]$config.reviewFeedback.enabled) {
        throw 'Automated review transport requires reviewFeedback.enabled.'
    }

    $pullRequest = Get-RepoFlowPullRequest `
        -Number $Number `
        -Repository $repository

    if ([string]$pullRequest.state -ne 'OPEN') {
        throw "Pull request #$Number is not open."
    }

    if ([string]::IsNullOrWhiteSpace([string]$pullRequest.baseRefOid)) {
        throw "Pull request #$Number did not report a base commit SHA."
    }

    $issueNumber = Get-RepoFlowPullRequestIssueNumber -PullRequest $pullRequest
    $issue = Get-RepoFlowIssue -Number $issueNumber -Repository $repository
    $changedFiles = Get-RepoFlowPullRequestFiles `
        -PullRequestNumber $Number `
        -Repository $repository
    $checkState = Get-RepoFlowPrCheckState `
        -PullRequestNumber $Number `
        -Repository $repository
    $request = New-RepoFlowAutomatedReviewRequestEnvelope `
        -Issue $issue `
        -PullRequest $pullRequest `
        -Repository $repository `
        -ChangedFiles $changedFiles `
        -CheckState $checkState

    Show-RepoFlowAutomatedReviewRequestSummary -Request $request

    if (-not $Apply) {
        Write-Host 'PLAN ONLY - no GitHub comment or run state was created.'
        Write-Host 'Run again with -Apply to publish the request and wait for a result.'
        return
    }

    $authenticatedLogin = Get-RepoFlowAuthenticatedGitHubLogin
    $comments = @(
        Get-RepoFlowAllPullRequestComments `
            -PullRequestNumber $Number `
            -Repository $repository
    )
    $existingRequest = Find-RepoFlowAutomatedReviewRequestComment `
        -Comments $comments `
        -AuthenticatedLogin $authenticatedLogin `
        -RequestId ([string]$request.requestId) `
        -Repository $repository `
        -IssueNumber ([int]$issue.number) `
        -PullRequestNumber $Number `
        -BaseSha ([string]$pullRequest.baseRefOid) `
        -HeadSha ([string]$pullRequest.headRefOid)

    if ($null -eq $existingRequest) {
        $requestBody = ConvertTo-RepoFlowReviewComment `
            -Envelope $request `
            -HumanSummary (
                'Automated review requested for the exact current ' +
                'pull-request head. Do not edit the machine-readable payload.'
            )
        $requestComment = New-RepoFlowPullRequestComment `
            -PullRequestNumber $Number `
            -Repository $repository `
            -Body $requestBody
        Write-Host "[REVIEW] Published request comment #$($requestComment.id)."
    }
    else {
        $requestComment = $existingRequest.Comment
        $request = $existingRequest.Envelope
        Write-Host "[REVIEW] Reusing request comment #$($requestComment.id)."
    }

    $runRecord = Get-RepoFlowAutomatedReviewRunRecord `
        -ConfigPath $stateConfigPath `
        -RequestId ([string]$request.requestId)

    if ($null -eq $runRecord) {
        $runRecord = Start-RepoFlowAutomatedReviewRunRecord `
            -ConfigPath $stateConfigPath `
            -RepositoryRoot ([string]$context.RepositoryRoot) `
            -RepositoryName ([string]$context.RepositorySelection.Repository.name) `
            -RepositorySlug $repository `
            -Issue $issue `
            -PullRequest $pullRequest `
            -RequestId ([string]$request.requestId) `
            -RequestCommentId ([long]$requestComment.id)
    }
    else {
        if (
            [int]$runRecord.pullRequestNumber -ne $Number -or
            -not [string]::Equals(
                [string]$runRecord.baseSha,
                [string]$request.baseSha,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            -not [string]::Equals(
                [string]$runRecord.headSha,
                [string]$request.headSha,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            throw 'Persisted automated-review state does not match the current request.'
        }

        $resultRun = Get-RepoFlowAutomatedReviewResultRunRecord `
            -ConfigPath $stateConfigPath `
            -RequestId ([string]$request.requestId)

        if ($null -ne $resultRun) {
            $verdict = ([string]$resultRun.currentPhase).Replace(
                'review-result-',
                ''
            )

            if ($verdict -eq 'pass' -and [string]$runRecord.status -ne 'completed') {
                Set-RepoFlowRunCheckpoint `
                    -ConfigPath $stateConfigPath `
                    -RunId ([string]$request.requestId) `
                    -CurrentPhase 'review-passed' `
                    -SafePhase 'review-result-received'
                Complete-RepoFlowRunRecord `
                    -ConfigPath $stateConfigPath `
                    -RunId ([string]$request.requestId) `
                    -Outcome completed
            }
            elseif (
                $verdict -ne 'pass' -and
                [string]$runRecord.status -ne 'paused'
            ) {
                Set-RepoFlowRunPaused `
                    -ConfigPath $stateConfigPath `
                    -RunId ([string]$request.requestId) `
                    -CurrentPhase "review-$($verdict.Replace('_', '-'))" `
                    -PauseReason (
                        "Automated review returned '$verdict'. " +
                        'Inspect the trusted result comment before continuing.'
                    )
            }

            Write-Host (
                "[REVIEW] Result already accepted from comment " +
                "#$($resultRun.prCommentId) with verdict '$verdict'."
            )
            return
        }

        Set-RepoFlowAutomatedReviewRequestComment `
            -ConfigPath $stateConfigPath `
            -RequestId ([string]$request.requestId) `
            -RequestCommentId ([long]$requestComment.id)
    }

    $reviewerConfig = Get-RepoFlowProperty `
        -Object $config `
        -Name 'reviewer' `
        -Default ([pscustomobject]@{ mode = 'external' })

    $bridgeResolution = $null

    if ([string]$reviewerConfig.mode -eq 'local') {
        Write-Host '[REVIEW] Starting local automated review bridge.'
        $bridgeResolution = Invoke-RepoFlowLocalReviewBridge `
            -Request $request `
            -Issue $issue `
            -PullRequest $pullRequest `
            -Context $context `
            -StateConfigPath $stateConfigPath
    }
    else {
        Write-Host '[REVIEW] External bridge mode; waiting for a trusted result comment.'
    }

    $processedRequestIds = Get-RepoFlowProcessedAutomatedReviewRequestIds `
        -ConfigPath $stateConfigPath `
        -ExcludeRequestId ([string]$request.requestId)

    $resolution = if ($null -ne $bridgeResolution) {
        $bridgeResolution
    }
    else {
        Wait-RepoFlowAutomatedReviewResult `
            -Request $request `
            -Repository $repository `
            -Config $config `
            -ProcessedRequestIds $processedRequestIds
    }

    switch ([string]$resolution.Status) {
        'accepted' {
            Save-RepoFlowAutomatedReviewResult `
                -ConfigPath $stateConfigPath `
                -RepositoryRoot ([string]$context.RepositoryRoot) `
                -RepositoryName ([string]$context.RepositorySelection.Repository.name) `
                -RepositorySlug $repository `
                -Issue $issue `
                -PullRequest $pullRequest `
                -RequestId ([string]$request.requestId) `
                -ResultCommentId ([long]$resolution.Comment.id) `
                -Result $resolution.Result

            Write-Host (
                "[REVIEW] Accepted trusted result comment " +
                "#$($resolution.Comment.id): $($resolution.Result.verdict)"
            )
            return
        }

        'malformed' {
            Set-RepoFlowAutomatedReviewPaused `
                -ConfigPath $stateConfigPath `
                -RequestId ([string]$request.requestId) `
                -ReasonCode malformed
            throw 'A trusted marked review result was malformed. The run was paused safely.'
        }

        'stale' {
            Set-RepoFlowAutomatedReviewPaused `
                -ConfigPath $stateConfigPath `
                -RequestId ([string]$request.requestId) `
                -ReasonCode stale
            throw 'The pull-request head changed. The previous review request is now stale.'
        }

        'timeout' {
            Set-RepoFlowAutomatedReviewPaused `
                -ConfigPath $stateConfigPath `
                -RequestId ([string]$request.requestId) `
                -ReasonCode timeout
            throw 'Automated review timed out. The run was paused safely.'
        }

        default {
            Set-RepoFlowAutomatedReviewPaused `
                -ConfigPath $stateConfigPath `
                -RequestId ([string]$request.requestId) `
                -ReasonCode malformed
            throw "Unsupported automated-review resolution: $($resolution.Status)"
        }
    }
}
