<#
.SYNOPSIS
    Runs PSScriptAnalyzer and the Pester suite inside the test container.
.PARAMETER Tag
    Only run Pester tests with these tags (for example Unit or Integration).
.PARAMETER ExcludeTag
    Skip Pester tests with these tags.
.PARAMETER LintOnly
    Run PSScriptAnalyzer and stop.
#>
[CmdletBinding()]
param(
    [string[]]$Tag,
    [string[]]$ExcludeTag,
    [switch]$LintOnly
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# --- Static analysis -------------------------------------------------------
$settings = Join-Path $repoRoot 'build/PSScriptAnalyzerSettings.psd1'
$lintDirs = @('src', 'scripts', 'sim') | Where-Object { Test-Path (Join-Path $repoRoot $_) -PathType Container }
$findings = @()
foreach ($dir in $lintDirs) {
    $findings += @(Invoke-ScriptAnalyzer -Path (Join-Path $repoRoot $dir) -Recurse -Settings $settings)
}
if ($findings.Count -gt 0) {
    $findings | Format-Table -AutoSize Severity, RuleName, ScriptName, Line, Message | Out-String -Width 200 | Write-Host
}
$errorFindings = @($findings | Where-Object { $_.Severity -eq 'Error' })
Write-Host ("PSScriptAnalyzer: {0} finding(s), {1} error(s) in {2}" -f $findings.Count, $errorFindings.Count, ($lintDirs -join ', '))
if ($errorFindings.Count -gt 0) {
    Write-Host 'PSScriptAnalyzer reported Error-severity findings.' -ForegroundColor Red
    exit 1
}
if ($LintOnly) { exit 0 }

# --- MailHog readiness for integration tests -------------------------------
$integrationDir = Join-Path $repoRoot 'tests/integration'
$hasIntegrationTests = (Test-Path $integrationDir) -and
    @(Get-ChildItem -Path $integrationDir -Recurse -Filter '*.Tests.ps1').Count -gt 0
$integrationSelected = ((-not $Tag) -or ($Tag -contains 'Integration')) -and
    -not ($ExcludeTag -contains 'Integration')

if ($hasIntegrationTests -and $integrationSelected) {
    $mailhogUrl = 'http://mailhog:8025/api/v2/messages'
    $deadline = (Get-Date).AddSeconds(10)
    $ready = $false
    while (-not $ready) {
        try {
            Invoke-RestMethod -Uri $mailhogUrl -TimeoutSec 2 | Out-Null
            $ready = $true
        } catch {
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Milliseconds 500
        }
    }
    if (-not $ready) {
        Write-Host "MailHog did not answer at $mailhogUrl within 10 seconds; integration tests need it (run 'make test', which starts it)." -ForegroundColor Red
        exit 1
    }
}

# --- Pester ----------------------------------------------------------------
$outDir = Join-Path $repoRoot 'out'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$pesterArgs = @{
    Script       = Join-Path $repoRoot 'tests'
    EnableExit   = $true
    OutputFormat = 'NUnitXml'
    OutputFile   = Join-Path $outDir 'testresults.xml'
}
if ($Tag) { $pesterArgs.Tag = $Tag }
if ($ExcludeTag) { $pesterArgs.ExcludeTag = $ExcludeTag }

$srcDir = Join-Path $repoRoot 'src'
if (Test-Path $srcDir) {
    $coverage = @(Get-ChildItem -Path $srcDir -Recurse -Include '*.ps1' | Select-Object -ExpandProperty FullName)
    if ($coverage.Count -gt 0) { $pesterArgs.CodeCoverage = $coverage }
}

Import-Module Pester -RequiredVersion 4.6.0
Invoke-Pester @pesterArgs
