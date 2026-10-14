<#
.SYNOPSIS
    Mobile Device Client for Exchange - the sign-in window (dot-sourced by MobileDeviceClient.psm1).

.DESCRIPTION
    The OAuth sign-in in a window, like a mail app: Microsoft Edge (or Google Chrome) opens the
    authorization page of AD FS or Entra ID in an app window with a temporary profile - no account
    of the workstation, no cookie, no extension - and the user signs in there: password, MFA,
    Conditional Access. The tool drives the window through the DevTools protocol of the browser,
    on the loopback interface and a port chosen by the browser, and catches the redirect that
    carries the authorization code before the browser follows it (a 302 to urn:ietf:wg:oauth:2.0:oob
    for AD FS, a navigation to the native-client page or to com.apple.Preferences:// for Entra ID).
    The window then shows a completion page and closes; the profile folder is deleted.

    During the sign-in only the browser talks to AD FS or Entra ID: those pages are not in the
    trace of the run. The tool records what it opened and the redirect it caught (code masked),
    then exchanges the code itself (traced).

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.0
#>

# Page shown in the window once the code is caught, before it closes.
$script:MdcSignInDonePage = '<!DOCTYPE html><html><head><meta charset="utf-8"><title>Mobile Device Client for Exchange - sign-in complete</title><style>' +
    'body{font:15px "Segoe UI",sans-serif;background:#f7f4ef;color:#242424;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}' +
    'div{background:#fff;border:1px solid #dedede;border-top:4px solid #b11f4b;border-radius:12px;padding:26px 30px;max-width:360px}' +
    'h1{font-size:18px;margin:0 0 8px}p{margin:0;color:#5c5c5c;line-height:1.5}</style></head><body><div><h1>Sign-in complete</h1>' +
    '<p>Mobile Device Client for Exchange received the authorization code and goes on with the test. This window closes by itself.</p></div></body></html>'

# Text of the page, kept when the window shows an AD FS or Entra ID error (reported if the window is closed).
$script:MdcSignInErrorProbe = '(() => { const t = (document.body && document.body.innerText) || ""; const m = t.match(/(AADSTS\d+|MSIS\d{4})[^\n]{0,240}/); return m ? m[0] : ""; })()'

function Find-MdcBrowser {
    <# Microsoft Edge, else Google Chrome (both speak the DevTools protocol): name and path, or $null. -All: every one installed. #>
    param([switch]$All)
    if (-not $IsWindows) { return $null }
    $found = [Collections.Generic.List[object]]::new()
    $candidates = @(
        @{ Name = 'Microsoft Edge'; Exe = 'msedge.exe'; Paths = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe", "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe") }
        @{ Name = 'Google Chrome'; Exe = 'chrome.exe'; Paths = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") }
    )
    foreach ($candidate in $candidates) {
        $paths = [Collections.Generic.List[string]]::new()
        foreach ($hive in 'HKLM:', 'HKCU:') {
            $item = Get-ItemProperty -LiteralPath "$hive\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$($candidate.Exe)" -ErrorAction SilentlyContinue
            $value = [string](Get-MdcField $item '(default)')
            if ($value) { $paths.Add($value.Trim('"')) }
        }
        foreach ($path in $candidate.Paths) { $paths.Add($path) }
        $path = $paths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
        if ($path) {
            $browser = [pscustomobject]@{ Name = $candidate.Name; Path = $path }
            if (-not $All) { return $browser }
            $found.Add($browser)
        }
    }
    if ($All) { return $found.ToArray() }
    return $null
}

function Test-MdcBrowserPolicyBlock {
    <#
        An organisation policy forbids the DevTools protocol in this browser (RemoteDebuggingAllowed = 0,
        machine or user): the sign-in window cannot catch the answer of the server with it.
    #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Browser)

    $key = if ($Browser.Name -eq 'Google Chrome') { 'SOFTWARE\Policies\Google\Chrome' } else { 'SOFTWARE\Policies\Microsoft\Edge' }
    foreach ($hive in 'HKLM:', 'HKCU:') {
        $value = Get-MdcField (Get-ItemProperty -LiteralPath "$hive\$key" -ErrorAction SilentlyContinue) 'RemoteDebuggingAllowed'
        if ($null -ne $value -and "$value" -eq '0') { return $true }
    }
    return $false
}

function Test-MdcDesktopSession {
    <# A window can be shown: Windows and an interactive desktop - not a service, a task as SYSTEM or an SSH session (session 0). #>
    if (-not $IsWindows -or -not [Environment]::UserInteractive) { return $false }
    try { return (Get-Process -Id $PID -ErrorAction Stop).SessionId -ne 0 } catch { return $false }
}

function Get-MdcSignInMode {
    <#
        How this run signs in with OAuth: 'Window' (authorization code in the sign-in window) or
        'DeviceCode' (code typed on any device). Test.SignIn Auto: the window when this session can
        show one, the device code otherwise (Reason says why). Window: throws when it cannot.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    $wanted = if ([string]$Configuration.SignIn) { [string]$Configuration.SignIn } else { 'Auto' }
    if ($wanted -eq 'DeviceCode') { return [pscustomobject]@{ Mode = 'DeviceCode'; Browser = $null; Reason = $null } }
    $why = $null
    $browser = $null
    if (-not (Test-MdcDesktopSession)) { $why = 'no interactive desktop in this session (service, scheduled task, SSH)' }
    else {
        $browsers = @(Find-MdcBrowser -All | Where-Object { $_ })
        $browser = $browsers | Where-Object { -not (Test-MdcBrowserPolicyBlock -Browser $_) } | Select-Object -First 1
        if (-not $browsers) { $why = 'neither Microsoft Edge nor Google Chrome is installed' }
        elseif (-not $browser) { $why = "an organisation policy forbids the DevTools protocol in $(@($browsers.Name) -join ' and ') (RemoteDebuggingAllowed = 0)" }
    }
    if ($why -and $wanted -eq 'Window') { throw "The sign-in window cannot be opened: $why. Run with -SignIn DeviceCode." }
    if ($why) { return [pscustomobject]@{ Mode = 'DeviceCode'; Browser = $null; Reason = $why } }
    [pscustomobject]@{ Mode = 'Window'; Browser = $browser; Reason = $null }
}

function Test-MdcRedirectMatch {
    <#
        The URL is the redirect URI with the answer of the server (?code=..., ?error=...). Compared
        without case and final '/': Entra ID answers com.apple.preferences://oauth-redirect/?code=...
        to com.apple.Preferences://oauth-redirect.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Url, [Parameter(Mandatory = $true)][string]$RedirectUri)

    if ([string]::IsNullOrEmpty($Url)) { return $false }
    $prefix = $RedirectUri.TrimEnd('/')
    if (-not $Url.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $rest = $Url.Substring($prefix.Length)
    return ($rest.Length -eq 0 -or $rest.Substring(0, 1) -in '/', '?', '#')
}

function Send-MdcDevTools {
    <# Sends one DevTools command (no wait). Returns its id. #>
    param([Parameter(Mandatory = $true)][hashtable]$Session, [Parameter(Mandatory = $true)][string]$Method, [hashtable]$Params = @{}, [string]$SessionId)

    $Session.NextId++
    $message = [ordered]@{ id = $Session.NextId; method = $Method; params = $Params }
    if ($SessionId) { $message.sessionId = $SessionId }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($message | ConvertTo-Json -Depth 12 -Compress))
    [void]$Session.Socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    return $Session.NextId
}

function Receive-MdcDevTools {
    <# Next message of the browser (hashtable), or $null after WaitMs without one. Throws when the browser has gone. #>
    param([Parameter(Mandatory = $true)][hashtable]$Session, [int]$WaitMs = 250)

    if ($Session.Queue.Count) { return $Session.Queue.Dequeue() }
    while ($true) {
        if (-not $Session.Pending) {
            $Session.Pending = $Session.Socket.ReceiveAsync([ArraySegment[byte]]::new($Session.Buffer), [Threading.CancellationToken]::None)
        }
        try { if (-not $Session.Pending.Wait($WaitMs)) { return $null } }
        catch { throw [InvalidOperationException]::new('The sign-in window was closed before the sign-in was completed.') }
        $result = $Session.Pending.Result
        $Session.Pending = $null
        if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw [InvalidOperationException]::new('The sign-in window was closed before the sign-in was completed.') }
        $Session.Stream.Write($Session.Buffer, 0, $result.Count)
        if ($result.EndOfMessage) {
            $text = [Text.Encoding]::UTF8.GetString($Session.Stream.ToArray())
            $Session.Stream.SetLength(0)
            return ($text | ConvertFrom-Json -AsHashtable -Depth 64)
        }
    }
}

function Invoke-MdcDevTools {
    <# Sends a DevTools command and waits for its answer (events received meanwhile are kept in order). #>
    param([Parameter(Mandatory = $true)][hashtable]$Session, [Parameter(Mandatory = $true)][string]$Method, [hashtable]$Params = @{}, [string]$SessionId, [int]$TimeoutSeconds = 15)

    $id = Send-MdcDevTools -Session $Session -Method $Method -Params $Params -SessionId $SessionId
    $until = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    $held = [Collections.Generic.List[object]]::new()
    try {
        while ([DateTimeOffset]::UtcNow -lt $until) {
            Invoke-MdcUiPump
            $message = Receive-MdcDevTools -Session $Session -WaitMs 200
            if ($null -eq $message) { continue }
            if ($message['id'] -eq $id) {
                if ($message['error']) { throw "The browser refused $($Method): $($message['error']['message'])" }
                return $message['result']
            }
            $held.Add($message)
        }
        throw "The browser did not answer $Method within $TimeoutSeconds seconds."
    }
    finally {
        foreach ($m in $held) { $Session.Queue.Enqueue($m) }
    }
}

function Get-MdcPausedRedirect {
    <# The redirect URL with the code, when a paused request or response is the answer of the server; $null otherwise. #>
    param([Parameter(Mandatory = $true)][System.Collections.IDictionary]$Params, [Parameter(Mandatory = $true)][string]$RedirectUri)

    $status = $Params['responseStatusCode']
    if ($null -eq $status) {
        $url = [string]$Params['request']['url']
        if (Test-MdcRedirectMatch -Url $url -RedirectUri $RedirectUri) { return $url }
        return $null
    }
    if ([int]$status -in 301, 302, 303, 307, 308) {
        $location = @($Params['responseHeaders'] | Where-Object { $_ -and [string]$_['name'] -ieq 'location' } | ForEach-Object { [string]$_['value'] }) | Select-Object -First 1
        if (Test-MdcRedirectMatch -Url $location -RedirectUri $RedirectUri) { return $location }
    }
    return $null
}

function Invoke-MdcBrowserAuthorization {
    <#
        Opens Url (an authorization request, response_type=code) in the sign-in window and returns the
        redirect URL caught - RedirectUri with code and state, or with error. Throws when the window is
        closed, on timeout or cancel. The browser is always closed and its temporary profile deleted.
        When the window cannot even start (the browser closes at once, or does not open its DevTools
        endpoint - an organisation policy can forbid it: RemoteDebuggingAllowed), it throws a
        NotSupportedException: the caller can then use the device code.
    #>
    param(
        [Parameter(Mandatory = $true)][pscustomobject]$Browser,
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$RedirectUri,
        [int]$TimeoutSeconds = 600,
        [int]$StartTimeoutSeconds = 20
    )

    # Profiles left by a run that was killed (the browser holds them while it runs): deleted when old.
    Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'MobileDeviceClient-signin-*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddHours(-1) } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    $profileDir = Join-Path ([IO.Path]::GetTempPath()) ('MobileDeviceClient-signin-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    [void][IO.Directory]::CreateDirectory($profileDir)
    # The window starts on a page of its own, found again among the pages the browser opens (an organisation
    # policy can add a new-tab or start page): the others are closed.
    $startHtml = "<!DOCTYPE html><html><head><meta charset=""utf-8""><title>Mobile Device Client for Exchange - sign-in</title></head><body style=""font:15px 'Segoe UI',sans-serif;color:#5c5c5c;padding:24px"">Opening the sign-in page...<!-- $([guid]::NewGuid().ToString('N')) --></body></html>"
    $startPage = 'data:text/html;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($startHtml))
    # App window (no address bar), new profile: no workstation account, no single sign-on, no extension.
    $arguments = @(
        "--user-data-dir=`"$profileDir`"", '--remote-debugging-port=0', '--no-first-run', '--no-default-browser-check',
        '--disable-sync', '--disable-extensions', '--window-size=520,760', "--app=$startPage"
    )
    $session = @{
        Socket = $null; NextId = 0; Buffer = [byte[]]::new(65536); Stream = [IO.MemoryStream]::new()
        Pending = $null; Queue = [Collections.Generic.Queue[object]]::new()
    }
    $process = $null
    try {
        # Start: anything that fails here means the window cannot be used on this computer (NotSupportedException).
        try {
            $process = Start-Process -FilePath $Browser.Path -ArgumentList $arguments -PassThru -ErrorAction Stop
            # The browser writes the port it listens on (loopback only) and the path of its DevTools endpoint.
            $portFile = Join-Path $profileDir 'DevToolsActivePort'
            $until = [DateTimeOffset]::UtcNow.AddSeconds($StartTimeoutSeconds)
            $lines = @()
            while ($lines.Count -lt 2) {
                if ($process.HasExited -and -not (Test-Path -LiteralPath $portFile)) { throw "$($Browser.Name) closed at once (exit code $($process.ExitCode))." }
                if ([DateTimeOffset]::UtcNow -gt $until) { throw "$($Browser.Name) did not open its DevTools endpoint within $StartTimeoutSeconds seconds: an organisation policy can forbid it (RemoteDebuggingAllowed)." }
                Wait-MdcSeconds 0.2
                if (Test-Path -LiteralPath $portFile) { $lines = @(Get-Content -LiteralPath $portFile -ErrorAction SilentlyContinue | Where-Object { $_ }) }
            }
            $session.Socket = [Net.WebSockets.ClientWebSocket]::new()
            [void]$session.Socket.ConnectAsync([Uri]"ws://127.0.0.1:$($lines[0].Trim())$($lines[1].Trim())", [Threading.CancellationToken]::None).GetAwaiter().GetResult()

            $target = $null
            $until = [DateTimeOffset]::UtcNow.AddSeconds(15)
            while (-not $target) {
                $pages = @((Invoke-MdcDevTools -Session $session -Method 'Target.getTargets')['targetInfos'] | Where-Object { $_['type'] -eq 'page' })
                $target = $pages | Where-Object { [string]$_['url'] -eq $startPage } | Select-Object -First 1
                if ($target) { break }
                if ([DateTimeOffset]::UtcNow -gt $until) { throw "$($Browser.Name) did not show the sign-in window (pages: $(@($pages | ForEach-Object { [string]$_['url'] -replace '^(data:[^,]{0,20}).*', '$1...' }) -join ', '))." }
                Wait-MdcSeconds 0.2
            }
            foreach ($other in @($pages | Where-Object { $_['targetId'] -ne $target['targetId'] })) {
                [void](Send-MdcDevTools -Session $session -Method 'Target.closeTarget' -Params @{ targetId = [string]$other['targetId'] })
            }
            $sessionId = [string](Invoke-MdcDevTools -Session $session -Method 'Target.attachToTarget' -Params @{ targetId = $target['targetId']; flatten = $true })['sessionId']
        }
        catch {
            if ($_.Exception.Message -eq 'Cancelled by the operator.') { throw }
            throw [NotSupportedException]::new("The sign-in window could not start: $($_.Exception.Message)", $_.Exception)
        }
        # The answer comes back either as a redirect (AD FS: 302 to urn:ietf:wg:oauth:2.0:oob) or as a navigation
        # (Entra ID: native-client page or com.apple.Preferences://): documents paused at the response, the
        # redirect URI paused before it is requested, and every request seen.
        $patterns = [Collections.Generic.List[object]]::new()
        $patterns.Add(@{ urlPattern = '*'; resourceType = 'Document'; requestStage = 'Response' })
        if ($RedirectUri -match '^https?://') { $patterns.Add(@{ urlPattern = "$RedirectUri*"; requestStage = 'Request' }) }
        [void](Invoke-MdcDevTools -Session $session -Method 'Fetch.enable' -Params @{ patterns = @($patterns) } -SessionId $sessionId)
        [void](Invoke-MdcDevTools -Session $session -Method 'Network.enable' -SessionId $sessionId)
        [void](Invoke-MdcDevTools -Session $session -Method 'Page.enable' -SessionId $sessionId)
        # Not awaited: the answer of Page.navigate waits for the paused response handled below.
        [void](Send-MdcDevTools -Session $session -Method 'Page.navigate' -Params @{ url = $Url } -SessionId $sessionId)

        $donePage = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:MdcSignInDonePage))
        $fulfil = { param([string]$RequestId) try { [void](Send-MdcDevTools -Session $session -Method 'Fetch.fulfillRequest' -SessionId $sessionId -Params @{ requestId = $RequestId; responseCode = 200; responseHeaders = @(@{ name = 'Content-Type'; value = 'text/html; charset=utf-8' }); body = $donePage }) } catch { } }
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
        $captured = $null
        $lastError = $null
        $probes = @{}
        $showDone = $false
        try {
            while (-not $captured) {
                if ([DateTimeOffset]::UtcNow -gt $deadline) { throw "No sign-in in the window within $(Format-MdcDuration $TimeoutSeconds) (Test.OAuthPollTimeoutSeconds)." }
                Invoke-MdcUiPump
                Assert-MdcNotCancelled
                $message = Receive-MdcDevTools -Session $session -WaitMs 250
                if ($null -eq $message) { continue }
                if ($null -ne $message['id']) {
                    if ($probes.ContainsKey([int]$message['id'])) {
                        $text = [string]$message['result']['result']['value']
                        if ($text) { $lastError = $text }
                    }
                    continue
                }
                $params = $message['params']
                switch ([string]$message['method']) {
                    'Fetch.requestPaused' {
                        $hit = Get-MdcPausedRedirect -Params $params -RedirectUri $RedirectUri
                        if ($hit) { $captured = $hit; & $fulfil ([string]$params['requestId']) }
                        else { [void](Send-MdcDevTools -Session $session -Method 'Fetch.continueRequest' -Params @{ requestId = [string]$params['requestId'] } -SessionId $sessionId) }
                    }
                    'Network.requestWillBeSent' {
                        $url = [string]$params['request']['url']
                        if (Test-MdcRedirectMatch -Url $url -RedirectUri $RedirectUri) { $captured = $url; $showDone = $true }
                    }
                    'Page.loadEventFired' {
                        $id = Send-MdcDevTools -Session $session -Method 'Runtime.evaluate' -Params @{ expression = $script:MdcSignInErrorProbe; returnByValue = $true } -SessionId $sessionId
                        $probes[[int]$id] = $true
                    }
                    'Target.detachedFromTarget' {
                        if ([string]$params['sessionId'] -eq $sessionId) { throw [InvalidOperationException]::new('The sign-in window was closed before the sign-in was completed.') }
                    }
                    'Inspector.detached' {
                        throw [InvalidOperationException]::new('The sign-in window was closed before the sign-in was completed.')
                    }
                }
            }
        }
        catch {
            $why = $_.Exception.Message
            if ($lastError) { $why += " The window showed: $lastError" }
            throw $why
        }

        # A navigation the browser cannot follow (custom scheme): show the completion page instead.
        # The code is caught: from here the window is only cosmetic, a failure of the browser is ignored.
        try {
            if ($showDone) { [void](Send-MdcDevTools -Session $session -Method 'Page.navigate' -Params @{ url = "data:text/html;base64,$donePage" } -SessionId $sessionId) }
            # Let the completion page show; requests still paused are answered so the window does not hang.
            $until = [DateTimeOffset]::UtcNow.AddSeconds(1.5)
            while ([DateTimeOffset]::UtcNow -lt $until) {
                Invoke-MdcUiPump
                $message = Receive-MdcDevTools -Session $session -WaitMs 150
                if ($message -and [string]$message['method'] -eq 'Fetch.requestPaused') {
                    $requestId = [string]$message['params']['requestId']
                    if (Get-MdcPausedRedirect -Params $message['params'] -RedirectUri $RedirectUri) { & $fulfil $requestId }
                    else { [void](Send-MdcDevTools -Session $session -Method 'Fetch.continueRequest' -Params @{ requestId = $requestId } -SessionId $sessionId) }
                }
            }
        }
        catch { Write-MdcLog 'INFO' "Sign-in window: $($_.Exception.Message) (after the code was received)." }
        return $captured
    }
    finally {
        if ($session.Socket -and $session.Socket.State -eq [Net.WebSockets.WebSocketState]::Open) {
            try { [void](Send-MdcDevTools -Session $session -Method 'Browser.close') } catch { }
        }
        if ($process) {
            $until = [DateTimeOffset]::UtcNow.AddSeconds(5)
            while (-not $process.HasExited -and [DateTimeOffset]::UtcNow -lt $until) { Start-Sleep -Milliseconds 100 }
            if (-not $process.HasExited) { try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { } }
        }
        if ($session.Socket) { $session.Socket.Dispose() }
        $session.Stream.Dispose()
        # The profile holds the cookies of the sign-in: it is deleted (the browser may hold it for a moment).
        for ($attempt = 0; $attempt -lt 20 -and (Test-Path -LiteralPath $profileDir); $attempt++) {
            try { Remove-Item -LiteralPath $profileDir -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 250 }
        }
        if (Test-Path -LiteralPath $profileDir) { Write-MdcLog 'WARN' "The temporary profile of the sign-in window could not be deleted: $profileDir" }
    }
}

# SIG # Begin signature block
# MIIghQYJKoZIhvcNAQcCoIIgdjCCIHICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDcR7OAqziIuwW+
# NEM8I/NWCBlwKLdjuqr0a8wiG6NBgqCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCCNkpXMlAX5
# KjBiTQ/iTW0hhFTey0qGTd69+kYC//0pSDANBgkqhkiG9w0BAQEFAASCAgCDz9xD
# roeWXW2tkB09To0O/DBRyfG379+MfyltiYixj53CQtCQtnWccYeAWTxm6z3KLG9y
# 7IXyTlI/FyrRqJbFrML8fd5FophhiqjtdH6OMMckOmk4NeIpsTAzepAzsT0zREpH
# mBgeBBejfnrXrDSQvBvB43rclRnABgnLw4ly9DkJ1HUvpebRtx+m3N5KoeWmqfum
# /HRzIXCg3n+LrN8zSbVinY3h5Z5gCeyqx3MEmklXOCDOmlVmBzdJ10JYN5k/tolx
# 4yEejiLlC6vZaXXOTPuSUgwgF0e7GdpUEtb0EDCosfoPTRfmgKOkHlJTWdleTUEd
# Sw/DSK02ndGMyngC1lobDu1CUF8c6cEABv4MNuV+Ftgxc1frZuJy+soTTUu737K2
# UpSjSzTXgrD7l7hK040ssPzwj1WM9UfO7OShytoUNYovKYu5KvjwjKLUu1tAX/jr
# +ATK1pJMIYzYTMpwrPamhEuFoJr/KyuvNd4Aq8x30CX5fbVByW9mETFFfR2emneW
# iEyZLbxe6Lzm3zI6Nm3A2cF4cWI9snjk2aok83HoXoA1PVbiIKK4HkoRQNSeISVd
# yO+GwMixVeijETl7IL+4zZCpRs9DXPk96si/aNg05udS9ztD/lbNBg0EucMmqkGD
# l7FKtjK6/YRwS1Kg3sD3B4e7/A5lFxvS37HniKGCDykwgg8lBgorBgEEAYI3AwMB
# MYIPFTCCDxEGCSqGSIb3DQEHAqCCDwIwgg7+AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEINDWphR70VWB/KzJrjUDueqd2rGS3ENy1sbG9KPLTbu9AggEClsffprr
# sRgPMjAyNjEwMTQxMTM1MjBaMAMCAQECEFurL9lmWH4mdZMzyFanaTygggwAMIIE
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
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDExMzUyMFowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEID1zvBVliw02
# b6dRxlxJdpQBVAA7fXvTQZzjNw3gfv38MIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEcwRQIhAOFwmjbJ6RlRYQQwxmqoLtXoUgZlaCGluK5J5HOY2UG0AiAMPQAWH4nP
# cGXJDopgk7Dj0Wec7JVkYgSn5m2UzmMPug==
# SIG # End signature block
