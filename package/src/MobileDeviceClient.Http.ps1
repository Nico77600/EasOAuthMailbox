<#
.SYNOPSIS
    Mobile Device Client for Exchange - HTTP layer and trace of the exchanges (dot-sourced by MobileDeviceClient.psm1).

.DESCRIPTION
    Every HTTP request of the tool (ActiveSync, Autodiscover, AD FS) goes through Invoke-MdcHttp:
      - Send-MdcHttpRequest sends it. It is the only function that touches the network; the tests
        and the documentation tool replace it with the simulator.
      - The exchange is added to the trace of the run: the request sent and the response received
        as text (start line, headers, body), WBXML bodies decoded to XML, JSON indented, HTML pages
        summarised.
    Add-MdcStep attaches the exchanges recorded since the previous check to that check: the report
    shows, for every check, what the client sent and what it received.

    Secrets never reach the trace: access, refresh and ID tokens, device and authorization codes,
    cookies are replaced by their length; for Basic authentication only the user name is shown,
    never the password. The forged token of the Discovery check is shown: it is
    not a secret. Mailbox data (folder names, addresses, Inbox headers) is shown like in the rest
    of the report.

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.0
#>

# Exchanges of the current run (List of objects), $null outside a run. Stage: current stage.
$script:MdcTrace = $null
$script:MdcTraceStage = $null
$script:MdcTraceLimit = 24000
$script:MdcTraceSecrets = @('access_token', 'refresh_token', 'id_token', 'device_code', 'code', 'client_secret', 'code_verifier', 'assertion', 'client_assertion', 'password')
$script:MdcReasons = @{
    200 = 'OK'; 301 = 'Moved Permanently'; 302 = 'Found'; 303 = 'See Other'; 307 = 'Temporary Redirect'; 308 = 'Permanent Redirect'
    400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 449 = 'Retry With'; 451 = 'Redirect'
    500 = 'Internal Server Error'; 502 = 'Bad Gateway'; 503 = 'Service Unavailable'; 504 = 'Gateway Timeout'
}

function Send-MdcHttpRequest {
    <# Sends one request, never follows a redirect. The only function of the tool that touches the network. #>
    param([Parameter(Mandatory = $true)][Net.Http.HttpClient]$HttpClient, [Parameter(Mandatory = $true)][Net.Http.HttpRequestMessage]$Request)

    $response = $HttpClient.SendAsync($Request).GetAwaiter().GetResult()
    try {
        $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
        $headers = @{}
        $lines = [Collections.Generic.List[string]]::new()
        foreach ($set in @($response.Headers.NonValidated, $response.Content.Headers.NonValidated)) {
            foreach ($header in $set) {
                $values = @($header.Value)
                $headers[$header.Key] = $values -join ','
                foreach ($value in $values) { [void]$lines.Add("$($header.Key): $value") }
            }
        }
        [pscustomobject]@{
            StatusCode  = [int]$response.StatusCode
            Reason      = $response.ReasonPhrase
            Headers     = $headers
            HeaderLines = @($lines)
            Challenges  = @(foreach ($challenge in $response.Headers.WwwAuthenticate) { $challenge.ToString() })
            Body        = [byte[]]$bytes
        }
    }
    finally {
        $response.Dispose()
    }
}

function Get-MdcNetworkErrorText {
    <#
        Readable reason of a request that got no answer: the message of the first network exception
        (without the PowerShell "Exception calling GetResult" wrapper and ", see inner exception"),
        followed by the innermost cause (the socket or TLS error). $null when no network exception is
        in the chain: the caller then throws the original exception.
    #>
    param([Parameter(Mandatory = $true)][Exception]$Exception)

    $chain = [Collections.Generic.List[Exception]]::new()
    for ($e = $Exception; $e; $e = $e.InnerException) { $chain.Add($e) }
    $outer = $chain | Where-Object {
        $_ -is [Net.Http.HttpRequestException] -or $_ -is [IO.IOException] -or $_ -is [Net.Sockets.SocketException] -or
        $_ -is [Security.Authentication.AuthenticationException] -or $_ -is [OperationCanceledException]
    } | Select-Object -First 1
    if (-not $outer) { return $null }
    $text = ($outer.Message -replace '[,.]?\s*see inner exception\.?\s*$', '').Trim()
    $inner = $chain[$chain.Count - 1]
    if ($inner -ne $outer -and $inner -isnot [OperationCanceledException] -and $inner -isnot [TimeoutException] -and
        -not [string]::IsNullOrWhiteSpace($inner.Message) -and -not $text.Contains($inner.Message.Trim())) {
        $text = "$($text.TrimEnd('.')): $($inner.Message.Trim())"
    }
    return $text
}

function Invoke-MdcHttp {
    <#
        Sends a request (Send-MdcHttpRequest) and adds the exchange to the trace. Collapse: requests
        repeated with the same answer (AD FS token polling) are counted on the first one.
    #>
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpClient]$HttpClient,
        [Parameter(Mandatory = $true)][Net.Http.HttpRequestMessage]$Request,
        [string]$Note,
        [string]$Collapse
    )

    $body = if ($Request.Content) { [byte[]]$Request.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() } else { [byte[]]@() }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        $response = Send-MdcHttpRequest -HttpClient $HttpClient -Request $Request
    }
    catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        Add-MdcTraceExchange -Request $Request -RequestBody $body -Failure $failure.Message -DurationMs $clock.ElapsedMilliseconds -Note $Note
        $text = Get-MdcNetworkErrorText -Exception $_.Exception
        if ($text) { throw [Net.Http.HttpRequestException]::new($text, $_.Exception) }
        throw
    }
    Add-MdcTraceExchange -Request $Request -RequestBody $body -Response $response -DurationMs $clock.ElapsedMilliseconds -Note $Note -Collapse $Collapse
    return $response
}

function Protect-MdcHeaderValue {
    <# Header value as written to the trace: tokens and cookies replaced by their length, Basic password never shown. #>
    param([Parameter(Mandatory = $true)][string]$Name, [AllowEmptyString()][string]$Value)

    if ($Name -ieq 'Authorization') {
        $parts = $Value.Trim().Split(' ', 2)
        if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[1])) { return $Value }
        if ($parts[0] -ieq 'Basic') {
            # The user name helps to read the trace; the password never leaves memory.
            $decoded = $null
            try { $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($parts[1].Trim())) } catch { $decoded = $null }
            if ($decoded -and $decoded.Contains(':')) { return "Basic <user $($decoded.Split(':', 2)[0]), password never written>" }
            return "Basic <credentials: $($parts[1].Length) characters, never written>"
        }
        if ($parts[1] -eq $script:InvalidToken) { return $Value }
        return "$($parts[0]) <access token: $($parts[1].Length) characters, never written>"
    }
    if ($Name -ieq 'Set-Cookie') { return [regex]::Replace($Value, '^\s*([^=;]+)=[^;]*', '$1=<hidden>') }
    if ($Name -ieq 'Cookie') { return [regex]::Replace($Value, '([^=;\s]+)=[^;]*', '$1=<hidden>') }
    return $Value
}

function Limit-MdcTraceText {
    param([AllowEmptyString()][string]$Text, [int]$Limit = $script:MdcTraceLimit)
    if ($Text.Length -le $Limit) { return $Text }
    return $Text.Substring(0, $Limit) + "`n... (cut: $($Text.Length) characters in total)"
}

function Format-MdcWbxmlXml {
    <# Decoded WBXML document as indented XML, without the code page attributes. #>
    param([Parameter(Mandatory = $true)][Xml.XmlDocument]$Document)

    $copy = [Xml.XmlDocument]$Document.Clone()
    foreach ($attribute in @($copy.SelectNodes('//@CodePage'))) { [void]$attribute.OwnerElement.Attributes.Remove($attribute) }
    $builder = [Text.StringBuilder]::new()
    $settings = [Xml.XmlWriterSettings]::new()
    $settings.Indent = $true
    $settings.IndentChars = '  '
    $settings.OmitXmlDeclaration = $true
    $settings.ConformanceLevel = [Xml.ConformanceLevel]::Fragment
    $writer = [Xml.XmlWriter]::Create($builder, $settings)
    try { foreach ($node in $copy.DocumentElement.ChildNodes) { $node.WriteTo($writer) } }
    finally { $writer.Dispose() }
    return $builder.ToString()
}

function Format-MdcFormBody {
    <# application/x-www-form-urlencoded body, one field per line, URL-decoded, secrets masked. #>
    param([AllowEmptyString()][string]$Text)

    $lines = foreach ($pair in $Text.Split('&')) {
        if (-not $pair) { continue }
        $name, $value = $pair.Split('=', 2)
        $name = [Uri]::UnescapeDataString($name.Replace('+', ' '))
        $value = if ($null -ne $value) { [Uri]::UnescapeDataString($value.Replace('+', ' ')) } else { '' }
        if ($name -in $script:MdcTraceSecrets) { $value = "<$($value.Length) characters, never written>" }
        "$name=$value"
    }
    return "# form fields, one per line, URL-decoded`n" + (@($lines) -join "`n")
}

function Format-MdcJsonBody {
    <# JSON body indented, secrets masked. Throws if the text is not JSON. #>
    param([Parameter(Mandatory = $true)][string]$Text)

    $value = $Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($value -is [System.Collections.IDictionary]) {
        foreach ($key in @($value.Keys)) {
            if ($key -in $script:MdcTraceSecrets -and $null -ne $value[$key]) { $value[$key] = "<$($key): $(([string]$value[$key]).Length) characters, never written>" }
        }
    }
    return (ConvertTo-Json -InputObject $value -Depth 8)
}

function Format-MdcHtmlSummary {
    <# An HTML page summarised: title, AD FS error (MSIS), sign-in form, or the beginning of the visible text. #>
    param([AllowEmptyString()][string]$Text, [int]$Length)

    $lines = [Collections.Generic.List[string]]::new()
    [void]$lines.Add("# HTML page, $Length bytes: summary")
    $title = [regex]::Match($Text, '<title[^>]*>(.*?)</title>', 'IgnoreCase, Singleline')
    if ($title.Success) { [void]$lines.Add('Title: ' + [Net.WebUtility]::HtmlDecode($title.Groups[1].Value).Trim()) }
    $msis = [regex]::Match($Text, 'MSIS\d{4}[^<]*')
    if ($msis.Success) { [void]$lines.Add('AD FS error: ' + [Net.WebUtility]::HtmlDecode($msis.Value).Trim()) }
    if ($Text -match 'passwordInput|userNameInput|loginForm') { [void]$lines.Add('Sign-in form: user name and password fields (AD FS forms authentication)') }
    if (-not $msis.Success -and $Text -notmatch 'passwordInput|userNameInput|loginForm') {
        $visible = [regex]::Replace($Text, '<(script|style)[^>]*>.*?</\1>', ' ', 'IgnoreCase, Singleline')
        $visible = [Net.WebUtility]::HtmlDecode([regex]::Replace($visible, '<[^>]+>', ' '))
        $visible = [regex]::Replace($visible, '\s+', ' ').Trim()
        if ($visible) { [void]$lines.Add('Text: ' + $(if ($visible.Length -gt 600) { $visible.Substring(0, 600) + '...' } else { $visible })) }
    }
    return $lines -join "`n"
}

function Format-MdcTraceBody {
    <# Body of a request or a response as text: WBXML decoded, form and JSON readable, HTML summarised. #>
    param([AllowNull()][byte[]]$Body, [string]$ContentType)

    if ($null -eq $Body -or $Body.Length -eq 0) { return '' }
    $type = ([string]$ContentType).ToLowerInvariant()
    if ($type -like '*vnd.ms-sync.wbxml*' -or ($Body.Length -ge 4 -and $Body[0] -eq 3 -and $Body[1] -eq 1 -and $Body[2] -eq 0x6A)) {
        try {
            return "# WBXML, $($Body.Length) bytes, decoded`n" + (Format-MdcWbxmlXml -Document (ConvertFrom-EasWbxml -Data $Body))
        }
        catch {
            $hex = ($Body | Select-Object -First 64 | ForEach-Object { $_.ToString('X2') }) -join ' '
            return "# WBXML, $($Body.Length) bytes, not decodable ($($_.Exception.Message))`n$hex"
        }
    }
    $text = [Text.Encoding]::UTF8.GetString($Body)
    if ($type -like '*x-www-form-urlencoded*') { return Format-MdcFormBody $text }
    if ($type -like '*json*' -or $text.TrimStart().StartsWith('{')) {
        try { return Format-MdcJsonBody $text } catch { }
    }
    if ($type -like '*html*' -or $text -match '^\s*<(!doctype|html)') { return Format-MdcHtmlSummary -Text $text -Length $Body.Length }
    return Limit-MdcTraceText $text 4000
}

function Get-MdcTraceRequestText {
    <# The request as sent: start line, headers (secrets masked), blank line, body. #>
    param([Parameter(Mandatory = $true)][Net.Http.HttpRequestMessage]$Request, [byte[]]$Body)

    $uri = $Request.RequestUri
    $lines = [Collections.Generic.List[string]]::new()
    [void]$lines.Add("$($Request.Method.Method) $($uri.PathAndQuery) HTTP/1.1")
    [void]$lines.Add("Host: $($uri.Authority)")
    $contentType = $null
    foreach ($set in @($Request.Headers.NonValidated, $(if ($Request.Content) { $Request.Content.Headers.NonValidated }))) {
        if ($null -eq $set) { continue }
        foreach ($header in $set) {
            if ($header.Key -ieq 'Content-Length') { continue }
            $value = $header.Value.ToString()
            if ($header.Key -ieq 'Content-Type') { $contentType = $value }
            [void]$lines.Add("$($header.Key): $(Protect-MdcHeaderValue -Name $header.Key -Value $value)")
        }
    }
    if ($Request.Content) { [void]$lines.Add("Content-Length: $($Body.Length)") }
    $text = $lines -join "`n"
    $bodyText = Format-MdcTraceBody -Body $Body -ContentType $contentType
    if (-not $bodyText -and $uri.Query.Length -gt 1 -and ($uri.Query.Split('&').Count -ge 3)) {
        # Long query strings (AD FS authorization request) are easier to read decoded, one parameter per line.
        $bodyText = (Format-MdcFormBody $uri.Query.TrimStart('?')).Replace('# form fields, one per line', '# query parameters, one per line')
    }
    if ($bodyText) { $text += "`n`n" + $bodyText }
    return Limit-MdcTraceText $text
}

function Get-MdcTraceResponseText {
    <# The response as received: status line, headers (cookies masked), blank line, body. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Response)

    $code = [int]$Response.StatusCode
    $reason = [string](Get-MdcField $Response 'Reason')
    if (-not $reason) { $reason = if ($script:MdcReasons.ContainsKey($code)) { $script:MdcReasons[$code] } else { '' } }
    $lines = [Collections.Generic.List[string]]::new()
    [void]$lines.Add("HTTP/1.1 $code $reason".TrimEnd())
    $headerLines = @(Get-MdcField $Response 'HeaderLines')
    if (-not $headerLines.Count) {
        # Response without the raw header lines (simulator): its headers, one line per challenge.
        $headerLines = @(foreach ($c in @(Get-MdcField $Response 'Challenges')) { "WWW-Authenticate: $c" })
        $headers = Get-MdcField $Response 'Headers'
        if ($headers) { $headerLines += @(foreach ($key in ($headers.Keys | Sort-Object)) { if ($key -ine 'WWW-Authenticate') { "$($key): $($headers[$key])" } }) }
    }
    $contentType = $null
    foreach ($line in $headerLines) {
        $name, $value = ([string]$line).Split(':', 2)
        $value = ([string]$value).Trim()
        if ($name -ieq 'Content-Type') { $contentType = $value }
        [void]$lines.Add("$($name): $(Protect-MdcHeaderValue -Name $name -Value $value)")
    }
    $text = $lines -join "`n"
    $bodyText = Format-MdcTraceBody -Body ([byte[]](Get-MdcField $Response 'Body')) -ContentType $contentType
    if ($bodyText) { $text += "`n`n" + $bodyText }
    return Limit-MdcTraceText $text
}

function Add-MdcTraceEntry {
    <# Adds one exchange to the trace of the run (nothing outside a run). #>
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Request,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Response,
        [AllowNull()][object]$StatusCode,
        [string]$Reason,
        [long]$DurationMs,
        [string]$Note,
        [string]$Collapse,
        [string]$Label
    )

    if ($null -eq $script:MdcTrace) { return }
    if ($Collapse -and $script:MdcTrace.Count) {
        $last = $script:MdcTrace[$script:MdcTrace.Count - 1]
        if ($last.Collapse -eq $Collapse -and $null -eq $last.Step -and $last.StatusCode -eq $StatusCode -and $last.Response -eq $Response) {
            $last.Repeated++
            $last.Note = "Sent $($last.Repeated) times with the same answer (polling while the user signs in): only the first one is shown."
            return
        }
    }
    $entry = [pscustomobject]@{
        Sequence     = $script:MdcTrace.Count + 1
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Stage        = $script:MdcTraceStage
        Step         = $null
        StepName     = $null
        Method       = $Method
        Url          = $Url
        Label        = $Label
        StatusCode   = $StatusCode
        Reason       = $Reason
        DurationMs   = [int]$DurationMs
        Repeated     = 1
        Note         = $Note
        Collapse     = $Collapse
        Request      = $Request
        Response     = $Response
    }
    $script:MdcTrace.Add($entry)
    $status = if ($null -ne $StatusCode) { "$StatusCode $Reason".TrimEnd() } else { 'no response' }
    Write-MdcLog 'INFO' ("HTTP #{0} {1} {2} -> {3} ({4} ms)" -f $entry.Sequence, $Method, $Url, $status, $entry.DurationMs)
}

function Add-MdcTraceExchange {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpRequestMessage]$Request,
        [byte[]]$RequestBody,
        [pscustomobject]$Response,
        [string]$Failure,
        [long]$DurationMs,
        [string]$Note,
        [string]$Collapse
    )

    if ($null -eq $script:MdcTrace) { return }
    $requestText = Get-MdcTraceRequestText -Request $Request -Body $RequestBody
    # What makes this request different from its neighbours: the credentials sent, the user identity.
    $hints = [Collections.Generic.List[string]]::new()
    $auth = $Request.Headers.Authorization
    if ($Request.RequestUri.AbsolutePath -match 'Microsoft-Server-ActiveSync') {
        if (-not $auth) { $hints.Add('no credentials') }
        elseif (-not $auth.Parameter) { $hints.Add("empty $($auth.Scheme) header") }
        elseif ($auth.Scheme -ieq 'Basic') {
            $wrong = (Protect-MdcHeaderValue -Name 'Authorization' -Value "Basic $($auth.Parameter)") -like "Basic <user $($script:InvalidBasicUserPrefix)*"
            $hints.Add($(if ($wrong) { 'wrong user name and password' } else { 'user name and password (Basic)' }))
        }
        elseif ($auth.Parameter -eq $script:InvalidToken) { $hints.Add('forged token') }
        else { $hints.Add('access token') }
    }
    $values = $null
    if ($Request.Headers.TryGetValues('X-User-Identity', [ref]$values)) { $hints.Add('X-User-Identity') }
    $values = $null
    if ($Request.Headers.TryGetValues('X-MS-PolicyKey', [ref]$values)) { $hints.Add("policy key $(@($values) -join '')") }
    if ($RequestBody -and $RequestBody.Length -and $Request.Content -and "$($Request.Content.Headers.ContentType)" -like '*form-urlencoded*') {
        $grant = [regex]::Match([Text.Encoding]::UTF8.GetString($RequestBody), '(?:^|&)grant_type=([^&]*)')
        if ($grant.Success) { $hints.Add('grant ' + ([Uri]::UnescapeDataString($grant.Groups[1].Value) -replace '^urn:ietf:params:oauth:grant-type:', '')) }
    }
    $label = $hints -join ' + '
    if ($Response) {
        $code = [int]$Response.StatusCode
        $reason = [string](Get-MdcField $Response 'Reason')
        if (-not $reason -and $script:MdcReasons.ContainsKey($code)) { $reason = $script:MdcReasons[$code] }
        Add-MdcTraceEntry -Method $Request.Method.Method -Url $Request.RequestUri.AbsoluteUri -Request $requestText -Response (Get-MdcTraceResponseText -Response $Response) `
            -StatusCode $code -Reason $reason -DurationMs $DurationMs -Note $Note -Collapse $Collapse -Label $label
    }
    else {
        Add-MdcTraceEntry -Method $Request.Method.Method -Url $Request.RequestUri.AbsoluteUri -Request $requestText -Response "No response: $Failure" `
            -StatusCode $null -DurationMs $DurationMs -Note $Note -Label $label
    }
}

function Complete-MdcTraceStep {
    <# Attaches the exchanges recorded since the previous check to this check. Returns their numbers. #>
    param([Parameter(Mandatory = $true)][int]$Step, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $script:MdcTrace) { return @() }
    $ids = foreach ($entry in $script:MdcTrace) {
        if ($null -eq $entry.Step) { $entry.Step = $Step; $entry.StepName = $Name; $entry.Sequence }
    }
    return @($ids)
}

# SIG # Begin signature block
# MIIghQYJKoZIhvcNAQcCoIIgdjCCIHICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDZSAptS+KsH72x
# 4dSiRy6MkM/36MygMjdnkRgJnp8PsKCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# wZislcdCZuS6MYISbDCCEmgCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCAWgAin3gRU
# Yoi5CsujdYozANobPxwj8UhtVh34NBNisTANBgkqhkiG9w0BAQEFAASCAgCXI3ga
# TfjrfoFD/9i7TBuHGujq4MnRdDLGj5mhDm75wTvb++olIKfgJFKSYN9zALN6jsLk
# 6AEkOgWsuXhUNVUeu7R6bwQjrYhgS+D9SyZntCfyxk5jT5o42sBuuIaAWxOowF4T
# afPQoXeCURbDe8IBsPP/PMGWIHM7cVWtDkIFNz4gNKX4fjIX3YrZUKRdmkr3P5B/
# 9mmc6XbDMIJaiuA1fdinHbhypRSitVTwLsTCYTosjNW7SZz2TUpmQLhIpx6sS3JR
# XSn902z6dTc6lfxdyYbX53PdWXrx2pNpBP2sgRU40rFwwsKFuTH0FW8k2KI+epDP
# ooErP33NM+U4l6UeEBZZSQI/QiCEKcucjsCdZb7XDL7znHWqYkVC3llmMb6pEGEB
# Ta6U2XxmGWKMQBzhCOxOennUqgMLOWQ5knjL+5J4mMU/TOvDbRd8WhETlNrOoV+i
# mS6/CGl8OpB1w1ftJmq0t2dgz/jo73hG9Iqy7wb9wwWPs337Uchec/ogYLCa0Upb
# 0zQtzAtOBqZaOPIf750mLCequ44mjPSr92NUFYk/bV09zqg8yHckH187RJi1sJIr
# skEhYmTjVnnZAwhUE1g4GttR1ZPacxTCeWn3QF95vd7NcWx2XYSyp0aqhAGhu8N/
# 7lRozgFWwrl4vHp87FhnNujO0EeVxyN0u6MZ8qGCDykwgg8lBgorBgEEAYI3AwMB
# MYIPFTCCDxEGCSqGSIb3DQEHAqCCDwIwgg7+AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIHYgAF5dIH/8afNnOUZqL/qMWCi6Fmsmz1+J2LGjyNwkAggN2JBsEf4U
# 5xgPMjAyNjEwMTQxMTM2MTRaMAMCAQECEDe7G0wXhYhTuqB4+uNvhZSgggwAMIIE
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
# WDCCAlQCAQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhtsXfHAwaBg
# DjgwCwYJYIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDExMzYxNFowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIFjItQkURw95
# XIkp8RFMb3W7vkZ8MZa0y/XSeqUj0rwTMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEcwRQIhAKZPnrL7FuWeB1v8deGIKb+oHQLFk6JPDw0C87xCMwMDAiA2CI211Ljn
# 2//tQ3VQNim+IxWBd7n073PafV1TGAYHbg==
# SIG # End signature block
