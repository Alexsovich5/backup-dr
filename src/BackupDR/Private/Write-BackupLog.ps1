function Write-BackupLog {
    <#
    .SYNOPSIS
        Writes a timestamped line to the host and appends it to the module log file.
    .DESCRIPTION
        Line format: [yyyy-MM-dd HH:mm:ss] [LEVEL] message. The file is $script:LogPath,
        set with Set-BackupLogPath; its directory is created when missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter(Position = 1)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line

    if ($script:LogPath) {
        $directory = Split-Path -Parent $script:LogPath
        if ($directory -and -not (Test-Path -Path $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        Add-Content -Path $script:LogPath -Value $line
    }
}
