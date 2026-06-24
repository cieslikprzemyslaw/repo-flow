function Get-RepoFlowTelemetryHash {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [Convert]::ToHexString($hash).ToLowerInvariant()
}

function ConvertTo-RepoFlowTelemetrySingleLine {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [ValidateRange(5, 1000)]
        [int]$MaximumLength = 100
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    $singleLine = ($Text -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()

    if ($singleLine.Length -le $MaximumLength) {
        return $singleLine
    }

    return $singleLine.Substring(0, $MaximumLength - 3) + '...'
}

function ConvertTo-RepoFlowTelemetryDuration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [timespan]$Duration
    )

    if ($Duration.TotalHours -ge 1) {
        return '{0}h {1}m' -f [Math]::Floor($Duration.TotalHours), $Duration.Minutes
    }

    if ($Duration.TotalMinutes -ge 1) {
        return '{0}m {1}s' -f [Math]::Floor($Duration.TotalMinutes), $Duration.Seconds
    }

    return '{0}s' -f [Math]::Max(0, [Math]::Floor($Duration.TotalSeconds))
}

function Get-RepoFlowTelemetryFilePaths {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$PorcelainStatus
    )

    $paths = [System.Collections.Generic.List[string]]::new()

    foreach ($line in @($PorcelainStatus -split '\r?\n')) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) {
            continue
        }

        $path = $line.Substring(3).Trim()

        if ($path.Contains(' -> ', [System.StringComparison]::Ordinal)) {
            $path = ($path -split ' -> ', 2)[1].Trim()
        }

        if (
            $path.Length -ge 2 -and
            $path.StartsWith('"', [System.StringComparison]::Ordinal) -and
            $path.EndsWith('"', [System.StringComparison]::Ordinal)
        ) {
            $path = $path.Substring(1, $path.Length - 2)
        }

        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $paths.Add($path)
        }
    }

    return $paths.ToArray()
}

function Get-RepoFlowWorkingTreeTelemetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $statusResult = Invoke-RepoFlowCommand -Command 'git' -Arguments @(
        '-C',
        $RepositoryRoot,
        'status',
        '--porcelain=v1',
        '--untracked-files=all'
    ) -AllowFailure

    if ($statusResult.ExitCode -ne 0) {
        return [pscustomobject]@{
            Available = $false
            ChangedFileCount = 0
            Fingerprint = ''
            LastWriteTimeUtc = $null
        }
    }

    $status = [string]$statusResult.Text
    $paths = @(Get-RepoFlowTelemetryFilePaths -PorcelainStatus $status)
    $metadata = [System.Collections.Generic.List[string]]::new()
    $latestWrite = $null

    foreach ($relativePath in $paths) {
        $fullPath = Join-Path $RepositoryRoot $relativePath

        try {
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                $metadata.Add("$relativePath|missing")
                continue
            }

            $item = Get-Item -LiteralPath $fullPath -ErrorAction Stop
            $writeTime = [datetime]$item.LastWriteTimeUtc
            $length = [long]$item.Length
            $metadataEntry = '{0}|{1}|{2}' -f
                $relativePath,
                $length,
                $writeTime.Ticks
            $metadata.Add($metadataEntry)

            if ($null -eq $latestWrite -or $writeTime -gt $latestWrite) {
                $latestWrite = $writeTime
            }
        }
        catch {
            $metadata.Add("$relativePath|unreadable")
        }
    }

    $fingerprintSource = @($status, ($metadata -join "`n")) -join "`n"

    return [pscustomobject]@{
        Available = $true
        ChangedFileCount = $paths.Count
        Fingerprint = Get-RepoFlowTelemetryHash -Text $fingerprintSource
        LastWriteTimeUtc = $latestWrite
    }
}

function Get-RepoFlowAgentProcessTelemetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [datetime]$StartedAt,

        [double]$PreviousCpuSeconds = 0,

        [AllowNull()]
        [Nullable[int]]$PreviousProcessId
    )

    $expectedName = [System.IO.Path]::GetFileNameWithoutExtension($ExecutablePath)
    $candidates = @(
        Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            try {
                $_.ProcessName -eq $expectedName -and
                $_.StartTime -ge $StartedAt.AddSeconds(-2)
            }
            catch {
                $false
            }
        } |
        Sort-Object -Property StartTime -Descending
    )
    $process = $candidates | Select-Object -First 1

    if ($null -eq $process) {
        return [pscustomobject]@{
            Detected = $false
            Id = $null
            Name = ''
            CpuSeconds = $PreviousCpuSeconds
            CpuDeltaSeconds = 0.0
        }
    }

    $cpuSeconds = try {
        [double]$process.CPU
    }
    catch {
        $PreviousCpuSeconds
    }

    $cpuBaseline = if (
        $null -ne $PreviousProcessId -and
        [int]$PreviousProcessId -ne [int]$process.Id
    ) {
        0.0
    }
    else {
        $PreviousCpuSeconds
    }

    return [pscustomobject]@{
        Detected = $true
        Id = [int]$process.Id
        Name = [string]$process.ProcessName
        CpuSeconds = $cpuSeconds
        CpuDeltaSeconds = [Math]::Max(0.0, $cpuSeconds - $cpuBaseline)
    }
}

function Get-RepoFlowTelemetryFileTail {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateRange(1024, 1048576)]
        [int]$MaximumBytes = 131072
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }

    $stream = $null

    try {
        $stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $byteCount = [int][Math]::Min([long]$MaximumBytes, $stream.Length)

        if ($byteCount -le 0) {
            return ''
        }

        $startOffset = $stream.Length - $byteCount
        $stream.Seek($startOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buffer = [byte[]]::new($byteCount)
        $readCount = $stream.Read($buffer, 0, $byteCount)
        $text = [System.Text.Encoding]::UTF8.GetString($buffer, 0, $readCount)

        if ($startOffset -gt 0) {
            $firstNewLine = $text.IndexOf("`n", [System.StringComparison]::Ordinal)

            if ($firstNewLine -ge 0) {
                $text = $text.Substring($firstNewLine + 1)
            }
            else {
                return ''
            }
        }

        return $text
    }
    catch {
        return ''
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-RepoFlowObservableValidationCommand {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$JsonLines
    )

    if ([string]::IsNullOrWhiteSpace($JsonLines)) {
        return ''
    }

    $lines = @(
        $JsonLines -split '\r?\n' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        try {
            $event = $lines[$index] | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            continue
        }

        $item = Get-RepoFlowProperty -Object $event -Name 'item' -Default $null
        $itemType = [string](Get-RepoFlowProperty -Object $item -Name 'type' -Default '')
        $eventType = [string](Get-RepoFlowProperty -Object $event -Name 'type' -Default '')

        if ($itemType -eq 'command_execution') {
            if ($eventType -eq 'item.completed') {
                return ''
            }

            if ($eventType -eq 'item.started') {
                $command = [string](Get-RepoFlowProperty `
                    -Object $item `
                    -Name 'command' `
                    -Default '')

                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    return ConvertTo-RepoFlowTelemetrySingleLine `
                        -Text $command `
                        -MaximumLength 100
                }
            }
        }

        $message = Get-RepoFlowProperty -Object $event -Name 'message' -Default $null
        $content = Get-RepoFlowProperty -Object $message -Name 'content' -Default $null

        foreach ($part in @($content)) {
            $partType = [string](Get-RepoFlowProperty -Object $part -Name 'type' -Default '')

            if ($partType -eq 'tool_result') {
                return ''
            }

            $toolName = [string](Get-RepoFlowProperty -Object $part -Name 'name' -Default '')
            $input = Get-RepoFlowProperty -Object $part -Name 'input' -Default $null

            if ($partType -eq 'tool_use' -and $toolName -eq 'Bash') {
                $command = [string](Get-RepoFlowProperty -Object $input -Name 'command' -Default '')

                if (-not [string]::IsNullOrWhiteSpace($command)) {
                    return ConvertTo-RepoFlowTelemetrySingleLine -Text $command -MaximumLength 100
                }
            }
        }
    }

    return ''
}

