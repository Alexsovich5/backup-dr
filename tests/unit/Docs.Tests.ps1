$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
$runbookPath = Join-Path $repoRoot 'docs/runbook.md'

function Get-RunbookReferencedPath {
    # Every scripts/*.ps1 and config/*.json path written in the text, as repo-relative paths.
    param([string]$Text)
    $found = [regex]::Matches($Text, '(?<![\w/.-])(scripts/[\w.-]+\.ps1|config/[\w.-]+\.json)(?![\w/-])')
    @($found | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
}

Describe 'Operations runbook' -Tag 'Unit' {
    It 'exists at docs/runbook.md' {
        Test-Path -Path $runbookPath -PathType Leaf | Should -Be $true
    }

    $text = ''
    if (Test-Path -Path $runbookPath -PathType Leaf) {
        $text = Get-Content -Path $runbookPath -Raw
    }
    $referenced = @(Get-RunbookReferencedPath -Text $text)

    It 'references script and config paths' {
        $referenced.Count | Should -BeGreaterThan 0
    }

    foreach ($path in $referenced) {
        It "references an existing file: $path" -TestCases @{ RelativePath = $path } {
            param($RelativePath)
            Test-Path -Path (Join-Path $repoRoot $RelativePath) -PathType Leaf | Should -Be $true
        }
    }

    $scripts = @(Get-ChildItem -Path (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -File | Sort-Object Name)
    foreach ($script in $scripts) {
        It "mentions scripts/$($script.Name)" -TestCases @{ RelativePath = "scripts/$($script.Name)" } {
            param($RelativePath)
            $referenced | Should -Contain $RelativePath
        }
    }
}

Describe 'Get-RunbookReferencedPath' -Tag 'Unit' {
    It 'finds script and config paths and ignores other directories' {
        $text = 'Run `pwsh scripts/health_check.ps1` with config/backup_policy.json; see out/dr-run.json and sim/state/veeam.sample.json.'
        $paths = @(Get-RunbookReferencedPath -Text $text)
        $paths | Should -Be @('config/backup_policy.json', 'scripts/health_check.ps1')
    }

    It 'reports a missing file so the existence check can fail' {
        $paths = @(Get-RunbookReferencedPath -Text 'pwsh scripts/no_such_script.ps1')
        $paths | Should -Be @('scripts/no_such_script.ps1')
        Test-Path -Path (Join-Path $repoRoot $paths[0]) -PathType Leaf | Should -Be $false
    }
}
