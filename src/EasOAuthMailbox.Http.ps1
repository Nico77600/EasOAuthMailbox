<#
.SYNOPSIS
    EAS OAuth Mailbox - HTTP layer and trace of the exchanges (dot-sourced by EasOAuthMailbox.psm1).

.DESCRIPTION
    Every HTTP request of the tool (ActiveSync, Autodiscover, AD FS) goes through Invoke-EomHttp:
      - Send-EomHttpRequest sends it. It is the only function that touches the network; the tests
        and the documentation tool replace it with the simulator.
      - The exchange is added to the trace of the run: the request sent and the response received
        as text (start line, headers, body), WBXML bodies decoded to XML, JSON indented, HTML pages
        summarised.
    Add-EomStep attaches the exchanges recorded since the previous check to that check: the report
    shows, for every check, what the client sent and what it received.

    Secrets never reach the trace: access, refresh and ID tokens, device and authorization codes,
    cookies are replaced by their length. The forged token of the Discovery check is shown: it is
    not a secret. Mailbox data (folder names, addresses, Inbox headers) is shown like in the rest
    of the report.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
#>

# Exchanges of the current run (List of objects), $null outside a run. Stage: current stage.
$script:EomTrace = $null
$script:EomTraceStage = $null
$script:EomTraceLimit = 24000
$script:EomTraceSecrets = @('access_token', 'refresh_token', 'id_token', 'device_code', 'code', 'client_secret', 'code_verifier', 'assertion', 'client_assertion', 'password')
$script:EomReasons = @{
    200 = 'OK'; 301 = 'Moved Permanently'; 302 = 'Found'; 303 = 'See Other'; 307 = 'Temporary Redirect'; 308 = 'Permanent Redirect'
    400 = 'Bad Request'; 401 = 'Unauthorized'; 403 = 'Forbidden'; 404 = 'Not Found'; 449 = 'Retry With'; 451 = 'Redirect'
    500 = 'Internal Server Error'; 502 = 'Bad Gateway'; 503 = 'Service Unavailable'; 504 = 'Gateway Timeout'
}

function Send-EomHttpRequest {
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

function Invoke-EomHttp {
    <#
        Sends a request (Send-EomHttpRequest) and adds the exchange to the trace. Collapse: requests
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
        $response = Send-EomHttpRequest -HttpClient $HttpClient -Request $Request
    }
    catch {
        $failure = $_.Exception
        while ($failure.InnerException) { $failure = $failure.InnerException }
        Add-EomTraceExchange -Request $Request -RequestBody $body -Failure $failure.Message -DurationMs $clock.ElapsedMilliseconds -Note $Note
        throw
    }
    Add-EomTraceExchange -Request $Request -RequestBody $body -Response $response -DurationMs $clock.ElapsedMilliseconds -Note $Note -Collapse $Collapse
    return $response
}

function Protect-EomHeaderValue {
    <# Header value as written to the trace: tokens and cookies replaced by their length. #>
    param([Parameter(Mandatory = $true)][string]$Name, [AllowEmptyString()][string]$Value)

    if ($Name -ieq 'Authorization') {
        $parts = $Value.Trim().Split(' ', 2)
        if ($parts.Count -lt 2 -or [string]::IsNullOrWhiteSpace($parts[1])) { return $Value }
        if ($parts[1] -eq $script:InvalidToken) { return $Value }
        return "$($parts[0]) <access token: $($parts[1].Length) characters, never written>"
    }
    if ($Name -ieq 'Set-Cookie') { return [regex]::Replace($Value, '^\s*([^=;]+)=[^;]*', '$1=<hidden>') }
    if ($Name -ieq 'Cookie') { return [regex]::Replace($Value, '([^=;\s]+)=[^;]*', '$1=<hidden>') }
    return $Value
}

function Limit-EomTraceText {
    param([AllowEmptyString()][string]$Text, [int]$Limit = $script:EomTraceLimit)
    if ($Text.Length -le $Limit) { return $Text }
    return $Text.Substring(0, $Limit) + "`n... (cut: $($Text.Length) characters in total)"
}

function Format-EomWbxmlXml {
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

function Format-EomFormBody {
    <# application/x-www-form-urlencoded body, one field per line, URL-decoded, secrets masked. #>
    param([AllowEmptyString()][string]$Text)

    $lines = foreach ($pair in $Text.Split('&')) {
        if (-not $pair) { continue }
        $name, $value = $pair.Split('=', 2)
        $name = [Uri]::UnescapeDataString($name.Replace('+', ' '))
        $value = if ($null -ne $value) { [Uri]::UnescapeDataString($value.Replace('+', ' ')) } else { '' }
        if ($name -in $script:EomTraceSecrets) { $value = "<$($value.Length) characters, never written>" }
        "$name=$value"
    }
    return "# form fields, one per line, URL-decoded`n" + (@($lines) -join "`n")
}

function Format-EomJsonBody {
    <# JSON body indented, secrets masked. Throws if the text is not JSON. #>
    param([Parameter(Mandatory = $true)][string]$Text)

    $value = $Text | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    if ($value -is [System.Collections.IDictionary]) {
        foreach ($key in @($value.Keys)) {
            if ($key -in $script:EomTraceSecrets -and $null -ne $value[$key]) { $value[$key] = "<$($key): $(([string]$value[$key]).Length) characters, never written>" }
        }
    }
    return (ConvertTo-Json -InputObject $value -Depth 8)
}

function Format-EomHtmlSummary {
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

function Format-EomTraceBody {
    <# Body of a request or a response as text: WBXML decoded, form and JSON readable, HTML summarised. #>
    param([AllowNull()][byte[]]$Body, [string]$ContentType)

    if ($null -eq $Body -or $Body.Length -eq 0) { return '' }
    $type = ([string]$ContentType).ToLowerInvariant()
    if ($type -like '*vnd.ms-sync.wbxml*' -or ($Body.Length -ge 4 -and $Body[0] -eq 3 -and $Body[1] -eq 1 -and $Body[2] -eq 0x6A)) {
        try {
            return "# WBXML, $($Body.Length) bytes, decoded`n" + (Format-EomWbxmlXml -Document (ConvertFrom-EasWbxml -Data $Body))
        }
        catch {
            $hex = ($Body | Select-Object -First 64 | ForEach-Object { $_.ToString('X2') }) -join ' '
            return "# WBXML, $($Body.Length) bytes, not decodable ($($_.Exception.Message))`n$hex"
        }
    }
    $text = [Text.Encoding]::UTF8.GetString($Body)
    if ($type -like '*x-www-form-urlencoded*') { return Format-EomFormBody $text }
    if ($type -like '*json*' -or $text.TrimStart().StartsWith('{')) {
        try { return Format-EomJsonBody $text } catch { }
    }
    if ($type -like '*html*' -or $text -match '^\s*<(!doctype|html)') { return Format-EomHtmlSummary -Text $text -Length $Body.Length }
    return Limit-EomTraceText $text 4000
}

function Get-EomTraceRequestText {
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
            [void]$lines.Add("$($header.Key): $(Protect-EomHeaderValue -Name $header.Key -Value $value)")
        }
    }
    if ($Request.Content) { [void]$lines.Add("Content-Length: $($Body.Length)") }
    $text = $lines -join "`n"
    $bodyText = Format-EomTraceBody -Body $Body -ContentType $contentType
    if (-not $bodyText -and $uri.Query.Length -gt 1 -and ($uri.Query.Split('&').Count -ge 3)) {
        # Long query strings (AD FS authorization request) are easier to read decoded, one parameter per line.
        $bodyText = (Format-EomFormBody $uri.Query.TrimStart('?')).Replace('# form fields, one per line', '# query parameters, one per line')
    }
    if ($bodyText) { $text += "`n`n" + $bodyText }
    return Limit-EomTraceText $text
}

function Get-EomTraceResponseText {
    <# The response as received: status line, headers (cookies masked), blank line, body. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Response)

    $code = [int]$Response.StatusCode
    $reason = [string](Get-EomField $Response 'Reason')
    if (-not $reason) { $reason = if ($script:EomReasons.ContainsKey($code)) { $script:EomReasons[$code] } else { '' } }
    $lines = [Collections.Generic.List[string]]::new()
    [void]$lines.Add("HTTP/1.1 $code $reason".TrimEnd())
    $headerLines = @(Get-EomField $Response 'HeaderLines')
    if (-not $headerLines.Count) {
        # Response without the raw header lines (simulator): its headers, one line per challenge.
        $headerLines = @(foreach ($c in @(Get-EomField $Response 'Challenges')) { "WWW-Authenticate: $c" })
        $headers = Get-EomField $Response 'Headers'
        if ($headers) { $headerLines += @(foreach ($key in ($headers.Keys | Sort-Object)) { if ($key -ine 'WWW-Authenticate') { "$($key): $($headers[$key])" } }) }
    }
    $contentType = $null
    foreach ($line in $headerLines) {
        $name, $value = ([string]$line).Split(':', 2)
        $value = ([string]$value).Trim()
        if ($name -ieq 'Content-Type') { $contentType = $value }
        [void]$lines.Add("$($name): $(Protect-EomHeaderValue -Name $name -Value $value)")
    }
    $text = $lines -join "`n"
    $bodyText = Format-EomTraceBody -Body ([byte[]](Get-EomField $Response 'Body')) -ContentType $contentType
    if ($bodyText) { $text += "`n`n" + $bodyText }
    return Limit-EomTraceText $text
}

function Add-EomTraceEntry {
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

    if ($null -eq $script:EomTrace) { return }
    if ($Collapse -and $script:EomTrace.Count) {
        $last = $script:EomTrace[$script:EomTrace.Count - 1]
        if ($last.Collapse -eq $Collapse -and $null -eq $last.Step -and $last.StatusCode -eq $StatusCode -and $last.Response -eq $Response) {
            $last.Repeated++
            $last.Note = "Sent $($last.Repeated) times with the same answer (polling while the user signs in): only the first one is shown."
            return
        }
    }
    $entry = [pscustomobject]@{
        Sequence     = $script:EomTrace.Count + 1
        TimestampUtc = [DateTimeOffset]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
        Stage        = $script:EomTraceStage
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
    $script:EomTrace.Add($entry)
    $status = if ($null -ne $StatusCode) { "$StatusCode $Reason".TrimEnd() } else { 'no response' }
    Write-EomLog 'INFO' ("HTTP #{0} {1} {2} -> {3} ({4} ms)" -f $entry.Sequence, $Method, $Url, $status, $entry.DurationMs)
}

function Add-EomTraceExchange {
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpRequestMessage]$Request,
        [byte[]]$RequestBody,
        [pscustomobject]$Response,
        [string]$Failure,
        [long]$DurationMs,
        [string]$Note,
        [string]$Collapse
    )

    if ($null -eq $script:EomTrace) { return }
    $requestText = Get-EomTraceRequestText -Request $Request -Body $RequestBody
    # What makes this request different from its neighbours: the credentials sent, the user identity.
    $hints = [Collections.Generic.List[string]]::new()
    $auth = $Request.Headers.Authorization
    if ($Request.RequestUri.AbsolutePath -match 'Microsoft-Server-ActiveSync') {
        if (-not $auth) { $hints.Add('no credentials') }
        elseif (-not $auth.Parameter) { $hints.Add("empty $($auth.Scheme) header") }
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
        $reason = [string](Get-EomField $Response 'Reason')
        if (-not $reason -and $script:EomReasons.ContainsKey($code)) { $reason = $script:EomReasons[$code] }
        Add-EomTraceEntry -Method $Request.Method.Method -Url $Request.RequestUri.AbsoluteUri -Request $requestText -Response (Get-EomTraceResponseText -Response $Response) `
            -StatusCode $code -Reason $reason -DurationMs $DurationMs -Note $Note -Collapse $Collapse -Label $label
    }
    else {
        Add-EomTraceEntry -Method $Request.Method.Method -Url $Request.RequestUri.AbsoluteUri -Request $requestText -Response "No response: $Failure" `
            -StatusCode $null -DurationMs $DurationMs -Note $Note -Label $label
    }
}

function Complete-EomTraceStep {
    <# Attaches the exchanges recorded since the previous check to this check. Returns their numbers. #>
    param([Parameter(Mandatory = $true)][int]$Step, [Parameter(Mandatory = $true)][string]$Name)

    if ($null -eq $script:EomTrace) { return @() }
    $ids = foreach ($entry in $script:EomTrace) {
        if ($null -eq $entry.Step) { $entry.Step = $Step; $entry.StepName = $Name; $entry.Sequence }
    }
    return @($ids)
}
