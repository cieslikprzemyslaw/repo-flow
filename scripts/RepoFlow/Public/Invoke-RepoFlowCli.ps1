function ConvertTo-RepoFlowCliBoolean {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    switch ($Value.Trim().ToLowerInvariant()) {
        { $_ -in @('true', '$true', '1', 'yes') } {
            return $true
        }

        { $_ -in @('false', '$false', '0', 'no') } {
            return $false
        }

        default {
            throw "Invalid switch value: '$Value'. Use true or false."
        }
    }
}

function New-RepoFlowCliUsageException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$Topic
    )

    $helpText = Get-RepoFlowHelpText -Topic $Topic

    return [System.ArgumentException]::new(
        "$Message$([Environment]::NewLine)$([Environment]::NewLine)$helpText"
    )
}

function Get-RepoFlowCliVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot
    )

    $manifestPath = Join-Path `
        $RepositoryRoot `
        'scripts/RepoFlow/RepoFlow.psd1'

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "RepoFlow module manifest was not found: $manifestPath"
    }

    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    return "RepoFlow $($manifest.ModuleVersion)"
}

function Invoke-RepoFlowCli {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [string[]]$Arguments = @(),

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RepositoryRoot
    )

    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $RepositoryRoot = [System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '../../..')
        )
    }

    $tokens = @($Arguments)

    if ($tokens.Count -eq 0) {
        Show-RepoFlowHelp
        return
    }

    $firstToken = $tokens[0].Trim().ToLowerInvariant()

    if ($firstToken -in @('--version', '-version')) {
        if ($tokens.Count -ne 1) {
            throw (
                New-RepoFlowCliUsageException `
                    -Message '--version does not accept additional arguments.' `
                    -Topic $null
            )
        }

        Get-RepoFlowCliVersion -RepositoryRoot $RepositoryRoot
        return
    }

    if ($firstToken -eq 'help') {
        $topic = if ($tokens.Count -gt 1) {
            ($tokens[1..($tokens.Count - 1)] -join ' ')
        }
        else {
            $null
        }

        Show-RepoFlowHelp -Topic $topic
        return
    }

    $helpIndex = -1

    for ($index = 0; $index -lt $tokens.Count; $index++) {
        if ($tokens[$index].Trim().ToLowerInvariant() -in @('-h', '--help')) {
            $helpIndex = $index
            break
        }
    }

    if ($helpIndex -ge 0) {
        $topicTokens = [System.Collections.Generic.List[string]]::new()

        for ($index = 0; $index -lt $helpIndex; $index++) {
            $candidate = $tokens[$index]

            if ($candidate.StartsWith('-')) {
                continue
            }

            if ($topicTokens.Count -lt 2) {
                $topicTokens.Add($candidate)
            }
        }

        $topic = if ($topicTokens.Count -gt 0) {
            $topicTokens -join ' '
        }
        else {
            $null
        }

        Show-RepoFlowHelp -Topic $topic
        return
    }

    $invokeParameters = @{}
    $positionals = [System.Collections.Generic.List[string]]::new()

    $switchOptions = @{
        'apply' = 'Apply'
        'run' = 'Apply'
        'skipcreates' = 'SkipCreates'
        'lastprcomment' = 'LastPrComment'
        'resume' = 'Resume'
    }

    $valueOptions = @{
        'area' = 'Area'
        'action' = 'Action'
        'number' = 'Number'
        'issuenumber' = 'Number'
        'prnumber' = 'Number'
        'prcommentid' = 'PrCommentId'
        'cimode' = 'CiMode'
        'runid' = 'RunId'
        'outcome' = 'Outcome'
        'repo' = 'Repo'
        'repository' = 'Repo'
        'repositoryname' = 'Repo'
        'configpath' = 'ConfigPath'
    }

    for ($index = 0; $index -lt $tokens.Count; $index++) {
        $token = $tokens[$index]

        if (-not $token.StartsWith('-')) {
            $positionals.Add($token)
            continue
        }

        $trimmedOption = $token.TrimStart('-')
        $optionName = $trimmedOption
        $inlineValue = $null
        $hasInlineValue = $false

        if ($trimmedOption -match '^([^:=]+)[:=](.*)$') {
            $optionName = $Matches[1]
            $inlineValue = $Matches[2]
            $hasInlineValue = $true
        }

        $normalisedOption = $optionName.ToLowerInvariant()

        if ($switchOptions.ContainsKey($normalisedOption)) {
            $parameterName = $switchOptions[$normalisedOption]
            $invokeParameters[$parameterName] = if ($hasInlineValue) {
                ConvertTo-RepoFlowCliBoolean -Value $inlineValue
            }
            else {
                $true
            }

            continue
        }

        if ($valueOptions.ContainsKey($normalisedOption)) {
            $parameterName = $valueOptions[$normalisedOption]

            $value = if ($hasInlineValue) {
                $inlineValue
            }
            else {
                if ($index + 1 -ge $tokens.Count) {
                    $topic = if ($positionals.Count -gt 0) {
                        $positionals[0]
                    }
                    else {
                        $null
                    }

                    throw (
                        New-RepoFlowCliUsageException `
                            -Message "Option '$token' requires a value." `
                            -Topic $topic
                    )
                }

                $index++
                $tokens[$index]
            }

            switch ($parameterName) {
                'Number' {
                    $parsedValue = 0

                    if (
                        -not [int]::TryParse(
                            $value,
                            [ref]$parsedValue
                        ) -or
                        $parsedValue -le 0
                    ) {
                        throw (
                            New-RepoFlowCliUsageException `
                                -Message "Invalid issue or PR number: '$value'." `
                                -Topic $null
                        )
                    }

                    $invokeParameters[$parameterName] = $parsedValue
                }

                'PrCommentId' {
                    $parsedValue = 0L

                    if (
                        -not [long]::TryParse(
                            $value,
                            [ref]$parsedValue
                        ) -or
                        $parsedValue -le 0
                    ) {
                        throw (
                            New-RepoFlowCliUsageException `
                                -Message "Invalid PR comment ID: '$value'." `
                                -Topic $null
                        )
                    }

                    $invokeParameters[$parameterName] = $parsedValue
                }

                default {
                    $invokeParameters[$parameterName] = $value
                }
            }

            continue
        }

        $topic = if ($positionals.Count -gt 0) {
            $positionals[0]
        }
        else {
            $null
        }

        throw (
            New-RepoFlowCliUsageException `
                -Message "Unknown RepoFlow option: '$token'." `
                -Topic $topic
        )
    }

    if ($positionals.Count -gt 3) {
        throw (
            New-RepoFlowCliUsageException `
                -Message (
                    'Too many positional arguments: ' +
                    ($positionals -join ' ')
                ) `
                -Topic $null
        )
    }

    $validActions = @{
        issue = @('sync', 'run', 'continue', 'resume')
        pr = @('status', 'watch', 'ready', 'merge', 'accept', 'repair')
        branch = @('cleanup')
        ci = @('watch')
        run = @('list', 'show', 'complete', 'prune')
        config = @('validate', 'show')
        repo = @('list', 'current', 'use', 'reset')
        doctor = @('run')
        review = @('run')
    }

    if ($invokeParameters.ContainsKey('Area')) {
        $area = ([string]$invokeParameters['Area']).Trim().ToLowerInvariant()

        if (-not $validActions.ContainsKey($area)) {
            throw (
                New-RepoFlowCliUsageException `
                    -Message "Unknown RepoFlow area: '$area'." `
                    -Topic $null
            )
        }

        $invokeParameters['Area'] = $area
    }

    if ($invokeParameters.ContainsKey('Action')) {
        if (-not $invokeParameters.ContainsKey('Area')) {
            throw (
                New-RepoFlowCliUsageException `
                    -Message '-Action requires -Area.' `
                    -Topic $null
            )
        }

        $action = ([string]$invokeParameters['Action']).Trim().ToLowerInvariant()
        $area = [string]$invokeParameters['Area']

        if ($action -notin $validActions[$area]) {
            throw (
                New-RepoFlowCliUsageException `
                    -Message "Unsupported RepoFlow command: $area $action." `
                    -Topic $area
            )
        }

        $invokeParameters['Action'] = $action
    }

    if ($positionals.Count -gt 0) {
        if ($invokeParameters.ContainsKey('Area')) {
            throw (
                New-RepoFlowCliUsageException `
                    -Message 'Area was supplied both positionally and with -Area.' `
                    -Topic $null
            )
        }

        $area = $positionals[0].Trim().ToLowerInvariant()

        if (-not $validActions.ContainsKey($area)) {
            throw (
                New-RepoFlowCliUsageException `
                    -Message "Unknown RepoFlow area: '$area'." `
                    -Topic $null
            )
        }

        $invokeParameters['Area'] = $area
    }

    if ($positionals.Count -gt 1) {
        if ($invokeParameters.ContainsKey('Action')) {
            throw (
                New-RepoFlowCliUsageException `
                    -Message 'Action was supplied both positionally and with -Action.' `
                    -Topic ([string]$invokeParameters['Area'])
            )
        }

        $action = $positionals[1].Trim().ToLowerInvariant()
        $area = [string]$invokeParameters['Area']

        if ($action -notin $validActions[$area]) {
            throw (
                New-RepoFlowCliUsageException `
                    -Message "Unsupported RepoFlow command: $area $action." `
                    -Topic $area
            )
        }

        $invokeParameters['Action'] = $action
    }

    if ($positionals.Count -gt 2) {
        if ($invokeParameters.ContainsKey('Repo')) {
            throw (
                New-RepoFlowCliUsageException `
                    -Message (
                        'Repository was supplied both positionally and with ' +
                        '-Repo.'
                    ) `
                    -Topic 'repo'
            )
        }

        $invokeParameters['Repo'] = $positionals[2]
    }

    if (-not $invokeParameters.ContainsKey('ConfigPath')) {
        $invokeParameters['ConfigPath'] = Join-Path `
            $RepositoryRoot `
            '.repo-flow.json'
    }

    Invoke-RepoFlow @invokeParameters
}
