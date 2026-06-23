<#
.SYNOPSIS
Runs RepoFlow through the recommended short rf command.

.EXAMPLE
.\rf.ps1 --help

.EXAMPLE
.\rf.ps1 issue run -Number 67 -Apply
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'scripts/RepoFlow/RepoFlow.psd1'

if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    [Console]::Error.WriteLine(
        "RepoFlow module was not found: $modulePath"
    )
    exit 1
}

$originalLocation = (Get-Location).Path

try {
    Import-Module -Name $modulePath -Force
    Invoke-RepoFlowCli `
        -Arguments ([string[]]$args) `
        -RepositoryRoot $PSScriptRoot
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    Set-Location -LiteralPath $originalLocation
}
