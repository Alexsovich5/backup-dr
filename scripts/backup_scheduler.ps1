# Backup Scheduler - Veeam Automation
# IT Administrator - Zambaiti (2018-2019)
#
# Manages Veeam backup jobs with policy-based scheduling,
# verification, and reporting.

param(
    [string]$ConfigPath = "..\config\backup_policy.json",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

# Load Veeam PowerShell module
Add-PSSnapin VeeamPSSnapin -ErrorAction SilentlyContinue

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
    Add-Content -Path "C:\Logs\backup_scheduler.log" -Value "[$timestamp] [$Level] $Message"
}

function Get-BackupPolicy {
    param([string]$Path)
    $json = Get-Content $Path -Raw | ConvertFrom-Json
    return $json
}

function Start-BackupJob {
    param([PSObject]$Job)

    Write-Log "Starting backup job: $($Job.name)"

    if ($DryRun) {
        Write-Log "DRY RUN: Would start $($Job.name)" "WARN"
        return
    }

    try {
        $veeamJob = Get-VBRJob -Name $Job.name
        if (-not $veeamJob) {
            Write-Log "Job not found: $($Job.name)" "ERROR"
            return
        }

        # Check if already running
        if ($veeamJob.GetLastState() -eq "Working") {
            Write-Log "Job already running: $($Job.name)" "WARN"
            return
        }

        Start-VBRJob -Job $veeamJob
        Write-Log "Job started successfully: $($Job.name)"

        # Wait and verify
        $timeout = New-TimeSpan -Hours $Job.timeoutHours
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        do {
            Start-Sleep -Seconds 60
            $session = $veeamJob.FindLastSession()
        } while ($session.State -eq "Working" -and $sw.Elapsed -lt $timeout)

        if ($session.Result -eq "Success") {
            Write-Log "Job completed successfully: $($Job.name)"
        } else {
            Write-Log "Job completed with status: $($session.Result)" "WARN"
            Send-AlertEmail -Subject "Backup Alert: $($Job.name)" -Body "Status: $($session.Result)"
        }

    } catch {
        Write-Log "Backup error: $($_.Exception.Message)" "ERROR"
        Send-AlertEmail -Subject "Backup FAILED: $($Job.name)" -Body $_.Exception.Message
    }
}

function Test-BackupIntegrity {
    param([string]$JobName)

    Write-Log "Verifying backup integrity: $JobName"
    $session = Get-VBRBackupSession | Where-Object { $_.JobName -eq $JobName } | Select-Object -First 1

    if ($session) {
        $result = @{
            JobName = $JobName
            Status = $session.Result
            StartTime = $session.CreationTime
            EndTime = $session.EndTime
            DataSize = $session.BackupStats.DataSize
            DedupRatio = $session.BackupStats.DedupRatio
        }
        return $result
    }
    return $null
}

function Send-AlertEmail {
    param([string]$Subject, [string]$Body)
    $params = @{
        From = "backup@zambaiti.local"
        To = "it-admin@zambaiti.local"
        Subject = $Subject
        Body = $Body
        SmtpServer = "smtp.zambaiti.local"
    }
    Send-MailMessage @params
}

# Main execution
Write-Log "=== Backup Scheduler Started ==="

$policy = Get-BackupPolicy -Path $ConfigPath

foreach ($job in $policy.jobs) {
    $dayOfWeek = (Get-Date).DayOfWeek.ToString()

    if ($job.schedule -contains $dayOfWeek -or $job.schedule -contains "Daily") {
        Start-BackupJob -Job $job
    } else {
        Write-Log "Skipping $($job.name) - not scheduled for $dayOfWeek"
    }
}

# Generate daily report
$report = @()
foreach ($job in $policy.jobs) {
    $integrity = Test-BackupIntegrity -JobName $job.name
    if ($integrity) { $report += $integrity }
}

Write-Log "=== Backup Scheduler Complete ==="
Write-Log "Jobs processed: $($policy.jobs.Count)"
