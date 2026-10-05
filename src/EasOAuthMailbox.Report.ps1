<#
.SYNOPSIS
    EAS OAuth Mailbox - report files (dot-sourced by EasOAuthMailbox.psm1).

.DESCRIPTION
    One folder per execution, <FilePrefix>_<Scenario>_<yyyyMMdd-HHmmss>, with:
      <prefix>-Steps.csv     every check: stage, status, message, details, duration
      <prefix>-Folders.csv   folders returned by FolderSync
      <prefix>-Messages.csv  Inbox headers returned by Sync
      <prefix>-Policy.csv    ActiveSync policy settings returned by Exchange
      <prefix>-Trace.csv     every HTTP request sent and the response received (tokens masked)
      <prefix>-Summary.json  the whole result, for scripts
      <prefix>.html          self-contained dashboard (templates\Report.template.html)
    CSV files: UTF-8 with BOM, configurable delimiter, text cells starting with = + - @ are
    prefixed with an apostrophe (no formula injection when opened in Excel), like Purview DLP Report.
    The access token is never part of the result, so it can never reach a report file.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.2.1
#>

$script:ReportColumns = [ordered]@{
    Steps    = @('Stage', 'Name', 'Status', 'Message', 'Details', 'DurationMs', 'TimestampUtc', 'Trace')
    Folders  = @('DisplayName', 'Type', 'TypeName', 'ServerId', 'ParentId')
    Messages = @('DateReceived', 'From', 'Subject', 'Read', 'ServerId')
    Policy   = @('Setting', 'Value')
    Trace    = @('Sequence', 'TimestampUtc', 'Stage', 'Step', 'StepName', 'Method', 'Url', 'Label', 'StatusCode', 'Reason', 'DurationMs', 'Repeated', 'Note', 'Request', 'Response')
}

function Format-EomDetails {
    <# Details of a step on one line: Key=Value; Key=Value (empty values left out). #>
    param([AllowNull()][System.Collections.IDictionary]$Details)

    if ($null -eq $Details) { return '' }
    $parts = foreach ($key in $Details.Keys) {
        $value = $Details[$key]
        if ($null -eq $value -or ([string]$value) -eq '') { continue }
        if ($value -is [array]) { $value = $value -join ', ' }
        '{0}={1}' -f $key, $value
    }
    return (@($parts) -join '; ')
}

function Format-EomCsvCell {
    param([AllowNull()][object]$Value, [Parameter(Mandatory = $true)][string]$Delimiter)

    if ($null -eq $Value) { return '' }
    if ($Value -is [System.Collections.IDictionary]) { $text = Format-EomDetails $Value }
    elseif ($Value -is [array]) { $text = $Value -join ', ' }
    elseif ($Value -is [bool]) { $text = if ($Value) { 'True' } else { 'False' } }
    elseif ($Value -is [string]) {
        $text = $Value
        # Formula injection: Excel evaluates a cell starting with = + - @ (or tab / CR).
        if ($text -match '^[=+\-@\t\r]') { $text = "'" + $text }
    }
    else { $text = [string]$Value }
    if ($text.Contains($Delimiter) -or $text.Contains('"') -or $text -match '[\r\n]') {
        $text = '"' + $text.Replace('"', '""') + '"'
    }
    return $text
}

function Write-EomCsv {
    param(
        [AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Columns,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Delimiter = ';'
    )

    $builder = [Text.StringBuilder]::new()
    [void]$builder.AppendLine((@($Columns | ForEach-Object { Format-EomCsvCell $_ $Delimiter }) -join $Delimiter))
    foreach ($row in @($Rows)) {
        [void]$builder.AppendLine((@($Columns | ForEach-Object { Format-EomCsvCell (Get-EomField $row $_) $Delimiter }) -join $Delimiter))
    }
    [IO.File]::WriteAllText($Path, $builder.ToString(), [Text.UTF8Encoding]::new($true))
}

function ConvertTo-EomEmbeddedJson {
    <# JSON safe inside a <script type="application/json"> block. #>
    param([AllowNull()][object]$Value)

    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    if ([string]::IsNullOrEmpty($json)) { $json = 'null' }
    return $json.Replace('<', '\u003c').Replace('>', '\u003e').Replace('&', '\u0026')
}

function New-EomRunFolder {
    param([Parameter(Mandatory = $true)][string]$OutputPath, [Parameter(Mandatory = $true)][string]$Prefix, [string]$TestType = 'Run')

    $base = Join-Path $OutputPath ('{0}_{1}_{2}' -f $Prefix, $TestType, (Get-Date).ToString('yyyyMMdd-HHmmss'))
    $path = $base
    $n = 2
    while (Test-Path -LiteralPath $path) { $path = "$base-$n"; $n++ }
    [void][IO.Directory]::CreateDirectory($path)
    return $path
}

function Export-EomReport {
    <#
    .SYNOPSIS
        Writes the CSV, JSON and HTML files of one result in a new folder under OutputPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Result,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [string]$Prefix = 'EasOAuthMailbox',
        [ValidateSet('Csv', 'Html')][string[]]$Formats = @('Csv', 'Html'),
        [ValidateSet(';', ',', "`t")][string]$Delimiter = ';'
    )

    $testType = [string](Get-EomField $Result 'TestType')
    $runPath = New-EomRunFolder -OutputPath $OutputPath -Prefix $Prefix -TestType $(if ($testType) { $testType } else { 'Run' })
    $data = [ordered]@{
        Steps    = @(Get-EomField $Result 'Steps')
        Folders  = @(Get-EomField $Result 'Folders')
        Messages = @(Get-EomField $Result 'Messages')
        Policy   = @(Get-EomField $Result 'PolicySettings')
        Trace    = @(Get-EomField $Result 'Trace')
    }
    $files = [ordered]@{}

    if ($Formats -contains 'Csv') {
        foreach ($name in $data.Keys) {
            $files[$name] = Join-Path $runPath "$Prefix-$name.csv"
            Write-EomCsv -Rows $data[$name] -Columns $script:ReportColumns[$name] -Path $files[$name] -Delimiter $Delimiter
        }
    }

    $files.Summary = Join-Path $runPath "$Prefix-Summary.json"
    [IO.File]::WriteAllText($files.Summary, (ConvertTo-Json -InputObject $Result -Depth 8), [Text.UTF8Encoding]::new($false))

    if ($Formats -contains 'Html') {
        $summary = [ordered]@{}
        foreach ($key in 'Tool', 'Version', 'Status', 'TestType', 'Scenario', 'StartedUtc', 'CompletedUtc', 'DurationSeconds', 'Mailbox', 'Authentication', 'BasicUser', 'Client', 'ClientId', 'UserAgent', 'ProtocolVersion', 'DeviceId', 'AdfsUrlSource', 'EasUrlSource',
            'Authority', 'AuthorityUrl', 'AuthoritySource', 'TenantId', 'SignIn',
            'DeviceType', 'AdfsUrl', 'EasUrl', 'PolicyAcknowledged', 'MoreAvailable', 'Identity', 'Token', 'Counts', 'Error') {
            $summary[$key] = Get-EomField $Result $key
        }
        $template = [IO.File]::ReadAllText((Join-Path $script:ToolRoot 'templates\Report.template.html'))
        $status = if ($summary.Status) { $summary.Status } else { 'Unknown' }
        $html = $template.Replace('{{TITLE}}', [Net.WebUtility]::HtmlEncode("EAS OAuth Mailbox | $status | $testType"))
        $html = $html.Replace('{{SUMMARY_JSON}}', (ConvertTo-EomEmbeddedJson $summary))
        foreach ($name in $data.Keys) {
            $html = $html.Replace("{{$($name.ToUpperInvariant())_JSON}}", (ConvertTo-EomEmbeddedJson @($data[$name])))
        }
        if ($html -match '\{\{[A-Z_]+\}\}') { throw "Report template marker not replaced: $($Matches[0])" }
        $files.Html = Join-Path $runPath "$Prefix.html"
        [IO.File]::WriteAllText($files.Html, $html, [Text.UTF8Encoding]::new($true))
    }

    [pscustomobject]@{ Directory = $runPath; Files = $files }
}
