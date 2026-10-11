$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).ProviderPath
$composePath = Join-Path $repoRoot 'docker-compose.yml'
# Written by `make test` / `make test-unit` with `docker compose config` before the container starts.
$renderedComposePath = Join-Path $repoRoot 'out/compose.config.yml'

function Get-ComposePublishedPort {
    # Published ports in a compose file, as written or as rendered by `docker compose config`
    # (short "host_ip:published:target" strings and long-syntax mappings with host_ip).
    # Returns one object per entry: Service, Entry and HostIp ('' when every interface is bound).
    param([string]$Text)

    $results = New-Object System.Collections.Generic.List[object]
    $inServices = $false
    $serviceIndent = -1
    $service = $null
    $portsIndent = -1
    $itemIndent = -1
    $item = $null

    $flush = {
        if ($null -ne $item) {
            $hostIp = ''
            if ($item.ContainsKey('host_ip')) { $hostIp = $item['host_ip'] }
            $entry = (@($item.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f $_, $item[$_] }) -join ' ')
            $results.Add([pscustomobject]@{ Service = $service; Entry = $entry; HostIp = $hostIp })
        }
    }

    function Get-Unquoted {
        param([string]$Value)
        $Value.Trim().Trim('"').Trim("'")
    }

    function Get-ShortHostIp {
        param([string]$Value)
        $spec = (Get-Unquoted $Value) -replace '/(tcp|udp)$', ''
        $match = [regex]::Match($spec, '^(.+):([^:\]]+):([^:\]]+)$')
        if ($match.Success) { return $match.Groups[1].Value.Trim('[', ']') }
        ''
    }

    foreach ($rawLine in ($Text -split '\r?\n')) {
        $line = $rawLine -replace '\s+#.*$', ''
        if ($line -match '^\s*(#|$)') { continue }
        $indent = $line.Length - $line.TrimStart(' ').Length
        $content = $line.Trim()

        if ($indent -eq 0) {
            & $flush; $item = $null
            $inServices = ($content -eq 'services:')
            $serviceIndent = -1; $service = $null; $portsIndent = -1
            continue
        }
        if (-not $inServices) { continue }

        if ($serviceIndent -lt 0) { $serviceIndent = $indent }
        if ($indent -le $serviceIndent) {
            & $flush; $item = $null
            $service = $content.TrimEnd(':')
            $portsIndent = -1
            continue
        }

        if ($portsIndent -ge 0) {
            $isListItem = $content.StartsWith('-')
            if ($indent -lt $portsIndent -or ($indent -eq $portsIndent -and -not $isListItem)) {
                & $flush; $item = $null
                $portsIndent = -1
            } elseif ($isListItem) {
                & $flush; $item = $null
                $value = $content.Substring(1).Trim()
                $itemIndent = $indent
                $pair = [regex]::Match($value, '^([A-Za-z_]+):(?:\s+(.*))?$')
                if ($pair.Success) {
                    $item = @{}
                    $item[$pair.Groups[1].Value] = Get-Unquoted $pair.Groups[2].Value
                } else {
                    $results.Add([pscustomobject]@{ Service = $service; Entry = (Get-Unquoted $value); HostIp = (Get-ShortHostIp $value) })
                }
                continue
            } elseif ($null -ne $item -and $indent -gt $itemIndent) {
                $pair = [regex]::Match($content, '^([A-Za-z_]+):(?:\s+(.*))?$')
                if ($pair.Success) { $item[$pair.Groups[1].Value] = Get-Unquoted $pair.Groups[2].Value }
                continue
            }
        }

        $flow = [regex]::Match($content, '^ports:\s*\[(.*)\]\s*$')
        if ($flow.Success) {
            foreach ($value in @($flow.Groups[1].Value -split ',' | Where-Object { $_.Trim() })) {
                $results.Add([pscustomobject]@{ Service = $service; Entry = (Get-Unquoted $value); HostIp = (Get-ShortHostIp $value) })
            }
            continue
        }
        if ($content -eq 'ports:') {
            & $flush; $item = $null
            $portsIndent = $indent
        }
    }
    & $flush
    $results.ToArray()
}

function Get-AptBypass {
    # Lines that turn off apt signature checking or fetch over plain HTTP.
    param([string]$Text)
    $pattern = '--allow-unauthenticated|--force-yes|\[\s*trusted\s*=\s*yes\s*\]|AllowUnauthenticated|AllowInsecureRepositories|--allow-insecure-repositories|--no-check-gpg|http://'
    @($Text -split '\r?\n' | Where-Object { $_ -match $pattern })
}

Describe 'Get-ComposePublishedPort' -Tag 'Unit' {
    It 'reads the host address of short-syntax entries' {
        $text = "services:`n  web:`n    image: x`n    ports:`n      - `"127.0.0.1:21025:8025`"`n      - 21026:8026`n      - `"8027`"`n"
        $ports = @(Get-ComposePublishedPort -Text $text)
        $ports.Count | Should -Be 3
        $ports[0].HostIp | Should -Be '127.0.0.1'
        $ports[1].HostIp | Should -Be ''
        $ports[2].HostIp | Should -Be ''
        @($ports | ForEach-Object { $_.Service } | Select-Object -Unique) | Should -Be @('web')
    }

    It 'reads the host address of long-syntax entries as rendered by docker compose config' {
        $text = @(
            'name: backup-dr'
            'services:'
            '  mailhog:'
            '    image: mailhog/mailhog:v1.0.0'
            '    networks:'
            '      default: null'
            '    ports:'
            '      - mode: ingress'
            '        host_ip: 127.0.0.1'
            '        target: 8025'
            '        published: "21025"'
            '        protocol: tcp'
            '      - mode: ingress'
            '        target: 1025'
            '        published: "21026"'
            '        protocol: tcp'
            '  app:'
            '    image: backup-dr:dev'
            'networks:'
            '  default:'
            '    ports: not-a-service'
        ) -join "`n"
        $ports = @(Get-ComposePublishedPort -Text $text)
        $ports.Count | Should -Be 2
        $ports[0].Service | Should -Be 'mailhog'
        $ports[0].HostIp | Should -Be '127.0.0.1'
        $ports[1].HostIp | Should -Be ''
    }

    It 'reads the 1.x rendering with protocol suffixes and flow lists' {
        $text = "services:`n  a:`n    ports:`n    - 127.0.0.1:21025:8025/tcp`n  b:`n    ports: [`"0.0.0.0:21030:80`", `"21031:81`"]`n"
        $ports = @(Get-ComposePublishedPort -Text $text)
        @($ports | ForEach-Object { $_.HostIp }) | Should -Be @('127.0.0.1', '0.0.0.0', '')
    }

    It 'does not count expose entries as published ports' {
        $text = "services:`n  a:`n    expose:`n      - `"8025`"`n"
        @(Get-ComposePublishedPort -Text $text).Count | Should -Be 0
    }
}

Describe 'Published ports' -Tag 'Unit' {
    $sources = @(
        @{ Label = 'docker-compose.yml'; Path = $composePath }
        @{ Label = 'rendered compose configuration (out/compose.config.yml)'; Path = $renderedComposePath }
    )

    It '<Label> exists' -TestCases $sources {
        param($Label, $Path)
        Test-Path -Path $Path -PathType Leaf | Should -Be $true -Because 'make test renders it with docker compose config'
    }

    It '<Label> publishes ports' -TestCases $sources {
        param($Label, $Path)
        @(Get-ComposePublishedPort -Text (Get-Content -Path $Path -Raw)).Count | Should -BeGreaterThan 0
    }

    It '<Label> binds every published port to 127.0.0.1' -TestCases $sources {
        param($Label, $Path)
        $open = @(Get-ComposePublishedPort -Text (Get-Content -Path $Path -Raw) | Where-Object { $_.HostIp -ne '127.0.0.1' } |
                ForEach-Object { '{0}: {1}' -f $_.Service, $_.Entry })
        $open | Should -BeNullOrEmpty
    }
}

Describe 'Get-AptBypass' -Tag 'Unit' {
    It 'flags <Text>' -TestCases @(
        @{ Text = 'RUN apt-get install -y --allow-unauthenticated git' }
        @{ Text = 'RUN apt-get install -y --force-yes git' }
        @{ Text = 'deb [trusted=yes] https://snapshot.debian.org/archive/debian/20190101T000000Z stretch main' }
        @{ Text = 'APT::Get::AllowUnauthenticated "true";' }
        @{ Text = 'RUN echo "deb http://archive.ubuntu.com/ubuntu bionic main" > /etc/apt/sources.list' }
        @{ Text = 'RUN apt-get -o Acquire::Check-Valid-Until=false --no-check-gpg update' }
    ) {
        param($Text)
        @(Get-AptBypass -Text $Text).Count | Should -Be 1
    }

    It 'accepts a plain apt-get install' {
        @(Get-AptBypass -Text "RUN apt-get update \`n && apt-get install -y --no-install-recommends git").Count | Should -Be 0
    }
}

Describe 'Image build files' -Tag 'Unit' {
    $buildFiles = @(
        Get-ChildItem -Path $repoRoot -Recurse -File -Force |
            Where-Object { $_.FullName -notmatch '[\\/](\.git|out|logs)[\\/]' } |
            Where-Object { $_.Name -like 'Dockerfile*' -or $_.Name -like '*.dockerfile' -or $_.Name -like '*.list' -or $_.Name -like 'apt.conf*' } |
            ForEach-Object { @{ RelativePath = $_.FullName.Substring($repoRoot.Length + 1); FullPath = $_.FullName } }
    )

    It 'finds the Dockerfile' {
        @($buildFiles | ForEach-Object { $_.RelativePath }) | Should -Contain 'Dockerfile'
    }

    It '<RelativePath> keeps apt signature checks on and uses no plain-HTTP sources' -TestCases $buildFiles {
        param($RelativePath, $FullPath)
        Get-AptBypass -Text (Get-Content -Path $FullPath -Raw) | Should -BeNullOrEmpty
    }
}
