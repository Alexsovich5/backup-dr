function Get-AzureReplicationStatus {
    <#
    .SYNOPSIS
        Grades Azure Site Recovery protected items against the DR plan's RPO threshold.
    .DESCRIPTION
        Sets the ASR vault context to the plan's azure.vaultName and lists the replication
        protected items of azure.recoveryPlan (every item in the vault when the plan names no
        recovery plan).

        Each item's RPO is the RpoInSeconds that ASR reported (read from ProviderSpecificDetails,
        else from the item itself) plus the time between LastRpoCalculatedTime and -Now, so a
        value that has stopped being refreshed keeps growing. An item is Ok when its
        ReplicationHealth is Normal and its RPO is at most rpoThresholdMinutes.

        State, worst first:
          CRITICAL (2)  an item's ReplicationHealth is Critical, the vault has no protected
                        items, or the vault / items cannot be read
          WARNING  (1)  an item's health is not Normal, its RPO is over the threshold, or ASR
                        reported no RPO for it
          OK       (0)  otherwise
    .EXAMPLE
        Get-AzureReplicationStatus -Plan (Get-DRPlan -Path config/dr_plan.json)
    .OUTPUTS
        State, ExitCode, Message and Items (Name, Health, RpoMinutes, Ok). RpoMinutes is rounded
        to one decimal, or $null when no RPO was reported.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Plan,

        [datetime]$Now = (Get-Date)
    )

    $threshold = [double]$Plan.rpoThresholdMinutes
    $vaultName = $null
    $planName = $null
    if ($Plan.PSObject.Properties.Name -contains 'azure' -and $null -ne $Plan.azure) {
        $vaultName = [string]$Plan.azure.vaultName
        $planName = [string]$Plan.azure.recoveryPlan
    }

    $protected = @()
    try {
        if ([string]::IsNullOrWhiteSpace($vaultName)) {
            throw 'the DR plan has no azure.vaultName'
        }
        $vault = Resolve-ExactVendorObject -Kind 'Recovery Services vault' -Name $vaultName -Lookup {
            param($n)
            Get-AzureRmRecoveryServicesVault -Name $n
        }
        Set-AzureRmRecoveryServicesAsrVaultContext -Vault $vault | Out-Null

        if ([string]::IsNullOrWhiteSpace($planName)) {
            $protected = @(Get-AzureRmRecoveryServicesAsrReplicationProtectedItem)
        } else {
            $recoveryPlan = Resolve-ExactVendorObject -Kind 'ASR recovery plan' -Name $planName -Lookup {
                param($n)
                Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name $n
            }
            $protected = @(Get-AzureRmRecoveryServicesAsrReplicationProtectedItem -RecoveryPlan $recoveryPlan)
        }
        $protected = @($protected | Where-Object { $null -ne $_ })
    } catch {
        $message = "Cannot read Azure Site Recovery protected items: $($_.Exception.Message)"
        Write-BackupLog -Level 'ERROR' -Message $message
        return [pscustomobject]@{ State = 'CRITICAL'; ExitCode = 2; Message = $message; Items = @() }
    }

    $items = @(
        foreach ($entry in $protected) {
            $name = [string]$entry.FriendlyName
            if (-not $name) { $name = [string]$entry.Name }
            $health = [string]$entry.ReplicationHealth

            $source = $entry
            $details = $entry.PSObject.Properties['ProviderSpecificDetails']
            if ($details -and $null -ne $details.Value -and $null -ne $details.Value.PSObject.Properties['RpoInSeconds'] -and
                $null -ne $details.Value.RpoInSeconds) {
                $source = $details.Value
            }

            $rpoMinutes = $null
            if ($null -ne $source.PSObject.Properties['RpoInSeconds'] -and $null -ne $source.RpoInSeconds) {
                $seconds = [double]$source.RpoInSeconds
                if ($null -ne $source.PSObject.Properties['LastRpoCalculatedTime'] -and $null -ne $source.LastRpoCalculatedTime) {
                    $sinceCalculated = ($Now - [datetime]$source.LastRpoCalculatedTime).TotalSeconds
                    if ($sinceCalculated -gt 0) { $seconds += $sinceCalculated }
                }
                $rpoMinutes = [math]::Round($seconds / 60, 1)
            }

            $ok = ($health -eq 'Normal') -and ($null -ne $rpoMinutes) -and ($rpoMinutes -le $threshold)
            [pscustomobject]@{
                Name       = $name
                Health     = $health
                RpoMinutes = $rpoMinutes
                Ok         = $ok
            }
        }
    )

    $critical = @($items | Where-Object { $_.Health -eq 'Critical' })
    $notOk = @($items | Where-Object { -not $_.Ok })
    if ($items.Count -eq 0) {
        $state = 'CRITICAL'
        $message = "no protected items in vault '$vaultName'"
        if ($planName) { $message += " for recovery plan '$planName'" }
    } elseif ($critical.Count -gt 0) {
        $state = 'CRITICAL'
        $message = '{0} of {1} item(s) with critical replication health: {2}' -f
            $critical.Count, $items.Count, (@($critical | ForEach-Object { $_.Name }) -join ', ')
    } elseif ($notOk.Count -gt 0) {
        $state = 'WARNING'
        $message = '{0} of {1} item(s) unhealthy or over the {2} minute RPO threshold: {3}' -f
            $notOk.Count, $items.Count, $threshold, (@($notOk | ForEach-Object { $_.Name }) -join ', ')
    } else {
        $state = 'OK'
        $message = '{0} item(s) healthy within the {1} minute RPO threshold' -f $items.Count, $threshold
    }

    $exitCodes = @{ OK = 0; WARNING = 1; CRITICAL = 2 }
    $levels = @{ OK = 'INFO'; WARNING = 'WARN'; CRITICAL = 'ERROR' }
    Write-BackupLog -Level $levels[$state] -Message "Azure replication $state - $message"

    [pscustomobject]@{
        State    = $state
        ExitCode = $exitCodes[$state]
        Message  = $message
        Items    = $items
    }
}
