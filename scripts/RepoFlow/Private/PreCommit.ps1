function Invoke-RepoFlowCommitAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        $Config
    )

    Invoke-RepoFlowCommand `
        -Command 'git' `
        -Arguments @('add', '--all') |
        Out-Null

    $arguments = @('commit')

    if ([bool]$Config.git.signOffCommits) {
        $arguments += '-s'
    }

    $arguments += @('-m', $Message)

    return Invoke-RepoFlowCommand `
        -Command 'git' `
        -Arguments $arguments `
        -AllowFailure
}

function Write-RepoFlowPreCommitFailureContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        [string]$FailureText,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $status = (
        Invoke-RepoFlowCommand `
            -Command 'git' `
            -Arguments @('status', '--short') `
            -AllowFailure
    ).Text

    $unstagedStat = (
        Invoke-RepoFlowCommand `
            -Command 'git' `
            -Arguments @('diff', '--stat') `
            -AllowFailure
    ).Text

    $stagedStat = (
        Invoke-RepoFlowCommand `
            -Command 'git' `
            -Arguments @('diff', '--cached', '--stat') `
            -AllowFailure
    ).Text

    $maximumFailureLength = [Math]::Min($FailureText.Length, 30000)
    $trimmedFailure = if ($maximumFailureLength -gt 0) {
        $FailureText.Substring(0, $maximumFailureLength)
    }
    else {
        'No commit-hook output was captured.'
    }

    $content = [System.Collections.Generic.List[string]]::new()
    $content.Add('# Pre-commit hook failure')
    $content.Add('')
    $content.Add("Issue: #$($Issue.number) $($Issue.title)")
    $content.Add('')
    $content.Add('## Git status')
    $content.Add('')
    $content.Add('```text')
    $statusOutput = if ([string]::IsNullOrWhiteSpace($status)) {
        'No status output.'
    }
    else {
        $status
    }

    $content.Add($statusOutput)
    $content.Add('```')
    $content.Add('')
    $content.Add('## Staged diff summary')
    $content.Add('')
    $content.Add('```text')
    $stagedStatOutput = if ([string]::IsNullOrWhiteSpace($stagedStat)) {
        'No staged diff summary.'
    }
    else {
        $stagedStat
    }

    $content.Add($stagedStatOutput)
    $content.Add('```')
    $content.Add('')
    $content.Add('## Unstaged diff summary')
    $content.Add('')
    $content.Add('```text')
    $unstagedStatOutput = if ([string]::IsNullOrWhiteSpace($unstagedStat)) {
        'No unstaged diff summary.'
    }
    else {
        $unstagedStat
    }

    $content.Add($unstagedStatOutput)
    $content.Add('```')
    $content.Add('')
    $content.Add('## Commit-hook output')
    $content.Add('')
    $content.Add('```text')
    $content.Add($trimmedFailure)
    $content.Add('```')

    Set-Content `
        -LiteralPath $OutputPath `
        -Value $content `
        -Encoding utf8
}

function Invoke-RepoFlowPreCommitFixAttempt {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        [string]$FailureText,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        $Config
    )

    $contextPath = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ('repo-flow-pre-commit-failure-{0}.md' -f [guid]::NewGuid().ToString('N'))

    $finalMessagePath = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ('repo-flow-pre-commit-final-{0}.md' -f [guid]::NewGuid().ToString('N'))

    try {
        Write-RepoFlowPreCommitFailureContext `
            -Issue $Issue `
            -FailureText $FailureText `
            -OutputPath $contextPath

        $prompt = New-RepoFlowPreCommitFixPrompt `
            -Issue $Issue `
            -ContextPath $contextPath

        Write-Host '[AGENT] Making a focused pre-commit fix attempt...'

        $result = Invoke-RepoFlowAgent `
            -RepositoryRoot $RepositoryRoot `
            -Prompt $prompt `
            -FinalMessagePath $finalMessagePath `
            -Config $Config `
            -ReasoningEffort ([string]$Config.agent.preCommitFixReasoningEffort)

        $summary = Get-RepoFlowAgentFinalMessage -Path $finalMessagePath

        if (-not [string]::IsNullOrWhiteSpace($summary)) {
            Write-Host '[AGENT] Final response:'
            Write-Host $summary
        }

        if ($result.ExitCode -ne 0) {
            Write-Warning (
                'Agent pre-commit fix attempt failed: {0}' -f $result.Text
            )
            return $false
        }

        return $true
    }
    finally {
        Remove-Item `
            -LiteralPath $contextPath, $finalMessagePath `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Complete-RepoFlowCommit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        $Config
    )

    $commitResult = Invoke-RepoFlowCommitAttempt `
        -Message $Message `
        -Config $Config

    if ($commitResult.ExitCode -eq 0) {
        return
    }

    $maximumFixAttempts = [int]$Config.git.preCommitFixAttempts

    if ($maximumFixAttempts -le 0) {
        throw (
            'Git commit was blocked and automatic pre-commit fixes ' +
            "are disabled:`n{0}"
        ) -f $commitResult.Text
    }

    $lastFailure = [string]$commitResult.Text

    for (
        $attempt = 1;
        $attempt -le $maximumFixAttempts;
        $attempt++
    ) {
        Write-Host ''
        Write-Warning 'Git commit was blocked by a pre-commit hook.'
        Write-Host '[GIT] Commit-hook output:'
        Write-Host $lastFailure
        Write-Host ''
        Write-Host (
            '[GIT] Automatic pre-commit fix attempt ' +
            "$attempt of $maximumFixAttempts..."
        )

        $fixCompleted = Invoke-RepoFlowPreCommitFixAttempt `
            -Issue $Issue `
            -FailureText $lastFailure `
            -RepositoryRoot $RepositoryRoot `
            -Config $Config

        if (-not $fixCompleted) {
            throw (
                "Automatic pre-commit fix attempt $attempt failed. " +
                'All working-tree changes were preserved.'
            )
        }

        Write-Host '[GIT] Retrying commit...'

        $commitResult = Invoke-RepoFlowCommitAttempt `
            -Message $Message `
            -Config $Config

        if ($commitResult.ExitCode -eq 0) {
            Write-Host '[GIT] Commit succeeded after the automatic fix.'
            return
        }

        $lastFailure = [string]$commitResult.Text
    }

    throw (
        'Git commit still failed after {0} automatic ' +
        'pre-commit fix attempt(s). ' +
        "All working-tree changes were preserved:`n{1}"
    ) -f $maximumFixAttempts, $lastFailure
}
