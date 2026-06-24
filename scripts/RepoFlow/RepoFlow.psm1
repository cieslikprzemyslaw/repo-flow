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
    'Git.Resume.ps1',
    'AgentRunState.Core.ps1',
    'AgentRunState.Records.ps1',
    'AgentRunState.Resume.ps1',
    'AgentRunState.Review.ps1',
    'Issues.ps1',
    'Branches.ps1',
    'Diagnostics.ps1',
    'Doctor.Core.ps1',
    'Doctor.Configuration.ps1',
    'Doctor.Checks.ps1',
    'Doctor.Repository.ps1',
    'Doctor.Workflow.ps1',
    'Telemetry.Observations.ps1',
    'Telemetry.Heartbeat.ps1',
    'Telemetry.Ci.ps1',
    'Telemetry.State.ps1',
    'Agent.Telemetry.ps1',
    'Ci.Telemetry.ps1',
    'CiDiagnosticSupport.ps1',
    'CiDiagnostics.ps1',
    'Agent.ps1',
    'Prompts.ps1',
    'PreCommit.ps1',
    'PullRequests.ps1',
    'ReviewFeedback.ps1',
    'CiContext.ps1',
    'Ci.ps1',
    'PrRepair.ps1',
    'Manifest.ps1',
    'IssueResume.State.ps1',
    'IssueResume.PlanInitial.ps1',
    'IssueResume.PlanReview.ps1',
    'IssueResume.Plan.ps1',
    'IssueResume.Resolve.ps1',
    'IssueResume.Agent.ps1',
    'IssueResume.GitHub.ps1',
    'IssueResume.Ci.ps1',
    'IssueResume.Workflow.ps1',
    'Workflows.ps1'
)

foreach ($file in $privateFiles) {
    . (Join-Path $PSScriptRoot "Private/$file")
}

. (Join-Path $PSScriptRoot 'Public/Invoke-RepoFlow.ps1')
. (Join-Path $PSScriptRoot 'Public/Invoke-RepoFlowCli.ps1')

Export-ModuleMember -Function Invoke-RepoFlow, Invoke-RepoFlowCli
