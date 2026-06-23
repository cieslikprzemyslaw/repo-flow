function Get-RepoFlowConfigurationDocument {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $resolvedConfigPath = Resolve-RepoFlowConfigPath -ConfigPath $ConfigPath

    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "RepoFlow configuration was not found: $resolvedConfigPath"
    }

    try {
        $raw = Get-Content -LiteralPath $resolvedConfigPath -Raw |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "RepoFlow configuration contains invalid JSON: $resolvedConfigPath"
    }

    return [pscustomobject]@{
        ConfigPath = $resolvedConfigPath
        Raw = $raw
    }
}

function Resolve-RepoFlowRegisteredPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$LocalPath
    )

    if ([System.IO.Path]::IsPathRooted($LocalPath)) {
        return [System.IO.Path]::GetFullPath($LocalPath)
    }

    $configDirectory = Split-Path -Parent $ConfigPath

    return [System.IO.Path]::GetFullPath(
        (Join-Path $configDirectory $LocalPath)
    )
}

function Get-RepoFlowStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    return Join-Path (Split-Path -Parent $ConfigPath) '.repo-flow.state.json'
}

function Get-RepoFlowRepositoryStatePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    return Get-RepoFlowStatePath -ConfigPath $ConfigPath
}

function Open-RepoFlowStateLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$StatePath
    )

    $lockPath = "$StatePath.lock"

    try {
        return [System.IO.FileStream]::new(
            $lockPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None,
            1,
            [System.IO.FileOptions]::DeleteOnClose
        )
    }
    catch {
        throw (
            'RepoFlow state is busy and could not be locked for an atomic ' +
            "update: $StatePath"
        )
    }
}

function New-RepoFlowStateDocument {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$ActiveRepository = $null,

        [AllowEmptyCollection()]
        [object[]]$Runs = @()
    )

    return [pscustomobject][ordered]@{
        schemaVersion = 2
        activeRepository = $ActiveRepository
        runs = @($Runs)
    }
}

function Read-RepoFlowStateDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath

    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $null
    }

    try {
        $state = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 |
            ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw (
            'RepoFlow state contains invalid JSON. Move or delete the file ' +
            "and retry: $statePath"
        )
    }

    $hasSchemaVersion = $null -ne $state.PSObject.Properties['schemaVersion']
    $hasRuns = $null -ne $state.PSObject.Properties['runs']

    if (-not $hasSchemaVersion -and -not $hasRuns) {
        Assert-RepoFlowAllowedProperties `
            -Object $state `
            -Allowed @('activeRepository') `
            -Path '$'

        $activeRepository = Get-RepoFlowProperty `
            -Object $state `
            -Name 'activeRepository' `
            -Default $null

        Assert-RepoFlowString `
            -Value $activeRepository `
            -Path '$.activeRepository'

        return New-RepoFlowStateDocument `
            -ActiveRepository ([string]$activeRepository) `
            -Runs @()
    }

    Assert-RepoFlowAllowedProperties `
        -Object $state `
        -Allowed @('schemaVersion', 'activeRepository', 'runs') `
        -Path '$'

    $schemaVersion = Get-RepoFlowProperty `
        -Object $state `
        -Name 'schemaVersion' `
        -Default $null

    if ($schemaVersion -ne 2) {
        throw (
            'RepoFlow state schema is unsupported. Move or delete the file ' +
            "and retry: $statePath"
        )
    }

    $activeRepository = Get-RepoFlowProperty `
        -Object $state `
        -Name 'activeRepository' `
        -Default $null
    $runs = Get-RepoFlowProperty `
        -Object $state `
        -Name 'runs' `
        -Default @()

    if (-not [string]::IsNullOrWhiteSpace([string]$activeRepository)) {
        Assert-RepoFlowString `
            -Value $activeRepository `
            -Path '$.activeRepository'
    }
    else {
        $activeRepository = $null
    }

    Assert-RepoFlowArray `
        -Value $runs `
        -Path '$.runs'

    try {
        $runRecords = @($runs)

        for ($index = 0; $index -lt $runRecords.Count; $index++) {
            Assert-RepoFlowRunRecord `
                -Record $runRecords[$index] `
                -Path ("$.runs[{0}]" -f $index)
        }
    }
    catch {
        throw (
            'RepoFlow state contains an invalid or incompatible run record. ' +
            "Move or delete the file and retry: $statePath"
        )
    }

    return New-RepoFlowStateDocument `
        -ActiveRepository $activeRepository `
        -Runs @($runs)
}

function Write-RepoFlowStateDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        $Document
    )

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath
    $stateDirectory = Split-Path -Parent $statePath
    $temporaryPath = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)

    New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null

    try {
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            ($Document | ConvertTo-Json -Depth 12),
            $utf8WithoutBom
        )
        [System.IO.File]::Move($temporaryPath, $statePath, $true)
    }
    finally {
        Remove-Item `
            -LiteralPath $temporaryPath `
            -Force `
            -ErrorAction SilentlyContinue
    }
}

function Invoke-RepoFlowStateMutation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [scriptblock]$Update
    )

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath
    $lock = Open-RepoFlowStateLock -StatePath $statePath

    try {
        $document = Read-RepoFlowStateDocument -ConfigPath $ConfigPath

        if ($null -eq $document) {
            $document = New-RepoFlowStateDocument
        }

        $updatedDocument = & $Update $document

        if ($null -eq $updatedDocument) {
            $updatedDocument = $document
        }

        Write-RepoFlowStateDocument `
            -ConfigPath $ConfigPath `
            -Document $updatedDocument

        return $updatedDocument
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}

function Remove-RepoFlowStateFileIfEmpty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath

    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $false
    }

    $lock = Open-RepoFlowStateLock -StatePath $statePath

    try {
        $document = Read-RepoFlowStateDocument -ConfigPath $ConfigPath

        if (
            $null -ne $document -and
            [string]::IsNullOrWhiteSpace([string]$document.activeRepository) -and
            @($document.runs).Count -eq 0
        ) {
            Remove-Item -LiteralPath $statePath -Force
            return $true
        }

        return $false
    }
    finally {
        if ($null -ne $lock) {
            $lock.Dispose()
        }
    }
}

function Read-RepoFlowRepositoryState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath
    $state = Read-RepoFlowStateDocument -ConfigPath $ConfigPath

    if ($null -eq $state -or [string]::IsNullOrWhiteSpace([string]$state.activeRepository)) {
        return $null
    }

    return [pscustomobject]@{
        Path = $statePath
        ActiveRepository = [string]$state.activeRepository
    }
}

function Find-RepoFlowRepositoryByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Repositories,

        [Parameter(Mandatory)]
        [string]$Name
    )

    return @(
        $Repositories |
        Where-Object {
            [string]::Equals(
                [string]$_.name,
                $Name,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        }
    ) | Select-Object -First 1
}

function Get-RepoFlowRepositoryRegistry {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $document = Get-RepoFlowConfigurationDocument -ConfigPath $ConfigPath
    $raw = $document.Raw

    $hasLegacy = $null -ne $raw.PSObject.Properties['repository']
    $hasRepositories = $null -ne $raw.PSObject.Properties['repositories']
    $hasDefault = $null -ne $raw.PSObject.Properties['defaultRepository']

    if ($hasLegacy -and ($hasRepositories -or $hasDefault)) {
        throw (
            "Configuration must use either '$.repository' or " +
            "'$.defaultRepository' with '$.repositories', not both."
        )
    }

    if (-not $hasLegacy -and -not $hasRepositories) {
        throw (
            "Configuration must define either '$.repository' or " +
            "'$.defaultRepository' with '$.repositories'."
        )
    }

    if ($hasLegacy) {
        $repository = $raw.repository

        Assert-RepoFlowAllowedProperties `
            -Object $repository `
            -Allowed @('localPath', 'slug', 'expectedOrigins', 'baseBranch') `
            -Path '$.repository'

        $configuredPath = Get-RepoFlowProperty `
            -Object $repository `
            -Name 'localPath' `
            -Default (Get-Location).Path

        $slug = Get-RepoFlowProperty -Object $repository -Name 'slug' -Default ''
        $origins = Get-RepoFlowProperty -Object $repository -Name 'expectedOrigins' -Default @()
        $baseBranch = Get-RepoFlowProperty -Object $repository -Name 'baseBranch' -Default 'main'

        Assert-RepoFlowString -Value $configuredPath -Path '$.repository.localPath'
        Assert-RepoFlowString -Value $slug -Path '$.repository.slug'
        Assert-RepoFlowArray -Value $origins -Path '$.repository.expectedOrigins'
        Assert-RepoFlowString -Value $baseBranch -Path '$.repository.baseBranch'

        if ([string]$slug -notmatch '^[^/\s]+/[^/\s]+$') {
            throw "Configuration value '$.repository.slug' must use the 'owner/repository' format."
        }

        if (@($origins).Count -eq 0) {
            throw "Configuration value '$.repository.expectedOrigins' must contain at least one origin."
        }

        foreach ($origin in @($origins)) {
            Assert-RepoFlowString -Value $origin -Path '$.repository.expectedOrigins[]'
        }

        $entry = [pscustomobject]@{
            name = 'legacy'
            localPath = Resolve-RepoFlowRegisteredPath `
                -ConfigPath $document.ConfigPath `
                -LocalPath ([string]$configuredPath)
            slug = [string]$slug
            expectedOrigins = @($origins | ForEach-Object { [string]$_ })
            baseBranch = [string]$baseBranch
            isLegacy = $true
        }

        return [pscustomobject]@{
            ConfigPath = $document.ConfigPath
            Raw = $raw
            IsLegacy = $true
            DefaultRepository = $null
            Repositories = @($entry)
        }
    }

    if (-not $hasDefault) {
        throw "Configuration value '$.defaultRepository' is required when '$.repositories' is used."
    }

    $defaultRepository = [string]$raw.defaultRepository
    Assert-RepoFlowString -Value $defaultRepository -Path '$.defaultRepository'
    Assert-RepoFlowArray -Value $raw.repositories -Path '$.repositories'

    $rawRepositories = @($raw.repositories)

    if ($rawRepositories.Count -eq 0) {
        throw "Configuration value '$.repositories' must contain at least one repository."
    }

    $names = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    $entries = [System.Collections.Generic.List[object]]::new()

    for ($index = 0; $index -lt $rawRepositories.Count; $index++) {
        $repository = $rawRepositories[$index]
        $path = '$.repositories[{0}]' -f $index

        Assert-RepoFlowAllowedProperties `
            -Object $repository `
            -Allowed @('name', 'localPath', 'slug', 'expectedOrigins', 'baseBranch') `
            -Path $path

        $name = Get-RepoFlowProperty -Object $repository -Name 'name' -Default $null
        $localPath = Get-RepoFlowProperty -Object $repository -Name 'localPath' -Default $null
        $slug = Get-RepoFlowProperty -Object $repository -Name 'slug' -Default $null
        $origins = Get-RepoFlowProperty -Object $repository -Name 'expectedOrigins' -Default $null
        $baseBranch = Get-RepoFlowProperty -Object $repository -Name 'baseBranch' -Default $null

        Assert-RepoFlowString -Value $name -Path "$path.name"
        Assert-RepoFlowString -Value $localPath -Path "$path.localPath"
        Assert-RepoFlowString -Value $slug -Path "$path.slug"
        Assert-RepoFlowArray -Value $origins -Path "$path.expectedOrigins"
        Assert-RepoFlowString -Value $baseBranch -Path "$path.baseBranch"

        if (-not $names.Add([string]$name)) {
            throw "Repository name '$name' is duplicated in '$.repositories'."
        }

        if ([string]$slug -notmatch '^[^/\s]+/[^/\s]+$') {
            throw "Configuration value '$path.slug' must use the 'owner/repository' format."
        }

        if (@($origins).Count -eq 0) {
            throw "Configuration value '$path.expectedOrigins' must contain at least one origin."
        }

        foreach ($origin in @($origins)) {
            Assert-RepoFlowString -Value $origin -Path "$path.expectedOrigins[]"
        }

        $entries.Add([pscustomobject]@{
            name = [string]$name
            localPath = Resolve-RepoFlowRegisteredPath `
                -ConfigPath $document.ConfigPath `
                -LocalPath ([string]$localPath)
            slug = [string]$slug
            expectedOrigins = @($origins | ForEach-Object { [string]$_ })
            baseBranch = [string]$baseBranch
            isLegacy = $false
        })
    }

    $repositoryEntries = $entries.ToArray()
    $defaultEntry = Find-RepoFlowRepositoryByName `
        -Repositories $repositoryEntries `
        -Name $defaultRepository

    if ($null -eq $defaultEntry) {
        throw (
            "Configuration value '$.defaultRepository' references unknown " +
            "repository '$defaultRepository'."
        )
    }

    return [pscustomobject]@{
        ConfigPath = $document.ConfigPath
        Raw = $raw
        IsLegacy = $false
        DefaultRepository = [string]$defaultEntry.name
        Repositories = $repositoryEntries
    }
}

function Test-RepoFlowPathWithinRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryPath,

        [Parameter(Mandatory)]
        [string]$CandidatePath
    )

    $root = [System.IO.Path]::GetFullPath($RepositoryPath).TrimEnd(
        [char[]]@('\', '/')
    )
    $candidate = [System.IO.Path]::GetFullPath($CandidatePath).TrimEnd(
        [char[]]@('\', '/')
    )

    $comparison = if (
        [System.IO.Path]::DirectorySeparatorChar -eq '\'
    ) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }

    if ([string]::Equals($root, $candidate, $comparison)) {
        return $true
    }

    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    return $candidate.StartsWith($prefix, $comparison)
}

function Get-RepoFlowRepositorySelection {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [Alias('Repo', 'Repository')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RepositoryName,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$CurrentDirectory
    )

    $registry = Get-RepoFlowRepositoryRegistry -ConfigPath $ConfigPath

    if ($registry.IsLegacy) {
        if (-not [string]::IsNullOrWhiteSpace($RepositoryName)) {
            throw (
                "Explicit -Repo selection requires a configuration using " +
                "'$.repositories'."
            )
        }

        $selected = $registry.Repositories[0]

        return [pscustomobject]@{
            Registry = $registry
            Repository = $selected
            RepositoryRoot = [string]$selected.localPath
            Source = 'legacy'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($RepositoryName)) {
        $selected = Find-RepoFlowRepositoryByName `
            -Repositories $registry.Repositories `
            -Name $RepositoryName

        if ($null -eq $selected) {
            throw "Unknown RepoFlow repository: $RepositoryName"
        }

        return [pscustomobject]@{
            Registry = $registry
            Repository = $selected
            RepositoryRoot = [string]$selected.localPath
            Source = 'explicit'
        }
    }

    $state = Read-RepoFlowRepositoryState `
        -ConfigPath $registry.ConfigPath

    if ($null -ne $state) {
        $selected = Find-RepoFlowRepositoryByName `
            -Repositories $registry.Repositories `
            -Name $state.ActiveRepository

        if ($null -eq $selected) {
            throw (
                "Active RepoFlow repository '$($state.ActiveRepository)' " +
                "does not exist in '$($registry.ConfigPath)'."
            )
        }

        return [pscustomobject]@{
            Registry = $registry
            Repository = $selected
            RepositoryRoot = [string]$selected.localPath
            Source = 'active'
        }
    }

    $directory = if (
        [string]::IsNullOrWhiteSpace($CurrentDirectory)
    ) {
        (Get-Location).Path
    }
    else {
        $CurrentDirectory
    }

    $directoryMatches = @(
        $registry.Repositories |
            Where-Object {
                Test-RepoFlowPathWithinRepository `
                    -RepositoryPath ([string]$_.localPath) `
                    -CandidatePath $directory
            } |
            Sort-Object `
                -Property @{
                    Expression = {
                        ([string]$_.localPath).Length
                    }
                } `
                -Descending
    )

    if ($directoryMatches.Count -gt 0) {
        $selected = $directoryMatches[0]

        return [pscustomobject]@{
            Registry = $registry
            Repository = $selected
            RepositoryRoot = [string]$selected.localPath
            Source = 'current-directory'
        }
    }

    $selected = Find-RepoFlowRepositoryByName `
        -Repositories $registry.Repositories `
        -Name $registry.DefaultRepository

    return [pscustomobject]@{
        Registry = $registry
        Repository = $selected
        RepositoryRoot = [string]$selected.localPath
        Source = 'default'
    }
}


function Get-RepoFlowRepositoryRoot {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [Alias('Repo', 'Repository')]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$RepositoryName
    )

    $selection = Get-RepoFlowRepositorySelection `
        -ConfigPath $ConfigPath `
        -RepositoryName $RepositoryName

    $candidatePath = [string]$selection.RepositoryRoot

    if (-not (Test-Path -LiteralPath $candidatePath -PathType Container)) {
        throw "Configured repository path does not exist: $candidatePath"
    }

    $result = Invoke-RepoFlowCommand `
        -Command 'git' `
        -Arguments @(
            '-C',
            $candidatePath,
            'rev-parse',
            '--show-toplevel'
        ) `
        -AllowFailure

    if ($result.ExitCode -ne 0) {
        throw "Configured repository path is not a Git repository: $candidatePath"
    }

    $root = $result.Text.Trim()

    if ([string]::IsNullOrWhiteSpace($root)) {
        throw "Git did not return a repository root for: $candidatePath"
    }

    return [System.IO.Path]::GetFullPath($root)
}

function Show-RepoFlowRepositoryBanner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Selection
    )

    Write-Host "[REPO] $($Selection.Repository.name)"
    Write-Host "[PATH] $($Selection.RepositoryRoot)"
    Write-Host "[GITHUB] $($Selection.Repository.slug)"
    Write-Host ''
}

function Write-RepoFlowActiveRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RepositoryName
    )

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath
    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $document.activeRepository = $RepositoryName
        return $document
    } | Out-Null

    return $statePath
}

function Remove-RepoFlowActiveRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath
    )

    $statePath = Get-RepoFlowStatePath -ConfigPath $ConfigPath

    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return $false
    }

    $document = Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($state)

        $state.activeRepository = $null
        return $state
    }

    Remove-RepoFlowStateFileIfEmpty -ConfigPath $ConfigPath | Out-Null

    return $true
}

function Invoke-RepoFlowRepositoryListWorkflow {
    [CmdletBinding()]
    param(
        [string]$ConfigPath
    )

    $registry = Get-RepoFlowRepositoryRegistry -ConfigPath $ConfigPath
    $state = if ($registry.IsLegacy) {
        $null
    }
    else {
        Read-RepoFlowRepositoryState -ConfigPath $registry.ConfigPath
    }
    $currentDirectory = (Get-Location).Path

    Write-Host 'Repositories'
    Write-Host ''

    foreach ($repository in $registry.Repositories) {
        $isDefault = (
            -not $registry.IsLegacy -and
            [string]::Equals(
                [string]$repository.name,
                [string]$registry.DefaultRepository,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
        $isActive = (
            $null -ne $state -and
            [string]::Equals(
                [string]$repository.name,
                [string]$state.ActiveRepository,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        )
        $isCurrent = Test-RepoFlowPathWithinRepository `
            -RepositoryPath ([string]$repository.localPath) `
            -CandidatePath $currentDirectory

        $markers = @()
        if ($repository.isLegacy) { $markers += 'legacy' }
        if ($isDefault) { $markers += 'default' }
        if ($isActive) { $markers += 'active' }
        if ($isCurrent) { $markers += 'current-directory' }

        $markerText = if ($markers.Count -eq 0) {
            ''
        }
        else {
            ' [' + ($markers -join ', ') + ']'
        }

        Write-Host "$($repository.name)$markerText"
        Write-Host "  Path:   $($repository.localPath)"
        Write-Host "  GitHub: $($repository.slug)"
        Write-Host "  Base:   $($repository.baseBranch)"
        Write-Host ''
    }
}

function Invoke-RepoFlowRepositoryCurrentWorkflow {
    [CmdletBinding()]
    param(
        [string]$ConfigPath,

        [Alias('Repository', 'RepositoryName')]
        [string]$Repo
    )

    $selection = Get-RepoFlowRepositorySelection `
        -ConfigPath $ConfigPath `
        -RepositoryName $Repo

    Write-Host "Repository: $($selection.Repository.name)"
    Write-Host "Source:     $($selection.Source)"
    Write-Host "Path:       $($selection.RepositoryRoot)"
    Write-Host "GitHub:     $($selection.Repository.slug)"
    Write-Host "Base:       $($selection.Repository.baseBranch)"
}

function Invoke-RepoFlowRepositoryUseWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Alias('Repository', 'RepositoryName')]
        [string]$Repo,

        [switch]$Apply,

        [string]$ConfigPath
    )

    $registry = Get-RepoFlowRepositoryRegistry -ConfigPath $ConfigPath

    if ($registry.IsLegacy) {
        throw "'repo use' requires a configuration using '$.repositories'."
    }

    $repository = Find-RepoFlowRepositoryByName `
        -Repositories $registry.Repositories `
        -Name $Repo

    if ($null -eq $repository) {
        throw "Unknown RepoFlow repository: $Repo"
    }

    Write-Host "Active repository: $($repository.name)"
    Write-Host "Path:              $($repository.localPath)"
    Write-Host "GitHub:            $($repository.slug)"

    if (-not $Apply) {
        Write-Host ''
        Write-Host 'PLAN ONLY - active repository state was not changed.'
        Write-Host "Run again with -Apply to select '$($repository.name)'."
        return
    }

    $statePath = Write-RepoFlowActiveRepository `
        -ConfigPath $registry.ConfigPath `
        -RepositoryName ([string]$repository.name)

    Write-Host ''
    Write-Host "Active repository saved: $statePath"
}

function Invoke-RepoFlowRepositoryResetWorkflow {
    [CmdletBinding()]
    param(
        [switch]$Apply,

        [string]$ConfigPath
    )

    $registry = Get-RepoFlowRepositoryRegistry -ConfigPath $ConfigPath
    $statePath = Get-RepoFlowRepositoryStatePath -ConfigPath $registry.ConfigPath

    if (-not $Apply) {
        Write-Host "Active repository state: $statePath"
        Write-Host ''
        Write-Host 'PLAN ONLY - active repository state was not removed.'
        Write-Host 'Run again with -Apply to reset repository selection.'
        return
    }

    $removed = Remove-RepoFlowActiveRepository -ConfigPath $registry.ConfigPath

    if ($removed) {
        Write-Host "Active repository selection removed: $statePath"
    }
    else {
        Write-Host 'No active repository selection was stored.'
    }
}
