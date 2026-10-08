#Requires -Version 7.4
#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '6.1.0' }
<#
    EAS OAuth Mailbox - automated tests (Pester 6.1 or later).
    Author  : Nicolas Fabert
    Version : 1.2.1

    Run:  .\Run-Tests.ps1      (or Invoke-Pester -Path .\tests -Output Detailed)

    No AD FS and no Exchange server are needed. The scenarios run against a simulated Exchange:
    Invoke-EasRequest is replaced by a mock that answers with WBXML documents built byte by byte
    with the code pages of MS-ASWBXML (FolderSync, Provision, Settings, Sync), HTTP 401 / 403 / 449
    and the WWW-Authenticate / x-ms-diagnostics headers of Exchange. Tokens are unsigned JWTs.
#>

BeforeAll {
    $script:RepoRoot = Split-Path $PSScriptRoot -Parent
    $script:Root = Join-Path $script:RepoRoot 'package'
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
    $script:OnlineUrl = 'https://outlook.office365.com/Microsoft-Server-ActiveSync'
    $script:InvalidTokenPayload = (& $script:Module { $script:InvalidToken }).Split('.')[1]
    $script:Config = @{
        AdfsUrl = 'https://adfs.contoso.test/adfs'; EasUrl = 'https://mail.contoso.test/Microsoft-Server-ActiveSync'
        Mailbox = 'eas-test@contoso.test'; ClientId = 'client'; DeviceId = 'TESTDEVICE01'
        # The device code unless a test opens the (simulated) sign-in window: no browser is ever started by the tests.
        SignIn = 'DeviceCode'
        OutputPath = (Join-Path $script:RepoRoot 'artifacts\test-reports'); LogPath = (Join-Path $script:RepoRoot 'artifacts\test-logs')
    }
    function Invoke-Scenario([string]$Type, [hashtable]$Overrides = @{}, [string]$Token = $script:ValidToken) {
        $cfg = $script:Config.Clone(); foreach ($k in $Overrides.Keys) { $cfg[$k] = $Overrides[$k] }
        Invoke-EomMailboxTest -Configuration $cfg -TestType $Type -AccessToken $Token -Quiet
    }
    function Get-Calls([string]$Command) { @($script:Exchange.Calls | Where-Object Command -eq $Command) }
    $script:BasicPassword = 'Sim-Pa55word!'
    function Invoke-BasicScenario([string]$Type, [hashtable]$Overrides = @{}, [string]$Password = $script:BasicPassword, [string]$User = 'eas-test@contoso.test', [switch]$NoCredential) {
        $cfg = $script:Config.Clone(); $cfg.Authentication = 'Basic'; foreach ($k in $Overrides.Keys) { $cfg[$k] = $Overrides[$k] }
        $credential = if ($NoCredential) { $null } else { [pscredential]::new($User, (ConvertTo-SecureString $Password -AsPlainText -Force)) }
        Invoke-EomMailboxTest -Configuration $cfg -TestType $Type -Credential $credential -Quiet
    }
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
        $path = Join-Path $script:RepoRoot 'artifacts\bad.config.psd1'
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

    It 'Basic needs neither AD FS nor a client ID, refuses the OAuth scenario and checks the user name' {
        $cfg = InModule { $c = Get-EomDefaultConfiguration; $c.Authentication = 'Basic'; $c.AdfsUrl = ''; $c.ClientId = ''; $c }
        (Test-EomConfiguration -Configuration $cfg).IsValid | Should -BeTrue
        $cfg.BasicUser = 'CONTOSO\eas-test'
        (Test-EomConfiguration -Configuration $cfg).IsValid | Should -BeTrue
        $cfg.BasicUser = 'eas:test@contoso.test'
        (Test-EomConfiguration -Configuration $cfg).Problems | Should -Contain 'Target.BasicUser must be empty (= Target.Mailbox), a UPN (user@domain) or DOMAIN\user.'
        $cfg.BasicUser = ''
        $cfg.TestType = 'OAuth'
        (Test-EomConfiguration -Configuration $cfg).Problems -join ' ' | Should -Match 'The OAuth scenario tests the AD FS sign-in'
        $cfg.TestType = 'Full'
        $cfg.Authentication = 'NTLM'
        (Test-EomConfiguration -Configuration $cfg).Problems | Should -Contain "Test.Authentication must be 'OAuth' or 'Basic'."
    }

    It 'replaces the AD FS sign-in by the Basic sign-in in every scenario' {
        InModule { Get-EomScenarioStages -TestType 'Full' -Authentication 'Basic' } | Should -Be @('Discovery', 'Basic', 'Endpoint', 'FolderSync', 'Identity', 'InboxSync')
        InModule { Get-EomScenarioStages -TestType 'AppleMail' -Authentication 'Basic' } | Should -Be @('AppleSetup', 'Basic', 'Endpoint', 'FolderSync', 'Identity', 'InboxSync')
        InModule { Get-EomScenarioStages -TestType 'Full' } | Should -Contain 'OAuth'
        InModule { Get-EomStageTitle -Stage 'Endpoint' -Authentication 'Basic' } | Should -Be 'ActiveSync endpoint with the user name and password'
    }

    It 'Entra ID and Auto need no AD FS URL; the authority and the tenant are checked' {
        $cfg = InModule { $c = Get-EomDefaultConfiguration; $c.Authority = 'EntraID'; $c.AdfsUrl = ''; $c }
        (Test-EomConfiguration -Configuration $cfg).IsValid | Should -BeTrue
        $cfg.Authority = 'Auto'
        (Test-EomConfiguration -Configuration $cfg).IsValid | Should -BeTrue
        $cfg.Authority = 'ADFS'
        (Test-EomConfiguration -Configuration $cfg).Problems | Should -Contain 'Target.AdfsUrl is required.'
        $cfg.Authority = 'Okta'; $cfg.AdfsUrl = 'https://adfs.contoso.test/adfs'
        (Test-EomConfiguration -Configuration $cfg).Problems | Should -Contain "Target.Authority must be 'ADFS', 'EntraID' or 'Auto'."
        $cfg.Authority = 'EntraID'
        foreach ($ok in '', '7d4e2a91-3c5b-4f6e-8a1d-2b9c0e5f4a37', 'contoso.onmicrosoft.com') { $cfg.TenantId = $ok; (Test-EomConfiguration -Configuration $cfg).IsValid | Should -BeTrue }
        $cfg.TenantId = 'not a tenant'
        (Test-EomConfiguration -Configuration $cfg).Problems -join ' ' | Should -Match 'Target.TenantId must be'
        $ep = InModule { Resolve-EomEndpoints @{ Authority = 'EntraID'; TenantId = 'contoso.test'; EasUrl = 'https://mail.contoso.test/Microsoft-Server-ActiveSync' } }
        $ep.DeviceCodeEndpoint | Should -Be 'https://login.microsoftonline.com/contoso.test/oauth2/v2.0/devicecode'
        $ep.Scope | Should -Be 'https://mail.contoso.test/EAS.AccessAsUser.All'
        InModule { Get-EomStageTitle -Stage 'OAuth' -Authority 'EntraID' } | Should -Match '^Entra ID sign-in'
    }

    It 'Exchange Online: recognised from the URL; AD FS and a Basic sign-in are refused, Basic Discovery is allowed' {
        $ep = InModule { Resolve-EomEndpoints @{ Authority = 'EntraID'; TenantId = 'contoso.test'; EasUrl = 'https://outlook.office365.com/Microsoft-Server-ActiveSync' } }
        $ep.ExchangeOnline | Should -BeTrue
        $ep.Scope | Should -Be 'https://outlook.office365.com/EAS.AccessAsUser.All'
        (InModule { Resolve-EomEndpoints @{ EasUrl = 'https://mail.contoso.test/Microsoft-Server-ActiveSync' } }).ExchangeOnline | Should -BeFalse
        $cfg = InModule { $c = Get-EomDefaultConfiguration; $c.Authority = 'EntraID'; $c.AdfsUrl = ''; $c.EasUrl = 'https://outlook.office365.com/Microsoft-Server-ActiveSync'; $c }
        (Test-EomConfiguration -Configuration $cfg).IsValid | Should -BeTrue
        $cfg.Authority = 'ADFS'; $cfg.AdfsUrl = 'https://adfs.contoso.test/adfs'
        (Test-EomConfiguration -Configuration $cfg).Problems -join ' ' | Should -Match 'Exchange Online accepts only Entra ID tokens'
        $cfg.Authentication = 'Basic'
        (Test-EomConfiguration -Configuration $cfg).Problems -join ' ' | Should -Match 'Exchange Online no longer accepts Basic authentication'
        $cfg.TestType = 'Discovery'
        (Test-EomConfiguration -Configuration $cfg).IsValid | Should -BeTrue
        # AppleMail takes the URL from Autodiscover: the Basic stage decides (see the scenarios).
        $cfg.TestType = 'AppleMail'
        (Test-EomConfiguration -Configuration $cfg).IsValid | Should -BeTrue
    }

    It 'an HTTP 451 to Exchange Online says to test it with Entra ID; another URL is only named' {
        $advice = InModule { Get-EasRedirectAdvice -Response ([pscustomobject]@{ Headers = @{ 'X-MS-Location' = 'https://outlook.office365.com/Microsoft-Server-ActiveSync/' } }) }
        $advice | Should -Match 'the mailbox is in Exchange Online'
        $advice | Should -Match '-EasUrl https://outlook\.office365\.com/Microsoft-Server-ActiveSync and Entra ID'
        InModule { Get-EasRedirectAdvice -Response ([pscustomobject]@{ Headers = @{ 'X-MS-Location' = 'https://mail2.contoso.test/Microsoft-Server-ActiveSync' } }) } | Should -Be 'test that URL.'
    }

    It 'reads the authorization server of a challenge: AD FS, Entra ID and its tenant, other' {
        (InModule { Get-EomAuthorityInfo 'https://adfs.contoso.test/adfs/oauth2/authorize' }).AdfsRoot | Should -Be 'https://adfs.contoso.test/adfs'
        $entra = InModule { Get-EomAuthorityInfo 'https://login.windows.net/common/oauth2/authorize' }
        $entra.Kind | Should -Be 'EntraID'
        $entra.Tenant | Should -Be 'common'
        (InModule { Get-EomAuthorityInfo 'https://login.microsoftonline.com/7d4e2a91-3c5b-4f6e-8a1d-2b9c0e5f4a37/oauth2/authorize' }).Tenant | Should -Be '7d4e2a91-3c5b-4f6e-8a1d-2b9c0e5f4a37'
        (InModule { Get-EomAuthorityInfo 'https://sts.fabrikam.test/oauth2/authorize' }).Kind | Should -Be 'Other'
        (InModule { Get-EomAuthorityInfo '' }).Kind | Should -Be 'None'
        $info = InModule { Get-EomChallengeInfo -Challenges @('Bearer client_id="x", trusted_issuers="00000001-0000-0000-c000-000000000000@7d4e2a91-3c5b-4f6e-8a1d-2b9c0e5f4a37", authorization_uri="https://login.windows.net/common/oauth2/authorize", issuer_kind="AzureAD"') }
        $info.TrustedIssuers | Should -Be @('00000001-0000-0000-c000-000000000000@7d4e2a91-3c5b-4f6e-8a1d-2b9c0e5f4a37')
        $info.IssuerKind | Should -Be 'AzureAD'
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

    It 'accepts every audience of Exchange Online for Exchange Online, but not for an on-premises URL' {
        foreach ($audience in 'https://outlook.office365.com', 'https://outlook.office.com/', '00000002-0000-0ff1-ce00-000000000000') {
            $t = New-SimEntraToken -Audience $audience
            $r = InModule { param($t) Test-EomTokenClaims -Claims (Get-EomTokenClaims $t) -Endpoints (Resolve-EomEndpoints @{ Authority = 'EntraID'; EasUrl = 'https://outlook.office365.com/Microsoft-Server-ActiveSync' }) -Mailbox 'eas-test@contoso.test' } $t
            $r.Status | Should -Be 'Passed'
        }
        $r = InModule { param($t) Test-EomTokenClaims -Claims (Get-EomTokenClaims $t) -Endpoints (Resolve-EomEndpoints @{ Authority = 'EntraID'; EasUrl = 'https://mail.contoso.test/Microsoft-Server-ActiveSync' }) -Mailbox 'eas-test@contoso.test' } $t
        $r.Status | Should -Be 'Warning'
        $r.Message | Should -Match 'the token is for Exchange Online, not for the on-premises URL'
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

    It 'sends Basic credentials as user:password in base64 and shows only the user name in the trace' {
        $credential = [pscredential]::new('eas-test@contoso.test', (ConvertTo-SecureString 'Pa55:word é' -AsPlainText -Force))
        $request = InModule { param($c) New-EasRequestMessage -Method ([Net.Http.HttpMethod]::Options) -Uri 'https://mail.contoso.test/Microsoft-Server-ActiveSync' -Credential $c } $credential
        $request.Headers.Authorization.Scheme | Should -BeExactly 'Basic'
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($request.Headers.Authorization.Parameter)) | Should -BeExactly 'eas-test@contoso.test:Pa55:word é'
        $shown = InModule { param($v) Protect-EomHeaderValue -Name 'Authorization' -Value $v } $request.Headers.Authorization.ToString()
        $shown | Should -BeExactly 'Basic <user eas-test@contoso.test, password never written>'
        InModule { Protect-EomHeaderValue -Name 'Authorization' -Value 'Basic bm90LWEtcGFpcg==' } | Should -Match '^Basic <credentials: \d+ characters, never written>$'
        $request.Dispose()
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

    It 'Discovery: a TLS handshake closed before the certificate is a network failure, not an untrusted certificate' {
        Mock -ModuleName EasOAuthMailbox Get-EomTlsCertificate {
            [pscustomobject]@{ HostName = $HostName; Port = $Port; Reachable = $true; Valid = $false; Interrupted = $true; Subject = $null; Issuer = $null; NotAfterUtc = $null; DaysLeft = $null; Protocol = $null; Error = 'An existing connection was forcibly closed by the remote host.' }
        }
        $r = Invoke-Scenario 'Discovery' -Token ''
        $step = @($r.Steps | Where-Object Name -like 'TLS certificate*')[0]
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -Match 'handshake interrupted'
        $step.Message | Should -Match 'certificate is not in question'
        $step.Message | Should -Not -Match 'not trusted'
    }

    It 'Discovery: a certificate received and rejected is still reported as not trusted' {
        Mock -ModuleName EasOAuthMailbox Get-EomTlsCertificate {
            [pscustomobject]@{ HostName = $HostName; Port = $Port; Reachable = $true; Valid = $false; Interrupted = $false; Subject = $null; Issuer = $null; NotAfterUtc = $null; DaysLeft = $null; Protocol = $null; Error = 'The remote certificate is invalid: RemoteCertificateChainErrors (UntrustedRoot)' }
        }
        $r = Invoke-Scenario 'Discovery' -Token ''
        $step = @($r.Steps | Where-Object Name -like 'TLS certificate*')[0]
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -Match 'not trusted by this computer.*UntrustedRoot'
    }

    It 'a connection reset during the TLS handshake gives the socket reason, not the PowerShell wrapper' {
        Mock -ModuleName EasOAuthMailbox Send-EomHttpRequest {
            $socket = [Net.Sockets.SocketException]::new(10054)
            $io = [IO.IOException]::new('Unable to read data from the transport connection.', $socket)
            $http = [Net.Http.HttpRequestException]::new('The SSL connection could not be established, see inner exception.', $io)
            throw [Management.Automation.MethodInvocationException]::new('Exception calling "GetResult" with "0" argument(s): "The SSL connection could not be established, see inner exception."', $http)
        }
        $r = Invoke-Scenario 'Discovery' -Token ''
        $step = $r.Steps | Where-Object Name -eq 'OAuth challenge'
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -BeLike "ActiveSync not reachable: The SSL connection could not be established: $([Net.Sockets.SocketException]::new(10054).Message)*"
        $step.Message | Should -Not -Match 'GetResult|see inner exception'
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

    It 'AppleMail: an authorization URL that is neither AD FS nor Entra ID stops before the sign-in' {
        $script:Exchange.MailboxAuthorizationUri = 'https://sts.fabrikam.test/oauth2/authorize'
        $r = Invoke-Scenario 'AppleMail' @{ AdfsUrl = '' } -Token ''
        ($r.Steps | Where-Object Name -eq 'Authorization server').Status | Should -Be 'Failed'
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

    It 'Basic Full: no AD FS request, every ActiveSync request carries the user name and password' {
        $script:Exchange.MailboxOAuth = 'Blocked'
        $script:Exchange.RequireProvisioning = $true
        $r = Invoke-BasicScenario 'Full' @{ AcknowledgePolicy = $true }
        $r.Status | Should -Be 'Passed'
        $r.Authentication | Should -Be 'Basic'
        $r.BasicUser | Should -Be 'eas-test@contoso.test'
        $r.AdfsUrl | Should -BeNullOrEmpty
        $r.ClientId | Should -BeNullOrEmpty
        ($r.Steps | Where-Object Stage -eq 'Basic').Name | Should -Be 'Basic sign-in'
        @($r.Steps | Where-Object Stage -eq 'OAuth').Count | Should -Be 0
        @($r.Trace | Where-Object Url -match '/adfs/').Count | Should -Be 0
        @($r.Trace | Where-Object Url -match 'adfs\.contoso').Count | Should -Be 0
        foreach ($c in @($script:Exchange.Calls | Where-Object { $_.Command -ne 'OPTIONS' })) { $c.BasicUser | Should -Be 'eas-test@contoso.test' }
        (Get-Calls 'Sync').PolicyKey | Should -Be @('FINALKEY', 'FINALKEY')
        ($r.Steps | Where-Object Name -eq 'OPTIONS').Message | Should -Match '^User name and password accepted'
    }

    It 'Basic Discovery: Basic offered, OAuth for the mailbox read for Basic, wrong password with a user that does not exist' {
        $r = Invoke-BasicScenario 'Discovery' -NoCredential
        $r.Steps.Name | Should -Be @('TLS certificate (mail.contoso.test)', 'Basic challenge', 'OAuth for the mailbox', 'Wrong password')
        ($r.Steps | Where-Object Name -eq 'Basic challenge').Message | Should -Match 'realm mail.contoso.test'
        # The mailbox is offered OAuth: Outlook and the iPhone will not use Basic.
        $oauth = $r.Steps | Where-Object Name -eq 'OAuth for the mailbox'
        $oauth.Status | Should -Be 'Warning'
        $oauth.Message | Should -Match 'sign in with AD FS, without the password'
        $wrong = Get-Calls 'OPTIONS' | Where-Object BasicUser
        @($wrong).Count | Should -Be 1
        $wrong.BasicUser | Should -Match '^eom-invalid-[0-9a-f]{12}@contoso\.test$'
        ($r.Steps | Where-Object Name -eq 'Wrong password').Status | Should -Be 'Passed'
        ($r.Trace | Where-Object Label -eq 'wrong user name and password').Request | Should -Match 'Authorization: Basic <user eom-invalid-'
    }

    It 'Basic Discovery: a mailbox without OAuth is what Basic needs' {
        $script:Exchange.MailboxOAuth = 'Blocked'
        $r = Invoke-BasicScenario 'Discovery' -NoCredential
        $r.Status | Should -Be 'Passed'
        ($r.Steps | Where-Object Name -eq 'OAuth for the mailbox').Message | Should -Match 'ask for the password and use Basic authentication'
    }

    It 'Basic Discovery: Basic disabled on ActiveSync is a failure' {
        $script:Exchange.BasicEnabled = $false
        $r = Invoke-BasicScenario 'Discovery' -NoCredential
        $step = $r.Steps | Where-Object Name -eq 'Basic challenge'
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -Match 'BasicAuthEnabled'
    }

    It 'Basic: a wrong password is sent only once, then the run stops' {
        $r = Invoke-BasicScenario 'InboxSync' -Password 'wrong'
        $r.Status | Should -Be 'Failed'
        $sign = $r.Steps | Where-Object Name -eq 'Basic sign-in'
        $sign.Status | Should -Be 'Failed'
        $sign.Message | Should -Match 'sent only once'
        $sign.Message | Should -Match 'BlockLegacyAuthActiveSync'
        @($script:Exchange.Calls | Where-Object BasicUser -eq 'eas-test@contoso.test').Count | Should -Be 1
        @($r.Steps | Where-Object Status -eq 'Skipped').Count | Should -Be 3
    }

    It 'Basic: no credential refuses to start, except Discovery that sends none' {
        { Invoke-BasicScenario 'Endpoint' -NoCredential } | Should -Throw '*-Credential*'
        @($script:Exchange.Calls).Count | Should -Be 0
        (Invoke-BasicScenario 'Discovery' -NoCredential).Steps.Count | Should -Be 4
    }

    It 'AppleMail Basic: a mailbox without OAuth, the iPhone asks for the password and syncs as an iPhone' {
        $script:Exchange.MailboxOAuth = 'Blocked'
        $r = Invoke-BasicScenario 'AppleMail' @{ AdfsUrl = ''; EasUrl = '' }
        $r.Status | Should -Be 'Passed'
        ($r.Steps | Where-Object Stage -eq 'AppleSetup').Name | Should -Be @('Autodiscover', 'OAuth for the mailbox')
        ($r.Steps | Where-Object Name -eq 'OAuth for the mailbox').Message | Should -Match 'the iPhone asks for the password and uses Basic'
        @($script:Exchange.WebCalls | Where-Object Uri -match '/adfs/').Count | Should -Be 0
        foreach ($c in @($script:Exchange.Calls | Where-Object BasicUser)) { $c.UserAgent | Should -Be 'Apple-iPhone15C4/2401.539000006' }
        $r.ProtocolVersion | Should -Be '16.1'
    }

    It 'AppleMail Basic: a mailbox offered OAuth is a warning, the iPhone would open AD FS' {
        $r = Invoke-BasicScenario 'AppleMail'
        $step = $r.Steps | Where-Object Name -eq 'OAuth for the mailbox'
        $step.Status | Should -Be 'Warning'
        $step.Message | Should -Match 'AppleMail without -Authentication Basic'
        ($r.Steps | Where-Object Name -eq 'FolderSync').Status | Should -Be 'Passed'
    }

    It 'Basic: the password never reaches the result, the trace or the report' {
        $r = Invoke-BasicScenario 'Full' @{ AcknowledgePolicy = $true }
        $out = Join-Path $script:RepoRoot 'artifacts\report-basic'
        Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue
        $report = Export-EomReport -Result $r -OutputPath $out
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("eas-test@contoso.test:$script:BasicPassword"))
        foreach ($file in Get-ChildItem $report.Directory -File) {
            $text = [IO.File]::ReadAllText($file.FullName)
            $text | Should -Not -Match ([regex]::Escape($script:BasicPassword))
            $text | Should -Not -Match ([regex]::Escape($encoded))
        }
        ($r | ConvertTo-Json -Depth 8) | Should -Not -Match ([regex]::Escape($script:BasicPassword))
        [IO.File]::ReadAllText($report.Files.Html) | Should -Match '"Authentication":"Basic"'
    }

    It 'HMA Discovery: Entra ID tenant and realm, challenge naming Entra ID, tenant trusted, no AD FS request' {
        $script:Exchange.Authority = 'EntraID'
        $r = Invoke-Scenario 'Discovery' @{ Authority = 'EntraID'; AdfsUrl = '' } -Token ''
        $r.Status | Should -Be 'Passed'
        $r.Steps.Name | Should -Be @('Entra ID tenant', 'User realm', 'TLS certificate (mail.contoso.test)', 'OAuth challenge', 'OAuth for the mailbox', 'Tenant trusted by Exchange', 'Invalid token')
        $r.TenantId | Should -Be $script:SimTenantId
        $r.Authority | Should -Be 'EntraID'
        $r.AuthorityUrl | Should -Be "https://login.microsoftonline.com/$script:SimTenantId"
        ($r.Steps | Where-Object Name -eq 'OAuth challenge').Message | Should -Match 'hybrid modern authentication'
        ($r.Steps | Where-Object Name -eq 'OAuth for the mailbox').Message | Should -Match 'sign in with Entra ID'
        @($r.Trace | Where-Object Url -match 'adfs').Count | Should -Be 0
        ($r.Trace | Where-Object Url -match 'openid-configuration').Url | Should -Be 'https://login.microsoftonline.com/contoso.test/v2.0/.well-known/openid-configuration'
    }

    It 'HMA Discovery: an Exchange still on AD FS is a warning that names the EvoSts command' {
        $r = Invoke-Scenario 'Discovery' @{ Authority = 'EntraID'; AdfsUrl = '' } -Token ''
        $step = $r.Steps | Where-Object Name -eq 'OAuth for the mailbox'
        $step.Status | Should -Be 'Warning'
        $step.Message | Should -Match 'hybrid modern authentication is not enabled'
        $step.Message | Should -Match 'IsDefaultAuthorizationEndpoint'
    }

    It 'AD FS Discovery: an Exchange that sends clients to Entra ID says HMA is enabled' {
        $script:Exchange.Authority = 'EntraID'
        $r = Invoke-Scenario 'Discovery' -Token ''
        ($r.Steps | Where-Object Name -eq 'OAuth for the mailbox').Message | Should -Match 'Test it with -Authority EntraID'
    }

    It 'HMA: a tenant unknown to Entra ID fails, a realm unknown is a warning, another trusted tenant is a warning' {
        $script:Exchange.Authority = 'EntraID'
        $r = Invoke-Scenario 'Discovery' @{ Authority = 'EntraID'; AdfsUrl = ''; Mailbox = 'eas-test@fabrikam.test' } -Token ''
        $tenant = $r.Steps | Where-Object Name -eq 'Entra ID tenant'
        $tenant.Status | Should -Be 'Failed'
        $tenant.Message | Should -Match 'AADSTS90002'
        $script:Exchange = New-SimState; $script:Exchange.Authority = 'EntraID'; $script:Exchange.UserRealm = 'Unknown'; $script:Exchange.TrustedTenantId = '11111111-2222-3333-4444-555555555555'
        $r = Invoke-Scenario 'Discovery' @{ Authority = 'EntraID'; AdfsUrl = '' } -Token ''
        ($r.Steps | Where-Object Name -eq 'User realm').Status | Should -Be 'Warning'
        $trusted = $r.Steps | Where-Object Name -eq 'Tenant trusted by Exchange'
        $trusted.Status | Should -Be 'Warning'
        $trusted.Message | Should -Match '11111111-2222-3333-4444-555555555555'
    }

    It 'HMA Full: device code with Entra ID v2.0, token for the on-premises URL and the tenant, mailbox synchronised' {
        Mock -ModuleName EasOAuthMailbox Wait-EomSeconds { }
        Mock -ModuleName EasOAuthMailbox Start-Process { }
        $script:Exchange.Authority = 'EntraID'
        $script:Exchange.ValidToken = New-SimEntraToken
        $script:Exchange.RequireProvisioning = $true
        $r = Invoke-Scenario 'Full' @{ Authority = 'EntraID'; AdfsUrl = ''; AcknowledgePolicy = $true } -Token ''
        $r.Status | Should -Be 'Passed'
        $sign = $r.Steps | Where-Object Name -eq 'Device-code sign-in'
        $sign.Message | Should -Be 'Access token received from Entra ID.'
        $calls = @($r.Trace | Where-Object { $_.Sequence -in $sign.Trace })
        $calls[0].Url | Should -Be "https://login.microsoftonline.com/$script:SimTenantId/oauth2/v2.0/devicecode"
        $calls[0].Request | Should -Match 'scope=https://mail.contoso.test/EAS.AccessAsUser.All'
        $claims = $r.Steps | Where-Object Name -eq 'Token claims'
        $claims.Status | Should -Be 'Passed'
        $claims.Details.TenantId | Should -Be $script:SimTenantId
        ($r.Steps | Where-Object Name -eq 'Sync').Status | Should -Be 'Passed'
        @($r.Steps | Where-Object Name -eq 'Entra ID tenant').Count | Should -Be 1
    }

    It 'HMA: a token from another tenant is a warning; AADSTS500011 explains the missing service principal name' {
        Mock -ModuleName EasOAuthMailbox Wait-EomSeconds { }
        Mock -ModuleName EasOAuthMailbox Start-Process { }
        $script:Exchange.Authority = 'EntraID'
        $r = Invoke-Scenario 'OAuth' @{ Authority = 'EntraID'; AdfsUrl = '' } -Token (New-SimEntraToken -TenantId '11111111-2222-3333-4444-555555555555')
        ($r.Steps | Where-Object Name -eq 'Token claims').Message | Should -Match 'comes from the tenant 11111111-2222-3333-4444-555555555555'
        $script:Exchange.EntraTokenError = 'AADSTS500011: The resource principal named https://mail.contoso.test/ was not found in the tenant named Contoso.'
        $r = Invoke-Scenario 'OAuth' @{ Authority = 'EntraID'; AdfsUrl = '' } -Token ''
        $r.Status | Should -Be 'Failed'
        $r.Error | Should -Match 'AADSTS500011'
        $r.Error | Should -Match 'service principal name of Office 365 Exchange Online'
        $r.Error | Should -Not -Match 'Trace ID'
    }

    It 'Auto: the sign-in uses the server Exchange names, AD FS or Entra ID' {
        Mock -ModuleName EasOAuthMailbox Wait-EomSeconds { }
        Mock -ModuleName EasOAuthMailbox Start-Process { }
        $r = Invoke-Scenario 'Endpoint' @{ Authority = 'Auto'; AdfsUrl = '' } -Token ''
        $r.Status | Should -Be 'Passed'
        ($r.Steps | Where-Object Name -eq 'Authorization server').Message | Should -Match 'AD FS https://adfs.contoso.test/adfs'
        $r.AdfsUrl | Should -Be 'https://adfs.contoso.test/adfs'
        $r.AuthoritySource | Should -Match 'Exchange challenge'
        $script:Exchange = New-SimState
        $script:Exchange.Authority = 'EntraID'
        $script:Exchange.ValidToken = New-SimEntraToken
        $r = Invoke-Scenario 'Endpoint' @{ Authority = 'Auto'; AdfsUrl = '' } -Token ''
        $r.Status | Should -Be 'Passed'
        $r.Authority | Should -Be 'EntraID'
        $r.Steps.Name | Should -Be @('Authorization server', 'Entra ID tenant', 'User realm', 'Device-code sign-in', 'Token claims', 'OPTIONS')
        $r = Invoke-Scenario 'Discovery' @{ Authority = 'Auto'; AdfsUrl = '' } -Token ''
        $r.Steps.Name | Should -Be @('TLS certificate (mail.contoso.test)', 'OAuth challenge', 'OAuth for the mailbox', 'Entra ID tenant', 'User realm', 'Tenant trusted by Exchange', 'Invalid token')
    }

    It 'AppleMail with HMA: Entra ID found in the challenge, tenant, sign-in page of the Apple client, iPhone token' {
        Mock -ModuleName EasOAuthMailbox Wait-EomSeconds { }
        Mock -ModuleName EasOAuthMailbox Start-Process { }
        $script:Exchange.Authority = 'EntraID'
        $script:Exchange.ValidToken = New-SimEntraToken -AppId 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $r = Invoke-Scenario 'AppleMail' @{ AdfsUrl = ''; EasUrl = '' } -Token ''
        $r.Status | Should -Be 'Passed'
        ($r.Steps | Where-Object Stage -eq 'AppleSetup').Name | Should -Be @('Autodiscover', 'OAuth for the mailbox', 'Entra ID tenant', 'User realm', 'Tenant trusted by Exchange', 'Entra ID sign-in page')
        $page = @($script:Exchange.WebCalls | Where-Object Uri -match '^https://login\.windows\.net/common/oauth2/authorize')
        $page.Count | Should -Be 1
        $page[0].Uri | Should -Match 'client_id=f8d98a96-0999-43f5-8af3-69971c7bb423'
        $page[0].UserAgent | Should -Match 'Safari/605'
        ($r.Steps | Where-Object Name -eq 'Device-code sign-in').Message | Should -Match 'from Entra ID for the Apple Mail client'
        ($r.Steps | Where-Object Name -eq 'Token claims').Status | Should -Be 'Passed'
        $r.Authority | Should -Be 'EntraID'
        $script:Exchange = New-SimState; $script:Exchange.Authority = 'EntraID'
        $script:Exchange.EntraSignInPage = 'AADSTS50011: The redirect URI specified in the request does not match.'
        $r = Invoke-Scenario 'AppleMail' -Token ''
        $step = $r.Steps | Where-Object Name -eq 'Entra ID sign-in page'
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -Match 'AADSTS50011'
    }

    It 'an anonymous probe answered HTTP 500 (Exchange starting) is a warning: the sign-in decides' {
        $script:Exchange.AnonymousStatus = 500
        $r = Invoke-BasicScenario 'Full' @{ AcknowledgePolicy = $true }
        $r.Status | Should -Be 'Warning'
        $probe = $r.Steps | Where-Object Name -eq 'Basic challenge'
        $probe.Status | Should -Be 'Warning'
        $probe.Message | Should -Match 'HTTP 500 instead of 401.*The Basic sign-in decides'
        ($r.Steps | Where-Object Name -eq 'Basic sign-in').Status | Should -Be 'Passed'
        @($r.Steps | Where-Object Status -eq 'Failed').Count | Should -Be 0
        # OAuth: the empty bearer header still gets the challenge, as clients send it.
        $r = Invoke-Scenario 'Discovery' -Token ''
        $challenge = $r.Steps | Where-Object Name -eq 'OAuth challenge'
        $challenge.Status | Should -Be 'Passed'
        $challenge.Details.HttpStatus | Should -Be 500
        $challenge.Details.EmptyBearerStatus | Should -Be 401
        $script:Exchange.BearerChallenge = 'None'
        $r = Invoke-Scenario 'Discovery' -Token ''
        ($r.Steps | Where-Object Name -eq 'OAuth challenge').Message | Should -Match 'does not advertise OAuth'
    }

    It 'Basic with HMA: the mailbox offered OAuth says Outlook and the iPhone use Entra ID' {
        $script:Exchange.Authority = 'EntraID'
        $r = Invoke-BasicScenario 'Discovery' -NoCredential
        ($r.Steps | Where-Object Name -eq 'OAuth for the mailbox').Message | Should -Match 'sign in with Entra ID, without the password'
    }

    It 'Exchange Online Discovery: anonymous request redirected, the empty bearer gets Entra ID, every tenant trusted' {
        $script:Exchange.Online = $true
        $r = Invoke-Scenario 'Discovery' @{ Authority = 'EntraID'; AdfsUrl = ''; EasUrl = $script:OnlineUrl } -Token ''
        $r.Status | Should -Be 'Passed'
        $r.Steps.Name | Should -Be @('Entra ID tenant', 'User realm', 'TLS certificate (outlook.office365.com)', 'OAuth challenge', 'OAuth for the mailbox', 'Tenant trusted by Exchange', 'Invalid token')
        $challenge = $r.Steps | Where-Object Name -eq 'OAuth challenge'
        $challenge.Message | Should -Match 'redirected to https://outlook-cba\.office365\.com'
        $challenge.Message | Should -Match 'Exchange Online\.$'
        $challenge.Details.EmptyBearerStatus | Should -Be 401
        ($r.Steps | Where-Object Name -eq 'OAuth for the mailbox').Message | Should -Match 'Entra ID \(Exchange Online\)'
        ($r.Steps | Where-Object Name -eq 'Tenant trusted by Exchange').Message | Should -Match 'every tenant'
    }

    It 'Exchange Online Full: token for outlook.office365.com, ActiveSync 16.1 instead of 14.1, mailbox synchronised' {
        Mock -ModuleName EasOAuthMailbox Wait-EomSeconds { }
        Mock -ModuleName EasOAuthMailbox Start-Process { }
        $script:Exchange.Online = $true
        $script:Exchange.ValidToken = New-SimEntraToken -Audience 'https://outlook.office365.com'
        $r = Invoke-Scenario 'Full' @{ Authority = 'EntraID'; AdfsUrl = ''; EasUrl = $script:OnlineUrl; AcknowledgePolicy = $true } -Token ''
        $r.Status | Should -Be 'Passed'
        $sign = $r.Steps | Where-Object Name -eq 'Device-code sign-in'
        @($r.Trace | Where-Object { $_.Sequence -in $sign.Trace })[0].Request | Should -Match 'scope=https://outlook.office365.com/EAS.AccessAsUser.All'
        ($r.Steps | Where-Object Name -eq 'Token claims').Status | Should -Be 'Passed'
        ($r.Steps | Where-Object Name -eq 'OPTIONS').Message | Should -Match 'Exchange does not offer 14\.1 \(versions: 16\.1\): the test goes on with 16\.1'
        $r.ProtocolVersion | Should -Be '16.1'
        ($r.Steps | Where-Object Name -eq 'Sync').Status | Should -Be 'Passed'
    }

    It 'Exchange Online with Basic: Discovery explains it is turned off, the iPhone password is never sent' {
        $script:Exchange.Online = $true
        $r = Invoke-BasicScenario 'Discovery' @{ EasUrl = $script:OnlineUrl } -NoCredential
        $basic = $r.Steps | Where-Object Name -eq 'Basic challenge'
        $basic.Status | Should -Be 'Failed'
        $basic.Message | Should -Match 'Exchange Online does not offer Basic authentication'
        $script:Exchange = New-SimState
        $script:Exchange.Online = $true
        $script:Exchange.AutodiscoverUrl = $script:OnlineUrl
        $r = Invoke-BasicScenario 'AppleMail' @{ AdfsUrl = ''; EasUrl = '' }
        $step = $r.Steps | Where-Object Name -eq 'Basic sign-in'
        $step.Status | Should -Be 'Failed'
        $step.Message | Should -Match 'the password of eas-test@contoso.test was not sent'
        @($script:Exchange.Calls | Where-Object BasicUser).Count | Should -Be 0
    }

    It 'returns the same result shape for every scenario, with one duration per step' {
        foreach ($type in 'OAuth', 'Endpoint', 'Full') {
            $r = Invoke-Scenario $type
            foreach ($p in 'Status', 'Steps', 'Folders', 'Messages', 'PolicySettings', 'Identity', 'Token', 'Counts', 'Error') { $r.PSObject.Properties.Name | Should -Contain $p }
            foreach ($s in $r.Steps) { $s.DurationMs | Should -BeOfType [int] }
        }
    }
}

Describe 'Sign-in window' {
    BeforeAll {
        Mock -ModuleName EasOAuthMailbox Send-EomHttpRequest { Get-SimHttpResponse -Request $Request -State $script:Exchange }
        Mock -ModuleName EasOAuthMailbox Get-EomTlsCertificate { Get-SimCertificate $HostName $Port $script:Exchange.CertificateDays }
        Mock -ModuleName EasOAuthMailbox Wait-EomSeconds { }
        Mock -ModuleName EasOAuthMailbox Start-Process { }
        Mock -ModuleName EasOAuthMailbox Test-EomDesktopSession { $true }
        Mock -ModuleName EasOAuthMailbox Find-EomBrowser { [pscustomobject]@{ Name = 'Microsoft Edge'; Path = 'msedge.exe' } }
        Mock -ModuleName EasOAuthMailbox Test-EomBrowserPolicyBlock { $false }
        Mock -ModuleName EasOAuthMailbox Invoke-EomBrowserAuthorization { Get-SimWindowRedirect -Url $Url -RedirectUri $RedirectUri -State $script:Exchange }
        function Get-Query([string]$Url) { $q = @{}; foreach ($pair in $Url.Substring($Url.IndexOf('?') + 1).Split('&')) { $kv = $pair.Split('=', 2); $q[$kv[0]] = [Uri]::UnescapeDataString($kv[1]) }; $q }
    }

    BeforeEach { $script:Exchange = New-SimState }

    It 'AD FS: authorization code with PKCE in the window, redirect urn:ietf:wg:oauth:2.0:oob, code exchanged once, no secret written' {
        $r = Invoke-Scenario 'Endpoint' @{ SignIn = 'Auto' } -Token ''
        $r.Status | Should -Be 'Passed'
        $r.SignIn | Should -Be 'Window'
        $sign = $r.Steps | Where-Object Name -eq 'Sign-in window'
        $sign.Status | Should -Be 'Passed'
        $sign.Details.Browser | Should -Be 'Microsoft Edge'
        $sign.Details.RedirectUri | Should -Be 'urn:ietf:wg:oauth:2.0:oob'
        $script:Exchange.WindowCalls.Count | Should -Be 1
        $call = $script:Exchange.WindowCalls[0]
        $call.Url | Should -BeLike 'https://adfs.contoso.test/adfs/oauth2/authorize?*'
        $q = Get-Query $call.Url
        $q.response_type | Should -Be 'code'
        $q.code_challenge_method | Should -Be 'S256'
        $q.code_challenge | Should -Match '^[A-Za-z0-9_-]{43}$'
        $q.prompt | Should -Be 'login'
        $q.login_hint | Should -Be 'eas-test@contoso.test'
        $q.scope | Should -Be 'openid https://mail.contoso.test//EAS.AccessAsUser.All'
        # The redirect of the window checked first, then the window, then the code exchanged (PKCE verified by the simulator).
        $calls = @($r.Trace | Where-Object { $_.Sequence -in $sign.Trace })
        $calls.Label | Should -Be @('', 'sign-in window', 'grant authorization_code')
        $calls[1].Response | Should -Match 'code=<\d+ characters, never written>'
        $calls[2].Request | Should -Match 'code_verifier=<\d+ characters, never written>'
        $script:Exchange.AuthorizationCodes.Count | Should -Be 0
        $json = $r | ConvertTo-Json -Depth 8
        $json | Should -Not -Match 'SimAuthCode'
        $json | Should -Not -Match ([regex]::Escape($script:ValidToken.Split('.')[1]))
    }

    It 'Entra ID: authorize v2.0 of the tenant, redirect to the native-client page, scope of the on-premises URL' {
        $script:Exchange.Authority = 'EntraID'
        $script:Exchange.ValidToken = New-SimEntraToken
        $r = Invoke-Scenario 'Endpoint' @{ SignIn = 'Window'; Authority = 'EntraID'; AdfsUrl = '' } -Token ''
        $r.Status | Should -Be 'Passed'
        $r.Steps.Name | Should -Be @('Entra ID tenant', 'User realm', 'Sign-in window', 'Token claims', 'OPTIONS')
        $call = $script:Exchange.WindowCalls[0]
        $call.RedirectUri | Should -Be 'https://login.microsoftonline.com/common/oauth2/nativeclient'
        $call.Url | Should -BeLike "https://login.microsoftonline.com/$script:SimTenantId/oauth2/v2.0/authorize?*"
        (Get-Query $call.Url).scope | Should -Be 'https://mail.contoso.test/EAS.AccessAsUser.All'
        $token = $r.Trace | Where-Object Label -eq 'grant authorization_code'
        $token.Url | Should -Be "https://login.microsoftonline.com/$script:SimTenantId/oauth2/v2.0/token"
        $token.Request | Should -Match 'scope=https://mail.contoso.test/EAS.AccessAsUser.All'
    }

    It 'AppleMail: the Apple client with the redirect URI of the iPhone, with AD FS and with Entra ID (answer in lower case)' {
        $script:Exchange.ValidToken = New-SimToken -AppId 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $r = Invoke-Scenario 'AppleMail' @{ SignIn = 'Auto'; AdfsUrl = ''; EasUrl = '' } -Token ''
        $r.Status | Should -Be 'Passed'
        $sign = $r.Steps | Where-Object Name -eq 'Sign-in window'
        $sign.Message | Should -Match 'redirect URI of the iPhone \(com\.apple\.Preferences://oauth-redirect\)'
        $q = Get-Query $script:Exchange.WindowCalls[0].Url
        $q.client_id | Should -Be 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $q.claims | Should -Be '{"access_token":{"xms_cc":{"values":["cp1"]}}}'
        # AppleSetup already checked the Apple redirect URIs: no check of urn:ietf:wg:oauth:2.0:oob.
        @($script:Exchange.WebCalls | Where-Object Uri -match 'urn%3Aietf').Count | Should -Be 0
        $script:Exchange = New-SimState
        $script:Exchange.Authority = 'EntraID'
        $script:Exchange.ValidToken = New-SimEntraToken -AppId 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        $r = Invoke-Scenario 'AppleMail' @{ SignIn = 'Auto'; AdfsUrl = ''; EasUrl = '' } -Token ''
        $r.Status | Should -Be 'Passed'
        ($r.Trace | Where-Object Label -eq 'sign-in window').Response | Should -Match 'com\.apple\.preferences://oauth-redirect/\?code=<'
    }

    It 'Auto falls back to the device code without a desktop or a browser, or when AD FS refuses the redirect; Window refuses' {
        Mock -ModuleName EasOAuthMailbox Test-EomDesktopSession { $false }
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Auto' } -Token ''
        $r.Status | Should -Be 'Passed'
        $r.SignIn | Should -Be 'DeviceCode'
        $r.Steps.Name | Should -Contain 'Device-code sign-in'
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Window' } -Token ''
        $r.Status | Should -Be 'Failed'
        $r.Error | Should -Match 'sign-in window cannot be opened: no interactive desktop.*-SignIn DeviceCode'
        Mock -ModuleName EasOAuthMailbox Test-EomDesktopSession { $true }
        $script:Exchange = New-SimState
        $script:Exchange.AdfsWindowRedirect = 'Missing'
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Auto' } -Token ''
        $r.Status | Should -Be 'Passed'
        $r.SignIn | Should -Be 'DeviceCode'
        $script:Exchange.WindowCalls.Count | Should -Be 0
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Window' } -Token ''
        $r.Error | Should -Match 'MSIS9224.*Set-AdfsNativeClientApplication -RedirectUri'
    }

    It 'a window that cannot start (DevTools forbidden by a policy) falls back to the device code with Auto, fails with Window' {
        Mock -ModuleName EasOAuthMailbox Invoke-EomBrowserAuthorization { throw [NotSupportedException]::new('The sign-in window could not start: Microsoft Edge did not open its DevTools endpoint within 20 seconds: an organisation policy can forbid it (RemoteDebuggingAllowed).') }
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Auto' } -Token ''
        $r.Status | Should -Be 'Passed'
        $r.SignIn | Should -Be 'DeviceCode'
        $r.Steps.Name | Should -Contain 'Device-code sign-in'
        ($r.Trace | Where-Object Label -eq 'sign-in window').Response | Should -Match 'RemoteDebuggingAllowed'
        ($r.Steps | Where-Object Name -eq 'Device-code sign-in').Details.SignInWindow | Should -Match '^not used: could not start: Microsoft Edge did not open'
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Window' } -Token ''
        $r.Status | Should -Be 'Failed'
        $r.Error | Should -Match 'could not start.*RemoteDebuggingAllowed.*-SignIn DeviceCode'
    }

    It 'a policy that forbids DevTools (RemoteDebuggingAllowed = 0) is seen before the start: the other browser, else the device code' {
        Mock -ModuleName EasOAuthMailbox Find-EomBrowser { [pscustomobject]@{ Name = 'Microsoft Edge'; Path = 'msedge.exe' }; [pscustomobject]@{ Name = 'Google Chrome'; Path = 'chrome.exe' } }
        Mock -ModuleName EasOAuthMailbox Test-EomBrowserPolicyBlock { $Browser.Name -eq 'Microsoft Edge' }
        $mode = InModule { Get-EomSignInMode -Configuration @{ SignIn = 'Auto' } }
        $mode.Mode | Should -Be 'Window'
        $mode.Browser.Name | Should -Be 'Google Chrome'
        Mock -ModuleName EasOAuthMailbox Test-EomBrowserPolicyBlock { $true }
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Auto' } -Token ''
        $r.Status | Should -Be 'Passed'
        $r.SignIn | Should -Be 'DeviceCode'
        $script:Exchange.WindowCalls.Count | Should -Be 0
        ($r.Steps | Where-Object Name -eq 'Device-code sign-in').Details.SignInWindow | Should -Match '^not used: an organisation policy forbids the DevTools protocol in Microsoft Edge and Google Chrome'
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Window' } -Token ''
        $r.Error | Should -Match 'policy forbids the DevTools protocol in Microsoft Edge and Google Chrome \(RemoteDebuggingAllowed = 0\).*-SignIn DeviceCode'
    }

    It 'a window closed, a consent declined or an answer to another sign-in fails the sign-in with the cause' {
        $script:Exchange.WindowOutcome = 'Closed'
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Window' } -Token ''
        $r.Error | Should -Match 'did not complete: The sign-in window was closed'
        ($r.Trace | Where-Object Label -eq 'sign-in window').Response | Should -Match 'No authorization code'
        $script:Exchange.Authority = 'EntraID'
        $script:Exchange.WindowOutcome = 'Denied'
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Window'; Authority = 'EntraID'; AdfsUrl = '' } -Token ''
        $r.Error | Should -Match 'answered the sign-in with the error access_denied: AADSTS65004'
        $script:Exchange.WindowOutcome = 'OtherState'
        $r = Invoke-Scenario 'OAuth' @{ SignIn = 'Window'; Authority = 'EntraID'; AdfsUrl = '' } -Token ''
        $r.Error | Should -Match 'another state'
    }

    It 'catches the answer of the server: redirect URI without case or final slash, never the authorization request itself' {
        $match = { param($u, $r) InModule { param($a) Test-EomRedirectMatch -Url $a[0] -RedirectUri $a[1] } @($u, $r) }
        & $match 'urn:ietf:wg:oauth:2.0:oob?code=abc&state=1' 'urn:ietf:wg:oauth:2.0:oob' | Should -BeTrue
        & $match 'com.apple.preferences://oauth-redirect/?code=abc' 'com.apple.Preferences://oauth-redirect' | Should -BeTrue
        & $match 'https://login.microsoftonline.com/common/oauth2/nativeclient?code=abc' 'https://login.microsoftonline.com/common/oauth2/nativeclient' | Should -BeTrue
        & $match 'https://login.microsoftonline.com/common/oauth2/nativeclientx' 'https://login.microsoftonline.com/common/oauth2/nativeclient' | Should -BeFalse
        & $match 'https://adfs.contoso.test/adfs/oauth2/authorize?redirect_uri=urn%3Aietf%3Awg%3Aoauth%3A2.0%3Aoob' 'urn:ietf:wg:oauth:2.0:oob' | Should -BeFalse
        $paused = InModule { Get-EomPausedRedirect -Params @{ responseStatusCode = 302; responseHeaders = @(@{ name = 'Location'; value = 'urn:ietf:wg:oauth:2.0:oob?code=x&state=y' }); request = @{ url = 'https://adfs/x' } } -RedirectUri 'urn:ietf:wg:oauth:2.0:oob' }
        $paused | Should -Be 'urn:ietf:wg:oauth:2.0:oob?code=x&state=y'
        InModule { Get-EomPausedRedirect -Params @{ responseStatusCode = 200; responseHeaders = @(); request = @{ url = 'https://adfs/x' } } -RedirectUri 'urn:ietf:wg:oauth:2.0:oob' } | Should -BeNullOrEmpty
    }

    It 'Test.SignIn: Auto, Window or DeviceCode' {
        { Invoke-Scenario 'OAuth' @{ SignIn = 'Browser' } -Token '' } | Should -Throw "*Test.SignIn must be 'Auto', 'Window' or 'DeviceCode'.*"
    }
}

Describe 'Sign-in window: the browser' {
    It 'reads the RemoteDebuggingAllowed policy of each browser, machine or user (0 forbids, 1 or none allows)' {
        Mock -ModuleName EasOAuthMailbox Get-ItemProperty { if ($LiteralPath -like 'HKCU:*\Microsoft\Edge') { [pscustomobject]@{ RemoteDebuggingAllowed = 0 } } elseif ($LiteralPath -like 'HKLM:*\Google\Chrome') { [pscustomobject]@{ RemoteDebuggingAllowed = 1 } } }
        InModule { Test-EomBrowserPolicyBlock -Browser ([pscustomobject]@{ Name = 'Microsoft Edge' }) } | Should -BeTrue
        InModule { Test-EomBrowserPolicyBlock -Browser ([pscustomobject]@{ Name = 'Google Chrome' }) } | Should -BeFalse
        Mock -ModuleName EasOAuthMailbox Get-ItemProperty { }
        InModule { Test-EomBrowserPolicyBlock -Browser ([pscustomobject]@{ Name = 'Microsoft Edge' }) } | Should -BeFalse
    }
    It 'a browser that closes at once is a start failure, and its temporary profile is deleted' {
        Mock -ModuleName EasOAuthMailbox Start-Process { [pscustomobject]@{ HasExited = $true; ExitCode = 3; Id = 0 } }
        $before = @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'EasOAuthMailbox-signin-*').Count
        $err = $null
        try { InModule { Invoke-EomBrowserAuthorization -Browser ([pscustomobject]@{ Name = 'Microsoft Edge'; Path = 'msedge.exe' }) -Url 'https://adfs.contoso.test/adfs/oauth2/authorize?x=1' -RedirectUri 'urn:ietf:wg:oauth:2.0:oob' -StartTimeoutSeconds 2 } }
        catch { $err = $_.Exception }
        $err | Should -BeOfType ([NotSupportedException])
        $err.Message | Should -Match 'Microsoft Edge closed at once \(exit code 3\)'
        @(Get-ChildItem ([IO.Path]::GetTempPath()) -Directory -Filter 'EasOAuthMailbox-signin-*').Count | Should -Be $before
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
        $script:ReportOut = Join-Path $script:RepoRoot 'artifacts\report-test'
        Remove-Item $script:ReportOut -Recurse -Force -ErrorAction SilentlyContinue
        $script:Report = Export-EomReport -Result $script:Result -OutputPath $script:ReportOut
    }

    It 'ends the console with the next action, naming the test device only when the scenario creates one' {
        $script:Result.Status | Should -Be 'Passed'
        $withDevice = Write-EomRunSummary -Result $script:Result 6>&1 | Out-String
        $discovery = $script:Result.PSObject.Copy(); $discovery.TestType = 'Discovery'
        $withoutDevice = Write-EomRunSummary -Result $discovery 6>&1 | Out-String
        $withDevice | Should -Match 'Get-MobileDevice'
        $withoutDevice | Should -Not -Match 'Get-MobileDevice'
        $withoutDevice | Should -Match 'No device partnership was created'
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
        $script:Window = New-EomTestForm -Configuration (Import-EomConfiguration) -Theme Light
        $w = $script:Window.Form
        $w.WindowStartupLocation = 'Manual'
        $w.Left = -6000; $w.Top = -6000; $w.Width = 1180; $w.Height = 860
        $w.ShowActivated = $false; $w.ShowInTaskbar = $false
        $w.Show()
        function Pump { InModule { Invoke-EomGuiPump } }
        function LogText { $script:Window.Lines -join "`n" }
        function Position([string]$Name) { $script:Window.Controls[$Name].TranslatePoint([Windows.Point]::new(0, 0), $script:Window.Form.Content) }
        Pump
    }
    AfterAll { if ($script:Window.Form.IsVisible) { $script:Window.Form.Close() } }

    It 'shows the header, then the method and the target on the left, the scenario and the progress on the right, the actions at the bottom' {
        (Position 'Method').Y | Should -BeGreaterThan (Position 'Header').Y
        (Position 'Target').Y | Should -BeGreaterThan (Position 'Method').Y
        (Position 'Scenario').X | Should -BeGreaterThan (Position 'Method').X
        (Position 'Progress').Y | Should -BeGreaterThan (Position 'Scenario').Y
        (Position 'Actions').Y | Should -BeGreaterThan (Position 'Progress').Y
        $script:Window.Controls.Close.IsCancel | Should -BeTrue
    }

    It 'uses the Fluent theme of Windows 11 when .NET offers it, with the accent of the report' {
        $fluent = $null -ne [Windows.Application].GetProperty('ThemeMode')
        if ($fluent) { [string][Windows.Application]::Current.ThemeMode | Should -Be 'Light' }
        $script:Window.Form.TryFindResource('AccentFillColorDefaultBrush').Color.ToString() | Should -Be '#FFB11F4B'
        $script:Window.Form.TryFindResource('CardBackgroundFillColorDefaultBrush') | Should -Not -BeNullOrEmpty
    }

    It 'follows the light or dark mode of Windows, light when the setting is missing (Windows Server 2016), never the System mode of WPF' {
        Mock -ModuleName EasOAuthMailbox Get-ItemProperty { }
        $theme = InModule { Initialize-EomGuiTheme -Theme System }
        $theme.Dark | Should -BeFalse
        if ($theme.Fluent) { [string]$theme.Application.ThemeMode | Should -Be 'Light' }
        Mock -ModuleName EasOAuthMailbox Get-ItemProperty { [pscustomobject]@{ AppsUseLightTheme = 0 } }
        $theme = InModule { Initialize-EomGuiTheme -Theme System }
        $theme.Dark | Should -BeTrue
        if ($theme.Fluent) { [string]$theme.Application.ThemeMode | Should -Be 'Dark' }
        [void](InModule { Initialize-EomGuiTheme -Theme Light })
    }

    It 'offers the three sign-in methods as cards' {
        InModule { $script:GuiAuthentication.Text } | Should -Be @('OAuth - On-prem AD FS', 'OAuth - Entra ID', 'Basic - On-prem')
        $script:Window.Controls.Authentication.Items.Count | Should -Be 3
    }

    It 'updates the description, the policy checkbox and the notice with the scenario' {
        $c = $script:Window.Controls
        $c.TestType.SelectedItem = 'Discovery'; Pump
        $c.Acknowledge.IsEnabled | Should -BeFalse
        $c.Warning.Text | Should -Match 'No sign-in'
        $c.TestType.SelectedItem = 'InboxSync'; Pump
        $c.Acknowledge.IsEnabled | Should -BeTrue
        $c.Description.Text | Should -Match 'Inbox headers'
        $c.Warning.Text | Should -Match 'device partnership'
    }

    It 'lists invalid values in the progress without running anything' {
        $c = $script:Window.Controls
        $c.Mailbox.Text = ''
        $c.MessageCount.Text = 'abc'
        InModule { Invoke-EomGuiRun }
        LogText | Should -Match 'Target.Mailbox is required'
        LogText | Should -Match 'Test.MessageCount must be'
        $c.Status.Text | Should -Be 'Fix the values above.'
        $c.Run.IsEnabled | Should -BeTrue
        $c.LogEmpty.Visibility | Should -Be 'Collapsed'
    }

    It 'Basic: AD FS fields hidden, user name and password shown, password required, OAuth scenario refused' {
        $c = $script:Window.Controls
        $c.Mailbox.Text = 'eas-test@contoso.test'
        $c.MessageCount.Text = '5'
        $c.Authentication.SelectedIndex = 2
        $c.TestType.SelectedItem = 'Full'; Pump
        $c.AdfsUrl.IsEnabled | Should -BeFalse
        $c.AdfsPanel.Visibility | Should -Be 'Collapsed'
        $c.ClientId.IsEnabled | Should -BeFalse
        $c.BasicPanel.Visibility | Should -Be 'Visible'
        $c.BasicPassword.IsEnabled | Should -BeTrue
        $c.BasicPassword | Should -BeOfType ([Windows.Controls.PasswordBox])
        $c.DeviceCode.IsEnabled | Should -BeFalse
        $c.Warning.Text | Should -Match 'AD FS is not used'
        $c.BasicPassword.Password = ''
        InModule { Invoke-EomGuiRun }
        LogText | Should -Match 'Enter the password \(Basic\)'
        $c.TestType.SelectedItem = 'Discovery'; Pump
        $c.BasicPassword.IsEnabled | Should -BeFalse
        $c.TestType.SelectedItem = 'OAuth'; Pump
        $c.Warning.Text | Should -Match 'choose OAuth'
        $c.Authentication.SelectedIndex = 0
        $c.TestType.SelectedItem = 'Full'; Pump
        $c.AdfsUrl.IsEnabled | Should -BeTrue
        $c.AdfsPanel.Visibility | Should -Be 'Visible'
        $c.BasicPanel.Visibility | Should -Be 'Collapsed'
    }

    It 'Entra ID: no AD FS URL, the client ID stays, the run gets the authority and the sign-in mode' {
        $c = $script:Window.Controls
        $c.Authentication.SelectedIndex = 1
        $c.TestType.SelectedItem = 'Endpoint'; Pump
        $c.AdfsUrl.IsEnabled | Should -BeFalse
        $c.ClientId.IsEnabled | Should -BeTrue
        $c.Warning.Text | Should -Match 'sign-in in a window \(password, MFA\)'
        $c.DeviceCode.IsEnabled | Should -BeTrue
        $c.DeviceCode.IsChecked = $true
        InModule { Update-EomGuiScenario }
        $c.Warning.Text | Should -Match 'code typed on any device'
        Mock -ModuleName EasOAuthMailbox Write-EomLog { }
        Mock -ModuleName EasOAuthMailbox Invoke-EomMailboxTest { $script:GuiRun = $Configuration.Clone(); throw 'simulated end of run' }
        $c.Mailbox.Text = 'eas-test@contoso.test'; $c.MessageCount.Text = '5'
        InModule { Invoke-EomGuiRun }
        $script:GuiRun.Authority | Should -Be 'EntraID'
        $script:GuiRun.Authentication | Should -Be 'OAuth'
        $script:GuiRun.SignIn | Should -Be 'DeviceCode'
        $c.DeviceCode.IsChecked = $false
        InModule { Invoke-EomGuiRun }
        $script:GuiRun.SignIn | Should -Be 'Auto'
        $c.Authentication.SelectedIndex = 0; Pump
    }

    It 'shows each check with the icon of its status, and a device code in its own box' {
        InModule {
            Clear-EomGuiProgress
            Add-EomGuiLine 'Step' '[1/2] AD FS sign-in and token'
            Add-EomGuiLine 'Info' 'Code: QDZ8-HKWP  -  page: https://adfs.contoso.test/adfs/oauth2/deviceauth'
            Add-EomGuiLine 'Ok' 'Device-code sign-in: Access token received from AD FS.'
            Add-EomGuiLine 'Fail' 'OPTIONS: HTTP 401.'
        }
        $items = $script:Window.Items
        $items.Count | Should -Be 4
        $items[0].Text | Should -Be '1/2   AD FS sign-in and token'
        $items[2].Glyph | Should -Be ([string][char]0xE73E)
        $items[3].Glyph | Should -Be ([string][char]0xEA39)
        $items[3].Brush.Color.ToString() | Should -Be '#FFDC2626'
        $c = $script:Window.Controls
        $c.CodeBanner.Visibility | Should -Be 'Visible'
        $c.CodeText.Text | Should -Be 'QDZ8-HKWP'
        $c.CodePage.Text | Should -Be 'https://adfs.contoso.test/adfs/oauth2/deviceauth'
        InModule { Clear-EomGuiProgress }
        $c.CodeBanner.Visibility | Should -Be 'Collapsed'
    }

    It 'fits its texts: the buttons and the method cards are not cut' {
        $c = $script:Window.Controls
        foreach ($name in 'Run', 'Cancel', 'OpenReport', 'OpenFolder', 'Close') {
            $b = $c[$name]
            $b.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
            $b.DesiredSize.Width | Should -BeLessOrEqual ($b.ActualWidth + $b.Margin.Left + $b.Margin.Right + 1) -Because "the text of $name must fit its button"
        }
        foreach ($item in $c.Authentication.Items) {
            $item.Content.Measure([Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
            $item.Content.DesiredSize.Width | Should -BeLessOrEqual ($item.ActualWidth) -Because 'the name of each method must fit its card'
        }
    }

    It 'refuses to close during a run, asks the run to stop, then closes normally' {
        $c = $script:Window.Controls
        $c.Mailbox.Text = 'eas-test@contoso.test'
        $c.MessageCount.Text = '5'
        $c.TestType.SelectedItem = 'Discovery'
        Mock -ModuleName EasOAuthMailbox Write-EomLog { }
        Mock -ModuleName EasOAuthMailbox Invoke-EomMailboxTest {
            $script:Window.Form.Close()
            $script:DuringRun = @{ Visible = $script:Window.Form.IsVisible; Cancel = (InModule { $script:Ui.Cancel }); CloseEnabled = $script:Window.Controls.Close.IsEnabled }
            throw 'simulated end of run'
        }
        InModule { Invoke-EomGuiRun }
        $script:DuringRun.Visible | Should -BeTrue
        $script:DuringRun.Cancel | Should -BeTrue
        $script:DuringRun.CloseEnabled | Should -BeFalse
        LogText | Should -Match 'A test is running'
        $c.Close.IsEnabled | Should -BeTrue

        $script:Window.Form.Close()
        $script:Window.Form.IsVisible | Should -BeFalse
    }
}