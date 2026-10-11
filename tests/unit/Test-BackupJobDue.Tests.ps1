$env:BACKUPDR_PROVIDER = 'none'
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'Test-BackupJobDue' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'due.log')
    }

    # 2019-02-17 is a Sunday; the following six days run Monday..Saturday.
    $sunday = [datetime]'2019-02-17T02:00:00'

    function New-TestJob {
        param([string[]]$Schedule, $IntervalMinutes)
        $job = [pscustomobject]@{
            name         = 'Test-Job'
            type         = 'incremental'
            schedule     = $Schedule
            timeoutHours = 1
        }
        if ($null -ne $IntervalMinutes) {
            $job | Add-Member -NotePropertyName intervalMinutes -NotePropertyValue $IntervalMinutes
        }
        $job
    }

    $dayCases = 0..6 | ForEach-Object {
        $date = $sunday.AddDays($_)
        @{ Now = $date; Day = $date.DayOfWeek.ToString(); Expected = ($_ -eq 0) }
    }

    Context 'weekday schedules' {
        It 'treats a Daily job as due on <Day>' -TestCases $dayCases {
            param($Now, $Day)
            Test-BackupJobDue -Job (New-TestJob -Schedule 'Daily') -Now $Now | Should -BeTrue
        }

        It 'treats a Sunday-only job as due=<Expected> on <Day>' -TestCases $dayCases {
            param($Now, $Day, $Expected)
            Test-BackupJobDue -Job (New-TestJob -Schedule 'Sunday') -Now $Now | Should -Be $Expected
        }

        It 'returns a bool' {
            Test-BackupJobDue -Job (New-TestJob -Schedule 'Monday') -Now $sunday | Should -BeOfType [bool]
        }

        It 'matches a job listing several days on any of them' {
            $job = New-TestJob -Schedule 'Sunday', 'Wednesday'
            Test-BackupJobDue -Job $job -Now $sunday | Should -BeTrue
            Test-BackupJobDue -Job $job -Now $sunday.AddDays(3) | Should -BeTrue
            Test-BackupJobDue -Job $job -Now $sunday.AddDays(1) | Should -BeFalse
        }

        It 'compares day names case-insensitively (<Name>)' -TestCases @(
            @{ Name = 'sunday' }, @{ Name = 'SUNDAY' }, @{ Name = 'daily' }, @{ Name = 'DAILY' }
        ) {
            param($Name)
            Test-BackupJobDue -Job (New-TestJob -Schedule $Name) -Now $sunday | Should -BeTrue
        }

        It 'is not due on a scheduled weekday mismatch even with case variants' {
            Test-BackupJobDue -Job (New-TestJob -Schedule 'MONDAY') -Now $sunday | Should -BeFalse
        }
    }

    Context 'interval jobs' {
        $job = New-TestJob -Schedule 'Daily' -IntervalMinutes 60

        It 'is due when there is no previous run' {
            Test-BackupJobDue -Job $job -Now $sunday | Should -BeTrue
        }

        It 'is due when the last run was <Minutes> minutes ago' -TestCases @(
            @{ Minutes = 60 }, @{ Minutes = 61 }, @{ Minutes = 600 }
        ) {
            param($Minutes)
            Test-BackupJobDue -Job $job -Now $sunday -LastRun $sunday.AddMinutes(-$Minutes) | Should -BeTrue
        }

        It 'is not due when the last run was <Minutes> minutes ago' -TestCases @(
            @{ Minutes = 59 }, @{ Minutes = 0 }
        ) {
            param($Minutes)
            Test-BackupJobDue -Job $job -Now $sunday -LastRun $sunday.AddMinutes(-$Minutes) | Should -BeFalse
        }

        It 'is not due on a day outside its schedule even when the interval has elapsed' {
            $mondayJob = New-TestJob -Schedule 'Monday' -IntervalMinutes 60
            Test-BackupJobDue -Job $mondayJob -Now $sunday -LastRun $sunday.AddHours(-5) | Should -BeFalse
        }

        It 'ignores LastRun for a job without intervalMinutes' {
            Test-BackupJobDue -Job (New-TestJob -Schedule 'Daily') -Now $sunday -LastRun $sunday.AddMinutes(-1) |
                Should -BeTrue
        }
    }

    Context 'last run in the future' {
        It 'is not due and logs a WARN when LastRun is after Now' {
            Mock -ModuleName BackupDR Write-BackupLog {}
            $job = New-TestJob -Schedule 'Daily' -IntervalMinutes 60
            Test-BackupJobDue -Job $job -Now $sunday -LastRun $sunday.AddMinutes(5) | Should -BeFalse
            Assert-MockCalled -ModuleName BackupDR Write-BackupLog -Times 1 -Exactly -Scope It -ParameterFilter {
                $Level -eq 'WARN' -and $Message -like '*Test-Job*'
            }
        }

        It 'does not warn for a last run in the past' {
            Mock -ModuleName BackupDR Write-BackupLog {}
            $job = New-TestJob -Schedule 'Daily' -IntervalMinutes 60
            Test-BackupJobDue -Job $job -Now $sunday -LastRun $sunday.AddMinutes(-90) | Out-Null
            Assert-MockCalled -ModuleName BackupDR Write-BackupLog -Times 0 -Exactly -Scope It -ParameterFilter {
                $Level -eq 'WARN'
            }
        }
    }
}
