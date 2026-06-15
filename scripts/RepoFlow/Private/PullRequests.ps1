function Build-RepoFlowPullRequestBody {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Template,

        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        [string]$AgentSummary
    )

    $number = [int]$Issue.number
    $title = [string]$Issue.title
    $body = $Template
    $summaryText = "Implements #$number`: $title."
    $changes = Get-RepoFlowMarkdownSection -Body $AgentSummary -Heading 'Changes'
    $acceptanceCriteria = Get-RepoFlowMarkdownSection -Body $AgentSummary -Heading 'Acceptance criteria'
    $scopeDeviations = Get-RepoFlowMarkdownSection -Body $AgentSummary -Heading 'Scope deviations'
    $securityImpact = Get-RepoFlowMarkdownSection -Body $AgentSummary -Heading 'Security impact'

    if ([string]::IsNullOrWhiteSpace($changes)) {
        $changes = '- Implementation completed. Review the changed files before marking the pull request ready.'
    }

    if ([string]::IsNullOrWhiteSpace($acceptanceCriteria)) {
        $acceptanceCriteria = Get-RepoFlowMarkdownSection -Body ([string]$Issue.body) -Heading 'Acceptance criteria'
    }

    if ([string]::IsNullOrWhiteSpace($acceptanceCriteria)) {
        $acceptanceCriteria = '- [ ] Review the linked issue acceptance criteria.'
    }

    if ([string]::IsNullOrWhiteSpace($scopeDeviations)) {
        $scopeDeviations = 'None.'
    }

    if ([string]::IsNullOrWhiteSpace($securityImpact)) {
        $securityImpact = 'None identified.'
    }

    $body = $body.Replace('<!-- Briefly describe what this PR implements. -->', $summaryText)
    $body = [regex]::Replace($body, '(?m)^Closes #\s*$', "Closes #$number")

    $replacements = @(
        [pscustomobject]@{
            Heading = 'Changes'
            NextHeading = 'Acceptance criteria'
            Value = $changes
        },
        [pscustomobject]@{
            Heading = 'Acceptance criteria'
            NextHeading = 'Scope deviations'
            Value = $acceptanceCriteria
        },
        [pscustomobject]@{
            Heading = 'Scope deviations'
            NextHeading = 'Security impact'
            Value = $scopeDeviations
        }
    )

    foreach ($replacement in $replacements) {
        $heading = [regex]::Escape($replacement.Heading)
        $nextHeading = [regex]::Escape($replacement.NextHeading)
        $pattern = "(?ms)(## $heading\s*\r?\n\r?\n).*?(?=\r?\n## $nextHeading)"

        $body = [regex]::Replace($body, $pattern, {
            param($match)
            return $match.Groups[1].Value + $replacement.Value.Trim() + [Environment]::NewLine
        })
    }

    $body = [regex]::Replace($body, '(?ms)(## Security impact\s*\r?\n\r?\n).*$', {
        param($match)
        return $match.Groups[1].Value + $securityImpact.Trim() + [Environment]::NewLine
    })

    if ($body -notmatch '(?m)^Closes #\d+\s*$') {
        $body = $body.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + "Closes #$number"
    }

    return $body.TrimEnd() + [Environment]::NewLine
}

function Get-RepoFlowMessageValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue
    )

    $branchType = Get-RepoFlowBranchType -Labels $Issue.labels
    $verb = Get-RepoFlowBranchVerb -BranchType $branchType

    return @{
        verb = $verb
        issueNumber = [int]$Issue.number
        issueTitle = [string]$Issue.title
    }
}

function Get-RepoFlowInitialCommitMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $Config
    )

    return Expand-RepoFlowMessageTemplate `
        -Template ([string]$Config.messages.initialCommit) `
        -Values (Get-RepoFlowMessageValues -Issue $Issue)
}

function Get-RepoFlowReviewCommitMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $Config
    )

    return Expand-RepoFlowMessageTemplate `
        -Template ([string]$Config.messages.reviewCommit) `
        -Values (Get-RepoFlowMessageValues -Issue $Issue)
}

function Get-RepoFlowCiFixCommitMessage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $Config
    )

    return Expand-RepoFlowMessageTemplate `
        -Template ([string]$Config.messages.ciFixCommit) `
        -Values (Get-RepoFlowMessageValues -Issue $Issue)
}

function Get-RepoFlowPullRequestTitle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $Config
    )

    return Expand-RepoFlowMessageTemplate `
        -Template ([string]$Config.messages.pullRequestTitle) `
        -Values (Get-RepoFlowMessageValues -Issue $Issue)
}

function Show-RepoFlowPullRequestStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PullRequest,

        [AllowNull()]
        $CheckState
    )

    Write-Host "PR:       #$($PullRequest.number) $($PullRequest.title)"
    Write-Host "URL:      $($PullRequest.url)"
    Write-Host "State:    $($PullRequest.state)"
    Write-Host "Draft:    $($PullRequest.isDraft)"
    Write-Host "Branch:   $($PullRequest.headRefName) -> $($PullRequest.baseRefName)"

    if (-not [string]::IsNullOrWhiteSpace([string]$PullRequest.reviewDecision)) {
        Write-Host "Review:   $($PullRequest.reviewDecision)"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$PullRequest.mergeStateStatus)) {
        Write-Host "Merge:    $($PullRequest.mergeStateStatus)"
    }

    if ($null -ne $CheckState) {
        Write-Host "CI:       $($CheckState.Status)"

        foreach ($check in @($CheckState.Checks)) {
            Write-Host "  - $($check.name): $($check.bucket)"
        }
    }
}
