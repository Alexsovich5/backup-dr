$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'Invoke-DRPlan' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'dr.log')
    }

    AfterAll {
        Remove-Variable -Name BackupDRTestCalls -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BackupDRTestFailStep -Scope Global -ErrorAction SilentlyContinue
    }

    $now = [datetime]'2019-02-17T02:00:00'
    $shippedPlanPath = Join-Path $PSScriptRoot '../../config/dr_plan.json'

    $alerting = [pscustomobject]@{
        email      = 'it-admin@example.local'
        from       = 'backup@example.local'
        smtpServer = 'smtp.example.local'
        smtpPort   = 25
    }

    function New-TestPlan {
        param([bool]$NotifyContinueOnError = $true, [bool]$DnsContinueOnError = $false)
        [pscustomobject]@{
            name                = 'Test-Plan'
            rpoThresholdMinutes = 15
            azure               = [pscustomobject]@{ vaultName = 'rsv-dr'; recoveryPlan = 'rp-primary' }
            failoverSteps       = @(
                [pscustomobject]@{ name = 'Notify start'; type = 'notification'; to = 'ops@example.local'; continueOnError = $NotifyContinueOnError },
                [pscustomobject]@{ name = 'Replica'; type = 'veeam_replica'; target = 'prod-db-01_replica' },
                [pscustomobject]@{ name = 'Azure'; type = 'azure_failover'; recoveryPlan = 'rp-primary' },
                [pscustomobject]@{ name = 'DNS'; type = 'dns_update'; zone = 'example.local'; record = 'app'
                    failoverIp = '10.20.0.10'; primaryIp = '10.10.0.10'; continueOnError = $DnsContinueOnError },
                [pscustomobject]@{ name = 'Notify end'; type = 'notification'; to = 'it-admin@example.local'; continueOnError = $NotifyContinueOnError }
            )
        }
    }

    # Every handler mock records "<step name>:<action>" in a global list (mock bodies run in
    # the module scope) and throws for the step named in $global:BackupDRTestFailStep.
    function Register-HandlerMocks {
        $global:BackupDRTestCalls = New-Object System.Collections.Generic.List[string]
        $global:BackupDRTestFailStep = $null
        $body = {
            $global:BackupDRTestCalls.Add("$($Step.name):$Action")
            if ($Step.name -eq $global:BackupDRTestFailStep) { throw "simulated failure in $($Step.name)" }
            "done $($Step.name)"
        }
        Mock -ModuleName BackupDR Invoke-VeeamReplicaStep $body
        Mock -ModuleName BackupDR Invoke-AzureFailoverStep $body
        Mock -ModuleName BackupDR Invoke-DnsUpdateStep $body
        Mock -ModuleName BackupDR Invoke-NotificationStep $body
    }

    Context 'failover' {
        It 'calls the step handlers in plan order and reports success' {
            Register-HandlerMocks

            $result = Invoke-DRPlan -Plan (New-TestPlan) -Action failover -Alerting $alerting -Now $now

            @($global:BackupDRTestCalls) | Should -Be @(
                'Notify start:failover', 'Replica:failover', 'Azure:failover', 'DNS:failover', 'Notify end:failover')
            $result.Action | Should -Be 'failover'
            $result.Success | Should -Be $true
            @($result.Steps).Count | Should -Be 5
            @($result.Steps | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('Succeeded')
            $result.Steps[1].Type | Should -Be 'veeam_replica'
            $result.Steps[1].Message | Should -Be 'done Replica'
        }

        It 'passes the vault from the plan to the Azure step and the alerting settings to notifications' {
            Register-HandlerMocks

            Invoke-DRPlan -Plan (New-TestPlan) -Action failover -Alerting $alerting -Now $now | Out-Null

            Assert-MockCalled -ModuleName BackupDR Invoke-AzureFailoverStep -Times 1 -Exactly -Scope It -ParameterFilter {
                $VaultName -eq 'rsv-dr' -and $Action -eq 'failover'
            }
            Assert-MockCalled -ModuleName BackupDR Invoke-NotificationStep -Times 2 -Exactly -Scope It -ParameterFilter {
                $Alerting.smtpServer -eq 'smtp.example.local' -and $PlanName -eq 'Test-Plan'
            }
        }

        It 'marks a throwing step Failed, later steps NotRun and the run unsuccessful' {
            Register-HandlerMocks
            $global:BackupDRTestFailStep = 'Replica'

            $result = Invoke-DRPlan -Plan (New-TestPlan) -Action failover -Alerting $alerting -Now $now

            $result.Success | Should -Be $false
            @($result.Steps | ForEach-Object { $_.Status }) | Should -Be @('Succeeded', 'Failed', 'NotRun', 'NotRun', 'NotRun')
            $result.Steps[1].Message | Should -Match 'simulated failure in Replica'
            @($global:BackupDRTestCalls) | Should -Be @('Notify start:failover', 'Replica:failover')
            Assert-MockCalled -ModuleName BackupDR Invoke-AzureFailoverStep -Times 0 -Exactly -Scope It
            Assert-MockCalled -ModuleName BackupDR Invoke-DnsUpdateStep -Times 0 -Exactly -Scope It
        }

        It 'keeps going after a failed continueOnError step and still reports success' {
            Register-HandlerMocks
            $global:BackupDRTestFailStep = 'Notify start'

            $result = Invoke-DRPlan -Plan (New-TestPlan) -Action failover -Alerting $alerting -Now $now

            @($result.Steps | ForEach-Object { $_.Status }) | Should -Be @('Failed', 'Succeeded', 'Succeeded', 'Succeeded', 'Succeeded')
            $result.Success | Should -Be $true
            @($global:BackupDRTestCalls).Count | Should -Be 5
        }

        It 'stops at a failed step that does not set continueOnError' {
            Register-HandlerMocks
            $global:BackupDRTestFailStep = 'Notify start'

            $result = Invoke-DRPlan -Plan (New-TestPlan -NotifyContinueOnError $false) -Action failover -Alerting $alerting -Now $now

            $result.Success | Should -Be $false
            @($result.Steps | ForEach-Object { $_.Status }) | Should -Be @('Failed', 'NotRun', 'NotRun', 'NotRun', 'NotRun')
        }
    }

    Context 'failback' {
        It 'runs the reversible steps in reverse order and notification steps last' {
            Register-HandlerMocks

            $result = Invoke-DRPlan -Plan (New-TestPlan) -Action failback -Alerting $alerting -Now $now

            @($global:BackupDRTestCalls) | Should -Be @(
                'DNS:failback', 'Azure:failback', 'Replica:failback', 'Notify start:failback', 'Notify end:failback')
            @($result.Steps | ForEach-Object { $_.Name }) | Should -Be @('DNS', 'Azure', 'Replica', 'Notify start', 'Notify end')
            $result.Success | Should -Be $true
        }

        It 'reverses the shipped plan with the notification still last' {
            Register-HandlerMocks
            $plan = Get-DRPlan -Path $shippedPlanPath

            Invoke-DRPlan -Plan $plan -Action failback -Alerting $alerting -Now $now | Out-Null

            @($global:BackupDRTestCalls) | Should -Be @(
                'Point app DNS at DR:failback', 'Fail over app tier to Azure:failback',
                'Fail over DB replica:failback', 'Notify IT:failback')
        }

        It 'stops on the first failure in reverse order' {
            Register-HandlerMocks
            $global:BackupDRTestFailStep = 'Azure'

            $result = Invoke-DRPlan -Plan (New-TestPlan) -Action failback -Alerting $alerting -Now $now

            $result.Success | Should -Be $false
            @($result.Steps | ForEach-Object { $_.Status }) | Should -Be @('Succeeded', 'Failed', 'NotRun', 'NotRun', 'NotRun')
            Assert-MockCalled -ModuleName BackupDR Invoke-VeeamReplicaStep -Times 0 -Exactly -Scope It
        }
    }

    Context 'test' {
        It 'runs every pre-flight check in plan order even after a failure' {
            Register-HandlerMocks
            $global:BackupDRTestFailStep = 'Replica'

            $result = Invoke-DRPlan -Plan (New-TestPlan) -Action test -Alerting $alerting -Now $now

            @($global:BackupDRTestCalls) | Should -Be @(
                'Notify start:test', 'Replica:test', 'Azure:test', 'DNS:test', 'Notify end:test')
            @($result.Steps | ForEach-Object { $_.Status }) | Should -Be @('Succeeded', 'Failed', 'Succeeded', 'Succeeded', 'Succeeded')
            $result.Success | Should -Be $false
        }
    }

    Context 'run log' {
        It 'writes the run as JSON to -RunLogPath, creating the directory' {
            Register-HandlerMocks
            $global:BackupDRTestFailStep = 'Azure'
            $runLog = Join-Path $TestDrive 'out/nested/dr-run.json'

            Invoke-DRPlan -Plan (New-TestPlan) -Action failover -Alerting $alerting -RunLogPath $runLog -Now $now | Out-Null

            Test-Path $runLog | Should -Be $true
            $text = Get-Content -Path $runLog -Raw
            # Checked on the raw text: ConvertFrom-Json on PowerShell 6 turns ISO strings into DateTime.
            $text | Should -Match '"Now":\s*"2019-02-17T02:00:00"'
            $log = $text | ConvertFrom-Json
            $log.Plan | Should -Be 'Test-Plan'
            $log.Action | Should -Be 'failover'
            $log.Success | Should -Be $false
            @($log.Steps | ForEach-Object { $_.Status }) | Should -Be @('Succeeded', 'Succeeded', 'Failed', 'NotRun', 'NotRun')
            $log.Steps[2].Name | Should -Be 'Azure'
            $log.Steps[2].Message | Should -Match 'simulated failure in Azure'
            $log.Steps[0].Started | Should -Not -BeNullOrEmpty
            $log.Steps[0].Finished | Should -Not -BeNullOrEmpty
            $log.Steps[3].Started | Should -BeNullOrEmpty
        }

        It 'does not write a run log when -RunLogPath is not given' {
            Register-HandlerMocks
            Mock -ModuleName BackupDR Set-Content { }

            Invoke-DRPlan -Plan (New-TestPlan) -Action test -Alerting $alerting -Now $now | Out-Null

            Assert-MockCalled -ModuleName BackupDR Set-Content -Times 0 -Exactly -Scope It
        }
    }

    It 'rejects an unknown action' {
        { Invoke-DRPlan -Plan (New-TestPlan) -Action 'rollback' -Now $now } | Should -Throw
    }
}
