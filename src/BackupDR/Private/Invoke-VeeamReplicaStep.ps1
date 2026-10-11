function Invoke-VeeamReplicaStep {
    <#
    .SYNOPSIS
        Runs a veeam_replica DR step: fails the replica over, back, or checks it exists.
    .DESCRIPTION
        Looks up the replica named in the step's target and its newest restore point.
          failover  Start-VBRViReplicaFailover -RestorePoint <newest>
          failback  Start-VBRViReplicaFailback -RestorePoint <newest>
          test      only the lookups; nothing is changed
        Throws when the replica or a restore point is missing, or when the returned
        session result is Failed. Returns a one-line description of what was done.
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
    $replica = @(Get-VBRReplica -Name $target) | Select-Object -First 1
    if (-not $replica) {
        throw "Veeam replica '$target' not found"
    }

    $point = @(Get-VBRRestorePoint -Backup $replica) |
        Where-Object { $null -ne $_ } |
        Sort-Object -Property CreationTime |
        Select-Object -Last 1
    if (-not $point) {
        throw "Veeam replica '$target' has no restore point"
    }

    if ($Action -eq 'test') {
        return "Veeam replica '$target' found in state $($replica.State), newest restore point $($point.CreationTime)"
    }

    if ($Action -eq 'failover') {
        $session = Start-VBRViReplicaFailover -RestorePoint $point -Reason 'DR plan failover'
    } else {
        $session = Start-VBRViReplicaFailback -RestorePoint $point
    }

    $result = [string](@($session) | Select-Object -Last 1).Result
    if ($result -eq 'Failed') {
        throw "Veeam replica $Action for '$target' finished with result Failed"
    }
    "Veeam replica '$target' $Action from restore point $($point.CreationTime) (result $result)"
}
