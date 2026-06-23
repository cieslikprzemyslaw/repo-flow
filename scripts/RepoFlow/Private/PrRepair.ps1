function Assert-RepoFlowPrRepairLiveHead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$ExpectedHeadSha
    )

    $livePullRequest = Get-RepoFlowPullRequest `
        -Number $Number `
        -Repository $Repository

    if ([string]$livePullRequest.headRefOid -ne $ExpectedHeadSha) {
        throw (
            "Pull request #$Number head changed from $ExpectedHeadSha " +
            "to $($livePullRequest.headRefOid)."
        )
    }

    return $livePullRequest
}

function Invoke-RepoFlowPrRepairWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [switch]$Apply,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo -RequireGitHub -RequireAgent:$Apply
    $config = $context.Config
    $repository = [string]$config.repository.slug
    $attemptLimit = [int]$config.ci.autoFixAttempts
    $pullRequest = Get-RepoFlowPullRequest -Number $Number -Repository $repository

    if ($pullRequest.state -ne 'OPEN') {
        throw "Pull request #$Number is not open."
    }

    if ($pullRequest.baseRefName -ne [string]$config.repository.baseBranch) {
        throw (
            "Pull request #$Number targets '$($pullRequest.baseRefName)', " +
            "not '$($config.repository.baseBranch)'."
        )
    }

    $issueNumber = Get-RepoFlowPullRequestIssueNumber -PullRequest $pullRequest
    $issue = Get-RepoFlowIssue -Number $issueNumber -Repository $repository
    $currentBranch = Get-RepoFlowCurrentBranch
    $expectedHeadSha = [string]$pullRequest.headRefOid
    $currentHeadSha = Get-RepoFlowCommitHash

    if ($currentBranch -ne [string]$pullRequest.headRefName) {
        throw (
            "Pull request #$Number is on branch '$($pullRequest.headRefName)', " +
            "but the current branch is '$currentBranch'."
        )
    }

    if ($currentHeadSha -ne $expectedHeadSha) {
        throw (
            "Pull request #$Number head changed before repair started. " +
            "Expected $expectedHeadSha, found $currentHeadSha."
        )
    }

    $workingTreeStatus = Get-RepoFlowWorkingTreeStatus

    if (-not [string]::IsNullOrWhiteSpace($workingTreeStatus)) {
        throw (
            'Repair requires a clean working tree. The current working tree ' +
            'contains unrelated changes.'
        )
    }

    $checks = Get-RepoFlowPrCheckState `
        -PullRequestNumber $Number `
        -Repository $repository

    if ($checks.Status -eq 'pending' -and $Apply) {
        Write-Host '[CI] Waiting for the current PR checks to finish...'
        $checks = Wait-RepoFlowPrChecks `
            -PullRequestNumber $Number `
            -Repository $repository `
            -TimeoutSeconds ([int]$config.ci.timeoutSeconds) `
            -PollSeconds ([int]$config.ci.pollSeconds)
    }

    if ($checks.Status -eq 'passed') {
        Write-Host "Pull request #$Number already has passing checks."
        return
    }

    if ($checks.Status -ne 'failed') {
        Write-Host "Pull request #$Number does not currently have failed checks."
        return
    }

    $changedFiles = Get-RepoFlowPullRequestChangedFiles `
        -BaseBranch ([string]$config.repository.baseBranch)
    $currentDiff = Get-RepoFlowPullRequestDiff `
        -BaseBranch ([string]$config.repository.baseBranch)
    $repairContextPath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'repo-flow-pr-repair-context-{0}.md' -f [guid]::NewGuid().ToString('N')
    )
    $repairContext = $null
    $contextDiagnostics = @()
    $failedChecks = @()

    try {
        $repairContext = Write-RepoFlowFailedCiContext `
            -IssueNumber ([int]$issue.number) `
            -PullRequestNumber $Number `
            -Checks $checks.Checks `
            -Repository $repository `
            -BaseBranch ([string]$config.repository.baseBranch) `
            -OutputPath $repairContextPath `
            -PassThru

        $contextDiagnostics = @($repairContext.Diagnostics)
        $failedChecks = @($repairContext.FailedChecks)
        $commitMessage = Get-RepoFlowCiFixCommitMessage `
            -Issue $issue `
            -Config $config

        Write-Host ''
        Write-Host "PR:       #$Number $($pullRequest.title)"
        Write-Host "URL:      $($pullRequest.url)"
        Write-Host "Head:     $expectedHeadSha"
        Write-Host "Branch:   $($pullRequest.headRefName) -> $($pullRequest.baseRefName)"
        Write-Host "Checks:   $($checks.Status)"
        Write-Host 'Failed checks:'
        foreach ($failedCheck in @($failedChecks)) {
            Write-Host "  - $($failedCheck.name): $($failedCheck.bucket)"
        }
        Write-Host "Commit:   $commitMessage"
        Write-Host 'Diagnostics:'
        Write-Host (Format-RepoFlowCiDiagnostics -Diagnostics $contextDiagnostics)
        Write-Host ''
        Write-Host 'Validation:'
        Write-Host '  - Smallest relevant local validation: git diff --check'
        Write-Host '  - Configured required checks: watch the repaired PR checks after push'
        Write-Host ''
        Write-Host 'Current diff:'
        Write-Host $currentDiff
        Write-Host ''
        Write-Host 'Changed files:'
        Write-Host (Format-RepoFlowChangedFiles -Files $changedFiles)
        Write-Host ''

        if (-not $Apply) {
            Write-Host 'PLAN ONLY - no changes were made.'
            Write-Host 'Run again with -Apply to repair the pull request.'
            return
        }

        if ($attemptLimit -le 0) {
            Write-Warning 'CI auto-fix attempts are disabled; no repair cycle will run.'
            return
        }

        $finalMessagePath = Join-Path ([System.IO.Path]::GetTempPath()) (
            'repo-flow-pr-repair-final-{0}.md' -f [guid]::NewGuid().ToString('N')
        )

        try {
            for ($attempt = 1; $attempt -le $attemptLimit; $attempt++) {
                $livePullRequest = Assert-RepoFlowPrRepairLiveHead `
                    -Number $Number `
                    -Repository $repository `
                    -ExpectedHeadSha $expectedHeadSha

                $changedFiles = Get-RepoFlowPullRequestChangedFiles `
                    -BaseBranch ([string]$config.repository.baseBranch)
                $currentDiff = Get-RepoFlowPullRequestDiff `
                    -BaseBranch ([string]$config.repository.baseBranch)
                $repairContext = Write-RepoFlowFailedCiContext `
                    -IssueNumber ([int]$issue.number) `
                    -PullRequestNumber $Number `
                    -Checks $checks.Checks `
                    -Repository $repository `
                    -BaseBranch ([string]$config.repository.baseBranch) `
                    -OutputPath $repairContextPath `
                    -PassThru

                $contextDiagnostics = @($repairContext.Diagnostics)

                $prompt = New-RepoFlowPrRepairPrompt `
                    -Issue $issue `
                    -PullRequest $livePullRequest `
                    -HeadSha $expectedHeadSha `
                    -ContextPath $repairContextPath `
                    -CurrentDiff $currentDiff `
                    -ChangedFiles $changedFiles `
                    -Diagnostics $contextDiagnostics `
                    -Config $config `
                    -RepairAttemptLimit $attemptLimit

                Write-Host "[AGENT] Repair attempt $attempt of $attemptLimit..."

                $result = Invoke-RepoFlowAgent `
                    -RepositoryRoot $context.RepositoryRoot `
                    -Prompt $prompt `
                    -FinalMessagePath $finalMessagePath `
                    -Config $config `
                    -ReasoningEffort ([string]$config.agent.ciFixReasoningEffort)

                if ($result.ExitCode -ne 0) {
                    throw "Agent failed:$([Environment]::NewLine)$($result.Text)"
                }

                $summary = Get-RepoFlowAgentFinalMessage -Path $finalMessagePath
                $changes = Get-RepoFlowWorkingTreeStatus

                if ([string]::IsNullOrWhiteSpace($changes)) {
                    if ([string]::IsNullOrWhiteSpace($summary)) {
                        Write-Warning 'Agent completed without changing files.'
                    }
                    else {
                        Write-Host '[AGENT] Final response:'
                        Write-Host $summary
                    }

                    throw 'Repair attempt completed without changing files.'
                }

                $validation = Invoke-RepoFlowLocalValidation

                if ($validation.ExitCode -ne 0) {
                    throw (
                        'Local validation failed. The working tree was left ' +
                        "available for inspection:`n$($validation.Text)"
                    )
                }

                $livePullRequest = Assert-RepoFlowPrRepairLiveHead `
                    -Number $Number `
                    -Repository $repository `
                    -ExpectedHeadSha $expectedHeadSha

                Write-Host '[GIT] Committing repair changes...'
                Complete-RepoFlowCommit `
                    -Issue $issue `
                    -Message $commitMessage `
                    -RepositoryRoot $context.RepositoryRoot `
                    -Config $config `
                    -BeforeRetryCommit {
                        Assert-RepoFlowPrRepairLiveHead `
                            -Number $Number `
                            -Repository $repository `
                            -ExpectedHeadSha $expectedHeadSha |
                            Out-Null
                    }

                Write-Host '[GIT] Pushing repair changes...'
                Push-RepoFlowBranch -Branch ([string]$pullRequest.headRefName)

                $expectedHeadSha = Get-RepoFlowCommitHash
                $pullRequest = Wait-RepoFlowPullRequestHead `
                    -PullRequestNumber $Number `
                    -Repository $repository `
                    -ExpectedHeadSha $expectedHeadSha `
                    -TimeoutSeconds ([int]$config.ci.timeoutSeconds) `
                    -PollSeconds ([int]$config.ci.pollSeconds)

                $checks = Wait-RepoFlowPrChecks `
                    -PullRequestNumber $Number `
                    -Repository $repository `
                    -TimeoutSeconds ([int]$config.ci.timeoutSeconds) `
                    -PollSeconds ([int]$config.ci.pollSeconds)

                if ($checks.Status -eq 'passed') {
                    Write-Host ''
                    Write-Host "Pull request #$Number repair completed."
                    Write-Host "Commit: $(Get-RepoFlowShortCommitHash)"
                    Write-Host "PR:     $($pullRequest.url)"
                    return
                }

                if ($attempt -lt $attemptLimit) {
                    Write-Warning (
                        "CI is still '$($checks.Status)' after repair attempt " +
                        "$attempt of $attemptLimit."
                    )
                }
            }

            foreach ($check in @($checks.Checks | Where-Object { $_.bucket -in @('fail', 'cancel') })) {
                Write-Warning "$($check.name): $($check.link)"
            }

            throw (
                "CI did not pass for pull request #$Number after " +
                "$attemptLimit repair attempt(s)."
            )
        }
        finally {
            Remove-Item -LiteralPath $finalMessagePath -Force -ErrorAction SilentlyContinue
        }
    }
    finally {
        Remove-Item -LiteralPath $repairContextPath -Force -ErrorAction SilentlyContinue
    }
}
