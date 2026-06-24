function New-RepoFlowAgentTelemetryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$StartedAt,

        [Parameter(Mandatory)]
        [int]$NoActivityWarningSeconds,

        [ValidateRange(5, 300)]
        [int]$HeartbeatSeconds = 15,

        [AllowNull()]
        $InitialWorkingTree
    )

    return [pscustomobject]@{
        StartedAt = $StartedAt
        LastHeartbeatAt = $StartedAt
        LastObservableActivityAt = $StartedAt
        LastOutputLength = 0L
        LastFingerprint = if ($null -eq $InitialWorkingTree) { '' } else { [string]$InitialWorkingTree.Fingerprint }
        LastWriteTimeUtc = if ($null -eq $InitialWorkingTree) { $null } else { $InitialWorkingTree.LastWriteTimeUtc }
        LastCommand = ''
        LastCpuSeconds = 0.0
        LastProcessId = $null
        NoActivityWarningSeconds = $NoActivityWarningSeconds
        HeartbeatSeconds = $HeartbeatSeconds
        StallWarningShown = $false
    }
}

function Get-RepoFlowAgentHeartbeatTelemetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State,

        [Parameter(Mandatory)]
        [datetime]$Now,

        [Parameter(Mandatory)]
        [long]$OutputLength,

        [Parameter(Mandatory)]
        $WorkingTree,

        [Parameter(Mandatory)]
        $Process,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ObservableCommand
    )

    $outputChanged = $OutputLength -gt [long]$State.LastOutputLength
    $fingerprintChanged = (
        $WorkingTree.Available -and
        [string]$WorkingTree.Fingerprint -ne [string]$State.LastFingerprint
    )
    $writeChanged = (
        $null -ne $WorkingTree.LastWriteTimeUtc -and
        (
            $null -eq $State.LastWriteTimeUtc -or
            $WorkingTree.LastWriteTimeUtc -gt $State.LastWriteTimeUtc
        )
    )
    $commandChanged = (
        -not [string]::IsNullOrWhiteSpace($ObservableCommand) -and
        $ObservableCommand -ne [string]$State.LastCommand
    )
    $cpuChanged = [double]$Process.CpuDeltaSeconds -ge 0.01
    $observableActivity = (
        $outputChanged -or
        $fingerprintChanged -or
        $writeChanged -or
        $commandChanged -or
        $cpuChanged
    )

    if ($observableActivity) {
        $State.LastObservableActivityAt = $Now
        $State.StallWarningShown = $false
    }

    $noActivity = $Now - $State.LastObservableActivityAt
    $status = if ($observableActivity) {
        'active'
    }
    elseif ($noActivity.TotalSeconds -ge $State.NoActivityWarningSeconds) {
        'possibly stalled'
    }
    elseif ($noActivity.TotalSeconds -ge (2 * $State.HeartbeatSeconds)) {
        'no observable change'
    }
    else {
        'waiting'
    }

    $result = [pscustomobject]@{
        Status = $status
        ObservableActivity = $observableActivity
        OutputChanged = $outputChanged
        FingerprintChanged = $fingerprintChanged
        WriteChanged = $writeChanged
        CommandChanged = $commandChanged
        CpuChanged = $cpuChanged
        Elapsed = $Now - $State.StartedAt
        NoActivity = $noActivity
        ShouldWarn = $status -eq 'possibly stalled' -and -not $State.StallWarningShown
    }

    $State.LastHeartbeatAt = $Now
    $State.LastOutputLength = $OutputLength
    $State.LastFingerprint = [string]$WorkingTree.Fingerprint
    $State.LastWriteTimeUtc = $WorkingTree.LastWriteTimeUtc
    $State.LastCommand = [string]$ObservableCommand
    $State.LastCpuSeconds = [double]$Process.CpuSeconds
    if ($Process.Detected) {
        $State.LastProcessId = [int]$Process.Id
    }

    if ($result.ShouldWarn) {
        $State.StallWarningShown = $true
    }

    return $result
}

function Format-RepoFlowAgentHeartbeat {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        $Heartbeat,

        [Parameter(Mandatory)]
        $WorkingTree,

        [Parameter(Mandatory)]
        $Process,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ObservableCommand
    )

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("[AGENT] provider=$Provider phase=$Phase")
    $parts.Add([string]$Heartbeat.Status)
    $parts.Add((ConvertTo-RepoFlowTelemetryDuration -Duration $Heartbeat.Elapsed))

    $availabilityProperty = $WorkingTree.PSObject.Properties['Available']
    $workingTreeAvailable = if ($null -eq $availabilityProperty) {
        $null -ne $WorkingTree.PSObject.Properties['ChangedFileCount']
    }
    else {
        [bool]$availabilityProperty.Value
    }

    if ($workingTreeAvailable) {
        $parts.Add("files=$($WorkingTree.ChangedFileCount)")
    }
    else {
        $parts.Add('files=<unavailable>')
    }

    if ($Heartbeat.FingerprintChanged) {
        $parts.Add('diff=changed')
    }

    if ($null -ne $WorkingTree.LastWriteTimeUtc) {
        $parts.Add(
            'last-write={0}' -f
            $WorkingTree.LastWriteTimeUtc.ToString('HH:mm:ssZ')
        )
    }

    if ($Process.Detected) {
        $parts.Add(
            'process={0}#{1} cpu+{2:N2}s' -f
            $Process.Name,
            $Process.Id,
            $Process.CpuDeltaSeconds
        )
    }

    if (-not [string]::IsNullOrWhiteSpace($ObservableCommand)) {
        $parts.Add("command=$ObservableCommand")
    }

    $parts.Add(
        'last-activity={0}' -f
        (ConvertTo-RepoFlowTelemetryDuration -Duration $Heartbeat.NoActivity)
    )

    return $parts -join ' | '
}
