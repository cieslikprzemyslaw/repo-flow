function Resume-RepoFlowRunRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ConfigPath,

        [Parameter(Mandatory)]
        [string]$RunId,

        [AllowNull()]
        [AllowEmptyString()]
        [string]$CurrentPhase
    )

    Invoke-RepoFlowStateMutation -ConfigPath $ConfigPath -Update {
        param($document)

        $updated = $false

        foreach ($record in @($document.runs)) {
            if (
                [string]::Equals(
                    [string]$record.runId,
                    $RunId,
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                $record.status = 'running'
                if (-not [string]::IsNullOrWhiteSpace($CurrentPhase)) {
                    $record.currentPhase = $CurrentPhase
                }
                $record.completedAtUtc = $null
                $record.terminalOutcome = $null
                $record.pauseReason = $null
                $record.updatedAtUtc = New-RepoFlowRunTimestamp
                $updated = $true
                break
            }
        }

        if (-not $updated) {
            throw "Unknown RepoFlow run record: $RunId"
        }

        return $document
    } | Out-Null
}
