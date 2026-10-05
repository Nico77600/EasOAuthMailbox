# Changelog — EAS OAuth Mailbox

All notable changes are listed here. Versions follow MAJOR.MINOR.PATCH (see the guide, Annex D).
Author: Nicolas Fabert.

## [1.2.1] — 2026-10-05

### Fixed
- *TLS certificate* no longer says **Certificate not trusted** when the connection is closed during the TLS handshake, before the server sends its certificate: it now says *TLS handshake interrupted* and that the certificate is not in question — a firewall or NSG that filters the source address, a reverse proxy, or a VPN or Global Secure Access client that tunnels the address of the server. A certificate received and rejected keeps *not trusted*, with the reason (`RemoteCertificateChainErrors (UntrustedRoot)`, `RemoteCertificateNameMismatch`, `NotTimeValid`...). Seen on a lab: a Global Secure Access client tunnelled the address of the ActiveSync URL and the network security group refused the egress address of the tunnel.
- A request that gets no answer gives its reason without the PowerShell wrapper: *The SSL connection could not be established: An existing connection was forcibly closed by the remote host* instead of *Exception calling "GetResult" with "0" argument(s): "The SSL connection could not be established, see inner exception."* (OAuth challenge, Autodiscover, endpoint...).
- Guide: troubleshooting entry for an interrupted TLS handshake. 3 new tests (122 in total).

## [1.2.0] — 2026-10-05

### Added
- **Hybrid modern authentication (HMA)**: `-Authority EntraID` (`Target.Authority`) tests ActiveSync with **Entra ID** as authorization server instead of AD FS, for an Exchange Server 2019 CU13+ / SE organisation in hybrid with Exchange Online. `-Authority Auto` signs in where Exchange sends the mailbox, like a client; *AppleMail* always does. `Target.TenantId` (`-TenantId`): tenant ID or domain, found from the domain of the mailbox when empty.
- *Discovery* with Entra ID: **Entra ID tenant** (OpenID configuration of the tenant), **User realm** (managed or federated domain), the OAuth challenge and *OAuth for the mailbox* compared with the expected server (Entra ID named while AD FS is expected, and the reverse, each with the command to check), **Tenant trusted by Exchange** (`trusted_issuers` of the challenge).
- Sign-in with the device code of the Microsoft identity platform v2.0 (`/<tenant>/oauth2/v2.0/devicecode`, scope `https://<exchange>/EAS.AccessAsUser.All`); *Token claims* checks the tenant (`tid`) and names a token issued for Exchange Online. Common Entra ID errors are explained (`AADSTS500011` URL not registered, `AADSTS65001` / `AADSTS90094` consent, `AADSTS53003` Conditional Access...).
- *AppleMail* through Entra ID: tenant, realm and the Entra ID sign-in page of the Apple Mail client (*Apple Internet Accounts*), then sign-in with that client.
- When no browser can be opened (service session, Server Core, SSH), the device code is shown with the page to open on any other device instead of failing.
- Window: one *Authentication* list (*OAuth - AD FS*, *OAuth - Entra ID (hybrid modern auth)*, *OAuth - server given by Exchange*, *Basic*). Report: *Entra ID* card (tenant), stage titles; `Authority`, `AuthorityUrl`, `AuthoritySource` and `TenantId` in the result.
- Guide: Entra ID prerequisites and checks, troubleshooting entries, console screenshot with Entra ID. 12 new tests (97 in total).

- **Sign-in window** for OAuth (`-SignIn`, `Test.SignIn`): Microsoft Edge or Google Chrome opens the page of AD FS or Entra ID in a window with a temporary profile — no account of the workstation, no single sign-on — and the user types the password and the MFA there, like in a mail app. Authorisation code with PKCE and `prompt=login`; the redirect that carries the code is caught through the DevTools protocol of the browser (loopback only) before the browser follows it, then the code is exchanged and the profile deleted. Redirect URIs: the native-client page of Entra ID, `urn:ietf:wg:oauth:2.0:oob` for AD FS (Exchange application group), and for *AppleMail* `com.apple.Preferences://oauth-redirect`: the exact flow of the iPhone web view, with AD FS and with Entra ID.
- `-SignIn Auto` (default): the window when the session can show one, the device code otherwise (service, scheduled task, SSH, no browser, AD FS without the redirect URI of the window), with the reason; `-SignIn DeviceCode` forces the code. Window: *Sign in with a device code* checkbox. Report and `Summary.json`: `SignIn` (Window, DeviceCode, Supplied). Device code: a line recalls to use a private window when the browser is signed in with another account. 8 new tests (105 in total).

### Changed
- **Guide reorganised around the three ways to sign in**: a new part *Three ways to sign in* with a comparison chapter (*Choose the path*, diagram and side-by-side table) and one chapter per path — OAuth with AD FS, OAuth with Entra ID, Basic — each with its prerequisites, commands and specific checks. Shorter tables and paragraphs (about a quarter shorter), troubleshooting grouped by path, the stage diagram updated for the three paths. The readme presents the three paths.
- Final console card: the `Get-MobileDevice` hint only appears for the scenarios that create a device partnership.
- Documentation builder: long code in a table cell (a command, a URL) wraps instead of widening the table.
- **New window in WPF**, Fluent theme of Windows 11 (PowerShell 7.5+, .NET 9+): light or dark like Windows, the accent colour of the report, sharp at any scaling. The three sign-in methods as cards; the target with only the fields of the chosen method (*Client and device* folded); the scenario and its notice; the progress with the icon of each check and a box for the device code (*Copy*, *Open the page*). Same engine, same behaviours (validation before the run, cancel, close refused during a run, native close, Ctrl+C ignored). With PowerShell 7.4 the same layout keeps the classic controls. Screenshots: light and dark theme. Window tests rewritten (108 tests).
- Window: the *Authentication* list offers the three paths — *OAuth - On-prem AD FS*, *OAuth - Entra ID* (HMA or Exchange Online), *Basic - On-prem*; `-Authority Auto` (the server Exchange names) stays on the command line.
- **Entra ID for Exchange Online too**: the same sign-in tests a mailbox in Exchange Online with `-EasUrl https://outlook.office365.com/Microsoft-Server-ActiveSync` (the card and the messages no longer say *HMA* when it does not apply). Exchange Online is recognised from the URL: the anonymous `451` (redirect to certificate-based authentication) is followed by the empty-Bearer request, `trusted_issuers="…@*"` passes, every audience of Exchange Online is accepted, the *AADSTS500011* hint fits. When 14.1 is not offered (Exchange Online offers only 16.1), the test goes on in 16.1; ActiveSync status 138 is explained. AD FS or a Basic sign-in with the Exchange Online URL is refused by the configuration check; *AppleMail* with Basic stops before sending the password.
- An HTTP 451 towards Exchange Online (a mailbox moved in hybrid) gives the command to test it there. Guide: chapter 7 *Exchange on-premises (HMA) or Exchange Online*, 7.4 *A mailbox moved to Exchange Online*, troubleshooting. 6 new tests (119 in total).
- The anonymous probes of *Discovery* (*OAuth challenge*, *Basic challenge*) answer a code other than 401 with a **warning**, no longer a failure: the sign-in that follows decides (seen on the lab: HTTP 500 to the anonymous request while Exchange was starting, then a successful Basic run). *OAuth challenge* then also asks with the empty header clients send, and keeps that answer (1 new test, 106 in total).
- **Sign-in window that cannot be used**: a policy that forbids the DevTools protocol of the browser (`RemoteDebuggingAllowed = 0`, machine or user) is read before anything opens — the other browser is tried, else the device code; a window that cannot start (browser closed at once, no DevTools endpoint within 20 s) also falls back to the device code with `-SignIn Auto` and is an error with `-SignIn Window`. The report keeps why the window was not used (*SignInWindow*). 4 new tests.
- Window `-Gui`: light or dark decided by the tool, light when Windows has no setting (Windows Server 2016 — WPF chose dark there and the notices were unreadable); the progress keeps clear of the scroll bar. 1 new test (113 in total).
- Guide: *Windows versions* (9.1) — what the sign-in window and the window need on each version, PowerShell 7 with the MSI on servers; troubleshooting of a window that cannot start.

### Validated
- On a hybrid lab (Exchange Server SE + Exchange Online, HMA enabled for the test): *Discovery* 7 of 7 (`EntraID` and `Auto`), *Full* 14 of 14 with a real Entra ID sign-in, *Endpoint* 6 of 6 with `-Authority Auto`, *AppleMail* through Entra ID with the Apple client, *Full* with Basic (the password still accepted next to HMA: expected warning).
- Basic with a real password on the AD FS lab (mailbox under the policy that blocks modern authentication): *Full* 10 of 10, *AppleMail* 8 of 8 as an iPhone, a wrong password refused once; no password in any output.
- Sign-in window on 05/10/2026 (Microsoft Edge): AD FS *Endpoint* from the command line and the window, *AppleMail* 10 of 10 with the redirect URI of the iPhone; Entra ID *OAuth* with password and MFA, and the Apple client with the redirect of the iPhone (token of *Apple Internet Accounts*).
- AD FS again on 05/10/2026 with a dedicated test account: *Discovery* 6 of 6, *Full* 13 of 13, *Endpoint* with `-Authority Auto` 4 of 4, and *AppleMail* 10 of 10 with the **real sign-in of the Apple Mail client** (until now validated up to its AD FS page). Observed: a user whose policy blocks modern authentication is not offered OAuth (*OAuth for the mailbox* fails, devices fall back to Basic), yet a token obtained directly from AD FS is still accepted for that user.
- **Windows Server 2016, 2019 and 2022** (Azure VMs, 1024 × 768 console) on 05/10/2026, against the AD FS lab: PowerShell 7.6 and 7.4; sign-in window with Microsoft Edge and *Endpoint* passed from the command line and from the window on the three versions; Server 2016 without a browser and the three versions with `RemoteDebuggingAllowed = 0` fall back to the device code; window Fluent (7.6) and classic (7.4), *Segoe MDL2* icons, within the screen. Windows Server 2025 and Windows 11 were already validated.
- **Exchange Online** on 05/10/2026, cloud-only mailbox: *Discovery* 7 of 7 (`EntraID` and `Auto`), *Full* 13 of 13 with password and MFA (Exchange 15.21, ActiveSync 16.1), *AppleMail* with the Apple client (Autodiscover not published for an `onmicrosoft.com` domain: expected warning), Basic *Discovery* reports that Exchange Online does not offer Basic.

## [1.1.0] — 2026-10-03

### Added
- **Basic authentication** (`-Authentication Basic`, `Test.Authentication`): every scenario except `OAuth` runs with a user name and password instead of the AD FS token, like a device without modern authentication. The *OAuth* stage becomes *Basic* (one `OPTIONS` with the user name and password, the run stops at the first refusal so that a wrong password is sent only once); AD FS is never contacted.
- *Discovery* with Basic: certificate of ActiveSync, `Basic` challenge (realm), *OAuth for the mailbox* read for Basic (Passed when Exchange does not offer OAuth to the mailbox — Outlook and the iPhone then ask for the password; Warning when it does), wrong user name and password refused, with a user that does not exist (no account can be locked).
- *AppleMail* with Basic: Autodiscover, then whether the iPhone would ask for the password (Exchange does not offer OAuth to the mailbox), then ActiveSync 16.1 as an iPhone with the password.
- `-Credential` (or the `Get-Credential` prompt, user name proposed from `Target.BasicUser` or the mailbox); new key `Target.BasicUser` (UPN or `DOMAIN\user`). The password is never in the configuration, the console, the log, the trace or the reports: the trace shows `Basic <user …, password never written>`.
- Window: *Authentication* list (OAuth / Basic), user name and password boxes; AD FS URL and client ID greyed with Basic; empty password and the `OAuth` scenario with Basic refused before anything is sent.
- Report: authentication in the title and the scope cards (*Signed-in user* = the user name sent, *Authentication* card, *AD FS: Not used*); `Authentication` and `BasicUser` in the result and `Summary.json`.
- Guide: chapter 10.8, troubleshooting entries, screenshots of the console, window and report with Basic. 13 new tests (85 in total).

### Fixed
- Two sentences of the guide where an `Authorization` header example had been replaced by asterisks.

## [1.0.0] — 2026-10-02

First version as a tool, from the `Test-EasOAuthMailbox.ps1` diagnostic script.

### Added
- **Nine scenarios** instead of two (folders only / folders + Inbox): `Discovery`, `OAuth`, `Endpoint`, `FolderSync`, `Provisioning`, `Identity`, `InboxSync`, `Full`, `AppleMail`. A scenario runs stages in a fixed order; after a failure or a block the next stages are *Skipped*.
- **Discovery** (no sign-in): AD FS OpenID configuration, TLS certificates of AD FS and ActiveSync (trust, expiry, protocol), `WWW-Authenticate: Bearer` challenge of ActiveSync (anonymous request, then an empty `Authorization: Bearer` header like a client) and the authorization server it points to, OAuth offered **for the tested mailbox** (empty `Bearer` header and `X-User-Identity`: Exchange gives the AD FS authorization URL only when the authentication policy of the user allows modern authentication), rejection of a forged token, HTTP 451 redirect (`X-MS-Location`).
- **AppleMail** scenario: the account added like the Mail app of an iPhone, from the mailbox address only (the ActiveSync URL from Autodiscover, AD FS from the authorization URL of the Exchange challenge; `-EasUrl` only when Autodiscover does not answer), from a trace of a real iPhone (iOS 27) on Exchange Server SE + AD FS: Autodiscover v2, AD FS URL from the Exchange challenge (User-Agent of the Settings screen), AD FS authorization page of the Apple Mail client `f8d98a96-…` for its three redirect URIs (no password typed), sign-in with that client, then ActiveSync 16.1 with the User-Agent, DeviceType and device information of an iPhone. New `AppleMail` section in the configuration.
- **Token claims**: audience, `scp` (`EAS.AccessAsUser.All`), expiry and user of the AD FS token compared with the ActiveSync resource.
- **Identity**: `Settings` › `UserInformation`, the addresses Exchange associates with the token, compared with the tested mailbox.
- **Policy review**: when Exchange requires provisioning and the acknowledgement is not authorised, the policy is downloaded and shown (Policy tab) and the run stops as *Blocked*.
- Exchange `x-ms-diagnostics` reason added to every HTTP 401.
- Five statuses (Passed, Warning, Blocked, Failed, Skipped), one duration and one set of details per check; exit codes 0 / 1 / 2.
- Module split by responsibility (`src\*.ps1`), configuration file with sections (unknown keys rejected, all errors at once), console and daily log file with the rules of Exchange Log Report and Purview DLP Report.
- Report: CSV (Steps, Folders, Messages, Policy, Trace), `Summary.json` and a self-contained HTML dashboard with the common design (tiles, scope, checks grouped by stage, tabs, search, sort, detail dialog, CSV export of the view, dark theme).
- **HTTP trace**: every request of the tool (ActiveSync, Autodiscover, AD FS) and the response received, attached to the check that sent it. Under each check of the report, one line per request (what was sent: no credentials, empty Bearer header, X-User-Identity, access token, policy key; status received); in the detail dialog and the *HTTP trace* tab, the request and the response side by side with every header and the WBXML bodies decoded to XML. Tokens, codes and cookies are replaced by their length; repeated token polling is counted once. `Trace.csv` and one log line per request.
- One network entry point (`Send-EomHttpRequest` in `src\EasOAuthMailbox.Http.ps1`): the AD FS requests no longer use `Invoke-RestMethod`, and the simulator replaces only this function.
- Window (`-Gui`): scenario list with description and safety warning, live progress including the AD FS sign-in code, cancel, open report.
- Pester tests against a simulated AD FS and Exchange (`tests\EasOAuthMailbox.Simulator.ps1`, WBXML built byte by byte).
- Administrator guide (Markdown → self-contained HTML), screenshots rendered by the tool itself (`tools\New-DocumentationImages.ps1`), package tool.

### Fixed (compared with the original script and the first refactoring)
- The policy key received when the policy is acknowledged is sent with every following command (`Settings`, `Sync`): Inbox synchronisation failed on mailboxes that require provisioning.
- A blocked provisioning is reported as *Blocked*, not overwritten by a failure of the next stage.
- FolderSync answers other than 200 / 449 (401, 403, 5xx) are failures, never a pass.
- `FolderSync` with `-AcknowledgePolicy` provisions when Exchange requires it, like the original `-FoldersOnly -AcknowledgePolicy`.
- Reports and logs are written under the tool folder, whatever the current folder.
- The window shows its sections in the right order and stays responsive while waiting for the sign-in.
- The window always closes (Close, Esc, title bar) even after the command that opened it was stopped (Ctrl+C, stop button of an editor): closing and painting no longer run PowerShell code, which failed with "The pipeline has been stopped". Closing during a test cancels the test first; Ctrl+C is ignored by the console while the window is open.
- The window scales with the Windows display setting (125 %, 150 %...): texts of buttons and header were cut on high-DPI screens.
- *OAuth challenge* no longer warns on a working Exchange Server SE + AD FS: Exchange returns its `Bearer` challenge only to a request that already carries an empty `Authorization: Bearer` header, which *Discovery* now sends (validated on a lab, 5 of 5 checks passed).
- CSV cells starting with `=`, `+`, `-`, `@` are neutralised (formula injection).
