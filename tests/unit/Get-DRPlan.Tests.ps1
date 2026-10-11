$env:BACKUPDR_PROVIDER = 'none'
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$ShippedPlan = Join-Path $RepoRoot 'config/dr_plan.json'
$InvalidPlan = Join-Path $RepoRoot 'tests/fixtures/dr-plan-invalid.json'

Describe 'Get-DRPlan' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'drplan.log')
    }

    function Write-PlanFile {
        param([scriptblock]$Change)
        $plan = Get-Content -Path $ShippedPlan -Raw | ConvertFrom-Json
        & $Change $plan
        $path = Join-Path $TestDrive ('plan{0}.json' -f [guid]::NewGuid().ToString('N'))
        $plan | ConvertTo-Json -Depth 10 | Set-Content -Path $path
        $path
    }

    function Get-ValidationMessage {
        param([string]$Path)
        try {
            Get-DRPlan -Path $Path | Out-Null
        } catch {
            return $_.Exception.Message
        }
        throw "Get-DRPlan accepted $Path"
    }

    Context 'shipped plan' {
        It 'loads the four failover steps from config/dr_plan.json in order' {
            $plan = Get-DRPlan -Path $ShippedPlan
            $plan.name | Should -Be 'Primary-Site-To-Azure'
            @($plan.failoverSteps).Count | Should -Be 4
            @($plan.failoverSteps.type) | Should -Be @('veeam_replica', 'azure_failover', 'dns_update', 'notification')
        }

        It 'exposes the RPO threshold, Azure settings and step fields' {
            $plan = Get-DRPlan -Path $ShippedPlan
            $plan.rpoThresholdMinutes | Should -Be 15
            $plan.azure.vaultName | Should -Be 'rsv-dr'
            $plan.azure.recoveryPlan | Should -Be 'rp-primary'
            $plan.failoverSteps[0].target | Should -Be 'prod-db-01_replica'
            $plan.failoverSteps[2].failoverIp | Should -Be '10.20.0.10'
            $plan.failoverSteps[2].primaryIp | Should -Be '10.10.0.10'
            $plan.failoverSteps[3].continueOnError | Should -Be $true
        }
    }

    Context 'validation' {
        It 'rejects an unknown step type' {
            $path = Write-PlanFile { param($p) $p.failoverSteps[1].type = 'vmware_failover' }
            Get-ValidationMessage $path | Should -Match "step 'Fail over app tier to Azure': type 'vmware_failover' is not one of veeam_replica, azure_failover, dns_update, notification"
        }

        It 'rejects a dns_update step without failoverIp' {
            $path = Write-PlanFile { param($p) $p.failoverSteps[2].PSObject.Properties.Remove('failoverIp') }
            Get-ValidationMessage $path | Should -Match "step 'Point app DNS at DR': dns_update requires 'failoverIp'"
        }

        It 'rejects a veeam_replica step without target' {
            $path = Write-PlanFile { param($p) $p.failoverSteps[0].target = '' }
            Get-ValidationMessage $path | Should -Match "step 'Fail over DB replica': veeam_replica requires 'target'"
        }

        It 'rejects an azure_failover step without recoveryPlan' {
            $path = Write-PlanFile { param($p) $p.failoverSteps[1].PSObject.Properties.Remove('recoveryPlan') }
            Get-ValidationMessage $path | Should -Match "step 'Fail over app tier to Azure': azure_failover requires 'recoveryPlan'"
        }

        It 'rejects a notification step without a recipient' {
            $path = Write-PlanFile { param($p) $p.failoverSteps[3].PSObject.Properties.Remove('to') }
            Get-ValidationMessage $path | Should -Match "step 'Notify IT': notification requires 'to'"
        }

        It 'rejects duplicate step names' {
            $path = Write-PlanFile { param($p) $p.failoverSteps[1].name = $p.failoverSteps[0].name }
            Get-ValidationMessage $path | Should -Match "duplicate step name 'Fail over DB replica'"
        }

        It 'rejects an rpoThresholdMinutes of 0' {
            $path = Write-PlanFile { param($p) $p.rpoThresholdMinutes = 0 }
            Get-ValidationMessage $path | Should -Match 'rpoThresholdMinutes must be greater than 0'
        }

        It 'rejects a plan without steps' {
            $path = Write-PlanFile { param($p) $p.failoverSteps = @() }
            Get-ValidationMessage $path | Should -Match 'failoverSteps: at least one step is required'
        }

        It 'reports every problem in one error' {
            $message = Get-ValidationMessage $InvalidPlan
            $message | Should -Match 'dr-plan-invalid\.json'
            $message | Should -Match 'rpoThresholdMinutes must be greater than 0'
            $message | Should -Match "step 'Fail over DB replica': veeam_replica requires 'target'"
            $message | Should -Match "step 'Restore from tape': type 'tape_restore' is not one of"
            $message | Should -Match "step 'Point app DNS at DR': dns_update requires 'failoverIp'"
            $message | Should -Match "duplicate step name 'Notify IT'"
            $message | Should -Match '5 problem\(s\)'
        }

        It 'reports a missing file' {
            { Get-DRPlan -Path (Join-Path $TestDrive 'missing.json') } |
                Should -Throw 'DR plan not found'
        }

        It 'reports a file that is not JSON' {
            $path = Join-Path $TestDrive 'broken.json'
            Set-Content -Path $path -Value '{ "failoverSteps": [ '
            { Get-DRPlan -Path $path } | Should -Throw 'is not valid JSON'
        }
    }
}
