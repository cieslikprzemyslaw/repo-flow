BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
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
