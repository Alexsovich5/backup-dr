function Get-BackupServerHealth {
    <#
    .SYNOPSIS
        Checks backup repositories, each job's last result and schedule, and retention compliance.
    .DESCRIPTION
        Builds a list of checks, each with Type, Name, State (OK, WARNING or CRITICAL) and Message:

          Repository  one per Get-VBRBackupRepository entry: free space as a percentage of
                      capacity (GetContainer().CachedFreeSpace / CachedTotalSpace). Below
                      health.repositoryMinFreePercent (default 15) is a WARNING; repositories
                      that cannot be read are CRITICAL.
          LastResult  one per policy job, from the job's newest backup session: Failed is
                      CRITICAL; Warning, or no session at all, is a WARNING; a session still
                      running is OK.
          Schedule    one per policy job: the newest session is overdue (WARNING) when it is
                      older than the gap the schedule allows (intervalMinutes, one day for
                      Daily, else the longest gap between scheduled weekdays) plus timeoutHours.
          Retention   one per job from Test-RetentionCompliance -Now; a non-compliant job is a
                      WARNING whose message lists its issues.

        The overall state is the worst check state. All ages are measured from -Now.
    .EXAMPLE
        Get-BackupServerHealth -Policy (Get-BackupPolicy -Path config/backup_policy.json)
    .OUTPUTS
        State, ExitCode (0 OK, 1 WARNING, 2 CRITICAL) and Checks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Policy,

        [datetime]$Now = (Get-Date)
    )

    $checks = New-Object System.Collections.Generic.List[object]
    $culture = [System.Globalization.CultureInfo]::InvariantCulture

    function Add-Check {
        param([string]$Type, [string]$Name, [string]$State, [string]$Message)
        $checks.Add([pscustomobject]@{ Type = $Type; Name = $Name; State = $State; Message = $Message })
    }

    # --- Repository free space ---------------------------------------------
    $minFree = 15.0
    if ($Policy.PSObject.Properties['health'] -and $null -ne $Policy.health -and
        $Policy.health.PSObject.Properties['repositoryMinFreePercent'] -and
        $null -ne $Policy.health.repositoryMinFreePercent) {
        $minFree = [double]$Policy.health.repositoryMinFreePercent
    }

    try {
        $repositories = @(@(Get-VBRBackupRepository) | Where-Object { $null -ne $_ })
        if ($repositories.Count -eq 0) {
            Add-Check 'Repository' '(none)' 'WARNING' 'no backup repositories found'
        }
        foreach ($repository in $repositories) {
            $name = [string]$repository.Name
            $container = $repository.GetContainer()
            $total = [double]$container.CachedTotalSpace.InBytes
            $free = [double]$container.CachedFreeSpace.InBytes
            if ($total -le 0) {
                Add-Check 'Repository' $name 'WARNING' 'capacity unknown (0 bytes reported)'
                continue
            }
            $percent = [math]::Round($free / $total * 100, 1)
            $text = '{0}% free ({1:N0} of {2:N0} GB), minimum {3}%' -f
                $percent.ToString('0.0', $culture), ($free / 1GB), ($total / 1GB), $minFree.ToString($culture)
            if ($percent -lt $minFree) {
                Add-Check 'Repository' $name 'WARNING' $text
            } else {
                Add-Check 'Repository' $name 'OK' $text
            }
        }
    } catch {
        Add-Check 'Repository' '(all)' 'CRITICAL' "cannot read backup repositories: $($_.Exception.Message)"
    }

    # --- Last result and schedule per job ---------------------------------
    foreach ($job in @($Policy.jobs)) {
        if ($null -eq $job) { continue }
        $name = [string]$job.name

        try {
            $latest = @(Get-VBRBackupSession -Name $name) |
                Where-Object { $null -ne $_ -and $_.JobName -eq $name -and $null -ne $_.CreationTime } |
                Sort-Object -Property CreationTime -Descending |
                Select-Object -First 1
        } catch {
            Add-Check 'LastResult' $name 'CRITICAL' "cannot read backup sessions: $($_.Exception.Message)"
            Add-Check 'Schedule' $name 'CRITICAL' "cannot read backup sessions: $($_.Exception.Message)"
            continue
        }

        if ($null -eq $latest) {
            Add-Check 'LastResult' $name 'WARNING' 'no backup session found'
            Add-Check 'Schedule' $name 'WARNING' 'overdue: the job has never run'
            continue
        }

        $started = [datetime]$latest.CreationTime
        $result = [string]$latest.Result
        $sessionState = [string]$latest.State
        $when = $started.ToString('yyyy-MM-dd HH:mm', $culture)
        switch ($result) {
            'Failed' { Add-Check 'LastResult' $name 'CRITICAL' "last session $when ended Failed" }
            'Warning' { Add-Check 'LastResult' $name 'WARNING' "last session $when ended with Warning" }
            'Success' { Add-Check 'LastResult' $name 'OK' "last session $when ended Success" }
            default {
                if ($sessionState -and $sessionState -ne 'Stopped') {
                    Add-Check 'LastResult' $name 'OK' "session started $when is $sessionState"
                } else {
                    Add-Check 'LastResult' $name 'WARNING' "last session $when has result '$result'"
                }
            }
        }

        $age = $Now - $started
        $allowed = (Get-RetentionExpectedGap -Job $job) + [timespan]::FromHours([double]$job.timeoutHours)
        if ($age -gt $allowed) {
            Add-Check 'Schedule' $name 'WARNING' ('overdue: last run {0:N1} hours ago, schedule allows {1:N1} hours' -f
                $age.TotalHours, $allowed.TotalHours)
        } else {
            Add-Check 'Schedule' $name 'OK' ('last run {0:N1} hours ago, schedule allows {1:N1} hours' -f
                $age.TotalHours, $allowed.TotalHours)
        }
    }

    # --- Retention audit ---------------------------------------------------
    try {
        foreach ($audit in @(Test-RetentionCompliance -Policy $Policy -Now $Now)) {
            if ($null -eq $audit) { continue }
            if ($audit.Compliant) {
                Add-Check 'Retention' ([string]$audit.JobName) 'OK' 'restore points within retention and schedule'
            } else {
                Add-Check 'Retention' ([string]$audit.JobName) 'WARNING' (@($audit.Issues) -join '; ')
            }
        }
    } catch {
        Add-Check 'Retention' '(all)' 'CRITICAL' "cannot audit retention: $($_.Exception.Message)"
    }

    $states = @($checks | ForEach-Object { $_.State })
    if ($states -contains 'CRITICAL') {
        $state = 'CRITICAL'
    } elseif ($states -contains 'WARNING') {
        $state = 'WARNING'
    } else {
        $state = 'OK'
    }

    $exitCodes = @{ OK = 0; WARNING = 1; CRITICAL = 2 }
    $levels = @{ OK = 'INFO'; WARNING = 'WARN'; CRITICAL = 'ERROR' }
    foreach ($check in $checks) {
        if ($check.State -ne 'OK') {
            Write-BackupLog -Level $levels[$check.State] -Message ('{0} {1}: {2}' -f $check.Type, $check.Name, $check.Message)
        }
    }
    Write-BackupLog -Level $levels[$state] -Message ("Backup server health $state ({0} checks)" -f $checks.Count)

    [pscustomobject]@{
        State    = $state
        ExitCode = $exitCodes[$state]
        Checks   = $checks.ToArray()
    }
}
