@{
    RootModule           = 'DnsSim.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = 'd3e1b7a5-4c29-4e8f-b6a0-2f9c8e7d1a53'
    Description          = 'Simulates the Windows DnsServer cmdlets used by BackupDR over a JSON state file.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Get-DnsServerZone',
        'Get-DnsServerResourceRecord',
        'Add-DnsServerResourceRecordA',
        'Remove-DnsServerResourceRecord'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
}
