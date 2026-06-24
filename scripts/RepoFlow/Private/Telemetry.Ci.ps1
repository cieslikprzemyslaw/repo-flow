function New-RepoFlowCiTelemetryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [datetime]$StartedAt,

        [ValidateRange(30, 7200)]
        [int]$NoActivityWarningSeconds = 180
    )

    return [pscustomobject]@{
        StartedAt = $StartedAt
        LastObservableActivityAt = $StartedAt
        LastFingerprint = ''
        LastBuckets = @{}
        NoActivityWarningSeconds = $NoActivityWarningSeconds
        StallWarningShown = $false
    }
}

function Get-RepoFlowCiCheckFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State
    )

    $parts = @(
        foreach ($check in @($State.Checks | Sort-Object -Property name)) {
            '{0}={1}' -f [string]$check.name, [string]$check.bucket
        }
    )

    return Get-RepoFlowTelemetryHash -Text (
        '{0}|{1}' -f [string]$State.Status, ($parts -join ';')
    )
}

function Get-RepoFlowCiBucketMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $State
    )

    $map = @{}

    foreach ($check in @($State.Checks)) {
        $map[[string]$check.name] = [string]$check.bucket
    }

    return $map
}

function Get-RepoFlowCiProgressTelemetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $TelemetryState,

        [Parameter(Mandatory)]
        $CiState,

        [Parameter(Mandatory)]
        [datetime]$Now,

        [Parameter(Mandatory)]
        [int]$PollSeconds
    )

    $fingerprint = Get-RepoFlowCiCheckFingerprint -State $CiState
    $currentBuckets = Get-RepoFlowCiBucketMap -State $CiState
    $transitions = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @($currentBuckets.Keys | Sort-Object)) {
        $previous = if ($TelemetryState.LastBuckets.ContainsKey($name)) {
            [string]$TelemetryState.LastBuckets[$name]
        }
        else {
            '<new>'
        }
        $current = [string]$currentBuckets[$name]

        if ($previous -ne $current) {
            $transitions.Add("${name}: $previous -> $current")
        }
    }

    foreach ($name in @($TelemetryState.LastBuckets.Keys | Sort-Object)) {
        if (-not $currentBuckets.ContainsKey($name)) {
            $transitions.Add("${name}: $($TelemetryState.LastBuckets[$name]) -> <missing>")
        }
    }

    $changed = (
        [string]$TelemetryState.LastFingerprint -ne $fingerprint
    )

    if ($changed) {
        $TelemetryState.LastObservableActivityAt = $Now
        $TelemetryState.StallWarningShown = $false
    }

    $noActivity = $Now - $TelemetryState.LastObservableActivityAt
    $status = if ($changed) {
        'active'
    }
    elseif ($noActivity.TotalSeconds -ge $TelemetryState.NoActivityWarningSeconds) {
        'possibly stalled'
    }
    elseif ($noActivity.TotalSeconds -ge (2 * $PollSeconds)) {
        'no observable change'
    }
    else {
        'waiting'
    }

    $shouldWarn = (
        $status -eq 'possibly stalled' -and
        -not $TelemetryState.StallWarningShown
    )

    if ($shouldWarn) {
        $TelemetryState.StallWarningShown = $true
    }

    $TelemetryState.LastFingerprint = $fingerprint
    $TelemetryState.LastBuckets = $currentBuckets

    return [pscustomobject]@{
        Status = $status
        ObservableActivity = $changed
        NoActivity = $noActivity
        Elapsed = $Now - $TelemetryState.StartedAt
        Transitions = $transitions.ToArray()
        ShouldWarn = $shouldWarn
    }
}

function Format-RepoFlowCiProgress {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        $Progress,

        [Parameter(Mandatory)]
        $CiState
    )

    $checkCount = @($CiState.Checks).Count

    return @(
        "[CI] phase=$Phase",
        [string]$Progress.Status,
        (ConvertTo-RepoFlowTelemetryDuration -Duration $Progress.Elapsed),
        "checks=$checkCount",
        "result=$($CiState.Status)",
        (
            'last-activity={0}' -f
            (ConvertTo-RepoFlowTelemetryDuration -Duration $Progress.NoActivity)
        )
    ) -join ' | '
}
