# DnsSim: functions named after the Windows DnsServer module cmdlets the toolkit
# calls, backed by a JSON state file instead of a DNS server.
#
# State file:  $env:BACKUPDR_SIM_STATE/dns.json (zones, each with A records).
#              When BACKUPDR_SIM_STATE is not set, every sim/state/*.sample.json is
#              copied to a new temp directory on first use.
#
# Errors follow the real cmdlets: a missing zone, a lookup of a name with no
# records (category ObjectNotFound), adding a duplicate record and removing a
# record that does not exist all throw. Only A records are modelled.

$script:SampleDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'state'
$script:Culture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-SimNow {
    if ($env:BACKUPDR_SIM_NOW) {
        return [datetime]::Parse($env:BACKUPDR_SIM_NOW, $script:Culture, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    Get-Date
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
    $path = Join-Path $env:BACKUPDR_SIM_STATE 'dns.json'
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        throw "DnsSim state file not found: $path"
    }
    $path
}

function Read-SimState {
    $state = Get-Content -Path (Get-SimStatePath) -Raw | ConvertFrom-Json
    if (-not ($state.PSObject.Properties.Name -contains 'zones')) {
        $state | Add-Member -MemberType NoteProperty -Name zones -Value @()
    }
    foreach ($zone in @($state.zones)) {
        if (-not ($zone.PSObject.Properties.Name -contains 'records') -or $null -eq $zone.records) {
            $zone | Add-Member -MemberType NoteProperty -Name records -Value @() -Force
        }
    }
    $state
}

function Save-SimState {
    param($State)
    $State | ConvertTo-Json -Depth 10 | Set-Content -Path (Get-SimStatePath) -Encoding UTF8
}

function Get-SimServerName {
    [System.Environment]::MachineName
}

function Get-SimZone {
    param($State, [string]$ZoneName)
    $zone = @($State.zones | Where-Object { $_.name -eq $ZoneName })[0]
    if (-not $zone) {
        throw "Failed to get the zone information for $ZoneName on server $(Get-SimServerName)."
    }
    $zone
}

function ConvertTo-SimRecord {
    param($Record, [string]$ZoneName)
    $ttl = '01:00:00'
    if ($Record.PSObject.Properties.Name -contains 'timeToLive' -and $Record.timeToLive) { $ttl = [string]$Record.timeToLive }
    [pscustomobject]@{
        PSTypeName        = 'DnsSim.ResourceRecord'
        HostName          = [string]$Record.hostName
        RecordType        = [string]$Record.recordType
        RecordClass       = 'IN'
        TimeToLive        = [timespan]::Parse($ttl, $script:Culture)
        DistinguishedName = "DC=$($Record.hostName),DC=$ZoneName,cn=MicrosoftDNS,DC=DomainDnsZones"
        RecordData        = [pscustomobject]@{
            IPv4Address = [System.Net.IPAddress]::Parse([string]$Record.ipv4Address)
        }
    }
}

function Get-DnsServerZone {
    [CmdletBinding()]
    param(
        [string]$Name,
        [string]$ComputerName
    )
    $state = Read-SimState
    $zones = @($state.zones)
    if ($Name) { $zones = @(Get-SimZone -State $state -ZoneName $Name) }
    foreach ($zone in $zones) {
        [pscustomobject]@{
            PSTypeName          = 'DnsSim.Zone'
            ZoneName            = [string]$zone.name
            ZoneType            = [string]$zone.zoneType
            IsDsIntegrated      = [bool]$zone.isDsIntegrated
            IsReverseLookupZone = $false
            IsAutoCreated       = $false
        }
    }
}

function Get-DnsServerResourceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [string]$Name,
        [string]$RRType,
        [string]$ComputerName
    )
    $state = Read-SimState
    $zone = Get-SimZone -State $state -ZoneName $ZoneName
    $records = @($zone.records)
    if ($Name) { $records = @($records | Where-Object { $_.hostName -eq $Name }) }
    if ($RRType) { $records = @($records | Where-Object { $_.recordType -eq $RRType }) }
    if ($Name -and $records.Count -eq 0) {
        # Like the real cmdlet, a name without records is an ObjectNotFound error.
        $exception = New-Object System.Exception "Failed to get $Name record in $ZoneName zone on server $(Get-SimServerName)."
        $errorRecord = New-Object System.Management.Automation.ErrorRecord @(
            $exception, 'WIN32 9714,Get-DnsServerResourceRecord',
            [System.Management.Automation.ErrorCategory]::ObjectNotFound, $Name)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
    foreach ($record in $records) {
        ConvertTo-SimRecord -Record $record -ZoneName $ZoneName
    }
}

function Add-DnsServerResourceRecordA {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$IPv4Address,
        [timespan]$TimeToLive = [timespan]::FromHours(1),
        [switch]$CreatePtr,
        [switch]$AllowUpdateAny,
        [switch]$PassThru,
        [string]$ComputerName
    )
    $state = Read-SimState
    $zone = Get-SimZone -State $state -ZoneName $ZoneName
    foreach ($address in $IPv4Address) {
        $parsed = [System.Net.IPAddress]::Parse($address).ToString()
        $existing = @($zone.records | Where-Object {
            $_.hostName -eq $Name -and $_.recordType -eq 'A' -and $_.ipv4Address -eq $parsed
        })
        if ($existing.Count -gt 0) {
            throw "Failed to create resource record $Name in $ZoneName zone on server $(Get-SimServerName): the record already exists."
        }
        $record = [pscustomobject]@{
            hostName    = $Name
            recordType  = 'A'
            ipv4Address = $parsed
            timeToLive  = $TimeToLive.ToString()
        }
        $zone.records = @($zone.records) + $record
        Save-SimState $state
        if ($PassThru) { ConvertTo-SimRecord -Record $record -ZoneName $ZoneName }
    }
}

function Remove-DnsServerResourceRecord {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)][string]$ZoneName,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$RRType,
        [string]$RecordData,
        [switch]$Force,
        [string]$ComputerName
    )
    $state = Read-SimState
    $zone = Get-SimZone -State $state -ZoneName $ZoneName
    $isMatch = {
        param($Record)
        $Record.hostName -eq $Name -and $Record.recordType -eq $RRType -and
            (-not $RecordData -or $Record.ipv4Address -eq $RecordData)
    }
    $matched = @($zone.records | Where-Object { & $isMatch $_ })
    if ($matched.Count -eq 0) {
        throw "Failed to find any resource record with name $Name and type $RRType in $ZoneName zone on server $(Get-SimServerName)."
    }
    if ($Force -or $PSCmdlet.ShouldProcess("$Name.$ZoneName", "Remove $RRType record")) {
        $zone.records = @($zone.records | Where-Object { -not (& $isMatch $_) })
        Save-SimState $state
    }
}

Export-ModuleMember -Function @(
    'Get-DnsServerZone', 'Get-DnsServerResourceRecord',
    'Add-DnsServerResourceRecordA', 'Remove-DnsServerResourceRecord'
)
