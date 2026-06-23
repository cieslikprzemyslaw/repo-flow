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
        [int]$MaximumRawCharacters = 4000,

        [ValidateRange(0, 1000000)]
        [int]$HeadCharacters = 2000
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    $cleanText = ConvertTo-RepoFlowCiNormalisedText -Text $Text
    $sections = @(
        Get-RepoFlowCiRunSections `
            -Text $cleanText `
            -DefaultStepName $StepName `
            -DefaultCommand $Command
    )

    $records = [System.Collections.Generic.List[object]]::new()

    foreach ($section in $sections) {
        $sectionText = [string]$section.Text

        if ([string]::IsNullOrWhiteSpace($sectionText)) {
            continue
        }

        $sectionStepName = [string]$section.StepName
        $sectionCommand = [string]$section.Command

        $hasTestFailure = [regex]::IsMatch(
            $sectionText,
            '(?m)^\s*FAIL\s+'
        ) -or [regex]::IsMatch(
            $sectionText,
            '(?im)^\s*tests?\s+\d+\s+failed\b'
        )

        $hasSuccessfulExit = [regex]::IsMatch(
            $sectionText,
            '(?im)process completed with exit code 0'
        )

        $hasFailedExit = [regex]::IsMatch(
            $sectionText,
            '(?im)process completed with exit code [1-9]\d*'
        )

        $hasFailureSignal = [regex]::IsMatch(
            $sectionText,
            '(?im)assertionerror|testinglibraryelementerror|\berror\b|\bfailed\b|\bfailure\b|code style|\bproblem\b|\brejected\b|\bcancelled\b|\bcanceled\b|could not|error\s+ts\d+|zx-\d+'
        )

        if (-not $hasTestFailure -and -not $hasFailedExit -and -not $hasFailureSignal) {
            continue
        }

        if (-not $hasTestFailure -and $hasSuccessfulExit -and -not $hasFailedExit) {
            continue
        }

        $headers = [regex]::Matches(
            $sectionText,
            '(?m)^\s*FAIL\s+(?<target>.+?)\s+>\s+(?<name>[^\n]+?)\s*$'
        )

        if ($headers.Count -gt 0) {
            for ($index = 0; $index -lt $headers.Count; $index++) {
                $header = $headers[$index]
                $start = $header.Index

                if ($index + 1 -lt $headers.Count) {
                    $end = $headers[$index + 1].Index
                }
                else {
                    $end = $sectionText.Length
                }

                $block = $sectionText.Substring($start, $end - $start)
                $target = $header.Groups['target'].Value.Trim()
                $project = $null
                $testFile = $target

                $bracketProject = [regex]::Match(
                    $target,
                    '^\[(?<project>[^\]]+)\]\s+(?<file>\S+)$'
                )
                $pipeProject = [regex]::Match(
                    $target,
                    '^\|(?<project>[^|]+)\|\s+(?<file>\S+)$'
                )

                if ($bracketProject.Success) {
                    $project = $bracketProject.Groups['project'].Value.Trim()
                    $testFile = $bracketProject.Groups['file'].Value.Trim()
                }
                elseif ($pipeProject.Success) {
                    $project = $pipeProject.Groups['project'].Value.Trim()
                    $testFile = $pipeProject.Groups['file'].Value.Trim()
                }
                else {
                    $targetParts = @($target -split '\s+')

                    if ($targetParts.Count -gt 1) {
                        $testFile = [string]$targetParts[-1]
                        $project = ($targetParts[0..($targetParts.Count - 2)] -join ' ').Trim()
                    }
                }

                $fullTestName = $header.Groups['name'].Value.Trim()
                $nameParts = @($fullTestName -split '\s+>\s+')
                $suite = $null

                if ($nameParts.Count -gt 1) {
                    $suite = ($nameParts[0..($nameParts.Count - 2)] -join ' > ').Trim()
                }

                $summaryMatch = [regex]::Match(
                    $block,
                    '(?m)^\s*(?<summary>(?:AssertionError|TestingLibraryElementError|Error):[^\n]+)\s*$'
                )

                if ($summaryMatch.Success) {
                    $summary = Get-RepoFlowBoundedText `
                        -Text $summaryMatch.Groups['summary'].Value.Trim() `
                        -MaximumCharacters 1000 `
                        -HeadCharacters 700
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

                $sourcePatterns = @(
                    '(?m)^\s*(?:at|❯)\s+(?<path>[^()\n]+?):(?<line>\d+):(?<column>\d+)\s*$'
                    '(?m)^\s*(?:at|❯)\s+.+?\((?<path>[^()\n]+?):(?<line>\d+):(?<column>\d+)\)\s*$'
                )

                $sourceMatch = $null

                foreach ($pattern in $sourcePatterns) {
                    $candidate = [regex]::Match($block, $pattern)

                    if ($candidate.Success) {
                        $sourceMatch = $candidate
                        break
                    }
                }

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

                if ($null -ne $sourceMatch) {
                    $sourcePath = $sourceMatch.Groups['path'].Value.Trim()
                    $sourceLine = [int]$sourceMatch.Groups['line'].Value
                }

                $stack = @(
                    $block -split '\n' |
                        Where-Object { $_ -match '^\s*(?:at|❯)\s+' } |
                        ForEach-Object { $_.Trim() } |
                        Select-Object -First 5
                ) -join [Environment]::NewLine

                $rawContext = Get-RepoFlowBoundedText `
                    -Text $block `
                    -MaximumCharacters $MaximumRawCharacters `
                    -HeadCharacters ([Math]::Min($HeadCharacters, $MaximumRawCharacters))

                $recordParameters = @{
                    Category = 'test'
                    CheckName = $CheckName
                    StepName = $sectionStepName
                    Command = $sectionCommand
                    Project = $project
                    Suite = $suite
                    TestFile = $testFile
                    TestName = $fullTestName
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

            continue
        }

        $category = Get-RepoFlowCiFailureCategory `
            -Text $sectionText `
            -CheckName $CheckName `
            -StepName $sectionStepName `
            -Command $sectionCommand

        $summary = Get-RepoFlowCiSummaryLine -Text $sectionText

        if ($category -eq 'build') {
            $specificBuildSummary = [regex]::Match(
                $sectionText,
                '(?im)^\s*(?<summary>(?:could not resolve|failed to compile)[^\n]*)\s*$'
            )

            if ($specificBuildSummary.Success) {
                $summary = $specificBuildSummary.Groups['summary'].Value.Trim()
            }
        }

        $sourcePatterns = @(
            '(?m)^(?<path>.+?)\((?<line>\d+),(?<column>\d+)\):'
            '(?m)^\s*(?:at|❯)\s+(?<path>[^()\n]+?):(?<line>\d+):(?<column>\d+)\s*$'
            '(?m)^\s*(?:at|❯)\s+.+?\((?<path>[^()\n]+?):(?<line>\d+):(?<column>\d+)\)\s*$'
        )

        $sourceMatch = $null

        foreach ($pattern in $sourcePatterns) {
            $candidate = [regex]::Match($sectionText, $pattern)

            if ($candidate.Success) {
                $sourceMatch = $candidate
                break
            }
        }

        $sourcePath = $null
        $sourceLine = $null

        if ($null -ne $sourceMatch) {
            $sourcePath = $sourceMatch.Groups['path'].Value.Trim()
            $sourceLine = [int]$sourceMatch.Groups['line'].Value
        }

        $rawContext = Get-RepoFlowBoundedText `
            -Text $sectionText `
            -MaximumCharacters $MaximumRawCharacters `
            -HeadCharacters ([Math]::Min($HeadCharacters, $MaximumRawCharacters))

        $recordParameters = @{
            Category = $category
            CheckName = $CheckName
            StepName = $sectionStepName
            Command = $sectionCommand
            Project = $null
            Suite = $null
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

        $records.Add((New-RepoFlowCiDiagnosticRecord @recordParameters))
    }

    return $records.ToArray()
}
