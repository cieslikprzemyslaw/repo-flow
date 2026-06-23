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

        $runLines = @(
            $logResult.Text -split '\r?\n' |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^Run\s+' } |
            Select-Object -First 1
        )

        $stepName = $null
        $command = $null

        if ($runLines.Count -gt 0) {
            $stepName = [string]$runLines[0]

            if ($stepName.Length -gt 4) {
                $command = $stepName.Substring(4).Trim()
            }
        }

        $diagnostics = @(
            Get-RepoFlowCiDiagnostics `
                -Text $logResult.Text `
                -CheckName $checkName `
                -StepName $stepName `
                -Command $command
        )

        if ($diagnostics.Count -eq 0) {
            $content.Add('### Raw failed log fallback')
            $content.Add('')
            $content.Add('```text')
            $content.Add(
                (Get-RepoFlowBoundedText `
                    -Text $logResult.Text `
                    -MaximumCharacters 24000 `
                    -HeadCharacters 4000)
            )
            $content.Add('```')
            $content.Add('')
            continue
        }

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
        $content.Add(
            [string](
                ConvertTo-Json `
                    -InputObject $diagnostics `
                    -Depth 8
            )
        )
        $content.Add('```')
        $content.Add('')

        $knownDiagnostics = @(
            $diagnostics |
            Where-Object {
                [string]$_.Category -ne 'infrastructure/unknown'
            }
        )

        if ($knownDiagnostics.Count -eq 0) {
            $content.Add('### Raw failed log fallback')
            $content.Add('')
            $content.Add('```text')
            $content.Add(
                (Get-RepoFlowBoundedText `
                    -Text $logResult.Text `
                    -MaximumCharacters 24000 `
                    -HeadCharacters 4000)
            )
            $content.Add('```')
            $content.Add('')
        }
    }

    Set-Content `
        -LiteralPath $OutputPath `
        -Value $content `
        -Encoding utf8
}
