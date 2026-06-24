function Get-RepoFlowQueueResolvedTaskKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositorySlug,

        [Parameter(Mandatory)]
        [int]$IssueNumber
    )

    return ('{0}#{1}' -f $RepositorySlug.ToLowerInvariant(), $IssueNumber)
}

function Assert-RepoFlowQueuePlanDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Entries
    )

    $resolvedTasks = @{}

    foreach ($entry in @($Entries)) {
        $key = Get-RepoFlowQueueResolvedTaskKey `
            -RepositorySlug ([string]$entry.Snapshot.RepositorySlug) `
            -IssueNumber ([int]$entry.Task.issueNumber)

        if ($resolvedTasks.ContainsKey($key)) {
            throw (
                "Queue resolves more than one task to " +
                "$($entry.Snapshot.RepositorySlug) issue #$($entry.Task.issueNumber)."
            )
        }

        $resolvedTasks[$key] = $entry
    }

    foreach ($entry in @($Entries)) {
        $issue = $entry.Snapshot.Issue
        $issueNumber = [int]$issue.number
        $pullRequest = $entry.Snapshot.PullRequest

        if (
            $null -ne $pullRequest -and
            [string]$pullRequest.state -in @('MERGED', 'CLOSED')
        ) {
            continue
        }

        foreach ($dependency in @(
            Get-RepoFlowIssueDependencies -IssueBody ([string]$issue.body)
        )) {
            if ($dependency -eq $issueNumber) {
                throw "Issue #$issueNumber lists itself as a dependency."
            }

            $dependencyKey = Get-RepoFlowQueueResolvedTaskKey `
                -RepositorySlug ([string]$entry.Snapshot.RepositorySlug) `
                -IssueNumber $dependency
            $queuedDependency = if ($resolvedTasks.ContainsKey($dependencyKey)) {
                $resolvedTasks[$dependencyKey]
            }
            else {
                $null
            }

            $dependencyIssue = if ($null -ne $queuedDependency) {
                $queuedDependency.Snapshot.Issue
            }
            else {
                Get-RepoFlowIssue `
                    -Number $dependency `
                    -Repository ([string]$entry.Snapshot.RepositorySlug)
            }

            if ([string]$dependencyIssue.state -eq 'CLOSED') {
                continue
            }

            if ($null -ne $queuedDependency) {
                $dependencyPosition = [int]$queuedDependency.Task.position
                $currentPosition = [int]$entry.Task.position

                if ($dependencyPosition -lt $currentPosition) {
                    continue
                }

                throw (
                    "Issue #$issueNumber depends on open issue #$dependency, but " +
                    "the dependency is not earlier in the queue (task " +
                    "$($dependencyPosition + 1))."
                )
            }

            throw (
                "Dependency #$dependency is still open and is not scheduled " +
                "earlier in this queue: $($dependencyIssue.title)"
            )
        }
    }
}

function Get-RepoFlowQueuePlanRows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Manifest,

        [AllowNull()]
        $QueueRecord,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $entries = [System.Collections.Generic.List[object]]::new()
    $validatedRepositories = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )

    foreach ($task in @($Manifest.tasks)) {
        $repositoryName = Get-RepoFlowQueueTaskRepositoryName -Task $task
        $repositoryKey = if ([string]::IsNullOrWhiteSpace($repositoryName)) {
            '<default>'
        }
        else {
            $repositoryName
        }

        if ($validatedRepositories.Add($repositoryKey)) {
            Assert-RepoFlowQueueRepositoryHealth `
                -Repository $repositoryName `
                -ConfigPath $ConfigPath | Out-Null
        }

        $snapshot = Get-RepoFlowQueueTaskSnapshot `
            -Task $task `
            -ConfigPath $ConfigPath `
            -DeferDependencyValidation

        $entries.Add([pscustomobject]@{
            Task = $task
            Snapshot = $snapshot
        }) | Out-Null
    }

    Assert-RepoFlowQueuePlanDependencies -Entries $entries.ToArray()

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($entry in $entries) {
        $task = $entry.Task
        $snapshot = $entry.Snapshot
        $savedTask = if (
            $null -ne $QueueRecord -and
            [int]$task.position -lt @($QueueRecord.tasks).Count
        ) {
            @($QueueRecord.tasks)[[int]$task.position]
        }
        else {
            $null
        }

        $liveState = if ($null -ne $snapshot.PullRequest) {
            "PR #$($snapshot.PullRequest.number) $(([string]$snapshot.PullRequest.state).ToLowerInvariant())"
        }
        elseif ($snapshot.LocalBranchExists -or $snapshot.RemoteBranchExists) {
            'branch exists; resume required'
        }
        else {
            'ready to start'
        }

        $rows.Add([pscustomobject]@{
            Position = [int]$task.position + 1
            Repository = [string]$snapshot.RepositoryName
            Issue = [int]$task.issueNumber
            Title = [string]$snapshot.Issue.title
            CiMode = Get-RepoFlowQueueTaskCiMode `
                -Task $task `
                -Config $snapshot.Config
            Review = if ([bool]$task.automatedReview) {
                'automated'
            }
            else {
                'manual gate'
            }
            SavedStatus = if ($null -eq $savedTask) {
                'new'
            }
            else {
                "$( [string]$savedTask.status )/$( [string]$savedTask.phase )"
            }
            LiveState = $liveState
        }) | Out-Null
    }

    return $rows.ToArray()
}

function Show-RepoFlowQueuePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Manifest,

        [Parameter(Mandatory)]
        [object[]]$Rows,

        [AllowNull()]
        $QueueRecord,

        [switch]$Continuous
    )

    Write-Host ''
    Write-Host "Queue:      $($Manifest.name)"
    Write-Host "Manifest:   $($Manifest.path)"
    Write-Host "Fingerprint: $($Manifest.hash)"
    Write-Host "Mode:       $(if ($Continuous) { 'continuous between completed tasks' } else { 'one task per invocation' })"

    if ($null -ne $QueueRecord) {
        $taskCount = @($QueueRecord.tasks).Count
        $displayPosition = [Math]::Min(
            ([int]$QueueRecord.currentIndex + 1),
            $taskCount
        )
        Write-Host "Queue ID:   $($QueueRecord.queueId)"
        Write-Host "Status:     $($QueueRecord.status)"
        Write-Host "Position:   $displayPosition/$taskCount"
    }

    Write-Host ''
    Write-Host 'Ordered execution plan:'

    foreach ($row in @($Rows)) {
        Write-Host (
            ' {0,2}. [{1}] #{2} {3}' -f
            $row.Position,
            $row.Repository,
            $row.Issue,
            $row.Title
        )
        Write-Host (
            '     CI={0}; review={1}; saved={2}; live={3}' -f
            $row.CiMode,
            $row.Review,
            $row.SavedStatus,
            $row.LiveState
        )
    }

    Write-Host ''
}

function Assert-RepoFlowQueueManifestMatchesState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Manifest,

        [Parameter(Mandatory)]
        $QueueRecord
    )

    if (
        -not [string]::Equals(
            [string]$Manifest.hash,
            [string]$QueueRecord.manifestHash,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw (
            "Queue manifest changed after queue '$($QueueRecord.queueId)' " +
            'was created. Restore the original manifest or start a new file.'
        )
    }

    if (@($Manifest.tasks).Count -ne @($QueueRecord.tasks).Count) {
        throw 'Queue manifest task count conflicts with persisted queue state.'
    }
}

function Test-RepoFlowQueueControlRequested {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$QueueId
    )

    $record = Get-RepoFlowQueueRecord `
        -ConfigPath $ConfigPath `
        -QueueId $QueueId

    if ($null -eq $record) {
        throw "Queue state disappeared during execution: $QueueId"
    }

    if ([string]$record.status -eq 'stopped') {
        Write-Warning "Queue '$QueueId' was stopped."
        return $true
    }

    if ([string]$record.status -eq 'paused') {
        Write-Warning "Queue '$QueueId' was paused."
        return $true
    }

    return $false
}

function Invoke-RepoFlowQueueLocalValidation {
    [CmdletBinding()]
    param()

    Write-Host '[QUEUE] Running local validation: git diff --check'
    $validation = Invoke-RepoFlowLocalValidation

    if ($validation.ExitCode -ne 0) {
        throw (
            'Queue local validation failed:' +
            "$([Environment]::NewLine)$($validation.Text)"
        )
    }
}

