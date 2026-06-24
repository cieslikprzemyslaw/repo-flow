BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow queue manifest' {
    InModuleScope RepoFlow {
        BeforeEach {
            $script:TempRoot = Join-Path (
                [System.IO.Path]::GetTempPath()
            ) ('repo-flow-queue-manifest-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:TempRoot | Out-Null
            $script:ManifestPath = Join-Path $script:TempRoot 'queue.json'
        }

        AfterEach {
            Remove-Item -LiteralPath $script:TempRoot -Recurse -Force
        }

        It 'normalises an explicit ordered manifest and task overrides' {
            @'
{
  "schemaVersion": 1,
  "name": "release queue",
  "repository": "flow",
  "tasks": [
    { "issueNumber": 11 },
    {
      "issueNumber": 12,
      "repository": "report",
      "ciMode": "observe",
      "automatedReview": false
    }
  ]
}
'@ | Set-Content -LiteralPath $script:ManifestPath -Encoding utf8

            $manifest = Read-RepoFlowQueueManifest `
                -ManifestPath $script:ManifestPath

            $manifest.name | Should -Be 'release queue'
            $manifest.tasks.Count | Should -Be 2
            $manifest.tasks[0].position | Should -Be 0
            $manifest.tasks[0].repository | Should -Be 'flow'
            $manifest.tasks[0].ciMode | Should -BeNullOrEmpty
            $manifest.tasks[0].automatedReview | Should -BeTrue
            $manifest.tasks[1].repository | Should -Be 'report'
            $manifest.tasks[1].ciMode | Should -Be 'observe'
            $manifest.tasks[1].automatedReview | Should -BeFalse
            $manifest.hash | Should -Match '^[0-9a-f]{64}$'
        }

        It 'rejects duplicate repository and issue pairs' {
            @'
{
  "schemaVersion": 1,
  "repository": "flow",
  "tasks": [
    { "issueNumber": 11 },
    { "issueNumber": 11 }
  ]
}
'@ | Set-Content -LiteralPath $script:ManifestPath -Encoding utf8

            {
                Read-RepoFlowQueueManifest -ManifestPath $script:ManifestPath
            } | Should -Throw '*duplicate task*'
        }

        It 'rejects unknown task properties' {
            @'
{
  "schemaVersion": 1,
  "tasks": [
    { "issueNumber": 11, "script": "Invoke-Expression" }
  ]
}
'@ | Set-Content -LiteralPath $script:ManifestPath -Encoding utf8

            {
                Read-RepoFlowQueueManifest -ManifestPath $script:ManifestPath
            } | Should -Throw '*Unknown configuration property*'
        }
    }
}
