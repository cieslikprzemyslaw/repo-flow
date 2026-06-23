function Remove-RepoFlowAnsiSequence {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrEmpty($Text)) {
        return ''
    }

    $ansiPattern = ([string][char]27) + '\[[0-?]*[ -/]*[@-~]'
    return [regex]::Replace($Text, $ansiPattern, '')
}

function New-RepoFlowCiDiagnosticRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Category,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$CheckName,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StepName,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Command,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Project,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TestFile,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$TestName,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Summary,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Expected,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Received,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$SourcePath,

        [AllowNull()]
        [Nullable[int]]$SourceLine,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Stack,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RawContext
    )

    [pscustomobject][ordered]@{
        Category = $Category
        CheckName = $CheckName
        StepName = $StepName
        Command = $Command
        Project = $Project
        TestFile = $TestFile
        TestName = $TestName
        Summary = $Summary
        Expected = $Expected
        Received = $Received
        SourcePath = $SourcePath
        SourceLine = $SourceLine
        Stack = $Stack
        RawContext = $RawContext
    }
}

function Get-RepoFlowCiFailureCategory {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$CheckName,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$StepName,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Command
    )

    $probe = (@($CheckName, $StepName, $Command, $Text) -join "`n").ToLowerInvariant()

    if ($probe -match 'prettier|format:check|checking formatting|code style') {
        return 'formatting'
    }

    if ($probe -match 'eslint|\blint\b|no-explicit-any') {
        return 'lint'
    }

    if ($probe -match '\btypecheck\b|\btsc\b|error\s+ts\d+') {
        return 'typecheck'
    }

    if ($probe -match '\bvitest\b|\bjest\b|(?m)^\s*tests?\s+.*\bfailed\b') {
        return 'test'
    }

    if ($probe -match '\bbuild\b|error during build|could not resolve|failed to compile') {
        return 'build'
    }

    return 'infrastructure/unknown'
}

function Get-RepoFlowCiSummaryLine {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text
    )

    $lines = @(
        $Text -split '\n' |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    foreach ($line in $lines) {
        if (
            $line -match '(?i)assertionerror|testinglibraryelementerror|\berror\b|\bfailed\b|\bfailure\b|code style|\bproblem\b|\brejected\b|\bcancelled\b|\bcanceled\b|could not|error\s+ts\d+|zx-\d+' -and
            $line -notmatch '(?i)^process completed with exit code'
        ) {
            return $line
        }
    }

    if ($lines.Count -gt 0) {
        return [string]$lines[0]
    }

    return ''
}

function Format-RepoFlowCiDiagnostics {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object[]]$Diagnostics
    )

    $records = @($Diagnostics)

    if ($records.Count -eq 0) {
        return 'No structured CI failures were detected.'
    }

    $lines = [System.Collections.Generic.List[string]]::new()

    foreach ($record in $records) {
        if (-not [string]::IsNullOrWhiteSpace([string]$record.TestName)) {
            $name = [string]$record.TestName
        }
        elseif (-not [string]::IsNullOrWhiteSpace([string]$record.CheckName)) {
            $name = [string]$record.CheckName
        }
        else {
            $name = [string]$record.Category
        }

        $location = $null
        if (-not [string]::IsNullOrWhiteSpace([string]$record.SourcePath)) {
            if ($null -ne $record.SourceLine) {
                $location = '{0}:{1}' -f $record.SourcePath, $record.SourceLine
            }
            else {
                $location = [string]$record.SourcePath
            }
        }

        $line = '- [{0}] {1}' -f $record.Category, $name

        if (-not [string]::IsNullOrWhiteSpace([string]$record.Summary)) {
            $line += ': {0}' -f $record.Summary
        }

        if (-not [string]::IsNullOrWhiteSpace($location)) {
            $line += ' ({0})' -f $location
        }

        $lines.Add($line)
    }

    return $lines -join [Environment]::NewLine
}
