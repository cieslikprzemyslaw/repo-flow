BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow queue state' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:TempRoot = Join-Path (
                [System.IO.Path]::GetTempPath()
            ) ('repo-flow-queue-state-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
            $script:ConfigPath = Join-Path $script:TempRoot '.repo-flow.json'
            '{}' | Set-Content -LiteralPath $script:ConfigPath -Encoding utf8
            $script:Manifest = [pscustomobject]@{
                name = 'test queue'
                path = Join-Path $script:TempRoot 'queue.json'
                hash = ('a' * 64)
                tasks = @(
                    [pscustomobject]@{
                        position = 0
                        issueNumber = 11
                        repository = 'flow'
                        ciMode = 'require-passing'
                        automatedReview = $true
                    },
                    [pscustomobject]@{
                        position = 1
                        issueNumber = 12
                        repository = 'flow'
                        ciMode = 'require-passing'
                        automatedReview = $true
                    }
                )
            }
        }

        AfterEach {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }

        It 'persists an auditable queue and advances one task at a time' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest `
                -Continuous

            Set-RepoFlowQueueTaskCheckpoint `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId `
                -Position 0 `
                -Phase 'merge-gate' `
                -Status paused `
                -PullRequestNumber 44 `
                -HeadSha ('b' * 40) `
                -PauseReason 'Awaiting merge.'

            Complete-RepoFlowQueueTask `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId `
                -Position 0

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId

            $saved.currentIndex | Should -Be 1
            $saved.tasks[0].status | Should -Be 'completed'
            $saved.tasks[0].pullRequestNumber | Should -Be 44
            $saved.tasks[1].status | Should -Be 'pending'

            $document = Read-RepoFlowStateDocument `
                -ConfigPath $script:ConfigPath
            $document.schemaVersion | Should -Be 3
            $document.queues.Count | Should -Be 1
        }

        It 'refuses to advance a task that is not the current position' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest

            {
                Complete-RepoFlowQueueTask `
                    -ConfigPath $script:ConfigPath `
                    -QueueId $queue.queueId `
                    -Position 1
            } | Should -Throw '*current position is 0*'

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId
            $saved.currentIndex | Should -Be 0
            $saved.tasks[0].status | Should -Be 'pending'
            $saved.tasks[1].status | Should -Be 'pending'
        }

        It 'does not overwrite a stop request with a late task checkpoint' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest
            Stop-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId `
                -Reason 'Stop won the race.'

            {
                Set-RepoFlowQueueTaskCheckpoint `
                    -ConfigPath $script:ConfigPath `
                    -QueueId $queue.queueId `
                    -Position 0 `
                    -Phase 'late-result' `
                    -Status running
            } | Should -Throw "*is 'stopped'*"

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId
            $saved.status | Should -Be 'stopped'
            $saved.currentIndex | Should -Be 0
            $saved.tasks[0].status | Should -Be 'stopped'
            $saved.tasks[1].status | Should -Be 'pending'
        }

        It 'refuses a duplicate active queue for the same manifest path' {
            Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest | Out-Null

            {
                Start-RepoFlowQueueRecord `
                    -ConfigPath $script:ConfigPath `
                    -Manifest $script:Manifest
            } | Should -Throw '*queue resume*'
        }

        It 'records an explicit pause without advancing or skipping tasks' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest `
                -Continuous

            Set-RepoFlowQueueUserPaused `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId `
                -Reason 'Pause requested by test.'

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId

            $saved.status | Should -Be 'paused'
            $saved.currentIndex | Should -Be 0
            $saved.tasks[0].status | Should -Be 'paused'
            $saved.tasks[0].phase | Should -Be 'paused-before-start'
            $saved.tasks[1].status | Should -Be 'pending'
        }

        It 'migrates schema version 2 state without losing run records' {
            @'
{
  "schemaVersion": 2,
  "activeRepository": null,
  "runs": []
}
'@ | Set-Content `
                -LiteralPath (Get-RepoFlowStatePath -ConfigPath $script:ConfigPath) `
                -Encoding utf8

            $document = Read-RepoFlowStateDocument `
                -ConfigPath $script:ConfigPath

            $document.schemaVersion | Should -Be 3
            $document.runs.Count | Should -Be 0
            $document.queues.Count | Should -Be 0
        }
    }
}
