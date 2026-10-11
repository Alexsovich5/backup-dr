$env:BACKUPDR_PROVIDER = 'none'
Import-Module (Join-Path $PSScriptRoot '../../src/BackupDR') -Force

Describe 'ConvertTo-BackupReportHtml' -Tag 'Unit' {
    $start = [datetime]'2019-02-17T02:00:00'

    function New-ReportRow {
        param([string]$JobName, [string]$Status)
        [pscustomobject]@{
            JobName    = $JobName
            Status     = $Status
            StartTime  = $start
            EndTime    = $start.AddMinutes(30)
            DataSize   = 1024
            DedupRatio = 2
        }
    }

    $rows = @(
        (New-ReportRow -JobName 'Job-A' -Status 'Success'),
        (New-ReportRow -JobName 'Job-B' -Status 'Failed'),
        (New-ReportRow -JobName '<script>alert(1)</script> & Co' -Status 'Warning')
    )

    It 'returns a single HTML document string with the title' {
        $html = ConvertTo-BackupReportHtml -Report $rows -Title 'Daily Backup Report'

        $html | Should -BeOfType [string]
        $html | Should -Match '<title>Daily Backup Report</title>'
        $html | Should -Match '<style>'
    }

    It 'renders one table row per job plus a header row' {
        $html = ConvertTo-BackupReportHtml -Report $rows -Title 'Daily Backup Report'

        ([regex]::Matches($html, '<tr[ >]')).Count | Should -Be ($rows.Count + 1)
        ([regex]::Matches($html, '<th>')).Count | Should -Be 6
    }

    It 'escapes job names' {
        $html = ConvertTo-BackupReportHtml -Report $rows -Title 'Daily Backup Report'

        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt; &amp; Co'
    }

    It 'escapes the title' {
        $html = ConvertTo-BackupReportHtml -Report $rows -Title 'Report <b>'

        $html | Should -Match '<title>Report &lt;b&gt;</title>'
    }

    It 'marks the status cell with a class per status' {
        $html = ConvertTo-BackupReportHtml -Report $rows -Title 'Daily Backup Report'

        $html | Should -Match '<td class="status status-success">Success</td>'
        $html | Should -Match '<td class="status status-failed">Failed</td>'
        $html | Should -Match '<td class="status status-warning">Warning</td>'
    }

    It 'renders an empty report with a header row only' {
        $html = ConvertTo-BackupReportHtml -Report @() -Title 'Empty'

        $html | Should -Match '<title>Empty</title>'
        ([regex]::Matches($html, '<tr[ >]')).Count | Should -Be 1
    }
}
