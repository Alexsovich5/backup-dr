function Start-BackupJob {
    <#
    .SYNOPSIS
        Starts the Veeam job for a policy entry and waits for its session to finish.
    .DESCRIPTION
        Looks the job up with Get-VBRJob by its exact policy name: a name with wildcard
        characters, or one that two Veeam jobs share, is an Error and nothing is started; a
        lookup that returns only other names (for example prefix matches) is NotFound.
        Refuses to start a job that is already Working, notes the job's last session, starts it
        with Start-VBRJob -RunAsync (-FullBackup for a 'full' policy job) and then checks
        FindLastSession(). The first check happens straight after the start, so a session that
        has already finished costs no sleep. Until a session other than the one noted before
        the start exists and has reached the Stopped state, the function sleeps -PollSeconds
        and checks again, at most ceil(timeoutHours * 3600 / max(PollSeconds, 1)) times.

        Result is the new session's result when it is Success, Warning or Failed; 'Timeout'
        when the new session is still running after the budget; 'Unknown' when no new session
        appeared or it stopped with any other result (such as None). The previous run's result
        is never reported as this run's.

        Returns an object with JobName, Outcome (Started, NotFound, AlreadyRunning, DryRun or
        Error), Result, Duration (session EndTime minus CreationTime when both are known) and
        Message.
    .PARAMETER PollSeconds
        Seconds between session checks. Defaults to $env:BACKUPDR_POLL_SECONDS, else 60.
        0 is allowed (no wait between checks; the number of checks stays bounded).
    .PARAMETER Alerting
        The policy's alerting block. When given, an Error or NotFound outcome and a Failed,
        Timeout or Unknown result send 'Backup FAILED: <job>' if alertOnFailure is true; a
        Warning result sends 'Backup WARNING: <job>' if alertOnWarning is true. Mail goes
        through Send-BackupAlert, so SMTP problems are logged and do not change the outcome.
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
        [int]$PollSeconds,

        [psobject]$Alerting
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
        $veeamJob = Resolve-ExactVendorObject -Kind 'Veeam job' -Name $jobName -AllowMissing -Lookup {
            param($n)
            Get-VBRJob -Name $n
        }
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

        # The session of the previous run, so it is not mistaken for this run's session.
        $previous = $veeamJob.FindLastSession()

        Write-BackupLog -Message "Starting backup job: $jobName"
        $startParams = @{ Job = $veeamJob; RunAsync = $true }
        if ([string]$Job.type -eq 'full') {
            $startParams['FullBackup'] = $true
        }
        Start-VBRJob @startParams | Out-Null
        $outcome.Outcome = 'Started'

        $timeoutSeconds = [double]$Job.timeoutHours * 3600
        $maxPolls = [int][math]::Ceiling($timeoutSeconds / [math]::Max($PollSeconds, 1))

        $isNewSession = {
            param($Candidate)
            if ($null -eq $Candidate) { return $false }
            if ($null -eq $previous) { return $true }
            $candidateId = [string]$Candidate.Id
            $previousId = [string]$previous.Id
            if ($candidateId -or $previousId) { return $candidateId -ne $previousId }
            [string]$Candidate.CreationTime -ne [string]$previous.CreationTime
        }

        $session = $veeamJob.FindLastSession()
        for ($i = 0; $i -lt $maxPolls -and -not ((& $isNewSession $session) -and $session.State -eq 'Stopped'); $i++) {
            Start-Sleep -Seconds $PollSeconds
            $session = $veeamJob.FindLastSession()
        }

        $finalResults = @('Success', 'Warning', 'Failed')
        if (-not (& $isNewSession $session)) {
            $outcome.Result = 'Unknown'
            $outcome.Message = "Job $jobName was started but no new session appeared within $($Job.timeoutHours) h ($maxPolls checks)"
            Write-BackupLog -Level 'ERROR' -Message $outcome.Message
        }
        elseif ($session.State -ne 'Stopped') {
            $outcome.Result = 'Timeout'
            $outcome.Message = "Job $jobName still $($session.State) after $($Job.timeoutHours) h ($maxPolls checks)"
            Write-BackupLog -Level 'ERROR' -Message $outcome.Message
        }
        elseif ($finalResults -notcontains [string]$session.Result) {
            $outcome.Result = 'Unknown'
            $outcome.Message = "Job $jobName stopped with result '$($session.Result)', not Success, Warning or Failed"
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

    if ($Alerting) {
        $severity = $null
        if (@('Error', 'NotFound') -contains $outcome.Outcome -or
            @('Failed', 'Timeout', 'Unknown') -contains $outcome.Result) {
            if ($Alerting.alertOnFailure -eq $true) { $severity = 'FAILED' }
        }
        elseif ($outcome.Result -eq 'Warning') {
            if ($Alerting.alertOnWarning -eq $true) { $severity = 'WARNING' }
        }

        if ($severity) {
            $body = "Job: $jobName`r`nOutcome: $($outcome.Outcome)`r`nResult: $($outcome.Result)`r`n$($outcome.Message)"
            Send-BackupAlert -Alerting $Alerting -Subject "Backup ${severity}: $jobName" -Body $body
        }
    }

    $outcome
}
