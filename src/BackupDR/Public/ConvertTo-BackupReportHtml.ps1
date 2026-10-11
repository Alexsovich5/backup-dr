function ConvertTo-BackupReportHtml {
    <#
    .SYNOPSIS
        Renders report rows from Get-BackupJobReport as a standalone HTML page.
    .DESCRIPTION
        Builds the table with ConvertTo-Html (which HTML-encodes every value), adds inline CSS
        and tags each Status cell with a class such as "status status-failed" so results are
        colour-coded. Returns the whole document as a single string, ready to be written to
        disk or sent with Send-BackupAlert -BodyAsHtml.
    .EXAMPLE
        $rows = @(Get-BackupJobReport -Policy $policy)
        ConvertTo-BackupReportHtml -Report $rows -Title 'Daily Backup Report'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Report,

        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $columns = @('JobName', 'Status', 'StartTime', 'EndTime', 'DataSize', 'DedupRatio')
    $encodedTitle = [System.Net.WebUtility]::HtmlEncode($Title)

    $rows = @($Report | Where-Object { $null -ne $_ })
    if ($rows.Count -gt 0) {
        $table = ($rows | Select-Object -Property $columns | ConvertTo-Html -Fragment) -join "`n"
    }
    else {
        $header = ($columns | ForEach-Object { "<th>$_</th>" }) -join ''
        $table = "<table>`n<colgroup>$('<col/>' * $columns.Count)</colgroup>`n<tr>$header</tr>`n</table>"
    }

    # Status is the second column: tag that cell with a class derived from its value.
    $table = [regex]::Replace($table, '(<tr><td>[^<]*</td>)<td>([^<]*)</td>', {
            param($match)
            $status = $match.Groups[2].Value
            $class = ($status.ToLowerInvariant() -replace '[^a-z0-9]', '')
            '{0}<td class="status status-{1}">{2}</td>' -f $match.Groups[1].Value, $class, $status
        })

    $css = @'
body { font-family: Verdana, Arial, sans-serif; font-size: 13px; color: #222; }
h1 { font-size: 18px; }
table { border-collapse: collapse; }
th, td { border: 1px solid #999; padding: 4px 8px; text-align: left; }
th { background-color: #ddd; }
td.status { font-weight: bold; }
td.status-success { background-color: #c6efce; color: #006100; }
td.status-warning { background-color: #ffeb9c; color: #7f6000; }
td.status-failed, td.status-timeout, td.status-error { background-color: #ffc7ce; color: #9c0006; }
td.status-nosession { background-color: #eee; color: #555; }
'@

    $lines = @(
        '<!DOCTYPE html>'
        '<html>'
        '<head>'
        '<meta charset="utf-8">'
        "<title>$encodedTitle</title>"
        '<style>'
        $css.TrimEnd()
        '</style>'
        '</head>'
        '<body>'
        "<h1>$encodedTitle</h1>"
        $table
        '</body>'
        '</html>'
    )
    $lines -join "`n"
}
