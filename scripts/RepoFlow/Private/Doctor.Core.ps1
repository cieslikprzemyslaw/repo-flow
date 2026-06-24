function New-RepoFlowDoctorResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'WARN', 'FAIL')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Group,

        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [string]$Details
    )

    return [pscustomobject][ordered]@{
        Status = $Status
        Group = $Group
        Check = $Check
        Details = ConvertTo-RepoFlowDoctorSingleLine -Text $Details
    }
}

function Add-RepoFlowDoctorResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Results,

        [Parameter(Mandatory)]
        [ValidateSet('PASS', 'WARN', 'FAIL')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Group,

        [Parameter(Mandatory)]
        [string]$Check,

        [Parameter(Mandatory)]
        [string]$Details
    )

    $Results.Add((New-RepoFlowDoctorResult `
        -Status $Status `
        -Group $Group `
        -Check $Check `
        -Details $Details)) | Out-Null
}

function ConvertTo-RepoFlowDoctorSingleLine {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Text,

        [ValidateRange(5, 1000)]
        [int]$MaximumLength = 220
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return '-'
    }

    $singleLine = ($Text -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()

    if ($singleLine.Length -le $MaximumLength) {
        return $singleLine
    }

    return $singleLine.Substring(0, $MaximumLength - 3) + '...'
}

function Format-RepoFlowDoctorReport {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Results = @()
    )

    $rows = @($Results)
    $statusWidth = 6
    $groupWidth = 5
    $checkWidth = 5

    foreach ($row in $rows) {
        $groupWidth = [Math]::Max($groupWidth, ([string]$row.Group).Length)
        $checkWidth = [Math]::Max($checkWidth, ([string]$row.Check).Length)
    }

    $groupWidth = [Math]::Min($groupWidth, 22)
    $checkWidth = [Math]::Min($checkWidth, 34)

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('RepoFlow doctor')
    $lines.Add('')
    $lines.Add(('{0}  {1}  {2}  {3}' -f
        'STATUS'.PadRight($statusWidth),
        'GROUP'.PadRight($groupWidth),
        'CHECK'.PadRight($checkWidth),
        'DETAILS'))
    $lines.Add(('{0}  {1}  {2}  {3}' -f
        ('-' * $statusWidth),
        ('-' * $groupWidth),
        ('-' * $checkWidth),
        ('-' * 32)))

    foreach ($row in $rows) {
        $group = ConvertTo-RepoFlowDoctorSingleLine -Text ([string]$row.Group) -MaximumLength $groupWidth
        $check = ConvertTo-RepoFlowDoctorSingleLine -Text ([string]$row.Check) -MaximumLength $checkWidth
        $lines.Add(('{0}  {1}  {2}  {3}' -f
            ([string]$row.Status).PadRight($statusWidth),
            $group.PadRight($groupWidth),
            $check.PadRight($checkWidth),
            ([string]$row.Details)))
    }

    $passCount = @($rows | Where-Object { $_.Status -eq 'PASS' }).Count
    $warnCount = @($rows | Where-Object { $_.Status -eq 'WARN' }).Count
    $failCount = @($rows | Where-Object { $_.Status -eq 'FAIL' }).Count

    $lines.Add('')
    $lines.Add("Summary: $passCount PASS, $warnCount WARN, $failCount FAIL")

    return ($lines -join [Environment]::NewLine)
}

function Get-RepoFlowDoctorFailureCount {
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [object[]]$Results = @()
    )

    return @($Results | Where-Object { $_.Status -eq 'FAIL' }).Count
}
