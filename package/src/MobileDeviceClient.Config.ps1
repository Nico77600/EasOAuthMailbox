<#
.SYNOPSIS
    Mobile Device Client for Exchange - configuration and scenarios (dot-sourced by MobileDeviceClient.psm1).

.DESCRIPTION
    The configuration file has sections (Target, Device, Test, Report, Logging, AppleMail), like the other
    tools. It is flattened into one settings hashtable used by the CLI, the GUI and the tests;
    unknown sections or keys and invalid values are all reported at once. The Basic password is
    never part of it: it is asked at run time (-Credential, prompt or window) and stays in memory.

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.0
#>

# Section.Key of the configuration file -> key of the settings hashtable.
$script:ConfigSchema = [ordered]@{
    Target  = [ordered]@{ AdfsUrl = 'AdfsUrl'; EasUrl = 'EasUrl'; Mailbox = 'Mailbox'; ClientId = 'ClientId'; BasicUser = 'BasicUser'; Authority = 'Authority'; TenantId = 'TenantId' }
    Device  = [ordered]@{ DeviceId = 'DeviceId'; DeviceType = 'DeviceType'; UserAgent = 'UserAgent' }
    Test    = [ordered]@{
        DefaultType = 'TestType'; Authentication = 'Authentication'; SignIn = 'SignIn'; MessageCount = 'MessageCount'; AcknowledgePolicy = 'AcknowledgePolicy'
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

# Entra ID signs the user in for two kinds of mailboxes, with the same flows:
#   Exchange on-premises with hybrid modern authentication (HMA): Exchange sends the clients to Entra ID
#     instead of AD FS (Get-AuthServer 'EvoSts - <id>' -IsDefaultAuthorizationEndpoint $true). Recorded on
#     Exchange Server SE in hybrid (2026-10-03): authorization_uri="https://login.windows.net/common/oauth2/authorize",
#     issuer_kind="AzureAD", trusted_issuers="00000001-0000-0000-c000-000000000000@<tenant ID>".
#   Exchange Online (https://outlook.office365.com/Microsoft-Server-ActiveSync): the same challenge,
#     with trusted_issuers="00000001-0000-0000-c000-000000000000@*" (every tenant).
$script:Entra = @{
    LoginHost   = 'login.microsoftonline.com'
    # Hosts of the Entra ID sign-in service (worldwide, US Government, China).
    Hosts       = @('login.microsoftonline.com', 'login.windows.net', 'login.microsoft.com', 'sts.windows.net', 'login.microsoftonline.us', 'login.partner.microsoftonline.cn', 'login.chinacloudapi.cn')
    # Application ID of the Entra ID token service, in trusted_issuers (<id>@<tenant ID>).
    EvoStsId    = '00000001-0000-0000-c000-000000000000'
    # Application ID of Office 365 Exchange Online: the on-premises URLs are its service principal names.
    ExchangeApp = '00000002-0000-0ff1-ce00-000000000000'
    # ActiveSync hosts of Exchange Online (worldwide, GCC High, DoD, operated by 21Vianet).
    OnlineHosts = @('outlook.office365.com', 'outlook.office.com', 'outlook.office365.us', 'outlook-dod.office365.us', 'partner.outlook.cn')
}

# Redirect URIs of the sign-in window (authorization code): Entra ID returns the code of the native clients
# of Microsoft (Microsoft Office d3590ed6...) to its native-client page; the AD FS application group of the
# Exchange documentation registers urn:ietf:wg:oauth:2.0:oob for that client (Add-AdfsNativeClientApplication).
# AppleMail uses the redirect URI of the iPhone ($script:AppleMail.RedirectUris[0]).
$script:SignInRedirect = @{
    EntraID = 'https://login.microsoftonline.com/common/oauth2/nativeclient'
    ADFS    = 'urn:ietf:wg:oauth:2.0:oob'
}

# Scenarios and the stages they run, in order. A stage runs only if no earlier stage failed or was blocked.
$script:Scenarios = @(
    @{ Name = 'Discovery'; DisplayName = 'Prerequisites without sign-in'; Stages = @('Discovery')
       Description = 'AD FS or Entra ID metadata, TLS certificates, OAuth challenge advertised by ActiveSync and the server it names, OAuth offered to the mailbox, rejection of an invalid token. No sign-in, nothing created.' }
    @{ Name = 'OAuth'; DisplayName = 'Sign-in and token'; Stages = @('OAuth')
       Description = 'Sign-in with AD FS or Entra ID in a window or with a device code, then the claims of the token: audience, scope, expiry and user.' }
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
       Description = 'Adds the account like the Mail app of an iPhone: Autodiscover, AD FS or Entra ID found in the Exchange challenge, the sign-in page of the Apple Mail client, sign-in with that client, then ActiveSync 16.1 as an iPhone.' }
)

$script:StageInfo = @{
    Discovery    = @{ Title = 'Prerequisites without sign-in'; Icon = 'Search' }
    AppleSetup   = @{ Title = 'Account setup like the iPhone (no sign-in)'; Icon = 'Search' }
    OAuth        = @{ Title = 'AD FS sign-in and token'; EntraTitle = 'Entra ID sign-in and token'; AutoTitle = 'OAuth sign-in and token (server given by Exchange)'; Icon = 'Key' }
    Basic        = @{ Title = 'Basic authentication (user name and password)'; Icon = 'Key' }
    Endpoint     = @{ Title = 'ActiveSync endpoint with the token'; BasicTitle = 'ActiveSync endpoint with the user name and password'; Icon = 'Server' }
    Provisioning = @{ Title = 'ActiveSync policy'; Icon = 'Shield' }
    FolderSync   = @{ Title = 'Mailbox folders (FolderSync)'; Icon = 'Folder' }
    Identity     = @{ Title = 'Mailbox identity (Settings)'; Icon = 'People' }
    InboxSync    = @{ Title = 'Inbox headers (Sync)'; Icon = 'Mail' }
}

function Get-MdcTestCatalog {
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

function Get-MdcScenarioStages {
    <#
        Stages a scenario runs. With Basic authentication the AD FS sign-in (OAuth stage) is replaced
        by the Basic stage: the user name and password are checked, then sent with every request.
    #>
    param([Parameter(Mandatory = $true)][string]$TestType, [string]$Authentication = 'OAuth')

    $scenario = $script:Scenarios | Where-Object { $_.Name -eq $TestType } | Select-Object -First 1
    if (-not $scenario) { return }
    foreach ($stage in $scenario.Stages) {
        if ($stage -eq 'OAuth' -and $Authentication -eq 'Basic') { 'Basic' } else { $stage }
    }
}

function Get-MdcStageTitle {
    <# Title of a stage in the console, the window and the report; some depend on the authentication and the authorization server. #>
    param([Parameter(Mandatory = $true)][string]$Stage, [string]$Authentication = 'OAuth', [string]$Authority = 'ADFS')
    $info = $script:StageInfo[$Stage]
    if ($Authentication -eq 'Basic' -and $info.ContainsKey('BasicTitle')) { return $info.BasicTitle }
    if ($Authority -eq 'EntraID' -and $info.ContainsKey('EntraTitle')) { return $info.EntraTitle }
    if ($Authority -eq 'Auto' -and $info.ContainsKey('AutoTitle')) { return $info.AutoTitle }
    return $info.Title
}

function Get-MdcDefaultConfiguration {
    @{
        AdfsUrl                 = 'https://adfs.contoso.test/adfs'
        EasUrl                  = 'https://mail.contoso.test/Microsoft-Server-ActiveSync'
        Mailbox                 = 'eas-test@contoso.test'
        ClientId                = 'd3590ed6-52b3-4102-aeff-aad2292ab01c'
        BasicUser               = ''
        Authority               = 'ADFS'
        TenantId                = ''
        Authentication          = 'OAuth'
        SignIn                  = 'Auto'
        DeviceId                = ''
        DeviceType              = 'MobileDeviceClient'
        UserAgent               = 'MobileDeviceClient/1.0'
        TestType                = 'Full'
        MessageCount            = 5
        AcknowledgePolicy       = $false
        OAuthPollTimeoutSeconds = 600
        HttpTimeoutSeconds      = 60
        CertificateWarningDays  = 30
        OutputPath              = '.\reports'
        ReportPrefix            = 'MobileDeviceClient'
        ReportFormats           = @('Csv', 'Html')
        CsvDelimiter            = ';'
        LogPath                 = '.\logs'
        LogRetentionDays        = 14
        AppleClientId           = 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        AppleUserAgent          = 'Apple-iPhone15C4/2401.539000006'
        AppleDeviceType         = 'iPhone'
    }
}

function Resolve-MdcClientSettings {
    <#
        Settings of the client a scenario plays. AppleMail: client ID, User-Agent and DeviceType of
        the Apple Mail app, ActiveSync 16.1. Other scenarios: the tool itself, ActiveSync 14.1.
        The DeviceId derives from the DeviceType, so both clients are different devices in Exchange.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    $cfg = Get-MdcDefaultConfiguration
    foreach ($key in $Configuration.Keys) { $cfg[$key] = $Configuration[$key] }
    $scenario = $script:Scenarios | Where-Object { $_.Name -eq [string]$cfg.TestType } | Select-Object -First 1
    $cfg.Client = if ($scenario -and $scenario.ContainsKey('Client')) { [string]$scenario['Client'] } else { 'Tool' }
    $cfg.ProtocolVersion = '14.1'
    $cfg.DeviceModel = 'Mobile Device Client for Exchange'
    $cfg.DeviceFriendlyName = "$env:COMPUTERNAME Mobile Device Client for Exchange"
    $cfg.DeviceOS = [Environment]::OSVersion.VersionString
    if ($cfg.Client -eq 'AppleMail') {
        $cfg.ClientId = [string]$cfg.AppleClientId
        $cfg.UserAgent = [string]$cfg.AppleUserAgent
        $cfg.DeviceType = [string]$cfg.AppleDeviceType
        $cfg.ProtocolVersion = $script:AppleMail.ProtocolVersion
        $cfg.DeviceModel = $script:AppleMail.Model
        # Marked so that the test device is easy to find and remove (Get-MobileDevice | FriendlyName).
        $cfg.DeviceFriendlyName = "iPhone (Mobile Device Client for Exchange $env:COMPUTERNAME)"
        $cfg.DeviceOS = 'iOS (simulated by Mobile Device Client for Exchange)'
        # The iPhone is never told where AD FS is: it reads it in the Exchange challenge (AppleSetup).
        $cfg.AdfsUrl = ''
        $cfg.Authority = 'Auto'
    }
    if ([string]$cfg.Authority -in 'EntraID', 'Auto') {
        # Entra ID, or the server Exchange names in its challenge: the AD FS URL is not used.
        $cfg.AdfsUrl = ''
    }
    if ([string]$cfg.Authentication -eq 'Basic') {
        # Basic authentication never contacts AD FS: no AD FS URL, no client.
        $cfg.AdfsUrl = ''
        $cfg.ClientId = ''
    }
    return $cfg
}

function Resolve-MdcPath {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Root)
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath($Path, $Root)
}

function Test-MdcEndpoint {
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

function Test-MdcConfiguration {
    <# Checks a settings hashtable (flattened configuration) and lists every problem. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    $problems = [Collections.Generic.List[string]]::new()
    $c = $Configuration
    # AppleMail needs only the mailbox, like the iPhone: AD FS comes from the Exchange challenge and
    # the ActiveSync URL from Autodiscover (Target.EasUrl, if set, is the server typed by hand).
    $apple = [string]$c.TestType -eq 'AppleMail'
    # Basic authentication never contacts AD FS: Target.AdfsUrl and Target.ClientId are not used.
    $basic = [string]$c.Authentication -eq 'Basic'
    # Entra ID (Exchange on-premises with HMA, or Exchange Online) or the server named by Exchange: Target.AdfsUrl is not used.
    $noAdfs = $apple -or $basic -or [string]$c.Authority -in 'EntraID', 'Auto'
    # Exchange Online trusts only Entra ID and no longer accepts Basic (AppleMail takes the URL from Autodiscover).
    $online = -not $apple -and (Test-MdcExchangeOnlineUrl -Url ([string]$c.EasUrl))
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
        if ($basic -and $pair[0] -in 'AdfsUrl', 'ClientId') { continue }
        if ($noAdfs -and $pair[0] -eq 'AdfsUrl') { continue }
        if ([string]::IsNullOrWhiteSpace([string]$c[$pair[0]])) { [void]$problems.Add("$($pair[1]) is required.") }
    }
    if ([string]$c.AppleDeviceType -and [string]$c.AppleDeviceType -notmatch '^[A-Za-z0-9]{1,32}$') { [void]$problems.Add('AppleMail.DeviceType must contain 1 to 32 letters or digits.') }
    if ([string]$c.AppleUserAgent -match '[\r\n]') { [void]$problems.Add('AppleMail.UserAgent must be on one line.') }
    $endpointProblems = (Test-MdcEndpoint -AdfsUrl ([string]$c.AdfsUrl) -EasUrl ([string]$c.EasUrl)).Problems
    # Format of a URL that is set (an empty one is reported as required above); Target.AdfsUrl is used only with AD FS.
    $endpointProblems = @($endpointProblems | Where-Object {
            ($_ -like 'Target.EasUrl*' -and [string]$c.EasUrl) -or ($_ -like 'Target.AdfsUrl*' -and [string]$c.AdfsUrl -and -not $noAdfs)
        })
    foreach ($p in $endpointProblems) { [void]$problems.Add($p) }

    if ([string]$c.Authentication -notin 'OAuth', 'Basic') { [void]$problems.Add("Test.Authentication must be 'OAuth' or 'Basic'.") }
    if ([string]$c.Authority -notin 'ADFS', 'EntraID', 'Auto') { [void]$problems.Add("Target.Authority must be 'ADFS', 'EntraID' or 'Auto'.") }
    if ([string]$c.SignIn -notin 'Auto', 'Window', 'DeviceCode') { [void]$problems.Add("Test.SignIn must be 'Auto', 'Window' or 'DeviceCode'.") }
    if ([string]$c.TenantId -and [string]$c.TenantId -notmatch '^([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}|[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+)$') {
        [void]$problems.Add('Target.TenantId must be empty (= the domain of the mailbox), a tenant ID (GUID) or a domain of the tenant.')
    }
    if ($basic -and [string]$c.TestType -eq 'OAuth') { [void]$problems.Add('The OAuth scenario tests the AD FS sign-in: with Basic authentication, run Endpoint (user name and password checked) or a later scenario.') }
    if ($online -and -not $basic -and [string]$c.Authority -eq 'ADFS') {
        [void]$problems.Add('Exchange Online accepts only Entra ID tokens: with this Target.EasUrl set Target.Authority to EntraID (or Auto). A federated user still types the password on AD FS, through Entra ID.')
    }
    $signsIn = @($script:Scenarios | Where-Object { $_.Name -eq [string]$c.TestType } | ForEach-Object { $_.Stages } | Where-Object { $_ -eq 'OAuth' }).Count
    if ($online -and $basic -and $signsIn) {
        [void]$problems.Add('Exchange Online no longer accepts Basic authentication for ActiveSync: test this mailbox with OAuth and Entra ID (Target.Authority EntraID). Discovery with Basic shows what Exchange Online offers, without a password.')
    }
    # Basic sends "user:password": a user name with ':' or a line break cannot be sent.
    if ([string]$c.BasicUser -and [string]$c.BasicUser -notmatch '^([^@\s:\\]+@[^@\s:\\]+|[^@\s:\\]+\\[^@\s:\\]+)$') { [void]$problems.Add('Target.BasicUser must be empty (= Target.Mailbox), a UPN (user@domain) or DOMAIN\user.') }
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

function Import-MdcConfiguration {
    <#
        Reads config\MobileDeviceClient.config.psd1 (sections), applies the defaults, resolves the
        relative paths from the tool folder, checks everything and returns the settings hashtable.
    #>
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path $script:ToolRoot 'config\MobileDeviceClient.config.psd1'),
        [string]$Root = $script:ToolRoot
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Configuration file not found: $Path" }
    $settings = Get-MdcDefaultConfiguration
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
        if (-not [string]::IsNullOrWhiteSpace([string]$settings[$key])) { $settings[$key] = Resolve-MdcPath -Path ([string]$settings[$key]) -Root $Root }
    }
    $settings.ConfigPath = [IO.Path]::GetFullPath($Path)
    foreach ($p in (Test-MdcConfiguration -Configuration $settings).Problems) {
        # Checked again once the scenario and the authentication are known (command line, window):
        # AppleMail needs no URL, Basic needs neither AD FS nor a client ID.
        if ($p -in 'Target.AdfsUrl is required.', 'Target.EasUrl is required.', 'Target.ClientId is required.' -or $p -like 'The OAuth scenario tests the AD FS sign-in*') { continue }
        [void]$problems.Add($p)
    }
    if ($problems.Count) { throw ("Invalid configuration ($Path):`n - " + ($problems -join "`n - ")) }
    return $settings
}

function Get-MdcDeviceId {
    <# Stable 32-character DeviceId derived from the computer, the mailbox and the device type. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mailbox,
        [string]$DeviceType = 'MobileDeviceClient',
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

function Test-MdcExchangeOnlineUrl {
    <# Whether an ActiveSync URL is the one of Exchange Online (outlook.office365.com and the other clouds). #>
    param([AllowEmptyString()][AllowNull()][string]$Url)

    $uri = $null
    if (-not $Url -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return $script:Entra.OnlineHosts -contains $uri.Host.ToLowerInvariant()
}

function Resolve-MdcEndpoints {
    <#
        URLs derived from the configuration. AdfsUrl or EasUrl may be empty (AppleMail finds them like
        the iPhone). Authority EntraID: the endpoints of the tenant (TenantId, a GUID or a domain),
        Microsoft identity platform v2.0, the same flows as AD FS (authorization code in the sign-in window,
        device code). ExchangeOnline: the ActiveSync URL is the one of Exchange Online.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    $authority = if ([string]$Configuration['Authority']) { [string]$Configuration['Authority'] } else { 'ADFS' }
    $tenant = [string]$Configuration['TenantId']
    $adfsRoot = ([string]$Configuration['AdfsUrl']).TrimEnd('/')
    $adfsUri = if ($adfsRoot) { [Uri]$adfsRoot } else { $null }
    $easUrl = ([string]$Configuration['EasUrl']).TrimEnd('/')
    $easUri = if ($easUrl) { [Uri]$easUrl } else { $null }
    $resource = if ($easUri) { $easUri.GetLeftPart([UriPartial]::Authority) + '/' } else { $null }
    $entraRoot = if ($authority -eq 'EntraID' -and $tenant) { "https://$($script:Entra.LoginHost)/$tenant" } else { $null }
    [pscustomobject]@{
        Authority          = $authority
        TenantId           = $tenant
        AdfsRoot           = $adfsRoot
        EntraRoot          = $entraRoot
        EasUrl             = $easUrl
        ExchangeOnline     = Test-MdcExchangeOnlineUrl -Url $easUrl
        Resource           = $resource
        # AD FS: the Web API identifier ends with '/', and the resource-qualified scope syntax adds
        # another '/' (the double slash is intentional). Entra ID: the URL of Exchange Online, or the
        # on-premises URL registered as a service principal name of Office 365 Exchange Online (HMA);
        # the scope is that URL and the permission.
        Scope              = if (-not $resource) { $null } elseif ($authority -eq 'EntraID') { "$($resource)EAS.AccessAsUser.All" } else { "openid $($resource)/EAS.AccessAsUser.All" }
        AuthorizeEndpoint  = if ($entraRoot) { "$entraRoot/oauth2/v2.0/authorize" } elseif ($adfsRoot) { "$adfsRoot/oauth2/authorize" } else { $null }
        DeviceCodeEndpoint = if ($entraRoot) { "$entraRoot/oauth2/v2.0/devicecode" } elseif ($adfsRoot) { "$adfsRoot/oauth2/devicecode" } else { $null }
        TokenEndpoint      = if ($entraRoot) { "$entraRoot/oauth2/v2.0/token" } elseif ($adfsRoot) { "$adfsRoot/oauth2/token" } else { $null }
        MetadataEndpoint   = if ($entraRoot) { "$entraRoot/v2.0/.well-known/openid-configuration" } elseif ($adfsRoot) { "$adfsRoot/.well-known/openid-configuration" } else { $null }
        AdfsHost           = if ($adfsUri) { $adfsUri.Host } else { $null }
        AdfsPort           = if ($adfsUri) { $adfsUri.Port } else { $null }
        EasHost            = if ($easUri) { $easUri.Host } else { $null }
        EasPort            = if ($easUri) { $easUri.Port } else { $null }
    }
}

# SIG # Begin signature block
# MIIghgYJKoZIhvcNAQcCoIIgdzCCIHMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCAB9yseOk7DM8OT
# 1P1gOGRP1/oAon1NuMq5GvAgowhI7KCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYISbTCCEmkCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCBplTbj8TRV
# Yv5d7dyw+EYLxqBvT+68t63w61sYtQ+MJDANBgkqhkiG9w0BAQEFAASCAgBwVNIv
# FND1k14g0O5K+JJeBbvg4Z21D6kvY5HsZ+kdw4QEJmrsUuoo72GnUb+s4OIKWS3+
# 5zIN+3bHRd3IeMKXsoNNsU1DOhHISr2q32Hkhi6YqEJA+IFd71iT2Q5T432N4z5J
# 4pHw2/5YkHu7XkOI6z8fSNVzuHzCIf61gLsMTgA5FhIuDHir7N6g1e+9bats6PCY
# T+9BYsFez5Gyn/OROfYbsycK9j/QTxVSw22wqG10F36idORhWgsW0P3uRZVHxUWl
# jhJeDpwfEYp/Kx20HSTcafFRsr56HJycQf9SmKKJBnrf6A7uNJ3n8SowD2vggnPu
# y5dwvM8Aj736CEdtPT2pt6FvX6t1VV/4cWMBB6sfoYTei28ql5gwkPUjSxgwMDsH
# M6yxsQeuoMQ3uPsZShEuKkEaVv53CBZMk+IbH9FxgLD0cLZnLUO0YcqBImasZfbr
# //AXV8iPbsHHf6HFGcOJz9sSkPVjHv/1eXnSQ4qlEEVaOgnZl7urUJH0WB8q4W9z
# FE0Uv1EKHuGVwcAGUFUNr0zHMfr4y8rpGRiL2bzVu5i4vObljUxER/u1Zg5JV+dN
# XRND4bDxKzlUGIz/C5Gf2VY/3hT5rutRKOia5njnmseTlIsAFHJlN8rQhZJJhcDd
# gX6aKJnKxb/LWpzULqw1hvVzU0X5vo54uKyEkaGCDyowgg8mBgorBgEEAYI3AwMB
# MYIPFjCCDxIGCSqGSIb3DQEHAqCCDwMwgg7/AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIEYytswIHVjsAsVdPCN0BLbaXLmHU+BsvbnzHcteJV2RAgh0TIlSDY7G
# oRgPMjAyNjEwMTQxMTM1MzlaMAMCAQECEEOfZ+H0DC+KHIbkoZn+p8agggwAMIIE
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
# WTCCAlUCAQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhtsXfHAwaBg
# DjgwCwYJYIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDExMzUzOVowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIPRyUcdCc/KK
# a7Ln302/gBIXngP47uezTCGS6/Jiqd4pMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEgwRgIhAI4J3Jr8X8ied5N19+utujoLMGp5CjaGBhtKcaI9Gp/xAiEApRhbuCM3
# Hjg6zEKw7PYftUqfTbVxA2TINgJ0FT/pdH8=
# SIG # End signature block
