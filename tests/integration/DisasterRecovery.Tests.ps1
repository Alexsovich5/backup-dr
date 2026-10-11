. (Join-Path $PSScriptRoot '../TestHelpers/MailHog.ps1')
. (Join-Path $PSScriptRoot '../TestHelpers/New-SimState.ps1')

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:DrScriptPath = Join-Path $script:RepoRoot 'scripts/disaster_recovery.ps1'

function Read-SimFile {
    param([string]$Name)
    Get-Content -Path (Join-Path $env:BACKUPDR_SIM_STATE "$Name.json") -Raw | ConvertFrom-Json
}

function Write-SimFile {
    param([string]$Name, $State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $env:BACKUPDR_SIM_STATE "$Name.json")
}

function Get-SimFileHash {
    # SHA256 of every state file, keyed by file name.
    $hashes = @{}
    foreach ($file in @(Get-ChildItem -Path $env:BACKUPDR_SIM_STATE -Filter '*.json' -File)) {
        $hashes[$file.Name] = (Get-FileHash -Path $file.FullName -Algorithm SHA256).Hash
    }
    $hashes
}

function Initialize-DrRun {
    param([datetime]$Now)
    $dir = Join-Path $TestDrive ('sim-' + [guid]::NewGuid().ToString('N'))
    New-SimState -Anchor $Now -Path $dir | Out-Null
    $env:BACKUPDR_SIM_NOW = $Now.ToString('o')
}

function Invoke-DrScript {
    # Runs disaster_recovery.ps1 in a child pwsh process; returns exit code, output and run log.
    param([string]$Action, [datetime]$Now, [switch]$Force)

    $runLogPath = Join-Path $TestDrive ('dr-run-' + [guid]::NewGuid().ToString('N') + '.json')
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-File', $script:DrScriptPath,
        '-Action', $Action,
        '-Now', $Now.ToString('yyyy-MM-ddTHH:mm:ss'),
        '-RunLogPath', $runLogPath
    )
    if ($Force) { $arguments += '-Force' }

    $output = & pwsh @arguments 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $runLog = $null
    if (Test-Path -Path $runLogPath -PathType Leaf) {
        $runLog = Get-Content -Path $runLogPath -Raw | ConvertFrom-Json
    }
    [pscustomobject]@{
        ExitCode   = $exitCode
        Output     = $output
        RunLogPath = $runLogPath
        RunLog     = $runLog
    }
}

function Get-AppRecordIp {
    $zone = @((Read-SimFile 'dns').zones | Where-Object { $_.name -eq 'example.local' })[0]
    @($zone.records | Where-Object { $_.hostName -eq 'app' -and $_.recordType -eq 'A' } |
        ForEach-Object { [string]$_.ipv4Address })
}

Describe 'disaster_recovery.ps1 against the simulators' -Tag 'Integration' {
    $now = [datetime]'2019-02-17T02:00:00'

    BeforeAll {
        $script:saved = @{}
        foreach ($name in 'BACKUPDR_PROVIDER', 'BACKUPDR_SIM_STATE', 'BACKUPDR_SIM_NOW', 'BACKUPDR_SMTP_SERVER', 'BACKUPDR_SMTP_PORT') {
            $script:saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
        }
        $env:BACKUPDR_PROVIDER = 'simulator'
        $env:BACKUPDR_SMTP_SERVER = 'mailhog'
        $env:BACKUPDR_SMTP_PORT = '1025'
        Wait-MailHog
    }

    AfterAll {
        foreach ($name in $script:saved.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $script:saved[$name])
        }
    }

    BeforeEach {
        Clear-MailHog
    }

    It 'runs -Action test with exit code 0 and leaves every state file byte-identical' {
        Initialize-DrRun -Now $now
        $before = Get-SimFileHash

        $run = Invoke-DrScript -Action 'test' -Now $now

        $run.ExitCode | Should -Be 0
        $after = Get-SimFileHash
        $after.Keys.Count | Should -Be 3
        foreach ($name in $before.Keys) {
            $after[$name] | Should -Be $before[$name]
        }
        $run.RunLog.Action | Should -Be 'test'
        $run.RunLog.Success | Should -Be $true
        @($run.RunLog.Steps | Where-Object { $_.Status -ne 'Succeeded' }).Count | Should -Be 0
        @(Get-MailHogMessages).Count | Should -Be 0
    }

    It 'fails over the replica, the ASR plan and DNS with -Force and mails the notification, then fails back' {
        Initialize-DrRun -Now $now

        $failover = Invoke-DrScript -Action 'failover' -Now $now -Force

        $failover.ExitCode | Should -Be 0
        $failover.RunLog.Success | Should -Be $true
        $replica = @((Read-SimFile 'veeam').replicas | Where-Object { $_.name -eq 'prod-db-01_replica' })[0]
        $replica.state | Should -Be 'Failover'
        $azure = Read-SimFile 'azure'
        @($azure.recoveryPlans | Where-Object { $_.name -eq 'rp-primary' })[0].currentSite | Should -Be 'Recovery'
        $jobs = @($azure.jobs)
        $jobs.Count | Should -Be 1
        $jobs[0].displayName | Should -Be 'Unplanned failover'
        $jobs[0].targetObjectName | Should -Be 'rp-primary'
        $jobs[0].state | Should -Be 'Succeeded'
        ([datetime]$jobs[0].startTime) | Should -Be $now
        Get-AppRecordIp | Should -Be @('10.20.0.10')

        $messages = @(Get-MailHogMessages)
        $messages.Count | Should -Be 1
        $messages[0].Subject | Should -Be 'DR failover: Primary-Site-To-Azure'
        $messages[0].To | Should -Be @('it-admin@example.local')

        Clear-MailHog
        $failback = Invoke-DrScript -Action 'failback' -Now $now -Force

        $failback.ExitCode | Should -Be 0
        $failback.RunLog.Success | Should -Be $true
        Get-AppRecordIp | Should -Be @('10.10.0.10')
        $azure = Read-SimFile 'azure'
        @($azure.recoveryPlans | Where-Object { $_.name -eq 'rp-primary' })[0].currentSite | Should -Be 'Primary'
        $jobs = @($azure.jobs)
        $jobs.Count | Should -Be 2
        $jobs[1].displayName | Should -Be 'Planned failover'
        $jobs[1].targetObjectName | Should -Be 'rp-primary'
        $failback.RunLog.Steps[1].Type | Should -Be 'azure_failover'
        $failback.RunLog.Steps[1].Message | Should -Match 'RecoveryToPrimary'
        @((Read-SimFile 'veeam').replicas)[0].state | Should -Be 'Ready'
        @(Get-MailHogMessages | ForEach-Object { $_.Subject }) | Should -Be @('DR failback: Primary-Site-To-Azure')
    }

    It 'exits 1 when the replica is missing and reports the later steps as NotRun' {
        Initialize-DrRun -Now $now
        $veeam = Read-SimFile 'veeam'
        $veeam.replicas = @()
        Write-SimFile 'veeam' $veeam

        $run = Invoke-DrScript -Action 'failover' -Now $now -Force

        $run.ExitCode | Should -Be 1
        $run.RunLog.Success | Should -Be $false
        $steps = @($run.RunLog.Steps)
        $steps.Count | Should -Be 4
        $steps[0].Status | Should -Be 'Failed'
        $steps[0].Message | Should -Match 'prod-db-01_replica'
        @($steps[1..3] | ForEach-Object { $_.Status }) | Should -Be @('NotRun', 'NotRun', 'NotRun')
        Get-AppRecordIp | Should -Be @('10.10.0.10')
        @((Read-SimFile 'azure').jobs).Count | Should -Be 0
    }

    It 'exits 1 on -Action test when the DNS zone is missing and names the zone in the pre-flight result' {
        Initialize-DrRun -Now $now
        $dns = Read-SimFile 'dns'
        $dns.zones = @()
        Write-SimFile 'dns' $dns

        $run = Invoke-DrScript -Action 'test' -Now $now

        $run.ExitCode | Should -Be 1
        $dnsStep = @($run.RunLog.Steps | Where-Object { $_.Type -eq 'dns_update' })[0]
        $dnsStep.Status | Should -Be 'Failed'
        $dnsStep.Message | Should -Match 'example\.local'
        $run.Output | Should -Match 'example\.local'
    }

    It 'refuses to fail over without -Force when it cannot ask for confirmation' {
        Initialize-DrRun -Now $now
        $before = Get-SimFileHash

        $run = Invoke-DrScript -Action 'failover' -Now $now

        $run.ExitCode | Should -Be 1
        $after = Get-SimFileHash
        foreach ($name in $before.Keys) {
            $after[$name] | Should -Be $before[$name]
        }
        Test-Path -Path $run.RunLogPath | Should -Be $false
        $run.Output | Should -Match 'use -Force for unattended runs'
    }
}
