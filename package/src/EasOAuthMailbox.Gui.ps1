<#
.SYNOPSIS
    EAS OAuth Mailbox - graphical interface (dot-sourced by EasOAuthMailbox.psm1).

.DESCRIPTION
    WPF window. With .NET 9 or later (PowerShell 7.5 and later) it uses the Fluent theme of Windows 11:
    light or dark like Windows, rounded controls, with the accent colour of the report (#B11F4B). With
    PowerShell 7.4 (.NET 8) the same window uses the classic WPF controls with the colours of the report.

    Layout: a header; on the left the sign-in method (three cards: OAuth - On-prem AD FS, OAuth - Entra
    ID for Exchange on-prem with HMA or Exchange Online, Basic - On-prem), the target and the scenario; on the right the progress, one line per
    check with its status icon, and the device code when one is used; at the bottom the actions.

    It runs exactly the same engine as the command line (Invoke-EomMailboxTest, Export-EomReport): the
    progress shows the lines of the console. The run happens on the window thread; the window is kept
    responsive while waiting for the sign-in (Invoke-EomUiPump), and the run can be cancelled.

    Closing never needs PowerShell code: Close is the cancel button of the window (Esc too) and the
    title-bar button is native; the only Closing handler is attached while a test runs. A PowerShell
    event handler fails ("The pipeline has been stopped") once the command that opened the window is
    stopped, so the window must close without one. Ctrl+C is ignored in the console while it is open.

.NOTES
    Author  : Nicolas Fabert
    Version : 1.2.1
#>

$script:Gui = $null
# The three ways a device signs in. Target.Authority Auto (the server Exchange names) stays a
# command-line option; in the window it shows as AD FS.
$script:GuiAuthentication = @(
    [pscustomobject]@{ Text = 'OAuth - On-prem AD FS'; Kind = 'OAuth'; Title = 'On-prem AD FS'; Detail = ''; Glyph = 0xE8D7; Authentication = 'OAuth'; Authority = 'ADFS'
        Hint = 'Exchange 2019 CU13+ or SE with AD FS: the user signs in on the AD FS page, Exchange receives an AD FS token.' }
    [pscustomobject]@{ Text = 'OAuth - Entra ID'; Kind = 'OAuth'; Title = 'Entra ID'; Detail = 'HMA or Exchange Online'; Glyph = 0xE753; Authentication = 'OAuth'; Authority = 'EntraID'
        Hint = 'Entra ID signs the user in (password, MFA, Conditional Access). The mailbox is on Exchange on-prem with hybrid modern authentication, or in Exchange Online (https://outlook.office365.com/Microsoft-Server-ActiveSync).' }
    [pscustomobject]@{ Text = 'Basic - On-prem'; Kind = 'Basic'; Title = 'On-prem'; Detail = ''; Glyph = 0xE77B; Authentication = 'Basic'; Authority = $null
        Hint = 'User name and password with every request, protected only by TLS: devices and mailboxes without modern authentication.' }
)
$script:GuiIconFont = 'Segoe Fluent Icons, Segoe MDL2 Assets'

function Get-EomGuiXaml {
    <# The window. Colours come from the Fluent theme resources (or the classic fallback of Set-EomGuiTheme). #>
    @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1180" Height="860" MinWidth="1000" MinHeight="640" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="EomCard" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource CardBackgroundFillColorDefaultBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardStrokeColorDefaultBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="18,14,18,16"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="EomCardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Foreground" Value="{DynamicResource TextFillColorPrimaryBrush}"/>
    </Style>
    <Style x:Key="EomLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource TextFillColorSecondaryBrush}"/>
      <Setter Property="Margin" Value="0,8,0,4"/>
    </Style>
    <Style x:Key="EomIcon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
    </Style>
    <Style x:Key="EomMethod" TargetType="ListBoxItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Card" Margin="0,0,8,0" Padding="12,10,10,10" CornerRadius="6" BorderThickness="2"
                    Background="{DynamicResource ControlFillColorDefaultBrush}" BorderBrush="{DynamicResource ControlStrokeColorDefaultBrush}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Card" Property="Background" Value="{DynamicResource ControlFillColorSecondaryBrush}"/>
              </Trigger>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Card" Property="BorderBrush" Value="{DynamicResource AccentFillColorDefaultBrush}"/>
                <Setter TargetName="Card" Property="Background" Value="{DynamicResource EomAccentSoft}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="Root" Background="{DynamicResource ApplicationBackgroundBrush}">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid x:Name="Header" Margin="24,18,24,14">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Border Width="46" Height="46" CornerRadius="10" Background="{DynamicResource EomBrand}" VerticalAlignment="Center">
        <TextBlock Style="{StaticResource EomIcon}" Text="&#xE715;" FontSize="22" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="EXCHANGE ACTIVESYNC DIAGNOSTIC" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource EomBrandText}"/>
        <TextBlock Text="EAS OAuth Mailbox" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
        <TextBlock FontSize="13" Foreground="{DynamicResource TextFillColorSecondaryBrush}" TextTrimming="CharacterEllipsis"
                   Text="Choose how the device signs in and a scenario, then run it: same checks and same report as the command line."/>
      </StackPanel>
      <TextBlock x:Name="Version" Grid.Column="2" FontSize="12" Foreground="{DynamicResource TextFillColorSecondaryBrush}" VerticalAlignment="Top"/>
    </Grid>

    <Grid Grid.Row="1" Margin="24,0,24,0">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="460"/>
        <ColumnDefinition Width="16"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <ScrollViewer x:Name="SettingsScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Padding="0,0,4,0">
        <StackPanel>
          <Border x:Name="Method" Style="{StaticResource EomCard}">
            <StackPanel>
              <TextBlock Text="Sign-in method" Style="{StaticResource EomCardTitle}"/>
              <ListBox x:Name="Authentication" ItemContainerStyle="{StaticResource EomMethod}" BorderThickness="0" Background="Transparent" Padding="0"
                       ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Disabled">
                <ListBox.ItemsPanel>
                  <ItemsPanelTemplate><UniformGrid Columns="3"/></ItemsPanelTemplate>
                </ListBox.ItemsPanel>
              </ListBox>
              <TextBlock x:Name="MethodHint" TextWrapping="Wrap" Margin="0,10,0,0" FontSize="12" Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
            </StackPanel>
          </Border>

          <Border x:Name="Target" Style="{StaticResource EomCard}">
            <StackPanel>
              <TextBlock Text="Target" Style="{StaticResource EomCardTitle}" Margin="0,0,0,2"/>
              <TextBlock Text="Test mailbox (SMTP or UPN)" Style="{StaticResource EomLabel}"/>
              <TextBox x:Name="Mailbox"/>
              <TextBlock Text="ActiveSync URL" Style="{StaticResource EomLabel}"/>
              <TextBox x:Name="EasUrl"/>
              <StackPanel x:Name="AdfsPanel">
                <TextBlock Text="AD FS URL (ends with /adfs)" Style="{StaticResource EomLabel}"/>
                <TextBox x:Name="AdfsUrl"/>
              </StackPanel>
              <Grid x:Name="BasicPanel">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="User name (empty = mailbox)" Style="{StaticResource EomLabel}"/>
                  <TextBox x:Name="BasicUser"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="Password (never written)" Style="{StaticResource EomLabel}"/>
                  <PasswordBox x:Name="BasicPassword"/>
                </StackPanel>
              </Grid>
              <Expander x:Name="Advanced" Header="Client and device" Margin="0,12,0,0">
                <StackPanel Margin="0,0,0,2">
                  <TextBlock x:Name="ClientIdLabel" Text="Client ID" Style="{StaticResource EomLabel}" Margin="0,0,0,4"/>
                  <TextBox x:Name="ClientId"/>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="2*"/>
                      <ColumnDefinition Width="12"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel>
                      <TextBlock Text="Device ID (empty = derived)" Style="{StaticResource EomLabel}"/>
                      <TextBox x:Name="DeviceId"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Text="Inbox headers (1-100)" Style="{StaticResource EomLabel}"/>
                      <TextBox x:Name="MessageCount"/>
                    </StackPanel>
                  </Grid>
                </StackPanel>
              </Expander>
            </StackPanel>
          </Border>

        </StackPanel>
      </ScrollViewer>

      <Grid Grid.Column="2">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <Border x:Name="Scenario" Style="{StaticResource EomCard}">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="230"/>
              <ColumnDefinition Width="16"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Text="Scenario" Style="{StaticResource EomCardTitle}" Grid.ColumnSpan="3"/>
            <ComboBox x:Name="TestType" Grid.Row="1" VerticalAlignment="Top"/>
            <TextBlock x:Name="Description" Grid.Row="1" Grid.Column="2" TextWrapping="Wrap" VerticalAlignment="Center" FontSize="12" Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
            <WrapPanel Grid.Row="2" Grid.ColumnSpan="3" Margin="0,10,0,0">
              <CheckBox x:Name="Acknowledge" Margin="0,0,24,0" Content="Acknowledge the ActiveSync policy (test mailbox only)"/>
              <CheckBox x:Name="DeviceCode" Content="Sign in with a device code (no sign-in window)"/>
            </WrapPanel>
            <Border x:Name="WarningBox" Grid.Row="3" Grid.ColumnSpan="3" Margin="0,10,0,0" Padding="12,8" CornerRadius="6" BorderThickness="1">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="Auto"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <TextBlock x:Name="WarningIcon" Style="{StaticResource EomIcon}" FontSize="16" Margin="0,1,10,0" VerticalAlignment="Top"/>
                <TextBlock x:Name="Warning" Grid.Column="1" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
              </Grid>
            </Border>
          </Grid>
        </Border>
        <Border x:Name="Progress" Grid.Row="1" Style="{StaticResource EomCard}">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock Text="Progress" Style="{StaticResource EomCardTitle}"/>
            <Border x:Name="StatusPill" Grid.Column="1" CornerRadius="10" Padding="10,2" VerticalAlignment="Top">
              <TextBlock x:Name="Status" FontSize="12" FontWeight="SemiBold"/>
            </Border>
          </Grid>
          <Border x:Name="CodeBanner" Grid.Row="1" Visibility="Collapsed" Margin="0,0,0,12" Padding="14,10" CornerRadius="6" BorderThickness="1"
                  Background="{DynamicResource EomAccentSoft}" BorderBrush="{DynamicResource AccentFillColorDefaultBrush}">
            <Grid>
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
              </Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Device code: type it on the sign-in page, from any device" FontSize="12" Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
                <TextBlock x:Name="CodeText" FontSize="26" FontWeight="SemiBold" FontFamily="Cascadia Mono, Consolas" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
                <TextBlock x:Name="CodePage" FontSize="12" Foreground="{DynamicResource AccentTextFillColorPrimaryBrush}"/>
              </StackPanel>
              <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
                <Button x:Name="CopyCode" Content="Copy the code" Margin="0,0,8,0"/>
                <Button x:Name="OpenPage" Content="Open the page"/>
              </StackPanel>
            </Grid>
          </Border>
          <TextBlock x:Name="LogEmpty" Grid.Row="2" FontSize="13" Foreground="{DynamicResource TextFillColorTertiaryBrush}" Text="The checks appear here as they run, with the sign-in code when a device code is used."/>
          <ScrollViewer x:Name="LogScroll" Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <ItemsControl x:Name="Log" Margin="0,0,12,0">
              <ItemsControl.ItemTemplate>
                <DataTemplate>
                  <Grid Margin="{Binding Margin}">
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="22"/>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Text="{Binding Glyph}" Foreground="{Binding Brush}" FontFamily="Segoe Fluent Icons, Segoe MDL2 Assets" FontSize="13" Margin="0,3,0,0" VerticalAlignment="Top"/>
                    <TextBlock Grid.Column="1" Text="{Binding Text}" TextWrapping="Wrap" FontSize="{Binding Size}" FontWeight="{Binding Weight}" Foreground="{Binding TextBrush}"/>
                    <TextBlock Grid.Column="2" Text="{Binding Time}" FontSize="11" Margin="10,2,0,0" Foreground="{DynamicResource TextFillColorTertiaryBrush}"/>
                  </Grid>
                </DataTemplate>
              </ItemsControl.ItemTemplate>
            </ItemsControl>
          </ScrollViewer>
        </Grid>
      </Border>
      </Grid>
    </Grid>

    <Border x:Name="Actions" Grid.Row="2" Padding="24,12" BorderThickness="0,1,0,0"
            BorderBrush="{DynamicResource DividerStrokeColorDefaultBrush}" Background="{DynamicResource LayerFillColorDefaultBrush}">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal">
          <Button x:Name="Run" MinWidth="150" Padding="16,6" Margin="0,0,8,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Style="{StaticResource EomIcon}" Text="&#xE768;" Margin="0,2,8,0"/>
              <TextBlock Text="Run the test"/>
            </StackPanel>
          </Button>
          <Button x:Name="Cancel" Content="Cancel" MinWidth="96" IsEnabled="False"/>
        </StackPanel>
        <TextBlock x:Name="Footer" Grid.Column="1" Margin="16,0" VerticalAlignment="Center" TextTrimming="CharacterEllipsis" FontSize="12"
                   Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <Button x:Name="OpenReport" Content="Open the report" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="OpenFolder" Content="Open the folder" Margin="0,0,8,0" IsEnabled="False"/>
          <Button x:Name="Close" Content="Close" MinWidth="96" IsCancel="True"/>
        </StackPanel>
      </Grid>
    </Border>
  </Grid>
</Window>
'@
}

function New-EomGuiBrush {
    param([Parameter(Mandatory = $true)][string]$Color)
    $brush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($Color))
    $brush.Freeze()
    return $brush
}

function Initialize-EomGuiTheme {
    <#
        Loads WPF and applies the theme to the application: Fluent (.NET 9+), light or dark as Windows
        (System), or Light / Dark for the documentation images. Returns Fluent and Dark.
    #>
    param([ValidateSet('System', 'Light', 'Dark')][string]$Theme = 'System')

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $dark = $Theme -eq 'Dark'
    if ($Theme -eq 'System') { $dark = Test-EomGuiDarkMode }
    # One application per process: created once, never shut down by a closed window.
    $app = [Windows.Application]::Current
    if (-not $app) {
        $app = [Windows.Application]::new()
        $app.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown
    }
    $fluent = $null -ne [Windows.Application].GetProperty('ThemeMode')
    if ($fluent) {
        # ThemeMode is the Fluent theme of WPF (.NET 9 and later); its name is experimental in .NET 9.
        # Light or Dark, never System: without the setting (Windows Server 2016) WPF would pick dark and the
        # colours of the window (light) would not match.
        $app.ThemeMode = [Windows.ThemeMode]::new($(if ($dark) { 'Dark' } else { 'Light' }))
    }
    [pscustomobject]@{ Fluent = $fluent; Dark = $dark; Application = $app }
}

function Test-EomGuiDarkMode {
    <# Windows shows the applications in dark mode (AppsUseLightTheme = 0); light when the setting is missing. #>
    $personalize = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    return [string](Get-EomField $personalize 'AppsUseLightTheme') -eq '0'
}

function Set-EomGuiTheme {
    <#
        Colours of the window: the accent of the report on the Fluent accent resources, the status colours,
        and with the classic theme (.NET 8) the Fluent resources the window uses, with the report palette.
    #>
    param([Parameter(Mandatory = $true)][Windows.Window]$Window, [Parameter(Mandatory = $true)][pscustomobject]$Theme)

    $dark = $Theme.Dark
    $r = $Window.Resources
    $set = { param([string[]]$Keys, [string]$LightColor, [string]$DarkColor) $b = New-EomGuiBrush $(if ($dark) { $DarkColor } else { $LightColor }); foreach ($k in $Keys) { $r[$k] = $b } }
    if (-not $Theme.Fluent) {
        & $set 'ApplicationBackgroundBrush' '#F7F4EF' '#202020'
        & $set 'CardBackgroundFillColorDefaultBrush' '#FFFFFF' '#2B2B2B'
        & $set 'CardStrokeColorDefaultBrush', 'ControlStrokeColorDefaultBrush' '#DEDEDE' '#3D3D3D'
        & $set 'ControlFillColorDefaultBrush' '#FFFFFF' '#2D2D2D'
        & $set 'ControlFillColorSecondaryBrush' '#F5F5F5' '#323232'
        & $set 'DividerStrokeColorDefaultBrush' '#DEDEDE' '#3D3D3D'
        & $set 'LayerFillColorDefaultBrush' '#FCFBF8' '#262626'
        & $set 'TextFillColorPrimaryBrush' '#242424' '#FFFFFF'
        & $set 'TextFillColorSecondaryBrush' '#5C5C5C' '#C5C5C5'
        & $set 'TextFillColorTertiaryBrush' '#8A8A8A' '#9A9A9A'
    }
    # The accent of the report instead of the accent colour of Windows.
    & $set 'AccentFillColorDefaultBrush', 'AccentButtonBackground', 'AccentButtonBorderBrush' '#B11F4B' '#FD8EA1'
    & $set 'AccentFillColorSecondaryBrush', 'AccentButtonBackgroundPointerOver' '#E6B11F4B' '#E6FD8EA1'
    & $set 'AccentFillColorTertiaryBrush', 'AccentButtonBackgroundPressed' '#CCB11F4B' '#CCFD8EA1'
    & $set 'AccentTextFillColorPrimaryBrush' '#9A1A41' '#FD8EA1'
    & $set 'EomBrand' '#B11F4B' '#B11F4B'
    & $set 'EomBrandText' '#B11F4B' '#FD8EA1'
    & $set 'EomAccentSoft' '#14B11F4B' '#33FD8EA1'
    & $set 'EomSuccess' '#16A34A' '#4ADE80'
    & $set 'EomCaution' '#D97706' '#FBBF24'
    & $set 'EomCritical' '#DC2626' '#F87171'
    & $set 'EomInfoBackground' '#F3F3F3' '#2E2E2E'
    & $set 'EomInfoBorder' '#E0E0E0' '#3D3D3D'
    & $set 'EomCautionBackground' '#FFF7E8' '#33FBBF24'
    & $set 'EomCautionBorder' '#F5D7A1' '#66FBBF24'
    & $set 'EomCriticalBackground' '#FDECEC' '#33F87171'
    & $set 'EomCriticalBorder' '#F4B4B4' '#66F87171'
    & $set 'EomSuccessBackground' '#EAF7EE' '#334ADE80'
}

function Invoke-EomGuiPump {
    <# Lets the window repaint and handle clicks during a run (the WPF equivalent of DoEvents). #>
    $frame = [Windows.Threading.DispatcherFrame]::new()
    [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,
        [Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; $null }, $frame)
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function New-EomGuiMethodCard {
    <# Content of one sign-in method card: icon, kind (OAuth, Basic), name. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Method)

    $panel = [Windows.Controls.StackPanel]::new()
    $icon = [Windows.Controls.TextBlock]::new()
    $icon.Text = [string][char]$Method.Glyph
    $icon.FontFamily = [Windows.Media.FontFamily]::new($script:GuiIconFont)
    $icon.FontSize = 18
    $icon.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
    $icon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'EomBrandText')
    $kind = [Windows.Controls.TextBlock]::new()
    $kind.Text = $Method.Kind
    $kind.FontSize = 11
    $kind.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextFillColorSecondaryBrush')
    $name = [Windows.Controls.TextBlock]::new()
    $name.Text = $Method.Title
    $name.FontSize = 13
    $name.FontWeight = [Windows.FontWeights]::SemiBold
    $name.TextWrapping = [Windows.TextWrapping]::Wrap
    $name.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextFillColorPrimaryBrush')
    foreach ($part in $icon, $kind, $name) { [void]$panel.Children.Add($part) }
    if ($Method.Detail) {
        $detail = [Windows.Controls.TextBlock]::new()
        $detail.Text = $Method.Detail
        $detail.FontSize = 11
        $detail.Margin = [Windows.Thickness]::new(0, 2, 0, 0)
        $detail.TextWrapping = [Windows.TextWrapping]::Wrap
        $detail.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'TextFillColorSecondaryBrush')
        [void]$panel.Children.Add($detail)
    }
    $item = [Windows.Controls.ListBoxItem]::new()
    $item.Content = $panel
    $item.ToolTip = $Method.Text
    return $item
}

function New-EomTestForm {
    <#
    .SYNOPSIS
        Builds the window (without showing it). Used by Show-EomTestGui, the tests and the documentation tool.
    .PARAMETER Theme
        System (like Windows), Light or Dark (documentation images, tests).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Configuration, [ValidateSet('System', 'Light', 'Dark')][string]$Theme = 'System')

    $look = Initialize-EomGuiTheme -Theme $Theme
    $catalog = @(Get-EomTestCatalog)
    $window = [Windows.Markup.XamlReader]::Parse((Get-EomGuiXaml))
    $window.Title = "EAS OAuth Mailbox $($script:ToolVersion)"
    Set-EomGuiTheme -Window $window -Theme $look
    $controls = @{}
    foreach ($name in 'Root', 'Header', 'Version', 'Method', 'Authentication', 'MethodHint', 'Target', 'Mailbox', 'EasUrl', 'AdfsPanel', 'AdfsUrl', 'BasicPanel', 'BasicUser',
        'BasicPassword', 'Advanced', 'ClientIdLabel', 'ClientId', 'DeviceId', 'MessageCount', 'Scenario', 'TestType', 'Description', 'Acknowledge', 'DeviceCode', 'WarningBox',
        'WarningIcon', 'Warning', 'Progress', 'StatusPill', 'Status', 'CodeBanner', 'CodeText', 'CodePage', 'CopyCode', 'OpenPage', 'LogScroll', 'Log', 'Actions', 'Run',
        'Cancel', 'Footer', 'OpenReport', 'OpenFolder', 'Close', 'SettingsScroll', 'LogEmpty') {
        $controls[$name] = $window.FindName($name)
    }
    if ($look.Fluent) { $controls.Run.SetResourceReference([Windows.FrameworkElement]::StyleProperty, 'AccentButtonStyle') }
    else {
        $controls.Run.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, 'AccentFillColorDefaultBrush')
        $controls.Run.Foreground = [Windows.Media.Brushes]::White
    }
    $controls.Version.Text = "v$($script:ToolVersion)  " + [char]0x00B7 + '  Nicolas Fabert'
    foreach ($method in $script:GuiAuthentication) { [void]$controls.Authentication.Items.Add((New-EomGuiMethodCard -Method $method)) }
    $current = if ([string]$Configuration.Authentication -eq 'Basic') { 'Basic' } else { [string]$Configuration.Authority }
    $index = [Array]::FindIndex([object[]]$script:GuiAuthentication, [Predicate[object]] { param($x) ($x.Authentication -eq 'Basic' -and $current -eq 'Basic') -or $x.Authority -eq $current })
    $controls.Authentication.SelectedIndex = [Math]::Max(0, $index)
    foreach ($key in 'AdfsUrl', 'EasUrl', 'Mailbox', 'ClientId', 'DeviceId', 'MessageCount', 'BasicUser') { $controls[$key].Text = [string]$Configuration[$key] }
    foreach ($s in $catalog) { [void]$controls.TestType.Items.Add($s.Name) }
    $controls.Acknowledge.IsChecked = [bool]$Configuration.AcknowledgePolicy
    $controls.DeviceCode.IsChecked = [string]$Configuration.SignIn -eq 'DeviceCode'

    $items = [Collections.ObjectModel.ObservableCollection[object]]::new()
    $controls.Log.ItemsSource = $items
    $script:Gui = @{
        Form = $window; Controls = $controls; Configuration = $Configuration.Clone(); Catalog = $catalog; Theme = $look
        Running = $false; LastReport = $null; LastFolder = $null
        # The progress: the items shown and the same lines as text (tests, copy).
        Items = $items; Lines = [Collections.Generic.List[string]]::new(); CodePage = $null
        # Attached to Closing only while a test runs: closing then cancels the run first.
        ClosingGuard = [ComponentModel.CancelEventHandler] {
            param($sender, $e)
            $e.Cancel = $true
            if ($script:Ui) { $script:Ui.Cancel = $true }
            Add-EomGuiLine 'Warn' 'A test is running: it stops at the next check, then the window can be closed.'
        }
    }
    Set-EomGuiStatus 'Ready' 'Ready'
    $controls.Footer.Text = "Reports: $($Configuration.OutputPath)"

    $controls.TestType.Add_SelectionChanged({ Update-EomGuiScenario })
    $controls.Authentication.Add_SelectionChanged({ Update-EomGuiScenario })
    $controls.DeviceCode.Add_Click({ Update-EomGuiScenario })
    # The notice of Entra ID names Exchange Online or on-prem from the ActiveSync URL.
    $controls.EasUrl.Add_LostFocus({ Update-EomGuiScenario })
    $controls.Run.Add_Click({ Invoke-EomGuiRun })
    $controls.Cancel.Add_Click({
            if ($script:Ui) {
                $script:Ui.Cancel = $true
                Add-EomGuiLine 'Warn' 'Cancellation requested: the run stops at the next check.'
            }
        })
    $controls.OpenReport.Add_Click({ if ($script:Gui.LastReport) { Start-Process -FilePath $script:Gui.LastReport } })
    $controls.OpenFolder.Add_Click({ if ($script:Gui.LastFolder) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($script:Gui.LastFolder)`"" } })
    $controls.CopyCode.Add_Click({ [Windows.Clipboard]::SetText([string]$script:Gui.Controls.CodeText.Text) })
    $controls.OpenPage.Add_Click({ if ($script:Gui.CodePage) { Start-Process -FilePath $script:Gui.CodePage } })

    # The window fits the screen where it opens (small laptop screen at 150 %); the left column scrolls.
    $area = [Windows.SystemParameters]::WorkArea
    $window.Width = [Math]::Min($window.Width, $area.Width)
    $window.Height = [Math]::Min($window.Height, $area.Height)
    $window.MinWidth = [Math]::Min($window.MinWidth, $area.Width)
    $window.MinHeight = [Math]::Min($window.MinHeight, $area.Height)

    $controls.TestType.SelectedItem = if ($catalog.Name -contains [string]$Configuration.TestType) { [string]$Configuration.TestType } else { 'Full' }
    Update-EomGuiScenario
    [pscustomobject]@{ Form = $window; Controls = $controls; Lines = $script:Gui.Lines; Items = $items }
}

function Set-EomGuiNotice {
    <# The coloured box under the scenario: Info, Caution or Critical. #>
    param([Parameter(Mandatory = $true)][string]$Text, [ValidateSet('Info', 'Caution', 'Critical')][string]$Level = 'Info')

    $c = $script:Gui.Controls
    $c.Warning.Text = $Text
    $c.WarningIcon.Text = [string][char]$(switch ($Level) { 'Caution' { 0xE7BA } 'Critical' { 0xEA39 } default { 0xE946 } })
    $c.WarningIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(switch ($Level) { 'Caution' { 'EomCaution' } 'Critical' { 'EomCritical' } default { 'TextFillColorSecondaryBrush' } }))
    $c.WarningBox.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $(switch ($Level) { 'Caution' { 'EomCautionBackground' } 'Critical' { 'EomCriticalBackground' } default { 'EomInfoBackground' } }))
    $c.WarningBox.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, $(switch ($Level) { 'Caution' { 'EomCautionBorder' } 'Critical' { 'EomCriticalBorder' } default { 'EomInfoBorder' } }))
}

function Update-EomGuiScenario {
    $g = $script:Gui
    if (-not $g) { return }
    $c = $g.Controls
    $s = $g.Catalog | Where-Object Name -eq ([string]$c.TestType.SelectedItem) | Select-Object -First 1
    if (-not $s) { return }
    $c.Description.Text = "$($s.DisplayName). $($s.Description)"
    $c.Acknowledge.IsEnabled = $s.CanProvision
    $choice = $script:GuiAuthentication[[Math]::Max(0, $c.Authentication.SelectedIndex)]
    $basic = $choice.Authentication -eq 'Basic'
    $apple = $s.Client -eq 'AppleMail'
    $c.MethodHint.Text = $choice.Hint
    # AppleMail uses only the mailbox, like the iPhone; Basic never contacts AD FS; Entra ID does not use
    # the AD FS URL. The Basic fields are used only by a scenario that signs in.
    $adfs = -not $apple -and $choice.Authority -eq 'ADFS'
    $c.AdfsUrl.IsEnabled = $adfs
    $c.AdfsPanel.Visibility = if ($adfs) { 'Visible' } else { 'Collapsed' }
    $c.ClientId.IsEnabled = -not $apple -and -not $basic
    $c.ClientIdLabel.Text = if ($basic) { 'Client ID (not used by Basic)' } elseif ($apple) { "Client ID (AppleMail uses $($g.Configuration['AppleClientId']))" } elseif ($choice.Authority -eq 'EntraID') { 'Client ID (Microsoft Office by default)' } else { 'Client ID (AD FS native client)' }
    $c.BasicUser.IsEnabled = $basic -and $s.SignIn
    $c.BasicPassword.IsEnabled = $basic -and $s.SignIn
    $c.BasicPanel.Visibility = if ($basic) { 'Visible' } else { 'Collapsed' }
    $c.DeviceCode.IsEnabled = -not $basic -and $s.SignIn
    $how = if ($c.DeviceCode.IsChecked) { 'sign-in with a code typed on any device' } else { 'sign-in in a window (password, MFA)' }
    $partnership = if ($s.ChangesServerState) { ' Creates an ActiveSync device partnership: use a test mailbox.' } else { '' }
    if ($basic -and $s.Name -eq 'OAuth') {
        Set-EomGuiNotice 'The OAuth scenario tests the AD FS sign-in: choose OAuth, or Endpoint to check the user name and password.' Critical
    }
    elseif ($basic -and $apple) {
        Set-EomGuiNotice "iPhone with a password (Basic): ActiveSync URL from Autodiscover, checks that Exchange does not offer OAuth to the mailbox, then Basic as an iPhone.$partnership" Caution
    }
    elseif ($basic) {
        $text = if ($s.SignIn) { "Basic: the user name and password go with every request (TLS only); AD FS is not used.$partnership" } else { 'Basic, no sign-in: Basic offered, OAuth offered to the mailbox, wrong password refused (with a user that does not exist).' }
        Set-EomGuiNotice $text $(if ($partnership) { 'Caution' } else { 'Info' })
    }
    elseif ($apple) {
        Set-EomGuiNotice "Like the iPhone, only the mailbox is needed: ActiveSync URL from Autodiscover (the one above only if Autodiscover fails), AD FS or Entra ID from Exchange, Apple Mail client $($g.Configuration['AppleClientId']). Creates an iPhone device: use a test mailbox." Caution
    }
    elseif ($choice.Authority -eq 'EntraID' -and $s.SignIn) {
        $tenant = if ($g.Configuration['TenantId']) { "tenant $($g.Configuration['TenantId'])" } else { 'tenant found from the domain of the mailbox' }
        $where = if (Test-EomExchangeOnlineUrl -Url ([string]$c.EasUrl.Text)) { 'Exchange Online' } else { 'Exchange on-prem with hybrid modern authentication' }
        Set-EomGuiNotice "Entra ID ($where): $tenant, $how.$partnership" $(if ($partnership) { 'Caution' } else { 'Info' })
    }
    elseif ($s.ChangesServerState) {
        Set-EomGuiNotice "This scenario creates an ActiveSync device partnership for the device ID: use a test mailbox. AD FS, $how." Caution
    }
    elseif (-not $s.SignIn) {
        Set-EomGuiNotice 'No sign-in: only requests without credentials and a deliberately invalid token are sent.'
    }
    else {
        Set-EomGuiNotice "Sign-in only, $($how): no ActiveSync device partnership is created."
    }
}

function Add-EomGuiLine {
    <# One line of the progress: icon and colour of its status; a device code also shows in its own box. #>
    param([string]$Status, [string]$Text)

    $g = $script:Gui
    if (-not $g) { return }
    $glyphs = @{ Step = 0xE76C; Ok = 0xE73E; Warn = 0xE7BA; Fail = 0xEA39; Info = 0xE946; Skip = 0xE72A; Block = 0xE733 }
    $colours = @{ Step = 'EomBrandText'; Ok = 'EomSuccess'; Warn = 'EomCaution'; Fail = 'EomCritical'; Info = 'TextFillColorSecondaryBrush'; Skip = 'TextFillColorTertiaryBrush'; Block = 'EomCaution' }
    $key = if ($glyphs.ContainsKey($Status)) { $Status } else { 'Info' }
    $step = $Status -eq 'Step'
    $shown = if ($step) { $Text -replace '^\[(\d+/\d+)\]\s*', '$1   ' } else { $Text }
    $window = $g.Form
    $g.Items.Add([pscustomobject]@{
            Glyph     = [string][char]$glyphs[$key]
            Brush     = $window.TryFindResource($colours[$key])
            Text      = $shown
            TextBrush = $window.TryFindResource($(if ($key -in 'Info', 'Skip') { 'TextFillColorSecondaryBrush' } else { 'TextFillColorPrimaryBrush' }))
            Weight    = if ($step) { [Windows.FontWeights]::SemiBold } else { [Windows.FontWeights]::Normal }
            Size      = if ($step) { 14 } else { 13 }
            Margin    = if ($step) { [Windows.Thickness]::new(0, $(if ($g.Items.Count) { 12 } else { 0 }), 0, 4) } else { [Windows.Thickness]::new(0, 2, 0, 2) }
            Time      = (Get-Date).ToString('HH:mm:ss')
        })
    $g.Lines.Add("[$Status] $Text")
    # The device code: big, with Copy and Open buttons (the console line is "Code: XXXX  -  page: URL").
    $code = [regex]::Match($Text, '^Code:\s*(\S+)\s+-\s+page:\s*(\S+)')
    if ($code.Success) {
        $g.Controls.CodeText.Text = $code.Groups[1].Value
        $g.Controls.CodePage.Text = $code.Groups[2].Value
        $g.CodePage = $code.Groups[2].Value
        $g.Controls.CodeBanner.Visibility = 'Visible'
    }
    $g.Controls.LogEmpty.Visibility = 'Collapsed'
    $g.Controls.LogScroll.ScrollToEnd()
    Invoke-EomGuiPump
}

function Clear-EomGuiProgress {
    $g = $script:Gui
    $g.Items.Clear()
    $g.Lines.Clear()
    $g.CodePage = $null
    $g.Controls.CodeBanner.Visibility = 'Collapsed'
    $g.Controls.LogEmpty.Visibility = 'Visible'
}

function Set-EomGuiStatus {
    <# The status pill of the progress: Ready, Running, Passed, Warning, Blocked or Failed. #>
    param([string]$Text, [string]$Status)

    $c = $script:Gui.Controls
    $c.Status.Text = $Text
    $pair = switch ($Status) {
        'Passed' { 'EomSuccess', 'EomSuccessBackground' }
        'Failed' { 'EomCritical', 'EomCriticalBackground' }
        { $_ -in 'Warning', 'Blocked' } { 'EomCaution', 'EomCautionBackground' }
        'Running' { 'EomBrandText', 'EomAccentSoft' }
        default { 'TextFillColorSecondaryBrush', 'EomInfoBackground' }
    }
    $c.Status.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $pair[0])
    $c.StatusPill.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $pair[1])
}

function Invoke-EomGuiRun {
    $g = $script:Gui
    $c = $g.Controls
    $cfg = $g.Configuration.Clone()
    foreach ($key in 'AdfsUrl', 'EasUrl', 'Mailbox', 'ClientId', 'DeviceId', 'BasicUser') { $cfg[$key] = $c[$key].Text.Trim() }
    $count = 0
    $cfg.MessageCount = if ([int]::TryParse($c.MessageCount.Text.Trim(), [ref]$count)) { $count } else { -1 }
    $cfg.TestType = [string]$c.TestType.SelectedItem
    $choice = $script:GuiAuthentication[[Math]::Max(0, $c.Authentication.SelectedIndex)]
    $cfg.Authentication = $choice.Authentication
    if ($choice.Authority) { $cfg.Authority = $choice.Authority }
    $cfg.AcknowledgePolicy = $c.Acknowledge.IsEnabled -and [bool]$c.Acknowledge.IsChecked
    if ($c.DeviceCode.IsChecked) { $cfg.SignIn = 'DeviceCode' } elseif ([string]$cfg.SignIn -eq 'DeviceCode') { $cfg.SignIn = 'Auto' }

    Clear-EomGuiProgress
    $problems = @((Test-EomConfiguration -Configuration $cfg).Problems)
    # Basic: the password of the box, for this run only (never written, never kept in the settings).
    $credential = $null
    if ($cfg.Authentication -eq 'Basic' -and $c.BasicPassword.IsEnabled) {
        if ($c.BasicPassword.SecurePassword.Length -eq 0) { $problems += 'Enter the password (Basic).' }
        else {
            $user = if ($cfg.BasicUser) { $cfg.BasicUser } else { [string]$cfg.Mailbox }
            $credential = [pscredential]::new($user, $c.BasicPassword.SecurePassword.Copy())
        }
    }
    if ($problems.Count) {
        foreach ($problem in $problems) { Add-EomGuiLine 'Fail' $problem }
        Set-EomGuiStatus 'Fix the values above.' 'Failed'
        return
    }

    $script:Ui = @{
        Sink   = { param($Status, $Text) Add-EomGuiLine $Status $Text }
        Pump   = { Invoke-EomGuiPump }
        Cancel = $false
    }
    try {
        $g.Running = $true
        $g.Form.add_Closing($g.ClosingGuard)
        foreach ($b in 'Run', 'OpenReport', 'OpenFolder', 'Close') { $c[$b].IsEnabled = $false }
        $c.Cancel.IsEnabled = $true
        Set-EomGuiStatus "Running $($cfg.TestType)..." 'Running'
        $c.Footer.Text = "$($choice.Text)  " + [char]0x00B7 + "  $($cfg.Mailbox)"
        Write-EomLog 'STEP' "GUI run: $($cfg.TestType) ($($cfg.Authentication)) for $($cfg.Mailbox)"
        $result = Invoke-EomMailboxTest -Configuration $cfg -TestType $cfg.TestType -Credential $credential
        $report = Export-EomReport -Result $result -OutputPath $cfg.OutputPath -Prefix $cfg.ReportPrefix -Formats $cfg.ReportFormats -Delimiter $cfg.CsvDelimiter
        $g.LastFolder = $report.Directory
        $g.LastReport = Get-EomField $report.Files 'Html'
        $c.Footer.Text = "Report: $($report.Directory)"
        $n = $result.Counts
        Set-EomGuiStatus ("{0}  {1}  {2}/{3} checks passed" -f $result.Status, [char]0x00B7, $n.Passed, @($result.Steps).Count) $result.Status
    }
    catch {
        Add-EomGuiLine 'Fail' $_.Exception.Message
        Set-EomGuiStatus 'Failed - see the progress' 'Failed'
    }
    finally {
        $g.Form.remove_Closing($g.ClosingGuard)
        $script:Ui = $null
        $g.Running = $false
        foreach ($b in 'Run', 'Close') { $c[$b].IsEnabled = $true }
        $c.Cancel.IsEnabled = $false
        $c.OpenReport.IsEnabled = [bool]$g.LastReport
        $c.OpenFolder.IsEnabled = [bool]$g.LastFolder
        if ($credential) { $credential.Password.Dispose() }
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
        $script:Gui = $null
    }
}
