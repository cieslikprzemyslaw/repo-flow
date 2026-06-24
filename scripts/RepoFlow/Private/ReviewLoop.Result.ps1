function Get-RepoFlowAcceptedPrReviewResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        $Config
    )

    $requestId = Get-RepoFlowAutomatedReviewRequestId `
        -PullRequestNumber ([int]$PullRequest.number) `
        -BaseSha ([string]$PullRequest.baseRefOid) `
        -HeadSha ([string]$PullRequest.headRefOid)
    $requestRun = Get-RepoFlowAutomatedReviewRunRecord `
        -ConfigPath $ConfigPath `
        -RequestId $requestId
    $resultRun = Get-RepoFlowAutomatedReviewResultRunRecord `
        -ConfigPath $ConfigPath `
        -RequestId $requestId

    if ($null -eq $requestRun -or $null -eq $resultRun) {
        throw 'Automated review completed without a persisted accepted result.'
    }

    $requestComment = Get-RepoFlowPullRequestComment `
        -CommentId ([long]$requestRun.prCommentId) `
        -Repository $Repository
    $resultComment = Get-RepoFlowPullRequestComment `
        -CommentId ([long]$resultRun.prCommentId) `
        -Repository $Repository

    Assert-RepoFlowCommentBelongsToPullRequest `
        -Comment $requestComment `
        -PullRequestNumber ([int]$PullRequest.number)
    Assert-RepoFlowCommentBelongsToPullRequest `
        -Comment $resultComment `
        -PullRequestNumber ([int]$PullRequest.number)

    if (
        -not (Test-RepoFlowAutomatedReviewTrustedComment `
            -Comment $resultComment `
            -Config $Config)
    ) {
        throw 'The persisted automated-review result is no longer trusted.'
    }

    $request = ConvertFrom-RepoFlowReviewComment `
        -Text ([string]$requestComment.body) `
        -Kind request
    $result = ConvertFrom-RepoFlowReviewComment `
        -Text ([string]$resultComment.body) `
        -Kind result

    Assert-RepoFlowReviewResultMatchesRequest `
        -Request $request `
        -Result $result `
        -CurrentHeadSha ([string]$PullRequest.headRefOid) `
        -ProcessedRequestIds @()

    return [pscustomobject]@{
        RequestId = $requestId
        Request = $request
        RequestComment = $requestComment
        Result = $result
        ResultComment = $resultComment
    }
}

function Get-RepoFlowReviewBlockerFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Blockers
    )

    if (@($Blockers).Count -eq 0) {
        throw 'A changes-required result must contain at least one blocker.'
    }

    $normalised = @(
        foreach ($blocker in @($Blockers)) {
            [pscustomobject][ordered]@{
                category = [string](Get-RepoFlowProperty `
                    -Object $blocker `
                    -Name category `
                    -Default '')
                path = [string](Get-RepoFlowProperty `
                    -Object $blocker `
                    -Name path `
                    -Default '')
                startLine = [int](Get-RepoFlowProperty `
                    -Object $blocker `
                    -Name startLine `
                    -Default 0)
                endLine = [int](Get-RepoFlowProperty `
                    -Object $blocker `
                    -Name endLine `
                    -Default 0)
                explanation = [string](Get-RepoFlowProperty `
                    -Object $blocker `
                    -Name explanation `
                    -Default '')
            }
        }
    ) | Sort-Object `
        -Property path, startLine, endLine, category, explanation

    $json = $normalised | ConvertTo-Json -Depth 8 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $digest = [System.Security.Cryptography.SHA256]::HashData($bytes)

    return [System.Convert]::ToHexString($digest).ToLowerInvariant()
}

function Get-RepoFlowReviewBlockerRunId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LoopRunId,

        [Parameter(Mandatory)]
        [string]$ScopeHeadSha,

        [Parameter(Mandatory)]
        [string]$Fingerprint
    )

    $scopeToken = $ScopeHeadSha.Substring(
        0,
        [Math]::Min(12, $ScopeHeadSha.Length)
    )

    return "$LoopRunId.blockers.$scopeToken.$Fingerprint"
}

function Test-RepoFlowReviewBlockerFingerprintRecorded {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$LoopRunId,

        [Parameter(Mandatory)]
        [string]$ScopeHeadSha,

        [Parameter(Mandatory)]
        [string]$Fingerprint
    )

    $runId = Get-RepoFlowReviewBlockerRunId `
        -LoopRunId $LoopRunId `
        -ScopeHeadSha $ScopeHeadSha `
        -Fingerprint $Fingerprint

    return $null -ne (Get-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RunId $runId)
}

function Save-RepoFlowReviewBlockerFingerprint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$RepositoryName,

        [Parameter(Mandatory)]
        [string]$RepositorySlug,

        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        [string]$LoopRunId,

        [Parameter(Mandatory)]
        [string]$ScopeHeadSha,

        [Parameter(Mandatory)]
        [string]$Fingerprint
    )

    $runId = Get-RepoFlowReviewBlockerRunId `
        -LoopRunId $LoopRunId `
        -ScopeHeadSha $ScopeHeadSha `
        -Fingerprint $Fingerprint

    if ($null -ne (Get-RepoFlowRunRecord -ConfigPath $ConfigPath -RunId $runId)) {
        return
    }

    Start-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RepositoryRoot $RepositoryRoot `
        -Repository $RepositoryName `
        -RepositorySlug $RepositorySlug `
        -Operation 'pr-review-blockers' `
        -IssueNumber ([int]$Issue.number) `
        -Branch ([string]$PullRequest.headRefName) `
        -PullRequestNumber ([int]$PullRequest.number) `
        -BaseSha $ScopeHeadSha `
        -HeadSha ([string]$PullRequest.headRefOid) `
        -Phase 'review-blockers-recorded' `
        -Provider 'openai-review-bridge' `
        -Model "sha256:$Fingerprint" `
        -RunId $runId |
        Out-Null

    Complete-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RunId $runId `
        -Outcome completed
}
