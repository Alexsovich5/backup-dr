# Helpers for integration tests that assert on mail captured by the MailHog container.
# The API base can be overridden with BACKUPDR_MAILHOG_API (default http://mailhog:8025).

function Get-MailHogBaseUri {
    if ($env:BACKUPDR_MAILHOG_API) { return $env:BACKUPDR_MAILHOG_API.TrimEnd('/') }
    'http://mailhog:8025'
}

function Wait-MailHog {
    <#
    .SYNOPSIS
        Retries the MailHog API every 500 ms for up to -TimeoutSeconds; throws if it never answers.
    #>
    param([int]$TimeoutSeconds = 10)

    $uri = (Get-MailHogBaseUri) + '/api/v2/messages'
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        try {
            Invoke-RestMethod -Uri $uri -TimeoutSec 2 | Out-Null
            return
        } catch {
            if ((Get-Date) -ge $deadline) {
                throw "MailHog did not answer at $uri within $TimeoutSeconds seconds: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Clear-MailHog {
    <#
    .SYNOPSIS
        Deletes every message MailHog holds.
    #>
    Invoke-RestMethod -Method Delete -Uri ((Get-MailHogBaseUri) + '/api/v1/messages') | Out-Null
}

function Get-MailHogMessages {
    <#
    .SYNOPSIS
        Returns the captured messages as objects with Subject, From, To (string[]) and Body.
    #>
    $response = Invoke-RestMethod -Uri ((Get-MailHogBaseUri) + '/api/v2/messages')
    foreach ($item in @($response.items)) {
        if ($null -eq $item) { continue }
        $headers = $item.Content.Headers
        [pscustomobject]@{
            Subject = @($headers.Subject)[0]
            From    = @($headers.From)[0]
            To      = @($item.To | ForEach-Object { '{0}@{1}' -f $_.Mailbox, $_.Domain })
            Body    = $item.Content.Body
        }
    }
}
