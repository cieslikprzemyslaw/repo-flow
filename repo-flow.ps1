<#
.SYNOPSIS
Runs RepoFlow Git, GitHub, CI, and coding-agent workflows.

.DESCRIPTION
RepoFlow manages GitHub issues, branches, pull requests, CI checks,
review-feedback iterations, and coding-agent execution.

Commands are plan-only by default. Add -Apply to perform mutations.
By default, RepoFlow loads .repo-flow.json from the directory containing
this script, so the script can manage a repository located elsewhere.

.EXAMPLE
.\repo-flow.ps1 help

Shows the complete command list.

.EXAMPLE
.\repo-flow.ps1 issue run -Number 67 -Apply

Implements issue #67 in the effective selected repository.

.EXAMPLE
.\repo-flow.ps1 pr merge -Number 116 -Apply

After you manually review and validate the PR, waits for required CI checks,
requires typing MERGE, and then performs the configured merge workflow.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'issue',
        'pr',
        'branch',
        'ci',
        'config',
        'repo',
        'help'
    )]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Area,

    [Parameter(Position = 1)]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Action,

    [Alias('IssueNumber', 'PrNumber')]
    [ValidateRange(1, 999999999)]
    [int]$Number,

    [Alias('Run')]
    [switch]$Apply,

    [switch]$SkipCreates,

    [switch]$LastPrComment,

    [ValidateRange(1, [long]::MaxValue)]
    [long]$PrCommentId,

    [switch]$Resume,

    [ValidateSet('skip', 'observe', 'require-passing')]
    [string]$CiMode,

    [Parameter(Position = 2)]
    [Alias('Repository', 'RepositoryName')]
    [string]$Repo,

    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'scripts/RepoFlow/RepoFlow.psd1'

if (-not (Test-Path -LiteralPath $modulePath)) {
    throw "RepoFlow module was not found: $modulePath"
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '.repo-flow.json'
}
elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = [System.IO.Path]::GetFullPath(
        (Join-Path (Get-Location).Path $ConfigPath)
    )
}

$originalLocation = (Get-Location).Path

try {
    Import-Module -Name $modulePath -Force

    $invokeParameters = @{}

    foreach ($entry in $PSBoundParameters.GetEnumerator()) {
        $invokeParameters[$entry.Key] = $entry.Value
    }

    $invokeParameters['ConfigPath'] = $ConfigPath

    Invoke-RepoFlow @invokeParameters
}
finally {
    Set-Location -LiteralPath $originalLocation
}
