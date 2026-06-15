function Resolve-RepoFlowExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command
    )

    $resolved = Get-Command -Name $Command -ErrorAction SilentlyContinue

    if ($null -eq $resolved -and -not $Command.EndsWith('.cmd', [System.StringComparison]::OrdinalIgnoreCase)) {
        $resolved = Get-Command -Name "$Command.cmd" -ErrorAction SilentlyContinue
    }

    if ($null -eq $resolved) {
        throw "Required agent command not found: $Command"
    }

    return $resolved.Source
}

function Get-RepoFlowAgentFinalMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $message = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue

    if ([string]::IsNullOrWhiteSpace($message)) {
        return ''
    }

    return $message.Trim()
}

function Get-RepoFlowCodexUsage {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$JsonLines
    )

    $totals = [ordered]@{
        InputTokens = 0L
        CachedInputTokens = 0L
        OutputTokens = 0L
        ReasoningOutputTokens = 0L
    }

    if ([string]::IsNullOrWhiteSpace($JsonLines)) {
        return [pscustomobject]$totals
    }

    foreach ($line in @($JsonLines -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $event = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        if ([string]$event.type -ne 'turn.completed' -or $null -eq $event.usage) {
            continue
        }

        $totals.InputTokens += [long](Get-RepoFlowProperty -Object $event.usage -Name 'input_tokens' -Default 0)
        $totals.CachedInputTokens += [long](Get-RepoFlowProperty -Object $event.usage -Name 'cached_input_tokens' -Default 0)
        $totals.OutputTokens += [long](Get-RepoFlowProperty -Object $event.usage -Name 'output_tokens' -Default 0)
        $totals.ReasoningOutputTokens += [long](Get-RepoFlowProperty -Object $event.usage -Name 'reasoning_output_tokens' -Default 0)
    }

    return [pscustomobject]$totals
}

function Invoke-RepoFlowCodexWithHeartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$FinalMessagePath,

        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh')]
        [string]$ReasoningEffort,

        [ValidateRange(5, 300)]
        [int]$HeartbeatSeconds = 15
    )

    $promptPath = [System.IO.Path]::GetTempFileName()
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $exitCodePath = [System.IO.Path]::GetTempFileName()
    $job = $null

    try {
        Set-Content -LiteralPath $promptPath -Value $Prompt -Encoding utf8
        $executablePath = Resolve-RepoFlowExecutable -Command $Command
        $arguments = @(
            '-a',
            'never',
            '-s',
            'workspace-write',
            '-C',
            $RepositoryRoot,
            '-c',
            ('model_reasoning_effort="{0}"' -f $ReasoningEffort),
            'exec',
            '--json',
            '-o',
            $FinalMessagePath,
            '-'
        )

        Write-Host "[AGENT] Reasoning effort: $ReasoningEffort"

        $job = Start-Job -ScriptBlock {
            param(
                [string]$ExecutablePath,
                [string[]]$CommandArguments,
                [string]$InputPath,
                [string]$OutputPath,
                [string]$ErrorPath,
                [string]$ResultPath
            )

            $inputContent = Get-Content -LiteralPath $InputPath -Raw
            $inputContent | & $ExecutablePath @CommandArguments 1> $OutputPath 2> $ErrorPath
            Set-Content -LiteralPath $ResultPath -Value $LASTEXITCODE -Encoding ascii
        } -ArgumentList @(
            $executablePath,
            $arguments,
            $promptPath,
            $stdoutPath,
            $stderrPath,
            $exitCodePath
        )

        $startedAt = Get-Date
        $lastOutputLength = 0L

        while ($job.State -in @('NotStarted', 'Running')) {
            Start-Sleep -Seconds $HeartbeatSeconds
            $job = Get-Job -Id $job.Id
            $elapsed = (Get-Date) - $startedAt
            $minutes = [Math]::Floor($elapsed.TotalMinutes)
            $seconds = $elapsed.Seconds
            $changedFiles = Get-RepoFlowChangedFileCount
            $stdoutLength = if (Test-Path -LiteralPath $stdoutPath) { (Get-Item -LiteralPath $stdoutPath).Length } else { 0L }
            $stderrLength = if (Test-Path -LiteralPath $stderrPath) { (Get-Item -LiteralPath $stderrPath).Length } else { 0L }
            $outputLength = $stdoutLength + $stderrLength

            $activity = if ($changedFiles -gt 0) {
                'editing files'
            }
            elseif ($outputLength -gt $lastOutputLength) {
                'working'
            }
            else {
                'analysing repository'
            }

            Write-Host ("[AGENT] {0}m {1}s | {2} | {3} changed file(s)" -f $minutes, $seconds, $activity, $changedFiles)
            $lastOutputLength = $outputLength
        }

        Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null

        $stdout = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        $exitCode = 1

        if (Test-Path -LiteralPath $exitCodePath) {
            $exitCodeText = Get-Content -LiteralPath $exitCodePath -Raw -ErrorAction SilentlyContinue
            $parsedExitCode = 0

            if ([int]::TryParse($exitCodeText.Trim(), [ref]$parsedExitCode)) {
                $exitCode = $parsedExitCode
            }
        }

        if ($job.State -eq 'Failed') {
            $exitCode = 1
            $jobError = @(
                $job.ChildJobs |
                ForEach-Object { $_.JobStateInfo.Reason } |
                Where-Object { $null -ne $_ }
            ) -join [Environment]::NewLine

            if (-not [string]::IsNullOrWhiteSpace($jobError)) {
                $stderr = @($stderr, $jobError) -join [Environment]::NewLine
            }
        }

        $usage = Get-RepoFlowCodexUsage -JsonLines $stdout
        $duration = (Get-Date) - $startedAt

        if (
            $usage.InputTokens -gt 0 -or
            $usage.CachedInputTokens -gt 0 -or
            $usage.OutputTokens -gt 0 -or
            $usage.ReasoningOutputTokens -gt 0
        ) {
            Write-Host (
                '[AGENT] Usage: input={0:N0}, cached={1:N0}, output={2:N0}, reasoning={3:N0}' -f
                $usage.InputTokens,
                $usage.CachedInputTokens,
                $usage.OutputTokens,
                $usage.ReasoningOutputTokens
            )
        }

        Write-Host (
            '[AGENT] Duration: {0}m {1}s' -f
            [Math]::Floor($duration.TotalMinutes),
            $duration.Seconds
        )

        $combined = @($stdout, $stderr) |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Text = ($combined -join [Environment]::NewLine)
            Usage = $usage
            DurationSeconds = [int][Math]::Round($duration.TotalSeconds)
        }
    }
    finally {
        if ($null -ne $job) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        Remove-Item -LiteralPath $promptPath, $stdoutPath, $stderrPath, $exitCodePath -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-RepoFlowAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$FinalMessagePath,

        [Parameter(Mandatory)]
        $Config,

        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh')]
        [string]$ReasoningEffort
    )

    $effectiveReasoningEffort = if ([string]::IsNullOrWhiteSpace($ReasoningEffort)) {
        [string]$Config.agent.reasoningEffort
    }
    else {
        $ReasoningEffort
    }

    switch ($Config.agent.provider) {
        'codex' {
            return Invoke-RepoFlowCodexWithHeartbeat `
                -RepositoryRoot $RepositoryRoot `
                -Prompt $Prompt `
                -FinalMessagePath $FinalMessagePath `
                -Command ([string]$Config.agent.command) `
                -ReasoningEffort $effectiveReasoningEffort `
                -HeartbeatSeconds ([int]$Config.agent.heartbeatSeconds)
        }
        default {
            throw "Unsupported agent provider: $($Config.agent.provider)"
        }
    }
}
