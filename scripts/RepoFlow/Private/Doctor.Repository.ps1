function ConvertTo-RepoFlowDoctorOrigin {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Origin
    )

    if ([string]::IsNullOrWhiteSpace($Origin)) {
        return ''
    }

    return $Origin.Trim().TrimEnd('/')
}

function Add-RepoFlowDoctorRepositoryChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results,

        [Parameter(Mandatory)]
        $Snapshot,

        [Parameter(Mandatory)]
        $ToolState
    )

    if ($null -eq $Snapshot.Registry) {
        Add-RepoFlowDoctorResult -Results $Results -Status WARN `
            -Group Repositories -Check 'Repository checks' `
            -Details 'Skipped because the repository registry could not be loaded.'
        return
    }

    foreach ($repository in @($Snapshot.Registry.Repositories)) {
        $name = [string]$repository.name
        $path = [string]$repository.localPath
        $group = "Repository:$name"

        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
                -Group $group -Check 'Registered path' `
                -Details "Directory does not exist: $path"
            continue
        }

        Add-RepoFlowDoctorResult -Results $Results -Status PASS `
            -Group $group -Check 'Registered path' `
            -Details $path

        if (-not $ToolState.GitAvailable) {
            Add-RepoFlowDoctorResult -Results $Results -Status WARN `
                -Group $group -Check 'Git repository' `
                -Details 'Skipped because Git is unavailable.'
        }
        else {
            $gitRoot = Invoke-RepoFlowDoctorExternalCommand `
                -Command git `
                -Arguments @('-C', $path, 'rev-parse', '--show-toplevel')

            if ($gitRoot.ExitCode -ne 0) {
                Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
                    -Group $group -Check 'Git repository' `
                    -Details 'The registered path is not a readable Git work tree.'
            }
            else {
                Add-RepoFlowDoctorResult -Results $Results -Status PASS `
                    -Group $group -Check 'Git repository' `
                    -Details $gitRoot.Text

                Add-RepoFlowDoctorGitRepositoryChecks `
                    -Results $Results `
                    -Repository $repository `
                    -Group $group
            }
        }

        if ($ToolState.GitHubAvailable -and $ToolState.GitHubAuthenticated) {
            $permission = Invoke-RepoFlowDoctorExternalCommand `
                -Command gh `
                -Arguments @(
                    'api',
                    "repos/$($repository.slug)",
                    '--jq',
                    '.permissions.push'
                )
            $hasWrite = $permission.ExitCode -eq 0 -and $permission.Text.Trim() -eq 'true'

            Add-RepoFlowDoctorResult -Results $Results `
                -Status $(if ($hasWrite) { 'PASS' } else { 'FAIL' }) `
                -Group $group -Check 'GitHub write access' `
                -Details $(if ($hasWrite) {
                    "Push permission confirmed for $($repository.slug)."
                }
                else {
                    "Push permission could not be confirmed for $($repository.slug)."
                })
        }
        else {
            Add-RepoFlowDoctorResult -Results $Results -Status WARN `
                -Group $group -Check 'GitHub write access' `
                -Details 'Skipped because GitHub CLI authentication is unavailable.'
        }

        $agentsPath = Join-Path $path 'AGENTS.md'
        Add-RepoFlowDoctorResult -Results $Results `
            -Status $(if (Test-Path -LiteralPath $agentsPath -PathType Leaf) { 'PASS' } else { 'WARN' }) `
            -Group $group -Check AGENTS.md `
            -Details $(if (Test-Path -LiteralPath $agentsPath -PathType Leaf) {
                $agentsPath
            }
            else {
                'Root AGENTS.md is missing; the agent will not receive repository-specific rules.'
            })

        Add-RepoFlowDoctorRepositoryFileChecks `
            -Results $Results `
            -Snapshot $Snapshot `
            -Repository $repository `
            -Group $group
    }
}

function Add-RepoFlowDoctorGitRepositoryChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results,

        [Parameter(Mandatory)]
        $Repository,

        [Parameter(Mandatory)]
        [string]$Group
    )

    $path = [string]$Repository.localPath
    $origin = Invoke-RepoFlowDoctorExternalCommand `
        -Command git `
        -Arguments @('-C', $path, 'remote', 'get-url', 'origin')

    if ($origin.ExitCode -ne 0) {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group $Group -Check Origin `
            -Details 'Remote origin is missing or unreadable.'
    }
    else {
        $actualOrigin = ConvertTo-RepoFlowDoctorOrigin -Origin $origin.Text
        $expectedOrigins = @(
            $Repository.expectedOrigins |
            ForEach-Object { ConvertTo-RepoFlowDoctorOrigin -Origin ([string]$_) }
        )
        $originMatches = @(
            $expectedOrigins |
            Where-Object {
                [string]::Equals(
                    $_,
                    $actualOrigin,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            }
        ).Count -gt 0

        Add-RepoFlowDoctorResult -Results $Results `
            -Status $(if ($originMatches) { 'PASS' } else { 'FAIL' }) `
            -Group $Group -Check Origin `
            -Details $(if ($originMatches) {
                $actualOrigin
            }
            else {
                "Actual origin '$actualOrigin' is not one of the configured expected origins."
            })
    }

    $baseBranch = [string]$Repository.baseBranch
    $localBase = Invoke-RepoFlowDoctorExternalCommand `
        -Command git `
        -Arguments @('-C', $path, 'show-ref', '--verify', '--quiet', "refs/heads/$baseBranch")
    $remoteBase = Invoke-RepoFlowDoctorExternalCommand `
        -Command git `
        -Arguments @('-C', $path, 'show-ref', '--verify', '--quiet', "refs/remotes/origin/$baseBranch")
    $baseExists = $localBase.ExitCode -eq 0 -or $remoteBase.ExitCode -eq 0

    if (-not $baseExists) {
        $remoteQuery = Invoke-RepoFlowDoctorExternalCommand `
            -Command git `
            -Arguments @('-C', $path, 'ls-remote', '--exit-code', '--heads', 'origin', $baseBranch)
        $baseExists = $remoteQuery.ExitCode -eq 0
    }

    Add-RepoFlowDoctorResult -Results $Results `
        -Status $(if ($baseExists) { 'PASS' } else { 'FAIL' }) `
        -Group $Group -Check 'Base branch' `
        -Details $(if ($baseExists) {
            "Branch '$baseBranch' is available locally or from origin."
        }
        else {
            "Branch '$baseBranch' was not found locally or on origin."
        })

    $workingTree = Invoke-RepoFlowDoctorExternalCommand `
        -Command git `
        -Arguments @('-C', $path, 'status', '--porcelain')

    if ($workingTree.ExitCode -ne 0) {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group $Group -Check 'Working tree' `
            -Details 'Git status failed.'
    }
    elseif ([string]::IsNullOrWhiteSpace($workingTree.Text)) {
        Add-RepoFlowDoctorResult -Results $Results -Status PASS `
            -Group $Group -Check 'Working tree' `
            -Details 'Clean.'
    }
    else {
        $changeCount = @($workingTree.Text -split '\r?\n' |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count
        Add-RepoFlowDoctorResult -Results $Results -Status WARN `
            -Group $Group -Check 'Working tree' `
            -Details "$changeCount changed path(s); mutation workflows may require a clean tree."
    }
}

function Add-RepoFlowDoctorRepositoryFileChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results,

        [Parameter(Mandatory)]
        $Snapshot,

        [Parameter(Mandatory)]
        $Repository,

        [Parameter(Mandatory)]
        [string]$Group
    )

    $config = $Snapshot.EffectiveConfig

    if ($null -eq $config) {
        Add-RepoFlowDoctorResult -Results $Results -Status WARN `
            -Group $Group -Check 'Workflow files' `
            -Details 'Skipped because the effective configuration is invalid.'
        return
    }

    $root = [string]$Repository.localPath
    $templatePath = Resolve-RepoFlowPath `
        -RepositoryRoot $root `
        -Path ([string]$config.pullRequest.templatePath)

    Add-RepoFlowDoctorResult -Results $Results `
        -Status $(if (Test-Path -LiteralPath $templatePath -PathType Leaf) { 'PASS' } else { 'FAIL' }) `
        -Group $Group -Check 'PR template' `
        -Details $(if (Test-Path -LiteralPath $templatePath -PathType Leaf) {
            $templatePath
        }
        else {
            "Configured pull-request template is missing: $templatePath"
        })

    if (-not (Test-RepoFlowDoctorManifestConfigured -RawConfiguration $Snapshot.Raw)) {
        Add-RepoFlowDoctorResult -Results $Results -Status WARN `
            -Group $Group -Check 'Issue manifest' `
            -Details 'Not configured; issue sync diagnostics were skipped.'
        return
    }

    $manifestPath = Resolve-RepoFlowPath `
        -RepositoryRoot $root `
        -Path ([string]$config.issues.manifestPath)

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group $Group -Check 'Issue manifest' `
            -Details "Configured issue manifest is missing: $manifestPath"
        return
    }

    try {
        Get-Content -LiteralPath $manifestPath -Raw |
            ConvertFrom-Json -ErrorAction Stop |
            Out-Null
        Add-RepoFlowDoctorResult -Results $Results -Status PASS `
            -Group $Group -Check 'Issue manifest' `
            -Details $manifestPath
    }
    catch {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group $Group -Check 'Issue manifest' `
            -Details "Configured issue manifest contains invalid JSON: $manifestPath"
    }
}
