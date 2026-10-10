Describe 'Test harness' -Tag 'Unit' {
    It 'runs on PowerShell Core 6.1.2' {
        $PSVersionTable.PSVersion.ToString() | Should -Be '6.1.2'
    }

    It 'uses Pester 4.6.0' {
        (Get-Module Pester).Version.ToString() | Should -Be '4.6.0'
    }

    It 'has PSScriptAnalyzer 1.17.1 installed' {
        $versions = @(Get-Module -ListAvailable PSScriptAnalyzer | ForEach-Object { $_.Version.ToString() })
        $versions | Should -Be @('1.17.1')
    }
}
