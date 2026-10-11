$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/VendorStubs.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'Send-BackupAlert' -Tag 'Unit' {
    BeforeAll {
        $script:logFile = Join-Path $TestDrive 'alert.log'
        Set-BackupLogPath -Path $script:logFile
    }

    function New-Alerting {
        param([bool]$OnFailure = $true, [bool]$OnWarning = $true)
        [pscustomobject]@{
            email          = 'it-admin@example.local'
            from           = 'backup@example.local'
            smtpServer     = 'smtp.example.local'
            smtpPort       = 2525
            alertOnFailure = $OnFailure
            alertOnWarning = $OnWarning
            dailyReport    = $true
        }
    }

    It 'passes relay, port, sender, recipient, subject and body from the alerting block' {
        Mock -ModuleName BackupDR Send-MailMessage { }

        Send-BackupAlert -Alerting (New-Alerting) -Subject 'Backup FAILED: Job-A' -Body 'boom'

        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 1 -Exactly -ParameterFilter {
            $SmtpServer -eq 'smtp.example.local' -and $Port -eq 2525 -and
            $From -eq 'backup@example.local' -and @($To) -contains 'it-admin@example.local' -and
            $Subject -eq 'Backup FAILED: Job-A' -and $Body -eq 'boom' -and -not $BodyAsHtml
        }
    }

    It 'sends an HTML body when -BodyAsHtml is given' {
        Mock -ModuleName BackupDR Send-MailMessage { }

        Send-BackupAlert -Alerting (New-Alerting) -Subject 'Report' -Body '<p>ok</p>' -BodyAsHtml

        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 1 -Exactly -ParameterFilter {
            $BodyAsHtml -and $Subject -eq 'Report'
        }
    }

    It 'uses port 25 when the alerting block has no smtpPort' {
        Mock -ModuleName BackupDR Send-MailMessage { }
        $alerting = New-Alerting
        $alerting.PSObject.Properties.Remove('smtpPort')

        Send-BackupAlert -Alerting $alerting -Subject 'S' -Body 'B'

        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 1 -Exactly -ParameterFilter { $Port -eq 25 }
    }

    It 'logs an SMTP failure instead of throwing' {
        Mock -ModuleName BackupDR Send-MailMessage { throw 'relay refused connection' }

        { Send-BackupAlert -Alerting (New-Alerting) -Subject 'S' -Body 'B' } | Should -Not -Throw

        Get-Content -Path $script:logFile -Raw | Should -Match '\[ERROR\].*relay refused connection'
    }

    It 'logs a warning and sends nothing when no recipient is configured' {
        Mock -ModuleName BackupDR Send-MailMessage { }
        $alerting = New-Alerting
        $alerting.email = ''

        { Send-BackupAlert -Alerting $alerting -Subject 'S' -Body 'B' } | Should -Not -Throw

        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 0 -Exactly
        Get-Content -Path $script:logFile -Raw | Should -Match '\[WARN\].*recipient'
    }

    It 'returns nothing without -PassThru' {
        Mock -ModuleName BackupDR Send-MailMessage { }

        $output = @(Send-BackupAlert -Alerting (New-Alerting) -Subject 'S' -Body 'B')

        $output.Count | Should -Be 0
    }

    It 'returns $true with -PassThru when the mail was handed to the relay' {
        Mock -ModuleName BackupDR Send-MailMessage { }

        Send-BackupAlert -Alerting (New-Alerting) -Subject 'S' -Body 'B' -PassThru | Should -Be $true
    }

    It 'returns $false with -PassThru when the relay fails' {
        Mock -ModuleName BackupDR Send-MailMessage { throw 'relay refused connection' }

        Send-BackupAlert -Alerting (New-Alerting) -Subject 'S' -Body 'B' -PassThru | Should -Be $false
    }

    It 'returns $false with -PassThru when settings are missing' {
        Mock -ModuleName BackupDR Send-MailMessage { }
        $alerting = New-Alerting
        $alerting.smtpServer = ''

        Send-BackupAlert -Alerting $alerting -Subject 'S' -Body 'B' -PassThru | Should -Be $false
    }
}

Describe 'Start-BackupJob alerting' -Tag 'Unit' {
    BeforeAll {
        Set-BackupLogPath -Path (Join-Path $TestDrive 'start-alert.log')
    }

    AfterAll {
        Remove-Variable -Name BackupDRTestVeeamJob -Scope Global -ErrorAction SilentlyContinue
    }

    function New-Alerting {
        param([bool]$OnFailure = $true, [bool]$OnWarning = $true)
        [pscustomobject]@{
            email          = 'it-admin@example.local'
            from           = 'backup@example.local'
            smtpServer     = 'smtp.example.local'
            smtpPort       = 25
            alertOnFailure = $OnFailure
            alertOnWarning = $OnWarning
        }
    }

    $policyJob = [pscustomobject]@{
        name         = 'Alert-Job'
        type         = 'incremental'
        schedule     = @('Daily')
        timeoutHours = 1
    }

    # Fake Veeam job whose session finishes immediately with $Result.
    function Set-FinishedJob {
        param([string]$Result)
        $job = [pscustomobject]@{ Name = 'Alert-Job'; Result = $Result; Launched = $false }
        $job | Add-Member -MemberType ScriptMethod -Name GetLastState -Value { 'Stopped' }
        $job | Add-Member -MemberType ScriptMethod -Name FindLastSession -Value {
            # The job has no earlier session; the new one exists once Start-VBRJob ran.
            if (-not $this.Launched) { return $null }
            [pscustomobject]@{
                Id           = 'new-session'
                State        = 'Stopped'
                Result       = $this.Result
                CreationTime = [datetime]'2019-02-17T02:00:00'
                EndTime      = [datetime]'2019-02-17T02:30:00'
            }
        }
        $global:BackupDRTestVeeamJob = $job
    }

    BeforeEach {
        Mock -ModuleName BackupDR Get-VBRJob { $global:BackupDRTestVeeamJob }
        Mock -ModuleName BackupDR Start-VBRJob { $global:BackupDRTestVeeamJob.Launched = $true }
        Mock -ModuleName BackupDR Start-Sleep { }
        Mock -ModuleName BackupDR Send-MailMessage { }
    }

    It 'sends a failure alert for a Failed session when alertOnFailure is true' {
        Set-FinishedJob -Result 'Failed'

        $outcome = Start-BackupJob -Job $policyJob -PollSeconds 0 -Alerting (New-Alerting)

        $outcome.Result | Should -Be 'Failed'
        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 1 -Exactly -ParameterFilter {
            $Subject -eq 'Backup FAILED: Alert-Job' -and @($To) -contains 'it-admin@example.local'
        }
    }

    It 'suppresses the failure alert when alertOnFailure is false' {
        Set-FinishedJob -Result 'Failed'

        Start-BackupJob -Job $policyJob -PollSeconds 0 -Alerting (New-Alerting -OnFailure $false) | Out-Null

        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 0 -Exactly
    }

    It 'sends a failure alert when Start-VBRJob throws' {
        Set-FinishedJob -Result 'Success'
        Mock -ModuleName BackupDR Start-VBRJob { throw 'license expired' }

        $outcome = Start-BackupJob -Job $policyJob -PollSeconds 0 -Alerting (New-Alerting)

        $outcome.Outcome | Should -Be 'Error'
        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 1 -Exactly -ParameterFilter {
            $Subject -eq 'Backup FAILED: Alert-Job' -and $Body -match 'license expired'
        }
    }

    It 'sends a warning alert for a Warning session when alertOnWarning is true' {
        Set-FinishedJob -Result 'Warning'

        Start-BackupJob -Job $policyJob -PollSeconds 0 -Alerting (New-Alerting) | Out-Null

        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 1 -Exactly -ParameterFilter {
            $Subject -eq 'Backup WARNING: Alert-Job' -and @($To) -contains 'it-admin@example.local'
        }
    }

    It 'suppresses the warning alert when alertOnWarning is false, even with alertOnFailure true' {
        Set-FinishedJob -Result 'Warning'

        Start-BackupJob -Job $policyJob -PollSeconds 0 -Alerting (New-Alerting -OnWarning $false) | Out-Null

        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 0 -Exactly
    }

    It 'sends nothing for a Success session' {
        Set-FinishedJob -Result 'Success'

        Start-BackupJob -Job $policyJob -PollSeconds 0 -Alerting (New-Alerting) | Out-Null

        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 0 -Exactly
    }

    It 'sends nothing when -Alerting is not given' {
        Set-FinishedJob -Result 'Failed'

        Start-BackupJob -Job $policyJob -PollSeconds 0 | Out-Null

        Assert-MockCalled -ModuleName BackupDR Send-MailMessage -Scope It -Times 0 -Exactly
    }

    It 'returns its outcome even when the SMTP relay fails' {
        Set-FinishedJob -Result 'Failed'
        Mock -ModuleName BackupDR Send-MailMessage { throw 'no route to relay' }

        $outcome = Start-BackupJob -Job $policyJob -PollSeconds 0 -Alerting (New-Alerting)

        $outcome.Outcome | Should -Be 'Started'
        $outcome.Result | Should -Be 'Failed'
    }
}
