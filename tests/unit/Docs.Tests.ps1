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

$readmePath = Join-Path $repoRoot 'README.md'

function Get-ReadmeLayoutBlock {
    # Lines of the first fenced block after the '## Layout' heading.
    param([string]$Text)
    $match = [regex]::Match($Text, '(?ms)^## Layout\s*\r?\n\s*```[^\n]*\r?\n(.*?)\r?\n```')
    if (-not $match.Success) { return @() }
    @($match.Groups[1].Value -split '\r?\n')
}

function ConvertTo-LayoutTree {
    # Renders repo-relative file paths as an indented tree: directories end in '/', two spaces per level.
    param([string[]]$Path)
    $sorted = [string[]]@($Path)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    $lines = New-Object System.Collections.Generic.List[string]
    $previous = @()
    foreach ($file in $sorted) {
        $parts = @($file -split '/')
        $dirs = @()
        if ($parts.Count -gt 1) { $dirs = $parts[0..($parts.Count - 2)] }
        $common = 0
        while ($common -lt $dirs.Count -and $common -lt $previous.Count -and $dirs[$common] -ceq $previous[$common]) {
            $common++
        }
        for ($i = $common; $i -lt $dirs.Count; $i++) {
            $lines.Add(('  ' * $i) + $dirs[$i] + '/')
        }
        $lines.Add(('  ' * $dirs.Count) + $parts[-1])
        $previous = $dirs
    }
    @($lines)
}

function ConvertFrom-LayoutTree {
    # Inverse of ConvertTo-LayoutTree: returns the file paths named by the tree lines.
    param([string[]]$Line)
    $stack = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $Line) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $name = $entry.TrimStart(' ')
        $depth = [int](($entry.Length - $name.Length) / 2)
        while ($stack.Count -gt $depth) { $stack.RemoveAt($stack.Count - 1) }
        if ($name.EndsWith('/')) {
            $stack.Add($name.TrimEnd('/'))
        } else {
            (@($stack) + $name) -join '/'
        }
    }
}

Describe 'Layout tree helpers' -Tag 'Unit' {
    It 'renders nested paths with directories before their files' {
        $tree = ConvertTo-LayoutTree -Path @('src/b/x.ps1', 'README.md', 'src/a.ps1', 'Makefile', 'src/b/y.ps1')
        $tree | Should -Be @('Makefile', 'README.md', 'src/', '  a.ps1', '  b/', '    x.ps1', '    y.ps1')
    }

    It 'round-trips a tree back to file paths' {
        $paths = @('a/b/c.txt', 'a/d.txt', 'e.txt')
        @(ConvertFrom-LayoutTree -Line (ConvertTo-LayoutTree -Path $paths)) | Should -Be $paths
    }

    It 'extracts the Layout block from README text' {
        $fence = '`' * 3
        $text = @('# T', '', '## Layout', '', $fence, '.gitignore', 'src/', '  a.ps1', $fence, '', '## Other') -join "`n"
        @(Get-ReadmeLayoutBlock -Text $text) | Should -Be @('.gitignore', 'src/', '  a.ps1')
    }
}

Describe 'README' -Tag 'Unit' {
    $readme = ''
    if (Test-Path -Path $readmePath -PathType Leaf) {
        $readme = Get-Content -Path $readmePath -Raw
    }
    $layout = @(Get-ReadmeLayoutBlock -Text $readme)
    $layoutPaths = @(ConvertFrom-LayoutTree -Line $layout)

    It 'has a Layout block' {
        $layoutPaths.Count | Should -BeGreaterThan 0
    }

    foreach ($path in $layoutPaths) {
        It "lists an existing file in Layout: $path" -TestCases @{ RelativePath = $path } {
            param($RelativePath)
            Test-Path -Path (Join-Path $repoRoot $RelativePath) -PathType Leaf | Should -Be $true
        }
    }

    It 'has a Layout block generated from the repository file list' {
        $files = @(& git -C $repoRoot -c safe.directory=* ls-files --cached --others --exclude-standard)
        $LASTEXITCODE | Should -Be 0
        $files.Count | Should -BeGreaterThan 0
        ($layout -join "`n") | Should -BeExactly ((ConvertTo-LayoutTree -Path $files) -join "`n")
    }

    It 'contains none of the removed portfolio claims' {
        $readme | Should -Not -Match 'Zambaiti|Career Portfolio|Efrem|img\.shields\.io|Status-Complete|Developed during|RPO <|RTO <|100% Backup'
    }

    It 'has no organization or role labels' {
        $readme | Should -Not -CMatch '\*\*Organization\*\*|Organization:|\*\*Role\*\*|Role:'
    }

    It 'states that the vendor systems are simulated' {
        foreach ($name in 'VeeamSim', 'AzureSim', 'DnsSim', 'vSphere', 'Windows DNS', 'Azure Site Recovery') {
            $readme | Should -Match ([regex]::Escape($name))
        }
    }
}
