function New-RepoFlowQueueId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ManifestHash
    )

    $timestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
    return "rf-queue-v1-$($ManifestHash.Substring(0, 12))-$timestamp-$suffix"
}

function Assert-RepoFlowQueueTaskRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-RepoFlowAllowedProperties `
        -Object $Task `
        -Allowed @(
            'position',
            'issueNumber',
            'repository',
            'ciMode',
            'automatedReview',
            'status',
            'phase',
            'runId',
            'pullRequestNumber',
            'headSha',
            'startedAtUtc',
            'updatedAtUtc',
            'completedAtUtc',
            'pauseReason'
        ) `
        -Path $Path

    foreach ($propertyName in @('position', 'issueNumber')) {
        $value = -1
        if (
            -not [int]::TryParse(
                [string](Get-RepoFlowProperty `
                    -Object $Task `
                    -Name $propertyName `
                    -Default $null),
                [ref]$value
            ) -or
            ($propertyName -eq 'position' -and $value -lt 0) -or
            ($propertyName -eq 'issueNumber' -and $value -le 0)
        ) {
            throw "RepoFlow queue state is invalid at '$Path.$propertyName'."
        }
    }

    $repository = Get-RepoFlowProperty `
        -Object $Task `
        -Name 'repository' `
        -Default $null
    if ($null -ne $repository) {
        Assert-RepoFlowString -Value $repository -Path "$Path.repository"
    }

    $ciMode = Get-RepoFlowProperty -Object $Task -Name 'ciMode' -Default $null
    if ($null -ne $ciMode -and [string]$ciMode -notin @(
        'skip',
        'observe',
        'require-passing'
    )) {
        throw "RepoFlow queue state is invalid at '$Path.ciMode'."
    }

    Assert-RepoFlowBoolean `
        -Value (Get-RepoFlowProperty `
            -Object $Task `
            -Name 'automatedReview' `
            -Default $null) `
        -Path "$Path.automatedReview"

    $status = [string](Get-RepoFlowProperty `
        -Object $Task `
        -Name 'status' `
        -Default '')
    if ($status -notin @('pending', 'running', 'paused', 'completed', 'stopped')) {
        throw "RepoFlow queue state is invalid at '$Path.status'."
    }

    Assert-RepoFlowString `
        -Value (Get-RepoFlowProperty `
            -Object $Task `
            -Name 'phase' `
            -Default $null) `
        -Path "$Path.phase"

    foreach ($propertyName in @('runId', 'headSha', 'pauseReason')) {
        $value = Get-RepoFlowProperty `
            -Object $Task `
            -Name $propertyName `
            -Default $null
        if ($null -ne $value) {
            Assert-RepoFlowString -Value $value -Path "$Path.$propertyName"
        }
    }

    $pullRequestNumber = Get-RepoFlowProperty `
        -Object $Task `
        -Name 'pullRequestNumber' `
        -Default $null
    if ($null -ne $pullRequestNumber) {
        $parsedPullRequestNumber = 0
        if (
            -not [int]::TryParse(
                [string]$pullRequestNumber,
                [ref]$parsedPullRequestNumber
            ) -or
            $parsedPullRequestNumber -le 0
        ) {
            throw "RepoFlow queue state is invalid at '$Path.pullRequestNumber'."
        }
    }

    foreach ($propertyName in @(
        'startedAtUtc',
        'completedAtUtc'
    )) {
        Assert-RepoFlowTimestampField `
            -Value (Get-RepoFlowProperty `
                -Object $Task `
                -Name $propertyName `
                -Default $null) `
            -Path "$Path.$propertyName" `
            -AllowNull
    }

    Assert-RepoFlowTimestampField `
        -Value (Get-RepoFlowProperty `
            -Object $Task `
            -Name 'updatedAtUtc' `
            -Default $null) `
        -Path "$Path.updatedAtUtc"
}

function Assert-RepoFlowQueueRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Record,

        [Parameter(Mandatory)]
        [string]$Path
    )

    Assert-RepoFlowAllowedProperties `
        -Object $Record `
        -Allowed @(
            'queueId',
            'name',
            'status',
            'manifestPath',
            'manifestHash',
            'continuous',
            'currentIndex',
            'createdAtUtc',
            'updatedAtUtc',
            'completedAtUtc',
            'pauseReason',
            'stopReason',
            'tasks'
        ) `
        -Path $Path

    foreach ($propertyName in @(
        'queueId',
        'name',
        'status',
        'manifestPath',
        'manifestHash'
    )) {
        Assert-RepoFlowString `
            -Value (Get-RepoFlowProperty `
                -Object $Record `
                -Name $propertyName `
                -Default $null) `
            -Path "$Path.$propertyName"
    }

    if ([string]$Record.status -notin @(
        'running',
        'paused',
        'stopped',
        'completed'
    )) {
        throw "RepoFlow queue state is invalid at '$Path.status'."
    }

    if ([string]$Record.manifestHash -notmatch '^[0-9a-f]{64}$') {
        throw "RepoFlow queue state is invalid at '$Path.manifestHash'."
    }

    Assert-RepoFlowBoolean `
        -Value (Get-RepoFlowProperty `
            -Object $Record `
            -Name 'continuous' `
            -Default $null) `
        -Path "$Path.continuous"

    $currentIndex = -1
    if (
        -not [int]::TryParse(
            [string](Get-RepoFlowProperty `
                -Object $Record `
                -Name 'currentIndex' `
                -Default $null),
            [ref]$currentIndex
        ) -or
        $currentIndex -lt 0
    ) {
        throw "RepoFlow queue state is invalid at '$Path.currentIndex'."
    }

    foreach ($propertyName in @('createdAtUtc', 'updatedAtUtc')) {
        Assert-RepoFlowTimestampField `
            -Value (Get-RepoFlowProperty `
                -Object $Record `
                -Name $propertyName `
                -Default $null) `
            -Path "$Path.$propertyName"
    }

    Assert-RepoFlowTimestampField `
        -Value (Get-RepoFlowProperty `
            -Object $Record `
            -Name 'completedAtUtc' `
            -Default $null) `
        -Path "$Path.completedAtUtc" `
        -AllowNull

    foreach ($propertyName in @('pauseReason', 'stopReason')) {
        $value = Get-RepoFlowProperty `
            -Object $Record `
            -Name $propertyName `
            -Default $null
        if ($null -ne $value) {
            Assert-RepoFlowString -Value $value -Path "$Path.$propertyName"
        }
    }

    $tasks = Get-RepoFlowProperty -Object $Record -Name 'tasks' -Default $null
    Assert-RepoFlowArray -Value $tasks -Path "$Path.tasks"

    if (@($tasks).Count -eq 0) {
        throw "RepoFlow queue state is invalid at '$Path.tasks'."
    }

    if ($currentIndex -gt @($tasks).Count) {
        throw "RepoFlow queue state is invalid at '$Path.currentIndex'."
    }

    $taskRecords = @($tasks)
    for ($index = 0; $index -lt $taskRecords.Count; $index++) {
        $taskRecord = $taskRecords[$index]
        Assert-RepoFlowQueueTaskRecord `
            -Task $taskRecord `
            -Path ("$Path.tasks[{0}]" -f $index)

        if ([int]$taskRecord.position -ne $index) {
            throw "RepoFlow queue state is invalid at '$Path.tasks[$index].position'."
        }

        if ($index -lt $currentIndex -and [string]$taskRecord.status -ne 'completed') {
            throw "RepoFlow queue state has an incomplete task before currentIndex."
        }

        if ($index -eq $currentIndex -and [string]$taskRecord.status -eq 'completed') {
            throw "RepoFlow queue state has a completed task at currentIndex."
        }

        if ($index -gt $currentIndex -and [string]$taskRecord.status -ne 'pending') {
            throw "RepoFlow queue state has a non-pending task after currentIndex."
        }
    }
}

