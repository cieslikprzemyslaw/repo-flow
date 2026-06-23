function Get-RepoFlowCiDiagnostics {
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
        [string]$Command,

        [ValidateRange(256, 1000000)]
        [int]$MaximumRawCharacters = 24000,

        [ValidateRange(0, 1000000)]
        [int]$HeadCharacters = 4000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $cleanText = Remove-RepoFlowAnsiSequence -Text $Text
    $cleanText = $cleanText.Replace("`r`n", "`n").Replace("`r", "`n")

    $hasFailure = [regex]::IsMatch($cleanText, '(?m)^\s*FAIL\s+') -or
        [regex]::IsMatch($cleanText, '(?im)^\s*tests?\s+\d+\s+failed\b')

    $hasSuccess = [regex]::IsMatch($cleanText, '(?im)^\s*tests?\s+\d+\s+passed\b') -or
        [regex]::IsMatch($cleanText, '(?im)process completed with exit code 0')

    if (-not $hasFailure -and $hasSuccess) {
        return @()
    }

    $headers = [regex]::Matches(
        $cleanText,
        '(?m)^\s*FAIL\s+(?<file>\S+)\s+>\s+(?<name>[^\n]+?)\s*$'
    )

    if ($headers.Count -gt 0) {
        $records = [System.Collections.Generic.List[object]]::new()

        for ($index = 0; $index -lt $headers.Count; $index++) {
            $header = $headers[$index]
            $start = $header.Index

            if ($index + 1 -lt $headers.Count) {
                $end = $headers[$index + 1].Index
            }
            else {
                $end = $cleanText.Length
            }

            $block = $cleanText.Substring($start, $end - $start)

            $summaryMatch = [regex]::Match(
                $block,
                '(?m)^\s*(?<summary>(?:AssertionError|TestingLibraryElementError|Error):[^\n]+)\s*$'
            )

            if ($summaryMatch.Success) {
                $summary = $summaryMatch.Groups['summary'].Value.Trim()
            }
            else {
                $summary = Get-RepoFlowCiSummaryLine -Text $block
            }

            $expectedMatch = [regex]::Match(
                $block,
                '(?m)^\s*Expected:\s*(?<value>.+?)\s*$'
            )
            $receivedMatch = [regex]::Match(
                $block,
                '(?m)^\s*Received:\s*(?<value>.+?)\s*$'
            )
            $sourceMatch = [regex]::Match(
                $block,
                '(?m)^\s*at\s+(?<path>.+?):(?<line>\d+):(?<column>\d+)\s*$'
            )

            $expected = $null
            if ($expectedMatch.Success) {
                $expected = $expectedMatch.Groups['value'].Value.Trim()
            }

            $received = $null
            if ($receivedMatch.Success) {
                $received = $receivedMatch.Groups['value'].Value.Trim()
            }

            $sourcePath = $null
            $sourceLine = $null
            if ($sourceMatch.Success) {
                $sourcePath = $sourceMatch.Groups['path'].Value.Trim()
                $sourceLine = [int]$sourceMatch.Groups['line'].Value
            }

            $stack = @(
                $block -split '\n' |
                    Where-Object { $_ -match '^\s*at\s+' } |
                    ForEach-Object { $_.Trim() } |
                    Select-Object -First 5
            ) -join [Environment]::NewLine

            $rawContext = Get-RepoFlowBoundedText `
                -Text $block `
                -MaximumCharacters $MaximumRawCharacters `
                -HeadCharacters $HeadCharacters

            $recordParameters = @{
                Category = 'test'
                CheckName = $CheckName
                StepName = $StepName
                Command = $Command
                Project = $null
                TestFile = $header.Groups['file'].Value
                TestName = $header.Groups['name'].Value.Trim()
                Summary = $summary
                Expected = $expected
                Received = $received
                SourcePath = $sourcePath
                SourceLine = $sourceLine
                Stack = $stack
                RawContext = $rawContext
            }

            $records.Add((New-RepoFlowCiDiagnosticRecord @recordParameters))
        }

        return $records.ToArray()
    }

    $category = Get-RepoFlowCiFailureCategory `
        -Text $cleanText `
        -CheckName $CheckName `
        -StepName $StepName `
        -Command $Command

    $summary = Get-RepoFlowCiSummaryLine -Text $cleanText

    $sourceMatch = [regex]::Match(
        $cleanText,
        '(?m)^(?<path>.+?)\((?<line>\d+),(?<column>\d+)\):'
    )

    if (-not $sourceMatch.Success) {
        $sourceMatch = [regex]::Match(
            $cleanText,
            '(?m)^\s*at\s+(?<path>.+?):(?<line>\d+):(?<column>\d+)\s*$'
        )
    }

    $sourcePath = $null
    $sourceLine = $null
    if ($sourceMatch.Success) {
        $sourcePath = $sourceMatch.Groups['path'].Value.Trim()
        $sourceLine = [int]$sourceMatch.Groups['line'].Value
    }

    $rawContext = Get-RepoFlowBoundedText `
        -Text $cleanText `
        -MaximumCharacters $MaximumRawCharacters `
        -HeadCharacters $HeadCharacters

    $recordParameters = @{
        Category = $category
        CheckName = $CheckName
        StepName = $StepName
        Command = $Command
        Project = $null
        TestFile = $null
        TestName = $null
        Summary = $summary
        Expected = $null
        Received = $null
        SourcePath = $sourcePath
        SourceLine = $sourceLine
        Stack = $null
        RawContext = $rawContext
    }

    New-RepoFlowCiDiagnosticRecord @recordParameters
}
