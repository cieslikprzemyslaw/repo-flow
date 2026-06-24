BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow observable progress telemetry' {
    InModuleScope RepoFlow {
        It 'classifies output, CPU, command, and diff changes as observable activity' {
            $started = [datetime]'2026-06-24T08:00:00Z'
            $initialTree = [pscustomobject]@{
                Available = $true
                ChangedFileCount = 0
                Fingerprint = 'before'
                LastWriteTimeUtc = $null
            }
            $state = New-RepoFlowAgentTelemetryState `
                -StartedAt $started `
                -NoActivityWarningSeconds 120 `
                -HeartbeatSeconds 5 `
                -InitialWorkingTree $initialTree
            $tree = [pscustomobject]@{
                Available = $true
                ChangedFileCount = 2
                Fingerprint = 'after'
                LastWriteTimeUtc = [datetime]'2026-06-24T08:00:09Z'
            }
            $process = [pscustomobject]@{
                Detected = $true
                Id = 42
                Name = 'codex'
                CpuSeconds = 2.0
                CpuDeltaSeconds = 0.4
            }

            $heartbeat = Get-RepoFlowAgentHeartbeatTelemetry `
                -State $state `
                -Now $started.AddSeconds(10) `
                -OutputLength 100 `
                -WorkingTree $tree `
                -Process $process `
                -ObservableCommand 'npm test'

            $heartbeat.Status | Should -Be active
            $heartbeat.ObservableActivity | Should -BeTrue
            $heartbeat.FingerprintChanged | Should -BeTrue
            $heartbeat.CpuChanged | Should -BeTrue
            $heartbeat.CommandChanged | Should -BeTrue
        }

        It 'distinguishes waiting, no observable change, and possibly stalled' {
            $started = [datetime]'2026-06-24T08:00:00Z'
            $tree = [pscustomobject]@{
                Available = $true
                ChangedFileCount = 1
                Fingerprint = 'same'
                LastWriteTimeUtc = $null
            }
            $process = [pscustomobject]@{
                Detected = $true
                Id = 42
                Name = 'codex'
                CpuSeconds = 0.0
                CpuDeltaSeconds = 0.0
            }
            $state = New-RepoFlowAgentTelemetryState `
                -StartedAt $started `
                -NoActivityWarningSeconds 30 `
                -HeartbeatSeconds 5 `
                -InitialWorkingTree $tree

            $waiting = Get-RepoFlowAgentHeartbeatTelemetry `
                -State $state `
                -Now $started.AddSeconds(5) `
                -OutputLength 0 `
                -WorkingTree $tree `
                -Process $process `
                -ObservableCommand ''
            $unchanged = Get-RepoFlowAgentHeartbeatTelemetry `
                -State $state `
                -Now $started.AddSeconds(15) `
                -OutputLength 0 `
                -WorkingTree $tree `
                -Process $process `
                -ObservableCommand ''
            $stalled = Get-RepoFlowAgentHeartbeatTelemetry `
                -State $state `
                -Now $started.AddSeconds(31) `
                -OutputLength 0 `
                -WorkingTree $tree `
                -Process $process `
                -ObservableCommand ''

            $waiting.Status | Should -Be waiting
            $unchanged.Status | Should -Be 'no observable change'
            $stalled.Status | Should -Be 'possibly stalled'
            $stalled.ShouldWarn | Should -BeTrue
        }

        It 'does not present changed files as a progress percentage' {
            $heartbeat = [pscustomobject]@{
                Status = 'active'
                Elapsed = [timespan]::FromSeconds(10)
                NoActivity = [timespan]::Zero
                FingerprintChanged = $true
            }
            $tree = [pscustomobject]@{
                ChangedFileCount = 12
                LastWriteTimeUtc = [datetime]'2026-06-24T08:00:09Z'
            }
            $process = [pscustomobject]@{
                Detected = $false
            }

            $text = Format-RepoFlowAgentHeartbeat `
                -Provider codex `
                -Phase issue-agent-running `
                -Heartbeat $heartbeat `
                -WorkingTree $tree `
                -Process $process `
                -ObservableCommand ''

            $text | Should -Match 'files=12'
            $text | Should -Not -Match '%'
            $text | Should -Match 'diff=changed'
        }

        It 'extracts only observable validation commands from supported streams' {
            $codex = @'
{"type":"item.started","item":{"type":"command_execution","command":"npm test"}}
'@
            $claude = @'
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"npm run typecheck"}}]}}
'@

            Get-RepoFlowObservableValidationCommand -JsonLines $codex |
                Should -Be 'npm test'
            Get-RepoFlowObservableValidationCommand -JsonLines $claude |
                Should -Be 'npm run typecheck'
            Get-RepoFlowObservableValidationCommand -JsonLines '{"type":"message","text":"probably testing"}' |
                Should -Be ''
            $completedCommand = @'
{"type":"item.started","item":{"type":"command_execution","command":"npm test"}}
{"type":"item.completed","item":{"type":"command_execution","command":"npm test"}}
'@
            Get-RepoFlowObservableValidationCommand -JsonLines $completedCommand |
                Should -Be ''
        }

        It 'does not claim zero changed files when Git telemetry is unavailable' {
            $heartbeat = [pscustomobject]@{
                Status = 'waiting'
                Elapsed = [timespan]::FromSeconds(5)
                NoActivity = [timespan]::FromSeconds(5)
                FingerprintChanged = $false
            }
            $tree = [pscustomobject]@{
                Available = $false
                ChangedFileCount = 0
                LastWriteTimeUtc = $null
            }
            $process = [pscustomobject]@{ Detected = $false }

            $text = Format-RepoFlowAgentHeartbeat `
                -Provider codex `
                -Phase issue-agent-running `
                -Heartbeat $heartbeat `
                -WorkingTree $tree `
                -Process $process `
                -ObservableCommand ''

            $text | Should -Match 'files=<unavailable>'
            $text | Should -Not -Match 'files=0'
        }

        It 'uses mocked process observations to report CPU delta' {
            Mock Get-Process {
                [pscustomobject]@{
                    ProcessName = 'codex'
                    Id = 123
                    StartTime = [datetime]'2026-06-24T08:00:01Z'
                    CPU = 3.5
                }
            }

            $result = Get-RepoFlowAgentProcessTelemetry `
                -ExecutablePath 'codex.exe' `
                -StartedAt ([datetime]'2026-06-24T08:00:00Z') `
                -PreviousCpuSeconds 3.0

            $result.Detected | Should -BeTrue
            $result.Name | Should -Be codex
            $result.CpuDeltaSeconds | Should -Be 0.5
        }

        It 'uses mocked filesystem observations for the working-tree fingerprint' {
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = " M src/app.ps1"
                }
            }
            Mock Test-Path { $true }
            Mock Get-Item {
                [pscustomobject]@{
                    Length = 12
                    LastWriteTimeUtc = [datetime]'2026-06-24T08:00:00Z'
                }
            }

            $result = Get-RepoFlowWorkingTreeTelemetry -RepositoryRoot $TestDrive

            $result.Available | Should -BeTrue
            $result.ChangedFileCount | Should -Be 1
            $result.Fingerprint | Should -Not -BeNullOrEmpty
            $result.LastWriteTimeUtc | Should -Be ([datetime]'2026-06-24T08:00:00Z')
        }
    }
}

Describe 'RepoFlow CI transition telemetry' {
    InModuleScope RepoFlow {
        It 'reports check transitions once and then waiting states' {
            $started = [datetime]'2026-06-24T08:00:00Z'
            $telemetry = New-RepoFlowCiTelemetryState `
                -StartedAt $started `
                -NoActivityWarningSeconds 60
            $pending = [pscustomobject]@{
                Status = 'pending'
                Checks = @(
                    [pscustomobject]@{ name = 'Validate'; bucket = 'pending' }
                )
            }

            $first = Get-RepoFlowCiProgressTelemetry `
                -TelemetryState $telemetry `
                -CiState $pending `
                -Now $started.AddSeconds(1) `
                -PollSeconds 10
            $second = Get-RepoFlowCiProgressTelemetry `
                -TelemetryState $telemetry `
                -CiState $pending `
                -Now $started.AddSeconds(11) `
                -PollSeconds 10

            $first.Status | Should -Be active
            $first.Transitions | Should -Contain 'Validate: <new> -> pending'
            $second.Status | Should -Be waiting
            $second.Transitions.Count | Should -Be 0
        }

        It 'warns without terminating after the configured no-activity period' {
            $started = [datetime]'2026-06-24T08:00:00Z'
            $telemetry = New-RepoFlowCiTelemetryState `
                -StartedAt $started `
                -NoActivityWarningSeconds 30
            $pending = [pscustomobject]@{
                Status = 'pending'
                Checks = @()
            }

            Get-RepoFlowCiProgressTelemetry `
                -TelemetryState $telemetry `
                -CiState $pending `
                -Now $started `
                -PollSeconds 10 |
                Out-Null
            $result = Get-RepoFlowCiProgressTelemetry `
                -TelemetryState $telemetry `
                -CiState $pending `
                -Now $started.AddSeconds(31) `
                -PollSeconds 10

            $result.Status | Should -Be 'possibly stalled'
            $result.ShouldWarn | Should -BeTrue
        }
    }
}

Describe 'RepoFlow persisted heartbeat telemetry' {
    InModuleScope RepoFlow {
        It 'adds telemetry timestamps to an older run record and preserves the phase' {
            $script:document = [pscustomobject]@{
                runs = @(
                    [pscustomobject]@{
                        runId = 'run-1'
                        currentPhase = 'issue-agent-running'
                        updatedAtUtc = '2026-06-24T08:00:00.0000000+00:00'
                    }
                )
            }
            Mock Invoke-RepoFlowStateMutation {
                param($ConfigPath, $Update)
                $script:document = & $Update $script:document
                return $script:document
            }

            Set-RepoFlowRunHeartbeat `
                -ConfigPath 'C:\repo\.repo-flow.json' `
                -RunId 'run-1' `
                -CurrentPhase 'issue-agent-running' `
                -ObservableActivity

            $record = $script:document.runs[0]
            $record.currentPhase | Should -Be 'issue-agent-running'
            $record.lastHeartbeatAtUtc | Should -Not -BeNullOrEmpty
            $record.lastObservableActivityAtUtc | Should -Not -BeNullOrEmpty
            Should -Invoke Invoke-RepoFlowStateMutation -Times 1
        }
    }
}
