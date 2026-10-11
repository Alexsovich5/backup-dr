# Defines the vendor commands from SPEC 5.5 as stubs in a global module so that
# code inside the BackupDR module can resolve them and Pester can mock them with
# Mock -ModuleName BackupDR. Every stub throws if it is called without a mock.
# Parameter names match the real cmdlets so ParameterFilter blocks work.
# Import-Module is not stubbed; provider tests mock it with a ParameterFilter.

New-Module -Name VendorStubs -ScriptBlock {
    function Get-StubError {
        param([string]$Command)
        "VendorStubs: $Command was called without a Mock"
    }

    # Windows PowerShell host (absent from PowerShell Core)
    function Add-PSSnapin {
        param([string[]]$Name)
        throw (Get-StubError 'Add-PSSnapin')
    }

    # Veeam Backup & Replication 9.5 (VeeamPSSnapin)
    function Get-VBRJob {
        param([string[]]$Name)
        throw (Get-StubError 'Get-VBRJob')
    }

    function Start-VBRJob {
        param(
            [Parameter(ValueFromPipeline = $true)][object[]]$Job,
            [switch]$FullBackup,
            [switch]$RunAsync
        )
        throw (Get-StubError 'Start-VBRJob')
    }

    function Get-VBRBackupSession {
        param([string[]]$Name)
        throw (Get-StubError 'Get-VBRBackupSession')
    }

    function Get-VBRBackup {
        param([string[]]$Name)
        throw (Get-StubError 'Get-VBRBackup')
    }

    function Get-VBRRestorePoint {
        param(
            [Parameter(ValueFromPipeline = $true)][object[]]$Backup,
            [string[]]$Name
        )
        throw (Get-StubError 'Get-VBRRestorePoint')
    }

    function Get-VBRReplica {
        param([string[]]$Name)
        throw (Get-StubError 'Get-VBRReplica')
    }

    function Start-VBRViReplicaFailover {
        param(
            [Parameter(ValueFromPipeline = $true)][object]$RestorePoint,
            [string]$Reason,
            [switch]$RunAsync
        )
        throw (Get-StubError 'Start-VBRViReplicaFailover')
    }

    function Start-VBRViReplicaFailback {
        param(
            [Parameter(ValueFromPipeline = $true)][object]$RestorePoint,
            [switch]$RunAsync,
            [switch]$PowerOn
        )
        throw (Get-StubError 'Start-VBRViReplicaFailback')
    }

    function Get-VBRBackupRepository {
        param([string[]]$Name)
        throw (Get-StubError 'Get-VBRBackupRepository')
    }

    # AzureRM 6.x Recovery Services / Site Recovery
    function Get-AzureRmRecoveryServicesVault {
        param([string]$Name, [string]$ResourceGroupName)
        throw (Get-StubError 'Get-AzureRmRecoveryServicesVault')
    }

    function Set-AzureRmRecoveryServicesAsrVaultContext {
        param([Parameter(ValueFromPipeline = $true)][object]$Vault)
        throw (Get-StubError 'Set-AzureRmRecoveryServicesAsrVaultContext')
    }

    function Get-AzureRmRecoveryServicesAsrRecoveryPlan {
        param([string]$Name, [string]$FriendlyName)
        throw (Get-StubError 'Get-AzureRmRecoveryServicesAsrRecoveryPlan')
    }

    function Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob {
        param(
            [object]$RecoveryPlan,
            [ValidateSet('PrimaryToRecovery', 'RecoveryToPrimary')][string]$Direction,
            [switch]$PerformSourceSideAction
        )
        throw (Get-StubError 'Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob')
    }

    function Start-AzureRmRecoveryServicesAsrPlannedFailoverJob {
        param(
            [object]$RecoveryPlan,
            [ValidateSet('PrimaryToRecovery', 'RecoveryToPrimary')][string]$Direction
        )
        throw (Get-StubError 'Start-AzureRmRecoveryServicesAsrPlannedFailoverJob')
    }

    function Get-AzureRmRecoveryServicesAsrJob {
        param([string]$Name, [Parameter(ValueFromPipeline = $true)][object]$Job)
        throw (Get-StubError 'Get-AzureRmRecoveryServicesAsrJob')
    }

    function Get-AzureRmRecoveryServicesAsrReplicationProtectedItem {
        param(
            [object]$ProtectionContainer,
            [object]$RecoveryPlan,
            [string]$Name,
            [string]$FriendlyName
        )
        throw (Get-StubError 'Get-AzureRmRecoveryServicesAsrReplicationProtectedItem')
    }

    # Windows DnsServer module
    function Get-DnsServerZone {
        param([string]$Name, [string]$ComputerName)
        throw (Get-StubError 'Get-DnsServerZone')
    }

    function Get-DnsServerResourceRecord {
        param([string]$ZoneName, [string]$Name, [string]$RRType, [string]$ComputerName)
        throw (Get-StubError 'Get-DnsServerResourceRecord')
    }

    function Add-DnsServerResourceRecordA {
        param(
            [string]$ZoneName,
            [string]$Name,
            [string[]]$IPv4Address,
            [timespan]$TimeToLive,
            [switch]$CreatePtr,
            [switch]$AllowUpdateAny,
            [switch]$PassThru,
            [string]$ComputerName
        )
        throw (Get-StubError 'Add-DnsServerResourceRecordA')
    }

    function Remove-DnsServerResourceRecord {
        param(
            [string]$ZoneName,
            [string]$Name,
            [string]$RRType,
            [string]$RecordData,
            [switch]$Force,
            [string]$ComputerName
        )
        throw (Get-StubError 'Remove-DnsServerResourceRecord')
    }

    Export-ModuleMember -Function @(
        'Add-PSSnapin',
        'Get-VBRJob', 'Start-VBRJob', 'Get-VBRBackupSession', 'Get-VBRBackup',
        'Get-VBRRestorePoint', 'Get-VBRReplica', 'Start-VBRViReplicaFailover',
        'Start-VBRViReplicaFailback', 'Get-VBRBackupRepository',
        'Get-AzureRmRecoveryServicesVault', 'Set-AzureRmRecoveryServicesAsrVaultContext',
        'Get-AzureRmRecoveryServicesAsrRecoveryPlan',
        'Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob',
        'Start-AzureRmRecoveryServicesAsrPlannedFailoverJob',
        'Get-AzureRmRecoveryServicesAsrJob',
        'Get-AzureRmRecoveryServicesAsrReplicationProtectedItem',
        'Get-DnsServerZone', 'Get-DnsServerResourceRecord',
        'Add-DnsServerResourceRecordA', 'Remove-DnsServerResourceRecord'
    )
} | Import-Module -Global -Force
