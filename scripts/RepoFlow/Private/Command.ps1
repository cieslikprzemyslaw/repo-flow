function Assert-RepoFlowCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Get-Command -Name $Name -ErrorAction SilentlyContinue)) {
        throw "Required command not found: $Name"
    }
}

function Invoke-RepoFlowCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $output = & $Command @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output -join [Environment]::NewLine)

    if (-not $AllowFailure -and $exitCode -ne 0) {
        throw "$Command $($Arguments -join ' ') failed:$([Environment]::NewLine)$text"
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Text = $text
    }
}

function Invoke-RepoFlowJsonCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Command,

        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$AllowFailure
    )

    $stdoutPath = [System.IO.Path]::GetTempFileName()
    $stderrPath = [System.IO.Path]::GetTempFileName()

    try {
        & $Command @Arguments 1> $stdoutPath 2> $stderrPath
        $exitCode = $LASTEXITCODE
        $stdout = Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue
        $stderr = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue

        if (-not $AllowFailure -and $exitCode -ne 0) {
            throw "$Command $($Arguments -join ' ') failed:$([Environment]::NewLine)$stderr$([Environment]::NewLine)$stdout"
        }

        if ([string]::IsNullOrWhiteSpace($stdout)) {
            return [pscustomobject]@{
                ExitCode = $exitCode
                Data = $null
                StandardError = $stderr
            }
        }

        try {
            $data = $stdout | ConvertFrom-Json
        }
        catch {
            throw "Invalid JSON returned by $Command $($Arguments -join ' '):$([Environment]::NewLine)$stdout"
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Data = $data
            StandardError = $stderr
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Confirm-RepoFlowAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Prompt
    )

    $answer = Read-Host "$Prompt (y/N)"
    return $answer -match '^(?i:y|yes)$'
}

function Confirm-RepoFlowManualReview {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PullRequestNumber
    )

    Write-Host ''
    Write-Host 'Manual review confirmation required.'
    Write-Host (
        'Only continue after you have reviewed the pull request diff ' +
        'and validated the application behaviour.'
    )
    Write-Host ''

    $answer = Read-Host (
        "Type MERGE to continue with the configured merge workflow for " +
        "pull request #$PullRequestNumber"
    )

    return $answer -ceq 'MERGE'
}

function Write-RepoFlowHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Text
    )

    Write-Host ""
    Write-Host $Text
    Write-Host ("-" * $Text.Length)
}
