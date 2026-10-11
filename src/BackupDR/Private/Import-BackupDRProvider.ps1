function Import-BackupDRProvider {
    <#
    .SYNOPSIS
        Loads the commands behind the vendor cmdlet names used by BackupDR.
    .DESCRIPTION
        veeam      Add-PSSnapin VeeamPSSnapin (Windows with the Veeam console installed), then
                   Import-Module AzureRM.RecoveryServices, AzureRM.RecoveryServices.SiteRecovery
                   and DnsServer (RSAT DNS Server tools) globally.
        simulator  Import every simulator module under sim/ (sim/<Name>/<Name>.psd1) globally.
        none       Load nothing; unit tests provide stubs and mocks.
        The provider comes from -Provider, else $env:BACKUPDR_PROVIDER, else veeam on
        Windows and simulator elsewhere.
    #>
    [CmdletBinding()]
    param([string]$Provider)

    if (-not $Provider) { $Provider = $env:BACKUPDR_PROVIDER }
    if (-not $Provider) {
        if ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
            $Provider = 'veeam'
        } else {
            $Provider = 'simulator'
        }
    }

    switch ($Provider.ToLowerInvariant()) {
        'veeam' {
            try {
                Add-PSSnapin -Name VeeamPSSnapin -ErrorAction Stop
            } catch {
                throw 'Veeam PowerShell snap-in (VeeamPSSnapin) not found; install the Veeam console or set BACKUPDR_PROVIDER=simulator'
            }
            foreach ($moduleName in @('AzureRM.RecoveryServices', 'AzureRM.RecoveryServices.SiteRecovery', 'DnsServer')) {
                try {
                    Import-Module -Name $moduleName -Global -ErrorAction Stop
                } catch {
                    throw "PowerShell module '$moduleName' not found; install it on the Veeam server or set BACKUPDR_PROVIDER=simulator"
                }
            }
        }
        'simulator' {
            $simRoot = Join-Path $script:RepoRoot 'sim'
            foreach ($dir in @(Get-ChildItem -Path $simRoot -Directory | Sort-Object Name)) {
                $manifest = Join-Path $dir.FullName ($dir.Name + '.psd1')
                if (Test-Path -Path $manifest -PathType Leaf) {
                    Import-Module -Name $manifest -Global -Force
                }
            }
        }
        'none' { }
        default {
            throw "Unknown BACKUPDR_PROVIDER '$Provider'; use veeam, simulator or none"
        }
    }
}
