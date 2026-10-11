. (Join-Path $PSScriptRoot '../TestHelpers/MailHog.ps1')
. (Join-Path $PSScriptRoot '../TestHelpers/New-SimState.ps1')

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:SchedulerPath = Join-Path $script:RepoRoot 'scripts/backup_scheduler.ps1'
$script:Elapsed = [timespan]::Zero

function Read-VeeamState {
    Get-Content -Path (Join-Path $env:BACKUPDR_SIM_STATE 'veeam.json') -Raw | ConvertFrom-Json
}

function Write-VeeamState {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $env:BACKUPDR_SIM_STATE 'veeam.json')
}

function Initialize-SchedulerRun {
    # Seeds simulator state anchored at -Now and sets the simulator clock to match.
    param([datetime]$Now)
    $dir = Join-Path $TestDrive ('sim-' + [guid]::NewGuid().ToString('N'))
    New-SimState -Anchor $Now -Path $dir | Out-Null
    $env:BACKUPDR_SIM_NOW = $Now.ToString('o')
}

function Invoke-Scheduler {
    # Runs the scheduler in a child pwsh process; returns its exit code, output and file paths.
    param([datetime]$Now, [switch]$DryRun)

    $runDir = Join-Path $TestDrive ('run-' + [guid]::NewGuid().ToString('N'))
    $reportPath = Join-Path $runDir 'report.html'
    $logPath = Join-Path $runDir 'scheduler.log'

    $arguments = @(
        '-NoProfile', '-NonInteractive', '-File', $script:SchedulerPath,
        '-Now', $Now.ToString('yyyy-MM-ddTHH:mm:ss'),
        '-PollSeconds', '0',
        '-ReportPath', $reportPath,
        '-LogPath', $logPath
    )
    if ($DryRun) { $arguments += '-DryRun' }

    $output = $null
    $script:Elapsed += Measure-Command {
        $output = & pwsh @arguments 2>&1 | Out-String
    }
    [pscustomobject]@{
        ExitCode   = $LASTEXITCODE
        Output     = $output
        ReportPath = $reportPath
        LogPath    = $logPath
    }
}

function ConvertFrom-QuotedPrintable {
    # Send-MailMessage encodes HTML bodies as quoted-printable; decode before matching text.
    param([string]$Text)
    $joined = [regex]::Replace($Text, '=\r?\n', '')
    $bytes = New-Object System.Collections.Generic.List[byte]
    $i = 0
    while ($i -lt $joined.Length) {
        if ($joined[$i] -eq '=' -and $i + 2 -lt $joined.Length -and $joined.Substring($i + 1, 2) -match '^[0-9A-Fa-f]{2}$') {
            $bytes.Add([Convert]::ToByte($joined.Substring($i + 1, 2), 16))
            $i += 3
        } else {
            foreach ($b in [System.Text.Encoding]::UTF8.GetBytes([string]$joined[$i])) { $bytes.Add($b) }
            $i++
        }
    }
    [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function Get-JobSession {
    param([string]$JobName)
    @((Read-VeeamState).sessions | Where-Object { $_.jobName -eq $JobName })
}

Describe 'backup_scheduler.ps1 against the simulator' -Tag 'Integration' {
    $sunday = [datetime]'2019-02-17T02:00:00'
    $monday = $sunday.AddDays(1)

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

    It 'runs the weekly full job on a Sunday' {
        Initialize-SchedulerRun -Now $sunday
        $before = (Get-JobSession 'Production-Servers-Weekly-Full').Count

        $run = Invoke-Scheduler -Now $sunday

        $run.ExitCode | Should -Be 0
        $after = Get-JobSession 'Production-Servers-Weekly-Full'
        $after.Count | Should -Be ($before + 1)
        $after[-1].fullBackup | Should -Be $true
    }

    It 'does not run the weekly full job on a Monday' {
        Initialize-SchedulerRun -Now $monday
        $before = (Get-JobSession 'Production-Servers-Weekly-Full').Count

        $run = Invoke-Scheduler -Now $monday

        $run.ExitCode | Should -Be 0
        (Get-JobSession 'Production-Servers-Weekly-Full').Count | Should -Be $before
        (Get-JobSession 'Production-Servers-Daily').Count | Should -Be 3
        Get-Content -Path $run.LogPath -Raw | Should -Match 'Skipping Production-Servers-Weekly-Full'
    }

    It 'runs the hourly job whose last session is two hours old and stamps the new session at -Now' {
        Initialize-SchedulerRun -Now $sunday
        $seeded = Get-JobSession 'Database-Servers-Hourly'
        $latestSeeded = @($seeded | Sort-Object { [datetime]$_.creationTime })[-1]
        ([datetime]$latestSeeded.creationTime) | Should -Be $sunday.AddHours(-2)

        $run = Invoke-Scheduler -Now $sunday

        $run.ExitCode | Should -Be 0
        $sessions = Get-JobSession 'Database-Servers-Hourly'
        $sessions.Count | Should -Be ($seeded.Count + 1)
        ([datetime]$sessions[-1].creationTime) | Should -Be $sunday
    }

    It 'leaves every session count unchanged with -DryRun' {
        Initialize-SchedulerRun -Now $sunday
        $before = (Read-VeeamState).sessions.Count

        $run = Invoke-Scheduler -Now $sunday -DryRun

        $run.ExitCode | Should -Be 0
        (Read-VeeamState).sessions.Count | Should -Be $before
        Get-Content -Path $run.LogPath -Raw | Should -Match 'DRY RUN: would start Production-Servers-Daily'
    }

    It 'exits 1 and mails "Backup FAILED" when a job fails' {
        Initialize-SchedulerRun -Now $sunday
        $state = Read-VeeamState
        ($state.jobs | Where-Object { $_.name -eq 'File-Servers-Daily' }).nextResult = 'Failed'
        Write-VeeamState $state

        $run = Invoke-Scheduler -Now $sunday

        $run.ExitCode | Should -Be 1
        $subjects = @(Get-MailHogMessages | ForEach-Object { $_.Subject })
        $subjects | Should -Contain 'Backup FAILED: File-Servers-Daily'
        @($subjects | Where-Object { $_ -like 'Backup FAILED:*' }).Count | Should -Be 1
    }

    It 'exits 1 and mails "Backup FAILED" when a job stops without a known result' {
        Initialize-SchedulerRun -Now $sunday
        $state = Read-VeeamState
        ($state.jobs | Where-Object { $_.name -eq 'File-Servers-Daily' }).nextResult = 'None'
        Write-VeeamState $state

        $run = Invoke-Scheduler -Now $sunday

        $run.ExitCode | Should -Be 1
        $subjects = @(Get-MailHogMessages | ForEach-Object { $_.Subject })
        $subjects | Should -Contain 'Backup FAILED: File-Servers-Daily'
    }

    It 'writes the report file with one row per policy job and mails the daily report' {
        Initialize-SchedulerRun -Now $sunday

        $run = Invoke-Scheduler -Now $sunday

        $run.ExitCode | Should -Be 0
        Test-Path -Path $run.ReportPath -PathType Leaf | Should -Be $true
        $html = Get-Content -Path $run.ReportPath -Raw
        ([regex]::Matches($html, '<tr><td>')).Count | Should -Be 4
        foreach ($job in 'Production-Servers-Daily', 'Production-Servers-Weekly-Full', 'Database-Servers-Hourly', 'File-Servers-Daily') {
            $html | Should -Match ([regex]::Escape("<td>$job</td>"))
        }

        $messages = @(Get-MailHogMessages)
        $reports = @($messages | Where-Object { $_.Subject -like 'Daily Backup Report*' })
        $reports.Count | Should -Be 1
        $reports[0].To | Should -Be @('it-admin@example.local')
        $body = ConvertFrom-QuotedPrintable $reports[0].Body
        $body | Should -Match ([regex]::Escape('<h1>Daily Backup Report 2019-02-17</h1>'))
        ([regex]::Matches($body, '<tr><td>')).Count | Should -Be 4
        @($messages | Where-Object { $_.Subject -like 'Backup FAILED:*' }).Count | Should -Be 0
    }

    It 'completes every scheduler run in this file in under 60 seconds' {
        $script:Elapsed | Should -BeGreaterThan ([timespan]::Zero)
        $script:Elapsed.TotalSeconds | Should -BeLessThan 60
    }
}
