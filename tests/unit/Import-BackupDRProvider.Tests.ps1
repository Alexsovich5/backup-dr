$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'Import-BackupDRProvider' -Tag 'Unit' {
    AfterAll {
        Remove-Module VeeamSim, AzureSim, DnsSim -Force -ErrorAction SilentlyContinue
        # The simulators shadowed the global stubs while it was loaded; restore them.
        . (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
        $env:BACKUPDR_PROVIDER = 'none'
    }

    It 'throws on an unknown provider' {
        InModuleScope BackupDR {
            { Import-BackupDRProvider -Provider 'hyperv' } | Should -Throw "Unknown BACKUPDR_PROVIDER 'hyperv'"
        }
    }

    It 'reads the provider from BACKUPDR_PROVIDER when -Provider is omitted' {
        $env:BACKUPDR_PROVIDER = 'bogus'
        try {
            InModuleScope BackupDR {
                { Import-BackupDRProvider } | Should -Throw "Unknown BACKUPDR_PROVIDER 'bogus'"
            }
        } finally {
            $env:BACKUPDR_PROVIDER = 'none'
        }
    }

    Context 'none' {
        It 'loads nothing for none' {
            Mock -ModuleName BackupDR Import-Module {}
            Mock -ModuleName BackupDR Add-PSSnapin {}
            InModuleScope BackupDR { Import-BackupDRProvider -Provider 'none' }
            Assert-MockCalled -ModuleName BackupDR Import-Module -Times 0 -Exactly
            Assert-MockCalled -ModuleName BackupDR Add-PSSnapin -Times 0 -Exactly
        }
    }

    Context 'simulator' {
        It 'makes the VeeamSim Get-VBRJob available for simulator' {
            Mock -ModuleName BackupDR Add-PSSnapin {}
            Remove-Module VeeamSim -Force -ErrorAction SilentlyContinue
            InModuleScope BackupDR {
                Import-BackupDRProvider -Provider 'simulator'
                (Get-Command Get-VBRJob).ModuleName | Should -Be 'VeeamSim'
            }
            Get-Module VeeamSim | Should -Not -BeNullOrEmpty
            Assert-MockCalled -ModuleName BackupDR Add-PSSnapin -Times 0 -Exactly
        }

        It 'makes the AzureSim and DnsSim commands available for simulator' {
            Mock -ModuleName BackupDR Add-PSSnapin {}
            Remove-Module AzureSim, DnsSim -Force -ErrorAction SilentlyContinue
            InModuleScope BackupDR {
                Import-BackupDRProvider -Provider 'simulator'
                (Get-Command Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob).ModuleName | Should -Be 'AzureSim'
                (Get-Command Get-AzureRmRecoveryServicesAsrReplicationProtectedItem).ModuleName | Should -Be 'AzureSim'
                (Get-Command Get-DnsServerZone).ModuleName | Should -Be 'DnsSim'
                (Get-Command Add-DnsServerResourceRecordA).ModuleName | Should -Be 'DnsSim'
            }
        }
    }

    Context 'veeam' {
        It 'adds the VeeamPSSnapin snap-in for veeam' {
            Mock -ModuleName BackupDR Add-PSSnapin {}
            Mock -ModuleName BackupDR Import-Module {} -ParameterFilter { $Name -like 'AzureRM*' -or $Name -eq 'DnsServer' }
            InModuleScope BackupDR { Import-BackupDRProvider -Provider 'veeam' }
            Assert-MockCalled -ModuleName BackupDR Add-PSSnapin -Times 1 -Exactly -ParameterFilter { $Name -eq 'VeeamPSSnapin' }
        }

        It 'imports the AzureRM Site Recovery and DnsServer modules for veeam' {
            Mock -ModuleName BackupDR Add-PSSnapin {}
            Mock -ModuleName BackupDR Import-Module {} -ParameterFilter { $Name -like 'AzureRM*' -or $Name -eq 'DnsServer' }
            InModuleScope BackupDR { Import-BackupDRProvider -Provider 'veeam' }
            Assert-MockCalled -ModuleName BackupDR Import-Module -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'AzureRM.RecoveryServices' }
            Assert-MockCalled -ModuleName BackupDR Import-Module -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'AzureRM.RecoveryServices.SiteRecovery' }
            Assert-MockCalled -ModuleName BackupDR Import-Module -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'DnsServer' }
        }

        It 'names the module that cannot be imported for veeam' {
            Mock -ModuleName BackupDR Add-PSSnapin {}
            Mock -ModuleName BackupDR Import-Module {} -ParameterFilter { $Name -like 'AzureRM*' }
            Mock -ModuleName BackupDR Import-Module { throw "The specified module 'DnsServer' was not loaded." } -ParameterFilter { $Name -eq 'DnsServer' }
            InModuleScope BackupDR {
                { Import-BackupDRProvider -Provider 'veeam' } | Should -Throw "PowerShell module 'DnsServer' not found"
            }
        }

        It 'names the snap-in when it cannot be loaded' {
            Mock -ModuleName BackupDR Add-PSSnapin { throw 'The Windows PowerShell snap-in is not installed on this computer.' }
            InModuleScope BackupDR {
                { Import-BackupDRProvider -Provider 'veeam' } |
                    Should -Throw 'Veeam PowerShell snap-in (VeeamPSSnapin) not found; install the Veeam console or set BACKUPDR_PROVIDER=simulator'
            }
        }
    }
}
