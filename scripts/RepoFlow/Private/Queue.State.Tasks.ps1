function Set-RepoFlowQueueTaskCheckpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId,

        [Parameter(Mandatory)]
        [int]$Position,

        [Parameter(Mandatory)]
        [string]$Phase,

        [ValidateSet('pending', 'running', 'paused')]
        [string]$Status = 'running',

        [AllowNull()]
        [string]$RunId = $null,

        [int]$PullRequestNumber = 0,

        [AllowNull()]
        [string]$HeadSha = $null,

        [AllowNull()]
        [string]$PauseReason = $null
    )

    Update-RepoFlowQueueRecord `
        -ConfigPath $ConfigPath `
        -QueueId $QueueId `
        -Update {
            param($queue)

            if ([string]$queue.status -ne 'running') {
                throw (
                    "Cannot update queue task while queue '$($queue.queueId)' " +
                    "is '$($queue.status)'."
                )
            }

            $tasks = @($queue.tasks)
            if ($Position -lt 0 -or $Position -ge $tasks.Count) {
                throw "Queue task position is out of range: $Position"
            }

            if ([int]$queue.currentIndex -ne $Position) {
                throw (
                    "Cannot update queue task at position $Position; " +
                    "the current position is $($queue.currentIndex)."
                )
            }

            $task = $tasks[$Position]
            $task.status = $Status
            $task.phase = $Phase
            $task.updatedAtUtc = New-RepoFlowRunTimestamp

            if ($null -eq $task.startedAtUtc -and $Status -eq 'running') {
                $task.startedAtUtc = New-RepoFlowRunTimestamp
            }

            if (-not [string]::IsNullOrWhiteSpace($RunId)) {
                $task.runId = $RunId
            }

            if ($PullRequestNumber -gt 0) {
                $task.pullRequestNumber = $PullRequestNumber
            }

            if (-not [string]::IsNullOrWhiteSpace($HeadSha)) {
                $task.headSha = $HeadSha
            }

            $task.pauseReason = if ([string]::IsNullOrWhiteSpace($PauseReason)) {
                $null
            }
            else {
                $PauseReason
            }
        } | Out-Null
}

function Complete-RepoFlowQueueTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId,

        [Parameter(Mandatory)]
        [int]$Position
    )

    Update-RepoFlowQueueRecord `
        -ConfigPath $ConfigPath `
        -QueueId $QueueId `
        -Update {
            param($queue)

            if ([string]$queue.status -ne 'running') {
                throw (
                    "Cannot complete a queue task while queue '$($queue.queueId)' " +
                    "is '$($queue.status)'."
                )
            }

            $tasks = @($queue.tasks)
            if ($Position -lt 0 -or $Position -ge $tasks.Count) {
                throw "Queue task position is out of range: $Position"
            }

            if ([int]$queue.currentIndex -ne $Position) {
                throw (
                    "Cannot complete queue task at position $Position; " +
                    "the current position is $($queue.currentIndex)."
                )
            }

            $task = $tasks[$Position]
            $now = New-RepoFlowRunTimestamp
            $task.status = 'completed'
            $task.phase = 'completed'
            $task.pauseReason = $null
            $task.completedAtUtc = $now
            $task.updatedAtUtc = $now
            $queue.currentIndex = $Position + 1
        } | Out-Null
}

function Set-RepoFlowQueuePaused {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    Update-RepoFlowQueueRecord `
        -ConfigPath $ConfigPath `
        -QueueId $QueueId `
        -Update {
            param($queue)

            if ([string]$queue.status -in @('stopped', 'completed')) {
                return
            }

            $queue.status = 'paused'
            $queue.pauseReason = $Reason
            $queue.stopReason = $null
        } | Out-Null
}

function Set-RepoFlowQueueUserPaused {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    Update-RepoFlowQueueRecord `
        -ConfigPath $ConfigPath `
        -QueueId $QueueId `
        -Update {
            param($queue)

            if ([string]$queue.status -in @('stopped', 'completed')) {
                throw "Queue '$($queue.queueId)' is already $($queue.status)."
            }

            $queue.status = 'paused'
            $queue.pauseReason = $Reason
            $queue.stopReason = $null

            if ([int]$queue.currentIndex -lt @($queue.tasks).Count) {
                $task = @($queue.tasks)[[int]$queue.currentIndex]

                if ([string]$task.status -notin @('completed', 'stopped')) {
                    $task.phase = if ([string]$task.status -eq 'pending') {
                        'paused-before-start'
                    }
                    else {
                        'user-paused'
                    }
                    $task.status = 'paused'
                    $task.pauseReason = $Reason
                    $task.updatedAtUtc = New-RepoFlowRunTimestamp
                }
            }
        } | Out-Null
}

function Set-RepoFlowQueueRunning {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId,

        [switch]$Continuous
    )

    Update-RepoFlowQueueRecord `
        -ConfigPath $ConfigPath `
        -QueueId $QueueId `
        -Update {
            param($queue)

            if ([string]$queue.status -in @('stopped', 'completed')) {
                throw "Queue '$($queue.queueId)' is $($queue.status) and cannot resume."
            }

            $queue.status = 'running'
            $queue.pauseReason = $null
            $queue.stopReason = $null
            $queue.continuous = [bool]$Continuous

            if ([int]$queue.currentIndex -lt @($queue.tasks).Count) {
                $task = @($queue.tasks)[[int]$queue.currentIndex]
                if ([string]$task.status -eq 'paused') {
                    $task.status = 'running'
                    $task.pauseReason = $null
                    $task.updatedAtUtc = New-RepoFlowRunTimestamp
                }
            }
        } | Out-Null
}

function Stop-RepoFlowQueueRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    Update-RepoFlowQueueRecord `
        -ConfigPath $ConfigPath `
        -QueueId $QueueId `
        -Update {
            param($queue)

            if ([string]$queue.status -eq 'completed') {
                throw "Queue '$($queue.queueId)' is already completed."
            }

            if ([string]$queue.status -eq 'stopped') {
                return
            }

            $queue.status = 'stopped'
            $queue.stopReason = $Reason
            $queue.pauseReason = $null

            if ([int]$queue.currentIndex -lt @($queue.tasks).Count) {
                $task = @($queue.tasks)[[int]$queue.currentIndex]
                if ([string]$task.status -notin @('completed', 'stopped')) {
                    $task.status = 'stopped'
                    $task.phase = 'stopped'
                    $task.pauseReason = $Reason
                    $task.updatedAtUtc = New-RepoFlowRunTimestamp
                }
            }
        } | Out-Null
}

function Complete-RepoFlowQueueRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId
    )

    Update-RepoFlowQueueRecord `
        -ConfigPath $ConfigPath `
        -QueueId $QueueId `
        -Update {
            param($queue)

            if ([string]$queue.status -ne 'running') {
                throw (
                    "Cannot complete queue '$($queue.queueId)' while it is " +
                    "'$($queue.status)'."
                )
            }

            $unfinishedTasks = @(
                $queue.tasks |
                Where-Object status -ne 'completed'
            )
            if ($unfinishedTasks.Count -gt 0) {
                throw (
                    "Queue '$($queue.queueId)' cannot complete with " +
                    'unfinished tasks.'
                )
            }

            $now = New-RepoFlowRunTimestamp
            $queue.status = 'completed'
            $queue.currentIndex = @($queue.tasks).Count
            $queue.pauseReason = $null
            $queue.stopReason = $null
            $queue.completedAtUtc = $now
        } | Out-Null
}
