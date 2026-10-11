function Invoke-AzureFailoverStep {
    <#
    .SYNOPSIS
        Runs an azure_failover DR step against an Azure Site Recovery recovery plan.
    .DESCRIPTION
        Sets the ASR vault context from -VaultName, looks up the step's recoveryPlan (both by
        exact name, exactly one match; see Resolve-ExactVendorObject) and then:
          failover  Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -Direction PrimaryToRecovery
          failback  Start-AzureRmRecoveryServicesAsrPlannedFailoverJob -Direction RecoveryToPrimary
          test      only the vault and recovery plan lookups
        VMware machines replicated to Azure can only be failed over with an unplanned
        failover; planned failover is used for failback.
        A job that is still NotStarted/InProgress is polled with Get-AzureRmRecoveryServicesAsrJob
        every -PollSeconds (default $env:BACKUPDR_POLL_SECONDS, else 30) for at most
        -TimeoutMinutes. A job ending in any state other than Succeeded throws.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Step,

        [Parameter(Mandatory = $true)]
        [ValidateSet('failover', 'failback', 'test')]
        [string]$Action,

        [AllowEmptyString()]
        [string]$VaultName,

        [int]$PollSeconds,

        [int]$TimeoutMinutes = 60
    )

    if (-not $PSBoundParameters.ContainsKey('PollSeconds')) {
        $PollSeconds = 30
        $fromEnv = 0
        if ($env:BACKUPDR_POLL_SECONDS -and [int]::TryParse($env:BACKUPDR_POLL_SECONDS, [ref]$fromEnv) -and $fromEnv -ge 0) {
            $PollSeconds = $fromEnv
        }
    }

    if ([string]::IsNullOrWhiteSpace($VaultName)) {
        throw "Azure failover step '$($Step.name)' has no vault: set azure.vaultName in the DR plan"
    }

    $vault = Resolve-ExactVendorObject -Kind 'Recovery Services vault' -Name $VaultName -Lookup {
        param($n)
        Get-AzureRmRecoveryServicesVault -Name $n
    }
    Set-AzureRmRecoveryServicesAsrVaultContext -Vault $vault | Out-Null

    $planName = [string]$Step.recoveryPlan
    $recoveryPlan = Resolve-ExactVendorObject -Kind 'ASR recovery plan' -Name $planName -Lookup {
        param($n)
        try {
            Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name $n
        } catch {
            throw "ASR recovery plan '$n' not found in vault '$VaultName': $($_.Exception.Message)"
        }
    }

    if ($Action -eq 'test') {
        return "ASR recovery plan '$planName' found in vault '$VaultName' (current site $($recoveryPlan.CurrentSite))"
    }

    if ($Action -eq 'failover') {
        $direction = 'PrimaryToRecovery'
        $job = Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -RecoveryPlan $recoveryPlan -Direction $direction
    } else {
        $direction = 'RecoveryToPrimary'
        $job = Start-AzureRmRecoveryServicesAsrPlannedFailoverJob -RecoveryPlan $recoveryPlan -Direction $direction
    }

    $runningStates = @('NotStarted', 'InProgress')
    $maxPolls = [int][math]::Ceiling($TimeoutMinutes * 60 / [math]::Max($PollSeconds, 1))
    $polls = 0
    while ($runningStates -contains [string]$job.State -and $polls -lt $maxPolls) {
        Start-Sleep -Seconds $PollSeconds
        $job = Get-AzureRmRecoveryServicesAsrJob -Name ([string]$job.Name)
        $polls++
    }

    $state = [string]$job.State
    if ($state -ne 'Succeeded') {
        throw "ASR $direction job '$($job.Name)' for recovery plan '$planName' ended in state '$state'"
    }
    "ASR $direction job '$($job.Name)' for recovery plan '$planName' Succeeded"
}
