BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

function New-RepoFlowFakeAgentProcessFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Directory,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        $Spec
    )

    $scriptPath = Join-Path $Directory "$Name-fake-provider.ps1"
    $specPath = Join-Path $Directory "$Name-fake-provider.json"
    $providerScript = @'
param(
    [Parameter(Mandatory)]
    [string]$SpecPath
)

$spec = Get-Content -LiteralPath $SpecPath -Raw -Encoding utf8 | ConvertFrom-Json

if ($spec.spawnChild -eq $true) {
    $childScriptPath = Join-Path (
        [System.IO.Path]::GetDirectoryName($SpecPath)
    ) 'fake-child-provider.ps1'
    $childScript = @(
        'param(',
        '    [Parameter(Mandatory)]',
        '    [string]$MarkerPath',
        ')',
        '',
        'Start-Sleep -Seconds 2',
        "Set-Content -LiteralPath `\$MarkerPath -Value 'child survived' -Encoding utf8"
    ) -join [Environment]::NewLine

    Set-Content -LiteralPath $childScriptPath -Value $childScript -Encoding utf8

    $childArguments = @(
        '-NoProfile',
        '-File',
        $childScriptPath,
        [string]$spec.markerPath
    )

    if ($IsWindows) {
        $null = Start-Process `
            -FilePath ([string]$spec.pwshPath) `
            -ArgumentList $childArguments `
            -WindowStyle Hidden `
            -PassThru
    }
    else {
        $null = Start-Process `
            -FilePath ([string]$spec.pwshPath) `
            -ArgumentList $childArguments `
            -PassThru
    }
}

foreach ($step in @($spec.steps)) {
    if ([int]$step.delayMs -gt 0) {
        Start-Sleep -Milliseconds ([int]$step.delayMs)
    }

    $text = [string]$step.text
    $stream = [string]$step.stream

    if ($stream -eq 'stderr') {
        [Console]::Error.WriteLine($text)
        [Console]::Error.Flush()
    }
    else {
        [Console]::Out.WriteLine($text)
        [Console]::Out.Flush()
    }
}

if ([int]$spec.waitMs -gt 0) {
    Start-Sleep -Milliseconds ([int]$spec.waitMs)
}

if (-not [string]::IsNullOrWhiteSpace([string]$spec.finalMessagePath)) {
    Set-Content `
        -LiteralPath ([string]$spec.finalMessagePath) `
        -Value ([string]$spec.finalMessage) `
        -Encoding utf8
}

exit ([int]$spec.exitCode)
'@

    Set-Content -LiteralPath $scriptPath -Value $providerScript -Encoding utf8
    $Spec | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath $specPath -Encoding utf8

    return [pscustomobject]@{
        ScriptPath = $scriptPath
        SpecPath = $specPath
    }
}

Describe 'RepoFlow Codex usage parsing' {
    InModuleScope RepoFlow {
        It 'extracts token usage from Codex JSON events' {
            $jsonLines = @'
{"type":"thread.started","thread_id":"example"}
{"type":"turn.completed","usage":{"input_tokens":24763,"cached_input_tokens":24448,"output_tokens":122,"reasoning_output_tokens":17}}
'@

            $usage = Get-RepoFlowCodexUsage -JsonLines $jsonLines

            $usage.InputTokens | Should -Be 24763
            $usage.CachedInputTokens | Should -Be 24448
            $usage.OutputTokens | Should -Be 122
            $usage.ReasoningOutputTokens | Should -Be 17
        }

        It 'returns zero usage when no completed turn is present' {
            $usage = Get-RepoFlowCodexUsage -JsonLines '{"type":"turn.started"}'

            $usage.InputTokens | Should -Be 0
            $usage.OutputTokens | Should -Be 0
        }
    }
}

Describe 'RepoFlow agent process streaming' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:hostOutput = [System.Collections.Generic.List[string]]::new()
            $script:throwOnHostLine = $null
            Mock Write-Host {
                param($Object)

                if ($PSBoundParameters.ContainsKey('Object')) {
                    $script:hostOutput.Add([string]$Object)
                    if (
                        -not [string]::IsNullOrWhiteSpace($script:throwOnHostLine) -and
                        [string]$Object -eq [string]$script:throwOnHostLine
                    ) {
                        throw 'Simulated cancellation'
                    }
                }
            }
        }

        It 'streams delayed stdout before the provider exits' {
            $fixture = New-RepoFlowFakeAgentProcessFixture `
                -Directory $TestDrive `
                -Name 'delayed-stdout' `
                -Spec ([pscustomobject]@{
                    pwshPath = (Get-Command pwsh).Source
                    exitCode = 0
                    waitMs = 250
                    steps = @(
                        [pscustomobject]@{
                            stream = 'stdout'
                            text = 'stdout one'
                            delayMs = 100
                        }
                        [pscustomobject]@{
                            stream = 'stdout'
                            text = 'stdout two'
                            delayMs = 100
                        }
                    )
                })

            $result = Invoke-RepoFlowAgentProcessWithHeartbeat `
                -Provider 'future-provider' `
                -ExecutablePath (Get-Command pwsh).Source `
                -Arguments @(
                    '-NoProfile',
                    '-File',
                    $fixture.ScriptPath,
                    $fixture.SpecPath
                ) `
                -WorkingDirectory $TestDrive `
                -Prompt 'ignored' `
                -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                -HeartbeatSeconds 5

            @($script:hostOutput) | Should -Be @('stdout one', 'stdout two')
            ($result.StandardOutput -split '\r?\n') |
                Should -Be @('stdout one', 'stdout two')
            $result.StandardError | Should -Be ''
            $result.ExitCode | Should -Be 0
        }

        It 'streams delayed stderr before the provider exits' {
            $fixture = New-RepoFlowFakeAgentProcessFixture `
                -Directory $TestDrive `
                -Name 'delayed-stderr' `
                -Spec ([pscustomobject]@{
                    pwshPath = (Get-Command pwsh).Source
                    exitCode = 0
                    waitMs = 250
                    steps = @(
                        [pscustomobject]@{
                            stream = 'stderr'
                            text = 'stderr one'
                            delayMs = 100
                        }
                        [pscustomobject]@{
                            stream = 'stderr'
                            text = 'stderr two'
                            delayMs = 100
                        }
                    )
                })

            $result = Invoke-RepoFlowAgentProcessWithHeartbeat `
                -Provider 'future-provider' `
                -ExecutablePath (Get-Command pwsh).Source `
                -Arguments @(
                    '-NoProfile',
                    '-File',
                    $fixture.ScriptPath,
                    $fixture.SpecPath
                ) `
                -WorkingDirectory $TestDrive `
                -Prompt 'ignored' `
                -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                -HeartbeatSeconds 5

            @($script:hostOutput) | Should -Be @('stderr one', 'stderr two')
            $result.StandardOutput | Should -Be ''
            ($result.StandardError -split '\r?\n') |
                Should -Be @('stderr one', 'stderr two')
            $result.ExitCode | Should -Be 0
        }

        It 'preserves interleaved stdout and stderr without a synthetic heartbeat' {
            $fixture = New-RepoFlowFakeAgentProcessFixture `
                -Directory $TestDrive `
                -Name 'interleaved' `
                -Spec ([pscustomobject]@{
                    pwshPath = (Get-Command pwsh).Source
                    exitCode = 0
                    waitMs = 100
                    steps = @(
                        [pscustomobject]@{
                            stream = 'stdout'
                            text = 'stdout one'
                            delayMs = 0
                        }
                        [pscustomobject]@{
                            stream = 'stderr'
                            text = 'stderr two'
                            delayMs = 50
                        }
                        [pscustomobject]@{
                            stream = 'stdout'
                            text = 'stdout three'
                            delayMs = 50
                        }
                    )
                })

            $result = Invoke-RepoFlowAgentProcessWithHeartbeat `
                -Provider 'future-provider' `
                -ExecutablePath (Get-Command pwsh).Source `
                -Arguments @(
                    '-NoProfile',
                    '-File',
                    $fixture.ScriptPath,
                    $fixture.SpecPath
                ) `
                -WorkingDirectory $TestDrive `
                -Prompt 'ignored' `
                -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                -HeartbeatSeconds 5

            @($script:hostOutput) | Should -Be @(
                'stdout one',
                'stderr two',
                'stdout three'
            )
            ($script:hostOutput -join [Environment]::NewLine) |
                Should -Not -Match '\[AGENT\].*working'
            ($result.StandardOutput -split '\r?\n') |
                Should -Be @('stdout one', 'stdout three')
            $result.StandardError | Should -Be 'stderr two'
            $result.ExitCode | Should -Be 0
        }

        It 'does not emit any synthetic heartbeat for a silent agent' {
            $fixture = New-RepoFlowFakeAgentProcessFixture `
                -Directory $TestDrive `
                -Name 'silent' `
                -Spec ([pscustomobject]@{
                    pwshPath = (Get-Command pwsh).Source
                    exitCode = 0
                    waitMs = 100
                    steps = @()
                })

            $result = Invoke-RepoFlowAgentProcessWithHeartbeat `
                -Provider 'future-provider' `
                -ExecutablePath (Get-Command pwsh).Source `
                -Arguments @(
                    '-NoProfile',
                    '-File',
                    $fixture.ScriptPath,
                    $fixture.SpecPath
                ) `
                -WorkingDirectory $TestDrive `
                -Prompt 'ignored' `
                -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                -HeartbeatSeconds 5

            $script:hostOutput | Should -BeEmpty
            $result.StandardOutput | Should -Be ''
            $result.StandardError | Should -Be ''
            $result.ExitCode | Should -Be 0
        }

        It 'does not duplicate output after the provider completes' {
            $fixture = New-RepoFlowFakeAgentProcessFixture `
                -Directory $TestDrive `
                -Name 'no-duplicate' `
                -Spec ([pscustomobject]@{
                    pwshPath = (Get-Command pwsh).Source
                    exitCode = 0
                    waitMs = 50
                    steps = @(
                        [pscustomobject]@{
                            stream = 'stdout'
                            text = 'final line'
                            delayMs = 0
                        }
                    )
                })

            $result = Invoke-RepoFlowAgentProcessWithHeartbeat `
                -Provider 'future-provider' `
                -ExecutablePath (Get-Command pwsh).Source `
                -Arguments @(
                    '-NoProfile',
                    '-File',
                    $fixture.ScriptPath,
                    $fixture.SpecPath
                ) `
                -WorkingDirectory $TestDrive `
                -Prompt 'ignored' `
                -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                -HeartbeatSeconds 5

            @($script:hostOutput) | Should -Be @('final line')
            $script:hostOutput.Count | Should -Be 1
            $result.StandardOutput | Should -Be 'final line'
        }

        It 'returns the provider exit code and captured diagnostics when the provider fails' {
            $fixture = New-RepoFlowFakeAgentProcessFixture `
                -Directory $TestDrive `
                -Name 'non-zero-exit' `
                -Spec ([pscustomobject]@{
                    pwshPath = (Get-Command pwsh).Source
                    exitCode = 7
                    waitMs = 0
                    steps = @(
                        [pscustomobject]@{
                            stream = 'stdout'
                            text = 'before failure'
                            delayMs = 0
                        }
                        [pscustomobject]@{
                            stream = 'stderr'
                            text = 'failure detail'
                            delayMs = 0
                        }
                    )
                })

            $result = Invoke-RepoFlowAgentProcessWithHeartbeat `
                -Provider 'future-provider' `
                -ExecutablePath (Get-Command pwsh).Source `
                -Arguments @(
                    '-NoProfile',
                    '-File',
                    $fixture.ScriptPath,
                    $fixture.SpecPath
                ) `
                -WorkingDirectory $TestDrive `
                -Prompt 'ignored' `
                -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                -HeartbeatSeconds 5

            $result.ExitCode | Should -Be 7
            $result.StandardOutput | Should -Be 'before failure'
            $result.StandardError | Should -Be 'failure detail'
        }

        It 'captures the final message written by a fake provider' {
            $finalMessagePath = Join-Path $TestDrive 'final-message.md'
            $fixture = New-RepoFlowFakeAgentProcessFixture `
                -Directory $TestDrive `
                -Name 'final-message' `
                -Spec ([pscustomobject]@{
                    pwshPath = (Get-Command pwsh).Source
                    exitCode = 0
                    waitMs = 0
                    finalMessagePath = $finalMessagePath
                    finalMessage = 'final from provider'
                    steps = @(
                        [pscustomobject]@{
                            stream = 'stdout'
                            text = 'streamed output'
                            delayMs = 0
                        }
                    )
                })

            $result = Invoke-RepoFlowAgentProcessWithHeartbeat `
                -Provider 'future-provider' `
                -ExecutablePath (Get-Command pwsh).Source `
                -Arguments @(
                    '-NoProfile',
                    '-File',
                    $fixture.ScriptPath,
                    $fixture.SpecPath
                ) `
                -WorkingDirectory $TestDrive `
                -Prompt 'ignored' `
                -FinalMessagePath $finalMessagePath `
                -HeartbeatSeconds 5

            Get-RepoFlowAgentFinalMessage -Path $finalMessagePath |
                Should -Be 'final from provider'
            $result.StandardOutput | Should -Be 'streamed output'
        }

        It 'kills the provider tree when output streaming is interrupted' {
            $markerPath = Join-Path $TestDrive 'cancellation-marker.txt'
            $fixture = New-RepoFlowFakeAgentProcessFixture `
                -Directory $TestDrive `
                -Name 'cancelled-tree' `
                -Spec ([pscustomobject]@{
                    pwshPath = (Get-Command pwsh).Source
                    exitCode = 0
                    waitMs = 10000
                    spawnChild = $true
                    markerPath = $markerPath
                    steps = @(
                        [pscustomobject]@{
                            stream = 'stdout'
                            text = 'stop now'
                            delayMs = 0
                        }
                    )
                })

            $script:throwOnHostLine = 'stop now'

            {
                Invoke-RepoFlowAgentProcessWithHeartbeat `
                    -Provider 'future-provider' `
                    -ExecutablePath (Get-Command pwsh).Source `
                    -Arguments @(
                        '-NoProfile',
                        '-File',
                        $fixture.ScriptPath,
                        $fixture.SpecPath
                    ) `
                    -WorkingDirectory $TestDrive `
                    -Prompt 'ignored' `
                    -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                    -HeartbeatSeconds 5
            } | Should -Throw '*Simulated cancellation*'

            Start-Sleep -Seconds 3
            Test-Path -LiteralPath $markerPath | Should -BeFalse
        }
    }
}

Describe 'RepoFlow agent version handling' {
    InModuleScope RepoFlow {
        It 'extracts semantic versions from prefixed CLI output' {
            Get-RepoFlowSemanticVersionFromText -Text 'codex-cli 1.2.3' |
                Should -Be '1.2.3'
            Get-RepoFlowSemanticVersionFromText -Text '2.1.154 (Claude Code)' |
                Should -Be '2.1.154'
        }

        It 'compares semantic versions as a lower bound' {
            Test-RepoFlowSemanticVersionAtLeast `
                -InstalledVersion '2.1.154' `
                -MinimumVersion '2.1.0' |
                Should -BeTrue

            Test-RepoFlowSemanticVersionAtLeast `
                -InstalledVersion '2.0.9' `
                -MinimumVersion '2.1.0' |
                Should -BeFalse
        }

        It 'fails clearly when the installed CLI is too old' {
            {
                Assert-RepoFlowAgentCliVersion `
                    -Provider 'claude' `
                    -InstalledVersion '2.0.0' `
                    -MinimumVersion '2.1.0'
            } | Should -Throw '*claude*Installed version: 2.0.0*Required minimum version: 2.1.0*'
        }
    }
}

Describe 'RepoFlow agent argument construction' {
    InModuleScope RepoFlow {
        It 'passes the configured model to Codex' {
            $arguments = New-RepoFlowCodexArguments `
                -RepositoryRoot 'C:\repo' `
                -FinalMessagePath 'C:\tmp\final.md' `
                -Model 'gpt-5.5' `
                -ReasoningEffort 'medium'

            $modelIndex = [Array]::IndexOf($arguments, '--model')
            $modelIndex | Should -BeGreaterOrEqual 0
            $arguments[$modelIndex + 1] | Should -Be 'gpt-5.5'
            $arguments | Should -Contain 'model_reasoning_effort="medium"'
        }

        It 'passes the configured model and effort to Claude' {
            $arguments = New-RepoFlowClaudeArguments `
                -Model 'claude-sonnet-4-6' `
                -ReasoningEffort 'xhigh'

            $modelIndex = [Array]::IndexOf($arguments, '--model')
            $effortIndex = [Array]::IndexOf($arguments, '--effort')

            $arguments[$modelIndex + 1] | Should -Be 'claude-sonnet-4-6'
            $arguments[$effortIndex + 1] | Should -Be 'xhigh'
            $arguments | Should -Contain '--permission-mode'
            $arguments | Should -Contain 'acceptEdits'
            $arguments | Should -Contain '--no-session-persistence'
        }

        It 'maps minimal RepoFlow effort to low Claude effort' {
            $arguments = New-RepoFlowClaudeArguments `
                -Model 'claude-sonnet-4-6' `
                -ReasoningEffort 'minimal'

            $effortIndex = [Array]::IndexOf($arguments, '--effort')
            $arguments[$effortIndex + 1] | Should -Be 'low'
        }

        It 'never includes Claude bypass permission arguments' {
            $arguments = New-RepoFlowClaudeArguments `
                -Model 'claude-sonnet-4-6' `
                -ReasoningEffort 'medium'

            $arguments | Should -Not -Contain 'bypassPermissions'
            $arguments | Should -Not -Contain '--dangerously-skip-permissions'
        }
    }
}

Describe 'RepoFlow Claude stream parsing' {
    InModuleScope RepoFlow {
        It 'extracts the final Claude message and usage' {
            $jsonLines = @'
not json
{"type":"assistant","message":{"content":[{"type":"text","text":"draft"}],"usage":{"input_tokens":10,"output_tokens":3}}}
{"type":"unknown","value":true}
{"type":"result","result":"final response","usage":{"input_tokens":2,"cache_read_input_tokens":1,"output_tokens":5}}
'@

            $result = Get-RepoFlowClaudeResult -JsonLines $jsonLines

            $result.FinalMessage | Should -Be 'final response'
            $result.Usage.InputTokens | Should -Be 12
            $result.Usage.CachedInputTokens | Should -Be 1
            $result.Usage.OutputTokens | Should -Be 8
        }

        It 'ignores malformed stream-json lines' {
            $result = Get-RepoFlowClaudeResult -JsonLines @'
{"type":"assistant","message":{"content":[{"type":"text","text":"still works"}]}}
{bad json}
'@

            $result.FinalMessage | Should -Be 'still works'
            $result.Usage.InputTokens | Should -Be 0
        }

        It 'writes the final Claude response to the configured final-message path' {
            $path = Join-Path ([System.IO.Path]::GetTempPath()) ("repo-flow-claude-{0}.md" -f [guid]::NewGuid().ToString('N'))

            try {
                Mock Invoke-RepoFlowAgentProcessWithHeartbeat {
                    [pscustomobject]@{
                        ExitCode = 0
                        StandardOutput = '{"type":"result","result":"final from claude"}'
                        StandardError = ''
                        DurationSeconds = 2
                    }
                }

                Invoke-RepoFlowClaudeWithHeartbeat `
                    -RepositoryRoot $TestDrive `
                    -Prompt 'do work' `
                    -FinalMessagePath $path `
                    -ExecutablePath 'claude' `
                    -Model 'claude-sonnet-4-6' `
                    -ReasoningEffort 'medium' `
                    -HeartbeatSeconds 5 |
                    Out-Null

                Get-Content -LiteralPath $path -Raw |
                    Should -BeLike "final from claude*"
            }
            finally {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'RepoFlow agent provider dispatch' {
    InModuleScope RepoFlow {
        BeforeEach {
            Mock Get-RepoFlowAgentCliVersion {
                [pscustomobject]@{
                    ExecutablePath = 'agent'
                    Version = '2.1.154'
                    Text = 'agent 2.1.154'
                }
            }
        }

        It 'dispatches to Codex with the configured model' {
            $config = [pscustomobject]@{
                agent = [pscustomobject]@{
                    provider = 'codex'
                    command = 'codex'
                    model = 'gpt-5.5'
                    minimumCliVersion = $null
                    heartbeatSeconds = 5
                    reasoningEffort = 'medium'
                }
            }

            Mock Invoke-RepoFlowCodexWithHeartbeat {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                    Usage = New-RepoFlowAgentUsage
                    DurationSeconds = 0
                }
            } -ParameterFilter { $Model -eq 'gpt-5.5' -and $ReasoningEffort -eq 'medium' }
            Mock Invoke-RepoFlowClaudeWithHeartbeat {
                throw 'Claude should not be called'
            }

            Invoke-RepoFlowAgent `
                -RepositoryRoot $TestDrive `
                -Prompt 'do work' `
                -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                -Config $config |
                Out-Null

            Should -Invoke Invoke-RepoFlowCodexWithHeartbeat -Times 1 -Exactly
            Should -Invoke Invoke-RepoFlowClaudeWithHeartbeat -Times 0 -Exactly
        }

        It 'dispatches to Claude with the configured model' {
            $config = [pscustomobject]@{
                agent = [pscustomobject]@{
                    provider = 'claude'
                    command = 'claude'
                    model = 'claude-sonnet-4-6'
                    minimumCliVersion = $null
                    heartbeatSeconds = 5
                    reasoningEffort = 'medium'
                }
            }

            Mock Invoke-RepoFlowClaudeWithHeartbeat {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                    Usage = New-RepoFlowAgentUsage
                    DurationSeconds = 0
                }
            } -ParameterFilter { $Model -eq 'claude-sonnet-4-6' -and $ReasoningEffort -eq 'medium' }
            Mock Invoke-RepoFlowCodexWithHeartbeat {
                throw 'Codex should not be called'
            }

            Invoke-RepoFlowAgent `
                -RepositoryRoot $TestDrive `
                -Prompt 'do work' `
                -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                -Config $config |
                Out-Null

            Should -Invoke Invoke-RepoFlowClaudeWithHeartbeat -Times 1 -Exactly
            Should -Invoke Invoke-RepoFlowCodexWithHeartbeat -Times 0 -Exactly
        }

        It 'keeps the initial agent metadata visible before dispatching' {
            $script:messages = [System.Collections.Generic.List[string]]::new()

            Mock Write-Host {
                param($Object)

                if ($PSBoundParameters.ContainsKey('Object')) {
                    $script:messages.Add([string]$Object)
                }
            }
            Mock Invoke-RepoFlowCodexWithHeartbeat {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = ''
                    Usage = New-RepoFlowAgentUsage
                    DurationSeconds = 0
                }
            } -ParameterFilter { $Model -eq 'gpt-5.5' -and $ReasoningEffort -eq 'medium' }

            $config = [pscustomobject]@{
                agent = [pscustomobject]@{
                    provider = 'codex'
                    command = 'codex'
                    model = 'gpt-5.5'
                    minimumCliVersion = $null
                    heartbeatSeconds = 5
                    reasoningEffort = 'medium'
                }
            }

            Invoke-RepoFlowAgent `
                -RepositoryRoot $TestDrive `
                -Prompt 'do work' `
                -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                -Config $config |
                Out-Null

            @($script:messages) | Should -Be @(
                '[AGENT] Provider: codex',
                '[AGENT] Model: gpt-5.5',
                '[AGENT] CLI version: 2.1.154',
                '[AGENT] Reasoning effort: medium'
            )
        }

        It 'rejects unsupported providers before invoking a CLI' {
            $config = [pscustomobject]@{
                agent = [pscustomobject]@{
                    provider = 'other'
                    command = 'other'
                    model = 'other-model'
                    minimumCliVersion = $null
                    heartbeatSeconds = 5
                    reasoningEffort = 'medium'
                }
            }

            {
                Invoke-RepoFlowAgent `
                    -RepositoryRoot $TestDrive `
                    -Prompt 'do work' `
                    -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                    -Config $config
            } | Should -Throw '*Unsupported agent provider: other*'

            Should -Invoke Get-RepoFlowAgentCliVersion -Times 0 -Exactly
        }

        It 'stops before dispatch when the CLI version is too old' {
            $config = [pscustomobject]@{
                agent = [pscustomobject]@{
                    provider = 'codex'
                    command = 'codex'
                    model = 'gpt-5.5'
                    minimumCliVersion = '2.0.0'
                    heartbeatSeconds = 5
                    reasoningEffort = 'medium'
                }
            }

            Mock Get-RepoFlowAgentCliVersion {
                [pscustomobject]@{
                    ExecutablePath = 'codex'
                    Version = '1.9.9'
                    Text = 'codex-cli 1.9.9'
                }
            }
            Mock Invoke-RepoFlowCodexWithHeartbeat {
                throw 'Codex should not be called'
            }

            {
                Invoke-RepoFlowAgent `
                    -RepositoryRoot $TestDrive `
                    -Prompt 'do work' `
                    -FinalMessagePath (Join-Path $TestDrive 'final.md') `
                    -Config $config
            } | Should -Throw '*codex*Installed version: 1.9.9*Required minimum version: 2.0.0*'

            Should -Invoke Invoke-RepoFlowCodexWithHeartbeat -Times 0 -Exactly
        }
    }
}

Describe 'RepoFlow agent run state tracking' {
    InModuleScope RepoFlow {
        It 'records the current changed-file count when starting a review run' {
            $script:capturedState = $null

            Mock Read-RepoFlowAgentRunState { $null }
            Mock Get-RepoFlowCommitHash { 'a' * 40 }
            Mock Get-RepoFlowChangedFileCount { 3 }
            Mock Write-RepoFlowAgentRunState {
                param(
                    [string]$RepositoryRoot,
                    $State
                )

                $script:capturedState = $State
            }

            $config = [pscustomobject]@{
                agent = [pscustomobject]@{
                    provider = 'codex'
                    model = 'gpt-5.5'
                }
            }

            $state = Start-RepoFlowReviewAgentRunState `
                -RepositoryRoot $TestDrive `
                -Repository 'owner/repository' `
                -Branch 'review/123' `
                -IssueNumber 123 `
                -PullRequestNumber 456 `
                -PrCommentId 789 `
                -Config $config

            $script:capturedState | Should -Not -BeNullOrEmpty
            $state.changedFileCount | Should -Be 3
            $script:capturedState.changedFileCount | Should -Be 3
        }
    }
}

Describe 'RepoFlow Claude error normalisation' {
    InModuleScope RepoFlow {
        It 'extracts Claude model errors from stream-json' {
            $jsonLines = @'
{"type":"assistant","message":{"content":[{"type":"text","text":"The selected model does not exist."}],"error":"model_not_found"}}
{"type":"result","is_error":true,"api_error_status":404,"result":"The selected model does not exist."}
'@

            $result = Get-RepoFlowClaudeResult -JsonLines $jsonLines

            $result.IsError | Should -BeTrue
            $result.ErrorCode | Should -Be 'model_not_found'
            $result.ErrorMessage | Should -Be 'The selected model does not exist.'
        }

        It 'returns a concise failure instead of the full Claude stream' {
            $path = Join-Path $TestDrive 'claude-error.md'
            $stream = @'
{"type":"system","subtype":"init","model":"bad-model","tools":["Read","Edit"]}
{"type":"assistant","message":{"content":[{"type":"text","text":"Model is unavailable."}],"error":"model_not_found"}}
{"type":"result","is_error":true,"result":"Model is unavailable."}
'@

            Mock Invoke-RepoFlowAgentProcessWithHeartbeat {
                [pscustomobject]@{
                    ExitCode = 0
                    StandardOutput = $stream
                    StandardError = ''
                    DurationSeconds = 1
                }
            }

            $result = Invoke-RepoFlowClaudeWithHeartbeat `
                -RepositoryRoot $TestDrive `
                -Prompt 'do work' `
                -FinalMessagePath $path `
                -ExecutablePath 'claude' `
                -Model 'bad-model' `
                -ReasoningEffort 'medium' `
                -HeartbeatSeconds 5

            $result.ExitCode | Should -Be 1
            $result.ErrorCode | Should -Be 'model_not_found'
            $result.Text | Should -BeLike "*bad-model*model_not_found*Model is unavailable*"
            $result.Text | Should -Not -Match '"type":"system"'
            Test-Path -LiteralPath $path | Should -BeFalse
        }
    }
}
