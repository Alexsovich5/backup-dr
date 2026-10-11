function Get-BackupJobReport {
    <#
    .SYNOPSIS
        Reads the newest backup session of each job and returns one report row per job.
    .DESCRIPTION
        For every job name, asks Get-VBRBackupSession for the job's sessions, keeps only those
        whose JobName matches, and picks the one with the latest CreationTime. The row carries
        the session result as Status, its start/end time and the DataSize and DedupRatio from
        BackupStats. A job without any session is reported with Status 'NoSession'.

        With -Policy, only the jobs whose verifyAfterBackup is true are verified; jobs with
        verifyAfterBackup false (or unset) are not queried at all.
    .EXAMPLE
        Get-BackupJobReport -JobName 'Production-Servers-Daily', 'File-Servers-Daily'
    .EXAMPLE
        Get-BackupJobReport -Policy (Get-BackupPolicy -Path config/backup_policy.json)
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'ByName', Position = 0)]
        [string[]]$JobName,

        [Parameter(Mandatory = $true, ParameterSetName = 'ByPolicy')]
        [psobject]$Policy
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByPolicy') {
        $JobName = @(
            @($Policy.jobs) |
                Where-Object { $null -ne $_ -and $_.verifyAfterBackup -eq $true } |
                ForEach-Object { [string]$_.name }
        )
    }

    foreach ($name in $JobName) {
        Write-BackupLog -Message "Verifying backup integrity: $name"

        $latest = @(Get-VBRBackupSession -Name $name) |
            Where-Object { $null -ne $_ -and $_.JobName -eq $name } |
            Sort-Object -Property CreationTime -Descending |
            Select-Object -First 1

        if ($null -eq $latest) {
            Write-BackupLog -Level 'WARN' -Message "No backup session found for $name"
            [pscustomobject]@{
                JobName    = $name
                Status     = 'NoSession'
                StartTime  = $null
                EndTime    = $null
                DataSize   = $null
                DedupRatio = $null
            }
            continue
        }

        $dataSize = $null
        $dedupRatio = $null
        if ($null -ne $latest.BackupStats) {
            $dataSize = $latest.BackupStats.DataSize
            $dedupRatio = $latest.BackupStats.DedupRatio
        }

        [pscustomobject]@{
            JobName    = $name
            Status     = [string]$latest.Result
            StartTime  = $latest.CreationTime
            EndTime    = $latest.EndTime
            DataSize   = $dataSize
            DedupRatio = $dedupRatio
        }
    }
}
