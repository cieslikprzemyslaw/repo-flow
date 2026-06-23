function New-RepoFlowContext {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,

        [string]$Repo,

        [switch]$RequireGitHub,

        [switch]$RequireAgent
    )

    $selection = Get-RepoFlowRepositorySelection `
        -ConfigPath $ConfigPath `
        -RepositoryName $Repo `
        -CurrentDirectory (Get-Location).Path

    $repositoryRoot = Get-RepoFlowRepositoryRoot `
        -ConfigPath $ConfigPath `
        -RepositoryName $Repo

    Set-Location -LiteralPath $repositoryRoot

    $config = Read-RepoFlowConfiguration `
        -RepositoryRoot $repositoryRoot `
        -ConfigPath $ConfigPath `
        -RepositorySelection $selection

    Assert-RepoFlowRepositoryIdentity -Config $config
    Show-RepoFlowRepositoryBanner -Selection $selection

    if ($RequireGitHub) {
        Assert-RepoFlowGitHubAuthentication
    }

    if ($RequireAgent) {
        Resolve-RepoFlowExecutable `
            -Command ([string]$config.agent.command) |
            Out-Null
    }

    return [pscustomobject]@{
        RepositoryRoot = $repositoryRoot
        Config = $config
        RepositorySelection = $selection
    }
}


function Invoke-RepoFlowIssueRunWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [switch]$Apply,

        [string]$CiMode,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo -RequireGitHub -RequireAgent:$Apply
    $config = $context.Config
    $stateConfigPath = [string]$context.RepositorySelection.Registry.ConfigPath
    $repositoryName = [string]$context.RepositorySelection.Repository.name
    $repository = [string]$config.repository.slug
    $issue = Get-RepoFlowIssue -Number $Number -Repository $repository
    Assert-RepoFlowIssueReady -Issue $issue -Repository $repository
    $branchName = Get-RepoFlowIssueBranchName -Issue $issue
    $localExists = Test-RepoFlowLocalBranch -Branch $branchName
    $remoteExists = Test-RepoFlowRemoteBranch -Branch $branchName
    $effectiveCiMode = Get-RepoFlowEffectiveCiMode -Config $config -Override $CiMode

    if ($localExists -or $remoteExists) {
        $openPullRequest = Get-RepoFlowOpenPullRequestForBranch -Branch $branchName -Repository $repository

        if ($null -ne $openPullRequest) {
            throw "Branch already exists with open PR #$($openPullRequest.number). Use 'issue continue' with -LastPrComment or -PrCommentId."
        }

        throw "Branch already exists without an open pull request: $branchName"
    }

    Write-Host ''
    Write-Host "Issue:   #$Number $($issue.title)"
    Write-Host "URL:     $($issue.url)"
    Write-Host "Branch:  $branchName"
    Write-Host "CI mode: $effectiveCiMode"
    Write-Host ''

    if (-not $Apply) {
        Write-Host 'PLAN ONLY - no changes were made.'
        Write-Host ''
        Write-Host 'Run:'
        Write-Host "  .\repo-flow.ps1 issue run -Number $Number -Apply"
        return
    }

    Prepare-RepoFlowBaseBranch -Config $config

    if ((Test-RepoFlowLocalBranch -Branch $branchName) -or (Test-RepoFlowRemoteBranch -Branch $branchName)) {
        throw "Branch appeared while preparing the base branch: $branchName"
    }

    New-RepoFlowBranch -Branch $branchName
    $finalMessagePath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'repo-flow-agent-final-{0}.md' -f [guid]::NewGuid().ToString('N')
    )

    $runRecord = $null

    try {
        $prompt = New-RepoFlowInitialPrompt -Issue $issue -Config $config
        $scopeLength = ([string]$issue.body).Length
        Write-Host "[AGENT] Scope source: issue #$($issue.number) body ($scopeLength characters)."
        Write-Host '[AGENT] Implementing issue...'

        $runRecord = Start-RepoFlowRunRecord `
            -ConfigPath $stateConfigPath `
            -RepositoryRoot $context.RepositoryRoot `
            -Repository $repositoryName `
            -RepositorySlug $repository `
            -Operation 'issue-run' `
            -IssueNumber $Number `
            -Branch $branchName `
            -BaseSha (Get-RepoFlowCommitHash) `
            -HeadSha (Get-RepoFlowCommitHash) `
            -Phase 'branch-created' `
            -Provider ([string]$config.agent.provider) `
            -Model ([string]$config.agent.model)

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -CurrentPhase 'issue-agent-running'

        $result = Invoke-RepoFlowAgent `
            -RepositoryRoot $context.RepositoryRoot `
            -Prompt $prompt `
            -FinalMessagePath $finalMessagePath `
            -Config $config

        if ($result.ExitCode -ne 0) {
            throw "Agent failed:$([Environment]::NewLine)$($result.Text)"
        }

        $summary = Get-RepoFlowAgentFinalMessage -Path $finalMessagePath
        $changes = Get-RepoFlowWorkingTreeStatus

        if ([string]::IsNullOrWhiteSpace($changes)) {
            Write-Host ''

            if ([string]::IsNullOrWhiteSpace($summary)) {
                Write-Warning 'Agent did not provide a final response.'
            }
            else {
                Write-Host '[AGENT] Final response:'
                Write-Host $summary
                Write-Host ''
            }

            Write-Host "[GIT] Removing empty branch $branchName..."
            Invoke-RepoFlowCommand -Command 'git' -Arguments @(
                'switch',
                [string]$config.repository.baseBranch
            ) | Out-Null
            Invoke-RepoFlowCommand -Command 'git' -Arguments @(
                'branch',
                '-D',
                $branchName
            ) | Out-Null

            Complete-RepoFlowRunRecord `
                -ConfigPath $stateConfigPath `
                -RunId ([string]$runRecord.runId) `
                -Outcome 'abandoned'

            throw 'Agent completed without changing files.'
        }

        $commitMessage = Get-RepoFlowInitialCommitMessage `
            -Issue $issue `
            -Config $config

        Write-Host '[GIT] Committing changes...'

        Complete-RepoFlowCommit `
            -Issue $issue `
            -Message $commitMessage `
            -RepositoryRoot $context.RepositoryRoot `
            -Config $config

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -CurrentPhase 'changes-committed' `
            -SafePhase 'changes-committed' `
            -HeadSha (Get-RepoFlowCommitHash)

        Write-Host '[GIT] Pushing branch...'
        Push-RepoFlowBranch -Branch $branchName -SetUpstream

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -CurrentPhase 'branch-pushed' `
            -SafePhase 'branch-pushed' `
            -HeadSha (Get-RepoFlowCommitHash)

        $templatePath = Resolve-RepoFlowPath `
            -RepositoryRoot $context.RepositoryRoot `
            -Path ([string]$config.pullRequest.templatePath)

        if (-not (Test-Path -LiteralPath $templatePath)) {
            throw "Missing pull request template: $templatePath"
        }

        $template = Get-Content -LiteralPath $templatePath -Raw
        $pullRequestBody = Build-RepoFlowPullRequestBody `
            -Template $template `
            -Issue $issue `
            -AgentSummary $summary
        $pullRequestTitle = Get-RepoFlowPullRequestTitle -Issue $issue -Config $config

        Write-Host '[GH] Creating pull request...'
        $pullRequest = New-RepoFlowPullRequest `
            -Repository $repository `
            -BaseBranch ([string]$config.repository.baseBranch) `
            -HeadBranch $branchName `
            -Title $pullRequestTitle `
            -Body $pullRequestBody `
            -Draft:([bool]$config.pullRequest.createDraft)

        Write-Host "[GH] PR: $($pullRequest.url)"

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -CurrentPhase 'pull-request-created' `
            -SafePhase 'pull-request-created' `
            -PullRequestNumber ([int]$pullRequest.number) `
            -HeadSha (Get-RepoFlowCommitHash)

        $ciState = Invoke-RepoFlowCiPolicy `
            -Issue $issue `
            -PullRequest $pullRequest `
            -RepositoryRoot $context.RepositoryRoot `
            -Config $config `
            -Mode $effectiveCiMode

        $ciIdentifiers = Get-RepoFlowCiIdentifiersFromChecks -Checks $ciState.Checks
        Set-RepoFlowRunCheckpoint `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -CurrentPhase "ci-$($ciState.Status)" `
            -SafePhase "ci-$($ciState.Status)" `
            -CiRunIds @($ciIdentifiers.RunIds) `
            -CiJobIds @($ciIdentifiers.JobIds) `
            -HeadSha (Get-RepoFlowCommitHash)

        Complete-RepoFlowRunRecord `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -Outcome 'completed'

        $commitHash = Get-RepoFlowShortCommitHash
        Write-Host ''
        Write-Host 'Completed.'
        Write-Host "Branch: $branchName"
        Write-Host "Commit: $commitHash"
        Write-Host "PR:     $($pullRequest.url)"
    }
    catch {
        if ($null -ne $runRecord) {
            $latestRunRecord = Get-RepoFlowRunRecord `
                -ConfigPath $stateConfigPath `
                -RunId ([string]$runRecord.runId)

            if ([string]::IsNullOrWhiteSpace([string]$latestRunRecord.terminalOutcome)) {
                Set-RepoFlowRunPaused `
                    -ConfigPath $stateConfigPath `
                    -RunId ([string]$runRecord.runId) `
                    -PauseReason $_.Exception.Message
            }
        }

        throw
    }
    finally {
        Remove-Item -LiteralPath $finalMessagePath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RepoFlowIssueContinueWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [switch]$LastPrComment,

        [long]$PrCommentId,

        [switch]$Resume,

        [switch]$Apply,

        [string]$CiMode,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo -RequireGitHub -RequireAgent:$Apply
    $config = $context.Config
    $stateConfigPath = [string]$context.RepositorySelection.Registry.ConfigPath
    $repositoryName = [string]$context.RepositorySelection.Repository.name
    $repository = [string]$config.repository.slug
    $issue = Get-RepoFlowIssue -Number $Number -Repository $repository
    Assert-RepoFlowIssueReady -Issue $issue -Repository $repository
    $branchName = Get-RepoFlowIssueBranchName -Issue $issue
    $branchExists = (Test-RepoFlowLocalBranch -Branch $branchName) -or (Test-RepoFlowRemoteBranch -Branch $branchName)

    if (-not $branchExists) {
        throw "Issue branch does not exist: $branchName. Use 'issue run' for the first implementation."
    }

    $pullRequest = Get-RepoFlowOpenPullRequestForBranch -Branch $branchName -Repository $repository

    if ($null -eq $pullRequest) {
        $latest = Get-RepoFlowLatestPullRequestForBranch -Branch $branchName -Repository $repository

        if ($null -ne $latest -and $latest.state -eq 'MERGED') {
            throw "Pull request #$($latest.number) is already merged. Post-merge work requires a new issue."
        }

        if ($null -ne $latest -and $latest.state -eq 'CLOSED') {
            throw "Pull request #$($latest.number) is closed. RepoFlow will not resume a closed review."
        }

        throw "Branch '$branchName' exists without an open pull request."
    }

    $comment = Get-RepoFlowSelectedPullRequestComment `
        -PullRequest $pullRequest `
        -Config $config `
        -LastPrComment:$LastPrComment `
        -PrCommentId $PrCommentId
    Show-RepoFlowSelectedComment -PullRequest $pullRequest -Comment $comment
    $effectiveCiMode = Get-RepoFlowEffectiveCiMode -Config $config -Override $CiMode

    Write-Host "Branch:  $branchName"
    Write-Host "CI mode: $effectiveCiMode"
    Write-Host "Resume:  $([bool]$Resume)"
    Write-Host ''

    if (-not $Apply) {
        Write-Host 'PLAN ONLY - no changes were made.'

        if ($Resume) {
            Write-Host (
                'Apply mode will preserve and continue the existing dirty ' +
                'working tree on the issue branch.'
            )
        }
        else {
            Write-Host 'Run again with -Apply to process this comment.'
        }

        return
    }

    if (
        $config.reviewFeedback.confirmBeforeRun -and
        -not (Confirm-RepoFlowAction -Prompt 'Process this review feedback')
    ) {
        Write-Host 'Cancelled.'
        return
    }

    if ($Resume) {
        Assert-RepoFlowReviewResumeAllowed `
            -ConfigPath $stateConfigPath `
            -RepositoryRoot $context.RepositoryRoot `
            -Repository $repositoryName `
            -Branch $branchName `
            -IssueNumber $Number `
            -PullRequestNumber ([int]$pullRequest.number) `
            -PrCommentId ([long]$comment.id) | Out-Null

        Write-Host (
            '[GIT] Preserving existing working-tree changes on ' +
            "$branchName."
        )
    }
    else {
        Assert-RepoFlowCleanWorkingTree -Config $config
        $currentBranch = Get-RepoFlowCurrentBranch

        if (
            $currentBranch -ne $branchName -and
            $currentBranch -ne [string]$config.repository.baseBranch
        ) {
            Prepare-RepoFlowBaseBranch -Config $config
        }

        Switch-RepoFlowExistingBranch -Branch $branchName
    }

    $finalMessagePath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'repo-flow-review-final-{0}.md' -f [guid]::NewGuid().ToString('N')
    )

    $runRecord = $null

    try {
        $prompt = New-RepoFlowReviewPrompt `
            -Issue $issue `
            -PullRequest $pullRequest `
            -Comment $comment `
            -Config $config `
            -ResumeInterruptedWork:$Resume
        $scopeLength = ([string]$issue.body).Length
        Write-Host "[AGENT] Scope source: issue #$($issue.number) body ($scopeLength characters) plus PR comment #$($comment.id)."

        if ($Resume) {
            Write-Host '[AGENT] Resuming interrupted review feedback...'
        }
        else {
            Write-Host '[AGENT] Applying review feedback...'
        }

        Start-RepoFlowReviewAgentRunState `
            -ConfigPath $stateConfigPath `
            -RepositoryRoot $context.RepositoryRoot `
            -Repository $repositoryName `
            -RepositorySlug $repository `
            -Branch $branchName `
            -IssueNumber $Number `
            -PullRequestNumber ([int]$pullRequest.number) `
            -PrCommentId ([long]$comment.id) `
            -Config $config `
            -AdoptedExistingChanges:$Resume | Out-Null

        $runRecord = Read-RepoFlowAgentRunState `
            -ConfigPath $stateConfigPath `
            -RepositoryRoot $context.RepositoryRoot

        try {
            $result = Invoke-RepoFlowAgent `
                -RepositoryRoot $context.RepositoryRoot `
                -Prompt $prompt `
                -FinalMessagePath $finalMessagePath `
                -Config $config
        }
        catch {
            Set-RepoFlowAgentRunInterrupted `
                -ConfigPath $stateConfigPath `
                -RepositoryRoot $context.RepositoryRoot `
                -ErrorMessage $_.Exception.Message
            throw
        }

        if ($result.ExitCode -ne 0) {
            Set-RepoFlowAgentRunInterrupted `
                -ConfigPath $stateConfigPath `
                -RepositoryRoot $context.RepositoryRoot `
                -ErrorMessage $result.Text
            throw "Agent failed:$([Environment]::NewLine)$($result.Text)"
        }

        $summary = Get-RepoFlowAgentFinalMessage -Path $finalMessagePath
        $changes = Get-RepoFlowWorkingTreeStatus

        if ([string]::IsNullOrWhiteSpace($changes)) {
            Write-Host ''

            if ([string]::IsNullOrWhiteSpace($summary)) {
                Write-Warning 'Agent made no changes and did not provide a final response.'
            }
            else {
                Write-Host '[AGENT] Final response:'
                Write-Host $summary
            }

            Write-Host 'No commit was created.'
            Complete-RepoFlowRunRecord `
                -ConfigPath $stateConfigPath `
                -RunId ([string]$runRecord.runId) `
                -Outcome 'abandoned'
            return
        }

        $commitMessage = Get-RepoFlowReviewCommitMessage `
            -Issue $issue `
            -Config $config

        Write-Host '[GIT] Committing review changes...'

        Complete-RepoFlowCommit `
            -Issue $issue `
            -Message $commitMessage `
            -RepositoryRoot $context.RepositoryRoot `
            -Config $config

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -CurrentPhase 'review-committed' `
            -SafePhase 'review-committed' `
            -HeadSha (Get-RepoFlowCommitHash)

        Write-Host '[GIT] Pushing review changes...'
        Push-RepoFlowBranch -Branch $branchName

        # Do not read stale checks from the previous PR head after pushing review changes.
        $expectedHeadSha = Get-RepoFlowCommitHash
        $pullRequest = Wait-RepoFlowPullRequestHead `
            -PullRequestNumber ([int]$pullRequest.number) `
            -Repository $repository `
            -ExpectedHeadSha $expectedHeadSha `
            -TimeoutSeconds ([int]$config.ci.timeoutSeconds) `
            -PollSeconds ([int]$config.ci.pollSeconds)

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -CurrentPhase 'review-pushed' `
            -SafePhase 'review-pushed' `
            -HeadSha $expectedHeadSha `
            -PullRequestNumber ([int]$pullRequest.number)

        $ciState = Invoke-RepoFlowCiPolicy `
            -Issue $issue `
            -PullRequest $pullRequest `
            -RepositoryRoot $context.RepositoryRoot `
            -Config $config `
            -Mode $effectiveCiMode

        $ciIdentifiers = Get-RepoFlowCiIdentifiersFromChecks -Checks $ciState.Checks
        Set-RepoFlowRunCheckpoint `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -CurrentPhase "ci-$($ciState.Status)" `
            -SafePhase "ci-$($ciState.Status)" `
            -CiRunIds @($ciIdentifiers.RunIds) `
            -CiJobIds @($ciIdentifiers.JobIds) `
            -HeadSha $expectedHeadSha

        Complete-RepoFlowRunRecord `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$runRecord.runId) `
            -Outcome 'completed'

        Write-Host ''
        Write-Host 'Review feedback completed.'
        Write-Host "Commit: $(Get-RepoFlowShortCommitHash)"
        Write-Host "PR:     $($pullRequest.url)"
    }
    catch {
        if ($null -ne $runRecord) {
            $latestRunRecord = Get-RepoFlowRunRecord `
                -ConfigPath $stateConfigPath `
                -RunId ([string]$runRecord.runId)

            if ([string]::IsNullOrWhiteSpace([string]$latestRunRecord.terminalOutcome)) {
                Set-RepoFlowRunPaused `
                    -ConfigPath $stateConfigPath `
                    -RunId ([string]$runRecord.runId) `
                    -PauseReason $_.Exception.Message
            }
        }

        throw
    }
    finally {
        Remove-Item -LiteralPath $finalMessagePath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RepoFlowPrStatusWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo -RequireGitHub
    $pullRequest = Get-RepoFlowPullRequest -Number $Number -Repository ([string]$context.Config.repository.slug)
    $checks = Get-RepoFlowPrCheckState -PullRequestNumber $Number -Repository ([string]$context.Config.repository.slug)
    Show-RepoFlowPullRequestStatus -PullRequest $pullRequest -CheckState $checks
}

function Invoke-RepoFlowPrWatchWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo -RequireGitHub
    $pullRequest = Get-RepoFlowPullRequest -Number $Number -Repository ([string]$context.Config.repository.slug)
    $checks = Wait-RepoFlowPrChecks `
        -PullRequestNumber $Number `
        -Repository ([string]$context.Config.repository.slug) `
        -TimeoutSeconds ([int]$context.Config.ci.timeoutSeconds) `
        -PollSeconds ([int]$context.Config.ci.pollSeconds)
    Show-RepoFlowPullRequestStatus -PullRequest $pullRequest -CheckState $checks
}

function Invoke-RepoFlowPrReadyWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [switch]$Apply,

        [string]$CiMode,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo -RequireGitHub
    $config = $context.Config
    $repository = [string]$config.repository.slug
    $pullRequest = Get-RepoFlowPullRequest -Number $Number -Repository $repository

    if ($pullRequest.state -ne 'OPEN') {
        throw "Pull request #$Number is not open."
    }

    if (-not $pullRequest.isDraft) {
        Write-Host "Pull request #$Number is already ready for review."
        return
    }

    $mode = Get-RepoFlowEffectiveCiMode -Config $config -Override $CiMode
    $checks = Get-RepoFlowPrCheckState -PullRequestNumber $Number -Repository $repository
    Show-RepoFlowPullRequestStatus -PullRequest $pullRequest -CheckState $checks

    if ($mode -eq 'require-passing' -and $checks.Status -ne 'passed') {
        throw "Pull request #$Number cannot be marked ready because CI status is '$($checks.Status)'."
    }

    if ($mode -eq 'observe' -and $checks.Status -ne 'passed') {
        Write-Warning "CI status is '$($checks.Status)', but observe mode allows manual readiness."
    }

    if (-not $Apply) {
        Write-Host ''
        Write-Host 'PLAN ONLY - the pull request remains a draft.'
        Write-Host 'Run again with -Apply to mark it ready for review.'
        return
    }

    Set-RepoFlowPullRequestReady -Number $Number -Repository $repository
    Write-Host "Pull request #$Number is ready for review."
}

function Invoke-RepoFlowPrMergeWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [switch]$Apply,

        [string]$CiMode,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo -RequireGitHub
    $config = $context.Config
    $repository = [string]$config.repository.slug
    $pullRequest = Get-RepoFlowPullRequest `
        -Number $Number `
        -Repository $repository

    if ($pullRequest.state -ne 'OPEN') {
        throw "Pull request #$Number is not open."
    }

    if ($pullRequest.baseRefName -ne [string]$config.repository.baseBranch) {
        throw (
            "Pull request #$Number targets '$($pullRequest.baseRefName)', " +
            "not '$($config.repository.baseBranch)'."
        )
    }

    $mode = Get-RepoFlowEffectiveCiMode -Config $config -Override $CiMode

    Write-Host ''
    Write-Host "PR:           #$Number $($pullRequest.title)"
    Write-Host "URL:          $($pullRequest.url)"
    Write-Host "Head branch:  $($pullRequest.headRefName)"
    Write-Host "Base branch:  $($pullRequest.baseRefName)"
    Write-Host "Draft:        $($pullRequest.isDraft)"
    Write-Host "Merge method: $($config.pullRequest.mergeMethod)"
    Write-Host "CI mode:      $mode"
    Write-Host ''

    if (-not $Apply) {
        Write-Host 'PLAN ONLY - the pull request was not changed or merged.'
        Write-Host ''
        Write-Host 'After you manually review the diff and validate the application, run:'
        Write-Host "  .\repo-flow.ps1 pr merge -Number $Number -Apply"
        Write-Host ''
        Write-Host 'The apply command will still require typing MERGE before any PR mutation.'
        return
    }

    Assert-RepoFlowCleanWorkingTree -Config $config

    if ($mode -ne 'skip') {
        Write-Host '[CI] Waiting for pull-request checks before merge...'
        $checks = Wait-RepoFlowPrChecks `
            -PullRequestNumber $Number `
            -Repository $repository `
            -TimeoutSeconds ([int]$config.ci.timeoutSeconds) `
            -PollSeconds ([int]$config.ci.pollSeconds)

        Show-RepoFlowPullRequestStatus `
            -PullRequest $pullRequest `
            -CheckState $checks

        if ($checks.Status -ne 'passed') {
            throw (
                "Pull request #$Number cannot be merged because CI status is " +
                "'$($checks.Status)'."
            )
        }
    }
    else {
        Write-Warning 'CI checks are skipped for this merge.'
    }

    Write-Host ''
    Write-Host 'RepoFlow is ready to perform the following explicit merge workflow:'
    Write-Host '- mark the draft pull request ready, when necessary'
    Write-Host "- merge it using $($config.pullRequest.mergeMethod)"
    Write-Host "- update local $($config.repository.baseBranch)"

    if ([bool]$config.pullRequest.deleteBranchOnMerge) {
        Write-Host '- delete the branch only after GitHub confirms the merge'
    }
    else {
        Write-Host '- keep the merged branch because deleteBranchOnMerge is false'
    }

    if (-not (Confirm-RepoFlowManualReview -PullRequestNumber $Number)) {
        Write-Host 'Cancelled. The pull request was not changed or merged.'
        return
    }

    if ($pullRequest.isDraft) {
        Write-Host "[GH] Marking pull request #$Number ready..."
        Set-RepoFlowPullRequestReady `
            -Number $Number `
            -Repository $repository
    }

    Write-Host (
        "[GH] Merging pull request #$Number using " +
        "$($config.pullRequest.mergeMethod)..."
    )

    Merge-RepoFlowPullRequest `
        -Number $Number `
        -Repository $repository `
        -Method ([string]$config.pullRequest.mergeMethod)

    $mergedPullRequest = Get-RepoFlowPullRequest `
        -Number $Number `
        -Repository $repository

    if ($mergedPullRequest.state -ne 'MERGED') {
        throw (
            "GitHub accepted the merge command, but pull request #$Number " +
            "is currently '$($mergedPullRequest.state)'."
        )
    }

    Complete-RepoFlowPostMergeCleanup `
        -PullRequest $mergedPullRequest `
        -Config $config

    Write-Host ''
    Write-Host "Pull request #$Number was merged."
    Write-Host "URL: $($mergedPullRequest.url)"
}

function Invoke-RepoFlowIssueSyncWorkflow {
    [CmdletBinding()]
    param(
        [switch]$Apply,

        [switch]$SkipCreates,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo -RequireGitHub
    Invoke-RepoFlowIssueSync `
        -RepositoryRoot $context.RepositoryRoot `
        -Config $context.Config `
        -Apply:$Apply `
        -SkipCreates:$SkipCreates
}

function Invoke-RepoFlowBranchCleanupWorkflow {
    [CmdletBinding()]
    param(
        [switch]$Apply,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo -RequireGitHub
    Invoke-RepoFlowBranchCleanup -Config $context.Config -Apply:$Apply
}

function Invoke-RepoFlowConfigValidateWorkflow {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo
    Write-Host "Configuration is valid: $($context.Config.configPath)"
}

function Invoke-RepoFlowConfigShowWorkflow {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext -ConfigPath $ConfigPath -Repo $Repo
    Show-RepoFlowConfiguration -Config $context.Config
}
