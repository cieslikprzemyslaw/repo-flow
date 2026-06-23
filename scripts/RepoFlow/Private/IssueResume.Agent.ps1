function Invoke-RepoFlowResumedInitialAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resolved,

        [Parameter(Mandatory)]
        $Context
    )

    $plan = $Resolved.Plan
    $record = $plan.RunRecord
    $config = $Context.Config
    $stateConfigPath = $Resolved.StateConfigPath

    Resolve-RepoFlowExecutable `
        -Command ([string]$config.agent.command) |
        Out-Null

    Set-RepoFlowResumeBranch -BranchState $Resolved.BranchState
    Assert-RepoFlowNoGitOperationInProgress -RepositoryRoot $Context.RepositoryRoot

    Set-RepoFlowRunCheckpoint `
        -ConfigPath $stateConfigPath `
        -RunId ([string]$record.runId) `
        -CurrentPhase 'issue-agent-running'

    $finalMessagePath = Join-Path ([System.IO.Path]::GetTempPath()) (
        'repo-flow-agent-resume-{0}.md' -f [guid]::NewGuid().ToString('N')
    )

    try {
        $prompt = New-RepoFlowInitialPrompt `
            -Issue $Resolved.Issue `
            -Config $config `
            -ResumeInterruptedWork:$Resolved.BranchState.IsDirty

        Write-Host '[AGENT] Resuming the initial issue implementation...'
        $result = Invoke-RepoFlowAgent `
            -RepositoryRoot $Context.RepositoryRoot `
            -Prompt $prompt `
            -FinalMessagePath $finalMessagePath `
            -Config $config

        if ($result.ExitCode -ne 0) {
            throw "Agent failed:$([Environment]::NewLine)$($result.Text)"
        }

        if ([string]::IsNullOrWhiteSpace((Get-RepoFlowWorkingTreeStatus))) {
            throw 'The resumed agent completed without producing implementation changes.'
        }

        Set-RepoFlowRunCheckpoint `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$record.runId) `
            -CurrentPhase 'issue-agent-completed' `
            -SafePhase 'issue-agent-completed' `
            -HeadSha (Get-RepoFlowCommitHash)
    }
    catch {
        Set-RepoFlowRunPaused `
            -ConfigPath $stateConfigPath `
            -RunId ([string]$record.runId) `
            -CurrentPhase 'issue-agent-running' `
            -PauseReason $_.Exception.Message
        throw
    }
    finally {
        Remove-Item -LiteralPath $finalMessagePath -Force -ErrorAction SilentlyContinue
    }
}

function Complete-RepoFlowResumedCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resolved,

        [Parameter(Mandatory)]
        $Context,

        [Parameter(Mandatory)]
        [ValidateSet('initial', 'review')]
        [string]$Kind
    )

    Set-RepoFlowResumeBranch -BranchState $Resolved.BranchState
    Assert-RepoFlowNoGitOperationInProgress -RepositoryRoot $Context.RepositoryRoot

    $record = $Resolved.Plan.RunRecord
    $message = if ($Kind -eq 'initial') {
        Get-RepoFlowInitialCommitMessage `
            -Issue $Resolved.Issue `
            -Config $Context.Config
    }
    else {
        Get-RepoFlowReviewCommitMessage `
            -Issue $Resolved.Issue `
            -Config $Context.Config
    }

    Write-Host '[GIT] Committing resumed changes...'
    Complete-RepoFlowCommit `
        -Issue $Resolved.Issue `
        -Message $message `
        -RepositoryRoot $Context.RepositoryRoot `
        -Config $Context.Config

    $phase = if ($Kind -eq 'initial') {
        'changes-committed'
    }
    else {
        'review-committed'
    }

    Set-RepoFlowRunCheckpoint `
        -ConfigPath $Resolved.StateConfigPath `
        -RunId ([string]$record.runId) `
        -CurrentPhase $phase `
        -SafePhase $phase `
        -HeadSha (Get-RepoFlowCommitHash)
}

function Set-RepoFlowReconciledCommitCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Resolved,

        [Parameter(Mandatory)]
        [ValidateSet('initial', 'review')]
        [string]$Kind
    )

    $phase = if ($Kind -eq 'initial') {
        'changes-committed'
    }
    else {
        'review-committed'
    }

    Set-RepoFlowRunCheckpoint `
        -ConfigPath $Resolved.StateConfigPath `
        -RunId ([string]$Resolved.Plan.RunRecord.runId) `
        -CurrentPhase $phase `
        -SafePhase $phase `
        -HeadSha ([string]$Resolved.BranchState.LocalSha)
}
