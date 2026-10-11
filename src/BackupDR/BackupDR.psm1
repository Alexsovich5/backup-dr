# Loads private helpers first, then the public functions listed in BackupDR.psd1.

$script:ModuleRoot = $PSScriptRoot
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

foreach ($folder in @('Private', 'Public')) {
    $folderPath = Join-Path $PSScriptRoot $folder
    if (Test-Path -Path $folderPath -PathType Container) {
        foreach ($file in @(Get-ChildItem -Path $folderPath -Filter '*.ps1' -File | Sort-Object Name)) {
            . $file.FullName
        }
    }
}

$script:LogPath = Join-Path (Join-Path $script:RepoRoot 'logs') 'backupdr.log'

# Make the vendor cmdlets (real snap-in, simulator, or nothing) available to module code.
Import-BackupDRProvider
