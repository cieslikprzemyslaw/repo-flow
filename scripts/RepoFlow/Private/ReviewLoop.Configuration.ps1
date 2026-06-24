function Get-RepoFlowPrReviewOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    return [pscustomobject]@{
        RequirePassingCi = ([string]$Config.ci.mode -eq 'require-passing')
        MaxReviewCycles = [int](Get-RepoFlowProperty `
            -Object $Config.reviewFeedback `
            -Name 'maxReviewCycles' `
            -Default 3)
        MaxRepairCycles = [int](Get-RepoFlowProperty `
            -Object $Config.reviewFeedback `
            -Name 'maxRepairCycles' `
            -Default 2)
    }
}

function Get-RepoFlowPrReviewLoopRunId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [ValidateRange(1, 999999999)]
        [int]$PullRequestNumber
    )

    $repositoryToken = (
        $Repository.ToLowerInvariant() -replace '[^a-z0-9]+', '-'
    ).Trim('-')

    return "rf-pr-review-v1-$repositoryToken-pr-$PullRequestNumber"
}

function Get-RepoFlowPrReviewLoopRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [int]$PullRequestNumber
    )

    $runId = Get-RepoFlowPrReviewLoopRunId `
        -Repository $Repository `
        -PullRequestNumber $PullRequestNumber
    $record = Get-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RunId $runId

    if ($null -eq $record) {
        return $null
    }

    if ([string]$record.operation -ne 'pr-review-loop') {
        throw "Run ID '$runId' belongs to a different workflow operation."
    }

    return $record
}

function Get-RepoFlowPrReviewScopeSha {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $RunRecord
    )

    $createdAtUtc = [string](Get-RepoFlowProperty `
        -Object $RunRecord `
        -Name 'createdAtUtc' `
        -Default '')

    if ([string]::IsNullOrWhiteSpace($createdAtUtc)) {
        throw 'PR-review run state is missing createdAtUtc.'
    }

    $binding = '{0}:{1}:{2}' -f
        [string]$RunRecord.runId,
        $createdAtUtc,
        [string]$RunRecord.baseSha
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($binding)
    $digest = [System.Security.Cryptography.SHA256]::HashData($bytes)

    return [System.Convert]::ToHexString($digest).ToLowerInvariant()
}

function Initialize-RepoFlowPrReviewLoopRun {
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
        $Config
    )

    $runId = Get-RepoFlowPrReviewLoopRunId `
        -Repository $RepositorySlug `
        -PullRequestNumber ([int]$PullRequest.number)
    $existing = Get-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RunId $runId
    $currentBase = [string]$PullRequest.baseRefOid
    $currentHead = [string]$PullRequest.headRefOid

    if ($null -ne $existing) {
        if ([string]$existing.operation -ne 'pr-review-loop') {
            throw "Run ID '$runId' belongs to a different workflow operation."
        }

        $sameBase = [string]::Equals(
            [string]$existing.baseSha,
            $currentBase,
            [System.StringComparison]::OrdinalIgnoreCase
        )
        $sameHead = [string]::Equals(
            [string]$existing.headSha,
            $currentHead,
            [System.StringComparison]::OrdinalIgnoreCase
        )
        $sameRevision = $sameBase -and $sameHead

        if (
            [string]$existing.status -eq 'completed' -and
            [string]$existing.currentPhase -eq 'review-passed' -and
            $sameRevision
        ) {
            return [pscustomobject]@{
                Record = $existing
                AlreadyPassed = $true
                Paused = $false
            }
        }

        if ([string]$existing.status -in @('running', 'paused')) {
            if (-not $sameRevision) {
                throw (
                    'An active PR-review loop is bound to a different base/head ' +
                    'revision. Complete or abandon that run before starting another.'
                )
            }

            return [pscustomobject]@{
                Record = $existing
                AlreadyPassed = $false
                Paused = ([string]$existing.status -eq 'paused')
            }
        }
    }

    $record = Start-RepoFlowRunRecord `
        -ConfigPath $ConfigPath `
        -RepositoryRoot $RepositoryRoot `
        -Repository $RepositoryName `
        -RepositorySlug $RepositorySlug `
        -Operation 'pr-review-loop' `
        -IssueNumber ([int]$Issue.number) `
        -Branch ([string]$PullRequest.headRefName) `
        -PullRequestNumber ([int]$PullRequest.number) `
        -BaseSha $currentBase `
        -HeadSha $currentHead `
        -Phase 'review-loop-started' `
        -Provider ([string]$Config.agent.provider) `
        -Model ([string]$Config.agent.model) `
        -RunId $runId

    return [pscustomobject]@{
        Record = $record
        AlreadyPassed = $false
        Paused = $false
    }
}

function Set-RepoFlowPrReviewLoopPaused {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RunId,

        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    Set-RepoFlowRunPaused `
        -ConfigPath $ConfigPath `
        -RunId $RunId `
        -CurrentPhase $Phase `
        -PauseReason $Reason
}
