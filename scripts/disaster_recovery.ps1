<#
.SYNOPSIS
    Runs the DR plan: failover, failback or a pre-flight test.
.DESCRIPTION
    Loads and validates the DR plan and the backup policy (whose alerting block is used by
    notification steps), then runs Invoke-DRPlan and writes the run log as JSON.

      failover  runs the plan's steps in order and stops at the first failed step
      failback  runs the reversible steps in reverse order, then the notifications
      test      runs every step's pre-flight check and changes nothing

    failover and failback ask for confirmation first; -Force skips the prompt. A session
    that cannot prompt (pwsh -NonInteractive) without -Force is refused.

    Exit code: 0 when the plan succeeded, 1 when a step failed, the plan or policy cannot be
    loaded, or the action was not confirmed.

    The vendor commands come from BACKUPDR_PROVIDER (veeam, simulator or none).
.PARAMETER Action
    failover, failback or test.
.PARAMETER PlanPath
    DR plan file. Default: config/dr_plan.json under the repository.
.PARAMETER ConfigPath
    Backup policy file providing the alerting settings. Default: config/backup_policy.json.
.PARAMETER RunLogPath
    Where the JSON run log is written. Default: out/dr-run.json under the repository.
.PARAMETER Now
    Time recorded in the run log. Default: the current time.
.PARAMETER Force
    Run failover or failback without asking for confirmation.
.EXAMPLE
    pwsh scripts/disaster_recovery.ps1 -Action test
.EXAMPLE
    pwsh scripts/disaster_recovery.ps1 -Action failover -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('failover', 'failback', 'test')]
    [string]$Action,
    [string]$PlanPath,
    [string]$ConfigPath,
    [string]$RunLogPath,
    [datetime]$Now = (Get-Date),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
if (-not $PlanPath) { $PlanPath = Join-Path (Join-Path $repoRoot 'config') 'dr_plan.json' }
if (-not $ConfigPath) { $ConfigPath = Join-Path (Join-Path $repoRoot 'config') 'backup_policy.json' }
if (-not $RunLogPath) { $RunLogPath = Join-Path (Join-Path $repoRoot 'out') 'dr-run.json' }

Import-Module (Join-Path (Join-Path $repoRoot 'src') 'BackupDR') -Force
Set-BackupLogPath -Path (Join-Path (Join-Path $repoRoot 'logs') 'disaster_recovery.log')

function Write-DRLog {
    # Writes through the module's private Write-BackupLog so lines share its format and log file.
    param([string]$Message, [string]$Level = 'INFO')
    & (Get-Module -Name BackupDR) { param($m, $l) Write-BackupLog -Message $m -Level $l } $Message $Level
}

try {
    $plan = Get-DRPlan -Path $PlanPath
    $policy = Get-BackupPolicy -Path $ConfigPath
}
catch {
    Write-DRLog -Level 'ERROR' -Message $_.Exception.Message
    exit 1
}

if ($Action -ne 'test' -and -not $Force) {
    $question = "Run DR $Action of plan '$($plan.name)'? This changes replicas, Azure Site Recovery and DNS."
    $confirmed = $false
    try {
        $confirmed = $PSCmdlet.ShouldContinue($question, "Confirm DR $Action")
    }
    catch {
        Write-DRLog -Level 'ERROR' -Message "Cannot ask for confirmation ($($_.Exception.Message)); use -Force for unattended runs"
        exit 1
    }
    if (-not $confirmed) {
        Write-DRLog -Level 'WARN' -Message "DR $Action not confirmed; nothing was changed"
        exit 1
    }
}

$run = Invoke-DRPlan -Plan $plan -Action $Action -Alerting $policy.alerting -RunLogPath $RunLogPath -Now $Now

foreach ($step in @($run.Steps)) {
    Write-Output ('{0,-10} {1} ({2}) {3}' -f $step.Status, $step.Name, $step.Type, $step.Message)
}

if ($run.Success) {
    exit 0
}
exit 1
