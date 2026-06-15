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
