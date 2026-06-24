BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow queue execution integration' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:TempRoot = Join-Path (
                [System.IO.Path]::GetTempPath()
            ) ('repo-flow-queue-workflow-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
            $script:ConfigPath = Join-Path $script:TempRoot '.repo-flow.json'
            '{}' | Set-Content -LiteralPath $script:ConfigPath -Encoding utf8
            $script:Manifest = [pscustomobject]@{
                name = 'integration queue'
                path = Join-Path $script:TempRoot 'queue.json'
                hash = ('c' * 64)
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

        It 'completes two tasks in explicit order after confirmed merges' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest `
                -Continuous
            $script:ObservedIssues = [System.Collections.Generic.List[int]]::new()

            Mock Invoke-RepoFlowQueueTask {
                param($Task)
                $script:ObservedIssues.Add([int]$Task.issueNumber) | Out-Null
                return New-RepoFlowQueueTaskResult `
                    -Status completed `
                    -Reason 'Merged and cleaned.'
            }

            Invoke-RepoFlowQueueExecution `
                -Manifest $script:Manifest `
                -QueueId $queue.queueId `
                -StateConfigPath $script:ConfigPath `
                -ConfigPath $script:ConfigPath `
                -Continuous

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId

            ($script:ObservedIssues.ToArray() -join ',') | Should -Be '11,12'
            $saved.status | Should -Be 'completed'
            $saved.currentIndex | Should -Be 2
            @($saved.tasks | Where-Object status -eq 'completed').Count |
                Should -Be 2
        }

        It 'pauses without skipping the task when CI handling fails' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest

            Mock Invoke-RepoFlowQueueTask {
                throw 'Passing CI is required; checks failed.'
            }

            {
                Invoke-RepoFlowQueueExecution `
                    -Manifest $script:Manifest `
                    -QueueId $queue.queueId `
                    -StateConfigPath $script:ConfigPath `
                    -ConfigPath $script:ConfigPath
            } | Should -Throw '*checks failed*'

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId
            $saved.status | Should -Be 'paused'
            $saved.currentIndex | Should -Be 0
            $saved.tasks[0].phase | Should -Be 'failed'
            $saved.tasks[1].status | Should -Be 'pending'
        }

        It 'pauses and fails closed when a task returns an invalid result' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest

            Mock Invoke-RepoFlowQueueTask {
                return [pscustomobject]@{ Status = 'unknown' }
            }

            {
                Invoke-RepoFlowQueueExecution `
                    -Manifest $script:Manifest `
                    -QueueId $queue.queueId `
                    -StateConfigPath $script:ConfigPath `
                    -ConfigPath $script:ConfigPath
            } | Should -Throw "*unsupported status 'unknown'*"

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId
            $saved.status | Should -Be 'paused'
            $saved.currentIndex | Should -Be 0
            $saved.tasks[0].phase | Should -Be 'invalid-result'
            $saved.tasks[1].status | Should -Be 'pending'
        }

        It 'pauses on an automated review failure' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest

            Mock Invoke-RepoFlowQueueTask {
                return New-RepoFlowQueueTaskResult `
                    -Status paused `
                    -Reason 'Automated review requested manual review.'
            }

            Invoke-RepoFlowQueueExecution `
                -Manifest $script:Manifest `
                -QueueId $queue.queueId `
                -StateConfigPath $script:ConfigPath `
                -ConfigPath $script:ConfigPath

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId
            $saved.status | Should -Be 'paused'
            $saved.pauseReason | Should -Match 'manual review'
            $saved.currentIndex | Should -Be 0
        }

        It 'resumes the same queue after an interrupted task' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest

            Mock Invoke-RepoFlowQueueTask {
                throw 'Agent interrupted.'
            }

            {
                Invoke-RepoFlowQueueExecution `
                    -Manifest $script:Manifest `
                    -QueueId $queue.queueId `
                    -StateConfigPath $script:ConfigPath `
                    -ConfigPath $script:ConfigPath
            } | Should -Throw '*Agent interrupted*'

            Set-RepoFlowQueueRunning `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId

            Mock Invoke-RepoFlowQueueTask {
                return New-RepoFlowQueueTaskResult `
                    -Status completed `
                    -Reason 'Recovered and merged.'
            }

            Invoke-RepoFlowQueueExecution `
                -Manifest $script:Manifest `
                -QueueId $queue.queueId `
                -StateConfigPath $script:ConfigPath `
                -ConfigPath $script:ConfigPath

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId
            $saved.queueId | Should -Be $queue.queueId
            $saved.tasks.Count | Should -Be 2
            $saved.currentIndex | Should -Be 1
            $saved.status | Should -Be 'paused'
            $saved.tasks[0].status | Should -Be 'completed'
        }

        It 'honours a stop request before starting another task' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest `
                -Continuous
            Stop-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId `
                -Reason 'Stopped by test.'

            Mock Invoke-RepoFlowQueueTask {
                throw 'Task must not run.'
            }

            Invoke-RepoFlowQueueExecution `
                -Manifest $script:Manifest `
                -QueueId $queue.queueId `
                -StateConfigPath $script:ConfigPath `
                -ConfigPath $script:ConfigPath `
                -Continuous

            Should -Invoke Invoke-RepoFlowQueueTask -Times 0 -Exactly
            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId
            $saved.status | Should -Be 'stopped'
            $saved.currentIndex | Should -Be 0
            $saved.tasks[0].status | Should -Be 'stopped'
            $saved.tasks[1].status | Should -Be 'pending'
        }

        It 'pauses at the explicit merge gate' {
            $queue = Start-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -Manifest $script:Manifest `
                -Continuous

            Mock Invoke-RepoFlowQueueTask {
                return New-RepoFlowQueueTaskResult `
                    -Status merge-gate `
                    -Reason 'Explicit merge required.' `
                    -PullRequest ([pscustomobject]@{
                        number = 91
                        headRefOid = ('d' * 40)
                    })
            }

            Invoke-RepoFlowQueueExecution `
                -Manifest $script:Manifest `
                -QueueId $queue.queueId `
                -StateConfigPath $script:ConfigPath `
                -ConfigPath $script:ConfigPath `
                -Continuous

            $saved = Get-RepoFlowQueueRecord `
                -ConfigPath $script:ConfigPath `
                -QueueId $queue.queueId
            $saved.status | Should -Be 'paused'
            $saved.tasks[0].phase | Should -Be 'merge-gate'
            $saved.tasks[0].pullRequestNumber | Should -Be 91
            $saved.currentIndex | Should -Be 0
        }
    }
}
