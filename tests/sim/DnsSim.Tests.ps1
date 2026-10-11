. (Join-Path $PSScriptRoot '../TestHelpers/New-SimState.ps1')
Import-Module (Join-Path $PSScriptRoot '../../sim/DnsSim') -Force

Describe 'DnsSim' -Tag 'Unit' {
    $anchor = [datetime]'2019-02-17T02:00:00'

    BeforeAll {
        $script:savedState = $env:BACKUPDR_SIM_STATE
    }

    AfterAll {
        $env:BACKUPDR_SIM_STATE = $script:savedState
        Remove-Module DnsSim -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:stateDir = New-SimState -Anchor $anchor
        $script:stateFile = Join-Path $script:stateDir 'dns.json'
    }

    function Get-SeededRecord {
        param([string]$Name)
        $zone = @((Get-Content -Path $script:stateFile -Raw | ConvertFrom-Json).zones |
            Where-Object { $_.name -eq 'example.local' })[0]
        @($zone.records | Where-Object { $_.hostName -eq $Name })
    }

    Context 'zones' {
        It 'New-SimState writes dns.json' {
            Test-Path $script:stateFile | Should -Be $true
        }

        It 'Get-DnsServerZone -Name example.local returns the zone' {
            $zone = Get-DnsServerZone -Name 'example.local'
            $zone.ZoneName | Should -Be 'example.local'
            $zone.ZoneType | Should -Be 'Primary'
        }

        It 'Get-DnsServerZone throws for a zone that does not exist' {
            { Get-DnsServerZone -Name 'missing.local' } | Should -Throw 'Failed to get the zone information for missing.local'
        }
    }

    Context 'A records' {
        It 'Get-DnsServerResourceRecord returns the seeded app record' {
            $record = Get-DnsServerResourceRecord -ZoneName 'example.local' -Name 'app'
            $record.HostName | Should -Be 'app'
            $record.RecordType | Should -Be 'A'
            $record.RecordData.IPv4Address.ToString() | Should -Be '10.10.0.10'
        }

        It 'Get-DnsServerResourceRecord throws for a name with no records' {
            { Get-DnsServerResourceRecord -ZoneName 'example.local' -Name 'nothing' } | Should -Throw 'Failed to get nothing record'
        }

        It 'Get-DnsServerResourceRecord reports a name with no records as ObjectNotFound' {
            $category = $null
            try {
                Get-DnsServerResourceRecord -ZoneName 'example.local' -Name 'nothing' -ErrorAction Stop
            } catch {
                $category = $_.CategoryInfo.Category
            }
            $category | Should -Be ([System.Management.Automation.ErrorCategory]::ObjectNotFound)
        }

        It 'remove then add swaps the IP and the change is persisted to JSON' {
            Remove-DnsServerResourceRecord -ZoneName 'example.local' -Name 'app' -RRType A -Force
            @(Get-SeededRecord -Name 'app').Count | Should -Be 0

            Add-DnsServerResourceRecordA -ZoneName 'example.local' -Name 'app' -IPv4Address '10.20.0.10'

            $persisted = @(Get-SeededRecord -Name 'app')
            $persisted.Count | Should -Be 1
            $persisted[0].ipv4Address | Should -Be '10.20.0.10'
            (Get-DnsServerResourceRecord -ZoneName 'example.local' -Name 'app').RecordData.IPv4Address.ToString() |
                Should -Be '10.20.0.10'
        }

        It 'adding a second address for the same name keeps both records' {
            Add-DnsServerResourceRecordA -ZoneName 'example.local' -Name 'app' -IPv4Address '10.20.0.10'
            $addresses = @(Get-DnsServerResourceRecord -ZoneName 'example.local' -Name 'app' -RRType A |
                ForEach-Object { $_.RecordData.IPv4Address.ToString() })
            $addresses.Count | Should -Be 2
            $addresses | Should -Contain '10.10.0.10'
            $addresses | Should -Contain '10.20.0.10'
        }

        It 'adding a record that already exists throws' {
            { Add-DnsServerResourceRecordA -ZoneName 'example.local' -Name 'app' -IPv4Address '10.10.0.10' } |
                Should -Throw 'already exists'
        }

        It 'adding to a zone that does not exist throws' {
            { Add-DnsServerResourceRecordA -ZoneName 'missing.local' -Name 'app' -IPv4Address '10.20.0.10' } |
                Should -Throw 'missing.local'
        }

        It 'removing a record that does not exist throws like the real cmdlet' {
            { Remove-DnsServerResourceRecord -ZoneName 'example.local' -Name 'nothing' -RRType A -Force } |
                Should -Throw 'Failed to find any resource record'
        }

        It 'removing with -RecordData removes only the matching address' {
            Add-DnsServerResourceRecordA -ZoneName 'example.local' -Name 'app' -IPv4Address '10.20.0.10'
            Remove-DnsServerResourceRecord -ZoneName 'example.local' -Name 'app' -RRType A -RecordData '10.10.0.10' -Force
            $remaining = @(Get-SeededRecord -Name 'app')
            $remaining.Count | Should -Be 1
            $remaining[0].ipv4Address | Should -Be '10.20.0.10'
        }

        It 'Add-DnsServerResourceRecordA -PassThru returns the new record' {
            $record = Add-DnsServerResourceRecordA -ZoneName 'example.local' -Name 'web' -IPv4Address '10.10.0.20' -PassThru
            $record.HostName | Should -Be 'web'
            $record.RecordData.IPv4Address.ToString() | Should -Be '10.10.0.20'
        }
    }
}
