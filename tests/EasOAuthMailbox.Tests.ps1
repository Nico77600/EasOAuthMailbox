#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
<#
    EAS OAuth Mailbox - automated tests (Pester 6.1 or later).
    Author  : Nicolas Fabert
    Version : 1.0.0

    Run:  .\Run-Tests.ps1      (or Invoke-Pester -Path .\tests -Output Detailed)

    No AD FS and no Exchange server are needed. The scenarios run against a simulated Exchange:
    Invoke-EasRequest is replaced by a mock that answers with WBXML documents built byte by byte
    with the code pages of MS-ASWBXML (FolderSync, Provision, Settings, Sync), HTTP 401 / 403 / 449
    and the WWW-Authenticate / x-ms-diagnostics headers of Exchange. Tokens are unsigned JWTs.
#>

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:Root 'EasOAuthMailbox.psd1') -Force
    $script:Module = Get-Module EasOAuthMailbox
    function InModule([scriptblock]$Block, [object]$Argument) { & $script:Module $Block $Argument }

    # Simulated AD FS and Exchange ActiveSync (WBXML built byte by byte), shared with tools\New-DocumentationImages.ps1.
    . (Join-Path $PSScriptRoot 'EasOAuthMailbox.Simulator.ps1')
    function New-TestToken { New-SimToken @args }
    function New-Response { New-SimResponse @args }
    $script:Wbxml = @{
        SyncMessages = New-SimSync -SyncKey 'SK2' -Messages (New-SimState).Messages -MoreAvailable
    }

    $script:ValidToken = $script:SimValidToken
    $script:InvalidTokenPayload = (& $script:Module { $script:InvalidToken }).Split('.')[1]
    $script:Config = @{
        AdfsUrl = 'https://adfs.contoso.test/adfs'; EasUrl = 'https://mail.contoso.test/Microsoft-Server-ActiveSync'
        Mailbox = 'eas-test@contoso.test'; ClientId = 'client'; DeviceId = 'TESTDEVICE01'
        OutputPath = (Join-Path $script:Root 'artifacts\test-reports'); LogPath = (Join-Path $script:Root 'artifacts\test-logs')
    }
    function Invoke-Scenario([string]$Type, [hashtable]$Overrides = @{}, [string]$Token = $script:ValidToken) {
        $cfg = $script:Config.Clone(); foreach ($k in $Overrides.Keys) { $cfg[$k] = $Overrides[$k] }
        Invoke-EomMailboxTest -Configuration $cfg -TestType $Type -AccessToken $Token -Quiet
    }
    function Get-Calls([string]$Command) { @($script:Exchange.Calls | Where-Object Command -eq $Command) }
}

Describe 'Configuration' {
    It 'reads the sections and resolves relative paths from the tool folder' {
        $c = Import-EomConfiguration
        $c.OutputPath | Should -Be (Join-Path $script:Root 'reports')
        $c.LogPath | Should -Be (Join-Path $script:Root 'logs')
        $c.TestType | Should -Be 'Full'
        $c.AcknowledgePolicy | Should -BeFalse
    }

    It 'lists unknown sections, unknown keys and invalid values together' {
        $path = Join-Path $script:Root 'artifacts\bad.config.psd1'
        [void][IO.Directory]::CreateDirectory((Split-Path $path))
        "@{ Target = @{ AdfsUrl = 'http://adfs/x'; Mailbx = 'a' }; Extra = @{}; Test = @{ MessageCount = 500; DefaultType = 'Nope' } }" | Set-Content $path
        $message = { Import-EomConfiguration -Path $path } | Should -Throw -PassThru
        $text = $message.Exception.Message
        $text | Should -Match "Unknown key 'Target.Mailbx'"
        $text | Should -Match "Unknown section 'Extra'"
        $text | Should -Match 'Target.AdfsUrl must be an https'
        $text | Should -Match 'Test.MessageCount must be'
        $text | Should -Match 'Test.DefaultType must be one of'
        Remove-Item $path
    }

    It 'accepts the documented URLs and rejects HTTP or a wrong ActiveSync path' {
        (Test-EomEndpoint -AdfsUrl 'https://adfs.contoso.com/adfs' -EasUrl 'https://mail.contoso.com/Microsoft-Server-ActiveSync').IsValid | Should -BeTrue
        $bad = Test-EomEndpoint -AdfsUrl 'http://adfs.contoso.com/adfs' -EasUrl 'https://mail.contoso.com/owa'
        $bad.Problems.Count | Should -Be 2
    }

    It 'exposes nine scenarios with their stages, client and safety flags' {
        $catalog = Get-EomTestCatalog
        $catalog.Name | Should -Be @('Discovery', 'OAuth', 'Endpoint', 'FolderSync', 'Provisioning', 'Identity', 'InboxSync', 'Full', 'AppleMail')
        ($catalog | Where-Object Name -eq 'Discovery').SignIn | Should -BeFalse
        ($catalog | Where-Object Name -eq 'Endpoint').ChangesServerState | Should -BeFalse
        ($catalog | Where-Object Name -eq 'Full').Stages | Should -Be @('Discovery', 'OAuth', 'Endpoint', 'FolderSync', 'Identity', 'InboxSync')
        ($catalog | Where-Object Name -eq 'AppleMail').Stages | Should -Be @('AppleSetup', 'OAuth', 'Endpoint', 'FolderSync', 'Identity', 'InboxSync')
        ($catalog | Where-Object Name -eq 'AppleMail').Client | Should -Be 'AppleMail'
        ($catalog | Where-Object Name -eq 'Full').Client | Should -Be 'Tool'
    }

    It 'derives a stable 32-character DeviceId that ignores the case of the mailbox' {
        $one = Get-EomDeviceId -Mailbox 'Eas-Test@Contoso.test' -ComputerName 'PC1'
        $one | Should -Match '^[A-F0-9]{32}$'
        Get-EomDeviceId -Mailbox 'eas-test@contoso.test' -ComputerName 'PC1' | Should -Be $one
        Get-EomDeviceId -Mailbox 'other@contoso.test' -ComputerName 'PC1' | Should -Not -Be $one
    }
}

Describe 'Token claims' {
    It 'decodes a base64url JWT payload without padding' {
        $claims = InModule { param($t) Get-EomTokenClaims -AccessToken $t } (New-TestToken -Upn 'a@b.c')
        $claims.upn | Should -Be 'a@b.c'
    }

    It 'returns nothing for an opaque token' {
        InModule { Get-EomTokenClaims -AccessToken 'opaque-token' } | Should -BeNullOrEmpty
    }

    It 'passes when audience, scope and expiry match the ActiveSync resource' {
        $r = InModule { param($t) Test-EomTokenClaims -Claims (Get-EomTokenClaims $t) -Endpoints (Resolve-EomEndpoints @{ AdfsUrl = 'https://adfs.contoso.test/adfs'; EasUrl = 'https://mail.contoso.test/Microsoft-Server-ActiveSync' }) -Mailbox 'eas-test@contoso.test' } $script:ValidToken
        $r.Status | Should -Be 'Passed'
        $r.Details.Audience | Should -Be 'https://mail.contoso.test/'
    }

    It 'warns when the audience or the scope does not fit ActiveSync' {
        $t = New-TestToken -Audience 'https://other.contoso.test/' -Scope 'openid'
        $r = InModule { param($t) Test-EomTokenClaims -Claims (Get-EomTokenClaims $t) -Endpoints (Resolve-EomEndpoints @{ AdfsUrl = 'https://adfs.contoso.test/adfs'; EasUrl = 'https://mail.contoso.test/Microsoft-Server-ActiveSync' }) -Mailbox 'eas-test@contoso.test' } $t
        $r.Status | Should -Be 'Warning'
        $r.Message | Should -Match 'audience'
        $r.Message | Should -Match 'EAS.AccessAsUser.All'
    }

    It 'fails an expired token' {
        $t = New-TestToken -ExpiresIn -120
        $r = InModule { param($t) Test-EomTokenClaims -Claims (Get-EomTokenClaims $t) -Endpoints (Resolve-EomEndpoints @{ AdfsUrl = 'https://adfs.contoso.test/adfs'; EasUrl = 'https://mail.contoso.test/Microsoft-Server-ActiveSync' }) -Mailbox 'eas-test@contoso.test' } $t
        $r.Status | Should -Be 'Failed'
    }
}

Describe 'ActiveSync protocol helpers' {
    It 'reads single-byte and multi-byte WBXML integers' {
        InModule { $o = 0; Read-WbxmlMultiByteInteger -Data ([byte[]](0x7F)) -Offset ([ref]$o) } | Should -Be 127
        InModule { $o = 0; Read-WbxmlMultiByteInteger -Data ([byte[]](0x81, 0x00)) -Offset ([ref]$o) } | Should -Be 128
    }

    It 'decodes nested elements across code pages' {
        $xml = InModule { param($d) ConvertFrom-EasWbxml -Data $d } $script:Wbxml.SyncMessages
        $xml.SelectSingleNode('//*[local-name()="Subject"]').InnerText | Should -Be '=HYPERLINK("http://x")'
        $xml.SelectSingleNode('//*[local-name()="MoreAvailable"]') | Should -Not -BeNullOrEmpty
    }

    It 'rejects truncated, unclosed and invalid string-table WBXML' {
        { InModule { ConvertFrom-EasWbxml -Data ([byte[]](0x03, 0x01)) } } | Should -Throw '*too short*'
        { InModule { ConvertFrom-EasWbxml -Data ([byte[]](0x03, 0x01, 0x6A, 0x00, 0x45, 0x03, 0x31, 0x00)) } } | Should -Throw '*ended before*'
        { InModule { ConvertFrom-EasWbxml -Data ([byte[]](0x03, 0x01, 0x6A, 0x01, 0x00, 0x83, 0x01)) } } | Should -Throw '*string-table*'
    }

    It 'names the Settings code page tags and keeps unknown tags readable' {
        InModule { Get-EasTagName -Page 18 -Token 0x1D } | Should -Be 'UserInformation'
        InModule { Get-EasTagName -Page 18 -Token 0x23 } | Should -Be 'PrimarySmtpAddress'
        InModule { Get-EasTagName -Page 99 -Token 0x22 } | Should -Be 'Page99Token22'
    }

    It 'builds the exact Settings UserInformation request' {
        InModule { New-EasSettingsRequest } | Should -Be ([byte[]](0x03, 0x01, 0x6A, 0x00, 0x00, 0x12, 0x45, 0x5D, 0x07, 0x01, 0x01))
    }

    It 'sends no Authorization header, an empty Bearer header or the token, as asked' {
        $uri = 'https://mail.contoso.test/Microsoft-Server-ActiveSync'
        $options = [Net.Http.HttpMethod]::Options
        $anonymous = InModule { param($a) New-EasRequestMessage -Method $a[0] -Uri $a[1] -AccessToken '' } @($options, $uri)
        $empty = InModule { param($a) New-EasRequestMessage -Method $a[0] -Uri $a[1] -AccessToken '' -EmptyBearer } @($options, $uri)
        $token = InModule { param($a) New-EasRequestMessage -Method $a[0] -Uri $a[1] -AccessToken 'abc' -EmptyBearer } @($options, $uri)
        $anonymous.Headers.Authorization | Should -BeNullOrEmpty
        $empty.Headers.Authorization.ToString() | Should -BeExactly 'Bearer'
        $token.Headers.Authorization.ToString() | Should -BeExactly 'Bearer abc'
        $anonymous, $empty, $token | ForEach-Object { $_.Dispose() }
    }

    It 'puts the configured User-Agent in the provisioning device information' {
        $text = [Text.Encoding]::UTF8.GetString((InModule { New-EasProvisionRequest }))
        $text | Should -Match 'EasOAuthMailbox/1.0'
        $text | Should -Match 'EAS OAuth Mailbox'
    }

    It 'accepts ActiveSync status 1 and explains the provisioning statuses' {
        { InModule { Assert-EasStatus -Command 'Test' -Status '1' } } | Should -Not -Throw
        { InModule { Assert-EasStatus -Command 'Test' -Status '144' } } | Should -Throw '*policy key*'
        { InModule { Assert-EasStatus -Command 'Test' -Status 'x' } } | Should -Throw '*non-numeric*'
    }

    It 'adds the Exchange diagnostics to a 401 and the redirect URL to a 451' {
        $r401 = New-Response 401 -Headers @{ 'x-ms-diagnostics' = '2000001;reason="The token is invalid."' }
        { InModule { param($r) Assert-EasHttpResponse -Command 'OPTIONS' -Response $r } $r401 } | Should -Throw '*The token is invalid*'
        $r451 = New-Response 451 -Headers @{ 'X-MS-Location' = 'https://eas2.contoso.test/Microsoft-Server-ActiveSync' }
        { InModule { param($r) Assert-EasHttpResponse -Command 'OPTIONS' -Response $r } $r451 } | Should -Throw '*eas2.contoso.test*'
    }

    It 'reads the schemes and the authorization URI of the challenges' {
        $info = InModule { Get-EomChallengeInfo -Challenges @('Bearer client_id="x", authorization_uri="https://adfs.contoso.test/adfs/oauth2/authorize"', 'Basic realm="mail"') }
        $info.Bearer | Should -BeTrue
        $info.Schemes | Should -Be @('Bearer', 'Basic')
        $info.AuthorizationUri | Should -Be 'https://adfs.contoso.test/adfs/oauth2/authorize'
    }

    It 'reads the sign-in page, the unknown client and the refused redirect URI of AD FS' {
        $page = [pscustomobject]@{ StatusCode = 200; Location = $null; Content = '<form id="loginForm"><input id="passwordInput"/></form>' }
        $client = [pscustomobject]@{ StatusCode = 200; Location = $null; Content = '<div>MSIS9223: Received invalid OAuth authorization request. The received &#39;client_id&#39; is invalid.</div>' }
        $redirect = [pscustomobject]@{ StatusCode = 200; Location = $null; Content = '<div>MSIS9224: The received &#39;redirect_uri&#39; parameter is not valid.</div>' }
        $code = [pscustomobject]@{ StatusCode = 302; Location = 'com.apple.Preferences://oauth-redirect?code=abc&state=x'; Content = '' }
        (InModule { param($r) Get-EomAuthorizeOutcome -Response $r } $page).Code | Should -Be 'SignInPage'
        (InModule { param($r) Get-EomAuthorizeOutcome -Response $r } $client).Code | Should -Be 'UnknownClient'
        (InModule { param($r) Get-EomAuthorizeOutcome -Response $r } $redirect).Text | Should -Match "MSIS9224: The received 'redirect_uri'"
        (InModule { param($r) Get-EomAuthorizeOutcome -Response $r } $code).Code | Should -Be 'SignedIn'
    }

    It 'masks tokens, codes and cookies, and summarises HTML pages in the trace' {
        InModule { Protect-EomHeaderValue -Name 'Authorization' -Value 'Bearer abc.def.ghi' } | Should -Be 'Bearer <access token: 11 characters, never written>'
        InModule { Protect-EomHeaderValue -Name 'Authorization' -Value 'Bearer' } | Should -Be 'Bearer'
        InModule { Protect-EomHeaderValue -Name 'Set-Cookie' -Value 'MSISAuth=secret; path=/adfs; secure' } | Should -Be 'MSISAuth=<hidden>; path=/adfs; secure'
        InModule { Format-EomFormBody 'grant_type=authorization_code&code=abc123&client_id=x' } | Should -Match 'code=<6 characters, never written>'
        InModule { Format-EomJsonBody '{"access_token":"abc","token_type":"bearer"}' } | Should -Match '"access_token": "<access_token: 3 characters, never written>"'
        $html = InModule { Format-EomHtmlSummary -Text '<html><title>Sign In</title><div>MSIS9224: Received invalid OAuth authorization request.</div></html>' -Length 90 }
        $html | Should -Match 'Title: Sign In'
        $html | Should -Match 'AD FS error: MSIS9224'
    }

    It 'gives the overall status Failed > Blocked > Warning > Passed' {
        $s = { param($l) InModule { param($x) Get-EomOverallStatus -Steps @($x | ForEach-Object { [pscustomobject]@{ Status = $_ } }) } $l }
        & $s @('Passed', 'Warning', 'Blocked', 'Failed') | Should -Be 'Failed'
        & $s @('Passed', 'Warning', 'Blocked', 'Skipped') | Should -Be 'Blocked'
        & $s @('Passed', 'Warning') | Should -Be 'Warning'
        & $s @('Passed', 'Passed') | Should -Be 'Passed'
    }
}

Describe 'Scenarios against a simulated Exchange' {
    BeforeAll {
        Mock -ModuleName EasOAuthMailbox Send-EomHttpRequest { Get-SimHttpResponse -Request $Request -State $script:Exchange }
        Mock -ModuleName EasOAuthMailbox Get-EomTlsCertificate { Get-SimCertificate $HostName $Port $script:Exchange.CertificateDays }
    }

    BeforeEach { $script:Exchange = New-SimState }

    It 'Endpoint: the token is accepted and the Exchange version is reported' {
        $r = Invoke-Scenario 'Endpoint'
        $r.Status | Should -Be 'Passed'
        ($r.Steps | Where-Object Name -eq 'OPTIONS').Details.ExchangeVersion | Should -Be '15.20'
        ($r.Steps | Where-Object Name -eq 'Token claims').Status | Should -Be 'Passed'
    }

    It 'Endpoint: a rejected token fails with the reason given by Exchange' {
        $r = Invoke-Scenario 'Endpoint' -Token (New-TestToken -Upn 'eas-test@contoso.test' -Scope 'EAS.AccessAsUser.All openid')
        $r.Status | Should -Be 'Failed'
        $r.Error | Should -Match 'HTTP 401'
        $r.Error | Should -Match 'The token is invalid'
    }

    It 'FolderSync: folders are listed with their type name' {
        $r = Invoke-Scenario 'FolderSync'
        $r.Status | Should -Be 'Passed'
        $r.Folders.Count | Should -Be 2
        ($r.Folders | Where-Object Type -eq '2').TypeName | Should -Be 'Inbox'
    }

    It 'FolderSync: HTTP 403 is a failure, never a pass' {
        $script:Exchange.FolderSyncHttp = 403
        $r = Invoke-Scenario 'FolderSync'
        $r.Status | Should -Be 'Failed'
        $r.Error | Should -Match '403'
    }

    It 'provisioning required and not authorised: Blocked, policy downloaded for review, nothing after it' {
        $script:Exchange.RequireProvisioning = $true
        $r = Invoke-Scenario 'InboxSync'
        $r.Status | Should -Be 'Blocked'
        $r.PolicyAcknowledged | Should -BeFalse
        $r.PolicySettings.Count | Should -Be 2
        @(Get-Calls 'Provision').Count | Should -Be 1
        @(Get-Calls 'Sync').Count | Should -Be 0
        @($r.Steps | Where-Object Status -eq 'Failed').Count | Should -Be 0
        ($r.Steps | Select-Object -Last 1).Status | Should -Be 'Skipped'
    }

    It 'provisioning required (HTTP 449) and authorised: FolderSync acknowledges the policy, then succeeds' {
        $script:Exchange.RequireProvisioning = $true
        $r = Invoke-Scenario 'FolderSync' @{ AcknowledgePolicy = $true }
        $r.Status | Should -Be 'Passed'
        $r.PolicyAcknowledged | Should -BeTrue
        (Get-Calls 'FolderSync').PolicyKey | Should -Be @('0', 'FINALKEY')
    }

    It 'provisioning required (ActiveSync status 142) is detected the same way' {
        $script:Exchange.RequireProvisioning = $true
        $script:Exchange.ProvisionByStatus = $true
        $r = Invoke-Scenario 'FolderSync' @{ AcknowledgePolicy = $true }
        $r.Status | Should -Be 'Passed'
        $r.PolicyAcknowledged | Should -BeTrue
    }

    It 'every command after the acknowledgement sends the final policy key' {
        $script:Exchange.RequireProvisioning = $true
        $r = Invoke-Scenario 'Full' @{ AcknowledgePolicy = $true }
        $r.Status | Should -Be 'Passed'
        (Get-Calls 'Sync').PolicyKey | Should -Be @('FINALKEY', 'FINALKEY')
        (Get-Calls 'Settings').PolicyKey | Should -Be @('FINALKEY')
        $r.Messages.Count | Should -Be 1
        $r.MoreAvailable | Should -BeTrue
        $r.Messages[0].Read | Should -Be 'No'
    }

    It 'Provisioning scenario without authorisation never sends FolderSync' {
        $r = Invoke-Scenario 'Provisioning'
        $r.Status | Should -Be 'Blocked'
        @(Get-Calls 'FolderSync').Count | Should -Be 0
        @(Get-Calls 'Provision').Count | Should -Be 1
    }

    It 'a remote-wipe directive stops the run and is never acknowledged' {
        $script:Exchange.RequireProvisioning = $true
        $script:Exchange.RemoteWipe = $true
        $r = Invoke-Scenario 'FolderSync' @{ AcknowledgePolicy = $true }
        $r.Status | Should -Be 'Failed'
        $r.Error | Should -Match 'remote-wipe'
        @(Get-Calls 'Provision' | Where-Object PolicyKey -eq 'TEMPKEY').Count | Should -Be 0
    }

    It 'Identity: passes when the mailbox is one of the addresses of the signed-in user' {
        $r = Invoke-Scenario 'Identity'
        $r.Status | Should -Be 'Passed'
        $r.Identity.PrimarySmtpAddress | Should -Be 'eas-test@contoso.test'
        $r.Identity.Addresses | Should -Contain 'alias@contoso.test'
    }

    It 'Identity: warns when the signed-in user is not the mailbox' {
        $script:Exchange.Identity = @{ DisplayName = $null; Primary = $null; Addresses = @('someone.else@contoso.test') }
        $r = Invoke-Scenario 'Identity'
        $r.Status | Should -Be 'Warning'
        ($r.Steps | Where-Object Name -eq 'UserInformation').Message | Should -Match 'someone.else@contoso.test'
    }

    It 'Discovery: OAuth found with an empty Bearer header (Exchange SE), invalid token rejected, no sign-in' {
        $r = Invoke-Scenario 'Discovery' -Token ''
        $r.Status | Should -Be 'Passed'
        $step = $r.Steps | Where-Object Name -eq 'OAuth challenge'
        $step.Status | Should -Be 'Passed'
        $step.Details.ChallengeRequest | Should -Be 'Empty Bearer'
        $step.Details.Diagnostics | Should -Match 'oauth_not_available'
        ($r.Steps | Where-Object Name -eq 'Invalid token').Status | Should -Be 'Passed'
        @($r.Steps | Where-Object Name -like 'TLS certificate*').Count | Should -Be 2
        @(Get-Calls 'OPTIONS' | Where-Object { $_.EmptyBearer -and -not $_.Identity }).Count | Should -Be 1
        @(Get-Calls 'OPTIONS' | Where-Object Token -eq $script:ValidToken).Count | Should -Be 0
    }

    It 'Discovery: a challenge already sent to anonymous requests is enough (no second request)' {
        $script:Exchange.BearerChallenge = 'Anonymous'
        $script:Exchange.AuthorizationUri = 'https://adfs.contoso.test/adfs/oauth2/authorize'
        $r = Invoke-Scenario 'Discovery' -Token ''
        $step = $r.Steps | Where-Object Name -eq 'OAuth challenge'
        $step.Status | Should -Be 'Passed'
        $step.Details.ChallengeRequest | Should -Be 'Anonymous'
        $step.Details.AuthorizationUri | Should -Match 'adfs.contoso.test'
        @(Get-Calls 'OPTIONS' | Where-Object { $_.EmptyBearer -and -not $_.Identity }).Count | Should -Be 0
    }

    It 'Discovery: no Bearer challenge, even to an empty Bearer header, is a warning' {
        $script:Exchange.BearerChallenge = 'None'
        $r = Invoke-Scenario 'Discovery' -Token ''
        $step = $r.Steps | Where-Object Name -eq 'OAuth challenge'
        $step.Status | Should -Be 'Warning'
        $step.Message | Should -Match 'even to an empty Bearer header'
        ($r.Steps | Where-Object Name -eq 'OAuth for the mailbox').Status | Should -Be 'Failed'
        $r.Status | Should -Be 'Failed'
    }

    It 'Discovery: an invalid token accepted by Exchange is a failure' {
        $script:Exchange.AcceptAnyToken = $true
        $r = Invoke-Scenario 'Discovery' -Token ''
        $r.Status | Should -Be 'Failed'
        ($r.Steps | Where-Object Name -eq 'Invalid token').Status | Should -Be 'Failed'
    }

    It 'Discovery: a Bearer challenge that points to another authorization server is a warning' {
        $script:Exchange.AuthorizationUri = 'https://adfs.contoso.test/adfs/oauth2/authorize'
        $r = Invoke-Scenario 'Discovery' @{ AdfsUrl = 'https://sts.fabrikam.test/adfs' } -Token ''
        $step = $r.Steps | Where-Object Name -eq 'OAuth challenge'
        $step.Status | Should -Be 'Warning'
        $step.Message | Should -Match 'adfs.contoso.test'
    }

    It 'Discovery: a certificate that expires soon is a warning' {
        $script:Exchange.CertificateDays = 10
        $r = Invoke-Scenario 'Discovery' -Token ''
        $r.Status | Should -Be 'Warning'
    }

    It 'an expired token fails and the following stages are skipped, not run' {
        $r = Invoke-Scenario 'InboxSync' -Token (New-TestToken -ExpiresIn -60)
        $r.Status | Should -Be 'Failed'
        @($r.Steps | Where-Object Status -eq 'Skipped').Count | Should -Be 3
        @($script:Exchange.Calls).Count | Should -Be 0
    }

    It 'Discovery: the mailbox gets the AD FS authorization URL when its policy allows OAuth' {
        $r = Invoke-Scenario 'Discovery' -Token ''
        $step = $r.Steps | Where-Object Name -eq 'OAuth for the mailbox'
        $step.Status | Should -Be 'Passed'
        $step.Details.AuthorizationUri | Should -Be 'https://adfs.contoso.test/adfs/oauth2/authorize'
        $step.Details.IssuerKind | Should -Be 'ADFS'
        $call = @(Get-Calls 'OPTIONS' | Where-Object Identity)
        $call.Count | Should -Be 1
        $call[0].Identity | Should -Be 'eas-test@contoso.test'
        $call[0].EmptyBearer | Should -BeTrue
    }

    It 'Discovery: a mailbox whose authentication policy blocks OAuth fails with the policy to check' {
        $script:Exchange.MailboxOAuth = 'Blocked'
        $r = Invoke-Scenario 'Discovery' -Token ''
        $step = $r.Steps | Where-Object Name -eq 'OAuth for the mailbox'
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -Match 'authentication policy'
        $step.Message | Should -Match 'BlockModernAuthActiveSync'
        $step.Details.Diagnostics | Should -Match 'oauth_not_available'
        ($r.Steps | Where-Object Name -eq 'OAuth challenge').Status | Should -Be 'Passed'
        $r.Status | Should -Be 'Failed'
    }

    It 'Discovery: a mailbox sent to another authorization server is a warning' {
        $script:Exchange.MailboxAuthorizationUri = 'https://login.microsoftonline.com/common/oauth2/authorize'
        $r = Invoke-Scenario 'Discovery' -Token ''
        $step = $r.Steps | Where-Object Name -eq 'OAuth for the mailbox'
        $step.Status | Should -Be 'Warning'
        $step.Message | Should -Match 'login.microsoftonline.com'
    }

    It 'AppleMail: the iPhone path passes and every request looks like an iPhone' {
        $apple = New-TestToken -AppId 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $script:Exchange.ValidToken = $apple
        $script:Exchange.RequireProvisioning = $true
        $r = Invoke-Scenario 'AppleMail' @{ AcknowledgePolicy = $true } -Token $apple
        $r.Status | Should -Be 'Passed'
        $r.Client | Should -Be 'AppleMail'
        $r.ClientId | Should -Be 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $r.DeviceType | Should -Be 'iPhone'
        $r.ProtocolVersion | Should -Be '16.1'
        ($r.Steps | Where-Object Stage -eq 'AppleSetup').Name | Should -Be @('Autodiscover', 'OAuth for the mailbox', 'Apple Mail client in AD FS')
        # Autodiscover with the Mail account, OAuth discovery with the Settings screen, AD FS page with Safari.
        $script:Exchange.WebCalls[0].UserAgent | Should -Match '^Apple-iPhone'
        (Get-Calls 'OPTIONS' | Where-Object Identity).UserAgent | Should -Match '^Preferences/'
        $authorize = @($script:Exchange.WebCalls | Where-Object Uri -match '/adfs/oauth2/authorize')
        $authorize.Count | Should -Be 3
        $authorize[0].Uri | Should -Match 'client_id=f8d98a96-0999-43f5-8af3-69971c7bb423'
        $authorize[0].Uri | Should -Match ('redirect_uri=' + [regex]::Escape([Uri]::EscapeDataString('com.apple.Preferences://oauth-redirect')) + '&')
        $authorize[0].Uri | Should -Match 'display=ios'
        $authorize[0].UserAgent | Should -Match 'Safari/605'
        # ActiveSync as an iPhone, the device information of an iPhone in Provision.
        foreach ($c in @($script:Exchange.Calls | Where-Object { $_.Command -ne 'OPTIONS' })) {
            $c.DeviceType | Should -Be 'iPhone'
            $c.UserAgent | Should -Be 'Apple-iPhone15C4/2401.539000006'
        }
        [Text.Encoding]::UTF8.GetString((Get-Calls 'Provision')[0].Body) | Should -Match 'iPhone15C4'
        (Get-Calls 'Sync').PolicyKey | Should -Be @('FINALKEY', 'FINALKEY')
    }

    It 'AppleMail: the iPhone is another device than the tool in Exchange' {
        $tool = Resolve-EomClientSettings -Configuration (@{ TestType = 'Full' } + $script:Config)
        $apple = Resolve-EomClientSettings -Configuration (@{ TestType = 'AppleMail' } + $script:Config)
        $apple.ClientId | Should -Be 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $tool.ClientId | Should -Be 'client'
        (Get-EomDeviceId -Mailbox $apple.Mailbox -DeviceType $apple.DeviceType) | Should -Not -Be (Get-EomDeviceId -Mailbox $tool.Mailbox -DeviceType $tool.DeviceType)
        $tool.ProtocolVersion | Should -Be '14.1'
    }

    It 'AppleMail: an AD FS without the Apple Mail client stops before the sign-in' {
        $script:Exchange.AppleClient = 'Missing'
        $r = Invoke-Scenario 'AppleMail' -Token ''
        $step = $r.Steps | Where-Object Name -eq 'Apple Mail client in AD FS'
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -Match 'MSIS9223'
        $step.Message | Should -Match 'Add-AdfsNativeClientApplication'
        @($r.Steps | Where-Object Status -eq 'Skipped').Count | Should -Be 5
        @(Get-Calls 'FolderSync').Count | Should -Be 0
    }

    It 'AppleMail: the redirect URI of the Settings screen missing in AD FS is a failure' {
        $script:Exchange.AppleClient = 'NoPreferencesRedirect'
        $r = Invoke-Scenario 'AppleMail' -Token ''
        $step = $r.Steps | Where-Object Name -eq 'Apple Mail client in AD FS'
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -Match 'com.apple.Preferences://oauth-redirect'
        $step.Message | Should -Match 'MSIS9224'
    }

    It 'AppleMail: a mailbox blocked for OAuth stops where the iPhone would fall back to a password' {
        $script:Exchange.MailboxOAuth = 'Blocked'
        $r = Invoke-Scenario 'AppleMail' -Token ''
        ($r.Steps | Where-Object Name -eq 'OAuth for the mailbox').Status | Should -Be 'Failed'
        @($script:Exchange.WebCalls | Where-Object Uri -match '/adfs/oauth2/authorize').Count | Should -Be 0
        $r.Status | Should -Be 'Failed'
    }

    It 'AppleMail: no Autodiscover is a warning, the account can still be added by hand' {
        $script:Exchange.AutodiscoverUrl = $null
        $apple = New-TestToken -AppId 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $script:Exchange.ValidToken = $apple
        $r = Invoke-Scenario 'AppleMail' -Token $apple
        ($r.Steps | Where-Object Name -eq 'Autodiscover').Status | Should -Be 'Warning'
        ($r.Steps | Where-Object Name -eq 'FolderSync').Status | Should -Be 'Passed'
    }

    It 'AppleMail: only the mailbox is needed, ActiveSync from Autodiscover and AD FS from the Exchange challenge' {
        $apple = New-TestToken -AppId 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $script:Exchange.ValidToken = $apple
        $cfg = InModule { $c = Get-EomDefaultConfiguration; $c.TestType = 'AppleMail'; $c.AdfsUrl = ''; $c.EasUrl = ''; $c.ClientId = ''; $c }
        (Test-EomConfiguration -Configuration $cfg).IsValid | Should -BeTrue
        $cfg.TestType = 'Full'
        (Test-EomConfiguration -Configuration $cfg).Problems | Should -Contain 'Target.AdfsUrl is required.'
        $r = Invoke-Scenario 'AppleMail' @{ AdfsUrl = ''; EasUrl = '' } -Token $apple
        $r.Status | Should -Be 'Passed'
        $r.EasUrl | Should -Be 'https://mail.contoso.test/Microsoft-Server-ActiveSync'
        $r.EasUrlSource | Should -Be 'Autodiscover'
        $r.AdfsUrl | Should -Be 'https://adfs.contoso.test/adfs'
        $r.AdfsUrlSource | Should -Match 'Exchange challenge'
        @(Get-Calls 'FolderSync').Count | Should -BeGreaterThan 0
    }

    It 'AppleMail: a configured AD FS URL is ignored, the iPhone goes where Exchange sends it' {
        $apple = New-TestToken -AppId 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $script:Exchange.ValidToken = $apple
        $r = Invoke-Scenario 'AppleMail' @{ AdfsUrl = 'https://sts.fabrikam.test/adfs' } -Token $apple
        $r.AdfsUrl | Should -Be 'https://adfs.contoso.test/adfs'
        @($script:Exchange.WebCalls | Where-Object Uri -match 'fabrikam').Count | Should -Be 0
        $r.Status | Should -Be 'Passed'
    }

    It 'AppleMail: no Autodiscover and no server typed stops, like the iPhone asking for the server' {
        $script:Exchange.AutodiscoverUrl = $null
        $r = Invoke-Scenario 'AppleMail' @{ AdfsUrl = ''; EasUrl = '' } -Token ''
        $step = $r.Steps | Where-Object Name -eq 'Autodiscover'
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -Match '-EasUrl'
        @($script:Exchange.Calls).Count | Should -Be 0
    }

    It 'AppleMail: an authorization URL that is not AD FS stops before the sign-in' {
        $script:Exchange.MailboxAuthorizationUri = 'https://login.microsoftonline.com/common/oauth2/authorize'
        $r = Invoke-Scenario 'AppleMail' @{ AdfsUrl = '' } -Token ''
        ($r.Steps | Where-Object Name -eq 'AD FS found').Status | Should -Be 'Failed'
        @($script:Exchange.WebCalls | Where-Object Uri -match 'oauth2/authorize').Count | Should -Be 0
    }

    It 'AppleMail: a token issued to another client is reported in the token claims' {
        $r = Invoke-Scenario 'AppleMail'
        $claims = $r.Steps | Where-Object Name -eq 'Token claims'
        $claims.Status | Should -Be 'Warning'
        $claims.Message | Should -Match 'd3590ed6-52b3-4102-aeff-aad2292ab01c, not to f8d98a96-0999-43f5-8af3-69971c7bb423'
    }

    It 'trace: each check keeps the requests it sent and the responses, WBXML decoded' {
        $script:Exchange.RequireProvisioning = $true
        $r = Invoke-Scenario 'Full' @{ AcknowledgePolicy = $true }
        @($r.Trace | Where-Object { $null -eq $_.Step }).Count | Should -Be 0
        $policy = $r.Steps | Where-Object Name -eq 'Policy'
        $exchanges = @($r.Trace | Where-Object { $_.Sequence -in $policy.Trace })
        $exchanges.Count | Should -Be 3
        $exchanges[0].StatusCode | Should -Be 449
        $exchanges[0].Request | Should -Match 'POST /Microsoft-Server-ActiveSync\?Cmd=FolderSync&'
        $exchanges[0].Request | Should -Match '<FolderSync>\s*<SyncKey>0</SyncKey>'
        $exchanges[0].Response | Should -Match '^HTTP/1.1 449 Retry With'
        $exchanges[1].Response | Should -Match '<PolicyKey>TEMPKEY</PolicyKey>'
        $exchanges[1].Label | Should -Be 'access token + policy key 0'
        $exchanges[2].Label | Should -Be 'access token + policy key TEMPKEY'
        $tls = $r.Trace | Where-Object Method -eq 'TLS' | Select-Object -First 1
        $tls.Response | Should -Match 'Trusted by this computer: yes'
    }

    It 'trace: the empty Bearer header is shown as sent, the forged token in full, the real token never' {
        $r = Invoke-Scenario 'Full'
        $challenge = $r.Steps | Where-Object Name -eq 'OAuth challenge'
        $empty = $r.Trace | Where-Object { $_.Sequence -in $challenge.Trace } | Select-Object -Last 1
        $empty.Label | Should -Be 'empty Bearer header'
        $empty.Request -split "`n" | Should -Contain 'Authorization: Bearer'
        ($r.Trace | Where-Object Label -eq 'forged token').Request | Should -Match ([regex]::Escape($script:InvalidTokenPayload))
        $json = $r.Trace | ConvertTo-Json -Depth 6
        $json | Should -Not -Match ([regex]::Escape($script:ValidToken.Split('.')[1]))
        $json | Should -Match 'access token: \d+ characters, never written'
    }

    It 'trace: AD FS sign-in requests with codes and tokens masked, polling counted once' {
        Mock -ModuleName EasOAuthMailbox Wait-EomSeconds { }
        Mock -ModuleName EasOAuthMailbox Start-Process { }
        $script:Exchange.TokenPendingPolls = 3
        $r = Invoke-Scenario 'OAuth' -Token ''
        $r.Status | Should -Be 'Passed'
        $sign = $r.Steps | Where-Object Name -eq 'Device-code sign-in'
        $calls = @($r.Trace | Where-Object { $_.Sequence -in $sign.Trace })
        $calls.Count | Should -Be 3
        $calls[0].Request | Should -Match 'POST /adfs/oauth2/devicecode'
        $calls[0].Response | Should -Match '"user_code": "QDZ8-HKWP"'
        $calls[1].Repeated | Should -Be 3
        $calls[1].Response | Should -Match 'authorization_pending'
        $calls[2].StatusCode | Should -Be 200
        $json = $r.Trace | ConvertTo-Json -Depth 6
        foreach ($secret in 'SimDeviceCode', 'SimRefreshToken', $script:ValidToken.Split('.')[1]) { $json | Should -Not -Match ([regex]::Escape($secret)) }
        $json | Should -Match 'device_code=<\d+ characters, never written>'
    }

    It 'returns the same result shape for every scenario, with one duration per step' {
        foreach ($type in 'OAuth', 'Endpoint', 'Full') {
            $r = Invoke-Scenario $type
            foreach ($p in 'Status', 'Steps', 'Folders', 'Messages', 'PolicySettings', 'Identity', 'Token', 'Counts', 'Error') { $r.PSObject.Properties.Name | Should -Contain $p }
            foreach ($s in $r.Steps) { $s.DurationMs | Should -BeOfType [int] }
        }
    }
}

Describe 'Report' {
    BeforeAll {
        $script:Exchange = New-SimState
        $script:Exchange.RequireProvisioning = $true
        Mock -ModuleName EasOAuthMailbox Send-EomHttpRequest { Get-SimHttpResponse -Request $Request -State $script:Exchange }
        $cfg = $script:Config.Clone()
        $cfg.AcknowledgePolicy = $true
        $script:Result = Invoke-EomMailboxTest -Configuration $cfg -TestType InboxSync -AccessToken $script:ValidToken -Quiet
        $script:ReportOut = Join-Path $script:Root 'artifacts\report-test'
        Remove-Item $script:ReportOut -Recurse -Force -ErrorAction SilentlyContinue
        $script:Report = Export-EomReport -Result $script:Result -OutputPath $script:ReportOut
    }

    It 'writes the five CSV files, the JSON summary and the HTML dashboard' {
        foreach ($name in 'Steps', 'Folders', 'Messages', 'Policy', 'Trace', 'Summary', 'Html') { Test-Path -LiteralPath $script:Report.Files[$name] | Should -BeTrue }
        Split-Path $script:Report.Directory -Leaf | Should -Match '^EasOAuthMailbox_InboxSync_\d{8}-\d{6}'
        (Import-Csv $script:Report.Files.Policy -Delimiter ';').Setting | Should -Be @('DevicePasswordEnabled', 'MinDevicePasswordLength')
    }

    It 'writes the HTTP trace: every request sent and the response received, attached to its check' {
        Test-Path -LiteralPath $script:Report.Files.Trace | Should -BeTrue
        $trace = @(Import-Csv $script:Report.Files.Trace -Delimiter ';')
        $trace.Count | Should -Be @($script:Result.Trace).Count
        $trace[0].Request | Should -Match '^OPTIONS /Microsoft-Server-ActiveSync HTTP/1.1'
        (Import-Csv $script:Report.Files.Steps -Delimiter ';')[0].PSObject.Properties.Name | Should -Contain 'Trace'
        [IO.File]::ReadAllText($script:Report.Files.Html) | Should -Match 'id="data-trace"'
    }

    It 'never writes the access token' {
        foreach ($file in Get-ChildItem $script:Report.Directory -File) { [IO.File]::ReadAllText($file.FullName) | Should -Not -Match ([regex]::Escape($script:ValidToken.Split('.')[1])) }
    }

    It 'neutralises spreadsheet formulas in CSV text cells but not in numbers' {
        $csv = [IO.File]::ReadAllText($script:Report.Files.Messages)
        $csv | Should -Match ([regex]::Escape(';"''=HYPERLINK(""http://x"")";'))
        $cell = InModule { Format-EomCsvCell -Value 42 -Delimiter ';' }
        $cell | Should -Be '42'
        InModule { Format-EomCsvCell -Value '-1' -Delimiter ';' } | Should -Be "'-1"
    }

    It 'fills every marker of the template with JSON that cannot close the script block' {
        $html = [IO.File]::ReadAllText($script:Report.Files.Html)
        $html | Should -Not -Match '\{\{[A-Z_]+\}\}'
        $html | Should -Match '\\u003calice@contoso.test\\u003e'
        $html | Should -Not -Match '<alice@contoso.test>'
    }

    It 'creates a new folder for each execution, even in the same second' {
        $a = Export-EomReport -Result $script:Result -OutputPath $script:ReportOut -Formats Csv
        $b = Export-EomReport -Result $script:Result -OutputPath $script:ReportOut -Formats Csv
        $a.Directory | Should -Not -Be $b.Directory
    }
}

Describe 'Window' -Skip:(-not $IsWindows) {
    BeforeAll {
        $script:Window = New-EomTestForm -Configuration (Import-EomConfiguration)
        $f = $script:Window.Form
        $f.StartPosition = 'Manual'
        $f.Location = [Drawing.Point]::new(-5000, -5000)
        $f.Show()
        [Windows.Forms.Application]::DoEvents()
    }
    AfterAll { if (-not $script:Window.Form.IsDisposed) { $script:Window.Form.Close(); $script:Window.Form.Dispose() } }

    It 'shows header, target, scenario, actions and progress from top to bottom' {
        $c = $script:Window.Controls
        $tops = foreach ($name in 'Header', 'Target', 'Scenario', 'Actions', 'Progress') { $script:Window.Form.PointToClient($c[$name].PointToScreen([Drawing.Point]::Empty)).Y }
        for ($i = 1; $i -lt $tops.Count; $i++) { $tops[$i] | Should -BeGreaterThan $tops[$i - 1] }
    }

    It 'updates the description, the policy checkbox and the warning with the scenario' {
        $c = $script:Window.Controls
        $c.TestType.SelectedItem = 'Discovery'; [Windows.Forms.Application]::DoEvents()
        $c.Acknowledge.Enabled | Should -BeFalse
        $c.Warning.Text | Should -Match 'No sign-in'
        $c.TestType.SelectedItem = 'InboxSync'; [Windows.Forms.Application]::DoEvents()
        $c.Acknowledge.Enabled | Should -BeTrue
        $c.Description.Text | Should -Match 'Inbox headers'
    }

    It 'lists invalid values in the progress box without running anything' {
        $c = $script:Window.Controls
        $c.Mailbox.Text = ''
        $c.MessageCount.Text = 'abc'
        InModule { Invoke-EomGuiRun }
        $c.Log.Text | Should -Match 'Target.Mailbox is required'
        $c.Log.Text | Should -Match 'Test.MessageCount must be'
        $c.Status.Text | Should -Be 'Fix the values above.'
        $c.Run.Enabled | Should -BeTrue
    }

    It 'scales with the screen DPI: button texts and header lines are not cut' {
        $c = $script:Window.Controls
        $script:Window.Form.AutoScaleMode | Should -Be ([Windows.Forms.AutoScaleMode]::Dpi)
        foreach ($name in 'Run', 'Cancel', 'OpenReport', 'OpenFolder', 'Close') {
            $b = $c[$name]
            ([Windows.Forms.TextRenderer]::MeasureText($b.Text, $b.Font).Width + 8) | Should -BeLessOrEqual $b.ClientSize.Width -Because "'$($b.Text)' must fit its button"
        }
        foreach ($line in $c.Header.Controls) { $line.Bottom | Should -BeLessOrEqual $c.Header.ClientSize.Height -Because "'$($line.Text)' must stay in the header" }
    }

    It 'closes natively (Close button, Esc): no PowerShell code has to run to close the window' {
        # A PowerShell event handler fails once the command that opened the window is stopped
        # (Ctrl+C, stop button of an editor); the window must still close in that case.
        $c = $script:Window.Controls
        $c.Close.DialogResult | Should -Be ([Windows.Forms.DialogResult]::Cancel)
        [object]::ReferenceEquals($script:Window.Form.CancelButton, $c.Close) | Should -BeTrue
    }

    It 'refuses to close during a run, asks the run to stop, then closes normally' {
        $c = $script:Window.Controls
        $c.Mailbox.Text = 'eas-test@contoso.test'
        $c.MessageCount.Text = '5'
        $c.TestType.SelectedItem = 'Discovery'
        Mock -ModuleName EasOAuthMailbox Write-EomLog { }
        Mock -ModuleName EasOAuthMailbox Invoke-EomMailboxTest {
            $script:Window.Form.Close()
            [Windows.Forms.Application]::DoEvents()
            $script:DuringRun = @{ Visible = $script:Window.Form.Visible; Cancel = (InModule { $script:Ui.Cancel }) }
            throw 'simulated end of run'
        }
        InModule { Invoke-EomGuiRun }
        $script:DuringRun.Visible | Should -BeTrue
        $script:DuringRun.Cancel | Should -BeTrue
        $c.Log.Text | Should -Match 'A test is running'
        $c.Close.Enabled | Should -BeTrue

        $script:Window.Form.Close()
        [Windows.Forms.Application]::DoEvents()
        $script:Window.Form.Visible | Should -BeFalse
    }
}
