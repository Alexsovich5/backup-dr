function Invoke-DnsUpdateStep {
    <#
    .SYNOPSIS
        Runs a dns_update DR step: points an A record at the failover or primary IP.
    .DESCRIPTION
        Checks the zone with Get-DnsServerZone (throws when it is missing), then:
          failover  replaces primaryIp with failoverIp
          failback  replaces failoverIp with primaryIp
          test      only the zone check
        The old address is removed only when the record currently holds it, and the new
        address is added only when it is not already there, so a repeated run is harmless.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Step,

        [Parameter(Mandatory = $true)]
        [ValidateSet('failover', 'failback', 'test')]
        [string]$Action
    )

    $zone = [string]$Step.zone
    $record = [string]$Step.record

    try {
        $zoneInfo = @(Get-DnsServerZone -Name $zone) | Select-Object -First 1
    } catch {
        throw "DNS zone '$zone' not found: $($_.Exception.Message)"
    }
    if (-not $zoneInfo) {
        throw "DNS zone '$zone' not found"
    }

    if ($Action -eq 'test') {
        return "DNS zone '$zone' found; record '$record' would move between $($Step.primaryIp) and $($Step.failoverIp)"
    }

    if ($Action -eq 'failover') {
        $fromIp = [string]$Step.primaryIp
        $toIp = [string]$Step.failoverIp
    } else {
        $fromIp = [string]$Step.failoverIp
        $toIp = [string]$Step.primaryIp
    }

    $current = @()
    try {
        $current = @(Get-DnsServerResourceRecord -ZoneName $zone -Name $record -RRType 'A' |
            ForEach-Object { [string]$_.RecordData.IPv4Address })
    } catch {
        # The real cmdlet throws when the name has no records; treat that as empty.
        $current = @()
    }

    if ($current -contains $fromIp) {
        Remove-DnsServerResourceRecord -ZoneName $zone -Name $record -RRType 'A' -RecordData $fromIp -Force
    }
    if ($current -notcontains $toIp) {
        Add-DnsServerResourceRecordA -ZoneName $zone -Name $record -IPv4Address $toIp
    }

    "DNS $record.$zone now points at $toIp (was $($current -join ', '))"
}
