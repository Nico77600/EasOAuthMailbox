<#
.SYNOPSIS
    EAS OAuth Mailbox - ActiveSync protocol helpers (dot-sourced by EasOAuthMailbox.psm1).

.DESCRIPTION
    WBXML decoding (MS-ASWBXML code pages used by the diagnostic), WBXML request builders
    (Provision, Sync, Settings), the ActiveSync HTTP request and the two-phase provisioning.
    No function here prints anything: results are returned to the module, which shows them
    in the console, the log file and the report.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
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
        Add-WbxmlInlineString -Buffer $buffer -Value ([string]$script:EomDevice.Model)
        $buffer.Add(0x01)

        $buffer.Add(0x59)
        Add-WbxmlInlineString `
            -Buffer $buffer `
            -Value ([string]$script:EomDevice.FriendlyName)
        $buffer.Add(0x01)

        $buffer.Add(0x5A)
        Add-WbxmlInlineString `
            -Buffer $buffer `
            -Value ([string]$script:EomDevice.OS)
        $buffer.Add(0x01)

        $buffer.Add(0x5B)
        Add-WbxmlInlineString `
            -Buffer $buffer `
            -Value ([Globalization.CultureInfo]::CurrentUICulture.Name)
        $buffer.Add(0x01)

        $buffer.Add(0x60)
        Add-WbxmlInlineString -Buffer $buffer -Value $script:EomUserAgent
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
        Bearer challenge only to such a request), none otherwise (anonymous request).
    #>
    param(
        [Parameter(Mandatory = $true)][Net.Http.HttpMethod]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [AllowEmptyString()][string]$AccessToken,
        [switch]$EmptyBearer,
        [byte[]]$Body,
        [string]$PolicyKey = '0',
        # Extra headers (X-User-Identity for the OAuth discovery of a mailbox).
        [hashtable]$Headers,
        # Default: the User-Agent of the simulated client ($script:EomUserAgent).
        [string]$UserAgent
    )

    $request = [Net.Http.HttpRequestMessage]::new($Method, $Uri)
    if (-not [string]::IsNullOrEmpty($AccessToken)) {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $AccessToken)
    }
    elseif ($EmptyBearer) {
        $request.Headers.Authorization = [Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer')
    }
    $null = $request.Headers.TryAddWithoutValidation('MS-ASProtocolVersion', [string]$script:EomDevice.ProtocolVersion)
    $null = $request.Headers.TryAddWithoutValidation('User-Agent', $(if ($UserAgent) { $UserAgent } else { $script:EomUserAgent }))
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
        sent by Invoke-EomHttp: never redirected, added to the trace of the run. The response keeps
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

        [byte[]]$Body,

        [string]$PolicyKey = '0',

        [hashtable]$Headers,

        [string]$UserAgent
    )

    $request = New-EasRequestMessage -Method $Method -Uri $Uri -AccessToken $AccessToken -EmptyBearer:$EmptyBearer -Body $Body -PolicyKey $PolicyKey -Headers $Headers -UserAgent $UserAgent

    try {
        # Status, headers, WWW-Authenticate challenges one by one and raw body (Send-EomHttpRequest).
        return Invoke-EomHttp -HttpClient $HttpClient -Request $request
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
    switch ($Response.StatusCode) {
        200 { return }
        401 { throw "$Command returned HTTP 401: Exchange did not accept the OAuth token.$suffix" }
        403 { throw "$Command returned HTTP 403: the user or the test device is blocked for ActiveSync.$suffix" }
        449 { throw "$Command returned HTTP 449: ActiveSync provisioning is required or Exchange rejected the policy key.$suffix" }
        451 { throw "$Command returned HTTP 451: Exchange redirects this mailbox to another ActiveSync URL ($(Get-EasRedirectLocation -Response $Response)). Test that URL.$suffix" }
        default { throw "$Command returned HTTP $($Response.StatusCode).$suffix" }
    }
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

        [Parameter(Mandatory = $true)]
        [string]$AccessToken,

        [switch]$Acknowledge
    )

    $provisionUri = '{0}?Cmd=Provision&User={1}&DeviceId={2}&DeviceType={3}' -f $EasUrl.TrimEnd('/'), $EncodedUser, $DeviceId, $DeviceType

    $initial = Invoke-EasRequest -HttpClient $HttpClient -Method ([Net.Http.HttpMethod]::Post) -Uri $provisionUri `
        -AccessToken $AccessToken -Body (New-EasProvisionRequest) -PolicyKey '0'
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
            -AccessToken $AccessToken -Body (New-EasProvisionRequest -TemporaryPolicyKey $temporaryKey) -PolicyKey $temporaryKey
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
