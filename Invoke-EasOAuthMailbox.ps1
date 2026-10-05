<#
.SYNOPSIS
    EAS OAuth Mailbox - diagnostic of Exchange ActiveSync with OAuth (AD FS), step by step.

.DESCRIPTION
    Runs one scenario and tells exactly which step works and which one does not:

      Discovery     no sign-in: AD FS metadata, TLS certificates, OAuth challenge advertised by
                    ActiveSync, rejection of an invalid token
      OAuth         AD FS sign-in (window or device code), claims of the token (audience, scope, expiry, user)
      Endpoint      + ActiveSync OPTIONS with the token (Exchange version, protocols, commands)
      FolderSync    + folder hierarchy of the mailbox (provisioning only when authorised)
      Provisioning  + download of the ActiveSync policy, acknowledgement when authorised
      Identity      + addresses Exchange resolves for the signed-in user (Settings)
      InboxSync     + Inbox headers (date, sender, subject; no body, no attachment)
      Full          every check, in order
      AppleMail     the account added like the Mail app of an iPhone: Autodiscover, AD FS found in
                    the Exchange challenge, Apple Mail client in AD FS, sign-in with that client,
                    then ActiveSync 16.1 as DeviceType iPhone (folders, identity, Inbox headers)

    -Authentication Basic runs the same scenarios with a user name and password instead of AD FS,
    like a device without modern authentication: the AD FS sign-in is replaced by a Basic sign-in,
    Discovery checks that Basic is offered, AppleMail checks that the iPhone would ask for the password.

    -Authority EntraID tests a sign-in with Entra ID: Exchange on-premises with hybrid modern authentication
    (HMA) sends the clients to Entra ID instead of AD FS, and Exchange Online always does (-EasUrl
    https://outlook.office365.com/Microsoft-Server-ActiveSync). Discovery checks the tenant, the user realm and the tenant Exchange trusts; the
    sign-in uses Entra ID. -Authority Auto takes the server Exchange names, like a client.

    The OAuth sign-in opens a window (Microsoft Edge or Google Chrome, temporary profile) on the page of
    AD FS or Entra ID: the user types the password and the MFA there, like in a mail app. Without a
    desktop or a browser (service, SSH, Server Core), or with -SignIn DeviceCode, a code is typed on any device.

    Writes CSV, JSON and HTML report files in a new folder, and a daily log file.
    Everything is set in config\EasOAuthMailbox.config.psd1; the parameters below override it.
    The access token and the Basic password stay in memory and are never written anywhere.

.PARAMETER TestType
    Scenario. Default: Test.DefaultType of the configuration.

.PARAMETER Authentication
    OAuth (AD FS sign-in) or Basic (user name and password). Default: Test.Authentication.
    The OAuth scenario needs OAuth.

.PARAMETER Credential
    Basic only: user name (UPN or DOMAIN\user) and password. Without it, the password is asked
    at start (user name proposed: Target.BasicUser, else the mailbox). Not needed by Discovery.

.PARAMETER Authority
    Authorization server of the OAuth sign-in: ADFS (Target.AdfsUrl), EntraID (Exchange on-premises
    with hybrid modern authentication, or Exchange Online) or Auto (the one Exchange names in its challenge). Default: Target.Authority.

.PARAMETER TenantId
    EntraID: tenant ID or a domain of the tenant. Default: Target.TenantId, else the domain of the mailbox.

.PARAMETER SignIn
    How the OAuth sign-in happens: Window (sign-in window, authorization code), DeviceCode (a code
    typed on any device) or Auto (the window when this session can show one). Default: Test.SignIn.

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
    Token already obtained (integration only): the sign-in is skipped. A token typed on
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
    from Autodiscover and AD FS from Exchange, then the Apple Mail client signs in in the window with
    the redirect URI of the iPhone.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -TestType Full -Authentication Basic -Mailbox legacy@contoso.com -AcknowledgePolicy
    The same diagnostic with Basic authentication: the password is asked at start, then sent with
    every request like a device without modern authentication.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -TestType AppleMail -Authentication Basic -Mailbox legacy@contoso.com -AcknowledgePolicy
    An iPhone on a mailbox without OAuth: Exchange does not offer AD FS, the iPhone asks for the
    password and uses Basic.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -TestType Full -Authority EntraID -Mailbox eas-test@contoso.com -AcknowledgePolicy
    Hybrid modern authentication: tenant found from the domain of the mailbox, sign-in with Entra ID
    in the window (password, MFA), token for the on-premises ActiveSync URL.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -TestType Endpoint -Authority EntraID -SignIn DeviceCode
    The same sign-in with a device code, typed on another device (a server without a browser).

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -TestType Full -Authority EntraID -EasUrl https://outlook.office365.com/Microsoft-Server-ActiveSync -Mailbox eas-test@contoso.com -AcknowledgePolicy
    A mailbox in Exchange Online: the same Entra ID sign-in, token for Exchange Online.

.EXAMPLE
    .\Invoke-EasOAuthMailbox.ps1 -Gui

.NOTES
    Author  : Nicolas Fabert
    Version : 1.2.0
    Exit codes : 0 = Passed, 1 = Failed, 2 = finished with warnings or blocked (policy not acknowledged).
    Documentation : docs\EasOAuthMailbox-Guide.html (source: docs\EasOAuthMailbox-Guide.md)
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Discovery', 'OAuth', 'Endpoint', 'FolderSync', 'Provisioning', 'Identity', 'InboxSync', 'Full', 'AppleMail')]
    [string]$TestType,
    [ValidateSet('OAuth', 'Basic')]
    [string]$Authentication,
    [pscredential]$Credential,
    [ValidateSet('ADFS', 'EntraID', 'Auto')]
    [string]$Authority,
    [string]$TenantId,
    [ValidateSet('Auto', 'Window', 'DeviceCode')]
    [string]$SignIn,
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
    if ($Authentication) { $settings.Authentication = $Authentication }
    if ($Authority) { $settings.Authority = $Authority }
    if ($TenantId) { $settings.TenantId = $TenantId }
    if ($SignIn) { $settings.SignIn = $SignIn }
    if ($Credential) { $settings.BasicUser = $Credential.UserName }
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

        # Basic: the password is asked here, kept in memory for this run only.
        $signsIn = (Get-EomTestCatalog | Where-Object Name -eq $settings.TestType).Stages -contains 'OAuth'
        if ($settings.Authentication -eq 'Basic' -and $signsIn -and -not $Credential) {
            $user = if ($settings.BasicUser) { [string]$settings.BasicUser } else { [string]$settings.Mailbox }
            Write-EomItem Info "Basic authentication: password of $user (UPN or DOMAIN\user), sent with every request and never written." -Icon Key
            $Credential = Get-Credential -UserName $user -Message "EAS OAuth Mailbox - Basic authentication for $($settings.Mailbox)"
            if (-not $Credential) { throw 'No user name and password entered: the Basic test cannot run.' }
        }

        $result = Invoke-EomMailboxTest -Configuration $settings -TestType $settings.TestType -AccessToken $AccessToken -Credential $Credential

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
