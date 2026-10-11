@{
    RootModule           = 'BackupDR.psm1'
    ModuleVersion        = '1.1.0'
    GUID                 = '6f0f3c2e-8f4a-4f39-9a59-2d1c7b6a4e11'
    Description          = 'Policy-driven Veeam backup jobs, reporting and disaster-recovery plans.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'ConvertTo-BackupReportHtml',
        'Get-BackupJobReport',
        'Get-BackupPolicy',
        'Send-BackupAlert',
        'Set-BackupLogPath',
        'Start-BackupJob',
        'Test-BackupJobDue',
        'Test-RetentionCompliance'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
