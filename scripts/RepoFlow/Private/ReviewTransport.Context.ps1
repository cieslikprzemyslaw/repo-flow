function Get-RepoFlowAutomatedReviewRequestId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 999999999)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [ValidatePattern('^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$')]
        [string]$BaseSha,

        [Parameter(Mandatory)]
        [ValidatePattern('^(?:[0-9A-Fa-f]{40}|[0-9A-Fa-f]{64})$')]
        [string]$HeadSha
    )

    $binding = '{0}:{1}:{2}' -f
        $PullRequestNumber,
        $BaseSha.ToLowerInvariant(),
        $HeadSha.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($binding)
    $digest = [System.Security.Cryptography.SHA256]::HashData($bytes)
    $token = [System.Convert]::ToHexString($digest).ToLowerInvariant()

    return 'rf-review-v1-pr-{0}-{1}' -f $PullRequestNumber, $token
}

function Get-RepoFlowAutomatedReviewAcceptanceCriteria {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$IssueBody
    )

    $section = Get-RepoFlowMarkdownSection `
        -Body $IssueBody `
        -Heading 'Acceptance criteria'
    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($line in @($section -split '\r?\n')) {
        $trimmed = $line.Trim()

        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }

        $match = [regex]::Match(
            $trimmed,
            '^(?:[-*+]\s+(?:\[[ xX]\]\s*)?|\d+[.)]\s+)(?<text>.+)$'
        )

        if ($match.Success) {
            $candidates.Add($match.Groups['text'].Value.Trim())
        }
    }

    if ($candidates.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($section)) {
        foreach ($line in @($section -split '\r?\n')) {
            $trimmed = $line.Trim()

            if (
                -not [string]::IsNullOrWhiteSpace($trimmed) -and
                -not $trimmed.StartsWith('```')
            ) {
                $candidates.Add($trimmed)
            }
        }
    }

    if ($candidates.Count -eq 0) {
        $candidates.Add('Review the linked issue acceptance criteria.')
    }

    $values = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $truncated = $false

    foreach ($candidate in $candidates) {
        if ($values.Count -ge 100) {
            $truncated = $true
            break
        }

        $value = [string]$candidate

        if ($value.Length -gt 1000) {
            $value = $value.Substring(0, 1000).TrimEnd()
            $truncated = $true
        }

        if ($seen.Add($value)) {
            $values.Add($value)
        }
    }

    return [pscustomobject]@{
        Values = $values.ToArray()
        Truncated = $truncated
    }
}

function ConvertTo-RepoFlowAutomatedReviewCheckStatus {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Bucket
    )

    switch (([string]$Bucket).ToLowerInvariant()) {
        'pass' { return 'passing' }
        'fail' { return 'failing' }
        'cancel' { return 'failing' }
        'pending' { return 'pending' }
        'skipping' { return 'skipped' }
        default { return 'unknown' }
    }
}

function ConvertTo-RepoFlowAutomatedReviewOverallCiStatus {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Status
    )

    switch (([string]$Status).ToLowerInvariant()) {
        'passed' { return 'passing' }
        'failed' { return 'failing' }
        'pending' { return 'pending' }
        'skipped' { return 'not_run' }
        default { return 'unknown' }
    }
}

function New-RepoFlowAutomatedReviewRequestEnvelope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        $PullRequest,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$ChangedFiles,

        [Parameter(Mandatory)]
        $CheckState,

        [AllowNull()]
        [string]$CreatedAtUtc
    )

    $requestId = Get-RepoFlowAutomatedReviewRequestId `
        -PullRequestNumber ([int]$PullRequest.number) `
        -BaseSha ([string]$PullRequest.baseRefOid) `
        -HeadSha ([string]$PullRequest.headRefOid)
    $criteria = Get-RepoFlowAutomatedReviewAcceptanceCriteria `
        -IssueBody ([string]$Issue.body)
    $boundedFiles = [System.Collections.Generic.List[object]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    $filesTruncated = $false

    foreach ($file in @($ChangedFiles)) {
        if ($boundedFiles.Count -ge 500) {
            $filesTruncated = $true
            break
        }

        $path = [string](Get-RepoFlowProperty `
            -Object $file `
            -Name 'filename' `
            -Default (Get-RepoFlowProperty -Object $file -Name 'path' -Default ''))

        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if ($path.Length -gt 1024) {
            throw "Changed-file path exceeds the review-contract limit: $path"
        }

        if (-not $seenPaths.Add($path)) {
            continue
        }

        $rawStatus = [string](Get-RepoFlowProperty `
            -Object $file `
            -Name 'status' `
            -Default 'unknown')
        $status = if ($rawStatus -in @(
            'added',
            'modified',
            'removed',
            'renamed',
            'copied',
            'changed'
        )) {
            $rawStatus
        }
        else {
            'unknown'
        }

        $boundedFiles.Add([pscustomobject][ordered]@{
            path = $path
            status = $status
        })
    }

    if ($boundedFiles.Count -eq 0) {
        throw 'Automated review requires at least one changed file.'
    }

    $boundedChecks = [System.Collections.Generic.List[object]]::new()
    $checksTruncated = $false

    foreach ($check in @($CheckState.Checks)) {
        if ($boundedChecks.Count -ge 100) {
            $checksTruncated = $true
            break
        }

        $name = [string](Get-RepoFlowProperty -Object $check -Name 'name' -Default 'Unknown check')
        if ($name.Length -gt 200) {
            $name = $name.Substring(0, 200).TrimEnd()
            $checksTruncated = $true
        }

        $bucket = [string](Get-RepoFlowProperty -Object $check -Name 'bucket' -Default 'unknown')
        $summary = "GitHub check bucket: $bucket."

        $boundedChecks.Add([pscustomobject][ordered]@{
            name = $name
            status = ConvertTo-RepoFlowAutomatedReviewCheckStatus -Bucket $bucket
            summary = $summary
        })
    }

    $overallStatus = ConvertTo-RepoFlowAutomatedReviewOverallCiStatus `
        -Status ([string]$CheckState.Status)
    $ciSummaryText = if ($boundedChecks.Count -eq 0) {
        'No GitHub checks were reported for the current pull-request head.'
    }
    else {
        '{0} GitHub check(s) reported; overall status: {1}.' -f `
            $boundedChecks.Count,
            $overallStatus
    }

    $effectiveCreatedAtUtc = if ([string]::IsNullOrWhiteSpace($CreatedAtUtc)) {
        [DateTimeOffset]::UtcNow.ToString('o')
    }
    else {
        $CreatedAtUtc
    }

    $request = [pscustomobject][ordered]@{
        contractVersion = '1'
        kind = 'review_request'
        requestId = $requestId
        repository = $Repository
        issue = [pscustomobject][ordered]@{
            number = [int]$Issue.number
            url = [string]$Issue.url
        }
        pullRequest = [pscustomobject][ordered]@{
            number = [int]$PullRequest.number
            url = [string]$PullRequest.url
        }
        baseSha = [string]$PullRequest.baseRefOid
        headSha = [string]$PullRequest.headRefOid
        acceptanceCriteria = @($criteria.Values)
        sourceLinks = @(
            [string]$Issue.url
            [string]$PullRequest.url
        )
        changedFiles = $boundedFiles.ToArray()
        ciSummary = [pscustomobject][ordered]@{
            status = $overallStatus
            summary = $ciSummaryText
            checks = $boundedChecks.ToArray()
        }
        truncation = [pscustomobject][ordered]@{
            acceptanceCriteria = [bool]$criteria.Truncated
            sourceLinks = $false
            changedFiles = $filesTruncated
            ciSummary = $checksTruncated
        }
        createdAtUtc = $effectiveCreatedAtUtc
    }

    Assert-RepoFlowReviewRequestEnvelope -Request $request
    return $request
}
