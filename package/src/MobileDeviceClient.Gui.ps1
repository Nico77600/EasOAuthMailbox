<#
.SYNOPSIS
    Mobile Device Client for Exchange - graphical interface (dot-sourced by MobileDeviceClient.psm1).

.DESCRIPTION
    WPF window. With .NET 9 or later (PowerShell 7.5 and later) it uses the Fluent theme of Windows 11:
    light or dark like Windows, rounded controls, with the accent colour of the report (#B11F4B). With
    PowerShell 7.4 (.NET 8) the same window uses the classic WPF controls with the colours of the report.

    Layout: a header; on the left the sign-in method (three cards: OAuth - On-prem AD FS, OAuth - Entra
    ID for Exchange on-prem with HMA or Exchange Online, Basic - On-prem), the target and the scenario; on the right the progress, one line per
    check with its status icon, and the device code when one is used; at the bottom the actions.

    It runs exactly the same engine as the command line (Invoke-MdcMailboxTest, Export-MdcReport): the
    progress shows the lines of the console. The run happens on the window thread; the window is kept
    responsive while waiting for the sign-in (Invoke-MdcUiPump), and the run can be cancelled.

    Closing never needs PowerShell code: Close is the cancel button of the window (Esc too) and the
    title-bar button is native; the only Closing handler is attached while a test runs. A PowerShell
    event handler fails ("The pipeline has been stopped") once the command that opened the window is
    stopped, so the window must close without one. Ctrl+C is ignored in the console while it is open.

.NOTES
    Author  : Nicolas Fabert
    Version : 2.0.0
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

function Get-MdcGuiXaml {
    <# The window. Colours come from the Fluent theme resources (or the classic fallback of Set-MdcGuiTheme). #>
    @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1180" Height="860" MinWidth="1000" MinHeight="640" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI Variable Text, Segoe UI" FontSize="14" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="MdcCard" TargetType="Border">
      <Setter Property="Background" Value="{DynamicResource CardBackgroundFillColorDefaultBrush}"/>
      <Setter Property="BorderBrush" Value="{DynamicResource CardStrokeColorDefaultBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="18,14,18,16"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="MdcCardTitle" TargetType="TextBlock">
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Foreground" Value="{DynamicResource TextFillColorPrimaryBrush}"/>
    </Style>
    <Style x:Key="MdcLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Foreground" Value="{DynamicResource TextFillColorSecondaryBrush}"/>
      <Setter Property="Margin" Value="0,8,0,4"/>
    </Style>
    <Style x:Key="MdcIcon" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe Fluent Icons, Segoe MDL2 Assets"/>
    </Style>
    <Style x:Key="MdcMethod" TargetType="ListBoxItem">
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
                <Setter TargetName="Card" Property="Background" Value="{DynamicResource MdcAccentSoft}"/>
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
      <Border Width="46" Height="46" CornerRadius="10" Background="{DynamicResource MdcBrand}" VerticalAlignment="Center">
        <TextBlock Style="{StaticResource MdcIcon}" Text="&#xE715;" FontSize="22" Foreground="White" HorizontalAlignment="Center" VerticalAlignment="Center"/>
      </Border>
      <StackPanel Grid.Column="1" Margin="14,0,0,0" VerticalAlignment="Center">
        <TextBlock Text="EXCHANGE ACTIVESYNC DIAGNOSTIC" FontSize="11" FontWeight="SemiBold" Foreground="{DynamicResource MdcBrandText}"/>
        <TextBlock Text="Mobile Device Client for Exchange" FontSize="24" FontWeight="SemiBold" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
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
          <Border x:Name="Method" Style="{StaticResource MdcCard}">
            <StackPanel>
              <TextBlock Text="Sign-in method" Style="{StaticResource MdcCardTitle}"/>
              <ListBox x:Name="Authentication" ItemContainerStyle="{StaticResource MdcMethod}" BorderThickness="0" Background="Transparent" Padding="0"
                       ScrollViewer.HorizontalScrollBarVisibility="Disabled" ScrollViewer.VerticalScrollBarVisibility="Disabled">
                <ListBox.ItemsPanel>
                  <ItemsPanelTemplate><UniformGrid Columns="3"/></ItemsPanelTemplate>
                </ListBox.ItemsPanel>
              </ListBox>
              <TextBlock x:Name="MethodHint" TextWrapping="Wrap" Margin="0,10,0,0" FontSize="12" Foreground="{DynamicResource TextFillColorSecondaryBrush}"/>
            </StackPanel>
          </Border>

          <Border x:Name="Target" Style="{StaticResource MdcCard}">
            <StackPanel>
              <TextBlock Text="Target" Style="{StaticResource MdcCardTitle}" Margin="0,0,0,2"/>
              <TextBlock Text="Test mailbox (SMTP or UPN)" Style="{StaticResource MdcLabel}"/>
              <TextBox x:Name="Mailbox"/>
              <TextBlock Text="ActiveSync URL" Style="{StaticResource MdcLabel}"/>
              <TextBox x:Name="EasUrl"/>
              <StackPanel x:Name="AdfsPanel">
                <TextBlock Text="AD FS URL (ends with /adfs)" Style="{StaticResource MdcLabel}"/>
                <TextBox x:Name="AdfsUrl"/>
              </StackPanel>
              <Grid x:Name="BasicPanel">
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="12"/>
                  <ColumnDefinition Width="*"/>
                </Grid.ColumnDefinitions>
                <StackPanel>
                  <TextBlock Text="User name (empty = mailbox)" Style="{StaticResource MdcLabel}"/>
                  <TextBox x:Name="BasicUser"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="Password (never written)" Style="{StaticResource MdcLabel}"/>
                  <PasswordBox x:Name="BasicPassword"/>
                </StackPanel>
              </Grid>
              <Expander x:Name="Advanced" Header="Client and device" Margin="0,12,0,0">
                <StackPanel Margin="0,0,0,2">
                  <TextBlock x:Name="ClientIdLabel" Text="Client ID" Style="{StaticResource MdcLabel}" Margin="0,0,0,4"/>
                  <TextBox x:Name="ClientId"/>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="2*"/>
                      <ColumnDefinition Width="12"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel>
                      <TextBlock Text="Device ID (empty = derived)" Style="{StaticResource MdcLabel}"/>
                      <TextBox x:Name="DeviceId"/>
                    </StackPanel>
                    <StackPanel Grid.Column="2">
                      <TextBlock Text="Inbox headers (1-100)" Style="{StaticResource MdcLabel}"/>
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
        <Border x:Name="Scenario" Style="{StaticResource MdcCard}">
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
            <TextBlock Text="Scenario" Style="{StaticResource MdcCardTitle}" Grid.ColumnSpan="3"/>
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
                <TextBlock x:Name="WarningIcon" Style="{StaticResource MdcIcon}" FontSize="16" Margin="0,1,10,0" VerticalAlignment="Top"/>
                <TextBlock x:Name="Warning" Grid.Column="1" TextWrapping="Wrap" FontSize="12" Foreground="{DynamicResource TextFillColorPrimaryBrush}"/>
              </Grid>
            </Border>
          </Grid>
        </Border>
        <Border x:Name="Progress" Grid.Row="1" Style="{StaticResource MdcCard}">
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
            <TextBlock Text="Progress" Style="{StaticResource MdcCardTitle}"/>
            <Border x:Name="StatusPill" Grid.Column="1" CornerRadius="10" Padding="10,2" VerticalAlignment="Top">
              <TextBlock x:Name="Status" FontSize="12" FontWeight="SemiBold"/>
            </Border>
          </Grid>
          <Border x:Name="CodeBanner" Grid.Row="1" Visibility="Collapsed" Margin="0,0,0,12" Padding="14,10" CornerRadius="6" BorderThickness="1"
                  Background="{DynamicResource MdcAccentSoft}" BorderBrush="{DynamicResource AccentFillColorDefaultBrush}">
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
              <TextBlock Style="{StaticResource MdcIcon}" Text="&#xE768;" Margin="0,2,8,0"/>
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

function New-MdcGuiBrush {
    param([Parameter(Mandatory = $true)][string]$Color)
    $brush = [Windows.Media.SolidColorBrush]::new([Windows.Media.ColorConverter]::ConvertFromString($Color))
    $brush.Freeze()
    return $brush
}

function Initialize-MdcGuiTheme {
    <#
        Loads WPF and applies the theme to the application: Fluent (.NET 9+), light or dark as Windows
        (System), or Light / Dark for the documentation images. Returns Fluent and Dark.
    #>
    param([ValidateSet('System', 'Light', 'Dark')][string]$Theme = 'System')

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $dark = $Theme -eq 'Dark'
    if ($Theme -eq 'System') { $dark = Test-MdcGuiDarkMode }
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

function Test-MdcGuiDarkMode {
    <# Windows shows the applications in dark mode (AppsUseLightTheme = 0); light when the setting is missing. #>
    $personalize = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction SilentlyContinue
    return [string](Get-MdcField $personalize 'AppsUseLightTheme') -eq '0'
}

function Set-MdcGuiTheme {
    <#
        Colours of the window: the accent of the report on the Fluent accent resources, the status colours,
        and with the classic theme (.NET 8) the Fluent resources the window uses, with the report palette.
    #>
    param([Parameter(Mandatory = $true)][Windows.Window]$Window, [Parameter(Mandatory = $true)][pscustomobject]$Theme)

    $dark = $Theme.Dark
    $r = $Window.Resources
    $set = { param([string[]]$Keys, [string]$LightColor, [string]$DarkColor) $b = New-MdcGuiBrush $(if ($dark) { $DarkColor } else { $LightColor }); foreach ($k in $Keys) { $r[$k] = $b } }
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
    & $set 'MdcBrand' '#B11F4B' '#B11F4B'
    & $set 'MdcBrandText' '#B11F4B' '#FD8EA1'
    & $set 'MdcAccentSoft' '#14B11F4B' '#33FD8EA1'
    & $set 'MdcSuccess' '#16A34A' '#4ADE80'
    & $set 'MdcCaution' '#D97706' '#FBBF24'
    & $set 'MdcCritical' '#DC2626' '#F87171'
    & $set 'MdcInfoBackground' '#F3F3F3' '#2E2E2E'
    & $set 'MdcInfoBorder' '#E0E0E0' '#3D3D3D'
    & $set 'MdcCautionBackground' '#FFF7E8' '#33FBBF24'
    & $set 'MdcCautionBorder' '#F5D7A1' '#66FBBF24'
    & $set 'MdcCriticalBackground' '#FDECEC' '#33F87171'
    & $set 'MdcCriticalBorder' '#F4B4B4' '#66F87171'
    & $set 'MdcSuccessBackground' '#EAF7EE' '#334ADE80'
}

function Invoke-MdcGuiPump {
    <# Lets the window repaint and handle clicks during a run (the WPF equivalent of DoEvents). #>
    $frame = [Windows.Threading.DispatcherFrame]::new()
    [void][Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([Windows.Threading.DispatcherPriority]::Background,
        [Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; $null }, $frame)
    [Windows.Threading.Dispatcher]::PushFrame($frame)
}

function New-MdcGuiMethodCard {
    <# Content of one sign-in method card: icon, kind (OAuth, Basic), name. #>
    param([Parameter(Mandatory = $true)][pscustomobject]$Method)

    $panel = [Windows.Controls.StackPanel]::new()
    $icon = [Windows.Controls.TextBlock]::new()
    $icon.Text = [string][char]$Method.Glyph
    $icon.FontFamily = [Windows.Media.FontFamily]::new($script:GuiIconFont)
    $icon.FontSize = 18
    $icon.Margin = [Windows.Thickness]::new(0, 0, 0, 6)
    $icon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, 'MdcBrandText')
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

function New-MdcTestForm {
    <#
    .SYNOPSIS
        Builds the window (without showing it). Used by Show-MdcTestGui, the tests and the documentation tool.
    .PARAMETER Theme
        System (like Windows), Light or Dark (documentation images, tests).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Configuration, [ValidateSet('System', 'Light', 'Dark')][string]$Theme = 'System')

    $look = Initialize-MdcGuiTheme -Theme $Theme
    $catalog = @(Get-MdcTestCatalog)
    $window = [Windows.Markup.XamlReader]::Parse((Get-MdcGuiXaml))
    $window.Title = "Mobile Device Client for Exchange $($script:ToolVersion)"
    Set-MdcGuiTheme -Window $window -Theme $look
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
    foreach ($method in $script:GuiAuthentication) { [void]$controls.Authentication.Items.Add((New-MdcGuiMethodCard -Method $method)) }
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
            Add-MdcGuiLine 'Warn' 'A test is running: it stops at the next check, then the window can be closed.'
        }
    }
    Set-MdcGuiStatus 'Ready' 'Ready'
    $controls.Footer.Text = "Reports: $($Configuration.OutputPath)"

    $controls.TestType.Add_SelectionChanged({ Update-MdcGuiScenario })
    $controls.Authentication.Add_SelectionChanged({ Update-MdcGuiScenario })
    $controls.DeviceCode.Add_Click({ Update-MdcGuiScenario })
    # The notice of Entra ID names Exchange Online or on-prem from the ActiveSync URL.
    $controls.EasUrl.Add_LostFocus({ Update-MdcGuiScenario })
    $controls.Run.Add_Click({ Invoke-MdcGuiRun })
    $controls.Cancel.Add_Click({
            if ($script:Ui) {
                $script:Ui.Cancel = $true
                Add-MdcGuiLine 'Warn' 'Cancellation requested: the run stops at the next check.'
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
    Update-MdcGuiScenario
    [pscustomobject]@{ Form = $window; Controls = $controls; Lines = $script:Gui.Lines; Items = $items }
}

function Set-MdcGuiNotice {
    <# The coloured box under the scenario: Info, Caution or Critical. #>
    param([Parameter(Mandatory = $true)][string]$Text, [ValidateSet('Info', 'Caution', 'Critical')][string]$Level = 'Info')

    $c = $script:Gui.Controls
    $c.Warning.Text = $Text
    $c.WarningIcon.Text = [string][char]$(switch ($Level) { 'Caution' { 0xE7BA } 'Critical' { 0xEA39 } default { 0xE946 } })
    $c.WarningIcon.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $(switch ($Level) { 'Caution' { 'MdcCaution' } 'Critical' { 'MdcCritical' } default { 'TextFillColorSecondaryBrush' } }))
    $c.WarningBox.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $(switch ($Level) { 'Caution' { 'MdcCautionBackground' } 'Critical' { 'MdcCriticalBackground' } default { 'MdcInfoBackground' } }))
    $c.WarningBox.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, $(switch ($Level) { 'Caution' { 'MdcCautionBorder' } 'Critical' { 'MdcCriticalBorder' } default { 'MdcInfoBorder' } }))
}

function Update-MdcGuiScenario {
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
        Set-MdcGuiNotice 'The OAuth scenario tests the AD FS sign-in: choose OAuth, or Endpoint to check the user name and password.' Critical
    }
    elseif ($basic -and $apple) {
        Set-MdcGuiNotice "iPhone with a password (Basic): ActiveSync URL from Autodiscover, checks that Exchange does not offer OAuth to the mailbox, then Basic as an iPhone.$partnership" Caution
    }
    elseif ($basic) {
        $text = if ($s.SignIn) { "Basic: the user name and password go with every request (TLS only); AD FS is not used.$partnership" } else { 'Basic, no sign-in: Basic offered, OAuth offered to the mailbox, wrong password refused (with a user that does not exist).' }
        Set-MdcGuiNotice $text $(if ($partnership) { 'Caution' } else { 'Info' })
    }
    elseif ($apple) {
        Set-MdcGuiNotice "Like the iPhone, only the mailbox is needed: ActiveSync URL from Autodiscover (the one above only if Autodiscover fails), AD FS or Entra ID from Exchange, Apple Mail client $($g.Configuration['AppleClientId']). Creates an iPhone device: use a test mailbox." Caution
    }
    elseif ($choice.Authority -eq 'EntraID' -and $s.SignIn) {
        $tenant = if ($g.Configuration['TenantId']) { "tenant $($g.Configuration['TenantId'])" } else { 'tenant found from the domain of the mailbox' }
        $where = if (Test-MdcExchangeOnlineUrl -Url ([string]$c.EasUrl.Text)) { 'Exchange Online' } else { 'Exchange on-prem with hybrid modern authentication' }
        Set-MdcGuiNotice "Entra ID ($where): $tenant, $how.$partnership" $(if ($partnership) { 'Caution' } else { 'Info' })
    }
    elseif ($s.ChangesServerState) {
        Set-MdcGuiNotice "This scenario creates an ActiveSync device partnership for the device ID: use a test mailbox. AD FS, $how." Caution
    }
    elseif (-not $s.SignIn) {
        Set-MdcGuiNotice 'No sign-in: only requests without credentials and a deliberately invalid token are sent.'
    }
    else {
        Set-MdcGuiNotice "Sign-in only, $($how): no ActiveSync device partnership is created."
    }
}

function Add-MdcGuiLine {
    <# One line of the progress: icon and colour of its status; a device code also shows in its own box. #>
    param([string]$Status, [string]$Text)

    $g = $script:Gui
    if (-not $g) { return }
    $glyphs = @{ Step = 0xE76C; Ok = 0xE73E; Warn = 0xE7BA; Fail = 0xEA39; Info = 0xE946; Skip = 0xE72A; Block = 0xE733 }
    $colours = @{ Step = 'MdcBrandText'; Ok = 'MdcSuccess'; Warn = 'MdcCaution'; Fail = 'MdcCritical'; Info = 'TextFillColorSecondaryBrush'; Skip = 'TextFillColorTertiaryBrush'; Block = 'MdcCaution' }
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
    Invoke-MdcGuiPump
}

function Clear-MdcGuiProgress {
    $g = $script:Gui
    $g.Items.Clear()
    $g.Lines.Clear()
    $g.CodePage = $null
    $g.Controls.CodeBanner.Visibility = 'Collapsed'
    $g.Controls.LogEmpty.Visibility = 'Visible'
}

function Set-MdcGuiStatus {
    <# The status pill of the progress: Ready, Running, Passed, Warning, Blocked or Failed. #>
    param([string]$Text, [string]$Status)

    $c = $script:Gui.Controls
    $c.Status.Text = $Text
    $pair = switch ($Status) {
        'Passed' { 'MdcSuccess', 'MdcSuccessBackground' }
        'Failed' { 'MdcCritical', 'MdcCriticalBackground' }
        { $_ -in 'Warning', 'Blocked' } { 'MdcCaution', 'MdcCautionBackground' }
        'Running' { 'MdcBrandText', 'MdcAccentSoft' }
        default { 'TextFillColorSecondaryBrush', 'MdcInfoBackground' }
    }
    $c.Status.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, $pair[0])
    $c.StatusPill.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $pair[1])
}

function Invoke-MdcGuiRun {
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

    Clear-MdcGuiProgress
    $problems = @((Test-MdcConfiguration -Configuration $cfg).Problems)
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
        foreach ($problem in $problems) { Add-MdcGuiLine 'Fail' $problem }
        Set-MdcGuiStatus 'Fix the values above.' 'Failed'
        return
    }

    $script:Ui = @{
        Sink   = { param($Status, $Text) Add-MdcGuiLine $Status $Text }
        Pump   = { Invoke-MdcGuiPump }
        Cancel = $false
    }
    try {
        $g.Running = $true
        $g.Form.add_Closing($g.ClosingGuard)
        foreach ($b in 'Run', 'OpenReport', 'OpenFolder', 'Close') { $c[$b].IsEnabled = $false }
        $c.Cancel.IsEnabled = $true
        Set-MdcGuiStatus "Running $($cfg.TestType)..." 'Running'
        $c.Footer.Text = "$($choice.Text)  " + [char]0x00B7 + "  $($cfg.Mailbox)"
        Write-MdcLog 'STEP' "GUI run: $($cfg.TestType) ($($cfg.Authentication)) for $($cfg.Mailbox)"
        $result = Invoke-MdcMailboxTest -Configuration $cfg -TestType $cfg.TestType -Credential $credential
        $report = Export-MdcReport -Result $result -OutputPath $cfg.OutputPath -Prefix $cfg.ReportPrefix -Formats $cfg.ReportFormats -Delimiter $cfg.CsvDelimiter
        $g.LastFolder = $report.Directory
        $g.LastReport = Get-MdcField $report.Files 'Html'
        $c.Footer.Text = "Report: $($report.Directory)"
        $n = $result.Counts
        Set-MdcGuiStatus ("{0}  {1}  {2}/{3} checks passed" -f $result.Status, [char]0x00B7, $n.Passed, @($result.Steps).Count) $result.Status
    }
    catch {
        Add-MdcGuiLine 'Fail' $_.Exception.Message
        Set-MdcGuiStatus 'Failed - see the progress' 'Failed'
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

function Show-MdcTestGui {
    <#
    .SYNOPSIS
        Opens the window. Default configuration: config\MobileDeviceClient.config.psd1 of the tool folder.
    #>
    [CmdletBinding()]
    param([hashtable]$Configuration)

    if (-not $Configuration) { $Configuration = Import-MdcConfiguration }
    $window = New-MdcTestForm -Configuration $Configuration
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

# SIG # Begin signature block
# MIIghgYJKoZIhvcNAQcCoIIgdzCCIHMCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDR/HMkDmifbIZG
# aBiemkFWWGr9QA3ONZhlO0WI8PxdjaCCDW8wggZyMIIEWqADAgECAghkM1HTxzif
# CDANBgkqhkiG9w0BAQsFADB8MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMx
# EDAOBgNVBAcMB0hvdXN0b24xGDAWBgNVBAoMD1NTTCBDb3Jwb3JhdGlvbjExMC8G
# A1UEAwwoU1NMLmNvbSBSb290IENlcnRpZmljYXRpb24gQXV0aG9yaXR5IFJTQTAe
# Fw0xNjA2MjQyMDQ0MzBaFw0zMTA2MjQyMDQ0MzBaMHgxCzAJBgNVBAYTAlVTMQ4w
# DAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjERMA8GA1UECgwIU1NMIENv
# cnAxNDAyBgNVBAMMK1NTTC5jb20gQ29kZSBTaWduaW5nIEludGVybWVkaWF0ZSBD
# QSBSU0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCfgxNzqrDG
# bSHL24t6h3TQcdyOl3Ka5LuINLTdgAPGL0WkdJq/Hg9Q6p5tePOf+lEmqT2d0bKU
# Vz77OYkbkStW72fL5gvjDjmMxjX0jD3dJekBrBdCfVgWQNz51ShEHZVkMGE6ZPKX
# 13NMfXsjAm3zdetVPW+qLcSvvnSsXf5qtvzqXHnpD0OctVIFD+8+sbGP0EmtpuNC
# GVQ/8y8Ooct8/hP5IznaJRy4PgBKOm8yMDdkHseudQfYVdIYyQ6KvKNc8HwKp4WB
# wg6vj5lc02AlvINaaRwlE81y9eucgJvcLGfE3ckJmNVz68Qho+Uyjj4vUpjGYDdk
# jLJvSlRyGMwnh/rNdaJjIUy1PWT9K6abVa8mTGC0uVz+q0O9rdATZlAfC9KJpv/X
# gAbxwxECMzNhF/dWH44vO2jnFfF3VkopngPawismYTJboFblSSmNNqf1x1KiVgMg
# Lzh4gL32Bq5BNMuURb2bx4kYHwu6/6muakCZE93vUN8BuvIE1tAx3zQ4XldbyDge
# VtSsSKbt//m4wTvtwiS+RGCnd83VPZhZtEPqqmB9zcLlL/Hr9dQg1Zc0bl0EawUR
# 0tOSjAknRO1PNTFGfnQZBWLsiePqI3CY5NEv1IoTGEaTZeVYc9NMPSd6Ij/D+KNV
# t/nmh4LsRR7Fbjp8sU65q2j3m2PVkUG8qQIDAQABo4H7MIH4MA8GA1UdEwEB/wQF
# MAMBAf8wHwYDVR0jBBgwFoAU3QQJB6L1en1SUxKSle44gCUNplkwMAYIKwYBBQUH
# AQEEJDAiMCAGCCsGAQUFBzABhhRodHRwOi8vb2NzcHMuc3NsLmNvbTARBgNVHSAE
# CjAIMAYGBFUdIAAwEwYDVR0lBAwwCgYIKwYBBQUHAwMwOwYDVR0fBDQwMjAwoC6g
# LIYqaHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0G
# A1UdDgQWBBRUwv4QlQCTzWr158DX2bJLuI8M4zAOBgNVHQ8BAf8EBAMCAYYwDQYJ
# KoZIhvcNAQELBQADggIBAPUPJodwr5miyvXWyfCNZj05gtOII9iCv49UhCe204MH
# 154niU2EjlTRIO5gQ9tXQjzHsJX2vszqoz2OTwbGK1mGf+tzG8rlQCbgPW/M9r1x
# xs19DiBAOdYF0q+UCL9/wlG3K7V7gyHwY9rlnOFpLnUdTsthHvWlM98CnRXZ7WmT
# V7pGRS6AvGW+5xI+3kf/kJwQrfZWsqTU+tb8LryXIbN2g9KR+gZQ0bGAKID+260P
# Z+34fdzZcFt6umi1s0pmF4/n8OdX3Wn+vF7h1YyfE7uVmhX7eSuF1W0+Z0duGwdc
# +1RFDxYRLhHDsLy1bhwzV5Qe/kI0Ro4xUE7bM1eV+jjk5hLbq1guRbfZIsr0WkdJ
# LCjoT4xCPGRo6eZDrBmRqccTgl/8cQo3t51Qezxd96JSgjXktefTCm9r/o35pNfV
# HUvnfWII+NnXrJlJ27WEQRQu9i5gl1NLmv7xiHp0up516eDap8nMLDt7TAp4z5T3
# NmC2gzyKVMtODWgqlBF1JhTqIDfM63kXdlV4cW3iSTgzN9vkbFnHI2LmvM4uVEv9
# XgMqyN0eS3FE0HU+MWJliymm7STheh2ENH+kF3y0rH0/NVjLw78a3Z9UVm1F5VPz
# iIorMaPKPlDRADTsJwjDZ8Zc6Gi/zy4WZbg8Zv87spWrmo2dzJTw7XhQf+xkR6Od
# MIIG9TCCBN2gAwIBAgIQBof4ljXihJpmCqqt2mhAWzANBgkqhkiG9w0BAQsFADB4
# MQswCQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24x
# ETAPBgNVBAoMCFNTTCBDb3JwMTQwMgYDVQQDDCtTU0wuY29tIENvZGUgU2lnbmlu
# ZyBJbnRlcm1lZGlhdGUgQ0EgUlNBIFIxMB4XDTI2MTAxMzAyNDgwMloXDTI3MTAx
# MzAyNDgwMlowXDELMAkGA1UEBhMCRlIxGzAZBgNVBAcMEkNoYW50ZWxvdXAtRW4t
# QnJpZTEXMBUGA1UECgwOTmljb2xhcyBGYWJlcnQxFzAVBgNVBAMMDk5pY29sYXMg
# RmFiZXJ0MIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAsg6CT0mFQ4jB
# V2plIS4uWFSoVqRHd82Y7XYZ4CUTe/7nPBRUlXXdKTZMMHzGgiG8dEXNE8K1Xe90
# Dgl/FnorzAFlrNWSwf6t27UAUw9xkqtRDVVpVgpixpWkAwjcQeLG+YMqBkGbFi35
# TGvS23lPFWvLp4DxARrv15MtZ/NjNTCAAGUlMP2hFVBknEmrnYjEGyeJ93sl20RS
# WXQQLNqlenBdkGCrQW4XjHtRjJAEqAC68hN6nWevopSQ8CLUV7A1RFfHFarDrzrL
# zr0/NjIdSyIfM9hShln31NDrktB6Ups2XIyrtPDNB7fjkW4jpLlOqQGfYKsU9ErE
# 4SnFsh0yOOjitegyh1RvZ9wH++3DF4CmJfTli5l/gEIm8xCCryxI+K5EogW3wu1y
# u8NT2hcvHjdh7OpRyPyFAuLZ8MfX7kPAJpnuCeOuktzY/20eVD8bDglj+4zgqzsn
# cR/t6T/7w1/HxpRyrVoKvEyRx+mphYh5jMdEa0BjxOL0vAJpdGZSfXGmPm/yPqRn
# 5STTkMtzkVQXPbcvgKM0luzFcQKPHk3qdHLEXa8gf93ktYDbLE5Wd2UHrXz3SZxN
# URHPdIXCr1qgrqQve7041kMpzrkDI5DnG2lvRG4108gp02bHG0muKyZlDdCOra7h
# Zonu2nO79sFallruzzNi0o994PoWksUCAwEAAaOCAZUwggGRMAwGA1UdEwEB/wQC
# MAAwHwYDVR0jBBgwFoAUVML+EJUAk81q9efA19myS7iPDOMwegYIKwYBBQUHAQEE
# bjBsMEgGCCsGAQUFBzAChjxodHRwOi8vY2VydC5zc2wuY29tL1NTTGNvbS1TdWJD
# QS1Db2RlU2lnbmluZy1SU0EtNDA5Ni1SMS5jZXIwIAYIKwYBBQUHMAGGFGh0dHA6
# Ly9vY3Nwcy5zc2wuY29tMFEGA1UdIARKMEgwCAYGZ4EMAQQBMDwGDCsGAQQBgqkw
# AQMDATAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3JlcG9zaXRv
# cnkwEwYDVR0lBAwwCgYIKwYBBQUHAwMwTQYDVR0fBEYwRDBCoECgPoY8aHR0cDov
# L2NybHMuc3NsLmNvbS9TU0xjb20tU3ViQ0EtQ29kZVNpZ25pbmctUlNBLTQwOTYt
# UjEuY3JsMB0GA1UdDgQWBBRoUx3630l9wA1fUpkKkw2GUIxl/jAOBgNVHQ8BAf8E
# BAMCB4AwDQYJKoZIhvcNAQELBQADggIBAE3oj6cNuwlDToi1BwjgsA5djfRN4DIi
# BYDFZIRYaIRe/rEdnItz3aqQQdFuwXnJA/MQEmi2WAGek8GeZF+R41s8FbcDxBUE
# BoSt98TuBE+0xgxQWDiPhhXaX1Aw9V0GF4ZnlfCSw1eu2KiASaKn7Bo0PLbEAXff
# vftRXof/kyqtw8iID6I4Rhrf5DI3WVZQodakUUmWnbnziWvEZOWbNOfzwP+7BwEt
# 7jQANfbmEfb4p75rfy5dQVwniTDSvdo6xkrbe1Cr93GS7cJta18IG5CoIVUmdK+s
# W38B1sLuy8Mi0MstMXV3004yaRuzLdNaAM0f9WAFerxemiQC0kdmA44/lWV3lVkM
# WJSwkHBkkSg8Eh0hxcGzTH2xmtDhLJHNNLRwkI9u2Ur+HbLCt50oBgSV8BcCs/1i
# qi884iC/yuX+HIv9YgTUNZ8c4lLaq4VuliJpXLu2buHIsTkO0v0+5oCM91zjTVZm
# ULeH38N0Vr83psiJVuBSxQyt5nRVrpYz7FACq5gtXELkyViq/rGOlJKaRrgQ6WWq
# eoIXqKhVFAdP/jAEm2M8ezoVYsUgPyKY2OcuecV9coulAcxUIUydx6qYiOfsGj5u
# Dy7l4aYjvB771wkUMzUQwxzcDYXJtMMTaWRe6n9EemR67jc73u5CJyFg3PfA5WR1
# wZislcdCZuS6MYISbTCCEmkCAQEwgYwweDELMAkGA1UEBhMCVVMxDjAMBgNVBAgM
# BVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDE0MDIG
# A1UEAwwrU1NMLmNvbSBDb2RlIFNpZ25pbmcgSW50ZXJtZWRpYXRlIENBIFJTQSBS
# MQIQBof4ljXihJpmCqqt2mhAWzANBglghkgBZQMEAgEFAKCBhDAYBgorBgEEAYI3
# AgEMMQowCKACgAChAoAAMBkGCSqGSIb3DQEJAzEMBgorBgEEAYI3AgEEMBwGCisG
# AQQBgjcCAQsxDjAMBgorBgEEAYI3AgEVMC8GCSqGSIb3DQEJBDEiBCDORv6YjZVI
# jhOmmEoLEwetcE3VYQ68m2DIqkC3sCR6WjANBgkqhkiG9w0BAQEFAASCAgB0osQ1
# TvaCLvFecj24OOa+NbokCGLKLCoO/Ej8R3bDhI4T0NAP9dclDq+UL6wpmrPi4ROL
# w5Xwq4VMLE7CgEf23N8D/z18gKGjroPyFfjzNdGYPpifCirDRca0CgAlq5He50JV
# elQYDTiVVNbGCK1jMgKl80Po+K3n1pEP47R7sXx0IN+ZHtZqz7G5t8eOWTWq+NPx
# hqGVTJoTT+35fTVvnVUOmDDAGx0qD+6MHLz8aurI/oHXeYbvb7SmxkcC7yc935Ka
# O6dE+s36FJ6q1aAPqYbe0bLvmJdnOyHCw24mBdVQOhZD67Yt5XcU9veLkzf19pgc
# E857mf6luVevNKN4Sa+cWAP4xHfV2IdC21bog3m9ElCC50VWkdActJO78Cf5KIrK
# 1rfH4h4IWqP+6NhcCS2NqXOfNAuAb9tGR15HQxYSjqWx+Q1UiiV4VAT6rai7Kzo8
# WvNtkGga1X1eTciXJ72sSmODcIITewvPvo1zeZ8wyl3gc2HZWBhBmEgaFFYRWAPo
# LZwq066xiKdWECr/DlY0qnpzxqU5ZyWZfbRJsf4djujIEyNDYiwSkIzFgl4CllBJ
# O6DUK+QbIP/xd7rhjw984l6bdRIrVLz07lpBQF6Lk3IS2jOJRw/LZIpZ9QbLzY5m
# EKbHc1H8Fdwjkez4ynPB48nBL7NNijI+nh+o3aGCDyowgg8mBgorBgEEAYI3AwMB
# MYIPFjCCDxIGCSqGSIb3DQEHAqCCDwMwgg7/AgEDMQ0wCwYJYIZIAWUDBAIBMIGJ
# BgsqhkiG9w0BCRABBKB6BHgwdgIBAQYMKwYBBAGCqTABAwYBMDEwDQYJYIZIAWUD
# BAIBBQAEICAZPRRRDXsUNt9xT9xkDeBa23uOFrv/NeMMMwOJWoynAghEOvTnMat0
# kRgPMjAyNjEwMTQxMTM2MDVaMAMCAQECECU8tn19G//i9A08gEdXOYGgggwAMIIE
# /DCCAuSgAwIBAgIQH2sWYtIuG2xd8cDBoGAOODANBgkqhkiG9w0BAQsFADBzMQsw
# CQYDVQQGEwJVUzEOMAwGA1UECAwFVGV4YXMxEDAOBgNVBAcMB0hvdXN0b24xETAP
# BgNVBAoMCFNTTCBDb3JwMS8wLQYDVQQDDCZTU0wuY29tIFRpbWVzdGFtcGluZyBJ
# c3N1aW5nIFJTQSBDQSBSMTAeFw0yNTAyMTgxNjMyMDJaFw0zNDExMTIxODUwMDVa
# MG4xCzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3Rv
# bjERMA8GA1UECgwIU1NMIENvcnAxKjAoBgNVBAMMIVNTTC5jb20gVGltZXN0YW1w
# aW5nIFVuaXQgMjAyNSBFMTBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABBv7UVHH
# b+ZVluxPXlfE3M6tg0Xnq8dic+O3vPOCRpalUM1vO9A+GRzSVVjyygHhYrBw62XL
# Fh1kv7e+yRd/aTajggFaMIIBVjAfBgNVHSMEGDAWgBQMnRAljpqnG5mHQ88IfuG9
# gZD0zzBRBggrBgEFBQcBAQRFMEMwQQYIKwYBBQUHMAKGNWh0dHA6Ly9jZXJ0LnNz
# bC5jb20vU1NMLmNvbS10aW1lU3RhbXBpbmctSS1SU0EtUjEuY2VyMFEGA1UdIARK
# MEgwPAYMKwYBBAGCqTABAwYBMCwwKgYIKwYBBQUHAgEWHmh0dHBzOi8vd3d3LnNz
# bC5jb20vcmVwb3NpdG9yeTAIBgZngQwBBAIwFgYDVR0lAQH/BAwwCgYIKwYBBQUH
# AwgwRgYDVR0fBD8wPTA7oDmgN4Y1aHR0cDovL2NybHMuc3NsLmNvbS9TU0wuY29t
# LXRpbWVTdGFtcGluZy1JLVJTQS1SMS5jcmwwHQYDVR0OBBYEFM582cAEgMUkEGoJ
# 6hyrJT0R/ajSMA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAgHN1
# JIW9ZlNip07FfY9r1LJwLKTl1h/y9r1BjDgHMEz7U7J7mAy32JxA1KLyjCCJqNku
# RfhDHGFEfZtjTOru7AQMDSDiUDvCCc3jaz5py9jGvwIe5npkLbXqXhA+SqCzG719
# USigwhHkYr7v8NiXoaY0Xu03p0BiZZreZlpngmGB9+86N94FqIFx2I5Z5iuu7d4j
# 7aAOZBNxfU9jFDIIGDtWfWeCpF0Q8rLE/3DHDlzJKs5Il3i/VoOl7rTU938oSrxM
# www6GDBlKX8rGHxvkjgIb9MXkVglJSDHsNAZDeCS/inaxKHA+ChuB8K4OxIxa6k1
# e+eHBypakAY3wuN7w7PlPmhN6k5IdqZn3HZHs2VjoR841Z9wmVPFdGDdkBZ7XOmb
# 5OZUaKufsvtER0VbY2DkzaqAaItt1kc+I+FUz7PiVz2PUzpegkftRRxvrPyIL08b
# lJTnbMQ0XrqDN0rEfuTLv4XhhnKyJaXhxCUdjO/cRumMzZ35QTUMItBWy1xGp0iy
# oFVnAya2pPsVMuAI+sy1zxlOS9l5iSxvKJ8gpnpOgjqYTa7u1eyZo+4JlcGoiiR1
# 7LthMTrF1q62tO5xOpI8txUZ6gtKGtkJV6wdj+vZLcwKZ2M93GqVpOo6UBlGjx1s
# KsVZ7AIUzJZli4NJ0M2KYcrfNnlebkYKpDnSqWwwggb8MIIE5KADAgECAhBtUhhw
# h+gjTYVgANCAj5NWMA0GCSqGSIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMQ4wDAYD
# VQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjEYMBYGA1UECgwPU1NMIENvcnBv
# cmF0aW9uMTEwLwYDVQQDDChTU0wuY29tIFJvb3QgQ2VydGlmaWNhdGlvbiBBdXRo
# b3JpdHkgUlNBMB4XDTE5MTExMzE4NTAwNVoXDTM0MTExMjE4NTAwNVowczELMAkG
# A1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYDVQQHDAdIb3VzdG9uMREwDwYD
# VQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNvbSBUaW1lc3RhbXBpbmcgSXNz
# dWluZyBSU0EgQ0EgUjEwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCu
# URAT0vk8IKAghd7JUBxkyeH9xek0/wp/MUjoclrFXqhh/fGH91Fc+7fm0MHCE7A+
# wmOiqBj9ODrJAYGq3rm33jCnHSsCBNWAQYyoauLq8IjqsS1JlXL29qDNMMdwZ8UN
# zQS7vWZMDJ40JSGNphMGTIA2qn2bohGtgRc4p1395ESypUOaGvJ3t0FNL3BuKmb6
# YctMcQUF2sqooMzd89h0E6ujdvBDo6ZwNnWoxj7YmfWjSXg33A5GuY9ym4QZM5OE
# Vgo8ebz/B+gyhyCLNNhh4Mb/4xvCTCMVmNYrBviGgdPZYrym8Zb84TQCmSuX0JlL
# La6WK1aO6qlwISbb9bVGh866ekKblC/XRP20gAu1CjvcYciUgNTrGFg8f8AJgQPO
# Cc1/CCdaJSYwhJpSdheKOnQgESgNmYZPhFOC6IKaMAUXk5U1tjTcFCgFvvArXtK4
# azAWUOO1Y3fdldIBL6LjkzLUCYJNkFXqhsBVcPMuB0nUDWvLJfPimstjJ8lF4S6E
# CxWnlWi7OElVwTnt1GtRqeY9ydvvGLntU+FecK7DbqHDUd366UreMkSBtzevAc9a
# qoZPnjVMjvFqV1pYOjzmTiVHZtAc80bAfFe5LLfJzPI6DntNyqobpwTevQpHqPDN
# 9qqNO83r3kaw8A9j+HZiSw2AX5cGdQP0kG0vhzfgBwIDAQABo4IBgTCCAX0wEgYD
# VR0TAQH/BAgwBgEB/wIBADAfBgNVHSMEGDAWgBTdBAkHovV6fVJTEpKV7jiAJQ2m
# WTCBgwYIKwYBBQUHAQEEdzB1MFEGCCsGAQUFBzAChkVodHRwOi8vd3d3LnNzbC5j
# b20vcmVwb3NpdG9yeS9TU0xjb21Sb290Q2VydGlmaWNhdGlvbkF1dGhvcml0eVJT
# QS5jcnQwIAYIKwYBBQUHMAGGFGh0dHA6Ly9vY3Nwcy5zc2wuY29tMD8GA1UdIAQ4
# MDYwNAYEVR0gADAsMCoGCCsGAQUFBwIBFh5odHRwczovL3d3dy5zc2wuY29tL3Jl
# cG9zaXRvcnkwEwYDVR0lBAwwCgYIKwYBBQUHAwgwOwYDVR0fBDQwMjAwoC6gLIYq
# aHR0cDovL2NybHMuc3NsLmNvbS9zc2wuY29tLXJzYS1Sb290Q0EuY3JsMB0GA1Ud
# DgQWBBQMnRAljpqnG5mHQ88IfuG9gZD0zzAOBgNVHQ8BAf8EBAMCAYYwDQYJKoZI
# hvcNAQELBQADggIBAJIZdQ2mWkLPGQfZ8vyU+sCb8BXpRJZaL3Ez3VDlE3uZk3cP
# xPtybVfLuqaci0W6SB22JTMttCiQMnIVOsXWnIuAbD/aFTcUkTLBI3xys+wEajzX
# aXJYWACDS47BRjDtYlDW14gLJxf8W6DQoH3jHDGGy8kGJFOlDKG7/YrK7UGfHtBA
# EDVe6lyZ+FtCsrk7dD/IiL/+Q3Q6SFASJLQ2XI89ihFugdYL77CiDNXrI2MFspQG
# swXEAGpHuaQDTHUp/LdR3TyrIsLlnzoLskUGswF/KF8+kpWUiKJNC4rPWtNrxlbX
# YRGgdEdx8SMjUTDClldcrknlFxbqHsVmr9xkT2QtFmG+dEq1v5fsIK0vHaHrWjMM
# maJ9i+4qGJSD0stYfQ6v0PddT7EpGxGd867Ada6FZyHwbuQSadMb0K0P0OC2r7rw
# qBUe0BaMqTa6LWzWItgBjGcObXeMxmbQqlEz2YtAcErkZvh0WABDDE4U8GyV/32F
# daAvJgTfe9MiL2nSBioYe/g5mHUSWAay/Ip1RQmQCvmF9sNfqlhJwkjy/1U1ibUk
# TIUBX3HgymyQvqQTZLLys6pL2tCdWcjI9YuLw30rgZm8+K387L7ycUvqrmQ3ZJlu
# jHl3r1hgV76s3WwMPgKk1bAEFMj+rRXimSC+Ev30hXZdqyMdl/il5Ksd0vhGMYIC
# WTCCAlUCAQEwgYcwczELMAkGA1UEBhMCVVMxDjAMBgNVBAgMBVRleGFzMRAwDgYD
# VQQHDAdIb3VzdG9uMREwDwYDVQQKDAhTU0wgQ29ycDEvMC0GA1UEAwwmU1NMLmNv
# bSBUaW1lc3RhbXBpbmcgSXNzdWluZyBSU0EgQ0EgUjECEB9rFmLSLhtsXfHAwaBg
# DjgwCwYJYIZIAWUDBAIBoIIBYTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQw
# HAYJKoZIhvcNAQkFMQ8XDTI2MTAxNDExMzYwNVowKAYJKoZIhvcNAQk0MRswGTAL
# BglghkgBZQMEAgGhCgYIKoZIzj0EAwIwLwYJKoZIhvcNAQkEMSIEIGbfklXerSj/
# i+VLsKYEM4bP4BfefTzcCEhRf9dXFMTmMIHJBgsqhkiG9w0BCRACLzGBuTCBtjCB
# szCBsAQgVCr5oWqNci5mEUl4iumUwYqaruWmXLNEolSa+Wx5x4swgYswd6R1MHMx
# CzAJBgNVBAYTAlVTMQ4wDAYDVQQIDAVUZXhhczEQMA4GA1UEBwwHSG91c3RvbjER
# MA8GA1UECgwIU1NMIENvcnAxLzAtBgNVBAMMJlNTTC5jb20gVGltZXN0YW1waW5n
# IElzc3VpbmcgUlNBIENBIFIxAhAfaxZi0i4bbF3xwMGgYA44MAoGCCqGSM49BAMC
# BEgwRgIhAKPTiKCZfVvK8XmjAzGGWlusLqUtymxCYHTkUD03HnsWAiEAk/7/FrNe
# uNDOwsM/PUrZLTeN16p6zd+1DAz7r7a2Wec=
# SIG # End signature block
