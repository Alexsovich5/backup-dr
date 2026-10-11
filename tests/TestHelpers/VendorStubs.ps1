# Defines the vendor commands from SPEC 5.5 as stubs in a global module so that
# code inside the BackupDR module can resolve them and Pester can mock them with
# Mock -ModuleName BackupDR. Every stub throws if it is called without a mock.
# Parameter names match the real cmdlets so ParameterFilter blocks work.

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

    Export-ModuleMember -Function @(
        'Add-PSSnapin',
        'Get-VBRJob', 'Start-VBRJob', 'Get-VBRBackupSession', 'Get-VBRBackup',
        'Get-VBRRestorePoint', 'Get-VBRReplica', 'Start-VBRViReplicaFailover',
        'Start-VBRViReplicaFailback', 'Get-VBRBackupRepository'
    )
} | Import-Module -Global -Force
