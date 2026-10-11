function Start-BackupJob {
    <#
    .SYNOPSIS
        Starts the Veeam job for a policy entry and waits for its session to finish.
    .DESCRIPTION
        Looks the job up with Get-VBRJob, refuses to start it when it is already Working,
        starts it with Start-VBRJob -RunAsync (-FullBackup for a 'full' policy job) and then
        checks FindLastSession().State. The first check happens straight after the start, so
        a session that has already finished costs no sleep. While the session is Working the
        function sleeps -PollSeconds and checks again, at most
        ceil(timeoutHours * 3600 / max(PollSeconds, 1)) times; when that budget is used up the
        result is 'Timeout'.

        Returns an object with JobName, Outcome (Started, NotFound, AlreadyRunning, DryRun or
        Error), Result (the session result, or 'Timeout'), Duration (session EndTime minus
        CreationTime when both are known) and Message.
    .PARAMETER PollSeconds
        Seconds between session checks. Defaults to $env:BACKUPDR_POLL_SECONDS, else 60.
        0 is allowed (no wait between checks; the number of checks stays bounded).
    .EXAMPLE
        Start-BackupJob -Job $policy.jobs[0] -PollSeconds 30
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Job,

        [switch]$DryRun,

        [ValidateRange(0, 86400)]
        [int]$PollSeconds
    )

    if (-not $PSBoundParameters.ContainsKey('PollSeconds')) {
        $PollSeconds = 60
        $fromEnv = 0
        if ($env:BACKUPDR_POLL_SECONDS -and [int]::TryParse($env:BACKUPDR_POLL_SECONDS, [ref]$fromEnv) -and $fromEnv -ge 0) {
            $PollSeconds = $fromEnv
        }
    }

    $jobName = [string]$Job.name
    $outcome = [pscustomobject]@{
        JobName  = $jobName
        Outcome  = $null
        Result   = $null
        Duration = $null
        Message  = $null
    }

    try {
        $veeamJob = Get-VBRJob -Name $jobName | Select-Object -First 1
        if (-not $veeamJob) {
            $outcome.Outcome = 'NotFound'
            $outcome.Message = "Job not found: $jobName"
            Write-BackupLog -Level 'ERROR' -Message $outcome.Message
            return $outcome
        }

        if ($veeamJob.GetLastState() -eq 'Working') {
            $outcome.Outcome = 'AlreadyRunning'
            $outcome.Message = "Job already running: $jobName"
            Write-BackupLog -Level 'WARN' -Message $outcome.Message
            return $outcome
        }

        if ($DryRun) {
            $outcome.Outcome = 'DryRun'
            $outcome.Message = "DRY RUN: would start $jobName"
            Write-BackupLog -Level 'WARN' -Message $outcome.Message
            return $outcome
        }

        Write-BackupLog -Message "Starting backup job: $jobName"
        $startParams = @{ Job = $veeamJob; RunAsync = $true }
        if ([string]$Job.type -eq 'full') {
            $startParams['FullBackup'] = $true
        }
        Start-VBRJob @startParams | Out-Null
        $outcome.Outcome = 'Started'

        $timeoutSeconds = [double]$Job.timeoutHours * 3600
        $maxPolls = [int][math]::Ceiling($timeoutSeconds / [math]::Max($PollSeconds, 1))

        $session = $veeamJob.FindLastSession()
        for ($i = 0; $i -lt $maxPolls -and $session -and $session.State -eq 'Working'; $i++) {
            Start-Sleep -Seconds $PollSeconds
            $session = $veeamJob.FindLastSession()
        }

        if (-not $session) {
            $outcome.Result = 'Unknown'
            $outcome.Message = "No session found for $jobName after start"
            Write-BackupLog -Level 'WARN' -Message $outcome.Message
        }
        elseif ($session.State -eq 'Working') {
            $outcome.Result = 'Timeout'
            $outcome.Message = "Job $jobName still running after $($Job.timeoutHours) h ($maxPolls checks)"
            Write-BackupLog -Level 'ERROR' -Message $outcome.Message
        }
        else {
            $outcome.Result = [string]$session.Result
            if ($session.CreationTime -and $session.EndTime) {
                $outcome.Duration = ([datetime]$session.EndTime) - ([datetime]$session.CreationTime)
            }
            $outcome.Message = "Job $jobName finished with result $($outcome.Result)"
            if ($outcome.Result -eq 'Success') {
                Write-BackupLog -Message $outcome.Message
            }
            else {
                Write-BackupLog -Level 'WARN' -Message $outcome.Message
            }
        }
    }
    catch {
        $outcome.Outcome = 'Error'
        $outcome.Message = $_.Exception.Message
        Write-BackupLog -Level 'ERROR' -Message "Backup error for ${jobName}: $($outcome.Message)"
    }

    $outcome
}
