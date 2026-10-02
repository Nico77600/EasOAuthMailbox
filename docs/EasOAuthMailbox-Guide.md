---
title: EAS OAuth Mailbox
subtitle: Administrator guide
version: 1.0.0
author: Nicolas Fabert
updated: 2026-10-02
---

# EAS OAuth Mailbox — Administrator guide

> A step-by-step diagnostic for **Exchange ActiveSync with modern authentication (OAuth) through AD FS**: prerequisites without sign-in, AD FS token, endpoint, ActiveSync policy, folders, identity and Inbox headers. Each check says **what works, what does not work and what to verify**, in the console, a window and an HTML report.

```cards
target | What it answers | Is the AD FS token the right one? Does Exchange accept it? Can the mailbox sync? Does a policy block it? Which user does Exchange actually see?
layers | Nine scenarios | From *Discovery* (no sign-in, nothing created) to *Full* (the full path of a mobile device), and *AppleMail*, which replays adding the account with the Mail app on an iPhone. From the command line or in a window.
file | What it produces | One folder per run: CSV, JSON and a **self-contained HTML** report, plus a daily log.
shield | Its guardrails | The token stays in memory, the ActiveSync policy is **never** acknowledged without explicit authorisation, and CSV cells are protected.
```

## Quick start

```steps
Check prerequisites | PowerShell 7.4+, HTTPS access to AD FS and Exchange, a **test mailbox** and the AD FS client authorised for `EAS.AccessAsUser.All` (chapter 5).
Fill in the target | Open `config\EasOAuthMailbox.config.psd1` and replace all `contoso.test` values (chapter 7).
Start without sign-in | `.\Invoke-EasOAuthMailbox.ps1 -TestType Discovery`: certificates, AD FS metadata, Exchange OAuth advertisement, rejection of an invalid token.
Run the full diagnostic | `.\Invoke-EasOAuthMailbox.ps1 -TestType Full`, or `-Gui` to choose the scenario in a window. The AD FS page opens: enter the displayed code.
Read the result | Open the HTML report shown in the final card: stop at the first red or orange check (chapter 11).
```

> [!IMPORTANT]
> Use a **dedicated test mailbox**. From `FolderSync`, Exchange records an ActiveSync device partnership (`Get-MobileDevice`). The ActiveSync policy acknowledgement only happens with `-AcknowledgePolicy` (or `Test.AcknowledgePolicy = $true`): without this authorisation, the policy is only downloaded for review and the diagnostic stops as **Blocked**.

# Part I · Understand

<!-- icon: target -->
## 1. Purpose

Since Exchange Server 2019 CU13 (and Exchange Server SE), ActiveSync clients can authenticate with **OAuth through AD FS**, without hybrid. The path of a device crosses several components, and each one fails in its own way: HTTPS publishing, AD FS (application, scopes, issuance rules), authorisation server declared in Exchange, user authentication policy, ActiveSync policy, mailbox.

A mobile device says almost nothing about the failure: “cannot connect”. EAS OAuth Mailbox replays the same path from an administration workstation and **isolates each stage**:

```cards
search | Before sign-in | The certificate, the Exchange OAuth advertisement and the rejection of a fake token are tested without an account: useful before opening the flow to a pilot.
key | The token itself | Audience, scope, expiry and user of the AD FS token are read and compared with what Exchange expects — the most common cause of HTTP 401.
server | The Exchange response | HTTP code, ActiveSync status in the WBXML and Exchange `x-ms-diagnostics` header are copied as-is into the report.
people | The right user | The `Settings` command shows the user that Exchange associates with the token, compared with the mailbox being tested.
phone | The real client | The *AppleMail* scenario presents itself as the Mail app on an iPhone: same AD FS discovery, same AD FS client, same User-Agent and same device type on the Exchange side.
```

The tool **does not modify any setting** in AD FS or Exchange and reads no message body or attachment.

<!-- icon: flow -->
## 2. How it works

![The six stages of a scenario](images/eas-pipeline.svg)

A scenario runs some of these stages, always in this order, with shared context: the token (in memory), the device ID, the **policy key** obtained during provisioning (sent back with each following command) and the folders found by `FolderSync`.

| Stage | Requests sent | What is checked |
|---|---|---|
| **Discovery** | `GET /adfs/.well-known/openid-configuration`, direct TLS connection, anonymous `OPTIONS`, then `OPTIONS` with an empty `Authorization: Bearer` header if needed, the same with `X-User-Identity` (the mailbox), `OPTIONS` with a deliberately invalid token | AD FS metadata, certificates (validity, expiry, protocol), `WWW-Authenticate: Bearer` challenge and announced authorisation server, OAuth offered **for the mailbox** (authentication policy), rejection of the fake token (HTTP 401). |
| **OAuth** | AD FS *device code* flow (`/adfs/oauth2/devicecode`, `/adfs/oauth2/token`) | Token retrieval, then its claims: `aud`, `scp`, `exp`, `upn` (and the client, for *AppleMail*). |
| **AppleSetup** | Autodiscover v2 (`autodiscover.json`), request with empty `Authorization` header and `X-User-Identity` (Settings screen User-Agent), `/adfs/oauth2/authorize` page for the Apple client for its three redirect URIs (Safari User-Agent) | What the iPhone does **before** the password: ActiveSync URL found, AD FS URL announced by Exchange for the mailbox, Apple Mail client and redirect URIs known by AD FS (chapter 10.7). |
| **Endpoint** | `OPTIONS /Microsoft-Server-ActiveSync` with the token | Token accepted, Exchange version (`MS-Server-ActiveSync`), protocol used (14.1, or 16.1 for *AppleMail*) and commands offered. |
| **Provisioning** | `Provision` (download, then acknowledgement if authorised) | ActiveSync policy for the mailbox, final policy key, no remote wipe command. |
| **FolderSync** | `FolderSync` (and `Provision` if Exchange requires it) | Mailbox tree and Inbox folder (type 2). |
| **Identity** | `Settings` › `UserInformation` › `Get` | Addresses of the authenticated user, compared with the mailbox being tested. |
| **InboxSync** | Initial `Sync`, then `Sync` with `GetChanges` | Up to `MessageCount` headers: date, sender, subject, read. |

<!-- icon: layers -->
## 3. Scenarios

| Scenario | Stages | AD FS sign-in | Device partnership possible |
|---|---|:---:|:---:|
| `Discovery` | Discovery | no | no |
| `OAuth` | OAuth | yes | no |
| `Endpoint` | OAuth, Endpoint | yes | no |
| `FolderSync` | OAuth, Endpoint, FolderSync | yes | yes |
| `Provisioning` | OAuth, Endpoint, Provisioning, FolderSync | yes | yes |
| `Identity` | OAuth, Endpoint, FolderSync, Identity | yes | yes |
| `InboxSync` | OAuth, Endpoint, FolderSync, InboxSync | yes | yes |
| `Full` | Discovery, OAuth, Endpoint, FolderSync, Identity, InboxSync | yes | yes |
| `AppleMail` | AppleSetup, OAuth, Endpoint, FolderSync, Identity, InboxSync — **as an iPhone** | yes (Apple client) | yes (type `iPhone`) |

```cards
search | Validate a publication | `Discovery`: no sign-in, no object created; run it from outside and from inside.
key | Validate AD FS | `OAuth` then `Endpoint`: is the token issued, then accepted by Exchange?
folder | Validate a mailbox | `FolderSync`, `Identity` or `InboxSync` on a test mailbox.
check | Full acceptance test | `Full` with `-AcknowledgePolicy` on the test mailbox: the full device path, end to end.
phone | Validate the iPhone | `AppleMail`: does a user's iPhone show an error or ask for a password instead of the AD FS page? This scenario replays its path and says at which stage it stops.
```

<!-- icon: lightbulb -->
## 4. What to know

Each check receives a status; the global status is the most severe one.

```cards
check | Passed | The check got exactly what was expected.
warning | Warning | The path continues, but something needs action: certificate close to expiry, unexpected audience, user different from the mailbox...
shield | Blocked | Exchange requires acknowledgement of the ActiveSync policy and it was not authorised. This is **not** an authentication failure.
info | Failed · Skipped | A failure stops the scenario; the following stages are marked *Skipped* (not run), never failed.
```

> [!NOTE]
> **Discovery checks do not stop the scenario.** They are independent: a certificate that cannot be reached directly (behind a proxy) does not prevent HTTPS requests, which go through the system proxy.

> [!TIP]
> **Blocked is a protection.** When Exchange requires provisioning (HTTP 449 or ActiveSync status 141 to 145), the tool downloads the policy and displays it in the report's *Policy* tab, then stops. Read the policy again, and only then rerun with `-AcknowledgePolicy` on the test mailbox.

> [!WARNING]
> **Device partnership.** `FolderSync`, `Provision`, `Settings` and `Sync` make the test device appear in `Get-MobileDevice -Mailbox <mailbox>` (type `EasOAuthMailbox` by default). The device ID is stable for one workstation and one mailbox: successive runs reuse the same partnership.

> [!CAUTION]
> **Remote wipe command.** If Exchange returns `RemoteWipe` or `AccountOnlyRemoteWipe` during provisioning, the tool **never acknowledges** it and stops with a failure: do not use this device ID again and check `Get-MobileDevice` on the Exchange side.

# Part II · Set up

<!-- icon: checklist -->
## 5. Prerequisites

| Item | Requirement |
|---|---|
| Workstation | Windows, **PowerShell 7.4 or later** (`pwsh`), a browser for the AD FS sign-in page. No module to install. The window (`-Gui`) uses Windows Forms. |
| Network | HTTPS (443) to AD FS and to the ActiveSync URL, with the system proxy if needed. The direct TLS check in *Discovery* needs a direct TCP connection (otherwise a simple warning). |
| Exchange | Exchange Server 2019 **CU13 or later**, or Exchange Server SE, configured for modern authentication with AD FS (5.1). |
| AD FS | AD FS on Windows Server 2019 or later (*device code* flow), application group with the native client used by the tool and one Web API application per Exchange URL (5.1). |
| Account | A **test mailbox** whose user has an authentication policy that allows modern authentication for ActiveSync. |
| Development | Pester 6.1 or later, only for `Run-Tests.ps1`. |

### 5.1 Expected AD FS and Exchange configuration

The tool tests the configuration described by Microsoft in *Enabling Modern Auth in Exchange on-premises* (AD FS as STS). The points it exercises:

| Side | Item | Verification |
|---|---|---|
| AD FS | Native client: by default `d3590ed6-52b3-4102-aeff-aad2292ab01c` (Outlook client from the application group documented by Microsoft) | `Get-AdfsNativeClientApplication` |
| AD FS | For *AppleMail*: native client `f8d98a96-0999-43f5-8af3-69971c7bb423` “iOS and macOS - Native mail application”, with its three redirect URIs `com.apple.mobilemail://oauth-redirect`, `com.apple.preferences.internetaccounts://oauth-redirect/` and `com.apple.Preferences://oauth-redirect/` | `Get-AdfsNativeClientApplication -Identifier f8d98a96-0999-43f5-8af3-69971c7bb423 \| Format-List Name, RedirectUri` |
| AD FS | Web API application whose identifier is **the Exchange URL with the final slash** (`https://mail.contoso.com/`) | `Get-AdfsWebApiApplication \| Format-List Name, Identifier` |
| AD FS | Scopes granted to the client for this Web API, including `openid` and `EAS.AccessAsUser.All`; issuance rule `scp = EAS.AccessAsUser.All` | `Get-AdfsApplicationPermission` |
| Exchange | `OAuth` in the ActiveSync virtual directory authentication methods | `Get-ActiveSyncVirtualDirectory \| Format-List Server, *auth*` |
| Exchange | AD FS authorisation server, default authorisation endpoint | `Get-AuthServer \| Format-List Name, Type, IsDefaultAuthorizationEndpoint` |
| Exchange | Modern authentication enabled for the organisation | `Get-OrganizationConfig \| Format-List OAuth2ClientProfileEnabled` |
| Exchange | Authentication policy of the test user without `BlockModernAuthActiveSync` | `Get-User eas-test \| Format-List AuthenticationPolicy` then `Get-AuthenticationPolicy <nom> \| Format-List BlockModernAuthActiveSync` |

> [!NOTE]
> The tool requests the scope `openid https://mail.contoso.com//EAS.AccessAsUser.All`: the **double slash is intentional**. AD FS derives the resource from everything before the last slash; because the Web API identifier ends with `/`, the slash is doubled.

> [!TIP]
> After an authentication policy change, Exchange takes up to 30 minutes to account for it on the front-end servers (or an `iisreset`). A diagnostic started too early still shows the old behaviour.

<!-- icon: download -->
## 6. Installation

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows and fail to run. Before using this project, unblock every file in the downloaded folder:
>
> ```powershell
> Get-ChildItem "C:\Chemin\Du\Dossier" -Recurse -File -Force | Unblock-File
> ```
>
> Replace the example path with the folder where you downloaded or extracted this project.

```steps
Copy the package | Copy the `EasOAuthMailbox-1.0.0` folder to the workstation, for example `C:\Tools\EasOAuthMailbox`. No installer, no module to register.
Check PowerShell | `pwsh -NoProfile -Command '$PSVersionTable.PSVersion'` must show 7.4 or later.
Fill in the configuration | Edit `config\EasOAuthMailbox.config.psd1` (chapter 7). All errors are listed at once on startup.
First test without an account | `.\Invoke-EasOAuthMailbox.ps1 -TestType Discovery`: checks the publication before any sign-in.
First test with an account | `.\Invoke-EasOAuthMailbox.ps1 -TestType Endpoint`: AD FS sign-in, then token presented to Exchange.
Acceptance test | `.\Invoke-EasOAuthMailbox.ps1 -TestType Full -AcknowledgePolicy` on the test mailbox, then archive the report folder.
```

The package contains no tests, reports, logs or run data.

<!-- icon: settings -->
## 7. Configuration

The `config\EasOAuthMailbox.config.psd1` file is a PowerShell data file in sections. Relative paths start from the tool folder. An unknown section or key is rejected; all errors are listed together.

```powershell
@{
    Target  = @{ AdfsUrl = 'https://adfs.contoso.com/adfs'; EasUrl = 'https://mail.contoso.com/Microsoft-Server-ActiveSync'
                 Mailbox = 'eas-test@contoso.com'; ClientId = 'd3590ed6-52b3-4102-aeff-aad2292ab01c' }
    Device  = @{ DeviceId = ''; DeviceType = 'EasOAuthMailbox'; UserAgent = 'EasOAuthMailbox/1.0' }
    Test    = @{ DefaultType = 'Full'; MessageCount = 5; AcknowledgePolicy = $false
                 OAuthPollTimeoutSeconds = 600; HttpTimeoutSeconds = 60; CertificateWarningDays = 30 }
    Report  = @{ OutputPath = '.\reports'; FilePrefix = 'EasOAuthMailbox'; Formats = @('Csv', 'Html'); CsvDelimiter = ';' }
    Logging = @{ Path = '.\logs'; RetentionDays = 14 }
    AppleMail = @{ ClientId = 'f8d98a96-0999-43f5-8af3-69971c7bb423'; UserAgent = 'Apple-iPhone15C4/2401.539000006'; DeviceType = 'iPhone' }
}
```

| Key | Default | Role |
|---|---|---|
| `Target.AdfsUrl` | — | AD FS root, ends with `/adfs`. Not needed for *AppleMail*, which reads it in the Exchange response like the iPhone. |
| `Target.EasUrl` | — | ActiveSync URL published to devices (`/Microsoft-Server-ActiveSync`). *AppleMail* finds it by Autodiscover and only uses this value if Autodiscover does not answer (the server the user would enter). |
| `Target.Mailbox` | — | Test mailbox (SMTP or UPN). Used for the `User=` parameter and for the *Identity* check comparison. |
| `Target.ClientId` | `d3590ed6-…` | Native client authorised by AD FS for the EAS scope. |
| `Device.DeviceId` | empty | Empty: stable value derived from the workstation, mailbox and type. Otherwise 1 to 32 letters or digits. |
| `Device.DeviceType` | `EasOAuthMailbox` | Device type seen by Exchange (letters and digits). |
| `Device.UserAgent` | `EasOAuthMailbox/1.0` | `User-Agent` header, visible in IIS and HttpProxy logs. |
| `Test.DefaultType` | `Full` | Default scenario. |
| `Test.MessageCount` | 5 | Headers read by *InboxSync* (1 to 100). |
| `Test.AcknowledgePolicy` | `$false` | Allows acknowledgement of the ActiveSync policy. Test mailbox only. |
| `Test.OAuthPollTimeoutSeconds` | 600 | Maximum wait for sign-in in the browser. |
| `Test.HttpTimeoutSeconds` | 60 | Timeout for each HTTP request. |
| `Test.CertificateWarningDays` | 30 | *Discovery*: warning if a certificate expires earlier. |
| `Report.OutputPath` | `.\reports` | Report folder (one subfolder per run). |
| `Report.FilePrefix` | `EasOAuthMailbox` | File prefix. |
| `Report.Formats` | `Csv`, `Html` | Formats; `Summary.json` is always written. |
| `Report.CsvDelimiter` | `;` | `;` opens directly in Excel under French regional settings. |
| `Logging.Path` · `RetentionDays` | `.\logs` · 14 | Daily log and its retention period. |
| `AppleMail.ClientId` | `f8d98a96-…` | AD FS client of Apple's Mail app, used instead of `Target.ClientId` by *AppleMail*. |
| `AppleMail.UserAgent` | `Apple-iPhone15C4/2401.539000006` | ActiveSync User-Agent of the iPhone (recorded on an iPhone 15 running iOS 27). |
| `AppleMail.DeviceType` | `iPhone` | Device type seen by Exchange. The device ID derives from this type: the “iPhone” and the tool are **two distinct devices** in `Get-MobileDevice`. |

> [!CAUTION]
> No secret in this file: sign-in is interactive and the token stays in memory. The delivered file contains only `contoso.test` sample values.

# Part III · Use

<!-- icon: terminal -->
## 8. Command line

```powershell
# Prerequisites, no sign-in
.\Invoke-EasOAuthMailbox.ps1 -TestType Discovery

# Is the AD FS token issued and then accepted by Exchange?
.\Invoke-EasOAuthMailbox.ps1 -TestType Endpoint

# Full acceptance test for a test mailbox, ActiveSync policy acknowledged if Exchange requires it
.\Invoke-EasOAuthMailbox.ps1 -TestType Full -AcknowledgePolicy

# Another mailbox and another report folder, without changing the configuration
.\Invoke-EasOAuthMailbox.ps1 -TestType InboxSync -Mailbox eas-test2@contoso.com -MessageCount 20 -OutputPath D:\Diag

# The Mail app path on an iPhone, for the mailbox of a user who reports a problem
.\Invoke-EasOAuthMailbox.ps1 -TestType AppleMail -Mailbox eas-test@contoso.com -AcknowledgePolicy

# Window
.\Invoke-EasOAuthMailbox.ps1 -Gui
```

```cards
layers | -TestType | Discovery, OAuth, Endpoint, FolderSync, Provisioning, Identity, InboxSync, Full or AppleMail.
shield | -AcknowledgePolicy | Allows acknowledgement of the ActiveSync policy (test mailbox).
settings | Overrides | `-AdfsUrl`, `-EasUrl`, `-Mailbox`, `-DeviceId`, `-MessageCount`, `-OutputPath`, `-ConfigPath`.
file | -NoReport | Console and log only, no report file.
```

![Console for a Full scenario (simulated Exchange, anonymised paths)](images/eas-console.png)

The console follows the same rules as the other tools: title card with context, one numbered stage per phase, one line per check, final card with the status, first problem, report, log and next action. Colours disappear when output is redirected (`NO_COLOR`); icons adapt to the terminal (`EOM_ICONS = Emoji | Symbols | Ascii`).

| Exit code | Status | Meaning |
|---:|---|---|
| `0` | Passed | All checks passed. |
| `1` | Failed | A check failed, or the configuration is invalid. |
| `2` | Warning · Blocked | Completed with warnings, or stopped because acknowledgement was not authorised. |

> [!WARNING]
> `-AccessToken` lets you provide a token that was already obtained (integration). A token entered on the command line can remain in PowerShell history: the tool reports this as a warning.

<!-- icon: people -->
## 9. Window

`.\Invoke-EasOAuthMailbox.ps1 -Gui` opens the window. It runs **the same engine** as the command line and writes the same report.

![The window after a Full scenario (simulated Exchange)](images/eas-gui.png)

- **Target and authentication**: AD FS and ActiveSync URLs, mailbox, client, device ID, number of headers. Values come from the configuration and are not saved again.
- **Diagnostic scenario**: the list of the nine scenarios; the description, warning (orange if a partnership can be created) and policy authorisation checkbox adapt to the scenario. The checkbox is active only for scenarios that can provision. For *AppleMail*, the warning reminds you that the Apple client replaces the displayed *Client ID*.
- **Run the test**: first validates all values (errors appear in *Progress*, nothing is sent), then runs. The window stays responsive while waiting for AD FS sign-in; **Cancel** stops at the next check.
- **Progress**: the same lines as the console, timestamped, **including the AD FS sign-in code**.
- **Open the report** · **Open the folder**: active after a run.
- **Close**, the **Esc** key or the close button close the window. During a test, closing is refused: the test stops at the next check, then the window can be closed. The console that opened the window ignores **Ctrl+C** while the window is open (otherwise PowerShell stops the command and the window stops responding); it is restored when the window closes.

> [!NOTE]
> The window follows Windows scaling (125%, 150%...): sizes, margins and fonts are enlarged together, and the window is limited to the screen size.

<!-- icon: search -->
## 10. The checks in detail

### 10.1 Discovery — no sign-in

| Check | Passed | Warning | Failed |
|---|---|---|---|
| AD FS metadata | `openid-configuration` published with a `token_endpoint` | Not readable (endpoint disabled in AD FS, network): sign-in can still work | — |
| TLS certificate (host) | Certificate trusted, expiry beyond `CertificateWarningDays` | No direct TCP connection (proxy) or close expiry | Certificate not trusted by the workstation |
| OAuth challenge | `401` with `WWW-Authenticate: Bearer`, to the anonymous request or to the empty `Bearer` header; optionally announced authorisation server = the configured AD FS | No `Bearer` challenge, even to the empty header; `Bearer` announcing a **different** authorisation server; `451` redirect (`X-MS-Location`); anonymous `200` | Other HTTP code (URL, publication) |
| OAuth for the mailbox | Request with empty `Authorization` header and `X-User-Identity` = the mailbox: `401` with the authorisation URL of the configured AD FS (`authorization_uri`, `issuer_kind="ADFS"`) | URL of a **different** authorisation server; OAuth accepted without authorisation URL; `451` redirect | OAuth refused for this mailbox (`oauth_not_available`): authentication policy that blocks ActiveSync, non-accepted domain |
| Invalid token | A forged token is refused (`401`) | Code other than `401` | **The fake token is accepted**: investigate the publishing chain immediately |

> [!NOTE]
> Exchange Server (2019 CU13+, SE) does not return a `Bearer` challenge to an anonymous request: only `Basic`. It returns it to a request that already carries an empty `Authorization: Bearer` header, the one sent by a client to discover OAuth. *Discovery* therefore sends this second request if the first one is not enough (detail *ChallengeRequest*: `Empty Bearer`). The accompanying `x-ms-diagnostics` header (`oauth_not_available`, *Flighting is not enabled*) also appears in a functional AD FS environment: by itself, it does not indicate a fault.
>
> When Exchange announces an authorisation URL (`authorization_uri`), it is the URL of its default authorisation server (`Set-AuthServer -IsDefaultAuthorizationEndpoint`). If it does not point to the configured AD FS, devices will authenticate elsewhere.

### 10.2 OAuth — sign-in and token

The tool requests a device code from AD FS, opens the verification page and displays the code (console and window), then polls AD FS until sign-in, code expiry or `OAuthPollTimeoutSeconds`.

The **Token claims** check reads the token claims (without verifying its signature; that role belongs to Exchange):

| Claim | Expected | Otherwise |
|---|---|---|
| `aud` | The Exchange URL with the final slash (`https://mail.contoso.com/`) | Warning: Exchange will return 401 |
| `scp` | Contains `EAS.AccessAsUser.All` | Warning: missing issuance rule or permission |
| `exp` | In the future | **Failed**: the scenario stops |
| `upn` | Informational | If different from the mailbox (UPN ≠ SMTP), the *Identity* check decides |

### 10.3 Endpoint — the token presented to Exchange

`OPTIONS` with `Authorization: Bearer`. A refusal gives the HTTP code and the reason given by Exchange in `x-ms-diagnostics` (for example *The token has an invalid audience*). On success, the detail gives the Exchange version, protocol versions and number of commands; a warning reports the absence of protocol 14.1 or of a command used.

### 10.4 ActiveSync policy and FolderSync

```flow
folder | FolderSync | key 0
arrow | 449 · 142 | provisioning required
shield | Provision | download
arrow | authorised? | AcknowledgePolicy
check | Acknowledgement | final key
arrow | same key | retry
folder | FolderSync | folders, Inbox
```

- Exchange requires provisioning: the policy is **downloaded** (*Policy* tab). Without authorisation: **Blocked**, stop. With authorisation: acknowledgement, then `FolderSync` retried with the **final key**, reused by all following commands (`Settings`, `Sync`).
- The *Provisioning* scenario downloads the policy immediately, even if Exchange does not require it.
- Successful `FolderSync` without a type 2 folder (Inbox): warning, and *InboxSync* will fail.

### 10.5 Identity — the user seen by Exchange

`Settings` › `UserInformation` returns the name and addresses of the user **associated with the token**. Passed if the mailbox being tested is one of these addresses; otherwise Warning: the folders and messages read are those of the token user.

### 10.6 InboxSync — the headers

Initial sync of the Inbox (key 0), then a request for `MessageCount` items: received date, sender, subject, read. No body, no attachment. *More available* indicates that the mailbox contains other items.

### 10.7 AppleMail — the Mail app path on an iPhone

The scenario replays what the iPhone does when the user adds an Exchange account (*Settings › Mail › Accounts › Add Account › Microsoft Exchange*): email address, then the AD FS page opens in an embedded browser, then the account is added. The sequence comes from a real trace recorded in the lab (iPhone 15, iOS 27, Exchange Server SE, AD FS published through WAP), in Exchange IIS and HttpProxy logs and the AD FS audit:

```flow
search | Autodiscover | ActiveSync URL
arrow | empty header | + identity
server | Exchange 401 | AD FS URL
arrow | browser | Apple client
key | AD FS page | password
arrow | code | token
mail | ActiveSync 16.1 | as iPhone
```

| Moment | What the iPhone does | User-Agent | What the tool replays |
|---|---|---|---|
| 1 | Autodiscover v2 on `autodiscover.<domain>`: the ActiveSync URL | `Apple-iPhone15C4/…` | Same (then the domain itself): *Autodiscover* check. **The URL found is the one used for the rest.** |
| 2 | `GET /Microsoft-Server-ActiveSync` with an empty `Authorization` header and the user's identity: Exchange returns `401` with the AD FS authorisation URL | `Preferences/…` | Same: *OAuth for the mailbox* check. **The AD FS used for the rest is the one from this URL.** |
| 3 | Opens the `/adfs/oauth2/authorize` page of the Apple client in an embedded browser (request below) | Safari (WebKit) | Same request **without entering a password**, for the three redirect URIs: *Apple Mail client in AD FS* check. |
| 4 | Password entered, authorisation code returned to `com.apple.Preferences://oauth-redirect`, exchanged on `/adfs/oauth2/token` | `Preferences/…` | A Windows workstation does not receive this iOS-specific redirect: token from the **same Apple client** through *device code* (same resource, same scope), then token client check. |
| 5 | `OPTIONS`, `FolderSync`, `Provision` ×2, `FolderSync`, `Settings`, `Sync`, `Ping` with protocol **16.1**, `DeviceType=iPhone` | `Apple-iPhone15C4/…` | Same up to `Sync` (without `Ping`), same policy and same key: stages *Endpoint* to *InboxSync*. |

The request from step 3, as recorded in the AD FS audit (and replayed by the tool):

```text
GET https://<adfs>/adfs/oauth2/authorize
    ?response_type=code
    &client_id=f8d98a96-0999-43f5-8af3-69971c7bb423
    &redirect_uri=com.apple.Preferences://oauth-redirect
    &resource=https://<exchange>/
    &display=ios  &ui_locales=fr-fr  &state=<GUID>
    &claims={"access_token":{"xms_cc":{"values":["cp1"]}}}
    &login_hint=<address>
```

> [!NOTE]
> **Only the address is requested**, as on the iPhone: `-TestType AppleMail -Mailbox <address>`. The ActiveSync URL comes from Autodiscover, and AD FS from the Exchange response; `Target.AdfsUrl` and `Target.ClientId` are not used (greyed out in the window). `-EasUrl` is used only if Autodiscover does not answer. The report's *Scope* block indicates where each URL comes from.

![Console for an AppleMail scenario (simulated Exchange, anonymised paths)](images/eas-console-apple.png)

> [!IMPORTANT]
> **The point that most often makes the iPhone fail is moment 2.** Exchange only gives the AD FS URL if the user's authentication policy allows modern authentication for ActiveSync. Otherwise it returns `oauth_not_available` (*Flighting is not enabled for domain …*) and the iPhone **asks for a password** (basic authentication) instead of opening the AD FS page. The *OAuth for the mailbox* check reports it, with the `Get-User` and `Get-AuthenticationPolicy` commands to run. *Discovery* performs the same check for the mailbox in the configuration.

| Check | Passed | Warning | Failed |
|---|---|---|---|
| Autodiscover | An ActiveSync URL is returned for the mailbox | URL different from `-EasUrl` (the Autodiscover URL is used); no response but `-EasUrl` provided (the manually entered server is used) | No response and no `-EasUrl`: **stop**, the iPhone would ask for the server |
| OAuth for the mailbox | Authorisation URL returned for the mailbox | No authorisation URL | OAuth refused for the mailbox: **the scenario stops**, like the iPhone |
| AD FS found | — | — | The authorisation URL is not an AD FS URL (Entra ID in hybrid, for example): **stop** |
| Apple Mail client in AD FS | AD FS sign-in page for the three redirect URIs | A URI other than the Settings URI is refused (MSIS9224) | Client unknown to AD FS (MSIS9223) or Settings URI refused: **stop**, no sign-in requested |
| Token claims | Token issued for the Apple client, expected audience and scope | Token issued for another client, unexpected audience or scope | Token expired |

> [!WARNING]
> **An “iPhone” device appears in Exchange.** From `FolderSync`, Exchange records the `iPhone` type device, friendly name `iPhone (EAS OAuth Mailbox <computer>)`, system `iOS (simulated by EAS OAuth Mailbox)`. It is distinct from the `EasOAuthMailbox` device used by the other scenarios. To remove it: `Get-MobileDevice -Mailbox <mailbox> | Where-Object FriendlyName -like 'iPhone (EAS OAuth Mailbox*' | Remove-MobileDevice`. A device access rule (ABQ) that targets iPhones applies to it as to a real iPhone.

> [!TIP]
> The User-Agent and device type are set in the `AppleMail` section of the configuration, for example to reproduce the exact model of a user (`Get-MobileDevice | Format-List DeviceUserAgent, DeviceModel`).

<!-- icon: chart -->
## 11. Reading the report

The HTML report is self-contained (no external resource), follows the system light or dark theme and uses the same visual system as Purview DLP Report and Exchange Log Report.

![Header, tiles and scope](images/eas-report-overview.png)

- **Header**: scenario, mailbox, run period; four tiles — result (and first problem), checks passed, folders, headers — then the status distribution bar.
- **Scope**: mailbox tested, token user, primary address seen by Exchange, policy state, AD FS, ActiveSync, device ID, token scope and client.

![The checks, grouped by stage](images/eas-report-checks.png)

- **Checks**: the checks in run order, grouped by stage, with their duration. A box at the top repeats the first *Failed* or *Blocked* check. **Read from top to bottom and stop at the first red or orange item.** Under each check, one line per HTTP request: the method, URL, what was sent (*no credentials*, *empty ****** *X-User-Identity*, *access token*, policy key...) and the response (`← 401 Unauthorized`, `← 449 Retry With`...).

![Detail of a check](images/eas-report-detail.png)

- **Detail**: click a check to display everything that was kept — HTTP code, `x-ms-diagnostics`, certificate, token claims, redirect... — then **the HTTP exchanges for this check**.
- **Tabs**: *All checks*, *Folders*, *Inbox headers*, *Policy*, *HTTP trace*; search, sort by column, detail of a row on click and **Export view to CSV** for the filtered view.

### 11.1 The HTTP trace: request sent, response received

Each request from the tool (ActiveSync, Autodiscover, AD FS) is kept with the received response, and attached to the check that sent it. Click a line under a check (or in the *HTTP trace* tab) to display it in two columns, **Request sent** and **Response received**, as they travelled:

![A check and its HTTP exchange: the OAuth discovery request and the Exchange 401 response](images/eas-report-exchange.png)

| Part | What is shown |
|---|---|
| Start line | `OPTIONS /Microsoft-Server-ActiveSync HTTP/1.1`, `HTTP/1.1 401 Unauthorized`. |
| Headers | All, in order: `Authorization`, `User-Agent`, `MS-ASProtocolVersion`, `X-MS-PolicyKey`, `X-User-Identity` on the request side; `WWW-Authenticate` (one per challenge), `x-ms-diagnostics`, `X-FEServer`, `request-id` on the response side. |
| ActiveSync body | The **WBXML decoded as XML** (`<FolderSync>`, `<Provision>`, `<Settings>`, `<Sync>`), with its size in bytes. |
| AD FS body | Form fields one per line (`grant_type`, `client_id`...), indented JSON, summarised HTML pages (title, `MSIS` error, sign-in form present). The parameters of a long URL (AD FS authorisation page) are also listed one per line. |
| TLS connection | For certificate checks: the requested name (SNI) and the presented certificate (subject, issuer, expiry, protocol, trust). |

> [!IMPORTANT]
> **No secret in the trace.** The access token, refresh token, `id_token`, device code, authorisation code and cookies are replaced by their length (`****** token: 1234 characters, never written>`). Only the fake token from the *Invalid token* check appears in full: it is not a secret. Mailbox data (folders, addresses, subjects) appears there as in the rest of the report.

> [!TIP]
> During AD FS sign-in, the tool polls `/adfs/oauth2/token` every 5 seconds: these identical requests (`400 authorization_pending`) are grouped into one line, marked `×N`. The **Copy** button in each column copies the request or the response, for example to attach it to a ticket.

<!-- icon: file -->
## 12. Files produced

Each run creates `<FilePrefix>_<Scenario>_<yyyyMMdd-HHmmss>` under `Report.OutputPath`:

| File | Content |
|---|---|
| `…-Steps.csv` | One check per line: `Stage`, `Name`, `Status`, `Message`, `Details`, `DurationMs`, `TimestampUtc`, `Trace` (numbers of its HTTP exchanges). |
| `…-Folders.csv` | `DisplayName`, `Type`, `TypeName`, `ServerId`, `ParentId`. |
| `…-Messages.csv` | `DateReceived`, `From`, `Subject`, `Read`, `ServerId`. |
| `…-Policy.csv` | `Setting`, `Value`: ActiveSync policy returned by Exchange. |
| `…-Trace.csv` | One HTTP exchange per line: number, check, method, URL, what was sent, status, duration, send count, **full request and response** (secrets masked). |
| `…-Summary.json` | The full result, for a script. |
| `….html` | The self-contained report. |
| `logs\EasOAuthMailbox_yyyyMMdd.log` | Log of the day (same lines as the console, without colour or icon), plus one line per HTTP request (`HTTP #n POST … -> 449 Retry With`). |

> [!IMPORTANT]
> CSV files are UTF-8 with BOM. A text cell that starts with `=`, `+`, `-` or `@` (for example a message subject) is prefixed with an apostrophe, as in Purview DLP Report: Excel does not interpret it as a formula. Reports contain the mailbox, its addresses and message subjects: protect them as messaging data.

# Part IV · Maintain

<!-- icon: gear -->
## 13. Architecture

| File | Role |
|---|---|
| `Invoke-EasOAuthMailbox.ps1` | Entry point: configuration, overrides, log, banner, run, report, final card, exit code. |
| `EasOAuthMailbox.psd1` · `.psm1` | Module manifest and loader, shared state. |
| `src\EasOAuthMailbox.Console.ps1` | Console and log (same rules as the other tools). |
| `src\EasOAuthMailbox.Config.ps1` | Configuration file, scenarios and their stages. |
| `src\EasOAuthMailbox.Http.ps1` | All HTTP requests go through `Invoke-EomHttp`: send (`Send-EomHttpRequest`, only contact point with the network) and trace of the exchange (secrets masked, WBXML decoded). |
| `src\EasOAuthMailbox.Core.ps1` | ActiveSync protocol: WBXML, `Provision`, `FolderSync`, `Settings`, `Sync` requests, two-phase provisioning. |
| `src\EasOAuthMailbox.Checks.ps1` | AD FS sign-in, claims, one function per stage, orchestration. |
| `src\EasOAuthMailbox.Report.ps1` | CSV, JSON and HTML. |
| `src\EasOAuthMailbox.Gui.ps1` | Windows Forms window. |
| `templates\Report.template.html` | Report: text, colours and tabs can be changed without touching code. |
| `config\EasOAuthMailbox.config.psd1` | Configuration. |

The token is never placed in the result of a run, and the HTTP trace only keeps its length: no file can contain it.

<!-- icon: beaker -->
## 14. Tests

```powershell
.\Run-Tests.ps1
```

Tests use neither AD FS nor Exchange: `tests\EasOAuthMailbox.Simulator.ps1` simulates both, by replacing the only contact point with the network (`Send-EomHttpRequest`); everything else — request construction, trace, device code sign-in — is the real code. ActiveSync responses are **WBXML documents built byte by byte** with the protocol code pages (FolderSync, Provision, Settings, AirSync, Email), with real Exchange HTTP codes and headers (`WWW-Authenticate`, `x-ms-diagnostics`, `X-MS-Location`).

```cards
settings | Configuration | Sections, unknown keys, paths, scenarios, device ID.
key | Token | Base64url decoding, audience, scope, expiry.
layers | Protocol | Integers and WBXML strings, truncated or malformed documents, exact requests, statuses.
server | Scenarios | Simulated Exchange: provisioning by 449 or status 142, final key propagated, 403, remote wipe, fake token accepted, other authorisation server, OAuth blocked for a mailbox...
phone | AppleMail | User-Agent and iPhone device type on each request, Apple client AD FS page, missing client (MSIS9223), redirect URI refused (MSIS9224), blocked mailbox, missing Autodiscover, token from another client.
file | Report and window | Files, HTTP trace (exchanges attached to their check, WBXML decoded, tokens, codes and cookies masked, grouped sign-in wait), no token, formula protection, order of the window sections, validation before running, closing without PowerShell code, closing refused during a test, text not truncated at screen scale.
```

Each fault fixed during tuning is covered by a dedicated test; reintroducing the fault makes this test fail, and only this one.

<!-- icon: wrench -->
## 15. Evolving the tool

| Evolution | Where |
|---|---|
| A new check in a stage | `src\EasOAuthMailbox.Checks.ps1`, function `Invoke-EomStage<Étape>` (one call to `Add-EomStep` per check), then a test with the simulator. |
| A new scenario | `src\EasOAuthMailbox.Config.ps1`, `$script:Scenarios` array (name, description, stages). The window and the command line offer it immediately (add the name to the `ValidateSet` of `Invoke-EasOAuthMailbox.ps1` and `Invoke-EomMailboxTest`). |
| A new ActiveSync command | `src\EasOAuthMailbox.Core.ps1` (WBXML request, code page tags), then its response in the simulator. |
| Report text, colours, tabs | `templates\Report.template.html`. |
| This guide | `docs\EasOAuthMailbox-Guide.md`, then `.\tools\Build-Documentation.ps1`. |
| Screenshots | `.\tools\New-DocumentationImages.ps1` (chapter 16). |
| Version | `EasOAuthMailbox.psd1`, `$script:ToolVersion` of the module, headers, this guide, `CHANGELOG.md`. |

<!-- icon: book -->
## 16. Documentation, screenshots and package

The screenshots in this guide are produced **by the tool itself**, against the simulated Exchange: they always match the code. Names and paths are anonymised (`contoso.test`, `C:\Tools\EasOAuthMailbox`).

```steps
Test | `.\Run-Tests.ps1`
Regenerate screenshots | `.\tools\New-DocumentationImages.ps1`: console (terminal colour rendering), window (`DrawToBitmap`) and report (Microsoft Edge without UI).
Build the guide | `.\tools\Build-Documentation.ps1` writes `docs\EasOAuthMailbox-Guide.html`, self-contained (embedded images).
Build the package | `.\tools\New-EasOAuthMailboxPackage.ps1` rebuilds the guide, then copies only the runtime files to `..\package\EasOAuthMailbox-<version>`.
```

### 16.1 Validation

| Validated | How |
|---|---|
| Protocol, scenarios, report, window | Automated tests against the simulated Exchange. |
| Real network checks in *Discovery* | Against a public ActiveSync endpoint: TLS 1.3 certificate, `451` redirect with `X-MS-Location`, fake token refused with `401`, unknown AD FS host as warning. |
| AD FS + Exchange path | *Discovery* validated on 02/10/2026 on Exchange Server SE (15.2.2562) with AD FS (farm level 4), published through WAP: 6 checks passed for an authorised mailbox; *OAuth for the mailbox* failed for a mailbox whose policy blocks modern authentication, as expected. *Full* validated the same day with real sign-in (window, policy acknowledged): 12 checks passed, policy with 42 settings, 19 folders, 5 headers. |
| *AppleMail* | Sequence recorded on a real iPhone (iOS 27) in the same lab. *AppleSetup* stage validated for real (Autodiscover, announced AD FS URL, Apple client AD FS page for the three URIs); refusal of the blocked mailbox confirmed. Path with real sign-in: **to do**. |

# Appendices

<!-- icon: lifebuoy -->
## Appendix A - Troubleshooting

| Symptom | Cause and action |
|---|---|
| `Target.AdfsUrl must end with /adfs` (and other configuration messages) | The indicated value; all errors are listed at once. |
| *AD FS metadata* as warning | `openid-configuration` endpoint disabled or AD FS unreachable: check `https://<adfs>/adfs/.well-known/openid-configuration` in a browser. |
| *TLS certificate*: *No direct TLS connection* | Normal behind a proxy. Otherwise: DNS, firewall. |
| *TLS certificate*: *not trusted* | Certification chain not trusted by the workstation, name absent from the certificate, expired certificate. |
| *OAuth challenge*: missing `Bearer` | Exchange returns no `Bearer` challenge, even to an empty `Authorization: Bearer` header: `OAuth` missing from the ActiveSync virtual directory, missing `New-AuthServer -Type ADFS`, `OAuth2ClientProfileEnabled` at `$false`, or reverse proxy that removes the header. |
| *OAuth challenge*: other authorisation server | `Get-AuthServer`: the server with `IsDefaultAuthorizationEndpoint` is not the expected AD FS (HMA hybrid configuration, for example). |
| *OAuth challenge*: HTTP 451 | Exchange redirects the mailbox to another ActiveSync URL (`X-MS-Location`): test this URL. |
| *Invalid token* failed | A forged token is accepted: immediately check the publishing chain (proxy that pre-authenticates, bypass rule). |
| `AD FS did not return a device code` | Client unknown to AD FS, *device code* flow unavailable (AD FS version), incorrect URL. |
| `invalid_scope` / `invalid_resource` on sign-in | Missing permission: `Grant-AdfsApplicationPermission` from the client to the Web API with `openid` and `EAS.AccessAsUser.All`. |
| *Token claims*: audience | The AD FS Web API identifier is not the Exchange URL with the final slash. |
| *Token claims*: scope | Issuance rule `scp = EAS.AccessAsUser.All` missing from the Web API. |
| *Endpoint*: HTTP 401 | Read `Exchange diagnostics` in the message: audience, untrusted issuer (`Get-AuthServer`), user's authentication policy (`BlockModernAuthActiveSync`). Wait 30 minutes or run `iisreset` after a change. |
| *Endpoint*: HTTP 403 | User or device blocked for ActiveSync: `Get-CASMailbox <mailbox> \| Format-List ActiveSync*`, device access rules, quarantine. |
| **Blocked** | Expected without authorisation: read the *Policy* tab again, then rerun with `-AcknowledgePolicy` on the test mailbox. |
| *Identity* as warning | The token user is not the test mailbox: account used in the browser, different UPN and SMTP. |
| *InboxSync*: *No Inbox* | `FolderSync` did not return a type 2 folder: mailbox not initialised or rights. |
| No window with `-Gui` | Session without desktop (service, SSH): use the command line. |
| The window displays “The pipeline has been stopped” | The command that opened the window was stopped (*Stop* button in an editor, Ctrl+C in a host that is not a console): the window always closes (Close, Esc, close button), then rerun `-Gui`. |
| *OAuth for the mailbox* failed (`oauth_not_available`) | The user's authentication policy (or the organisation policy, `DefaultAuthenticationPolicy`) blocks modern authentication for ActiveSync: an iPhone then asks for a password instead of opening AD FS. `Get-User <mailbox> \| Format-List AuthenticationPolicy`, then `Set-User -AuthenticationPolicy`; wait 30 minutes or run `iisreset`. |
| *Apple Mail client in AD FS*: MSIS9223 | The client `f8d98a96-…` does not exist in AD FS: `Add-AdfsNativeClientApplication` (“iOS and macOS - Native mail application”) then `Grant-AdfsApplicationPermission` to the Exchange Web API with `openid` and `EAS.AccessAsUser.All`. |
| *Apple Mail client in AD FS*: MSIS9224 | A redirect URI of the Apple client is missing: `Set-AdfsNativeClientApplication -TargetIdentifier f8d98a96-0999-43f5-8af3-69971c7bb423 -RedirectUri <les trois URI>`. |
| Clean the test device | `Get-MobileDevice -Mailbox <mailbox> \| Where-Object DeviceType -eq 'EasOAuthMailbox' \| Remove-MobileDevice`; for *AppleMail*: `Where-Object FriendlyName -like 'iPhone (EAS OAuth Mailbox*'`. |

<!-- icon: info -->
## Appendix B - HTTP codes and ActiveSync statuses

| Code | Meaning for the tool |
|---|---|
| HTTP 200 | Normal response; the ActiveSync status in the WBXML is then checked. |
| HTTP 401 | Token refused (or anonymous request, expected in *Discovery*). |
| HTTP 403 | User or device blocked for ActiveSync. |
| HTTP 449 | Provisioning required, or policy key refused. |
| HTTP 451 | Redirect to another ActiveSync URL (`X-MS-Location`). |
| Status 1 | Success. |
| Statuses 141 to 145 | Provisioning required or key refused: handled like an HTTP 449. |
| Status 139 · 140 | The device cannot apply the policy · remote wipe pending. |

<!-- icon: shield -->
## Appendix C - Security and data

- The access token stays in memory: never in the console, log, JSON, CSV or HTML. The AD FS sign-in code, valid for a few minutes, appears in the console and log.
- The ActiveSync policy is only acknowledged with explicit authorisation; a remote wipe command is never acknowledged.
- Requests do not use the Windows credentials of the workstation (`UseDefaultCredentials = $false`) and do not follow HTTP redirects.
- Reports contain messaging data (addresses, subjects): store and transmit them as such.

<!-- icon: tag -->
## Appendix D - Versions

MAJOR.MINOR.PATCH: MAJOR for a configuration or report format change, MINOR for a new check or scenario, PATCH for a fix. Each change is described in `CHANGELOG.md`.
