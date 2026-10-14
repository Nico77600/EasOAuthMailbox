<#
.SYNOPSIS
    Mobile Device Client for Exchange - diagnostic of Exchange ActiveSync with OAuth (AD FS), step by step.

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
    Everything is set in config\MobileDeviceClient.config.psd1; the parameters below override it.
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
    Configuration file. Default: config\MobileDeviceClient.config.psd1.

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -TestType Discovery
    Prerequisites without any sign-in.

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -TestType Full
    Complete diagnostic of the mailbox of the configuration.

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -TestType InboxSync -Mailbox eas-test@contoso.com -AcknowledgePolicy
    Inbox headers of a test mailbox, acknowledging the ActiveSync policy if Exchange requires it.

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -TestType AppleMail -Mailbox eas-test@contoso.com -AcknowledgePolicy
    The path of an iPhone adding the account: only the address is given, the ActiveSync URL comes
    from Autodiscover and AD FS from Exchange, then the Apple Mail client signs in in the window with
    the redirect URI of the iPhone.

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -TestType Full -Authentication Basic -Mailbox legacy@contoso.com -AcknowledgePolicy
    The same diagnostic with Basic authentication: the password is asked at start, then sent with
    every request like a device without modern authentication.

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -TestType AppleMail -Authentication Basic -Mailbox legacy@contoso.com -AcknowledgePolicy
    An iPhone on a mailbox without OAuth: Exchange does not offer AD FS, the iPhone asks for the
    password and uses Basic.

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -TestType Full -Authority EntraID -Mailbox eas-test@contoso.com -AcknowledgePolicy
    Hybrid modern authentication: tenant found from the domain of the mailbox, sign-in with Entra ID
    in the window (password, MFA), token for the on-premises ActiveSync URL.

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -TestType Endpoint -Authority EntraID -SignIn DeviceCode
    The same sign-in with a device code, typed on another device (a server without a browser).

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -TestType Full -Authority EntraID -EasUrl https://outlook.office365.com/Microsoft-Server-ActiveSync -Mailbox eas-test@contoso.com -AcknowledgePolicy
    A mailbox in Exchange Online: the same Entra ID sign-in, token for Exchange Online.

.EXAMPLE
    .\Invoke-MobileDeviceClient.ps1 -Gui

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.0
    Exit codes : 0 = Passed, 1 = Failed, 2 = finished with warnings or blocked (policy not acknowledged).
    Documentation : docs\MobileDeviceClient-Guide.html (source: docs\MobileDeviceClient-Guide.md)

    Disclaimer:
    This Script is a Personal project.
    It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

    As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.

    Use a test mailbox: from `FolderSync` on, Exchange registers an ActiveSync device partnership.
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
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config\MobileDeviceClient.config.psd1')
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('en-US')
$exitCode = 1
$moduleLoaded = $false

try {
    Import-Module (Join-Path $PSScriptRoot 'MobileDeviceClient.psd1') -Force
    $moduleLoaded = $true

    # ---- configuration, then command-line overrides ---------------------------------------------
    $settings = Import-MdcConfiguration -Path $ConfigPath -Root $PSScriptRoot
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
    $check = Test-MdcConfiguration -Configuration $settings
    if (-not $check.IsValid) { throw ("Invalid value:`n - " + ($check.Problems -join "`n - ")) }

    $logPath = Start-MdcLog -Directory $settings.LogPath -RetentionDays $settings.LogRetentionDays

    if ($Gui) {
        Write-MdcLog 'STEP' "=== Mobile Device Client for Exchange - window opened ==="
        Show-MdcTestGui -Configuration $settings
        $exitCode = 0
    }
    else {
        Write-MdcRunBanner -Settings $settings -LogPath $logPath -NoReport:$NoReport
        if ($AccessToken) { Write-MdcItem Warn 'An access token was passed on the command line: it can stay in the PowerShell history.' }

        # Basic: the password is asked here, kept in memory for this run only.
        $signsIn = (Get-MdcTestCatalog | Where-Object Name -eq $settings.TestType).Stages -contains 'OAuth'
        if ($settings.Authentication -eq 'Basic' -and $signsIn -and -not $Credential) {
            $user = if ($settings.BasicUser) { [string]$settings.BasicUser } else { [string]$settings.Mailbox }
            Write-MdcItem Info "Basic authentication: password of $user (UPN or DOMAIN\user), sent with every request and never written." -Icon Key
            $Credential = Get-Credential -UserName $user -Message "Mobile Device Client for Exchange - Basic authentication for $($settings.Mailbox)"
            if (-not $Credential) { throw 'No user name and password entered: the Basic test cannot run.' }
        }

        $result = Invoke-MdcMailboxTest -Configuration $settings -TestType $settings.TestType -AccessToken $AccessToken -Credential $Credential

        $reportText = 'none (-NoReport)'
        if (-not $NoReport) {
            $report = Export-MdcReport -Result $result -OutputPath $settings.OutputPath -Prefix $settings.ReportPrefix -Formats $settings.ReportFormats -Delimiter $settings.CsvDelimiter
            $reportText = if ($report.Files.Contains('Html')) { $report.Files.Html } else { $report.Directory }
        }
        Write-MdcRunSummary -Result $result -ReportText $reportText -LogPath $logPath
        $exitCode = switch ($result.Status) { 'Passed' { 0 } 'Failed' { 1 } default { 2 } }
    }
}
catch {
    if ($moduleLoaded) {
        Write-MdcItem Fail $_.Exception.Message
        Write-Host ''
    }
    else {
        Write-Host "Mobile Device Client for Exchange: $($_.Exception.Message)" -ForegroundColor Red
    }
    $exitCode = 1
}
finally {
    if ($moduleLoaded) { Stop-MdcLog }
    [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
}
exit $exitCode

# SIG # Begin signature block
# MIIghAYJKoZIhvcNAQcCoIIgdTCCIHECAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCC33DjIo5HJePTE
# 3TWUDwWqcmmhyQUIv8C2imR9eAFLg6CCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYISazCCEmcCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBt+OK+8GWk
# oehfdRcRwWCYywBirCyY6iJng8dgBiLk0DANBgkqhkiG9w0BAQEFAASCAgAspkj0
# VaNL5AfGK15QpRBgAH69a0RRbEuswlb643CHc1yvXcUEJ6tzWiSrWmRBZDUvgAaH
# /ue57ZfOk2oUyxnSFw+DgZPgKh9DceXcxxOz+lx66kNk5n5SqFPHMBwF4mfoWW+D
# qXvV7EWEoUkOLHrDwWInWFv0cooeUd32QyCmlsMBC4tuN1VANg1KTrLZ1oEYr0NE
# 7/G2zQYUASOg+h8QzM4snt2mmHoCMx/ZJsblUmX1wmlFqk31Xn1IBlR24r97tP33
# hYBL29qhEQ06MCZ7kjc9tNtjkB8d1K58tbEyVhhOXo1w81bKKOHffjIY0g64eamm
# ubjmvrTH0vxR7Obd+2vsgOZ0jH1N0xO/Rcv0CV+FrK9OIJQC0G/d4OhJwMqurzi6
# /PfLUGejENz1+eetu4zuJHEvivB+0zUBbefJlOyzAQXzTopNEtn8OIjQuvZlAE/L
# m+7ScVhaj1tOuyRUB3gr2PnadH/vtV3hb0yQoxicq96vj3sVaefswyaKNzTVDycu
# oDqEKyNFZjl9Monu5d0DEGpd992eFlcHlDVcqK/aG4fJfXALYWY/UX02Lk4ChPfR
# hngRIcKGURXRrnlLx9BLlM8vUBxCwq1V4rFYV5PEEHmtkYaNjH2cakwYR2Clht8e
# uurRmc69CnKb69WPFZsK0wSNM1WeE3Yi9z80zaGCDygwgg8kBgorBgEEAYI3AwMB
# MYIPFDCCDxAGCSqGSIb3DQEHAqCCDwEwgg79AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIDuywEuIu2a1PfS0GB/hC9GcPMZy+FI98L+hoYeNxosvAgg/QFyBYd0p
# 7BgPMjAyNjEwMTQxMTM0NTFaMAMCAQECEGsmglpqmecaLirL/KDZaA2gggwAMIIE
# /DCCAuSgAwIBAgIQH2sWYtIuG2xd8cDBoGAOODANBgkqhkiG9w0BAQsFADBzMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSBSMTAeFw0yNTAyMTgxNjMyMDJaFw0zNDExMTIxODUwMDVa
# MG4xCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3Rv
# bjERMA8GA1UECgwIU1NMIENvcnAxKjAoBgNVBAMMIVNTTC5jb20gVGltZXN0YW1w
# aW5nIFVuaXQgMjAyNSBFMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBv7UVHH
# b+ZVluxPXlfE3M6tg0Xnq8dic+O3vPOCRpalUM1vO9A+GRzSVVjyygHhYrBw62XL
# Fh1kv7e+yRd/aTajggFaMIIBVjAfBgNVHSMEGDAWgBQMnRAljpqnG5mHQ88IfuG9
# gZD0zzBRBggrBgEFBQcBAQRFMEMwQQYIKwYBBQUHMAKGNWh0dHA6Ly9jZXJ0LnNz
# bC5jb20vU1NMLmNvbS10aW1lU3RhbXBpbmctSS1SU0EtUjEuY2VyMFEGA1UdIARK
# MEgwPAYMKwYBBAGCqTABAwYBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNz
# bC5jb20vcmVwb3NpdG9yeTAIBgZngQwBBAIwFgYDVR0lAQH/BAwwCgYIKwYBBQUH
# AwgwRgYDVR0fBD8wPTA7oDmgN4Y1aHR0cDovL2NybHMuc3NsLmNvbS9TU0wuY29t
# LXRpbWVTdGFtcGluZy1JLVJTQS1SMS5jcmwwHQYDVR0OBBYEFM582cAEgMUkEGoJ
# 6hyrJT0R/ajSMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAgHN1
# JIW9ZlNip07FfY9r1LJwLKTl1h/y9r1BjDgHMEz7U7J7mAy32JxA1KLyjCCJqNku
# RfhDHGFEfZtjTOru7AQMDSDiUDvCCc3jaz5py9jGvwIe5npkLbXqXhA+SqCzG719
# USigwhHkYr7v8NiXoaY0Xu03p0BiZZreZlpngmGB9+86N94FqIFx2I5Z5iuu7d4j
# 7aAOZBNxfU9jFDIIGDtWfWeCpF0Q8rLE/3DHDlzJKs5Il3i/VoOl7rTU938oSrxM
# www6GDBlKX8rGHxvkjgIb9MXkVglJSDHsNAZDeCS/inaxKHA+ChuB8K4OxIxa6k1
# e+eHBypakAY3wuN7w7PlPmhN6k5IdqZn3HZHs2VjoR841Z9wmVPFdGDdkBZ7XOmb
# 5OZUaKufsvtER0VbY2DkzaqAaItt1kc+I+FUz7PiVz2PUzpegkftRRxvrPyIL08b
# lJTnbMQ0XrqDN0rEfuTLv4XhhnKyJaXhxCUdjO/cRumMzZ35QTUMItBWy1xGp0iy
# oFVnAya2pPsVMuAI+sy1zxlOS9l5iSxvKJ8gpnpOgjqYTa7u1eyZo+4JlcGoiiR1
# 7LthMTrF1q62tO5xOpI8txUZ6gtKGtkJV6wdj+vZLcwKZ2M93GqVpOo6UBlGjx1s
# KsVZ7AIUzJZli4NJ0M2KYcrfNnlebkYKpDnSqWwwggb8MIIE5KADAgECAhBtUhhw
# h+gjTYVgANCAj5NWMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYD
# VQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBv
# cmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRo
# b3JpdHkgUlNBMB4XDTE5MTExMzE4NTAwNVoXDTM0MTExMjE4NTAwNVowczELMAkG
# A1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYD
# VQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNz
# dWluZyBSU0EgQ0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCu
# URAT0vk8IKAghd7JUBxkyeH9xek0/wp/MUjoclrFXqhh/fGH91Fc+7fm0MHCE7A+
# wmOiqBj9ODrJAYGq3rm33jCnHSsCBNWAQYyoauLq8IjqsS1JlXL29qDNMMdwZ8UN
# zQS7vWZMDJ40JSGNphMGTIA2qn2bohGtgRc4p1395ESypUOaGvJ3t0FNL3BuKmb6
# YctMcQUF2sqooMzd89h0E6ujdvBDo6ZwNnWoxj7YmfWjSXg33A5GuY9ym4QZM5OE
# Vgo8ebz/B+gyhyCLNNhh4Mb/4xvCTCMVmNYrBviGgdPZYrym8Zb84TQCmSuX0JlL
# La6WK1aO6qlwISbb9bVGh866ekKblC/XRP20gAu1CjvcYciUgNTrGFg8f8AJgQPO
# Cc1/CCdaJSYwhJpSdheKOnQgESgNmYZPhFOC6IKaMAUXk5U1tjTcFCgFvvArXtK4
# azAWUOO1Y3fdldIBL6LjkzLUCYJNkFXqhsBVcPMuB0nUDWvLJfPimstjJ8lF4S6E
# CxWnlWi7OElVwTnt1GtRqeY9ydvvGLntU+FecK7DbqHDUd366UreMkSBtzevAc9a
# qoZPnjVMjvFqV1pYOjzmTiVHZtAc80bAfFe5LLfJzPI6DntNyqobpwTevQpHqPDN
# 9qqNO83r3kaw8A9j+HZiSw2AX5cGdQP0kG0vhzfgBwIDAQABo4IBgTCCAX0wEgYD
# VR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV7jiAJQ2m
# WTCBgwYIKwYBBQUHAQEEdzB1MFEGCCsGAQUFBzAChkVodHRwOi8vd3d3LnNzbC5j
# b20vcmVwb3NpdG9yeS9TU0xjb21Sb290Q2VydGlmaWNhdGlvbkF1dGhvcml0eVJT
# QS5jcnQwIAYIKwYBBQUHMAGGFGh0dHA6Ly9vY3Nwcy5zc2wuY29tMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwOwYDVR0fBDQwMjAwoC6gLIYq
# aHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0GA1Ud
# DgQWBBQMnRAljpqnG5mHQ88IfuG9gZD0zzAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZI
# hvcNAQELBQADggIBAJIZdQ2mWkLPGQfZ8vyU+sCb8BXpRJZaL3Ez3VDlE3uZk3cP
# xPtybVfLuqaci0W6SB22JTMttCiQMnIVOsXWnIuAbD/aFTcUkTLBI3xys+wEajzX
# aXJYWACDS47BRjDtYlDW14gLJxf8W6DQoH3jHDGGy8kGJFOlDKG7/YrK7UGfHtBA
# EDVe6lyZ+FtCsrk7dD/IiL/+Q3Q6SFASJLQ2XI89ihFugdYL77CiDNXrI2MFspQG
# swXEAGpHuaQDTHUp/LdR3TyrIsLlnzoLskUGswF/KF8+kpWUiKJNC4rPWtNrxlbX
# YRGgdEdx8SMjUTDClldcrknlFxbqHsVmr9xkT2QtFmG+dEq1v5fsIK0vHaHrWjMM
# maJ9i+4qGJSD0stYfQ6v0PddT7EpGxGd867Ada6FZyHwbuQSadMb0K0P0OC2r7rw
# qBUe0BaMqTa6LWzWItgBjGcObXeMxmbQqlEz2YtAcErkZvh0WABDDE4U8GyV/32F
# daAvJgTfe9MiL2nSBioYe/g5mHUSWAay/Ip1RQmQCvmF9sNfqlhJwkjy/1U1ibUk
# TIUBX3HgymyQvqQTZLLys6pL2tCdWcjI9YuLw30rgZm8+K387L7ycUvqrmQ3ZJlu
# jHl3r1hgV76s3WwMPgKk1bAEFMj+rRXimSC+Ev30hXZdqyMdl/il5Ksd0vhGMYIC
# VzCCAlMCAQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhtsXfHAwaBg
# DjgwCwYJYIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDExMzQ1MVowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIEvOmUm5Hss+
# 6GVknQgDtpoiAN1kDLmmgnhQcvsq4tekMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEYwRAIgSTUnsRjPd/gxyD8A93iVBEblW+81/vMcFtWdfkOi/I0CIEfMbEj79TEg
# zGiKGRWkDRyqpzftlpiWHdB9YoDigu0t
# SIG # End signature block
