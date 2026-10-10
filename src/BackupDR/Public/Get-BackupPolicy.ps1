function Get-BackupPolicy {
    <#
    .SYNOPSIS
        Loads backup_policy.json and validates it.
    .DESCRIPTION
        Every job must have a unique, non-empty name, a type of incremental or full,
        a schedule made of weekday names or Daily, timeoutHours greater than 0,
        retentionDays of at least 1 and, when present, intervalMinutes of at least 15.
        All problems are collected and reported in a single error.

        BACKUPDR_SMTP_SERVER and BACKUPDR_SMTP_PORT, when set, replace
        alerting.smtpServer and alerting.smtpPort.
    .EXAMPLE
        $policy = Get-BackupPolicy -Path .\config\backup_policy.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "Backup policy not found: $Path"
    }

    try {
        $policy = Get-Content -Path $Path -Raw | ConvertFrom-Json
    } catch {
        throw "Backup policy $Path is not valid JSON: $($_.Exception.Message)"
    }

    $problems = New-Object System.Collections.Generic.List[string]
    $jobTypes = @('incremental', 'full')
    $scheduleValues = @('Daily', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')

    if ($null -eq $policy -or $null -eq $policy.jobs -or @($policy.jobs).Count -eq 0) {
        $problems.Add('jobs: at least one job is required')
    } else {
        $seenNames = @{}
        $index = 0
        foreach ($job in @($policy.jobs)) {
            $name = [string]$job.name
            if ([string]::IsNullOrWhiteSpace($name)) {
                $problems.Add("jobs[$index]: name is required")
                $label = "jobs[$index]"
            } else {
                $label = "job '$name'"
                if ($seenNames.ContainsKey($name)) {
                    if ($seenNames[$name] -eq 1) {
                        $problems.Add("duplicate job name '$name'")
                    }
                    $seenNames[$name]++
                } else {
                    $seenNames[$name] = 1
                }
            }

            if ($jobTypes -notcontains [string]$job.type) {
                $problems.Add("${label}: type '$($job.type)' is not one of $($jobTypes -join ', ')")
            }

            $schedule = @($job.schedule | Where-Object { $null -ne $_ })
            if ($schedule.Count -eq 0) {
                $problems.Add("${label}: schedule must list weekday names or Daily")
            }
            foreach ($day in $schedule) {
                if ($scheduleValues -notcontains [string]$day) {
                    $problems.Add("${label}: schedule value '$day' is not a weekday name or Daily")
                }
            }

            if (-not (Test-PolicyNumber -Value $job.timeoutHours -Minimum 0 -Exclusive)) {
                $problems.Add("${label}: timeoutHours must be greater than 0")
            }
            if (-not (Test-PolicyNumber -Value $job.retentionDays -Minimum 1)) {
                $problems.Add("${label}: retentionDays must be at least 1")
            }
            if ($job.PSObject.Properties.Name -contains 'intervalMinutes' -and
                -not (Test-PolicyNumber -Value $job.intervalMinutes -Minimum 15)) {
                $problems.Add("${label}: intervalMinutes must be at least 15")
            }
            $index++
        }
    }

    if ($problems.Count -gt 0) {
        $message = "Backup policy $Path has $($problems.Count) problem(s):`n  - " + ($problems -join "`n  - ")
        throw $message
    }

    if ($null -ne $policy.alerting) {
        if ($env:BACKUPDR_SMTP_SERVER) {
            $policy.alerting | Add-Member -MemberType NoteProperty -Name smtpServer -Value $env:BACKUPDR_SMTP_SERVER -Force
        }
        if ($env:BACKUPDR_SMTP_PORT) {
            $port = 0
            if (-not [int]::TryParse($env:BACKUPDR_SMTP_PORT, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                throw "BACKUPDR_SMTP_PORT '$($env:BACKUPDR_SMTP_PORT)' is not a valid port number"
            }
            $policy.alerting | Add-Member -MemberType NoteProperty -Name smtpPort -Value $port -Force
        }
    }

    Write-BackupLog -Message "Loaded backup policy $Path ($(@($policy.jobs).Count) jobs)"
    $policy
}
