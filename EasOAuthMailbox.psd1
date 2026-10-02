#
#  EAS OAuth Mailbox - module manifest
#  --------------------------------------------------------------------------
#  Author  : Nicolas Fabert
#  Version : see ModuleVersion
#
#  Loaded by Invoke-EasOAuthMailbox.ps1 (Import-Module by path).
#
@{
    RootModule        = 'EasOAuthMailbox.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'a1a21a3b-4bb7-4f7c-9f7e-5d6e7b8c9012'
    Author            = 'Nicolas Fabert'
    Copyright         = '(c) 2026 Nicolas Fabert. MIT License.'
    Description       = 'EAS OAuth Mailbox: step-by-step diagnostic of Exchange ActiveSync with OAuth (AD FS) - prerequisites, sign-in and token claims, endpoint, provisioning, folders, identity and Inbox headers - with CSV, JSON and HTML reports and a window to choose the scenario.'
    PowerShellVersion = '7.4'

    # Functions called by Invoke-EasOAuthMailbox.ps1, the tests and the documentation tool. The other functions stay internal.
    FunctionsToExport = @(
        'Import-EomConfiguration', 'Test-EomConfiguration', 'Test-EomEndpoint', 'Get-EomTestCatalog', 'Get-EomDeviceId', 'Resolve-EomClientSettings'
        'Invoke-EomMailboxTest', 'Export-EomReport', 'Show-EomTestGui', 'New-EomTestForm'
        'Start-EomLog', 'Stop-EomLog', 'Write-EomLog', 'Write-EomBanner', 'Write-EomStep', 'Write-EomItem', 'Write-EomSummary', 'Write-EomRunBanner', 'Write-EomRunSummary', 'Format-EomDuration'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('Exchange', 'ActiveSync', 'OAuth', 'ADFS', 'ModernAuthentication', 'Diagnostic')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
