<#
.SYNOPSIS
    EAS OAuth Mailbox - simulated AD FS and Exchange ActiveSync, for the tests and the documentation images.

.DESCRIPTION
    Dot-source this file. It builds WBXML answers byte by byte with the code pages of MS-ASWBXML
    (FolderSync 7, Provision 14, Settings 18, AirSync 0, Email 2) and answers like Exchange:
    401 + WWW-Authenticate Bearer only to an empty Bearer header (like Exchange SE), 401 + x-ms-diagnostics to a bad token,
    449 or ActiveSync status 142 until the policy is acknowledged, TEMPKEY then FINALKEY, and
    Basic authentication (Basic realm in the 401, accounts of BasicUsers accepted, 401 otherwise).

      New-SimState              what the simulated Exchange does (provisioning, errors, folders, messages...)
      Get-SimEasResponse        answer to one ActiveSync request (body of the Pester mock of Invoke-EasRequest)
      Get-SimMetadata           AD FS OpenID configuration
      Get-SimCertificate        server certificate
      Get-SimHttpResponse       answer to one HTTP request of the tool (body of the replacement of Send-EomHttpRequest)
      Install-SimExchange       replaces the network inside the loaded module (scripts without Pester)
      New-SimToken              unsigned JWT with the claims AD FS puts in an access token

    Nothing here is used by the tool itself, and it is not part of the package.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.2.1
#>

#region WBXML builders: Doc(header + content), T(tag with content), E(empty tag), P(code page) -------
function Wb([object[]]$Parts) {
    $list = [Collections.Generic.List[byte]]::new()
    foreach ($part in $Parts) {
        if ($part -is [string]) { $list.Add(3); $list.AddRange([Text.Encoding]::UTF8.GetBytes($part)); $list.Add(0) }
        else { $list.AddRange([byte[]]$part) }
    }
    , $list.ToArray()
}
function T([int]$Token, [object[]]$Content) {
    $list = [Collections.Generic.List[byte]]::new(); $list.Add([byte]($Token -bor 0x40)); $list.AddRange([byte[]](Wb $Content)); $list.Add(1)
    , $list.ToArray()
}
function E([int]$Token) { , ([byte[]]@($Token)) }
function P([int]$Page) { , ([byte[]]@(0, $Page)) }
function Doc([object[]]$Content) { , ([byte[]](@(3, 1, 0x6A, 0) + (Wb $Content))) }
#endregion

#region Documents --------------------------------------------------------------------------------
$script:SimPolicyTokens = @{
    DevicePasswordEnabled = 0x0E; AlphanumericDevicePasswordRequired = 0x0F; RequireStorageCardEncryption = 0x10; PasswordRecoveryEnabled = 0x11
    AttachmentsEnabled = 0x13; MinDevicePasswordLength = 0x14; MaxInactivityTimeDeviceLock = 0x15; MaxDevicePasswordFailedAttempts = 0x16
    MaxAttachmentSize = 0x17; AllowSimpleDevicePassword = 0x18; DevicePasswordExpiration = 0x19; DevicePasswordHistory = 0x1A
    AllowStorageCard = 0x1B; AllowCamera = 0x1C; RequireDeviceEncryption = 0x1D
}

function New-SimFolderSync([object[]]$Folders, [string]$Status = '1') {
    $adds = @(foreach ($f in $Folders) { , (T 0x0F @((T 0x08 $f.Id), (T 0x09 $f.Parent), (T 0x07 $f.Name), (T 0x0A $f.Type))) })
    $changes = T 0x0E (@(, (T 0x17 ([string]$Folders.Count))) + $adds)
    if ($Status -ne '1') { return Doc @((P 7), (T 0x16 @(, (T 0x0C $Status)))) }
    Doc @((P 7), (T 0x16 @((T 0x0C '1'), (T 0x12 '1'), $changes)))
}

function New-SimProvision([string]$Key, [System.Collections.IDictionary]$Policy) {
    $children = @((T 0x08 'MS-EAS-Provisioning-WBXML'), (T 0x0B '1'), (T 0x09 $Key))
    if ($Policy) {
        $settings = @(foreach ($name in $Policy.Keys) { , (T $script:SimPolicyTokens[$name] ([string]$Policy[$name])) })
        $children += , (T 0x0A @(, (T 0x0D $settings)))
    }
    Doc @((P 14), (T 0x05 @((T 0x0B '1'), (T 0x06 @(, (T 0x07 $children))))))
}

function New-SimSettings([string]$DisplayName, [string]$Primary, [string[]]$Addresses) {
    $list = @()
    if ($Primary) { $list += , (T 0x23 $Primary) }
    $list += @(foreach ($a in $Addresses) { , (T 0x1F $a) })
    $account = @()
    if ($DisplayName) { $account += , (T 0x28 $DisplayName) }
    $account += , (T 0x1E $list)
    $get = T 0x07 @(, (T 0x24 @(, (T 0x25 $account))))
    $info = T 0x1D @((T 0x06 '1'), $get)
    Doc @((P 18), (T 0x05 @((T 0x06 '1'), $info)))
}

function New-SimSync([string]$SyncKey, [object[]]$Messages, [switch]$MoreAvailable) {
    $children = @((T 0x0B $SyncKey), (T 0x12 '2'), (T 0x0E '1'))
    if ($Messages) {
        $adds = @(for ($i = 0; $i -lt $Messages.Count; $i++) {
                $m = $Messages[$i]
                $email = T 0x1D @((P 2), (T 0x0F $m.Date), (T 0x18 $m.From), (T 0x14 $m.Subject), (T 0x15 $m.Read), (P 0))
                , (T 0x07 @((T 0x0D "2:$($i + 1)"), $email))
            })
        $children += , (T 0x16 $adds)
    }
    if ($MoreAvailable) { $children += , (E 0x14) }
    Doc @(, (T 0x05 @(, (T 0x1C @(, (T 0x0F $children))))))
}
#endregion

#region Tokens and responses ----------------------------------------------------------------------
# Entra ID tenant of the simulated hybrid organisation (hybrid modern authentication).
$script:SimTenantId = '7d4e2a91-3c5b-4f6e-8a1d-2b9c0e5f4a37'

function New-SimToken([string]$Audience = 'https://mail.contoso.test/', [string]$Scope = 'EAS.AccessAsUser.All', [string]$Upn = 'eas-test@contoso.test', [int]$ExpiresIn = 3600, [string]$AppId = 'd3590ed6-52b3-4102-aeff-aad2292ab01c', [string]$TenantId, [string]$Issuer = 'http://adfs.contoso.test/adfs/services/trust') {
    $encode = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $payload = [ordered]@{ aud = $Audience; iss = $Issuer; scp = $Scope; upn = $Upn; appid = $AppId; exp = [DateTimeOffset]::UtcNow.AddSeconds($ExpiresIn).ToUnixTimeSeconds() }
    if ($TenantId) { $payload.tid = $TenantId; $payload.iss = "https://sts.windows.net/$TenantId/" }
    '{0}.{1}.{2}' -f (& $encode @{ alg = 'RS256'; typ = 'JWT' }), (& $encode $payload), 'c2lnbmF0dXJl'
}

function New-SimEntraToken([string]$AppId = 'd3590ed6-52b3-4102-aeff-aad2292ab01c', [string]$TenantId = $script:SimTenantId, [string]$Audience = 'https://mail.contoso.test/') {
    <# Access token Entra ID issues for the on-premises ActiveSync URL (v1 token: iss sts.windows.net, tid). #>
    New-SimToken -AppId $AppId -TenantId $TenantId -Audience $Audience
}

function New-SimResponse([int]$Code, [byte[]]$Body = [byte[]]@(), [hashtable]$Headers = @{}, [string[]]$Challenges = @()) {
    [pscustomobject]@{ StatusCode = $Code; Headers = $Headers; Challenges = $Challenges; Body = $Body }
}

function New-SimState {
    <# Default: a healthy Exchange, one Inbox message whose subject is a spreadsheet formula. #>
    @{
        Calls               = [Collections.Generic.List[object]]::new()
        ValidToken          = $script:SimValidToken
        RequireProvisioning = $false
        ProvisionByStatus   = $false
        FolderSyncHttp      = 200
        RemoteWipe          = $false
        AcceptAnyToken      = $false
        CertificateDays     = 365
        ExchangeVersion     = '15.20'
        Folders             = @(@{ Name = 'Inbox'; Id = '2'; Parent = '0'; Type = '2' }, @{ Name = 'Sent Items'; Id = '5'; Parent = '0'; Type = '5' })
        Policy              = [ordered]@{ DevicePasswordEnabled = '1'; MinDevicePasswordLength = '6' }
        Identity            = @{ DisplayName = 'EAS Test'; Primary = 'eas-test@contoso.test'; Addresses = @('eas-test@contoso.test', 'alias@contoso.test') }
        Messages            = @(@{ Date = '2026-10-02T10:00:00.000Z'; From = '"Alice" <alice@contoso.test>'; Subject = '=HYPERLINK("http://x")'; Read = '0' })
        MoreAvailable       = $true
        # Exchange SE: Bearer challenge only to a request with an empty Bearer header (EmptyBearer),
        # 'Anonymous' (a proxy that adds it to every 401) or 'None' (OAuth not enabled).
        BearerChallenge     = 'EmptyBearer'
        AuthorizationUri    = $null
        # Empty Bearer header + X-User-Identity: 'Allowed' (authentication policy allows modern authentication:
        # authorization_uri of AD FS) or 'Blocked' (BlockModernAuthActiveSync: oauth_not_available).
        MailboxOAuth        = 'Allowed'
        MailboxAuthorizationUri = 'https://adfs.contoso.test/adfs/oauth2/authorize'
        AutodiscoverUrl     = 'https://mail.contoso.test/Microsoft-Server-ActiveSync'
        # AD FS native client of the Apple Mail app: 'Registered', 'Missing' (MSIS9223) or
        # 'NoPreferencesRedirect' (com.apple.Preferences://oauth-redirect not registered, MSIS9224).
        AppleClient         = 'Registered'
        WebCalls            = [Collections.Generic.List[object]]::new()
        # AD FS token endpoint: answers authorization_pending to the first TokenPendingPolls polls.
        TokenPendingPolls   = 0
        TokenPolls          = 0
        # Basic authentication: offered by the ActiveSync virtual directory (BasicAuthEnabled), and
        # the accounts that can sign in (user name -> password), like the legacy users of the lab.
        BasicEnabled        = $true
        BasicUsers          = @{ 'eas-test@contoso.test' = 'Sim-Pa55word!'; 'CONTOSO\eas-test' = 'Sim-Pa55word!' }
        # Authorization server Exchange names: 'ADFS', or 'EntraID' (hybrid modern authentication:
        # EvoSts is the default authorization endpoint; recorded on Exchange Server SE, 2026-10-03).
        Authority           = 'ADFS'
        EntraTenantId       = $script:SimTenantId
        # Tenant in trusted_issuers of the challenge (default: EntraTenantId).
        TrustedTenantId     = $null
        EntraDomains        = @('contoso.test')
        # userrealm of the mailbox: Managed, Federated or Unknown.
        UserRealm           = 'Managed'
        # Answer of the Entra ID token endpoint after the sign-in, e.g. 'AADSTS500011: ...' (resource not found).
        EntraTokenError     = $null
        # Entra ID authorization page: 'SignIn' (sign-in page) or an AADSTS error text.
        EntraSignInPage     = 'SignIn'
        # Sign-in window: 'Code' (the user signs in), 'Closed' (window closed), 'Denied' (consent declined),
        # 'OtherState' (an answer that is not the one of this sign-in). The codes issued, with their PKCE challenge.
        WindowOutcome       = 'Code'
        WindowCalls         = [Collections.Generic.List[object]]::new()
        AuthorizationCodes  = @{}
        # HTTP code of an OPTIONS without any Authorization header ($null: the normal 401).
        AnonymousStatus     = $null
        # AD FS: the redirect URI of the window (urn:ietf:wg:oauth:2.0:oob) is 'Registered' or 'Missing' (MSIS9224).
        AdfsWindowRedirect  = 'Registered'
        # Exchange Online (recorded 2026-10-05): anonymous request redirected to certificate-based authentication
        # (HTTP 451), Entra ID for every tenant (trusted_issuers ...@*), no Basic, ActiveSync 16.1 only.
        Online              = $false
    }
}

function Get-SimEasResponse {
    <# What the simulated Exchange answers to one ActiveSync request. #>
    param([string]$Uri, [AllowEmptyString()][string]$AccessToken, [switch]$EmptyBearer, [string]$BasicUser, [string]$BasicPassword, [string]$PolicyKey = '0', [byte[]]$Body, [hashtable]$Headers, [string]$UserAgent, [Parameter(Mandatory = $true)][hashtable]$State)

    $command = if ($Uri -match 'Cmd=(\w+)') { $Matches[1] } else { 'OPTIONS' }
    $identity = if ($Headers -and $Headers.ContainsKey('X-User-Identity')) { [string]$Headers['X-User-Identity'] } else { $null }
    $deviceType = if ($Uri -match 'DeviceType=(\w+)') { $Matches[1] } else { $null }
    $State.Calls.Add([pscustomobject]@{ Command = $command; PolicyKey = $PolicyKey; Token = $AccessToken; EmptyBearer = [bool]$EmptyBearer; BasicUser = $BasicUser; Identity = $identity; UserAgent = $UserAgent; DeviceType = $deviceType; Body = $Body })
    $provisioned = -not $State.RequireProvisioning -or $PolicyKey -eq 'FINALKEY'
    $basicAccepted = $BasicUser -and $State.BasicEnabled -and $State.BasicUsers.ContainsKey($BasicUser) -and $State.BasicUsers[$BasicUser] -ceq $BasicPassword
    $versions = @{ 'MS-ASProtocolVersions' = '2.5,12.0,12.1,14.0,14.1,16.0,16.1'; 'MS-ASProtocolCommands' = 'Sync,SendMail,SmartForward,SmartReply,GetAttachment,GetHierarchy,CreateCollection,DeleteCollection,MoveCollection,FolderSync,FolderCreate,FolderDelete,FolderUpdate,MoveItems,GetItemEstimate,MeetingResponse,Search,Settings,Ping,ItemOperations,Provision,ResolveRecipients,ValidateCert,Find'; 'MS-Server-ActiveSync' = $State.ExchangeVersion }
    # Basic: a refused user name and password gets the same 401 for every command.
    if ($BasicUser -and -not $basicAccepted) { return New-SimResponse 401 -Challenges @(if ($State.BasicEnabled) { 'Basic realm="mail.contoso.test"' }) }
    if ($State.Online) {
        $online = Get-SimOnlineResponse -Command $command -AccessToken $AccessToken -EmptyBearer:$EmptyBearer -BasicUser $BasicUser -Headers $Headers -State $State
        if ($online) { return $online }
    }
    switch ($command) {
        'OPTIONS' {
            if ($BasicUser) { return New-SimResponse 200 -Headers $versions }
            # Exchange still starting behind the reverse proxy (lab, 2026-10-05): the request without any
            # Authorization header gets HTTP 500, the others are answered normally.
            if ($State.AnonymousStatus -and -not $AccessToken -and -not $EmptyBearer) { return New-SimResponse $State.AnonymousStatus }
            # Headers recorded on Exchange Server SE with AD FS (Discovery run of 2026-10-02).
            $basic = 'Basic realm="mail.contoso.test"'
            $basicChallenges = @(if ($State.BasicEnabled) { $basic })
            $challenge = 'Bearer client_id="00000002-0000-0ff1-ce00-000000000000", token_types="app_asserted_user_v1 service_asserted_app_v1"'
            if ($State.AuthorizationUri) { $challenge += ", authorization_uri=""$($State.AuthorizationUri)""" }
            if ($State.Authority -eq 'EntraID' -and -not $AccessToken -and $EmptyBearer -and $State.BearerChallenge -ne 'None' -and -not ($identity -and $State.MailboxOAuth -ne 'Allowed')) {
                # Hybrid modern authentication: Entra ID, its tenant in trusted_issuers, with or without X-User-Identity.
                $trusted = if ($State.TrustedTenantId) { $State.TrustedTenantId } else { $State.EntraTenantId }
                $uri = if ($State.MailboxAuthorizationUri -match 'login\.') { $State.MailboxAuthorizationUri } else { 'https://login.windows.net/common/oauth2/authorize' }
                $entra = $challenge.Replace(', token_types', ", trusted_issuers=""00000001-0000-0000-c000-000000000000@$trusted"", token_types") + ", authorization_uri=""$uri"", issuer_kind=""AzureAD"""
                return New-SimResponse 401 -Challenges @(@($entra) + $basicChallenges)
            }
            if (-not $AccessToken -and $EmptyBearer -and $identity -and $State.BearerChallenge -ne 'None') {
                if ($State.MailboxOAuth -eq 'Allowed') { return New-SimResponse 401 -Challenges @($basicChallenges + "$challenge, authorization_uri=""$($State.MailboxAuthorizationUri)"", issuer_kind=""ADFS""") }
                return New-SimResponse 401 -Challenges @($basicChallenges + "$challenge, error=""invalid_token""") -Headers @{ 'x-ms-diagnostics' = "4000000;reason=""Flighting is not enabled for domain '$identity'."";error_category=""oauth_not_available""" }
            }
            if (-not $AccessToken -and $EmptyBearer) {
                if ($State.BearerChallenge -eq 'None') { return New-SimResponse 401 -Challenges $basicChallenges }
                return New-SimResponse 401 -Challenges @($basicChallenges + "$challenge, error=""invalid_token""") -Headers @{ 'x-ms-diagnostics' = '4000000;reason="Flighting is not enabled for domain ''mail.contoso.test''.";error_category="oauth_not_available"' }
            }
            if (-not $AccessToken) {
                if ($State.BearerChallenge -eq 'Anonymous') { return New-SimResponse 401 -Challenges @(@($challenge) + $basicChallenges) }
                return New-SimResponse 401 -Challenges $basicChallenges
            }
            if ($AccessToken -eq $State.ValidToken -or $State.AcceptAnyToken) {
                return New-SimResponse 200 -Headers @{ 'MS-ASProtocolVersions' = '2.5,12.0,12.1,14.0,14.1,16.0,16.1'; 'MS-ASProtocolCommands' = 'Sync,SendMail,SmartForward,SmartReply,GetAttachment,GetHierarchy,CreateCollection,DeleteCollection,MoveCollection,FolderSync,FolderCreate,FolderDelete,FolderUpdate,MoveItems,GetItemEstimate,MeetingResponse,Search,Settings,Ping,ItemOperations,Provision,ResolveRecipients,ValidateCert,Find'; 'MS-Server-ActiveSync' = $State.ExchangeVersion }
            }
            return New-SimResponse 401 -Headers @{ 'x-ms-diagnostics' = '2000001;reason="The token is invalid.";error_category="invalid_token"' }
        }
        'FolderSync' {
            if ($State.FolderSyncHttp -ne 200) { return New-SimResponse $State.FolderSyncHttp }
            if (-not $provisioned) { if ($State.ProvisionByStatus) { return New-SimResponse 200 (New-SimFolderSync -Folders @() -Status '142') } else { return New-SimResponse 449 } }
            return New-SimResponse 200 (New-SimFolderSync -Folders $State.Folders)
        }
        'Provision' {
            if ($PolicyKey -eq 'TEMPKEY') { return New-SimResponse 200 (New-SimProvision -Key 'FINALKEY') }
            if ($State.RemoteWipe) { return New-SimResponse 200 (Doc @((P 14), (T 0x05 @((T 0x0B '1'), (E 0x0C))))) }
            return New-SimResponse 200 (New-SimProvision -Key 'TEMPKEY' -Policy $State.Policy)
        }
        'Settings' {
            if (-not $provisioned) { return New-SimResponse 449 }
            $id = $State.Identity
            return New-SimResponse 200 (New-SimSettings -DisplayName $id.DisplayName -Primary $id.Primary -Addresses $id.Addresses)
        }
        'Sync' {
            if (-not $provisioned) { return New-SimResponse 449 }
            if ([Text.Encoding]::UTF8.GetString($Body) -match 'SK1') { return New-SimResponse 200 (New-SimSync -SyncKey 'SK2' -Messages $State.Messages -MoreAvailable:$State.MoreAvailable) }
            return New-SimResponse 200 (New-SimSync -SyncKey 'SK1')
        }
    }
}

function Get-SimOnlineResponse {
    <#
        What Exchange Online answers where it differs from Exchange on-premises (recorded 2026-10-05);
        $null: the on-premises answer applies (FolderSync, Settings, Sync with ActiveSync 16.1).
    #>
    param([string]$Command, [AllowEmptyString()][string]$AccessToken, [switch]$EmptyBearer, [string]$BasicUser, [hashtable]$Headers, [hashtable]$State)

    $bearer = 'Bearer client_id="00000002-0000-0ff1-ce00-000000000000", trusted_issuers="00000001-0000-0000-c000-000000000000@*", token_types="app_asserted_user_v1 service_asserted_app_v1", authorization_uri="https://login.microsoftonline.com/common/oauth2/authorize", error="invalid_token"'
    if ($BasicUser) { return New-SimResponse 401 -Challenges @($bearer) }
    if ($Command -eq 'OPTIONS') {
        if ($EmptyBearer) { return New-SimResponse 401 -Challenges @($bearer) }
        if (-not $AccessToken) { return New-SimResponse 451 -Headers @{ 'X-MS-Location' = 'https://outlook-cba.office365.com/Microsoft-Server-ActiveSync' } }
        if ($AccessToken -eq $State.ValidToken) {
            return New-SimResponse 200 -Headers @{ 'MS-ASProtocolVersions' = '16.1'; 'MS-ASProtocolCommands' = 'Sync,SendMail,SmartForward,SmartReply,GetAttachment,GetHierarchy,CreateCollection,DeleteCollection,MoveCollection,FolderSync,FolderCreate,FolderDelete,FolderUpdate,MoveItems,GetItemEstimate,MeetingResponse,Search,Settings,Ping,ItemOperations,Provision,ResolveRecipients,ValidateCert,Find'; 'MS-Server-ActiveSync' = '15.21' }
        }
        return New-SimResponse 401 -Challenges @($bearer)
    }
    # Any other version than 16.1: ActiveSync status 138 (VersionNotSupported).
    if ($Command -eq 'FolderSync' -and $Headers -and [string]$Headers['MS-ASProtocolVersion'] -ne '16.1') { return New-SimResponse 200 (New-SimFolderSync -Folders @() -Status '138') }
    return $null
}

function Get-SimMetadata {
    [pscustomobject]@{ issuer = 'http://adfs.contoso.test/adfs/services/trust'; token_endpoint = 'https://adfs.contoso.test/adfs/oauth2/token'; device_authorization_endpoint = 'https://adfs.contoso.test/adfs/oauth2/devicecode' }
}

function Get-SimWebResponse {
    <# Autodiscover v2 and the AD FS authorization page, as recorded on the lab (2026-10-02). #>
    param([string]$Uri, [string]$UserAgent, [Parameter(Mandatory = $true)][hashtable]$State)

    $State.WebCalls.Add([pscustomobject]@{ Uri = $Uri; UserAgent = $UserAgent })
    $web = { param([int]$Code, [string]$Content, [string]$Location) [pscustomobject]@{ StatusCode = $Code; Location = $Location; Content = $Content } }
    if ($Uri -match '/autodiscover/autodiscover\.json') {
        if ($Uri -notmatch '^https://autodiscover\.' -or -not $State.AutodiscoverUrl) { return & $web 404 '' }
        return & $web 200 ('{"Protocol":"ActiveSync","Url":"' + $State.AutodiscoverUrl + '"}')
    }
    if ($Uri -match '/adfs/oauth2/authorize') {
        $redirect = if ($Uri -match '[?&]redirect_uri=([^&]+)') { [Uri]::UnescapeDataString($Matches[1]) } else { '' }
        if ($State.AppleClient -eq 'Missing') {
            return & $web 200 '<html><body><div id="errorText">MSIS9223: Received invalid OAuth authorization request. The received &#39;client_id&#39; is invalid as no registered client was found with this client identifier.</div></body></html>'
        }
        if ($State.AdfsWindowRedirect -eq 'Missing' -and $redirect -eq 'urn:ietf:wg:oauth:2.0:oob') {
            return & $web 200 '<html><body><div id="errorText">MSIS9224: Received invalid OAuth authorization request. The received &#39;redirect_uri&#39; parameter is not a valid registered redirect URI for the client identifier.</div></body></html>'
        }
        if ($State.AppleClient -eq 'NoPreferencesRedirect' -and $redirect -like 'com.apple.Preferences:*') {
            return & $web 200 '<html><body><div id="errorText">MSIS9224: Received invalid OAuth authorization request. The received &#39;redirect_uri&#39; parameter is not a valid registered redirect URI for the client identifier.</div></body></html>'
        }
        return & $web 200 '<html><body><form id="loginForm"><input id="userNameInput"/><input id="passwordInput" type="password"/></form></body></html>'
    }
    return & $web 404 ''
}

function Get-SimWindowRedirect {
    <#
        The sign-in window, simulated: the user signs in on the page of Url and the server redirects to
        RedirectUri with a code bound to the PKCE challenge of the request (or closes, or declines).
    #>
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$RedirectUri, [Parameter(Mandatory = $true)][hashtable]$State)

    $State.WindowCalls.Add([pscustomobject]@{ Url = $Url; RedirectUri = $RedirectUri })
    $fields = @{}
    foreach ($pair in $Url.Substring($Url.IndexOf('?') + 1).Split('&')) { $kv = $pair.Split('=', 2); $fields[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }
    $separator = if ($RedirectUri.Contains('?')) { '&' } else { '?' }
    switch ($State.WindowOutcome) {
        'Closed' { throw 'The sign-in window was closed before the sign-in was completed.' }
        'Denied' { return "$RedirectUri$($separator)error=access_denied&error_description=$([Uri]::EscapeDataString('AADSTS65004: User declined to consent to access the app.'))&state=$($fields['state'])" }
    }
    $code = 'SimAuthCode' + [guid]::NewGuid().ToString('N') + ('c' * 40)
    $State.AuthorizationCodes[$code] = @{ Challenge = $fields['code_challenge']; RedirectUri = $RedirectUri; ClientId = $fields['client_id'] }
    $returned = if ($State.WindowOutcome -eq 'OtherState') { 'another-sign-in' } else { $fields['state'] }
    # Entra ID answers the Apple client in lower case with a final '/', like on the lab (2026-10-05).
    $target = if ($RedirectUri -like 'com.apple.*' -and $Url -match 'login\.microsoftonline') { $RedirectUri.ToLowerInvariant() + '/' } else { $RedirectUri }
    "$target$($separator)code=$code&state=$returned"
}

function Get-SimCodeGrant {
    <# Token endpoint, grant_type=authorization_code: the code once, the same redirect URI and client, the PKCE verifier of the challenge. #>
    param([byte[]]$Body, [Parameter(Mandatory = $true)][hashtable]$State)

    if (-not $Body -or -not $Body.Length) { return $null }
    $form = @{}
    foreach ($pair in [Text.Encoding]::UTF8.GetString($Body).Split('&')) { $kv = $pair.Split('=', 2); $form[[Uri]::UnescapeDataString($kv[0])] = [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
    if ($form['grant_type'] -ne 'authorization_code') { return $null }
    $issued = $State.AuthorizationCodes[$form['code']]
    $State.AuthorizationCodes.Remove([string]$form['code'])
    $challenge = if ($form['code_verifier']) { [Convert]::ToBase64String([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($form['code_verifier']))).TrimEnd('=').Replace('+', '-').Replace('/', '_') } else { $null }
    $refusal = if (-not $issued) { 'AADSTS70008: The provided authorization code or refresh token has expired or was already used.' }
    elseif ($issued.RedirectUri -ne $form['redirect_uri']) { 'AADSTS50148: The redirect_uri does not match the one of the authorization request.' }
    elseif ($issued.ClientId -ne $form['client_id']) { 'AADSTS700005: The authorization code was issued to another client.' }
    elseif ($issued.Challenge -ne $challenge) { 'AADSTS501481: The Code_Verifier does not match the code_challenge supplied in the authorization request.' }
    if ($refusal) { return @{ Code = 400; Json = ([ordered]@{ error = 'invalid_grant'; error_description = $refusal } | ConvertTo-Json -Compress) } }
    @{ Code = 200; Json = ([ordered]@{ token_type = 'Bearer'; expires_in = 3600; access_token = $State.ValidToken; refresh_token = 'SimRefreshToken' + ('r' * 40) } | ConvertTo-Json -Compress) }
}

function Get-SimHttpResponse {
    <#
        What the simulated AD FS and Exchange answer to one HttpRequestMessage: the body of the
        replacement of Send-EomHttpRequest, the only function of the tool that touches the network.
        The request is the one the tool really built (headers, WBXML body), so the trace of the run
        shows exactly what the tool sends.
    #>
    param([Parameter(Mandatory = $true)][Net.Http.HttpRequestMessage]$Request, [Parameter(Mandatory = $true)][hashtable]$State)

    $uri = $Request.RequestUri.AbsoluteUri
    $raw = { param([string]$Name) $values = $null; if ($Request.Headers.TryGetValues($Name, [ref]$values)) { @($values) -join ' ' } else { $null } }
    $userAgent = & $raw 'User-Agent'
    $body = if ($Request.Content) { [byte[]]$Request.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() } else { [byte[]]@() }
    $requestId = [guid]::NewGuid().ToString()

    if ($uri -match '/Microsoft-Server-ActiveSync') {
        $auth = $Request.Headers.Authorization
        $headers = @{}
        $identity = & $raw 'X-User-Identity'
        if ($identity) { $headers['X-User-Identity'] = $identity }
        $version = & $raw 'MS-ASProtocolVersion'
        if ($version) { $headers['MS-ASProtocolVersion'] = $version }
        $policyKey = & $raw 'X-MS-PolicyKey'
        $basicUser = $null
        $basicPassword = $null
        if ($auth -and $auth.Scheme -eq 'Basic' -and $auth.Parameter) {
            $pair = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($auth.Parameter)).Split(':', 2)
            $basicUser = $pair[0]
            $basicPassword = if ($pair.Count -gt 1) { $pair[1] } else { '' }
        }
        $answer = Get-SimEasResponse -Uri $uri -AccessToken $(if ($auth -and $auth.Scheme -eq 'Bearer' -and $auth.Parameter) { $auth.Parameter } else { '' }) `
            -EmptyBearer:([bool]($auth -and $auth.Scheme -eq 'Bearer' -and -not $auth.Parameter)) -BasicUser $basicUser -BasicPassword $basicPassword -PolicyKey $(if ($policyKey) { $policyKey } else { '0' }) `
            -Body $body -Headers $headers -UserAgent $userAgent -State $State
        # Header lines as Exchange Server SE sends them (lab, 2026-10-02).
        $lines = [Collections.Generic.List[string]]::new()
        $lines.Add('Cache-Control: private')
        if ($answer.Body.Length) { $lines.Add('Content-Type: application/vnd.ms-sync.wbxml') }
        $lines.Add('Server: Microsoft-IIS/10.0')
        $lines.Add("request-id: $requestId")
        foreach ($challenge in @($answer.Challenges)) { $lines.Add("WWW-Authenticate: $challenge") }
        foreach ($key in @($answer.Headers.Keys | Sort-Object)) { $lines.Add("$($key): $($answer.Headers[$key])") }
        $lines.Add('X-FEServer: EXMBX1')
        $lines.Add("Content-Length: $($answer.Body.Length)")
        return [pscustomobject]@{ StatusCode = $answer.StatusCode; Reason = $null; Headers = $answer.Headers; HeaderLines = @($lines); Challenges = @($answer.Challenges); Body = [byte[]]$answer.Body }
    }

    $json = $null
    $code = 200
    $html = $null
    $location = $null
    $entra = [regex]::Match($uri, '^https://login\.(microsoftonline\.com|windows\.net)/([^/?]+)/(.*)$')
    if ($entra.Success) {
        # Entra ID, as recorded for the tenant of a hybrid lab (2026-10-03).
        $tenant = $entra.Groups[2].Value
        $path = $entra.Groups[3].Value
        $known = $tenant -ieq $State.EntraTenantId -or @($State.EntraDomains | Where-Object { $_ -ieq $tenant }).Count
        $root = "https://login.microsoftonline.com/$($State.EntraTenantId)"
        if ($path -like 'v2.0/.well-known/openid-configuration*') {
            if ($known) {
                $json = [ordered]@{ token_endpoint = "$root/oauth2/v2.0/token"; device_authorization_endpoint = "$root/oauth2/v2.0/devicecode"; authorization_endpoint = "$root/oauth2/v2.0/authorize"; issuer = "$root/v2.0"; tenant_region_scope = 'EU' } | ConvertTo-Json -Compress
            }
            else {
                $code = 400
                $json = [ordered]@{ error = 'invalid_tenant'; error_description = "AADSTS90002: Tenant '$tenant' not found. Check to make sure you have the correct tenant ID and are signing into the correct cloud.`r`nTrace ID: 00000000"; error_codes = @(90002) } | ConvertTo-Json -Compress
            }
        }
        elseif ($tenant -eq 'common' -and $path -like 'userrealm/*') {
            $user = [Uri]::UnescapeDataString(($path -split '[/?]')[1])
            $realm = [ordered]@{ NameSpaceType = $State.UserRealm; Login = $user; DomainName = $user.Split('@')[-1]; FederationBrandName = 'Contoso'; cloud_instance_name = 'microsoftonline.com' }
            if ($State.UserRealm -eq 'Federated') { $realm.AuthURL = "https://adfs.contoso.test/adfs/ls/?username=$([Uri]::EscapeDataString($user))&wa=wsignin1.0" }
            $json = $realm | ConvertTo-Json -Compress
        }
        elseif ($path -like 'oauth2/v2.0/devicecode*') {
            $json = [ordered]@{
                user_code = 'EJ7KQ2LBN'; device_code = 'SimEntraDeviceCode' + ('y' * 48); verification_uri = 'https://microsoft.com/devicelogin'; expires_in = 900; interval = 1
                message = 'To sign in, use a web browser to open the page https://microsoft.com/devicelogin and enter the code EJ7KQ2LBN to authenticate.'
            } | ConvertTo-Json -Compress
        }
        elseif ($path -like 'oauth2/v2.0/token*' -and ($grant = Get-SimCodeGrant -Body $body -State $State)) {
            $code = $grant.Code
            $json = $grant.Json
        }
        elseif ($path -like 'oauth2/v2.0/token*') {
            $State.TokenPolls++
            if ($State.TokenPolls -le $State.TokenPendingPolls) {
                $code = 400
                $json = '{"error":"authorization_pending","error_description":"AADSTS70016: OAuth 2.0 device flow error. Authorization is pending. Continue polling.","error_codes":[70016]}'
            }
            elseif ($State.EntraTokenError) {
                $code = 400
                $json = [ordered]@{ error = 'invalid_resource'; error_description = "$($State.EntraTokenError)`r`nTrace ID: 00000000"; error_codes = @([int]([regex]::Match($State.EntraTokenError, 'AADSTS(\d+)').Groups[1].Value)) } | ConvertTo-Json -Compress
            }
            else {
                $json = [ordered]@{
                    token_type = 'Bearer'; scope = 'https://mail.contoso.test/EAS.AccessAsUser.All'; expires_in = 4486; ext_expires_in = 4486
                    access_token = $State.ValidToken; refresh_token = 'SimEntraRefreshToken' + ('r' * 40)
                } | ConvertTo-Json -Compress
            }
        }
        elseif ($path -like 'oauth2/authorize*') {
            $State.WebCalls.Add([pscustomobject]@{ Uri = $uri; UserAgent = $userAgent })
            $html = if ($State.EntraSignInPage -eq 'SignIn') {
                '<!DOCTYPE html><html><head><title>Sign in to your account</title></head><body><script>//<![CDATA[' + "`n" + '$Config={"pgid":"ConvergedSignIn","urlPost":"/common/login","sErrorCode":"50058"};' + "`n" + '//]]></script></body></html>'
            }
            else {
                '<!DOCTYPE html><html><head><title>Sign in to your account</title></head><body><script>//<![CDATA[' + "`n" + '$Config={"pgid":"ConvergedError","strServiceExceptionMessage":"' + $State.EntraSignInPage + '"};' + "`n" + '//]]></script></body></html>'
            }
        }
        else {
            $code = 404
        }
    }
    elseif ($uri -match '/\.well-known/openid-configuration') {
        $json = Get-SimMetadata | ConvertTo-Json -Compress
    }
    elseif ($uri -match '/oauth2/devicecode') {
        $json = [ordered]@{
            device_code = 'SimDeviceCode' + ('x' * 48); user_code = 'QDZ8-HKWP'; verification_uri = 'https://adfs.contoso.test/adfs/oauth2/deviceauth'
            expires_in = 900; interval = 1
            message = 'To sign in, use a web browser to open the page https://adfs.contoso.test/adfs/oauth2/deviceauth and enter the code QDZ8-HKWP to authenticate.'
        } | ConvertTo-Json -Compress
    }
    elseif ($uri -match '/oauth2/token' -and ($grant = Get-SimCodeGrant -Body $body -State $State)) {
        $code = $grant.Code
        $json = $grant.Json
    }
    elseif ($uri -match '/oauth2/token') {
        $State.TokenPolls++
        if ($State.TokenPolls -le $State.TokenPendingPolls) {
            $code = 400
            $json = '{"error":"authorization_pending"}'
        }
        else {
            $json = [ordered]@{
                access_token = $State.ValidToken; token_type = 'bearer'; expires_in = 3600; resource = 'https://mail.contoso.test/'
                refresh_token = 'SimRefreshToken' + ('r' * 40); refresh_token_expires_in = 28800; scope = 'EAS.AccessAsUser.All openid'
            } | ConvertTo-Json -Compress
        }
    }
    else {
        $web = Get-SimWebResponse -Uri $uri -UserAgent $userAgent -State $State
        $code = $web.StatusCode
        if ($web.Content -like '{*') { $json = $web.Content } elseif ($web.Content) { $html = $web.Content }
        if ($web.Location) { $location = $web.Location }
    }
    $text = if ($json) { $json } elseif ($html) { $html } else { '' }
    $type = if ($json) { 'application/json;charset=UTF-8' } elseif ($html) { 'text/html; charset=utf-8' } else { $null }
    $headers = @{}
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('Cache-Control: no-store')
    if ($type) { $headers['Content-Type'] = $type; $lines.Add("Content-Type: $type") }
    if ($location) { $headers['Location'] = $location; $lines.Add("Location: $location") }
    $lines.Add('Server: Microsoft-HTTPAPI/2.0')
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    $lines.Add("Content-Length: $($bytes.Length)")
    return [pscustomobject]@{ StatusCode = $code; Reason = $null; Headers = $headers; HeaderLines = @($lines); Challenges = @(); Body = [byte[]]$bytes }
}

function Get-SimCertificate([string]$HostName, [int]$Port, [int]$DaysLeft) {
    [pscustomobject]@{
        HostName = $HostName; Port = $Port; Reachable = $true; Valid = $true; Interrupted = $false; Subject = "CN=$HostName"; Issuer = 'CN=Contoso Issuing CA 01, DC=contoso, DC=test'
        NotAfterUtc = [DateTime]::UtcNow.AddDays($DaysLeft).ToString('yyyy-MM-ddTHH:mm:ssZ'); DaysLeft = $DaysLeft; Protocol = 'Tls13'; Error = $null
    }
}

function Install-SimExchange {
    <#
        Replaces the network inside the loaded module (documentation images, demos): Send-EomHttpRequest
        answers with Get-SimHttpResponse, the TLS check with Get-SimCertificate, Start-Process (browser)
        does nothing and the sign-in window is Get-SimWindowRedirect. Everything else is the real code of
        the module, the sign-in included.
        Remove-Module restores them.
    #>
    param([Parameter(Mandatory = $true)][psmoduleinfo]$Module, [Parameter(Mandatory = $true)][hashtable]$State)

    $responder = ${function:Get-SimHttpResponse}
    $certificate = ${function:Get-SimCertificate}
    $window = ${function:Get-SimWindowRedirect}
    . $Module {
        param($State, $Responder, $Certificate, $Window)
        $script:SimState = $State; $script:SimResponder = $Responder; $script:SimCertificate = $Certificate; $script:SimWindow = $Window
        function script:Send-EomHttpRequest {
            param($HttpClient, $Request)
            Start-Sleep -Milliseconds (Get-Random -Minimum 40 -Maximum 160)
            & $script:SimResponder -Request $Request -State $script:SimState
        }
        function script:Get-EomTlsCertificate { param([string]$HostName, [int]$Port = 443, [int]$TimeoutSeconds) & $script:SimCertificate $HostName $Port $script:SimState.CertificateDays }
        function script:Start-Process { }
        # The sign-in window: a desktop session with Microsoft Edge, the user signs in (no browser is started).
        function script:Test-EomDesktopSession { $true }
        function script:Find-EomBrowser { [pscustomobject]@{ Name = 'Microsoft Edge'; Path = 'msedge.exe' } }
        function script:Test-EomBrowserPolicyBlock { $false }
        function script:Invoke-EomBrowserAuthorization { param($Browser, $Url, $RedirectUri, $TimeoutSeconds) Start-Sleep -Milliseconds 400; & $script:SimWindow -Url $Url -RedirectUri $RedirectUri -State $script:SimState }
    } $State $responder $certificate $window
}
#endregion

$script:SimValidToken = New-SimToken
