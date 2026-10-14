# Mobile Device Client for Exchange

*Formerly EAS OAuth Mailbox (`EasOAuthMailbox`).*

A step-by-step diagnostic of Exchange ActiveSync with modern authentication through AD FS or Entra ID, on-premises or in Exchange Online.

This folder contains everything needed to run the tool: `Invoke-MobileDeviceClient.ps1`, the module, the configuration, the report template and the guides. Tests and build tools stay outside it, in the repository.

> [!IMPORTANT]
> Files downloaded from the Internet may be blocked by Windows. Unblock them once, from this folder:
>
> ```powershell
> Get-ChildItem . -Recurse -File | Unblock-File
> ```

## Requirements
- Windows 10 / 11 or Windows Server 2016 to 2025.
- PowerShell 7.4 or later.
- Microsoft Edge or Google Chrome for the sign-in window, or device code sign-in.
- HTTPS access to ActiveSync and to AD FS or `login.microsoftonline.com`.
- A test mailbox whose authentication policy allows the path tested.
- Exchange Server 2019 CU13 or later, Exchange Server SE, or Exchange Online.

## Quick start
```powershell
.\Invoke-MobileDeviceClient.ps1 -Gui

# Without signing in: certificates, OAuth challenge, and which sign-in Exchange offers this mailbox
.\Invoke-MobileDeviceClient.ps1 -TestType Discovery -Mailbox eas-test@contoso.com

# Complete test of a test mailbox, with each sign-in method
.\Invoke-MobileDeviceClient.ps1 -TestType Full -AcknowledgePolicy                          # OAuth - On-prem AD FS
.\Invoke-MobileDeviceClient.ps1 -TestType Full -Authority EntraID -AcknowledgePolicy       # OAuth - Entra ID, Exchange on-premises (HMA)
.\Invoke-MobileDeviceClient.ps1 -TestType Full -Authority EntraID -AcknowledgePolicy -EasUrl https://outlook.office365.com/Microsoft-Server-ActiveSync   # OAuth - Entra ID, Exchange Online
.\Invoke-MobileDeviceClient.ps1 -TestType Full -Authentication Basic -AcknowledgePolicy    # Basic - On-prem (the password is asked)

# Like an iPhone: only the address, the rest comes from Autodiscover and Exchange
.\Invoke-MobileDeviceClient.ps1 -TestType AppleMail -Mailbox eas-test@contoso.com -AcknowledgePolicy
```

## Content
| Item | Role |
|---|---|
| `Invoke-MobileDeviceClient.ps1` | Entry script. |
| `MobileDeviceClient.psd1` | Module manifest. |
| `MobileDeviceClient.psm1` | Module loader. |
| `config\` | Example configuration. |
| `docs\` | User and developer guides, Markdown and self-contained HTML, with images. |
| `src\` | Module implementation. |
| `templates\` | HTML report template. |
| `LICENSE` | MIT license. |
| `THIRD-PARTY-NOTICES.md` | Third-party notices. |

## Documentation
- [User guide](docs/MobileDeviceClient-UserGuide.md) - also `docs/MobileDeviceClient-UserGuide.html`, a single file to open locally
- [Developer guide](docs/MobileDeviceClient-Guide.md) - also `docs/MobileDeviceClient-Guide.html`

Project page, releases and change log: https://github.com/Nico77600/MobileDeviceClient

License: [MIT](LICENSE).

## Disclaimer

This Script is a Personal project.
It's provided "AS-IS". It's not an official Microsoft product so no support can be expected from Microsoft.

As any scripts you must read carefully the documentation and test it first in a Test environment before any run in Production.

Use a test mailbox: from `FolderSync` on, Exchange registers an ActiveSync device partnership.
