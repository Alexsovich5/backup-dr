function Invoke-NotificationStep {
    <#
    .SYNOPSIS
        Runs a notification DR step: e-mails the step's recipient a summary of the run.
    .DESCRIPTION
        Uses the relay and sender from -Alerting (the policy's alerting block) with the
        recipient replaced by the step's 'to'. The body lists the steps that ran before
        this one (-Results). In test mode nothing is sent; the step only checks that
        alerting settings are present. Throws when -Alerting is missing or when the mail
        was not sent, so the run log never reports an undelivered notification as Succeeded.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Step,

        [Parameter(Mandatory = $true)]
        [ValidateSet('failover', 'failback', 'test')]
        [string]$Action,

        [psobject]$Alerting,

        [string]$PlanName,

        [object[]]$Results = @()
    )

    $to = [string]$Step.to
    if ($null -eq $Alerting) {
        throw "Notification to $to cannot be sent: no alerting settings were provided"
    }

    if ($Action -eq 'test') {
        return "Notification would be sent to $to via $($Alerting.smtpServer)"
    }

    $settings = $Alerting.PSObject.Copy()
    $settings | Add-Member -MemberType NoteProperty -Name email -Value $to -Force

    $lines = @("DR $Action for plan '$PlanName'.", '')
    foreach ($result in @($Results | Where-Object { $null -ne $_ })) {
        $lines += "$($result.Name): $($result.Status) - $($result.Message)"
    }

    $sent = Send-BackupAlert -Alerting $settings -Subject "DR ${Action}: $PlanName" -Body ($lines -join "`n") -PassThru
    if (-not $sent) {
        throw "Notification to $to was not sent (see the log for the SMTP error)"
    }
    "Notification sent to $to"
}
