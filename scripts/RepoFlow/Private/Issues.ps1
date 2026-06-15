function Get-RepoFlowIssueDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IssueBody
    )

    $section = Get-RepoFlowMarkdownSection -Body $IssueBody -Heading 'Dependencies'

    return @(
        [regex]::Matches($section, '#(?<number>\d+)') |
        ForEach-Object { [int]$_.Groups['number'].Value } |
        Sort-Object -Unique
    )
}

function Get-RepoFlowBranchType {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Labels
    )

    $labelNames = @(
        $Labels |
        ForEach-Object { [string]$_.name }
    )

    if ($labelNames -contains 'type: bug') {
        return 'fix'
    }

    if ($labelNames -contains 'type: refactor') {
        return 'refactor'
    }

    if ($labelNames -contains 'type: docs') {
        return 'docs'
    }

    return 'feature'
}

function Get-RepoFlowBranchVerb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BranchType
    )

    switch ($BranchType) {
        'fix' { return 'Fix' }
        'refactor' { return 'Refactor' }
        'docs' { return 'Document' }
        default { return 'Implement' }
    }
}

function Get-RepoFlowIssueBranchName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue
    )

    $branchType = Get-RepoFlowBranchType -Labels $Issue.labels
    $slug = ConvertTo-RepoFlowSlug -Value ([string]$Issue.title)
    return "$branchType/$($Issue.number)-$slug"
}

function Assert-RepoFlowIssueReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $number = [int]$Issue.number

    if ($Issue.state -ne 'OPEN') {
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

    foreach ($dependency in @(Get-RepoFlowIssueDependencies -IssueBody ([string]$Issue.body))) {
        if ($dependency -eq $number) {
            throw "Issue #$number lists itself as a dependency."
        }

        $dependencyIssue = Get-RepoFlowIssue -Number $dependency -Repository $Repository

        if ($dependencyIssue.state -ne 'CLOSED') {
            throw "Dependency #$dependency is still open: $($dependencyIssue.title)"
        }
    }
}
