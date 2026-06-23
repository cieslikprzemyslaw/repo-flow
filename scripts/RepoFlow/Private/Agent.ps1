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

function New-RepoFlowAgentUsage {
    [CmdletBinding()]
    param()

    return [pscustomobject][ordered]@{
        InputTokens = 0L
        CachedInputTokens = 0L
        OutputTokens = 0L
        ReasoningOutputTokens = 0L
    }
}

function ConvertTo-RepoFlowSemanticVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Version,

        [Parameter(Mandatory)]
        [string]$Path
    )

    try {
        return [System.Management.Automation.SemanticVersion]::Parse($Version)
    }
    catch {
        throw "Configuration value '$Path' must be a semantic version string such as 1.2.3."
    }
}

function Get-RepoFlowSemanticVersionFromText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $match = [regex]::Match(
        $Text,
        '(?<![0-9])(?<version>[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)(?![0-9A-Za-z.-])'
    )

    if (-not $match.Success) {
        return $null
    }

    return $match.Groups['version'].Value
}

function Test-RepoFlowSemanticVersionAtLeast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$InstalledVersion,

        [Parameter(Mandatory)]
        [string]$MinimumVersion
    )

    $installed = ConvertTo-RepoFlowSemanticVersion `
        -Version $InstalledVersion `
        -Path 'installed CLI version'
    $minimum = ConvertTo-RepoFlowSemanticVersion `
        -Version $MinimumVersion `
        -Path '$.agent.minimumCliVersion'

    return $installed -ge $minimum
}

function Get-RepoFlowAgentCliVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Command
    )

    $executablePath = Resolve-RepoFlowExecutable -Command $Command
    $output = & $executablePath --version 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output -join [Environment]::NewLine)

    if ($exitCode -ne 0) {
        throw "Could not determine $Provider CLI version from '$Command --version':$([Environment]::NewLine)$text"
    }

    $version = Get-RepoFlowSemanticVersionFromText -Text $text

    if ([string]::IsNullOrWhiteSpace($version)) {
        throw "Could not extract $Provider CLI semantic version from '$Command --version' output:$([Environment]::NewLine)$text"
    }

    return [pscustomobject]@{
        ExecutablePath = $executablePath
        Version = $version
        Text = $text
    }
}

function Assert-RepoFlowAgentCliVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$InstalledVersion,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$MinimumVersion
    )

    if ([string]::IsNullOrWhiteSpace($MinimumVersion)) {
        return
    }

    if (-not (Test-RepoFlowSemanticVersionAtLeast -InstalledVersion $InstalledVersion -MinimumVersion $MinimumVersion)) {
        throw (
            "Configured $Provider CLI is too old. Installed version: $InstalledVersion. " +
            "Required minimum version: $MinimumVersion."
        )
    }
}

function Get-RepoFlowCodexUsage {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$JsonLines
    )

    $totals = New-RepoFlowAgentUsage

    if ([string]::IsNullOrWhiteSpace($JsonLines)) {
        return $totals
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

    return $totals
}

function New-RepoFlowCodexArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$FinalMessagePath,

        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh')]
        [string]$ReasoningEffort
    )

    return @(
        '-a',
        'never',
        '-s',
        'workspace-write',
        '-C',
        $RepositoryRoot,
        '-c',
        ('model_reasoning_effort="{0}"' -f $ReasoningEffort),
        '--model',
        $Model,
        'exec',
        '--json',
        '-o',
        $FinalMessagePath,
        '-'
    )
}

function ConvertTo-RepoFlowClaudeEffort {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh')]
        [string]$ReasoningEffort
    )

    if ($ReasoningEffort -eq 'minimal') {
        return 'low'
    }

    return $ReasoningEffort
}

function New-RepoFlowClaudeArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh')]
        [string]$ReasoningEffort
    )

    return @(
        '-p',
        '--output-format',
        'stream-json',
        '--verbose',
        '--permission-mode',
        'acceptEdits',
        '--model',
        $Model,
        '--effort',
        (ConvertTo-RepoFlowClaudeEffort -ReasoningEffort $ReasoningEffort),
        '--no-session-persistence'
    )
}

function Get-RepoFlowClaudeTextFromEvent {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Event
    )

    if ($null -eq $Event) {
        return ''
    }

    $type = [string](Get-RepoFlowProperty -Object $Event -Name 'type' -Default '')

    if ($type -eq 'result') {
        foreach ($name in @('result', 'response', 'text', 'content')) {
            $value = Get-RepoFlowProperty -Object $Event -Name $name -Default $null

            if ($value -is [string] -and -not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    $message = Get-RepoFlowProperty -Object $Event -Name 'message' -Default $null
    if ($null -eq $message) {
        return ''
    }

    $content = Get-RepoFlowProperty -Object $message -Name 'content' -Default $null
    $parts = New-Object System.Collections.Generic.List[string]

    if ($content -is [string]) {
        $parts.Add($content)
    }
    elseif ($null -ne $content) {
        foreach ($part in @($content)) {
            if ($part -is [string]) {
                if (-not [string]::IsNullOrWhiteSpace($part)) {
                    $parts.Add($part)
                }
                continue
            }

            $partType = [string](Get-RepoFlowProperty -Object $part -Name 'type' -Default '')
            $partText = Get-RepoFlowProperty -Object $part -Name 'text' -Default $null

            if ($partType -eq 'text' -and $partText -is [string] -and -not [string]::IsNullOrWhiteSpace($partText)) {
                $parts.Add($partText)
            }
        }
    }

    return ($parts -join [Environment]::NewLine).Trim()
}

function Get-RepoFlowClaudeUsageFromEvent {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Event
    )

    if ($null -eq $Event) {
        return $null
    }

    $usage = Get-RepoFlowProperty -Object $Event -Name 'usage' -Default $null
    if ($null -eq $usage) {
        $message = Get-RepoFlowProperty -Object $Event -Name 'message' -Default $null
        if ($null -ne $message) {
            $usage = Get-RepoFlowProperty -Object $message -Name 'usage' -Default $null
        }
    }

    return $usage
}

function Add-RepoFlowClaudeUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Totals,

        [AllowNull()]
        $Usage
    )

    if ($null -eq $Usage) {
        return
    }

    $Totals.InputTokens += [long](Get-RepoFlowProperty -Object $Usage -Name 'input_tokens' -Default 0)
    $Totals.CachedInputTokens += [long](Get-RepoFlowProperty -Object $Usage -Name 'cache_read_input_tokens' -Default 0)
    $Totals.CachedInputTokens += [long](Get-RepoFlowProperty -Object $Usage -Name 'cached_input_tokens' -Default 0)
    $Totals.OutputTokens += [long](Get-RepoFlowProperty -Object $Usage -Name 'output_tokens' -Default 0)
    $Totals.ReasoningOutputTokens += [long](Get-RepoFlowProperty -Object $Usage -Name 'reasoning_output_tokens' -Default 0)
}

function Get-RepoFlowClaudeResult {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$JsonLines
    )

    $usage = New-RepoFlowAgentUsage
    $finalMessage = ''
    $isError = $false
    $errorCode = ''
    $errorMessage = ''

    if ([string]::IsNullOrWhiteSpace($JsonLines)) {
        return [pscustomobject]@{
            FinalMessage = ''
            Usage = $usage
            IsError = $false
            ErrorCode = ''
            ErrorMessage = ''
        }
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

        Add-RepoFlowClaudeUsage `
            -Totals $usage `
            -Usage (Get-RepoFlowClaudeUsageFromEvent -Event $event)

        $text = Get-RepoFlowClaudeTextFromEvent -Event $event

        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $finalMessage = $text
        }

        $eventIsError = Get-RepoFlowProperty `
            -Object $event `
            -Name 'is_error' `
            -Default $false
        $eventError = [string](Get-RepoFlowProperty `
            -Object $event `
            -Name 'error' `
            -Default '')
        $eventMessage = Get-RepoFlowProperty `
            -Object $event `
            -Name 'message' `
            -Default $null
        $messageError = [string](Get-RepoFlowProperty `
            -Object $eventMessage `
            -Name 'error' `
            -Default '')

        if ([string]::IsNullOrWhiteSpace($eventError)) {
            $eventError = $messageError
        }

        if ($eventIsError -eq $true -or -not [string]::IsNullOrWhiteSpace($eventError)) {
            $isError = $true

            if (-not [string]::IsNullOrWhiteSpace($eventError)) {
                $errorCode = $eventError
            }

            $apiStatus = Get-RepoFlowProperty `
                -Object $event `
                -Name 'api_error_status' `
                -Default $null

            if ([string]::IsNullOrWhiteSpace($errorCode) -and $null -ne $apiStatus) {
                $errorCode = "http_$apiStatus"
            }

            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $errorMessage = $text
            }
        }
    }

    if ($isError -and [string]::IsNullOrWhiteSpace($errorMessage)) {
        $errorMessage = 'Claude reported an unsuccessful result.'
    }

    return [pscustomobject]@{
        FinalMessage = $finalMessage.Trim()
        Usage = $usage
        IsError = $isError
        ErrorCode = $errorCode
        ErrorMessage = $errorMessage.Trim()
    }
}

function Get-RepoFlowAgentFailureText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Model,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StandardOutput,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StandardError,

        [AllowNull()]
        $ParsedResult
    )

    $providerName = if ($Provider -eq 'claude') { 'Claude' } else { 'Codex' }

    if ($null -ne $ParsedResult -and $ParsedResult.IsError -eq $true) {
        $code = if ([string]::IsNullOrWhiteSpace([string]$ParsedResult.ErrorCode)) {
            'agent_error'
        }
        else {
            [string]$ParsedResult.ErrorCode
        }
        $message = if ([string]::IsNullOrWhiteSpace([string]$ParsedResult.ErrorMessage)) {
            'The agent reported an unsuccessful result.'
        }
        else {
            [string]$ParsedResult.ErrorMessage
        }

        return "$providerName agent failed for model '$Model' [$code]: $message"
    }

    $diagnostic = @($StandardError, $StandardOutput) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $diagnosticText = Get-RepoFlowBoundedText `
        -Text ($diagnostic -join [Environment]::NewLine) `
        -MaximumCharacters 12000 `
        -HeadCharacters 2000

    if ([string]::IsNullOrWhiteSpace($diagnosticText)) {
        return "$providerName agent failed for model '$Model' without diagnostic output."
    }

    return "$providerName agent failed for model '$Model':$([Environment]::NewLine)$diagnosticText"
}

function Write-RepoFlowAgentUsage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Usage
    )

    if (
        $Usage.InputTokens -gt 0 -or
        $Usage.CachedInputTokens -gt 0 -or
        $Usage.OutputTokens -gt 0 -or
        $Usage.ReasoningOutputTokens -gt 0
    ) {
        Write-Host (
            '[AGENT] Usage: input={0:N0}, cached={1:N0}, output={2:N0}, reasoning={3:N0}' -f
            $Usage.InputTokens,
            $Usage.CachedInputTokens,
            $Usage.OutputTokens,
            $Usage.ReasoningOutputTokens
        )
    }
}

function Write-RepoFlowAgentStreamLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Text.StringBuilder]$Builder,

        [Parameter(Mandatory)]
        [string]$Line
    )

    if ($Builder.Length -gt 0) {
        [void]$Builder.Append([Environment]::NewLine)
    }

    [void]$Builder.Append($Line)
    Write-Host $Line
}

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
        [int]$HeartbeatSeconds = 15
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $ExecutablePath
    foreach ($argument in @($Arguments)) {
        [void]$processStartInfo.ArgumentList.Add($argument)
    }
    $processStartInfo.WorkingDirectory = $WorkingDirectory
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.CreateNoWindow = $true
    $processStartInfo.RedirectStandardInput = $true
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $processStartInfo.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $processStartInfo.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo
    $process.EnableRaisingEvents = $true
    $stdoutBuilder = [System.Text.StringBuilder]::new()
    $stderrBuilder = [System.Text.StringBuilder]::new()
    $startedAt = Get-Date
    $stdoutDone = $false
    $stderrDone = $false
    $exitCode = 1

    try {
        if (-not $process.Start()) {
            throw "Failed to start the $Provider agent process."
        }

        $process.StandardInput.Write($Prompt)
        $process.StandardInput.Close()

        $stdoutReader = $process.StandardOutput
        $stderrReader = $process.StandardError
        $stdoutTask = $stdoutReader.ReadLineAsync()
        $stderrTask = $stderrReader.ReadLineAsync()

        while ($true) {
            if ($stdoutDone -and $stderrDone) {
                if ($process.HasExited) {
                    break
                }

                [void]$process.WaitForExit(50)
                continue
            }

            $pendingTasks = New-Object 'System.Collections.Generic.List[System.Threading.Tasks.Task]'

            if (-not $stdoutDone) {
                [void]$pendingTasks.Add($stdoutTask)
            }

            if (-not $stderrDone) {
                [void]$pendingTasks.Add($stderrTask)
            }

            $completedIndex = [System.Threading.Tasks.Task]::WaitAny(
                [System.Threading.Tasks.Task[]]$pendingTasks.ToArray(),
                50
            )

            if ($completedIndex -lt 0) {
                continue
            }

            $finishedTask = $pendingTasks[$completedIndex]

            if ($finishedTask -eq $stdoutTask) {
                $stdoutLine = $stdoutTask.GetAwaiter().GetResult()

                if ($null -eq $stdoutLine) {
                    $stdoutDone = $true
                }
                else {
                    Write-RepoFlowAgentStreamLine `
                        -Builder $stdoutBuilder `
                        -Line $stdoutLine
                    $stdoutTask = $stdoutReader.ReadLineAsync()
                }
            }
            elseif ($finishedTask -eq $stderrTask) {
                $stderrLine = $stderrTask.GetAwaiter().GetResult()

                if ($null -eq $stderrLine) {
                    $stderrDone = $true
                }
                else {
                    Write-RepoFlowAgentStreamLine `
                        -Builder $stderrBuilder `
                        -Line $stderrLine
                    $stderrTask = $stderrReader.ReadLineAsync()
                }
            }
        }

        [void]$process.WaitForExit()
        $exitCode = $process.ExitCode
        $stdout = $stdoutBuilder.ToString()
        $stderr = $stderrBuilder.ToString()
        $duration = (Get-Date) - $startedAt

        return [pscustomobject]@{
            ExitCode = $exitCode
            StandardOutput = $stdout
            StandardError = $stderr
            DurationSeconds = [int][Math]::Round($duration.TotalSeconds)
        }
    }
    finally {
        if ($null -ne $process) {
            if (-not $process.HasExited) {
                try {
                    $null = $process.Kill($true)
                }
                catch {
                }

                try {
                    [void]$process.WaitForExit(5000)
                }
                catch {
                }
            }

            $process.Dispose()
        }
    }
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
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh')]
        [string]$ReasoningEffort,

        [ValidateRange(5, 300)]
        [int]$HeartbeatSeconds = 15
    )

    $arguments = New-RepoFlowCodexArguments `
        -RepositoryRoot $RepositoryRoot `
        -FinalMessagePath $FinalMessagePath `
        -Model $Model `
        -ReasoningEffort $ReasoningEffort

    $run = Invoke-RepoFlowAgentProcessWithHeartbeat `
        -Provider 'codex' `
        -ExecutablePath $ExecutablePath `
        -Arguments $arguments `
        -WorkingDirectory $RepositoryRoot `
        -Prompt $Prompt `
        -FinalMessagePath $FinalMessagePath `
        -HeartbeatSeconds $HeartbeatSeconds

    $usage = Get-RepoFlowCodexUsage -JsonLines $run.StandardOutput
    Write-RepoFlowAgentUsage -Usage $usage

    $duration = [timespan]::FromSeconds($run.DurationSeconds)
    Write-Host (
        '[AGENT] Duration: {0}m {1}s' -f
        [Math]::Floor($duration.TotalMinutes),
        $duration.Seconds
    )

    $combined = @($run.StandardOutput, $run.StandardError) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $text = if ($run.ExitCode -ne 0) {
        Get-RepoFlowAgentFailureText `
            -Provider 'codex' `
            -Model $Model `
            -StandardOutput $run.StandardOutput `
            -StandardError $run.StandardError
    }
    else {
        $combined -join [Environment]::NewLine
    }

    return [pscustomobject]@{
        ExitCode = $run.ExitCode
        Text = $text
        Usage = $usage
        DurationSeconds = $run.DurationSeconds
        ErrorCode = ''
    }
}

function Invoke-RepoFlowClaudeWithHeartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        [string]$FinalMessagePath,

        [Parameter(Mandatory)]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [string]$Model,

        [Parameter(Mandatory)]
        [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh')]
        [string]$ReasoningEffort,

        [ValidateRange(5, 300)]
        [int]$HeartbeatSeconds = 15
    )

    $arguments = New-RepoFlowClaudeArguments `
        -Model $Model `
        -ReasoningEffort $ReasoningEffort

    $run = Invoke-RepoFlowAgentProcessWithHeartbeat `
        -Provider 'claude' `
        -ExecutablePath $ExecutablePath `
        -Arguments $arguments `
        -WorkingDirectory $RepositoryRoot `
        -Prompt $Prompt `
        -FinalMessagePath $FinalMessagePath `
        -HeartbeatSeconds $HeartbeatSeconds

    $result = Get-RepoFlowClaudeResult -JsonLines $run.StandardOutput
    $effectiveExitCode = if ($run.ExitCode -ne 0 -or $result.IsError) { 1 } else { 0 }

    if (
        $effectiveExitCode -eq 0 -and
        -not [string]::IsNullOrWhiteSpace($result.FinalMessage)
    ) {
        Set-Content -LiteralPath $FinalMessagePath -Value $result.FinalMessage -Encoding utf8
    }

    Write-RepoFlowAgentUsage -Usage $result.Usage

    $duration = [timespan]::FromSeconds($run.DurationSeconds)
    Write-Host (
        '[AGENT] Duration: {0}m {1}s' -f
        [Math]::Floor($duration.TotalMinutes),
        $duration.Seconds
    )

    $combined = @($run.StandardOutput, $run.StandardError) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $text = if ($effectiveExitCode -ne 0) {
        Get-RepoFlowAgentFailureText `
            -Provider 'claude' `
            -Model $Model `
            -StandardOutput $run.StandardOutput `
            -StandardError $run.StandardError `
            -ParsedResult $result
    }
    else {
        $combined -join [Environment]::NewLine
    }

    return [pscustomobject]@{
        ExitCode = $effectiveExitCode
        Text = $text
        Usage = $result.Usage
        DurationSeconds = $run.DurationSeconds
        ErrorCode = [string]$result.ErrorCode
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

    $provider = [string]$Config.agent.provider
    $command = [string]$Config.agent.command
    $model = [string]$Config.agent.model

    if ($provider -notin @('codex', 'claude')) {
        throw "Unsupported agent provider: $provider"
    }

    $minimumCliVersion = Get-RepoFlowProperty `
        -Object $Config.agent `
        -Name 'minimumCliVersion' `
        -Default $null
    $versionInfo = Get-RepoFlowAgentCliVersion `
        -Provider $provider `
        -Command $command

    Assert-RepoFlowAgentCliVersion `
        -Provider $provider `
        -InstalledVersion $versionInfo.Version `
        -MinimumVersion $minimumCliVersion

    Write-Host "[AGENT] Provider: $provider"
    Write-Host "[AGENT] Model: $model"
    Write-Host "[AGENT] CLI version: $($versionInfo.Version)"
    Write-Host "[AGENT] Reasoning effort: $effectiveReasoningEffort"

    switch ($provider) {
        'codex' {
            return Invoke-RepoFlowCodexWithHeartbeat `
                -RepositoryRoot $RepositoryRoot `
                -Prompt $Prompt `
                -FinalMessagePath $FinalMessagePath `
                -ExecutablePath ([string]$versionInfo.ExecutablePath) `
                -Model $model `
                -ReasoningEffort $effectiveReasoningEffort `
                -HeartbeatSeconds ([int]$Config.agent.heartbeatSeconds)
        }
        'claude' {
            return Invoke-RepoFlowClaudeWithHeartbeat `
                -RepositoryRoot $RepositoryRoot `
                -Prompt $Prompt `
                -FinalMessagePath $FinalMessagePath `
                -ExecutablePath ([string]$versionInfo.ExecutablePath) `
                -Model $model `
                -ReasoningEffort $effectiveReasoningEffort `
                -HeartbeatSeconds ([int]$Config.agent.heartbeatSeconds)
        }
        default {
            throw "Unsupported agent provider: $provider"
        }
    }
}
