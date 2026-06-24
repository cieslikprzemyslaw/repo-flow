function Resolve-RepoFlowConfigPath {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        return [System.IO.Path]::GetFullPath(
            (Join-Path (Get-Location).Path '.repo-flow.json')
        )
    }

    if ([System.IO.Path]::IsPathRooted($ConfigPath)) {
        return [System.IO.Path]::GetFullPath($ConfigPath)
    }

    return [System.IO.Path]::GetFullPath(
        (Join-Path (Get-Location).Path $ConfigPath)
    )
}

function Assert-RepoFlowAllowedProperties {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Object,

        [Parameter(Mandatory)]
        [string[]]$Allowed,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($null -eq $Object) {
        return
    }

    foreach ($property in $Object.PSObject.Properties.Name) {
        if ($Allowed -notcontains $property) {
            throw "Unknown configuration property: $Path.$property"
        }
    }
}

function Get-RepoFlowProperty {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Object,

        [Parameter(Mandatory)]
        [string]$Name,

        [AllowNull()]
        $Default
    )

    if ($null -eq $Object) {
        if ($Default -is [System.Array]) {
            Write-Output -NoEnumerate $Default
            return
        }

        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]

    if ($null -eq $property -or $null -eq $property.Value) {
        if ($Default -is [System.Array]) {
            Write-Output -NoEnumerate $Default
            return
        }

        return $Default
    }

    if ($property.Value -is [System.Array]) {
        Write-Output -NoEnumerate $property.Value
        return
    }

    return $property.Value
}

function Assert-RepoFlowString {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "Configuration value '$Path' must be a non-empty string."
    }
}

function Assert-RepoFlowNullableSemanticVersionString {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($null -eq $Value) {
        return
    }

    Assert-RepoFlowString -Value $Value -Path $Path

    if ([string]$Value -notmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$') {
        throw "Configuration value '$Path' must be a semantic version string such as 1.2.3."
    }

    ConvertTo-RepoFlowSemanticVersion `
        -Version ([string]$Value) `
        -Path $Path |
        Out-Null
}

function Assert-RepoFlowIntegerRange {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [int]$Minimum,

        [Parameter(Mandatory)]
        [int]$Maximum,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Value -is [bool] -or $Value -is [string] -or $Value -isnot [System.ValueType]) {
        throw "Configuration value '$Path' must be an integer."
    }

    $number = 0

    if (-not [int]::TryParse([string]$Value, [ref]$number)) {
        throw "Configuration value '$Path' must be an integer."
    }

    if ($number -lt $Minimum -or $number -gt $Maximum) {
        throw "Configuration value '$Path' must be between $Minimum and $Maximum."
    }
}

function Assert-RepoFlowBoolean {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Value -isnot [bool]) {
        throw "Configuration value '$Path' must be true or false."
    }
}

function Assert-RepoFlowArray {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Value,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ($Value -isnot [System.Array]) {
        throw "Configuration value '$Path' must be an array."
    }
}

function Resolve-RepoFlowPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Path))
}

function Read-RepoFlowConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RepositoryRoot,

        [string]$ConfigPath,

        [AllowNull()]
        $RepositorySelection
    )

    $selection = if ($null -eq $RepositorySelection) {
        Get-RepoFlowRepositorySelection -ConfigPath $ConfigPath
    }
    else {
        $RepositorySelection
    }

    $registry = $selection.Registry
    $raw = $registry.Raw
    $resolvedConfigPath = [string]$registry.ConfigPath

    Assert-RepoFlowAllowedProperties -Object $raw -Path '$' -Allowed @(
        '$schema',
        'repository',
        'defaultRepository',
        'repositories',
        'issues',
        'git',
        'agent',
        'pullRequest',
        'messages',
        'ci',
        'reviewFeedback'
    )

    $issues = Get-RepoFlowProperty -Object $raw -Name 'issues' -Default $null
    $git = Get-RepoFlowProperty -Object $raw -Name 'git' -Default $null
    $agent = Get-RepoFlowProperty -Object $raw -Name 'agent' -Default $null
    $pullRequest = Get-RepoFlowProperty -Object $raw -Name 'pullRequest' -Default $null
    $messages = Get-RepoFlowProperty -Object $raw -Name 'messages' -Default $null
    $ci = Get-RepoFlowProperty -Object $raw -Name 'ci' -Default $null
    $reviewFeedback = Get-RepoFlowProperty -Object $raw -Name 'reviewFeedback' -Default $null

    Assert-RepoFlowAllowedProperties -Object $issues -Path '$.issues' -Allowed @('manifestPath')
    Assert-RepoFlowAllowedProperties -Object $git -Path '$.git' -Allowed @(
        'requireCleanWorkingTree',
        'deleteMergedLocalBranches',
        'pruneRemoteReferences',
        'signOffCommits',
        'preCommitFixAttempts'
    )
    Assert-RepoFlowAllowedProperties -Object $agent -Path '$.agent' -Allowed @(
        'provider',
        'command',
        'model',
        'minimumCliVersion',
        'heartbeatSeconds',
        'noActivityWarningSeconds',
        'reasoningEffort',
        'ciFixReasoningEffort',
        'preCommitFixReasoningEffort',
        'runProjectChecks'
    )
    Assert-RepoFlowAllowedProperties -Object $pullRequest -Path '$.pullRequest' -Allowed @(
        'createDraft',
        'templatePath',
        'mergeMethod',
        'deleteBranchOnMerge'
    )
    Assert-RepoFlowAllowedProperties -Object $messages -Path '$.messages' -Allowed @(
        'initialCommit',
        'reviewCommit',
        'ciFixCommit',
        'pullRequestTitle'
    )
    Assert-RepoFlowAllowedProperties -Object $ci -Path '$.ci' -Allowed @(
        'mode',
        'pollSeconds',
        'timeoutSeconds',
        'autoFixAttempts'
    )
    Assert-RepoFlowAllowedProperties -Object $reviewFeedback -Path '$.reviewFeedback' -Allowed @(
        'enabled',
        'confirmBeforeRun',
        'trustedAssociations',
        'maxReviewCycles',
        'maxRepairCycles'
    )

    $manifestPath = Get-RepoFlowProperty -Object $issues -Name 'manifestPath' -Default './issues-manifest.json'

    $requireCleanWorkingTree = Get-RepoFlowProperty -Object $git -Name 'requireCleanWorkingTree' -Default $true
    $deleteMergedLocalBranches = Get-RepoFlowProperty -Object $git -Name 'deleteMergedLocalBranches' -Default $true
    $pruneRemoteReferences = Get-RepoFlowProperty -Object $git -Name 'pruneRemoteReferences' -Default $true
    $signOffCommits = Get-RepoFlowProperty -Object $git -Name 'signOffCommits' -Default $false
    $preCommitFixAttempts = Get-RepoFlowProperty -Object $git -Name 'preCommitFixAttempts' -Default 1

    $agentProvider = Get-RepoFlowProperty -Object $agent -Name 'provider' -Default 'codex'
    $agentCommand = Get-RepoFlowProperty -Object $agent -Name 'command' -Default 'codex'
    $agentModel = Get-RepoFlowProperty -Object $agent -Name 'model' -Default 'gpt-5.5'
    $minimumCliVersion = Get-RepoFlowProperty -Object $agent -Name 'minimumCliVersion' -Default $null
    $heartbeatSeconds = Get-RepoFlowProperty -Object $agent -Name 'heartbeatSeconds' -Default 15
    $noActivityWarningSeconds = Get-RepoFlowProperty -Object $agent -Name 'noActivityWarningSeconds' -Default 180
    $reasoningEffort = Get-RepoFlowProperty -Object $agent -Name 'reasoningEffort' -Default 'medium'
    $ciFixReasoningEffort = Get-RepoFlowProperty -Object $agent -Name 'ciFixReasoningEffort' -Default 'low'
    $preCommitFixReasoningEffort = Get-RepoFlowProperty -Object $agent -Name 'preCommitFixReasoningEffort' -Default 'low'
    $runProjectChecks = Get-RepoFlowProperty -Object $agent -Name 'runProjectChecks' -Default $false

    $createDraft = Get-RepoFlowProperty -Object $pullRequest -Name 'createDraft' -Default $true
    $templatePath = Get-RepoFlowProperty -Object $pullRequest -Name 'templatePath' -Default './.github/pull_request_template.md'
    $mergeMethod = Get-RepoFlowProperty -Object $pullRequest -Name 'mergeMethod' -Default 'squash'
    $deleteBranchOnMerge = Get-RepoFlowProperty -Object $pullRequest -Name 'deleteBranchOnMerge' -Default $true

    $initialCommit = Get-RepoFlowProperty -Object $messages -Name 'initialCommit' -Default '{verb} #{issueNumber}: {issueTitle}'
    $reviewCommit = Get-RepoFlowProperty -Object $messages -Name 'reviewCommit' -Default 'Fix review feedback for #{issueNumber}'
    $ciFixCommit = Get-RepoFlowProperty -Object $messages -Name 'ciFixCommit' -Default 'Fix CI for #{issueNumber}'
    $pullRequestTitle = Get-RepoFlowProperty -Object $messages -Name 'pullRequestTitle' -Default '{verb} #{issueNumber}: {issueTitle}'

    $ciMode = Get-RepoFlowProperty -Object $ci -Name 'mode' -Default 'observe'
    $pollSeconds = Get-RepoFlowProperty -Object $ci -Name 'pollSeconds' -Default 30
    $timeoutSeconds = Get-RepoFlowProperty -Object $ci -Name 'timeoutSeconds' -Default 300
    $autoFixAttempts = Get-RepoFlowProperty -Object $ci -Name 'autoFixAttempts' -Default 0

    $feedbackEnabled = Get-RepoFlowProperty -Object $reviewFeedback -Name 'enabled' -Default $true
    $confirmBeforeRun = Get-RepoFlowProperty -Object $reviewFeedback -Name 'confirmBeforeRun' -Default $true
    $trustedAssociations = Get-RepoFlowProperty -Object $reviewFeedback -Name 'trustedAssociations' -Default @('OWNER')
    $maxReviewCycles = Get-RepoFlowProperty -Object $reviewFeedback -Name 'maxReviewCycles' -Default 3
    $maxRepairCycles = Get-RepoFlowProperty -Object $reviewFeedback -Name 'maxRepairCycles' -Default 2

    Assert-RepoFlowString -Value $manifestPath -Path '$.issues.manifestPath'

    Assert-RepoFlowBoolean -Value $requireCleanWorkingTree -Path '$.git.requireCleanWorkingTree'
    Assert-RepoFlowBoolean -Value $deleteMergedLocalBranches -Path '$.git.deleteMergedLocalBranches'
    Assert-RepoFlowBoolean -Value $pruneRemoteReferences -Path '$.git.pruneRemoteReferences'
    Assert-RepoFlowBoolean -Value $signOffCommits -Path '$.git.signOffCommits'
    Assert-RepoFlowIntegerRange -Value $preCommitFixAttempts -Minimum 0 -Maximum 3 -Path '$.git.preCommitFixAttempts'

    Assert-RepoFlowString -Value $agentProvider -Path '$.agent.provider'
    Assert-RepoFlowString -Value $agentCommand -Path '$.agent.command'
    Assert-RepoFlowString -Value $agentModel -Path '$.agent.model'
    Assert-RepoFlowNullableSemanticVersionString -Value $minimumCliVersion -Path '$.agent.minimumCliVersion'
    Assert-RepoFlowIntegerRange -Value $heartbeatSeconds -Minimum 5 -Maximum 300 -Path '$.agent.heartbeatSeconds'
    Assert-RepoFlowIntegerRange -Value $noActivityWarningSeconds -Minimum 30 -Maximum 7200 -Path '$.agent.noActivityWarningSeconds'
    Assert-RepoFlowString -Value $reasoningEffort -Path '$.agent.reasoningEffort'
    Assert-RepoFlowString -Value $ciFixReasoningEffort -Path '$.agent.ciFixReasoningEffort'
    Assert-RepoFlowString -Value $preCommitFixReasoningEffort -Path '$.agent.preCommitFixReasoningEffort'
    Assert-RepoFlowBoolean -Value $runProjectChecks -Path '$.agent.runProjectChecks'

    Assert-RepoFlowBoolean -Value $createDraft -Path '$.pullRequest.createDraft'
    Assert-RepoFlowString -Value $templatePath -Path '$.pullRequest.templatePath'
    Assert-RepoFlowString -Value $mergeMethod -Path '$.pullRequest.mergeMethod'
    Assert-RepoFlowBoolean -Value $deleteBranchOnMerge -Path '$.pullRequest.deleteBranchOnMerge'

    Assert-RepoFlowString -Value $initialCommit -Path '$.messages.initialCommit'
    Assert-RepoFlowString -Value $reviewCommit -Path '$.messages.reviewCommit'
    Assert-RepoFlowString -Value $ciFixCommit -Path '$.messages.ciFixCommit'
    Assert-RepoFlowString -Value $pullRequestTitle -Path '$.messages.pullRequestTitle'

    Assert-RepoFlowString -Value $ciMode -Path '$.ci.mode'
    Assert-RepoFlowIntegerRange -Value $pollSeconds -Minimum 10 -Maximum 300 -Path '$.ci.pollSeconds'
    Assert-RepoFlowIntegerRange -Value $timeoutSeconds -Minimum 30 -Maximum 7200 -Path '$.ci.timeoutSeconds'
    Assert-RepoFlowIntegerRange -Value $autoFixAttempts -Minimum 0 -Maximum 5 -Path '$.ci.autoFixAttempts'

    Assert-RepoFlowBoolean -Value $feedbackEnabled -Path '$.reviewFeedback.enabled'
    Assert-RepoFlowBoolean -Value $confirmBeforeRun -Path '$.reviewFeedback.confirmBeforeRun'
    Assert-RepoFlowArray -Value $trustedAssociations -Path '$.reviewFeedback.trustedAssociations'
    Assert-RepoFlowIntegerRange -Value $maxReviewCycles -Minimum 1 -Maximum 10 -Path '$.reviewFeedback.maxReviewCycles'
    Assert-RepoFlowIntegerRange -Value $maxRepairCycles -Minimum 0 -Maximum 10 -Path '$.reviewFeedback.maxRepairCycles'

    foreach ($associationValue in @($trustedAssociations)) {
        Assert-RepoFlowString -Value $associationValue -Path '$.reviewFeedback.trustedAssociations[]'
    }

    $selectedRepository = $selection.Repository

    $config = [pscustomobject]@{
        configPath = $resolvedConfigPath
        selectedRepository = [string]$selectedRepository.name
        repositorySelectionSource = [string]$selection.Source
        defaultRepository = if ($registry.IsLegacy) {
            $null
        }
        else {
            [string]$registry.DefaultRepository
        }
        repositories = @($registry.Repositories)
        isLegacyRepositoryConfiguration = [bool]$registry.IsLegacy
        repository = [pscustomobject]@{
            name = [string]$selectedRepository.name
            localPath = [System.IO.Path]::GetFullPath([string]$RepositoryRoot)
            slug = [string]$selectedRepository.slug
            expectedOrigins = @(
                $selectedRepository.expectedOrigins |
                ForEach-Object { [string]$_ }
            )
            baseBranch = [string]$selectedRepository.baseBranch
        }
        issues = [pscustomobject]@{
            manifestPath = [string]$manifestPath
        }
        git = [pscustomobject]@{
            requireCleanWorkingTree = [bool]$requireCleanWorkingTree
            deleteMergedLocalBranches = [bool]$deleteMergedLocalBranches
            pruneRemoteReferences = [bool]$pruneRemoteReferences
            signOffCommits = [bool]$signOffCommits
            preCommitFixAttempts = [int]$preCommitFixAttempts
        }
        agent = [pscustomobject]@{
            provider = [string]$agentProvider
            command = [string]$agentCommand
            model = [string]$agentModel
            minimumCliVersion = if ($null -eq $minimumCliVersion) {
                $null
            }
            else {
                [string]$minimumCliVersion
            }
            heartbeatSeconds = [int]$heartbeatSeconds
            noActivityWarningSeconds = [int]$noActivityWarningSeconds
            reasoningEffort = [string]$reasoningEffort
            ciFixReasoningEffort = [string]$ciFixReasoningEffort
            preCommitFixReasoningEffort = [string]$preCommitFixReasoningEffort
            runProjectChecks = [bool]$runProjectChecks
        }
        pullRequest = [pscustomobject]@{
            createDraft = [bool]$createDraft
            templatePath = [string]$templatePath
            mergeMethod = [string]$mergeMethod
            deleteBranchOnMerge = [bool]$deleteBranchOnMerge
        }
        messages = [pscustomobject]@{
            initialCommit = [string]$initialCommit
            reviewCommit = [string]$reviewCommit
            ciFixCommit = [string]$ciFixCommit
            pullRequestTitle = [string]$pullRequestTitle
        }
        ci = [pscustomobject]@{
            mode = [string]$ciMode
            pollSeconds = [int]$pollSeconds
            timeoutSeconds = [int]$timeoutSeconds
            autoFixAttempts = [int]$autoFixAttempts
        }
        reviewFeedback = [pscustomobject]@{
            enabled = [bool]$feedbackEnabled
            confirmBeforeRun = [bool]$confirmBeforeRun
            trustedAssociations = @(
                $trustedAssociations |
                ForEach-Object { [string]$_ }
            )
            maxReviewCycles = [int]$maxReviewCycles
            maxRepairCycles = [int]$maxRepairCycles
        }
    }

    Assert-RepoFlowConfiguration -Config $config
    return $config
}

function Assert-RepoFlowConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    Assert-RepoFlowString -Value $Config.repository.localPath -Path '$.repository.localPath'
    Assert-RepoFlowString -Value $Config.repository.slug -Path '$.repository.slug'

    if ($Config.repository.slug -notmatch '^[^/\s]+/[^/\s]+$') {
        throw "Configuration value '$.repository.slug' must use the 'owner/repository' format."
    }

    if (@($Config.repository.expectedOrigins).Count -eq 0) {
        throw "Configuration value '$.repository.expectedOrigins' must contain at least one origin."
    }

    foreach ($origin in @($Config.repository.expectedOrigins)) {
        Assert-RepoFlowString -Value $origin -Path '$.repository.expectedOrigins[]'
    }

    Assert-RepoFlowString -Value $Config.repository.baseBranch -Path '$.repository.baseBranch'
    Assert-RepoFlowString -Value $Config.issues.manifestPath -Path '$.issues.manifestPath'

    Assert-RepoFlowBoolean -Value $Config.git.requireCleanWorkingTree -Path '$.git.requireCleanWorkingTree'
    Assert-RepoFlowBoolean -Value $Config.git.deleteMergedLocalBranches -Path '$.git.deleteMergedLocalBranches'
    Assert-RepoFlowBoolean -Value $Config.git.pruneRemoteReferences -Path '$.git.pruneRemoteReferences'
    Assert-RepoFlowBoolean -Value $Config.git.signOffCommits -Path '$.git.signOffCommits'
    Assert-RepoFlowIntegerRange -Value $Config.git.preCommitFixAttempts -Minimum 0 -Maximum 3 -Path '$.git.preCommitFixAttempts'

    if ($Config.agent.provider -notin @('codex', 'claude')) {
        throw "Configuration value '$.agent.provider' must be codex or claude."
    }

    Assert-RepoFlowString -Value $Config.agent.command -Path '$.agent.command'
    Assert-RepoFlowString -Value $Config.agent.model -Path '$.agent.model'
    Assert-RepoFlowNullableSemanticVersionString -Value $Config.agent.minimumCliVersion -Path '$.agent.minimumCliVersion'
    Assert-RepoFlowIntegerRange -Value $Config.agent.heartbeatSeconds -Minimum 5 -Maximum 300 -Path '$.agent.heartbeatSeconds'
    $noActivityWarningSeconds = Get-RepoFlowProperty `
        -Object $Config.agent `
        -Name 'noActivityWarningSeconds' `
        -Default 180
    Assert-RepoFlowIntegerRange `
        -Value $noActivityWarningSeconds `
        -Minimum 30 `
        -Maximum 7200 `
        -Path '$.agent.noActivityWarningSeconds'

    foreach ($name in @('reasoningEffort', 'ciFixReasoningEffort', 'preCommitFixReasoningEffort')) {
        $value = [string]$Config.agent.$name

        if ($value -notin @('minimal', 'low', 'medium', 'high', 'xhigh')) {
            throw "Configuration value '$.agent.$name' must be minimal, low, medium, high, or xhigh."
        }
    }

    Assert-RepoFlowBoolean -Value $Config.agent.runProjectChecks -Path '$.agent.runProjectChecks'

    Assert-RepoFlowBoolean -Value $Config.pullRequest.createDraft -Path '$.pullRequest.createDraft'
    Assert-RepoFlowString -Value $Config.pullRequest.templatePath -Path '$.pullRequest.templatePath'

    if ($Config.pullRequest.mergeMethod -notin @('squash', 'merge', 'rebase')) {
        throw "Configuration value '$.pullRequest.mergeMethod' must be squash, merge, or rebase."
    }

    Assert-RepoFlowBoolean -Value $Config.pullRequest.deleteBranchOnMerge -Path '$.pullRequest.deleteBranchOnMerge'

    foreach ($name in @('initialCommit', 'reviewCommit', 'ciFixCommit', 'pullRequestTitle')) {
        Assert-RepoFlowString -Value $Config.messages.$name -Path "$.messages.$name"
        Expand-RepoFlowMessageTemplate `
            -Template ([string]$Config.messages.$name) `
            -Values @{
                verb = 'Implement'
                issueNumber = 1
                issueTitle = 'Example issue'
            } |
            Out-Null
    }

    if ($Config.ci.mode -notin @('skip', 'observe', 'require-passing')) {
        throw "Configuration value '$.ci.mode' must be skip, observe, or require-passing."
    }

    Assert-RepoFlowIntegerRange -Value $Config.ci.pollSeconds -Minimum 10 -Maximum 300 -Path '$.ci.pollSeconds'
    Assert-RepoFlowIntegerRange -Value $Config.ci.timeoutSeconds -Minimum 30 -Maximum 7200 -Path '$.ci.timeoutSeconds'
    Assert-RepoFlowIntegerRange -Value $Config.ci.autoFixAttempts -Minimum 0 -Maximum 5 -Path '$.ci.autoFixAttempts'

    if ($Config.ci.mode -ne 'require-passing' -and $Config.ci.autoFixAttempts -gt 0) {
        throw "Configuration value '$.ci.autoFixAttempts' must be 0 unless '$.ci.mode' is 'require-passing'."
    }

    Assert-RepoFlowBoolean -Value $Config.reviewFeedback.enabled -Path '$.reviewFeedback.enabled'
    Assert-RepoFlowBoolean -Value $Config.reviewFeedback.confirmBeforeRun -Path '$.reviewFeedback.confirmBeforeRun'
    $maxReviewCycles = Get-RepoFlowProperty `
        -Object $Config.reviewFeedback `
        -Name 'maxReviewCycles' `
        -Default 3
    $maxRepairCycles = Get-RepoFlowProperty `
        -Object $Config.reviewFeedback `
        -Name 'maxRepairCycles' `
        -Default 2
    Assert-RepoFlowIntegerRange `
        -Value $maxReviewCycles `
        -Minimum 1 `
        -Maximum 10 `
        -Path '$.reviewFeedback.maxReviewCycles'
    Assert-RepoFlowIntegerRange `
        -Value $maxRepairCycles `
        -Minimum 0 `
        -Maximum 10 `
        -Path '$.reviewFeedback.maxRepairCycles'

    $trusted = @($Config.reviewFeedback.trustedAssociations)

    if ($trusted.Count -eq 0) {
        throw "Configuration value '$.reviewFeedback.trustedAssociations' must contain at least one value."
    }

    foreach ($association in $trusted) {
        if ($association -notin @('OWNER', 'MEMBER', 'COLLABORATOR')) {
            throw "Unsupported trusted association '$association'. Use OWNER, MEMBER, or COLLABORATOR."
        }
    }
}

function Get-RepoFlowEffectiveCiMode {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config,

        [string]$Override
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override
    }

    return [string]$Config.ci.mode
}

function Show-RepoFlowConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Config
    )

    $display = [ordered]@{
        configPath = $Config.configPath
        selectedRepository = $Config.selectedRepository
        repositorySelectionSource = $Config.repositorySelectionSource
        defaultRepository = $Config.defaultRepository
        repositories = $Config.repositories
        repository = $Config.repository
        issues = $Config.issues
        git = $Config.git
        agent = $Config.agent
        pullRequest = $Config.pullRequest
        messages = $Config.messages
        ci = $Config.ci
        reviewFeedback = $Config.reviewFeedback
    }

    $display | ConvertTo-Json -Depth 10
}
