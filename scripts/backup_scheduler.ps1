<#
.SYNOPSIS
    Starts the Veeam backup jobs that are due according to the backup policy.
.DESCRIPTION
    Loads and validates the policy, decides for each job whether it is due at -Now
    (weekday/Daily schedule and intervalMinutes against the job's newest session), starts the
    due jobs and waits for them, and alerts on warnings and failures as the policy's alerting
    block says. It then verifies the jobs marked verifyAfterBackup, writes an HTML report of
    every job's last result to -ReportPath and, when alerting.dailyReport is true, mails it.

    Exit code: 0 when every job that ran succeeded (or was skipped), 1 when any job ended with
    an error, was not found, failed or timed out, or when the policy cannot be loaded.

    The vendor commands come from BACKUPDR_PROVIDER (veeam, simulator or none).
.PARAMETER ConfigPath
    Backup policy file. Default: config/backup_policy.json next to this script's parent folder.
.PARAMETER DryRun
    Log which jobs would start without starting them. The report is still written; no mail is sent.
.PARAMETER Now
    Time used for every schedule decision. Default: the current time.
.PARAMETER PollSeconds
    Seconds between session checks while a job runs. Default: BACKUPDR_POLL_SECONDS, else 60.
.PARAMETER ReportPath
    Where the HTML report is written. Default: out/report.html under the repository.
.PARAMETER LogPath
    Log file. Default: logs/backup_scheduler.log under the repository.
.EXAMPLE
    pwsh scripts/backup_scheduler.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$DryRun,
    [datetime]$Now = (Get-Date),
    [ValidateRange(0, 86400)]
    [int]$PollSeconds,
    [string]$ReportPath,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) { $ConfigPath = Join-Path (Join-Path $repoRoot 'config') 'backup_policy.json' }
if (-not $ReportPath) { $ReportPath = Join-Path (Join-Path $repoRoot 'out') 'report.html' }
if (-not $LogPath) { $LogPath = Join-Path (Join-Path $repoRoot 'logs') 'backup_scheduler.log' }

Import-Module (Join-Path (Join-Path $repoRoot 'src') 'BackupDR') -Force
Set-BackupLogPath -Path $LogPath

function Write-SchedulerLog {
    # Writes through the module's private Write-BackupLog so lines share its format and log file.
    param([string]$Message, [string]$Level = 'INFO')
    & (Get-Module -Name BackupDR) { param($m, $l) Write-BackupLog -Message $m -Level $l } $Message $Level
}

function Get-JobLastRun {
    # Creation time of the job's newest backup session, or $null when it has none.
    param([string]$JobName)
    $latest = @(Get-VBRBackupSession -Name $JobName) |
        Where-Object { $null -ne $_ -and $_.JobName -eq $JobName -and $null -ne $_.CreationTime } |
        Sort-Object -Property CreationTime -Descending |
        Select-Object -First 1
    if ($latest) { return [datetime]$latest.CreationTime }
    $null
}

Write-SchedulerLog -Message ('=== Backup scheduler started for {0:yyyy-MM-dd HH:mm:ss} ===' -f $Now)

try {
    $policy = Get-BackupPolicy -Path $ConfigPath
}
catch {
    Write-SchedulerLog -Level 'ERROR' -Message $_.Exception.Message
    exit 1
}

$startParams = @{ Alerting = $policy.alerting }
if ($DryRun) { $startParams['DryRun'] = $true }
if ($PSBoundParameters.ContainsKey('PollSeconds')) { $startParams['PollSeconds'] = $PollSeconds }

$results = @()
foreach ($job in @($policy.jobs)) {
    $lastRun = Get-JobLastRun -JobName ([string]$job.name)
    if (-not (Test-BackupJobDue -Job $job -Now $Now -LastRun $lastRun)) {
        Write-SchedulerLog -Message ('Skipping {0} - not due at {1:yyyy-MM-dd HH:mm} ({2})' -f $job.name, $Now, $Now.DayOfWeek)
        continue
    }
    $results += Start-BackupJob -Job $job @startParams
}

$failed = @($results | Where-Object {
        @('Error', 'NotFound') -contains $_.Outcome -or @('Failed', 'Timeout') -contains $_.Result
    })

# Post-backup verification of the jobs marked verifyAfterBackup.
$rowsByJob = @{}
foreach ($row in @(Get-BackupJobReport -Policy $policy)) {
    $rowsByJob[$row.JobName] = $row
    if ($row.Status -ne 'Success') {
        Write-SchedulerLog -Level 'WARN' -Message "Verification of $($row.JobName): latest session status is $($row.Status)"
    }
}

# Daily report of every job's last result, in policy order. Jobs that are not verified are
# read only for the report.
$jobNames = @($policy.jobs | ForEach-Object { [string]$_.name })
$unverified = @($jobNames | Where-Object { -not $rowsByJob.ContainsKey($_) })
if ($unverified.Count -gt 0) {
    foreach ($row in @(Get-BackupJobReport -JobName $unverified)) {
        $rowsByJob[$row.JobName] = $row
    }
}
$report = @($jobNames | ForEach-Object { $rowsByJob[$_] })
$title = 'Daily Backup Report {0:yyyy-MM-dd}' -f $Now
$html = ConvertTo-BackupReportHtml -Report $report -Title $title

$reportDir = Split-Path -Parent $ReportPath
if ($reportDir -and -not (Test-Path -Path $reportDir -PathType Container)) {
    New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
}
Set-Content -Path $ReportPath -Value $html -Encoding UTF8
Write-SchedulerLog -Message "Report written to $ReportPath ($($report.Count) jobs)"

if ($DryRun) {
    Write-SchedulerLog -Level 'WARN' -Message 'DRY RUN: daily report not mailed'
}
elseif ($policy.alerting -and $policy.alerting.dailyReport -eq $true) {
    Send-BackupAlert -Alerting $policy.alerting -Subject $title -Body $html -BodyAsHtml
}

Write-SchedulerLog -Message ('=== Backup scheduler complete: {0} job(s) in policy, {1} due, {2} failed ===' -f
    $jobNames.Count, $results.Count, $failed.Count)

if ($failed.Count -gt 0) {
    exit 1
}
exit 0
