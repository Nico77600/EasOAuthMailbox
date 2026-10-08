<#
.SYNOPSIS
    EAS OAuth Mailbox - sign-in, checks and orchestration (dot-sourced by EasOAuthMailbox.psm1).

.DESCRIPTION
    Invoke-EomMailboxTest runs the stages of a scenario in order with one shared context
    (token, HTTP client, DeviceId, policy key, folders...). Every check adds one step with a
    status: Passed, Warning, Blocked, Failed or Skipped. A stage that fails or is blocked stops
    the scenario: the following stages are reported as Skipped, never as failures of their own.

    The policy key received when the policy is acknowledged is sent with every following
    command (FolderSync, Settings, Sync).

    Authentication: OAuth (AD FS sign-in, access token) or Basic (user name and password sent with
    every request). With Basic the OAuth stage is replaced by the Basic stage, and Discovery and
    the iPhone account setup check what Basic needs instead of AD FS.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.2.1
#>

#region Helpers ---------------------------------------------------------------------------

function Get-EomField {
    <# Property of an object or key of a dictionary; $null when absent (safe under strict mode). #>
    param([AllowNull()][object]$Object, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function ConvertTo-EomBase64Url {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-EomBase64Url {
    param([Parameter(Mandatory = $true)][string]$Text)
    $value = $Text.Replace('-', '+').Replace('_', '/')
    switch ($value.Length % 4) { 2 { $value += '==' } 3 { $value += '=' } }
    return [Convert]::FromBase64String($value)
}

function Invoke-EomUiPump {
    <# Keeps the GUI responsive during long waits (no effect on the command line). #>
    if ($script:Ui -and $script:Ui.Pump) { & $script:Ui.Pump }
}

function Assert-EomNotCancelled {
    if ($script:Ui -and $script:Ui.Cancel) { throw 'Cancelled by the operator.' }
}

function Wait-EomSeconds {
    param([Parameter(Mandatory = $true)][double]$Seconds)
    $until = [DateTimeOffset]::UtcNow.AddSeconds($Seconds)
    while ([DateTimeOffset]::UtcNow -lt $until) {
        Invoke-EomUiPump
        Assert-EomNotCancelled
        Start-Sleep -Milliseconds 200
    }
}

function Invoke-EomHttpGet {
    <# JSON GET without credentials (AD FS metadata), traced. Throws when the answer is not HTTP 200 with JSON. #>
    param([Parameter(Mandatory = $true)][Net.Http.HttpClient]$HttpClient, [Parameter(Mandatory = $true)][string]$Uri)

    $response = Invoke-EomWebRequest -HttpClient $HttpClient -Uri $Uri -UserAgent $script:EomUserAgent -Headers @{ Accept = 'application/json' }
    if ($response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode)" }
    return ($response.Content | ConvertFrom-Json -ErrorAction Stop)
}

function Invoke-EomWebRequest {
    <#
        GET without credentials and without following redirects (Autodiscover, AD FS pages), traced.
        Returns StatusCode, Location and Content (text).
    #>
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$HttpClient,
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$UserAgent,
        [hashtable]$Headers
    )

    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
    try {
        if ($UserAgent) { $null = $request.Headers.TryAddWithoutValidation('User-Agent', $UserAgent) }
        if ($Headers) { foreach ($name in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation([string]$name, [string]$Headers[$name]) } }
        $response = Invoke-EomHttp -HttpClient $HttpClient -Request $request
        [pscustomobject]@{
            StatusCode = $response.StatusCode
            Location   = if ($response.Headers -and $response.Headers.ContainsKey('Location')) { [string]$response.Headers['Location'] } else { $null }
            Content    = if ($response.Body) { [Text.Encoding]::UTF8.GetString([byte[]]$response.Body) } else { '' }
        }
    }
    finally {
        $request.Dispose()
    }
}

function Invoke-EomFormPost {
    <# POST of form fields to AD FS (device code, token), traced. Returns StatusCode and the JSON answer (or $null). #>
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$HttpClient,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][System.Collections.IDictionary]$Fields,
        [string]$UserAgent,
        [string]$Collapse
    )

    $pairs = [Collections.Generic.List[Collections.Generic.KeyValuePair[string, string]]]::new()
    foreach ($key in $Fields.Keys) { $pairs.Add([Collections.Generic.KeyValuePair[string, string]]::new([string]$key, [string]$Fields[$key])) }
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Post, $Uri)
    try {
        $request.Content = [Net.Http.FormUrlEncodedContent]::new($pairs)
        $null = $request.Headers.TryAddWithoutValidation('User-Agent', $(if ($UserAgent) { $UserAgent } else { $script:EomUserAgent }))
        $null = $request.Headers.TryAddWithoutValidation('Accept', 'application/json')
        $response = Invoke-EomHttp -HttpClient $HttpClient -Request $request -Collapse $Collapse
        $json = $null
        if ($response.Body -and $response.Body.Length) {
            try { $json = [Text.Encoding]::UTF8.GetString([byte[]]$response.Body) | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
        }
        [pscustomobject]@{ StatusCode = $response.StatusCode; Json = $json }
    }
    finally {
        $request.Dispose()
    }
}

function Get-EomTlsCertificate {
    <#
        Server certificate of HostName:Port with the default Windows validation. Reachable = $false
        when no direct TCP connection is possible (proxy, firewall); Valid = $false when the TLS
        handshake fails: Interrupted = $true when the connection was closed before the server sent a
        certificate (firewall, NSG, proxy or VPN client on the path), $false when the certificate was
        received and rejected.
    #>
    param([Parameter(Mandatory = $true)][string]$HostName, [int]$Port = 443, [int]$TimeoutSeconds = 10)

    $result = [ordered]@{ HostName = $HostName; Port = $Port; Reachable = $false; Valid = $false; Interrupted = $false; Subject = $null; Issuer = $null; NotAfterUtc = $null; DaysLeft = $null; Protocol = $null; Error = $null }
    $tcp = [Net.Sockets.TcpClient]::new()
    try {
        try {
            if (-not $tcp.ConnectAsync($HostName, $Port).Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
                $result.Error = "no TCP connection within $TimeoutSeconds s"
                return [pscustomobject]$result
            }
        }
        catch {
            $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
            $result.Error = $inner.Message
            return [pscustomobject]$result
        }
        $result.Reachable = $true
        $tcp.ReceiveTimeout = $TimeoutSeconds * 1000
        $tcp.SendTimeout = $TimeoutSeconds * 1000
        # Same decision as Windows (no policy error), and a trace of whether a certificate arrived at all.
        $received = @{ Certificate = $false; Errors = $null }
        $validate = [Net.Security.RemoteCertificateValidationCallback]{
            param($sender, $certificate, $chain, $errors)
            if ($certificate) { $received.Certificate = $true }
            if ($errors -ne [Net.Security.SslPolicyErrors]::None) {
                $status = @($chain.ChainStatus | ForEach-Object { [string]$_.Status } | Where-Object { $_ -ne 'NoError' } | Select-Object -Unique)
                $received.Errors = "The remote certificate is invalid: $errors$(if ($status) { " ($($status -join ', '))" })"
            }
            return $errors -eq [Net.Security.SslPolicyErrors]::None
        }.GetNewClosure()
        $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false, $validate)
        try {
            try {
                $ssl.AuthenticateAsClient($HostName)
            }
            catch {
                $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
                $result.Error = if ($received.Errors) { $received.Errors } else { $inner.Message }
                $result.Interrupted = -not $received.Certificate
                return [pscustomobject]$result
            }
            $certificate = [Security.Cryptography.X509Certificates.X509Certificate2]::new($ssl.RemoteCertificate)
            $notAfter = $certificate.NotAfter.ToUniversalTime()
            $result.Valid = $true
            $result.Subject = $certificate.Subject
            $result.Issuer = $certificate.Issuer
            $result.NotAfterUtc = $notAfter.ToString('yyyy-MM-ddTHH:mm:ssZ')
            $result.DaysLeft = [int][Math]::Floor(($notAfter - [DateTime]::UtcNow).TotalDays)
            $result.Protocol = [string]$ssl.SslProtocol
            return [pscustomobject]$result
        }
        finally {
            $ssl.Dispose()
        }
    }
    finally {
        $tcp.Dispose()
    }
}

function Get-EomChallengeInfo {
    <# Schemes of the WWW-Authenticate challenges, and the parameters of the Bearer challenge. #>
    param([AllowEmptyCollection()][string[]]$Challenges)

    $schemes = [Collections.Generic.List[string]]::new()
    $parameters = @{}
    $bearer = $false
    foreach ($challenge in @($Challenges)) {
        if ([string]::IsNullOrWhiteSpace($challenge)) { continue }
        $scheme = ($challenge.Trim() -split '\s+', 2)[0].TrimEnd(',')
        if (-not $schemes.Contains($scheme)) { [void]$schemes.Add($scheme) }
        if ($scheme -ieq 'Bearer') {
            $bearer = $true
            foreach ($m in [regex]::Matches($challenge, '([A-Za-z_]+)\s*=\s*"([^"]*)"')) { $parameters[$m.Groups[1].Value.ToLowerInvariant()] = $m.Groups[2].Value }
        }
    }
    [pscustomobject]@{
        Schemes          = @($schemes)
        Bearer           = $bearer
        AuthorizationUri = $parameters['authorization_uri']
        IssuerKind       = $parameters['issuer_kind']
        # Entra ID (hybrid modern authentication): <token service ID>@<tenant ID>, comma separated.
        TrustedIssuers   = @(([string]$parameters['trusted_issuers']).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Error            = $parameters['error']
    }
}

function Get-EomAuthorityInfo {
    <#
        What an authorization URL given by Exchange points to: AD FS (https://<host>/adfs/oauth2/authorize,
        AdfsRoot) or Entra ID (login.microsoftonline.com, login.windows.net..., Tenant: the path segment:
        common, organizations, a tenant ID or a domain). Kind None when there is no URL, Other otherwise.
    #>
    param([AllowEmptyString()][string]$Uri)

    $info = [ordered]@{ Kind = 'None'; Uri = $Uri; Host = $null; AdfsRoot = $null; Tenant = $null; Name = 'no authorization server' }
    $parsed = $null
    if (-not $Uri -or -not [Uri]::TryCreate($Uri, [UriKind]::Absolute, [ref]$parsed)) { return [pscustomobject]$info }
    $info.Host = $parsed.Host
    $adfs = [regex]::Match($Uri, '^(https://[^/?#]+/adfs)/oauth2/authorize', 'IgnoreCase')
    if ($adfs.Success) {
        $info.Kind = 'ADFS'; $info.AdfsRoot = $adfs.Groups[1].Value; $info.Name = "AD FS ($($parsed.Host))"
    }
    elseif ($script:Entra.Hosts -contains $parsed.Host.ToLowerInvariant()) {
        $info.Kind = 'EntraID'
        $info.Tenant = ($parsed.AbsolutePath.Trim('/') -split '/')[0]
        $info.Name = "Entra ID ($($parsed.Host))"
    }
    else {
        $info.Kind = 'Other'; $info.Name = $parsed.Host
    }
    [pscustomobject]$info
}

function Test-EomExpectedAuthority {
    <#
        Compares the authorization server named by Exchange with the one the test expects (Target.Authority).
        Returns $null when they match (or when the test takes the one of Exchange: Auto), otherwise
        the text of the warning.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][pscustomobject]$Advertised)

    $ep = $Context.Endpoints
    if ($Advertised.Kind -eq 'None') { return $null }
    switch ([string]$Context.Config.Authority) {
        'ADFS' {
            if ($Advertised.Kind -eq 'EntraID') {
                return "Exchange sends clients to Entra ID ($($Advertised.Uri)): hybrid modern authentication is enabled (Get-AuthServer: EvoSts is the default authorization endpoint), not AD FS $($ep.AdfsHost). Test it with -Authority EntraID."
            }
            if ($ep.AdfsHost -and $Advertised.Host -ine $ep.AdfsHost) {
                return "Exchange names the authorization server $($Advertised.Host), not $($ep.AdfsHost): clients will sign in there. Check Get-AuthServer (IsDefaultAuthorizationEndpoint)."
            }
        }
        'EntraID' {
            if ($Advertised.Kind -ne 'EntraID') {
                $evo = 'Set-AuthServer ''EvoSts - <ID>'' -IsDefaultAuthorizationEndpoint $true and Set-OrganizationConfig -OAuth2ClientProfileEnabled $true'
                return "Exchange sends clients to $($Advertised.Name), not to Entra ID: hybrid modern authentication is not enabled. Run the Hybrid Configuration Wizard, then $evo."
            }
            if ($Context.TenantId -and $Advertised.Tenant -match '^[0-9a-fA-F-]{36}$' -and $Advertised.Tenant -ine $Context.TenantId) {
                return "Exchange sends clients to the Entra ID tenant $($Advertised.Tenant), not to $($Context.TenantId): check Get-AuthServer (EvoSts, IsDefaultAuthorizationEndpoint) and Target.TenantId."
            }
        }
    }
    return $null
}

function Get-EomOverallStatus {
    <# Failed > Blocked > Warning > Passed. Skipped steps never decide the status alone. #>
    param([AllowEmptyCollection()][object[]]$Steps)

    $statuses = @($Steps | ForEach-Object { $_.Status })
    if ($statuses -contains 'Failed') { return 'Failed' }
    if ($statuses -contains 'Blocked') { return 'Blocked' }
    if ($statuses -contains 'Warning') { return 'Warning' }
    if (@($statuses | Where-Object { $_ -eq 'Passed' }).Count) { return 'Passed' }
    return 'Failed'
}

function Add-EomStep {
    <# Records one check: status, message, details and the time spent since the previous step. #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][ValidateSet('Passed', 'Warning', 'Blocked', 'Failed', 'Skipped')][string]$Status,
        [Parameter(Mandatory = $true)][string]$Message,
        [System.Collections.IDictionary]$Details
    )

    $elapsed = $Context.Clock.Elapsed.TotalMilliseconds
    $Context.Clock.Restart()
    $copy = [ordered]@{}
    if ($Details) { foreach ($key in $Details.Keys) { $copy[$key] = $Details[$key] } }
    # The HTTP exchanges sent since the previous check belong to this one.
    $trace = Complete-EomTraceStep -Step ($Context.Steps.Count + 1) -Name $Name
    $Context.Steps.Add([pscustomobject]@{
            Stage        = $Stage
            Name         = $Name
            Status       = $Status
            Message      = $Message
            Details      = $copy
            Trace        = @($trace)
            DurationMs   = [int][Math]::Round($elapsed)
            TimestampUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        })
    $item = @{ Passed = 'Ok'; Warning = 'Warn'; Blocked = 'Block'; Failed = 'Fail'; Skipped = 'Skip' }[$Status]
    Write-EomItem $item ('{0}: {1}' -f $Name, $Message)
}

function Get-EomCommandUri {
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Command)
    '{0}?Cmd={1}&User={2}&DeviceId={3}&DeviceType={4}' -f $Context.Endpoints.EasUrl, $Command, $Context.EncodedUser, $Context.DeviceId, $Context.Config.DeviceType
}

function Invoke-EomCommand {
    <# POST of one ActiveSync command with the token (OAuth) or the user name and password (Basic), and the current policy key. #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Command, [Parameter(Mandatory = $true)][byte[]]$Body)
    Invoke-EomUiPump
    Assert-EomNotCancelled
    Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Post) -Uri (Get-EomCommandUri $Context $Command) `
        -AccessToken $Context.AccessToken -Credential $Context.Credential -Body $Body -PolicyKey $Context.PolicyKey
}

#endregion

#region OAuth ------------------------------------------------------------------------------

function Get-EomEntraErrorHint {
    <# What to check for the Entra ID errors (AADSTS codes) a sign-in meets most often. #>
    param([AllowEmptyString()][string]$Description, [string]$Resource, [switch]$ExchangeOnline)

    $code = [regex]::Match($Description, 'AADSTS(\d+)').Groups[1].Value
    switch ($code) {
        '500011' {
            if ($ExchangeOnline) { return "Exchange Online ($Resource) is not found in this tenant: check the tenant (Target.TenantId, the domain of the mailbox) and that it has Exchange Online." }
            return "the URL $Resource is not a service principal name of Office 365 Exchange Online ($($script:Entra.ExchangeApp)) in this tenant: run the Hybrid Configuration Wizard, or add the external and internal ActiveSync URLs to its servicePrincipalNames (Microsoft Graph, Update-MgServicePrincipal)."
        }
        '65001' { return 'the user or an administrator has not consented to this client for Exchange: grant the consent in Entra ID (Enterprise applications).' }
        '90094' { return 'an administrator must consent to this client (users cannot consent in this tenant): grant admin consent to the application in Entra ID (Enterprise applications), for example "Apple Internet Accounts" for the Mail app of the iPhone.' }
        '53003' { return 'a Conditional Access policy blocked the sign-in: read the sign-in log of the user in Entra ID (Conditional Access tab).' }
        '50105' { return 'the user is not assigned to the application (assignment required).' }
        '700016' { return 'this client ID does not exist in the tenant (Target.ClientId).' }
        '7000218' { return 'the client is not a public client: the device-code flow needs a public client (Allow public client flows).' }
        { $_ -in '50020', '50034', '90072' } { return 'the account used in the browser is not a user of this tenant.' }
        '50076' { return 'multi-factor authentication is required: complete it in the browser.' }
        '90002' { return 'the tenant does not exist (Target.TenantId or the domain of the mailbox).' }
        default { return $null }
    }
}

function Invoke-EomDeviceCodeAuthentication {
    <#
        Device-code flow (RFC 8628) with AD FS or Entra ID, every request traced. The verification
        page is opened; the code is shown in the console and the GUI. UserAgent: the one of the
        client played (the iPhone setup screen for AppleMail).
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Configuration,
        [Parameter(Mandatory = $true)][pscustomobject]$Endpoints,
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$HttpClient,
        [string]$UserAgent
    )

    $server = if ($Endpoints.Authority -eq 'EntraID') { 'Entra ID' } else { 'AD FS' }
    $explain = {
        param([string]$Description)
        $first = ([string]$Description -split "`r?`n")[0]
        $hint = if ($Endpoints.Authority -eq 'EntraID') { Get-EomEntraErrorHint -Description $first -Resource $Endpoints.Resource -ExchangeOnline:$Endpoints.ExchangeOnline } else { $null }
        if ($hint) { "$first Cause: $hint" } else { $first }
    }
    $requested = Invoke-EomFormPost -HttpClient $HttpClient -Uri $Endpoints.DeviceCodeEndpoint -UserAgent $UserAgent `
        -Fields ([ordered]@{ client_id = [string]$Configuration.ClientId; scope = $Endpoints.Scope })
    $deviceCode = $requested.Json
    if ($requested.StatusCode -ne 200) {
        throw ('{0} refused the device-code request (HTTP {1}): {2} - {3}' -f $server, $requested.StatusCode, [string](Get-EomField $deviceCode 'error'), (& $explain ([string](Get-EomField $deviceCode 'error_description'))))
    }
    $deviceCodeValue = [string](Get-EomField $deviceCode 'device_code')
    if ([string]::IsNullOrWhiteSpace($deviceCodeValue)) { throw "$server did not return a device code." }
    $expiresIn = 0
    if (-not [int]::TryParse([string](Get-EomField $deviceCode 'expires_in'), [ref]$expiresIn) -or $expiresIn -le 0) {
        throw "$server did not return a valid device-code expiration."
    }
    $interval = 5
    $serverInterval = 0
    if ([int]::TryParse([string](Get-EomField $deviceCode 'interval'), [ref]$serverInterval) -and $serverInterval -gt 0) {
        $interval = [Math]::Max($serverInterval, 5)
    }
    $verificationUrl = [string](Get-EomField $deviceCode 'verification_uri_complete')
    if ([string]::IsNullOrWhiteSpace($verificationUrl)) { $verificationUrl = [string](Get-EomField $deviceCode 'verification_uri') }
    if ([string]::IsNullOrWhiteSpace($verificationUrl)) { throw "$server did not return a verification URL." }

    $message = [string](Get-EomField $deviceCode 'message')
    $userCode = [string](Get-EomField $deviceCode 'user_code')
    if ($message) { Write-EomItem Info $message -Icon Key }
    if ($userCode) { Write-EomItem Info ("Code: {0}  -  page: {1}" -f $userCode, [string](Get-EomField $deviceCode 'verification_uri')) -Icon Key }
    Write-EomItem Info 'Sign in with the account of the test: if the browser is already signed in with another account (work profile), open the page in a private window.' -Icon Key
    Write-EomItem Info ('Waiting for the sign-in in the browser (up to {0}).' -f (Format-EomDuration ([Math]::Min($expiresIn, [int]$Configuration.OAuthPollTimeoutSeconds)))) -Icon Clock
    # No browser in a service session, Server Core or SSH: the code is signed in from any other device.
    try { Start-Process -FilePath $verificationUrl -ErrorAction Stop | Out-Null }
    catch { Write-EomItem Info "No browser could be opened here ($($_.Exception.Message)): open $verificationUrl on any device and enter the code." -Icon Key }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Min($expiresIn, [int]$Configuration.OAuthPollTimeoutSeconds))
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Wait-EomSeconds $interval
        $answer = Invoke-EomFormPost -HttpClient $HttpClient -Uri $Endpoints.TokenEndpoint -UserAgent $UserAgent -Collapse 'TokenPoll' -Fields ([ordered]@{
                grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                client_id   = [string]$Configuration.ClientId
                device_code = $deviceCodeValue
            })
        if ($answer.StatusCode -eq 200) {
            $accessToken = [string](Get-EomField $answer.Json 'access_token')
            if ([string]::IsNullOrWhiteSpace($accessToken)) { throw "$server returned a token response without access_token." }
            return $accessToken
        }
        $code = [string](Get-EomField $answer.Json 'error')
        if (-not $code) { throw "$server token request failed: HTTP $($answer.StatusCode) without an OAuth error." }
        if ($code -eq 'authorization_pending') { continue }
        if ($code -eq 'slow_down') { $interval += 5; continue }
        if ($code -in 'access_denied', 'authorization_declined') { throw "$server sign-in was denied." }
        if ($code -eq 'expired_token') { throw "The $server device code expired before the sign-in was completed." }
        throw ('{0} token request failed: {1} - {2}' -f $server, $code, (& $explain ([string](Get-EomField $answer.Json 'error_description'))))
    }
    throw "$server did not return an access token before the configured timeout (Test.OAuthPollTimeoutSeconds)."
}

function Get-EomUrlFields {
    <# Parameters of the query (and fragment) of a URL, decoded. #>
    param([Parameter(Mandatory = $true)][string]$Url)

    $fields = @{}
    $start = $Url.IndexOfAny([char[]]'?#')
    if ($start -lt 0) { return $fields }
    foreach ($pair in $Url.Substring($start + 1).Split([char[]]'&#', [StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $pair.Split('=', 2)
        $fields[[Uri]::UnescapeDataString($parts[0])] = if ($parts.Count -gt 1) { [Uri]::UnescapeDataString($parts[1].Replace('+', ' ')) } else { '' }
    }
    return $fields
}

function Get-EomSignInRequest {
    <#
        Authorization request of the sign-in window: authorization code with PKCE (S256), a random state,
        the account of the test as login_hint and prompt=login (the password is always typed). Redirect
        URI: the native-client page for Entra ID, urn:ietf:wg:oauth:2.0:oob for AD FS, and for AppleMail
        the redirect URI of the iPhone with its client capability (claims).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Configuration, [Parameter(Mandatory = $true)][pscustomobject]$Endpoints, [switch]$Apple)

    $verifier = ConvertTo-EomBase64Url ([Security.Cryptography.RandomNumberGenerator]::GetBytes(32))
    $challenge = ConvertTo-EomBase64Url ([Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($verifier)))
    $redirect = if ($Apple) { $script:AppleMail.RedirectUris[0] } elseif ($Endpoints.Authority -eq 'EntraID') { $script:SignInRedirect.EntraID } else { $script:SignInRedirect.ADFS }
    $state = [guid]::NewGuid().ToString('N')
    $query = [ordered]@{
        response_type = 'code'; client_id = [string]$Configuration.ClientId; redirect_uri = $redirect; scope = $Endpoints.Scope; state = $state
        code_challenge = $challenge; code_challenge_method = 'S256'; login_hint = [string]$Configuration.Mailbox; prompt = 'login'
    }
    if ($Apple) { $query.claims = $script:AppleMail.Claims }
    [pscustomobject]@{
        Url         = $Endpoints.AuthorizeEndpoint + '?' + (@($query.Keys | ForEach-Object { '{0}={1}' -f $_, [Uri]::EscapeDataString([string]$query[$_]) }) -join '&')
        RedirectUri = $redirect
        State       = $state
        Verifier    = $verifier
    }
}

function Invoke-EomWindowAuthentication {
    <#
        Sign-in in the window (authorization code with PKCE), then the code exchanged for the token,
        traced. The trace keeps what the window opened and the redirect caught, the code masked: the
        pages of the sign-in itself (password, MFA) are exchanged by the browser.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Configuration,
        [Parameter(Mandatory = $true)][pscustomobject]$Endpoints,
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$HttpClient,
        [Parameter(Mandatory = $true)][pscustomobject]$Browser,
        [string]$UserAgent,
        [switch]$Apple
    )

    $entra = $Endpoints.Authority -eq 'EntraID'
    $server = if ($entra) { 'Entra ID' } else { 'AD FS' }
    $explain = {
        param([string]$Description)
        $first = ([string]$Description -split "`r?`n")[0]
        $hint = if ($entra) { Get-EomEntraErrorHint -Description $first -Resource $Endpoints.Resource -ExchangeOnline:$Endpoints.ExchangeOnline } else { $null }
        if ($hint) { "$first Cause: $hint" } else { $first }
    }
    $request = Get-EomSignInRequest -Configuration $Configuration -Endpoints $Endpoints -Apple:$Apple
    $timeout = [int]$Configuration.OAuthPollTimeoutSeconds
    Write-EomItem Info ('Sign-in window ({0}, temporary profile): sign in as {1} on the {2} page - password, then MFA if asked. The window closes by itself.' -f $Browser.Name, $Configuration.Mailbox, $server) -Icon Key
    Write-EomItem Info ('Waiting for the sign-in in the window (up to {0}).' -f (Format-EomDuration $timeout)) -Icon Clock
    $opened = "GET $($request.Url)`n`nOpened in the sign-in window: $($Browser.Name) in app mode, temporary profile deleted afterwards.`nThe sign-in pages (password, MFA) are exchanged by the browser and are not recorded."
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $redirect = Invoke-EomBrowserAuthorization -Browser $Browser -Url $request.Url -RedirectUri $request.RedirectUri -TimeoutSeconds $timeout
    }
    catch {
        Add-EomTraceEntry -Method 'GET' -Url $request.Url -Request $opened -Response "No authorization code: $($_.Exception.Message)" -StatusCode $null -DurationMs $clock.ElapsedMilliseconds -Label 'sign-in window'
        # The window could not start at all: the caller decides (device code with Test.SignIn Auto).
        if ($_.Exception -is [NotSupportedException]) { throw }
        throw "The $server sign-in in the window did not complete: $($_.Exception.Message)"
    }
    $masked = [regex]::Replace($redirect, '([?&#]code=)([^&#]+)', { param($m) $m.Groups[1].Value + "<$($m.Groups[2].Value.Length) characters, never written>" })
    Add-EomTraceEntry -Method 'GET' -Url $request.Url -Request $opened -Response "Redirect caught by the tool (not followed by the browser):`n$masked" `
        -StatusCode 302 -Reason 'Redirect caught' -DurationMs $clock.ElapsedMilliseconds -Label 'sign-in window'
    $fields = Get-EomUrlFields -Url $redirect
    if ($fields['error']) { throw ('{0} answered the sign-in with the error {1}: {2}' -f $server, $fields['error'], (& $explain ([string]$fields['error_description']))) }
    if ([string]$fields['state'] -ne $request.State) { throw "$server returned an authorization code with another state: it does not answer this sign-in." }
    $code = [string]$fields['code']
    if (-not $code) { throw "$server redirected to $($request.RedirectUri) without an authorization code." }

    $token = [ordered]@{ grant_type = 'authorization_code'; client_id = [string]$Configuration.ClientId; code = $code; redirect_uri = $request.RedirectUri; code_verifier = $request.Verifier }
    if ($entra) { $token.scope = $Endpoints.Scope }
    $answer = Invoke-EomFormPost -HttpClient $HttpClient -Uri $Endpoints.TokenEndpoint -UserAgent $UserAgent -Fields $token
    if ($answer.StatusCode -ne 200) {
        throw ('{0} refused the authorization code (HTTP {1}): {2} - {3}' -f $server, $answer.StatusCode, [string](Get-EomField $answer.Json 'error'), (& $explain ([string](Get-EomField $answer.Json 'error_description'))))
    }
    $accessToken = [string](Get-EomField $answer.Json 'access_token')
    if ([string]::IsNullOrWhiteSpace($accessToken)) { throw "$server returned a token response without access_token." }
    [pscustomobject]@{ AccessToken = $accessToken; RedirectUri = $request.RedirectUri }
}

function Test-EomAdfsWindowRedirect {
    <#
        Before the window opens with AD FS: the authorization page must accept the redirect URI of the
        window for the client (urn:ietf:wg:oauth:2.0:oob, registered by the Exchange documentation).
        Returns the outcome of Get-EomAuthorizeOutcome.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $cfg = $Context.Config
    $query = [ordered]@{ response_type = 'code'; client_id = [string]$cfg.ClientId; redirect_uri = $script:SignInRedirect.ADFS; scope = $Context.Endpoints.Scope; state = 'eom-check' }
    $url = $Context.Endpoints.AuthorizeEndpoint + '?' + (@($query.Keys | ForEach-Object { '{0}={1}' -f $_, [Uri]::EscapeDataString([string]$query[$_]) }) -join '&')
    try { Get-EomAuthorizeOutcome -Response (Invoke-EomWebRequest -HttpClient $Context.HttpClient -Uri $url -UserAgent $script:EomUserAgent) }
    catch { [pscustomobject]@{ Code = 'Error'; Text = "AD FS not reachable: $($_.Exception.Message)" } }
}

function Get-EomTokenClaims {
    <# Payload of a JWT access token as a hashtable, or $null if the token is not a readable JWT. The signature is not checked. #>
    param([Parameter(Mandatory = $true)][string]$AccessToken)

    $parts = $AccessToken.Split('.')
    if ($parts.Count -lt 2) { return $null }
    try {
        $json = [Text.Encoding]::UTF8.GetString((ConvertFrom-EomBase64Url $parts[1]))
        $claims = $json | ConvertFrom-Json -AsHashtable
        if ($claims -isnot [hashtable]) { return $null }
        return $claims
    }
    catch {
        return $null
    }
}

function Test-EomTokenClaims {
    <#
        Audience, scope and expiry of the token compared with the ActiveSync resource. Entra ID
        (TenantId set): also the tenant of the token (tid). Returns Status, Message, Details.
    #>
    param(
        [AllowNull()][hashtable]$Claims,
        [Parameter(Mandatory = $true)][pscustomobject]$Endpoints,
        [Parameter(Mandatory = $true)][string]$Mailbox,
        # Client the token must be issued to (AppleMail scenario); not checked when empty.
        [string]$ExpectedClientId,
        # Entra ID: tenant the token must come from; not checked when empty.
        [string]$TenantId,
        [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow
    )

    if ($null -eq $Claims) {
        return [pscustomobject]@{ Status = 'Warning'; Message = 'The access token is not a readable JWT: its claims were not checked.'; Details = [ordered]@{} }
    }
    $first = { param([string[]]$Names) foreach ($n in $Names) { if ($Claims.ContainsKey($n) -and -not [string]::IsNullOrWhiteSpace([string]$Claims[$n])) { return [string]$Claims[$n] } }; return $null }
    $audiences = @($Claims['aud'] | Where-Object { $_ })
    $scope = & $first @('scp', 'scope')
    $user = & $first @('upn', 'unique_name', 'email', 'preferred_username')
    $expires = $null
    $exp = 0L
    if ([long]::TryParse([string]$Claims['exp'], [ref]$exp)) { $expires = [DateTimeOffset]::FromUnixTimeSeconds($exp) }

    $details = [ordered]@{
        Issuer     = & $first @('iss')
        Audience   = $audiences -join ', '
        Scope      = $scope
        User       = $user
        ClientId   = & $first @('appid', 'client_id', 'azp')
        TenantId   = & $first @('tid')
        ExpiresUtc = if ($expires) { $expires.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
        MinutesLeft = if ($expires) { [int][Math]::Floor(($expires - $Now).TotalMinutes) } else { $null }
    }
    if ($expires -and $expires -le $Now) {
        return [pscustomobject]@{ Status = 'Failed'; Message = "The token expired at $($details.ExpiresUtc)."; Details = $details }
    }
    $issues = [Collections.Generic.List[string]]::new()
    if (-not $expires) { [void]$issues.Add('the token has no exp claim') }
    $expected = $Endpoints.Resource.TrimEnd('/')
    $cloud = @($audiences | Where-Object { $_ -ieq $script:Entra.ExchangeApp -or $_ -match 'outlook\.office(365)?\.com' }).Count
    # Exchange Online accepts every audience of Office 365 Exchange Online (its ID, outlook.office.com, outlook.office365.com).
    $matched = @($audiences | Where-Object { ([string]$_).TrimEnd('/') -ieq $expected }).Count -or ($Endpoints.ExchangeOnline -and $cloud)
    if (-not $matched) {
        $why = if ($cloud) { ': the token is for Exchange Online, not for the on-premises URL' } else { '' }
        [void]$issues.Add("the audience '$($details.Audience)' is not the ActiveSync resource '$($Endpoints.Resource)'$why. Exchange will reject the token (HTTP 401)")
    }
    if ($scope -notmatch '(^|\s)EAS\.AccessAsUser\.All(\s|$)') {
        [void]$issues.Add("the scope '$scope' does not contain EAS.AccessAsUser.All")
    }
    if ($ExpectedClientId -and $details.ClientId -and $details.ClientId -ine $ExpectedClientId) {
        [void]$issues.Add("the token was issued to the client $($details.ClientId), not to $ExpectedClientId")
    }
    if ($TenantId -and $details.TenantId -and $details.TenantId -ine $TenantId) {
        $trust = if ($Endpoints.ExchangeOnline) { 'Exchange Online looks for the mailbox in the tenant of the token' } else { 'Exchange trusts only the tenant of its EvoSts authorization server' }
        [void]$issues.Add("the token comes from the tenant $($details.TenantId), not from $($TenantId): $trust")
    }
    $note = if ($user -and $user -ine $Mailbox) { " Token user $user is not written like the mailbox $Mailbox (UPN and SMTP address can differ): the Identity check confirms the mailbox." } else { '' }
    if ($issues.Count) {
        return [pscustomobject]@{ Status = 'Warning'; Message = ('Token received, but ' + ($issues -join '; ') + '.' + $note); Details = $details }
    }
    $left = if ($null -ne $details.MinutesLeft) { " (valid for $($details.MinutesLeft) min)" } else { '' }
    $tenantText = if ($TenantId -and $details.TenantId) { ', tenant' } else { '' }
    return [pscustomobject]@{ Status = 'Passed'; Message = "Audience, scope$tenantText and expiry match the ActiveSync resource$left.$note"; Details = $details }
}

#endregion

#region Stages -----------------------------------------------------------------------------

function Test-EomMailboxChallenge {
    <#
        What Exchange tells a client about OAuth for one mailbox: request with an empty Bearer
        header and X-User-Identity, as Outlook and the iPhone send it. Exchange returns the
        authorization URL (AD FS, or Entra ID with hybrid modern authentication) only when the
        authentication policy of that user allows modern authentication. Returns Status, Message,
        Details, AuthorizationUri and TrustedIssuers.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Net.Http.HttpMethod]$Method = [Net.Http.HttpMethod]::Options,
        [string]$UserAgent
    )

    $ep = $Context.Endpoints
    $mailbox = [string]$Context.Config.Mailbox
    $response = Invoke-EasRequest -HttpClient $Context.HttpClient -Method $Method -Uri $ep.EasUrl -AccessToken '' -EmptyBearer `
        -Headers @{ 'X-User-Identity' = $mailbox } -UserAgent $UserAgent
    $info = Get-EomChallengeInfo -Challenges @(Get-EomField $response 'Challenges')
    $diagnostics = Get-EasDiagnostics -Response $response
    $details = [ordered]@{
        Request          = "$($Method.Method) with an empty Bearer header and X-User-Identity $mailbox"
        HttpStatus       = $response.StatusCode
        Schemes          = $info.Schemes -join ', '
        AuthorizationUri = $info.AuthorizationUri
        IssuerKind       = $info.IssuerKind
        Diagnostics      = $diagnostics
    }
    $outcome = { param([string]$Status, [string]$Message) [pscustomobject]@{ Status = $Status; Message = $Message; Details = $details; AuthorizationUri = $info.AuthorizationUri; TrustedIssuers = @($info.TrustedIssuers) } }
    $advertised = Get-EomAuthorityInfo -Uri ([string]$info.AuthorizationUri)
    if ($info.TrustedIssuers.Count) { $details.TrustedIssuers = $info.TrustedIssuers -join ', ' }

    if ($response.StatusCode -eq 451) {
        $details.Location = Get-EasRedirectLocation -Response $response
        return & $outcome 'Warning' "Exchange redirects $mailbox to another ActiveSync URL (HTTP 451, X-MS-Location $($details.Location)): $(Get-EasRedirectAdvice -Response $response)"
    }
    if ($response.StatusCode -ne 401) {
        return & $outcome 'Failed' "HTTP $($response.StatusCode) instead of 401 to a request without a token: check the URL and the publishing (reverse proxy, load balancer)."
    }
    $mismatch = if ($info.Bearer -and $advertised.Kind -ne 'None') { Test-EomExpectedAuthority -Context $Context -Advertised $advertised } else { $null }
    if ($mismatch) {
        return & $outcome 'Warning' "Exchange offers OAuth to $mailbox, but: $mismatch"
    }
    if ($info.Bearer -and $advertised.Kind -ne 'None') {
        $kind = if ($info.IssuerKind) { ", issuer_kind $($info.IssuerKind)" } else { '' }
        $how = if ($advertised.Kind -eq 'EntraID' -and $Context.Endpoints.ExchangeOnline) { 'Outlook and the iPhone sign in with Entra ID (Exchange Online)' }
        elseif ($advertised.Kind -eq 'EntraID') { 'Outlook and the iPhone sign in with Entra ID (hybrid modern authentication)' }
        else { 'this is how Outlook and the iPhone find the authorization server' }
        return & $outcome 'Passed' "Exchange offers OAuth to $mailbox and gives the authorization URL ($($info.AuthorizationUri)$kind): $how."
    }
    if ($info.Bearer -and $diagnostics -match 'oauth_not_available') {
        $reason = if ($diagnostics -match 'reason="([^"]+)"') { $Matches[1] } else { $diagnostics }
        return & $outcome 'Failed' ("Exchange does not offer OAuth to $mailbox ($reason): the authentication policy of the user blocks modern authentication for ActiveSync, or the domain is not an accepted domain. " +
            "Clients fall back to Basic authentication. Check Get-User $mailbox | Format-List AuthenticationPolicy, Get-AuthenticationPolicy | Format-List Name, BlockModernAuthActiveSync and Get-OrganizationConfig | Format-List DefaultAuthenticationPolicy.")
    }
    if ($info.Bearer) {
        return & $outcome 'Warning' "Exchange accepts OAuth for $mailbox but gives no authorization URL: Outlook and the iPhone cannot find the authorization server. Check Get-AuthServer (IsDefaultAuthorizationEndpoint `$true on the AD FS or the EvoSts server)."
    }
    return & $outcome 'Failed' "No OAuth challenge for $mailbox (schemes: $($details.Schemes)): check OAuth on the ActiveSync virtual directory, the authorization server (New-AuthServer -Type ADFS, or EvoSts created by the Hybrid Configuration Wizard) and the reverse proxy."
}

function Get-EomAuthorizeOutcome {
    <# What the AD FS authorization page answers to one request: sign-in page, unknown client, refused redirect URI... #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Response)

    $content = [string]$Response.Content
    $msis = [regex]::Match($content, 'MSIS\d{4}[^<]*')
    $text = if ($msis.Success) { [Net.WebUtility]::HtmlDecode($msis.Value).Trim() } else { $null }
    $outcome = { param([string]$Code, [string]$Text) [pscustomobject]@{ Code = $Code; Text = $Text } }
    if ($content -match 'MSIS9223') { return & $outcome 'UnknownClient' $text }
    if ($content -match 'MSIS9224') { return & $outcome 'RedirectRefused' $text }
    if ($Response.StatusCode -in 301, 302, 303 -and $Response.Location) {
        if ($Response.Location -match '[?&]code=') { return & $outcome 'SignedIn' 'AD FS signed in without a prompt (Windows integrated authentication) and returned an authorization code.' }
        if ($Response.Location -match '[?&]error=([^&]+)') {
            $description = if ($Response.Location -match '[?&]error_description=([^&]+)') { ': ' + [Uri]::UnescapeDataString($Matches[1].Replace('+', ' ')) } else { '' }
            return & $outcome 'Error' "AD FS returned the error $([Uri]::UnescapeDataString($Matches[1]))$description"
        }
        return & $outcome 'SignInPage' "AD FS continues the sign-in at $($Response.Location)."
    }
    if ($text) { return & $outcome 'Error' $text }
    if ($Response.StatusCode -eq 200 -and $content -match 'userNameInput|passwordInput|loginForm|idp_') { return & $outcome 'SignInPage' 'AD FS shows its sign-in page.' }
    return & $outcome 'Error' "HTTP $($Response.StatusCode) without a sign-in page."
}

function Set-EomAuthority {
    <# Applies the authorization server found (AD FS root or Entra ID tenant) to the run and recomputes the endpoints. #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [Parameter(Mandatory = $true)][ValidateSet('ADFS', 'EntraID')][string]$Kind,
        [string]$AdfsRoot,
        [string]$TenantId,
        [string]$Source
    )

    $cfg = $Context.Config
    $cfg.Authority = $Kind
    if ($Kind -eq 'ADFS') { $cfg.AdfsUrl = $AdfsRoot }
    else {
        $cfg.AdfsUrl = ''
        if ($TenantId) { $cfg.TenantId = $TenantId }
    }
    $Context.Endpoints = Resolve-EomEndpoints -Configuration $cfg
    if ($Source) { $Context.AuthoritySource = $Source }
}

function Resolve-EomEntraTenant {
    <#
        Tenant ID from the OpenID configuration Entra ID publishes for a tenant ID or a domain (traced,
        no sign-in). Returns TenantId (empty when the tenant is not found), Issuer, Url and Error.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Name)

    $url = "https://$($script:Entra.LoginHost)/$([Uri]::EscapeDataString($Name))/v2.0/.well-known/openid-configuration"
    $response = Invoke-EomWebRequest -HttpClient $Context.HttpClient -Uri $url -UserAgent $script:EomUserAgent -Headers @{ Accept = 'application/json' }
    $json = $null
    try { $json = $response.Content | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
    $issuer = [string](Get-EomField $json 'issuer')
    $tenantId = [regex]::Match($issuer, '[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}').Value
    $problem = if ($response.StatusCode -eq 200 -and $tenantId) { $null }
    elseif ($json -and (Get-EomField $json 'error_description')) { ([string](Get-EomField $json 'error_description') -split "`r?`n")[0] }
    else { "HTTP $($response.StatusCode)" }
    [pscustomobject]@{ TenantId = if ($problem) { $null } else { $tenantId }; Issuer = $issuer; Url = $url; Error = $problem }
}

function Get-EomUserRealm {
    <#
        How Entra ID signs in a user, before any sign-in (traced): Managed (password hash
        synchronization, pass-through authentication), Federated (AD FS or another identity
        provider: AuthUrl) or Unknown (the domain is not a domain of a tenant).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$User)

    $url = "https://$($script:Entra.LoginHost)/common/userrealm/$([Uri]::EscapeDataString($User))?api-version=2.0"
    $response = Invoke-EomWebRequest -HttpClient $Context.HttpClient -Uri $url -UserAgent $script:EomUserAgent -Headers @{ Accept = 'application/json' }
    $json = $null
    try { $json = $response.Content | ConvertFrom-Json -ErrorAction Stop } catch { $json = $null }
    [pscustomobject]@{
        HttpStatus          = $response.StatusCode
        NameSpaceType       = [string](Get-EomField $json 'NameSpaceType')
        DomainName          = [string](Get-EomField $json 'DomainName')
        FederationBrandName = [string](Get-EomField $json 'FederationBrandName')
        AuthUrl             = [string](Get-EomField $json 'AuthURL')
    }
}

function Add-EomEntraChecks {
    <#
        Entra ID before any sign-in: the tenant (OpenID configuration; Target.TenantId, the tenant of
        the authorization URL, or the domain of the mailbox) and the user realm of the mailbox.
        Sets the tenant of the run. Returns $false when the tenant is not found.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Stage, [string]$Hint, [string]$Source)

    $cfg = $Context.Config
    $mailbox = [string]$cfg.Mailbox
    $domain = $mailbox.Split('@')[-1]
    if ([string]$cfg.TenantId) { $name = [string]$cfg.TenantId; $from = 'Target.TenantId' }
    elseif ($Hint -and $Hint -notin 'common', 'organizations', 'consumers') { $name = $Hint; $from = 'the authorization URL of Exchange' }
    else { $name = $domain; $from = "the domain of the mailbox ($domain)" }
    $tenant = try { Resolve-EomEntraTenant -Context $Context -Name $name } catch { [pscustomobject]@{ TenantId = $null; Issuer = $null; Url = $null; Error = $_.Exception.Message } }
    $details = [ordered]@{ Tenant = $name; From = $from; TenantId = $tenant.TenantId; Issuer = $tenant.Issuer; Url = $tenant.Url; Error = $tenant.Error }
    if (-not $tenant.TenantId) {
        Add-EomStep $Context $Stage 'Entra ID tenant' Failed ("Entra ID does not know the tenant $name ($($tenant.Error)): the users of this domain cannot sign in with Entra ID. " +
            'Check the domain of the mailbox (a verified domain of the tenant) or set Target.TenantId.') $details
        return $false
    }
    $Context.TenantId = $tenant.TenantId
    Set-EomAuthority -Context $Context -Kind EntraID -TenantId $tenant.TenantId -Source $Source
    Add-EomStep $Context $Stage 'Entra ID tenant' Passed "Tenant $($tenant.TenantId), found from $($from): the token is requested from $($Context.Endpoints.EntraRoot)." $details

    $realm = try { Get-EomUserRealm -Context $Context -User $mailbox } catch { [pscustomobject]@{ HttpStatus = $null; NameSpaceType = $null; DomainName = $null; FederationBrandName = $null; AuthUrl = $null; Error = $_.Exception.Message } }
    $realmDetails = [ordered]@{ User = $mailbox; NameSpaceType = $realm.NameSpaceType; DomainName = $realm.DomainName; FederationBrandName = $realm.FederationBrandName; AuthUrl = $realm.AuthUrl }
    switch ($realm.NameSpaceType) {
        'Managed' { Add-EomStep $Context $Stage 'User realm' Passed "Entra ID signs in $mailbox itself (managed domain $($realm.DomainName): password hash synchronization or pass-through authentication)." $realmDetails }
        'Federated' { Add-EomStep $Context $Stage 'User realm' Passed "Entra ID sends $mailbox to the federation server $($realm.AuthUrl) (federated domain $($realm.DomainName)): the password is typed there, then Entra ID issues the token." $realmDetails }
        default {
            Add-EomStep $Context $Stage 'User realm' Warning ("Entra ID does not know the domain of $mailbox (NameSpaceType $(if ($realm.NameSpaceType) { $realm.NameSpaceType } else { 'not returned' })): sign in with the UPN of the user, " +
                'which must use a verified domain of the tenant (the UPN can differ from the e-mail address).') $realmDetails
        }
    }
    return $true
}

function Add-EomTrustedIssuerCheck {
    <# Entra ID: the tenant whose tokens Exchange trusts (trusted_issuers of the challenge) compared with the tenant of the run. #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Stage, [string[]]$TrustedIssuers)

    if (-not $Context.TenantId -or -not @($TrustedIssuers).Count) { return }
    $details = [ordered]@{ TrustedIssuers = $TrustedIssuers -join ', '; TenantId = $Context.TenantId }
    if (@($TrustedIssuers | Where-Object { $_ -ilike "*@$($Context.TenantId)" }).Count) {
        Add-EomStep $Context $Stage 'Tenant trusted by Exchange' Passed "Exchange trusts the tokens of Entra ID for tenant $($Context.TenantId) (trusted_issuers of its challenge, from the EvoSts authorization server)." $details
    }
    elseif (@($TrustedIssuers | Where-Object { $_ -like '*@`*' }).Count) {
        # Exchange Online: <token service ID>@* (every tenant); the mailbox is looked up in the tenant of the token.
        Add-EomStep $Context $Stage 'Tenant trusted by Exchange' Passed "Exchange trusts the tokens of Entra ID for every tenant ($($details.TrustedIssuers)), as Exchange Online does: it looks for the mailbox in the tenant of the token, $($Context.TenantId)." $details
    }
    else {
        Add-EomStep $Context $Stage 'Tenant trusted by Exchange' Warning ("Exchange trusts the tokens of $($TrustedIssuers -join ', '), not of tenant $($Context.TenantId): it will refuse the token (HTTP 401). " +
            'Check Get-AuthServer (EvoSts for this tenant) and run the Hybrid Configuration Wizard again.') $details
    }
}

function Get-EomEntraSignInOutcome {
    <#
        What the Entra ID authorization page shows: before the password Entra ID checks neither the
        client nor the redirect URI nor the resource (AADSTS50058: sign-in page), only the tenant.
    #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Response)

    $content = [string]$Response.Content
    $config = [regex]::Match($content, '\$Config=(\{.*?\});', 'Singleline')
    $json = $null
    if ($config.Success) { try { $json = $config.Groups[1].Value | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { $json = $null } }
    $message = if ($json -and $json['strServiceExceptionMessage']) { [string]$json['strServiceExceptionMessage'] } else { ([regex]::Match($content, 'AADSTS\d+[^"\\<]{0,200}')).Value }
    $outcome = { param([string]$Code, [string]$Text) [pscustomobject]@{ Code = $Code; Text = $Text } }
    if ($Response.StatusCode -in 301, 302, 303 -and $Response.Location) { return & $outcome 'SignInPage' "Entra ID continues the sign-in at $($Response.Location)." }
    if ($message) { return & $outcome 'Error' $message }
    if ($Response.StatusCode -eq 200 -and ($content -match '"urlPost"' -or ($json -and $json['pgid'] -match 'SignIn'))) { return & $outcome 'SignInPage' 'Entra ID shows its sign-in page.' }
    return & $outcome 'Error' "HTTP $($Response.StatusCode) without a sign-in page."
}

function Invoke-EomAppleEntraSetup {
    <#
        AppleSetup with Entra ID: Exchange (on-premises with hybrid modern authentication, or Exchange
        Online) sends the iPhone to Entra ID. The
        tenant and the user realm, then the sign-in page the web view opens (authorization URL of
        Exchange with the Apple Mail client, as the iPhone sends it). Entra ID checks the client, the
        redirect URI and the resource only after the password: the sign-in confirms them.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][pscustomobject]$Challenge, [Parameter(Mandatory = $true)][pscustomobject]$Server)

    $stage = 'AppleSetup'
    $cfg = $Context.Config
    $mailbox = [string]$cfg.Mailbox
    if (-not (Add-EomEntraChecks -Context $Context -Stage $stage -Hint $Server.Tenant -Source 'Exchange challenge (authorization_uri)')) { $Context.Stop = $true; return }
    Add-EomTrustedIssuerCheck -Context $Context -Stage $stage -TrustedIssuers $Challenge.TrustedIssuers
    $ep = $Context.Endpoints

    $locale = [Globalization.CultureInfo]::CurrentUICulture.Name.ToLowerInvariant()
    if (-not $locale) { $locale = 'en-us' }
    $redirect = $script:AppleMail.RedirectUris[0]
    $query = [ordered]@{
        response_type = 'code'; client_id = [string]$cfg.ClientId; redirect_uri = $redirect; ui_locales = $locale; display = 'ios'
        state = [guid]::NewGuid().ToString().ToUpperInvariant(); resource = $ep.Resource; claims = $script:AppleMail.Claims; login_hint = $mailbox
    }
    $url = $Challenge.AuthorizationUri + '?' + (@($query.Keys | ForEach-Object { '{0}={1}' -f $_, [Uri]::EscapeDataString([string]$query[$_]) }) -join '&')
    Assert-EomNotCancelled
    $outcome = try { Get-EomEntraSignInOutcome -Response (Invoke-EomWebRequest -HttpClient $Context.HttpClient -Uri $url -UserAgent $script:AppleMail.BrowserUserAgent) }
    catch { [pscustomobject]@{ Code = 'Error'; Text = "Entra ID not reachable: $($_.Exception.Message)" } }
    $details = [ordered]@{ AuthorizationEndpoint = $Challenge.AuthorizationUri; ClientId = [string]$cfg.ClientId; RedirectUri = $redirect; Resource = $ep.Resource; Outcome = "$($outcome.Code): $($outcome.Text)" }
    if ($outcome.Code -eq 'SignInPage') {
        Add-EomStep $Context $stage 'Entra ID sign-in page' Passed ("Entra ID opens its sign-in page for the Apple Mail client $($cfg.ClientId) (redirect $redirect, resource $($ep.Resource)): the web view of the iPhone can sign in. " +
            'Entra ID checks the client, the redirect URI and the resource only after the password: the sign-in below confirms them.') $details
    }
    else {
        Add-EomStep $Context $stage 'Entra ID sign-in page' Failed "Entra ID does not open its sign-in page for the iPhone: $($outcome.Text)" $details
        $Context.Stop = $true
    }
}

function Invoke-EomStageAppleSetup {
    <#
        What the iPhone does when the account is added, before the password: Autodiscover, OAuth
        offered for the mailbox with the AD FS URL, then the AD FS page for the Apple Mail client.
        No sign-in, nothing created. Stops the scenario when the iPhone could not reach the sign-in.
        With Basic authentication: Autodiscover, then whether the iPhone would ask for the password
        (Exchange does not offer OAuth to the mailbox); AD FS is not contacted.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $stage = 'AppleSetup'
    $cfg = $Context.Config
    $ep = $Context.Endpoints
    $mailbox = [string]$cfg.Mailbox
    $domain = $mailbox.Split('@')[-1]

    # 1. Autodiscover v2, sent by the Mail account (User-Agent Apple-iPhone...).
    $attempts = [Collections.Generic.List[string]]::new()
    $found = $null
    foreach ($base in "https://autodiscover.$domain", "https://$domain") {
        $uri = "$base/autodiscover/autodiscover.json/v1.0/$([Uri]::EscapeDataString($mailbox))?Protocol=ActiveSync"
        try {
            $response = $null
            for ($hop = 0; $hop -lt 4; $hop++) {
                Assert-EomNotCancelled
                $response = Invoke-EomWebRequest -HttpClient $Context.HttpClient -Uri $uri -UserAgent ([string]$cfg.UserAgent)
                if ($response.StatusCode -in 301, 302, 307, 308 -and [string]$response.Location -like 'https://*') { $uri = $response.Location; continue }
                break
            }
            if ($response.StatusCode -eq 200) {
                $json = $response.Content | ConvertFrom-Json -ErrorAction Stop
                $url = [string](Get-EomField $json 'Url')
                if ($url) { $found = [pscustomobject]@{ Request = $uri; Url = $url }; break }
                [void]$attempts.Add("${base}: HTTP 200 without URL ($([string](Get-EomField $json 'ErrorCode')))")
            }
            else {
                [void]$attempts.Add("${base}: HTTP $($response.StatusCode)")
            }
        }
        catch {
            [void]$attempts.Add("${base}: $($_.Exception.Message)")
        }
    }
    $typed = [string]$cfg.EasUrl
    $set = { param([string]$Eas, [string]$Adfs) $cfg.EasUrl = $Eas; $cfg.AdfsUrl = $Adfs; $Context.Endpoints = Resolve-EomEndpoints -Configuration $cfg }
    if ($found) {
        & $set $found.Url.TrimEnd('/') ''
        $Context.EasUrlSource = 'Autodiscover'
        if ($typed -and $typed.TrimEnd('/') -ine $found.Url.TrimEnd('/')) {
            Add-EomStep $Context $stage 'Autodiscover' Warning "Autodiscover gives $($found.Url) for $mailbox, not $($typed): the iPhone uses the Autodiscover URL, so does the test." ([ordered]@{ Request = $found.Request; Url = $found.Url; Configured = $typed })
        }
        else {
            Add-EomStep $Context $stage 'Autodiscover' Passed "Autodiscover gives the ActiveSync URL of $mailbox ($($found.Url)): the iPhone needs no server name." ([ordered]@{ Request = $found.Request; Url = $found.Url })
        }
    }
    elseif ($typed) {
        & $set $typed.TrimEnd('/') ''
        $Context.EasUrlSource = 'Typed (Target.EasUrl)'
        Add-EomStep $Context $stage 'Autodiscover' Warning ("No usable Autodiscover answer for $domain ($($attempts -join '; ')): on the iPhone the server has to be typed by hand. The test goes on with $typed (Target.EasUrl, -EasUrl).") ([ordered]@{ Attempts = $attempts -join ' | '; Typed = $typed })
    }
    else {
        Add-EomStep $Context $stage 'Autodiscover' Failed ("No usable Autodiscover answer for $domain ($($attempts -join '; ')): the iPhone would ask for the server name. Publish Autodiscover (autodiscover.$domain), or give the server the user would type with -EasUrl.") ([ordered]@{ Attempts = $attempts -join ' | ' })
        $Context.Stop = $true
        return
    }
    $ep = $Context.Endpoints

    if ($cfg.Authentication -eq 'Basic') {
        # An iPhone asks for the password only when Exchange does not offer OAuth to the mailbox.
        $challenge = Test-EomMailboxChallenge -Context $Context -Method ([Net.Http.HttpMethod]::Get) -UserAgent $script:AppleMail.SetupUserAgent
        $view = Get-EomBasicClientView -Challenge $challenge -Mailbox $mailbox -Clients 'the iPhone' -Rerun 'AppleMail without -Authentication Basic'
        Add-EomStep $Context $stage 'OAuth for the mailbox' $view.Status $view.Message $view.Details
        if ($view.Status -eq 'Failed') { $Context.Stop = $true }
        return
    }

    # 2. OAuth for the mailbox, sent by the account setup screen (User-Agent Preferences/..., GET).
    $challenge = Test-EomMailboxChallenge -Context $Context -Method ([Net.Http.HttpMethod]::Get) -UserAgent $script:AppleMail.SetupUserAgent
    Add-EomStep $Context $stage 'OAuth for the mailbox' $challenge.Status $challenge.Message $challenge.Details
    if ($challenge.Status -eq 'Failed') { $Context.Stop = $true; return }
    # The authorization server is where Exchange sends the iPhone: AD FS, or Entra ID (hybrid modern authentication, Exchange Online).
    $server = Get-EomAuthorityInfo -Uri ([string]$challenge.AuthorizationUri)
    if ($server.Kind -eq 'EntraID') {
        Invoke-EomAppleEntraSetup -Context $Context -Challenge $challenge -Server $server
        return
    }
    if ($server.Kind -ne 'ADFS') {
        Add-EomStep $Context $stage 'Authorization server' Failed ("Exchange gives neither an AD FS nor an Entra ID authorization URL ($(if ($challenge.AuthorizationUri) { $challenge.AuthorizationUri } else { 'none' })): the iPhone cannot reach a sign-in page. " +
            'Check Get-AuthServer: IsDefaultAuthorizationEndpoint $true on the AD FS server (Type ADFS) or on EvoSts (hybrid modern authentication).') ([ordered]@{ AuthorizationUri = $challenge.AuthorizationUri })
        $Context.Stop = $true
        return
    }
    $cfg.EasUrl = $ep.EasUrl
    Set-EomAuthority -Context $Context -Kind ADFS -AdfsRoot $server.AdfsRoot -Source 'Exchange challenge (authorization_uri)'
    $Context.AdfsUrlSource = 'Exchange challenge (authorization_uri)'
    $ep = $Context.Endpoints

    # 3. The page the web view opens: AD FS authorization endpoint with the Apple Mail client.
    $authorize = $challenge.AuthorizationUri
    $locale = [Globalization.CultureInfo]::CurrentUICulture.Name.ToLowerInvariant()
    if (-not $locale) { $locale = 'en-us' }
    $outcomes = [ordered]@{}
    foreach ($redirect in $script:AppleMail.RedirectUris) {
        $query = [ordered]@{
            response_type = 'code'; client_id = [string]$cfg.ClientId; redirect_uri = $redirect; ui_locales = $locale; display = 'ios'
            state = [guid]::NewGuid().ToString().ToUpperInvariant(); resource = $ep.Resource; claims = $script:AppleMail.Claims; login_hint = $mailbox
        }
        $url = $authorize + '?' + (@($query.Keys | ForEach-Object { '{0}={1}' -f $_, [Uri]::EscapeDataString([string]$query[$_]) }) -join '&')
        Assert-EomNotCancelled
        $outcomes[$redirect] = try {
            Get-EomAuthorizeOutcome -Response (Invoke-EomWebRequest -HttpClient $Context.HttpClient -Uri $url -UserAgent $script:AppleMail.BrowserUserAgent)
        }
        catch {
            [pscustomobject]@{ Code = 'Error'; Text = "AD FS not reachable: $($_.Exception.Message)" }
        }
    }
    $details = [ordered]@{ AuthorizationEndpoint = $authorize; ClientId = [string]$cfg.ClientId; Resource = $ep.Resource }
    foreach ($redirect in $outcomes.Keys) { $details[$redirect] = "$($outcomes[$redirect].Code): $($outcomes[$redirect].Text)" }
    $refused = @($outcomes.Keys | Where-Object { $outcomes[$_].Code -notin 'SignInPage', 'SignedIn' })
    $settingsRedirect = $script:AppleMail.RedirectUris[0]
    if (@($outcomes.Values | Where-Object Code -eq 'UnknownClient').Count) {
        Add-EomStep $Context $stage 'Apple Mail client in AD FS' Failed ("AD FS does not know the Apple Mail client $($cfg.ClientId) (MSIS9223): create the native client application 'iOS and macOS - Native mail application' " +
            "with its three redirect URIs (Add-AdfsNativeClientApplication), then allow it on the ActiveSync Web API (Grant-AdfsApplicationPermission with EAS.AccessAsUser.All and openid).") $details
        $Context.Stop = $true
    }
    elseif (-not $refused.Count) {
        Add-EomStep $Context $stage 'Apple Mail client in AD FS' Passed "AD FS opens its sign-in page for the Apple Mail client $($cfg.ClientId) with the $($outcomes.Count) redirect URIs of the iPhone: the web view of the iPhone can sign in." $details
    }
    elseif ($refused -contains $settingsRedirect) {
        Add-EomStep $Context $stage 'Apple Mail client in AD FS' Failed ("AD FS refuses $settingsRedirect, the redirect URI the iPhone uses when the account is added from Settings: $($outcomes[$settingsRedirect].Text) " +
            "Add the redirect URIs of the Apple Mail client (Set-AdfsNativeClientApplication -RedirectUri).") $details
        $Context.Stop = $true
    }
    else {
        Add-EomStep $Context $stage 'Apple Mail client in AD FS' Warning ("AD FS refuses $($refused -join ', '): the account added from Settings works, other ways of adding it may not. " +
            "Add the missing redirect URIs (Set-AdfsNativeClientApplication -RedirectUri).") $details
    }
}

function Add-EomTlsCheck {
    <# Certificate a server presents (direct TLS connection), added to the trace and checked: trusted, expiry. #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Stage, [Parameter(Mandatory = $true)][string]$HostName, [Parameter(Mandatory = $true)][int]$Port)

    $cfg = $Context.Config
    $cert = Get-EomTlsCertificate -HostName $HostName -Port $Port -TimeoutSeconds ([Math]::Min(15, [int]$cfg.HttpTimeoutSeconds))
    $name = "TLS certificate ($HostName)"
    $details = [ordered]@{ Host = "$($HostName):$Port"; Subject = $cert.Subject; Issuer = $cert.Issuer; NotAfterUtc = $cert.NotAfterUtc; DaysLeft = $cert.DaysLeft; Protocol = $cert.Protocol; Error = $cert.Error }
    $received = if (-not $cert.Reachable) { "No TLS connection: $($cert.Error)" }
    elseif ($cert.Interrupted) { "No certificate: the connection was closed during the TLS handshake ($($cert.Error))" }
    else { "Certificate
Subject: $($cert.Subject)
Issuer: $($cert.Issuer)
Valid until: $($cert.NotAfterUtc) ($($cert.DaysLeft) day(s))
Protocol: $($cert.Protocol)
Trusted by this computer: $(if ($cert.Valid) { 'yes' } else { "no - $($cert.Error)" })" }
    Add-EomTraceEntry -Method 'TLS' -Url "tls://$($HostName):$Port" -Request "TLS handshake (ClientHello)
Server name (SNI): $HostName
Port: $Port" -Response $received -Note 'Direct TLS connection (no HTTP request): the certificate the server presents.'
    if (-not $cert.Reachable) {
        Add-EomStep $Context $Stage $name Warning "No direct TLS connection ($($cert.Error)). Expected behind a proxy (the HTTPS checks use the system proxy); otherwise check DNS and the firewall." $details
    }
    elseif ($cert.Interrupted) {
        Add-EomStep $Context $Stage $name Failed ("TLS handshake interrupted before the server sent its certificate ($($cert.Error)): the certificate is not in question. " +
            "Something on the path closes the connection: a firewall or NSG that filters the source address, a reverse proxy, or a VPN or Global Secure Access client that tunnels this address. Try from another network.") $details
    }
    elseif (-not $cert.Valid) {
        Add-EomStep $Context $Stage $name Failed "Certificate not trusted by this computer: $($cert.Error)" $details
    }
    elseif ($cert.DaysLeft -lt [int]$cfg.CertificateWarningDays) {
        Add-EomStep $Context $Stage $name Warning "Certificate expires in $($cert.DaysLeft) day(s) ($($cert.NotAfterUtc))." $details
    }
    else {
        Add-EomStep $Context $Stage $name Passed "Certificate trusted, valid $($cert.DaysLeft) more day(s), $($cert.Protocol)." $details
    }
}

function Get-EomBasicClientView {
    <#
        The answer of Exchange to the OAuth discovery of a mailbox (Test-EomMailboxChallenge), read for
        a Basic test. When Exchange offers OAuth, Outlook and the iPhone sign in with AD FS and never
        ask for the password; when it does not, they ask for the password and use Basic, like the test.
    #>
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Challenge,
        [Parameter(Mandatory = $true)][string]$Mailbox,
        [string]$Clients = 'Outlook and the iPhone',
        [string]$Rerun = 'the same scenario without -Authentication Basic'
    )

    $details = $Challenge.Details
    # Redirect (451) or no 401 at all: the same verdict as with OAuth.
    if ([int]$details.HttpStatus -ne 401) { return $Challenge }
    $s = if ($Clients -match ' and ') { '' } else { 's' }
    if ($Challenge.AuthorizationUri) {
        $server = Get-EomAuthorityInfo -Uri ([string]$Challenge.AuthorizationUri)
        $with = if ($server.Kind -eq 'EntraID') { 'Entra ID' } elseif ($server.Kind -eq 'ADFS') { 'AD FS' } else { $server.Name }
        return [pscustomobject]@{
            Status = 'Warning'; Details = $details; AuthorizationUri = $Challenge.AuthorizationUri
            Message = "Exchange offers OAuth to $Mailbox ($($Challenge.AuthorizationUri)): $Clients sign$s in with $with, without the password. This Basic test shows what a client without modern authentication does; run $Rerun for the path of $Clients."
        }
    }
    $reason = if ([string]$details.Diagnostics -match 'reason="([^"]+)"') { $Matches[1] } elseif ($details.Schemes) { "schemes: $($details.Schemes)" } else { 'no OAuth challenge' }
    [pscustomobject]@{
        Status = 'Passed'; Details = $details; AuthorizationUri = $null
        Message = "Exchange does not offer OAuth to $Mailbox ($reason): $Clients ask$s for the password and use$s Basic authentication, like this test."
    }
}

function Invoke-EomStageDiscoveryBasic {
    <#
        Discovery with Basic authentication (no AD FS): certificate of ActiveSync, Basic offered,
        what Outlook and the iPhone choose for the mailbox, wrong credentials refused. The wrong
        credentials use a user that does not exist: no real account can be locked.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $stage = 'Discovery'
    $ep = $Context.Endpoints
    $mailbox = [string]$Context.Config.Mailbox
    Add-EomTlsCheck -Context $Context -Stage $stage -HostName $ep.EasHost -Port $ep.EasPort

    try {
        $anonymous = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $ep.EasUrl -AccessToken ''
        $challenges = @(Get-EomField $anonymous 'Challenges')
        $info = Get-EomChallengeInfo -Challenges $challenges
        $basic = $challenges | Where-Object { $_ -match '^\s*Basic\b' } | Select-Object -First 1
        $details = [ordered]@{ HttpStatus = $anonymous.StatusCode; Schemes = $info.Schemes -join ', '; Realm = if ($basic -match 'realm="([^"]*)"') { $Matches[1] } else { $null } }
        if ($anonymous.StatusCode -eq 401 -and $basic) {
            Add-EomStep $Context $stage 'Basic challenge' Passed "ActiveSync offers Basic authentication (realm $($details.Realm)): the client sends the user name and password with every request, protected only by TLS." $details
        }
        elseif ($ep.ExchangeOnline -and $anonymous.StatusCode -in 401, 451) {
            if ($anonymous.StatusCode -eq 451) { $details.Location = Get-EasRedirectLocation -Response $anonymous }
            $seen = if ($anonymous.StatusCode -eq 451) { "an anonymous request is redirected to $($details.Location)" } else { "schemes: $(if ($details.Schemes) { $details.Schemes } else { 'none' })" }
            Add-EomStep $Context $stage 'Basic challenge' Failed ("Exchange Online does not offer Basic authentication for ActiveSync ($seen): Microsoft turned it off in every tenant. " +
                'Devices must sign in with OAuth and Entra ID: test the mailbox with -Authority EntraID.') $details
        }
        elseif ($anonymous.StatusCode -eq 401) {
            Add-EomStep $Context $stage 'Basic challenge' Failed ("ActiveSync does not offer Basic authentication (schemes: $(if ($details.Schemes) { $details.Schemes } else { 'none' })): Basic is disabled on the ActiveSync virtual directory " +
                '(Get-ActiveSyncVirtualDirectory | Format-List Server, BasicAuthEnabled) or not let through by the reverse proxy (pre-authentication).') $details
        }
        elseif ($anonymous.StatusCode -eq 200) {
            Add-EomStep $Context $stage 'Basic challenge' Warning 'ActiveSync answered an anonymous OPTIONS with HTTP 200: anonymous access is not expected.' $details
        }
        elseif ($anonymous.StatusCode -eq 451) {
            $details.Location = Get-EasRedirectLocation -Response $anonymous
            Add-EomStep $Context $stage 'Basic challenge' Warning "ActiveSync redirects to another URL (HTTP 451, X-MS-Location $($details.Location)): $(Get-EasRedirectAdvice -Response $anonymous)" $details
        }
        else {
            # Only a probe: the Basic sign-in that follows (or the wrong password below) is the real test.
            $details.Diagnostics = Get-EasDiagnostics -Response $anonymous
            Add-EomStep $Context $stage 'Basic challenge' Warning ("The anonymous OPTIONS got HTTP $($anonymous.StatusCode) instead of 401: this probe cannot tell whether Basic is offered. " +
                'The Basic sign-in decides; if it fails too, check the URL and the publishing (reverse proxy, load balancer), or wait for Exchange after a restart.') $details
        }

        $view = Get-EomBasicClientView -Challenge (Test-EomMailboxChallenge -Context $Context) -Mailbox $mailbox
        Add-EomStep $Context $stage 'OAuth for the mailbox' $view.Status $view.Message $view.Details

        $user = '{0}{1}@{2}' -f $script:InvalidBasicUserPrefix, [guid]::NewGuid().ToString('N').Substring(0, 12), $mailbox.Split('@')[-1]
        $wrong = [pscredential]::new($user, (ConvertTo-SecureString ([guid]::NewGuid().ToString()) -AsPlainText -Force))
        $invalid = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $ep.EasUrl -Credential $wrong
        $details = [ordered]@{ User = $user; HttpStatus = $invalid.StatusCode; Diagnostics = Get-EasDiagnostics -Response $invalid }
        if ($invalid.StatusCode -eq 401) {
            Add-EomStep $Context $stage 'Wrong password' Passed "A wrong user name and password are refused (HTTP 401). The test uses a user that does not exist ($user): no account can be locked." $details
        }
        elseif ($invalid.StatusCode -ge 200 -and $invalid.StatusCode -lt 300) {
            Add-EomStep $Context $stage 'Wrong password' Failed "Exchange accepted a user that does not exist (HTTP $($invalid.StatusCode)): investigate the publishing chain immediately." $details
        }
        else {
            Add-EomStep $Context $stage 'Wrong password' Warning "A wrong user name and password returned HTTP $($invalid.StatusCode) (401 expected)." $details
        }
    }
    catch {
        Add-EomStep $Context $stage 'Basic challenge' Failed "ActiveSync not reachable: $($_.Exception.Message)" ([ordered]@{ Url = $ep.EasUrl })
    }
}

function Add-EomAdfsMetadataCheck {
    <# OpenID configuration published by AD FS, then the certificate of AD FS. #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Stage)

    $ep = $Context.Endpoints
    try {
        $meta = Invoke-EomHttpGet -HttpClient $Context.HttpClient -Uri $ep.MetadataEndpoint
        $details = [ordered]@{
            Issuer                      = [string](Get-EomField $meta 'issuer')
            TokenEndpoint               = [string](Get-EomField $meta 'token_endpoint')
            DeviceAuthorizationEndpoint = [string](Get-EomField $meta 'device_authorization_endpoint')
        }
        if ($details.TokenEndpoint) {
            Add-EomStep $Context $Stage 'AD FS metadata' Passed "OpenID configuration published by AD FS (issuer $($details.Issuer))." $details
        }
        else {
            Add-EomStep $Context $Stage 'AD FS metadata' Warning 'The OpenID configuration of AD FS has no token_endpoint.' $details
        }
    }
    catch {
        Add-EomStep $Context $Stage 'AD FS metadata' Warning ("OpenID configuration not readable ($($_.Exception.Message)). Sign-in can still work if this endpoint is disabled in AD FS.") ([ordered]@{ Url = $ep.MetadataEndpoint })
    }
    if ($ep.AdfsHost -and ($ep.AdfsHost -ine $ep.EasHost -or $ep.AdfsPort -ne $ep.EasPort)) {
        Add-EomTlsCheck -Context $Context -Stage $Stage -HostName $ep.AdfsHost -Port $ep.AdfsPort
    }
}

function Add-EomOAuthChallengeCheck {
    <#
        The OAuth challenge of ActiveSync: anonymous OPTIONS, then an empty "Authorization: Bearer"
        header (Exchange Server 2019 CU13+ and SE return their Bearer challenge only to it), and the
        authorization server the challenge names, compared with the one expected (Target.Authority).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Stage)

    $ep = $Context.Endpoints
    $anonymous = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $ep.EasUrl -AccessToken ''
    $info = Get-EomChallengeInfo -Challenges @(Get-EomField $anonymous 'Challenges')
    $details = [ordered]@{ HttpStatus = $anonymous.StatusCode; Schemes = $info.Schemes -join ', '; ChallengeRequest = 'Anonymous'; AuthorizationUri = $info.AuthorizationUri }
    # The empty Bearer header is what clients send to discover OAuth: tried when the anonymous answer has no OAuth challenge.
    # Exchange Online redirects an anonymous request to its certificate-based authentication URL (HTTP 451): the empty one is tried too.
    $status = $anonymous.StatusCode
    if ($status -ne 200 -and -not ($status -eq 401 -and $info.Bearer)) {
        $probe = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $ep.EasUrl -AccessToken '' -EmptyBearer
        $probeInfo = Get-EomChallengeInfo -Challenges @(Get-EomField $probe 'Challenges')
        $details.EmptyBearerStatus = $probe.StatusCode
        $details.EmptyBearerSchemes = $probeInfo.Schemes -join ', '
        $details.Diagnostics = Get-EasDiagnostics -Response $probe
        # The answer clients get decides when the anonymous one was unexpected (HTTP 500 while Exchange starts).
        if ($probe.StatusCode -eq 401) { $status = 401 }
        if ($probe.StatusCode -eq 401 -and $probeInfo.Bearer) {
            $info = $probeInfo
            $details.ChallengeRequest = 'Empty Bearer'
            $details.AuthorizationUri = $probeInfo.AuthorizationUri
        }
    }
    if ($info.IssuerKind) { $details.IssuerKind = $info.IssuerKind }
    if ($info.TrustedIssuers.Count) { $details.TrustedIssuers = $info.TrustedIssuers -join ', ' }
    if ($anonymous.StatusCode -eq 451) { $details.AnonymousLocation = Get-EasRedirectLocation -Response $anonymous }
    $anon = if ($anonymous.StatusCode -eq 451) { "the anonymous request is redirected to $($details.AnonymousLocation)" } else { "anonymous schemes: $($details.Schemes)" }
    $advertised = Get-EomAuthorityInfo -Uri ([string]$info.AuthorizationUri)
    $mismatch = if ($status -eq 401 -and $info.Bearer) { Test-EomExpectedAuthority -Context $Context -Advertised $advertised } else { $null }
    $how = if ($ep.ExchangeOnline) { 'Exchange Online' } else { 'hybrid modern authentication' }
    $names = if ($advertised.Kind -eq 'EntraID') { " It names Entra ID ($($info.AuthorizationUri)): $how." } elseif ($advertised.Kind -eq 'ADFS') { " It names AD FS ($($advertised.Host))." } else { '' }
    if ($mismatch) {
        Add-EomStep $Context $Stage 'OAuth challenge' Warning "ActiveSync advertises OAuth, but: $mismatch" $details
    }
    elseif ($status -eq 401 -and $info.Bearer -and $details.ChallengeRequest -eq 'Empty Bearer') {
        Add-EomStep $Context $Stage 'OAuth challenge' Passed ("ActiveSync answers an empty Bearer header with an OAuth challenge, as Exchange does for clients: OAuth is enabled ($anon).$names") $details
    }
    elseif ($status -eq 401 -and $info.Bearer) {
        Add-EomStep $Context $Stage 'OAuth challenge' Passed ("ActiveSync advertises OAuth (Bearer) to an anonymous request; schemes: $($details.Schemes).$names") $details
    }
    elseif ($status -eq 401) {
        Add-EomStep $Context $Stage 'OAuth challenge' Warning ("ActiveSync does not advertise OAuth, even to an empty Bearer header (schemes: $($details.Schemes)): check OAuth on the ActiveSync virtual directory, the authorization server (New-AuthServer -Type ADFS, or EvoSts of the Hybrid Configuration Wizard), OAuth2ClientProfileEnabled, and the reverse proxy.") $details
    }
    elseif ($anonymous.StatusCode -eq 200) {
        Add-EomStep $Context $Stage 'OAuth challenge' Warning 'ActiveSync answered an anonymous OPTIONS with HTTP 200: anonymous access is not expected.' $details
    }
    elseif ($anonymous.StatusCode -eq 451) {
        $details.Location = Get-EasRedirectLocation -Response $anonymous
        Add-EomStep $Context $Stage 'OAuth challenge' Warning "ActiveSync redirects to another URL (HTTP 451, X-MS-Location $($details.Location)): $(Get-EasRedirectAdvice -Response $anonymous)" $details
    }
    else {
        # Only a probe: OAuth for the mailbox and the sign-in that follow are the real test.
        Add-EomStep $Context $Stage 'OAuth challenge' Warning ("The anonymous OPTIONS got HTTP $status instead of 401: this probe cannot tell whether OAuth is advertised. " +
            'OAuth for the mailbox and the sign-in decide; if they fail too, check the URL and the publishing (reverse proxy, load balancer), or wait for Exchange after a restart.') $details
    }
}

function Add-EomInvalidTokenCheck {
    <# A forged token must be refused (HTTP 401). #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Stage)

    $invalid = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $Context.Endpoints.EasUrl -AccessToken $script:InvalidToken
    $details = [ordered]@{ HttpStatus = $invalid.StatusCode; Diagnostics = Get-EasDiagnostics -Response $invalid }
    if ($invalid.StatusCode -eq 401) {
        Add-EomStep $Context $Stage 'Invalid token' Passed 'An invalid bearer token is rejected (HTTP 401).' $details
    }
    elseif ($invalid.StatusCode -ge 200 -and $invalid.StatusCode -lt 300) {
        Add-EomStep $Context $Stage 'Invalid token' Failed "Exchange accepted an invalid bearer token (HTTP $($invalid.StatusCode)): investigate the publishing chain immediately." $details
    }
    else {
        Add-EomStep $Context $Stage 'Invalid token' Warning "An invalid bearer token returned HTTP $($invalid.StatusCode) (401 expected)." $details
    }
}

function Invoke-EomStageDiscovery {
    <#
        Checks that need no sign-in and create nothing on the server. A failed check does not stop the scenario.
          AD FS     metadata and certificate of AD FS, certificate of ActiveSync, OAuth challenge, OAuth for the mailbox, forged token
          Entra ID  tenant and user realm, certificate of ActiveSync, OAuth challenge, OAuth for the mailbox, tenant trusted by Exchange, forged token
          Auto      certificate of ActiveSync, OAuth challenge, OAuth for the mailbox, then the checks of the server Exchange names, forged token
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    if ($Context.Config.Authentication -eq 'Basic') { Invoke-EomStageDiscoveryBasic -Context $Context; return }
    $stage = 'Discovery'
    $authority = [string]$Context.Config.Authority
    if ($authority -eq 'ADFS') { Add-EomAdfsMetadataCheck -Context $Context -Stage $stage }
    elseif ($authority -eq 'EntraID') { [void](Add-EomEntraChecks -Context $Context -Stage $stage -Source 'Configuration') }
    $ep = $Context.Endpoints
    Add-EomTlsCheck -Context $Context -Stage $stage -HostName $ep.EasHost -Port $ep.EasPort

    try {
        Add-EomOAuthChallengeCheck -Context $Context -Stage $stage
        $mailboxChallenge = Test-EomMailboxChallenge -Context $Context
        Add-EomStep $Context $stage 'OAuth for the mailbox' $mailboxChallenge.Status $mailboxChallenge.Message $mailboxChallenge.Details

        if ($authority -eq 'Auto') {
            # Like a client: the authorization server is the one Exchange names for the mailbox.
            $server = Get-EomAuthorityInfo -Uri ([string]$mailboxChallenge.AuthorizationUri)
            if ($server.Kind -eq 'ADFS') {
                Set-EomAuthority -Context $Context -Kind ADFS -AdfsRoot $server.AdfsRoot -Source 'Exchange challenge (authorization_uri)'
                $Context.AdfsUrlSource = 'Exchange challenge (authorization_uri)'
                Add-EomAdfsMetadataCheck -Context $Context -Stage $stage
            }
            elseif ($server.Kind -eq 'EntraID') {
                [void](Add-EomEntraChecks -Context $Context -Stage $stage -Hint $server.Tenant -Source 'Exchange challenge (authorization_uri)')
            }
            elseif ($mailboxChallenge.Status -ne 'Failed') {
                Add-EomStep $Context $stage 'Authorization server' Warning "Exchange names neither AD FS nor Entra ID for the mailbox ($($server.Name)): the sign-in cannot be tested. Check Get-AuthServer (IsDefaultAuthorizationEndpoint)." ([ordered]@{ AuthorizationUri = $mailboxChallenge.AuthorizationUri })
            }
        }
        if ($Context.Config.Authority -eq 'EntraID') { Add-EomTrustedIssuerCheck -Context $Context -Stage $stage -TrustedIssuers $mailboxChallenge.TrustedIssuers }
        Add-EomInvalidTokenCheck -Context $Context -Stage $stage
    }
    catch {
        Add-EomStep $Context $stage 'OAuth challenge' Failed "ActiveSync not reachable: $($_.Exception.Message)" ([ordered]@{ Url = $ep.EasUrl })
    }
}

function Invoke-EomStageOAuth {
    <#
        Sign-in and token. The authorization server is known before: AD FS (Target.AdfsUrl), Entra ID
        (tenant found by Discovery or here), or, with Target.Authority Auto, the one Exchange names
        for the mailbox (read here when no earlier stage did).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $stage = 'OAuth'
    $cfg = $Context.Config
    $apple = $cfg.Client -eq 'AppleMail'
    if ([string]$cfg.Authority -eq 'Auto') {
        # Like a client: ask Exchange where to sign in for this mailbox.
        $challenge = Test-EomMailboxChallenge -Context $Context
        $server = Get-EomAuthorityInfo -Uri ([string]$challenge.AuthorizationUri)
        if ($server.Kind -eq 'ADFS') {
            Set-EomAuthority -Context $Context -Kind ADFS -AdfsRoot $server.AdfsRoot -Source 'Exchange challenge (authorization_uri)'
            $Context.AdfsUrlSource = 'Exchange challenge (authorization_uri)'
            Add-EomStep $Context $stage 'Authorization server' Passed "Exchange sends the clients of $($cfg.Mailbox) to AD FS $($server.AdfsRoot): the sign-in uses it." $challenge.Details
        }
        elseif ($server.Kind -eq 'EntraID') {
            $how = if ($Context.Endpoints.ExchangeOnline) { 'Exchange Online' } else { 'hybrid modern authentication' }
            Add-EomStep $Context $stage 'Authorization server' Passed "Exchange sends the clients of $($cfg.Mailbox) to Entra ID ($($challenge.AuthorizationUri)): $how, the sign-in uses Entra ID." $challenge.Details
            if (-not (Add-EomEntraChecks -Context $Context -Stage $stage -Hint $server.Tenant -Source 'Exchange challenge (authorization_uri)')) { $Context.Stop = $true; return }
        }
        else {
            $why = if ($challenge.Status -eq 'Failed') { $challenge.Message } else { "Exchange names neither AD FS nor Entra ID ($($server.Name))." }
            Add-EomStep $Context $stage 'Authorization server' Failed "No authorization server to sign in with: $why" $challenge.Details
            $Context.Stop = $true
            return
        }
    }
    elseif ([string]$cfg.Authority -eq 'EntraID' -and -not $Context.TenantId) {
        if (-not (Add-EomEntraChecks -Context $Context -Stage $stage -Source 'Configuration')) { $Context.Stop = $true; return }
    }
    $entra = $Context.Endpoints.Authority -eq 'EntraID'
    $server = if ($entra) { 'Entra ID' } else { 'AD FS' }
    if ($Context.AccessToken) {
        $Context.SignIn = 'Supplied'
        Add-EomStep $Context $stage 'Access token' Passed 'Access token supplied by the caller: sign-in skipped.' ([ordered]@{ Source = 'Caller' })
    }
    else {
        $userAgent = if ($apple) { $script:AppleMail.SetupUserAgent } else { $script:EomUserAgent }
        $mode = Get-EomSignInMode -Configuration $cfg
        if ($mode.Mode -eq 'Window' -and -not $entra -and -not $apple) {
            # AD FS: the window needs its redirect URI for the client (AppleMail checked it in AppleSetup).
            $check = Test-EomAdfsWindowRedirect -Context $Context
            if ($check.Code -notin 'SignInPage', 'SignedIn') {
                $why = "AD FS does not accept the redirect URI of the sign-in window ($($script:SignInRedirect.ADFS)) for the client $($cfg.ClientId): $($check.Text)"
                if ([string]$cfg.SignIn -eq 'Window') { throw "$why Add it to the client (Set-AdfsNativeClientApplication -RedirectUri), or run with -SignIn DeviceCode." }
                Write-EomItem Info "$why Sign-in with a device code instead." -Icon Key
                $mode = [pscustomobject]@{ Mode = 'DeviceCode'; Browser = $null; Reason = 'redirect URI of the window not accepted by AD FS' }
            }
        }
        elseif ($mode.Mode -eq 'DeviceCode' -and $mode.Reason) {
            Write-EomItem Info "No sign-in window here ($($mode.Reason)): sign-in with a device code, on any device." -Icon Key
        }
        $window = $null
        if ($mode.Mode -eq 'Window') {
            try {
                $window = Invoke-EomWindowAuthentication -Configuration $cfg -Endpoints $Context.Endpoints -HttpClient $Context.HttpClient -Browser $mode.Browser -UserAgent $userAgent -Apple:$apple
            }
            catch [NotSupportedException] {
                if ([string]$cfg.SignIn -eq 'Window') { throw "$($_.Exception.Message) Run with -SignIn DeviceCode." }
                Write-EomItem Info "$($_.Exception.Message) Sign-in with a device code instead." -Icon Key
                $mode = [pscustomobject]@{ Mode = 'DeviceCode'; Browser = $null; Reason = $_.Exception.Message -replace '^The sign-in window could not start: ', 'could not start: ' }
            }
        }
        $Context.SignIn = $mode.Mode
        if ($window) {
            $Context.AccessToken = $window.AccessToken
            $source = [ordered]@{
                Source = "$server sign-in window"; Browser = $mode.Browser.Name; Flow = 'authorization code with PKCE'; RedirectUri = $window.RedirectUri
                ClientId = $cfg.ClientId; Scope = $Context.Endpoints.Scope; AuthorizeEndpoint = $Context.Endpoints.AuthorizeEndpoint; TokenEndpoint = $Context.Endpoints.TokenEndpoint
            }
            if ($apple) {
                Add-EomStep $Context $stage 'Sign-in window' Passed ("Access token received from $server for the Apple Mail client $($cfg.ClientId) after the sign-in in the window, with the redirect URI " +
                    "of the iPhone ($($window.RedirectUri)): the authorization code flow of the iPhone web view.") $source
            }
            else {
                Add-EomStep $Context $stage 'Sign-in window' Passed "Access token received from $server after the sign-in in the window (authorization code with PKCE)." $source
            }
        }
        else {
            $Context.AccessToken = Invoke-EomDeviceCodeAuthentication -Configuration $cfg -Endpoints $Context.Endpoints -HttpClient $Context.HttpClient -UserAgent $userAgent
            $source = [ordered]@{ Source = "$server device code"; ClientId = $cfg.ClientId; Scope = $Context.Endpoints.Scope; TokenEndpoint = $Context.Endpoints.TokenEndpoint }
            if ($mode.Reason) { $source.SignInWindow = "not used: $($mode.Reason)" }
            if ($apple) {
                $source.iPhone = 'authorization code in a web view, same client and resource'
                Add-EomStep $Context $stage 'Device-code sign-in' Passed ("Access token received from $server for the Apple Mail client $($cfg.ClientId). The iPhone gets the same token in its web view " +
                    "(authorization code sent to com.apple.Preferences://oauth-redirect); the sign-in window plays that flow, the device code of the same client is used here.") $source
            }
            else {
                Add-EomStep $Context $stage 'Device-code sign-in' Passed "Access token received from $server." $source
            }
        }
    }
    $expectedClient = if ($apple) { [string]$cfg.ClientId } else { $null }
    $tenant = if ($entra) { [string]$Context.TenantId } else { $null }
    $check = Test-EomTokenClaims -Claims (Get-EomTokenClaims -AccessToken $Context.AccessToken) -Endpoints $Context.Endpoints -Mailbox ([string]$cfg.Mailbox) -ExpectedClientId $expectedClient -TenantId $tenant
    $Context.Token = $check.Details
    Add-EomStep $Context $stage 'Token claims' $check.Status $check.Message $check.Details
    if ($check.Status -eq 'Failed') { $Context.Stop = $true }
}

function Invoke-EomStageBasic {
    <#
        Basic authentication: one OPTIONS request with the user name and password. The run stops at
        the first refusal, so that a wrong password is sent only once (account lockout).
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $stage = 'Basic'
    $name = 'Basic sign-in'
    $credential = $Context.Credential
    if (-not $credential) { throw 'Basic authentication needs a user name and a password (-Credential, the prompt or the window).' }
    $user = $credential.UserName
    if ($Context.Endpoints.ExchangeOnline) {
        # Refused whatever the password: it is not sent.
        Add-EomStep $Context $stage $name Failed ("Exchange Online ($($Context.Endpoints.EasHost)) no longer accepts Basic authentication for ActiveSync: the password of $user was not sent. " +
            'Devices sign in with OAuth and Entra ID: test the mailbox with -Authority EntraID.') ([ordered]@{ User = $user; EasUrl = $Context.Endpoints.EasUrl })
        $Context.Stop = $true
        return
    }
    Invoke-EomUiPump
    Assert-EomNotCancelled
    $response = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $Context.Endpoints.EasUrl -Credential $credential
    $info = Get-EomChallengeInfo -Challenges @(Get-EomField $response 'Challenges')
    $diagnostics = Get-EasDiagnostics -Response $response
    $details = [ordered]@{ User = $user; HttpStatus = $response.StatusCode; Schemes = $info.Schemes -join ', '; Diagnostics = $diagnostics }
    $suffix = if ($diagnostics) { " Exchange diagnostics: $diagnostics" } else { '' }
    if ($response.StatusCode -eq 200) {
        Add-EomStep $Context $stage $name Passed "Exchange accepted the user name and password of $user (HTTP 200). They are sent with every request, protected only by TLS." $details
        return
    }
    $Context.Stop = $true
    switch ($response.StatusCode) {
        401 {
            if ($info.Schemes.Count -and $info.Schemes -notcontains 'Basic') {
                Add-EomStep $Context $stage $name Failed ("ActiveSync does not offer Basic authentication (schemes: $($details.Schemes)): Basic is disabled on the ActiveSync virtual directory " +
                    "(Get-ActiveSyncVirtualDirectory | Format-List Server, BasicAuthEnabled) or not let through by the reverse proxy.$suffix") $details
            }
            else {
                Add-EomStep $Context $stage $name Failed ("Exchange refused the user name and password of $user (HTTP 401). Check, in order: the password and the account (not locked, password not expired; " +
                    'the user name is the UPN or DOMAIN\user, which can differ from the e-mail address), Basic on the ActiveSync virtual directory (Get-ActiveSyncVirtualDirectory | Format-List Server, BasicAuthEnabled), ' +
                    "the authentication policy of the user (Get-User <user> | Format-List AuthenticationPolicy; Get-AuthenticationPolicy | Format-List Name, BlockLegacyAuthActiveSync). The run stops here: a wrong password is sent only once.$suffix") $details
            }
        }
        403 { Add-EomStep $Context $stage $name Failed "Exchange knows $user but refuses ActiveSync (HTTP 403): ActiveSync disabled for the mailbox (Get-CASMailbox | Format-List ActiveSyncEnabled) or a device access rule.$suffix" $details }
        451 {
            $details.Location = Get-EasRedirectLocation -Response $response
            Add-EomStep $Context $stage $name Failed "Exchange redirects this mailbox to another ActiveSync URL (HTTP 451, X-MS-Location $($details.Location)): $(Get-EasRedirectAdvice -Response $response)$suffix" $details
        }
        default { Add-EomStep $Context $stage $name Failed "OPTIONS with the user name and password returned HTTP $($response.StatusCode).$suffix" $details }
    }
}

function Invoke-EomStageEndpoint {
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $response = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $Context.Endpoints.EasUrl -AccessToken $Context.AccessToken -Credential $Context.Credential
    Assert-EasHttpResponse -Command 'OPTIONS' -Response $response
    $accepted = if ($Context.Config.Authentication -eq 'Basic') { 'User name and password accepted' } else { 'Token accepted' }
    $headers = $response.Headers
    if (-not $headers.ContainsKey('MS-ASProtocolVersions')) { throw 'OPTIONS succeeded without the MS-ASProtocolVersions header: this is not an ActiveSync endpoint, or a proxy removes the header.' }
    $versions = @(([string]$headers['MS-ASProtocolVersions']).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $commands = @(([string]$headers['MS-ASProtocolCommands']).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $details = [ordered]@{
        HttpStatus       = $response.StatusCode
        ExchangeVersion  = [string]$headers['MS-Server-ActiveSync']
        ProtocolVersions = $versions -join ', '
        Commands         = $commands.Count
    }
    $missing = @('FolderSync', 'Sync', 'Provision', 'Settings' | Where-Object { $commands.Count -and $_ -notin $commands })
    $protocol = [string]$script:EomDevice.ProtocolVersion
    # The versions the requests of the tool are written for. Exchange Online offers only 16.1 since 2025:
    # the test then goes on with the version the server offers, like a current device.
    $usable = @('14.1', '16.1' | Where-Object { $_ -in $versions })
    $switched = $null
    if ($versions -notcontains $protocol -and $usable.Count) {
        $switched = $protocol
        $protocol = $usable[0]
        $script:EomDevice.ProtocolVersion = $protocol
        $Context.Config.ProtocolVersion = $protocol
        $details.ProtocolUsed = $protocol
    }
    if ($versions -notcontains $protocol) {
        Add-EomStep $Context 'Endpoint' 'OPTIONS' Warning "$accepted, but protocol $protocol used by the simulated client is not offered (versions: $($details.ProtocolVersions))." $details
    }
    elseif ($missing.Count) {
        Add-EomStep $Context 'Endpoint' 'OPTIONS' Warning "$accepted, but commands not offered: $($missing -join ', ')." $details
    }
    else {
        $version = if ($details.ExchangeVersion) { "Exchange $($details.ExchangeVersion), " } else { '' }
        $note = if ($switched) { " Exchange does not offer $switched (versions: $($details.ProtocolVersions)): the test goes on with $protocol, like a current device." } else { '' }
        Add-EomStep $Context 'Endpoint' 'OPTIONS' Passed "$accepted (HTTP 200): $($version)protocol $protocol and the commands used are available.$note" $details
    }
}

function Invoke-EomPolicy {
    <# Downloads the policy; acknowledges it only when authorised. Returns $true if the policy is acknowledged. #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Stage, [Parameter(Mandatory = $true)][string]$Reason)

    $acknowledge = [bool]$Context.Config.AcknowledgePolicy
    Invoke-EomUiPump
    $policy = Invoke-EasProvision -HttpClient $Context.HttpClient -EasUrl $Context.Endpoints.EasUrl -EncodedUser $Context.EncodedUser `
        -DeviceId $Context.DeviceId -DeviceType $Context.Config.DeviceType -AccessToken $Context.AccessToken -Credential $Context.Credential -Acknowledge:$acknowledge
    $Context.PolicySettings = @($policy.Settings)
    $details = [ordered]@{ Reason = $Reason; Settings = $Context.PolicySettings.Count; Acknowledged = $acknowledge }
    if (-not $acknowledge) {
        Add-EomStep $Context $Stage 'Policy' Blocked ("$Reason The policy was downloaded for review ($($Context.PolicySettings.Count) setting(s), see the Policy tab) but not acknowledged: on a test mailbox, run again with -AcknowledgePolicy (Test.AcknowledgePolicy).") $details
        $Context.Stop = $true
        return $false
    }
    $Context.PolicyKey = $policy.PolicyKey
    $Context.PolicyAcknowledged = $true
    Add-EomStep $Context $Stage 'Policy' Passed "Policy acknowledged ($($Context.PolicySettings.Count) setting(s)): the final policy key is sent with the next commands." $details
    return $true
}

function Invoke-EomStageProvisioning {
    param([Parameter(Mandatory = $true)][hashtable]$Context)
    [void](Invoke-EomPolicy -Context $Context -Stage 'Provisioning' -Reason 'Provisioning scenario.')
}

function Get-EomFolderSyncState {
    <# HTTP status, ActiveSync status and whether Exchange asks for provisioning. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Response)

    $easStatus = $null
    if ($Response.StatusCode -eq 200 -and $Response.Body.Length -gt 0) {
        $root = (ConvertFrom-EasWbxml -Data $Response.Body).SelectSingleNode('/*[local-name()="Wbxml"]/*[local-name()="FolderSync"]')
        if ($null -eq $root) { throw 'The FolderSync response does not contain a FolderSync root element.' }
        $easStatus = Get-ChildText -Node $root -Name 'Status'
    }
    [pscustomobject]@{
        HttpStatus           = $Response.StatusCode
        EasStatus            = $easStatus
        ProvisioningRequired = $Response.StatusCode -eq 449 -or $easStatus -in '141', '142', '143', '144', '145'
    }
}

function Invoke-EomStageFolderSync {
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $stage = 'FolderSync'
    $response = Invoke-EomCommand -Context $Context -Command 'FolderSync' -Body (New-EasFolderSyncRequest)
    $state = Get-EomFolderSyncState -Response $response
    if ($state.ProvisioningRequired) {
        if ($Context.PolicyAcknowledged) {
            throw "FolderSync still requires provisioning after the policy was acknowledged (HTTP $($state.HttpStatus), ActiveSync status $($state.EasStatus))."
        }
        $what = if ($state.HttpStatus -eq 449) { 'HTTP 449' } else { "ActiveSync status $($state.EasStatus)" }
        if (-not (Invoke-EomPolicy -Context $Context -Stage $stage -Reason "Exchange requires ActiveSync provisioning ($what).")) { return }
        $response = Invoke-EomCommand -Context $Context -Command 'FolderSync' -Body (New-EasFolderSyncRequest)
    }
    Assert-EasHttpResponse -Command 'FolderSync' -Response $response
    if ($response.Body.Length -eq 0) { throw 'FolderSync returned an empty response.' }
    $Context.Folders = @(Get-EomFoldersFromResponse -Document (ConvertFrom-EasWbxml -Data $response.Body))
    $inbox = $Context.Folders | Where-Object Type -eq '2' | Select-Object -First 1
    $details = [ordered]@{ HttpStatus = $response.StatusCode; Folders = $Context.Folders.Count; InboxServerId = if ($inbox) { $inbox.ServerId } else { $null }; PolicyKeySent = $Context.PolicyKey -ne '0' }
    if ($inbox) {
        Add-EomStep $Context $stage 'FolderSync' Passed "$($Context.Folders.Count) folder(s) returned; Inbox found." $details
    }
    else {
        Add-EomStep $Context $stage 'FolderSync' Warning "$($Context.Folders.Count) folder(s) returned, but no default Inbox (type 2)." $details
    }
}

function Invoke-EomStageIdentity {
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $response = Invoke-EomCommand -Context $Context -Command 'Settings' -Body (New-EasSettingsRequest)
    Assert-EasHttpResponse -Command 'Settings' -Response $response
    if ($response.Body.Length -eq 0) { throw 'Settings returned an empty response.' }
    $identity = Get-EomIdentityFromResponse -Document (ConvertFrom-EasWbxml -Data $response.Body)
    $Context.Identity = $identity
    $mailbox = [string]$Context.Config.Mailbox
    $details = [ordered]@{ DisplayName = $identity.DisplayName; PrimarySmtpAddress = $identity.PrimarySmtpAddress; Addresses = $identity.Addresses -join ', ' }
    $who = if ($identity.PrimarySmtpAddress) { $identity.PrimarySmtpAddress } elseif ($identity.Addresses.Count) { $identity.Addresses[0] } else { $null }
    if (-not $identity.Addresses.Count) {
        Add-EomStep $Context 'Identity' 'UserInformation' Warning 'Exchange returned no address for the signed-in user.' $details
    }
    elseif (@($identity.Addresses | Where-Object { $_ -ieq $mailbox }).Count) {
        Add-EomStep $Context 'Identity' 'UserInformation' Passed "The signed-in user is $who; $mailbox is one of its $($identity.Addresses.Count) address(es)." $details
    }
    else {
        Add-EomStep $Context 'Identity' 'UserInformation' Warning "The signed-in user is $who, not $($mailbox): the folders and messages read belong to the user of the token." $details
    }
}

function Invoke-EomStageInboxSync {
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $inbox = $Context.Folders | Where-Object Type -eq '2' | Select-Object -First 1
    if ($null -eq $inbox) { throw 'No Inbox to synchronise: FolderSync did not return a default Inbox folder (type 2).' }
    $initial = Invoke-EomCommand -Context $Context -Command 'Sync' -Body (New-EasSyncRequest -SyncKey '0' -CollectionId $inbox.ServerId)
    Assert-EasHttpResponse -Command 'Sync (initial)' -Response $initial
    if ($initial.Body.Length -eq 0) { throw 'The initial Sync returned an empty response.' }
    $first = Get-EomMessagesFromResponse -Document (ConvertFrom-EasWbxml -Data $initial.Body) -Command 'Sync (initial)'
    if ([string]::IsNullOrWhiteSpace($first.SyncKey) -or $first.SyncKey -eq '0') { throw 'The initial Sync did not return a usable synchronisation key.' }

    $window = [int]$Context.Config.MessageCount
    $response = Invoke-EomCommand -Context $Context -Command 'Sync' -Body (New-EasSyncRequest -SyncKey $first.SyncKey -CollectionId $inbox.ServerId -GetChanges -WindowSize $window)
    Assert-EasHttpResponse -Command 'Sync' -Response $response
    $messages = @()
    $more = $false
    # An empty answer means that the Inbox has no item to return.
    if ($response.Body.Length -gt 0) {
        $parsed = Get-EomMessagesFromResponse -Document (ConvertFrom-EasWbxml -Data $response.Body) -Command 'Sync'
        $messages = @($parsed.Messages)
        $more = $parsed.MoreAvailable
    }
    $Context.Messages = $messages
    $Context.MoreAvailable = $more
    $moreText = if ($more) { '; more are available' } else { '' }
    Add-EomStep $Context 'InboxSync' 'Sync' Passed "$($messages.Count) Inbox header(s) read (window $window$moreText)." ([ordered]@{ InboxServerId = $inbox.ServerId; Headers = $messages.Count; WindowSize = $window; MoreAvailable = $more })
}

#endregion

#region Response parsing ------------------------------------------------------------------

$script:FolderTypes = @{
    '1' = 'User folder'; '2' = 'Inbox'; '3' = 'Drafts'; '4' = 'Deleted Items'; '5' = 'Sent Items'; '6' = 'Outbox'
    '7' = 'Tasks'; '8' = 'Calendar'; '9' = 'Contacts'; '10' = 'Notes'; '11' = 'Journal'; '12' = 'User mail'
    '13' = 'User calendar'; '14' = 'User contacts'; '15' = 'User tasks'; '16' = 'User journal'; '17' = 'User notes'
    '18' = 'Unknown'; '19' = 'Recipient information cache'
}

function Get-EomFoldersFromResponse {
    param([Parameter(Mandatory = $true)][Xml.XmlDocument]$Document)

    $root = $Document.SelectSingleNode('/*[local-name()="Wbxml"]/*[local-name()="FolderSync"]')
    if ($null -eq $root) { throw 'The FolderSync response does not contain a FolderSync root element.' }
    Assert-EasStatus -Command 'FolderSync' -Status ([string](Get-ChildText -Node $root -Name 'Status'))
    @(
        foreach ($node in $root.SelectNodes('./*[local-name()="Changes"]/*[local-name()="Add"]')) {
            $type = Get-ChildText -Node $node -Name 'Type'
            [pscustomobject]@{
                DisplayName = Get-ChildText -Node $node -Name 'DisplayName'
                Type        = $type
                TypeName    = if ($script:FolderTypes.ContainsKey([string]$type)) { $script:FolderTypes[[string]$type] } else { 'Unknown' }
                ServerId    = Get-ChildText -Node $node -Name 'ServerId'
                ParentId    = Get-ChildText -Node $node -Name 'ParentId'
            }
        }
    )
}

function Get-EomMessagesFromResponse {
    param([Parameter(Mandatory = $true)][Xml.XmlDocument]$Document, [string]$Command = 'Sync')

    $collection = $Document.SelectSingleNode('/*[local-name()="Wbxml"]/*[local-name()="Sync"]/*[local-name()="Collections"]/*[local-name()="Collection"]')
    if ($null -eq $collection) { throw "The $Command response does not contain a collection." }
    Assert-EasStatus -Command $Command -Status ([string](Get-ChildText -Node $collection -Name 'Status'))
    [pscustomobject]@{
        SyncKey       = Get-ChildText -Node $collection -Name 'SyncKey'
        MoreAvailable = $null -ne $collection.SelectSingleNode('./*[local-name()="MoreAvailable"]')
        Messages      = @(
            foreach ($node in $collection.SelectNodes('./*[local-name()="Commands"]/*[local-name()="Add"]')) {
                $data = $node.SelectSingleNode('./*[local-name()="ApplicationData"]')
                $read = if ($data) { Get-ChildText -Node $data -Name 'Read' } else { $null }
                [pscustomobject]@{
                    DateReceived = if ($data) { Get-ChildText -Node $data -Name 'DateReceived' } else { $null }
                    From         = if ($data) { Get-ChildText -Node $data -Name 'From' } else { $null }
                    Subject      = if ($data) { Get-ChildText -Node $data -Name 'Subject' } else { $null }
                    Read         = switch ($read) { '1' { 'Yes' } '0' { 'No' } default { $read } }
                    ServerId     = Get-ChildText -Node $node -Name 'ServerId'
                }
            }
        )
    }
}

function Get-EomIdentityFromResponse {
    param([Parameter(Mandatory = $true)][Xml.XmlDocument]$Document)

    $root = $Document.SelectSingleNode('/*[local-name()="Wbxml"]/*[local-name()="Settings"]')
    if ($null -eq $root) { throw 'The Settings response does not contain a Settings root element.' }
    Assert-EasStatus -Command 'Settings' -Status ([string](Get-ChildText -Node $root -Name 'Status'))
    $info = $root.SelectSingleNode('./*[local-name()="UserInformation"]')
    if ($null -eq $info) { throw 'The Settings response does not contain UserInformation.' }
    $infoStatus = Get-ChildText -Node $info -Name 'Status'
    if ($infoStatus) { Assert-EasStatus -Command 'Settings UserInformation' -Status $infoStatus }

    $addresses = [Collections.Generic.List[string]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $primary = $null
    foreach ($node in $info.SelectNodes('.//*[local-name()="PrimarySmtpAddress" or local-name()="SmtpAddress"]')) {
        $value = $node.InnerText.Trim()
        if (-not $value) { continue }
        if ($node.LocalName -eq 'PrimarySmtpAddress' -and -not $primary) { $primary = $value }
        if ($seen.Add($value)) { [void]$addresses.Add($value) }
    }
    $displayNode = $info.SelectSingleNode('.//*[local-name()="UserDisplayName"]')
    [pscustomobject]@{
        DisplayName        = if ($displayNode) { $displayNode.InnerText } else { $null }
        PrimarySmtpAddress = $primary
        Addresses          = @($addresses)
    }
}

#endregion

#region Orchestration ---------------------------------------------------------------------

function Invoke-EomMailboxTest {
    <#
    .SYNOPSIS
        Runs one scenario and returns the result (steps, folders, headers, policy, identity, token claims).
    .PARAMETER Configuration
        Settings hashtable (Import-EomConfiguration). Missing keys take their default value.
    .PARAMETER TestType
        Scenario. Default: the TestType of the configuration (Test.DefaultType).
    .PARAMETER AccessToken
        Token already obtained (integration only). It is never written anywhere.
    .PARAMETER Credential
        User name and password for Basic authentication (Test.Authentication = 'Basic'). The password
        is sent with the requests and never written anywhere. Not needed by Discovery.
    .PARAMETER Quiet
        No console output (log and GUI still receive the lines).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Configuration,
        [ValidateSet('Discovery', 'OAuth', 'Endpoint', 'FolderSync', 'Provisioning', 'Identity', 'InboxSync', 'Full', 'AppleMail')][string]$TestType,
        [string]$AccessToken,
        [pscredential]$Credential,
        [switch]$Quiet
    )

    $cfg = Get-EomDefaultConfiguration
    foreach ($key in $Configuration.Keys) { $cfg[$key] = $Configuration[$key] }
    if ($TestType) { $cfg.TestType = $TestType }
    $validation = Test-EomConfiguration -Configuration $cfg
    if (-not $validation.IsValid) { throw ("Invalid configuration:`n - " + ($validation.Problems -join "`n - ")) }
    $cfg = Resolve-EomClientSettings -Configuration $cfg
    $basic = $cfg.Authentication -eq 'Basic'
    $stages = @(Get-EomScenarioStages -TestType $cfg.TestType -Authentication $cfg.Authentication)
    if ($basic -and $stages -contains 'Basic' -and -not $Credential) { throw 'Basic authentication needs a user name and a password: -Credential (Get-Credential).' }

    $previousQuiet = $script:Quiet
    $previousAgent = $script:EomUserAgent
    $previousDevice = $script:EomDevice
    $previousTrace = $script:EomTrace
    $previousAuthentication = $script:EomAuthentication
    $script:Quiet = [bool]$Quiet
    $script:EomUserAgent = [string]$cfg.UserAgent
    $script:EomDevice = @{ ProtocolVersion = [string]$cfg.ProtocolVersion; Model = [string]$cfg.DeviceModel; FriendlyName = [string]$cfg.DeviceFriendlyName; OS = [string]$cfg.DeviceOS }
    $script:EomAuthentication = [string]$cfg.Authentication
    $scenario = $script:Scenarios | Where-Object Name -eq $cfg.TestType
    $started = [DateTimeOffset]::UtcNow
    $endpoints = Resolve-EomEndpoints -Configuration $cfg
    $context = @{
        Config             = $cfg
        Endpoints          = $endpoints
        EasUrlSource       = 'Configuration'
        AdfsUrlSource      = 'Configuration'
        # Authorization server: where it comes from (configuration, Exchange challenge) and, for Entra ID, the tenant ID found.
        AuthoritySource    = 'Configuration'
        TenantId           = $null
        DeviceId           = if ($cfg.DeviceId) { [string]$cfg.DeviceId } else { Get-EomDeviceId -Mailbox ([string]$cfg.Mailbox) -DeviceType ([string]$cfg.DeviceType) }
        EncodedUser        = [Uri]::EscapeDataString([string]$cfg.Mailbox)
        # One authentication per run: the token (OAuth) or the user name and password (Basic).
        AccessToken        = if ($basic) { '' } else { $AccessToken }
        Credential         = if ($basic) { $Credential } else { $null }
        # How the OAuth sign-in happened: Window, DeviceCode or Supplied ($null: no sign-in, or Basic).
        SignIn             = $null
        HttpClient         = $null
        PolicyKey          = '0'
        PolicyAcknowledged = $false
        PolicySettings     = @()
        Folders            = @()
        Messages           = @()
        MoreAvailable      = $false
        Identity           = $null
        Token              = $null
        Steps              = [Collections.Generic.List[object]]::new()
        Trace              = [Collections.Generic.List[object]]::new()
        Clock              = [Diagnostics.Stopwatch]::StartNew()
        Stop               = $false
    }
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseDefaultCredentials = $false
    $handler.CookieContainer = [Net.CookieContainer]::new()
    $script:EomTrace = $context.Trace
    $context.HttpClient = [Net.Http.HttpClient]::new($handler)
    $context.HttpClient.Timeout = [TimeSpan]::FromSeconds([int]$cfg.HttpTimeoutSeconds)

    try {
        for ($i = 0; $i -lt $stages.Count; $i++) {
            $stage = $stages[$i]
            $info = $script:StageInfo[$stage]
            $title = Get-EomStageTitle -Stage $stage -Authentication $cfg.Authentication -Authority $cfg.Authority
            $script:EomTraceStage = $stage
            Write-EomStep ($i + 1) $stages.Count $title -Icon $info.Icon
            if ($context.Stop) {
                Add-EomStep $context $stage $title Skipped 'Not run: an earlier step failed or was blocked.'
                continue
            }
            try {
                switch ($stage) {
                    'Discovery' { Invoke-EomStageDiscovery -Context $context }
                    'AppleSetup' { Invoke-EomStageAppleSetup -Context $context }
                    'OAuth' { Invoke-EomStageOAuth -Context $context }
                    'Basic' { Invoke-EomStageBasic -Context $context }
                    'Endpoint' { Invoke-EomStageEndpoint -Context $context }
                    'Provisioning' { Invoke-EomStageProvisioning -Context $context }
                    'FolderSync' { Invoke-EomStageFolderSync -Context $context }
                    'Identity' { Invoke-EomStageIdentity -Context $context }
                    'InboxSync' { Invoke-EomStageInboxSync -Context $context }
                }
            }
            catch {
                Add-EomStep $context $stage $title Failed $_.Exception.Message
                $context.Stop = $true
            }
        }
    }
    finally {
        $context.HttpClient.Dispose()
        $handler.Dispose()
        $script:Quiet = $previousQuiet
        $script:EomUserAgent = $previousAgent
        $script:EomDevice = $previousDevice
        $script:EomAuthentication = $previousAuthentication
        $script:EomTrace = $previousTrace
        $script:EomTraceStage = $null
    }

    $steps = @($context.Steps)
    $counts = [ordered]@{}
    foreach ($s in 'Passed', 'Warning', 'Blocked', 'Failed', 'Skipped') { $counts[$s] = @($steps | Where-Object Status -eq $s).Count }
    $firstProblem = $steps | Where-Object { $_.Status -in 'Failed', 'Blocked' } | Select-Object -First 1
    $completed = [DateTimeOffset]::UtcNow
    [pscustomobject]@{
        Tool               = 'EAS OAuth Mailbox'
        Version            = $script:ToolVersion
        Status             = Get-EomOverallStatus -Steps $steps
        TestType           = $cfg.TestType
        Scenario           = $scenario.DisplayName
        StartedUtc         = $started.ToString('yyyy-MM-ddTHH:mm:ssZ')
        CompletedUtc       = $completed.ToString('yyyy-MM-ddTHH:mm:ssZ')
        DurationSeconds    = [Math]::Round(($completed - $started).TotalSeconds, 1)
        Mailbox            = [string]$cfg.Mailbox
        Authentication     = [string]$cfg.Authentication
        # User name sent with Basic authentication (the password is never kept).
        BasicUser          = if ($context.Credential) { $context.Credential.UserName } else { $null }
        Client             = [string]$cfg.Client
        ClientId           = [string]$cfg.ClientId
        UserAgent          = [string]$cfg.UserAgent
        ProtocolVersion    = [string]$cfg.ProtocolVersion
        DeviceId           = $context.DeviceId
        DeviceType         = [string]$cfg.DeviceType
        AdfsUrl            = $context.Endpoints.AdfsRoot
        EasUrl             = $context.Endpoints.EasUrl
        AdfsUrlSource      = if ($context.Endpoints.AdfsRoot) { $context.AdfsUrlSource } else { $null }
        EasUrlSource       = if ($context.Endpoints.EasUrl) { $context.EasUrlSource } else { $null }
        # Authorization server of the sign-in: ADFS, EntraID (Exchange on-premises with HMA, or Exchange Online), or empty (Basic, or not found).
        Authority          = if ($cfg.Authentication -eq 'Basic' -or $cfg.Authority -eq 'Auto') { $null } else { [string]$cfg.Authority }
        AuthorityUrl       = if ($context.Endpoints.EntraRoot) { $context.Endpoints.EntraRoot } else { $context.Endpoints.AdfsRoot }
        AuthoritySource    = if ($context.Endpoints.EntraRoot -or $context.Endpoints.AdfsRoot) { $context.AuthoritySource } else { $null }
        TenantId           = $context.TenantId
        SignIn             = $context.SignIn
        PolicyAcknowledged = $context.PolicyAcknowledged
        PolicySettings     = @($context.PolicySettings)
        Folders            = @($context.Folders)
        Messages           = @($context.Messages)
        MoreAvailable      = $context.MoreAvailable
        Identity           = $context.Identity
        Token              = $context.Token
        Counts             = $counts
        Steps              = $steps
        Trace              = @($context.Trace)
        Error              = if ($firstProblem) { "$($firstProblem.Name): $($firstProblem.Message)" } else { $null }
    }
}

#endregion
