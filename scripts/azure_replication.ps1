<#
.SYNOPSIS
    Reports Azure Site Recovery replication health against the DR plan's RPO threshold.
.DESCRIPTION
    Loads the DR plan, runs Get-AzureReplicationStatus for its vault and recovery plan and
    prints a summary line followed by one line per protected item:

      AZURE REPLICATION <STATE> - <summary>
      <OK|WARNING|CRITICAL> <item> health=<ReplicationHealth> rpo=<minutes> min

    Exit code (Nagios convention): 0 OK, 1 WARNING, 2 CRITICAL. A plan that cannot be loaded
    is CRITICAL.

    The vendor commands come from BACKUPDR_PROVIDER (veeam, simulator or none).
.PARAMETER PlanPath
    DR plan file. Default: config/dr_plan.json under the repository.
.PARAMETER Now
    Time the RPO age is measured against. Default: the current time.
.EXAMPLE
    pwsh scripts/azure_replication.ps1
#>
[CmdletBinding()]
param(
    [string]$PlanPath,
    [datetime]$Now = (Get-Date)
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $PlanPath) { $PlanPath = Join-Path (Join-Path $repoRoot 'config') 'dr_plan.json' }

Import-Module (Join-Path (Join-Path $repoRoot 'src') 'BackupDR') -Force
Set-BackupLogPath -Path (Join-Path (Join-Path $repoRoot 'logs') 'azure_replication.log')

try {
    $plan = Get-DRPlan -Path $PlanPath
}
catch {
    Write-Output "AZURE REPLICATION CRITICAL - cannot load DR plan: $($_.Exception.Message)"
    exit 2
}

$status = Get-AzureReplicationStatus -Plan $plan -Now $Now
$culture = [System.Globalization.CultureInfo]::InvariantCulture

Write-Output ('AZURE REPLICATION {0} - {1}' -f $status.State, $status.Message)
foreach ($item in @($status.Items)) {
    if ($item.Ok) {
        $itemState = 'OK'
    } elseif ($item.Health -eq 'Critical') {
        $itemState = 'CRITICAL'
    } else {
        $itemState = 'WARNING'
    }
    if ($null -eq $item.RpoMinutes) {
        $rpoText = 'unknown'
    } else {
        $rpoText = ([double]$item.RpoMinutes).ToString('0.0', $culture) + ' min'
    }
    Write-Output ('{0,-8} {1} health={2} rpo={3}' -f $itemState, $item.Name, $item.Health, $rpoText)
}

exit $status.ExitCode
