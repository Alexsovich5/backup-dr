# Checks that code under src/, scripts/ and sim/ only uses syntax and commands
# available in Windows PowerShell 5.1 (SPEC section 10).

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$CheckedDirs = @('src', 'scripts', 'sim') |
    ForEach-Object { Join-Path $RepoRoot $_ } |
    Where-Object { Test-Path $_ -PathType Container }

# Vendor commands from SPEC 5.5. They are not part of the desktop 5.1 client
# profile, but exist on a Veeam server with AzureRM and DnsServer installed.
$VendorAllowlist = @(
    'Add-PSSnapin',
    'Get-VBRJob', 'Start-VBRJob', 'Get-VBRBackupSession', 'Get-VBRBackup',
    'Get-VBRRestorePoint', 'Get-VBRReplica', 'Start-VBRViReplicaFailover',
    'Start-VBRViReplicaFailback', 'Get-VBRBackupRepository',
    'Get-AzureRmRecoveryServicesVault', 'Set-AzureRmRecoveryServicesAsrVaultContext',
    'Get-AzureRmRecoveryServicesAsrRecoveryPlan',
    'Start-AzureRmRecoveryServicesAsrUnplannedFailoverJob',
    'Start-AzureRmRecoveryServicesAsrPlannedFailoverJob',
    'Get-AzureRmRecoveryServicesAsrJob',
    'Get-AzureRmRecoveryServicesAsrReplicationProtectedItem',
    'Get-DnsServerZone', 'Add-DnsServerResourceRecordA',
    'Remove-DnsServerResourceRecord', 'Get-DnsServerResourceRecord'
)

# Parameters that exist only in PowerShell 6+ on cmdlets 5.1 also has.
$UnsupportedParameterPatterns = @(
    'ConvertFrom-Json[^|]*-AsHashtable',
    'ForEach-Object[^|]*-Parallel'
)

function Get-Desktop51CommandName {
    $module = Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1
    $profilePath = Join-Path $module.ModuleBase 'Settings/desktop-5.1.14393.206-windows.json'
    $platform = Get-Content -Path $profilePath -Raw | ConvertFrom-Json
    foreach ($m in $platform.Modules) {
        foreach ($c in $m.ExportedCommands) { $c.Name }
    }
}

function Get-ScriptFile {
    param([string[]]$Directory)
    if (-not $Directory) { return }
    Get-ChildItem -Path $Directory -Recurse -File -Include '*.ps1', '*.psm1' |
        Select-Object -ExpandProperty FullName
}

function Get-ScriptAst {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    [pscustomobject]@{ Ast = $ast; Errors = @($errors) }
}

function Get-DefinedFunctionName {
    param([string[]]$Path)
    foreach ($p in $Path) {
        $parsed = Get-ScriptAst -Path $p
        $parsed.Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true) | ForEach-Object { $_.Name }
    }
}

function New-AllowedCommandSet {
    param([string[]]$ExtraName)
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(Get-Desktop51CommandName) + $VendorAllowlist + @($ExtraName)) {
        if ($name) { [void]$set.Add($name) }
    }
    , $set
}

function Get-CompatibilityIssue {
    param(
        [string]$Path,
        [System.Collections.Generic.HashSet[string]]$AllowedCommand
    )
    $parsed = Get-ScriptAst -Path $Path
    foreach ($e in $parsed.Errors) {
        "parse error at line $($e.Extent.StartLineNumber): $($e.Message)"
    }

    $commands = $parsed.Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true)
    foreach ($cmd in $commands) {
        $name = $cmd.GetCommandName()
        if ($null -ne $name -and -not $AllowedCommand.Contains($name)) {
            "command not available in Windows PowerShell 5.1 at line $($cmd.Extent.StartLineNumber): $name"
        }
    }

    $lineNumber = 0
    foreach ($line in (Get-Content -Path $Path)) {
        $lineNumber++
        foreach ($pattern in $UnsupportedParameterPatterns) {
            if ($line -imatch $pattern) {
                "parameter not available in Windows PowerShell 5.1 at line ${lineNumber}: $($Matches[0])"
            }
        }
    }
}

$CheckedFiles = @(Get-ScriptFile -Directory $CheckedDirs)
$AllowedCommands = New-AllowedCommandSet -ExtraName @(Get-DefinedFunctionName -Path $CheckedFiles)

Describe 'Windows PowerShell 5.1 compatibility' -Tag 'Unit' {
    Context 'helpers' {
        function Test-Snippet([string]$Code) {
            $file = Join-Path $TestDrive ("snippet{0}.ps1" -f [guid]::NewGuid().ToString('N'))
            Set-Content -Path $file -Value $Code
            $allowed = New-AllowedCommandSet -ExtraName @(Get-DefinedFunctionName -Path $file)
            @(Get-CompatibilityIssue -Path $file -AllowedCommand $allowed)
        }

        It 'loads the desktop 5.1 command list from PSScriptAnalyzer' {
            $names = @(Get-Desktop51CommandName)
            $names | Should -Contain 'Get-ChildItem'
            $names | Should -Contain 'Send-MailMessage'
        }

        It 'flags Get-Uptime, which 5.1 does not have' {
            $issues = @(Test-Snippet 'Get-Uptime')
            $issues.Count | Should -Be 1
            $issues[0] | Should -Match 'Get-Uptime'
        }

        It 'flags Test-Json, which 5.1 does not have' {
            $issues = @(Test-Snippet '$ok = "{}" | Test-Json')
            $issues.Count | Should -Be 1
            $issues[0] | Should -Match 'Test-Json'
        }

        It 'flags ConvertFrom-Json -AsHashtable' {
            $issues = @(Test-Snippet '$h = Get-Content x.json -Raw | ConvertFrom-Json -AsHashtable')
            $issues.Count | Should -Be 1
            $issues[0] | Should -Match 'AsHashtable'
        }

        It 'flags ForEach-Object -Parallel' {
            $issues = @(Test-Snippet '1..3 | ForEach-Object -Parallel { $_ }')
            $issues.Count | Should -BeGreaterThan 0
            ($issues -join "`n") | Should -Match 'Parallel'
        }

        It 'flags syntax that does not parse, such as the ternary operator' {
            $issues = @(Test-Snippet '$a = $true ? 1 : 2')
            ($issues -join "`n") | Should -Match 'parse error'
        }

        It 'accepts Group-Object -AsHashTable, which 5.1 supports' {
            Test-Snippet '$g = Get-Process | Group-Object -Property Name -AsHashTable' | Should -BeNullOrEmpty
        }

        It 'accepts allowlisted vendor commands such as Get-VBRJob' {
            Test-Snippet '$job = Get-VBRJob -Name "SQL"' | Should -BeNullOrEmpty
        }

        It 'accepts functions defined in the checked code' {
            Test-Snippet "function Invoke-Thing { 'x' }`nInvoke-Thing" | Should -BeNullOrEmpty
        }

        It 'skips dynamic invocations' {
            Test-Snippet '$cmd = "Get-Uptime"; & $cmd' | Should -BeNullOrEmpty
        }
    }

    if ($CheckedFiles.Count -gt 0) {
        Context 'repository code' {
            $cases = $CheckedFiles | ForEach-Object {
                @{ Path = $_; Name = $_.Substring($RepoRoot.Length + 1) }
            }
            It '<Name> uses only Windows PowerShell 5.1 syntax and commands' -TestCases $cases {
                param($Path, $Name)
                $issues = @(Get-CompatibilityIssue -Path $Path -AllowedCommand $AllowedCommands)
                ($issues -join "`n") | Should -BeNullOrEmpty
            }
        }
    }
}
