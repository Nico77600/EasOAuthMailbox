<#
.SYNOPSIS
    EAS OAuth Mailbox - configuration and scenarios (dot-sourced by EasOAuthMailbox.psm1).

.DESCRIPTION
    The configuration file has sections (Target, Device, Test, Report, Logging, AppleMail), like the other
    tools. It is flattened into one settings hashtable used by the CLI, the GUI and the tests;
    unknown sections or keys and invalid values are all reported at once. The Basic password is
    never part of it: it is asked at run time (-Credential, prompt or window) and stays in memory.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.2.1
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

function Get-EomScenarioStages {
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

function Get-EomStageTitle {
    <# Title of a stage in the console, the window and the report; some depend on the authentication and the authorization server. #>
    param([Parameter(Mandatory = $true)][string]$Stage, [string]$Authentication = 'OAuth', [string]$Authority = 'ADFS')
    $info = $script:StageInfo[$Stage]
    if ($Authentication -eq 'Basic' -and $info.ContainsKey('BasicTitle')) { return $info.BasicTitle }
    if ($Authority -eq 'EntraID' -and $info.ContainsKey('EntraTitle')) { return $info.EntraTitle }
    if ($Authority -eq 'Auto' -and $info.ContainsKey('AutoTitle')) { return $info.AutoTitle }
    return $info.Title
}

function Get-EomDefaultConfiguration {
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
    # Basic authentication never contacts AD FS: Target.AdfsUrl and Target.ClientId are not used.
    $basic = [string]$c.Authentication -eq 'Basic'
    # Entra ID (Exchange on-premises with HMA, or Exchange Online) or the server named by Exchange: Target.AdfsUrl is not used.
    $noAdfs = $apple -or $basic -or [string]$c.Authority -in 'EntraID', 'Auto'
    # Exchange Online trusts only Entra ID and no longer accepts Basic (AppleMail takes the URL from Autodiscover).
    $online = -not $apple -and (Test-EomExchangeOnlineUrl -Url ([string]$c.EasUrl))
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
    $endpointProblems = (Test-EomEndpoint -AdfsUrl ([string]$c.AdfsUrl) -EasUrl ([string]$c.EasUrl)).Problems
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
        # Checked again once the scenario and the authentication are known (command line, window):
        # AppleMail needs no URL, Basic needs neither AD FS nor a client ID.
        if ($p -in 'Target.AdfsUrl is required.', 'Target.EasUrl is required.', 'Target.ClientId is required.' -or $p -like 'The OAuth scenario tests the AD FS sign-in*') { continue }
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

function Test-EomExchangeOnlineUrl {
    <# Whether an ActiveSync URL is the one of Exchange Online (outlook.office365.com and the other clouds). #>
    param([AllowEmptyString()][AllowNull()][string]$Url)

    $uri = $null
    if (-not $Url -or -not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    return $script:Entra.OnlineHosts -contains $uri.Host.ToLowerInvariant()
}

function Resolve-EomEndpoints {
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
        ExchangeOnline     = Test-EomExchangeOnlineUrl -Url $easUrl
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
