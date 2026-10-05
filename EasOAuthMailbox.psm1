<#
.SYNOPSIS
    EAS OAuth Mailbox - PowerShell module.

.DESCRIPTION
    Loads the parts of the tool, in the order of an execution:

        src\EasOAuthMailbox.Console.ps1   console output and log file (same rules as Exchange Log Report)
        src\EasOAuthMailbox.Config.ps1    configuration file and scenarios
        src\EasOAuthMailbox.Http.ps1      HTTP requests and their trace (request sent, response received)
        src\EasOAuthMailbox.Core.ps1      ActiveSync protocol: WBXML, requests, provisioning
        src\EasOAuthMailbox.Checks.ps1    sign-in, checks and Invoke-EomMailboxTest
        src\EasOAuthMailbox.Report.ps1    CSV, JSON and HTML report
        src\EasOAuthMailbox.Browser.ps1   sign-in window (Edge or Chrome, DevTools protocol)
        src\EasOAuthMailbox.Gui.ps1       WPF window (Fluent theme of Windows 11)

    The access token and the Basic password stay in memory: they are never written to the console,
    the log or the report.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.2.0
    History : see CHANGELOG.md
#>
#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http

$script:ToolVersion = '1.2.0'
$script:ToolRoot = $PSScriptRoot
$script:EomUserAgent = 'EasOAuthMailbox/1.0'
# Authentication of the current run: 'OAuth' (access token) or 'Basic' (user name and password).
$script:EomAuthentication = 'OAuth'
# User name of the deliberately wrong Basic credentials (Discovery): a user that does not exist,
# so that no real account is ever locked by the test.
$script:InvalidBasicUserPrefix = 'eom-invalid-'
# Device the requests describe (MS-ASProtocolVersion header, Provision DeviceInformation): the tool
# by default, an iPhone for the AppleMail scenario (Resolve-EomClientSettings).
$script:EomDevice = @{ ProtocolVersion = '14.1'; Model = 'EAS OAuth Mailbox'; FriendlyName = "$env:COMPUTERNAME EAS OAuth Mailbox"; OS = [Environment]::OSVersion.VersionString }
$script:LogWriter = $null
$script:LogPath = $null
$script:Quiet = $false
# GUI hooks, set only while the window runs a test: Sink (progress lines), Pump (keeps the window responsive), Cancel.
$script:Ui = $null

foreach ($part in 'Console', 'Config', 'Http', 'Core', 'Checks', 'Browser', 'Report', 'Gui') {
    . (Join-Path $PSScriptRoot "src\EasOAuthMailbox.$part.ps1")
}

# Unsigned token with a wrong audience: Exchange must answer 401 (Discovery scenario).
$script:InvalidToken = '{0}.{1}.{2}' -f (ConvertTo-EomBase64Url ([Text.Encoding]::UTF8.GetBytes('{"alg":"none","typ":"JWT"}'))),
    (ConvertTo-EomBase64Url ([Text.Encoding]::UTF8.GetBytes('{"aud":"https://invalid.example/","iss":"eas-oauth-mailbox","exp":1}'))),
    (ConvertTo-EomBase64Url ([Text.Encoding]::UTF8.GetBytes('invalid')))

Export-ModuleMember -Function @(
    'Import-EomConfiguration', 'Test-EomConfiguration', 'Test-EomEndpoint', 'Get-EomTestCatalog', 'Get-EomDeviceId', 'Resolve-EomClientSettings'
    'Invoke-EomMailboxTest', 'Export-EomReport', 'Show-EomTestGui', 'New-EomTestForm'
    'Start-EomLog', 'Stop-EomLog', 'Write-EomLog', 'Write-EomBanner', 'Write-EomStep', 'Write-EomItem', 'Write-EomSummary', 'Write-EomRunBanner', 'Write-EomRunSummary', 'Format-EomDuration'
)
