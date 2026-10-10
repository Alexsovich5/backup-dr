FROM mcr.microsoft.com/powershell:6.1.2-ubuntu-18.04

RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

COPY build/requirements.psd1 /tmp/requirements.psd1

RUN pwsh -NoProfile -Command " \
    \$ProgressPreference = 'SilentlyContinue'; \
    \$ErrorActionPreference = 'Stop'; \
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted; \
    \$modules = Import-PowerShellDataFile /tmp/requirements.psd1; \
    foreach (\$name in \$modules.Keys) { \
        for (\$i = 1; \$i -le 3; \$i++) { \
            try { \
                Install-Module -Name \$name -RequiredVersion \$modules[\$name] -Scope AllUsers -SkipPublisherCheck -Force; \
                break \
            } catch { \
                if (\$i -eq 3) { throw }; \
                Start-Sleep -Seconds 5 \
            } \
        } \
    }"

WORKDIR /src
