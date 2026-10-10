$env:BACKUPDR_PROVIDER = 'none'
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$ShippedPolicy = Join-Path $RepoRoot 'config/backup_policy.json'
$InvalidPolicy = Join-Path $RepoRoot 'tests/fixtures/policy-invalid.json'

Describe 'Get-BackupPolicy' -Tag 'Unit' {
    BeforeAll {
        $script:savedServer = $env:BACKUPDR_SMTP_SERVER
        $script:savedPort = $env:BACKUPDR_SMTP_PORT
        Set-BackupLogPath -Path (Join-Path $TestDrive 'policy.log')
    }

    AfterAll {
        $env:BACKUPDR_SMTP_SERVER = $script:savedServer
        $env:BACKUPDR_SMTP_PORT = $script:savedPort
    }

    BeforeEach {
        Remove-Item Env:\BACKUPDR_SMTP_SERVER -ErrorAction SilentlyContinue
        Remove-Item Env:\BACKUPDR_SMTP_PORT -ErrorAction SilentlyContinue
    }

    function Write-PolicyFile {
        param([scriptblock]$Change)
        $policy = Get-Content -Path $ShippedPolicy -Raw | ConvertFrom-Json
        & $Change $policy
        $path = Join-Path $TestDrive ('policy{0}.json' -f [guid]::NewGuid().ToString('N'))
        $policy | ConvertTo-Json -Depth 10 | Set-Content -Path $path
        $path
    }

    function Get-ValidationMessage {
        param([string]$Path)
        try {
            Get-BackupPolicy -Path $Path | Out-Null
        } catch {
            return $_.Exception.Message
        }
        throw "Get-BackupPolicy accepted $Path"
    }

    Context 'shipped policy' {
        It 'loads the four jobs from config/backup_policy.json' {
            $policy = Get-BackupPolicy -Path $ShippedPolicy
            @($policy.jobs).Count | Should -Be 4
            $policy.jobs.name | Should -Contain 'Database-Servers-Hourly'
        }

        It 'exposes the alerting and health settings' {
            $policy = Get-BackupPolicy -Path $ShippedPolicy
            $policy.version | Should -Be '1.1'
            $policy.alerting.from | Should -Be 'backup@example.local'
            $policy.alerting.smtpServer | Should -Be 'smtp.example.local'
            $policy.alerting.smtpPort | Should -Be 25
            $policy.health.repositoryMinFreePercent | Should -Be 15
        }
    }

    Context 'environment overrides' {
        It 'replaces smtpServer with BACKUPDR_SMTP_SERVER' {
            $env:BACKUPDR_SMTP_SERVER = 'mailhog'
            $policy = Get-BackupPolicy -Path $ShippedPolicy
            $policy.alerting.smtpServer | Should -Be 'mailhog'
        }

        It 'replaces smtpPort with BACKUPDR_SMTP_PORT as a number' {
            $env:BACKUPDR_SMTP_PORT = '1025'
            $policy = Get-BackupPolicy -Path $ShippedPolicy
            $policy.alerting.smtpPort | Should -Be 1025
            $policy.alerting.smtpPort | Should -BeOfType [int]
        }
    }

    Context 'validation' {
        It 'rejects duplicate job names' {
            $path = Write-PolicyFile { param($p) $p.jobs[1].name = $p.jobs[0].name }
            Get-ValidationMessage $path | Should -Match "duplicate job name 'Production-Servers-Daily'"
        }

        It 'rejects an empty job name' {
            $path = Write-PolicyFile { param($p) $p.jobs[2].name = '' }
            Get-ValidationMessage $path | Should -Match 'jobs\[2\]: name is required'
        }

        It 'rejects an unknown job type' {
            $path = Write-PolicyFile { param($p) $p.jobs[0].type = 'differential' }
            Get-ValidationMessage $path | Should -Match "job 'Production-Servers-Daily': type 'differential' is not one of incremental, full"
        }

        It 'rejects an unknown weekday' {
            $path = Write-PolicyFile { param($p) $p.jobs[1].schedule = @('Sunday', 'Funday') }
            Get-ValidationMessage $path | Should -Match "job 'Production-Servers-Weekly-Full': schedule value 'Funday' is not a weekday name or Daily"
        }

        It 'rejects timeoutHours of 0' {
            $path = Write-PolicyFile { param($p) $p.jobs[0].timeoutHours = 0 }
            Get-ValidationMessage $path | Should -Match "job 'Production-Servers-Daily': timeoutHours must be greater than 0"
        }

        It 'rejects retentionDays below 1' {
            $path = Write-PolicyFile { param($p) $p.jobs[3].retentionDays = 0 }
            Get-ValidationMessage $path | Should -Match "job 'File-Servers-Daily': retentionDays must be at least 1"
        }

        It 'rejects intervalMinutes below 15' {
            $path = Write-PolicyFile { param($p) $p.jobs[2].intervalMinutes = 5 }
            Get-ValidationMessage $path | Should -Match "job 'Database-Servers-Hourly': intervalMinutes must be at least 15"
        }

        It 'reports every problem in one error' {
            $message = Get-ValidationMessage $InvalidPolicy
            $message | Should -Match 'policy-invalid\.json'
            $message | Should -Match "duplicate job name 'Nightly-Files'"
            $message | Should -Match "job 'Archive-Differential': type 'differential'"
            $message | Should -Match "job 'Weekend-Full': schedule value 'Funday'"
            $message | Should -Match "job 'Zero-Timeout': timeoutHours must be greater than 0"
            $message | Should -Match "job 'Too-Frequent': intervalMinutes must be at least 15"
            $message | Should -Match '5 problem\(s\)'
        }

        It 'reports a missing file' {
            { Get-BackupPolicy -Path (Join-Path $TestDrive 'missing.json') } |
                Should -Throw 'Backup policy not found'
        }

        It 'reports a file that is not JSON' {
            $path = Join-Path $TestDrive 'broken.json'
            Set-Content -Path $path -Value '{ "jobs": [ '
            { Get-BackupPolicy -Path $path } | Should -Throw 'is not valid JSON'
        }
    }
}
