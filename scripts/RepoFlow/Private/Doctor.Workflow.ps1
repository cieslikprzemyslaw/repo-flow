function Get-RepoFlowDoctorResults {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Repo,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $results = [System.Collections.Generic.List[object]]::new()
    Add-RepoFlowDoctorRuntimeChecks -Results $results

    $snapshot = Get-RepoFlowDoctorConfigurationSnapshot `
        -ConfigPath $ConfigPath `
        -Repo $Repo
    Add-RepoFlowDoctorConfigurationChecks `
        -Results $results `
        -Snapshot $snapshot

    Add-RepoFlowDoctorStateCheck `
        -Results $results `
        -ConfigPath ([string]$snapshot.ConfigPath)

    $toolState = Add-RepoFlowDoctorToolChecks `
        -Results $results `
        -Snapshot $snapshot
    Add-RepoFlowDoctorRepositoryChecks `
        -Results $results `
        -Snapshot $snapshot `
        -ToolState $toolState

    return $results.ToArray()
}

function Invoke-RepoFlowDoctorWorkflow {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Repo,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath
    )

    $results = @(Get-RepoFlowDoctorResults `
        -Repo $Repo `
        -ConfigPath $ConfigPath)
    $report = Format-RepoFlowDoctorReport -Results $results

    Write-Host $report

    $failureCount = Get-RepoFlowDoctorFailureCount -Results $results

    if ($failureCount -gt 0) {
        throw "RepoFlow doctor found $failureCount required failure(s)."
    }
}
