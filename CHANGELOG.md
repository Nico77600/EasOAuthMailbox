# Changelog — EAS OAuth Mailbox

All notable changes are listed here. Versions follow MAJOR.MINOR.PATCH (see the guide, Annex D).
Author: Nicolas Fabert.

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
