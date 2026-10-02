<#
.SYNOPSIS
    EAS OAuth Mailbox - simulated AD FS and Exchange ActiveSync, for the tests and the documentation images.

.DESCRIPTION
    Dot-source this file. It builds WBXML answers byte by byte with the code pages of MS-ASWBXML
    (FolderSync 7, Provision 14, Settings 18, AirSync 0, Email 2) and answers like Exchange:
    401 + WWW-Authenticate Bearer only to an empty Bearer header (like Exchange SE), 401 + x-ms-diagnostics to a bad token,
    449 or ActiveSync status 142 until the policy is acknowledged, TEMPKEY then FINALKEY.

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
    Version : 1.0.0
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
function New-SimToken([string]$Audience = 'https://mail.contoso.test/', [string]$Scope = 'EAS.AccessAsUser.All', [string]$Upn = 'eas-test@contoso.test', [int]$ExpiresIn = 3600, [string]$AppId = 'd3590ed6-52b3-4102-aeff-aad2292ab01c') {
    $encode = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    $payload = [ordered]@{ aud = $Audience; iss = 'http://adfs.contoso.test/adfs/services/trust'; scp = $Scope; upn = $Upn; appid = $AppId; exp = [DateTimeOffset]::UtcNow.AddSeconds($ExpiresIn).ToUnixTimeSeconds() }
    '{0}.{1}.{2}' -f (& $encode @{ alg = 'RS256'; typ = 'JWT' }), (& $encode $payload), 'c2lnbmF0dXJl'
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
    }
}

function Get-SimEasResponse {
    <# What the simulated Exchange answers to one ActiveSync request. #>
    param([string]$Uri, [AllowEmptyString()][string]$AccessToken, [switch]$EmptyBearer, [string]$PolicyKey = '0', [byte[]]$Body, [hashtable]$Headers, [string]$UserAgent, [Parameter(Mandatory = $true)][hashtable]$State)

    $command = if ($Uri -match 'Cmd=(\w+)') { $Matches[1] } else { 'OPTIONS' }
    $identity = if ($Headers -and $Headers.ContainsKey('X-User-Identity')) { [string]$Headers['X-User-Identity'] } else { $null }
    $deviceType = if ($Uri -match 'DeviceType=(\w+)') { $Matches[1] } else { $null }
    $State.Calls.Add([pscustomobject]@{ Command = $command; PolicyKey = $PolicyKey; Token = $AccessToken; EmptyBearer = [bool]$EmptyBearer; Identity = $identity; UserAgent = $UserAgent; DeviceType = $deviceType; Body = $Body })
    $provisioned = -not $State.RequireProvisioning -or $PolicyKey -eq 'FINALKEY'
    switch ($command) {
        'OPTIONS' {
            # Headers recorded on Exchange Server SE with AD FS (Discovery run of 2026-10-02).
            $basic = 'Basic realm="mail.contoso.test"'
            $challenge = 'Bearer client_id="00000002-0000-0ff1-ce00-000000000000", token_types="app_asserted_user_v1 service_asserted_app_v1"'
            if ($State.AuthorizationUri) { $challenge += ", authorization_uri=""$($State.AuthorizationUri)""" }
            if (-not $AccessToken -and $EmptyBearer -and $identity -and $State.BearerChallenge -ne 'None') {
                if ($State.MailboxOAuth -eq 'Allowed') { return New-SimResponse 401 -Challenges @($basic, "$challenge, authorization_uri=""$($State.MailboxAuthorizationUri)"", issuer_kind=""ADFS""") }
                return New-SimResponse 401 -Challenges @($basic, "$challenge, error=""invalid_token""") -Headers @{ 'x-ms-diagnostics' = "4000000;reason=""Flighting is not enabled for domain '$identity'."";error_category=""oauth_not_available""" }
            }
            if (-not $AccessToken -and $EmptyBearer) {
                if ($State.BearerChallenge -eq 'None') { return New-SimResponse 401 -Challenges @($basic) }
                return New-SimResponse 401 -Challenges @($basic, "$challenge, error=""invalid_token""") -Headers @{ 'x-ms-diagnostics' = '4000000;reason="Flighting is not enabled for domain ''mail.contoso.test''.";error_category="oauth_not_available"' }
            }
            if (-not $AccessToken) {
                if ($State.BearerChallenge -eq 'Anonymous') { return New-SimResponse 401 -Challenges @($challenge, $basic) }
                return New-SimResponse 401 -Challenges @($basic)
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
        if ($State.AppleClient -eq 'NoPreferencesRedirect' -and $redirect -like 'com.apple.Preferences:*') {
            return & $web 200 '<html><body><div id="errorText">MSIS9224: Received invalid OAuth authorization request. The received &#39;redirect_uri&#39; parameter is not a valid registered redirect URI for the client identifier.</div></body></html>'
        }
        return & $web 200 '<html><body><form id="loginForm"><input id="userNameInput"/><input id="passwordInput" type="password"/></form></body></html>'
    }
    return & $web 404 ''
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
        $policyKey = & $raw 'X-MS-PolicyKey'
        $answer = Get-SimEasResponse -Uri $uri -AccessToken $(if ($auth -and $auth.Parameter) { $auth.Parameter } else { '' }) `
            -EmptyBearer:([bool]($auth -and $auth.Scheme -eq 'Bearer' -and -not $auth.Parameter)) -PolicyKey $(if ($policyKey) { $policyKey } else { '0' }) `
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
    if ($uri -match '/\.well-known/openid-configuration') {
        $json = Get-SimMetadata | ConvertTo-Json -Compress
    }
    elseif ($uri -match '/oauth2/devicecode') {
        $json = [ordered]@{
            device_code = 'SimDeviceCode' + ('x' * 48); user_code = 'QDZ8-HKWP'; verification_uri = 'https://adfs.contoso.test/adfs/oauth2/deviceauth'
            expires_in = 900; interval = 1
            message = 'To sign in, use a web browser to open the page https://adfs.contoso.test/adfs/oauth2/deviceauth and enter the code QDZ8-HKWP to authenticate.'
        } | ConvertTo-Json -Compress
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
        HostName = $HostName; Port = $Port; Reachable = $true; Valid = $true; Subject = "CN=$HostName"; Issuer = 'CN=Contoso Issuing CA 01, DC=contoso, DC=test'
        NotAfterUtc = [DateTime]::UtcNow.AddDays($DaysLeft).ToString('yyyy-MM-ddTHH:mm:ssZ'); DaysLeft = $DaysLeft; Protocol = 'Tls13'; Error = $null
    }
}

function Install-SimExchange {
    <#
        Replaces the network inside the loaded module (documentation images, demos): Send-EomHttpRequest
        answers with Get-SimHttpResponse, the TLS check with Get-SimCertificate, Start-Process (browser)
        does nothing. Everything else is the real code of the module, the device-code sign-in included.
        Remove-Module restores them.
    #>
    param([Parameter(Mandatory = $true)][psmoduleinfo]$Module, [Parameter(Mandatory = $true)][hashtable]$State)

    $responder = ${function:Get-SimHttpResponse}
    $certificate = ${function:Get-SimCertificate}
    . $Module {
        param($State, $Responder, $Certificate)
        $script:SimState = $State; $script:SimResponder = $Responder; $script:SimCertificate = $Certificate
        function script:Send-EomHttpRequest {
            param($HttpClient, $Request)
            Start-Sleep -Milliseconds (Get-Random -Minimum 40 -Maximum 160)
            & $script:SimResponder -Request $Request -State $script:SimState
        }
        function script:Get-EomTlsCertificate { param([string]$HostName, [int]$Port = 443, [int]$TimeoutSeconds) & $script:SimCertificate $HostName $Port $script:SimState.CertificateDays }
        function script:Start-Process { }
    } $State $responder $certificate
}
#endregion

$script:SimValidToken = New-SimToken
