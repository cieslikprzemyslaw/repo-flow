function Test-RepoFlowDoctorCommandAvailable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    return $null -ne (Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Invoke-RepoFlowDoctorExternalCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    return Invoke-RepoFlowCommand `
        -Command $Command `
        -Arguments $Arguments `
        -AllowFailure
}

function Get-RepoFlowDoctorPowerShellVersion {
    [CmdletBinding()]
    param()

    return $PSVersionTable.PSVersion
}

function Get-RepoFlowDoctorPesterVersion {
    [CmdletBinding()]
    param()

    $module = Get-Module -ListAvailable -Name Pester |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $module) {
        return $null
    }

    return $module.Version
}

function Get-RepoFlowDoctorAgentVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Provider,

        [Parameter(Mandatory)]
        [string]$Command
    )

    return Get-RepoFlowAgentCliVersion `
        -Provider $Provider `
        -Command $Command
}

function Add-RepoFlowDoctorRuntimeChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results
    )

    $powerShellVersion = Get-RepoFlowDoctorPowerShellVersion

    $powerShellSupported = (
        $powerShellVersion.Major -gt 7 -or
        (
            $powerShellVersion.Major -eq 7 -and
            $powerShellVersion.Minor -ge 2
        )
    )

    if ($powerShellSupported) {
        Add-RepoFlowDoctorResult -Results $Results -Status PASS `
            -Group Runtime -Check PowerShell `
            -Details "Version $powerShellVersion (minimum 7.2)."
    }
    else {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group Runtime -Check PowerShell `
            -Details "Version $powerShellVersion is below the required 7.2."
    }

    $pesterVersion = Get-RepoFlowDoctorPesterVersion

    if ($null -eq $pesterVersion) {
        Add-RepoFlowDoctorResult -Results $Results -Status WARN `
            -Group Runtime -Check Pester `
            -Details 'Pester 5+ is not installed; workflows can run, but the RepoFlow test suite cannot.'
    }
    elseif ($pesterVersion -ge [version]'5.0.0') {
        Add-RepoFlowDoctorResult -Results $Results -Status PASS `
            -Group Runtime -Check Pester `
            -Details "Version $pesterVersion."
    }
    else {
        Add-RepoFlowDoctorResult -Results $Results -Status WARN `
            -Group Runtime -Check Pester `
            -Details "Version $pesterVersion is below the recommended 5.0.0."
    }
}

function Add-RepoFlowDoctorConfigurationChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results,

        [Parameter(Mandatory)]
        $Snapshot
    )

    if ($null -ne $Snapshot.DocumentError) {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group Configuration -Check 'Configuration file' `
            -Details ([string]$Snapshot.DocumentError)
        return
    }

    Add-RepoFlowDoctorResult -Results $Results -Status PASS `
        -Group Configuration -Check 'Configuration file' `
        -Details ([string]$Snapshot.ConfigPath)

    if ($null -ne $Snapshot.RegistryError) {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group Configuration -Check 'Repository registry' `
            -Details ([string]$Snapshot.RegistryError)
        return
    }

    Add-RepoFlowDoctorResult -Results $Results -Status PASS `
        -Group Configuration -Check 'Repository registry' `
        -Details ("{0} registered repository/repositories." -f @($Snapshot.Registry.Repositories).Count)

    if ($null -ne $Snapshot.SelectionError) {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group Configuration -Check 'Repository selection' `
            -Details ([string]$Snapshot.SelectionError)
    }
    elseif ($null -ne $Snapshot.Selection) {
        Add-RepoFlowDoctorResult -Results $Results -Status PASS `
            -Group Configuration -Check 'Repository selection' `
            -Details ("{0} ({1})." -f $Snapshot.Selection.Repository.name, $Snapshot.Selection.Source)
    }

    if ($null -ne $Snapshot.ConfigurationError) {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group Configuration -Check 'Configuration schema' `
            -Details ([string]$Snapshot.ConfigurationError)
    }
    elseif ($null -ne $Snapshot.EffectiveConfig) {
        Add-RepoFlowDoctorResult -Results $Results -Status PASS `
            -Group Configuration -Check 'Configuration schema' `
            -Details 'Effective configuration passed RepoFlow validation.'
    }
}

function Add-RepoFlowDoctorStateCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results,

        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath

    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        Add-RepoFlowDoctorResult -Results $Results -Status PASS `
            -Group State -Check 'Local state' `
            -Details 'No state file exists yet; this is valid before the first persisted selection or run.'
        return
    }

    try {
        $state = Read-RepoFlowStateDocument -ConfigPath $ConfigPath
        Add-RepoFlowDoctorResult -Results $Results -Status PASS `
            -Group State -Check 'Local state' `
            -Details ("Readable schema v{0}; {1} run record(s)." -f $state.schemaVersion, @($state.runs).Count)
    }
    catch {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group State -Check 'Local state' `
            -Details $_.Exception.Message
    }
}

function Add-RepoFlowDoctorToolChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results,

        [Parameter(Mandatory)]
        $Snapshot
    )

    $gitAvailable = Test-RepoFlowDoctorCommandAvailable -Name git

    if ($gitAvailable) {
        $gitVersion = Invoke-RepoFlowDoctorExternalCommand `
            -Command git `
            -Arguments @('--version')

        if ($gitVersion.ExitCode -eq 0) {
            Add-RepoFlowDoctorResult -Results $Results -Status PASS `
                -Group Tools -Check Git `
                -Details $gitVersion.Text
        }
        else {
            Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
                -Group Tools -Check Git `
                -Details 'Git exists but its version command failed.'
        }
    }
    else {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group Tools -Check Git `
            -Details 'Required command was not found.'
    }

    $ghAvailable = Test-RepoFlowDoctorCommandAvailable -Name gh
    $ghAuthenticated = $false

    if ($ghAvailable) {
        $auth = Invoke-RepoFlowDoctorExternalCommand `
            -Command gh `
            -Arguments @('auth', 'status')
        $ghAuthenticated = $auth.ExitCode -eq 0

        Add-RepoFlowDoctorResult -Results $Results `
            -Status $(if ($ghAuthenticated) { 'PASS' } else { 'FAIL' }) `
            -Group Tools -Check 'GitHub CLI' `
            -Details $(if ($ghAuthenticated) {
                'Available and authenticated.'
            }
            else {
                'Available, but gh auth status failed. Run gh auth login.'
            })
    }
    else {
        Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
            -Group Tools -Check 'GitHub CLI' `
            -Details 'Required command gh was not found.'
    }

    $agentAvailable = $false
    $config = $Snapshot.EffectiveConfig

    if ($null -eq $config) {
        Add-RepoFlowDoctorResult -Results $Results -Status WARN `
            -Group Agent -Check 'Command and model' `
            -Details 'Skipped because the effective configuration is invalid.'
    }
    else {
        $provider = [string]$config.agent.provider
        $command = [string]$config.agent.command
        $model = [string]$config.agent.model
        $agentAvailable = Test-RepoFlowDoctorCommandAvailable -Name $command

        if (-not $agentAvailable) {
            Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
                -Group Agent -Check 'Command and model' `
                -Details "$provider command '$command' was not found; configured model is '$model'."
        }
        else {
            try {
                $versionInfo = Get-RepoFlowDoctorAgentVersion `
                    -Provider $provider `
                    -Command $command
                Add-RepoFlowDoctorResult -Results $Results -Status PASS `
                    -Group Agent -Check 'Command and model' `
                    -Details "$provider $($versionInfo.Version), model '$model'."

                $minimum = [string]$config.agent.minimumCliVersion

                if ([string]::IsNullOrWhiteSpace($minimum)) {
                    Add-RepoFlowDoctorResult -Results $Results -Status WARN `
                        -Group Agent -Check 'Minimum CLI version' `
                        -Details 'Not configured; version compatibility is not enforced.'
                }
                elseif (Test-RepoFlowSemanticVersionAtLeast `
                    -InstalledVersion ([string]$versionInfo.Version) `
                    -MinimumVersion $minimum
                ) {
                    Add-RepoFlowDoctorResult -Results $Results -Status PASS `
                        -Group Agent -Check 'Minimum CLI version' `
                        -Details "Installed $($versionInfo.Version) satisfies $minimum."
                }
                else {
                    Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
                        -Group Agent -Check 'Minimum CLI version' `
                        -Details "Installed $($versionInfo.Version) is below $minimum."
                }
            }
            catch {
                Add-RepoFlowDoctorResult -Results $Results -Status FAIL `
                    -Group Agent -Check 'Command and model' `
                    -Details $_.Exception.Message
            }
        }
    }

    return [pscustomobject]@{
        GitAvailable = $gitAvailable
        GitHubAvailable = $ghAvailable
        GitHubAuthenticated = $ghAuthenticated
        AgentAvailable = $agentAvailable
    }
}
