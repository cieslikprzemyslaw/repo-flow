function Get-RepoFlowPrCheckState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $result = Invoke-RepoFlowCommand -Command 'gh' -Arguments @(
        'pr',
        'checks',
        $PullRequestNumber.ToString(),
        '--repo',
        $Repository,
        '--json',
        'name,bucket,link'
    ) -AllowFailure

    if ([string]::IsNullOrWhiteSpace($result.Text)) {
        return [pscustomobject]@{
            Status = 'pending'
            Checks = @()
        }
    }

    try {
        $checks = @($result.Text | ConvertFrom-Json)
    }
    catch {
        return [pscustomobject]@{
            Status = 'pending'
            Checks = @()
        }
    }

    if ($checks.Count -eq 0) {
        return [pscustomobject]@{
            Status = 'pending'
            Checks = @()
        }
    }

    $pendingChecks = @(
        $checks |
        Where-Object {
            [string]$_.bucket -eq 'pending' -or
            [string]$_.bucket -notin @(
                'pass',
                'fail',
                'cancel',
                'skipping'
            )
        }
    )

    # Pending checks take precedence over failures. This prevents RepoFlow
    # from reacting to a partially completed check set before GitHub has
    # reported every terminal result.
    if ($pendingChecks.Count -gt 0) {
        return [pscustomobject]@{
            Status = 'pending'
            Checks = $checks
        }
    }

    if (@($checks | Where-Object { $_.bucket -in @('fail', 'cancel') }).Count -gt 0) {
        return [pscustomobject]@{
            Status = 'failed'
            Checks = $checks
        }
    }

    return [pscustomobject]@{
        Status = 'passed'
        Checks = $checks
    }
}

function Invoke-RepoFlowCiFixAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Checks,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        $Config,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StateConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Phase = 'ci-fix-agent'
    )

    $contextPath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'repo-flow-ci-failure-{0}.md' -f [guid]::NewGuid().ToString('N')
    )
    $finalMessagePath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'repo-flow-ci-fix-{0}.md' -f [guid]::NewGuid().ToString('N')
    )

    try {
        Write-RepoFlowFailedCiContext `
            -IssueNumber ([int]$Issue.number) `
            -PullRequestNumber ([int]$PullRequest.number) `
            -Checks $Checks `
            -Repository ([string]$Config.repository.slug) `
            -BaseBranch ([string]$Config.repository.baseBranch) `
            -OutputPath $contextPath

        $prompt = New-RepoFlowCiFixPrompt `
            -Issue $Issue `
            -PullRequestNumber ([int]$PullRequest.number) `
            -ContextPath $contextPath `
            -Config $Config

        Write-Host '[AGENT] Making a focused CI-fix attempt...'
        $result = Invoke-RepoFlowAgent `
            -RepositoryRoot $RepositoryRoot `
            -Prompt $prompt `
            -FinalMessagePath $finalMessagePath `
            -Config $Config `
            -ReasoningEffort ([string]$Config.agent.ciFixReasoningEffort) `
            -StateConfigPath $StateConfigPath `
            -RunId $RunId `
            -Phase $Phase

        if ($result.ExitCode -ne 0) {
            Write-Warning "Agent CI-fix attempt failed: $($result.Text)"
            return $false
        }

        $summary = Get-RepoFlowAgentFinalMessage -Path $finalMessagePath
        $changes = Get-RepoFlowWorkingTreeStatus

        if ([string]::IsNullOrWhiteSpace($changes)) {
            if (-not [string]::IsNullOrWhiteSpace($summary)) {
                Write-Host '[AGENT] Final response:'
                Write-Host $summary
            }

            Write-Warning 'Agent made no changes during the CI-fix attempt.'
            return $false
        }

        $commitMessage = Get-RepoFlowCiFixCommitMessage `
            -Issue $Issue `
            -Config $Config

        Write-Host '[GIT] Committing CI fix...'

        Complete-RepoFlowCommit `
            -Issue $Issue `
            -Message $commitMessage `
            -RepositoryRoot $RepositoryRoot `
            -Config $Config `
            -StateConfigPath $StateConfigPath `
            -RunId $RunId `
            -Phase 'ci-pre-commit-fix'
        Write-Host '[GIT] Pushing CI fix...'
        Push-RepoFlowBranch -Branch ([string]$PullRequest.headRefName)
        return $true
    }
    finally {
        Remove-Item -LiteralPath $contextPath, $finalMessagePath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RepoFlowCiPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        $Config,

        [Parameter(Mandatory)]
        [ValidateSet('skip', 'observe', 'require-passing')]
        [string]$Mode,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StateConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Phase = 'ci-watching'
    )

    if ($Mode -eq 'skip') {
        Write-Host '[CI] Check observation skipped.'
        return [pscustomobject]@{
            Status = 'skipped'
            Checks = @()
        }
    }

    $noActivityWarningSeconds = [int](Get-RepoFlowProperty `
        -Object $Config.agent `
        -Name 'noActivityWarningSeconds' `
        -Default 180)

    Write-Host "[CI] Watching checks for up to $($Config.ci.timeoutSeconds) seconds..."
    $state = Wait-RepoFlowPrChecks `
        -PullRequestNumber ([int]$PullRequest.number) `
        -Repository ([string]$Config.repository.slug) `
        -TimeoutSeconds ([int]$Config.ci.timeoutSeconds) `
        -PollSeconds ([int]$Config.ci.pollSeconds) `
        -StateConfigPath $StateConfigPath `
        -RunId $RunId `
        -Phase $Phase `
        -NoActivityWarningSeconds $noActivityWarningSeconds

    if ($state.Status -eq 'passed') {
        Write-Host '[CI] All reported checks passed.'
        return $state
    }

    if ($Mode -eq 'observe') {
        if ($state.Status -eq 'failed') {
            Write-Warning 'CI failed. Observe mode will not attempt a fix.'
        }
        else {
            Write-Warning 'CI is still pending or no checks were reported.'
        }

        return $state
    }

    $attempt = 0

    while (
        $state.Status -eq 'failed' -and
        $attempt -lt [int]$Config.ci.autoFixAttempts
    ) {
        $attempt++
        Write-Host "[CI] Automatic fix attempt $attempt of $($Config.ci.autoFixAttempts)..."
        $created = Invoke-RepoFlowCiFixAttempt `
            -Issue $Issue `
            -PullRequest $PullRequest `
            -Checks $state.Checks `
            -RepositoryRoot $RepositoryRoot `
            -Config $Config `
            -StateConfigPath $StateConfigPath `
            -RunId $RunId `
            -Phase 'ci-fix-agent'

        if (-not $created) {
            break
        }

        $expectedHeadSha = Get-RepoFlowCommitHash

        Wait-RepoFlowPullRequestHead `
            -PullRequestNumber ([int]$PullRequest.number) `
            -Repository ([string]$Config.repository.slug) `
            -ExpectedHeadSha $expectedHeadSha `
            -TimeoutSeconds ([int]$Config.ci.timeoutSeconds) `
            -PollSeconds ([int]$Config.ci.pollSeconds) `
            -StateConfigPath $StateConfigPath `
            -RunId $RunId `
            -Phase 'ci-head-sync' `
            -NoActivityWarningSeconds $noActivityWarningSeconds |
            Out-Null

        $state = Wait-RepoFlowPrChecks `
            -PullRequestNumber ([int]$PullRequest.number) `
            -Repository ([string]$Config.repository.slug) `
            -TimeoutSeconds ([int]$Config.ci.timeoutSeconds) `
            -PollSeconds ([int]$Config.ci.pollSeconds) `
            -StateConfigPath $StateConfigPath `
            -RunId $RunId `
            -Phase $Phase `
            -NoActivityWarningSeconds $noActivityWarningSeconds

        if ($state.Status -eq 'passed') {
            Write-Host '[CI] All checks passed after the automatic fix.'
            return $state
        }
    }

    if ($state.Status -eq 'failed') {
        foreach ($check in @($state.Checks | Where-Object { $_.bucket -in @('fail', 'cancel') })) {
            Write-Warning "$($check.name): $($check.link)"
        }

        throw "CI did not pass for pull request #$($PullRequest.number)."
    }

    throw "CI is still pending or no checks were reported for pull request #$($PullRequest.number)."
}
