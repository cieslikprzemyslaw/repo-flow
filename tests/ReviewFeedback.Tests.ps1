BeforeDiscovery {
    $modulePath = Join-Path $PSScriptRoot '../scripts/RepoFlow/RepoFlow.psd1'
    Import-Module $modulePath -Force
}

Describe 'RepoFlow review feedback trust boundary' {
    InModuleScope RepoFlow {
        BeforeEach {
            $config = [pscustomobject]@{
                reviewFeedback = [pscustomobject]@{
                    trustedAssociations = @('OWNER', 'MEMBER', 'COLLABORATOR')
                }
            }
        }

        It 'accepts an owner comment' {
            $comment = [pscustomobject]@{
                author_association = 'OWNER'
                user = [pscustomobject]@{ type = 'User' }
            }

            Test-RepoFlowTrustedComment -Comment $comment -Config $config | Should -BeTrue
        }

        It 'rejects an external comment' {
            $comment = [pscustomobject]@{
                author_association = 'NONE'
                user = [pscustomobject]@{ type = 'User' }
            }

            Test-RepoFlowTrustedComment -Comment $comment -Config $config | Should -BeFalse
        }

        It 'rejects bot comments even when association is trusted' {
            $comment = [pscustomobject]@{
                author_association = 'MEMBER'
                user = [pscustomobject]@{ type = 'Bot' }
            }

            Test-RepoFlowTrustedComment -Comment $comment -Config $config | Should -BeFalse
        }
    }
}

