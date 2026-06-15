BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow Git helpers' {
    InModuleScope RepoFlow {
        It 'normalises HTTPS GitHub origins' {
            Normalize-RepoFlowGitOrigin -Origin 'https://github.com/Owner/Repo.git' |
                Should -Be 'github.com/owner/repo'
        }

        It 'normalises SSH GitHub origins' {
            Normalize-RepoFlowGitOrigin -Origin 'git@github.com:Owner/Repo.git' |
                Should -Be 'github.com/owner/repo'
        }
    }
}

