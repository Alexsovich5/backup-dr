$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'Get-AzureReplicationStatus' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'replication.log')
    }

    # A fixed evaluation time far from the wall clock, so any use of Get-Date shows up.
    $now = [datetime]'2019-02-17T02:00:00'

    $plan = [pscustomobject]@{
        name                = 'Primary-Site-To-Azure'
        rpoThresholdMinutes = 15
        azure               = [pscustomobject]@{ vaultName = 'rsv-dr'; recoveryPlan = 'rp-primary' }
        failoverSteps       = @()
    }

    function New-TestItem {
        # Shaped like an InMageAzureV2 ASRReplicationProtectedItem: RPO lives in the provider details.
        param(
            [string]$Name,
            [string]$Health = 'Normal',
            [long]$RpoSeconds = 300,
            [datetime]$Calculated = [datetime]'2019-02-17T02:00:00'
        )
        [pscustomobject]@{
            Name                    = $Name
            FriendlyName            = $Name
            ReplicationHealth       = $Health
            ProviderSpecificDetails = [pscustomobject]@{
                RpoInSeconds          = $RpoSeconds
                LastRpoCalculatedTime = $Calculated
            }
        }
    }

    BeforeEach {
        $global:BackupDRTestItems = @()
        Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesVault {
            [pscustomobject]@{ Name = 'rsv-dr'; ResourceGroupName = 'rg-dr' }
        }
        Mock -ModuleName BackupDR Set-AzureRmRecoveryServicesAsrVaultContext {
            [pscustomobject]@{ ResourceName = 'rsv-dr' }
        }
        Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrRecoveryPlan {
            [pscustomobject]@{ Name = 'rp-primary'; CurrentSite = 'Primary' }
        }
        Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrReplicationProtectedItem {
            $global:BackupDRTestItems
        }
    }

    AfterAll {
        Remove-Variable -Name BackupDRTestItems -Scope Global -ErrorAction SilentlyContinue
    }

    It 'is OK with exit code 0 when every item is Normal and inside the RPO threshold' {
        $global:BackupDRTestItems = @(
            (New-TestItem -Name 'prod-web-01' -RpoSeconds 240),
            (New-TestItem -Name 'prod-app-01' -RpoSeconds 300)
        )

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        $status.State | Should -Be 'OK'
        $status.ExitCode | Should -Be 0
        $items = @($status.Items)
        $items.Count | Should -Be 2
        $items[0].Name | Should -Be 'prod-web-01'
        $items[0].Health | Should -Be 'Normal'
        $items[0].RpoMinutes | Should -Be 4
        $items[0].Ok | Should -Be $true
        $items[1].RpoMinutes | Should -Be 5
        $items[1].Ok | Should -Be $true
    }

    It 'sets the vault context from the plan and lists the items of its recovery plan' {
        $global:BackupDRTestItems = @(New-TestItem -Name 'prod-web-01')

        Get-AzureReplicationStatus -Plan $plan -Now $now | Out-Null

        Assert-MockCalled -ModuleName BackupDR Get-AzureRmRecoveryServicesVault -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'rsv-dr' }
        Assert-MockCalled -ModuleName BackupDR Set-AzureRmRecoveryServicesAsrVaultContext -Times 1 -Exactly -Scope It -ParameterFilter { $Vault.Name -eq 'rsv-dr' }
        Assert-MockCalled -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrRecoveryPlan -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'rp-primary' }
        Assert-MockCalled -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrReplicationProtectedItem -Times 1 -Exactly -Scope It -ParameterFilter { $RecoveryPlan.Name -eq 'rp-primary' }
    }

    It 'is WARNING with exit code 1 when one item has an RPO over rpoThresholdMinutes' {
        $global:BackupDRTestItems = @(
            (New-TestItem -Name 'prod-web-01' -RpoSeconds 240),
            (New-TestItem -Name 'prod-app-01' -RpoSeconds 1800)
        )

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        $status.State | Should -Be 'WARNING'
        $status.ExitCode | Should -Be 1
        $bad = @($status.Items | Where-Object { -not $_.Ok })
        $bad.Count | Should -Be 1
        $bad[0].Name | Should -Be 'prod-app-01'
        $bad[0].RpoMinutes | Should -Be 30
    }

    It 'adds the time since the RPO was last calculated, measured from -Now' {
        # Reported RPO is 5 minutes, but it was calculated 20 minutes before -Now.
        $global:BackupDRTestItems = @(
            New-TestItem -Name 'prod-app-01' -RpoSeconds 300 -Calculated ([datetime]'2019-02-17T01:40:00')
        )

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        @($status.Items)[0].RpoMinutes | Should -Be 25
        $status.State | Should -Be 'WARNING'
        $status.ExitCode | Should -Be 1
    }

    It 'treats an RPO exactly at the threshold as within it' {
        $global:BackupDRTestItems = @(New-TestItem -Name 'prod-app-01' -RpoSeconds 900 -Calculated $now)

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        $status.State | Should -Be 'OK'
        @($status.Items)[0].RpoMinutes | Should -Be 15
    }

    It 'is WARNING when an item reports ReplicationHealth Warning' {
        $global:BackupDRTestItems = @(
            (New-TestItem -Name 'prod-web-01'),
            (New-TestItem -Name 'prod-app-01' -Health 'Warning')
        )

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        $status.State | Should -Be 'WARNING'
        $status.ExitCode | Should -Be 1
        @($status.Items | Where-Object { $_.Name -eq 'prod-app-01' })[0].Ok | Should -Be $false
    }

    It 'is CRITICAL with exit code 2 when any item has ReplicationHealth Critical' {
        $global:BackupDRTestItems = @(
            (New-TestItem -Name 'prod-web-01' -RpoSeconds 1800),
            (New-TestItem -Name 'prod-app-01' -Health 'Critical')
        )

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        $status.State | Should -Be 'CRITICAL'
        $status.ExitCode | Should -Be 2
        @($status.Items | Where-Object { $_.Name -eq 'prod-app-01' })[0].Health | Should -Be 'Critical'
    }

    It 'is CRITICAL with exit code 2 when there are no protected items' {
        $global:BackupDRTestItems = @()

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        $status.State | Should -Be 'CRITICAL'
        $status.ExitCode | Should -Be 2
        @($status.Items).Count | Should -Be 0
        $status.Message | Should -Match 'no protected items'
    }

    It 'is CRITICAL when the vault cannot be found, naming the vault' {
        Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesVault { }

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        $status.State | Should -Be 'CRITICAL'
        $status.ExitCode | Should -Be 2
        $status.Message | Should -Match 'rsv-dr'
        Assert-MockCalled -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrReplicationProtectedItem -Times 0 -Exactly -Scope It
    }

    It 'is CRITICAL when listing protected items throws, carrying the error message' {
        Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrReplicationProtectedItem { throw 'Operation failed. NotFound' }

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        $status.State | Should -Be 'CRITICAL'
        $status.ExitCode | Should -Be 2
        $status.Message | Should -Match 'Operation failed'
    }

    It 'falls back to a top-level RpoInSeconds when the provider details have none' {
        $global:BackupDRTestItems = @(
            [pscustomobject]@{ Name = 'prod-web-01'; ReplicationHealth = 'Normal'; RpoInSeconds = 120 }
        )

        $status = Get-AzureReplicationStatus -Plan $plan -Now $now

        @($status.Items)[0].RpoMinutes | Should -Be 2
        $status.State | Should -Be 'OK'
    }
}
