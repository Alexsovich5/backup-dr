$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'Get-BackupServerHealth' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'health.log')
    }

    # A fixed evaluation time far from the wall clock, so any use of Get-Date shows up.
    $now = [datetime]'2019-02-17T02:00:00'

    function New-TestPolicy {
        param([int]$MinFreePercent = 15)
        [pscustomobject]@{
            jobs   = @(
                [pscustomobject]@{
                    name = 'Daily-Job'; type = 'incremental'; schedule = @('Daily')
                    timeoutHours = 4; retentionDays = 30; targets = @('vm-*')
                },
                [pscustomobject]@{
                    name = 'Weekly-Job'; type = 'full'; schedule = @('Sunday')
                    timeoutHours = 8; retentionDays = 90; targets = @('vm-*')
                }
            )
            health = [pscustomobject]@{ repositoryMinFreePercent = $MinFreePercent }
        }
    }

    function New-TestRepository {
        param([string]$Name = 'Repo-1', [double]$TotalBytes = 1000, [double]$FreeBytes = 500)
        $repo = [pscustomobject]@{ Name = $Name; Total = $TotalBytes; Free = $FreeBytes }
        $repo | Add-Member -MemberType ScriptMethod -Name GetContainer -Value {
            [pscustomobject]@{
                CachedTotalSpace = [pscustomobject]@{ InBytes = [long]$this.Total }
                CachedFreeSpace  = [pscustomobject]@{ InBytes = [long]$this.Free }
            }
        }
        $repo
    }

    function New-TestSession {
        param([string]$JobName, [datetime]$Created, [string]$Result = 'Success', [string]$State = 'Stopped')
        [pscustomobject]@{
            JobName = $JobName; Name = $JobName; Result = $Result; State = $State; CreationTime = $Created
        }
    }

    function Get-Check {
        param($Health, [string]$Type, [string]$Name)
        @($Health.Checks | Where-Object { $_.Type -eq $Type -and $_.Name -eq $Name })
    }

    BeforeEach {
        $global:BackupDRTestRepositories = @(New-TestRepository)
        $global:BackupDRTestSessions = @(
            New-TestSession -JobName 'Daily-Job' -Created $now.AddHours(-20)
            New-TestSession -JobName 'Daily-Job' -Created $now.AddHours(-44)
            New-TestSession -JobName 'Weekly-Job' -Created $now.AddDays(-7)
        )
        $global:BackupDRTestRetention = @(
            [pscustomobject]@{ JobName = 'Daily-Job'; Compliant = $true; Issues = @() }
            [pscustomobject]@{ JobName = 'Weekly-Job'; Compliant = $true; Issues = @() }
        )
        Mock -ModuleName BackupDR Get-VBRBackupRepository { $global:BackupDRTestRepositories }
        Mock -ModuleName BackupDR Get-VBRBackupSession {
            @($global:BackupDRTestSessions | Where-Object { $Name -contains $_.JobName })
        }
        Mock -ModuleName BackupDR Test-RetentionCompliance { $global:BackupDRTestRetention }
    }

    AfterAll {
        foreach ($name in 'BackupDRTestRepositories', 'BackupDRTestSessions', 'BackupDRTestRetention') {
            Remove-Variable -Name $name -Scope Global -ErrorAction SilentlyContinue
        }
    }

    It 'is OK with exit code 0 for a healthy server' {
        $health = Get-BackupServerHealth -Policy (New-TestPolicy) -Now $now

        $health.State | Should -Be 'OK'
        $health.ExitCode | Should -Be 0
        @($health.Checks | Where-Object { $_.State -ne 'OK' }).Count | Should -Be 0
        (Get-Check $health 'Repository' 'Repo-1').Count | Should -Be 1
        (Get-Check $health 'LastResult' 'Daily-Job').Count | Should -Be 1
        (Get-Check $health 'Schedule' 'Weekly-Job').Count | Should -Be 1
        (Get-Check $health 'Retention' 'Daily-Job').Count | Should -Be 1
        (Get-Check $health 'Retention' 'Weekly-Job').Count | Should -Be 1
    }

    It 'warns when a repository is below repositoryMinFreePercent' {
        $global:BackupDRTestRepositories = @(New-TestRepository -TotalBytes 1000 -FreeBytes 100)

        $health = Get-BackupServerHealth -Policy (New-TestPolicy -MinFreePercent 15) -Now $now

        $health.State | Should -Be 'WARNING'
        $health.ExitCode | Should -Be 1
        $check = (Get-Check $health 'Repository' 'Repo-1')[0]
        $check.State | Should -Be 'WARNING'
        $check.Message | Should -Match '10(\.0)?% free'
        $check.Message | Should -Match '15'
    }

    It 'accepts a repository exactly at the threshold' {
        $global:BackupDRTestRepositories = @(New-TestRepository -TotalBytes 1000 -FreeBytes 150)

        $health = Get-BackupServerHealth -Policy (New-TestPolicy -MinFreePercent 15) -Now $now

        (Get-Check $health 'Repository' 'Repo-1')[0].State | Should -Be 'OK'
    }

    It 'is CRITICAL with exit code 2 when a last session failed, and the worst state wins' {
        $global:BackupDRTestRepositories = @(New-TestRepository -TotalBytes 1000 -FreeBytes 100)
        $global:BackupDRTestSessions += New-TestSession -JobName 'Daily-Job' -Created $now.AddHours(-2) -Result 'Failed'

        $health = Get-BackupServerHealth -Policy (New-TestPolicy) -Now $now

        $health.State | Should -Be 'CRITICAL'
        $health.ExitCode | Should -Be 2
        (Get-Check $health 'LastResult' 'Daily-Job')[0].State | Should -Be 'CRITICAL'
        (Get-Check $health 'LastResult' 'Daily-Job')[0].Message | Should -Match 'Failed'
        (Get-Check $health 'Repository' 'Repo-1')[0].State | Should -Be 'WARNING'
    }

    It 'warns when the last session ended with Warning' {
        $global:BackupDRTestSessions += New-TestSession -JobName 'Weekly-Job' -Created $now.AddHours(-1) -Result 'Warning'

        $health = Get-BackupServerHealth -Policy (New-TestPolicy) -Now $now

        $health.State | Should -Be 'WARNING'
        (Get-Check $health 'LastResult' 'Weekly-Job')[0].State | Should -Be 'WARNING'
    }

    It 'warns that a daily job last run 3 days before -Now is overdue' {
        $global:BackupDRTestSessions = @(
            New-TestSession -JobName 'Daily-Job' -Created $now.AddDays(-3)
            New-TestSession -JobName 'Weekly-Job' -Created $now.AddDays(-7)
        )

        $health = Get-BackupServerHealth -Policy (New-TestPolicy) -Now $now

        $health.State | Should -Be 'WARNING'
        $health.ExitCode | Should -Be 1
        $check = (Get-Check $health 'Schedule' 'Daily-Job')[0]
        $check.State | Should -Be 'WARNING'
        $check.Message | Should -Match 'overdue'
        (Get-Check $health 'Schedule' 'Weekly-Job')[0].State | Should -Be 'OK'
    }

    It 'warns about a job that has no session' {
        $global:BackupDRTestSessions = @(New-TestSession -JobName 'Daily-Job' -Created $now.AddHours(-20))

        $health = Get-BackupServerHealth -Policy (New-TestPolicy) -Now $now

        $health.State | Should -Be 'WARNING'
        (Get-Check $health 'LastResult' 'Weekly-Job')[0].Message | Should -Match 'no backup session'
    }

    It 'adds a WARNING Retention check carrying the issue text of a non-compliant job' {
        $global:BackupDRTestRetention = @(
            [pscustomobject]@{ JobName = 'Daily-Job'; Compliant = $true; Issues = @() }
            [pscustomobject]@{
                JobName = 'Weekly-Job'; Compliant = $false
                Issues  = @('1 restore point(s) older than retention of 90 days (oldest 92.0 days)')
            }
        )

        $health = Get-BackupServerHealth -Policy (New-TestPolicy) -Now $now

        $health.State | Should -Be 'WARNING'
        $health.ExitCode | Should -Be 1
        $check = (Get-Check $health 'Retention' 'Weekly-Job')[0]
        $check.State | Should -Be 'WARNING'
        $check.Message | Should -Match 'older than retention of 90 days'
        (Get-Check $health 'Retention' 'Daily-Job')[0].State | Should -Be 'OK'
    }

    It 'passes -Now through to Test-RetentionCompliance' {
        Get-BackupServerHealth -Policy (New-TestPolicy) -Now $now | Out-Null

        Assert-MockCalled -ModuleName BackupDR Test-RetentionCompliance -Times 1 -Exactly -Scope It -ParameterFilter {
            $Now -eq [datetime]'2019-02-17T02:00:00'
        }
    }

    It 'is CRITICAL when the repositories cannot be read' {
        Mock -ModuleName BackupDR Get-VBRBackupRepository { throw 'connection refused' }

        $health = Get-BackupServerHealth -Policy (New-TestPolicy) -Now $now

        $health.State | Should -Be 'CRITICAL'
        $health.ExitCode | Should -Be 2
        @($health.Checks | Where-Object { $_.Type -eq 'Repository' })[0].Message | Should -Match 'connection refused'
    }
}
