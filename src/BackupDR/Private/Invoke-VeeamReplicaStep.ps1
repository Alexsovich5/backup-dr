function Invoke-VeeamReplicaStep {
    <#
    .SYNOPSIS
        Runs a veeam_replica DR step: fails the replica over, back, or checks it exists.
    .DESCRIPTION
        Looks up the replica named in the step's target (exact name, exactly one match; see
        Resolve-ExactVendorObject) and its newest restore point.
          failover  Start-VBRViReplicaFailover -RestorePoint <newest>
          failback  Start-VBRViReplicaFailback -RestorePoint <newest>
          test      only the lookups; nothing is changed
        Throws, before anything is changed, when the replica is missing or ambiguous, has no
        restore point, holds restore points of more than one VM, or has two newest restore
        points with the same time. Throws afterwards when the returned session result is not
        Success or Warning. Returns a one-line description of what was done.
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

    $target = [string]$Step.target
    $replica = Resolve-ExactVendorObject -Kind 'Veeam replica' -Name $target -Lookup {
        param($n)
        Get-VBRReplica -Name $n
    }

    $points = @(Get-VBRRestorePoint -Backup $replica | Where-Object { $null -ne $_ -and $null -ne $_.CreationTime })
    if ($points.Count -eq 0) {
        throw "Veeam replica '$target' has no restore point"
    }

    $vmNames = @($points | ForEach-Object { [string]$_.Name } | Sort-Object -Unique)
    if ($vmNames.Count -gt 1) {
        throw "Veeam replica '$target' holds restore points of more than one VM ($($vmNames -join ', ')); refusing to pick one"
    }

    $newestTime = @($points | ForEach-Object { [datetime]$_.CreationTime } | Sort-Object)[-1]
    $newest = @($points | Where-Object { [datetime]$_.CreationTime -eq $newestTime })
    if ($newest.Count -gt 1) {
        throw "Veeam replica '$target' has $($newest.Count) newest restore points at $newestTime; refusing to pick one"
    }
    $point = $newest[0]

    if ($Action -eq 'test') {
        return "Veeam replica '$target' found in state $($replica.State), newest restore point $($point.CreationTime)"
    }

    if ($Action -eq 'failover') {
        $session = Start-VBRViReplicaFailover -RestorePoint $point -Reason 'DR plan failover'
    } else {
        $session = Start-VBRViReplicaFailback -RestorePoint $point
    }

    $result = ''
    $last = @($session) | Where-Object { $null -ne $_ } | Select-Object -Last 1
    if ($null -ne $last) { $result = [string]$last.Result }
    if (@('Success', 'Warning') -notcontains $result) {
        throw "Veeam replica $Action for '$target' finished with result '$result'"
    }
    "Veeam replica '$target' $Action from restore point $($point.CreationTime) (result $result)"
}
