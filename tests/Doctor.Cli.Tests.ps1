BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow doctor CLI' {
    InModuleScope RepoFlow {
        It 'routes the top-level doctor command' {
            Mock Invoke-RepoFlowDoctorWorkflow { return }

            Invoke-RepoFlowCli `
                -Arguments @('doctor') `
                -RepositoryRoot $TestDrive

            Should -Invoke Invoke-RepoFlowDoctorWorkflow -Times 1 -Exactly
        }

        It 'forwards explicit repository selection to doctor' {
            Mock Invoke-RepoFlowDoctorWorkflow { return }

            Invoke-RepoFlow `
                -Area doctor `
                -Repo flow

            Should -Invoke Invoke-RepoFlowDoctorWorkflow `
                -Times 1 `
                -Exactly `
                -ParameterFilter { $Repo -eq 'flow' }
        }

        It 'rejects Apply because doctor is always read-only' {
            Mock Invoke-RepoFlowDoctorWorkflow { return }

            { Invoke-RepoFlow -Area doctor -Apply } |
                Should -Throw '*does not accept -Apply*'
        }

        It 'documents the read-only doctor command' {
            $help = Get-RepoFlowHelpText -Topic doctor

            $help | Should -Match 'read-only'
            $help | Should -Match 'PASS/WARN/FAIL'
            $help | Should -Match 'rf doctor'
        }
    }
}
