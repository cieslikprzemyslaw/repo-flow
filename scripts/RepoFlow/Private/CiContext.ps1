function Write-RepoFlowFailedCiContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$IssueNumber,

        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        $Checks,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$BaseBranch,

        [Parameter(Mandatory)]
        [string]$OutputPath
    )

    $failedChecks = @(
        $Checks |
        Where-Object { $_.bucket -in @('fail', 'cancel') }
    )

    $checkCount = [Math]::Max(1, $failedChecks.Count)
    $rawBudgetPerCheck = [Math]::Max(
        256,
        [Math]::Floor(24000 / $checkCount)
    )
    $rawHeadPerCheck = [Math]::Min(
        4000,
        [Math]::Floor($rawBudgetPerCheck / 2)
    )

    $content = [System.Collections.Generic.List[string]]::new()
    $content.Add('# Failed CI checks')
    $content.Add('')
    $content.Add("PR: #$PullRequestNumber")
    $content.Add("Issue: #$IssueNumber")
    $content.Add('')
    $content.Add('## Files changed by this pull request')
    $content.Add('')
    $content.Add(
        (Format-RepoFlowChangedFiles `
            -Files (
                Get-RepoFlowPullRequestChangedFiles `
                    -BaseBranch $BaseBranch
            ))
    )
    $content.Add('')

    foreach ($check in $failedChecks) {
        $checkName = [string]$check.name
        $checkLink = [string]$check.link

        $content.Add("## $checkName")
        $content.Add('')
        $content.Add("Link: $checkLink")
        $content.Add('')

        if ($checkLink -notmatch '/actions/runs/(?<runId>\d+)') {
            $content.Add('No GitHub Actions run ID was available for this check.')
            $content.Add('')
            continue
        }

        $runId = $Matches['runId']
        $logResult = Invoke-RepoFlowCommand -Command 'gh' -Arguments @(
            'run',
            'view',
            $runId,
            '--repo',
            $Repository,
            '--log-failed'
        ) -AllowFailure

        if ([string]::IsNullOrWhiteSpace($logResult.Text)) {
            $content.Add('No failed log output was available.')
            $content.Add('')
            continue
        }

        $cleanLogText = ConvertTo-RepoFlowCiNormalisedText -Text $logResult.Text
        $diagnostics = @(
            Get-RepoFlowCiDiagnostics `
                -Text $cleanLogText `
                -CheckName $checkName `
                -MaximumRawCharacters ([Math]::Min(4000, $rawBudgetPerCheck)) `
                -HeadCharacters ([Math]::Min(2000, $rawHeadPerCheck))
        )

        if ($diagnostics.Count -gt 0) {
            $content.Add('### Structured diagnostics')
            $content.Add('')
            $content.Add(
                (Format-RepoFlowCiDiagnostics `
                    -Diagnostics $diagnostics)
            )
            $content.Add('')
            $content.Add('### Machine-readable diagnostics')
            $content.Add('')
            $content.Add('```json')

            $machineDiagnostics = @(
                $diagnostics |
                Select-Object `
                    Category,
                    CheckName,
                    StepName,
                    Command,
                    Project,
                    Suite,
                    TestFile,
                    TestName,
                    Summary,
                    Expected,
                    Received,
                    SourcePath,
                    SourceLine,
                    Stack
            )

            $content.Add(
                [string](
                    ConvertTo-Json `
                        -InputObject $machineDiagnostics `
                        -Depth 8
                )
            )
            $content.Add('```')
            $content.Add('')
        }

        $knownDiagnostics = @(
            $diagnostics |
            Where-Object {
                [string]$_.Category -ne 'infrastructure/unknown'
            }
        )

        if ($diagnostics.Count -eq 0 -or $knownDiagnostics.Count -eq 0) {
            $rawHeading = '### Raw failed log fallback'
        }
        else {
            $rawHeading = '### Bounded raw context'
        }

        $content.Add($rawHeading)
        $content.Add('')
        $content.Add('```text')
        $content.Add(
            (Get-RepoFlowBoundedText `
                -Text $cleanLogText `
                -MaximumCharacters $rawBudgetPerCheck `
                -HeadCharacters $rawHeadPerCheck)
        )
        $content.Add('```')
        $content.Add('')
    }

    Set-Content `
        -LiteralPath $OutputPath `
        -Value $content `
        -Encoding utf8
}
