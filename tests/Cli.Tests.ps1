BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow CLI parser' {
    BeforeAll {
        $script:TestRepositoryRoot = [System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..')
        )
    }

    It 'shows root help for an empty argument list' {
        $result = Invoke-RepoFlowCli `
            -Arguments @() `
            -RepositoryRoot $script:TestRepositoryRoot

        $result | Should -Match 'Usage:'
        $result | Should -Match 'rf --version'
    }

    It 'supports root -h and --help' {
        foreach ($helpFlag in @('-h', '--help')) {
            $result = Invoke-RepoFlowCli `
                -Arguments @($helpFlag) `
                -RepositoryRoot $script:TestRepositoryRoot

            $result | Should -Match 'RepoFlow'
            $result | Should -Match 'issue run'
        }
    }

    It 'supports area and action-level help' {
        $areaHelp = Invoke-RepoFlowCli `
            -Arguments @('issue', '-h') `
            -RepositoryRoot $script:TestRepositoryRoot

        $actionHelp = Invoke-RepoFlowCli `
            -Arguments @('issue', 'run', '--help') `
            -RepositoryRoot $script:TestRepositoryRoot

        $futureRepairHelp = Invoke-RepoFlowCli `
            -Arguments @('pr', 'repair', '--help') `
            -RepositoryRoot $script:TestRepositoryRoot

        $areaHelp | Should -Match 'RepoFlow issue commands'
        $actionHelp | Should -Match 'Implements a GitHub issue'
        $futureRepairHelp | Should -Match 'pr repair'
        $futureRepairHelp | Should -Match 'not implemented'
    }

    It 'prints the module version without loading configuration' {
        $result = Invoke-RepoFlowCli `
            -Arguments @('--version') `
            -RepositoryRoot $script:TestRepositoryRoot

        $result | Should -Match '^RepoFlow \d+\.\d+\.\d+'
    }

    It 'maps existing named parameters and aliases' {
        Mock -CommandName Invoke-RepoFlow -ModuleName RepoFlow

        Invoke-RepoFlowCli `
            -Arguments @(
                'issue'
                'run'
                '-IssueNumber'
                '12'
                '-Run'
                '-Repository'
                'repo-flow'
                '-CiMode'
                'require-passing'
            ) `
            -RepositoryRoot $script:TestRepositoryRoot

        Should -Invoke -CommandName Invoke-RepoFlow `
            -ModuleName RepoFlow `
            -Times 1 `
            -Exactly `
            -ParameterFilter {
                $Area -eq 'issue' -and
                $Action -eq 'run' -and
                $Number -eq 12 -and
                $Apply -eq $true -and
                $Repo -eq 'repo-flow' -and
                $CiMode -eq 'require-passing'
            }
    }

    It 'maps the positional repository name' {
        Mock -CommandName Invoke-RepoFlow -ModuleName RepoFlow

        Invoke-RepoFlowCli `
            -Arguments @(
                'repo'
                'use'
                'repo-flow'
                '-Apply'
            ) `
            -RepositoryRoot $script:TestRepositoryRoot

        Should -Invoke -CommandName Invoke-RepoFlow `
            -ModuleName RepoFlow `
            -Times 1 `
            -Exactly `
            -ParameterFilter {
                $Area -eq 'repo' -and
                $Action -eq 'use' -and
                $Repo -eq 'repo-flow' -and
                $Apply -eq $true
            }
    }

    It 'rejects unknown commands with relevant usage' {
        {
            Invoke-RepoFlowCli `
                -Arguments @('issue', 'explode') `
                -RepositoryRoot $script:TestRepositoryRoot
        } | Should -Throw `
            '*Unsupported RepoFlow command*RepoFlow issue commands*'
    }

    It 'rejects unknown options with relevant usage' {
        {
            Invoke-RepoFlowCli `
                -Arguments @('issue', 'run', '--wat') `
                -RepositoryRoot $script:TestRepositoryRoot
        } | Should -Throw `
            '*Unknown RepoFlow option*RepoFlow issue commands*'
    }
}

Describe 'RepoFlow CLI launchers' {
    BeforeAll {
        $script:TestRepositoryRoot = [System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..')
        )
        $script:PwshPath = (Get-Command pwsh -ErrorAction Stop).Source
    }

    It 'runs rf --help successfully' {
        $output = & $script:PwshPath `
            -NoProfile `
            -File (Join-Path $script:TestRepositoryRoot 'rf.ps1') `
            '--help' 2>&1

        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) | Should -Match 'Usage:'
    }

    It 'runs repo-flow --version successfully' {
        $output = & $script:PwshPath `
            -NoProfile `
            -File (Join-Path $script:TestRepositoryRoot 'repo-flow.ps1') `
            '--version' 2>&1

        $LASTEXITCODE | Should -Be 0
        ($output | Out-String) |
            Should -Match '^RepoFlow \d+\.\d+\.\d+'
    }

    It 'returns non-zero and usage for an invalid command' {
        $output = & $script:PwshPath `
            -NoProfile `
            -File (Join-Path $script:TestRepositoryRoot 'rf.ps1') `
            'issue' `
            'explode' 2>&1

        $LASTEXITCODE | Should -Not -Be 0
        ($output | Out-String) |
            Should -Match 'Unsupported RepoFlow command'
        ($output | Out-String) |
            Should -Match 'RepoFlow issue commands'
    }
}
