BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow markdown helpers' {
    InModuleScope RepoFlow {
        It 'creates a bounded branch slug' {
            $slug = ConvertTo-RepoFlowSlug `
                -Value 'Add User Identity to the Right Side of the Topbar'

            $slug |
                Should -Be 'add-user-identity-to-the-right-side-of-the-topbar'

            $slug.Length |
                Should -BeLessOrEqual 55
        }

        It 'extracts a markdown section' {
            $body = @'
## Changes

- One
- Two

## Security impact

None.
'@

            $section = Get-RepoFlowMarkdownSection `
                -Body $body `
                -Heading 'Changes'

            $normalisedSection = $section -replace "`r`n", "`n"

            $normalisedSection |
                Should -Be "- One`n- Two"
        }

        It 'expands configured message placeholders' {
            $message = Expand-RepoFlowMessageTemplate `
                -Template '{verb} #{issueNumber}: {issueTitle}' `
                -Values @{
                    verb = 'Implement'
                    issueNumber = 66
                    issueTitle = 'Add user identity'
                }

            $message |
                Should -Be 'Implement #66: Add user identity'
        }

        It 'rejects unknown message placeholders' {
            {
                Expand-RepoFlowMessageTemplate `
                    -Template '{unknown}' `
                    -Values @{ issueNumber = 66 }
            } | Should -Throw '*Unknown message placeholder*'
        }
    }
}
