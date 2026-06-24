function Invoke-RepoFlowQueueTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        [string]$StateConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $snapshot = Get-RepoFlowQueueTaskSnapshot `
        -Task $Task `
        -ConfigPath $ConfigPath
    $pullRequest = $snapshot.PullRequest
    $issueWorkflowReconciled = $false
    $existingRun = Get-RepoFlowQueueLatestIssueRun `
        -ConfigPath $StateConfigPath `
        -Repository $snapshot.RepositoryName `
        -IssueNumber ([int]$Task.issueNumber)

    if ($null -ne $pullRequest -and [string]$pullRequest.state -eq 'MERGED') {
        Write-Host "[QUEUE] PR #$($pullRequest.number) is merged; reconciling cleanup."
        Complete-RepoFlowPostMergeCleanup `
            -PullRequest $pullRequest `
            -Config $snapshot.Config

        return New-RepoFlowQueueTaskResult `
            -Status completed `
            -Reason "PR #$($pullRequest.number) is merged and cleanup completed." `
            -PullRequest $pullRequest `
            -Phase 'cleanup-completed' `
            -RepositoryName $snapshot.RepositoryName
    }

    if ($null -ne $pullRequest -and [string]$pullRequest.state -eq 'CLOSED') {
        return New-RepoFlowQueueTaskResult `
            -Status paused `
            -Reason (
                "PR #$($pullRequest.number) is closed without a confirmed merge. " +
                'Manual review is required.'
            ) `
            -PullRequest $pullRequest `
            -Phase 'closed-pr' `
            -RepositoryName $snapshot.RepositoryName
    }

    if (
        $null -ne $pullRequest -and
        [string]$pullRequest.state -eq 'OPEN' -and
        $null -eq $existingRun
    ) {
        return New-RepoFlowQueueTaskResult `
            -Status paused `
            -Reason (
                "Open PR #$($pullRequest.number) has no saved issue run state. " +
                'RepoFlow cannot resume it deterministically.'
            ) `
            -PullRequest $pullRequest `
            -Phase 'missing-run-state' `
            -RepositoryName $snapshot.RepositoryName
    }

    if ($null -eq $pullRequest) {
        $mustResume = (
            $snapshot.LocalBranchExists -or
            $snapshot.RemoteBranchExists -or
            $null -ne $existingRun
        )

        if ($mustResume) {
            Write-Host "[QUEUE] Resuming issue #$($Task.issueNumber)."
            Invoke-RepoFlowIssueResumeWorkflow `
                -Number ([int]$Task.issueNumber) `
                -Apply `
                -CiMode (Get-RepoFlowQueueTaskCiMode `
                    -Task $Task `
                    -Config $snapshot.Config) `
                -Repo $snapshot.RepositoryName `
                -ConfigPath $ConfigPath
            $issueWorkflowReconciled = $true
        }
        else {
            Write-Host "[QUEUE] Starting issue #$($Task.issueNumber)."
            Invoke-RepoFlowIssueRunWorkflow `
                -Number ([int]$Task.issueNumber) `
                -Apply `
                -CiMode (Get-RepoFlowQueueTaskCiMode `
                    -Task $Task `
                    -Config $snapshot.Config) `
                -Repo $snapshot.RepositoryName `
                -ConfigPath $ConfigPath
            $issueWorkflowReconciled = $true
        }

        $snapshot = Get-RepoFlowQueueTaskSnapshot `
            -Task $Task `
            -ConfigPath $ConfigPath
        $pullRequest = $snapshot.PullRequest

        if ($null -eq $pullRequest) {
            return New-RepoFlowQueueTaskResult `
                -Status paused `
                -Reason 'Issue execution ended without a pull request.' `
                -Phase 'missing-pr' `
                -RepositoryName $snapshot.RepositoryName
        }
    }

    if (
        -not $issueWorkflowReconciled -and
        $null -ne $existingRun -and
        [string]$pullRequest.state -eq 'OPEN'
    ) {
        Write-Host "[QUEUE] Reconciling saved issue workflow for PR #$($pullRequest.number)."
        Invoke-RepoFlowIssueResumeWorkflow `
            -Number ([int]$Task.issueNumber) `
            -Apply `
            -CiMode (Get-RepoFlowQueueTaskCiMode `
                -Task $Task `
                -Config $snapshot.Config) `
            -Repo $snapshot.RepositoryName `
            -ConfigPath $ConfigPath
        $issueWorkflowReconciled = $true

        $snapshot = Get-RepoFlowQueueTaskSnapshot `
            -Task $Task `
            -ConfigPath $ConfigPath
        $pullRequest = $snapshot.PullRequest

        if ($null -eq $pullRequest) {
            return New-RepoFlowQueueTaskResult `
                -Status paused `
                -Reason 'Issue resume ended without a pull request.' `
                -Phase 'missing-pr-after-resume' `
                -RepositoryName $snapshot.RepositoryName
        }
    }

    if ([string]$pullRequest.state -eq 'MERGED') {
        Complete-RepoFlowPostMergeCleanup `
            -PullRequest $pullRequest `
            -Config $snapshot.Config

        return New-RepoFlowQueueTaskResult `
            -Status completed `
            -Reason "PR #$($pullRequest.number) is merged and cleanup completed." `
            -PullRequest $pullRequest `
            -Phase 'cleanup-completed' `
            -RepositoryName $snapshot.RepositoryName
    }

    if ([string]$pullRequest.state -ne 'OPEN') {
        return New-RepoFlowQueueTaskResult `
            -Status paused `
            -Reason "PR #$($pullRequest.number) is '$($pullRequest.state)'." `
            -PullRequest $pullRequest `
            -Phase 'unexpected-pr-state' `
            -RepositoryName $snapshot.RepositoryName
    }

    $ciState = Get-RepoFlowPrCheckState `
        -PullRequestNumber ([int]$pullRequest.number) `
        -Repository $snapshot.RepositorySlug

    if ($ciState.Status -ne 'passed') {
        return New-RepoFlowQueueTaskResult `
            -Status paused `
            -Reason (
                "Passing CI is required before review; PR #$($pullRequest.number) " +
                "is '$($ciState.Status)'."
            ) `
            -PullRequest $pullRequest `
            -Phase 'ci-not-passing' `
            -RepositoryName $snapshot.RepositoryName
    }

    Invoke-RepoFlowQueueLocalValidation

    if (-not [bool]$Task.automatedReview) {
        return New-RepoFlowQueueTaskResult `
            -Status merge-gate `
            -Reason (
                "PR #$($pullRequest.number) passed CI and awaits explicit manual " +
                'review and merge.'
            ) `
            -PullRequest $pullRequest `
            -Phase 'merge-gate' `
            -RepositoryName $snapshot.RepositoryName
    }

    $reviewState = Get-RepoFlowQueueReviewRunState `
        -ConfigPath $StateConfigPath `
        -RepositorySlug $snapshot.RepositorySlug `
        -PullRequest $pullRequest

    if ($reviewState.Status -ne 'passed') {
        Write-Host "[QUEUE] Running bounded automated review for PR #$($pullRequest.number)."
        Invoke-RepoFlowPrReviewWorkflow `
            -Number ([int]$pullRequest.number) `
            -Apply `
            -Repo $snapshot.RepositoryName `
            -ConfigPath $ConfigPath

        $pullRequest = Get-RepoFlowPullRequest `
            -Number ([int]$pullRequest.number) `
            -Repository $snapshot.RepositorySlug
        $reviewState = Get-RepoFlowQueueReviewRunState `
            -ConfigPath $StateConfigPath `
            -RepositorySlug $snapshot.RepositorySlug `
            -PullRequest $pullRequest
    }

    if ($reviewState.Status -eq 'paused') {
        return New-RepoFlowQueueTaskResult `
            -Status paused `
            -Reason (
                "Automated review paused at phase " +
                "'$($reviewState.Record.currentPhase)': " +
                "$($reviewState.Record.pauseReason)"
            ) `
            -PullRequest $pullRequest `
            -RunRecord $reviewState.Record `
            -Phase 'review-paused' `
            -RepositoryName $snapshot.RepositoryName
    }

    if ($reviewState.Status -ne 'passed') {
        return New-RepoFlowQueueTaskResult `
            -Status paused `
            -Reason (
                "Automated review did not produce a passing exact-head " +
                "checkpoint for PR #$($pullRequest.number)."
            ) `
            -PullRequest $pullRequest `
            -RunRecord $reviewState.Record `
            -Phase 'review-incomplete' `
            -RepositoryName $snapshot.RepositoryName
    }

    $finalCiState = Get-RepoFlowPrCheckState `
        -PullRequestNumber ([int]$pullRequest.number) `
        -Repository $snapshot.RepositorySlug

    if ($finalCiState.Status -ne 'passed') {
        return New-RepoFlowQueueTaskResult `
            -Status paused `
            -Reason (
                "CI changed after automated review; PR #$($pullRequest.number) " +
                "is '$($finalCiState.Status)' for its current head."
            ) `
            -PullRequest $pullRequest `
            -RunRecord $reviewState.Record `
            -Phase 'post-review-ci-not-passing' `
            -RepositoryName $snapshot.RepositoryName
    }

    Invoke-RepoFlowQueueLocalValidation

    return New-RepoFlowQueueTaskResult `
        -Status merge-gate `
        -Reason (
            "PR #$($pullRequest.number) passed CI and automated review for " +
            'its current head. Explicit human-confirmed merge is required.'
        ) `
        -PullRequest $pullRequest `
        -RunRecord $reviewState.Record `
        -Phase 'merge-gate' `
        -RepositoryName $snapshot.RepositoryName
}

