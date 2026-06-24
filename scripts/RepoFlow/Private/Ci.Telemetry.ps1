function Wait-RepoFlowPullRequestHead {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$ExpectedHeadSha,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [int]$PollSeconds,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StateConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Phase = 'ci-head-sync',

        [ValidateRange(30, 7200)]
        [int]$NoActivityWarningSeconds = 180
    )

    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $shortExpected = $ExpectedHeadSha.Substring(
        0,
        [Math]::Min(8, $ExpectedHeadSha.Length)
    )
    $telemetry = New-RepoFlowCiTelemetryState `
        -StartedAt $startedAt `
        -NoActivityWarningSeconds $NoActivityWarningSeconds
    $previousHead = ''

    Write-Host "[CI] Waiting for GitHub to register PR head $shortExpected..."

    do {
        $pullRequest = Get-RepoFlowPullRequest `
            -Number $PullRequestNumber `
            -Repository $Repository
        $actualHeadSha = [string]$pullRequest.headRefOid
        $now = Get-Date
        $changed = $actualHeadSha -ne $previousHead

        if ($changed) {
            $telemetry.LastObservableActivityAt = $now
            $telemetry.StallWarningShown = $false
        }

        $noActivity = $now - $telemetry.LastObservableActivityAt
        $status = if ($changed) {
            'active'
        }
        elseif ($noActivity.TotalSeconds -ge $NoActivityWarningSeconds) {
            'possibly stalled'
        }
        elseif ($noActivity.TotalSeconds -ge (2 * $PollSeconds)) {
            'no observable change'
        }
        else {
            'waiting'
        }

        Write-Host (
            '[CI] phase={0} | {1} | head={2} | expected={3} | last-activity={4}' -f
            $Phase,
            $status,
            $(if ([string]::IsNullOrWhiteSpace($actualHeadSha)) { '<none>' } else { $actualHeadSha.Substring(0, [Math]::Min(8, $actualHeadSha.Length)) }),
            $shortExpected,
            (ConvertTo-RepoFlowTelemetryDuration -Duration $noActivity)
        )

        Set-RepoFlowRunHeartbeat `
            -ConfigPath $StateConfigPath `
            -RunId $RunId `
            -CurrentPhase $Phase `
            -ObservableActivity:$changed

        if (
            $status -eq 'possibly stalled' -and
            -not $telemetry.StallWarningShown
        ) {
            $telemetry.StallWarningShown = $true
            Write-Warning (
                '[CI] GitHub has not reported an observable PR-head change ' +
                "for $(ConvertTo-RepoFlowTelemetryDuration -Duration $noActivity)."
            )
        }

        if ($actualHeadSha -eq $ExpectedHeadSha) {
            Write-Host "[CI] GitHub registered PR head $shortExpected."
            return $pullRequest
        }

        if ($now -ge $deadline) {
            $actualText = if ([string]::IsNullOrWhiteSpace($actualHeadSha)) {
                '<not reported>'
            }
            else {
                $actualHeadSha
            }

            throw "GitHub did not register expected PR head '$ExpectedHeadSha' before timeout. Current PR head: $actualText"
        }

        $previousHead = $actualHeadSha
        Start-Sleep -Seconds $PollSeconds
    }
    while ($true)
}

function Wait-RepoFlowPrChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [int]$TimeoutSeconds,

        [Parameter(Mandatory)]
        [int]$PollSeconds,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StateConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Phase = 'ci-watching',

        [ValidateRange(30, 7200)]
        [int]$NoActivityWarningSeconds = 180
    )

    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $telemetry = New-RepoFlowCiTelemetryState `
        -StartedAt $startedAt `
        -NoActivityWarningSeconds $NoActivityWarningSeconds

    do {
        $state = Get-RepoFlowPrCheckState `
            -PullRequestNumber $PullRequestNumber `
            -Repository $Repository
        $now = Get-Date
        $progress = Get-RepoFlowCiProgressTelemetry `
            -TelemetryState $telemetry `
            -CiState $state `
            -Now $now `
            -PollSeconds $PollSeconds

        Write-Host (Format-RepoFlowCiProgress `
            -Phase $Phase `
            -Progress $progress `
            -CiState $state)

        foreach ($transition in @($progress.Transitions)) {
            Write-Host "[CI] transition: $transition"
        }

        Set-RepoFlowRunHeartbeat `
            -ConfigPath $StateConfigPath `
            -RunId $RunId `
            -CurrentPhase $Phase `
            -ObservableActivity:$progress.ObservableActivity

        if ($progress.ShouldWarn) {
            Write-Warning (
                '[CI] No observable check transition for ' +
                "$(ConvertTo-RepoFlowTelemetryDuration -Duration $progress.NoActivity)."
            )
        }

        if ($state.Status -ne 'pending') {
            return $state
        }

        if ($now -ge $deadline) {
            return $state
        }

        Start-Sleep -Seconds $PollSeconds
    }
    while ($true)
}

