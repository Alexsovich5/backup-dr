$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

# Mock bodies run in the BackupDR module scope, so they build their own objects
# instead of closing over test-scope variables.
function global:Register-HealthyVendorMocks {
    Mock -ModuleName BackupDR Get-VBRReplica {
        [pscustomobject]@{ Name = 'prod-db-01_replica'; VmName = 'prod-db-01'; IsReplica = $true; State = 'Ready' }
    }
    Mock -ModuleName BackupDR Get-VBRRestorePoint {
        [pscustomobject]@{ Id = 'rp-old'; ReplicaName = 'prod-db-01_replica'; CreationTime = [datetime]'2019-02-17T00:00:00' }
        [pscustomobject]@{ Id = 'rp-new'; ReplicaName = 'prod-db-01_replica'; CreationTime = [datetime]'2019-02-17T01:00:00' }
    }
    Mock -ModuleName BackupDR Start-VBRViReplicaFailover {
        [pscustomobject]@{ Name = 'prod-db-01_replica Failover'; State = 'Stopped'; Result = 'Success' }
    }
    Mock -ModuleName BackupDR Start-VBRViReplicaFailback {
        [pscustomobject]@{ Name = 'prod-db-01_replica Failback'; State = 'Stopped'; Result = 'Success' }
    }
    Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesVault {
        [pscustomobject]@{ Name = 'rsv-dr'; ResourceGroupName = 'rg-dr' }
    }
    Mock -ModuleName BackupDR Set-AzureRmRecoveryServicesAsrVaultContext {
        [pscustomobject]@{ ResourceName = 'rsv-dr' }
    }
    Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrRecoveryPlan {
        [pscustomobject]@{ Name = 'rp-primary'; CurrentSite = 'Primary' }
    }
    Mock -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob {
        [pscustomobject]@{ Name = 'job-1'; DisplayName = 'Unplanned failover'; State = 'Succeeded' }
    }
    Mock -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrPlannedFailoverJob {
        [pscustomobject]@{ Name = 'job-2'; DisplayName = 'Planned failover'; State = 'Succeeded' }
    }
    Mock -ModuleName BackupDR Get-DnsServerZone {
        [pscustomobject]@{ ZoneName = 'example.local'; ZoneType = 'Primary' }
    }
    Mock -ModuleName BackupDR Get-DnsServerResourceRecord {
        [pscustomobject]@{ HostName = 'app'; RecordType = 'A'
            RecordData = [pscustomobject]@{ IPv4Address = [System.Net.IPAddress]::Parse('10.10.0.10') } }
    }
    Mock -ModuleName BackupDR Add-DnsServerResourceRecordA { }
    Mock -ModuleName BackupDR Remove-DnsServerResourceRecord { }
    Mock -ModuleName BackupDR Send-MailMessage { }
    Mock -ModuleName BackupDR Start-Sleep { }
}

InModuleScope BackupDR {
    Describe 'DR step handlers' -Tag 'Unit' {
        BeforeAll {
            Set-BackupLogPath -Path (Join-Path $TestDrive 'steps.log')
        }

        $replicaStep = [pscustomobject]@{ name = 'Fail over DB replica'; type = 'veeam_replica'; target = 'prod-db-01_replica' }
        $azureStep = [pscustomobject]@{ name = 'Fail over app tier'; type = 'azure_failover'; recoveryPlan = 'rp-primary' }
        $dnsStep = [pscustomobject]@{ name = 'Point app DNS at DR'; type = 'dns_update'; zone = 'example.local'
            record = 'app'; failoverIp = '10.20.0.10'; primaryIp = '10.10.0.10' }
        $notifyStep = [pscustomobject]@{ name = 'Notify IT'; type = 'notification'; to = 'it-admin@example.local' }
        $alerting = [pscustomobject]@{ email = 'someone-else@example.local'; from = 'backup@example.local'
            smtpServer = 'smtp.example.local'; smtpPort = 25 }

        Context 'Invoke-VeeamReplicaStep' {
            It 'fails over the newest restore point of the target replica' {
                Register-HealthyVendorMocks

                $message = Invoke-VeeamReplicaStep -Step $replicaStep -Action failover

                Assert-MockCalled -ModuleName BackupDR Get-VBRReplica -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'prod-db-01_replica' }
                Assert-MockCalled -ModuleName BackupDR Start-VBRViReplicaFailover -Times 1 -Exactly -Scope It -ParameterFilter { $RestorePoint.Id -eq 'rp-new' }
                Assert-MockCalled -ModuleName BackupDR Start-VBRViReplicaFailback -Times 0 -Exactly -Scope It
                $message | Should -Match 'prod-db-01_replica'
            }

            It 'fails back with Start-VBRViReplicaFailback' {
                Register-HealthyVendorMocks

                Invoke-VeeamReplicaStep -Step $replicaStep -Action failback | Out-Null

                Assert-MockCalled -ModuleName BackupDR Start-VBRViReplicaFailback -Times 1 -Exactly -Scope It -ParameterFilter { $RestorePoint.Id -eq 'rp-new' }
                Assert-MockCalled -ModuleName BackupDR Start-VBRViReplicaFailover -Times 0 -Exactly -Scope It
            }

            It 'throws when the replica does not exist' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Get-VBRReplica { }

                { Invoke-VeeamReplicaStep -Step $replicaStep -Action failover } | Should -Throw "replica 'prod-db-01_replica' not found"
                Assert-MockCalled -ModuleName BackupDR Start-VBRViReplicaFailover -Times 0 -Exactly -Scope It
            }

            It 'throws when the replica has no restore point' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Get-VBRRestorePoint { }

                { Invoke-VeeamReplicaStep -Step $replicaStep -Action failover } | Should -Throw 'has no restore point'
            }

            It 'throws when the failover session result is Failed' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Start-VBRViReplicaFailover {
                    [pscustomobject]@{ Name = 'x'; State = 'Stopped'; Result = 'Failed' }
                }

                { Invoke-VeeamReplicaStep -Step $replicaStep -Action failover } | Should -Throw 'Failed'
            }
        }

        Context 'Invoke-AzureFailoverStep' {
            It 'sets the vault context and runs an unplanned PrimaryToRecovery failover on failover' {
                Register-HealthyVendorMocks

                $message = Invoke-AzureFailoverStep -Step $azureStep -Action failover -VaultName 'rsv-dr'

                Assert-MockCalled -ModuleName BackupDR Get-AzureRmRecoveryServicesVault -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'rsv-dr' }
                Assert-MockCalled -ModuleName BackupDR Set-AzureRmRecoveryServicesAsrVaultContext -Times 1 -Exactly -Scope It -ParameterFilter { $Vault.Name -eq 'rsv-dr' }
                Assert-MockCalled -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrRecoveryPlan -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'rp-primary' }
                Assert-MockCalled -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -Times 1 -Exactly -Scope It -ParameterFilter {
                    $Direction -eq 'PrimaryToRecovery' -and $RecoveryPlan.Name -eq 'rp-primary'
                }
                Assert-MockCalled -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrPlannedFailoverJob -Times 0 -Exactly -Scope It
                $message | Should -Match 'Succeeded'
            }

            It 'runs a planned RecoveryToPrimary failover on failback and never the unplanned one' {
                Register-HealthyVendorMocks

                Invoke-AzureFailoverStep -Step $azureStep -Action failback -VaultName 'rsv-dr' | Out-Null

                Assert-MockCalled -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrPlannedFailoverJob -Times 1 -Exactly -Scope It -ParameterFilter {
                    $Direction -eq 'RecoveryToPrimary' -and $RecoveryPlan.Name -eq 'rp-primary'
                }
                Assert-MockCalled -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -Times 0 -Exactly -Scope It
            }

            It 'polls an in-progress job until it finishes' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob {
                    [pscustomobject]@{ Name = 'job-1'; State = 'InProgress' }
                }
                $script:asrPolls = 0
                Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrJob {
                    $script:asrPolls++
                    if ($script:asrPolls -lt 3) { $state = 'InProgress' } else { $state = 'Succeeded' }
                    [pscustomobject]@{ Name = 'job-1'; State = $state }
                }

                Invoke-AzureFailoverStep -Step $azureStep -Action failover -VaultName 'rsv-dr' -PollSeconds 5 | Out-Null

                Assert-MockCalled -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrJob -Times 3 -Exactly -Scope It -ParameterFilter { $Name -eq 'job-1' }
                Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 3 -Exactly -Scope It -ParameterFilter { $Seconds -eq 5 }
            }

            It 'throws when the ASR job ends in a failed state' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob {
                    [pscustomobject]@{ Name = 'job-1'; State = 'Failed' }
                }

                { Invoke-AzureFailoverStep -Step $azureStep -Action failover -VaultName 'rsv-dr' } | Should -Throw "ended in state 'Failed'"
            }

            It 'throws when the vault does not exist' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesVault { }

                { Invoke-AzureFailoverStep -Step $azureStep -Action failover -VaultName 'rsv-dr' } | Should -Throw "vault 'rsv-dr' not found"
            }

            It 'throws when no vault name is given' {
                Register-HealthyVendorMocks

                { Invoke-AzureFailoverStep -Step $azureStep -Action failover -VaultName '' } | Should -Throw 'vaultName'
            }
        }

        Context 'Invoke-DnsUpdateStep' {
            It 'swaps the record from the primary IP to the failover IP on failover' {
                Register-HealthyVendorMocks

                Invoke-DnsUpdateStep -Step $dnsStep -Action failover | Out-Null

                Assert-MockCalled -ModuleName BackupDR Get-DnsServerZone -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'example.local' }
                Assert-MockCalled -ModuleName BackupDR Remove-DnsServerResourceRecord -Times 1 -Exactly -Scope It -ParameterFilter {
                    $ZoneName -eq 'example.local' -and $Name -eq 'app' -and $RRType -eq 'A' -and $RecordData -eq '10.10.0.10' -and $Force
                }
                Assert-MockCalled -ModuleName BackupDR Add-DnsServerResourceRecordA -Times 1 -Exactly -Scope It -ParameterFilter {
                    $ZoneName -eq 'example.local' -and $Name -eq 'app' -and @($IPv4Address) -contains '10.20.0.10'
                }
            }

            It 'swaps the record back to the primary IP on failback' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Get-DnsServerResourceRecord {
                    [pscustomobject]@{ HostName = 'app'; RecordType = 'A'
                        RecordData = [pscustomobject]@{ IPv4Address = [System.Net.IPAddress]::Parse('10.20.0.10') } }
                }

                Invoke-DnsUpdateStep -Step $dnsStep -Action failback | Out-Null

                Assert-MockCalled -ModuleName BackupDR Remove-DnsServerResourceRecord -Times 1 -Exactly -Scope It -ParameterFilter { $RecordData -eq '10.20.0.10' }
                Assert-MockCalled -ModuleName BackupDR Add-DnsServerResourceRecordA -Times 1 -Exactly -Scope It -ParameterFilter { @($IPv4Address) -contains '10.10.0.10' }
            }

            It 'does not add a duplicate when the record already points at the target IP' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Get-DnsServerResourceRecord {
                    [pscustomobject]@{ HostName = 'app'; RecordType = 'A'
                        RecordData = [pscustomobject]@{ IPv4Address = [System.Net.IPAddress]::Parse('10.20.0.10') } }
                }

                Invoke-DnsUpdateStep -Step $dnsStep -Action failover | Out-Null

                Assert-MockCalled -ModuleName BackupDR Add-DnsServerResourceRecordA -Times 0 -Exactly -Scope It
                Assert-MockCalled -ModuleName BackupDR Remove-DnsServerResourceRecord -Times 0 -Exactly -Scope It
            }

            It 'adds the record when it does not exist yet' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Get-DnsServerResourceRecord { throw 'Failed to get app record in example.local zone' }

                Invoke-DnsUpdateStep -Step $dnsStep -Action failover | Out-Null

                Assert-MockCalled -ModuleName BackupDR Remove-DnsServerResourceRecord -Times 0 -Exactly -Scope It
                Assert-MockCalled -ModuleName BackupDR Add-DnsServerResourceRecordA -Times 1 -Exactly -Scope It -ParameterFilter { @($IPv4Address) -contains '10.20.0.10' }
            }

            It 'throws when the zone does not exist' {
                Register-HealthyVendorMocks
                Mock -ModuleName BackupDR Get-DnsServerZone { throw 'Failed to get the zone information for example.local on server dns01.' }

                { Invoke-DnsUpdateStep -Step $dnsStep -Action failover } | Should -Throw "DNS zone 'example.local' not found"
                Assert-MockCalled -ModuleName BackupDR Add-DnsServerResourceRecordA -Times 0 -Exactly -Scope It
            }
        }

        Context 'Invoke-NotificationStep' {
            It 'mails the step recipient using the policy relay and lists earlier steps' {
                Register-HealthyVendorMocks
                $results = @([pscustomobject]@{ Name = 'Fail over DB replica'; Status = 'Succeeded'; Message = 'ok' })

                Invoke-NotificationStep -Step $notifyStep -Action failover -Alerting $alerting -PlanName 'Primary-Site-To-Azure' -Results $results | Out-Null

                Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Times 1 -Exactly -Scope It -ParameterFilter {
                    @($To) -contains 'it-admin@example.local' -and @($To).Count -eq 1 -and
                    $SmtpServer -eq 'smtp.example.local' -and
                    $Subject -eq 'DR failover: Primary-Site-To-Azure' -and $Body -match 'Fail over DB replica: Succeeded'
                }
            }

            It 'throws when no alerting settings are available' {
                Register-HealthyVendorMocks

                { Invoke-NotificationStep -Step $notifyStep -Action failover -PlanName 'P' } | Should -Throw 'alerting'
                Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Times 0 -Exactly -Scope It
            }

            It 'sends nothing in test mode' {
                Register-HealthyVendorMocks

                $message = Invoke-NotificationStep -Step $notifyStep -Action test -Alerting $alerting -PlanName 'P'

                Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Times 0 -Exactly -Scope It
                $message | Should -Match 'it-admin@example.local'
            }
        }
    }
}

Describe 'Invoke-DRPlan -Action test' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'test-mode.log')
    }

    $plan = Get-DRPlan -Path (Join-Path $PSScriptRoot '../../config/dr_plan.json')
    $alerting = [pscustomobject]@{ email = 'it-admin@example.local'; from = 'backup@example.local'
        smtpServer = 'smtp.example.local'; smtpPort = 25 }
    $now = [datetime]'2019-02-17T02:00:00'

    function Assert-NothingChanged {
        Assert-MockCalled -ModuleName BackupDR Start-VBRViReplicaFailover -Times 0 -Exactly -Scope It
        Assert-MockCalled -ModuleName BackupDR Start-VBRViReplicaFailback -Times 0 -Exactly -Scope It
        Assert-MockCalled -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob -Times 0 -Exactly -Scope It
        Assert-MockCalled -ModuleName BackupDR Start-AzureRmRecoveryServicesAsrPlannedFailoverJob -Times 0 -Exactly -Scope It
        Assert-MockCalled -ModuleName BackupDR Add-DnsServerResourceRecordA -Times 0 -Exactly -Scope It
        Assert-MockCalled -ModuleName BackupDR Remove-DnsServerResourceRecord -Times 0 -Exactly -Scope It
        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Times 0 -Exactly -Scope It
    }

    It 'passes pre-flight for a healthy environment without calling any mutating cmdlet' {
        Register-HealthyVendorMocks

        $result = Invoke-DRPlan -Plan $plan -Action test -Alerting $alerting -Now $now

        $result.Success | Should -Be $true
        @($result.Steps | ForEach-Object { $_.Status } | Select-Object -Unique) | Should -Be @('Succeeded')
        Assert-MockCalled -ModuleName BackupDR Get-DnsServerZone -Times 1 -Exactly -Scope It -ParameterFilter { $Name -eq 'example.local' }
        Assert-NothingChanged
    }

    It 'reports a missing replica, recovery plan and DNS zone as pre-flight failures' {
        Register-HealthyVendorMocks
        Mock -ModuleName BackupDR Get-VBRReplica { }
        Mock -ModuleName BackupDR Get-AzureRmRecoveryServicesAsrRecoveryPlan {
            throw "Operation failed. NotFound: recovery plan 'rp-primary' was not found in vault 'rsv-dr'"
        }
        Mock -ModuleName BackupDR Get-DnsServerZone { throw 'Failed to get the zone information for example.local on server dns01.' }

        $result = Invoke-DRPlan -Plan $plan -Action test -Alerting $alerting -Now $now

        $result.Success | Should -Be $false
        @($result.Steps | ForEach-Object { $_.Status }) | Should -Be @('Failed', 'Failed', 'Failed', 'Succeeded')
        $result.Steps[0].Message | Should -Match "replica 'prod-db-01_replica' not found"
        $result.Steps[1].Message | Should -Match "recovery plan 'rp-primary' not found"
        $result.Steps[2].Message | Should -Match "DNS zone 'example.local' not found"
        Assert-NothingChanged
    }
}
