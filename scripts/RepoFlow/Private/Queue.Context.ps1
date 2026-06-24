function Get-RepoFlowQueueStateConfigPath {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    return Resolve-RepoFlowConfigPath -ConfigPath $ConfigPath
}

function Get-RepoFlowQueueTaskRepositoryName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Task
    )

    $repository = Get-RepoFlowProperty `
        -Object $Task `
        -Name 'repository' `
        -Default $null

    if ([string]::IsNullOrWhiteSpace([string]$repository)) {
        return $null
    }

    return [string]$repository
}

function Get-RepoFlowQueueTaskCiMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Task,

        [Parameter(Mandatory)]
        $Config
    )

    $override = Get-RepoFlowProperty `
        -Object $Task `
        -Name 'ciMode' `
        -Default $null

    return Get-RepoFlowEffectiveCiMode `
        -Config $Config `
        -Override ([string]$override)
}

function Get-RepoFlowQueueLatestIssueRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [int]$IssueNumber
    )

    return @(
        Get-RepoFlowRunRecords `
            -ConfigPath $ConfigPath `
            -Repository $Repository |
        Where-Object {
            [int]$_.issueNumber -eq $IssueNumber -and
            [string]$_.operation -in @(
                'issue-run',
                'issue-continue-review-feedback'
            )
        }
    ) | Select-Object -First 1
}

function Assert-RepoFlowQueueIssueReadyWithoutDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue
    )

    $number = [int]$Issue.number

    if ([string]$Issue.state -ne 'OPEN') {
        throw "Issue #$number is not open."
    }

    $labelNames = @(
        $Issue.labels |
        ForEach-Object { [string]$_.name }
    )

    if ($labelNames -contains 'status: needs review') {
        throw "Issue #$number is marked 'status: needs review'."
    }

    if ([string]$Issue.body -match '(?i)feature idea|more information soon|refinement placeholder') {
        throw "Issue #$number is not ready for implementation."
    }
}

function Get-RepoFlowQueueTaskSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Task,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [switch]$RequireAgent,

        [switch]$DeferDependencyValidation
    )

    $repositoryName = Get-RepoFlowQueueTaskRepositoryName -Task $Task
    $context = New-RepoFlowContext `
        -ConfigPath $ConfigPath `
        -Repo $repositoryName `
        -RequireGitHub `
        -RequireAgent:$RequireAgent
    $repository = [string]$context.Config.repository.slug
    $issue = Get-RepoFlowIssue `
        -Number ([int]$Task.issueNumber) `
        -Repository $repository
    $branch = Get-RepoFlowIssueBranchName -Issue $issue
    $pullRequest = Get-RepoFlowLatestPullRequestForBranch `
        -Branch $branch `
        -Repository $repository

    if ($null -eq $pullRequest -or [string]$pullRequest.state -eq 'OPEN') {
        if ($DeferDependencyValidation) {
            Assert-RepoFlowQueueIssueReadyWithoutDependencies -Issue $issue
        }
        else {
            Assert-RepoFlowIssueReady -Issue $issue -Repository $repository
        }
    }

    if ($null -ne $pullRequest) {
        $pullRequest = Get-RepoFlowPullRequest `
            -Number ([int]$pullRequest.number) `
            -Repository $repository
    }

    return [pscustomobject]@{
        Context = $context
        Config = $context.Config
        RepositoryName = [string]$context.RepositorySelection.Repository.name
        RepositorySlug = $repository
        Issue = $issue
        Branch = $branch
        LocalBranchExists = Test-RepoFlowLocalBranch -Branch $branch
        RemoteBranchExists = Test-RepoFlowRemoteBranch -Branch $branch
        PullRequest = $pullRequest
    }
}

function Assert-RepoFlowQueueRepositoryHealth {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Repository,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $results = @(Get-RepoFlowDoctorResults `
        -Repo $Repository `
        -ConfigPath $ConfigPath)
    $failureCount = Get-RepoFlowDoctorFailureCount -Results $results

    if ($failureCount -gt 0) {
        $report = Format-RepoFlowDoctorReport -Results $results
        throw (
            "Queue repository health validation failed.$([Environment]::NewLine)" +
            $report
        )
    }

    return [pscustomobject]@{
        PassCount = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
        WarnCount = @($results | Where-Object { $_.Status -eq 'WARN' }).Count
        FailCount = 0
    }
}
