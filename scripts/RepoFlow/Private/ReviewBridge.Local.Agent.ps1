function ConvertFrom-RepoFlowLocalReviewerOutput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory)]
        $Request,

        [Parameter(Mandatory)]
        [string]$CurrentHeadSha,

        [Parameter(Mandatory)]
        [string]$ExpectedReviewerId
    )

    $json = $Text.Trim()
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw 'Local reviewer returned an empty result.'
    }

    $fenced = [regex]::Match(
        $json,
        '(?s)\A```(?:json)?[ \t]*\r?\n(?<json>.*?)\r?\n```[ \t]*\z'
    )
    if ($fenced.Success) {
        $json = $fenced.Groups['json'].Value.Trim()
    }

    Assert-RepoFlowReviewJsonDocument -Json $json -Kind result
    Assert-RepoFlowReviewJsonSchema -Json $json -Kind result

    try {
        $result = $json | ConvertFrom-Json -Depth 30 -ErrorAction Stop
    }
    catch {
        throw 'Local reviewer result is not valid JSON.'
    }

    Assert-RepoFlowReviewResultEnvelope -Result $result
    Assert-RepoFlowReviewResultMatchesRequest `
        -Request $Request `
        -Result $result `
        -CurrentHeadSha $CurrentHeadSha `
        -ProcessedRequestIds @()

    if ([string]$result.reviewerId -cne $ExpectedReviewerId) {
        throw (
            "Local reviewer returned reviewerId '$($result.reviewerId)'; " +
            "expected '$ExpectedReviewerId'."
        )
    }

    return $result
}

function Invoke-RepoFlowLocalReviewerAgent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Prompt,

        [Parameter(Mandatory)]
        $Reviewer,

        [Parameter(Mandatory)]
        [string]$StateConfigPath,

        [Parameter(Mandatory)]
        [string]$RunId
    )

    $provider = [string]$Reviewer.provider
    $command = [string]$Reviewer.command
    $model = [string]$Reviewer.model
    $versionInfo = Get-RepoFlowAgentCliVersion -Provider $provider -Command $command
    $finalMessagePath = [System.IO.Path]::GetTempFileName()

    try {
        Write-Host "[REVIEWER] Provider: $provider"
        Write-Host "[REVIEWER] Model: $model"
        Write-Host "[REVIEWER] CLI version: $($versionInfo.Version)"
        Write-Host "[REVIEWER] Reasoning effort: $($Reviewer.reasoningEffort)"

        $run = switch ($provider) {
            'codex' {
                Invoke-RepoFlowCodexWithHeartbeat `
                    -RepositoryRoot $RepositoryRoot `
                    -Prompt $Prompt `
                    -FinalMessagePath $finalMessagePath `
                    -ExecutablePath ([string]$versionInfo.ExecutablePath) `
                    -Model $model `
                    -ReasoningEffort ([string]$Reviewer.reasoningEffort) `
                    -HeartbeatSeconds ([int]$Reviewer.heartbeatSeconds) `
                    -NoActivityWarningSeconds ([int]$Reviewer.noActivityWarningSeconds) `
                    -Phase 'local-reviewer-running' `
                    -StateConfigPath $StateConfigPath `
                    -RunId $RunId `
                    -SandboxMode 'read-only' `
                    -TimeoutSeconds ([int]$Reviewer.timeoutSeconds)
            }
            'claude' {
                Invoke-RepoFlowClaudeWithHeartbeat `
                    -RepositoryRoot $RepositoryRoot `
                    -Prompt $Prompt `
                    -FinalMessagePath $finalMessagePath `
                    -ExecutablePath ([string]$versionInfo.ExecutablePath) `
                    -Model $model `
                    -ReasoningEffort ([string]$Reviewer.reasoningEffort) `
                    -HeartbeatSeconds ([int]$Reviewer.heartbeatSeconds) `
                    -NoActivityWarningSeconds ([int]$Reviewer.noActivityWarningSeconds) `
                    -Phase 'local-reviewer-running' `
                    -StateConfigPath $StateConfigPath `
                    -RunId $RunId `
                    -PermissionMode 'plan' `
                    -TimeoutSeconds ([int]$Reviewer.timeoutSeconds)
            }
            default {
                throw "Unsupported reviewer provider: $provider"
            }
        }

        return [pscustomobject]@{
            ExitCode = [int]$run.ExitCode
            TimedOut = [bool](Get-RepoFlowProperty -Object $run -Name 'TimedOut' -Default $false)
            Text = [string]$run.Text
            FinalMessage = Get-RepoFlowAgentFinalMessage -Path $finalMessagePath
        }
    }
    finally {
        Remove-Item -LiteralPath $finalMessagePath -Force -ErrorAction SilentlyContinue
    }
}
