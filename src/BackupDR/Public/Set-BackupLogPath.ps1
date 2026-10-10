function Set-BackupLogPath {
    <#
    .SYNOPSIS
        Sets the file that Write-BackupLog appends to and creates its directory.
    .DESCRIPTION
        Relative paths and PowerShell drive paths (for example TestDrive:\logs\run.log)
        are resolved to a file system path. Without a call to this function the
        module logs to logs/backupdr.log under the repository.
    .EXAMPLE
        Set-BackupLogPath -Path D:\Logs\backup_scheduler.log
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    $resolved = $PSCmdlet.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    if (-not $PSCmdlet.ShouldProcess($resolved, 'Set backup log path')) {
        return
    }

    $directory = Split-Path -Parent $resolved
    if ($directory -and -not (Test-Path -Path $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $script:LogPath = $resolved
}
