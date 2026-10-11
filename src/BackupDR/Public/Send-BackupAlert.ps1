function Send-BackupAlert {
    <#
    .SYNOPSIS
        Sends an e-mail through the relay described by the policy's alerting block.
    .DESCRIPTION
        Reads the recipient (email), sender (from), relay (smtpServer) and port (smtpPort,
        default 25) from -Alerting and calls Send-MailMessage. A missing recipient, sender or
        relay is logged as a warning and nothing is sent. SMTP errors are logged at ERROR
        level and not rethrown, so a broken relay never stops a backup run.
    .EXAMPLE
        Send-BackupAlert -Alerting $policy.alerting -Subject 'Backup FAILED: Job-A' -Body 'Status: Failed'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Alerting,

        [Parameter(Mandatory = $true)]
        [string]$Subject,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Body,

        [switch]$BodyAsHtml
    )

    $to = @($Alerting.email | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
    $from = [string]$Alerting.from
    $server = [string]$Alerting.smtpServer

    $missing = @()
    if ($to.Count -eq 0) { $missing += 'recipient (email)' }
    if ([string]::IsNullOrWhiteSpace($from)) { $missing += 'sender (from)' }
    if ([string]::IsNullOrWhiteSpace($server)) { $missing += 'relay (smtpServer)' }
    if ($missing.Count -gt 0) {
        Write-BackupLog -Level 'WARN' -Message "Alert '$Subject' not sent: no $($missing -join ', ') in alerting settings"
        return
    }

    $port = 25
    if ($null -ne $Alerting.smtpPort -and [string]$Alerting.smtpPort -ne '') {
        $port = [int]$Alerting.smtpPort
    }

    $mailParams = @{
        SmtpServer  = $server
        Port        = $port
        From        = $from
        To          = $to
        Subject     = $Subject
        Body        = $Body
        ErrorAction = 'Stop'
    }
    if ($BodyAsHtml) {
        $mailParams['BodyAsHtml'] = $true
    }

    try {
        Send-MailMessage @mailParams
        Write-BackupLog -Message "Alert sent to $($to -join ', '): $Subject"
    }
    catch {
        Write-BackupLog -Level 'ERROR' -Message "Alert '$Subject' could not be sent via ${server}:${port}: $($_.Exception.Message)"
    }
}
