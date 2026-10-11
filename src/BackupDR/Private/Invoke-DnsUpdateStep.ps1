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
        A record that does not exist yet (ObjectNotFound) counts as holding no address; any
        other error reading it stops the step before anything is changed.
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
        $current = @(Get-DnsServerResourceRecord -ZoneName $zone -Name $record -RRType 'A' -ErrorAction Stop |
            ForEach-Object { [string]$_.RecordData.IPv4Address })
    } catch {
        # The real cmdlet reports a name without records as ObjectNotFound; that means "no
        # address yet". Any other error (access denied, server down) must not be read as
        # empty, or the new address would be added next to the old one.
        if ($_.CategoryInfo.Category -ne [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
            throw "DNS record '$record' in zone '$zone' cannot be read: $($_.Exception.Message)"
        }
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
