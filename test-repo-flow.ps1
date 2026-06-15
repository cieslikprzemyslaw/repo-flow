[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$parseErrors = New-Object System.Collections.Generic.List[object]
$files = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') }

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
        })
    }
}

if ($parseErrors.Count -gt 0) {
    $parseErrors | Format-Table -AutoSize
    throw "PowerShell parser found $($parseErrors.Count) error(s)."
}

Write-Host "PowerShell syntax checks passed for $($files.Count) file(s)."

Get-Content -LiteralPath (Join-Path $root '.repo-flow.json') -Raw |
    ConvertFrom-Json |
    Out-Null
Get-Content -LiteralPath (Join-Path $root 'scripts/RepoFlow/repo-flow.schema.json') -Raw |
    ConvertFrom-Json |
    Out-Null

Write-Host 'JSON parsing checks passed.'

if (Get-Module -ListAvailable -Name Pester) {
    Import-Module Pester -MinimumVersion 5.0
    $result = Invoke-Pester -Path (Join-Path $root 'tests') -PassThru

    if ($result.FailedCount -gt 0) {
        throw "$($result.FailedCount) Pester test(s) failed."
    }
}
else {
    Write-Warning 'Pester 5 is not installed; unit tests were skipped.'
}
