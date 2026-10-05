#
#  EAS OAuth Mailbox - configuration file
#  --------------------------------------------------------------------------
#  Author  : Nicolas Fabert
#  Version : 1.2.1
#
#  This file is read by Invoke-EasOAuthMailbox.ps1 and by the window (-Gui). It is a PowerShell
#  data file: text between quotes, $true / $false, numbers, and @( ) for lists.
#  Lines starting with # are comments. Relative paths are relative to the tool folder.
#  Every value is checked at start; all the problems are listed at once.
#
#  No secret here: the OAuth sign-in is interactive (sign-in window or device code) and the access
#  token stays in memory. With Basic authentication the password is asked at each run (prompt or window) and
#  is never written. Replace every contoso.test value before the first run.
#
@{
    # ---------------------------------------------------------------------
    # What is tested.
    # ---------------------------------------------------------------------
    # AppleMail needs only Mailbox, like an iPhone: AdfsUrl is not used, EasUrl only if Autodiscover fails.
    # Basic authentication uses neither AdfsUrl nor ClientId.
    #   Authority: where the OAuth sign-in happens.
    #     'ADFS'    AD FS at AdfsUrl (Exchange Server 2019 CU13+ / SE with AD FS)
    #     'EntraID' Entra ID, AdfsUrl not used: Exchange on-premises with hybrid modern authentication (HMA),
    #               or Exchange Online (EasUrl = https://outlook.office365.com/Microsoft-Server-ActiveSync)
    #     'Auto'    the server Exchange names in its challenge for the mailbox, like a client
    Target = @{
        AdfsUrl   = 'https://adfs.contoso.test/adfs'                         # AD FS root, ends with /adfs
        EasUrl    = 'https://mail.contoso.test/Microsoft-Server-ActiveSync'  # ActiveSync URL published to the devices
        Mailbox   = 'eas-test@contoso.test'                                  # a test mailbox (SMTP address or UPN)
        ClientId  = 'd3590ed6-52b3-4102-aeff-aad2292ab01c'                   # public client allowed for the EAS scope (AD FS, or Entra ID: Microsoft Office)
        BasicUser = ''                                                       # Basic only: user name, UPN or DOMAIN\user (empty = Mailbox)
        Authority = 'ADFS'                                                   # ADFS | EntraID | Auto
        TenantId  = ''                                                       # EntraID: tenant ID or domain (empty = domain of Mailbox)
    }

    # ---------------------------------------------------------------------
    # The ActiveSync "device" seen by Exchange (Get-MobileDevice -Mailbox <Mailbox>).
    # ---------------------------------------------------------------------
    Device = @{
        DeviceId   = ''                     # empty = stable value derived from the computer, the mailbox and DeviceType
        DeviceType = 'EasOAuthMailbox'      # letters and digits only (shown as DeviceType in Exchange)
        UserAgent  = 'EasOAuthMailbox/1.0'  # User-Agent header, visible in the IIS and HttpProxy logs
    }

    # ---------------------------------------------------------------------
    # How it is tested.
    #   DefaultType: Discovery | OAuth | Endpoint | FolderSync | Provisioning | Identity | InboxSync | Full | AppleMail
    #   Authentication: 'OAuth' (AD FS sign-in, access token) or 'Basic' (user name and password sent
    #   with every request, like a device without modern authentication). The OAuth scenario needs 'OAuth'.
    #   SignIn: how the OAuth sign-in happens. 'Window': a window (Microsoft Edge or Google Chrome, temporary
    #   profile) opens the page of AD FS or Entra ID, the password and the MFA are typed there. 'DeviceCode':
    #   a code typed on any device (a server without a browser). 'Auto': the window when this session can show one.
    #   AcknowledgePolicy: $true lets the tool acknowledge the ActiveSync policy when Exchange
    #   requires provisioning. Keep $false outside a test mailbox: without it the policy is only
    #   downloaded for review and the run stops as "Blocked".
    # ---------------------------------------------------------------------
    Test = @{
        DefaultType             = 'Full'
        Authentication          = 'OAuth'
        SignIn                  = 'Auto'    # Auto | Window | DeviceCode
        MessageCount            = 5       # Inbox headers read by InboxSync (1-100): date, sender, subject only
        AcknowledgePolicy       = $false
        OAuthPollTimeoutSeconds = 600     # longest wait for the sign-in in the browser
        HttpTimeoutSeconds      = 60      # timeout of every HTTP request
        CertificateWarningDays  = 30      # Discovery: warning when a certificate expires sooner
    }

    # ---------------------------------------------------------------------
    # Report files (one sub-folder per execution), written locally only.
    # ---------------------------------------------------------------------
    Report = @{
        OutputPath   = '.\reports'
        FilePrefix   = 'EasOAuthMailbox'
        Formats      = @('Csv', 'Html')   # a Summary.json file is always written as well
        CsvDelimiter = ';'                # ';' opens directly in Excel with French regional settings
    }

    # ---------------------------------------------------------------------
    # Execution log files (one per day, no token, no colour).
    # ---------------------------------------------------------------------
    Logging = @{
        Path          = '.\logs'
        RetentionDays = 14
    }

    # ---------------------------------------------------------------------
    # AppleMail scenario: the Mail app of an iPhone, as Exchange and AD FS see it.
    #   ClientId: native client application "iOS and macOS - Native mail application" of AD FS
    #   (identifier fixed by Microsoft). UserAgent and DeviceType: what an iPhone sends to
    #   ActiveSync. The device appears in Exchange with the friendly name
    #   "iPhone (EAS OAuth Mailbox <computer>)".
    # ---------------------------------------------------------------------
    AppleMail = @{
        ClientId   = 'f8d98a96-0999-43f5-8af3-69971c7bb423'
        UserAgent  = 'Apple-iPhone15C4/2401.539000006'
        DeviceType = 'iPhone'
    }
}
