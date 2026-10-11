@{
    RootModule           = 'VeeamSim.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '0b7f4f6e-2d1a-4b8c-9e57-3c6a1f2d8e40'
    Description          = 'Simulates the Veeam Backup & Replication 9.5 cmdlets used by BackupDR over a JSON state file.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Get-VBRJob',
        'Start-VBRJob',
        'Get-VBRBackupSession',
        'Get-VBRBackup',
        'Get-VBRRestorePoint',
        'Get-VBRReplica',
        'Start-VBRViReplicaFailover',
        'Start-VBRViReplicaFailback',
        'Get-VBRBackupRepository'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
