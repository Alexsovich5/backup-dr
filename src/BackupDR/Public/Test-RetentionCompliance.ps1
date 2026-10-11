function Test-RetentionCompliance {
    <#
    .SYNOPSIS
        Audits each policy job's restore points against its retentionDays and schedule.
    .DESCRIPTION
        For every job in the policy, looks up the job's backup with Get-VBRBackup -Name and its
        restore points with Get-VBRRestorePoint -Backup. All ages are measured from -Now.

        A restore point older than retentionDays is counted in ExpiredPoints (Veeam should have
        removed it). The job also needs a restore point newer than its expected gap plus a grace
        of timeoutHours, where the expected gap is:
          - intervalMinutes, when the job sets it;
          - one day, when the schedule contains 'Daily';
          - otherwise the longest gap in days between consecutive scheduled weekdays
            (7 for a job that runs on one weekday).

        The backup is matched by the exact job name (see Resolve-ExactVendorObject): a job without
        a backup of exactly that name is reported with the issue 'no backup found', and a name
        that several backups share throws instead of auditing one of them. Any issue makes the
        job non-compliant. Nothing is deleted; this only reports drift.
    .EXAMPLE
        Test-RetentionCompliance -Policy (Get-BackupPolicy -Path config/backup_policy.json)
    .OUTPUTS
        One object per job: JobName, OldestPointAge, ExpiredPoints, NewestPointAge, Compliant,
        Issues. The ages are TimeSpan values, or $null when the job has no restore point.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Policy,

        [datetime]$Now = (Get-Date)
    )

    foreach ($job in @($Policy.jobs)) {
        if ($null -eq $job) { continue }
        $name = [string]$job.name
        $retentionDays = [double]$job.retentionDays
        $issues = New-Object System.Collections.Generic.List[string]
        $oldestAge = $null
        $newestAge = $null
        $expired = 0

        $backup = Resolve-ExactVendorObject -Kind 'Veeam backup' -Name $name -AllowMissing -Lookup {
            param($n)
            Get-VBRBackup -Name $n
        }
        if ($null -eq $backup) {
            $issues.Add("no backup found for job '$name'")
        } else {
            $ages = @(
                @(Get-VBRRestorePoint -Backup $backup) |
                    Where-Object { $null -ne $_ -and $null -ne $_.CreationTime } |
                    ForEach-Object { $Now - [datetime]$_.CreationTime }
            )

            if ($ages.Count -gt 0) {
                $sorted = @($ages | Sort-Object)
                $newestAge = $sorted[0]
                $oldestAge = $sorted[-1]
                $expired = @($ages | Where-Object { $_.TotalDays -gt $retentionDays }).Count
                if ($expired -gt 0) {
                    $issues.Add(("{0} restore point(s) older than retention of {1} days (oldest {2:N1} days)" -f
                        $expired, $retentionDays, $oldestAge.TotalDays))
                }
            }

            $allowed = (Get-RetentionExpectedGap -Job $job) + [timespan]::FromHours([double]$job.timeoutHours)
            if ($null -eq $newestAge) {
                $issues.Add('no recent restore point: the backup has no restore points')
            } elseif ($newestAge -gt $allowed) {
                $issues.Add(("no recent restore point: newest is {0:N1} hours old, schedule allows {1:N1} hours" -f
                    $newestAge.TotalHours, $allowed.TotalHours))
            }
        }

        $compliant = ($issues.Count -eq 0)
        if (-not $compliant) {
            Write-BackupLog -Level 'WARN' -Message ("Retention audit for {0}: {1}" -f $name, ($issues -join '; '))
        }

        [pscustomobject]@{
            JobName        = $name
            OldestPointAge = $oldestAge
            ExpiredPoints  = $expired
            NewestPointAge = $newestAge
            Compliant      = $compliant
            Issues         = $issues.ToArray()
        }
    }
}
