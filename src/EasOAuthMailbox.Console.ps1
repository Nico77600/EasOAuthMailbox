<#
.SYNOPSIS
    EAS OAuth Mailbox - console output and log file (dot-sourced by EasOAuthMailbox.psm1).

.DESCRIPTION
    Same rules as Exchange Log Report and Purview DLP Report:
      - ANSI colours are disabled when the output is redirected or NO_COLOR is set;
        EOM_FORCE_COLOR=1 forces them.
      - Icons: emoji in Windows Terminal / VS Code, symbols of the classic console fonts elsewhere.
        EOM_ICONS = Emoji | Symbols | Ascii forces a style.
      - Every line shown is also written to the daily log file, without colours or icons.
      - During a GUI run, the same lines are sent to the progress box of the window.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
#>

$script:C = @{ Reset = ''; Bold = ''; Dim = ''; Accent = ''; AccentBg = ''; Green = ''; Yellow = ''; Red = ''; White = '' }
if ($env:EOM_FORCE_COLOR -eq '1' -or (-not [Console]::IsOutputRedirected -and -not $env:NO_COLOR)) {
    $e = [char]27
    $script:C = @{
        Reset = "$e[0m"; Bold = "$e[1m"; Dim = "$e[90m"; White = "$e[97m"
        Accent = "$e[38;2;214;62;115m"; AccentBg = "$e[48;2;177;31;75m$e[97m"
        Green = "$e[38;2;80;200;120m"; Yellow = "$e[38;2;240;200;90m"; Red = "$e[38;2;240;90;90m"
    }
}
$script:IconStyle = if ($env:EOM_ICONS -in 'Emoji', 'Symbols', 'Ascii') { $env:EOM_ICONS }
    elseif ([Console]::IsOutputRedirected) { 'Symbols' }
    elseif ($env:WT_SESSION -or $env:TERM_PROGRAM -eq 'vscode') { 'Emoji' }
    else { 'Symbols' }

function Get-EomIconSet {
    <# Icons of one console style. Symbols: only characters of the classic console fonts. #>
    param([Parameter(Mandatory = $true)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style)

    $u = { param([int]$Code) [char]::ConvertFromUtf32($Code) }
    switch ($Style) {
        'Emoji' {
            return @{
                Logo = & $u 0x1F4F1; Ok = & $u 0x2705; Warn = (& $u 0x26A0) + [char]0xFE0F; Fail = & $u 0x274C; Info = & $u 0x1F539
                Skip = & $u 0x23E9; Block = & $u 0x26D4; Key = & $u 0x1F511; Server = & $u 0x1F5A5; Shield = & $u 0x1F512
                Folder = & $u 0x1F4C1; Mail = & $u 0x1F4E8; People = & $u 0x1F465; File = & $u 0x1F4C4; Log = & $u 0x1F4DD
                Report = & $u 0x1F4CA; Done = & $u 0x1F389; Target = & $u 0x1F3AF; Search = & $u 0x1F50E; Clock = & $u 0x23F3
                Settings = & $u 0x1F527
            }
        }
        'Symbols' {
            return @{
                Logo = & $u 0x2666; Ok = & $u 0x221A; Warn = & $u 0x25B2; Fail = & $u 0x00D7; Info = & $u 0x2022
                Skip = & $u 0x00BB; Block = & $u 0x25A0; Key = & $u 0x00A7; Server = & $u 0x2261; Shield = & $u 0x25CA
                Folder = & $u 0x2302; Mail = '@'; People = & $u 0x2192; File = & $u 0x25AC; Log = & $u 0x00B6
                Report = & $u 0x2261; Done = & $u 0x221A; Target = & $u 0x25D9; Search = & $u 0x25BA; Clock = & $u 0x25CB
                Settings = & $u 0x263C
            }
        }
        default {
            return @{
                Logo = '*'; Ok = '+'; Warn = '!'; Fail = 'x'; Info = '-'; Skip = '>'; Block = '#'; Key = 'k'; Server = '='
                Shield = 'o'; Folder = '>'; Mail = '@'; People = '&'; File = '-'; Log = '='; Report = '='; Done = '*'
                Target = 'o'; Search = '?'; Clock = '~'; Settings = '%'
            }
        }
    }
}

function Get-EomFrameSet {
    <# Rounded corners in modern terminals (emoji style), square corners elsewhere (present in every console font). #>
    param([Parameter(Mandatory = $true)][ValidateSet('Emoji', 'Symbols', 'Ascii')][string]$Style)

    if ($Style -eq 'Ascii') {
        return @{ TopLeft = [char]'+'; TopRight = [char]'+'; BottomLeft = [char]'+'; BottomRight = [char]'+'; Horizontal = [char]'-'; Vertical = [char]'|' }
    }
    if ($Style -eq 'Symbols') {
        return @{ TopLeft = [char]0x250C; TopRight = [char]0x2510; BottomLeft = [char]0x2514; BottomRight = [char]0x2518; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
    }
    return @{ TopLeft = [char]0x256D; TopRight = [char]0x256E; BottomLeft = [char]0x2570; BottomRight = [char]0x256F; Horizontal = [char]0x2500; Vertical = [char]0x2502 }
}

$script:Icons = Get-EomIconSet $script:IconStyle
$script:Frame = Get-EomFrameSet $script:IconStyle
$script:IconPad = if ($script:IconStyle -eq 'Emoji') { ' ' } else { '  ' }

function Get-EomIcon { param([Parameter(Mandatory = $true)][string]$Name) return $script:Icons[$Name] + $script:IconPad }

function Format-EomDuration {
    param([Parameter(Mandatory = $true)][double]$Seconds)

    $inv = [Globalization.CultureInfo]::InvariantCulture
    $t = [TimeSpan]::FromTicks([long]([Math]::Max(0.0, $Seconds) * 10000000))
    if ($t.TotalHours -ge 1) { return [string]::Format($inv, '{0} h {1:00} min', [int][Math]::Floor($t.TotalHours), $t.Minutes) }
    if ($t.TotalMinutes -ge 1) { return [string]::Format($inv, '{0} min {1:00} s', $t.Minutes, $t.Seconds) }
    return [string]::Format($inv, '{0:0.0} s', $t.TotalSeconds)
}

function Send-EomUi {
    <# Forwards a console line to the GUI progress box while a GUI run is in progress. #>
    param([string]$Status, [string]$Text)
    if ($script:Ui -and $script:Ui.Sink) { & $script:Ui.Sink $Status $Text }
}

function Start-EomLog {
    <# Opens (or continues) today's log file and deletes the log files older than the retention. #>
    param([Parameter(Mandatory = $true)][string]$Directory, [int]$RetentionDays = 14)

    Stop-EomLog
    [void][IO.Directory]::CreateDirectory($Directory)
    $script:LogPath = Join-Path $Directory ('EasOAuthMailbox_{0:yyyyMMdd}.log' -f (Get-Date))
    $stream = [IO.FileStream]::new($script:LogPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    $script:LogWriter = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
    $script:LogWriter.AutoFlush = $true
    $limit = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem -LiteralPath $Directory -Filter 'EasOAuthMailbox_*.log' -File -ErrorAction SilentlyContinue |
        Where-Object LastWriteTime -lt $limit | Remove-Item -Force -ErrorAction SilentlyContinue
    return $script:LogPath
}

function Stop-EomLog {
    if ($script:LogWriter) { $script:LogWriter.Dispose(); $script:LogWriter = $null }
}

function Write-EomLog {
    <# One line in the log file only. The log never contains colours, icons or tokens. #>
    param(
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO',
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )
    if ($script:LogWriter) { $script:LogWriter.WriteLine(('{0:yyyy-MM-ddTHH:mm:ss.fffzzz} [{1,-5}] {2}' -f (Get-Date), $Level, $Message)) }
}

function Write-EomBanner {
    <# Title card at the start of an execution, followed by the context rows (label -> @(Icon, Text)). #>
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Subtitle,
        [System.Collections.Specialized.OrderedDictionary]$Details
    )

    Write-EomLog 'STEP' "=== $Title v$($script:ToolVersion) ==="
    if ($Details) {
        foreach ($key in $Details.Keys) {
            $v = $Details[$key]
            Write-EomLog 'INFO' ('{0}: {1}' -f $key, $(if ($v -is [array]) { $v[1] } else { $v }))
        }
    }
    if ($script:Quiet) { return }
    $C = $script:C; $F = $script:Frame; $width = 74
    $right = "v$($script:ToolVersion) $([char]0x00B7) Nicolas Fabert"
    $iconWidth = if ($script:IconStyle -eq 'Emoji') { 2 } else { 1 }
    $left = "  $($script:Icons.Logo)  $Title"
    $gap = [Math]::Max(1, $width - ($left.Length - $script:Icons.Logo.Length + $iconWidth) - $right.Length - 2)
    Write-Host ''
    Write-Host ('  {0}{1}{2}{3}{4}' -f $C.Accent, $F.TopLeft, [string]::new($F.Horizontal, $width), $F.TopRight, $C.Reset)
    Write-Host ('  {0}{1}{2}{3}{4}{5}{6}{7}{8}{9}{10}{11}' -f $C.Accent, $F.Vertical, $C.Reset, $C.Bold, $left, $C.Reset, [string]::new(' ', $gap), $C.Dim, $right, '  ', ($C.Accent + $F.Vertical), $C.Reset)
    if ($Subtitle) {
        $sub = "     $Subtitle"
        if ($sub.Length -gt $width - 2) { $sub = $sub.Substring(0, $width - 5) + '...' }
        Write-Host ('  {0}{1}{2}{3}{4}{5}{0}{6}{2}' -f $C.Accent, $F.Vertical, $C.Reset, $C.Dim, $sub.PadRight($width), $C.Reset, $F.Vertical)
    }
    Write-Host ('  {0}{1}{2}{3}{4}' -f $C.Accent, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    if ($Details) {
        foreach ($key in $Details.Keys) {
            $value = $Details[$key]
            $icon, $text = if ($value -is [array]) { (Get-EomIcon $value[0]), $value[1] } else { '   ', $value }
            Write-Host ('     {0}{1}{2,-11}{3} {4}' -f $icon, $C.Dim, $key, $C.Reset, $text)
        }
    }
}

function Write-EomStep {
    <# Step header with a coloured number pill and an icon:  ─ 3/5 ─ 🔑  AD FS sign-in #>
    param(
        [Parameter(Mandatory = $true)][int]$Number,
        [Parameter(Mandatory = $true)][int]$Total,
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Icon = 'Info'
    )

    Write-EomLog 'STEP' "[$Number/$Total] $Title"
    Send-EomUi 'Step' "[$Number/$Total] $Title"
    if ($script:Quiet) { return }
    $C = $script:C
    Write-Host ''
    Write-Host ('  {0} {1}/{2} {3} {4}{5}{6}{3}' -f $C.AccentBg, $Number, $Total, $C.Reset, (Get-EomIcon $Icon), $C.Bold, $Title)
}

function Write-EomItem {
    <# One indented result line with a status icon, also written to the log and to the GUI. #>
    param(
        [ValidateSet('Ok', 'Warn', 'Fail', 'Info', 'Skip', 'Block')][string]$Status = 'Info',
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [string]$Icon
    )

    $level = @{ Ok = 'OK'; Warn = 'WARN'; Fail = 'ERROR'; Info = 'INFO'; Skip = 'INFO'; Block = 'WARN' }[$Status]
    Write-EomLog $level $Text
    Send-EomUi $Status $Text
    if ($script:Quiet) { return }
    $color = @{ Ok = $script:C.Green; Warn = $script:C.Yellow; Fail = $script:C.Red; Info = ''; Skip = $script:C.Dim; Block = $script:C.Yellow }[$Status]
    $symbol = Get-EomIcon $(if ($Icon) { $Icon } else { $Status })
    $textColor = if ($Status -in 'Warn', 'Fail', 'Skip', 'Block') { $color } else { '' }
    Write-Host ('      {0}{1}{2}{3}{4}{2}' -f $color, $symbol, $script:C.Reset, $textColor, $Text)
}

function Write-EomSummary {
    <# Final summary card (label -> @(Icon, Text)). #>
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][System.Collections.Specialized.OrderedDictionary]$Values,
        [ValidateSet('Ok', 'Warn', 'Fail')][string]$Status = 'Ok'
    )

    foreach ($key in $Values.Keys) {
        $v = $Values[$key]
        Write-EomLog 'INFO' ('Summary - {0}: {1}' -f $key, $(if ($v -is [array]) { $v[1] } else { $v }))
    }
    if ($script:Quiet) { return }
    $C = $script:C; $F = $script:Frame; $width = 74
    $color = @{ Ok = $C.Green; Warn = $C.Yellow; Fail = $C.Red }[$Status]
    $icon = $script:Icons[@{ Ok = 'Done'; Warn = 'Warn'; Fail = 'Fail' }[$Status]]
    $iconWidth = if ($script:IconStyle -eq 'Emoji') { 2 } else { 1 }
    $head = " $icon  $Title "
    $rest = [Math]::Max(2, $width - 1 - ($head.Length - $icon.Length + $iconWidth))
    Write-Host ''
    Write-Host ('  {0}{1}{2}{3}{4}{0}{5}{6}{7}' -f $color, $F.TopLeft, $F.Horizontal, $C.Bold, $head, ($C.Reset + $color), ([string]::new($F.Horizontal, $rest) + $F.TopRight), $C.Reset)
    foreach ($key in $Values.Keys) {
        $value = $Values[$key]
        $rowIcon, $text = if ($value -is [array]) { (Get-EomIcon $value[0]), $value[1] } else { '   ', $value }
        Write-Host ('    {0}{1}{2,-10}{3} {4}' -f $rowIcon, $C.Dim, $key, $C.Reset, $text)
    }
    Write-Host ('  {0}{1}{2}{3}{4}' -f $color, $F.BottomLeft, [string]::new($F.Horizontal, $width), $F.BottomRight, $C.Reset)
    Write-Host ''
}

function Write-EomRunBanner {
    <# Title card of a command-line run: scenario, mailbox, endpoints, device, policy, report and log. #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Settings,
        [string]$LogPath,
        [switch]$NoReport
    )

    $scenario = Get-EomTestCatalog | Where-Object Name -eq $Settings.TestType
    $client = Resolve-EomClientSettings -Configuration $Settings
    $dot = [char]0x00B7
    $device = if ($client.DeviceId) { $client.DeviceId } else { Get-EomDeviceId -Mailbox $client.Mailbox -DeviceType $client.DeviceType }
    $banner = [ordered]@{}
    $banner['Scenario'] = @('Target', "$($scenario.Name) $dot $($scenario.DisplayName)")
    $banner['Mailbox'] = @('People', $Settings.Mailbox)
    if ($client.Client -eq 'AppleMail') {
        # Like the iPhone: only the address is given, the rest is discovered.
        $banner['AD FS'] = @('Key', 'found in the Exchange challenge, like the iPhone')
        $banner['ActiveSync'] = @('Server', $(if ($client.EasUrl) { "Autodiscover (else $($client.EasUrl), as typed by hand)" } else { 'Autodiscover' }))
    }
    else {
        $banner['AD FS'] = @('Key', $Settings.AdfsUrl)
        $banner['ActiveSync'] = @('Server', $Settings.EasUrl)
    }
    if ($client.Client -eq 'AppleMail') { $banner['Client'] = @('Key', "Apple Mail $dot $($client.ClientId) $dot $($client.UserAgent) $dot EAS $($client.ProtocolVersion)") }
    $banner['Device'] = @('Settings', "$($client.DeviceType) $dot $device")
    if ($scenario.CanProvision) {
        $banner['Policy'] = @('Shield', $(if ($Settings.AcknowledgePolicy) { 'acknowledgement AUTHORISED (test mailbox)' } else { 'downloaded for review only, not acknowledged' }))
    }
    $banner['Report'] = @('Report', $(if ($NoReport) { 'none (-NoReport)' } else { $Settings.OutputPath }))
    if ($LogPath) { $banner['Log'] = @('Log', $LogPath) }
    Write-EomBanner -Title 'EAS OAuth Mailbox' -Subtitle "Exchange ActiveSync $dot OAuth with AD FS $dot step-by-step diagnostic" -Details $banner
}

function Write-EomRunSummary {
    <# Final card of a command-line run: status, counts, first issue, report, log and what to do next. #>
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Result,
        [string]$ReportText = 'none (-NoReport)',
        [string]$LogPath
    )

    $dot = [char]0x00B7
    $n = $Result.Counts
    $values = [ordered]@{}
    $values['Status'] = @($(switch ($Result.Status) { 'Passed' { 'Ok' } 'Failed' { 'Fail' } 'Blocked' { 'Block' } default { 'Warn' } }), "$($Result.Status) $dot $($Result.TestType)")
    $values['Checks'] = @('Target', ('{0} passed {5} {1} warning(s) {5} {2} blocked {5} {3} failed {5} {4} skipped' -f $n.Passed, $n.Warning, $n.Blocked, $n.Failed, $n.Skipped, $dot))
    if ($Result.Error) { $values['First issue'] = @('Fail', $Result.Error) }
    $values['Duration'] = @('Clock', (Format-EomDuration $Result.DurationSeconds))
    $values['Report'] = @('Report', $ReportText)
    if ($LogPath) { $values['Log'] = @('Log', $LogPath) }
    $values['Next'] = @('Info', $(switch ($Result.Status) {
                'Passed' { 'Nothing to do. Exchange lists the test device: Get-MobileDevice -Mailbox <mailbox>.' }
                'Blocked' { 'Review the policy (Policy tab of the report), then run again with -AcknowledgePolicy on a test mailbox.' }
                'Warning' { 'Read the warnings in the report: each one gives the cause and what to check.' }
                default { 'Open the report: the first Failed step gives the HTTP status and the Exchange diagnostics.' }
            }))
    $title = switch ($Result.Status) { 'Passed' { 'Diagnostic passed' } 'Warning' { 'Diagnostic finished with warnings' } 'Blocked' { 'Diagnostic blocked' } default { 'Diagnostic failed' } }
    $card = switch ($Result.Status) { 'Passed' { 'Ok' } 'Failed' { 'Fail' } default { 'Warn' } }
    Write-EomSummary -Title $title -Values $values -Status $card
}
