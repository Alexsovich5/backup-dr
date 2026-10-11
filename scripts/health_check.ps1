<#
.SYNOPSIS
    Checks backup repositories, job results and schedules, and retention compliance.
.DESCRIPTION
    Loads the backup policy, runs Get-BackupServerHealth and prints one line per check followed
    by a summary line:

      <OK|WARNING|CRITICAL> <Type> <Name>: <message>
      <STATE> - <n> checks, <m> warnings, <k> critical[; retention: <job>: <issues> ...]

    Check types are Repository, LastResult, Schedule and Retention. Retention issues of
    non-compliant jobs are repeated in the summary line.

    Exit code (Nagios convention): 0 OK, 1 WARNING, 2 CRITICAL. A policy that cannot be loaded
    is CRITICAL.

    The vendor commands come from BACKUPDR_PROVIDER (veeam, simulator or none).
.PARAMETER ConfigPath
    Backup policy file. Default: config/backup_policy.json under the repository.
.PARAMETER Now
    Time that ages and schedules are measured against. Default: the current time.
.EXAMPLE
    pwsh scripts/health_check.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [datetime]$Now = (Get-Date)
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path (Join-Path $repoRoot 'config') 'backup_policy.json' }

Import-Module (Join-Path (Join-Path $repoRoot 'src') 'BackupDR') -Force
Set-BackupLogPath -Path (Join-Path (Join-Path $repoRoot 'logs') 'health_check.log')

try {
    $policy = Get-BackupPolicy -Path $ConfigPath
}
catch {
    Write-Output "CRITICAL - cannot load backup policy: $($_.Exception.Message)"
    exit 2
}

$health = Get-BackupServerHealth -Policy $policy -Now $Now
$checks = @($health.Checks)

foreach ($check in $checks) {
    Write-Output ('{0,-8} {1,-10} {2}: {3}' -f $check.State, $check.Type, $check.Name, $check.Message)
}

$warnings = @($checks | Where-Object { $_.State -eq 'WARNING' }).Count
$critical = @($checks | Where-Object { $_.State -eq 'CRITICAL' }).Count
$summary = '{0} - {1} checks, {2} warnings, {3} critical' -f $health.State, $checks.Count, $warnings, $critical

$retention = @($checks | Where-Object { $_.Type -eq 'Retention' -and $_.State -ne 'OK' })
if ($retention.Count -gt 0) {
    $summary += '; retention: ' + (@($retention | ForEach-Object { '{0}: {1}' -f $_.Name, $_.Message }) -join '; ')
}
Write-Output $summary

exit $health.ExitCode
