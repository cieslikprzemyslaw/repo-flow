BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow automated review contract' {
    BeforeAll {
        $env:REPO_FLOW_REVIEW_FIXTURE_DIRECTORY = Join-Path $PSScriptRoot 'fixtures/review'
    }

    AfterAll {
        Remove-Item Env:REPO_FLOW_REVIEW_FIXTURE_DIRECTORY -ErrorAction SilentlyContinue
    }

    InModuleScope RepoFlow {
        BeforeEach {
            $request = Get-Content -LiteralPath (
                Join-Path $env:REPO_FLOW_REVIEW_FIXTURE_DIRECTORY 'valid-request.json'
            ) -Raw | ConvertFrom-Json -Depth 30

            $result = Get-Content -LiteralPath (
                Join-Path $env:REPO_FLOW_REVIEW_FIXTURE_DIRECTORY 'valid-pass-result.json'
            ) -Raw | ConvertFrom-Json -Depth 30
        }

        It 'validates request and result fixtures against the v1 JSON schemas' {
            { Assert-RepoFlowReviewRequestEnvelope -Request $request } |
                Should -Not -Throw
            { Assert-RepoFlowReviewResultEnvelope -Result $result } |
                Should -Not -Throw
        }

        It 'round-trips a request with human-readable Markdown' {
            $comment = ConvertTo-RepoFlowReviewComment `
                -Envelope $request `
                -HumanSummary 'Automated review requested for the current PR head.'

            $comment | Should -Match '<!-- rf-review-request:v1 -->'
            $comment | Should -Match 'Automated review requested'

            $parsed = ConvertFrom-RepoFlowReviewComment `
                -Text $comment `
                -Kind 'request'

            $parsed.requestId | Should -Be $request.requestId
            $parsed.headSha | Should -Be $request.headSha
            @($parsed.changedFiles) | Should -HaveCount 3
        }

        It 'uses a safe Markdown fence when untrusted text contains backticks' {
            $hostileResult = Get-Content -LiteralPath (
                Join-Path $env:REPO_FLOW_REVIEW_FIXTURE_DIRECTORY 'hostile-result.json'
            ) -Raw | ConvertFrom-Json -Depth 30

            $comment = ConvertTo-RepoFlowReviewComment -Envelope $hostileResult

            $comment | Should -Match '(?m)^````json$'

            $parsed = ConvertFrom-RepoFlowReviewComment `
                -Text $comment `
                -Kind 'result'

            $parsed.warnings[0].explanation | Should -Match '\$\(Set-Content'
            $parsed.warnings[0].explanation | Should -Match '```'
        }

        It 'treats payload content as data and never evaluates it' {
            $sentinel = Join-Path $TestDrive 'review-payload-executed.txt'
            $result.verdict = 'manual_review'
            $result.warnings[0].explanation = (
                "`$(Set-Content -LiteralPath '$sentinel' -Value executed)"
            )

            $comment = ConvertTo-RepoFlowReviewComment -Envelope $result
            $parsed = ConvertFrom-RepoFlowReviewComment `
                -Text $comment `
                -Kind 'result'

            Test-Path -LiteralPath $sentinel | Should -BeFalse
            $parsed.warnings[0].explanation | Should -Match 'Set-Content'
        }

        It 'rejects unknown properties through JSON schema validation' {
            $request | Add-Member -NotePropertyName execute -NotePropertyValue 'whoami'

            {
                Assert-RepoFlowReviewRequestEnvelope -Request $request
            } | Should -Throw '*schema validation*'
        }

        It 'rejects duplicate changed-file paths' {
            $request.changedFiles = @(
                $request.changedFiles[0]
                [pscustomobject]@{
                    path = $request.changedFiles[0].path
                    status = 'modified'
                }
            )

            {
                Assert-RepoFlowReviewRequestEnvelope -Request $request
            } | Should -Throw '*duplicate value*'
        }

        It 'rejects repository path traversal in request and result payloads' {
            $request.changedFiles[0].path = '../outside.ps1'

            {
                Assert-RepoFlowReviewRequestEnvelope -Request $request
            } | Should -Throw '*safe repository-relative path*'

            $request.changedFiles[0].path = 'scripts/RepoFlow/Private/ReviewContract.Core.ps1'
            $result.verdict = 'changes_required'
            $result.blockers = @(
                [pscustomobject]@{
                    category = 'security'
                    explanation = 'Unsafe path supplied by an untrusted reviewer.'
                    path = 'C:\outside.ps1'
                }
            )

            {
                Assert-RepoFlowReviewResultEnvelope -Result $result
            } | Should -Throw '*safe repository-relative path*'
        }

        It 'rejects duplicate contract markers in one comment' {
            $comment = ConvertTo-RepoFlowReviewComment -Envelope $result
            $duplicateComment = "$comment`n`n$comment"

            {
                ConvertFrom-RepoFlowReviewComment `
                    -Text $duplicateComment `
                    -Kind 'result'
            } | Should -Throw '*duplicate contract markers*'
        }

        It 'rejects duplicate JSON property names before object conversion' {
            $json = $result | ConvertTo-Json -Depth 30
            $json = $json.Replace(
                '  "requestId": "review-request-0001",',
                "  `"requestId`": `"review-request-0001`",`n" +
                    "  `"requestId`": `"duplicate-request-0002`","
            )
            $json | Should -Match 'duplicate-request-0002'

            $comment = @(
                '<!-- rf-review-result:v1 -->'
                '```json'
                $json
                '```'
            ) -join "`n"

            {
                ConvertFrom-RepoFlowReviewComment `
                    -Text $comment `
                    -Kind 'result'
            } | Should -Throw '*duplicate JSON property names*'
        }

        It 'rejects unsupported marker versions before reading the payload' {
            $comment = ConvertTo-RepoFlowReviewComment -Envelope $result
            $unsupported = $comment.Replace(
                '<!-- rf-review-result:v1 -->',
                '<!-- rf-review-result:v2 -->'
            )

            {
                ConvertFrom-RepoFlowReviewComment `
                    -Text $unsupported `
                    -Kind 'result'
            } | Should -Throw '*version*unsupported*'
        }

        It 'allows surrounding Markdown but requires JSON immediately after the marker' {
            $comment = ConvertTo-RepoFlowReviewComment `
                -Envelope $result `
                -HumanSummary 'Review completed.'
            $comment = "$comment`n`nAdditional human notes."

            {
                ConvertFrom-RepoFlowReviewComment -Text $comment -Kind 'result'
            } | Should -Not -Throw

            $broken = $comment.Replace(
                '<!-- rf-review-result:v1 -->',
                "<!-- rf-review-result:v1 -->`nUnexpected text"
            )

            {
                ConvertFrom-RepoFlowReviewComment -Text $broken -Kind 'result'
            } | Should -Throw '*followed by one fenced JSON object*'
        }

        It 'rejects a result for a different request ID' {
            $result.requestId = 'different-request-0002'

            {
                Assert-RepoFlowReviewResultMatchesRequest `
                    -Request $request `
                    -Result $result `
                    -CurrentHeadSha $request.headSha `
                    -ProcessedRequestIds @()
            } | Should -Throw '*request ID does not match*'
        }

        It 'rejects a result for a different requested head SHA' {
            $result.reviewedHeadSha = '3333333333333333333333333333333333333333'

            {
                Assert-RepoFlowReviewResultMatchesRequest `
                    -Request $request `
                    -Result $result `
                    -CurrentHeadSha $request.headSha `
                    -ProcessedRequestIds @()
            } | Should -Throw '*head SHA does not match*'
        }

        It 'rejects a stale result after the pull-request head changes' {
            {
                Assert-RepoFlowReviewResultMatchesRequest `
                    -Request $request `
                    -Result $result `
                    -CurrentHeadSha '4444444444444444444444444444444444444444' `
                    -ProcessedRequestIds @()
            } | Should -Throw '*stale*head has changed*'
        }

        It 'rejects a duplicate result for an already processed request' {
            {
                Assert-RepoFlowReviewResultMatchesRequest `
                    -Request $request `
                    -Result $result `
                    -CurrentHeadSha $request.headSha `
                    -ProcessedRequestIds @($request.requestId)
            } | Should -Throw '*duplicate*already processed*'
        }

        It 'accepts the matching result for the current head' {
            {
                Assert-RepoFlowReviewResultMatchesRequest `
                    -Request $request `
                    -Result $result `
                    -CurrentHeadSha $request.headSha `
                    -ProcessedRequestIds @()
            } | Should -Not -Throw
        }

        It 'enforces verdict and blocker consistency' {
            $result.blockers = @(
                [pscustomobject]@{
                    category = 'correctness'
                    explanation = 'The result cannot pass with this blocker.'
                }
            )

            {
                Assert-RepoFlowReviewResultEnvelope -Result $result
            } | Should -Throw "*'pass' cannot contain blockers*"

            $result.verdict = 'changes_required'
            $result.blockers = @()

            {
                Assert-RepoFlowReviewResultEnvelope -Result $result
            } | Should -Throw "*'changes_required' requires a blocker*"
        }

        It 'rejects invalid finding line ranges' {
            $result.verdict = 'changes_required'
            $result.blockers = @(
                [pscustomobject]@{
                    category = 'correctness'
                    explanation = 'The range is reversed.'
                    path = 'scripts/RepoFlow/Private/ReviewContract.ps1'
                    startLine = 20
                    endLine = 10
                }
            )

            {
                Assert-RepoFlowReviewResultEnvelope -Result $result
            } | Should -Throw '*invalid line range*'
        }

        It 'rejects results completed before their request' {
            $result.completedAtUtc = '2026-06-24T09:20:00.0000000+00:00'

            {
                Assert-RepoFlowReviewResultMatchesRequest `
                    -Request $request `
                    -Result $result `
                    -CurrentHeadSha $request.headSha `
                    -ProcessedRequestIds @()
            } | Should -Throw '*predates its request*'
        }

        It 'rejects timestamps that are valid but not UTC' {
            $result.completedAtUtc = '2026-06-24T10:35:00.0000000+01:00'

            {
                Assert-RepoFlowReviewResultEnvelope -Result $result
            } | Should -Throw '*schema validation*'
        }

        It 'rejects oversized comments before parsing JSON' {
            $oversized = [string]::new(
                'x',
                $script:RepoFlowReviewCommentMaximumCharacters + 1
            )

            {
                ConvertFrom-RepoFlowReviewComment `
                    -Text $oversized `
                    -Kind 'request'
            } | Should -Throw '*exceeds*character limit*'
        }
    }
}
