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

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
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
        handshake rejects the certificate.
    #>
    param([Parameter(Mandatory = $true)][string]$HostName, [int]$Port = 443, [int]$TimeoutSeconds = 10)

    $result = [ordered]@{ HostName = $HostName; Port = $Port; Reachable = $false; Valid = $false; Subject = $null; Issuer = $null; NotAfterUtc = $null; DaysLeft = $null; Protocol = $null; Error = $null }
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
        $ssl = [Net.Security.SslStream]::new($tcp.GetStream(), $false)
        try {
            try {
                $ssl.AuthenticateAsClient($HostName)
            }
            catch {
                $inner = $_.Exception; while ($inner.InnerException) { $inner = $inner.InnerException }
                $result.Error = $inner.Message
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
        Error            = $parameters['error']
    }
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
    <# POST of one ActiveSync command with the token and the current policy key. #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Command, [Parameter(Mandatory = $true)][byte[]]$Body)
    Invoke-EomUiPump
    Assert-EomNotCancelled
    Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Post) -Uri (Get-EomCommandUri $Context $Command) `
        -AccessToken $Context.AccessToken -Body $Body -PolicyKey $Context.PolicyKey
}

#endregion

#region OAuth ------------------------------------------------------------------------------

function Invoke-EomDeviceCodeAuthentication {
    <#
        AD FS device-code flow, every request traced. The verification page is opened; the code is
        shown in the console and the GUI. UserAgent: the one of the client played (the iPhone setup
        screen for AppleMail).
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Configuration,
        [Parameter(Mandatory = $true)][pscustomobject]$Endpoints,
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$HttpClient,
        [string]$UserAgent
    )

    $requested = Invoke-EomFormPost -HttpClient $HttpClient -Uri $Endpoints.DeviceCodeEndpoint -UserAgent $UserAgent `
        -Fields ([ordered]@{ client_id = [string]$Configuration.ClientId; scope = $Endpoints.Scope })
    $deviceCode = $requested.Json
    if ($requested.StatusCode -ne 200) {
        throw ('AD FS refused the device-code request (HTTP {0}): {1} - {2}' -f $requested.StatusCode, [string](Get-EomField $deviceCode 'error'), [string](Get-EomField $deviceCode 'error_description'))
    }
    $deviceCodeValue = [string](Get-EomField $deviceCode 'device_code')
    if ([string]::IsNullOrWhiteSpace($deviceCodeValue)) { throw 'AD FS did not return a device code.' }
    $expiresIn = 0
    if (-not [int]::TryParse([string](Get-EomField $deviceCode 'expires_in'), [ref]$expiresIn) -or $expiresIn -le 0) {
        throw 'AD FS did not return a valid device-code expiration.'
    }
    $interval = 5
    $serverInterval = 0
    if ([int]::TryParse([string](Get-EomField $deviceCode 'interval'), [ref]$serverInterval) -and $serverInterval -gt 0) {
        $interval = [Math]::Max($serverInterval, 5)
    }
    $verificationUrl = [string](Get-EomField $deviceCode 'verification_uri_complete')
    if ([string]::IsNullOrWhiteSpace($verificationUrl)) { $verificationUrl = [string](Get-EomField $deviceCode 'verification_uri') }
    if ([string]::IsNullOrWhiteSpace($verificationUrl)) { throw 'AD FS did not return a verification URL.' }

    $message = [string](Get-EomField $deviceCode 'message')
    $userCode = [string](Get-EomField $deviceCode 'user_code')
    if ($message) { Write-EomItem Info $message -Icon Key }
    if ($userCode) { Write-EomItem Info ("Code: {0}  -  page: {1}" -f $userCode, [string](Get-EomField $deviceCode 'verification_uri')) -Icon Key }
    Write-EomItem Info ('Waiting for the sign-in in the browser (up to {0}).' -f (Format-EomDuration ([Math]::Min($expiresIn, [int]$Configuration.OAuthPollTimeoutSeconds)))) -Icon Clock
    Start-Process -FilePath $verificationUrl | Out-Null

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
            if ([string]::IsNullOrWhiteSpace($accessToken)) { throw 'AD FS returned a token response without access_token.' }
            return $accessToken
        }
        $code = [string](Get-EomField $answer.Json 'error')
        if (-not $code) { throw "AD FS token request failed: HTTP $($answer.StatusCode) without an OAuth error." }
        if ($code -eq 'authorization_pending') { continue }
        if ($code -eq 'slow_down') { $interval += 5; continue }
        if ($code -eq 'access_denied') { throw 'AD FS sign-in was denied.' }
        if ($code -eq 'expired_token') { throw 'The AD FS device code expired before the sign-in was completed.' }
        throw ('AD FS token request failed: {0} - {1}' -f $code, [string](Get-EomField $answer.Json 'error_description'))
    }
    throw 'AD FS did not return an access token before the configured timeout (Test.OAuthPollTimeoutSeconds).'
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
    <# Audience, scope and expiry of the token compared with the ActiveSync resource. Returns Status, Message, Details. #>
    param(
        [AllowNull()][hashtable]$Claims,
        [Parameter(Mandatory = $true)][pscustomobject]$Endpoints,
        [Parameter(Mandatory = $true)][string]$Mailbox,
        # Client the token must be issued to (AppleMail scenario); not checked when empty.
        [string]$ExpectedClientId,
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
        ExpiresUtc = if ($expires) { $expires.UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ') } else { $null }
        MinutesLeft = if ($expires) { [int][Math]::Floor(($expires - $Now).TotalMinutes) } else { $null }
    }
    if ($expires -and $expires -le $Now) {
        return [pscustomobject]@{ Status = 'Failed'; Message = "The token expired at $($details.ExpiresUtc)."; Details = $details }
    }
    $issues = [Collections.Generic.List[string]]::new()
    if (-not $expires) { [void]$issues.Add('the token has no exp claim') }
    $expected = $Endpoints.Resource.TrimEnd('/')
    if (-not @($audiences | Where-Object { ([string]$_).TrimEnd('/') -ieq $expected }).Count) {
        [void]$issues.Add("the audience '$($details.Audience)' is not the ActiveSync resource '$($Endpoints.Resource)': Exchange will reject the token (HTTP 401)")
    }
    if ($scope -notmatch '(^|\s)EAS\.AccessAsUser\.All(\s|$)') {
        [void]$issues.Add("the scope '$scope' does not contain EAS.AccessAsUser.All")
    }
    if ($ExpectedClientId -and $details.ClientId -and $details.ClientId -ine $ExpectedClientId) {
        [void]$issues.Add("the token was issued to the client $($details.ClientId), not to $ExpectedClientId")
    }
    $note = if ($user -and $user -ine $Mailbox) { " Token user $user is not written like the mailbox $Mailbox (UPN and SMTP address can differ): the Identity check confirms the mailbox." } else { '' }
    if ($issues.Count) {
        return [pscustomobject]@{ Status = 'Warning'; Message = ('Token received, but ' + ($issues -join '; ') + '.' + $note); Details = $details }
    }
    $left = if ($null -ne $details.MinutesLeft) { " (valid for $($details.MinutesLeft) min)" } else { '' }
    return [pscustomobject]@{ Status = 'Passed'; Message = "Audience, scope and expiry match the ActiveSync resource$left.$note"; Details = $details }
}

#endregion

#region Stages -----------------------------------------------------------------------------

function Test-EomMailboxChallenge {
    <#
        What Exchange tells a client about OAuth for one mailbox: request with an empty Bearer
        header and X-User-Identity, as Outlook and the iPhone send it. Exchange returns the
        authorization URL of AD FS only when the authentication policy of that user allows modern
        authentication. Returns Status, Message, Details and AuthorizationUri.
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
    $outcome = { param([string]$Status, [string]$Message) [pscustomobject]@{ Status = $Status; Message = $Message; Details = $details; AuthorizationUri = $info.AuthorizationUri } }
    $advertised = $null
    if ($info.AuthorizationUri) { [void][Uri]::TryCreate($info.AuthorizationUri, [UriKind]::Absolute, [ref]$advertised) }

    if ($response.StatusCode -eq 451) {
        $details.Location = Get-EasRedirectLocation -Response $response
        return & $outcome 'Warning' "Exchange redirects $mailbox to another ActiveSync URL (HTTP 451, X-MS-Location $($details.Location)): test that URL."
    }
    if ($response.StatusCode -ne 401) {
        return & $outcome 'Failed' "HTTP $($response.StatusCode) instead of 401 to a request without a token: check the URL and the publishing (reverse proxy, load balancer)."
    }
    if ($info.Bearer -and $advertised -and $ep.AdfsHost -and $advertised.Host -ine $ep.AdfsHost) {
        return & $outcome 'Warning' "Exchange offers OAuth to $mailbox, but with the authorization server $($advertised.Host), not $($ep.AdfsHost): clients will sign in there. Check Get-AuthServer (IsDefaultAuthorizationEndpoint)."
    }
    if ($info.Bearer -and $advertised) {
        $kind = if ($info.IssuerKind) { ", issuer_kind $($info.IssuerKind)" } else { '' }
        return & $outcome 'Passed' "Exchange offers OAuth to $mailbox and gives the authorization URL ($($info.AuthorizationUri)$kind): this is how Outlook and the iPhone find the authorization server."
    }
    if ($info.Bearer -and $diagnostics -match 'oauth_not_available') {
        $reason = if ($diagnostics -match 'reason="([^"]+)"') { $Matches[1] } else { $diagnostics }
        return & $outcome 'Failed' ("Exchange does not offer OAuth to $mailbox ($reason): the authentication policy of the user blocks modern authentication for ActiveSync, or the domain is not an accepted domain. " +
            "Clients fall back to Basic authentication. Check Get-User $mailbox | Format-List AuthenticationPolicy, Get-AuthenticationPolicy | Format-List Name, BlockModernAuthActiveSync and Get-OrganizationConfig | Format-List DefaultAuthenticationPolicy.")
    }
    if ($info.Bearer) {
        return & $outcome 'Warning' "Exchange accepts OAuth for $mailbox but gives no authorization URL: Outlook and the iPhone cannot find AD FS. Check Get-AuthServer (Type ADFS, IsDefaultAuthorizationEndpoint `$true)."
    }
    return & $outcome 'Failed' "No OAuth challenge for $mailbox (schemes: $($details.Schemes)): check OAuth on the ActiveSync virtual directory, New-AuthServer -Type ADFS and the reverse proxy."
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

function Invoke-EomStageAppleSetup {
    <#
        What the iPhone does when the account is added, before the password: Autodiscover, OAuth
        offered for the mailbox with the AD FS URL, then the AD FS page for the Apple Mail client.
        No sign-in, nothing created. Stops the scenario when the iPhone could not reach the sign-in.
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

    # 2. OAuth for the mailbox, sent by the account setup screen (User-Agent Preferences/..., GET).
    $challenge = Test-EomMailboxChallenge -Context $Context -Method ([Net.Http.HttpMethod]::Get) -UserAgent $script:AppleMail.SetupUserAgent
    Add-EomStep $Context $stage 'OAuth for the mailbox' $challenge.Status $challenge.Message $challenge.Details
    if ($challenge.Status -eq 'Failed') { $Context.Stop = $true; return }
    # AD FS is where Exchange sends the iPhone: the root of the authorization URL.
    $adfsRoot = [regex]::Match([string]$challenge.AuthorizationUri, '^(https://[^/?#]+/adfs)/oauth2/authorize', 'IgnoreCase')
    if (-not $adfsRoot.Success) {
        Add-EomStep $Context $stage 'AD FS found' Failed ("Exchange gives no AD FS authorization URL ($(if ($challenge.AuthorizationUri) { $challenge.AuthorizationUri } else { 'none' })): the iPhone cannot reach AD FS. " +
            'Check Get-AuthServer (Type ADFS, IsDefaultAuthorizationEndpoint $true); an Entra ID URL means hybrid modern authentication, not AD FS.') ([ordered]@{ AuthorizationUri = $challenge.AuthorizationUri })
        $Context.Stop = $true
        return
    }
    & $set $ep.EasUrl $adfsRoot.Groups[1].Value
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

function Invoke-EomStageDiscovery {
    <# Checks that need no sign-in and create nothing on the server. A failed check does not stop the scenario. #>
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $stage = 'Discovery'
    $cfg = $Context.Config
    $ep = $Context.Endpoints

    try {
        $meta = Invoke-EomHttpGet -HttpClient $Context.HttpClient -Uri $ep.MetadataEndpoint
        $details = [ordered]@{
            Issuer                      = [string](Get-EomField $meta 'issuer')
            TokenEndpoint               = [string](Get-EomField $meta 'token_endpoint')
            DeviceAuthorizationEndpoint = [string](Get-EomField $meta 'device_authorization_endpoint')
        }
        if ($details.TokenEndpoint) {
            Add-EomStep $Context $stage 'AD FS metadata' Passed "OpenID configuration published by AD FS (issuer $($details.Issuer))." $details
        }
        else {
            Add-EomStep $Context $stage 'AD FS metadata' Warning 'The OpenID configuration of AD FS has no token_endpoint.' $details
        }
    }
    catch {
        Add-EomStep $Context $stage 'AD FS metadata' Warning ("OpenID configuration not readable ($($_.Exception.Message)). Sign-in can still work if this endpoint is disabled in AD FS.") ([ordered]@{ Url = $ep.MetadataEndpoint })
    }

    $hosts = [ordered]@{}
    $hosts["$($ep.AdfsHost):$($ep.AdfsPort)"] = @($ep.AdfsHost, $ep.AdfsPort)
    $hosts["$($ep.EasHost):$($ep.EasPort)"] = @($ep.EasHost, $ep.EasPort)
    foreach ($entry in $hosts.Values) {
        $cert = Get-EomTlsCertificate -HostName $entry[0] -Port $entry[1] -TimeoutSeconds ([Math]::Min(15, [int]$cfg.HttpTimeoutSeconds))
        $name = "TLS certificate ($($entry[0]))"
        $details = [ordered]@{ Host = "$($entry[0]):$($entry[1])"; Subject = $cert.Subject; Issuer = $cert.Issuer; NotAfterUtc = $cert.NotAfterUtc; DaysLeft = $cert.DaysLeft; Protocol = $cert.Protocol; Error = $cert.Error }
        $received = if ($cert.Reachable) { "Certificate
Subject: $($cert.Subject)
Issuer: $($cert.Issuer)
Valid until: $($cert.NotAfterUtc) ($($cert.DaysLeft) day(s))
Protocol: $($cert.Protocol)
Trusted by this computer: $(if ($cert.Valid) { 'yes' } else { "no - $($cert.Error)" })" } else { "No TLS connection: $($cert.Error)" }
        Add-EomTraceEntry -Method 'TLS' -Url "tls://$($entry[0]):$($entry[1])" -Request "TLS handshake (ClientHello)
Server name (SNI): $($entry[0])
Port: $($entry[1])" -Response $received -Note 'Direct TLS connection (no HTTP request): the certificate the server presents.'
        if (-not $cert.Reachable) {
            Add-EomStep $Context $stage $name Warning "No direct TLS connection ($($cert.Error)). Expected behind a proxy (the HTTPS checks use the system proxy); otherwise check DNS and the firewall." $details
        }
        elseif (-not $cert.Valid) {
            Add-EomStep $Context $stage $name Failed "Certificate not trusted by this computer: $($cert.Error)" $details
        }
        elseif ($cert.DaysLeft -lt [int]$cfg.CertificateWarningDays) {
            Add-EomStep $Context $stage $name Warning "Certificate expires in $($cert.DaysLeft) day(s) ($($cert.NotAfterUtc))." $details
        }
        else {
            Add-EomStep $Context $stage $name Passed "Certificate trusted, valid $($cert.DaysLeft) more day(s), $($cert.Protocol)." $details
        }
    }

    try {
        $anonymous = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $ep.EasUrl -AccessToken ''
        $info = Get-EomChallengeInfo -Challenges @(Get-EomField $anonymous 'Challenges')
        $details = [ordered]@{ HttpStatus = $anonymous.StatusCode; Schemes = $info.Schemes -join ', '; ChallengeRequest = 'Anonymous'; AuthorizationUri = $info.AuthorizationUri }
        if ($anonymous.StatusCode -eq 401 -and -not $info.Bearer) {
            # Exchange Server (2019 CU13+, SE) returns its Bearer challenge only to a request that
            # already carries "Authorization: Bearer", the request a client sends to discover OAuth.
            $probe = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $ep.EasUrl -AccessToken '' -EmptyBearer
            $probeInfo = Get-EomChallengeInfo -Challenges @(Get-EomField $probe 'Challenges')
            $details.EmptyBearerStatus = $probe.StatusCode
            $details.EmptyBearerSchemes = $probeInfo.Schemes -join ', '
            $details.Diagnostics = Get-EasDiagnostics -Response $probe
            if ($probe.StatusCode -eq 401 -and $probeInfo.Bearer) {
                $info = $probeInfo
                $details.ChallengeRequest = 'Empty Bearer'
                $details.AuthorizationUri = $probeInfo.AuthorizationUri
            }
        }
        $advertised = $null
        if ($info.AuthorizationUri) { [void][Uri]::TryCreate($info.AuthorizationUri, [UriKind]::Absolute, [ref]$advertised) }
        if ($anonymous.StatusCode -eq 401 -and $info.Bearer -and $advertised -and $advertised.Host -ine $ep.AdfsHost) {
            # Exchange advertises the authorization URL of its DefaultAuthorizationEndpoint auth server.
            Add-EomStep $Context $stage 'OAuth challenge' Warning ("ActiveSync advertises OAuth, but with the authorization server $($advertised.Host), not $($ep.AdfsHost): devices will sign in there. Check Get-AuthServer (IsDefaultAuthorizationEndpoint).") $details
        }
        elseif ($anonymous.StatusCode -eq 401 -and $info.Bearer -and $details.ChallengeRequest -eq 'Empty Bearer') {
            Add-EomStep $Context $stage 'OAuth challenge' Passed ("ActiveSync answers an empty Bearer header with an OAuth challenge, as Exchange does for clients: OAuth is enabled (anonymous schemes: $($details.Schemes)).") $details
        }
        elseif ($anonymous.StatusCode -eq 401 -and $info.Bearer) {
            Add-EomStep $Context $stage 'OAuth challenge' Passed ("ActiveSync advertises OAuth (Bearer) to an anonymous request; schemes: $($details.Schemes).") $details
        }
        elseif ($anonymous.StatusCode -eq 401) {
            Add-EomStep $Context $stage 'OAuth challenge' Warning ("ActiveSync does not advertise OAuth, even to an empty Bearer header (schemes: $($details.Schemes)): check OAuth on the ActiveSync virtual directory, New-AuthServer -Type ADFS, OAuth2ClientProfileEnabled, and the reverse proxy.") $details
        }
        elseif ($anonymous.StatusCode -eq 200) {
            Add-EomStep $Context $stage 'OAuth challenge' Warning 'ActiveSync answered an anonymous OPTIONS with HTTP 200: anonymous access is not expected.' $details
        }
        elseif ($anonymous.StatusCode -eq 451) {
            $details.Location = Get-EasRedirectLocation -Response $anonymous
            Add-EomStep $Context $stage 'OAuth challenge' Warning "ActiveSync redirects to another URL (HTTP 451, X-MS-Location $($details.Location)): devices are sent there; test that URL." $details
        }
        else {
            Add-EomStep $Context $stage 'OAuth challenge' Failed "Anonymous OPTIONS returned HTTP $($anonymous.StatusCode): check the URL and the publishing (reverse proxy, load balancer)." $details
        }

        $mailboxChallenge = Test-EomMailboxChallenge -Context $Context
        Add-EomStep $Context $stage 'OAuth for the mailbox' $mailboxChallenge.Status $mailboxChallenge.Message $mailboxChallenge.Details

        $invalid = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $ep.EasUrl -AccessToken $script:InvalidToken
        $details = [ordered]@{ HttpStatus = $invalid.StatusCode; Diagnostics = Get-EasDiagnostics -Response $invalid }
        if ($invalid.StatusCode -eq 401) {
            Add-EomStep $Context $stage 'Invalid token' Passed 'An invalid bearer token is rejected (HTTP 401).' $details
        }
        elseif ($invalid.StatusCode -ge 200 -and $invalid.StatusCode -lt 300) {
            Add-EomStep $Context $stage 'Invalid token' Failed "Exchange accepted an invalid bearer token (HTTP $($invalid.StatusCode)): investigate the publishing chain immediately." $details
        }
        else {
            Add-EomStep $Context $stage 'Invalid token' Warning "An invalid bearer token returned HTTP $($invalid.StatusCode) (401 expected)." $details
        }
    }
    catch {
        Add-EomStep $Context $stage 'OAuth challenge' Failed "ActiveSync not reachable: $($_.Exception.Message)" ([ordered]@{ Url = $ep.EasUrl })
    }
}

function Invoke-EomStageOAuth {
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $stage = 'OAuth'
    $apple = $Context.Config.Client -eq 'AppleMail'
    if ($Context.AccessToken) {
        Add-EomStep $Context $stage 'Access token' Passed 'Access token supplied by the caller: device-code sign-in skipped.' ([ordered]@{ Source = 'Caller' })
    }
    else {
        $userAgent = if ($apple) { $script:AppleMail.SetupUserAgent } else { $script:EomUserAgent }
        $Context.AccessToken = Invoke-EomDeviceCodeAuthentication -Configuration $Context.Config -Endpoints $Context.Endpoints -HttpClient $Context.HttpClient -UserAgent $userAgent
        if ($apple) {
            Add-EomStep $Context $stage 'Device-code sign-in' Passed ("Access token received from AD FS for the Apple Mail client $($Context.Config.ClientId). The iPhone gets the same token in its web view " +
                "(authorization code sent to com.apple.Preferences://oauth-redirect); a Windows tool cannot receive that redirect, so the device code of the same client is used.") ([ordered]@{
                    Source = 'AD FS device code'; ClientId = $Context.Config.ClientId; Scope = $Context.Endpoints.Scope; iPhone = 'authorization code in a web view, same client and resource'
                })
        }
        else {
            Add-EomStep $Context $stage 'Device-code sign-in' Passed 'Access token received from AD FS.' ([ordered]@{ Source = 'AD FS device code'; ClientId = $Context.Config.ClientId; Scope = $Context.Endpoints.Scope })
        }
    }
    $expectedClient = if ($apple) { [string]$Context.Config.ClientId } else { $null }
    $check = Test-EomTokenClaims -Claims (Get-EomTokenClaims -AccessToken $Context.AccessToken) -Endpoints $Context.Endpoints -Mailbox ([string]$Context.Config.Mailbox) -ExpectedClientId $expectedClient
    $Context.Token = $check.Details
    Add-EomStep $Context $stage 'Token claims' $check.Status $check.Message $check.Details
    if ($check.Status -eq 'Failed') { $Context.Stop = $true }
}

function Invoke-EomStageEndpoint {
    param([Parameter(Mandatory = $true)][hashtable]$Context)

    $response = Invoke-EasRequest -HttpClient $Context.HttpClient -Method ([Net.Http.HttpMethod]::Options) -Uri $Context.Endpoints.EasUrl -AccessToken $Context.AccessToken
    Assert-EasHttpResponse -Command 'OPTIONS' -Response $response
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
    if ($versions -notcontains $protocol) {
        Add-EomStep $Context 'Endpoint' 'OPTIONS' Warning "Token accepted, but protocol $protocol used by the simulated client is not offered (versions: $($details.ProtocolVersions))." $details
    }
    elseif ($missing.Count) {
        Add-EomStep $Context 'Endpoint' 'OPTIONS' Warning "Token accepted, but commands not offered: $($missing -join ', ')." $details
    }
    else {
        $version = if ($details.ExchangeVersion) { "Exchange $($details.ExchangeVersion), " } else { '' }
        Add-EomStep $Context 'Endpoint' 'OPTIONS' Passed "Token accepted (HTTP 200): $($version)protocol $protocol and the commands used are available." $details
    }
}

function Invoke-EomPolicy {
    <# Downloads the policy; acknowledges it only when authorised. Returns $true if the policy is acknowledged. #>
    param([Parameter(Mandatory = $true)][hashtable]$Context, [Parameter(Mandatory = $true)][string]$Stage, [Parameter(Mandatory = $true)][string]$Reason)

    $acknowledge = [bool]$Context.Config.AcknowledgePolicy
    Invoke-EomUiPump
    $policy = Invoke-EasProvision -HttpClient $Context.HttpClient -EasUrl $Context.Endpoints.EasUrl -EncodedUser $Context.EncodedUser `
        -DeviceId $Context.DeviceId -DeviceType $Context.Config.DeviceType -AccessToken $Context.AccessToken -Acknowledge:$acknowledge
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
    .PARAMETER Quiet
        No console output (log and GUI still receive the lines).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Configuration,
        [ValidateSet('Discovery', 'OAuth', 'Endpoint', 'FolderSync', 'Provisioning', 'Identity', 'InboxSync', 'Full', 'AppleMail')][string]$TestType,
        [string]$AccessToken,
        [switch]$Quiet
    )

    $cfg = Get-EomDefaultConfiguration
    foreach ($key in $Configuration.Keys) { $cfg[$key] = $Configuration[$key] }
    if ($TestType) { $cfg.TestType = $TestType }
    $validation = Test-EomConfiguration -Configuration $cfg
    if (-not $validation.IsValid) { throw ("Invalid configuration:`n - " + ($validation.Problems -join "`n - ")) }
    $cfg = Resolve-EomClientSettings -Configuration $cfg

    $previousQuiet = $script:Quiet
    $previousAgent = $script:EomUserAgent
    $previousDevice = $script:EomDevice
    $previousTrace = $script:EomTrace
    $script:Quiet = [bool]$Quiet
    $script:EomUserAgent = [string]$cfg.UserAgent
    $script:EomDevice = @{ ProtocolVersion = [string]$cfg.ProtocolVersion; Model = [string]$cfg.DeviceModel; FriendlyName = [string]$cfg.DeviceFriendlyName; OS = [string]$cfg.DeviceOS }
    $scenario = $script:Scenarios | Where-Object Name -eq $cfg.TestType
    $started = [DateTimeOffset]::UtcNow
    $endpoints = Resolve-EomEndpoints -Configuration $cfg
    $context = @{
        Config             = $cfg
        Endpoints          = $endpoints
        EasUrlSource       = 'Configuration'
        AdfsUrlSource      = 'Configuration'
        DeviceId           = if ($cfg.DeviceId) { [string]$cfg.DeviceId } else { Get-EomDeviceId -Mailbox ([string]$cfg.Mailbox) -DeviceType ([string]$cfg.DeviceType) }
        EncodedUser        = [Uri]::EscapeDataString([string]$cfg.Mailbox)
        AccessToken        = $AccessToken
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
        $stages = @($scenario.Stages)
        for ($i = 0; $i -lt $stages.Count; $i++) {
            $stage = $stages[$i]
            $info = $script:StageInfo[$stage]
            $script:EomTraceStage = $stage
            Write-EomStep ($i + 1) $stages.Count $info.Title -Icon $info.Icon
            if ($context.Stop) {
                Add-EomStep $context $stage $info.Title Skipped 'Not run: an earlier step failed or was blocked.'
                continue
            }
            try {
                switch ($stage) {
                    'Discovery' { Invoke-EomStageDiscovery -Context $context }
                    'AppleSetup' { Invoke-EomStageAppleSetup -Context $context }
                    'OAuth' { Invoke-EomStageOAuth -Context $context }
                    'Endpoint' { Invoke-EomStageEndpoint -Context $context }
                    'Provisioning' { Invoke-EomStageProvisioning -Context $context }
                    'FolderSync' { Invoke-EomStageFolderSync -Context $context }
                    'Identity' { Invoke-EomStageIdentity -Context $context }
                    'InboxSync' { Invoke-EomStageInboxSync -Context $context }
                }
            }
            catch {
                Add-EomStep $context $stage $info.Title Failed $_.Exception.Message
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
