function Read-RepoFlowIssueManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        $Config
    )

    $manifestPath = Resolve-RepoFlowPath `
        -RepositoryRoot $RepositoryRoot `
        -Path ([string]$Config.issues.manifestPath)

    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Issue manifest was not found: $manifestPath"
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "Issue manifest contains invalid JSON: $manifestPath"
    }

    Assert-RepoFlowAllowedProperties -Object $manifest -Path '$manifest' -Allowed @(
        'repository',
        'managedLabelPrefixes',
        'requiredLabels',
        'milestones',
        'updates',
        'creates'
    )

    if ([string]$manifest.repository -ne [string]$Config.repository.slug) {
        throw "Issue manifest repository '$($manifest.repository)' does not match RepoFlow configuration '$($Config.repository.slug)'."
    }

    return [pscustomobject]@{
        path = $manifestPath
        data = $manifest
    }
}

function Get-RepoFlowManagedLabelNames {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Issue,

        [Parameter(Mandatory)]
        [string[]]$ManagedPrefixes
    )

    $managed = foreach ($label in @($Issue.labels)) {
        $name = [string]$label.name
        $matchesPrefix = $false

        foreach ($prefix in $ManagedPrefixes) {
            if ($name.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matchesPrefix = $true
                break
            }
        }

        if ($matchesPrefix -or $name -eq 'good first issue') {
            $name
        }
    }

    return @($managed)
}

function Invoke-RepoFlowIssueSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        $Config,

        [switch]$Apply,

        [switch]$SkipCreates
    )

    $manifestResult = Read-RepoFlowIssueManifest -RepositoryRoot $RepositoryRoot -Config $Config
    $manifest = $manifestResult.data
    $repository = [string]$Config.repository.slug
    $mode = if ($Apply) { 'APPLY' } else { 'DRY RUN' }

    Write-Host "Repository: $repository"
    Write-Host "Manifest:   $($manifestResult.path)"
    Write-Host "Mode:       $mode"
    Write-Host ''

    $labelsResult = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'label',
        'list',
        '--repo',
        $repository,
        '--limit',
        '500',
        '--json',
        'name'
    )
    $currentLabelNames = @($labelsResult.Data | ForEach-Object { [string]$_.name })

    foreach ($label in @($manifest.requiredLabels)) {
        if ($currentLabelNames -notcontains [string]$label) {
            throw "Required label does not exist: $label"
        }
    }

    $milestoneResult = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'api',
        "repos/$repository/milestones?state=all&per_page=100"
    )
    $currentMilestones = @($milestoneResult.Data)

    foreach ($wanted in @($manifest.milestones)) {
        $existing = $currentMilestones |
            Where-Object { $_.title -eq $wanted.title } |
            Select-Object -First 1

        if ($existing) {
            Write-Host "[OK] milestone exists: $($wanted.title)"
            continue
        }

        Write-Host "[CREATE] milestone: $($wanted.title)"

        if ($Apply) {
            $payloadPath = [System.IO.Path]::GetTempFileName()

            try {
                @{
                    title = [string]$wanted.title
                    description = [string]$wanted.description
                    state = [string]$wanted.state
                } |
                    ConvertTo-Json -Compress |
                    Set-Content -LiteralPath $payloadPath -Encoding utf8

                $created = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
                    'api',
                    "repos/$repository/milestones",
                    '--method',
                    'POST',
                    '--input',
                    $payloadPath
                )

                $currentMilestones += $created.Data
            }
            finally {
                Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $issuesResult = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'issue',
        'list',
        '--repo',
        $repository,
        '--state',
        'all',
        '--limit',
        '500',
        '--json',
        'number,title,body,state,labels,milestone'
    )
    $allIssues = @($issuesResult.Data)
    $openByNumber = @{}
    $titleLookup = @{}

    foreach ($issue in $allIssues) {
        if ($issue.state -eq 'OPEN') {
            $openByNumber[[int]$issue.number] = $issue
        }

        if (-not $titleLookup.ContainsKey([string]$issue.title)) {
            $titleLookup[[string]$issue.title] = $issue
        }
    }

    $managedPrefixes = @($manifest.managedLabelPrefixes | ForEach-Object { [string]$_ })

    foreach ($wanted in @($manifest.updates)) {
        $number = [int]$wanted.number

        if (-not $openByNumber.ContainsKey($number)) {
            throw "Open issue #$number was not found. Refusing to continue."
        }

        $current = $openByNumber[$number]
        $wantedLabels = @($wanted.labels | ForEach-Object { [string]$_ })
        $currentManaged = @(Get-RepoFlowManagedLabelNames -Issue $current -ManagedPrefixes $managedPrefixes)
        $removeLabels = @($currentManaged | Where-Object { $wantedLabels -notcontains $_ })
        $addLabels = @($wantedLabels | Where-Object { $currentManaged -notcontains $_ })
        $currentMilestoneTitle = if ($current.milestone) { [string]$current.milestone.title } else { $null }
        $wantedMilestoneTitle = if ($null -ne $wanted.milestone) { [string]$wanted.milestone } else { $null }
        $changes = New-Object System.Collections.Generic.List[string]

        if ([string]$current.title -ne [string]$wanted.title) { $changes.Add('title') }
        if ([string]$current.body -ne [string]$wanted.body) { $changes.Add('body') }
        if ($currentMilestoneTitle -ne $wantedMilestoneTitle) { $changes.Add('milestone') }
        if ($addLabels.Count -gt 0 -or $removeLabels.Count -gt 0) { $changes.Add('labels') }

        if ($changes.Count -eq 0) {
            Write-Host "[OK] #$number $($wanted.title)"
            continue
        }

        Write-Host "[UPDATE] #$number $($wanted.title) [$($changes -join ', ')]"

        if (-not $Apply) {
            if ($addLabels.Count -gt 0) { Write-Host "  + labels: $($addLabels -join ', ')" }
            if ($removeLabels.Count -gt 0) { Write-Host "  - labels: $($removeLabels -join ', ')" }
            if ($currentMilestoneTitle -ne $wantedMilestoneTitle) {
                Write-Host "  milestone: '$currentMilestoneTitle' -> '$wantedMilestoneTitle'"
            }
            continue
        }

        $bodyPath = [System.IO.Path]::GetTempFileName()

        try {
            Set-Content -LiteralPath $bodyPath -Value ([string]$wanted.body) -Encoding utf8
            $arguments = @(
                'issue',
                'edit',
                $number.ToString(),
                '--repo',
                $repository,
                '--title',
                [string]$wanted.title,
                '--body-file',
                $bodyPath
            )

            if ($wantedMilestoneTitle) {
                $arguments += @('--milestone', $wantedMilestoneTitle)
            }
            elseif ($currentMilestoneTitle) {
                $arguments += '--remove-milestone'
            }

            foreach ($label in $addLabels) { $arguments += @('--add-label', $label) }
            foreach ($label in $removeLabels) { $arguments += @('--remove-label', $label) }
            Invoke-RepoFlowCommand -Command 'gh' -Arguments $arguments | Out-Null
        }
        finally {
            Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $SkipCreates) {
        foreach ($wanted in @($manifest.creates)) {
            if ($titleLookup.ContainsKey([string]$wanted.title)) {
                $existing = $titleLookup[[string]$wanted.title]
                Write-Host "[OK] issue title exists as #$($existing.number) ($($existing.state)): $($wanted.title)"
                continue
            }

            Write-Host "[CREATE] issue: $($wanted.title)"

            if (-not $Apply) {
                continue
            }

            $bodyPath = [System.IO.Path]::GetTempFileName()

            try {
                Set-Content -LiteralPath $bodyPath -Value ([string]$wanted.body) -Encoding utf8
                $arguments = @(
                    'issue',
                    'create',
                    '--repo',
                    $repository,
                    '--title',
                    [string]$wanted.title,
                    '--body-file',
                    $bodyPath
                )

                foreach ($label in @($wanted.labels)) {
                    $arguments += @('--label', [string]$label)
                }

                if ($wanted.milestone) {
                    $arguments += @('--milestone', [string]$wanted.milestone)
                }

                Invoke-RepoFlowCommand -Command 'gh' -Arguments $arguments | Out-Null
            }
            finally {
                Remove-Item -LiteralPath $bodyPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host ''

    if ($Apply) {
        Write-Host 'Issue manifest synchronisation completed.'
    }
    else {
        Write-Host 'Dry run completed. No GitHub data was changed.'
        Write-Host 'Run again with -Apply to apply this plan.'
    }
}
