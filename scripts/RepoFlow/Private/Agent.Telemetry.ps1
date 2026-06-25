function Invoke-RepoFlowAgentProcessWithHeartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$WorkingDirectory,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$FinalMessagePath,

        [ValidateRange(5, 300)]
        [int]$HeartbeatSeconds = 15,

        [ValidateRange(30, 7200)]
        [int]$NoActivityWarningSeconds = 180,

        [ValidateRange(0, 7200)]
        [int]$TimeoutSeconds = 0,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Phase = 'agent-running',

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StateConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunId
    )

    $promptPath = [System.IO.Path]::GetTempFileName()
    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()
    $exitCodePath = [System.IO.Path]::GetTempFileName()
    $job = $null
    $timedOut = $false

    try {
        Set-Content -LiteralPath $promptPath -Value $Prompt -Encoding utf8

        $job = Start-Job -ScriptBlock {
            param(
                [string]$WorkingDirectory,
                [string]$ExecutablePath,
                [string[]]$CommandArguments,
                [string]$InputPath,
                [string]$OutputPath,
                [string]$ErrorPath,
                [string]$ResultPath
            )

            Set-Location -LiteralPath $WorkingDirectory
            $inputContent = Get-Content -LiteralPath $InputPath -Raw
            $inputContent | & $ExecutablePath @CommandArguments 1> $OutputPath 2> $ErrorPath
            Set-Content -LiteralPath $ResultPath -Value $LASTEXITCODE -Encoding ascii
        } -ArgumentList @(
            $WorkingDirectory,
            $ExecutablePath,
            $Arguments,
            $promptPath,
            $stdoutPath,
            $stderrPath,
            $exitCodePath
        )

        $startedAt = Get-Date
        $initialWorkingTree = Get-RepoFlowWorkingTreeTelemetry `
            -RepositoryRoot $WorkingDirectory
        $telemetryState = New-RepoFlowAgentTelemetryState `
            -StartedAt $startedAt `
            -NoActivityWarningSeconds $NoActivityWarningSeconds `
            -HeartbeatSeconds $HeartbeatSeconds `
            -InitialWorkingTree $initialWorkingTree

        while ($job.State -in @('NotStarted', 'Running')) {
            Start-Sleep -Seconds $HeartbeatSeconds
            $job = Get-Job -Id $job.Id

            $stdoutLength = if (Test-Path -LiteralPath $stdoutPath) {
                (Get-Item -LiteralPath $stdoutPath).Length
            }
            else {
                0L
            }
            $stderrLength = if (Test-Path -LiteralPath $stderrPath) {
                (Get-Item -LiteralPath $stderrPath).Length
            }
            else {
                0L
            }
            $stdoutSnapshot = Get-RepoFlowTelemetryFileTail `
                -Path $stdoutPath
            $workingTree = Get-RepoFlowWorkingTreeTelemetry `
                -RepositoryRoot $WorkingDirectory
            $processTelemetry = Get-RepoFlowAgentProcessTelemetry `
                -ExecutablePath $ExecutablePath `
                -StartedAt $startedAt `
                -PreviousCpuSeconds ([double]$telemetryState.LastCpuSeconds) `
                -PreviousProcessId $telemetryState.LastProcessId
            $observableCommand = Get-RepoFlowObservableValidationCommand `
                -JsonLines $stdoutSnapshot
            $now = Get-Date
            $heartbeat = Get-RepoFlowAgentHeartbeatTelemetry `
                -State $telemetryState `
                -Now $now `
                -OutputLength ([long]($stdoutLength + $stderrLength)) `
                -WorkingTree $workingTree `
                -Process $processTelemetry `
                -ObservableCommand $observableCommand

            Write-Host (Format-RepoFlowAgentHeartbeat `
                -Provider $Provider `
                -Phase $Phase `
                -Heartbeat $heartbeat `
                -WorkingTree $workingTree `
                -Process $processTelemetry `
                -ObservableCommand $observableCommand)

            Set-RepoFlowRunHeartbeat `
                -ConfigPath $StateConfigPath `
                -RunId $RunId `
                -CurrentPhase $Phase `
                -ObservableActivity:$heartbeat.ObservableActivity

            if ($heartbeat.ShouldWarn) {
                $idleText = ConvertTo-RepoFlowTelemetryDuration `
                    -Duration $heartbeat.NoActivity
                Write-Warning (
                    "[AGENT] No observable activity for $idleText. " +
                    'The process has not been terminated.'
                )
            }

            if (
                $TimeoutSeconds -gt 0 -and
                ((Get-Date) - $startedAt).TotalSeconds -ge $TimeoutSeconds
            ) {
                $timedOut = $true
                Stop-Job -Job $job -ErrorAction SilentlyContinue
                break
            }
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

        $duration = (Get-Date) - $startedAt

        return [pscustomobject]@{
            ExitCode = $exitCode
            StandardOutput = $stdout
            StandardError = $stderr
            DurationSeconds = [int][Math]::Round($duration.TotalSeconds)
            TimedOut = $timedOut
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

