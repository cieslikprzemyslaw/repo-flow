function Initialize-RepoFlowRunTelemetryFields {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $Record
    )

    foreach ($name in @(
        'lastHeartbeatAtUtc',
        'lastObservableActivityAtUtc'
    )) {
        if ($null -eq $Record.PSObject.Properties[$name]) {
            $Record | Add-Member `
                -MemberType NoteProperty `
                -Name $name `
                -Value $null
        }
    }

    return $Record
}

function Set-RepoFlowRunHeartbeat {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ConfigPath,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$RunId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$CurrentPhase,

        [switch]$ObservableActivity
    )

    if (
        [string]::IsNullOrWhiteSpace($ConfigPath) -or
        [string]::IsNullOrWhiteSpace($RunId)
    ) {
        return
    }

    $heartbeatAt = New-RepoFlowRunTimestamp

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        foreach ($record in @($document.runs)) {
            if (
                -not [string]::Equals(
                    [string]$record.runId,
                    $RunId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                continue
            }

            Initialize-RepoFlowRunTelemetryFields -Record $record | Out-Null

            if (-not [string]::IsNullOrWhiteSpace($CurrentPhase)) {
                $record.currentPhase = $CurrentPhase
            }

            $record.lastHeartbeatAtUtc = $heartbeatAt

            if ($ObservableActivity) {
                $record.lastObservableActivityAtUtc = $heartbeatAt
            }

            $record.updatedAtUtc = $heartbeatAt
            return $document
        }

        throw "Unknown RepoFlow run record: $RunId"
    } | Out-Null
}
