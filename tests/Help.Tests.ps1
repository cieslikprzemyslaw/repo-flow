BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow help' {
    InModuleScope RepoFlow {
        It 'shows the general command list' {
            $helpText = Get-RepoFlowHelpText
            $helpText | Should -Match 'issue run'
            $helpText | Should -Match 'pr merge'
            $helpText | Should -Match 'pr repair'
        }

        It 'shows command-specific merge help' {
            $helpText = Get-RepoFlowHelpText -Topic 'pr merge'
            $helpText | Should -Match 'manually review'
            $helpText | Should -Match 'type MERGE'
            $helpText | Should -Match 'pr accept'
        }

        It 'shows command-specific repair help' {
            $helpText = Get-RepoFlowHelpText -Topic 'pr repair'
            $helpText | Should -Match 'Repairs a failed, open pull request'
            $helpText | Should -Match 'plan-only by default'
        }

        It 'shows positional repository use syntax' {
            $helpText = Get-RepoFlowHelpText -Topic 'repo use'

            $helpText |
                Should -Match 'repo use repo-flow'
        }
        It 'routes the help command without loading a workflow' {
            $result = Invoke-RepoFlow -Area help -Action 'issue run'
            $result | Should -Match 'Implements a GitHub issue'
        }

        It 'shows area help when the action is omitted' {
            $result = Invoke-RepoFlow -Area issue
            $result | Should -Match 'RepoFlow issue commands'
        }
    }
}
