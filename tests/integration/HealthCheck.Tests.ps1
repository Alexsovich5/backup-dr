. (Join-Path $PSScriptRoot '../TestHelpers/New-SimState.ps1')

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:HealthScriptPath = Join-Path $script:RepoRoot 'scripts/health_check.ps1'

function Read-VeeamSimFile {
    Get-Content -Path (Join-Path $env:BACKUPDR_SIM_STATE 'veeam.json') -Raw | ConvertFrom-Json
}

function Write-VeeamSimFile {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $env:BACKUPDR_SIM_STATE 'veeam.json')
}

function Invoke-HealthScript {
    # Runs health_check.ps1 in a child pwsh process; returns exit code and output lines.
    param([datetime]$Now)
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-File', $script:HealthScriptPath,
        '-Now', $Now.ToString('yyyy-MM-ddTHH:mm:ss')
    )
    $lines = @(& pwsh @arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Lines    = $lines
        Output   = ($lines -join [Environment]::NewLine)
    }
}

function Get-SummaryLine {
    param($Run)
    # The leading comma keeps a single match an array instead of unrolling it to a string.
    , @($Run.Lines | Where-Object { $_ -match '^(OK|WARNING|CRITICAL) - \d+ checks, ' })
}

Describe 'health_check.ps1 against VeeamSim' -Tag 'Integration' {
    $now = [datetime]'2019-02-17T02:00:00'

    BeforeAll {
        $script:saved = @{}
        foreach ($name in 'BACKUPDR_PROVIDER', 'BACKUPDR_SIM_STATE', 'BACKUPDR_SIM_NOW') {
            $script:saved[$name] = [System.Environment]::GetEnvironmentVariable($name)
        }
        $env:BACKUPDR_PROVIDER = 'simulator'
    }

    AfterAll {
        foreach ($name in $script:saved.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $script:saved[$name])
        }
    }

    function Initialize-State {
        param([datetime]$Anchor)
        New-SimState -Anchor $Anchor -Path (Join-Path $TestDrive ('sim-' + [guid]::NewGuid().ToString('N'))) | Out-Null
        $env:BACKUPDR_SIM_NOW = $Anchor.ToString('o')
    }

    It 'exits 1 and lists the over-retained weekly restore point in the summary' {
        Initialize-State -Anchor $now

        $run = Invoke-HealthScript -Now $now

        $run.ExitCode | Should -Be 1
        $summary = Get-SummaryLine $run
        $summary.Count | Should -Be 1
        $summary[0] | Should -Match '^WARNING - 13 checks, 1 warnings, 0 critical'
        $summary[0] | Should -Match 'Production-Servers-Weekly-Full'
        $summary[0] | Should -Match 'older than retention of 90 days'
        @($run.Lines | Where-Object { $_ -match '^WARNING\s+Retention\s+Production-Servers-Weekly-Full' }).Count | Should -Be 1
        @($run.Lines | Where-Object { $_ -match '^OK\s+Repository\s+Default Backup Repository' }).Count | Should -Be 1
        @($run.Lines | Where-Object { $_ -match '^OK\s+LastResult\s+Production-Servers-Daily' }).Count | Should -Be 1
    }

    It 'exits 0 once the over-retained restore point is removed' {
        Initialize-State -Anchor $now
        $state = Read-VeeamSimFile
        $state.restorePoints = @($state.restorePoints | Where-Object { $_.id -ne '8e3f6c10-1a2b-4c5d-8e9f-000000000006' })
        Write-VeeamSimFile $state

        $run = Invoke-HealthScript -Now $now

        $run.ExitCode | Should -Be 0
        $summary = Get-SummaryLine $run
        $summary.Count | Should -Be 1
        $summary[0] | Should -Match '^OK - 13 checks, 0 warnings, 0 critical'
        $run.Output | Should -Not -Match 'older than retention'
    }

    It 'gives the same result for a state anchored at another date when -Now is that anchor' {
        $other = [datetime]'2018-06-03T02:00:00'
        Initialize-State -Anchor $other

        $run = Invoke-HealthScript -Now $other

        $run.ExitCode | Should -Be 1
        (Get-SummaryLine $run)[0] | Should -Match '^WARNING - 13 checks, 1 warnings, 0 critical.*Production-Servers-Weekly-Full'
    }

    It 'exits 2 when the last session of a job failed' {
        Initialize-State -Anchor $now
        $state = Read-VeeamSimFile
        $session = @($state.sessions | Where-Object { $_.id -eq '5b0c2a1e-0d7e-4c43-9a51-000000000004' })[0]
        $session.result = 'Failed'
        Write-VeeamSimFile $state

        $run = Invoke-HealthScript -Now $now

        $run.ExitCode | Should -Be 2
        (Get-SummaryLine $run)[0] | Should -Match '^CRITICAL - 13 checks, 1 warnings, 1 critical'
        @($run.Lines | Where-Object { $_ -match '^CRITICAL\s+LastResult\s+File-Servers-Daily' }).Count | Should -Be 1
    }

    It 'exits 2 and names the policy file when it cannot be loaded' {
        Initialize-State -Anchor $now
        $missing = Join-Path $TestDrive 'missing-policy.json'
        $lines = @(& pwsh -NoProfile -NonInteractive -File $script:HealthScriptPath -ConfigPath $missing -Now $now.ToString('yyyy-MM-ddTHH:mm:ss') 2>&1 |
            ForEach-Object { [string]$_ })

        $LASTEXITCODE | Should -Be 2
        ($lines -join "`n") | Should -Match 'missing-policy\.json'
    }
}
