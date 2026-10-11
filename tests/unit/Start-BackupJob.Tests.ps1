$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'Start-BackupJob' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'start.log')
        $script:savedPollSeconds = $env:BACKUPDR_POLL_SECONDS
    }

    AfterAll {
        $env:BACKUPDR_POLL_SECONDS = $script:savedPollSeconds
        Remove-Variable -Name BackupDRTestVeeamJob -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach {
        $env:BACKUPDR_POLL_SECONDS = $null
    }

    $start = [datetime]'2019-02-17T02:00:00'

    function New-PolicyJob {
        param([double]$TimeoutHours = 1, [string]$Type = 'incremental')
        [pscustomobject]@{
            name         = 'Test-Job'
            type         = $Type
            schedule     = @('Daily')
            timeoutHours = $TimeoutHours
        }
    }

    # Mock bodies run in the BackupDR module scope, so the fake job is handed over through
    # a global variable rather than a test-scope local.
    # Builds a fake Veeam job whose FindLastSession() walks through $States, one entry per
    # call, repeating the last entry once the list is exhausted.
    function New-FakeVeeamJob {
        param(
            [string]$LastState = 'Stopped',
            [string[]]$States = @('Stopped'),
            [string]$Result = 'Success'
        )
        $job = [pscustomobject]@{
            Name      = 'Test-Job'
            LastState = $LastState
            States    = $States
            Result    = $Result
            Calls     = 0
            Started   = $start
        }
        $job | Add-Member -MemberType ScriptMethod -Name GetLastState -Value { $this.LastState }
        $job | Add-Member -MemberType ScriptMethod -Name FindLastSession -Value {
            $index = [math]::Min($this.Calls, $this.States.Count - 1)
            $this.Calls++
            $state = $this.States[$index]
            $result = 'None'
            $end = $null
            if ($state -eq 'Stopped') {
                $result = $this.Result
                $end = $this.Started.AddMinutes(42)
            }
            [pscustomobject]@{
                JobName      = $this.Name
                State        = $state
                Result       = $result
                CreationTime = $this.Started
                EndTime      = $end
            }
        }
        $job
    }

    Context 'before the job is started' {
        It 'returns NotFound and does not start anything when the job does not exist' {
            Mock -ModuleName BackupDR Get-VBRJob { }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            $outcome = Start-BackupJob -Job (New-PolicyJob) -PollSeconds 0

            $outcome.JobName | Should -Be 'Test-Job'
            $outcome.Outcome | Should -Be 'NotFound'
            Assert-MockCalled -ModuleName BackupDR Start-VBRJob -Times 0 -Exactly -Scope It
        }

        It 'returns AlreadyRunning when the job is Working' {
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob -LastState 'Working'
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            $outcome = Start-BackupJob -Job (New-PolicyJob) -PollSeconds 0

            $outcome.Outcome | Should -Be 'AlreadyRunning'
            Assert-MockCalled -ModuleName BackupDR Start-VBRJob -Times 0 -Exactly -Scope It
        }

        It 'returns DryRun with -DryRun and starts nothing' {
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            $outcome = Start-BackupJob -Job (New-PolicyJob) -DryRun -PollSeconds 0

            $outcome.Outcome | Should -Be 'DryRun'
            Assert-MockCalled -ModuleName BackupDR Start-VBRJob -Times 0 -Exactly -Scope It
            Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 0 -Exactly -Scope It
        }

        It 'looks the job up by its policy name' {
            Mock -ModuleName BackupDR Get-VBRJob { }
            Start-BackupJob -Job (New-PolicyJob) -PollSeconds 0 | Out-Null
            Assert-MockCalled -ModuleName BackupDR Get-VBRJob -Times 1 -Exactly -Scope It -ParameterFilter {
                $Name -eq 'Test-Job'
            }
        }
    }

    Context 'waiting for the session' {
        It 'does not sleep when the session has already finished' {
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob -States 'Stopped' -Result 'Success'
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            $outcome = Start-BackupJob -Job (New-PolicyJob) -PollSeconds 30

            $outcome.Outcome | Should -Be 'Started'
            $outcome.Result | Should -Be 'Success'
            $outcome.Duration | Should -Be ([timespan]::FromMinutes(42))
            Assert-MockCalled -ModuleName BackupDR Start-VBRJob -Times 1 -Exactly -Scope It
            Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 0 -Exactly -Scope It
        }

        It 'sleeps once when the session finishes on the second check' {
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob -States 'Working', 'Stopped' -Result 'Success'
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            $outcome = Start-BackupJob -Job (New-PolicyJob) -PollSeconds 30

            $outcome.Outcome | Should -Be 'Started'
            $outcome.Result | Should -Be 'Success'
            Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter {
                $Seconds -eq 30
            }
        }

        It 'reports the session result <Result>' -TestCases @(
            @{ Result = 'Warning' }, @{ Result = 'Failed' }
        ) {
            param($Result)
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob -States 'Stopped' -Result $Result
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            $outcome = Start-BackupJob -Job (New-PolicyJob) -PollSeconds 0

            $outcome.Outcome | Should -Be 'Started'
            $outcome.Result | Should -Be $Result
        }

        It 'times out after maxPolls sleeps when the session stays Working' {
            # 0.01 h = 36 s; 36 / 12 = 3 polls.
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob -States 'Working'
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            $outcome = Start-BackupJob -Job (New-PolicyJob -TimeoutHours 0.01) -PollSeconds 12

            $outcome.Outcome | Should -Be 'Started'
            $outcome.Result | Should -Be 'Timeout'
            Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 3 -Exactly -Scope It
        }

        It 'bounds the loop with PollSeconds 0 instead of spinning forever' {
            # max(PollSeconds, 1) = 1, so 0.001 h = 3.6 s gives ceil(3.6) = 4 polls.
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob -States 'Working'
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            $outcome = Start-BackupJob -Job (New-PolicyJob -TimeoutHours 0.001) -PollSeconds 0

            $outcome.Result | Should -Be 'Timeout'
            Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 4 -Exactly -Scope It -ParameterFilter {
                $Seconds -eq 0
            }
        }

        It 'uses BACKUPDR_POLL_SECONDS when -PollSeconds is omitted' {
            $env:BACKUPDR_POLL_SECONDS = '5'
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob -States 'Working', 'Stopped'
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            Start-BackupJob -Job (New-PolicyJob) | Out-Null

            Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter {
                $Seconds -eq 5
            }
        }

        It 'prefers an explicit -PollSeconds over BACKUPDR_POLL_SECONDS' {
            $env:BACKUPDR_POLL_SECONDS = '5'
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob -States 'Working', 'Stopped'
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            Start-BackupJob -Job (New-PolicyJob) -PollSeconds 7 | Out-Null

            Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter {
                $Seconds -eq 7
            }
        }

        It 'defaults to 60 seconds when neither is set' {
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob -States 'Working', 'Stopped'
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            Start-BackupJob -Job (New-PolicyJob) | Out-Null

            Assert-MockCalled -ModuleName BackupDR Start-Sleep -Times 1 -Exactly -Scope It -ParameterFilter {
                $Seconds -eq 60
            }
        }

        It 'requests a full backup for a full policy job' {
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { }
            Mock -ModuleName BackupDR Start-Sleep { }

            Start-BackupJob -Job (New-PolicyJob -Type 'full') -PollSeconds 0 | Out-Null

            Assert-MockCalled -ModuleName BackupDR Start-VBRJob -Times 1 -Exactly -Scope It -ParameterFilter {
                $FullBackup.IsPresent
            }
        }
    }

    Context 'errors' {
        It 'returns Error with the exception message when Start-VBRJob throws' {
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { throw 'repository offline' }
            Mock -ModuleName BackupDR Start-Sleep { }

            $outcome = Start-BackupJob -Job (New-PolicyJob) -PollSeconds 0

            $outcome.Outcome | Should -Be 'Error'
            $outcome.Message | Should -Match 'repository offline'
        }

        It 'logs the error at ERROR level' {
            Mock -ModuleName BackupDR Write-BackupLog { }
            $global:BackupDRTestVeeamJob = New-FakeVeeamJob
            Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
            Mock -ModuleName BackupDR Start-VBRJob { throw 'repository offline' }

            Start-BackupJob -Job (New-PolicyJob) -PollSeconds 0 | Out-Null

            Assert-MockCalled -ModuleName BackupDR Write-BackupLog -Scope It -ParameterFilter {
                $Level -eq 'ERROR' -and $Message -like '*repository offline*'
            }
        }
    }
}
