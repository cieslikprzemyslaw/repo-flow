BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow diagnostic text bounding' {
    InModuleScope RepoFlow {
        It 'preserves short diagnostic text' {
            Get-RepoFlowBoundedText `
                -Text 'short output' `
                -MaximumCharacters 256 `
                -HeadCharacters 64 |
                Should -Be 'short output'
        }

        It 'keeps both the beginning and end of long diagnostic text' {
            $text = ('A' * 200) + ('B' * 200) + ('Z' * 200)

            $result = Get-RepoFlowBoundedText `
                -Text $text `
                -MaximumCharacters 256 `
                -HeadCharacters 64

            $result.Length | Should -BeLessOrEqual 256
            $result.StartsWith('A' * 32) | Should -BeTrue
            $result.EndsWith('Z' * 32) | Should -BeTrue
            $result | Should -Match 'RepoFlow omitted'
        }
    }
}

Describe 'RepoFlow changed-file diagnostics' {
    InModuleScope RepoFlow {
        It 'returns unique pull-request changed files' {
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = "src/a.ts`nsrc/b.ts`nsrc/a.ts"
                }
            }

            $files = @(Get-RepoFlowPullRequestChangedFiles -BaseBranch 'master')

            $files | Should -HaveCount 2
            $files | Should -Contain 'src/a.ts'
            $files | Should -Contain 'src/b.ts'
        }

        It 'returns the bounded pull-request diff text' {
            Mock Invoke-RepoFlowCommand {
                [pscustomobject]@{
                    ExitCode = 0
                    Text = @"
diff --git a/src/a.ts b/src/a.ts
index 1234567..89abcde 100644
--- a/src/a.ts
+++ b/src/a.ts
@@ -1 +1 @@
-old
+new
"@
                }
            }

            $diff = Get-RepoFlowPullRequestDiff -BaseBranch 'master'

            $diff | Should -Match 'diff --git a/src/a.ts b/src/a.ts'
            $diff | Should -Match '@@ -1 \+1 @@'
            $diff | Should -Not -Match 'src/a.ts \|'
        }

        It 'formats an empty changed-file list clearly' {
            Format-RepoFlowChangedFiles -Files @() |
                Should -Be '- No changed files were reported.'
        }
    }
}
