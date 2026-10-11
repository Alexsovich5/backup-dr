$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$ShippedPolicy = Join-Path $RepoRoot 'config/backup_policy.json'

Describe 'Test-RetentionCompliance' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'retention.log')
    }

    # A fixed evaluation time far from the wall clock, so any use of Get-Date shows up.
    $now = [datetime]'2019-02-17T02:00:00'

    function New-TestPolicy {
        param(
            [string]$Name = 'Job-A',
            [string[]]$Schedule = @('Daily'),
            [int]$RetentionDays = 14,
            [int]$TimeoutHours = 4,
            $IntervalMinutes = $null
        )
        $job = [ordered]@{
            name          = $Name
            type          = 'incremental'
            schedule      = $Schedule
            timeoutHours  = $TimeoutHours
            retentionDays = $RetentionDays
            targets       = @('vm-*')
        }
        if ($null -ne $IntervalMinutes) { $job.intervalMinutes = $IntervalMinutes }
        [pscustomobject]@{ jobs = @([pscustomobject]$job) }
    }

    function Set-TestPoints {
        param([string]$BackupName = 'Job-A', [datetime[]]$Created)
        $global:BackupDRTestBackupName = $BackupName
        $global:BackupDRTestPoints = @(
            foreach ($time in $Created) {
                [pscustomobject]@{ Name = 'vm-01'; BackupName = $BackupName; CreationTime = $time }
            }
        )
    }

    Context 'restore-point ages' {
        BeforeEach {
            Mock -ModuleName BackupDR Get-VBRBackup {
                [pscustomobject]@{ Name = $global:BackupDRTestBackupName; JobName = $global:BackupDRTestBackupName }
            }
            Mock -ModuleName BackupDR Get-VBRRestorePoint { $global:BackupDRTestPoints }
        }

        It 'is compliant when every point is within retentionDays and the newest is recent' {
            Set-TestPoints -Created @($now.AddDays(-14), $now.AddDays(-7), $now.AddHours(-20))

            $result = @(Test-RetentionCompliance -Policy (New-TestPolicy -RetentionDays 14) -Now $now)

            $result.Count | Should -Be 1
            $result[0].JobName | Should -Be 'Job-A'
            $result[0].Compliant | Should -Be $true
            $result[0].ExpiredPoints | Should -Be 0
            @($result[0].Issues).Count | Should -Be 0
            $result[0].OldestPointAge | Should -Be ([timespan]::FromDays(14))
            $result[0].NewestPointAge | Should -Be ([timespan]::FromHours(20))
        }

        It 'counts a point at retentionDays + 1 as expired and marks the job non-compliant' {
            Set-TestPoints -Created @($now.AddDays(-15), $now.AddDays(-3), $now.AddHours(-20))

            $result = Test-RetentionCompliance -Policy (New-TestPolicy -RetentionDays 14) -Now $now

            $result.ExpiredPoints | Should -Be 1
            $result.Compliant | Should -Be $false
            $result.OldestPointAge | Should -Be ([timespan]::FromDays(15))
            ($result.Issues -join '; ') | Should -Match 'retention'
        }

        It 'flags a Daily job whose newest point is 2 days old' {
            Set-TestPoints -Created @($now.AddDays(-5), $now.AddDays(-2))

            $result = Test-RetentionCompliance -Policy (New-TestPolicy -Schedule 'Daily') -Now $now

            $result.Compliant | Should -Be $false
            $result.ExpiredPoints | Should -Be 0
            $result.NewestPointAge | Should -Be ([timespan]::FromDays(2))
            ($result.Issues -join '; ') | Should -Match 'no recent restore point'
        }

        It 'accepts a weekly job whose newest point is 7 days old' {
            Set-TestPoints -Created @($now.AddDays(-14), $now.AddDays(-7))

            $result = Test-RetentionCompliance -Policy (New-TestPolicy -Schedule 'Sunday' -RetentionDays 90) -Now $now

            $result.Compliant | Should -Be $true
        }

        It 'flags a weekly job whose newest point is 9 days old' {
            Set-TestPoints -Created @($now.AddDays(-9))

            $result = Test-RetentionCompliance -Policy (New-TestPolicy -Schedule 'Sunday' -RetentionDays 90) -Now $now

            $result.Compliant | Should -Be $false
            ($result.Issues -join '; ') | Should -Match 'no recent restore point'
        }

        It 'uses the longest gap between scheduled weekdays' {
            # Monday and Thursday: gaps of 3 and 4 days, so 4 days plus timeoutHours is allowed.
            $policy = New-TestPolicy -Schedule 'Monday', 'Thursday' -RetentionDays 90 -TimeoutHours 4

            Set-TestPoints -Created @($now.AddDays(-4))
            (Test-RetentionCompliance -Policy $policy -Now $now).Compliant | Should -Be $true

            Set-TestPoints -Created @($now.AddDays(-4).AddHours(-5))
            $late = Test-RetentionCompliance -Policy $policy -Now $now
            $late.Compliant | Should -Be $false
            ($late.Issues -join '; ') | Should -Match 'no recent restore point'
        }

        It 'uses intervalMinutes as the expected gap for interval jobs' {
            Set-TestPoints -Created @($now.AddHours(-3))
            $policy = New-TestPolicy -Schedule 'Daily' -IntervalMinutes 60 -TimeoutHours 1

            $stale = Test-RetentionCompliance -Policy $policy -Now $now
            $stale.Compliant | Should -Be $false
            ($stale.Issues -join '; ') | Should -Match 'no recent restore point'

            Set-TestPoints -Created @($now.AddHours(-2))
            $fresh = Test-RetentionCompliance -Policy $policy -Now $now
            $fresh.Compliant | Should -Be $true
        }

        It 'reports a backup with no restore points' {
            Set-TestPoints -Created @()

            $result = Test-RetentionCompliance -Policy (New-TestPolicy) -Now $now

            $result.Compliant | Should -Be $false
            $result.ExpiredPoints | Should -Be 0
            $result.NewestPointAge | Should -BeNullOrEmpty
            ($result.Issues -join '; ') | Should -Match 'no recent restore point'
        }

        It 'computes ages from -Now, not from the wall clock' {
            $later = $now.AddDays(30)
            Set-TestPoints -Created @($later.AddDays(-14), $later.AddHours(-20))

            $result = Test-RetentionCompliance -Policy (New-TestPolicy -RetentionDays 14) -Now $later

            $result.Compliant | Should -Be $true
            $result.ExpiredPoints | Should -Be 0
            $result.NewestPointAge | Should -Be ([timespan]::FromHours(20))
        }

        It 'queries restore points of the job''s backup' {
            Set-TestPoints -Created @($now.AddHours(-1))

            Test-RetentionCompliance -Policy (New-TestPolicy -Name 'Job-A') -Now $now | Out-Null

            Assert-MockCalled -ModuleName BackupDR Get-VBRBackup -Times 1 -Exactly -Scope It -ParameterFilter { $Name -contains 'Job-A' }
            Assert-MockCalled -ModuleName BackupDR Get-VBRRestorePoint -Times 1 -Exactly -Scope It -ParameterFilter {
                @($Backup)[0].Name -eq 'Job-A'
            }
        }
    }

    Context 'missing backup' {
        It 'reports "no backup found" and does not query restore points' {
            Mock -ModuleName BackupDR Get-VBRBackup { }
            Mock -ModuleName BackupDR Get-VBRRestorePoint { throw 'should not be called' }

            $result = Test-RetentionCompliance -Policy (New-TestPolicy -Name 'Job-Missing') -Now $now

            $result.JobName | Should -Be 'Job-Missing'
            $result.Compliant | Should -Be $false
            $result.ExpiredPoints | Should -Be 0
            $result.OldestPointAge | Should -BeNullOrEmpty
            $result.NewestPointAge | Should -BeNullOrEmpty
            ($result.Issues -join '; ') | Should -Match 'no backup found'
            Assert-MockCalled -ModuleName BackupDR Get-VBRRestorePoint -Times 0 -Exactly
        }
    }

    Context 'exact backup lookup' {
        It 'does not audit a backup whose name only starts with the job name' {
            Mock -ModuleName BackupDR Get-VBRBackup { [pscustomobject]@{ Name = 'Job-A-Archive'; JobName = 'Job-A-Archive' } }
            Mock -ModuleName BackupDR Get-VBRRestorePoint { throw 'should not be called' }

            $result = Test-RetentionCompliance -Policy (New-TestPolicy -Name 'Job-A') -Now $now

            $result.Compliant | Should -Be $false
            ($result.Issues -join '; ') | Should -Match 'no backup found'
            Assert-MockCalled -ModuleName BackupDR Get-VBRRestorePoint -Times 0 -Exactly -Scope It
        }

        It 'throws instead of auditing an arbitrary backup when two backups have the job name' {
            Mock -ModuleName BackupDR Get-VBRBackup {
                [pscustomobject]@{ Name = 'Job-A'; JobName = 'Job-A' }
                [pscustomobject]@{ Name = 'Job-A'; JobName = 'Job-A' }
            }
            Mock -ModuleName BackupDR Get-VBRRestorePoint { }

            { Test-RetentionCompliance -Policy (New-TestPolicy -Name 'Job-A') -Now $now } | Should -Throw 'matches 2 objects'
        }
    }

    Context 'shipped policy' {
        It 'returns one result per policy job in policy order' {
            $policy = Get-BackupPolicy -Path $ShippedPolicy
            Mock -ModuleName BackupDR Get-VBRBackup { }

            $result = @(Test-RetentionCompliance -Policy $policy -Now $now)

            ($result | ForEach-Object { $_.JobName }) -join ',' |
                Should -Be (($policy.jobs | ForEach-Object { $_.name }) -join ',')
        }
    }

    AfterAll {
        Remove-Variable -Name BackupDRTestPoints -Scope Global -ErrorAction SilentlyContinue
        Remove-Variable -Name BackupDRTestBackupName -Scope Global -ErrorAction SilentlyContinue
    }
}
