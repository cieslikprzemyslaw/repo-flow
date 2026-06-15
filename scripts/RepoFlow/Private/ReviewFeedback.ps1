function Test-RepoFlowTrustedComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Comment,

        [Parameter(Mandatory)]
        $Config
    )

    $association = [string]$Comment.author_association
    $userType = [string]$Comment.user.type

    if ($userType -eq 'Bot') {
        return $false
    }

    return @($Config.reviewFeedback.trustedAssociations) -contains $association
}

function Assert-RepoFlowCommentBelongsToPullRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Comment,

        [Parameter(Mandatory)]
        [int]$PullRequestNumber
    )

    $issueUrl = [string]$Comment.issue_url

    if ($issueUrl -notmatch "/issues/$PullRequestNumber$") {
        throw "Comment #$($Comment.id) does not belong to pull request #$PullRequestNumber."
    }
}

function Get-RepoFlowSelectedPullRequestComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Config,

        [switch]$LastPrComment,

        [long]$PrCommentId
    )

    if (-not $Config.reviewFeedback.enabled) {
        throw 'Review-feedback mode is disabled in .repo-flow.json.'
    }

    if ($LastPrComment -and $PrCommentId -gt 0) {
        throw 'Use either -LastPrComment or -PrCommentId, not both.'
    }

    if (-not $LastPrComment -and $PrCommentId -le 0) {
        throw 'Issue continuation requires -LastPrComment or -PrCommentId.'
    }

    $repository = [string]$Config.repository.slug
    $comment = $null

    if ($PrCommentId -gt 0) {
        $comment = Get-RepoFlowPullRequestComment -CommentId $PrCommentId -Repository $repository
        Assert-RepoFlowCommentBelongsToPullRequest -Comment $comment -PullRequestNumber ([int]$PullRequest.number)

        if (-not (Test-RepoFlowTrustedComment -Comment $comment -Config $Config)) {
            throw "Comment #$PrCommentId was not written by a trusted repository participant."
        }
    }
    else {
        $comments = @(
            Get-RepoFlowPullRequestComments `
                -PullRequestNumber ([int]$PullRequest.number) `
                -Repository $repository |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_.body) -and
                (Test-RepoFlowTrustedComment -Comment $_ -Config $Config)
            } |
            Sort-Object -Property created_at -Descending
        )

        if ($comments.Count -eq 0) {
            throw "Pull request #$($PullRequest.number) has no trusted top-level comments."
        }

        $comment = $comments[0]
    }

    return $comment
}

function Show-RepoFlowSelectedComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Comment
    )

    Write-Host ''
    Write-Host 'Selected PR feedback'
    Write-Host '--------------------'
    Write-Host "PR:          #$($PullRequest.number)"
    Write-Host "Author:      $($Comment.user.login)"
    Write-Host "Association: $($Comment.author_association)"
    Write-Host "Comment ID:  $($Comment.id)"
    Write-Host "URL:         $($Comment.html_url)"
    Write-Host ''
    Write-Host ([string]$Comment.body)
    Write-Host ''
}
