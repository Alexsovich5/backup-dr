function Get-RetentionExpectedGap {
    # Longest time a job's schedule may leave between two restore points.
    param([Parameter(Mandatory = $true)][psobject]$Job)

    if ($Job.PSObject.Properties['intervalMinutes'] -and $null -ne $Job.intervalMinutes) {
        return [timespan]::FromMinutes([double]$Job.intervalMinutes)
    }

    $days = New-Object System.Collections.Generic.List[int]
    foreach ($entry in @($Job.schedule)) {
        if ($null -eq $entry) { continue }
        $value = [string]$entry
        if ([string]::Equals($value, 'Daily', [System.StringComparison]::OrdinalIgnoreCase)) {
            return [timespan]::FromDays(1)
        }
        $day = [System.DayOfWeek]0
        if ([System.Enum]::TryParse($value, $true, [ref]$day)) {
            if (-not $days.Contains([int]$day)) { $days.Add([int]$day) }
        }
    }

    if ($days.Count -le 1) {
        return [timespan]::FromDays(7)
    }

    $ordered = @($days | Sort-Object)
    $maxGap = 7 - $ordered[-1] + $ordered[0]
    for ($i = 1; $i -lt $ordered.Count; $i++) {
        $gap = $ordered[$i] - $ordered[$i - 1]
        if ($gap -gt $maxGap) { $maxGap = $gap }
    }
    return [timespan]::FromDays($maxGap)
}
