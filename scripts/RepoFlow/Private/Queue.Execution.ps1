function Invoke-RepoFlowQueueExecution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Manifest,

        [Parameter(Mandatory)]
        [string]$QueueId,

        [Parameter(Mandatory)]
        [string]$StateConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [switch]$Continuous
    )

    while ($true) {
        if (Test-RepoFlowQueueControlRequested `
            -ConfigPath $StateConfigPath `
            -QueueId $QueueId) {
            return
        }

        $queue = Get-RepoFlowQueueRecord `
            -ConfigPath $StateConfigPath `
            -QueueId $QueueId
        $position = [int]$queue.currentIndex

        if ($position -ge @($Manifest.tasks).Count) {
            Complete-RepoFlowQueueRecord `
                -ConfigPath $StateConfigPath `
                -QueueId $QueueId
            Write-Host "Queue '$QueueId' completed."
            return
        }

        $task = @($Manifest.tasks)[$position]
        Write-Host ''
        Write-Host (
            '[QUEUE] Task {0}/{1}: issue #{2}' -f
            ($position + 1),
            @($Manifest.tasks).Count,
            $task.issueNumber
        )

        Set-RepoFlowQueueTaskCheckpoint `
            -ConfigPath $StateConfigPath `
            -QueueId $QueueId `
            -Position $position `
            -Phase 'orchestrating' `
            -Status running

        try {
            $result = Invoke-RepoFlowQueueTask `
                -Task $task `
                -StateConfigPath $StateConfigPath `
                -ConfigPath $ConfigPath
        }
        catch {
            $reason = $_.Exception.Message

            if (Test-RepoFlowQueueControlRequested `
                -ConfigPath $StateConfigPath `
                -QueueId $QueueId) {
                return
            }

            Set-RepoFlowQueueTaskCheckpoint `
                -ConfigPath $StateConfigPath `
                -QueueId $QueueId `
                -Position $position `
                -Phase 'failed' `
                -Status paused `
                -PauseReason $reason
            Set-RepoFlowQueuePaused `
                -ConfigPath $StateConfigPath `
                -QueueId $QueueId `
                -Reason "Issue #$($task.issueNumber) failed: $reason"
            throw
        }

        if (Test-RepoFlowQueueControlRequested `
            -ConfigPath $StateConfigPath `
            -QueueId $QueueId) {
            return
        }

        $validResultStatuses = @('completed', 'merge-gate', 'paused')
        $resultStatus = if ($null -eq $result) {
            ''
        }
        else {
            [string](Get-RepoFlowProperty `
                -Object $result `
                -Name 'Status' `
                -Default '')
        }

        $resultReason = if ($null -eq $result) {
            ''
        }
        else {
            [string](Get-RepoFlowProperty `
                -Object $result `
                -Name 'Reason' `
                -Default '')
        }

        if (
            $resultStatus -notin $validResultStatuses -or
            [string]::IsNullOrWhiteSpace($resultReason)
        ) {
            $reason = if ([string]::IsNullOrWhiteSpace($resultStatus)) {
                'Queue task returned no valid status.'
            }
            elseif ($resultStatus -notin $validResultStatuses) {
                "Queue task returned unsupported status '$resultStatus'."
            }
            else {
                'Queue task returned no valid reason.'
            }

            Set-RepoFlowQueueTaskCheckpoint `
                -ConfigPath $StateConfigPath `
                -QueueId $QueueId `
                -Position $position `
                -Phase 'invalid-result' `
                -Status paused `
                -PauseReason $reason
            Set-RepoFlowQueuePaused `
                -ConfigPath $StateConfigPath `
                -QueueId $QueueId `
                -Reason "Issue #$($task.issueNumber) failed: $reason"
            throw $reason
        }

        $resultRunRecord = Get-RepoFlowProperty `
            -Object $result `
            -Name 'RunRecord' `
            -Default $null
        $resultPullRequest = Get-RepoFlowProperty `
            -Object $result `
            -Name 'PullRequest' `
            -Default $null

        $resolvedRepositoryName = [string](Get-RepoFlowProperty `
            -Object $result `
            -Name 'RepositoryName' `
            -Default '')
        if ([string]::IsNullOrWhiteSpace($resolvedRepositoryName)) {
            $resolvedRepositoryName = [string](
                Get-RepoFlowQueueTaskRepositoryName -Task $task
            )
        }

        $runId = if ($null -ne $resultRunRecord) {
            [string]$resultRunRecord.runId
        }
        elseif (-not [string]::IsNullOrWhiteSpace($resolvedRepositoryName)) {
            $latest = Get-RepoFlowQueueLatestIssueRun `
                -ConfigPath $StateConfigPath `
                -Repository $resolvedRepositoryName `
                -IssueNumber ([int]$task.issueNumber)
            if ($null -eq $latest) { $null } else { [string]$latest.runId }
        }
        else {
            $null
        }
        $pullRequestNumber = if ($null -eq $resultPullRequest) {
            0
        }
        else {
            [int]$resultPullRequest.number
        }
        $headSha = if ($null -eq $resultPullRequest) {
            $null
        }
        else {
            [string](Get-RepoFlowProperty `
                -Object $resultPullRequest `
                -Name 'headRefOid' `
                -Default $null)
        }

        switch ($resultStatus) {
            'completed' {
                Set-RepoFlowQueueTaskCheckpoint `
                    -ConfigPath $StateConfigPath `
                    -QueueId $QueueId `
                    -Position $position `
                    -Phase 'cleanup-completed' `
                    -Status running `
                    -RunId $runId `
                    -PullRequestNumber $pullRequestNumber `
                    -HeadSha $headSha
                Complete-RepoFlowQueueTask `
                    -ConfigPath $StateConfigPath `
                    -QueueId $QueueId `
                    -Position $position
                Write-Host "[QUEUE] $resultReason"

                if (-not $Continuous) {
                    $latestQueue = Get-RepoFlowQueueRecord `
                        -ConfigPath $StateConfigPath `
                        -QueueId $QueueId

                    if ([int]$latestQueue.currentIndex -lt @($Manifest.tasks).Count) {
                        Set-RepoFlowQueuePaused `
                            -ConfigPath $StateConfigPath `
                            -QueueId $QueueId `
                            -Reason (
                                'One task completed. Resume with -Continuous to ' +
                                'start the next task automatically.'
                            )
                        Write-Host 'Queue paused before the next task.'
                        return
                    }
                }

                continue
            }

            'merge-gate' {
                Set-RepoFlowQueueTaskCheckpoint `
                    -ConfigPath $StateConfigPath `
                    -QueueId $QueueId `
                    -Position $position `
                    -Phase 'merge-gate' `
                    -Status paused `
                    -RunId $runId `
                    -PullRequestNumber $pullRequestNumber `
                    -HeadSha $headSha `
                    -PauseReason $resultReason
                Set-RepoFlowQueuePaused `
                    -ConfigPath $StateConfigPath `
                    -QueueId $QueueId `
                    -Reason $resultReason
                Write-Warning $resultReason
                Write-Host ''
                Write-Host 'After manually validating the PR, merge it explicitly:'
                $repositoryArgument = if (
                    [string]::IsNullOrWhiteSpace($resolvedRepositoryName)
                ) {
                    ''
                }
                else {
                    " -Repo $resolvedRepositoryName"
                }
                Write-Host (
                    "  rf pr merge -Number $pullRequestNumber" +
                    "$repositoryArgument -Apply"
                )
                Write-Host 'Then resume the queue:'
                Write-Host "  rf queue resume -Manifest `"$($Manifest.path)`" -Continuous -Apply"
                return
            }

            'paused' {
                Set-RepoFlowQueueTaskCheckpoint `
                    -ConfigPath $StateConfigPath `
                    -QueueId $QueueId `
                    -Position $position `
                    -Phase ([string](Get-RepoFlowProperty `
                        -Object $result `
                        -Name 'Phase' `
                        -Default 'manual-review-required')) `
                    -Status paused `
                    -RunId $runId `
                    -PullRequestNumber $pullRequestNumber `
                    -HeadSha $headSha `
                    -PauseReason $resultReason
                Set-RepoFlowQueuePaused `
                    -ConfigPath $StateConfigPath `
                    -QueueId $QueueId `
                    -Reason $resultReason
                Write-Warning $resultReason
                return
            }
        }
    }
}

