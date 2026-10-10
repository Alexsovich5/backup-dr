function Test-PolicyNumber {
    <#
    .SYNOPSIS
        Returns $true when a policy value is a JSON number at or above a minimum
        (strictly above it with -Exclusive).
    #>
    param(
        $Value,
        [double]$Minimum,
        [switch]$Exclusive
    )
    if ($null -eq $Value -or $Value -is [bool] -or $Value -is [string]) {
        return $false
    }
    $number = 0.0
    if (-not [double]::TryParse([string]$Value, [System.Globalization.NumberStyles]::Float,
            [System.Globalization.CultureInfo]::InvariantCulture, [ref]$number)) {
        return $false
    }
    if ($Exclusive) { return $number -gt $Minimum }
    $number -ge $Minimum
}
