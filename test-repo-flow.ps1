[CmdletBinding()]
param(
    [switch]$SkipPester
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$parseErrors = [System.Collections.Generic.List[object]]::new()
$files = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object {
        $_.Extension -in @('.ps1', '.psm1', '.psd1') -and
        $_.FullName -notmatch '[\\/]\.git[\\/]'
    }

foreach ($file in $files) {
    $tokens = $null
    $errors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null

    foreach ($error in @($errors)) {
        $parseErrors.Add([pscustomobject]@{
            File = $file.FullName
            Message = $error.Message
            Line = $error.Extent.StartLineNumber
            Column = $error.Extent.StartColumnNumber
            Code = $error.Extent.Text
        })
    }
}

if ($parseErrors.Count -gt 0) {
    Write-Host ''
    Write-Host 'PowerShell parser errors:' -ForegroundColor Red

    foreach ($parseError in $parseErrors) {
        Write-Host ''
        Write-Host (
            '{0}:{1}:{2}' -f
            $parseError.File,
            $parseError.Line,
            $parseError.Column
        ) -ForegroundColor Yellow
        Write-Host "  $($parseError.Message)" -ForegroundColor Red

        if (-not [string]::IsNullOrWhiteSpace([string]$parseError.Code)) {
            Write-Host "  Code: $($parseError.Code)" -ForegroundColor DarkGray
        }
    }

    throw "PowerShell parser found $($parseErrors.Count) error(s)."
}

Write-Host "PowerShell syntax checks passed for $($files.Count) file(s)."

$jsonPaths = [System.Collections.Generic.List[string]]::new()
$jsonPaths.Add((Join-Path $root 'repo-flow.example.json'))
$jsonPaths.Add((Join-Path $root 'queue.example.json'))
$jsonPaths.Add((Join-Path $root 'scripts/RepoFlow/repo-flow.schema.json'))

foreach ($schemaPath in @(
    Get-ChildItem -LiteralPath (Join-Path $root 'scripts/RepoFlow/Schemas') `
        -Filter '*.json' `
        -File
)) {
    $jsonPaths.Add($schemaPath.FullName)
}

foreach ($fixturePath in @(
    Get-ChildItem -LiteralPath (Join-Path $root 'tests/fixtures/review') `
        -Filter '*.json' `
        -File
)) {
    $jsonPaths.Add($fixturePath.FullName)
}

$localConfigPath = Join-Path $root '.repo-flow.json'
if (Test-Path -LiteralPath $localConfigPath) {
    $jsonPaths.Add($localConfigPath)
}

foreach ($jsonPath in $jsonPaths) {
    if (-not (Test-Path -LiteralPath $jsonPath -PathType Leaf)) {
        throw "Required JSON file was not found: $jsonPath"
    }

    Get-Content -LiteralPath $jsonPath -Raw |
        ConvertFrom-Json -ErrorAction Stop |
        Out-Null
}

Write-Host "JSON parsing checks passed for $($jsonPaths.Count) file(s)."

$modulePath = Join-Path $root 'scripts/RepoFlow/RepoFlow.psd1'
Import-Module $modulePath -Force -ErrorAction Stop
Write-Host 'RepoFlow module import passed.'

if ($SkipPester) {
    Write-Warning 'Pester tests were explicitly skipped with -SkipPester.'
    return
}

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version -ge [version]'5.0.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1

if ($null -eq $pester) {
    throw (
        'Pester 5 or newer is required. Install it with: ' +
        'Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser -Force'
    )
}

Import-Module Pester -MinimumVersion 5.0 -Force
$result = Invoke-Pester -Path (Join-Path $root 'tests') -PassThru

if ($result.FailedCount -gt 0) {
    throw "$($result.FailedCount) Pester test(s) failed."
}

Write-Host "Pester tests passed: $($result.PassedCount)."
