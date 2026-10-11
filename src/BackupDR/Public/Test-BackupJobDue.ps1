function Test-BackupJobDue {
    <#
    .SYNOPSIS
        Decides whether a policy job should run at the given time.
    .DESCRIPTION
        A job is due when its schedule contains 'Daily' or the weekday name of -Now
        (compared case-insensitively). When the job also sets intervalMinutes, it is
        only due if -LastRun is absent or at least intervalMinutes before -Now.
        A -LastRun later than -Now (clock skew, or a session stamped in the future)
        makes an interval job not due and writes a WARN log line.
    .EXAMPLE
        Test-BackupJobDue -Job $policy.jobs[2] -Now (Get-Date) -LastRun $session.CreationTime
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Job,

        [Parameter(Mandatory = $true)]
        [datetime]$Now,

        [Nullable[datetime]]$LastRun
    )

    $dayName = $Now.DayOfWeek.ToString()
    $scheduled = $false
    foreach ($entry in @($Job.schedule)) {
        if ($null -eq $entry) { continue }
        $value = [string]$entry
        if ([string]::Equals($value, 'Daily', [System.StringComparison]::OrdinalIgnoreCase) -or
            [string]::Equals($value, $dayName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $scheduled = $true
            break
        }
    }
    if (-not $scheduled) {
        return $false
    }

    $interval = $null
    if ($Job.PSObject.Properties['intervalMinutes'] -and $null -ne $Job.intervalMinutes) {
        $interval = [int]$Job.intervalMinutes
    }
    if ($null -eq $interval -or $null -eq $LastRun) {
        return $true
    }

    $lastRunValue = [datetime]$LastRun
    if ($lastRunValue -gt $Now) {
        Write-BackupLog -Level 'WARN' -Message (
            "Job '{0}' last ran at {1:yyyy-MM-dd HH:mm:ss}, after the evaluation time {2:yyyy-MM-dd HH:mm:ss}; not starting it" -f
            $Job.name, $lastRunValue, $Now)
        return $false
    }

    return (($Now - $lastRunValue).TotalMinutes -ge $interval)
}
