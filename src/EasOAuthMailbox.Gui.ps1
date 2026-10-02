<#
.SYNOPSIS
    EAS OAuth Mailbox - graphical interface (dot-sourced by EasOAuthMailbox.psm1).

.DESCRIPTION
    WinForms window with the palette of the HTML report and of the guide: page #F7F4EF, white
    cards with a #DEDEDE border, accent #B11F4B, small uppercase accent titles.
    It runs exactly the same engine as the command line (Invoke-EomMailboxTest, Export-EomReport):
    the progress box shows the same lines as the console, including the AD FS sign-in code.
    The window stays responsive while waiting for the sign-in, and the run can be cancelled.

    Layout: one TableLayoutPanel (header, target, scenario, actions, progress) so that the order
    on screen is the order of the rows - Dock=Top stacking reverses the order of addition.

    Closing and painting never run PowerShell code: the Close button closes natively (DialogResult),
    the card borders are panels, and the only FormClosing handler is attached while a test runs.
    A WinForms event handler written in PowerShell fails ("The pipeline has been stopped") once the
    command that opened the window is stopped (Ctrl+C in the console, stop button of an editor): the
    window must still close in that case. Ctrl+C is also ignored while the window is open.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.0.0
#>

$script:Gui = $null

function Get-EomGuiPalette {
    $c = { param([string]$Html) [Drawing.ColorTranslator]::FromHtml($Html) }
    @{
        Background = & $c '#F7F4EF'; Elevated = & $c '#FCFBF8'; Surface = [Drawing.Color]::White; Border = & $c '#DEDEDE'
        Text = & $c '#242424'; Muted = & $c '#5C5C5C'; Accent = & $c '#B11F4B'; AccentHover = & $c '#9A1A41'; AccentSoft = & $c '#FFDCE5'
        Success = & $c '#16A34A'; Danger = & $c '#DC2626'; Warning = & $c '#D97706'
    }
}

function New-EomGuiCard {
    <# White card with a border and a small uppercase accent title, like the blocks of the report. #>
    param([Parameter(Mandatory = $true)][string]$Title, [Parameter(Mandatory = $true)][hashtable]$Palette)

    $card = [Windows.Forms.Panel]::new()
    $card.Dock = 'Fill'
    # Border = 1-pixel padding of a border-coloured panel around a white panel (no Paint handler).
    $card.BackColor = $Palette.Border
    $card.Padding = [Windows.Forms.Padding]::new(1)
    $card.Margin = [Windows.Forms.Padding]::new(0, 0, 0, 12)
    $surface = [Windows.Forms.Panel]::new()
    $surface.Dock = 'Fill'
    $surface.BackColor = $Palette.Surface
    $surface.Padding = [Windows.Forms.Padding]::new(15, 11, 15, 11)
    $card.Controls.Add($surface)
    $inner = [Windows.Forms.TableLayoutPanel]::new()
    $inner.Dock = 'Fill'
    $inner.ColumnCount = 1
    $inner.RowCount = 2
    $inner.BackColor = $Palette.Surface
    [void]$inner.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    [void]$inner.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 24))
    [void]$inner.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    $label = [Windows.Forms.Label]::new()
    $label.Text = $Title.ToUpperInvariant()
    $label.Font = [Drawing.Font]::new('Segoe UI', 8.25, [Drawing.FontStyle]::Bold)
    $label.ForeColor = $Palette.Accent
    $label.Dock = 'Fill'
    $label.Margin = [Windows.Forms.Padding]::new(0)
    $inner.Controls.Add($label, 0, 0)
    $surface.Controls.Add($inner)
    [pscustomobject]@{ Card = $card; Body = $inner; Title = $label }
}

function New-EomGuiButton {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][hashtable]$Palette, [switch]$Primary, [int]$Width = 120)

    $button = [Windows.Forms.Button]::new()
    $button.Text = $Text
    $button.Width = $Width
    $button.Height = 34
    $button.FlatStyle = 'Flat'
    $button.Margin = [Windows.Forms.Padding]::new(0, 8, 10, 0)
    $button.Cursor = [Windows.Forms.Cursors]::Hand
    if ($Primary) { $button.Font = [Drawing.Font]::new('Segoe UI Semibold', 9.5) }
    $button.Tag = @{ Primary = [bool]$Primary }
    Set-EomGuiButton -Button $button -Enabled $true -Palette $Palette
    return $button
}

function Set-EomGuiButton {
    <# Enables or disables a button with its colours: flat buttons do not grey out by themselves. #>
    param([Parameter(Mandatory = $true)][Windows.Forms.Button]$Button, [Parameter(Mandatory = $true)][bool]$Enabled, [hashtable]$Palette = (Get-EomGuiPalette))

    $Button.Enabled = $Enabled
    if ($Button.Tag.Primary) {
        $Button.BackColor = if ($Enabled) { $Palette.Accent } else { $Palette.AccentSoft }
        $Button.ForeColor = if ($Enabled) { [Drawing.Color]::White } else { $Palette.Accent }
        $Button.FlatAppearance.BorderColor = if ($Enabled) { $Palette.AccentHover } else { $Palette.AccentSoft }
    }
    else {
        $Button.BackColor = if ($Enabled) { $Palette.Surface } else { $Palette.Elevated }
        $Button.ForeColor = if ($Enabled) { $Palette.Text } else { $Palette.Border }
        $Button.FlatAppearance.BorderColor = $Palette.Border
    }
}

function New-EomTestForm {
    <#
    .SYNOPSIS
        Builds the window (without showing it). Used by Show-EomTestGui, the tests and the documentation tool.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Configuration)

    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $p = Get-EomGuiPalette
    $catalog = @(Get-EomTestCatalog)
    $controls = @{}

    $form = [Windows.Forms.Form]::new()
    # Sizes below are written for 96 DPI; WinForms scales them to the screen (125 %, 150 %...) when
    # the layout resumes, like the fonts. Without it the text is cut on a high-DPI screen.
    $form.SuspendLayout()
    $form.AutoScaleDimensions = [Drawing.SizeF]::new(96, 96)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
    $form.Text = "EAS OAuth Mailbox $($script:ToolVersion)"
    $form.ClientSize = [Drawing.Size]::new(980, 840)
    $form.MinimumSize = [Drawing.Size]::new(900, 780)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $p.Background
    $form.ForeColor = $p.Text
    $form.Font = [Drawing.Font]::new('Segoe UI', 9.5)

    $layout = [Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock = 'Fill'
    $layout.ColumnCount = 1
    $layout.RowCount = 5
    $layout.Padding = [Windows.Forms.Padding]::new(20, 16, 20, 16)
    $layout.BackColor = $p.Background
    [void]$layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    foreach ($height in 108, 244, 170, 58) { [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, $height)) }
    [void]$layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    $form.Controls.Add($layout)

    # ---- Header (accent band, like the top border and primary tile of the report) ----------------
    $header = [Windows.Forms.Panel]::new()
    $header.Dock = 'Fill'
    $header.BackColor = $p.Accent
    $header.Margin = [Windows.Forms.Padding]::new(0, 0, 0, 12)
    $eyebrow = [Windows.Forms.Label]::new()
    $eyebrow.Text = 'EXCHANGE ACTIVESYNC  ' + [char]0x00B7 + '  OAUTH WITH AD FS'
    $eyebrow.Font = [Drawing.Font]::new('Segoe UI', 8.25, [Drawing.FontStyle]::Bold)
    $eyebrow.ForeColor = $p.AccentSoft
    $eyebrow.Location = [Drawing.Point]::new(22, 14)
    $eyebrow.AutoSize = $true
    $title = [Windows.Forms.Label]::new()
    $title.Text = 'EAS OAuth Mailbox'
    $title.Font = [Drawing.Font]::new('Segoe UI Semibold', 20)
    $title.ForeColor = [Drawing.Color]::White
    $title.Location = [Drawing.Point]::new(19, 32)
    $title.AutoSize = $true
    $subtitle = [Windows.Forms.Label]::new()
    $subtitle.Text = 'Choose a scenario, run it, open the report. Same checks and same report as the command line.'
    $subtitle.ForeColor = $p.AccentSoft
    $subtitle.Location = [Drawing.Point]::new(22, 74)
    $subtitle.AutoSize = $true
    $version = [Windows.Forms.Label]::new()
    $version.Text = "v$($script:ToolVersion)  " + [char]0x00B7 + '  Nicolas Fabert'
    $version.ForeColor = $p.AccentSoft
    $version.TextAlign = 'TopRight'
    $version.Dock = 'Right'
    $version.Width = 220
    $version.Padding = [Windows.Forms.Padding]::new(0, 16, 18, 0)
    $header.Controls.AddRange(@($version, $eyebrow, $title, $subtitle))
    $layout.Controls.Add($header, 0, 0)
    $controls.Header = $header

    # ---- Target --------------------------------------------------------------------------------
    $target = New-EomGuiCard -Title 'Target and authentication' -Palette $p
    $grid = [Windows.Forms.TableLayoutPanel]::new()
    $grid.Dock = 'Fill'
    $grid.ColumnCount = 2
    $grid.RowCount = 3
    $grid.BackColor = $p.Surface
    $grid.Margin = [Windows.Forms.Padding]::new(0)
    1..2 | ForEach-Object { [void]$grid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 50)) }
    1..3 | ForEach-Object { [void]$grid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Percent, 33.34)) }
    $fields = @(
        @('AdfsUrl', 'AD FS URL (ends with /adfs)', [string]$Configuration.AdfsUrl),
        @('EasUrl', 'ActiveSync URL', [string]$Configuration.EasUrl),
        @('Mailbox', 'Test mailbox (SMTP or UPN)', [string]$Configuration.Mailbox),
        @('ClientId', 'Client ID (AD FS)', [string]$Configuration.ClientId),
        @('DeviceId', 'Device ID (empty = derived from computer and mailbox)', [string]$Configuration.DeviceId),
        @('MessageCount', 'Inbox headers to read (1-100)', [string]$Configuration.MessageCount)
    )
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $cell = [Windows.Forms.TableLayoutPanel]::new()
        $cell.Dock = 'Fill'
        $cell.ColumnCount = 1
        $cell.RowCount = 2
        $cell.Margin = [Windows.Forms.Padding]::new(0, 0, 14, 0)
        [void]$cell.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 22))
        [void]$cell.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, 30))
        $label = [Windows.Forms.Label]::new()
        $label.Text = $fields[$i][1]
        $label.ForeColor = $p.Muted
        $label.Dock = 'Fill'
        $label.TextAlign = 'BottomLeft'
        $box = [Windows.Forms.TextBox]::new()
        $box.Text = $fields[$i][2]
        $box.Dock = 'Fill'
        $box.ForeColor = $p.Text
        $box.BackColor = $p.Surface
        $cell.Controls.Add($label, 0, 0)
        $cell.Controls.Add($box, 0, 1)
        $grid.Controls.Add($cell, $i % 2, [int][Math]::Floor($i / 2))
        $controls[$fields[$i][0]] = $box
    }
    $target.Body.Controls.Add($grid, 0, 1)
    $layout.Controls.Add($target.Card, 0, 1)
    $controls.Target = $target.Card

    # ---- Scenario ------------------------------------------------------------------------------
    $scenario = New-EomGuiCard -Title 'Diagnostic scenario' -Palette $p
    $sgrid = [Windows.Forms.TableLayoutPanel]::new()
    $sgrid.Dock = 'Fill'
    $sgrid.ColumnCount = 2
    $sgrid.RowCount = 3
    $sgrid.BackColor = $p.Surface
    $sgrid.Margin = [Windows.Forms.Padding]::new(0)
    [void]$sgrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 300))
    [void]$sgrid.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    foreach ($height in 50, 30, 26) { [void]$sgrid.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, $height)) }
    $combo = [Windows.Forms.ComboBox]::new()
    $combo.DropDownStyle = 'DropDownList'
    $combo.Dock = 'Fill'
    $combo.Margin = [Windows.Forms.Padding]::new(0, 6, 14, 0)
    $combo.Font = [Drawing.Font]::new('Segoe UI Semibold', 10)
    foreach ($s in $catalog) { [void]$combo.Items.Add($s.Name) }
    $description = [Windows.Forms.Label]::new()
    $description.Dock = 'Fill'
    $description.ForeColor = $p.Muted
    $description.TextAlign = 'MiddleLeft'
    $acknowledge = [Windows.Forms.CheckBox]::new()
    $acknowledge.Text = 'Authorise the acknowledgement of the ActiveSync policy (test mailbox only)'
    $acknowledge.Checked = [bool]$Configuration.AcknowledgePolicy
    $acknowledge.Dock = 'Fill'
    $acknowledge.ForeColor = $p.Text
    $warning = [Windows.Forms.Label]::new()
    $warning.Dock = 'Fill'
    $warning.TextAlign = 'MiddleLeft'
    $sgrid.Controls.Add($combo, 0, 0)
    $sgrid.Controls.Add($description, 1, 0)
    $sgrid.Controls.Add($acknowledge, 0, 1)
    $sgrid.SetColumnSpan($acknowledge, 2)
    $sgrid.Controls.Add($warning, 0, 2)
    $sgrid.SetColumnSpan($warning, 2)
    $scenario.Body.Controls.Add($sgrid, 0, 1)
    $layout.Controls.Add($scenario.Card, 0, 2)
    $controls.Scenario = $scenario.Card
    $controls.TestType = $combo
    $controls.Description = $description
    $controls.Acknowledge = $acknowledge
    $controls.Warning = $warning

    # ---- Actions -------------------------------------------------------------------------------
    $actions = [Windows.Forms.FlowLayoutPanel]::new()
    $actions.Dock = 'Fill'
    $actions.FlowDirection = 'LeftToRight'
    $actions.WrapContents = $false
    $actions.BackColor = $p.Background
    $actions.Margin = [Windows.Forms.Padding]::new(0)
    $controls.Run = New-EomGuiButton -Text 'Run the test' -Palette $p -Primary -Width 140
    $controls.Cancel = New-EomGuiButton -Text 'Cancel' -Palette $p -Width 100
    $controls.OpenReport = New-EomGuiButton -Text 'Open the report' -Palette $p -Width 140
    $controls.OpenFolder = New-EomGuiButton -Text 'Open the folder' -Palette $p -Width 130
    $controls.Close = New-EomGuiButton -Text 'Close' -Palette $p -Width 100
    foreach ($name in 'Cancel', 'OpenReport', 'OpenFolder') { Set-EomGuiButton -Button $controls[$name] -Enabled $false -Palette $p }
    # Native close: no PowerShell code runs when the window closes (Close button, Esc key, title bar X).
    $controls.Close.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $form.CancelButton = $controls.Close
    $status = [Windows.Forms.Label]::new()
    $status.AutoSize = $true
    $status.Margin = [Windows.Forms.Padding]::new(8, 16, 0, 0)
    $status.Font = [Drawing.Font]::new('Segoe UI Semibold', 10)
    $status.ForeColor = $p.Muted
    $status.Text = 'Ready.'
    $actions.Controls.AddRange(@($controls.Run, $controls.Cancel, $controls.OpenReport, $controls.OpenFolder, $controls.Close, $status))
    $layout.Controls.Add($actions, 0, 3)
    $controls.Actions = $actions
    $controls.Status = $status

    # ---- Progress ------------------------------------------------------------------------------
    $progress = New-EomGuiCard -Title 'Progress' -Palette $p
    $progress.Card.Margin = [Windows.Forms.Padding]::new(0)
    $log = [Windows.Forms.TextBox]::new()
    $log.Multiline = $true
    $log.ReadOnly = $true
    $log.ScrollBars = 'Vertical'
    $log.BorderStyle = 'None'
    $log.BackColor = $p.Elevated
    $log.ForeColor = $p.Text
    $log.Font = [Drawing.Font]::new('Consolas', 9.5)
    $log.Dock = 'Fill'
    $log.Text = "The lines of the console appear here during a run, including the AD FS sign-in code.`r`nThe report is written to: $($Configuration.OutputPath)"
    $progress.Body.Controls.Add($log, 0, 1)
    $layout.Controls.Add($progress.Card, 0, 4)
    $controls.Progress = $progress.Card
    $controls.Log = $log

    $script:Gui = @{
        Form = $form; Controls = $controls; Configuration = $Configuration.Clone(); Catalog = $catalog; Palette = $p
        Running = $false; LastReport = $null; LastFolder = $null
        # Attached to FormClosing only while a test runs: closing then cancels the run first.
        ClosingGuard = [Windows.Forms.FormClosingEventHandler] {
            param($sender, $e)
            $e.Cancel = $true
            if ($script:Ui) { $script:Ui.Cancel = $true }
            Add-EomGuiLine 'Warn' 'A test is running: it stops at the next check, then the window can be closed.'
        }
    }

    $combo.Add_SelectedIndexChanged({ Update-EomGuiScenario })
    $controls.Run.Add_Click({ Invoke-EomGuiRun })
    $controls.Cancel.Add_Click({
            if ($script:Ui) {
                $script:Ui.Cancel = $true
                Add-EomGuiLine 'Warn' 'Cancellation requested: the run stops at the next check.'
            }
        })
    $controls.OpenReport.Add_Click({ if ($script:Gui.LastReport) { Start-Process -FilePath $script:Gui.LastReport } })
    $controls.OpenFolder.Add_Click({ if ($script:Gui.LastFolder) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:Gui.LastFolder)`"" } })

    $form.ResumeLayout($true)
    # The scaled window must fit the screen where it opens (small laptop screen at 150 %).
    $area = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $form.MinimumSize = [Drawing.Size]::new([Math]::Min($form.MinimumSize.Width, $area.Width), [Math]::Min($form.MinimumSize.Height, $area.Height))
    $form.Size = [Drawing.Size]::new([Math]::Min($form.Width, $area.Width), [Math]::Min($form.Height, $area.Height))

    $selected = if ($catalog.Name -contains [string]$Configuration.TestType) { [string]$Configuration.TestType } else { 'Full' }
    $combo.SelectedItem = $selected
    Update-EomGuiScenario
    $form.ActiveControl = $combo
    [pscustomobject]@{ Form = $form; Controls = $controls }
}

function Update-EomGuiScenario {
    $g = $script:Gui
    $c = $g.Controls
    $s = $g.Catalog | Where-Object Name -eq ([string]$c.TestType.SelectedItem) | Select-Object -First 1
    if (-not $s) { return }
    $c.Description.Text = "$($s.DisplayName). $($s.Description)"
    $c.Acknowledge.Enabled = $s.CanProvision
    # AppleMail uses only the mailbox, like the iPhone: AD FS URL and Client ID are not used.
    $c.AdfsUrl.Enabled = $s.Client -ne 'AppleMail'
    $c.ClientId.Enabled = $s.Client -ne 'AppleMail'
    if ($s.Client -eq 'AppleMail') {
        $c.Warning.Text = "Like the iPhone, only the mailbox is needed: ActiveSync URL from Autodiscover (the one above only if Autodiscover fails), AD FS from Exchange, Apple Mail client $($g.Configuration['AppleClientId']). Creates an iPhone device: use a test mailbox."
        $c.Warning.ForeColor = $g.Palette.Warning
    }
    elseif ($s.ChangesServerState) {
        $c.Warning.Text = 'This scenario can create an ActiveSync device partnership for the DeviceId: use a test mailbox.'
        $c.Warning.ForeColor = $g.Palette.Warning
    }
    elseif (-not $s.SignIn) {
        $c.Warning.Text = 'No sign-in: only requests without credentials and a deliberately invalid token are sent.'
        $c.Warning.ForeColor = $g.Palette.Muted
    }
    else {
        $c.Warning.Text = 'Sign-in only: no ActiveSync device partnership is created.'
        $c.Warning.ForeColor = $g.Palette.Muted
    }
}

function Add-EomGuiLine {
    param([string]$Status, [string]$Text)

    if (-not $script:Gui) { return }
    $marks = @{ Step = [string][char]0x2500; Ok = [string][char]0x221A; Warn = [string][char]0x25B2; Fail = [string][char]0x00D7; Info = [string][char]0x2022; Skip = [string][char]0x00BB; Block = [string][char]0x25A0 }
    $mark = if ($marks.ContainsKey($Status)) { $marks[$Status] } else { '-' }
    $time = (Get-Date).ToString('HH:mm:ss')
    $line = if ($Status -eq 'Step') { "`r`n[$time] $mark$mark $Text" } else { "[$time]    $mark $Text" }
    $script:Gui.Controls.Log.AppendText($line + "`r`n")
    [Windows.Forms.Application]::DoEvents()
}

function Set-EomGuiStatus {
    param([string]$Text, [string]$Status)
    $g = $script:Gui
    $g.Controls.Status.Text = $Text
    $g.Controls.Status.ForeColor = switch ($Status) {
        'Passed' { $g.Palette.Success }
        'Failed' { $g.Palette.Danger }
        { $_ -in 'Warning', 'Blocked' } { $g.Palette.Warning }
        'Running' { $g.Palette.Accent }
        default { $g.Palette.Muted }
    }
}

function Invoke-EomGuiRun {
    $g = $script:Gui
    $c = $g.Controls
    $cfg = $g.Configuration.Clone()
    foreach ($key in 'AdfsUrl', 'EasUrl', 'Mailbox', 'ClientId', 'DeviceId') { $cfg[$key] = $c[$key].Text.Trim() }
    $count = 0
    $cfg.MessageCount = if ([int]::TryParse($c.MessageCount.Text.Trim(), [ref]$count)) { $count } else { -1 }
    $cfg.TestType = [string]$c.TestType.SelectedItem
    $cfg.AcknowledgePolicy = $c.Acknowledge.Enabled -and $c.Acknowledge.Checked

    $c.Log.Clear()
    $validation = Test-EomConfiguration -Configuration $cfg
    if (-not $validation.IsValid) {
        foreach ($problem in $validation.Problems) { Add-EomGuiLine 'Fail' $problem }
        Set-EomGuiStatus 'Fix the values above.' 'Failed'
        return
    }

    $script:Ui = @{
        Sink   = { param($Status, $Text) Add-EomGuiLine $Status $Text }
        Pump   = { [Windows.Forms.Application]::DoEvents() }
        Cancel = $false
    }
    try {
        $g.Running = $true
        $g.Form.add_FormClosing($g.ClosingGuard)
        foreach ($b in 'Run', 'OpenReport', 'OpenFolder', 'Close') { Set-EomGuiButton -Button $c[$b] -Enabled $false -Palette $g.Palette }
        Set-EomGuiButton -Button $c.Cancel -Enabled $true -Palette $g.Palette
        Set-EomGuiStatus "Running $($cfg.TestType)..." 'Running'
        Write-EomLog 'STEP' "GUI run: $($cfg.TestType) for $($cfg.Mailbox)"
        $result = Invoke-EomMailboxTest -Configuration $cfg -TestType $cfg.TestType
        $report = Export-EomReport -Result $result -OutputPath $cfg.OutputPath -Prefix $cfg.ReportPrefix -Formats $cfg.ReportFormats -Delimiter $cfg.CsvDelimiter
        $g.LastFolder = $report.Directory
        $g.LastReport = Get-EomField $report.Files 'Html'
        Add-EomGuiLine 'Info' "Report: $($report.Directory)"
        $n = $result.Counts
        Set-EomGuiStatus ("{0}  {1}  {2}/{3} checks passed" -f $result.Status, [char]0x00B7, $n.Passed, @($result.Steps).Count) $result.Status
    }
    catch {
        Add-EomGuiLine 'Fail' $_.Exception.Message
        Set-EomGuiStatus 'Failed - see the progress box.' 'Failed'
    }
    finally {
        $g.Form.remove_FormClosing($g.ClosingGuard)
        $script:Ui = $null
        $g.Running = $false
        foreach ($b in 'Run', 'Close') { Set-EomGuiButton -Button $c[$b] -Enabled $true -Palette $g.Palette }
        Set-EomGuiButton -Button $c.Cancel -Enabled $false -Palette $g.Palette
        Set-EomGuiButton -Button $c.OpenReport -Enabled ([bool]$g.LastReport) -Palette $g.Palette
        Set-EomGuiButton -Button $c.OpenFolder -Enabled ([bool]$g.LastFolder) -Palette $g.Palette
    }
}

function Show-EomTestGui {
    <#
    .SYNOPSIS
        Opens the window. Default configuration: config\EasOAuthMailbox.config.psd1 of the tool folder.
    #>
    [CmdletBinding()]
    param([hashtable]$Configuration)

    if (-not $Configuration) { $Configuration = Import-EomConfiguration }
    $window = New-EomTestForm -Configuration $Configuration
    # Ctrl+C in the console would stop the command that owns the window: the window then could not
    # run any of its PowerShell handlers. Ctrl+C is ignored while the window is open.
    $previousCtrlC = $null
    try { if (-not [Console]::IsInputRedirected) { $previousCtrlC = [Console]::TreatControlCAsInput; [Console]::TreatControlCAsInput = $true } } catch { $previousCtrlC = $null }
    try {
        [void]$window.Form.ShowDialog()
    }
    finally {
        if ($null -ne $previousCtrlC) { try { [Console]::TreatControlCAsInput = $previousCtrlC } catch { } }
        $window.Form.Dispose()
        $script:Gui = $null
    }
}
