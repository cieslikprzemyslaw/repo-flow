function Invoke-RepoFlowIssueResumeWorkflow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$Number,

        [switch]$Apply,

        [string]$CiMode,

        [string]$ConfigPath,

        [string]$Repo
    )

    $context = New-RepoFlowContext `
        -ConfigPath $ConfigPath `
        -Repo $Repo `
        -RequireGitHub

    for ($iteration = 0; $iteration -lt 12; $iteration++) {
        $resolved = Resolve-RepoFlowIssueResumePlan `
            -Context $context `
            -Number $Number
        $plan = $resolved.Plan

        Show-RepoFlowIssueResumePlan `
            -Plan $plan `
            -BranchState $resolved.BranchState

        if (-not $Apply) {
            Write-Host 'PLAN ONLY - no Git, GitHub, agent, or state mutation was performed.'
            Write-Host ''
            Write-Host 'Apply:'
            Write-Host "  rf issue resume -Number $Number -Apply"
            return
        }

        switch ([string]$plan.Action) {
            'terminal' {
                if ($null -ne $resolved.History.Active) {
                    $outcome = if (
                        $null -ne $plan.PullRequest -and
                        [string]$plan.PullRequest.state -eq 'MERGED'
                    ) {
                        'completed'
                    }
                    else {
                        'abandoned'
                    }

                    Complete-RepoFlowRunRecord `
                        -ConfigPath $resolved.StateConfigPath `
                        -RunId ([string]$plan.RunRecord.runId) `
                        -Outcome $outcome
                }

                Write-Host "Terminal result: $($plan.Reason)"
                return
            }

            'resume-initial-agent' {
                Invoke-RepoFlowResumedInitialAgent `
                    -Resolved $resolved `
                    -Context $context
                continue
            }

            'commit-initial-changes' {
                Complete-RepoFlowResumedCommit `
                    -Resolved $resolved `
                    -Context $context `
                    -Kind initial
                continue
            }

            'reconcile-initial-commit' {
                Set-RepoFlowReconciledCommitCheckpoint `
                    -Resolved $resolved `
                    -Kind initial
                continue
            }

            'push-initial-branch' {
                Push-RepoFlowResumedBranch `
                    -Resolved $resolved `
                    -Context $context `
                    -Kind initial
                continue
            }

            'reconcile-initial-push' {
                Push-RepoFlowResumedBranch `
                    -Resolved $resolved `
                    -Context $context `
                    -Kind initial `
                    -AlreadyPushed
                continue
            }

            'create-pull-request' {
                New-RepoFlowResumedPullRequest `
                    -Resolved $resolved `
                    -Context $context
                continue
            }

            'reconcile-pull-request' {
                Set-RepoFlowReconciledPullRequestCheckpoint `
                    -Resolved $resolved
                continue
            }

            'resume-review-agent' {
                if ($resolved.BranchState.IsDirty) {
                    Invoke-RepoFlowIssueContinueWorkflow `
                        -Number $Number `
                        -PrCommentId ([long]$plan.RunRecord.prCommentId) `
                        -Resume `
                        -Apply `
                        -CiMode $CiMode `
                        -Repo $Repo `
                        -ConfigPath $ConfigPath
                }
                else {
                    Complete-RepoFlowRunRecord `
                        -ConfigPath $resolved.StateConfigPath `
                        -RunId ([string]$plan.RunRecord.runId) `
                        -Outcome 'abandoned'
                    Invoke-RepoFlowIssueContinueWorkflow `
                        -Number $Number `
                        -PrCommentId ([long]$plan.RunRecord.prCommentId) `
                        -Apply `
                        -CiMode $CiMode `
                        -Repo $Repo `
                        -ConfigPath $ConfigPath
                }

                return
            }

            'commit-review-changes' {
                Complete-RepoFlowResumedCommit `
                    -Resolved $resolved `
                    -Context $context `
                    -Kind review
                continue
            }

            'reconcile-review-commit' {
                Set-RepoFlowReconciledCommitCheckpoint `
                    -Resolved $resolved `
                    -Kind review
                continue
            }

            'push-review-branch' {
                Push-RepoFlowResumedBranch `
                    -Resolved $resolved `
                    -Context $context `
                    -Kind review
                continue
            }

            'reconcile-review-push' {
                Push-RepoFlowResumedBranch `
                    -Resolved $resolved `
                    -Context $context `
                    -Kind review `
                    -AlreadyPushed
                continue
            }

            'observe-ci' {
                Invoke-RepoFlowResumedCi `
                    -Resolved $resolved `
                    -Context $context `
                    -CiMode $CiMode
                return
            }

            'complete-run' {
                Complete-RepoFlowRunRecord `
                    -ConfigPath $resolved.StateConfigPath `
                    -RunId ([string]$plan.RunRecord.runId) `
                    -Outcome 'completed'
                continue
            }

            'process-review-feedback' {
                if ($plan.AbandonActiveRun -and $null -ne $resolved.History.Active) {
                    Complete-RepoFlowRunRecord `
                        -ConfigPath $resolved.StateConfigPath `
                        -RunId ([string]$plan.RunRecord.runId) `
                        -Outcome 'abandoned'
                }

                Invoke-RepoFlowIssueContinueWorkflow `
                    -Number $Number `
                    -PrCommentId ([long]$plan.TrustedComment.id) `
                    -Apply `
                    -CiMode $CiMode `
                    -Repo $Repo `
                    -ConfigPath $ConfigPath
                return
            }

            default {
                throw "Unsupported issue-resume action: $($plan.Action)"
            }
        }
    }

    throw 'Issue resume did not converge after 12 deterministic phase transitions.'
}
