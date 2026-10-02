<#
.SYNOPSIS
    EAS OAuth Mailbox - configuration and scenarios (dot-sourced by EasOAuthMailbox.psm1).

.DESCRIPTION
    The configuration file has sections (Target, Device, Test, Report, Logging, AppleMail), like the other
    tools. It is flattened into one settings hashtable used by the CLI, the GUI and the tests;
    unknown sections or keys and invalid values are all reported at once.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
#>

# Section.Key of the configuration file -> key of the settings hashtable.
$script:ConfigSchema = [ordered]@{
    Target  = [ordered]@{ AdfsUrl = 'AdfsUrl'; EasUrl = 'EasUrl'; Mailbox = 'Mailbox'; ClientId = 'ClientId' }
    Device  = [ordered]@{ DeviceId = 'DeviceId'; DeviceType = 'DeviceType'; UserAgent = 'UserAgent' }
    Test    = [ordered]@{
        DefaultType = 'TestType'; MessageCount = 'MessageCount'; AcknowledgePolicy = 'AcknowledgePolicy'
        OAuthPollTimeoutSeconds = 'OAuthPollTimeoutSeconds'; HttpTimeoutSeconds = 'HttpTimeoutSeconds'
        CertificateWarningDays = 'CertificateWarningDays'
    }
    Report  = [ordered]@{ OutputPath = 'OutputPath'; FilePrefix = 'ReportPrefix'; Formats = 'ReportFormats'; CsvDelimiter = 'CsvDelimiter' }
    Logging = [ordered]@{ Path = 'LogPath'; RetentionDays = 'LogRetentionDays' }
    AppleMail = [ordered]@{ ClientId = 'AppleClientId'; UserAgent = 'AppleUserAgent'; DeviceType = 'AppleDeviceType' }
}

# How the Apple Mail app of an iPhone adds an Exchange account with AD FS (trace of iOS 27 on
# Exchange Server SE, 2026-10-02): the setup screen (User-Agent Preferences/...) sends a request
# with an empty Bearer header and the user identity, reads the AD FS authorization URL in the
# 401 challenge, opens AD FS in a web view with its own client, then the Mail account
# (User-Agent Apple-iPhone...) talks ActiveSync 16.1 as DeviceType iPhone.
$script:AppleMail = @{
    SetupUserAgent   = 'Preferences/2027.0.6.101 CFNetwork/3892.100.1 Darwin/27.0.0'
    BrowserUserAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15'
    ProtocolVersion  = '16.1'
    Model            = 'iPhone15C4'
    # Redirect URIs of "iOS and macOS - Native mail application" (Add-AdfsNativeClientApplication),
    # first the one the iPhone sends when the account is added from Settings (without the final '/').
    RedirectUris     = @('com.apple.Preferences://oauth-redirect', 'com.apple.mobilemail://oauth-redirect', 'com.apple.preferences.internetaccounts://oauth-redirect/')
    # Client capability sent by the iPhone in the authorization request.
    Claims           = '{"access_token":{"xms_cc":{"values":["cp1"]}}}'
}

# Scenarios and the stages they run, in order. A stage runs only if no earlier stage failed or was blocked.
$script:Scenarios = @(
    @{ Name = 'Discovery'; DisplayName = 'Prerequisites without sign-in'; Stages = @('Discovery')
       Description = 'AD FS metadata, TLS certificates, OAuth challenge advertised by ActiveSync, rejection of an invalid token. No sign-in, nothing created.' }
    @{ Name = 'OAuth'; DisplayName = 'AD FS sign-in and token'; Stages = @('OAuth')
       Description = 'AD FS device-code sign-in, then the claims of the token: audience, scope, expiry and user.' }
    @{ Name = 'Endpoint'; DisplayName = 'ActiveSync endpoint'; Stages = @('OAuth', 'Endpoint')
       Description = 'Sign-in, then ActiveSync OPTIONS with the token: Exchange version, protocol versions and commands.' }
    @{ Name = 'FolderSync'; DisplayName = 'Mailbox folders'; Stages = @('OAuth', 'Endpoint', 'FolderSync')
       Description = 'Folder hierarchy of the mailbox. If Exchange requires provisioning, the policy is acknowledged only when authorised.' }
    @{ Name = 'Provisioning'; DisplayName = 'ActiveSync policy'; Stages = @('OAuth', 'Endpoint', 'Provisioning', 'FolderSync')
       Description = 'Downloads the ActiveSync mailbox policy, acknowledges it when authorised, then FolderSync with the final policy key.' }
    @{ Name = 'Identity'; DisplayName = 'Mailbox identity'; Stages = @('OAuth', 'Endpoint', 'FolderSync', 'Identity')
       Description = 'Addresses Exchange resolves for the signed-in user (Settings UserInformation), compared with the mailbox.' }
    @{ Name = 'InboxSync'; DisplayName = 'Inbox headers'; Stages = @('OAuth', 'Endpoint', 'FolderSync', 'InboxSync')
       Description = 'Synchronises up to MessageCount Inbox headers: date, sender, subject. No body, no attachment.' }
    @{ Name = 'Full'; DisplayName = 'Complete diagnostic'; Stages = @('Discovery', 'OAuth', 'Endpoint', 'FolderSync', 'Identity', 'InboxSync')
       Description = 'Every check in order: prerequisites, sign-in, endpoint, folders, identity and Inbox headers.' }
    @{ Name = 'AppleMail'; DisplayName = 'Apple Mail on an iPhone'; Client = 'AppleMail'; Stages = @('AppleSetup', 'OAuth', 'Endpoint', 'FolderSync', 'Identity', 'InboxSync')
       Description = 'Adds the account like the Mail app of an iPhone: Autodiscover, AD FS found in the Exchange challenge, Apple Mail client in AD FS, sign-in with that client, then ActiveSync 16.1 as an iPhone.' }
)

$script:StageInfo = @{
    Discovery    = @{ Title = 'Prerequisites without sign-in'; Icon = 'Search' }
    AppleSetup   = @{ Title = 'Account setup like the iPhone (no sign-in)'; Icon = 'Search' }
    OAuth        = @{ Title = 'AD FS sign-in and token'; Icon = 'Key' }
    Endpoint     = @{ Title = 'ActiveSync endpoint with the token'; Icon = 'Server' }
    Provisioning = @{ Title = 'ActiveSync policy'; Icon = 'Shield' }
    FolderSync   = @{ Title = 'Mailbox folders (FolderSync)'; Icon = 'Folder' }
    Identity     = @{ Title = 'Mailbox identity (Settings)'; Icon = 'People' }
    InboxSync    = @{ Title = 'Inbox headers (Sync)'; Icon = 'Mail' }
}

function Get-EomTestCatalog {
    <# The scenarios: name, description, stages, whether they sign in or may create a device partnership. #>
    [CmdletBinding()]
    param()

    foreach ($s in $script:Scenarios) {
        [pscustomobject]@{
            Name               = $s.Name
            DisplayName        = $s.DisplayName
            Description        = $s.Description
            Stages             = @($s.Stages)
            Client             = if ($s.ContainsKey('Client')) { [string]$s['Client'] } else { 'Tool' }
            SignIn             = $s.Stages -contains 'OAuth'
            ChangesServerState = [bool]@($s.Stages | Where-Object { $_ -in 'FolderSync', 'Provisioning', 'Identity', 'InboxSync' }).Count
            CanProvision       = [bool]@($s.Stages | Where-Object { $_ -in 'FolderSync', 'Provisioning' }).Count
        }
    }
}

function Get-EomDefaultConfiguration {
    @{
        AdfsUrl                 = 'https://adfs.contoso.test/adfs'
        EasUrl                  = 'https://mail.contoso.test/Microsoft-Server-ActiveSync'
        Mailbox                 = 'eas-test@contoso.test'
        ClientId                = 'd3590ed6-52b3-4102-aeff-aad2292ab01c'
        DeviceId                = ''
        DeviceType              = 'EasOAuthMailbox'
        UserAgent               = 'EasOAuthMailbox/1.0'
        TestType                = 'Full'
        MessageCount            = 5
        AcknowledgePolicy       = $false
        OAuthPollTimeoutSeconds = 600
        HttpTimeoutSeconds      = 60
        CertificateWarningDays  = 30
        OutputPath              = '.\reports'
        ReportPrefix            = 'EasOAuthMailbox'
        ReportFormats           = @('Csv', 'Html')
        CsvDelimiter            = ';'
        LogPath                 = '.\logs'
        LogRetentionDays        = 14
        AppleClientId           = 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        AppleUserAgent          = 'Apple-iPhone15C4/2401.539000006'
        AppleDeviceType         = 'iPhone'
    }
}

function Resolve-EomClientSettings {
    <#
        Settings of the client a scenario plays. AppleMail: client ID, User-Agent and DeviceType of
        the Apple Mail app, ActiveSync 16.1. Other scenarios: the tool itself, ActiveSync 14.1.
        The DeviceId derives from the DeviceType, so both clients are different devices in Exchange.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    $cfg = Get-EomDefaultConfiguration
    foreach ($key in $Configuration.Keys) { $cfg[$key] = $Configuration[$key] }
    $scenario = $script:Scenarios | Where-Object { $_.Name -eq [string]$cfg.TestType } | Select-Object -First 1
    $cfg.Client = if ($scenario -and $scenario.ContainsKey('Client')) { [string]$scenario['Client'] } else { 'Tool' }
    $cfg.ProtocolVersion = '14.1'
    $cfg.DeviceModel = 'EAS OAuth Mailbox'
    $cfg.DeviceFriendlyName = "$env:COMPUTERNAME EAS OAuth Mailbox"
    $cfg.DeviceOS = [Environment]::OSVersion.VersionString
    if ($cfg.Client -eq 'AppleMail') {
        $cfg.ClientId = [string]$cfg.AppleClientId
        $cfg.UserAgent = [string]$cfg.AppleUserAgent
        $cfg.DeviceType = [string]$cfg.AppleDeviceType
        $cfg.ProtocolVersion = $script:AppleMail.ProtocolVersion
        $cfg.DeviceModel = $script:AppleMail.Model
        # Marked so that the test device is easy to find and remove (Get-MobileDevice | FriendlyName).
        $cfg.DeviceFriendlyName = "iPhone (EAS OAuth Mailbox $env:COMPUTERNAME)"
        $cfg.DeviceOS = 'iOS (simulated by EAS OAuth Mailbox)'
        # The iPhone is never told where AD FS is: it reads it in the Exchange challenge (AppleSetup).
        $cfg.AdfsUrl = ''
    }
    return $cfg
}

function Resolve-EomPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath($Path, $Root)
}

function Test-EomEndpoint {
    <# Checks the shape of the AD FS and ActiveSync URLs (no network call). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$AdfsUrl, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$EasUrl)

    $problems = [Collections.Generic.List[string]]::new()
    $adfsRoot = $AdfsUrl.TrimEnd('/')
    if ($adfsRoot -notmatch '^https://[^/\s]+/') { [void]$problems.Add('Target.AdfsUrl must be an https:// URL.') }
    if (-not $adfsRoot.EndsWith('/adfs', [StringComparison]::OrdinalIgnoreCase)) { [void]$problems.Add('Target.AdfsUrl must end with /adfs (for example https://adfs.contoso.com/adfs).') }

    $easUri = $null
    if (-not [Uri]::TryCreate($EasUrl, [UriKind]::Absolute, [ref]$easUri)) {
        [void]$problems.Add('Target.EasUrl is not an absolute URL.')
    }
    else {
        if ($easUri.Scheme -ne 'https') { [void]$problems.Add('Target.EasUrl must be an https:// URL.') }
        if ($easUri.AbsolutePath -notmatch '^/Microsoft-Server-ActiveSync/?$') { [void]$problems.Add('Target.EasUrl must target /Microsoft-Server-ActiveSync.') }
    }
    [pscustomobject]@{ IsValid = $problems.Count -eq 0; Problems = @($problems) }
}

function Test-EomConfiguration {
    <# Checks a settings hashtable (flattened configuration) and lists every problem. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    $problems = [Collections.Generic.List[string]]::new()
    $c = $Configuration
    # AppleMail needs only the mailbox, like the iPhone: AD FS comes from the Exchange challenge and
    # the ActiveSync URL from Autodiscover (Target.EasUrl, if set, is the server typed by hand).
    $apple = [string]$c.TestType -eq 'AppleMail'
    $number = {
        param([string]$Key, [string]$Label, [int]$Min, [int]$Max)
        $n = 0
        if (-not [int]::TryParse([string]$c[$Key], [ref]$n) -or $n -lt $Min -or $n -gt $Max) {
            [void]$problems.Add("$Label must be a whole number between $Min and $Max.")
        }
    }

    foreach ($pair in @(@('AdfsUrl', 'Target.AdfsUrl'), @('EasUrl', 'Target.EasUrl'), @('Mailbox', 'Target.Mailbox'), @('ClientId', 'Target.ClientId'),
            @('DeviceType', 'Device.DeviceType'), @('UserAgent', 'Device.UserAgent'), @('OutputPath', 'Report.OutputPath'), @('ReportPrefix', 'Report.FilePrefix'),
            @('AppleClientId', 'AppleMail.ClientId'), @('AppleUserAgent', 'AppleMail.UserAgent'), @('AppleDeviceType', 'AppleMail.DeviceType'))) {
        if ($apple -and $pair[0] -in 'AdfsUrl', 'EasUrl', 'ClientId') { continue }
        if ([string]::IsNullOrWhiteSpace([string]$c[$pair[0]])) { [void]$problems.Add("$($pair[1]) is required.") }
    }
    if ([string]$c.AppleDeviceType -and [string]$c.AppleDeviceType -notmatch '^[A-Za-z0-9]{1,32}$') { [void]$problems.Add('AppleMail.DeviceType must contain 1 to 32 letters or digits.') }
    if ([string]$c.AppleUserAgent -match '[\r\n]') { [void]$problems.Add('AppleMail.UserAgent must be on one line.') }
    $endpointProblems = (Test-EomEndpoint -AdfsUrl ([string]$c.AdfsUrl) -EasUrl ([string]$c.EasUrl)).Problems
    # Format of a URL that is set (an empty one is reported as required above); Target.AdfsUrl is not used by AppleMail.
    $endpointProblems = @($endpointProblems | Where-Object {
            ($_ -like 'Target.EasUrl*' -and [string]$c.EasUrl) -or ($_ -like 'Target.AdfsUrl*' -and [string]$c.AdfsUrl -and -not $apple)
        })
    foreach ($p in $endpointProblems) { [void]$problems.Add($p) }

    if ([string]$c.Mailbox -and [string]$c.Mailbox -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { [void]$problems.Add('Target.Mailbox must be an SMTP address or a UPN (user@domain).') }
    if ([string]$c.DeviceType -notmatch '^[A-Za-z0-9]{1,32}$') { [void]$problems.Add('Device.DeviceType must contain 1 to 32 letters or digits.') }
    if ([string]$c.DeviceId -and [string]$c.DeviceId -notmatch '^[A-Za-z0-9]{1,32}$') { [void]$problems.Add('Device.DeviceId must be empty or contain 1 to 32 letters or digits.') }
    if ([string]$c.UserAgent -match '[\r\n]') { [void]$problems.Add('Device.UserAgent must be on one line.') }
    if ([string]$c.TestType -notin @($script:Scenarios.Name)) { [void]$problems.Add("Test.DefaultType must be one of: $($script:Scenarios.Name -join ', ').") }
    & $number 'MessageCount' 'Test.MessageCount' 1 100
    & $number 'OAuthPollTimeoutSeconds' 'Test.OAuthPollTimeoutSeconds' 30 3600
    & $number 'HttpTimeoutSeconds' 'Test.HttpTimeoutSeconds' 5 300
    & $number 'CertificateWarningDays' 'Test.CertificateWarningDays' 0 365
    & $number 'LogRetentionDays' 'Logging.RetentionDays' 1 365
    if ($c.AcknowledgePolicy -isnot [bool]) { [void]$problems.Add('Test.AcknowledgePolicy must be $true or $false.') }
    $formats = @($c.ReportFormats)
    if ($formats.Count -eq 0 -or @($formats | Where-Object { $_ -notin 'Csv', 'Html' }).Count) { [void]$problems.Add("Report.Formats must contain 'Csv', 'Html' or both.") }
    if ([string]$c.CsvDelimiter -notin ';', ',', "`t") { [void]$problems.Add("Report.CsvDelimiter must be ';', ',' or a tab.") }
    if ([string]::IsNullOrWhiteSpace([string]$c.LogPath)) { [void]$problems.Add('Logging.Path is required.') }

    [pscustomobject]@{ IsValid = $problems.Count -eq 0; Problems = @($problems) }
}

function Import-EomConfiguration {
    <#
        Reads config\EasOAuthMailbox.config.psd1 (sections), applies the defaults, resolves the
        relative paths from the tool folder, checks everything and returns the settings hashtable.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $script:ToolRoot 'config\EasOAuthMailbox.config.psd1'),
        [string]$Root = $script:ToolRoot
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    $settings = Get-EomDefaultConfiguration
    $problems = [Collections.Generic.List[string]]::new()
    $data = Import-PowerShellDataFile -LiteralPath $Path
    foreach ($section in $data.Keys) {
        if (-not $script:ConfigSchema.Contains($section)) {
            [void]$problems.Add("Unknown section '$section'. Sections: $($script:ConfigSchema.Keys -join ', ').")
            continue
        }
        if ($data[$section] -isnot [hashtable]) { [void]$problems.Add("Section '$section' must be a @{ } block."); continue }
        foreach ($key in $data[$section].Keys) {
            if (-not $script:ConfigSchema[$section].Contains($key)) {
                [void]$problems.Add("Unknown key '$section.$key'. Keys of $($section): $($script:ConfigSchema[$section].Keys -join ', ').")
                continue
            }
            $settings[$script:ConfigSchema[$section][$key]] = $data[$section][$key]
        }
    }
    foreach ($key in 'OutputPath', 'LogPath') {
        if (-not [string]::IsNullOrWhiteSpace([string]$settings[$key])) { $settings[$key] = Resolve-EomPath -Path ([string]$settings[$key]) -Root $Root }
    }
    $settings.ConfigPath = [IO.Path]::GetFullPath($Path)
    foreach ($p in (Test-EomConfiguration -Configuration $settings).Problems) {
        # The URLs are checked again once the scenario is known: AppleMail needs neither of them.
        if ($p -in 'Target.AdfsUrl is required.', 'Target.EasUrl is required.') { continue }
        [void]$problems.Add($p)
    }
    if ($problems.Count) { throw ("Invalid configuration ($Path):`n - " + ($problems -join "`n - ")) }
    return $settings
}

function Get-EomDeviceId {
    <# Stable 32-character DeviceId derived from the computer, the mailbox and the device type. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mailbox,
        [string]$DeviceType = 'EasOAuthMailbox',
        [string]$ComputerName = $env:COMPUTERNAME
    )

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes("$ComputerName|$Mailbox|$DeviceType".ToLowerInvariant()))
        return ([BitConverter]::ToString($hash) -replace '-', '').Substring(0, 32)
    }
    finally {
        $sha256.Dispose()
    }
}

function Resolve-EomEndpoints {
    <# URLs derived from the configuration. AdfsUrl or EasUrl may be empty (AppleMail finds them like the iPhone). #>
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    $adfsRoot = ([string]$Configuration.AdfsUrl).TrimEnd('/')
    $adfsUri = if ($adfsRoot) { [Uri]$adfsRoot } else { $null }
    $easUrl = ([string]$Configuration.EasUrl).TrimEnd('/')
    $easUri = if ($easUrl) { [Uri]$easUrl } else { $null }
    $resource = if ($easUri) { $easUri.GetLeftPart([UriPartial]::Authority) + '/' } else { $null }
    [pscustomobject]@{
        AdfsRoot           = $adfsRoot
        EasUrl             = $easUrl
        Resource           = $resource
        # The AD FS Web API identifier ends with '/', and the resource-qualified scope syntax adds
        # another '/': the double slash is intentional.
        Scope              = if ($resource) { "openid $($resource)/EAS.AccessAsUser.All" } else { $null }
        DeviceCodeEndpoint = if ($adfsRoot) { "$adfsRoot/oauth2/devicecode" } else { $null }
        TokenEndpoint      = if ($adfsRoot) { "$adfsRoot/oauth2/token" } else { $null }
        MetadataEndpoint   = if ($adfsRoot) { "$adfsRoot/.well-known/openid-configuration" } else { $null }
        AdfsHost           = if ($adfsUri) { $adfsUri.Host } else { $null }
        AdfsPort           = if ($adfsUri) { $adfsUri.Port } else { $null }
        EasHost            = if ($easUri) { $easUri.Host } else { $null }
        EasPort            = if ($easUri) { $easUri.Port } else { $null }
    }
}
