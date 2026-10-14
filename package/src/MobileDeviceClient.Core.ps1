<#
.SYNOPSIS
    Mobile Device Client for Exchange - ActiveSync protocol helpers (dot-sourced by MobileDeviceClient.psm1).

.DESCRIPTION
    WBXML decoding (MS-ASWBXML code pages used by the diagnostic), WBXML request builders
    (Provision, Sync, Settings), the ActiveSync HTTP request and the two-phase provisioning.
    No function here prints anything: results are returned to the module, which shows them
    in the console, the log file and the report.

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.0
#>
function Read-WbxmlMultiByteInteger {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data,

        [Parameter(Mandatory = $true)]
        [ref]$Offset
    )

    [uint32]$value = 0

    do {
        if ($Offset.Value -ge $Data.Length) {
            throw 'Unexpected end of WBXML while reading a multi-byte integer.'
        }

        [byte]$current = $Data[$Offset.Value]
        $Offset.Value++
        $value = ($value -shl 7) -bor ($current -band 0x7F)
    }
    while (($current -band 0x80) -ne 0)

    return $value
}

function Get-EasTagName {
    param(
        [byte]$Page,
        [byte]$Token
    )

    $tags = @{
        '0:05'  = 'Sync'
        '0:06'  = 'Responses'
        '0:07'  = 'Add'
        '0:08'  = 'Change'
        '0:09'  = 'Delete'
        '0:0A'  = 'Fetch'
        '0:0B'  = 'SyncKey'
        '0:0C'  = 'ClientId'
        '0:0D'  = 'ServerId'
        '0:0E'  = 'Status'
        '0:0F'  = 'Collection'
        '0:10'  = 'Class'
        '0:12'  = 'CollectionId'
        '0:13'  = 'GetChanges'
        '0:14'  = 'MoreAvailable'
        '0:15'  = 'WindowSize'
        '0:16'  = 'Commands'
        '0:17'  = 'Options'
        '0:18'  = 'FilterType'
        '0:1C'  = 'Collections'
        '0:1D'  = 'ApplicationData'
        '0:21'  = 'SoftDelete'
        '0:22'  = 'MIMESupport'
        '0:23'  = 'MIMETruncation'
        '2:0F'  = 'DateReceived'
        '2:14'  = 'Subject'
        '2:15'  = 'Read'
        '2:18'  = 'From'
        '7:07'  = 'DisplayName'
        '7:08'  = 'ServerId'
        '7:09'  = 'ParentId'
        '7:0A'  = 'Type'
        '7:0C'  = 'Status'
        '7:0E'  = 'Changes'
        '7:0F'  = 'Add'
        '7:10'  = 'Delete'
        '7:11'  = 'Update'
        '7:12'  = 'SyncKey'
        '7:16'  = 'FolderSync'
        '7:17'  = 'Count'
        '17:05' = 'BodyPreference'
        '17:06' = 'Type'
        '17:07' = 'TruncationSize'
        '17:0A' = 'Body'
        '17:0B' = 'Data'
        '17:0C' = 'EstimatedDataSize'
        '17:0D' = 'Truncated'
        '17:16' = 'NativeBodyType'
        '14:05' = 'Provision'
        '14:06' = 'Policies'
        '14:07' = 'Policy'
        '14:08' = 'PolicyType'
        '14:09' = 'PolicyKey'
        '14:0A' = 'Data'
        '14:0B' = 'Status'
        '14:0C' = 'RemoteWipe'
        '14:0D' = 'EASProvisionDoc'
        '14:0E' = 'DevicePasswordEnabled'
        '14:0F' = 'AlphanumericDevicePasswordRequired'
        '14:10' = 'RequireStorageCardEncryption'
        '14:11' = 'PasswordRecoveryEnabled'
        '14:13' = 'AttachmentsEnabled'
        '14:14' = 'MinDevicePasswordLength'
        '14:15' = 'MaxInactivityTimeDeviceLock'
        '14:16' = 'MaxDevicePasswordFailedAttempts'
        '14:17' = 'MaxAttachmentSize'
        '14:18' = 'AllowSimpleDevicePassword'
        '14:19' = 'DevicePasswordExpiration'
        '14:1A' = 'DevicePasswordHistory'
        '14:1B' = 'AllowStorageCard'
        '14:1C' = 'AllowCamera'
        '14:1D' = 'RequireDeviceEncryption'
        '14:1E' = 'AllowUnsignedApplications'
        '14:1F' = 'AllowUnsignedInstallationPackages'
        '14:20' = 'MinDevicePasswordComplexCharacters'
        '14:21' = 'AllowWiFi'
        '14:22' = 'AllowTextMessaging'
        '14:23' = 'AllowPOPIMAPEmail'
        '14:24' = 'AllowBluetooth'
        '14:25' = 'AllowIrDA'
        '14:26' = 'RequireManualSyncWhenRoaming'
        '14:27' = 'AllowDesktopSync'
        '14:28' = 'MaxCalendarAgeFilter'
        '14:29' = 'AllowHTMLEmail'
        '14:2A' = 'MaxEmailAgeFilter'
        '14:2B' = 'MaxEmailBodyTruncationSize'
        '14:2C' = 'MaxEmailHTMLBodyTruncationSize'
        '14:2D' = 'RequireSignedSMIMEMessages'
        '14:2E' = 'RequireEncryptedSMIMEMessages'
        '14:2F' = 'RequireSignedSMIMEAlgorithm'
        '14:30' = 'RequireEncryptionSMIMEAlgorithm'
        '14:31' = 'AllowSMIMEEncryptionAlgorithmNegotiation'
        '14:32' = 'AllowSMIMESoftCerts'
        '14:33' = 'AllowBrowser'
        '14:34' = 'AllowConsumerEmail'
        '14:35' = 'AllowRemoteDesktop'
        '14:36' = 'AllowInternetSharing'
        '14:37' = 'UnapprovedInROMApplicationList'
        '14:38' = 'ApplicationName'
        '14:39' = 'ApprovedApplicationList'
        '14:3A' = 'Hash'
        '14:3B' = 'AccountOnlyRemoteWipe'
        '18:05' = 'Settings'
        '18:06' = 'Status'
        '18:07' = 'Get'
        '18:08' = 'Set'
        '18:16' = 'DeviceInformation'
        '18:17' = 'Model'
        '18:19' = 'FriendlyName'
        '18:1A' = 'OS'
        '18:1B' = 'OSLanguage'
        '18:1D' = 'UserInformation'
        '18:1E' = 'EmailAddresses'
        '18:1F' = 'SmtpAddress'
        '18:20' = 'UserAgent'
        '18:23' = 'PrimarySmtpAddress'
        '18:24' = 'Accounts'
        '18:25' = 'Account'
        '18:26' = 'AccountId'
        '18:27' = 'AccountName'
        '18:28' = 'UserDisplayName'
        '18:29' = 'SendDisabled'
    }

    $key = '{0}:{1:X2}' -f $Page,$Token
    if ($tags.ContainsKey($key)) {
        return $tags[$key]
    }

    return 'Page{0}Token{1:X2}' -f $Page,$Token
}

function ConvertFrom-EasWbxml {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data
    )

    if ($Data.Length -lt 4) {
        throw 'The WBXML response is too short.'
    }

    $offset = 0
    $null = $Data[$offset++]
    $null = Read-WbxmlMultiByteInteger -Data $Data -Offset ([ref]$offset)
    $null = Read-WbxmlMultiByteInteger -Data $Data -Offset ([ref]$offset)
    $stringTableLength = Read-WbxmlMultiByteInteger -Data $Data -Offset ([ref]$offset)

    if (($offset + $stringTableLength) -gt $Data.Length) {
        throw 'The WBXML string table extends beyond the response.'
    }

    [byte[]]$stringTable = if ($stringTableLength -gt 0) {
        $Data[$offset..($offset + $stringTableLength - 1)]
    }
    else {
        @()
    }
    $offset += $stringTableLength

    $document = [Xml.XmlDocument]::new()
    $container = $document.CreateElement('Wbxml')
    $null = $document.AppendChild($container)
    $currentNode = $container
    $stack = [Collections.Generic.Stack[Xml.XmlElement]]::new()
    [byte]$page = 0

    :TokenLoop while ($offset -lt $Data.Length) {
        [byte]$token = $Data[$offset++]

        switch ($token) {
            0x00 {
                if ($offset -ge $Data.Length) {
                    throw 'A WBXML page switch is missing its page number.'
                }
                $page = $Data[$offset++]
                continue TokenLoop
            }
            0x01 {
                if ($stack.Count -eq 0) {
                    throw 'WBXML contains an unexpected END token.'
                }
                $currentNode = $stack.Pop()
                continue TokenLoop
            }
            0x02 {
                $entity = Read-WbxmlMultiByteInteger -Data $Data -Offset ([ref]$offset)
                $null = $currentNode.AppendChild(
                    $document.CreateTextNode([char]$entity)
                )
                continue TokenLoop
            }
            0x03 {
                $start = $offset
                while ($offset -lt $Data.Length -and $Data[$offset] -ne 0) {
                    $offset++
                }
                if ($offset -ge $Data.Length) {
                    throw 'An inline WBXML string is not null-terminated.'
                }
                $text = [Text.Encoding]::UTF8.GetString($Data, $start, $offset - $start)
                $offset++
                $null = $currentNode.AppendChild($document.CreateTextNode($text))
                continue TokenLoop
            }
            0x83 {
                $tableOffset = Read-WbxmlMultiByteInteger -Data $Data -Offset ([ref]$offset)
                if ($tableOffset -ge $stringTable.Length) {
                    throw 'WBXML references an invalid string-table offset.'
                }
                $end = $tableOffset
                while ($end -lt $stringTable.Length -and $stringTable[$end] -ne 0) {
                    $end++
                }
                $text = [Text.Encoding]::UTF8.GetString(
                    $stringTable,
                    $tableOffset,
                    $end - $tableOffset
                )
                $null = $currentNode.AppendChild($document.CreateTextNode($text))
                continue TokenLoop
            }
            0xC3 {
                $opaqueLength = Read-WbxmlMultiByteInteger -Data $Data -Offset ([ref]$offset)
                if (($offset + $opaqueLength) -gt $Data.Length) {
                    throw 'A WBXML opaque value extends beyond the response.'
                }
                $offset += $opaqueLength
                continue TokenLoop
            }
        }

        if (($token -band 0x80) -ne 0) {
            throw 'WBXML attributes are not supported by this diagnostic parser.'
        }

        [byte]$tagToken = $token -band 0x3F
        $tagName = Get-EasTagName -Page $page -Token $tagToken
        $element = $document.CreateElement($tagName)
        $element.SetAttribute('CodePage', [string]$page)
        $null = $currentNode.AppendChild($element)

        if (($token -band 0x40) -ne 0) {
            $stack.Push($currentNode)
            $currentNode = $element
        }
    }

    if ($stack.Count -ne 0) {
        throw 'The WBXML response ended before all elements were closed.'
    }

    return $document
}

function Add-WbxmlInlineString {
    param(
        [Collections.Generic.List[byte]]$Buffer,
        [string]$Value
    )

    $Buffer.Add(0x03)
    $Buffer.AddRange([Text.Encoding]::UTF8.GetBytes($Value))
    $Buffer.Add(0x00)
}

function New-EasProvisionRequest {
    param(
        [string]$TemporaryPolicyKey
    )

    $buffer = [Collections.Generic.List[byte]]::new()
    $buffer.AddRange([byte[]](0x03,0x01,0x6A,0x00))
    $buffer.AddRange([byte[]](0x00,0x0E,0x45))

    if ([string]::IsNullOrWhiteSpace($TemporaryPolicyKey)) {
        $buffer.AddRange([byte[]](0x00,0x12,0x56,0x48))

        $buffer.Add(0x57)
        Add-WbxmlInlineString -Buffer $buffer -Value ([string]$script:MdcDevice.Model)
        $buffer.Add(0x01)

        $buffer.Add(0x59)
        Add-WbxmlInlineString `
            -Buffer $buffer `
            -Value ([string]$script:MdcDevice.FriendlyName)
        $buffer.Add(0x01)

        $buffer.Add(0x5A)
        Add-WbxmlInlineString `
            -Buffer $buffer `
            -Value ([string]$script:MdcDevice.OS)
        $buffer.Add(0x01)

        $buffer.Add(0x5B)
        Add-WbxmlInlineString `
            -Buffer $buffer `
            -Value ([Globalization.CultureInfo]::CurrentUICulture.Name)
        $buffer.Add(0x01)

        $buffer.Add(0x60)
        Add-WbxmlInlineString -Buffer $buffer -Value $script:MdcUserAgent
        $buffer.Add(0x01)

        $buffer.AddRange([byte[]](0x01,0x01,0x00,0x0E))
    }

    $buffer.AddRange([byte[]](0x46,0x47,0x48))
    Add-WbxmlInlineString `
        -Buffer $buffer `
        -Value 'MS-EAS-Provisioning-WBXML'
    $buffer.Add(0x01)

    if (-not [string]::IsNullOrWhiteSpace($TemporaryPolicyKey)) {
        $buffer.Add(0x49)
        Add-WbxmlInlineString -Buffer $buffer -Value $TemporaryPolicyKey
        $buffer.Add(0x01)

        $buffer.Add(0x4B)
        Add-WbxmlInlineString -Buffer $buffer -Value '1'
        $buffer.Add(0x01)
    }

    $buffer.AddRange([byte[]](0x01,0x01,0x01))
    return $buffer.ToArray()
}

function New-EasSyncRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SyncKey,

        [Parameter(Mandatory = $true)]
        [string]$CollectionId,

        [switch]$GetChanges,

        [ValidateRange(1, 100)]
        [int]$WindowSize = 5
    )

    $buffer = [Collections.Generic.List[byte]]::new()
    $buffer.AddRange([byte[]](0x03,0x01,0x6A,0x00))
    $buffer.AddRange([byte[]](0x45,0x5C,0x4F))

    $buffer.Add(0x4B)
    Add-WbxmlInlineString -Buffer $buffer -Value $SyncKey
    $buffer.Add(0x01)

    $buffer.Add(0x52)
    Add-WbxmlInlineString -Buffer $buffer -Value $CollectionId
    $buffer.Add(0x01)

    if ($GetChanges) {
        $buffer.Add(0x53)
        Add-WbxmlInlineString -Buffer $buffer -Value '1'
        $buffer.Add(0x01)

        $buffer.Add(0x55)
        Add-WbxmlInlineString -Buffer $buffer -Value ([string]$WindowSize)
        $buffer.Add(0x01)

        $buffer.Add(0x57)
        $buffer.AddRange([byte[]](0x00,0x11))
        $buffer.Add(0x45)

        $buffer.Add(0x46)
        Add-WbxmlInlineString -Buffer $buffer -Value '1'
        $buffer.Add(0x01)

        $buffer.Add(0x47)
        Add-WbxmlInlineString -Buffer $buffer -Value '0'
        $buffer.Add(0x01)

        $buffer.Add(0x01)
        $buffer.AddRange([byte[]](0x00,0x00))
        $buffer.Add(0x01)
    }

    $buffer.AddRange([byte[]](0x01,0x01,0x01))
    return $buffer.ToArray()
}

function New-EasFolderSyncRequest {
    # FolderSync with SyncKey 0: the full folder hierarchy.
    [byte[]](0x03,0x01,0x6A,0x00,0x00,0x07,0x56,0x52,0x03,0x30,0x00,0x01,0x01)
}

function New-EasSettingsRequest {
    # Settings > UserInformation > Get: the addresses Exchange resolves for the authenticated user.
    [byte[]](0x03,0x01,0x6A,0x00,0x00,0x12,0x45,0x5D,0x07,0x01,0x01)
}

function Get-ChildText {
    param(
        [Parameter(Mandatory = $true)]
        [Xml.XmlNode]$Node,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $child = $Node.SelectSingleNode("./*[local-name()='$Name']")
    if ($null -eq $child) {
        return $null
    }

    return $child.InnerText
}

function Assert-EasStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [string]$Status
    )

    [int]$numericStatus = 0
    if (-not [int]::TryParse($Status, [ref]$numericStatus)) {
        throw "$Command returned a non-numeric ActiveSync status: $Status."
    }

    if ($numericStatus -eq 1) {
        return
    }

    switch ($numericStatus) {
        138 {
            throw "$Command reports ActiveSync status 138: Exchange does not support the protocol version of the request (MS-ASProtocolVersion)."
        }
        139 {
            throw "$Command reports ActiveSync status 139: the device cannot fully comply with the mailbox policy."
        }
        140 {
            throw "$Command reports ActiveSync status 140: a remote wipe is pending. Stop using this test DeviceId."
        }
        141 {
            throw "$Command reports ActiveSync status 141: Exchange treats the client as non-provisionable or did not receive a usable policy key."
        }
        142 {
            throw "$Command reports ActiveSync status 142: the device is not provisioned."
        }
        143 {
            throw "$Command reports ActiveSync status 143: the mailbox policy must be refreshed."
        }
        144 {
            throw "$Command reports ActiveSync status 144: Exchange rejected the policy key."
        }
        145 {
            throw "$Command reports ActiveSync status 145: externally managed devices are not allowed."
        }
    }

    throw "$Command returned ActiveSync status $numericStatus."
}

function New-EasRequestMessage {
    <#
        The HTTP request of Invoke-EasRequest. Authorization header: "Bearer <token>" with AccessToken,
        "Bearer" alone with EmptyBearer (what a client sends to discover OAuth: Exchange returns its
        Bearer challenge only to such a request), none otherwise (anonymous request). With Credential: "Basic" and the
        base64 of user:password.
    #>
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpMethod]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [AllowEmptyString()][string]$AccessToken,
        [switch]$EmptyBearer,
        # Basic authentication: sent with the request, never written (see Protect-MdcHeaderValue).
        [pscredential]$Credential,
        [byte[]]$Body,
        [string]$PolicyKey = '0',
        # Extra headers (X-User-Identity for the OAuth discovery of a mailbox).
        [hashtable]$Headers,
        # Default: the User-Agent of the simulated client ($script:MdcUserAgent).
        [string]$UserAgent
    )

    $request = [Net.Http.HttpRequestMessage]::new($Method, $Uri)
    if (-not [string]::IsNullOrEmpty($AccessToken)) {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $AccessToken)
    }
    elseif ($Credential) {
        # UTF-8, like the mobile clients; sent at once (no first anonymous request), like ActiveSync devices.
        $pair = '{0}:{1}' -f $Credential.UserName, $Credential.GetNetworkCredential().Password
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Basic', [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($pair)))
    }
    elseif ($EmptyBearer) {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer')
    }
    $null = $request.Headers.TryAddWithoutValidation('MS-ASProtocolVersion', [string]$script:MdcDevice.ProtocolVersion)
    $null = $request.Headers.TryAddWithoutValidation('User-Agent', $(if ($UserAgent) { $UserAgent } else { $script:MdcUserAgent }))
    if ($Headers) { foreach ($name in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation([string]$name, [string]$Headers[$name]) } }

    if ($Method -eq [Net.Http.HttpMethod]::Post) {
        $null = $request.Headers.TryAddWithoutValidation('X-MS-PolicyKey', $PolicyKey)
        $request.Content = [Net.Http.ByteArrayContent]::new($Body)
        $request.Content.Headers.ContentType = [Net.Http.Headers.MediaTypeHeaderValue]::new('application/vnd.ms-sync.wbxml')
    }
    return $request
}

function Invoke-EasRequest {
    <#
        One ActiveSync HTTP request (see New-EasRequestMessage for the Authorization header),
        sent by Invoke-MdcHttp: never redirected, added to the trace of the run. The response keeps
        every header, the WWW-Authenticate challenges one by one, and the raw body.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [Net.Http.HttpClient]$HttpClient,

        [Parameter(Mandatory = $true)]
        [Net.Http.HttpMethod]$Method,

        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [AllowEmptyString()]
        [string]$AccessToken,

        [switch]$EmptyBearer,

        [pscredential]$Credential,

        [byte[]]$Body,

        [string]$PolicyKey = '0',

        [hashtable]$Headers,

        [string]$UserAgent
    )

    $request = New-EasRequestMessage -Method $Method -Uri $Uri -AccessToken $AccessToken -EmptyBearer:$EmptyBearer -Credential $Credential -Body $Body -PolicyKey $PolicyKey -Headers $Headers -UserAgent $UserAgent

    try {
        # Status, headers, WWW-Authenticate challenges one by one and raw body (Send-MdcHttpRequest).
        return Invoke-MdcHttp -HttpClient $HttpClient -Request $request
    }
    finally {
        $request.Dispose()
    }
}

function Get-EasDiagnostics {
    <# The x-ms-diagnostics header Exchange adds to OAuth failures (reason of a 401), or $null. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Response)

    if ($Response.PSObject.Properties['Headers'] -and $Response.Headers -and $Response.Headers.ContainsKey('x-ms-diagnostics')) {
        return [string]$Response.Headers['x-ms-diagnostics']
    }
    return $null
}

function Assert-EasHttpResponse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,

        [Parameter(Mandatory = $true)]
        [pscustomobject]$Response
    )

    $diagnostics = Get-EasDiagnostics -Response $Response
    $suffix = if ($diagnostics) { " Exchange diagnostics: $diagnostics" } else { '' }
    $refused = if ($script:MdcAuthentication -eq 'Basic') {
        'Exchange refused the user name and password (wrong password, locked account, Basic disabled on the ActiveSync virtual directory, or blocked by the authentication policy of the user).'
    }
    else { 'Exchange did not accept the OAuth token.' }
    switch ($Response.StatusCode) {
        200 { return }
        401 { throw "$Command returned HTTP 401: $refused$suffix" }
        403 { throw "$Command returned HTTP 403: the user or the test device is blocked for ActiveSync.$suffix" }
        449 { throw "$Command returned HTTP 449: ActiveSync provisioning is required or Exchange rejected the policy key.$suffix" }
        451 { throw "$Command returned HTTP 451: Exchange redirects this mailbox to another ActiveSync URL ($(Get-EasRedirectLocation -Response $Response)): $(Get-EasRedirectAdvice -Response $Response)$suffix" }
        default { throw "$Command returned HTTP $($Response.StatusCode).$suffix" }
    }
}

function Get-EasRedirectAdvice {
    <#
        What to do after an HTTP 451: in hybrid, Exchange on-premises sends the devices of a mailbox
        moved to Exchange Online to the URL of Exchange Online, where they sign in with Entra ID.
    #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Response)

    $location = Get-EasRedirectLocation -Response $Response
    if (Test-MdcExchangeOnlineUrl -Url $location) {
        return "the mailbox is in Exchange Online, devices are sent there. Test it with -EasUrl $(([string]$location).TrimEnd('/')) and Entra ID (-Authority EntraID)."
    }
    return 'test that URL.'
}

function Get-EasRedirectLocation {
    <# X-MS-Location of an HTTP 451 answer (ActiveSync redirect), or a placeholder. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Response)

    if ($Response.PSObject.Properties['Headers'] -and $Response.Headers -and $Response.Headers.ContainsKey('X-MS-Location')) {
        return [string]$Response.Headers['X-MS-Location']
    }
    return 'no X-MS-Location header'
}

function Get-EasProvisionRoot {
    param(
        [Parameter(Mandatory = $true)]
        [pscustomobject]$Response,

        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    Assert-EasHttpResponse -Command $Command -Response $Response
    if ($Response.Body.Length -eq 0) {
        throw "$Command returned an empty response."
    }
    $root = (ConvertFrom-EasWbxml -Data $Response.Body).SelectSingleNode('/*[local-name()="Wbxml"]/*[local-name()="Provision"]')
    if ($null -eq $root) {
        throw "$Command does not contain a Provision root element."
    }
    # A wipe directive is never acknowledged: the test stops before any further request.
    if ($root.SelectSingleNode('./*[local-name()="RemoteWipe"]') -or $root.SelectSingleNode('./*[local-name()="AccountOnlyRemoteWipe"]')) {
        throw 'Exchange returned a remote-wipe directive. It was not acknowledged: stop using this DeviceId.'
    }
    $status = Get-ChildText -Node $root -Name 'Status'
    if ($status -ne '1') {
        throw "$Command returned Provision status $status."
    }
    $policy = $root.SelectSingleNode('./*[local-name()="Policies"]/*[local-name()="Policy"]')
    if ($null -eq $policy) {
        throw "$Command did not return a policy."
    }
    $policyStatus = Get-ChildText -Node $policy -Name 'Status'
    if ($policyStatus -ne '1') {
        throw "$Command returned policy status $policyStatus."
    }
    return $policy
}

function Invoke-EasProvision {
    <#
        Phase 1 downloads the ActiveSync policy (temporary key and settings). Phase 2, only with
        -Acknowledge, acknowledges it and returns the final policy key. Without -Acknowledge the
        device stays unprovisioned: the settings are returned for review only.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [Net.Http.HttpClient]$HttpClient,

        [Parameter(Mandatory = $true)]
        [string]$EasUrl,

        [Parameter(Mandatory = $true)]
        [string]$EncodedUser,

        [Parameter(Mandatory = $true)]
        [string]$DeviceId,

        [Parameter(Mandatory = $true)]
        [string]$DeviceType,

        # The token (OAuth) or the credential (Basic) of the run.
        [AllowEmptyString()]
        [string]$AccessToken,

        [pscredential]$Credential,

        [switch]$Acknowledge
    )

    $provisionUri = '{0}?Cmd=Provision&User={1}&DeviceId={2}&DeviceType={3}' -f $EasUrl.TrimEnd('/'), $EncodedUser, $DeviceId, $DeviceType

    $initial = Invoke-EasRequest -HttpClient $HttpClient -Method ([Net.Http.HttpMethod]::Post) -Uri $provisionUri `
        -AccessToken $AccessToken -Credential $Credential -Body (New-EasProvisionRequest) -PolicyKey '0'
    $policy = Get-EasProvisionRoot -Response $initial -Command 'Provision (policy download)'

    $policyType = Get-ChildText -Node $policy -Name 'PolicyType'
    if ($policyType -ne 'MS-EAS-Provisioning-WBXML') {
        throw "Exchange returned unsupported policy type '$policyType'."
    }
    $temporaryKey = Get-ChildText -Node $policy -Name 'PolicyKey'
    if ([string]::IsNullOrWhiteSpace($temporaryKey)) {
        throw 'Exchange did not return a temporary ActiveSync policy key.'
    }

    $settings = @()
    $document = $policy.SelectSingleNode('./*[local-name()="Data"]/*[local-name()="EASProvisionDoc"]')
    if ($document) {
        $settings = @(
            foreach ($setting in $document.ChildNodes) {
                [pscustomobject]@{
                    Setting = $setting.LocalName
                    Value   = if ([string]::IsNullOrEmpty($setting.InnerText)) { '(not configured)' } else { $setting.InnerText }
                }
            }
        )
    }

    $finalKey = $null
    if ($Acknowledge) {
        $acknowledgement = Invoke-EasRequest -HttpClient $HttpClient -Method ([Net.Http.HttpMethod]::Post) -Uri $provisionUri `
            -AccessToken $AccessToken -Credential $Credential -Body (New-EasProvisionRequest -TemporaryPolicyKey $temporaryKey) -PolicyKey $temporaryKey
        $finalPolicy = Get-EasProvisionRoot -Response $acknowledgement -Command 'Provision (acknowledgement)'
        $finalKey = Get-ChildText -Node $finalPolicy -Name 'PolicyKey'
        if ([string]::IsNullOrWhiteSpace($finalKey)) {
            throw 'Exchange did not return a final ActiveSync policy key.'
        }
    }

    [pscustomobject]@{
        PolicyKey    = $finalKey
        Acknowledged = [bool]$Acknowledge
        Settings     = $settings
    }
}

# SIG # Begin signature block
# MIIghQYJKoZIhvcNAQcCoIIgdjCCIHICAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCBFBUpQwuCzyVT9
# UhuicOLkkUElcjzYs7Jn+Q/h7EYhyKCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
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
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCD1L885oJVL
# o86rsQtpil1mLqU+JuyIMUXH7NTHD3OP9jANBgkqhkiG9w0BAQEFAASCAgBIHLFs
# lSyd8OypgeRJ0uJ9lKj8piTzS873a8B7ZzW6KhgrgeTOTBgxMuEZde2oHKG6MGlb
# 8pUtmmL+OHGoM4G7WrQ1w3yhCCkUcBdhkHRzFBEjbG3MbXVnOoV7nLVj0mnfiDnF
# cJPpeBNp/d1B8r3mn8T2RQxejY0w0G+Uwg6YyQr8q+E/Ud/mzhX9SgYBvya6iMgf
# OJw/5k67I5zfBu2/EiowmLSM1FwXNbgRbtYWp6YzMzv47o6tKUXmc7+yhE9kkvWv
# o5lh+GDOzaHUVUCgH7agz94wcMn9Kouu/AEAQE4axedgci/EFT1SBBPg6OyFYlqZ
# hM2D7sQL11Y9tItggStWPc20T4bHIETNSPAGaOWAPui9j4aY7s/ycVHNZSwIvjhJ
# RXk9GwGqPBOC9Q+cCd8dQ4lyjJ7nLeECkkxRO/LA5Q32NHYYsHY8SbpcephKWGBx
# HDM/Tf5RrLLjQhWT34wFot9GG63N7MeEM/csuEQa135qxpGjvL1RjHOXbYp9+HxC
# dOMjrDUSB4DKOhGE+X5JDjbIp8XOX5TZ62l0IaFOMK1EeM5kHazriLD6vaHEMDoO
# 7zCF4Bcq2i725dNdsNmc5R6jAkwEjANrb7hktpfROXuJmZ1l9SPSL1kM7iDcuBAa
# pkCKk/CikivScy+8tkUVK0JshgTS0GvO5O9pkaGCDykwgg8lBgorBgEEAYI3AwMB
# MYIPFTCCDxEGCSqGSIb3DQEHAqCCDwIwgg7+AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEIPyLJYtk1DJgNjN2KIqeShsmUhEDhGa1wMRYnmoLypdbAggNpjQsUaXk
# fhgPMjAyNjEwMTQxMTM1NTRaMAMCAQECEEPZDgnLvBXdqQgnrZBQh2CgggwAMIIE
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
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDExMzU1NFowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIIXuDSTP3P87
# 6wJI6KLon90Hijr8keH9hYjX3MI97dPIMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEcwRQIgakqogF8pHobIS1xlKHSlaIjPUv96YrYtq8c1zj1mNwMCIQDmJ2YfUfQd
# zS6AqEf9qqlJPF37LUfVoNfMT4fJKhN+Bg==
# SIG # End signature block
