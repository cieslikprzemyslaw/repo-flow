function Expand-RepoFlowGitHubPagedItems {
    [CmdletBinding()]
    param(
        [AllowNull()]
        $Data
    )

    $items = [System.Collections.Generic.List[object]]::new()

    foreach ($page in @($Data)) {
        if ($null -eq $page) {
            continue
        }

        if ($page -is [System.Array]) {
            foreach ($item in $page) {
                if ($null -ne $item) {
                    $items.Add($item)
                }
            }
        }
        else {
            $items.Add($page)
        }
    }

    return $items.ToArray()
}

function Get-RepoFlowAuthenticatedGitHubLogin {
    [CmdletBinding()]
    param()

    $result = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'api',
        'user'
    )

    $login = [string](Get-RepoFlowProperty `
        -Object $result.Data `
        -Name 'login' `
        -Default '')

    if ([string]::IsNullOrWhiteSpace($login)) {
        throw 'GitHub did not return the authenticated user login.'
    }

    return $login
}

function Get-RepoFlowAllPullRequestComments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $result = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'api',
        '--paginate',
        '--slurp',
        "repos/$Repository/issues/$PullRequestNumber/comments?per_page=100"
    )

    return @(
        Expand-RepoFlowGitHubPagedItems -Data $result.Data
    )
}

function Get-RepoFlowPullRequestFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$Repository
    )

    $result = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
        'api',
        '--paginate',
        '--slurp',
        "repos/$Repository/pulls/$PullRequestNumber/files?per_page=100"
    )

    return @(
        Expand-RepoFlowGitHubPagedItems -Data $result.Data
    )
}

function New-RepoFlowPullRequestComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [int]$PullRequestNumber,

        [Parameter(Mandatory)]
        [string]$Repository,

        [Parameter(Mandatory)]
        [string]$Body
    )

    $payloadPath = [System.IO.Path]::GetTempFileName()
    $utf8WithoutBom = [System.Text.UTF8Encoding]::new($false)

    try {
        $payload = [pscustomobject]@{ body = $Body } | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText(
            $payloadPath,
            $payload,
            $utf8WithoutBom
        )

        $result = Invoke-RepoFlowJsonCommand -Command 'gh' -Arguments @(
            'api',
            '--method',
            'POST',
            "repos/$Repository/issues/$PullRequestNumber/comments",
            '--input',
            $payloadPath
        )

        return $result.Data
    }
    finally {
        Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
    }
}
