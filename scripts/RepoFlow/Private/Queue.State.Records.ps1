function Get-RepoFlowQueueRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $document = Read-RepoFlowStateDocument -ConfigPath $ConfigPath
    if ($null -eq $document) {
        return @()
    }

    return @(
        @($document.queues) |
        Sort-Object -Property updatedAtUtc -Descending
    )
}

function Get-RepoFlowQueueRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId
    )

    return @(
        Get-RepoFlowQueueRecords -ConfigPath $ConfigPath |
        Where-Object {
            [string]::Equals(
                [string]$_.queueId,
                $QueueId,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    ) | Select-Object -First 1
}

function Get-RepoFlowLatestQueueForManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$ManifestPath
    )

    $expectedPath = [System.IO.Path]::GetFullPath($ManifestPath)

    return @(
        Get-RepoFlowQueueRecords -ConfigPath $ConfigPath |
        Where-Object {
            [string]::Equals(
                [System.IO.Path]::GetFullPath([string]$_.manifestPath),
                $expectedPath,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    ) | Select-Object -First 1
}

function Start-RepoFlowQueueRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        $Manifest,

        [switch]$Continuous
    )

    $existing = Get-RepoFlowLatestQueueForManifest `
        -ConfigPath $ConfigPath `
        -ManifestPath ([string]$Manifest.path)

    if ($null -ne $existing -and [string]$existing.status -in @('running', 'paused')) {
        throw (
            "Queue '$($existing.queueId)' already exists for this manifest. " +
            "Use 'queue resume' instead of starting a duplicate queue."
        )
    }

    $now = New-RepoFlowRunTimestamp
    $taskRecords = [System.Collections.Generic.List[object]]::new()

    foreach ($task in @($Manifest.tasks)) {
        $taskRecords.Add([pscustomobject][ordered]@{
            position = [int]$task.position
            issueNumber = [int]$task.issueNumber
            repository = $task.repository
            ciMode = $task.ciMode
            automatedReview = [bool]$task.automatedReview
            status = 'pending'
            phase = 'pending'
            runId = $null
            pullRequestNumber = $null
            headSha = $null
            startedAtUtc = $null
            updatedAtUtc = $now
            completedAtUtc = $null
            pauseReason = $null
        }) | Out-Null
    }

    $record = [pscustomobject][ordered]@{
        queueId = New-RepoFlowQueueId -ManifestHash ([string]$Manifest.hash)
        name = [string]$Manifest.name
        status = 'running'
        manifestPath = [string]$Manifest.path
        manifestHash = [string]$Manifest.hash
        continuous = [bool]$Continuous
        currentIndex = 0
        createdAtUtc = $now
        updatedAtUtc = $now
        completedAtUtc = $null
        pauseReason = $null
        stopReason = $null
        tasks = $taskRecords.ToArray()
    }

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $manifestPath = [System.IO.Path]::GetFullPath([string]$Manifest.path)
        $activeQueue = @(
            @($document.queues) |
            Where-Object {
                [string]$_.status -in @('running', 'paused') -and
                [string]::Equals(
                    [System.IO.Path]::GetFullPath([string]$_.manifestPath),
                    $manifestPath,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
        ) | Select-Object -First 1

        if ($null -ne $activeQueue) {
            throw (
                "Queue '$($activeQueue.queueId)' already exists for this manifest. " +
                "Use 'queue resume' instead of starting a duplicate queue."
            )
        }

        $queues = [System.Collections.Generic.List[object]]::new()
        foreach ($queue in @($document.queues)) {
            $queues.Add($queue)
        }
        $queues.Add($record)
        $document.queues = $queues.ToArray()
        return $document
    } | Out-Null

    return $record
}

function Update-RepoFlowQueueRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId,

        [Parameter(Mandatory)]
        [scriptblock]$Update
    )

    $queueRecordUpdate = $Update

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $found = $false
        foreach ($queue in @($document.queues)) {
            if (
                [string]::Equals(
                    [string]$queue.queueId,
                    $QueueId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                & $queueRecordUpdate $queue | Out-Null
                $queue.updatedAtUtc = New-RepoFlowRunTimestamp
                $found = $true
                break
            }
        }

        if (-not $found) {
            throw "Unknown RepoFlow queue record: $QueueId"
        }

        return $document
    } | Out-Null

    return Get-RepoFlowQueueRecord -ConfigPath $ConfigPath -QueueId $QueueId
}

