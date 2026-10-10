$env:BACKUPDR_PROVIDER = 'none'
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'Set-BackupLogPath' -Tag 'Unit' {
    It 'creates the parent directory of the log file' {
        Test-Path 'TestDrive:\x' | Should -Be $false
        Set-BackupLogPath -Path 'TestDrive:\x\y.log'
        Test-Path 'TestDrive:\x' -PathType Container | Should -Be $true
    }

    It 'stores the resolved file system path' {
        Set-BackupLogPath -Path 'TestDrive:\x\y.log'
        $expected = Join-Path (Join-Path $TestDrive 'x') 'y.log'
        InModuleScope BackupDR { $script:LogPath } | Should -Be $expected
    }

    It 'defaults to logs/backupdr.log under the repository' {
        $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
        Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force
        $expected = Join-Path (Join-Path $repoRoot 'logs') 'backupdr.log'
        InModuleScope BackupDR { $script:LogPath } | Should -Be $expected
    }

    It 'is exported, Write-BackupLog is not' {
        (Get-Command -Module BackupDR).Name | Should -Contain 'Set-BackupLogPath'
        (Get-Command -Module BackupDR).Name | Should -Not -Contain 'Write-BackupLog'
    }
}

Describe 'Write-BackupLog' -Tag 'Unit' {
    BeforeEach {
        $script:logFile = Join-Path $TestDrive ('logs{0}/run.log' -f [guid]::NewGuid().ToString('N'))
        Set-BackupLogPath -Path $script:logFile
    }

    It 'appends a line in the format [yyyy-MM-dd HH:mm:ss] [LEVEL] message' {
        InModuleScope BackupDR { Write-BackupLog -Message 'Starting backup job: Nightly' -Level WARN 6>$null }
        $lines = @(Get-Content -Path $script:logFile)
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match '^\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[WARN\] Starting backup job: Nightly$'
    }

    It 'uses INFO as the default level and appends rather than overwrites' {
        InModuleScope BackupDR {
            Write-BackupLog -Message 'first' 6>$null
            Write-BackupLog -Message 'second' -Level ERROR 6>$null
        }
        $lines = @(Get-Content -Path $script:logFile)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '\] \[INFO\] first$'
        $lines[1] | Should -Match '\] \[ERROR\] second$'
    }

    It 'rejects an unknown level' {
        { InModuleScope BackupDR { Write-BackupLog -Message 'x' -Level DEBUG } } | Should -Throw
    }

    It 'stamps the line with the current time' {
        InModuleScope BackupDR {
            Mock Get-Date { '2019-02-17 02:00:00' } -ParameterFilter { $Format -eq 'yyyy-MM-dd HH:mm:ss' }
            Write-BackupLog -Message 'stamped' 6>$null
        }
        Get-Content -Path $script:logFile | Should -Be '[2019-02-17 02:00:00] [INFO] stamped'
    }

    It 'also writes the line to the host' {
        $hostOutput = InModuleScope BackupDR { Write-BackupLog -Message 'to host' 6>&1 }
        "$hostOutput" | Should -Match '\[INFO\] to host$'
    }
}
