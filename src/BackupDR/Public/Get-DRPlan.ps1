function Get-DRPlan {
    <#
    .SYNOPSIS
        Loads dr_plan.json and validates it.
    .DESCRIPTION
        The plan must have rpoThresholdMinutes greater than 0 and at least one
        failover step. Every step needs a unique, non-empty name and a type of
        veeam_replica, azure_failover, dns_update or notification, plus the
        fields that type requires:
          veeam_replica   target
          azure_failover  recoveryPlan
          dns_update      zone, record, failoverIp, primaryIp
          notification    to
        All problems are collected and reported in a single error.
    .EXAMPLE
        $plan = Get-DRPlan -Path .\config\dr_plan.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path -PathType Leaf)) {
        throw "DR plan not found: $Path"
    }

    try {
        $plan = Get-Content -Path $Path -Raw | ConvertFrom-Json
    } catch {
        throw "DR plan $Path is not valid JSON: $($_.Exception.Message)"
    }

    $requiredFields = [ordered]@{
        veeam_replica  = @('target')
        azure_failover = @('recoveryPlan')
        dns_update     = @('zone', 'record', 'failoverIp', 'primaryIp')
        notification   = @('to')
    }
    $stepTypes = @($requiredFields.Keys)

    $problems = New-Object System.Collections.Generic.List[string]

    if ($null -eq $plan) {
        throw "DR plan $Path is empty"
    }

    if (-not (Test-PolicyNumber -Value $plan.rpoThresholdMinutes -Minimum 0 -Exclusive)) {
        $problems.Add('rpoThresholdMinutes must be greater than 0')
    }

    $steps = @($plan.failoverSteps | Where-Object { $null -ne $_ })
    if ($steps.Count -eq 0) {
        $problems.Add('failoverSteps: at least one step is required')
    }

    $seenNames = @{}
    $index = 0
    foreach ($step in $steps) {
        $name = [string]$step.name
        if ([string]::IsNullOrWhiteSpace($name)) {
            $problems.Add("failoverSteps[$index]: name is required")
            $label = "failoverSteps[$index]"
        } else {
            $label = "step '$name'"
            if ($seenNames.ContainsKey($name)) {
                if ($seenNames[$name] -eq 1) {
                    $problems.Add("duplicate step name '$name'")
                }
                $seenNames[$name]++
            } else {
                $seenNames[$name] = 1
            }
        }

        $type = [string]$step.type
        if ($stepTypes -cnotcontains $type) {
            $problems.Add("${label}: type '$type' is not one of $($stepTypes -join ', ')")
        } else {
            foreach ($field in $requiredFields[$type]) {
                if ([string]::IsNullOrWhiteSpace([string]$step.$field)) {
                    $problems.Add("${label}: $type requires '$field'")
                }
            }
        }
        $index++
    }

    if ($problems.Count -gt 0) {
        $message = "DR plan $Path has $($problems.Count) problem(s):`n  - " + ($problems -join "`n  - ")
        throw $message
    }

    Write-BackupLog -Message "Loaded DR plan '$($plan.name)' from $Path ($($steps.Count) steps)"
    $plan
}
