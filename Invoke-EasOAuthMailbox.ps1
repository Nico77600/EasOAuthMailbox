<#
.SYNOPSIS
    EAS OAuth Mailbox - diagnostic of Exchange ActiveSync with OAuth (AD FS), step by step.

.DESCRIPTION
    Runs one scenario and tells exactly which step works and which one does not:

      Discovery     no sign-in: AD FS metadata, TLS certificates, OAuth challenge advertised by
                    ActiveSync, rejection of an invalid token
      OAuth         AD FS device-code sign-in, claims of the token (audience, scope, expiry, user)
      Endpoint      + ActiveSync OPTIONS with the token (Exchange version, protocols, commands)
      FolderSync    + folder hierarchy of the mailbox (provisioning only when authorised)
      Provisioning  + download of the ActiveSync policy, acknowledgement when authorised
      Identity      + addresses Exchange resolves for the signed-in user (Settings)
      InboxSync     + Inbox headers (date, sender, subject; no body, no attachment)
      Full          every check, in order
      AppleMail     the account added like the Mail app of an iPhone: Autodiscover, AD FS found in
                    the Exchange challenge, Apple Mail client in AD FS, sign-in with that client,
                    then ActiveSync 16.1 as DeviceType iPhone (folders, identity, Inbox headers)

    Writes CSV, JSON and HTML report files in a new folder, and a daily log file.
    Everything is set in config\EasOAuthMailbox.config.psd1; the parameters below override it.
    The access token stays in memory and is never written anywhere.

.PARAMETER TestType
    Scenario. Default: Test.DefaultType of the configuration.

.PARAMETER Gui
    Opens the window: same scenarios, same report, progress shown live.

.PARAMETER AcknowledgePolicy
    Allows the acknowledgement of the ActiveSync policy if Exchange requires provisioning.
    Test mailbox only. Without it, the policy is downloaded for review and the run is Blocked.

.PARAMETER AdfsUrl
    Overrides Target.AdfsUrl. Not used by AppleMail: like the iPhone, it reads AD FS in the Exchange challenge.

.PARAMETER EasUrl
    Overrides Target.EasUrl. AppleMail finds the ActiveSync URL with Autodiscover, like the iPhone,
    and uses this one only when Autodiscover does not answer (the server the user would type).

.PARAMETER Mailbox
    Overrides Target.Mailbox.

.PARAMETER DeviceId
    Overrides Device.DeviceId.

.PARAMETER MessageCount
    Overrides Test.MessageCount.

.PARAMETER OutputPath
    Overrides Report.OutputPath.

.PARAMETER NoReport
    No report file (console and log only).

.PARAMETER AccessToken
    Token already obtained (integration only): the device-code sign-in is skipped. A token typed on
    the command line can stay in the PowerShell history.

.PARAMETER ConfigPath
    Configuration file. Default: config\EasOAuthMailbox.config.psd1.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -TestType Discovery
    Prerequisites without any sign-in.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -TestType Full
    Complete diagnostic of the mailbox of the configuration.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -TestType InboxSync -Mailbox eas-test@contoso.com -AcknowledgePolicy
    Inbox headers of a test mailbox, acknowledging the ActiveSync policy if Exchange requires it.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -TestType AppleMail -Mailbox eas-test@contoso.com -AcknowledgePolicy
    The path of an iPhone adding the account: only the address is given, the ActiveSync URL comes
    from Autodiscover and AD FS from Exchange, then the Apple Mail client of AD FS signs in.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -Gui

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
    Exit codes : 0 = Passed, 1 = Failed, 2 = finished with warnings or blocked (policy not acknowledged).
    Documentation : docs\EasOAuthMailbox-Guide.html (source: docs\EasOAuthMailbox-Guide.md)
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Discovery', 'OAuth', 'Endpoint', 'FolderSync', 'Provisioning', 'Identity', 'InboxSync', 'Full', 'AppleMail')]
    [string]$TestType,
    [switch]$Gui,
    [switch]$AcknowledgePolicy,
    [string]$AdfsUrl,
    [string]$EasUrl,
    [string]$Mailbox,
    [string]$DeviceId,
    [int]$MessageCount,
    [string]$OutputPath,
    [switch]$NoReport,
    [string]$AccessToken,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\EasOAuthMailbox.config.psd1')
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$exitCode = 1
$moduleLoaded = $false

try {
    Import-Module (Join-Path $PSScriptRoot 'EasOAuthMailbox.psd1') -Force
    $moduleLoaded = $true

    # ---- configuration, then command-line overrides ---------------------------------------------
    $settings = Import-EomConfiguration -Path $ConfigPath -Root $PSScriptRoot
    if ($TestType) { $settings.TestType = $TestType }
    if ($AdfsUrl) { $settings.AdfsUrl = $AdfsUrl }
    if ($EasUrl) { $settings.EasUrl = $EasUrl }
    if ($Mailbox) { $settings.Mailbox = $Mailbox }
    if ($DeviceId) { $settings.DeviceId = $DeviceId }
    if ($PSBoundParameters.ContainsKey('MessageCount')) { $settings.MessageCount = $MessageCount }
    if ($OutputPath) { $settings.OutputPath = [IO.Path]::GetFullPath($OutputPath, (Get-Location).Path) }
    if ($PSBoundParameters.ContainsKey('AcknowledgePolicy')) { $settings.AcknowledgePolicy = [bool]$AcknowledgePolicy }
    $check = Test-EomConfiguration -Configuration $settings
    if (-not $check.IsValid) { throw ("Invalid value:`n - " + ($check.Problems -join "`n - ")) }

    $logPath = Start-EomLog -Directory $settings.LogPath -RetentionDays $settings.LogRetentionDays

    if ($Gui) {
        Write-EomLog 'STEP' "=== EAS OAuth Mailbox - window opened ==="
        Show-EomTestGui -Configuration $settings
        $exitCode = 0
    }
    else {
        Write-EomRunBanner -Settings $settings -LogPath $logPath -NoReport:$NoReport
        if ($AccessToken) { Write-EomItem Warn 'An access token was passed on the command line: it can stay in the PowerShell history.' }

        $result = Invoke-EomMailboxTest -Configuration $settings -TestType $settings.TestType -AccessToken $AccessToken

        $reportText = 'none (-NoReport)'
        if (-not $NoReport) {
            $report = Export-EomReport -Result $result -OutputPath $settings.OutputPath -Prefix $settings.ReportPrefix -Formats $settings.ReportFormats -Delimiter $settings.CsvDelimiter
            $reportText = if ($report.Files.Contains('Html')) { $report.Files.Html } else { $report.Directory }
        }
        Write-EomRunSummary -Result $result -ReportText $reportText -LogPath $logPath
        $exitCode = switch ($result.Status) { 'Passed' { 0 } 'Failed' { 1 } default { 2 } }
    }
}
catch {
    if ($moduleLoaded) {
        Write-EomItem Fail $_.Exception.Message
        Write-Host ''
    }
    else {
        Write-Host "EAS OAuth Mailbox: $($_.Exception.Message)" -ForegroundColor Red
    }
    $exitCode = 1
}
finally {
    if ($moduleLoaded) { Stop-EomLog }
    [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
}
exit $exitCode
