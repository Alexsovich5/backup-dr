$env:BACKUPDR_PROVIDER = 'none'
. (Join-Path $PSScriptRoot '../TestHelpers/MailHog.ps1')
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'Send-BackupAlert over SMTP' -Tag 'Integration' {
    BeforeAll {
        Wait-MailHog
        Set-BackupLogPath -Path (Join-Path $TestDrive 'smtp.log')
    }

    BeforeEach {
        Clear-MailHog
    }

    $alerting = [pscustomobject]@{
        email          = 'it-admin@example.local'
        from           = 'backup@example.local'
        smtpServer     = 'mailhog'
        smtpPort       = 1025
        alertOnFailure = $true
        alertOnWarning = $true
    }

    It 'delivers one message with the expected subject, sender and recipient' {
        Send-BackupAlert -Alerting $alerting -Subject 'Backup FAILED: Smtp-Test-Job' -Body 'Status: Failed'

        $messages = @(Get-MailHogMessages)
        $messages.Count | Should -Be 1
        $messages[0].Subject | Should -Be 'Backup FAILED: Smtp-Test-Job'
        $messages[0].From | Should -Be 'backup@example.local'
        $messages[0].To | Should -Be @('it-admin@example.local')
        $messages[0].Body | Should -Match 'Status: Failed'
    }

    It 'uses the relay from a policy loaded with the BACKUPDR_SMTP_* overrides' {
        $savedServer = $env:BACKUPDR_SMTP_SERVER
        $savedPort = $env:BACKUPDR_SMTP_PORT
        try {
            $env:BACKUPDR_SMTP_SERVER = 'mailhog'
            $env:BACKUPDR_SMTP_PORT = '1025'
            $policy = Get-BackupPolicy -Path (Join-Path $PSScriptRoot '../../config/backup_policy.json')
        } finally {
            $env:BACKUPDR_SMTP_SERVER = $savedServer
            $env:BACKUPDR_SMTP_PORT = $savedPort
        }

        Send-BackupAlert -Alerting $policy.alerting -Subject 'Backup WARNING: From-Policy' -Body 'Status: Warning'

        $messages = @(Get-MailHogMessages)
        $messages.Count | Should -Be 1
        $messages[0].Subject | Should -Be 'Backup WARNING: From-Policy'
        $messages[0].To | Should -Be @('it-admin@example.local')
    }
}
