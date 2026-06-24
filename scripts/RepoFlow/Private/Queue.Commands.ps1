function Invoke-RepoFlowQueueRunWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Manifest,

        [switch]$Continuous,

        [switch]$Apply,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $originalLocation = (Get-Location).Path

    try {
        $queueManifest = Read-RepoFlowQueueManifest -ManifestPath $Manifest
        $stateConfigPath = Get-RepoFlowQueueStateConfigPath -ConfigPath $ConfigPath
        $existing = Get-RepoFlowLatestQueueForManifest `
            -ConfigPath $stateConfigPath `
            -ManifestPath ([string]$queueManifest.path)
        $rows = @(Get-RepoFlowQueuePlanRows `
            -Manifest $queueManifest `
            -QueueRecord $existing `
            -ConfigPath $stateConfigPath)
        Show-RepoFlowQueuePlan `
            -Manifest $queueManifest `
            -Rows $rows `
            -QueueRecord $existing `
            -Continuous:$Continuous

        if ($null -ne $existing -and [string]$existing.status -in @('running', 'paused')) {
            throw (
                "Queue '$($existing.queueId)' already exists. " +
                "Use 'rf queue resume -Manifest `"$($queueManifest.path)`"'."
            )
        }

        if (-not $Apply) {
            Write-Host 'PLAN ONLY - no queue, Git, GitHub, agent, or state mutation ran.'
            Write-Host 'Run again with -Apply to start the ordered queue.'
            return
        }

        $queue = Start-RepoFlowQueueRecord `
            -ConfigPath $stateConfigPath `
            -Manifest $queueManifest `
            -Continuous:$Continuous
        Write-Host "Started queue: $($queue.queueId)"

        Invoke-RepoFlowQueueExecution `
            -Manifest $queueManifest `
            -QueueId ([string]$queue.queueId) `
            -StateConfigPath $stateConfigPath `
            -ConfigPath $stateConfigPath `
            -Continuous:$Continuous
    }
    finally {
        Set-Location -LiteralPath $originalLocation
    }
}

function Invoke-RepoFlowQueueResumeWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Manifest,

        [switch]$Continuous,

        [switch]$Apply,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $originalLocation = (Get-Location).Path

    try {
        $queueManifest = Read-RepoFlowQueueManifest -ManifestPath $Manifest
        $stateConfigPath = Get-RepoFlowQueueStateConfigPath -ConfigPath $ConfigPath
        $queue = Get-RepoFlowLatestQueueForManifest `
            -ConfigPath $stateConfigPath `
            -ManifestPath ([string]$queueManifest.path)

        if ($null -eq $queue) {
            throw 'No persisted queue exists for this manifest. Use queue run first.'
        }

        Assert-RepoFlowQueueManifestMatchesState `
            -Manifest $queueManifest `
            -QueueRecord $queue

        if ([string]$queue.status -eq 'completed') {
            Write-Host "Queue '$($queue.queueId)' is already completed."
            return
        }

        if ([string]$queue.status -eq 'stopped') {
            throw (
                "Queue '$($queue.queueId)' is stopped and cannot be resumed. " +
                'Start a new queue manifest file for new execution.'
            )
        }

        $effectiveContinuous = $Continuous -or [bool]$queue.continuous
        $rows = @(Get-RepoFlowQueuePlanRows `
            -Manifest $queueManifest `
            -QueueRecord $queue `
            -ConfigPath $stateConfigPath)
        Show-RepoFlowQueuePlan `
            -Manifest $queueManifest `
            -Rows $rows `
            -QueueRecord $queue `
            -Continuous:$effectiveContinuous

        if (-not $Apply) {
            Write-Host 'PLAN ONLY - persisted queue state was not changed.'
            Write-Host 'Run again with -Apply to resume from the saved position.'
            return
        }

        Set-RepoFlowQueueRunning `
            -ConfigPath $stateConfigPath `
            -QueueId ([string]$queue.queueId) `
            -Continuous:$effectiveContinuous

        Invoke-RepoFlowQueueExecution `
            -Manifest $queueManifest `
            -QueueId ([string]$queue.queueId) `
            -StateConfigPath $stateConfigPath `
            -ConfigPath $stateConfigPath `
            -Continuous:$effectiveContinuous
    }
    finally {
        Set-Location -LiteralPath $originalLocation
    }
}

function Invoke-RepoFlowQueuePauseWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Manifest,

        [switch]$Apply,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $manifestPath = Resolve-RepoFlowQueueManifestPath -ManifestPath $Manifest
    $stateConfigPath = Get-RepoFlowQueueStateConfigPath -ConfigPath $ConfigPath
    $queue = Get-RepoFlowLatestQueueForManifest `
        -ConfigPath $stateConfigPath `
        -ManifestPath $manifestPath

    if ($null -eq $queue) {
        throw 'No persisted queue exists for this manifest path.'
    }

    if ([string]$queue.status -in @('completed', 'stopped')) {
        throw "Queue '$($queue.queueId)' is already $($queue.status)."
    }

    if (-not $Apply) {
        Write-Host "PLAN ONLY - queue '$($queue.queueId)' would be paused."
        return
    }

    Set-RepoFlowQueueUserPaused `
        -ConfigPath $stateConfigPath `
        -QueueId ([string]$queue.queueId) `
        -Reason 'Paused by explicit user request.'
    Write-Host "Queue '$($queue.queueId)' is paused."
}

function Invoke-RepoFlowQueueStopWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Manifest,

        [switch]$Apply,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $manifestPath = Resolve-RepoFlowQueueManifestPath -ManifestPath $Manifest
    $stateConfigPath = Get-RepoFlowQueueStateConfigPath -ConfigPath $ConfigPath
    $queue = Get-RepoFlowLatestQueueForManifest `
        -ConfigPath $stateConfigPath `
        -ManifestPath $manifestPath

    if ($null -eq $queue) {
        throw 'No persisted queue exists for this manifest path.'
    }

    if ([string]$queue.status -eq 'completed') {
        throw "Queue '$($queue.queueId)' is already completed."
    }

    if ([string]$queue.status -eq 'stopped') {
        Write-Host "Queue '$($queue.queueId)' is already stopped."
        return
    }

    if (-not $Apply) {
        Write-Host "PLAN ONLY - queue '$($queue.queueId)' would be stopped permanently."
        return
    }

    Stop-RepoFlowQueueRecord `
        -ConfigPath $stateConfigPath `
        -QueueId ([string]$queue.queueId) `
        -Reason 'Stopped by explicit user request.'
    Write-Host "Queue '$($queue.queueId)' is stopped."
}
