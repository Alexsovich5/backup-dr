$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

InModuleScope BackupDR {
    Describe 'Resolve-ExactVendorObject' -Tag 'Unit' {
        BeforeAll {
            Set-BackupLogPath -Path (Join-Path $TestDrive 'resolve.log')
        }

        function New-Named {
            param([string[]]$Name)
            foreach ($n in $Name) { [pscustomobject]@{ Name = $n } }
        }

        It 'returns the one object whose name equals the requested name, ignoring prefix matches' {
            $lookup = { param($n) New-Named 'prod-db-01_replica', 'prod-db-01_replica_old' }

            $found = Resolve-ExactVendorObject -Kind 'Veeam replica' -Name 'prod-db-01_replica' -Lookup $lookup

            $found.Name | Should -Be 'prod-db-01_replica'
        }

        It 'compares names case-insensitively' {
            $found = Resolve-ExactVendorObject -Kind 'Veeam job' -Name 'JOB-A' -Lookup { param($n) New-Named 'job-a' }
            $found.Name | Should -Be 'job-a'
        }

        It 'passes the exact name to the lookup' {
            $script:lookedUp = $null
            Resolve-ExactVendorObject -Kind 'Veeam job' -Name 'Job-A' -Lookup {
                param($n)
                $script:lookedUp = $n
                New-Named 'Job-A'
            } | Out-Null
            $script:lookedUp | Should -Be 'Job-A'
        }

        It 'rejects a name with wildcard character <Name> before running the lookup' -TestCases @(
            @{ Name = 'prod-db*' }, @{ Name = 'prod-db-0?' }, @{ Name = 'prod-db-0[1]' }
        ) {
            param($Name)
            $script:lookupRan = $false
            {
                Resolve-ExactVendorObject -Kind 'Veeam replica' -Name $Name -Lookup {
                    param($n)
                    $script:lookupRan = $true
                    New-Named $n
                }
            } | Should -Throw 'wildcard'
            $script:lookupRan | Should -Be $false
        }

        It 'throws when more than one object has exactly that name' {
            {
                Resolve-ExactVendorObject -Kind 'Veeam job' -Name 'Job-A' -Lookup { param($n) New-Named 'Job-A', 'job-a' }
            } | Should -Throw "Veeam job name 'Job-A' matches 2 objects"
        }

        It 'throws "not found" when nothing has exactly that name' {
            {
                Resolve-ExactVendorObject -Kind 'Veeam job' -Name 'Job-A' -Lookup { param($n) New-Named 'Job-AB' }
            } | Should -Throw "Veeam job 'Job-A' not found"
        }

        It 'returns nothing with -AllowMissing when nothing matches' {
            $found = Resolve-ExactVendorObject -Kind 'Veeam job' -Name 'Job-A' -AllowMissing -Lookup { param($n) }
            $null -eq $found | Should -Be $true
        }

        It 'still throws for an ambiguous name with -AllowMissing' {
            {
                Resolve-ExactVendorObject -Kind 'Veeam job' -Name 'Job-A' -AllowMissing -Lookup { param($n) New-Named 'Job-A', 'Job-A' }
            } | Should -Throw 'matches 2 objects'
        }

        It 'throws for an empty name' {
            { Resolve-ExactVendorObject -Kind 'Veeam job' -Name ' ' -Lookup { param($n) } } | Should -Throw 'name is empty'
        }
    }
}
