<#
.SYNOPSIS
    Renders the screenshots of the guide (docs\images\eas-*.png) from the real tool, against the simulated Exchange.

.DESCRIPTION
    No lab is needed and the images always match the current code: the console, the window and the report
    are produced by the module itself, with tests\EasOAuthMailbox.Simulator.ps1 standing in for AD FS and
    Exchange (Install-SimExchange replaces only the network calls). Paths and names are anonymised
    (C:\Tools\EasOAuthMailbox, contoso.test).

        eas-console.png         console of a Full run (banner, the six stages, summary card)
        eas-console-apple.png   console of an AppleMail run (the path of the Mail app of an iPhone)
        eas-console-basic.png   console of a Full run with Basic authentication (mailbox without OAuth)
        eas-console-entra.png   console of a Full run with Entra ID (Exchange on-premises with HMA)
        eas-console-online.png  console of a Full run with Entra ID against Exchange Online
        eas-gui.png             the window after a Full run, with its progress box
        eas-gui-basic.png       the window after a Full run with Basic authentication, dark theme
        eas-report-overview.png header, tiles and scope of the HTML report
        eas-report-basic.png    header, tiles and scope of the report of the Basic run
        eas-report-checks.png   the checks, grouped by stage
        eas-report-detail.png   the detail dialog of a check (token claims)
        eas-report-exchange.png a check with the request sent and the response received (HTTP trace)

    The HTML pages are captured with Microsoft Edge (headless), the window with RenderTargetBitmap (WPF).
    Run tools\Build-Documentation.ps1 afterwards: the guide embeds the images.

.PARAMETER OutputFolder
    Default: docs\images next to the tools folder.

.PARAMETER KeepWork
    Keeps the work folder (report, HTML pages) and shows its path.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.2.0
    Part of : EAS OAuth Mailbox (repository tool, not in the package)
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$OutputFolder,
    [switch]$KeepWork
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutputFolder) { $OutputFolder = Join-Path $root 'docs\images' }
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge not found: it takes the screenshots (headless mode).' }
$work = Join-Path ([IO.Path]::GetTempPath()) ('eom-doc-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $work, $OutputFolder -Force | Out-Null
$shown = 'C:\Tools\EasOAuthMailbox'

#region Edge helpers (same as Exchange Log Report) -----------------------------------------------
function Save-Screenshot([string]$Html, [string]$Png, [int]$Width, [int]$Height) {
    $url = 'file:///' + ($Html -replace '\\', '/')
    if (Test-Path $Png) { Remove-Item $Png -Force }
    $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', "--user-data-dir=`"$(Join-Path $work 'edge-profile')`"", "--window-size=$Width,$Height", '--force-device-scale-factor=1', "--screenshot=`"$Png`"", "`"$url`"")
    $proc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(45)
    while (-not (Test-Path $Png) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    if (-not $proc.WaitForExit(10000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    if (-not (Test-Path $Png)) { throw "Screenshot not written: $Png" }
}

function Get-PageHeight([string]$Html, [int]$Width) {
    # The page writes its height in body[data-h]; Edge returns the DOM with --dump-dom.
    $url = 'file:///' + ($Html -replace '\\', '/')
    $dom = Join-Path $work ('dom-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.html')
    $edgeArgs = @('--headless=new', '--disable-gpu', '--hide-scrollbars', '--no-first-run', "--user-data-dir=`"$(Join-Path $work 'edge-profile')`"", "--window-size=$Width,2000", '--virtual-time-budget=3000', '--dump-dom', "`"$url`"")
    $proc = Start-Process -FilePath $edge -ArgumentList $edgeArgs -PassThru -WindowStyle Hidden -RedirectStandardOutput $dom
    if (-not $proc.WaitForExit(45000)) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    $m = $null
    for ($i = 0; $i -lt 20 -and -not ($m -and $m.Success); $i++) {
        $stream = [IO.File]::Open($dom, 'Open', 'Read', 'ReadWrite')
        try { $text = [IO.StreamReader]::new($stream).ReadToEnd() } finally { $stream.Dispose() }
        $m = [regex]::Match($text, 'data-h="(\d+)"')
        if (-not $m.Success) { Start-Sleep -Milliseconds 250 }
    }
    if (-not $m.Success) { throw "Height not measured: $Html" }
    return [int]$m.Groups[1].Value
}

function Save-Page([string]$Html, [string]$Name, [int]$Width, [int]$Height = 0) {
    if ($Height -le 0) { $Height = Get-PageHeight $Html $Width }
    $png = Join-Path $OutputFolder "$Name.png"
    Save-Screenshot $Html $png $Width $Height
    Write-Host ("  {0,-26} {1} x {2}" -f "$Name.png", $Width, $Height)
}
#endregion

#region Run the real tool against the simulated Exchange ----------------------------------------
# Console theme is chosen when the module loads: colours and emoji, as in Windows Terminal.
$env:EOM_FORCE_COLOR = '1'
$env:EOM_ICONS = 'Emoji'
Remove-Module EasOAuthMailbox -ErrorAction SilentlyContinue
Import-Module (Join-Path $root 'EasOAuthMailbox.psd1') -Force
$module = Get-Module EasOAuthMailbox
. (Join-Path $root 'tests\EasOAuthMailbox.Simulator.ps1')

$state = New-SimState
$state.RequireProvisioning = $true
$state.CertificateDays = 21
# AD FS answers authorization_pending once while the user signs in: shown once in the HTTP trace.
$state.TokenPendingPolls = 1
$state.Folders = @(
    @{ Name = 'Inbox'; Id = '2'; Parent = '0'; Type = '2' }, @{ Name = 'Drafts'; Id = '3'; Parent = '0'; Type = '3' }
    @{ Name = 'Deleted Items'; Id = '4'; Parent = '0'; Type = '4' }, @{ Name = 'Sent Items'; Id = '5'; Parent = '0'; Type = '5' }
    @{ Name = 'Outbox'; Id = '6'; Parent = '0'; Type = '6' }, @{ Name = 'Tasks'; Id = '7'; Parent = '0'; Type = '7' }
    @{ Name = 'Calendar'; Id = '8'; Parent = '0'; Type = '8' }, @{ Name = 'Contacts'; Id = '9'; Parent = '0'; Type = '9' }
    @{ Name = 'Notes'; Id = '10'; Parent = '0'; Type = '10' }, @{ Name = 'Journal'; Id = '11'; Parent = '0'; Type = '11' }
    @{ Name = 'Junk Email'; Id = '12'; Parent = '0'; Type = '12' }, @{ Name = 'Archive'; Id = '13'; Parent = '0'; Type = '12' }
)
$state.Policy = [ordered]@{
    DevicePasswordEnabled = '1'; AlphanumericDevicePasswordRequired = '0'; MinDevicePasswordLength = '6'; MaxInactivityTimeDeviceLock = '900'
    MaxDevicePasswordFailedAttempts = '10'; AllowSimpleDevicePassword = '0'; DevicePasswordExpiration = '0'; RequireDeviceEncryption = '1'
    AttachmentsEnabled = '1'; AllowCamera = '1'
}
$state.Messages = @(
    @{ Date = '2026-10-02T08:41:12.000Z'; From = '"Service Desk" <servicedesk@contoso.test>'; Subject = 'Your mobile device is ready'; Read = '0' }
    @{ Date = '2026-10-02T07:58:03.000Z'; From = '"Alice Martin" <alice.martin@contoso.test>'; Subject = 'Agenda - migration workshop'; Read = '1' }
    @{ Date = '2026-10-01T16:22:47.000Z'; From = '"Bob Durand" <bob.durand@contoso.test>'; Subject = 'RE: ActiveSync pilot group'; Read = '1' }
    @{ Date = '2026-10-01T09:05:30.000Z'; From = '"Exchange Team" <exchange@contoso.test>'; Subject = 'Maintenance window this weekend'; Read = '1' }
    @{ Date = '2026-09-30T14:37:19.000Z'; From = '"Carla Petit" <carla.petit@contoso.test>'; Subject = 'Test message from the iPhone'; Read = '1' }
)
Install-SimExchange -Module $module -State $state

$settings = Import-EomConfiguration
$settings.DeviceId = 'B7E21C9A4F6D3E8A1C5B9D2F7A4E6C30'
$settings.AcknowledgePolicy = $true
$settings.TestType = 'Full'
$settings.OutputPath = Join-Path $work 'reports'
$displayed = $settings.Clone()
$displayed.OutputPath = "$shown\reports"

Write-Host 'Console run (simulated Exchange)...'
$records = & {
    Write-EomRunBanner -Settings $displayed -LogPath "$shown\logs\EasOAuthMailbox_20261002.log"
    $script:DocResult = Invoke-EomMailboxTest -Configuration $settings -TestType Full
    Write-EomRunSummary -Result $script:DocResult -ReportText "$shown\reports\EasOAuthMailbox_Full_20261002-150412\EasOAuthMailbox.html" -LogPath "$shown\logs\EasOAuthMailbox_20261002.log"
} 6>&1
$result = $script:DocResult
$report = Export-EomReport -Result $result -OutputPath $settings.OutputPath
Write-Host "  result: $($result.Status), $($result.Steps.Count) checks"
#endregion

#region Console image -----------------------------------------------------------------------------
function ConvertFrom-Ansi([string]$Line) {
    # SGR codes used by the console theme: 0 reset, 1 bold, 90 dim, 97 white, 38;2;r;g;b and 48;2;r;g;b.
    $out = [Text.StringBuilder]::new()
    $fg = $null; $bg = $null; $bold = $false
    foreach ($part in [regex]::Split($Line, '(\x1b\[[0-9;]*m)')) {
        if ($part -match '^\x1b\[([0-9;]*)m$') {
            $codes = @($Matches[1].Split(';') | ForEach-Object { if ($_ -eq '') { 0 } else { [int]$_ } })
            for ($i = 0; $i -lt $codes.Count; $i++) {
                switch ($codes[$i]) {
                    0 { $fg = $null; $bg = $null; $bold = $false }
                    1 { $bold = $true }
                    90 { $fg = '#8a8a8a' }
                    97 { $fg = '#ffffff' }
                    38 { $fg = 'rgb({0},{1},{2})' -f $codes[$i + 2], $codes[$i + 3], $codes[$i + 4]; $i += 4 }
                    48 { $bg = 'rgb({0},{1},{2})' -f $codes[$i + 2], $codes[$i + 3], $codes[$i + 4]; $i += 4 }
                }
            }
            continue
        }
        if ($part -eq '') { continue }
        $style = @()
        if ($fg) { $style += "color:$fg" }
        if ($bg) { $style += "background:$bg" }
        if ($bold) { $style += 'font-weight:700' }
        $text = [Net.WebUtility]::HtmlEncode($part)
        [void]$out.Append($(if ($style) { "<span style=""$($style -join ';')"">$text</span>" } else { $text }))
    }
    return $out.ToString()
}

function Save-Console([object[]]$Records, [string]$Command, [string]$Name) {
    $lines = foreach ($r in $Records) {
        $data = if ($r -is [Management.Automation.InformationRecord]) { $r.MessageData } else { $r }
        if ($data -is [Management.Automation.HostInformationMessage]) { [string]$data.Message } else { [string]$data }
    }
    $body = ($lines | ForEach-Object { ConvertFrom-Ansi $_ }) -join "`n"
    $console = @"
<!doctype html><html><head><meta charset="utf-8"><style>
body { margin:0; background:#ffffff; font-family:"Segoe UI", sans-serif; }
.win { width:1180px; margin:0; border-radius:10px; overflow:hidden; background:#0c0c0c; border:1px solid #2b2b2b; }
.bar { display:flex; align-items:center; gap:10px; height:38px; padding:0 14px; background:#202020; color:#d0d0d0; font-size:12.5px; }
.tab { padding:6px 14px; background:#0c0c0c; border-radius:8px 8px 0 0; margin-top:8px; }
pre { margin:0; padding:14px 18px 18px; color:#cccccc; font:13.5px/1.42 "Cascadia Mono", Consolas, monospace; white-space:pre-wrap; word-break:break-all; }
.prompt { color:#cccccc; }
</style></head><body><div class="win"><div class="bar"><span class="tab">PowerShell 7.4</span></div>
<pre><span class="prompt">PS $shown&gt; $([Net.WebUtility]::HtmlEncode($Command))</span>
$body</pre></div>
<script>document.body.setAttribute('data-h', Math.ceil(document.querySelector('.win').getBoundingClientRect().height) + 2);</script></body></html>
"@
    $page = Join-Path $work "$Name.html"
    [IO.File]::WriteAllText($page, $console, [Text.UTF8Encoding]::new($false))
    Save-Page $page $Name 1182
}

Write-Host 'Images:'
Save-Console $records '.\Invoke-EasOAuthMailbox.ps1 -TestType Full -AcknowledgePolicy' 'eas-console'

# AppleMail: the same simulated Exchange, seen by the Mail app of an iPhone (token of the Apple client).
$appleState = New-SimState
$appleState.RequireProvisioning = $true
$appleState.CertificateDays = 21
$appleState.Folders = $state.Folders
$appleState.Policy = $state.Policy
$appleState.Messages = $state.Messages
$appleState.ValidToken = New-SimToken -AppId 'f8d98a96-0999-43f5-8af3-69971c7bb423'
Install-SimExchange -Module $module -State $appleState
$appleSettings = $settings.Clone()
$appleSettings.TestType = 'AppleMail'
$appleSettings.DeviceId = ''
$appleDisplayed = $appleSettings.Clone()
$appleDisplayed.OutputPath = "$shown\reports"
$appleRecords = & {
    Write-EomRunBanner -Settings $appleDisplayed -LogPath "$shown\logs\EasOAuthMailbox_20261002.log"
    $script:AppleResult = Invoke-EomMailboxTest -Configuration $appleSettings -TestType AppleMail
    Write-EomRunSummary -Result $script:AppleResult -ReportText "$shown\reports\EasOAuthMailbox_AppleMail_20261002-151208\EasOAuthMailbox.html" -LogPath "$shown\logs\EasOAuthMailbox_20261002.log"
} 6>&1
Write-Host "  AppleMail result: $($script:AppleResult.Status), $($script:AppleResult.Steps.Count) checks"
Save-Console $appleRecords '.\Invoke-EasOAuthMailbox.ps1 -TestType AppleMail -AcknowledgePolicy' 'eas-console-apple'

# Basic: a mailbox without OAuth (legacy user); the password is typed at the prompt of Get-Credential.
$basicState = New-SimState
$basicState.RequireProvisioning = $true
$basicState.CertificateDays = 21
$basicState.MailboxOAuth = 'Blocked'
$basicState.Folders = $state.Folders
$basicState.Policy = $state.Policy
$basicState.Messages = $state.Messages
Install-SimExchange -Module $module -State $basicState
$basicSettings = $settings.Clone()
$basicSettings.Authentication = 'Basic'
$basicSettings.TestType = 'Full'
$basicSettings.DeviceId = ''
$basicDisplayed = $basicSettings.Clone()
$basicDisplayed.OutputPath = "$shown\reports"
$basicUser = [string]$basicSettings.Mailbox
$basicCredential = [pscredential]::new($basicUser, (ConvertTo-SecureString $basicState.BasicUsers[$basicUser] -AsPlainText -Force))
$basicRecords = & {
    Write-EomRunBanner -Settings $basicDisplayed -LogPath "$shown\logs\EasOAuthMailbox_20261002.log"
    Write-EomItem Info "Basic authentication: password of $basicUser (UPN or DOMAIN\user), sent with every request and never written." -Icon Key
    Write-Host ''
    Write-Host 'PowerShell credential request'
    Write-Host "EAS OAuth Mailbox - Basic authentication for $basicUser"
    Write-Host "Password for user $($basicUser): *************"
    $script:BasicResult = Invoke-EomMailboxTest -Configuration $basicSettings -TestType Full -Credential $basicCredential
    Write-EomRunSummary -Result $script:BasicResult -ReportText "$shown\reports\EasOAuthMailbox_Full_20261002-152031\EasOAuthMailbox.html" -LogPath "$shown\logs\EasOAuthMailbox_20261002.log"
} 6>&1
Write-Host "  Basic result: $($script:BasicResult.Status), $($script:BasicResult.Steps.Count) checks"
Save-Console $basicRecords '.\Invoke-EasOAuthMailbox.ps1 -TestType Full -Authentication Basic -AcknowledgePolicy' 'eas-console-basic'
$basicReport = Export-EomReport -Result $script:BasicResult -OutputPath (Join-Path $work 'reports-basic')

# Hybrid modern authentication: Exchange sends the clients to Entra ID (tenant of the simulated organisation).
$entraState = New-SimState
$entraState.RequireProvisioning = $true
$entraState.CertificateDays = 21
$entraState.Authority = 'EntraID'
$entraState.ValidToken = New-SimEntraToken
$entraState.TokenPendingPolls = 1
$entraState.Folders = $state.Folders
$entraState.Policy = $state.Policy
$entraState.Messages = $state.Messages
Install-SimExchange -Module $module -State $entraState
$entraSettings = $settings.Clone()
$entraSettings.Authority = 'EntraID'
$entraSettings.AdfsUrl = ''
$entraSettings.TestType = 'Full'
$entraDisplayed = $entraSettings.Clone()
$entraDisplayed.OutputPath = "$shown\reports"
$entraRecords = & {
    Write-EomRunBanner -Settings $entraDisplayed -LogPath "$shown\logs\EasOAuthMailbox_20261003.log"
    $script:EntraResult = Invoke-EomMailboxTest -Configuration $entraSettings -TestType Full
    Write-EomRunSummary -Result $script:EntraResult -ReportText "$shown\reports\EasOAuthMailbox_Full_20261003-201846\EasOAuthMailbox.html" -LogPath "$shown\logs\EasOAuthMailbox_20261003.log"
} 6>&1
Write-Host "  Entra ID result: $($script:EntraResult.Status), $($script:EntraResult.Steps.Count) checks"
Save-Console $entraRecords '.\Invoke-EasOAuthMailbox.ps1 -TestType Full -Authority EntraID -AcknowledgePolicy' 'eas-console-entra'

# Exchange Online: the same Entra ID sign-in, the URL of Exchange Online, ActiveSync 16.1 only.
$onlineUrl = 'https://outlook.office365.com/Microsoft-Server-ActiveSync'
$onlineState = New-SimState
$onlineState.Online = $true
$onlineState.ValidToken = New-SimEntraToken -Audience 'https://outlook.office365.com'
$onlineState.Folders = $state.Folders
$onlineState.Messages = $state.Messages
Install-SimExchange -Module $module -State $onlineState
$onlineSettings = $entraSettings.Clone()
$onlineSettings.EasUrl = $onlineUrl
$onlineDisplayed = $onlineSettings.Clone()
$onlineDisplayed.OutputPath = "$shown\reports"
$onlineRecords = & {
    Write-EomRunBanner -Settings $onlineDisplayed -LogPath "$shown\logs\EasOAuthMailbox_20261005.log"
    $script:OnlineResult = Invoke-EomMailboxTest -Configuration $onlineSettings -TestType Full
    Write-EomRunSummary -Result $script:OnlineResult -ReportText "$shown\reports\EasOAuthMailbox_Full_20261005-153307\EasOAuthMailbox.html" -LogPath "$shown\logs\EasOAuthMailbox_20261005.log"
} 6>&1
Write-Host "  Exchange Online result: $($script:OnlineResult.Status), $($script:OnlineResult.Steps.Count) checks"
Save-Console $onlineRecords ".\Invoke-EasOAuthMailbox.ps1 -TestType Full -Authority EntraID -EasUrl $onlineUrl -AcknowledgePolicy" 'eas-console-online'
Install-SimExchange -Module $module -State $state
#endregion

#region Report images -----------------------------------------------------------------------------
$reportHtml = [IO.File]::ReadAllText($report.Files.Html)
$reportHtml = $reportHtml.Replace([Net.WebUtility]::HtmlEncode($settings.OutputPath), "$shown\reports")
$basicHtml = [IO.File]::ReadAllText($basicReport.Files.Html)
function Save-ReportView([string]$Name, [string]$Css, [string]$Script, [int]$Height = 0, [string]$Html = $reportHtml) {
    # Height of the body itself: documentElement.scrollHeight is never smaller than the window.
    $measure = "document.body.setAttribute('data-h', Math.ceil(document.body.getBoundingClientRect().height));"
    $inject = "<style>$Css</style><script>window.addEventListener('load', () => { $Script; setTimeout(() => { $measure }, 50); });</script></body>"
    $page = Join-Path $work "$Name.html"
    [IO.File]::WriteAllText($page, $Html.Replace('</body>', $inject), [Text.UTF8Encoding]::new($false))
    Save-Page $page $Name 1280 $Height
}
Save-ReportView 'eas-report-overview' 'section.block:nth-of-type(n+2), footer { display:none !important; } body { padding-bottom:8px; }' ''
Save-ReportView 'eas-report-basic' 'section.block:nth-of-type(n+2), footer { display:none !important; } body { padding-bottom:8px; }' '' -Html $basicHtml
Save-ReportView 'eas-report-checks' 'header, section.block:nth-of-type(1), section.block:nth-of-type(n+3), footer { display:none !important; } body { padding-top:20px; padding-bottom:8px; }' ''
Save-ReportView 'eas-report-detail' 'body { min-height:820px; }' "Array.from(document.querySelectorAll('.timeline > li')).find(li => li.querySelector('.what').textContent === 'Token claims').click()" 820
Save-ReportView 'eas-report-exchange' 'body { min-height:980px; } dialog { max-height:none; } .dialog-body { max-height:none; }' "Array.from(document.querySelectorAll('.timeline > li')).find(li => li.querySelector('.what').textContent === 'OAuth for the mailbox').click()" 980
#endregion

#region Window image -----------------------------------------------------------------------------
Write-Host 'Window run (simulated Exchange)...'
function Save-Window([hashtable]$Configuration, [string]$Name, [string]$Password, [string]$Theme = 'Light') {
    $window = New-EomTestForm -Configuration $Configuration -Theme $Theme
    $form = $window.Form
    # Off screen, at its design size (the work area of this computer does not matter for the image).
    $form.WindowStartupLocation = 'Manual'
    $form.Left = -6000; $form.Top = -6000; $form.Width = 1180; $form.Height = 860
    $form.ShowActivated = $false; $form.ShowInTaskbar = $false
    $form.Show()
    if ($Password) { $window.Controls.BasicPassword.Password = $Password }
    & $module { Invoke-EomGuiRun } 6>$null
    # Anonymised paths in the progress and the footer.
    for ($i = 0; $i -lt $window.Items.Count; $i++) {
        $item = $window.Items[$i]
        if ($item.Text.Contains($Configuration.OutputPath)) { $copy = $item.PSObject.Copy(); $copy.Text = $item.Text.Replace($Configuration.OutputPath, "$shown\reports"); $window.Items[$i] = $copy }
    }
    $window.Controls.Footer.Text = $window.Controls.Footer.Text.Replace($Configuration.OutputPath, "$shown\reports")
    $window.Controls.LogScroll.ScrollToHome()
    & $module { Invoke-EomGuiPump }
    $form.UpdateLayout()
    $root = $form.Content
    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new([int][Math]::Ceiling($root.ActualWidth), [int][Math]::Ceiling($root.ActualHeight), 96, 96, [Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)
    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream = [IO.File]::Create((Join-Path $OutputFolder "$Name.png"))
    try { $encoder.Save($stream) } finally { $stream.Dispose() }
    Write-Host ("  {0,-26} {1} x {2} ({3})" -f "$Name.png", $bitmap.PixelWidth, $bitmap.PixelHeight, $Theme)
    $form.Close()
}
Save-Window $settings.Clone() 'eas-gui'
Install-SimExchange -Module $module -State $basicState
Save-Window $basicSettings.Clone() 'eas-gui-basic' $basicState.BasicUsers[$basicUser] -Theme Dark
#endregion

Remove-Module EasOAuthMailbox -Force
Remove-Item Env:\EOM_FORCE_COLOR, Env:\EOM_ICONS -ErrorAction SilentlyContinue
if ($KeepWork) { Write-Host "Work folder: $work" } else { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }
