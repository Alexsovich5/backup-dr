function Invoke-DRPlan {
    <#
    .SYNOPSIS
        Executes a DR plan from Get-DRPlan: failover, failback or a pre-flight test.
    .DESCRIPTION
        failover  runs failoverSteps in plan order.
        failback  runs the reversible steps (veeam_replica, azure_failover, dns_update) in
                  reverse order, then the notification steps in plan order.
        test      runs every step's pre-flight check in plan order (replica exists, recovery
                  plan exists, DNS zone exists, alerting configured) and changes nothing.
                  All checks run even after a failure so every problem is reported.

        For failover and failback, the first failed step stops the run and the remaining
        steps are reported as NotRun, unless the failed step has continueOnError: true.
        Success is $false when any step without continueOnError failed.
        Each step result is {Name, Type, Status (Succeeded/Failed/NotRun), Message, Started,
        Finished}. With -RunLogPath the whole run is also written there as JSON.
    .EXAMPLE
        $plan = Get-DRPlan -Path .\config\dr_plan.json
        Invoke-DRPlan -Plan $plan -Action test -Alerting $policy.alerting -RunLogPath .\out\dr-run.json
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Plan,

        [Parameter(Mandatory = $true)]
        [ValidateSet('failover', 'failback', 'test')]
        [string]$Action,

        [psobject]$Alerting,

        [string]$RunLogPath,

        [datetime]$Now = (Get-Date)
    )

    $timeFormat = 'yyyy-MM-ddTHH:mm:ss'
    $culture = [System.Globalization.CultureInfo]::InvariantCulture
    $reversibleTypes = @('veeam_replica', 'azure_failover', 'dns_update')

    $planSteps = @($Plan.failoverSteps | Where-Object { $null -ne $_ })
    if ($Action -eq 'failback') {
        $reversible = @($planSteps | Where-Object { $reversibleTypes -contains [string]$_.type })
        [array]::Reverse($reversible)
        $notifications = @($planSteps | Where-Object { $reversibleTypes -notcontains [string]$_.type })
        $orderedSteps = @($reversible) + @($notifications)
    } else {
        $orderedSteps = $planSteps
    }

    $vaultName = ''
    if ($null -ne $Plan.azure) {
        $vaultName = [string]$Plan.azure.vaultName
    }

    Write-BackupLog -Message "DR $Action of plan '$($Plan.name)' started ($($orderedSteps.Count) steps)"

    $results = New-Object System.Collections.Generic.List[object]
    $stopped = $false
    $success = $true

    foreach ($step in $orderedSteps) {
        $result = [pscustomobject]@{
            Name     = [string]$step.name
            Type     = [string]$step.type
            Status   = 'NotRun'
            Message  = ''
            Started  = $null
            Finished = $null
        }

        if ($stopped) {
            $results.Add($result)
            continue
        }

        $result.Started = (Get-Date).ToString($timeFormat, $culture)
        try {
            switch ([string]$step.type) {
                'veeam_replica' {
                    $message = Invoke-VeeamReplicaStep -Step $step -Action $Action
                }
                'azure_failover' {
                    $message = Invoke-AzureFailoverStep -Step $step -Action $Action -VaultName $vaultName
                }
                'dns_update' {
                    $message = Invoke-DnsUpdateStep -Step $step -Action $Action
                }
                'notification' {
                    $message = Invoke-NotificationStep -Step $step -Action $Action -Alerting $Alerting `
                        -PlanName ([string]$Plan.name) -Results $results.ToArray()
                }
                default {
                    throw "Unknown step type '$($step.type)'"
                }
            }
            $result.Status = 'Succeeded'
            $result.Message = (@($message) | ForEach-Object { [string]$_ }) -join '; '
            Write-BackupLog -Message "Step '$($result.Name)' ($Action): $($result.Message)"
        } catch {
            $result.Status = 'Failed'
            $result.Message = $_.Exception.Message
            $continue = ($step.continueOnError -eq $true)
            if ($continue) {
                Write-BackupLog -Level 'WARN' -Message "Step '$($result.Name)' ($Action) failed, continuing: $($result.Message)"
            } else {
                Write-BackupLog -Level 'ERROR' -Message "Step '$($result.Name)' ($Action) failed: $($result.Message)"
                $success = $false
                if ($Action -ne 'test') {
                    $stopped = $true
                }
            }
        }
        $result.Finished = (Get-Date).ToString($timeFormat, $culture)
        $results.Add($result)
    }

    $run = [pscustomobject]@{
        Action  = $Action
        Success = $success
        Steps   = $results.ToArray()
    }

    if ($RunLogPath) {
        $directory = Split-Path -Parent $RunLogPath
        if ($directory -and -not (Test-Path -Path $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $log = [pscustomobject]@{
            Plan    = [string]$Plan.name
            Action  = $Action
            Now     = $Now.ToString($timeFormat, $culture)
            Success = $success
            Steps   = $results.ToArray()
        }
        $log | ConvertTo-Json -Depth 5 | Set-Content -Path $RunLogPath -Encoding UTF8
        Write-BackupLog -Message "DR run log written to $RunLogPath"
    }

    if ($success) { $level = 'INFO' } else { $level = 'ERROR' }
    Write-BackupLog -Level $level -Message "DR $Action of plan '$($Plan.name)' finished: Success=$success"
    $run
}
