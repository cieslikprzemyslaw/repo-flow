function Assert-RepoFlowGitHubAuthentication {
    [CmdletBinding()]
    param()

    Assert-RepoFlowCommand -Name 'gh'
    Invoke-RepoFlowCommand -Command 'gh' -Arguments @('auth', 'status') | Out-Null
}

function Get-RepoFlowIssue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $result = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'issue',
        'view',
        $Number.ToString(),
        '--repo',
        $Repository,
        '--json',
        'number,title,body,state,labels,url,milestone'
    )

    return $result.Data
}

function Get-RepoFlowPullRequestsForBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$Repository,

        [ValidateSet('open', 'closed', 'merged', 'all')]
        [string]$State = 'all'
    )

    $result = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'pr',
        'list',
        '--repo',
        $Repository,
        '--head',
        $Branch,
        '--state',
        $State,
        '--limit',
        '20',
        '--json',
        'number,title,state,isDraft,mergedAt,baseRefName,headRefName,url,reviewDecision'
    )

    return @($result.Data)
}

function Get-RepoFlowOpenPullRequestForBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $pullRequests = @(Get-RepoFlowPullRequestsForBranch -Branch $Branch -Repository $Repository -State open)

    if ($pullRequests.Count -eq 0) {
        return $null
    }

    if ($pullRequests.Count -gt 1) {
        throw "More than one open pull request uses branch '$Branch'."
    }

    return $pullRequests[0]
}

function Get-RepoFlowLatestPullRequestForBranch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $pullRequests = @(Get-RepoFlowPullRequestsForBranch -Branch $Branch -Repository $Repository -State all)

    if ($pullRequests.Count -eq 0) {
        return $null
    }

    return $pullRequests |
        Sort-Object -Property number -Descending |
        Select-Object -First 1
}

function Get-RepoFlowPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $result = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'pr',
        'view',
        $Number.ToString(),
        '--repo',
        $Repository,
        '--json',
        'number,title,state,isDraft,mergedAt,mergeStateStatus,baseRefName,headRefName,headRefOid,url,reviewDecision,author,body'
    )

    return $result.Data
}

function Get-RepoFlowPullRequestIssueNumber {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PullRequest
    )

    $body = [string](Get-RepoFlowProperty -Object $PullRequest -Name 'body' -Default '')

    foreach ($pattern in @(
        '(?m)^(?:Closes|Fixes|Resolves|Implements) #(?<number>\d+)\s*$',
        '(?m)^(?:Closes|Fixes|Resolves|Implements)\s+#(?<number>\d+)\s*$'
    )) {
        $match = [regex]::Match($body, $pattern)

        if ($match.Success) {
            return [int]$match.Groups['number'].Value
        }
    }

    throw (
        'Could not determine the originating issue number from the ' +
        "pull request body."
    )
}

function New-RepoFlowPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [string]$HeadBranch,

        [Parameter(Mandatory)]
        [string]$Title,

        [Parameter(Mandatory)]
        [string]$Body,

        [switch]$Draft
    )

    $bodyPath = [System.IO.Path]::GetTempFileName()

    try {
        Set-Content -LiteralPath $bodyPath -Value $Body -Encoding utf8

        $arguments = @(
            'pr',
            'create',
            '--repo',
            $Repository,
            '--base',
            $BaseBranch,
            '--head',
            $HeadBranch,
            '--title',
            $Title,
            '--body-file',
            $bodyPath
        )

        if ($Draft) {
            $arguments += '--draft'
        }

        Invoke-RepoFlowCommand -Command 'gh' -Arguments $arguments | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
    }

    $pullRequest = Get-RepoFlowOpenPullRequestForBranch -Branch $HeadBranch -Repository $Repository

    if ($null -eq $pullRequest) {
        throw "The pull request was created, but RepoFlow could not read it back."
    }

    return $pullRequest
}

function Set-RepoFlowPullRequestReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    Invoke-RepoFlowCommand -Command 'gh' -Arguments @(
        'pr',
        'ready',
        $Number.ToString(),
        '--repo',
        $Repository
    ) | Out-Null
}

function Get-RepoFlowPullRequestComments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $result = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'api',
        "repos/$Repository/issues/$PullRequestNumber/comments?per_page=100"
    )

    return @($result.Data)
}

function Get-RepoFlowPullRequestComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$CommentId,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $result = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'api',
        "repos/$Repository/issues/comments/$CommentId"
    )

    return $result.Data
}

function Merge-RepoFlowPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [ValidateSet('squash', 'merge', 'rebase')]
        [string]$Method
    )

    $methodArgument = switch ($Method) {
        'squash' { '--squash' }
        'merge' { '--merge' }
        'rebase' { '--rebase' }
    }

    Invoke-RepoFlowCommand `
        -Command 'gh' `
        -Arguments @(
            'pr',
            'merge',
            $Number.ToString(),
            '--repo',
            $Repository,
            $methodArgument
        ) |
        Out-Null
}
