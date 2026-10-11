# VeeamSim: functions named after the Veeam Backup & Replication 9.5 cmdlets the
# toolkit calls, backed by a JSON state file instead of a Veeam server.
#
# State file:  $env:BACKUPDR_SIM_STATE/veeam.json. When BACKUPDR_SIM_STATE is not
#              set, sim/state/veeam.sample.json is copied to a new temp directory
#              (relative offsets resolved against the simulator clock) on first use.
# Clock:       $env:BACKUPDR_SIM_NOW (ISO 8601) when set, else Get-Date.

$script:SampleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'state'
$script:TimeFormat = 'yyyy-MM-ddTHH:mm:ss'
$script:Culture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-SimNow {
    if ($env:BACKUPDR_SIM_NOW) {
        return [datetime]::Parse($env:BACKUPDR_SIM_NOW, $script:Culture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    Get-Date
}

function ConvertTo-SimTime {
    param($Value)
    if ($null -eq $Value -or $Value -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value }
    [datetime]::Parse([string]$Value, $script:Culture, [System.Globalization.DateTimeStyles]::RoundtripKind)
}

function Format-SimTime {
    param([datetime]$Value)
    $Value.ToString($script:TimeFormat, $script:Culture)
}

function Resolve-SimOffsetText {
    # Rewrites quoted offsets such as "-26h" to absolute times relative to Anchor.
    param([string]$Text, [datetime]$Anchor)
    $evaluator = {
        param($m)
        $amount = [int]$m.Groups[2].Value
        if ($m.Groups[1].Value -eq '-') { $amount = -$amount }
        switch ($m.Groups[3].Value) {
            's' { $when = $Anchor.AddSeconds($amount) }
            'm' { $when = $Anchor.AddMinutes($amount) }
            'h' { $when = $Anchor.AddHours($amount) }
            'd' { $when = $Anchor.AddDays($amount) }
        }
        '"' + $when.ToString('yyyy-MM-ddTHH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture) + '"'
    }.GetNewClosure()
    [regex]::Replace($Text, '"([+-])(\d+)([smhd])"', $evaluator)
}

function Get-SimStatePath {
    if (-not $env:BACKUPDR_SIM_STATE) {
        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('backupdr-sim-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $now = Get-SimNow
        foreach ($sample in @(Get-ChildItem -Path $script:SampleDir -Filter '*.sample.json' -File)) {
            $text = Resolve-SimOffsetText -Text (Get-Content -Path $sample.FullName -Raw) -Anchor $now
            $target = Join-Path $dir ($sample.Name -replace '\.sample\.json$', '.json')
            Set-Content -Path $target -Value $text -Encoding UTF8
        }
        $env:BACKUPDR_SIM_STATE = $dir
    }
    $path = Join-Path $env:BACKUPDR_SIM_STATE 'veeam.json'
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        throw "VeeamSim state file not found: $path"
    }
    $path
}

function Read-SimState {
    $state = Get-Content -Path (Get-SimStatePath) -Raw | ConvertFrom-Json
    foreach ($name in @('jobs', 'sessions', 'backups', 'restorePoints', 'replicas', 'repositories')) {
        if (-not ($state.PSObject.Properties.Name -contains $name)) {
            $state | Add-Member -MemberType NoteProperty -Name $name -Value @()
        }
    }
    $state
}

function Save-SimState {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path (Get-SimStatePath) -Encoding UTF8
}

function Get-SimProperty {
    param($Object, [string]$Name, $Default)
    if ($Object.PSObject.Properties.Name -contains $Name -and $null -ne $Object.$Name) {
        return $Object.$Name
    }
    $Default
}

function Test-SimNameMatch {
    param([string]$Value, [string[]]$Name)
    if (-not $Name) { return $true }
    foreach ($n in $Name) {
        if ($Value -like $n) { return $true }
    }
    $false
}

function New-SimSize {
    param([double]$Bytes)
    [pscustomobject]@{
        PSTypeName  = 'VeeamSim.Size'
        InBytes     = [long]$Bytes
        InKilobytes = [long][math]::Floor($Bytes / 1KB)
        InMegabytes = [long][math]::Floor($Bytes / 1MB)
        InGigabytes = [long][math]::Floor($Bytes / 1GB)
    }
}

function ConvertTo-SimSession {
    param($Record)
    [pscustomobject]@{
        PSTypeName   = 'VeeamSim.BackupSession'
        Id           = [string]$Record.id
        Name         = [string]$Record.jobName
        JobName      = [string]$Record.jobName
        State        = [string](Get-SimProperty $Record 'state' 'Stopped')
        Result       = [string](Get-SimProperty $Record 'result' 'None')
        CreationTime = ConvertTo-SimTime $Record.creationTime
        EndTime      = ConvertTo-SimTime (Get-SimProperty $Record 'endTime' $null)
        BackupStats  = [pscustomobject]@{
            DataSize      = [long](Get-SimProperty $Record 'dataSize' 0)
            BackupSize    = [long](Get-SimProperty $Record 'backupSize' 0)
            DedupRatio    = [int](Get-SimProperty $Record 'dedupRatio' 0)
            CompressRatio = [int](Get-SimProperty $Record 'compressRatio' 0)
        }
    }
}

function Get-SimJobSession {
    param([string]$JobName)
    $state = Read-SimState
    @($state.sessions | Where-Object { $_.jobName -eq $JobName }) |
        ForEach-Object { ConvertTo-SimSession $_ }
}

function ConvertTo-SimJob {
    param($Record)
    $job = [pscustomobject]@{
        PSTypeName = 'VeeamSim.Job'
        Id         = [string](Get-SimProperty $Record 'id' $Record.name)
        Name       = [string]$Record.name
        JobType    = [string](Get-SimProperty $Record 'jobType' 'Backup')
        Targets    = @(Get-SimProperty $Record 'targets' @())
    }
    $job | Add-Member -MemberType ScriptMethod -Name GetLastState -Value {
        $name = $this.Name
        $record = @((Read-SimState).jobs | Where-Object { $_.name -eq $name }) | Select-Object -First 1
        if (-not $record) { throw "VeeamSim: job '$name' no longer exists" }
        [string](Get-SimProperty $record 'state' 'Stopped')
    }
    $job | Add-Member -MemberType ScriptMethod -Name FindLastSession -Value {
        Get-SimJobSession -JobName $this.Name | Sort-Object CreationTime | Select-Object -Last 1
    }
    $job
}

function ConvertTo-SimRestorePoint {
    param($Record, [string]$BackupName, [string]$ReplicaName, [string]$VmName)
    [pscustomobject]@{
        PSTypeName   = 'VeeamSim.RestorePoint'
        Id           = [string]$Record.id
        Name         = $VmName
        VmName       = $VmName
        BackupName   = $BackupName
        ReplicaName  = $ReplicaName
        Type         = [string](Get-SimProperty $Record 'type' 'Increment')
        CreationTime = ConvertTo-SimTime $Record.creationTime
    }
}

function Get-VBRJob {
    [CmdletBinding()]
    param([string[]]$Name)
    $state = Read-SimState
    foreach ($record in @($state.jobs)) {
        if (Test-SimNameMatch -Value $record.name -Name $Name) {
            ConvertTo-SimJob $record
        }
    }
}

function Start-VBRJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][object[]]$Job,
        [switch]$FullBackup,
        [switch]$RunAsync
    )
    process {
        foreach ($item in $Job) {
            if ($item -is [string]) { $jobName = $item } else { $jobName = [string]$item.Name }
            $state = Read-SimState
            $record = @($state.jobs | Where-Object { $_.name -eq $jobName }) | Select-Object -First 1
            if (-not $record) { throw "VeeamSim: job '$jobName' not found" }

            # The simulated job runs to completion immediately.
            $now = Format-SimTime (Get-SimNow)
            $last = @($state.sessions | Where-Object { $_.jobName -eq $jobName }) | Select-Object -Last 1
            $session = [pscustomobject]@{
                id            = [guid]::NewGuid().ToString()
                jobName       = $jobName
                state         = 'Stopped'
                result        = [string](Get-SimProperty $record 'nextResult' 'Success')
                creationTime  = $now
                endTime       = $now
                fullBackup    = [bool]$FullBackup
                dataSize      = [long](Get-SimProperty $last 'dataSize' 0)
                backupSize    = [long](Get-SimProperty $last 'backupSize' 0)
                dedupRatio    = [int](Get-SimProperty $last 'dedupRatio' 0)
                compressRatio = [int](Get-SimProperty $last 'compressRatio' 0)
            }
            $state.sessions = @($state.sessions) + $session
            $record.state = 'Stopped'
            Save-SimState $state
            ConvertTo-SimSession $session
        }
    }
}

function Get-VBRBackupSession {
    [CmdletBinding()]
    param([string[]]$Name)
    $state = Read-SimState
    foreach ($record in @($state.sessions)) {
        if (Test-SimNameMatch -Value $record.jobName -Name $Name) {
            ConvertTo-SimSession $record
        }
    }
}

function Get-VBRBackup {
    [CmdletBinding()]
    param([string[]]$Name)
    $state = Read-SimState
    foreach ($record in @($state.backups)) {
        if (Test-SimNameMatch -Value $record.name -Name $Name) {
            [pscustomobject]@{
                PSTypeName   = 'VeeamSim.Backup'
                Name         = [string]$record.name
                JobName      = [string](Get-SimProperty $record 'jobName' $record.name)
                IsReplica    = $false
                CreationTime = ConvertTo-SimTime (Get-SimProperty $record 'creationTime' $null)
            }
        }
    }
}

function Get-VBRReplica {
    [CmdletBinding()]
    param([string[]]$Name)
    $state = Read-SimState
    foreach ($record in @($state.replicas)) {
        if (Test-SimNameMatch -Value $record.name -Name $Name) {
            [pscustomobject]@{
                PSTypeName       = 'VeeamSim.Replica'
                Name             = [string]$record.name
                VmName           = [string]$record.vmName
                IsReplica        = $true
                State            = [string](Get-SimProperty $record 'state' 'Ready')
                LastFailoverTime = ConvertTo-SimTime (Get-SimProperty $record 'lastFailoverTime' $null)
                LastFailbackTime = ConvertTo-SimTime (Get-SimProperty $record 'lastFailbackTime' $null)
            }
        }
    }
}

function Get-VBRRestorePoint {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline = $true)][object[]]$Backup,
        [string[]]$Name
    )
    process {
        $state = Read-SimState
        foreach ($item in @($Backup)) {
            if ($null -eq $item) { continue }
            if ($item.IsReplica) {
                $replica = @($state.replicas | Where-Object { $_.name -eq $item.Name }) | Select-Object -First 1
                if (-not $replica) { continue }
                foreach ($rp in @(Get-SimProperty $replica 'restorePoints' @())) {
                    if (Test-SimNameMatch -Value $replica.vmName -Name $Name) {
                        ConvertTo-SimRestorePoint -Record $rp -ReplicaName $replica.name -VmName $replica.vmName
                    }
                }
            } else {
                foreach ($rp in @($state.restorePoints | Where-Object { $_.backupName -eq $item.Name })) {
                    if (Test-SimNameMatch -Value $rp.vmName -Name $Name) {
                        ConvertTo-SimRestorePoint -Record $rp -BackupName $rp.backupName -VmName $rp.vmName
                    }
                }
            }
        }
    }
}

function Set-SimReplicaState {
    param($RestorePoint, [string]$Operation)
    if (-not $RestorePoint -or -not $RestorePoint.ReplicaName) {
        throw "VeeamSim: $Operation needs a replica restore point"
    }
    $state = Read-SimState
    $replica = @($state.replicas | Where-Object { $_.name -eq $RestorePoint.ReplicaName }) | Select-Object -First 1
    if (-not $replica) { throw "VeeamSim: replica '$($RestorePoint.ReplicaName)' not found" }

    $now = Format-SimTime (Get-SimNow)
    if ($Operation -eq 'Failover') {
        if ($replica.state -ne 'Ready') {
            throw "VeeamSim: replica '$($replica.name)' is in $($replica.state) state, not Ready"
        }
        $replica.state = 'Failover'
        $replica | Add-Member -MemberType NoteProperty -Name lastFailoverTime -Value $now -Force
    } else {
        if ($replica.state -ne 'Failover') {
            throw "VeeamSim: replica '$($replica.name)' is not in Failover state"
        }
        $replica.state = 'Ready'
        $replica | Add-Member -MemberType NoteProperty -Name lastFailbackTime -Value $now -Force
    }
    Save-SimState $state

    $time = ConvertTo-SimTime $now
    [pscustomobject]@{
        PSTypeName   = 'VeeamSim.ReplicaSession'
        Id           = [guid]::NewGuid().ToString()
        Name         = "$($replica.name) $Operation"
        JobName      = [string]$replica.name
        State        = 'Stopped'
        Result       = 'Success'
        CreationTime = $time
        EndTime      = $time
    }
}

function Start-VBRViReplicaFailover {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][object]$RestorePoint,
        [string]$Reason,
        [switch]$RunAsync
    )
    process {
        Set-SimReplicaState -RestorePoint $RestorePoint -Operation 'Failover'
    }
}

function Start-VBRViReplicaFailback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)][object]$RestorePoint,
        [switch]$RunAsync,
        [switch]$PowerOn
    )
    process {
        Set-SimReplicaState -RestorePoint $RestorePoint -Operation 'Failback'
    }
}

function Get-VBRBackupRepository {
    [CmdletBinding()]
    param([string[]]$Name)
    $state = Read-SimState
    foreach ($record in @($state.repositories)) {
        if (Test-SimNameMatch -Value $record.name -Name $Name) {
            $repo = [pscustomobject]@{
                PSTypeName = 'VeeamSim.Repository'
                Name       = [string]$record.name
                Path       = [string](Get-SimProperty $record 'path' '')
            }
            $repo | Add-Member -MemberType ScriptMethod -Name GetContainer -Value {
                $name = $this.Name
                $current = @((Read-SimState).repositories | Where-Object { $_.name -eq $name }) | Select-Object -First 1
                [pscustomobject]@{
                    CachedTotalSpace = New-SimSize -Bytes ([double]$current.totalBytes)
                    CachedFreeSpace  = New-SimSize -Bytes ([double]$current.freeBytes)
                }
            }
            $repo
        }
    }
}

Export-ModuleMember -Function @(
    'Get-VBRJob', 'Start-VBRJob', 'Get-VBRBackupSession', 'Get-VBRBackup',
    'Get-VBRRestorePoint', 'Get-VBRReplica', 'Start-VBRViReplicaFailover',
    'Start-VBRViReplicaFailback', 'Get-VBRBackupRepository'
)
