. (Join-Path $PSScriptRoot '../TestHelpers/New-SimState.ps1')
Import-Module (Join-Path $PSScriptRoot '../../sim/VeeamSim') -Force

Describe 'VeeamSim' -Tag 'Unit' {
    $anchor = [datetime]'2019-02-17T02:00:00'

    BeforeAll {
        $script:savedState = $env:BACKUPDR_SIM_STATE
        $script:savedNow = $env:BACKUPDR_SIM_NOW
    }

    AfterAll {
        $env:BACKUPDR_SIM_STATE = $script:savedState
        $env:BACKUPDR_SIM_NOW = $script:savedNow
    }

    BeforeEach {
        $script:stateDir = New-SimState -Anchor $anchor
        $script:stateFile = Join-Path $script:stateDir 'veeam.json'
        $env:BACKUPDR_SIM_NOW = $anchor.ToString('o')
    }

    function Read-State {
        Get-Content -Path $script:stateFile -Raw | ConvertFrom-Json
    }

    function Write-State {
        param($State)
        $State | ConvertTo-Json -Depth 10 | Set-Content -Path $script:stateFile
    }

    Context 'New-SimState' {
        It 'rewrites "-26h" to anchor minus 26 hours in ISO 8601' {
            $sample = Get-Content -Path (Join-Path $PSScriptRoot '../../sim/state/veeam.sample.json') -Raw
            $sample | Should -Match '"creationTime": "-26h"'
            $seeded = Get-Content -Path $script:stateFile -Raw
            $seeded | Should -Match '"creationTime": "2019-02-16T00:00:00"'
            $seeded | Should -Not -Match '"[+-]\d+[smhd]"'
        }

        It 'points BACKUPDR_SIM_STATE at the seeded directory' {
            $env:BACKUPDR_SIM_STATE | Should -Be $script:stateDir
            Test-Path $script:stateFile | Should -Be $true
        }
    }

    Context 'jobs' {
        It 'Get-VBRJob -Name returns the job and GetLastState() is Stopped' {
            $job = Get-VBRJob -Name 'Production-Servers-Daily'
            @($job).Count | Should -Be 1
            $job.Name | Should -Be 'Production-Servers-Daily'
            $job.GetLastState() | Should -Be 'Stopped'
        }

        It 'Get-VBRJob without -Name returns every job in state' {
            @(Get-VBRJob).Count | Should -Be 4
        }

        It 'Get-VBRJob returns nothing for an unknown job' {
            Get-VBRJob -Name 'No-Such-Job' | Should -BeNullOrEmpty
        }

        It 'GetLastState() reflects the state file at call time' {
            $job = Get-VBRJob -Name 'File-Servers-Daily'
            $state = Read-State
            ($state.jobs | Where-Object { $_.name -eq 'File-Servers-Daily' }).state = 'Working'
            Write-State $state
            $job.GetLastState() | Should -Be 'Working'
        }

        It 'FindLastSession() returns the newest seeded session' {
            $session = (Get-VBRJob -Name 'Database-Servers-Hourly').FindLastSession()
            $session.JobName | Should -Be 'Database-Servers-Hourly'
            $session.CreationTime | Should -Be $anchor.AddHours(-2)
            $session.Result | Should -Be 'Success'
            $session.State | Should -Be 'Stopped'
        }
    }

    Context 'Start-VBRJob' {
        It 'appends a session with the seeded result stamped with BACKUPDR_SIM_NOW' {
            $state = Read-State
            ($state.jobs | Where-Object { $_.name -eq 'File-Servers-Daily' }).nextResult = 'Failed'
            Write-State $state
            $before = @((Read-State).sessions).Count
            $simNow = $anchor.AddMinutes(7)
            $env:BACKUPDR_SIM_NOW = $simNow.ToString('o')

            $job = Get-VBRJob -Name 'File-Servers-Daily'
            $started = Start-VBRJob -Job $job

            $started.Result | Should -Be 'Failed'
            $started.CreationTime | Should -Be $simNow
            $sessions = @((Read-State).sessions)
            $sessions.Count | Should -Be ($before + 1)
            $last = $sessions[-1]
            $last.jobName | Should -Be 'File-Servers-Daily'
            $last.result | Should -Be 'Failed'
            [datetime]$last.creationTime | Should -Be $simNow

            $found = $job.FindLastSession()
            $found.Id | Should -Be $started.Id
            $found.Result | Should -Be 'Failed'
            $found.CreationTime | Should -Be $simNow
        }

        It 'uses Success when the job has no seeded result' {
            $state = Read-State
            $j = $state.jobs | Where-Object { $_.name -eq 'Production-Servers-Daily' }
            $j.PSObject.Properties.Remove('nextResult')
            Write-State $state
            (Start-VBRJob -Job (Get-VBRJob -Name 'Production-Servers-Daily')).Result | Should -Be 'Success'
        }

        It 'leaves the job Stopped after the session completes' {
            $job = Get-VBRJob -Name 'Production-Servers-Daily'
            Start-VBRJob -Job $job -RunAsync | Out-Null
            $job.GetLastState() | Should -Be 'Stopped'
        }

        It 'Get-VBRBackupSession -Name returns only that job''s sessions' {
            $sessions = @(Get-VBRBackupSession -Name 'Database-Servers-Hourly')
            $sessions.Count | Should -BeGreaterThan 0
            $sessions | ForEach-Object { $_.JobName | Should -Be 'Database-Servers-Hourly' }
            $sessions[0].BackupStats.DedupRatio | Should -BeGreaterThan 0
        }
    }

    Context 'backups and restore points' {
        It 'Get-VBRBackup -Name returns the backup for a job' {
            $backup = Get-VBRBackup -Name 'Production-Servers-Daily'
            $backup.Name | Should -Be 'Production-Servers-Daily'
            $backup.JobName | Should -Be 'Production-Servers-Daily'
        }

        It 'Get-VBRRestorePoint -Backup returns that backup''s points with CreationTime' {
            $backup = Get-VBRBackup -Name 'Production-Servers-Daily'
            $points = @(Get-VBRRestorePoint -Backup $backup)
            $points.Count | Should -BeGreaterThan 0
            $points | ForEach-Object {
                $_.BackupName | Should -Be 'Production-Servers-Daily'
                $_.CreationTime | Should -BeOfType [datetime]
            }
        }
    }

    Context 'replicas' {
        It 'Get-VBRReplica -Name returns the seeded replica in Ready state' {
            $replica = Get-VBRReplica -Name 'prod-db-01_replica'
            $replica.Name | Should -Be 'prod-db-01_replica'
            $replica.State | Should -Be 'Ready'
        }

        It 'failover sets the replica state to Failover and persists it' {
            $point = Get-VBRReplica -Name 'prod-db-01_replica' | Get-VBRRestorePoint |
                Sort-Object CreationTime | Select-Object -Last 1
            $result = Start-VBRViReplicaFailover -RestorePoint $point -Reason 'test'
            $result.Result | Should -Be 'Success'

            (Get-VBRReplica -Name 'prod-db-01_replica').State | Should -Be 'Failover'
            $persisted = (Read-State).replicas | Where-Object { $_.name -eq 'prod-db-01_replica' }
            $persisted.state | Should -Be 'Failover'
            [datetime]$persisted.lastFailoverTime | Should -Be $anchor
        }

        It 'failback returns a failed-over replica to Ready' {
            $point = Get-VBRReplica -Name 'prod-db-01_replica' | Get-VBRRestorePoint | Select-Object -Last 1
            Start-VBRViReplicaFailover -RestorePoint $point | Out-Null
            Start-VBRViReplicaFailback -RestorePoint $point | Out-Null
            ((Read-State).replicas | Where-Object { $_.name -eq 'prod-db-01_replica' }).state | Should -Be 'Ready'
        }

        It 'failback of a replica that is not failed over throws' {
            $point = Get-VBRReplica -Name 'prod-db-01_replica' | Get-VBRRestorePoint | Select-Object -Last 1
            { Start-VBRViReplicaFailback -RestorePoint $point } | Should -Throw 'not in Failover state'
        }
    }

    Context 'repositories' {
        It 'GetContainer() exposes cached total and free space' {
            $repo = @(Get-VBRBackupRepository)[0]
            $container = $repo.GetContainer()
            $container.CachedTotalSpace.InBytes | Should -BeGreaterThan 0
            $container.CachedFreeSpace.InBytes | Should -BeLessThan $container.CachedTotalSpace.InBytes
            $container.CachedFreeSpace.InGigabytes | Should -Be ([math]::Floor($container.CachedFreeSpace.InBytes / 1GB))
        }
    }
}
