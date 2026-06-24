function Test-RepoFlowAutomatedReviewTrustedComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Comment,

        [Parameter(Mandatory)]
        $Config
    )

    return Test-RepoFlowTrustedComment `
        -Comment $Comment `
        -Config $Config
}

function Find-RepoFlowAutomatedReviewRequestComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Comments,

        [Parameter(Mandatory)]
        [string]$AuthenticatedLogin,

        [Parameter(Mandatory)]
        [string]$RequestId,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$BaseSha,

        [Parameter(Mandatory)]
        [string]$HeadSha
    )

    foreach ($comment in @($Comments | Sort-Object -Property id)) {
        $commentLogin = [string](Get-RepoFlowProperty `
            -Object $comment.user `
            -Name 'login' `
            -Default '')

        if (
            -not [string]::Equals(
                $commentLogin,
                $AuthenticatedLogin,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            continue
        }

        $body = [string](Get-RepoFlowProperty -Object $comment -Name 'body' -Default '')

        if ($body -notmatch '(?im)^\s*<!--\s*rf-review-request:v1\s*-->\s*$') {
            continue
        }

        try {
            $request = ConvertFrom-RepoFlowReviewComment `
                -Text $body `
                -Kind 'request'
        }
        catch {
            continue
        }

        if (
            [string]$request.requestId -cne $RequestId -or
            -not [string]::Equals(
                [string]$request.repository,
                $Repository,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            [int]$request.issue.number -ne $IssueNumber -or
            [int]$request.pullRequest.number -ne $PullRequestNumber -or
            -not [string]::Equals(
                [string]$request.baseSha,
                $BaseSha,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            -not [string]::Equals(
                [string]$request.headSha,
                $HeadSha,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            continue
        }

        return [pscustomobject]@{
            Comment = $comment
            Envelope = $request
        }
    }

    return $null
}

function Resolve-RepoFlowAutomatedReviewResultComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Request,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Comments,

        [Parameter(Mandatory)]
        [string]$CurrentHeadSha,

        [Parameter(Mandatory)]
        $Config,

        [AllowEmptyCollection()]
        [string[]]$ProcessedRequestIds = @()
    )

    $requestCreatedAt = ConvertTo-RepoFlowReviewTimestamp `
        -Value $Request.createdAtUtc `
        -Path '$.createdAtUtc'
    $firstMalformed = $null

    foreach ($comment in @($Comments | Sort-Object -Property id)) {
        $body = [string](Get-RepoFlowProperty -Object $comment -Name 'body' -Default '')

        if ($body -notmatch '(?im)^\s*<!--\s*rf-review-result:v1\s*-->\s*$') {
            continue
        }

        if (-not (Test-RepoFlowAutomatedReviewTrustedComment -Comment $comment -Config $Config)) {
            continue
        }

        $createdAtText = [string](Get-RepoFlowProperty `
            -Object $comment `
            -Name 'created_at' `
            -Default '')
        $commentCreatedAt = [DateTimeOffset]::MinValue

        $hasValidCreatedAt = [DateTimeOffset]::TryParse(
            $createdAtText,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind,
            [ref]$commentCreatedAt
        )

        if (-not $hasValidCreatedAt) {
            if ($null -eq $firstMalformed) {
                $firstMalformed = [pscustomobject]@{
                    Status = 'malformed'
                    Comment = $comment
                    Result = $null
                    Reason = 'A trusted marked result comment has no valid timestamp.'
                }
            }
            continue
        }

        if ($commentCreatedAt -lt $requestCreatedAt) {
            continue
        }

        try {
            $result = ConvertFrom-RepoFlowReviewComment `
                -Text $body `
                -Kind 'result'
        }
        catch {
            if ($null -eq $firstMalformed) {
                $firstMalformed = [pscustomobject]@{
                    Status = 'malformed'
                    Comment = $comment
                    Result = $null
                    Reason = 'A trusted marked result comment is malformed.'
                }
            }
            continue
        }

        try {
            Assert-RepoFlowReviewResultMatchesRequest `
                -Request $Request `
                -Result $result `
                -CurrentHeadSha $CurrentHeadSha `
                -ProcessedRequestIds $ProcessedRequestIds
        }
        catch {
            $message = [string]$_.Exception.Message

            if ($message -match 'request ID does not match|head SHA does not match|stale because|duplicate for') {
                continue
            }

            if ($null -eq $firstMalformed) {
                $firstMalformed = [pscustomobject]@{
                    Status = 'malformed'
                    Comment = $comment
                    Result = $null
                    Reason = 'A trusted marked result comment failed validation.'
                }
            }
            continue
        }

        return [pscustomobject]@{
            Status = 'accepted'
            Comment = $comment
            Result = $result
            Reason = $null
        }
    }

    if ($null -ne $firstMalformed) {
        return $firstMalformed
    }

    return [pscustomobject]@{
        Status = 'none'
        Comment = $null
        Result = $null
        Reason = $null
    }
}
