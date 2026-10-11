. (Join-Path $PSScriptRoot '../TestHelpers/New-SimState.ps1')

$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$script:ReplicationScriptPath = Join-Path $script:RepoRoot 'scripts/azure_replication.ps1'

function Read-AzureSimFile {
    Get-Content -Path (Join-Path $env:BACKUPDR_SIM_STATE 'azure.json') -Raw | ConvertFrom-Json
}

function Write-AzureSimFile {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $env:BACKUPDR_SIM_STATE 'azure.json')
}

function Set-AzureSimItem {
    # Changes one protected item in the seeded azure.json.
    param([string]$Name, [string]$Property, $Value)
    $state = Read-AzureSimFile
    $item = @($state.protectedItems | Where-Object { $_.name -eq $Name })[0]
    $item | Add-Member -MemberType NoteProperty -Name $Property -Value $Value -Force
    Write-AzureSimFile $state
}

function Invoke-ReplicationScript {
    # Runs azure_replication.ps1 in a child pwsh process; returns exit code and output lines.
    param([datetime]$Now)
    $arguments = @(
        '-NoProfile', '-NonInteractive', '-File', $script:ReplicationScriptPath,
        '-Now', $Now.ToString('yyyy-MM-ddTHH:mm:ss')
    )
    $lines = @(& pwsh @arguments 2>&1 | ForEach-Object { [string]$_ })
    [pscustomobject]@{
        ExitCode = $LASTEXITCODE
        Lines    = $lines
        Output   = ($lines -join [Environment]::NewLine)
    }
}

function Get-ItemLine {
    param($Run, [string]$Name)
    # The leading comma keeps a single match an array instead of unrolling it to a string.
    , @($Run.Lines | Where-Object { $_ -match "^\s*\S+\s+$([regex]::Escape($Name))\s" })
}

Describe 'azure_replication.ps1 against AzureSim' -Tag 'Integration' {
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

    BeforeEach {
        New-SimState -Anchor $now -Path (Join-Path $TestDrive ('sim-' + [guid]::NewGuid().ToString('N'))) | Out-Null
        $env:BACKUPDR_SIM_NOW = $now.ToString('o')
    }

    It 'prints one line per protected item and exits 0 for the sample state' {
        $run = Invoke-ReplicationScript -Now $now

        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'AZURE REPLICATION OK'
        $web = Get-ItemLine $run 'prod-web-01'
        $web.Count | Should -Be 1
        $web[0] | Should -Match '^OK\s'
        $web[0] | Should -Match 'Normal'
        $web[0] | Should -Match 'rpo=6\.0 min'
        $app = Get-ItemLine $run 'prod-app-01'
        $app.Count | Should -Be 1
        $app[0] | Should -Match 'rpo=7\.0 min'
    }

    It 'exits 1 when one item has an RPO over the plan threshold' {
        Set-AzureSimItem -Name 'prod-app-01' -Property 'rpoInSeconds' -Value 1800

        $run = Invoke-ReplicationScript -Now $now

        $run.ExitCode | Should -Be 1
        $run.Output | Should -Match 'AZURE REPLICATION WARNING'
        (Get-ItemLine $run 'prod-app-01')[0] | Should -Match '^WARNING\s.*rpo=32\.0 min'
        (Get-ItemLine $run 'prod-web-01')[0] | Should -Match '^OK\s'
    }

    It 'exits 2 when an item reports ReplicationHealth Critical' {
        Set-AzureSimItem -Name 'prod-web-01' -Property 'replicationHealth' -Value 'Critical'

        $run = Invoke-ReplicationScript -Now $now

        $run.ExitCode | Should -Be 2
        $run.Output | Should -Match 'AZURE REPLICATION CRITICAL'
        (Get-ItemLine $run 'prod-web-01')[0] | Should -Match '^CRITICAL\s.*Critical'
        (Get-ItemLine $run 'prod-app-01').Count | Should -Be 1
    }

    It 'exits 2 when the vault has no protected items' {
        $state = Read-AzureSimFile
        $state.protectedItems = @()
        Write-AzureSimFile $state

        $run = Invoke-ReplicationScript -Now $now

        $run.ExitCode | Should -Be 2
        $run.Output | Should -Match 'AZURE REPLICATION CRITICAL'
        $run.Output | Should -Match 'no protected items'
    }

    It 'exits 2 and names the plan file when it cannot be loaded' {
        $missing = Join-Path $TestDrive 'missing-plan.json'
        $lines = @(& pwsh -NoProfile -NonInteractive -File $script:ReplicationScriptPath -PlanPath $missing -Now $now.ToString('yyyy-MM-ddTHH:mm:ss') 2>&1 |
            ForEach-Object { [string]$_ })

        $LASTEXITCODE | Should -Be 2
        ($lines -join "`n") | Should -Match 'missing-plan\.json'
    }
}
