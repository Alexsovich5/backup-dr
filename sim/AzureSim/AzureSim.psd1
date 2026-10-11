@{
    RootModule           = 'AzureSim.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '6a2d9c41-7e3b-4f58-a1c2-8d4e5f6a7b90'
    Description          = 'Simulates the AzureRM Recovery Services and Site Recovery cmdlets used by BackupDR over a JSON state file.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Get-AzureRmRecoveryServicesVault',
        'Set-AzureRmRecoveryServicesAsrVaultContext',
        'Get-AzureRmRecoveryServicesAsrRecoveryPlan',
        'Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob',
        'Start-AzureRmRecoveryServicesAsrPlannedFailoverJob',
        'Get-AzureRmRecoveryServicesAsrJob',
        'Get-AzureRmRecoveryServicesAsrReplicationProtectedItem'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
