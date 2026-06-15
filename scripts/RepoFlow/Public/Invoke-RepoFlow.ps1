function Invoke-RepoFlow {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [ValidateSet(
            'issue',
            'pr',
            'branch',
            'ci',
            'config',
            'help'
        )]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Area,

        [Parameter(Position = 1)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Action,

        [Alias('IssueNumber', 'PrNumber')]
        [ValidateRange(1, 999999999)]
        [int]$Number,

        [Alias('Run')]
        [switch]$Apply,

        [switch]$SkipCreates,

        [switch]$LastPrComment,

        [ValidateRange(1, [long]::MaxValue)]
        [long]$PrCommentId,

        [ValidateSet('skip', 'observe', 'require-passing')]
        [string]$CiMode,

        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($Area)) {
        $Area = 'help'
    }

    $normalisedArea = $Area.Trim().ToLowerInvariant()

    if ($normalisedArea -eq 'help') {
        Show-RepoFlowHelp -Topic $Action
        return
    }

    if ([string]::IsNullOrWhiteSpace($Action)) {
        Show-RepoFlowHelp -Topic $normalisedArea
        return
    }

    $normalisedAction = $Action.Trim().ToLowerInvariant()

    switch ("$normalisedArea/$normalisedAction") {
        'issue/sync' {
            Invoke-RepoFlowIssueSyncWorkflow `
                -Apply:$Apply `
                -SkipCreates:$SkipCreates `
                -ConfigPath $ConfigPath
            return
        }

        'issue/run' {
            if ($Number -le 0) {
                throw "'issue run' requires -Number."
            }

            if ($LastPrComment -or $PrCommentId -gt 0) {
                throw (
                    "'issue run' does not accept PR-comment parameters. " +
                    "Use 'issue continue'."
                )
            }

            Invoke-RepoFlowIssueRunWorkflow `
                -Number $Number `
                -Apply:$Apply `
                -CiMode $CiMode `
                -ConfigPath $ConfigPath
            return
        }

        'issue/continue' {
            if ($Number -le 0) {
                throw "'issue continue' requires -Number."
            }

            if ($LastPrComment -and $PrCommentId -gt 0) {
                throw 'Use either -LastPrComment or -PrCommentId, not both.'
            }

            if (-not $LastPrComment -and $PrCommentId -le 0) {
                throw (
                    "'issue continue' requires " +
                    '-LastPrComment or -PrCommentId.'
                )
            }

            Invoke-RepoFlowIssueContinueWorkflow `
                -Number $Number `
                -LastPrComment:$LastPrComment `
                -PrCommentId $PrCommentId `
                -Apply:$Apply `
                -CiMode $CiMode `
                -ConfigPath $ConfigPath
            return
        }

        'pr/status' {
            if ($Number -le 0) {
                throw "'pr status' requires -Number."
            }

            Invoke-RepoFlowPrStatusWorkflow `
                -Number $Number `
                -ConfigPath $ConfigPath
            return
        }

        'pr/watch' {
            if ($Number -le 0) {
                throw "'pr watch' requires -Number."
            }

            Invoke-RepoFlowPrWatchWorkflow `
                -Number $Number `
                -ConfigPath $ConfigPath
            return
        }

        'pr/ready' {
            if ($Number -le 0) {
                throw "'pr ready' requires -Number."
            }

            Invoke-RepoFlowPrReadyWorkflow `
                -Number $Number `
                -Apply:$Apply `
                -CiMode $CiMode `
                -ConfigPath $ConfigPath
            return
        }

        { $_ -in @('pr/merge', 'pr/accept') } {
            if ($Number -le 0) {
                throw "'pr merge' requires -Number."
            }

            Invoke-RepoFlowPrMergeWorkflow `
                -Number $Number `
                -Apply:$Apply `
                -CiMode $CiMode `
                -ConfigPath $ConfigPath
            return
        }

        'branch/cleanup' {
            Invoke-RepoFlowBranchCleanupWorkflow `
                -Apply:$Apply `
                -ConfigPath $ConfigPath
            return
        }

        'ci/watch' {
            if ($Number -le 0) {
                throw "'ci watch' requires -Number."
            }

            Invoke-RepoFlowPrWatchWorkflow `
                -Number $Number `
                -ConfigPath $ConfigPath
            return
        }

        'config/validate' {
            Invoke-RepoFlowConfigValidateWorkflow `
                -ConfigPath $ConfigPath
            return
        }

        'config/show' {
            Invoke-RepoFlowConfigShowWorkflow `
                -ConfigPath $ConfigPath
            return
        }

        default {
            throw (
                "Unsupported RepoFlow command: {0} {1}. " +
                "Run '.\repo-flow.ps1 help' to see available commands."
            ) -f $Area, $Action
        }
    }
}
