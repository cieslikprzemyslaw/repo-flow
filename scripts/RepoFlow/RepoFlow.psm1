Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$privateFiles = @(
    'Help.ps1',
    'Command.ps1',
    'Configuration.ps1',
    'Repositories.ps1',
    'Markdown.ps1',
    'GitHub.ps1',
    'Git.ps1',
    'AgentRunState.ps1',
    'Issues.ps1',
    'Branches.ps1',
    'Diagnostics.ps1',
    'Agent.ps1',
    'Prompts.ps1',
    'PreCommit.ps1',
    'PullRequests.ps1',
    'ReviewFeedback.ps1',
    'Ci.ps1',
    'Manifest.ps1',
    'Workflows.ps1'
)

foreach ($file in $privateFiles) {
    . (Join-Path $PSScriptRoot "Private/$file")
}

. (Join-Path $PSScriptRoot 'Public/Invoke-RepoFlow.ps1')

Export-ModuleMember -Function Invoke-RepoFlow
