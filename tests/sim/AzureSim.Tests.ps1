. (Join-Path $PSScriptRoot '../TestHelpers/New-SimState.ps1')
Import-Module (Join-Path $PSScriptRoot '../../sim/AzureSim') -Force

Describe 'AzureSim' -Tag 'Unit' {
    $anchor = [datetime]'2019-02-17T02:00:00'

    BeforeAll {
        $script:savedState = $env:BACKUPDR_SIM_STATE
        $script:savedNow = $env:BACKUPDR_SIM_NOW
    }

    AfterAll {
        $env:BACKUPDR_SIM_STATE = $script:savedState
        $env:BACKUPDR_SIM_NOW = $script:savedNow
        Remove-Module AzureSim -Force -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $script:stateDir = New-SimState -Anchor $anchor
        $script:stateFile = Join-Path $script:stateDir 'azure.json'
        $env:BACKUPDR_SIM_NOW = $anchor.ToString('o')
        Get-AzureRmRecoveryServicesVault -Name 'rsv-dr' | Set-AzureRmRecoveryServicesAsrVaultContext | Out-Null
    }

    function Read-State {
        Get-Content -Path $script:stateFile -Raw | ConvertFrom-Json
    }

    function Get-PlanRecord {
        @((Read-State).recoveryPlans | Where-Object { $_.name -eq 'rp-primary' })[0]
    }

    Context 'state seeding' {
        It 'New-SimState writes azure.json with offsets resolved against the anchor' {
            Test-Path $script:stateFile | Should -Be $true
            $seeded = Get-Content -Path $script:stateFile -Raw
            $seeded | Should -Not -Match '"[+-]\d+[smhd]"'
            $seeded | Should -Match '"2019-02-17T01:5\d:00"'
        }
    }

    Context 'vault and recovery plan' {
        It 'Get-AzureRmRecoveryServicesVault -Name returns the seeded vault' {
            $vault = Get-AzureRmRecoveryServicesVault -Name 'rsv-dr'
            $vault.Name | Should -Be 'rsv-dr'
            $vault.ResourceGroupName | Should -Not -BeNullOrEmpty
        }

        It 'Set-AzureRmRecoveryServicesAsrVaultContext returns the vault settings' {
            $context = Set-AzureRmRecoveryServicesAsrVaultContext -Vault (Get-AzureRmRecoveryServicesVault -Name 'rsv-dr')
            $context.ResourceName | Should -Be 'rsv-dr'
        }

        It 'Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name returns the plan at the primary site' {
            $plan = Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary'
            $plan.Name | Should -Be 'rp-primary'
            $plan.CurrentSite | Should -Be 'Primary'
        }

        It 'Get-AzureRmRecoveryServicesAsrRecoveryPlan throws for a plan that does not exist' {
            { Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-missing' } | Should -Throw "rp-missing"
        }

        It 'ASR cmdlets throw when no vault context is set' {
            Remove-Module AzureSim -Force
            Import-Module (Join-Path $PSScriptRoot '../../sim/AzureSim') -Force
            { Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary' } | Should -Throw 'Set-AzureRmRecoveryServicesAsrVaultContext'
        }
    }

    Context 'failover and failback' {
        It 'unplanned failover PrimaryToRecovery succeeds and moves the plan to the recovery site' {
            $simNow = $anchor.AddMinutes(3)
            $env:BACKUPDR_SIM_NOW = $simNow.ToString('o')
            $plan = Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary'

            $job = Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -RecoveryPlan $plan -Direction PrimaryToRecovery

            $job.State | Should -Be 'Succeeded'
            $job.TargetObjectName | Should -Be 'rp-primary'
            $job.StartTime | Should -Be $simNow
            $job.EndTime | Should -Be $simNow
            (Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary').CurrentSite | Should -Be 'Recovery'
            (Get-PlanRecord).currentSite | Should -Be 'Recovery'
        }

        It 'unplanned failover RecoveryToPrimary throws and leaves the plan at the primary site' {
            $plan = Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary'
            { Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -RecoveryPlan $plan -Direction RecoveryToPrimary } |
                Should -Throw 'PrimaryToRecovery'
            (Get-PlanRecord).currentSite | Should -Be 'Primary'
        }

        It 'planned failover RecoveryToPrimary returns a failed-over plan to the primary site' {
            $plan = Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary'
            Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -RecoveryPlan $plan -Direction PrimaryToRecovery | Out-Null

            $plan = Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary'
            $job = Start-AzureRmRecoveryServicesAsrPlannedFailoverJob -RecoveryPlan $plan -Direction RecoveryToPrimary

            $job.State | Should -Be 'Succeeded'
            (Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary').CurrentSite | Should -Be 'Primary'
        }

        It 'planned failover PrimaryToRecovery throws as ASR does for VMware to Azure' {
            $plan = Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary'
            { Start-AzureRmRecoveryServicesAsrPlannedFailoverJob -RecoveryPlan $plan -Direction PrimaryToRecovery } |
                Should -Throw 'unplanned failover'
            (Get-PlanRecord).currentSite | Should -Be 'Primary'
        }

        It 'failover of a plan already at the recovery site throws' {
            $plan = Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary'
            Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -RecoveryPlan $plan -Direction PrimaryToRecovery | Out-Null
            { Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -RecoveryPlan $plan -Direction PrimaryToRecovery } |
                Should -Throw 'already at the recovery site'
        }

        It 'failover jobs are recorded and returned by Get-AzureRmRecoveryServicesAsrJob' {
            $plan = Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary'
            $job = Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -RecoveryPlan $plan -Direction PrimaryToRecovery

            $found = Get-AzureRmRecoveryServicesAsrJob -Name $job.Name
            $found.Name | Should -Be $job.Name
            $found.State | Should -Be 'Succeeded'
            @((Read-State).jobs).Count | Should -Be 1
        }
    }

    Context 'replication protected items' {
        It 'expose ReplicationHealth and RpoInSeconds for each protected VM' {
            $items = @(Get-AzureRmRecoveryServicesAsrReplicationProtectedItem)
            $items.Count | Should -Be 2
            $items | ForEach-Object {
                $_.ReplicationHealth | Should -Be 'Normal'
                $_.RpoInSeconds | Should -BeGreaterThan 0
                $_.ProviderSpecificDetails.RpoInSeconds | Should -Be $_.RpoInSeconds
            }
        }

        It 'reflect seeded health and RPO from the state file' {
            $state = Read-State
            $item = $state.protectedItems | Where-Object { $_.name -eq 'prod-app-01' }
            $item.replicationHealth = 'Critical'
            $item.rpoInSeconds = 3600
            $state | ConvertTo-Json -Depth 10 | Set-Content -Path $script:stateFile

            $found = Get-AzureRmRecoveryServicesAsrReplicationProtectedItem -Name 'prod-app-01'
            $found.ReplicationHealth | Should -Be 'Critical'
            $found.RpoInSeconds | Should -Be 3600
        }

        It 'can be filtered by recovery plan' {
            $plan = Get-AzureRmRecoveryServicesAsrRecoveryPlan -Name 'rp-primary'
            @(Get-AzureRmRecoveryServicesAsrReplicationProtectedItem -RecoveryPlan $plan).Count | Should -Be 2
        }
    }
}
