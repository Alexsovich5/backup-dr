function Resolve-ExactVendorObject {
    <#
    .SYNOPSIS
        Looks a vendor object up by name and returns it only when exactly one has that name.
    .DESCRIPTION
        Veeam and AzureRM Get-* cmdlets treat -Name as a wildcard pattern, and some match more
        loosely than that, so a lookup can return several objects or one with a different name.
        Acting on the first result could start, fail over or audit the wrong job, replica or
        recovery plan. This helper:
          - rejects an empty name and a name containing wildcard characters (* ? [ ]) before
            the lookup runs;
          - keeps only results whose Name equals -Name (case-insensitive, like the vendor names);
          - throws when more than one remains, and when none remains unless -AllowMissing is
            given (then it returns nothing).
        -Lookup receives the name as its only argument and returns the candidate objects.
    .EXAMPLE
        Resolve-ExactVendorObject -Kind 'Veeam replica' -Name $target -Lookup { param($n) Get-VBRReplica -Name $n }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Lookup,

        [switch]$AllowMissing
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        throw "$Kind name is empty"
    }
    if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Name)) {
        throw "$Kind name '$Name' contains wildcard characters (* ? [ ]); use the exact name"
    }

    $found = @(
        & $Lookup $Name | Where-Object {
            $null -ne $_ -and [string]::Equals([string]$_.Name, $Name, [System.StringComparison]::OrdinalIgnoreCase)
        }
    )

    if ($found.Count -gt 1) {
        throw "$Kind name '$Name' matches $($found.Count) objects; refusing to pick one"
    }
    if ($found.Count -eq 0) {
        if ($AllowMissing) { return }
        throw "$Kind '$Name' not found"
    }
    $found[0]
}
