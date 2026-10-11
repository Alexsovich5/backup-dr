$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$ShippedPolicy = Join-Path $RepoRoot 'config/backup_policy.json'

Describe 'Get-BackupJobReport' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'report.log')
    }

    $base = [datetime]'2019-02-17T02:00:00'

    function New-FakeSession {
        param(
            [string]$JobName,
            [datetime]$Created,
            [string]$Result = 'Success',
            [long]$DataSize = 0,
            [int]$DedupRatio = 0
        )
        [pscustomobject]@{
            Name         = $JobName
            JobName      = $JobName
            State        = 'Stopped'
            Result       = $Result
            CreationTime = $Created
            EndTime      = $Created.AddMinutes(30)
            BackupStats  = [pscustomobject]@{ DataSize = $DataSize; DedupRatio = $DedupRatio }
        }
    }

    Context 'session selection' {
        It 'picks the newest session by CreationTime, not the first one returned' {
            $older = New-FakeSession -JobName 'Job-A' -Created $base.AddDays(-2) -Result 'Failed'
            $newest = New-FakeSession -JobName 'Job-A' -Created $base -Result 'Success'
            $middle = New-FakeSession -JobName 'Job-A' -Created $base.AddDays(-1) -Result 'Warning'
            $global:BackupDRTestSessions = @($older, $newest, $middle)
            Mock -ModuleName BackupDR Get-VBRBackupSession { $global:BackupDRTestSessions }

            $report = @(Get-BackupJobReport -JobName 'Job-A')

            $report.Count | Should -Be 1
            $report[0].JobName | Should -Be 'Job-A'
            $report[0].Status | Should -Be 'Success'
            $report[0].StartTime | Should -Be $base
            $report[0].EndTime | Should -Be $base.AddMinutes(30)
        }

        It 'ignores sessions that belong to other jobs' {
            $other = New-FakeSession -JobName 'Job-B' -Created $base.AddHours(1) -Result 'Failed'
            $mine = New-FakeSession -JobName 'Job-A' -Created $base -Result 'Success'
            $global:BackupDRTestSessions = @($other, $mine)
            Mock -ModuleName BackupDR Get-VBRBackupSession { $global:BackupDRTestSessions }

            $report = @(Get-BackupJobReport -JobName 'Job-A')

            $report[0].Status | Should -Be 'Success'
            $report[0].StartTime | Should -Be $base
        }

        It 'reports NoSession for a job without any session' {
            Mock -ModuleName BackupDR Get-VBRBackupSession { }

            $report = @(Get-BackupJobReport -JobName 'Job-Empty')

            $report.Count | Should -Be 1
            $report[0].JobName | Should -Be 'Job-Empty'
            $report[0].Status | Should -Be 'NoSession'
            $report[0].StartTime | Should -BeNullOrEmpty
            $report[0].EndTime | Should -BeNullOrEmpty
        }

        It 'returns one row per requested job in the requested order' {
            $global:BackupDRTestSessions = @(
                (New-FakeSession -JobName 'Job-B' -Created $base -Result 'Warning'),
                (New-FakeSession -JobName 'Job-A' -Created $base -Result 'Success')
            )
            Mock -ModuleName BackupDR Get-VBRBackupSession {
                $global:BackupDRTestSessions | Where-Object { $Name -contains $_.JobName }
            }

            $report = @(Get-BackupJobReport -JobName 'Job-A', 'Job-B', 'Job-C')

            ($report | ForEach-Object { $_.JobName }) -join ',' | Should -Be 'Job-A,Job-B,Job-C'
            ($report | ForEach-Object { $_.Status }) -join ',' | Should -Be 'Success,Warning,NoSession'
        }
    }

    Context 'statistics' {
        It 'maps DataSize and DedupRatio from BackupStats' {
            $global:BackupDRTestSessions = @(
                (New-FakeSession -JobName 'Job-A' -Created $base -DataSize 53687091200 -DedupRatio 37)
            )
            Mock -ModuleName BackupDR Get-VBRBackupSession { $global:BackupDRTestSessions }

            $report = Get-BackupJobReport -JobName 'Job-A'

            $report.DataSize | Should -Be 53687091200
            $report.DedupRatio | Should -Be 37
        }
    }

    Context 'policy selection' {
        It 'verifies only jobs marked verifyAfterBackup in the shipped policy' {
            $policy = Get-BackupPolicy -Path $ShippedPolicy
            Mock -ModuleName BackupDR Get-VBRBackupSession { }

            $report = @(Get-BackupJobReport -Policy $policy)

            $expected = @($policy.jobs | Where-Object { $_.verifyAfterBackup -eq $true } | ForEach-Object { $_.name })
            $expected.Count | Should -Be 3
            ($report | ForEach-Object { $_.JobName }) -join ',' | Should -Be ($expected -join ',')
            foreach ($jobName in $expected) {
                $global:BackupDRTestJobName = $jobName
                Assert-MockCalled -ModuleName BackupDR Get-VBRBackupSession -Times 1 -Exactly -ParameterFilter {
                    $Name -contains $global:BackupDRTestJobName
                }
            }
            Assert-MockCalled -ModuleName BackupDR Get-VBRBackupSession -Times 0 -Exactly -ParameterFilter {
                $Name -contains 'Database-Servers-Hourly'
            }
        }
    }

    AfterAll {
        Remove-Variable -Name BackupDRTestSessions -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BackupDRTestJobName -Scope Global -ErrorAction SilentlyContinue
    }
}
