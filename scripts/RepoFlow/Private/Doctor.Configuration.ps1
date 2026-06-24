function Get-RepoFlowDoctorConfigurationSnapshot {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Repo
    )

    $resolvedPath = Resolve-RepoFlowConfigPath -ConfigPath $ConfigPath
    $snapshot = [pscustomobject][ordered]@{
        ConfigPath = $resolvedPath
        Document = $null
        Raw = $null
        Registry = $null
        Selection = $null
        EffectiveConfig = $null
        DocumentError = $null
        RegistryError = $null
        SelectionError = $null
        ConfigurationError = $null
    }

    try {
        $snapshot.Document = Get-RepoFlowConfigurationDocument `
            -ConfigPath $resolvedPath
        $snapshot.Raw = $snapshot.Document.Raw
    }
    catch {
        $snapshot.DocumentError = $_.Exception.Message
        return $snapshot
    }

    try {
        $snapshot.Registry = Get-RepoFlowRepositoryRegistry `
            -ConfigPath $resolvedPath
    }
    catch {
        $snapshot.RegistryError = $_.Exception.Message
        return $snapshot
    }

    try {
        $snapshot.Selection = Get-RepoFlowRepositorySelection `
            -ConfigPath $resolvedPath `
            -RepositoryName $Repo
    }
    catch {
        $snapshot.SelectionError = $_.Exception.Message
        $snapshot.Selection = Get-RepoFlowDoctorFallbackSelection `
            -Registry $snapshot.Registry `
            -Repo $Repo
    }

    if ($null -eq $snapshot.Selection) {
        if ([string]::IsNullOrWhiteSpace([string]$snapshot.SelectionError)) {
            $snapshot.SelectionError = 'No target repository could be selected.'
        }

        return $snapshot
    }

    try {
        $snapshot.EffectiveConfig = Read-RepoFlowConfiguration `
            -RepositoryRoot ([string]$snapshot.Selection.RepositoryRoot) `
            -ConfigPath $resolvedPath `
            -RepositorySelection $snapshot.Selection
    }
    catch {
        $snapshot.ConfigurationError = $_.Exception.Message
    }

    return $snapshot
}

function Get-RepoFlowDoctorFallbackSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Registry,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Repo
    )

    $selected = $null
    $source = 'fallback'

    if (-not [string]::IsNullOrWhiteSpace($Repo)) {
        $selected = Find-RepoFlowRepositoryByName `
            -Repositories @($Registry.Repositories) `
            -Name $Repo
        $source = 'explicit-fallback'
    }
    elseif ([bool]$Registry.IsLegacy) {
        $selected = @($Registry.Repositories) | Select-Object -First 1
        $source = 'legacy-fallback'
    }
    else {
        $currentDirectory = (Get-Location).Path
        $selected = @(
            $Registry.Repositories |
            Where-Object {
                Test-RepoFlowPathWithinRepository `
                    -RepositoryPath ([string]$_.localPath) `
                    -CandidatePath $currentDirectory
            } |
            Sort-Object `
                -Property @{ Expression = { ([string]$_.localPath).Length } } `
                -Descending
        ) | Select-Object -First 1

        if ($null -ne $selected) {
            $source = 'current-directory-fallback'
        }
        else {
            $selected = Find-RepoFlowRepositoryByName `
                -Repositories @($Registry.Repositories) `
                -Name ([string]$Registry.DefaultRepository)
            $source = 'default-fallback'
        }
    }

    if ($null -eq $selected) {
        return $null
    }

    return [pscustomobject]@{
        Registry = $Registry
        Repository = $selected
        RepositoryRoot = [string]$selected.localPath
        Source = $source
    }
}

function Test-RepoFlowDoctorManifestConfigured {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $RawConfiguration
    )

    if ($null -eq $RawConfiguration) {
        return $false
    }

    $issuesProperty = $RawConfiguration.PSObject.Properties['issues']

    if ($null -eq $issuesProperty -or $null -eq $issuesProperty.Value) {
        return $false
    }

    $manifestProperty = $issuesProperty.Value.PSObject.Properties['manifestPath']

    return (
        $null -ne $manifestProperty -and
        -not [string]::IsNullOrWhiteSpace([string]$manifestProperty.Value)
    )
}
