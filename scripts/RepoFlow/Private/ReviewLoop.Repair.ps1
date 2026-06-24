function Assert-RepoFlowPrReviewLocalState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PullRequest
    )

    $currentBranch = Get-RepoFlowCurrentBranch
    $currentHead = Get-RepoFlowCommitHash
    $expectedBranch = [string]$PullRequest.headRefName
    $expectedHead = [string]$PullRequest.headRefOid

    if ($currentBranch -ne $expectedBranch) {
        throw (
            "Pull request #$($PullRequest.number) is on branch " +
            "'$expectedBranch', but the current branch is '$currentBranch'."
        )
    }

    if ($currentHead -ne $expectedHead) {
        throw (
            "Local HEAD does not match pull request #$($PullRequest.number). " +
            "Expected $expectedHead, found $currentHead."
        )
    }

    if (-not [string]::IsNullOrWhiteSpace((Get-RepoFlowWorkingTreeStatus))) {
        throw 'PR review and repair requires a clean working tree.'
    }
}

function Invoke-RepoFlowPrReviewRepairCycle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        $Context,

        [Parameter(Mandatory)]
        [string]$StateConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryName,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        $RunRecord,

        [Parameter(Mandatory)]
        [int]$RepairAttempt,

        [Parameter(Mandatory)]
        [int]$RepairAttemptLimit,

        [Parameter(Mandatory)]
        [bool]$RequirePassingCi
    )

    $config = $Context.Config
    $blockers = @($Result.blockers)

    if ($blockers.Count -eq 0) {
        throw 'A changes-required review result did not contain blockers.'
    }

    Assert-RepoFlowPrReviewLocalState -PullRequest $PullRequest
    Assert-RepoFlowPrRepairLiveHead `
        -Number $Number `
        -Repository $Repository `
        -ExpectedHeadSha ([string]$PullRequest.headRefOid) |
        Out-Null

    $changedFiles = Get-RepoFlowPullRequestChangedFiles `
        -BaseBranch ([string]$config.repository.baseBranch)
    $contextPath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'repo-flow-review-repair-context-{0}.json' -f
        [guid]::NewGuid().ToString('N')
    )
    $finalMessagePath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'repo-flow-review-repair-final-{0}.md' -f
        [guid]::NewGuid().ToString('N')
    )
    $expectedHead = [string]$PullRequest.headRefOid

    try {
        Write-RepoFlowReviewRepairContext `
            -Result $Result `
            -HeadSha $expectedHead `
            -OutputPath $contextPath |
            Out-Null

        $prompt = New-RepoFlowReviewRepairPrompt `
            -Issue $Issue `
            -PullRequest $PullRequest `
            -HeadSha $expectedHead `
            -ContextPath $contextPath `
            -ChangedFiles $changedFiles `
            -Config $config `
            -RepairAttempt $RepairAttempt `
            -RepairAttemptLimit $RepairAttemptLimit

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $StateConfigPath `
            -RunId ([string]$RunRecord.runId) `
            -CurrentPhase "review-repair-agent-$RepairAttempt" `
            -ReviewAttemptCount ([int]$RunRecord.reviewAttemptCount) `
            -RepairAttemptCount $RepairAttempt

        Write-Host (
            "[AGENT] Review repair attempt $RepairAttempt " +
            "of $RepairAttemptLimit..."
        )

        $agentResult = Invoke-RepoFlowAgent `
            -RepositoryRoot ([string]$Context.RepositoryRoot) `
            -Prompt $prompt `
            -FinalMessagePath $finalMessagePath `
            -Config $config `
            -ReasoningEffort ([string]$config.agent.reasoningEffort) `
            -StateConfigPath $StateConfigPath `
            -RunId ([string]$RunRecord.runId) `
            -Phase "review-repair-agent-$RepairAttempt"

        if ($agentResult.ExitCode -ne 0) {
            throw "Agent failed:$([Environment]::NewLine)$($agentResult.Text)"
        }

        $summary = Get-RepoFlowAgentFinalMessage -Path $finalMessagePath
        $changes = Get-RepoFlowWorkingTreeStatus

        if ([string]::IsNullOrWhiteSpace($changes)) {
            if (-not [string]::IsNullOrWhiteSpace($summary)) {
                Write-Host '[AGENT] Final response:'
                Write-Host $summary
            }

            throw 'Review repair completed without changing files.'
        }

        $validation = Invoke-RepoFlowLocalValidation

        if ($validation.ExitCode -ne 0) {
            throw (
                'Local validation failed. Working-tree changes were preserved:' +
                "$([Environment]::NewLine)$($validation.Text)"
            )
        }

        Assert-RepoFlowPrRepairLiveHead `
            -Number $Number `
            -Repository $Repository `
            -ExpectedHeadSha $expectedHead |
            Out-Null

        $commitMessage = Get-RepoFlowReviewCommitMessage `
            -Issue $Issue `
            -Config $config

        Write-Host '[GIT] Committing review-repair changes...'
        Complete-RepoFlowCommit `
            -Issue $Issue `
            -Message $commitMessage `
            -RepositoryRoot ([string]$Context.RepositoryRoot) `
            -Config $config `
            -StateConfigPath $StateConfigPath `
            -RunId ([string]$RunRecord.runId) `
            -Phase "review-repair-pre-commit-$RepairAttempt" `
            -BeforeRetryCommit {
                Assert-RepoFlowPrRepairLiveHead `
                    -Number $Number `
                    -Repository $Repository `
                    -ExpectedHeadSha $expectedHead |
                    Out-Null
            }

        $newHead = Get-RepoFlowCommitHash

        if ($newHead -eq $expectedHead) {
            throw 'Review repair commit did not create a new head SHA.'
        }

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $StateConfigPath `
            -RunId ([string]$RunRecord.runId) `
            -CurrentPhase "review-repair-committed-$RepairAttempt" `
            -SafePhase "review-repair-committed-$RepairAttempt" `
            -HeadSha $newHead `
            -ReviewAttemptCount ([int]$RunRecord.reviewAttemptCount) `
            -RepairAttemptCount $RepairAttempt

        Write-Host '[GIT] Pushing review-repair changes...'
        Push-RepoFlowBranch -Branch ([string]$PullRequest.headRefName)

        $noActivityWarningSeconds = [int](Get-RepoFlowProperty `
            -Object $config.agent `
            -Name noActivityWarningSeconds `
            -Default 180)
        $livePullRequest = Wait-RepoFlowPullRequestHead `
            -PullRequestNumber $Number `
            -Repository $Repository `
            -ExpectedHeadSha $newHead `
            -TimeoutSeconds ([int]$config.ci.timeoutSeconds) `
            -PollSeconds ([int]$config.ci.pollSeconds) `
            -StateConfigPath $StateConfigPath `
            -RunId ([string]$RunRecord.runId) `
            -Phase "review-repair-head-sync-$RepairAttempt" `
            -NoActivityWarningSeconds $noActivityWarningSeconds

        $checks = Wait-RepoFlowPrChecks `
            -PullRequestNumber $Number `
            -Repository $Repository `
            -TimeoutSeconds ([int]$config.ci.timeoutSeconds) `
            -PollSeconds ([int]$config.ci.pollSeconds) `
            -StateConfigPath $StateConfigPath `
            -RunId ([string]$RunRecord.runId) `
            -Phase "review-repair-ci-$RepairAttempt" `
            -NoActivityWarningSeconds $noActivityWarningSeconds

        if ([string]$checks.Status -eq 'pending') {
            throw 'CI remained pending until the review-repair timeout.'
        }

        if ($RequirePassingCi -and [string]$checks.Status -ne 'passed') {
            throw (
                "CI status is '$($checks.Status)' after review repair; " +
                'a fresh review request was not published.'
            )
        }

        if (-not $RequirePassingCi -and [string]$checks.Status -ne 'passed') {
            Write-Warning (
                "Continuing with CI status '$($checks.Status)' because " +
                "ci.mode is '$($config.ci.mode)'."
            )
        }

        $ciIdentifiers = Get-RepoFlowCiIdentifiersFromChecks `
            -Checks $checks.Checks
        Set-RepoFlowRunCheckpoint `
            -ConfigPath $StateConfigPath `
            -RunId ([string]$RunRecord.runId) `
            -CurrentPhase "review-repair-ci-$($checks.Status)" `
            -SafePhase "review-repair-ci-$($checks.Status)" `
            -HeadSha $newHead `
            -CiRunIds @($ciIdentifiers.RunIds) `
            -CiJobIds @($ciIdentifiers.JobIds) `
            -ReviewAttemptCount ([int]$RunRecord.reviewAttemptCount) `
            -RepairAttemptCount $RepairAttempt

        return [pscustomobject]@{
            PullRequest = $livePullRequest
            Checks = $checks
            HeadSha = $newHead
        }
    }
    finally {
        Remove-Item `
            -LiteralPath $contextPath, $finalMessagePath `
            -Force `
            -ErrorAction SilentlyContinue
    }
}
