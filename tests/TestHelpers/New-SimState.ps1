function New-SimState {
    <#
    .SYNOPSIS
        Seeds simulator state files for a test run.
    .DESCRIPTION
        Copies every sim/state/<name>.sample.json (veeam, azure, dns) to <Path>/<name>.json, rewrites each
        relative offset string such as "-26h" or "+1d" to Anchor + offset in ISO 8601
        (yyyy-MM-ddTHH:mm:ss), and points $env:BACKUPDR_SIM_STATE at Path.
        Returns the state directory.
    #>
    param(
        [Parameter(Mandatory = $true)][datetime]$Anchor,
        [string]$Path
    )

    if (-not $Path) {
        if ($TestDrive) {
            $Path = Join-Path $TestDrive 'simstate'
        } else {
            $Path = Join-Path ([System.IO.Path]::GetTempPath()) ('backupdr-sim-' + [guid]::NewGuid().ToString('N'))
        }
    }
    if (-not (Test-Path -Path $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    $Path = (Resolve-Path -Path $Path).ProviderPath

    $sampleDir = Join-Path $PSScriptRoot '../../sim/state'
    $offsetPattern = '"([+-])(\d+)([smhd])"'
    foreach ($sample in @(Get-ChildItem -Path $sampleDir -Filter '*.sample.json' -File)) {
        $text = Get-Content -Path $sample.FullName -Raw
        $text = [regex]::Replace($text, $offsetPattern, {
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
        }.GetNewClosure())
        $target = Join-Path $Path ($sample.Name -replace '\.sample\.json$', '.json')
        Set-Content -Path $target -Value $text -Encoding UTF8
    }

    $env:BACKUPDR_SIM_STATE = $Path
    $Path
}
