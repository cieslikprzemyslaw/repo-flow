function Invoke-RepoFlowPrReviewWorkflow {
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
        -RequireGitHub `
        -RequireAgent:$Apply
    $config = $context.Config
    $repository = [string]$config.repository.slug
    $repositoryName = [string]$context.RepositorySelection.Repository.name
    $stateConfigPath = [string]$context.RepositorySelection.Registry.ConfigPath
    $options = Get-RepoFlowPrReviewOptions -Config $config
    $pullRequest = Get-RepoFlowPullRequest `
        -Number $Number `
        -Repository $repository

    Assert-RepoFlowPrReviewPullRequest `
        -PullRequest $pullRequest `
        -Config $config
    Assert-RepoFlowPrReviewLocalState -PullRequest $pullRequest

    $issueNumber = Get-RepoFlowPullRequestIssueNumber `
        -PullRequest $pullRequest
    $issue = Get-RepoFlowIssue `
        -Number $issueNumber `
        -Repository $repository
    $checks = Get-RepoFlowPrCheckState `
        -PullRequestNumber $Number `
        -Repository $repository

    Show-RepoFlowPrReviewPlan `
        -PullRequest $pullRequest `
        -Checks $checks `
        -Options $options

    if (-not $Apply) {
        Write-Host 'PLAN ONLY - no review, agent, commit, push, or merge ran.'
        Write-Host 'Run again with -Apply to start the bounded review loop.'
        return
    }

    $checks = Resolve-RepoFlowPrReviewCiState `
        -PullRequestNumber $Number `
        -Repository $repository `
        -Config $config `
        -RequirePassingCi $false `
        -Wait

    if (
        $options.RequirePassingCi -and
        [string]$checks.Status -eq 'failed'
    ) {
        Write-Host (
            '[REVIEW] CI failed before automated review; ' +
            'handing the pull request to the AI repair workflow.'
        )

        Invoke-RepoFlowPrRepairWorkflow `
            -Number $Number `
            -Apply `
            -ConfigPath $ConfigPath `
            -Repo $Repo |
            Out-Null

        $checks = Resolve-RepoFlowPrReviewCiState `
            -PullRequestNumber $Number `
            -Repository $repository `
            -Config $config `
            -RequirePassingCi $true `
            -Wait
    }
    elseif (
        $options.RequirePassingCi -and
        [string]$checks.Status -ne 'passed'
    ) {
        throw (
            "PR review requires passing CI, but the current status is " +
            "'$($checks.Status)'."
        )
    }

    $pullRequest = Get-RepoFlowPullRequest `
        -Number $Number `
        -Repository $repository
    Assert-RepoFlowPrReviewPullRequest `
        -PullRequest $pullRequest `
        -Config $config
    Assert-RepoFlowPrReviewLocalState -PullRequest $pullRequest

    $initialised = Initialize-RepoFlowPrReviewLoopRun `
        -ConfigPath $stateConfigPath `
        -RepositoryRoot ([string]$context.RepositoryRoot) `
        -RepositoryName $repositoryName `
        -RepositorySlug $repository `
        -Issue $issue `
        -PullRequest $pullRequest `
        -Config $config

    if ($initialised.AlreadyPassed) {
        Write-Host (
            "[REVIEW] PR #$Number already passed automated review for head " +
            "$($pullRequest.headRefOid)."
        )
        return
    }

    if ([bool](Get-RepoFlowProperty `
        -Object $initialised `
        -Name 'Paused' `
        -Default $false)) {
        Write-Warning (
            "PR review run '$($initialised.Record.runId)' is paused at " +
            "phase '$($initialised.Record.currentPhase)'. Inspect it and " +
            'explicitly complete or abandon it before starting again.'
        )
        return
    }

    $runRecord = $initialised.Record
    $runId = [string]$runRecord.runId
    $reviewAttempt = [int]$runRecord.reviewAttemptCount
    $repairAttempt = [int]$runRecord.repairAttemptCount
    $scopeHeadSha = Get-RepoFlowPrReviewScopeSha -RunRecord $runRecord

    try {
        while ($reviewAttempt -lt $options.MaxReviewCycles) {
            $pullRequest = Get-RepoFlowPullRequest `
                -Number $Number `
                -Repository $repository
            Assert-RepoFlowPrReviewPullRequest `
                -PullRequest $pullRequest `
                -Config $config
            Assert-RepoFlowPrReviewLocalState -PullRequest $pullRequest

            $checks = Resolve-RepoFlowPrReviewCiState `
                -PullRequestNumber $Number `
                -Repository $repository `
                -Config $config `
                -RequirePassingCi $options.RequirePassingCi `
                -Wait `
                -StateConfigPath $stateConfigPath `
                -RunId $runId `
                -Phase "review-ci-before-$($reviewAttempt + 1)"

            $pullRequest = Get-RepoFlowPullRequest `
                -Number $Number `
                -Repository $repository
            Assert-RepoFlowPrReviewPullRequest `
                -PullRequest $pullRequest `
                -Config $config
            Assert-RepoFlowPrReviewLocalState -PullRequest $pullRequest

            if (
                -not [string]::Equals(
                    [string]$runRecord.baseSha,
                    [string]$pullRequest.baseRefOid,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                throw (
                    'The pull-request base SHA changed during the review loop. ' +
                    'Complete or abandon this run and start a fresh review.'
                )
            }

            $reviewAttempt++
            Set-RepoFlowRunCheckpoint `
                -ConfigPath $stateConfigPath `
                -RunId $runId `
                -CurrentPhase "review-request-$reviewAttempt" `
                -SafePhase "review-ci-ready-$reviewAttempt" `
                -HeadSha ([string]$pullRequest.headRefOid) `
                -ReviewAttemptCount $reviewAttempt `
                -RepairAttemptCount $repairAttempt

            Invoke-RepoFlowAutomatedReviewWorkflow `
                -Number $Number `
                -Apply `
                -ConfigPath $ConfigPath `
                -Repo $Repo

            $accepted = Get-RepoFlowAcceptedPrReviewResult `
                -ConfigPath $stateConfigPath `
                -Repository $repository `
                -PullRequest $pullRequest `
                -Config $config
            $verdict = [string]$accepted.Result.verdict

            Set-RepoFlowRunCheckpoint `
                -ConfigPath $stateConfigPath `
                -RunId $runId `
                -CurrentPhase "review-result-$($verdict.Replace('_', '-'))" `
                -SafePhase 'review-result-received' `
                -HeadSha ([string]$pullRequest.headRefOid) `
                -ReviewAttemptCount $reviewAttempt `
                -RepairAttemptCount $repairAttempt

            switch ($verdict) {
                'pass' {
                    Set-RepoFlowRunCheckpoint `
                        -ConfigPath $stateConfigPath `
                        -RunId $runId `
                        -CurrentPhase 'review-passed' `
                        -SafePhase 'review-passed' `
                        -HeadSha ([string]$pullRequest.headRefOid) `
                        -ReviewAttemptCount $reviewAttempt `
                        -RepairAttemptCount $repairAttempt
                    Complete-RepoFlowRunRecord `
                        -ConfigPath $stateConfigPath `
                        -RunId $runId `
                        -Outcome completed

                    Write-Host (
                        "[REVIEW] PR #$Number passed on head " +
                        "$($pullRequest.headRefOid)."
                    )
                    return
                }

                'manual_review' {
                    Set-RepoFlowPrReviewLoopPaused `
                        -ConfigPath $stateConfigPath `
                        -RunId $runId `
                        -Phase 'review-manual-review' `
                        -Reason (
                            'Automated review requested manual review. ' +
                            'No repair or merge was performed.'
                        )
                    Write-Warning (
                        'Automated review requested manual review. ' +
                        'The workflow was paused safely.'
                    )
                    return
                }

                'changes_required' {
                    if ($reviewAttempt -ge $options.MaxReviewCycles) {
                        Set-RepoFlowPrReviewLoopPaused `
                            -ConfigPath $stateConfigPath `
                            -RunId $runId `
                            -Phase 'review-cycle-limit-exhausted' `
                            -Reason (
                                'The configured review-cycle limit was exhausted ' +
                                'before another repair could be reviewed.'
                            )
                        Write-Warning (
                            'Automated-review cycle limit exhausted; ' +
                            'manual review is required.'
                        )
                        return
                    }

                    if ($repairAttempt -ge $options.MaxRepairCycles) {
                        Set-RepoFlowPrReviewLoopPaused `
                            -ConfigPath $stateConfigPath `
                            -RunId $runId `
                            -Phase 'review-repair-limit-exhausted' `
                            -Reason 'The configured review-repair limit was exhausted.'
                        Write-Warning 'Review-repair limit exhausted; manual review is required.'
                        return
                    }

                    $fingerprint = Get-RepoFlowReviewBlockerFingerprint `
                        -Blockers @($accepted.Result.blockers)
                    $repeated = Test-RepoFlowReviewBlockerFingerprintRecorded `
                        -ConfigPath $stateConfigPath `
                        -LoopRunId $runId `
                        -ScopeHeadSha $scopeHeadSha `
                        -Fingerprint $fingerprint

                    if ($repeated) {
                        Set-RepoFlowPrReviewLoopPaused `
                            -ConfigPath $stateConfigPath `
                            -RunId $runId `
                            -Phase 'review-repeated-blockers' `
                            -Reason (
                                'The same blocker set was returned again. ' +
                                'Manual review is required.'
                            )
                        Write-Warning (
                            'Automated review repeated an unchanged blocker set. ' +
                            'The workflow was paused safely.'
                        )
                        return
                    }

                    Save-RepoFlowReviewBlockerFingerprint `
                        -ConfigPath $stateConfigPath `
                        -RepositoryRoot ([string]$context.RepositoryRoot) `
                        -RepositoryName $repositoryName `
                        -RepositorySlug $repository `
                        -Issue $issue `
                        -PullRequest $pullRequest `
                        -LoopRunId $runId `
                        -ScopeHeadSha $scopeHeadSha `
                        -Fingerprint $fingerprint

                    $repairAttempt++
                    $runRecord = Get-RepoFlowRunRecord `
                        -ConfigPath $stateConfigPath `
                        -RunId $runId
                    $repair = Invoke-RepoFlowPrReviewRepairCycle `
                        -Number $Number `
                        -Context $context `
                        -StateConfigPath $stateConfigPath `
                        -RepositoryName $repositoryName `
                        -Repository $repository `
                        -Issue $issue `
                        -PullRequest $pullRequest `
                        -Result $accepted.Result `
                        -RunRecord $runRecord `
                        -RepairAttempt $repairAttempt `
                        -RepairAttemptLimit $options.MaxRepairCycles `
                        -RequirePassingCi $options.RequirePassingCi

                    $pullRequest = $repair.PullRequest
                    $runRecord = Get-RepoFlowRunRecord `
                        -ConfigPath $stateConfigPath `
                        -RunId $runId
                }

                default {
                    throw "Unsupported automated-review verdict: $verdict"
                }
            }
        }

        Set-RepoFlowPrReviewLoopPaused `
            -ConfigPath $stateConfigPath `
            -RunId $runId `
            -Phase 'review-cycle-limit-exhausted' `
            -Reason 'The configured automated-review cycle limit was exhausted.'
        Write-Warning 'Automated-review cycle limit exhausted; manual review is required.'
    }
    catch {
        $latest = Get-RepoFlowRunRecord `
            -ConfigPath $stateConfigPath `
            -RunId $runId

        if (
            $null -ne $latest -and
            [string]$latest.status -ne 'completed' -and
            [string]$latest.status -ne 'paused'
        ) {
            Set-RepoFlowPrReviewLoopPaused `
                -ConfigPath $stateConfigPath `
                -RunId $runId `
                -Phase ([string]$latest.currentPhase) `
                -Reason $_.Exception.Message
        }

        throw
    }
}
