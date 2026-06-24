function Assert-RepoFlowReviewResultMatchesRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Request,

        [Parameter(Mandatory)]
        $Result,

        [Parameter(Mandatory)]
        [ValidatePattern('^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$')]
        [string]$CurrentHeadSha,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$ProcessedRequestIds
    )

    Assert-RepoFlowReviewRequestEnvelope -Request $Request
    Assert-RepoFlowReviewResultEnvelope -Result $Result

    if ([string]$Result.requestId -cne [string]$Request.requestId) {
        throw 'RepoFlow review result request ID does not match the request.'
    }

    if (
        -not [string]::Equals(
            [string]$Result.reviewedHeadSha,
            [string]$Request.headSha,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'RepoFlow review result head SHA does not match the requested head SHA.'
    }

    if (
        -not [string]::Equals(
            [string]$Result.reviewedHeadSha,
            $CurrentHeadSha,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw 'RepoFlow review result is stale because the pull-request head has changed.'
    }

    if (
        @($ProcessedRequestIds) |
            Where-Object {
                [string]::Equals(
                    [string]$_,
                    [string]$Result.requestId,
                    [System.StringComparison]::Ordinal
                )
            }
    ) {
        throw 'RepoFlow review result is a duplicate for an already processed request.'
    }

    $requestCreatedAt = ConvertTo-RepoFlowReviewTimestamp `
        -Value $Request.createdAtUtc `
        -Path '$.createdAtUtc'
    $resultCompletedAt = ConvertTo-RepoFlowReviewTimestamp `
        -Value $Result.completedAtUtc `
        -Path '$.completedAtUtc'

    if ($resultCompletedAt -lt $requestCreatedAt) {
        throw 'RepoFlow review result completion time predates its request.'
    }
}
