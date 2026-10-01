#Requires -Version 5.1
<#
.SYNOPSIS
    Kiosk Fleet Manager: the desktop window for the Mach2 kiosks (Mach2
    Launcher ver 1.00NG, watchdog built in) and the Power BI screens (PBI
    Launcher).

.DESCRIPTION
    The window reads the same single
    file the Power BI report reads - MWST_FleetEvents.csv, plus the
    collector's status sidecar next to it - so it opens instantly, costs
    nothing to keep open, and needs no credentials until you ask it to do
    something to a kiosk.

    Five places:

      Overview   the headline, the numbers, everything needing attention,
                 a week of reboots, and how fresh the data is
      Mach2      the Mach2 kiosks, with the watchdog's columns and the NG
                 launcher's state per screen
      Power BI   the Power BI screens: what the launcher is doing, for how
                 long, and which account it is signed in as
      Deploy     pick a launcher, pick kiosks, pick options; the exact
                 command is shown before anything runs, and a dry run
                 changes nothing
      Activity   the live output of whatever is running, and the deploy
                 reports of what ran before

    Selecting a kiosk opens its details, with the actions that make sense
    for it: restart, SCCM remote control, a message on its screen, and -
    for a kiosk running a launcher - reload, restart the browser, take a
    screenshot of what is on the screen right now, hold, stop, read the
    log, and set the sign-in password.

    Nothing here collects: that is the collector's job, on a schedule or
    from Scan now. Everything that touches a kiosk goes over its admin
    share (C$), as the collector does, with the saved kiosk-admin
    credential.

.PARAMETER CsvPath
    The events CSV. Default: next to the SharePoint master kiosk list if it
    is synced here, otherwise Logs\MWST_FleetEvents.csv.

.PARAMETER RefreshSeconds
    How often the window looks for new data. Default 5. The CSV is only
    re-read when it has actually changed.

.PARAMETER StaleMinutes
    Say the data is stale when the last collector run is older than this.
    Default 45 (the collector runs every 15 minutes).

.PARAMETER AutoScanMinutes
    How often Auto-scan runs a collection. Default 15, matching the
    scheduled collector.

.PARAMETER View
    The view to open on: Overview (default), Mach2, PBI, Other, Deploy or
    Activity.

.PARAMETER AutoScan
    Start with auto-scan already on.

.PARAMETER Screenshot
    Render every view to PNG files in this folder and exit, without showing
    a window. For the tests and the documentation.

.EXAMPLE
    .\Show-FleetManager.ps1

.EXAMPLE
    .\Show-FleetManager.ps1 -View Deploy
#>

[CmdletBinding()]
param(
    [string]$CsvPath,
    [ValidateRange(1, 3600)][int]$RefreshSeconds = 5,
    [ValidateRange(1, 10080)][int]$StaleMinutes = 45,
    [ValidateRange(1, 1440)][int]$AutoScanMinutes = 15,
    [ValidateSet('Overview', 'Mach2', 'PBI', 'Web', 'Other', 'Deploy', 'Activity')][string]$View = 'Overview',
    [switch]$AutoScan,
    [string]$CredentialFile,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$RemoteControlPath,
    [string]$SccmSiteServer,
    [string]$RestartMessage = "IT is restarting this kiosk remotely. Please do not switch it off - it will come back on its own.",
    [ValidateRange(0, 3600)][int]$RestartWarningSeconds = 60,
    # For the tests: a local folder standing in for each kiosk's C: drive.
    # Reachability and the share login are skipped for a local root.
    [string]$RootTemplate = '\\{0}\C$',
    [string]$Screenshot,
    [switch]$NoShow
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ManagerVersion = '1.00'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'Lib\MWST.KioskList.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.Remote.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.Message.ps1')
. (Join-Path $ScriptDir 'Lib\PBI.Launcher.ps1')
. (Join-Path $ScriptDir 'Lib\M2.LauncherNG.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.FleetState.ps1')

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

if (-not $CredentialFile) { $CredentialFile = Join-Path $ScriptDir 'Config\kiosk-admin.cred.xml' }

$LogDir           = Join-Path $ScriptDir 'Logs'
$RunDir           = Join-Path $LogDir 'run'
$SnapshotDir      = Join-Path $LogDir 'snapshots'
$CollectorPath    = Join-Path $ScriptDir 'Collect-MWSTFleet.ps1'
$DeployNgPath     = Join-Path $ScriptDir 'Deploy-Mach2LauncherNG.ps1'
$DeployPbiPath    = Join-Path $ScriptDir 'Deploy-PbiLauncher.ps1'
$DeployWebPath    = Join-Path $ScriptDir 'Deploy-WebLauncher.ps1'
$ScanProgressPath = Join-Path $LogDir 'autoscan.progress.json'
$KioskRootTemplate = $RootTemplate
$PublicDocsRel    = 'Users\Public\Documents'
$LiveStaleMinutes = 5

foreach ($d in @($LogDir, $RunDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# ---------------------------------------------------------------------------
# Session state
# ---------------------------------------------------------------------------
$script:State          = $null       # the last Read-FleetState
$script:CsvFile        = $null
$script:CsvStamp       = $null       # last write time + length, to skip re-reads
$script:Tab            = 'Mach2'     # which kiosk tab the kiosk view is showing
$script:View           = $View
$script:OnlyProblems   = $false
$script:Filter         = ''
$script:Selected       = $null       # selected host name
$script:Credential     = $Credential
$script:RestartMessage = $RestartMessage
$script:RestartSeconds = $RestartWarningSeconds
$script:MessageSeconds = 60
$script:ScreenChoice   = @{}      # host -> 'S2|NG' (the card's Screen box), or '' for all
$script:AutoScan       = [bool]$AutoScan
$script:NextScanAt     = $null
$script:ScanStartedAt  = $null
$script:ScanProgress   = $null
$script:Jobs           = New-Object System.Collections.ArrayList
$script:Run            = $null       # the running deploy / collector process
$script:Rows           = $null       # ObservableCollection of FleetRow (kiosk view)
$script:AttentionRows  = $null
$script:TargetRows     = $null       # ObservableCollection of FleetRow (deploy view)
$script:ChartBars      = $null
$script:ReportRows     = $null
$script:Product        = 'NG'        # NG | PBI | WEB
$script:ExtraTargets   = @{ NG = (New-Object System.Collections.ArrayList); PBI = (New-Object System.Collections.ArrayList); WEB = (New-Object System.Collections.ArrayList) }
$script:OverlayAction  = $null
$script:OverlayData    = @{}
$script:OverlayFieldControls = @{}   # the card's boxes, by field name
$script:ConfigWritten  = @{}         # host -> a config was written from here
$script:DetailHost     = $null
$script:Busy           = @{}         # host -> what is being done to it
$script:LiveObs        = @{}         # host -> the last live read
$script:HoldState      = @{}         # host -> hold.txt seen on the last live read
$script:Refreshing     = $false
$script:NavSetting     = $false
$script:Toast          = $null
$script:LastSnapshot   = $null       # the picture the details pane is showing
$script:ConsoleUsed    = $false      # the Activity console still holds its opening note
$script:ViewerPath     = $null       # CmRcViewer.exe, when this PC has it

# ---------------------------------------------------------------------------
# Types: rows the grids bind to (proper change notification, so a refresh
# updates the table in place instead of rebuilding it and losing the
# selection, the sort and the scroll position), and the bars of the
# seven-day chart.
# ---------------------------------------------------------------------------
if (-not ('KioskFleet.FleetRow' -as [type])) {
    Add-Type -ReferencedAssemblies PresentationCore, WindowsBase, System.Xaml -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Windows.Media;

namespace KioskFleet
{
    public class FleetRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        private void S<T>(ref T field, T value, string name)
        {
            if (object.Equals(field, value)) return;
            field = value;
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(name));
        }

        private string _host = ""; public string Host { get { return _host; } set { S(ref _host, value, "Host"); } }
        private string _location = ""; public string Location { get { return _location; } set { S(ref _location, value, "Location"); } }
        private string _type = ""; public string Type { get { return _type; } set { S(ref _type, value, "Type"); } }
        private string _tab = ""; public string Tab { get { return _tab; } set { S(ref _tab, value, "Tab"); } }
        private string _status = ""; public string Status { get { return _status; } set { S(ref _status, value, "Status"); } }
        private string _severity = ""; public string Severity { get { return _severity; } set { S(ref _severity, value, "Severity"); } }
        private string _watchdog = ""; public string Watchdog { get { return _watchdog; } set { S(ref _watchdog, value, "Watchdog"); } }
        private string _logAge = ""; public string LogAge { get { return _logAge; } set { S(ref _logAge, value, "LogAge"); } }
        private string _agent = ""; public string Agent { get { return _agent; } set { S(ref _agent, value, "Agent"); } }
        private string _uptime = ""; public string Uptime { get { return _uptime; } set { S(ref _uptime, value, "Uptime"); } }
        private string _reboots = ""; public string Reboots { get { return _reboots; } set { S(ref _reboots, value, "Reboots"); } }
        private string _spark = ""; public string Spark { get { return _spark; } set { S(ref _spark, value, "Spark"); } }
        private string _launcher = ""; public string Launcher { get { return _launcher; } set { S(ref _launcher, value, "Launcher"); } }
        private string _forText = ""; public string ForText { get { return _forText; } set { S(ref _forText, value, "ForText"); } }
        private string _account = ""; public string Account { get { return _account; } set { S(ref _account, value, "Account"); } }
        private string _version = ""; public string Version { get { return _version; } set { S(ref _version, value, "Version"); } }
        private string _screen = ""; public string Screen { get { return _screen; } set { S(ref _screen, value, "Screen"); } }
        private string _note = ""; public string Note { get { return _note; } set { S(ref _note, value, "Note"); } }
        private int _rank = 8; public int Rank { get { return _rank; } set { S(ref _rank, value, "Rank"); } }
        private bool _attention; public bool Attention { get { return _attention; } set { S(ref _attention, value, "Attention"); } }
        private bool _selected; public bool Selected { get { return _selected; } set { S(ref _selected, value, "Selected"); } }
        private bool _busy; public bool Busy { get { return _busy; } set { S(ref _busy, value, "Busy"); } }

        private Brush _statusBrush; public Brush StatusBrush { get { return _statusBrush; } set { S(ref _statusBrush, value, "StatusBrush"); } }
        private Brush _statusBack; public Brush StatusBack { get { return _statusBack; } set { S(ref _statusBack, value, "StatusBack"); } }
        private Brush _launcherBrush; public Brush LauncherBrush { get { return _launcherBrush; } set { S(ref _launcherBrush, value, "LauncherBrush"); } }
        private Brush _accountBrush; public Brush AccountBrush { get { return _accountBrush; } set { S(ref _accountBrush, value, "AccountBrush"); } }
        private Brush _watchdogBrush; public Brush WatchdogBrush { get { return _watchdogBrush; } set { S(ref _watchdogBrush, value, "WatchdogBrush"); } }

        public object Tag { get; set; }
    }

    public class DayBar
    {
        public string Label { get; set; }
        public string Count { get; set; }
        public double BarHeight { get; set; }
        public string Tip { get; set; }
    }

    public class ReportRow
    {
        public string Name { get; set; }
        public string When { get; set; }
        public string Kind { get; set; }
        public string Path { get; set; }
    }
}
'@
}

# ---------------------------------------------------------------------------
# Palette. One frozen brush per colour: they are handed straight to rows and
# read from the UI thread, so they are created once and never changed.
# ---------------------------------------------------------------------------
# Creates a frozen WPF colour brush from a hex colour.
function New-Brush {
    param([string]$Hex)
    $b = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
    $b.Freeze()
    return $b
}

$Brush = @{
    Text      = New-Brush '#E7ECF4'
    Dim       = New-Brush '#94A0B4'
    Faint     = New-Brush '#5D6A7E'
    Accent    = New-Brush '#7BA6FF'
    Ok        = New-Brush '#4BD99B'
    Warn      = New-Brush '#F5C260'
    Crit      = New-Brush '#FF7A87'
    Info      = New-Brush '#6FD0F0'
    OkBack    = New-Brush '#123326'
    WarnBack  = New-Brush '#3A2E12'
    CritBack  = New-Brush '#3A1A1F'
    DimBack   = New-Brush '#1C2330'
    InfoBack  = New-Brush '#12293A'
    Clear     = New-Brush '#00000000'
}

# Returns the foreground/background brushes for a severity (OK, WARNING, CRITICAL, ...).
function Get-SeverityBrush {
    param([string]$Severity)
    switch ($Severity) {
        'OK'       { return @($Brush.Ok, $Brush.OkBack) }
        'CRITICAL' { return @($Brush.Crit, $Brush.CritBack) }
        'WARNING'  { return @($Brush.Warn, $Brush.WarnBack) }
        'INACTIVE' { return @($Brush.Faint, $Brush.DimBack) }
        default    { return @($Brush.Dim, $Brush.DimBack) }
    }
}

# Sparkline and glyphs, built from code points so the file stays plain ASCII.
$Spark = @([char]0x2581, [char]0x2582, [char]0x2583, [char]0x2584, [char]0x2585, [char]0x2586, [char]0x2587, [char]0x2588)
$DotGlyph = [string][char]0x00B7

# ---------------------------------------------------------------------------
# The window, in two halves: the look (colours, styles, templates) and the
# layout. Nothing is wired up in the markup - every handler is attached in
# code below, so the whole window is one file with no code-behind.
# ---------------------------------------------------------------------------
$XamlLook = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Kiosk Fleet Manager" Height="880" Width="1500" MinHeight="620" MinWidth="1080"
        WindowStartupLocation="CenterScreen"
        Background="{DynamicResource BgWindow}" Foreground="{DynamicResource FgText}"
        FontFamily="Segoe UI" FontSize="13"
        UseLayoutRounding="True" TextOptions.TextFormattingMode="Display" SnapsToDevicePixels="True">
  <Window.Resources>

    <SolidColorBrush x:Key="BgWindow" Color="#0E1116"/>
    <SolidColorBrush x:Key="BgPanel"  Color="#141922"/>
    <SolidColorBrush x:Key="BgCard"   Color="#171D27"/>
    <SolidColorBrush x:Key="BgHover"  Color="#1B2230"/>
    <SolidColorBrush x:Key="BgSel"    Color="#1E2B45"/>
    <SolidColorBrush x:Key="BgInput"  Color="#10151D"/>
    <SolidColorBrush x:Key="Line"     Color="#232B39"/>
    <SolidColorBrush x:Key="LineSoft" Color="#1B2230"/>
    <SolidColorBrush x:Key="FgText"   Color="#E7ECF4"/>
    <SolidColorBrush x:Key="FgDim"    Color="#94A0B4"/>
    <SolidColorBrush x:Key="FgFaint"  Color="#5D6A7E"/>
    <SolidColorBrush x:Key="Accent"   Color="#7BA6FF"/>
    <SolidColorBrush x:Key="AccentBg" Color="#1E2B45"/>
    <SolidColorBrush x:Key="AccentFill" Color="#3B6FD4"/>
    <SolidColorBrush x:Key="Ok"       Color="#4BD99B"/>
    <SolidColorBrush x:Key="OkBack"   Color="#123326"/>
    <SolidColorBrush x:Key="Warn"     Color="#F5C260"/>
    <SolidColorBrush x:Key="WarnBack" Color="#3A2E12"/>
    <SolidColorBrush x:Key="Crit"     Color="#FF7A87"/>
    <SolidColorBrush x:Key="CritBack" Color="#3A1A1F"/>
    <SolidColorBrush x:Key="Info"     Color="#6FD0F0"/>
    <SolidColorBrush x:Key="InfoBack" Color="#12293A"/>
    <SolidColorBrush x:Key="DimBack"  Color="#1C2330"/>

    <!-- Scrollbars: slim, dark, and out of the way. -->
    <Style x:Key="SbThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="T" Background="#39445A" CornerRadius="4" Margin="3"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="T" Property="Background" Value="#4C5A75"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <ControlTemplate x:Key="SbVertical" TargetType="ScrollBar">
      <Grid Background="Transparent" Width="11">
        <Track x:Name="PART_Track" IsDirectionReversed="True">
          <Track.Thumb><Thumb Style="{StaticResource SbThumb}"/></Track.Thumb>
          <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
          <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
        </Track>
      </Grid>
    </ControlTemplate>
    <ControlTemplate x:Key="SbHorizontal" TargetType="ScrollBar">
      <Grid Background="Transparent" Height="11">
        <Track x:Name="PART_Track">
          <Track.Thumb><Thumb Style="{StaticResource SbThumb}"/></Track.Thumb>
          <Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageRightCommand" Opacity="0" Focusable="False"/></Track.IncreaseRepeatButton>
          <Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageLeftCommand" Opacity="0" Focusable="False"/></Track.DecreaseRepeatButton>
        </Track>
      </Grid>
    </ControlTemplate>
    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Width" Value="11"/>
      <Setter Property="Template" Value="{StaticResource SbVertical}"/>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Height" Value="11"/>
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Template" Value="{StaticResource SbHorizontal}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <!-- Text -->
    <Style x:Key="H1" TargetType="TextBlock">
      <Setter Property="FontSize" Value="19"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
    </Style>
    <Style x:Key="H2" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Foreground" Value="{StaticResource FgFaint}"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
    </Style>
    <Style x:Key="Label" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource FgFaint}"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>
    <Style x:Key="Value" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="Mono" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas, Courier New"/>
      <Setter Property="Foreground" Value="{StaticResource FgDim}"/>
      <Setter Property="FontSize" Value="12"/>
    </Style>

    <!-- Cards -->
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource BgCard}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="16"/>
    </Style>

    <!-- Buttons -->
    <Style x:Key="Ghost" TargetType="Button">
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Height" Value="30"/>
      <Setter Property="Padding" Value="12,0"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="B" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource BgHover}"/>
                <Setter TargetName="B" Property="BorderBrush" Value="#33405A"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource BgSel}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{StaticResource FgFaint}"/>
                <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource LineSoft}"/>
                <Setter TargetName="B" Property="Background" Value="Transparent"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource Ghost}">
      <Setter Property="Background" Value="{StaticResource AccentFill}"/>
      <Setter Property="BorderBrush" Value="{StaticResource AccentFill}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="34"/>
    </Style>
    <Style x:Key="Danger" TargetType="Button" BasedOn="{StaticResource Ghost}">
      <Setter Property="Background" Value="#7A2530"/>
      <Setter Property="BorderBrush" Value="#7A2530"/>
      <Setter Property="Foreground" Value="#FFD9DE"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="34"/>
    </Style>
    <Style x:Key="Link" TargetType="Button" BasedOn="{StaticResource Ghost}">
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Height" Value="26"/>
      <Setter Property="Padding" Value="6,0"/>
    </Style>

    <!-- Navigation -->
    <Style x:Key="Nav" TargetType="ToggleButton">
      <Setter Property="Height" Value="36"/>
      <Setter Property="Margin" Value="0,2,0,2"/>
      <Setter Property="Foreground" Value="{StaticResource FgDim}"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Grid>
              <Border x:Name="B" CornerRadius="6" Background="Transparent" Padding="12,0"/>
              <Border x:Name="Bar" Width="3" Height="18" HorizontalAlignment="Left" CornerRadius="2"
                      Background="Transparent" Margin="0,0,0,0"/>
              <ContentPresenter Margin="12,0,10,0" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource BgHover}"/>
                <Setter Property="Foreground" Value="{StaticResource FgText}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource BgSel}"/>
                <Setter TargetName="Bar" Property="Background" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource FgText}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Chip" TargetType="ToggleButton" BasedOn="{StaticResource Nav}">
      <Setter Property="Height" Value="30"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="B" CornerRadius="6" Background="Transparent" BorderBrush="{StaticResource Line}"
                    BorderThickness="1" Padding="12,0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource BgHover}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="B" Property="Background" Value="{StaticResource AccentBg}"/>
                <Setter TargetName="B" Property="BorderBrush" Value="{StaticResource Accent}"/>
                <Setter Property="Foreground" Value="{StaticResource FgText}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Inputs -->
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource BgInput}"/>
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource AccentFill}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="PasswordBox">
      <Setter Property="Background" Value="{StaticResource BgInput}"/>
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
      <Setter Property="CaretBrush" Value="{StaticResource Accent}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="PasswordBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="{TemplateBinding VerticalContentAlignment}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="16" Height="16" CornerRadius="4" BorderThickness="1"
                      BorderBrush="{StaticResource Line}" Background="{StaticResource BgInput}" VerticalAlignment="Center">
                <Path x:Name="Tick" Data="M 2,6 L 5,10 L 12,2" Stroke="White" StrokeThickness="2"
                      Visibility="Collapsed" StrokeEndLineCap="Round" StrokeStartLineCap="Round"/>
              </Border>
              <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="{StaticResource AccentFill}"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentFill}"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Foreground" Value="{StaticResource FgFaint}"/>
                <Setter TargetName="Box" Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ProgressBar">
      <Setter Property="Height" Value="6"/>
      <Setter Property="Foreground" Value="{StaticResource Accent}"/>
      <Setter Property="Background" Value="#202836"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Border Background="{TemplateBinding Background}" CornerRadius="3">
              <Grid>
                <Rectangle x:Name="PART_Track"/>
                <Rectangle x:Name="PART_Indicator" HorizontalAlignment="Left" Fill="{TemplateBinding Foreground}" RadiusX="3" RadiusY="3"/>
              </Grid>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Tables -->
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RowBackground" Value="Transparent"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
      <Setter Property="RowHeight" Value="30"/>
      <Setter Property="ColumnHeaderHeight" Value="28"/>
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="VerticalGridLinesBrush" Value="Transparent"/>
      <Setter Property="HorizontalGridLinesBrush" Value="Transparent"/>
      <Setter Property="ScrollViewer.CanContentScroll" Value="True"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource FgFaint}"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,4,8,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="SeparatorBrush" Value="Transparent"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
      <Setter Property="BorderBrush" Value="{StaticResource LineSoft}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="{StaticResource BgHover}"/>
        </Trigger>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="{StaticResource BgSel}"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="Transparent" Padding="8,0" SnapsToDevicePixels="True">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="Pill" TargetType="Border">
      <Setter Property="CornerRadius" Value="4"/>
      <Setter Property="Padding" Value="7,2"/>
      <Setter Property="HorizontalAlignment" Value="Left"/>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="#0B0E14"/>
      <Setter Property="Foreground" Value="{StaticResource FgText}"/>
      <Setter Property="BorderBrush" Value="{StaticResource Line}"/>
      <Setter Property="Padding" Value="8,5"/>
    </Style>
  </Window.Resources>
'@

$XamlMain = @'
  <Grid>
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>

      <!-- ============================ header ============================ -->
      <Border Grid.Row="0" Background="{StaticResource BgPanel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1">
        <Grid Margin="16,10,16,10">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>

          <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
            <Border Width="28" Height="28" CornerRadius="7" Background="{StaticResource AccentBg}">
              <TextBlock Text="&#x25A0;" Foreground="{StaticResource Accent}" FontSize="14"
                         HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <StackPanel Margin="10,0,0,0" VerticalAlignment="Center">
              <TextBlock Text="KIOSK FLEET MANAGER" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource FgText}"/>
              <TextBlock x:Name="SubTitle" Text="Mach2 Launcher NG + PBI Launcher" FontSize="11" Foreground="{StaticResource FgFaint}"/>
            </StackPanel>
          </StackPanel>

          <Border x:Name="HeadlinePill" Grid.Column="1" HorizontalAlignment="Center" VerticalAlignment="Center"
                  CornerRadius="7" Padding="16,7" Background="{StaticResource OkBack}">
            <StackPanel Orientation="Horizontal">
              <Ellipse x:Name="HeadlineDot" Width="9" Height="9" Fill="{StaticResource Ok}" VerticalAlignment="Center"/>
              <TextBlock x:Name="HeadlineText" Margin="10,0,0,0" FontSize="14" FontWeight="SemiBold"
                         Foreground="{StaticResource Ok}" Text="READING THE FLEET"/>
            </StackPanel>
          </Border>

          <StackPanel Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
            <StackPanel x:Name="ScanPanel" Orientation="Horizontal" VerticalAlignment="Center"
                        Margin="0,0,18,0" Visibility="Collapsed">
              <TextBlock x:Name="ScanText" Text="scanning" FontSize="11" Foreground="{StaticResource Accent}"
                         VerticalAlignment="Center" Margin="0,0,8,0"/>
              <ProgressBar x:Name="ScanBar" Width="130" Height="6" Minimum="0" Maximum="100" Value="0" VerticalAlignment="Center"/>
            </StackPanel>
            <TextBlock x:Name="FreshText" Text="" FontSize="12" Foreground="{StaticResource FgDim}" VerticalAlignment="Center"/>
            <Border Width="1" Height="16" Background="{StaticResource Line}" Margin="14,0"/>
            <TextBlock x:Name="ClockText" Text="" FontSize="12" Foreground="{StaticResource FgFaint}" VerticalAlignment="Center"/>
          </StackPanel>
        </Grid>
      </Border>

      <!-- ====================== navigation + views ====================== -->
      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="210"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <Border Grid.Column="0" Background="{StaticResource BgPanel}" BorderBrush="{StaticResource Line}" BorderThickness="0,0,1,0">
          <DockPanel Margin="10,14,10,12">
            <StackPanel DockPanel.Dock="Bottom">
              <Border Height="1" Background="{StaticResource Line}" Margin="2,10,2,12"/>
              <Button x:Name="BtnScan" Style="{StaticResource Ghost}" Content="Scan now" Margin="0,0,0,8" Height="32"/>
              <ToggleButton x:Name="BtnAuto" Style="{StaticResource Chip}" Height="32" Margin="0" Content="Auto-scan"/>
              <TextBlock x:Name="AutoText" Style="{StaticResource Label}" Margin="4,8,0,0" TextWrapping="Wrap" Text="off"/>
            </StackPanel>

            <StackPanel>
              <TextBlock Text="FLEET" Style="{StaticResource H2}" Margin="12,2,0,6"/>
              <ToggleButton x:Name="NavOverview" Style="{StaticResource Nav}">
                <Grid>
                  <TextBlock Text="Overview" VerticalAlignment="Center"/>
                </Grid>
              </ToggleButton>
              <ToggleButton x:Name="NavMach2" Style="{StaticResource Nav}">
                <Grid>
                  <TextBlock Text="Mach2" VerticalAlignment="Center"/>
                  <Border x:Name="BadgeMach2Box" HorizontalAlignment="Right" VerticalAlignment="Center"
                          Style="{StaticResource Pill}" Background="{StaticResource CritBack}" Visibility="Collapsed">
                    <TextBlock x:Name="BadgeMach2" FontSize="11" Foreground="{StaticResource Crit}" Text="0"/>
                  </Border>
                </Grid>
              </ToggleButton>
              <ToggleButton x:Name="NavPbi" Style="{StaticResource Nav}">
                <Grid>
                  <TextBlock Text="Power BI" VerticalAlignment="Center"/>
                  <Border x:Name="BadgePbiBox" HorizontalAlignment="Right" VerticalAlignment="Center"
                          Style="{StaticResource Pill}" Background="{StaticResource CritBack}" Visibility="Collapsed">
                    <TextBlock x:Name="BadgePbi" FontSize="11" Foreground="{StaticResource Crit}" Text="0"/>
                  </Border>
                </Grid>
              </ToggleButton>
              <ToggleButton x:Name="NavWeb" Style="{StaticResource Nav}" Visibility="Collapsed">
                <Grid>
                  <TextBlock Text="Web pages" VerticalAlignment="Center"/>
                  <Border x:Name="BadgeWebBox" HorizontalAlignment="Right" VerticalAlignment="Center"
                          Style="{StaticResource Pill}" Background="{StaticResource CritBack}" Visibility="Collapsed">
                    <TextBlock x:Name="BadgeWeb" FontSize="11" Foreground="{StaticResource Crit}" Text="0"/>
                  </Border>
                </Grid>
              </ToggleButton>
              <ToggleButton x:Name="NavOther" Style="{StaticResource Nav}" Visibility="Collapsed">
                <Grid>
                  <TextBlock Text="Other" VerticalAlignment="Center"/>
                  <Border x:Name="BadgeOtherBox" HorizontalAlignment="Right" VerticalAlignment="Center"
                          Style="{StaticResource Pill}" Background="{StaticResource CritBack}" Visibility="Collapsed">
                    <TextBlock x:Name="BadgeOther" FontSize="11" Foreground="{StaticResource Crit}" Text="0"/>
                  </Border>
                </Grid>
              </ToggleButton>

              <TextBlock Text="MANAGE" Style="{StaticResource H2}" Margin="12,18,0,6"/>
              <ToggleButton x:Name="NavDeploy" Style="{StaticResource Nav}">
                <Grid><TextBlock Text="Deploy" VerticalAlignment="Center"/></Grid>
              </ToggleButton>
              <ToggleButton x:Name="NavActivity" Style="{StaticResource Nav}">
                <Grid>
                  <TextBlock Text="Activity" VerticalAlignment="Center"/>
                  <Border x:Name="BadgeRunBox" HorizontalAlignment="Right" VerticalAlignment="Center"
                          Style="{StaticResource Pill}" Background="{StaticResource AccentBg}" Visibility="Collapsed">
                    <TextBlock x:Name="BadgeRun" FontSize="11" Foreground="{StaticResource Accent}" Text="running"/>
                  </Border>
                </Grid>
              </ToggleButton>
            </StackPanel>
          </DockPanel>
        </Border>

        <Grid Grid.Column="1">

          <!-- ========================= overview ========================= -->
          <Grid x:Name="ViewOverview" Margin="18">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <TextBlock Grid.Row="0" Text="Overview" Style="{StaticResource H1}" Margin="0,0,0,14"/>

            <UniformGrid Grid.Row="1" Rows="1" Margin="0,0,0,16">
              <Border Style="{StaticResource Card}" Margin="0,0,12,0">
                <StackPanel>
                  <TextBlock Text="KIOSKS" Style="{StaticResource H2}" Margin="0,0,0,6"/>
                  <TextBlock x:Name="StatTotal" Text="-" FontSize="28" FontWeight="SemiBold" Foreground="{StaticResource FgText}"/>
                  <TextBlock x:Name="StatTotalNote" Style="{StaticResource Label}" Text=""/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="0,0,12,0">
                <StackPanel>
                  <TextBlock Text="NEED ATTENTION" Style="{StaticResource H2}" Margin="0,0,0,6"/>
                  <TextBlock x:Name="StatAttention" Text="-" FontSize="28" FontWeight="SemiBold" Foreground="{StaticResource Ok}"/>
                  <TextBlock x:Name="StatAttentionNote" Style="{StaticResource Label}" Text=""/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="0,0,12,0">
                <StackPanel>
                  <TextBlock Text="REBOOTS 24H" Style="{StaticResource H2}" Margin="0,0,0,6"/>
                  <TextBlock x:Name="StatReboots" Text="-" FontSize="28" FontWeight="SemiBold" Foreground="{StaticResource FgText}"/>
                  <TextBlock x:Name="StatRebootsNote" Style="{StaticResource Label}" Text=""/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}" Margin="0,0,12,0">
                <StackPanel>
                  <TextBlock Text="SCREEN EVENTS 24H" Style="{StaticResource H2}" Margin="0,0,0,6"/>
                  <TextBlock x:Name="StatEpisodes" Text="-" FontSize="28" FontWeight="SemiBold" Foreground="{StaticResource FgText}"/>
                  <TextBlock x:Name="StatEpisodesNote" Style="{StaticResource Label}" Text="white or dark screens"/>
                </StackPanel>
              </Border>
              <Border Style="{StaticResource Card}">
                <StackPanel>
                  <TextBlock Text="ON THE NEW LAUNCHERS" Style="{StaticResource H2}" Margin="0,0,0,6"/>
                  <TextBlock x:Name="StatLaunchers" Text="-" FontSize="28" FontWeight="SemiBold" Foreground="{StaticResource Accent}"/>
                  <TextBlock x:Name="StatLaunchersNote" Style="{StaticResource Label}" Text=""/>
                </StackPanel>
              </Border>
            </UniformGrid>

            <Grid Grid.Row="2">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="400"/>
              </Grid.ColumnDefinitions>

              <Border Style="{StaticResource Card}" Margin="0,0,16,0" Padding="0">
                <DockPanel>
                  <Grid DockPanel.Dock="Top" Margin="16,14,16,10">
                    <TextBlock x:Name="AttentionTitle" Text="NEEDS ATTENTION" Style="{StaticResource H2}" Margin="0"/>
                    <TextBlock x:Name="AttentionHint" Style="{StaticResource Label}" HorizontalAlignment="Right"
                               Text="double-click a kiosk to open it"/>
                  </Grid>
                  <Grid>
                    <DataGrid x:Name="AttentionGrid" Margin="6,0,6,8">
                      <DataGrid.Columns>
                        <DataGridTemplateColumn Header="KIOSK" Width="170" SortMemberPath="Host">
                          <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                              <StackPanel Orientation="Horizontal">
                                <Ellipse Width="7" Height="7" Fill="{Binding StatusBrush}" VerticalAlignment="Center"/>
                                <TextBlock Text="{Binding Host}" Margin="8,0,0,0" FontWeight="SemiBold"/>
                              </StackPanel>
                            </DataTemplate>
                          </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="LOCATION" Binding="{Binding Location}" Width="150"/>
                        <DataGridTextColumn Header="TYPE" Binding="{Binding Tab}" Width="80"/>
                        <DataGridTemplateColumn Header="STATUS" Width="170" SortMemberPath="Rank">
                          <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                              <Border Style="{StaticResource Pill}" Background="{Binding StatusBack}">
                                <TextBlock Text="{Binding Status}" Foreground="{Binding StatusBrush}" FontSize="11"/>
                              </Border>
                            </DataTemplate>
                          </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="WHAT THE LAST SCAN SAW" Binding="{Binding Note}" Width="*">
                          <DataGridTextColumn.ElementStyle>
                            <Style TargetType="TextBlock">
                              <Setter Property="Foreground" Value="{StaticResource FgDim}"/>
                              <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                            </Style>
                          </DataGridTextColumn.ElementStyle>
                        </DataGridTextColumn>
                      </DataGrid.Columns>
                    </DataGrid>
                    <TextBlock x:Name="AttentionEmpty" Text="Nothing needs attention." Foreground="{StaticResource Ok}"
                               HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                  </Grid>
                </DockPanel>
              </Border>

              <Grid Grid.Column="1">
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                  <StackPanel>
                    <TextBlock Text="REBOOTS, LAST 7 DAYS" Style="{StaticResource H2}"/>
                    <ItemsControl x:Name="ChartBars" Height="120">
                      <ItemsControl.ItemsPanel>
                        <ItemsPanelTemplate><UniformGrid Rows="1"/></ItemsPanelTemplate>
                      </ItemsControl.ItemsPanel>
                      <ItemsControl.ItemTemplate>
                        <DataTemplate>
                          <Grid Margin="5,0" ToolTip="{Binding Tip}">
                            <Grid.RowDefinitions>
                              <RowDefinition Height="*"/>
                              <RowDefinition Height="Auto"/>
                            </Grid.RowDefinitions>
                            <StackPanel Grid.Row="0" VerticalAlignment="Bottom">
                              <TextBlock Text="{Binding Count}" HorizontalAlignment="Center"
                                         FontSize="11" Foreground="{StaticResource FgDim}" Margin="0,0,0,4"/>
                              <Border Height="{Binding BarHeight}" Background="{StaticResource AccentFill}"
                                      CornerRadius="3" MinHeight="2"/>
                            </StackPanel>
                            <TextBlock Grid.Row="1" Text="{Binding Label}" HorizontalAlignment="Center"
                                       FontSize="10" Foreground="{StaticResource FgFaint}" Margin="0,6,0,0"/>
                          </Grid>
                        </DataTemplate>
                      </ItemsControl.ItemTemplate>
                    </ItemsControl>
                  </StackPanel>
                </Border>

                <Border Grid.Row="1" Style="{StaticResource Card}">
                  <DockPanel>
                    <TextBlock DockPanel.Dock="Top" Text="COLLECTION" Style="{StaticResource H2}"/>
                    <StackPanel x:Name="CollectorPanel"/>
                  </DockPanel>
                </Border>
              </Grid>
            </Grid>
          </Grid>

          <!-- ======================= kiosk tables ======================= -->
          <Grid x:Name="ViewKiosks" Margin="18" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="0,0,0,14">
              <StackPanel Orientation="Horizontal">
                <TextBlock x:Name="KioskTitle" Text="Mach2" Style="{StaticResource H1}"/>
                <TextBlock x:Name="KioskSubtitle" Style="{StaticResource Label}" VerticalAlignment="Bottom" Margin="10,0,0,3"/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Grid Width="200" Height="30" Margin="0,0,8,0">
                  <TextBox x:Name="FilterBox" VerticalContentAlignment="Center"
                           ToolTip="Filter by kiosk name, location, status or launcher"/>
                  <TextBlock x:Name="FilterHint" Text="Filter" Foreground="{StaticResource FgFaint}" FontSize="12"
                             Margin="10,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                </Grid>
                <ToggleButton x:Name="BtnOnlyProblems" Style="{StaticResource Chip}" Content="Only problems"/>
                <Button x:Name="BtnDeploySelected" Style="{StaticResource Ghost}" Content="Deploy..." Margin="8,0,0,0"
                        ToolTip="Open Deploy for this kind of kiosk"/>
              </StackPanel>
            </Grid>

            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="360"/>
              </Grid.ColumnDefinitions>

              <Border Style="{StaticResource Card}" Padding="0" Margin="0,0,16,0">
                <Grid>
                  <DataGrid x:Name="KioskGrid" Margin="6,6,6,8">
                    <DataGrid.Columns>
                      <DataGridTemplateColumn Header="KIOSK" Width="126" SortMemberPath="Host">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate>
                            <StackPanel Orientation="Horizontal">
                              <Ellipse Width="7" Height="7" Fill="{Binding StatusBrush}" VerticalAlignment="Center"/>
                              <TextBlock Text="{Binding Host}" Margin="8,0,0,0" FontWeight="SemiBold"/>
                            </StackPanel>
                          </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="TYPE" Binding="{Binding Type}" Width="120"/>
                      <DataGridTextColumn Header="LOCATION" Binding="{Binding Location}" Width="*" MinWidth="90"/>
                      <DataGridTemplateColumn Header="STATUS" Width="115" SortMemberPath="Rank">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate>
                            <Border Style="{StaticResource Pill}" Background="{Binding StatusBack}">
                              <TextBlock Text="{Binding Status}" Foreground="{Binding StatusBrush}" FontSize="11"/>
                            </Border>
                          </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTemplateColumn Header="LAUNCHER" Width="92" SortMemberPath="Launcher">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate>
                            <TextBlock Text="{Binding Launcher}" Foreground="{Binding LauncherBrush}" TextTrimming="CharacterEllipsis"/>
                          </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="FOR" Binding="{Binding ForText}" Width="44"/>
                      <DataGridTextColumn Header="SCREEN" Binding="{Binding Screen}" Width="62"/>
                      <DataGridTemplateColumn Header="SIGNED IN AS" Width="1.8*" MinWidth="140" SortMemberPath="Account">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate>
                            <TextBlock Text="{Binding Account}" Foreground="{Binding AccountBrush}" TextTrimming="CharacterEllipsis"/>
                          </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="VER" Binding="{Binding Version}" Width="52"/>
                      <DataGridTemplateColumn Header="WATCHDOG" Width="78" SortMemberPath="Watchdog">
                        <DataGridTemplateColumn.CellTemplate>
                          <DataTemplate>
                            <TextBlock Text="{Binding Watchdog}" Foreground="{Binding WatchdogBrush}"/>
                          </DataTemplate>
                        </DataGridTemplateColumn.CellTemplate>
                      </DataGridTemplateColumn>
                      <DataGridTextColumn Header="LOG" Binding="{Binding LogAge}" Width="58"/>
                      <DataGridTextColumn Header="AGENT" Binding="{Binding Agent}" Width="56"/>
                      <DataGridTextColumn Header="UPTIME" Binding="{Binding Uptime}" Width="60"/>
                      <DataGridTextColumn Header="REB" Binding="{Binding Reboots}" Width="46"/>
                      <DataGridTextColumn Header="7 DAYS" Binding="{Binding Spark}" Width="58" FontFamily="Cascadia Mono, Consolas"/>
                    </DataGrid.Columns>
                  </DataGrid>
                  <TextBlock x:Name="KioskEmpty" Text="" Foreground="{StaticResource FgDim}"
                             HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                </Grid>
              </Border>

              <Border Grid.Column="1" Style="{StaticResource Card}" Padding="0">
                <Grid>
                  <TextBlock x:Name="DetailEmpty" Text="Select a kiosk" Foreground="{StaticResource FgFaint}"
                             HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  <DockPanel x:Name="DetailRoot" Visibility="Collapsed">
                    <Border DockPanel.Dock="Top" Padding="16,14,16,12" BorderBrush="{StaticResource Line}" BorderThickness="0,0,0,1">
                      <Grid>
                        <StackPanel>
                          <TextBlock x:Name="DetailHostText" Text="" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource FgText}"/>
                          <TextBlock x:Name="DetailSubText" Style="{StaticResource Label}" Margin="0,2,0,0"/>
                        </StackPanel>
                        <Border x:Name="DetailPill" Style="{StaticResource Pill}" HorizontalAlignment="Right" VerticalAlignment="Top"
                                Background="{StaticResource DimBack}">
                          <TextBlock x:Name="DetailPillText" Text="" FontSize="11" Foreground="{StaticResource FgDim}"/>
                        </Border>
                      </Grid>
                    </Border>

                    <Border DockPanel.Dock="Bottom" Padding="12,10,12,12" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
                      <StackPanel>
                        <TextBlock Text="KIOSK" Style="{StaticResource H2}" Margin="2,0,0,6"/>
                        <WrapPanel>
                          <Button x:Name="BtnRestart" Style="{StaticResource Ghost}" Content="Restart..." Margin="0,0,8,8"/>
                          <Button x:Name="BtnRemote" Style="{StaticResource Ghost}" Content="Remote control" Margin="0,0,8,8"/>
                          <Button x:Name="BtnMessage" Style="{StaticResource Ghost}" Content="Message..." Margin="0,0,8,8"/>
                          <Button x:Name="BtnOpenShare" Style="{StaticResource Ghost}" Content="Open share" Margin="0,0,8,8"/>
                        </WrapPanel>
                        <TextBlock x:Name="LauncherActionsTitle" Text="LAUNCHER" Style="{StaticResource H2}" Margin="2,6,0,6"/>
                        <DockPanel x:Name="ScreenPickPanel" Margin="0,0,8,8">
                          <TextBlock Text="Screen" Style="{StaticResource Label}" VerticalAlignment="Center" Margin="2,0,10,0"/>
                          <ComboBox x:Name="ScreenPick" Height="28" MinWidth="220" HorizontalAlignment="Left"
                                    ToolTip="What the launcher buttons act on: every screen, or just one"/>
                        </DockPanel>
                        <WrapPanel x:Name="LauncherActions">
                          <Button x:Name="BtnLive" Style="{StaticResource Ghost}" Content="Read live" Margin="0,0,8,8"/>
                          <Button x:Name="BtnSnapshot" Style="{StaticResource Ghost}" Content="Screenshot" Margin="0,0,8,8"/>
                          <Button x:Name="BtnReload" Style="{StaticResource Ghost}" Content="Reload" Margin="0,0,8,8"/>
                          <Button x:Name="BtnRelaunch" Style="{StaticResource Ghost}" Content="Restart browser" Margin="0,0,8,8"/>
                          <Button x:Name="BtnHold" Style="{StaticResource Ghost}" Content="Hold" Margin="0,0,8,8"/>
                          <Button x:Name="BtnStopLauncher" Style="{StaticResource Ghost}" Content="Stop" Margin="0,0,8,8"/>
                          <Button x:Name="BtnLog" Style="{StaticResource Ghost}" Content="Log" Margin="0,0,8,8"/>
                          <Button x:Name="BtnConfig" Style="{StaticResource Ghost}" Content="Config..." Margin="0,0,8,8"/>
                          <Button x:Name="BtnAddScreen" Style="{StaticResource Ghost}" Content="Add screen..." Margin="0,0,8,8"/>
                          <Button x:Name="BtnPassword" Style="{StaticResource Ghost}" Content="Password..." Margin="0,0,8,8"/>
                          <Button x:Name="BtnDeployThis" Style="{StaticResource Ghost}" Content="Deploy..." Margin="0,0,8,8"/>
                        </WrapPanel>
                      </StackPanel>
                    </Border>

                    <ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
                      <StackPanel Margin="16,12,16,12">
                        <StackPanel x:Name="DetailPanel"/>
                        <Border x:Name="SnapshotCard" Visibility="Collapsed" Margin="0,12,0,0"
                                Background="{StaticResource BgInput}" BorderBrush="{StaticResource Line}"
                                BorderThickness="1" CornerRadius="6" Padding="8">
                          <StackPanel>
                            <Image x:Name="SnapshotImage" Stretch="Uniform" MaxHeight="220"/>
                            <TextBlock x:Name="SnapshotCaption" Style="{StaticResource Label}" Margin="0,8,0,0" TextWrapping="Wrap"/>
                            <Button x:Name="BtnOpenSnapshot" Style="{StaticResource Link}" Content="open the picture" HorizontalAlignment="Left" Margin="0,4,0,0"/>
                          </StackPanel>
                        </Border>
                      </StackPanel>
                    </ScrollViewer>
                  </DockPanel>
                </Grid>
              </Border>
            </Grid>
          </Grid>
'@

$XamlMore = @'
          <!-- ========================== deploy ========================== -->
          <Grid x:Name="ViewDeploy" Margin="18" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Margin="0,0,0,14">
              <TextBlock Text="Deploy" Style="{StaticResource H1}"/>
              <TextBlock Style="{StaticResource Label}" Margin="0,4,0,0"
                         Text="Pick what to install, pick the kiosks, then look at the command before it runs. A dry run changes nothing."/>
            </StackPanel>

            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="430"/>
              </Grid.ColumnDefinitions>

              <Border Style="{StaticResource Card}" Padding="0" Margin="0,0,16,0">
                <DockPanel>
                  <StackPanel DockPanel.Dock="Top" Margin="16,14,16,10">
                    <TextBlock Text="WHAT TO INSTALL" Style="{StaticResource H2}"/>
                    <WrapPanel Margin="0,0,0,12">
                      <ToggleButton x:Name="ProdNg" Style="{StaticResource Chip}" IsChecked="True" Content="Mach2 Launcher NG"/>
                      <ToggleButton x:Name="ProdPbi" Style="{StaticResource Chip}" Content="PBI Launcher"/>
                      <ToggleButton x:Name="ProdWeb" Style="{StaticResource Chip}" Content="Web Launcher"/>
                    </WrapPanel>
                    <TextBlock x:Name="ProductNote" Style="{StaticResource Label}" TextWrapping="Wrap" Margin="0,0,0,12"/>
                    <Grid>
                      <TextBlock x:Name="TargetTitle" Text="KIOSKS" Style="{StaticResource H2}" Margin="0" VerticalAlignment="Center"/>
                      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                        <Grid Width="170" Height="28" Margin="0,0,8,0">
                          <TextBox x:Name="DeployFilter" VerticalContentAlignment="Center"
                                   ToolTip="Filter by kiosk name, location or status"/>
                          <TextBlock x:Name="DeployFilterHint" Text="Filter" Foreground="{StaticResource FgFaint}" FontSize="12"
                                     Margin="10,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
                        </Grid>
                        <Button x:Name="BtnSelAll" Style="{StaticResource Ghost}" Content="All" Height="28"/>
                        <Button x:Name="BtnSelNone" Style="{StaticResource Ghost}" Content="None" Height="28"/>
                        <Button x:Name="BtnAddHost" Style="{StaticResource Ghost}" Content="Add a kiosk..." Height="28" Margin="0"
                                ToolTip="A kiosk the last scan did not see - a new one, or one that was off"/>
                      </StackPanel>
                    </Grid>
                  </StackPanel>
                  <Grid>
                    <DataGrid x:Name="DeployGrid" Margin="6,0,6,8">
                      <DataGrid.Columns>
                        <DataGridTemplateColumn Header="" Width="40" CanUserSort="False">
                          <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                              <CheckBox IsChecked="{Binding Selected, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                        HorizontalAlignment="Center"/>
                            </DataTemplate>
                          </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="KIOSK" Width="170" SortMemberPath="Host">
                          <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                              <StackPanel Orientation="Horizontal">
                                <Ellipse Width="7" Height="7" Fill="{Binding StatusBrush}" VerticalAlignment="Center"/>
                                <TextBlock Text="{Binding Host}" Margin="8,0,0,0" FontWeight="SemiBold"/>
                              </StackPanel>
                            </DataTemplate>
                          </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTextColumn Header="LOCATION" Binding="{Binding Location}" Width="150"/>
                        <DataGridTemplateColumn Header="STATUS" Width="160" SortMemberPath="Rank">
                          <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                              <Border Style="{StaticResource Pill}" Background="{Binding StatusBack}">
                                <TextBlock Text="{Binding Status}" Foreground="{Binding StatusBrush}" FontSize="11"/>
                              </Border>
                            </DataTemplate>
                          </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                        <DataGridTemplateColumn Header="RUNNING NOW" Width="*" SortMemberPath="Note">
                          <DataGridTemplateColumn.CellTemplate>
                            <DataTemplate>
                              <TextBlock Text="{Binding Note}" Foreground="{Binding LauncherBrush}" TextTrimming="CharacterEllipsis"/>
                            </DataTemplate>
                          </DataGridTemplateColumn.CellTemplate>
                        </DataGridTemplateColumn>
                      </DataGrid.Columns>
                    </DataGrid>
                    <TextBlock x:Name="DeployEmpty" Text="" Foreground="{StaticResource FgDim}"
                               HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Collapsed"/>
                  </Grid>
                </DockPanel>
              </Border>

              <Grid Grid.Column="1">
                <Grid.RowDefinitions>
                  <RowDefinition Height="Auto"/>
                  <RowDefinition Height="*"/>
                  <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <Border Style="{StaticResource Card}" Margin="0,0,0,16">
                  <StackPanel>
                    <TextBlock Text="MODE" Style="{StaticResource H2}"/>
                    <WrapPanel Margin="0,0,0,14">
                      <ToggleButton x:Name="ModeInstall" Style="{StaticResource Chip}" IsChecked="True" Content="Install / update"/>
                      <ToggleButton x:Name="ModeRollback" Style="{StaticResource Chip}" Content="Roll back"/>
                    </WrapPanel>

                    <TextBlock Text="OPTIONS" Style="{StaticResource H2}"/>
                    <CheckBox x:Name="OptRestart" Content="Restart each kiosk and wait for it" Margin="0,0,0,8"/>
                    <Grid Margin="24,0,0,10">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                      </Grid.ColumnDefinitions>
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="warning" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                        <TextBox x:Name="OptWarnSecs" Text="60" Width="48" Height="28" Margin="8,0,4,0"
                                 Padding="6,0" VerticalContentAlignment="Center" TextAlignment="Center"/>
                        <TextBlock Text="s" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                      </StackPanel>
                      <StackPanel Grid.Column="1" Orientation="Horizontal">
                        <TextBlock Text="wait up to" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                        <TextBox x:Name="OptVerifyMins" Text="12" Width="48" Height="28" Margin="8,0,4,0"
                                 Padding="6,0" VerticalContentAlignment="Center" TextAlignment="Center"/>
                        <TextBlock Text="min" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                      </StackPanel>
                    </Grid>
                    <CheckBox x:Name="OptForce" Content="Copy the files even if they are already there" Margin="0,0,0,8"/>
                    <CheckBox x:Name="OptUpdateConfig" Content="Rewrite the kiosk config from the old launcher" Margin="0,0,0,8"/>
                    <CheckBox x:Name="OptKeepLegacy" Content="Leave the old launcher in place" Margin="0,0,0,8"/>
                    <CheckBox x:Name="OptKeepWatchdog" Content="Leave the MWST watchdog task alone (testing)" Margin="0,0,0,8"/>                    <Grid Margin="0,6,0,0">
                      <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                      </Grid.ColumnDefinitions>
                      <TextBlock Text="Windows account" Style="{StaticResource Label}" VerticalAlignment="Center"/>
                      <TextBox x:Name="OptKioskUser" Grid.Column="1" Height="28" Margin="10,0,0,0" Padding="8,0"
                               VerticalContentAlignment="Center"
                               ToolTip="The account the kiosk logs on as, for the startup shortcut. Empty = the usual one for that kiosk."/>
                    </Grid>
                  </StackPanel>
                </Border>

                <Border Grid.Row="1" Style="{StaticResource Card}" Padding="16,14,16,14">
                  <DockPanel>
                    <Grid DockPanel.Dock="Top" Margin="0,0,0,8">
                      <TextBlock Text="THE COMMAND" Style="{StaticResource H2}" Margin="0" VerticalAlignment="Center"/>
                      <Button x:Name="BtnCopyCommand" Style="{StaticResource Link}" Content="copy"
                              HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0"/>
                    </Grid>
                    <TextBox x:Name="DeployPreview" IsReadOnly="True" TextWrapping="Wrap" AcceptsReturn="True"
                             FontFamily="Cascadia Mono, Consolas" FontSize="11" Foreground="{StaticResource Info}"
                             VerticalScrollBarVisibility="Auto" BorderThickness="0" Background="Transparent" Padding="0"/>
                  </DockPanel>
                </Border>

                <StackPanel Grid.Row="2" Margin="0,16,0,0">
                  <TextBlock x:Name="DeployNote" Style="{StaticResource Label}" TextWrapping="Wrap" Margin="0,0,0,10"/>
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <Button x:Name="BtnDryRun" Style="{StaticResource Ghost}" Height="36" Content="Dry run" Margin="0,0,8,0"/>
                    <Button x:Name="BtnDeployRun" Grid.Column="1" Style="{StaticResource Primary}" Content="Deploy" Height="36" Margin="0"/>
                  </Grid>
                </StackPanel>
              </Grid>
            </Grid>
          </Grid>

          <!-- ========================= activity ========================= -->
          <Grid x:Name="ViewActivity" Margin="18" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <Grid Grid.Row="0" Margin="0,0,0,14">
              <StackPanel>
                <TextBlock Text="Activity" Style="{StaticResource H1}"/>
                <TextBlock x:Name="ActivityState" Style="{StaticResource Label}" Margin="0,4,0,0" Text="Nothing is running."/>
              </StackPanel>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
                <Button x:Name="BtnStopRun" Style="{StaticResource Ghost}" Content="Stop" IsEnabled="False"/>
                <Button x:Name="BtnSaveOutput" Style="{StaticResource Ghost}" Content="Save output..."/>
                <Button x:Name="BtnClearConsole" Style="{StaticResource Ghost}" Content="Clear"/>
                <Button x:Name="BtnOpenLogs" Style="{StaticResource Ghost}" Content="Open Logs folder" Margin="0"/>
              </StackPanel>
            </Grid>

            <Border Grid.Row="1" Style="{StaticResource Card}" Padding="2">
              <TextBox x:Name="ConsoleBox" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
                       FontFamily="Cascadia Mono, Consolas" FontSize="12" Background="Transparent"
                       Foreground="{StaticResource FgDim}" BorderThickness="0" Padding="12"
                       VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
            </Border>

            <Border Grid.Row="2" Style="{StaticResource Card}" Padding="0" Margin="0,16,0,0" Height="190">
              <DockPanel>
                <TextBlock DockPanel.Dock="Top" Text="WHAT RAN BEFORE" Style="{StaticResource H2}" Margin="16,14,16,4"/>
                <DataGrid x:Name="ReportGrid" Margin="6,0,6,8">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="WHEN" Binding="{Binding When}" Width="150"/>
                    <DataGridTextColumn Header="WHAT" Binding="{Binding Kind}" Width="230"/>
                    <DataGridTextColumn Header="REPORT" Binding="{Binding Name}" Width="*"/>
                  </DataGrid.Columns>
                </DataGrid>
              </DockPanel>
            </Border>
          </Grid>

        </Grid>
      </Grid>

      <!-- ========================== status bar ========================== -->
      <Border Grid.Row="2" Background="{StaticResource BgPanel}" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
        <Grid Margin="16,6,16,6">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock x:Name="StatusLeft" Style="{StaticResource Label}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          <TextBlock x:Name="StatusMid" Grid.Column="1" Style="{StaticResource Label}" VerticalAlignment="Center" Margin="16,0"/>
          <TextBlock x:Name="StatusRight" Grid.Column="2" Style="{StaticResource Label}" VerticalAlignment="Center"/>
        </Grid>
      </Border>
    </Grid>

    <!-- ============================ overlay ============================ -->
    <Grid x:Name="Overlay" Background="#D00A0D13" Visibility="Collapsed">
      <Border Style="{StaticResource Card}" Padding="0" Width="580" MaxHeight="740"
              HorizontalAlignment="Center" VerticalAlignment="Center" Background="{StaticResource BgPanel}">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Margin="20,18,20,10">
            <TextBlock x:Name="OverlayTitle" Text="" FontSize="17" FontWeight="SemiBold" Foreground="{StaticResource FgText}"/>
            <TextBlock x:Name="OverlaySub" Style="{StaticResource Label}" Margin="0,4,0,0" TextWrapping="Wrap"/>
          </StackPanel>

          <Border DockPanel.Dock="Bottom" Padding="20,12,20,16" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0">
            <Grid>
              <TextBlock x:Name="OverlayNote" Style="{StaticResource Label}" VerticalAlignment="Center" TextWrapping="Wrap" MaxWidth="280" HorizontalAlignment="Left"/>
              <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                <Button x:Name="OverlayCancel" Style="{StaticResource Ghost}" Content="Cancel" Height="34"/>
                <Button x:Name="OverlayOk" Style="{StaticResource Primary}" Content="OK" MinWidth="120" Margin="0"/>
              </StackPanel>
            </Grid>
          </Border>

          <ScrollViewer VerticalScrollBarVisibility="Auto" MaxHeight="540">
            <StackPanel Margin="20,6,20,14">
              <TextBlock x:Name="OverlayBody" Foreground="{StaticResource FgDim}" TextWrapping="Wrap" Visibility="Collapsed"/>
              <StackPanel x:Name="OverlayFieldsPanel" Visibility="Collapsed" Margin="0,12,0,0">
                <StackPanel x:Name="OverlayFields"/>
                <ToggleButton x:Name="OverlayMore" Style="{StaticResource Chip}" Content="More settings"
                              HorizontalAlignment="Left" Margin="0,6,0,0" Visibility="Collapsed"/>
                <StackPanel x:Name="OverlayAdvanced" Visibility="Collapsed" Margin="0,12,0,0"/>
              </StackPanel>
              <StackPanel x:Name="OverlayInputPanel" Visibility="Collapsed" Margin="0,12,0,0">
                <TextBlock x:Name="OverlayInputLabel" Style="{StaticResource Label}" Margin="0,0,0,6"/>
                <TextBox x:Name="OverlayInput" Height="34" VerticalContentAlignment="Center"/>
              </StackPanel>
              <StackPanel x:Name="OverlayInput2Panel" Visibility="Collapsed" Margin="0,12,0,0">
                <TextBlock x:Name="OverlayInput2Label" Style="{StaticResource Label}" Margin="0,0,0,6"/>
                <TextBox x:Name="OverlayInput2" Width="120" HorizontalAlignment="Left" Height="30" VerticalContentAlignment="Center"/>
              </StackPanel>
              <StackPanel x:Name="OverlayPassPanel" Visibility="Collapsed" Margin="0,12,0,0">
                <TextBlock x:Name="OverlayPassLabel" Style="{StaticResource Label}" Margin="0,0,0,6" Text="Password"/>
                <PasswordBox x:Name="OverlayPass" Height="34"/>
                <TextBlock Style="{StaticResource Label}" Margin="0,10,0,6" Text="Again"/>
                <PasswordBox x:Name="OverlayPass2" Height="34"/>
              </StackPanel>
              <StackPanel x:Name="OverlayLogPanel" Visibility="Collapsed" Margin="0,14,0,0">
                <TextBox x:Name="OverlayLog" IsReadOnly="True" AcceptsReturn="True" Height="160"
                         FontFamily="Cascadia Mono, Consolas" FontSize="11" VerticalScrollBarVisibility="Auto"
                         Background="{StaticResource BgInput}" Foreground="{StaticResource FgDim}"/>
              </StackPanel>
            </StackPanel>
          </ScrollViewer>
        </DockPanel>
      </Border>
    </Grid>

    <!-- ============================= toast ============================= -->
    <Border x:Name="Toast" Visibility="Collapsed" HorizontalAlignment="Right" VerticalAlignment="Bottom"
            Margin="0,0,24,24" CornerRadius="8" Padding="16,12" Background="{StaticResource BgPanel}"
            BorderBrush="{StaticResource Line}" BorderThickness="1" MaxWidth="460">
      <StackPanel Orientation="Horizontal">
        <Ellipse x:Name="ToastDot" Width="8" Height="8" Fill="{StaticResource Ok}" VerticalAlignment="Center"/>
        <TextBlock x:Name="ToastText" Margin="10,0,0,0" Foreground="{StaticResource FgText}" TextWrapping="Wrap"/>
      </StackPanel>
    </Border>
  </Grid>
</Window>
'@

$Xaml = $XamlLook + $XamlMain + $XamlMore

# ---------------------------------------------------------------------------
# Build the window and collect every named element, so the code below can say
# $UI.HeadlineText instead of hunting through the tree.
# ---------------------------------------------------------------------------
$Window = [Windows.Markup.XamlReader]::Parse($Xaml)
$UI = @{}
foreach ($m in [regex]::Matches($Xaml, 'x:Name="([A-Za-z0-9_]+)"')) {
    $n = $m.Groups[1].Value
    $UI[$n] = $Window.FindName($n)
}

# Windows 11 draws the title bar light unless an app says otherwise; ours is
# dark, and a white bar on top of it looks like a bug. Old builds ignore this.
if (-not ('KioskFleet.Dwm' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace KioskFleet
{
    public static class Dwm
    {
        [DllImport("dwmapi.dll")]
        public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
        public static void Dark(IntPtr hwnd)
        {
            int on = 1;
            if (DwmSetWindowAttribute(hwnd, 20, ref on, 4) != 0) { DwmSetWindowAttribute(hwnd, 19, ref on, 4); }
        }
    }
}
'@
}

# ---------------------------------------------------------------------------
# When something goes wrong
#
# The window runs from a hidden console, so an error that escapes a button's
# handler used to take the whole window down with nothing on screen to say
# why. Anything that reaches the dispatcher now lands in
# Logs\fleet-manager.log with its full stack, and on screen as a toast; the
# window stays open.
# ---------------------------------------------------------------------------
$ManagerLogPath = Join-Path $LogDir 'fleet-manager.log'

# Appends an unexpected error, with where it happened, to the manager's error log.
function Write-ManagerError {
    param([string]$Where, $Problem)
    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add(('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Where))
        $ex = $(if ($Problem -is [System.Management.Automation.ErrorRecord]) { $Problem.Exception } else { $Problem })
        if ($Problem -is [System.Management.Automation.ErrorRecord] -and $Problem.ScriptStackTrace) {
            $lines.Add('  script: ' + ($Problem.ScriptStackTrace -replace "\r?\n", "`r`n          "))
        }
        $depth = 0
        while ($ex -and $depth -lt 6) {
            $lines.Add(('  {0}: {1}' -f $ex.GetType().FullName, $ex.Message))
            if ($ex -is [System.Management.Automation.IContainsErrorRecord] -and $ex.ErrorRecord -and $ex.ErrorRecord.ScriptStackTrace) {
                $lines.Add('  script: ' + ($ex.ErrorRecord.ScriptStackTrace -replace "\r?\n", "`r`n          "))
            }
            if ($ex.StackTrace) { $lines.Add('  .NET:   ' + (($ex.StackTrace -split "\r?\n" | Select-Object -First 12) -join "`r`n          ")) }
            $ex = $ex.InnerException
            $depth++
        }
        [IO.File]::AppendAllText($ManagerLogPath, (($lines -join "`r`n") + "`r`n`r`n"))
    }
    catch { }
}

$Window.Dispatcher.Add_UnhandledException({
        param($Sender, $E)
        Write-ManagerError 'unhandled in the window' $E.Exception
        $E.Handled = $true
        try {
            $msg = $E.Exception.Message
            if ($E.Exception.InnerException) { $msg = $E.Exception.InnerException.Message }
            Show-Toast ('Something went wrong: {0}  (details in Logs\fleet-manager.log)' -f $msg) 'CRITICAL' 15
        }
        catch { }
    })

$Window.Add_SourceInitialized({
        try {
            $h = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle
            [KioskFleet.Dwm]::Dark($h)
        }
        catch { }
    })

# ---------------------------------------------------------------------------
# Work that must not freeze the window
#
# Everything that touches a kiosk - reading its launcher over the share,
# dropping a control file, sending a message, restarting it - takes seconds at
# best and half a minute when the kiosk is off. It runs in a background
# runspace; the window keeps redrawing and the answer comes back to a
# callback on the UI thread. Long-running programs (the collector, the deploy
# scripts) are separate processes instead, with their output tailed into the
# Activity view.
# ---------------------------------------------------------------------------
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 4)
$script:Pool.Open()

$JobPreamble = @'
param($Ctx)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. (Join-Path $Ctx.ScriptDir 'Lib\MWST.Remote.ps1')
. (Join-Path $Ctx.ScriptDir 'Lib\MWST.KioskList.ps1')
. (Join-Path $Ctx.ScriptDir 'Lib\MWST.Message.ps1')
. (Join-Path $Ctx.ScriptDir 'Lib\PBI.Launcher.ps1')
. (Join-Path $Ctx.ScriptDir 'Lib\M2.LauncherNG.ps1')
. (Join-Path $Ctx.ScriptDir 'Lib\MWST.FleetState.ps1')
# Sends a progress line from a background job to the window.
function Say { param([string]$Text) if ($Ctx.Say) { [void]$Ctx.Say.Enqueue($Text) } }
# Opens the kiosk's C$ share with the fleet credential, or returns why it cannot.
function Open-KioskShare {
    # The kiosk's C$ with the fleet credential, or $null with a reason in
    # .Error. An open session under another name refuses a second one, but
    # the share is often readable through it anyway, so that is tried too.
    param([string]$HostName)
    $root = $Ctx.RootTemplate -f $HostName
    $out = [pscustomobject]@{ Host = $HostName; Root = $root; Drive = $null; Error = $null }
    if ($root -like '\\*') {
        $reach = Test-HostReachable -HostName $HostName
        if (-not $reach.Ok) { $out.Error = "offline: $($reach.Error)"; return $out }
        try { $out.Drive = Connect-KioskShare -Folder "$root\Users" -Credential $Ctx.Credential }
        catch { }
    }
    if (-not (Test-Path -LiteralPath "$root\Users")) {
        if ($out.Drive) { Disconnect-KioskShare -Drive $out.Drive; $out.Drive = $null }
        $out.Error = "cannot read $root"
    }
    return $out
}
# Closes a kiosk share opened by Open-KioskShare.
function Close-KioskShare { param($Share) if ($Share -and $Share.Drive) { Disconnect-KioskShare -Drive $Share.Drive } }
$LauncherFolders = [ordered]@{ NG = 'Mach2LauncherNG'; PBI = 'PbiLauncher'; WEB = 'WebLauncher' }
# Lists a kiosk's launcher screen folders (S1, S2, ...) that hold its config.
function Get-LauncherDirs {
    # Where a kiosk's launchers keep their control files and status, one
    # entry per screen folder (S1, S2, ...) that holds the kiosk's
    # <HOST>.json - and PBI Launcher's own folder, from before the screen
    # folders, as its S1. -Kind NG, PBI or WEB, or ALL for every launcher;
    # -Screen narrows it to one screen.
    param([string]$Root, [string]$Kind, [string]$HostName, [string]$Screen)
    $kinds = if ($Kind -eq 'ALL' -or -not $Kind) { @($LauncherFolders.Keys) } else { @($Kind) }
    $out = @()
    foreach ($k in $kinds) {
        $base = Join-Path $Root "Users\Public\Documents\$($LauncherFolders[$k])"
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $mine = @()
        foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^S\d+$' })) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName "$HostName.json")) {
                $mine += [pscustomobject]@{ Kind = $k; Instance = $d.Name.ToUpperInvariant(); Dir = $d.FullName; Status = (Join-Path $d.FullName 'Status') }
            }
        }
        if ($k -eq 'PBI' -and -not @($mine | Where-Object { $_.Instance -eq 'S1' }).Count -and (Test-Path -LiteralPath (Join-Path $base "$HostName.json"))) {
            $mine += [pscustomobject]@{ Kind = $k; Instance = 'S1'; Dir = $base; Status = (Join-Path $base 'Status') }
        }
        $out += $mine
    }
    if ($Screen) { $out = @($out | Where-Object { $_.Instance -eq $Screen.ToUpperInvariant() }) }
    return @($out | Sort-Object Instance, Kind)
}
# Returns the folder a screen's config goes in for a launcher.
function Get-ScreenDir {
    # The folder a screen's config goes in, for a launcher: <launcher>\S<n>,
    # or PBI Launcher's own folder where its old S1 config still lives.
    param([string]$Root, [string]$Kind, [string]$Instance, [string]$HostName)
    $base = Join-Path $Root "Users\Public\Documents\$($LauncherFolders[$Kind])"
    if ($Kind -eq 'PBI' -and $Instance -eq 'S1' -and -not (Test-Path -LiteralPath (Join-Path $base "S1\$HostName.json")) -and (Test-Path -LiteralPath (Join-Path $base "$HostName.json"))) { return $base }
    return (Join-Path $base $Instance)
}
# Reads a JSON file from a kiosk, or $null if missing or unreadable.
function Read-KioskJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return @(ConvertFrom-Json -InputObject (Read-SharedText -Path $Path))[0] } catch { return $null }
}
# Waits for the launcher to delete (act on) a control file.
function Wait-ControlFileTaken {
    # The launcher deletes a control file when it acts on it; hold.txt is
    # meant to stay, so it is never waited for.
    param([string]$Path, [int]$Seconds = 20)
    if ((Split-Path -Leaf $Path) -eq 'hold.txt') { return $true }
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}
'@

# Runs a script block in a background runspace and calls -Done on the UI thread when it ends.
function Start-FleetJob {
    <#
        Runs $Body in a background runspace. $Context is handed over as $Ctx
        (ScriptDir, the credential and the share template are always in it);
        Say inside the job puts a line on a queue that -OnSay receives here.
        -Done is called on the UI thread with the job's output, a message if
        anything went wrong, and the same $Ctx.

        The callbacks get their context that way rather than by closing over
        it: a PowerShell scriptblock does not keep the variables of the
        function that made it, so a -Done written as { ... $Kiosk.Host ... }
        would quietly act on nothing at all.
    #>
    param(
        [Parameter(Mandatory)][scriptblock]$Body,
        [hashtable]$Context = @{},
        [scriptblock]$Done,
        [scriptblock]$OnSay,
        [string]$Name = 'work'
    )

    $ctx = @{
        ScriptDir    = $ScriptDir
        RootTemplate = $KioskRootTemplate
        Credential   = $script:Credential
        Say          = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
    }
    foreach ($k in $Context.Keys) { $ctx[$k] = $Context[$k] }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($JobPreamble + "`r`n" + $Body.ToString())
    [void]$ps.AddArgument($ctx)

    $job = [pscustomobject]@{
        Name = $Name; Ps = $ps; Handle = $null; Done = $Done; OnSay = $OnSay; Ctx = $ctx; Started = Get-Date
    }
    $job.Handle = $ps.BeginInvoke()
    [void]$script:Jobs.Add($job)
    return $job
}

# Returns the last value a background job put out.
function Get-JobValue {
    # A job's answer: the last thing it put out.
    param($Result)
    $items = @($Result | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return $null }
    return $items[$items.Count - 1]
}

# Passes on background jobs' messages and runs the callbacks of finished jobs.
function Update-Jobs {
    $finished = @()
    foreach ($j in @($script:Jobs)) {
        while ($j.Ctx.Say.Count -gt 0) {
            $line = $j.Ctx.Say.Dequeue()
            if ($j.OnSay) { & $j.OnSay ([string]$line) }
        }
        if ($j.Handle.IsCompleted) { $finished += $j }
    }
    foreach ($j in $finished) {
        $script:Jobs.Remove($j)
        $result = $null
        $err = $null
        try { $result = $j.Ps.EndInvoke($j.Handle) }
        catch { $err = $_.Exception.Message }
        if (-not $err -and $j.Ps.Streams.Error.Count -gt 0) {
            $err = (@($j.Ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ')
        }
        while ($j.Ctx.Say.Count -gt 0) {
            $line = $j.Ctx.Say.Dequeue()
            if ($j.OnSay) { & $j.OnSay ([string]$line) }
        }
        try { $j.Ps.Dispose() } catch { }
        if ($j.Done) {
            try { & $j.Done $result $err $j.Ctx }
            catch { Show-Toast ("Something went wrong afterwards: {0}" -f $_.Exception.Message) 'CRITICAL' }
        }
    }
}

# Tells whether an action is already running for a kiosk.
function Test-HostBusy {
    param([string]$HostName)
    return ($script:Busy.ContainsKey($HostName))
}

# Marks a kiosk as busy (or free) and updates its row.
function Set-HostBusy {
    param([string]$HostName, [string]$What)
    if ($What) { $script:Busy[$HostName] = $What } else { [void]$script:Busy.Remove($HostName) }
    $row = $null
    if ($script:Rows) { $row = @($script:Rows | Where-Object { $_.Host -eq $HostName })[0] }
    if ($row) { $row.Busy = [bool]$What }
    if ($HostName -eq $script:DetailHost) { Update-ActionButtons }
}

# ---------------------------------------------------------------------------
# Credentials - asked for only when something actually needs them
# ---------------------------------------------------------------------------
if (-not ([System.Management.Automation.PSTypeName]'MwstCredUI').Type) {
    Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class MwstCredUI
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct CREDUI_INFO
    {
        public int cbSize;
        public IntPtr hwndParent;
        public string pszMessageText;
        public string pszCaptionText;
        public IntPtr hbmBanner;
    }

    [Flags]
    public enum CREDUI_FLAGS
    {
        GENERIC_CREDENTIALS = 0x40000,
        ALWAYS_SHOW_UI = 0x80,
        DO_NOT_PERSIST = 0x2
    }

    [DllImport("credui.dll", CharSet = CharSet.Unicode)]
    public static extern int CredUIPromptForCredentials(
        ref CREDUI_INFO pUiInfo,
        string pszTargetName,
        IntPtr Reserved,
        int dwAuthError,
        StringBuilder pszUserName,
        int ulUserNameMaxChars,
        StringBuilder pszPassword,
        int ulPasswordMaxChars,
        ref bool pfSave,
        CREDUI_FLAGS dwFlags);
}
'@
}

# Shows the Windows credential dialog for the kiosk-admin account.
function Show-CredentialPrompt {
    param(
        [string]$Caption = 'Kiosk Fleet Manager',
        [string]$Message = 'Enter the AD account with admin rights on the kiosks'
    )

    $info = New-Object MwstCredUI+CREDUI_INFO
    $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][MwstCredUI+CREDUI_INFO])
    try { $info.hwndParent = (New-Object System.Windows.Interop.WindowInteropHelper($Window)).Handle }
    catch { $info.hwndParent = [IntPtr]::Zero }
    $info.pszCaptionText = $Caption
    $info.pszMessageText = $Message
    $info.hbmBanner = [IntPtr]::Zero

    $userSb = New-Object System.Text.StringBuilder(256)
    [void]$userSb.Append("$env:USERDOMAIN\")
    $passSb = New-Object System.Text.StringBuilder(256)
    $save = $false

    $flags = [MwstCredUI+CREDUI_FLAGS]::GENERIC_CREDENTIALS -bor `
             [MwstCredUI+CREDUI_FLAGS]::ALWAYS_SHOW_UI -bor `
             [MwstCredUI+CREDUI_FLAGS]::DO_NOT_PERSIST

    $ret = [MwstCredUI]::CredUIPromptForCredentials(
        [ref]$info, 'MwstFleet', [IntPtr]::Zero, 0,
        $userSb, 256, $passSb, 256, [ref]$save, $flags)

    if ($ret -eq 1223) { return $null }   # cancelled
    if ($ret -ne 0) { throw "CredUIPromptForCredentials returned $ret" }

    return New-Object System.Management.Automation.PSCredential(
        $userSb.ToString(), (ConvertTo-SecureString $passSb.ToString() -AsPlainText -Force))
}

# Returns the kiosk-admin credential: the saved one, else asks once per session.
function Get-FleetCredential {
    # The saved DPAPI credential first - the collector already uses it, so
    # there is usually nothing to type. Otherwise ask, once, and keep it for
    # as long as the window is open.
    if ($script:Credential) { return $script:Credential }

    if (Test-Path -LiteralPath $CredentialFile) {
        try {
            $script:Credential = Import-StoredCredential -Path $CredentialFile
            return $script:Credential
        }
        catch { Show-Toast ("The saved credential could not be read: {0}" -f $_.Exception.Message) 'WARNING' }
    }

    try { $script:Credential = Show-CredentialPrompt }
    catch { Show-Toast ("The credential dialog failed: {0}" -f $_.Exception.Message) 'CRITICAL' }
    return $script:Credential
}

# ---------------------------------------------------------------------------
# Small pieces of window: the toast, and the modal card
# ---------------------------------------------------------------------------
# Shows a short coloured notification at the bottom of the window.
function Show-Toast {
    param([string]$Text, [string]$Severity = 'OK', [int]$Seconds = 6)

    $pair = Get-SeverityBrush $Severity
    $UI.ToastDot.Fill = $pair[0]
    $UI.ToastText.Text = $Text
    $UI.Toast.Visibility = 'Visible'

    if ($script:Toast) { $script:Toast.Stop() }
    $script:Toast = New-Object System.Windows.Threading.DispatcherTimer
    $script:Toast.Interval = [timespan]::FromSeconds($Seconds)
    $script:Toast.Add_Tick({
            $UI.Toast.Visibility = 'Collapsed'
            $script:Toast.Stop()
        })
    $script:Toast.Start()
}

# Closes the modal card (dialog) and clears its state.
function Hide-Overlay {
    $UI.Overlay.Visibility = 'Collapsed'
    $script:OverlayAction = $null
    $script:OverlayData = @{}
    $script:OverlayFieldControls = @{}
    $UI.OverlayFields.Children.Clear()
    $UI.OverlayAdvanced.Children.Clear()
    $UI.OverlayFieldsPanel.Visibility = 'Collapsed'
    $UI.OverlayMore.Visibility = 'Collapsed'
    $UI.OverlayMore.IsChecked = $false
    $UI.OverlayAdvanced.Visibility = 'Collapsed'
    foreach ($n in @('OverlayInputPanel', 'OverlayInput2Panel', 'OverlayPassPanel', 'OverlayLogPanel')) {
        $UI[$n].Visibility = 'Collapsed'
    }
    $UI.OverlayBody.Visibility = 'Collapsed'
    $UI.OverlayPass.Password = ''
    $UI.OverlayPass2.Password = ''
    $UI.OverlayLog.Text = ''
    $UI.OverlayNote.Text = ''
    $UI.OverlayOk.IsEnabled = $true
    $UI.OverlayCancel.Content = 'Cancel'
    $UI.OverlayOk.Visibility = 'Visible'
}

# Opens the modal card (dialog) with a title, text, fields and OK/Cancel actions.
function Show-Overlay {
    <#
        The one modal card, dressed differently depending on what is being
        asked. -OnOk is called with a hashtable of whatever was typed and
        the -Data the card was opened with (a scriptblock cannot see the
        variables of the function that made it, so what it needs is handed
        to it); it returns $false to keep the card open, for a card that
        reports progress and closes itself later.
    #>
    param(
        [string]$Title,
        [string]$Subtitle = '',
        [string]$Body = '',
        [string]$Note = '',
        [string]$OkText = 'OK',
        [switch]$Danger,
        [string]$Input1Label,
        [string]$Input1Text = '',
        [string]$Input2Label,
        [string]$Input2Text = '',
        [switch]$Password,
        [string]$PasswordLabel = 'Password',
        [switch]$WithLog,
        [array]$Fields = @(),
        [hashtable]$Data = @{},
        [scriptblock]$OnOk
    )

    Hide-Overlay
    $script:OverlayData = $Data
    $UI.OverlayTitle.Text = $Title
    $UI.OverlaySub.Text = $Subtitle
    $UI.OverlaySub.Visibility = $(if ($Subtitle) { 'Visible' } else { 'Collapsed' })
    if ($Body) {
        $UI.OverlayBody.Text = $Body
        $UI.OverlayBody.Visibility = 'Visible'
    }
    $UI.OverlayNote.Text = $Note
    $UI.OverlayOk.Content = $OkText
    $UI.OverlayOk.Style = $(if ($Danger) { $Window.FindResource('Danger') } else { $Window.FindResource('Primary') })

    if ($Input1Label) {
        $UI.OverlayInputLabel.Text = $Input1Label
        $UI.OverlayInput.Text = $Input1Text
        $UI.OverlayInputPanel.Visibility = 'Visible'
    }
    if ($Input2Label) {
        $UI.OverlayInput2Label.Text = $Input2Label
        $UI.OverlayInput2.Text = $Input2Text
        $UI.OverlayInput2Panel.Visibility = 'Visible'
    }
    if ($Password) {
        $UI.OverlayPassLabel.Text = $PasswordLabel
        $UI.OverlayPassPanel.Visibility = 'Visible'
    }
    if ($Fields.Count) { Add-OverlayFields -Fields $Fields }
    if ($WithLog) { $UI.OverlayLogPanel.Visibility = 'Visible' }

    $script:OverlayAction = $OnOk
    $UI.Overlay.Visibility = 'Visible'
    if ($Input1Label) { [void]$UI.OverlayInput.Focus(); $UI.OverlayInput.SelectAll() }
    elseif ($Password) { [void]$UI.OverlayPass.Focus() }
    else { [void]$UI.OverlayOk.Focus() }
}

# Builds the input fields (text, password, tick box, list) of the modal card.
function Add-OverlayFields {
    <#
        Renders a card's fields. Each one is a hashtable:

          Key       what the value is called when it comes back
          Label     what the person reads (the key itself, if left out)
          Value     what it starts as
          Kind      text (default), password, bool, note, choice (Options:
                    an array of @{ Value; Text })
          Hint      a line under the box
          Advanced  hidden until "More settings" is pressed

        The controls are kept in $script:OverlayFieldControls, so the OK
        handler can read a password as a SecureString rather than as text.
    #>
    param([array]$Fields)

    $script:OverlayFieldControls = @{}
    $UI.OverlayFields.Children.Clear()
    $UI.OverlayAdvanced.Children.Clear()
    $hasAdvanced = $false

    foreach ($f in $Fields) {
        $key = [string]$f.Key
        $kind = $(if ($f.ContainsKey('Kind') -and $f.Kind) { [string]$f.Kind } else { 'text' })
        $label = $(if ($f.ContainsKey('Label') -and $f.Label) { [string]$f.Label } else { $key })
        $value = $(if ($f.ContainsKey('Value') -and $null -ne $f.Value) { [string]$f.Value } else { '' })
        $advanced = ($f.ContainsKey('Advanced') -and $f.Advanced)
        $panel = $(if ($advanced) { $UI.OverlayAdvanced } else { $UI.OverlayFields })
        if ($advanced) { $hasAdvanced = $true }

        $box = New-Object System.Windows.Controls.StackPanel
        $box.Margin = '0,0,0,12'

        if ($kind -eq 'note') {
            $t = New-Object System.Windows.Controls.TextBlock
            $t.Text = $label
            $t.Style = $Window.FindResource('H2')
            $t.Margin = '0,4,0,2'
            [void]$panel.Children.Add($t)
            continue
        }

        $l = New-Object System.Windows.Controls.TextBlock
        $l.Text = $label
        $l.Style = $Window.FindResource('Label')
        $l.Margin = '0,0,0,5'
        [void]$box.Children.Add($l)

        switch ($kind) {
            'password' {
                $p1 = New-Object System.Windows.Controls.PasswordBox
                $p1.Height = 34
                $p1.Padding = '8,0'
                $p1.VerticalContentAlignment = 'Center'
                [void]$box.Children.Add($p1)
                $l2 = New-Object System.Windows.Controls.TextBlock
                $l2.Text = 'again'
                $l2.Style = $Window.FindResource('Label')
                $l2.Margin = '0,8,0,5'
                [void]$box.Children.Add($l2)
                $p2 = New-Object System.Windows.Controls.PasswordBox
                $p2.Height = 34
                $p2.Padding = '8,0'
                $p2.VerticalContentAlignment = 'Center'
                [void]$box.Children.Add($p2)
                $script:OverlayFieldControls[$key] = [pscustomobject]@{ Kind = 'password'; Box = $p1; Confirm = $p2 }
            }
            'choice' {
                $cb = New-Object System.Windows.Controls.ComboBox
                $cb.Height = 34
                $cb.VerticalContentAlignment = 'Center'
                foreach ($o in @($f.Options)) {
                    $item = New-Object System.Windows.Controls.ComboBoxItem
                    $item.Content = [string]$o.Text
                    $item.Tag = [string]$o.Value
                    [void]$cb.Items.Add($item)
                    if ([string]$o.Value -eq $value) { $cb.SelectedItem = $item }
                }
                if (-not $cb.SelectedItem -and $cb.Items.Count) { $cb.SelectedIndex = 0 }
                [void]$box.Children.Add($cb)
                $script:OverlayFieldControls[$key] = [pscustomobject]@{ Kind = 'choice'; Box = $cb }
            }
            'bool' {
                $c = New-Object System.Windows.Controls.CheckBox
                $c.IsChecked = ($value -eq '1' -or $value -eq 'true' -or $value -eq 'True')
                $c.Content = $(if ($f.ContainsKey('Hint') -and $f.Hint) { [string]$f.Hint } else { 'on' })
                [void]$box.Children.Add($c)
                $script:OverlayFieldControls[$key] = [pscustomobject]@{ Kind = 'bool'; Box = $c }
            }
            default {
                $t = New-Object System.Windows.Controls.TextBox
                $t.Text = $value
                $t.Height = 34
                $t.Padding = '8,0'
                $t.VerticalContentAlignment = 'Center'
                [void]$box.Children.Add($t)
                $script:OverlayFieldControls[$key] = [pscustomobject]@{ Kind = 'text'; Box = $t }
            }
        }

        if ($kind -ne 'bool' -and $f.ContainsKey('Hint') -and $f.Hint) {
            $h = New-Object System.Windows.Controls.TextBlock
            $h.Text = [string]$f.Hint
            $h.Style = $Window.FindResource('Label')
            $h.Foreground = $Brush.Faint
            $h.TextWrapping = 'Wrap'
            $h.Margin = '0,5,0,0'
            [void]$box.Children.Add($h)
        }
        [void]$panel.Children.Add($box)
    }

    $UI.OverlayFieldsPanel.Visibility = 'Visible'
    $UI.OverlayMore.Visibility = $(if ($hasAdvanced) { 'Visible' } else { 'Collapsed' })
}

# Returns what was typed into the modal card's fields.
function Get-OverlayFields {
    # What was typed: strings, with "1"/"0" for the ticks. A password comes
    # back as text only so the two boxes can be compared; the password
    # itself is read as a SecureString with Get-OverlayFieldSecret.
    $out = @{}
    foreach ($key in $script:OverlayFieldControls.Keys) {
        $c = $script:OverlayFieldControls[$key]
        switch ($c.Kind) {
            'password' {
                $out[$key] = $c.Box.Password
                $out["$key.Again"] = $c.Confirm.Password
            }
            'bool' { $out[$key] = $(if ($c.Box.IsChecked) { '1' } else { '0' }) }
            'choice' { $out[$key] = $(if ($c.Box.SelectedItem) { [string]$c.Box.SelectedItem.Tag } else { '' }) }
            default { $out[$key] = ("$($c.Box.Text)").Trim() }
        }
    }
    return $out
}

# Returns a password field of the modal card as a SecureString.
function Get-OverlayFieldSecret {
    param([string]$Key)
    $c = $script:OverlayFieldControls[$Key]
    if (-not $c -or $c.Kind -ne 'password') { return $null }
    return $c.Box.SecurePassword
}

# Appends a line to the progress text box of the modal card.
function Write-OverlayLog {
    param([string]$Text)
    $UI.OverlayLog.AppendText($Text + "`r`n")
    $UI.OverlayLog.ScrollToEnd()
}

# Leaves only a Close button on the modal card once its action is done.
function Set-OverlayFinished {
    # The card has said what happened; only a way out is left.
    param([string]$Note, [string]$Severity = 'OK')
    $UI.OverlayOk.Visibility = 'Collapsed'
    $UI.OverlayCancel.Content = 'Close'
    if ($Note) {
        $UI.OverlayNote.Text = $Note
        $UI.OverlayNote.Foreground = (Get-SeverityBrush $Severity)[0]
    }
}

# ---------------------------------------------------------------------------
# Reading the data
#
# The CSV is only re-read when it (or the collector's status file next to it)
# has actually changed, and the reading happens in a background runspace: a
# megabyte of CSV takes a moment, and the window must not stop for it.
# ---------------------------------------------------------------------------
# Returns a change stamp (size + time) of the events CSV, to tell when it has changed.
function Get-FleetStamp {
    param([string]$Path)
    $parts = @()
    foreach ($p in @($Path, [System.IO.Path]::ChangeExtension($Path, '.status.json'))) {
        try {
            $f = Get-Item -LiteralPath $p -ErrorAction Stop
            $parts += ('{0}|{1}' -f $f.LastWriteTimeUtc.Ticks, $f.Length)
        }
        catch { $parts += 'none' }
    }
    return ($parts -join ';')
}

# Re-reads the fleet state in the background when the events CSV has changed.
function Request-FleetRefresh {
    param([switch]$Force)

    if ($script:Refreshing) { return }
    $stamp = Get-FleetStamp -Path $script:CsvFile
    if (-not $Force -and $stamp -eq $script:CsvStamp -and $script:State) { return }

    $script:Refreshing = $true
    $script:CsvStamp = $stamp
    [void](Start-FleetJob -Name 'read' -Context @{ Csv = $script:CsvFile } -Body {
            Read-FleetState -Path $Ctx.Csv
        } -Done {
            param($Result, $Err)
            $script:Refreshing = $false
            $state = Get-JobValue $Result
            if ($Err -and -not $state) {
                $UI.StatusLeft.Text = "Could not read the fleet: $Err"
                return
            }
            $script:State = $state
            Update-Everything
        })
}

# Returns the kiosks shown on a tab (Mach2, PBI, Web, Other).
function Get-TabKiosks {
    param([string]$Tab)
    if (-not $script:State -or -not $script:State.Ok) { return @() }
    # A kiosk is on every tab it has a screen for: a PBI kiosk with a Mach2
    # dashboard on S2 is on both.
    return @($script:State.Hosts | Where-Object { $_.Tab -eq $Tab -or @($_.Tabs) -contains $Tab })
}

# What each tab's launcher is called, and the fleet state's key for it.
$LauncherNames = @{ NG = 'Mach2 Launcher NG'; PBI = 'PBI Launcher'; WEB = 'Web Launcher' }
$TabKinds = @{ Mach2 = 'NG'; PBI = 'PBI'; Web = 'WEB' }
$KindOfScreenLauncher = @{ MACH2 = 'NG'; PBI = 'PBI'; WEB = 'WEB' }

# Returns one kiosk from the current fleet state by host name.
function Get-Kiosk {
    param([string]$HostName)
    if (-not $script:State -or -not $script:State.Ok) { return $null }
    return @($script:State.Hosts | Where-Object { $_.Host -eq $HostName })[0]
}

# Summarises what a kiosk's launcher was doing at the last scan, for the table and details.
function Get-LauncherView {
    <#
        What a kiosk's launcher was doing at the last scan, from the
        collector's status file: the same reading for every launcher, so the
        table and the details can show them side by side. -Tab picks the
        launcher that tab is about (a kiosk can run several, one per
        screen); without it, the kiosk's own tab's, then whichever it has.
    #>
    param($Kiosk, [string]$Tab)

    $out = [pscustomobject]@{
        Kind = ''; Known = $false; Installed = $false; Old = $false
        State = ''; For = ''; Account = ''; Version = ''; Screen = ''
        Severity = 'UNKNOWN'; Instances = @(); Status = ''; Error = ''
    }
    if (-not $Kiosk) { return $out }

    $entry = $null
    $want = if ($Tab -and $TabKinds.ContainsKey($Tab)) { $TabKinds[$Tab] } elseif ($TabKinds.ContainsKey([string]$Kiosk.Tab)) { $TabKinds[[string]$Kiosk.Tab] } else { '' }
    $have = [ordered]@{ NG = $Kiosk.Ng; PBI = $Kiosk.Pbi; WEB = $(if ($Kiosk.PSObject.Properties['Web']) { $Kiosk.Web } else { $null }) }
    if ($want -and $have[$want]) { $entry = $have[$want]; $out.Kind = $want }
    elseif (-not $want -or -not $Tab) {
        foreach ($k in $have.Keys) { if ($have[$k]) { $entry = $have[$k]; $out.Kind = $k; break } }
    }
    if (-not $entry) {
        # A Mach2 kiosk with no NG entry at all is still on the old launcher.
        if (($Tab -eq 'Mach2') -or (-not $Tab -and $Kiosk.Tab -eq 'Mach2')) { $out.State = 'old launcher'; $out.Severity = 'INACTIVE' }
        return $out
    }

    $out.Known = $true
    $out.Status = [string]$entry.Status
    $out.Error = [string]$entry.Error
    $out.Installed = [bool]$entry.Installed
    $out.Old = $(if ($out.Kind -eq 'NG') { [bool]$entry.OldLauncher } elseif ($out.Kind -eq 'PBI') { [bool]$entry.LegacyLauncher } else { $false })
    $out.Instances = @($entry.Instances)

    if (-not $out.Installed) {
        $out.State = $(if ($out.Old) { 'old launcher' } else { 'no launcher' })
        $out.Severity = 'INACTIVE'
        return $out
    }
    if ($out.Instances.Count -eq 0) {
        $out.State = 'not started'
        $out.Severity = 'WARNING'
        return $out
    }

    $first = $out.Instances[0]
    $screenOf = { param($i) if ($i.PSObject.Properties['Screen'] -and $i.Screen) { [string]$i.Screen } else { [string]$i.Instance } }
    $out.State = $(if ($out.Instances.Count -gt 1) { (@($out.Instances | ForEach-Object { '{0}:{1}' -f (& $screenOf $_), $_.State }) -join ' ') } else { [string]$first.State })
    $out.For = Format-Minutes $first.StateMinutes
    $out.Version = [string]$first.Version
    if ($out.Kind -eq 'PBI') { $out.Account = [string]$first.SignedInAs }
    elseif ($out.Kind -eq 'WEB') { }
    else {
        $pct = $null
        if ($null -ne $first.ScreenWhitePercent) { $pct = $first.ScreenWhitePercent }
        elseif ($null -ne $first.PageWhitePercent) { $pct = $first.PageWhitePercent }
        if ($null -ne $pct -and "$pct" -ne '') { $out.Screen = ('{0}%' -f $pct) }
    }

    $out.Severity = switch ([string]$first.State) {
        'SHOWING' { 'OK' }
        'BROWSING' { 'OK' }
        { $_ -in @('LOADING', 'SIGNING_IN', 'LAUNCHING', 'STARTING', 'RESTARTING_PC') } { 'UNKNOWN' }
        { $_ -in @('SIGNIN_BLOCKED', 'ERROR', 'STOPPED') } { 'CRITICAL' }
        default { 'WARNING' }
    }
    if ([string]$first.HostStatus -eq 'LAUNCHER_STALE') {
        $out.State = '(' + $out.State + ')'
        $out.Severity = 'CRITICAL'
    }
    return $out
}

# Draws a week of daily counts as a small text sparkline.
function Get-Sparkline {
    param($Kiosk, [string[]]$DayKeys, [int]$Max)
    if ($Max -lt 1) { $Max = 1 }
    $out = ''
    foreach ($k in $DayKeys) {
        $n = 0
        if ($Kiosk.Days.ContainsKey($k)) { $n = $Kiosk.Days[$k] }
        if ($n -le 0) { $out += $DotGlyph; continue }
        $idx = [int][math]::Ceiling(($n / [double]$Max) * ($Spark.Count - 1))
        if ($idx -lt 0) { $idx = 0 }
        if ($idx -ge $Spark.Count) { $idx = $Spark.Count - 1 }
        $out += $Spark[$idx]
    }
    return $out
}

# Fills one table row from a kiosk's current state.
function Update-Row {
    param($Row, $Kiosk, [string[]]$DayKeys, [int]$MaxDaily, [string]$Tab)

    $pair = Get-SeverityBrush (Get-FleetSeverity $Kiosk.Status)
    $Row.Host = $Kiosk.Host
    $Row.Location = $Kiosk.Location
    $Row.Type = $Kiosk.Type
    $Row.Tab = $Kiosk.Tab
    $Row.Status = $Kiosk.Status
    $Row.Severity = Get-FleetSeverity $Kiosk.Status
    $Row.StatusBrush = $pair[0]
    $Row.StatusBack = $pair[1]
    $Row.Attention = [bool](Test-NeedsAttention $Kiosk)
    $Row.Rank = $(if ($StatusRank.ContainsKey($Kiosk.Status)) { $StatusRank[$Kiosk.Status] } else { 8 })
    $Row.Tag = $Kiosk

    $row0 = $Kiosk.StatusRow
    $Row.LogAge = ''
    $Row.Uptime = ''
    $Row.Watchdog = ''
    $Row.Agent = ''
    $Row.WatchdogBrush = $Brush.Dim
    if ($row0) {
        if ($row0.MinutesSinceLastLog) { $Row.LogAge = '{0}m' -f [int][double]$row0.MinutesSinceLastLog }
        if ($row0.UptimeHours) {
            $h = [double]$row0.UptimeHours
            $Row.Uptime = $(if ($h -ge 48) { '{0}d' -f [int]($h / 24) } else { '{0}h' -f [int]$h })
        }
        elseif ($row0.BootTimeUtc) {
            $boot = ConvertFrom-FleetIsoTime ([string]$row0.BootTimeUtc)
            if ($boot) { $Row.Uptime = Format-Minutes (([datetime]::UtcNow - $boot).TotalMinutes) }
        }
        $Row.Watchdog = switch ("$($row0.WatchdogRunning)") { 'TRUE' { 'running' } 'FALSE' { 'DEAD' } default { '' } }
        if ($Row.Watchdog -eq 'DEAD') { $Row.WatchdogBrush = $Brush.Crit }
        $Row.Agent = [string]$row0.AgentVersion
        $Row.Note = [string]$row0.Detail
    }

    $reb = ''
    if ($Kiosk.Reboots24 -gt 0) { $reb = '{0}' -f $Kiosk.Reboots24 }
    if ($Kiosk.Script24 -gt 0) { $reb = '{0} ({1})' -f $Kiosk.Reboots24, $Kiosk.Script24 }
    $Row.Reboots = $reb
    $Row.Spark = Get-Sparkline -Kiosk $Kiosk -DayKeys $DayKeys -Max $MaxDaily

    $lv = Get-LauncherView -Kiosk $Kiosk -Tab $Tab
    $Row.Launcher = $lv.State
    $Row.ForText = $lv.For
    $Row.Account = $lv.Account
    $Row.Version = $lv.Version
    $Row.Screen = $lv.Screen
    $Row.LauncherBrush = (Get-SeverityBrush $lv.Severity)[0]
    $Row.AccountBrush = $(if ($Kiosk.Status -eq 'WRONG_ACCOUNT') { $Brush.Crit } else { $Brush.Dim })
    $Row.Busy = (Test-HostBusy $Kiosk.Host)
}

# Updates the bound table rows in place so selection, sort and scroll survive a refresh.
function Sync-Rows {
    <#
        Brings a bound collection into line with a list of kiosks without
        throwing it away: rows are updated where they are, so the selection,
        the sort and the scroll position survive a refresh.
    #>
    param($Collection, [array]$Kiosks, [string[]]$DayKeys, [int]$MaxDaily, [string]$Tab)

    $byHost = @{}
    foreach ($r in $Collection) { $byHost[$r.Host] = $r }

    $wanted = @{}
    for ($i = 0; $i -lt $Kiosks.Count; $i++) {
        $k = $Kiosks[$i]
        $wanted[$k.Host] = $true
        $row = $null
        if ($byHost.ContainsKey($k.Host)) { $row = $byHost[$k.Host] }
        if (-not $row) {
            $row = New-Object KioskFleet.FleetRow
            Update-Row -Row $row -Kiosk $k -DayKeys $DayKeys -MaxDaily $MaxDaily -Tab $Tab
            if ($i -le $Collection.Count) { $Collection.Insert([math]::Min($i, $Collection.Count), $row) }
            else { $Collection.Add($row) }
            continue
        }
        Update-Row -Row $row -Kiosk $k -DayKeys $DayKeys -MaxDaily $MaxDaily -Tab $Tab
        $at = $Collection.IndexOf($row)
        if ($at -ge 0 -and $at -ne $i -and $i -lt $Collection.Count) { $Collection.Move($at, $i) }
    }

    for ($i = $Collection.Count - 1; $i -ge 0; $i--) {
        if (-not $wanted.ContainsKey($Collection[$i].Host)) { $Collection.RemoveAt($i) }
    }
}

# Returns the highest daily count across kiosks, to scale the sparklines.
function Get-MaxDaily {
    param([array]$Kiosks)
    $max = 1
    foreach ($k in $Kiosks) {
        foreach ($v in $k.Days.Values) { if ($v -gt $max) { $max = $v } }
    }
    return $max
}

# Tells whether a table row matches the text typed in the filter box.
function Test-RowMatchesFilter {
    param($Row, [string]$Text)
    if (-not $Text) { return $true }
    $t = $Text.Trim()
    if (-not $t) { return $true }
    foreach ($field in @($Row.Host, $Row.Location, $Row.Status, $Row.Type, $Row.Launcher, $Row.Account)) {
        if ($field -and $field.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Drawing what was read
# ---------------------------------------------------------------------------
# Redraws the whole window (header, navigation, overview, kiosk view).
function Update-Everything {
    Update-Header
    Update-Nav
    Update-Overview
    Update-KioskView
    Update-DeployTargets
    Update-Detail
    Update-StatusBar
}

# Updates the headline (how many kiosks need attention) at the top.
function Update-Header {
    if (-not $script:State) { return }
    if (-not $script:State.Ok) {
        $UI.HeadlineText.Text = 'NO DATA'
        $UI.HeadlineText.Foreground = $Brush.Warn
        $UI.HeadlineDot.Fill = $Brush.Warn
        $UI.HeadlinePill.Background = $Brush.WarnBack
        $UI.FreshText.Text = [string]$script:State.Error
        $UI.FreshText.Foreground = $Brush.Warn
        return
    }

    $attention = @($script:State.Hosts | Where-Object { Test-NeedsAttention $_ })
    if ($attention.Count -eq 0) {
        $UI.HeadlineText.Text = 'ALL {0} KIOSKS OK' -f $script:State.Hosts.Count
        $UI.HeadlineText.Foreground = $Brush.Ok
        $UI.HeadlineDot.Fill = $Brush.Ok
        $UI.HeadlinePill.Background = $Brush.OkBack
    }
    else {
        $UI.HeadlineText.Text = '{0} KIOSK{1} NEED{2} ATTENTION' -f $attention.Count,
            $(if ($attention.Count -eq 1) { '' } else { 'S' }), $(if ($attention.Count -eq 1) { 'S' } else { '' })
        $UI.HeadlineText.Foreground = $Brush.Crit
        $UI.HeadlineDot.Fill = $Brush.Crit
        $UI.HeadlinePill.Background = $Brush.CritBack
    }
    Update-Freshness
}

# Shows how old the scan data is, in red when it is stale.
function Update-Freshness {
    if (-not $script:State) { return }
    $f = Get-FleetFreshness -State $script:State -StaleMinutes $StaleMinutes
    $UI.FreshText.Text = $f.Text
    $UI.FreshText.Foreground = $(if ($f.Stale) { $Brush.Crit } else { $Brush.Dim })
}

# Updates the kiosk counts on the navigation tabs.
function Update-Nav {
    if (-not $script:State -or -not $script:State.Ok) { return }
    foreach ($t in @(@('Mach2', 'Mach2'), @('PBI', 'Pbi'), @('Web', 'Web'), @('Other', 'Other'))) {
        $n = @(Get-TabKiosks -Tab $t[0] | Where-Object { Test-NeedsAttention $_ }).Count
        $UI[('Badge{0}' -f $t[1])].Text = "$n"
        $UI[('Badge{0}Box' -f $t[1])].Visibility = $(if ($n -gt 0) { 'Visible' } else { 'Collapsed' })
    }
    $other = @(Get-TabKiosks -Tab 'Other').Count
    $UI.NavOther.Visibility = $(if ($other -gt 0) { 'Visible' } else { 'Collapsed' })
    # The Web tab appears once a kiosk shows a web page (or is typed Web).
    $web = @(Get-TabKiosks -Tab 'Web').Count
    $UI.NavWeb.Visibility = $(if ($web -gt 0 -or $script:View -eq 'Web') { 'Visible' } else { 'Collapsed' })
}

# Fills the Overview page (totals, attention list, statistics).
function Update-Overview {
    if (-not $script:State -or -not $script:State.Ok) { return }

    $hosts = @($script:State.Hosts)
    $attention = @($hosts | Where-Object { Test-NeedsAttention $_ })
    $inactive = @($hosts | Where-Object { $_.Status -eq 'INACTIVE' }).Count
    $reb = [int](($hosts | Measure-Object -Property Reboots24 -Sum).Sum)
    $scr = [int](($hosts | Measure-Object -Property Script24 -Sum).Sum)
    $eps = [int](($hosts | Measure-Object -Property Episodes24 -Sum).Sum)

    $UI.StatTotal.Text = "$($hosts.Count)"
    $webCount = @(Get-TabKiosks -Tab 'Web').Count
    $UI.StatTotalNote.Text = '{0} Mach2, {1} Power BI{2}{3}' -f @(Get-TabKiosks -Tab 'Mach2').Count,
        @(Get-TabKiosks -Tab 'PBI').Count, $(if ($webCount) { ", $webCount web page" } else { '' }), $(if ($inactive) { ", $inactive not watched" } else { '' })

    $UI.StatAttention.Text = "$($attention.Count)"
    $UI.StatAttention.Foreground = $(if ($attention.Count) { $Brush.Crit } else { $Brush.Ok })
    $crit = @($attention | Where-Object { (Get-FleetSeverity $_.Status) -eq 'CRITICAL' }).Count
    $UI.StatAttentionNote.Text = $(if ($attention.Count) { "$crit critical" } else { 'nothing to do' })

    $UI.StatReboots.Text = "$reb"
    $UI.StatRebootsNote.Text = $(if ($scr) { "$scr by the watchdog" } else { 'none by the watchdog' })
    $UI.StatEpisodes.Text = "$eps"

    $ng = @($hosts | Where-Object { $_.StatusRow -and (Test-Mach2NgVersion ([string]$_.StatusRow.AgentVersion)) }).Count
    $pbi = @($hosts | Where-Object { $_.Pbi -and $_.Pbi.Installed }).Count
    $web = @($hosts | Where-Object { $_.PSObject.Properties['Web'] -and $_.Web -and $_.Web.Installed }).Count
    $UI.StatLaunchers.Text = '{0}' -f ($ng + $pbi + $web)
    $UI.StatLaunchersNote.Text = '{0} Mach2 NG, {1} PBI Launcher{2}' -f $ng, $pbi, $(if ($web) { ", $web Web Launcher" } else { '' })

    # Attention list
    if (-not $script:AttentionRows) {
        $script:AttentionRows = New-Object System.Collections.ObjectModel.ObservableCollection[KioskFleet.FleetRow]
        $UI.AttentionGrid.ItemsSource = $script:AttentionRows
    }
    Sync-Rows -Collection $script:AttentionRows -Kiosks $attention -DayKeys $script:State.DayKeys -MaxDaily (Get-MaxDaily $hosts)
    $UI.AttentionEmpty.Visibility = $(if ($attention.Count) { 'Collapsed' } else { 'Visible' })
    $UI.AttentionGrid.Visibility = $(if ($attention.Count) { 'Visible' } else { 'Collapsed' })

    # Seven days of reboots
    if (-not $script:ChartBars) {
        $script:ChartBars = New-Object System.Collections.ObjectModel.ObservableCollection[KioskFleet.DayBar]
        $UI.ChartBars.ItemsSource = $script:ChartBars
    }
    $totals = @{}
    foreach ($k in $hosts) {
        foreach ($d in $k.Days.Keys) {
            if (-not $totals.ContainsKey($d)) { $totals[$d] = 0 }
            $totals[$d] += $k.Days[$d]
        }
    }
    $max = 1
    foreach ($d in $script:State.DayKeys) { if ($totals.ContainsKey($d) -and $totals[$d] -gt $max) { $max = $totals[$d] } }
    $script:ChartBars.Clear()
    foreach ($d in $script:State.DayKeys) {
        $n = 0
        if ($totals.ContainsKey($d)) { $n = $totals[$d] }
        $day = [datetime]::ParseExact($d, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
        $bar = New-Object KioskFleet.DayBar
        $bar.Label = $day.ToString('ddd')
        $bar.Count = $(if ($n -gt 0) { "$n" } else { '' })
        $bar.BarHeight = [math]::Max(2, [math]::Round(78 * ($n / [double]$max)))
        $bar.Tip = '{0}: {1} reboot(s)' -f $day.ToString('ddd dd MMM'), $n
        $script:ChartBars.Add($bar)
    }

    # Collection panel
    $UI.CollectorPanel.Children.Clear()
    $sc = $script:State.Sidecar
    $f = Get-FleetFreshness -State $script:State -StaleMinutes $StaleMinutes
    [void]$UI.CollectorPanel.Children.Add((New-DetailRow 'Last scan' $(if ($f.LastRun) { $f.LastRun.ToString('ddd dd MMM HH:mm') } else { 'never' }) $(if ($f.Stale) { $Brush.Crit } else { $Brush.Text })))
    if ($sc) {
        [void]$UI.CollectorPanel.Children.Add((New-DetailRow 'Took' ('{0}s' -f [int]$sc.DurationSeconds)))
        [void]$UI.CollectorPanel.Children.Add((New-DetailRow 'Reached' ('{0} of {1} kiosks' -f $sc.Reachable, $sc.Hosts)))
        [void]$UI.CollectorPanel.Children.Add((New-DetailRow 'New events' ("$($sc.NewEvents)")))
        [void]$UI.CollectorPanel.Children.Add((New-DetailRow 'Collector' ('v{0}' -f $sc.CollectorVersion)))
        [void]$UI.CollectorPanel.Children.Add((New-DetailRow 'Ran as' ([string]$sc.Runner) $Brush.Dim))
    }
    [void]$UI.CollectorPanel.Children.Add((New-DetailRow 'Events file' (Split-Path -Leaf $script:CsvFile) $Brush.Dim))
    [void]$UI.CollectorPanel.Children.Add((New-DetailRow 'Rows' ("$($script:State.RowCount)") $Brush.Dim))
}

# ---------------------------------------------------------------------------
# The kiosk tables and the details beside them
# ---------------------------------------------------------------------------
# Creates one label/value line for the kiosk details panel.
function New-DetailRow {
    param([string]$Label, [string]$Value, $Brush2, [switch]$Wrap)

    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = '0,0,0,5'
    $c1 = New-Object System.Windows.Controls.ColumnDefinition
    $c1.Width = New-Object System.Windows.GridLength(112)
    $c2 = New-Object System.Windows.Controls.ColumnDefinition
    $g.ColumnDefinitions.Add($c1)
    $g.ColumnDefinitions.Add($c2)

    $l = New-Object System.Windows.Controls.TextBlock
    $l.Text = $Label
    $l.Style = $Window.FindResource('Label')
    $l.VerticalAlignment = 'Top'
    [void]$g.Children.Add($l)

    $v = New-Object System.Windows.Controls.TextBlock
    $v.Text = $Value
    $v.FontSize = 12
    $v.Foreground = $(if ($Brush2) { $Brush2 } else { $Brush.Text })
    if ($Wrap) { $v.TextWrapping = 'Wrap' } else { $v.TextTrimming = 'CharacterEllipsis' }
    $v.ToolTip = $(if ($Value -and $Value.Length -gt 34) { $Value } else { $null })
    [System.Windows.Controls.Grid]::SetColumn($v, 1)
    [void]$g.Children.Add($v)
    return $g
}

# Creates a section heading for the kiosk details panel.
function New-DetailHeader {
    param([string]$Text, [switch]$First)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $Text
    $t.Style = $Window.FindResource('H2')
    $t.Margin = $(if ($First) { '0,0,0,8' } else { '0,14,0,8' })
    return $t
}

# Shows or hides table columns to suit the current tab.
function Set-KioskColumns {
    param([string]$Tab)

    # 0 KIOSK  1 TYPE  2 LOCATION  3 STATUS  4 LAUNCHER  5 FOR  6 SCREEN
    # 7 SIGNED IN AS  8 VER  9 WATCHDOG  10 LOG  11 AGENT  12 UPTIME
    # 13 REB 24H  14 7 DAYS
    $show = switch ($Tab) {
        'Mach2' { @(0, 2, 3, 4, 6, 9, 10, 11, 12, 13, 14) }
        'PBI'   { @(0, 2, 3, 4, 5, 7, 8, 12) }
        'Web'   { @(0, 2, 3, 4, 5, 8, 12) }
        default { @(0, 1, 2, 3, 12) }
    }
    for ($i = 0; $i -lt $UI.KioskGrid.Columns.Count; $i++) {
        $UI.KioskGrid.Columns[$i].Visibility = $(if ($show -contains $i) { 'Visible' } else { 'Collapsed' })
    }
}

# Fills the kiosk table for the current tab.
function Update-KioskView {
    if (-not $script:State -or -not $script:State.Ok) { return }

    $kiosks = @(Get-TabKiosks -Tab $script:Tab)
    $attention = @($kiosks | Where-Object { Test-NeedsAttention $_ })

    $title = switch ($script:Tab) { 'Mach2' { 'Mach2 kiosks' } 'PBI' { 'Power BI screens' } 'Web' { 'Web page screens' } default { 'Other kiosks' } }
    $UI.KioskTitle.Text = $title
    $UI.KioskSubtitle.Text = '{0} kiosks, {1} needing attention' -f $kiosks.Count, $attention.Count

    if (-not $script:Rows) {
        $script:Rows = New-Object System.Collections.ObjectModel.ObservableCollection[KioskFleet.FleetRow]
        $UI.KioskGrid.ItemsSource = $script:Rows
        $rowView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
        $rowView.Filter = [Predicate[object]] {
            param($item)
            if ($script:OnlyProblems -and -not $item.Attention) { return $false }
            return (Test-RowMatchesFilter -Row $item -Text $script:Filter)
        }
    }
    Set-KioskColumns -Tab $script:Tab
    Sync-Rows -Collection $script:Rows -Kiosks $kiosks -DayKeys $script:State.DayKeys -MaxDaily (Get-MaxDaily $kiosks) -Tab $script:Tab

    $rowView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
    $rowView.Refresh()

    $shown = @($rowView | ForEach-Object { $_ }).Count
    if ($kiosks.Count -eq 0) {
        $UI.KioskEmpty.Text = "No $($script:Tab) kiosks in the data."
        $UI.KioskEmpty.Visibility = 'Visible'
    }
    elseif ($shown -eq 0) {
        $UI.KioskEmpty.Text = $(if ($script:OnlyProblems) { 'Nothing on this tab needs attention.' } else { 'Nothing matches the filter.' })
        $UI.KioskEmpty.Visibility = 'Visible'
    }
    else { $UI.KioskEmpty.Visibility = 'Collapsed' }

    # Keep the selection on the same kiosk when the table is rebuilt.
    if ($script:Selected) {
        $row = @($script:Rows | Where-Object { $_.Host -eq $script:Selected })[0]
        if ($row -and $UI.KioskGrid.SelectedItem -ne $row) { $UI.KioskGrid.SelectedItem = $row }
    }
}

# Switches to a kiosk tab (Mach2, PBI, Web, Other).
function Select-KioskTab {
    param([string]$Tab, [string]$HostName)

    $script:Tab = $Tab
    $script:View = $Tab
    Show-View -Name $Tab
    Update-KioskView
    if ($HostName) {
        $row = @($script:Rows | Where-Object { $_.Host -eq $HostName })[0]
        if ($row) {
            $script:Selected = $HostName
            $UI.KioskGrid.SelectedItem = $row
            $UI.KioskGrid.ScrollIntoView($row)
            Update-Detail
        }
    }
}

# Fills the details panel for the selected kiosk.
function Update-Detail {
    $hostName = $script:Selected
    if (-not $hostName) {
        $UI.DetailRoot.Visibility = 'Collapsed'
        $UI.DetailEmpty.Visibility = 'Visible'
        $script:DetailHost = $null
        return
    }

    $k = Get-Kiosk $hostName
    if (-not $k) {
        $UI.DetailRoot.Visibility = 'Collapsed'
        $UI.DetailEmpty.Visibility = 'Visible'
        return
    }

    if ($script:DetailHost -ne $hostName) {
        $UI.SnapshotCard.Visibility = 'Collapsed'
        $UI.SnapshotImage.Source = $null
    }
    $script:DetailHost = $hostName
    $UI.DetailRoot.Visibility = 'Visible'
    $UI.DetailEmpty.Visibility = 'Collapsed'
    $UI.DetailHostText.Text = $k.Host
    $UI.DetailSubText.Text = (@($k.Location, $k.Type) | Where-Object { $_ }) -join '  |  '

    $pair = Get-SeverityBrush (Get-FleetSeverity $k.Status)
    $UI.DetailPillText.Text = $k.Status
    $UI.DetailPillText.Foreground = $pair[0]
    $UI.DetailPill.Background = $pair[1]

    $p = $UI.DetailPanel
    $p.Children.Clear()

    $row0 = $k.StatusRow
    [void]$p.Children.Add((New-DetailHeader 'LAST SCAN' -First))
    if ($row0) {
        $when = ConvertFrom-FleetIsoTime ([string]$row0.EventTimeUtc)
        [void]$p.Children.Add((New-DetailRow 'Seen' $(if ($when) { $when.ToLocalTime().ToString('ddd dd MMM HH:mm') } else { '' })))
        if ($row0.Detail) { [void]$p.Children.Add((New-DetailRow 'Detail' ([string]$row0.Detail) $Brush.Dim -Wrap)) }
        if ($row0.BootTimeUtc) {
            $boot = ConvertFrom-FleetIsoTime ([string]$row0.BootTimeUtc)
            if ($boot) {
                [void]$p.Children.Add((New-DetailRow 'PC up since' ('{0}  ({1})' -f $boot.ToLocalTime().ToString('dd MMM HH:mm'), (Format-Minutes ([datetime]::UtcNow - $boot).TotalMinutes))))
            }
        }
    }
    else { [void]$p.Children.Add((New-DetailRow 'Seen' 'no status row yet' $Brush.Warn)) }
    [void]$p.Children.Add((New-DetailRow 'Reboots 24h' ('{0}{1}' -f $k.Reboots24, $(if ($k.Script24) { " ($($k.Script24) by the watchdog)" } else { '' }))))
    [void]$p.Children.Add((New-DetailRow 'Screen events' ("$($k.Episodes24) in 24h")))

    if ($k.HasWatchdog -and $row0) {
        [void]$p.Children.Add((New-DetailHeader 'WATCHDOG'))
        $wd = switch ("$($row0.WatchdogRunning)") { 'TRUE' { 'running' } 'FALSE' { 'DEAD' } default { 'unknown' } }
        [void]$p.Children.Add((New-DetailRow 'State' $wd $(if ($wd -eq 'DEAD') { $Brush.Crit } else { $Brush.Ok })))
        [void]$p.Children.Add((New-DetailRow 'Version' ([string]$row0.AgentVersion)))
        if ($row0.MinutesSinceLastLog) {
            [void]$p.Children.Add((New-DetailRow 'Last wrote' ('{0} ago' -f (Format-Minutes ([double]$row0.MinutesSinceLastLog)))))
        }
    }

    # --- the launchers, screen by screen ---
    # One section per launcher the kiosk runs (Mach2 on S2 and Power BI on
    # S1 are two), or the one its tab is about when it has none yet.
    $kinds = @()
    foreach ($kk in @('NG', 'PBI', 'WEB')) {
        $e = switch ($kk) { 'NG' { $k.Ng } 'PBI' { $k.Pbi } 'WEB' { if ($k.PSObject.Properties['Web']) { $k.Web } } }
        if ($e) { $kinds += $kk }
    }
    if ($kinds.Count -eq 0 -and $TabKinds.ContainsKey([string]$k.Tab)) { $kinds = @($TabKinds[[string]$k.Tab]) }
    $screens = @(if ($k.PSObject.Properties['Screens']) { $k.Screens })
    if ($screens.Count -gt 1 -or $kinds.Count -gt 1) {
        [void]$p.Children.Add((New-DetailHeader 'SCREENS'))
        foreach ($s in $screens) {
            $sev = Get-SeverityBrush (Get-FleetSeverity ([string]$s.HostStatus))
            [void]$p.Children.Add((New-DetailRow ([string]$s.Screen) ('{0}  -  {1}' -f $LauncherNames[$KindOfScreenLauncher[[string]$s.Launcher]], $s.State) $sev[0]))
        }
    }
    foreach ($kind in $kinds) {
        $lv = Get-LauncherView -Kiosk $k -Tab $(switch ($kind) { 'NG' { 'Mach2' } 'PBI' { 'PBI' } 'WEB' { 'Web' } })
        [void]$p.Children.Add((New-DetailHeader ($LauncherNames[$kind].ToUpperInvariant())))
        if (-not $lv.Known) {
            # The collector only records the launcher it could actually read.
            $why = $(if ($kind -eq 'NG') { 'not installed - this kiosk still runs Mach2Launcher.exe and the MWST watchdog' }
                else { 'nothing was read at the last scan' })
            [void]$p.Children.Add((New-DetailRow 'Installed' $why $Brush.Dim -Wrap))
        }
        elseif (-not $lv.Installed) {
            [void]$p.Children.Add((New-DetailRow 'Installed' $(if ($lv.Old) { 'no - still on the old launcher' } elseif (@($screens | Where-Object { $KindOfScreenLauncher[[string]$_.Launcher] -eq $kind }).Count) { 'no - config written, launcher not installed' } else { 'no' }) $Brush.Warn -Wrap))
        }
        elseif ($lv.Instances.Count -eq 0) {
            [void]$p.Children.Add((New-DetailRow 'State' 'installed, never started' $Brush.Warn))
        }
        foreach ($i in $lv.Instances) {
            $label = $(if ($i.PSObject.Properties['Screen'] -and $i.Screen) { [string]$i.Screen } else { [string]$i.Instance })
            $sev = Get-SeverityBrush (Get-FleetSeverity ([string]$i.HostStatus))
            [void]$p.Children.Add((New-DetailRow $label ('{0} for {1}' -f $i.State, (Format-Minutes $i.StateMinutes)) $sev[0]))
            if ($i.Detail) { [void]$p.Children.Add((New-DetailRow '' ([string]$i.Detail) $Brush.Dim -Wrap)) }
            if ($kind -eq 'PBI') {
                $acct = $(if ($i.SignedInAs) { [string]$i.SignedInAs } else { 'not seen yet' })
                [void]$p.Children.Add((New-DetailRow 'Signed in as' $acct $(if ($k.Status -eq 'WRONG_ACCOUNT') { $Brush.Crit } else { $Brush.Dim })))
            }
            elseif ($kind -eq 'NG') {
                $w = @()
                if ($null -ne $i.ScreenWhitePercent -and "$($i.ScreenWhitePercent)" -ne '') { $w += "screen $($i.ScreenWhitePercent)%" }
                if ($null -ne $i.PageWhitePercent -and "$($i.PageWhitePercent)" -ne '') { $w += "page $($i.PageWhitePercent)%" }
                if ($w.Count) { [void]$p.Children.Add((New-DetailRow 'White' ($w -join ', ') $Brush.Dim)) }
                if ($i.Watchdog) { [void]$p.Children.Add((New-DetailRow 'Watchdog' 'this screen is the watchdog' $Brush.Dim)) }
                if ($i.LoopGuard -and "$($i.LoopGuard)" -ne 'OFF' -and "$($i.LoopGuard)" -ne '') {
                    [void]$p.Children.Add((New-DetailRow 'Loop guard' ([string]$i.LoopGuard) $Brush.Crit))
                }
                if ($i.PcRestarts) { [void]$p.Children.Add((New-DetailRow 'PC restarts' ("$($i.PcRestarts)") $Brush.Dim)) }
            }
            [void]$p.Children.Add((New-DetailRow 'Version' ('v{0}   Edge {1}' -f $i.Version, $i.Edge) $Brush.Dim))
            $counts = $(if ($kind -eq 'WEB') { '{0} reloads, {1} browser starts' -f $i.Reloads, $i.BrowserStarts }
                else { '{0} reloads, {1} sign-ins, {2} browser starts' -f $i.Reloads, $i.SignIns, $i.BrowserStarts })
            [void]$p.Children.Add((New-DetailRow 'Counts' $counts $Brush.Dim))
            $upd = ConvertFrom-FleetIsoTime ([string]$i.UpdatedUtc)
            if ($upd) { [void]$p.Children.Add((New-DetailRow 'Status written' ((Format-Minutes ([datetime]::UtcNow - $upd).TotalMinutes) + ' ago') $Brush.Dim)) }
            if ($i.LastError) { [void]$p.Children.Add((New-DetailRow 'Last error' ([string]$i.LastError) $Brush.Warn -Wrap)) }
        }
        if ($lv.Error) { [void]$p.Children.Add((New-DetailRow 'Could not read' ([string]$lv.Error) $Brush.Warn -Wrap)) }
        if ($lv.Installed -and $lv.Old) { [void]$p.Children.Add((New-DetailRow 'Old launcher' 'still on this kiosk' $Brush.Dim)) }
    }
    Update-ScreenPick -Kiosk $k

    # A live read, if one was taken since the window opened.
    if ($script:LiveObs.ContainsKey($hostName)) {
        $live = $script:LiveObs[$hostName]
        [void]$p.Children.Add((New-DetailHeader ('READ LIVE AT {0}' -f $live.At.ToString('HH:mm:ss'))))
        foreach ($line in @($live.Lines)) {
            [void]$p.Children.Add((New-DetailRow ([string]$line.Label) ([string]$line.Value) $(if ($line.Warn) { $Brush.Warn } else { $Brush.Dim }) -Wrap))
        }
    }

    Update-ActionButtons
}

# Fills the Screen list (all screens or one) in the details panel.
function Update-ScreenPick {
    <#
        The Screen box in the card: "All screens", then each screen the
        kiosk has with its launcher. The launcher buttons act on what is
        picked; the pick is remembered per kiosk while the window is open.
    #>
    param($Kiosk)
    $script:NavSetting = $true
    try {
        $UI.ScreenPick.Items.Clear()
        $all = New-Object System.Windows.Controls.ComboBoxItem
        $all.Content = 'All screens'
        $all.Tag = ''
        [void]$UI.ScreenPick.Items.Add($all)
        $want = $(if ($script:ScreenChoice.ContainsKey($Kiosk.Host)) { $script:ScreenChoice[$Kiosk.Host] } else { '' })
        $UI.ScreenPick.SelectedItem = $all
        foreach ($s in @(if ($Kiosk.PSObject.Properties['Screens']) { $Kiosk.Screens })) {
            $kind = $KindOfScreenLauncher[[string]$s.Launcher]
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = ('{0}  -  {1}  ({2})' -f $s.Screen, $LauncherNames[$kind], $s.State)
            $item.Tag = ('{0}|{1}' -f $s.Screen, $kind)
            [void]$UI.ScreenPick.Items.Add($item)
            if ($item.Tag -eq $want) { $UI.ScreenPick.SelectedItem = $item }
        }
        $UI.ScreenPickPanel.Visibility = $(if ($UI.ScreenPick.Items.Count -gt 2) { 'Visible' } else { 'Collapsed' })
    }
    finally { $script:NavSetting = $false }
}

# Returns which screen and launcher the launcher buttons act on for a kiosk.
function Get-ScreenTarget {
    # What the launcher buttons act on for this kiosk: Screen '' and Kind ALL
    # (every screen), or one screen and its launcher.
    param($Kiosk)
    $choice = $(if ($Kiosk -and $script:ScreenChoice.ContainsKey($Kiosk.Host)) { [string]$script:ScreenChoice[$Kiosk.Host] } else { '' })
    if ($choice -match '^(S\d+)\|(NG|PBI|WEB)$') { return [pscustomobject]@{ Screen = $Matches[1]; Kind = $Matches[2] } }
    return [pscustomobject]@{ Screen = ''; Kind = 'ALL' }
}

# Enables/disables the action buttons for the selected kiosk.
function Update-ActionButtons {
    $k = $(if ($script:DetailHost) { Get-Kiosk $script:DetailHost } else { $null })
    if (-not $k) { return }

    $busy = Test-HostBusy $k.Host
    $screens = @(if ($k.PSObject.Properties['Screens']) { $k.Screens })
    $installed = @(@($k.Ng, $k.Pbi, $(if ($k.PSObject.Properties['Web']) { $k.Web })) | Where-Object { $_ -and $_.Installed })
    $hasLauncher = ($installed.Count -gt 0)
    $isPbi = ($k.Tab -eq 'PBI' -or @($k.Tabs) -contains 'PBI')
    $isMach2 = ($k.Tab -eq 'Mach2' -or [bool]$k.Ng)
    $isWeb = (@($k.Tabs) -contains 'Web')
    $target = Get-ScreenTarget $k

    foreach ($n in @('BtnRestart', 'BtnRemote', 'BtnOpenShare')) { $UI[$n].IsEnabled = (-not $busy) }
    $ver = $(if ($k.StatusRow) { [string]$k.StatusRow.AgentVersion } else { '' })
    $UI.BtnMessage.IsEnabled = ((-not $busy) -and $isMach2)
    $UI.BtnMessage.ToolTip = $(if ($isMach2) { 'A window on the kiosk screen, put up by its watchdog' } else { 'Only Mach2 kiosks have a watchdog to show a message' })

    $UI.LauncherActions.Visibility = $(if ($isPbi -or $isMach2 -or $isWeb -or $screens.Count) { 'Visible' } else { 'Collapsed' })
    $UI.LauncherActionsTitle.Visibility = $UI.LauncherActions.Visibility
    # Config is open even without a launcher: a kiosk with no <HOST>.json is
    # exactly the one that needs it written before a deploy will install.
    foreach ($n in @('BtnLive', 'BtnDeployThis', 'BtnConfig', 'BtnAddScreen')) { $UI[$n].IsEnabled = (-not $busy) }
    $UI.BtnConfig.ToolTip = $(if ($hasLauncher) { "The kiosk's own settings: URL, account, screen, refresh" }
        else { 'No launcher here yet - this writes the config a deploy needs' })
    foreach ($n in @('BtnSnapshot', 'BtnReload', 'BtnRelaunch', 'BtnHold', 'BtnStopLauncher', 'BtnLog', 'BtnPassword')) {
        $UI[$n].IsEnabled = ((-not $busy) -and $hasLauncher)
        if (-not $hasLauncher) { $UI[$n].ToolTip = 'This kiosk is not on the new launcher yet' } else { $UI[$n].ToolTip = $null }
    }
    # A web page signs in to nothing: no password to hand over.
    $onlyWeb = ($target.Kind -eq 'WEB') -or ($target.Kind -eq 'ALL' -and $screens.Count -gt 0 -and -not @($screens | Where-Object { $_.Launcher -ne 'WEB' }).Count)
    if ($onlyWeb) { $UI.BtnPassword.IsEnabled = $false; $UI.BtnPassword.ToolTip = 'A web page screen signs in to nothing' }
    $UI.BtnHold.Content = $(if ($script:HoldState -and $script:HoldState[$k.Host]) { 'Resume' } else { 'Hold' })
}

# Shows one page of the window (Overview, a kiosk tab, Deploy, Activity, ...).
function Show-View {
    param([string]$Name)

    $isKiosk = ($Name -in @('Mach2', 'PBI', 'Web', 'Other'))
    $UI.ViewOverview.Visibility = $(if ($Name -eq 'Overview') { 'Visible' } else { 'Collapsed' })
    $UI.ViewKiosks.Visibility = $(if ($isKiosk) { 'Visible' } else { 'Collapsed' })
    $UI.ViewDeploy.Visibility = $(if ($Name -eq 'Deploy') { 'Visible' } else { 'Collapsed' })
    $UI.ViewActivity.Visibility = $(if ($Name -eq 'Activity') { 'Visible' } else { 'Collapsed' })

    $script:View = $Name
    $script:NavSetting = $true
    $UI.NavOverview.IsChecked = ($Name -eq 'Overview')
    $UI.NavMach2.IsChecked = ($Name -eq 'Mach2')
    $UI.NavPbi.IsChecked = ($Name -eq 'PBI')
    $UI.NavWeb.IsChecked = ($Name -eq 'Web')
    $UI.NavOther.IsChecked = ($Name -eq 'Other')
    $UI.NavDeploy.IsChecked = ($Name -eq 'Deploy')
    $UI.NavActivity.IsChecked = ($Name -eq 'Activity')
    $script:NavSetting = $false

    if ($isKiosk) { $script:Tab = $Name; Update-KioskView; Update-Detail }
    if ($Name -eq 'Deploy') { Update-DeployTargets; Update-DeployPreview }
    if ($Name -eq 'Activity') { Update-ReportList }
}

# Updates the status bar (kiosk/row counts, events file, credential).
function Update-StatusBar {
    $bits = @()
    if ($script:State -and $script:State.Ok) {
        $bits += '{0} kiosks' -f $script:State.Hosts.Count
        $bits += '{0} rows' -f $script:State.RowCount
    }
    $bits += (Split-Path -Leaf $script:CsvFile)
    $UI.StatusLeft.Text = ($bits -join '   |   ')
    $UI.StatusLeft.ToolTip = $script:CsvFile

    $cred = $(if (Test-Path -LiteralPath $CredentialFile) { 'kiosk-admin credential saved' } else { 'no saved credential - Save-KioskCredential.ps1' })
    $UI.StatusMid.Text = $cred
    $UI.StatusRight.Text = 'Kiosk Fleet Manager {0}' -f $ManagerVersion
}

# ---------------------------------------------------------------------------
# What the buttons do to a kiosk
#
# All of it goes over the kiosk's admin share with the kiosk-admin
# credential, exactly as the collector reads it, and all of it runs in the
# background: a kiosk that is switched off takes half a minute to say so.
#
# Every callback is handed what it needs ($Ctx from the job, $Data from the
# card). A scriptblock cannot see the variables of the function that made
# it, so anything written as { ... $Kiosk ... } would act on nothing.
# ---------------------------------------------------------------------------
# Returns the kiosk shown in the details panel.
function Get-SelectedKiosk {
    if (-not $script:DetailHost) { return $null }
    return (Get-Kiosk $script:DetailHost)
}

# Returns which launcher(s) a button acts on for a kiosk (NG, PBI, WEB or ALL).
function Get-LauncherKind {
    # Which launchers a button acts on: the screen picked in the card (its
    # launcher), or ALL - every launcher on every screen. '' for a kiosk
    # with no launcher at all.
    param($Kiosk)
    if (-not $Kiosk) { return '' }
    $target = Get-ScreenTarget $Kiosk
    if ($target.Screen) { return $target.Kind }
    $screens = @(if ($Kiosk.PSObject.Properties['Screens']) { $Kiosk.Screens })
    if ($screens.Count -or $Kiosk.Ng -or $Kiosk.Pbi -or ($Kiosk.PSObject.Properties['Web'] -and $Kiosk.Web)) { return 'ALL' }
    if ($TabKinds.ContainsKey([string]$Kiosk.Tab)) { return $TabKinds[[string]$Kiosk.Tab] }
    return ''
}

# --- restart ---------------------------------------------------------------
# Asks for confirmation (and an optional message) and restarts a kiosk.
function Show-RestartDialog {
    param($Kiosk)
    if (-not $Kiosk) { return }

    Show-Overlay -Title ('Restart {0}?' -f $Kiosk.Host) `
        -Subtitle ('{0}  |  {1}' -f $Kiosk.Location, $Kiosk.Type) `
        -Body 'The kiosk shows the message below, counts down, and then restarts. Anything running on it is closed.' `
        -Input1Label 'Message on the kiosk screen (empty for none)' -Input1Text $script:RestartMessage `
        -Input2Label 'Countdown in seconds (0 restarts at once)' -Input2Text "$($script:RestartSeconds)" `
        -OkText 'Restart the kiosk' -Danger -WithLog `
        -Note 'It comes back on its own.' `
        -Data @{ Host = $Kiosk.Host } `
        -OnOk {
            param($Values, $Data)
            $secs = 0
            if (-not [int]::TryParse(("$($Values.Input2)").Trim(), [ref]$secs) -or $secs -lt 0 -or $secs -gt 3600) {
                $UI.OverlayNote.Text = 'The countdown has to be a whole number of seconds, 0 to 3600.'
                $UI.OverlayNote.Foreground = $Brush.Crit
                return $false
            }
            $script:RestartMessage = ("$($Values.Input1)").Trim()
            $script:RestartSeconds = $secs

            $cred = Get-FleetCredential
            $UI.OverlayOk.IsEnabled = $false
            $UI.OverlayLogPanel.Visibility = 'Visible'
            Write-OverlayLog ('Restarting {0} ...' -f $Data.Host)
            Set-HostBusy $Data.Host 'restarting'

            [void](Start-FleetJob -Name 'restart' -Context @{
                    Target = $Data.Host; Secs = $secs; Message = $script:RestartMessage; Credential = $cred
                } -OnSay { param($t) Write-OverlayLog $t } -Body {
                    # Over CIM/DCOM (Lib\MWST.Remote.ps1). A countdown of 0
                    # restarts at once, with nothing on the screen.
                    $comment = if ($Ctx.Secs -gt 0) { $Ctx.Message } else { '' }
                    Send-KioskRestart -HostName $Ctx.Target -Credential $Ctx.Credential -WarningSeconds $Ctx.Secs -Comment $comment
                } -Done {
                    param($Result, $Err, $Ctx)
                    Set-HostBusy $Ctx.Target $null
                    $r = Get-JobValue $Result
                    if ($Err) { Write-OverlayLog "failed: $Err"; Set-OverlayFinished 'It did not go through.' 'CRITICAL'; return }
                    if ($r -and $r.Sent) {
                        Write-OverlayLog ('Sent over {0}.' -f $r.Via)
                        Set-OverlayFinished 'The kiosk restarts and comes back on its own.' 'OK'
                        Show-Toast ('{0} is restarting.' -f $Ctx.Target) 'OK'
                    }
                    else {
                        if ($r -and $r.Detail) { Write-OverlayLog $r.Detail }
                        Set-OverlayFinished 'It did not go through.' 'CRITICAL'
                    }
                })
            return $false
        }
}

# --- SCCM remote control ---------------------------------------------------
# Finds the ConfigMgr Remote Control viewer (CmRcViewer.exe).
function Get-CmRcViewerPath {
    param([string]$Explicit)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        return $null
    }
    $candidates = @()
    if ($env:SMS_ADMIN_UI_PATH) {
        $candidates += (Join-Path $env:SMS_ADMIN_UI_PATH 'CmRcViewer.exe')
        $candidates += (Join-Path $env:SMS_ADMIN_UI_PATH 'i386\CmRcViewer.exe')
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $root) { continue }
        foreach ($product in @('Microsoft Configuration Manager', 'Microsoft Endpoint Manager', 'Microsoft Endpoint Configuration Manager')) {
            $candidates += (Join-Path $root "$product\AdminConsole\bin\i386\CmRcViewer.exe")
            $candidates += (Join-Path $root "$product\AdminConsole\bin\CmRcViewer.exe")
        }
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

# Opens a ConfigMgr remote control session to a kiosk.
function Start-RemoteControl {
    param($Kiosk)
    if (-not $Kiosk) { return }

    if (-not $script:ViewerPath) {
        Show-Overlay -Title 'Remote control' -Body ("CmRcViewer.exe (SCCM remote control) is not on this PC.`r`n`r`n" +
            "Install the Configuration Manager console, or start the manager with -RemoteControlPath <path to CmRcViewer.exe>.") -OkText 'OK' -OnOk { $true }
        return
    }

    $argList = @($Kiosk.Host)
    if ($SccmSiteServer) { $argList += "\\$($SccmSiteServer.Trim().Trim('\'))" }
    try {
        Start-Process -FilePath $script:ViewerPath -ArgumentList $argList -WorkingDirectory (Split-Path -Parent $script:ViewerPath)
        Show-Toast ('Remote control opening for {0} - it has its own window.' -f $Kiosk.Host) 'OK'
    }
    catch { Show-Toast ("Could not start the viewer: {0}" -f $_.Exception.Message) 'CRITICAL' }
}

# --- a message on the kiosk screen -----------------------------------------
# Asks for a message and shows it on a kiosk screen.
function Show-MessageDialog {
    param($Kiosk)
    if (-not $Kiosk) { return }

    Show-Overlay -Title ('Message on {0}' -f $Kiosk.Host) `
        -Subtitle 'A window on the kiosk screen with an OK button and a countdown, put up by its watchdog.' `
        -Input1Label 'Message' -Input1Text '' `
        -Input2Label 'On screen for, at most, seconds' -Input2Text "$($script:MessageSeconds)" `
        -OkText 'Show it' -WithLog `
        -Data @{ Host = $Kiosk.Host } `
        -OnOk {
            param($Values, $Data)
            $text = ("$($Values.Input1)").Trim()
            if (-not $text) {
                $UI.OverlayNote.Text = 'Type the message first.'
                $UI.OverlayNote.Foreground = $Brush.Crit
                return $false
            }
            $secs = 0
            if (-not [int]::TryParse(("$($Values.Input2)").Trim(), [ref]$secs) -or $secs -lt 5 -or $secs -gt 900) {
                $UI.OverlayNote.Text = 'Between 5 and 900 seconds.'
                $UI.OverlayNote.Foreground = $Brush.Crit
                return $false
            }
            $script:MessageSeconds = $secs
            [void](Get-FleetCredential)
            $UI.OverlayOk.IsEnabled = $false
            $UI.OverlayLogPanel.Visibility = 'Visible'
            Set-HostBusy $Data.Host 'sending a message'

            [void](Start-FleetJob -Name 'message' -Context @{ Target = $Data.Host; Text = $text; Secs = $secs } `
                    -OnSay { param($t) Write-OverlayLog $t } -Body {
                    Invoke-KioskMessage -HostName $Ctx.Target -Text $Ctx.Text -Seconds $Ctx.Secs -Credential $Ctx.Credential `
                        -Progress { param($s) Say $s }
                } -Done {
                    param($Result, $Err, $Ctx)
                    Set-HostBusy $Ctx.Target $null
                    if ($Err) { Set-OverlayFinished $Err 'CRITICAL'; return }
                    $r = Get-JobValue $Result
                    $sev = switch ("$($r.Status)") {
                        'SHOWN' { 'OK' } 'ACKNOWLEDGED' { 'OK' } 'TIMEOUT' { 'WARNING' } default { 'CRITICAL' }
                    }
                    Write-OverlayLog ('{0}: {1}' -f $r.Status, $r.Detail)
                    Set-OverlayFinished ('{0}' -f $r.Status) $sev
                    Show-Toast ('{0}: message {1}' -f $Ctx.Target, $r.Status) $sev
                })
            return $false
        }
}

# --- reading a kiosk's launcher as it is right now -------------------------
# Reads a kiosk's launcher state right now over the admin share.
function Invoke-LiveRead {
    param($Kiosk)
    if (-not $Kiosk) { return }
    $kind = Get-LauncherKind $Kiosk
    if (-not $kind) { return }

    [void](Get-FleetCredential)
    Set-HostBusy $Kiosk.Host 'reading'
    Show-Toast ('Reading {0} ...' -f $Kiosk.Host) 'UNKNOWN' 3

    [void](Start-FleetJob -Name 'live' -Context @{ Target = $Kiosk.Host; Kind = $kind; Screen = (Get-ScreenTarget $Kiosk).Screen; Stale = $LiveStaleMinutes } -Body {
            $share = Open-KioskShare -HostName $Ctx.Target
            if ($share.Error) { return [pscustomobject]@{ Error = $share.Error } }
            try {
                # Every launcher asked for, as one: a kiosk can run several,
                # one per screen.
                $parts = @()
                if ($Ctx.Kind -in @('ALL', 'NG')) { $parts += Get-Mach2NgObservation -Folder (Join-Path $share.Root 'Users\Public\Documents') -StaleMinutes $Ctx.Stale }
                if ($Ctx.Kind -in @('ALL', 'PBI')) { $parts += Get-PbiLauncherObservation -Root $share.Root -StaleMinutes $Ctx.Stale -HostName $Ctx.Target }
                if ($Ctx.Kind -in @('ALL', 'WEB')) { $parts += Get-WebLauncherObservation -Root $share.Root -StaleMinutes $Ctx.Stale -HostName $Ctx.Target }
                $obs = [pscustomobject]@{
                    Installed = [bool]@($parts | Where-Object { $_.Installed }).Count
                    Instances = @($parts | ForEach-Object { $_.Instances } | Where-Object { -not $Ctx.Screen -or ([string]$_.Screen -eq $Ctx.Screen) })
                    Status    = @($parts | Where-Object { $_.Status } | ForEach-Object { $_.Status })[0]
                    Error     = (@($parts | Where-Object { $_.Error } | ForEach-Object { $_.Error }) -join '; ')
                }

                $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen)
                $lines = New-Object System.Collections.ArrayList
                $hold = $false
                $config = $null

                if (-not $obs.Installed) {
                    [void]$lines.Add([pscustomobject]@{ Label = 'Installed'; Value = 'no'; Warn = $true })
                }
                foreach ($d in $dirs) {
                    if (-not $config) { $config = Read-KioskJson -Path (Join-Path $d.Dir "$($Ctx.Target).json") }
                    if (Test-Path -LiteralPath (Join-Path $d.Dir 'hold.txt')) {
                        $hold = $true
                        [void]$lines.Add([pscustomobject]@{ Label = ('{0} {1}' -f $d.Instance, $d.Kind); Value = 'on hold (hold.txt) - no checks, no reloads'; Warn = $true })
                    }
                    if (Test-Path -LiteralPath (Join-Path $d.Dir 'kill.txt')) {
                        [void]$lines.Add([pscustomobject]@{ Label = $d.Instance; Value = 'kill.txt is waiting - the launcher stops when it sees it'; Warn = $true })
                    }
                }
                foreach ($i in @($obs.Instances)) {
                    $as = $(if ($i.PSObject.Properties['SignedInAs'] -and $i.SignedInAs) { " as $($i.SignedInAs)" } else { '' })
                    [void]$lines.Add([pscustomobject]@{
                            Label = $(if ($i.PSObject.Properties['Screen'] -and $i.Screen) { '{0} {1}' -f $i.Screen, $i.Launcher } else { [string]$i.Instance })
                            Value = ('{0}{1}, {2} old' -f $i.State, $as, (Format-Minutes $i.AgeMinutes))
                            Warn  = ($i.Severity -eq 'CRITICAL')
                        })
                    if ($i.Detail) { [void]$lines.Add([pscustomobject]@{ Label = ''; Value = [string]$i.Detail; Warn = $false }) }
                }
                if ($config) {
                    $url = $(if ($config.PSObject.Properties['DisplayURL']) { [string]$config.DisplayURL } elseif ($config.PSObject.Properties['URL']) { [string]$config.URL } else { '' })
                    if ($url) { [void]$lines.Add([pscustomobject]@{ Label = 'Shows'; Value = $url; Warn = $false }) }
                    $user = $(if ($config.PSObject.Properties['UserName']) { [string]$config.UserName } else { '' })
                    if ($user) { [void]$lines.Add([pscustomobject]@{ Label = 'Signs in as'; Value = $user; Warn = $false }) }
                }
                $pwState = 'none stored - signing in needs a person'
                if (-not @($dirs | Where-Object { $_.Kind -ne 'WEB' }).Count) { $pwState = 'none needed (a web page)' }
                foreach ($d in @($dirs | Where-Object { $_.Kind -ne 'WEB' })) {
                    if (Test-Path -LiteralPath (Join-Path $d.Dir 'password.seed')) { $pwState = 'a new one is waiting for the launcher'; break }
                    if (@(Get-ChildItem -LiteralPath $d.Dir -Filter '*.cred' -File -ErrorAction SilentlyContinue).Count) { $pwState = 'stored, encrypted for the kiosk account' }
                }
                [void]$lines.Add([pscustomobject]@{ Label = 'Password'; Value = $pwState; Warn = $false })
                if ($obs.Error) { [void]$lines.Add([pscustomobject]@{ Label = 'Error'; Value = [string]$obs.Error; Warn = $true }) }

                return [pscustomobject]@{
                    Error = $null; Status = $obs.Status; Hold = $hold; Lines = @($lines)
                    Instances = @($dirs | ForEach-Object { $_.Instance }); Installed = $obs.Installed
                }
            }
            finally { Close-KioskShare -Share $share }
        } -Done {
            param($Result, $Err, $Ctx)
            Set-HostBusy $Ctx.Target $null
            $r = Get-JobValue $Result
            if ($Err -or -not $r) { Show-Toast ("Could not read {0}: {1}" -f $Ctx.Target, $(if ($Err) { $Err } else { 'no answer' })) 'CRITICAL'; return }
            if ($r.Error) { Show-Toast ("{0}: {1}" -f $Ctx.Target, $r.Error) 'CRITICAL'; return }

            $script:LiveObs[$Ctx.Target] = [pscustomobject]@{ At = Get-Date; Lines = @($r.Lines) }
            $script:HoldState[$Ctx.Target] = [bool]$r.Hold
            if ($script:DetailHost -eq $Ctx.Target) { Update-Detail }
            Show-Toast ('{0}: read just now.' -f $Ctx.Target) 'OK' 4
        })
}

# --- control files ---------------------------------------------------------
# Drops a control file (reload, restart browser, stop, hold, ...) and waits for the launcher to act.
function Send-LauncherControl {
    <#
        Drops a control file in every one of the kiosk's launcher folders and
        waits for the launcher to take it, which is how it says it has acted.
    #>
    param($Kiosk, [string]$FileName, [string]$Doing, [switch]$Delete)

    $kind = Get-LauncherKind $Kiosk
    if (-not $kind) { return }
    [void](Get-FleetCredential)
    Set-HostBusy $Kiosk.Host $Doing
    Show-Toast ('{0}: {1} ...' -f $Kiosk.Host, $Doing) 'UNKNOWN' 4

    [void](Start-FleetJob -Name 'control' -Context @{
            Target = $Kiosk.Host; Kind = $kind; Screen = (Get-ScreenTarget $Kiosk).Screen; File = $FileName; Remove = [bool]$Delete; Doing = $Doing
        } -Body {
            $share = Open-KioskShare -HostName $Ctx.Target
            if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
            try {
                $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen)
                if ($dirs.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Detail = 'the launcher is not installed here' } }
                $taken = 0
                $sent = 0
                foreach ($d in $dirs) {
                    $path = Join-Path $d.Dir $Ctx.File
                    if ($Ctx.Remove) {
                        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                        $sent++
                        $taken++
                        continue
                    }
                    [IO.File]::WriteAllText($path, ('{0} by {1}\{2} from Kiosk Fleet Manager' -f (Get-Date -Format s), $env:USERDOMAIN, $env:USERNAME))
                    $sent++
                    if (Wait-ControlFileTaken -Path $path -Seconds 20) { $taken++ }
                }
                return [pscustomobject]@{ Ok = $true; Sent = $sent; Taken = $taken; Instances = @($dirs | ForEach-Object { $_.Instance }) }
            }
            catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
            finally { Close-KioskShare -Share $share }
        } -Done {
            param($Result, $Err, $Ctx)
            Set-HostBusy $Ctx.Target $null
            $r = Get-JobValue $Result
            if ($Err -or -not $r) { Show-Toast ("{0}: {1}" -f $Ctx.Target, $(if ($Err) { $Err } else { 'no answer' })) 'CRITICAL'; return }
            if (-not $r.Ok) { Show-Toast ('{0}: {1}' -f $Ctx.Target, $r.Detail) 'CRITICAL'; return }

            if ($Ctx.File -eq 'hold.txt') { $script:HoldState[$Ctx.Target] = (-not $Ctx.Remove) }
            Update-ActionButtons
            if ($r.Taken -ge $r.Sent) { Show-Toast ('{0}: {1} - the launcher has taken it.' -f $Ctx.Target, $Ctx.Doing) 'OK' }
            else { Show-Toast ('{0}: {1} - not taken within 20 s. It stays, and the launcher acts on it when it next looks.' -f $Ctx.Target, $Ctx.Doing) 'WARNING' 8 }
        })
}

# --- a picture of what is on the kiosk screen ------------------------------
# Asks the launcher for a screenshot of the kiosk screen and opens it.
function Invoke-Snapshot {
    param($Kiosk)
    $kind = Get-LauncherKind $Kiosk
    if (-not $kind) { return }
    [void](Get-FleetCredential)
    Set-HostBusy $Kiosk.Host 'taking a screenshot'
    Show-Toast ('{0}: asking for a screenshot ...' -f $Kiosk.Host) 'UNKNOWN' 5

    [void](Start-FleetJob -Name 'snapshot' -Context @{
            Target = $Kiosk.Host; Kind = $kind; Screen = (Get-ScreenTarget $Kiosk).Screen; Dest = $SnapshotDir
        } -Body {
            $share = Open-KioskShare -HostName $Ctx.Target
            if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
            try {
                $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen)
                if ($dirs.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Detail = 'the launcher is not installed here' } }

                $before = @{}
                foreach ($d in $dirs) {
                    foreach ($f in @(Get-ChildItem -LiteralPath $d.Status -Filter '*.snapshot.json' -File -ErrorAction SilentlyContinue)) {
                        $before[$f.FullName] = $f.LastWriteTimeUtc
                    }
                    [IO.File]::WriteAllText((Join-Path $d.Dir 'snapshot.txt'),
                        ('{0} by {1}\{2} from Kiosk Fleet Manager' -f (Get-Date -Format s), $env:USERDOMAIN, $env:USERNAME))
                }

                $deadline = (Get-Date).AddSeconds(45)
                $info = $null
                $where = $null
                while (-not $info -and (Get-Date) -lt $deadline) {
                    foreach ($d in $dirs) {
                        foreach ($f in @(Get-ChildItem -LiteralPath $d.Status -Filter '*.snapshot.json' -File -ErrorAction SilentlyContinue)) {
                            $was = $(if ($before.ContainsKey($f.FullName)) { $before[$f.FullName] } else { [datetime]::MinValue })
                            if ($f.LastWriteTimeUtc -le $was) { continue }
                            $j = Read-KioskJson -Path $f.FullName
                            if ($j) { $info = $j; $where = $d; break }
                        }
                        if ($info) { break }
                    }
                    if (-not $info) { Start-Sleep -Milliseconds 500 }
                }
                if (-not $info) { return [pscustomobject]@{ Ok = $false; Detail = 'no screenshot came back within 45 s' } }

                $out = [pscustomobject]@{
                    Ok = $true; Detail = ''; Image = ''; State = [string]$info.State; Url = [string]$info.Url
                    Title = [string]$info.Title; Instance = $where.Instance; Error = [string]$info.Error
                }
                if ($info.Error -or -not $info.Image) {
                    $out.Ok = $false
                    $out.Detail = $(if ($info.Error) { [string]$info.Error } else { 'the launcher saved no picture' })
                    return $out
                }
                $src = Join-Path $where.Status ([string]$info.Image)
                if (-not (Test-Path -LiteralPath $src)) { $out.Ok = $false; $out.Detail = "the picture is missing: $src"; return $out }
                if (-not (Test-Path -LiteralPath $Ctx.Dest)) { New-Item -ItemType Directory -Path $Ctx.Dest -Force | Out-Null }
                $dest = Join-Path $Ctx.Dest ('{0}_{1}_{2}.png' -f $Ctx.Target, $where.Instance, (Get-Date -Format 'yyyyMMdd-HHmmss'))
                Copy-Item -LiteralPath $src -Destination $dest -Force
                $out.Image = $dest
                return $out
            }
            catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
            finally { Close-KioskShare -Share $share }
        } -Done {
            param($Result, $Err, $Ctx)
            Set-HostBusy $Ctx.Target $null
            $r = Get-JobValue $Result
            if ($Err -or -not $r) { Show-Toast ("{0}: {1}" -f $Ctx.Target, $(if ($Err) { $Err } else { 'no answer' })) 'CRITICAL'; return }
            if (-not $r.Ok) { Show-Toast ('{0}: {1}' -f $Ctx.Target, $r.Detail) 'WARNING' 8; return }

            $script:LastSnapshot = $r.Image
            if ($script:DetailHost -eq $Ctx.Target) {
                try {
                    $img = New-Object System.Windows.Media.Imaging.BitmapImage
                    $img.BeginInit()
                    $img.CacheOption = 'OnLoad'
                    $img.UriSource = New-Object System.Uri($r.Image)
                    $img.EndInit()
                    $img.Freeze()
                    $UI.SnapshotImage.Source = $img
                    $UI.SnapshotCaption.Text = ('{0} {1}  |  {2}  |  {3}' -f $r.Instance, (Get-Date).ToString('HH:mm:ss'), $r.State, $r.Url)
                    $UI.SnapshotCard.Visibility = 'Visible'
                }
                catch { Show-Toast ("Could not show the picture: {0}" -f $_.Exception.Message) 'WARNING' }
            }
            Show-Toast ('{0}: screenshot saved.' -f $Ctx.Target) 'OK'
        })
}

# --- the launcher's own log ------------------------------------------------
# Shows the end of a kiosk's launcher log.
function Show-LauncherLog {
    param($Kiosk)
    $kind = Get-LauncherKind $Kiosk
    if (-not $kind) { return }
    [void](Get-FleetCredential)

    Show-Overlay -Title ('{0} - launcher log' -f $Kiosk.Host) -Subtitle 'The end of the log the launcher writes on the kiosk.' -WithLog -OnOk { $true }
    Set-OverlayFinished '' 'OK'
    Write-OverlayLog 'reading ...'
    Set-HostBusy $Kiosk.Host 'reading the log'

    [void](Start-FleetJob -Name 'log' -Context @{ Target = $Kiosk.Host; Kind = $kind; Screen = (Get-ScreenTarget $Kiosk).Screen; Lines = 60 } -Body {
            $share = Open-KioskShare -HostName $Ctx.Target
            if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
            try {
                $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen)
                if ($dirs.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Detail = 'the launcher is not installed here' } }
                $d = $dirs[0]
                $config = Read-KioskJson -Path (Join-Path $d.Dir "$($Ctx.Target).json")
                $logDir = Join-Path $d.Dir 'Logs'
                $name = ''
                if ($config) {
                    if ($config.PSObject.Properties['LogPath'] -and $config.LogPath) {
                        $p = [string]$config.LogPath
                        if ($p -match '^([A-Za-z]):\\?(.*)$') {
                            $logDir = $(if ($Matches[1] -ieq 'C') { Join-Path $share.Root $Matches[2] } else { '\\{0}\{1}$\{2}' -f $Ctx.Target, $Matches[1].ToUpperInvariant(), $Matches[2] })
                        }
                    }
                    if ($config.PSObject.Properties['LogName'] -and $config.LogName) { $name = [string]$config.LogName }
                }
                $path = $(if ($name) { Join-Path $logDir $name } else { '' })
                if (-not $path -or -not (Test-Path -LiteralPath $path)) {
                    $newest = @(Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTimeUtc -Descending)[0]
                    if (-not $newest) { return [pscustomobject]@{ Ok = $false; Detail = "no log in $logDir" } }
                    $path = $newest.FullName
                }

                $share2 = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
                $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share2)
                try {
                    if ($fs.Length -gt 262144) { [void]$fs.Seek(-262144, [IO.SeekOrigin]::End) }
                    $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
                    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                }
                finally { $fs.Dispose() }

                $entries = [regex]::Matches($text, '<!\[LOG\[(?<m>.*?)\]LOG\]!><time="(?<t>\d\d:\d\d:\d\d)[^"]*" date="(?<d>[^"]*)"[^>]*?type="(?<ty>\d)"',
                    [Text.RegularExpressions.RegexOptions]::Singleline)
                $out = New-Object System.Collections.ArrayList
                for ($i = [math]::Max(0, $entries.Count - $Ctx.Lines); $i -lt $entries.Count; $i++) {
                    $e = $entries[$i]
                    $d2 = $e.Groups['d'].Value
                    if ($d2 -match '^(\d\d)-(\d\d)-\d{4}$') { $d2 = "$($Matches[2]).$($Matches[1])." }
                    $mark = switch ($e.Groups['ty'].Value) { '3' { '!' } '2' { '*' } default { ' ' } }
                    [void]$out.Add(('{0} {1,-7}{2}  {3}' -f $mark, $d2, $e.Groups['t'].Value, ($e.Groups['m'].Value.TrimEnd() -replace "\r?\n", ' ')))
                }
                if ($entries.Count -eq 0) { [void]$out.Add('(no entries)') }
                return [pscustomobject]@{ Ok = $true; Path = $path; Lines = @($out) }
            }
            catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
            finally { Close-KioskShare -Share $share }
        } -Done {
            param($Result, $Err, $Ctx)
            Set-HostBusy $Ctx.Target $null
            $r = Get-JobValue $Result
            $UI.OverlayLog.Text = ''
            if ($Err -or -not $r) { Write-OverlayLog ("could not read it: {0}" -f $(if ($Err) { $Err } else { 'no answer' })); return }
            if (-not $r.Ok) { Write-OverlayLog $r.Detail; return }
            $UI.OverlaySub.Text = $r.Path
            foreach ($line in @($r.Lines)) { Write-OverlayLog $line }
        })
}

# --- the sign-in password --------------------------------------------------
# Asks for a new sign-in password and sends it to the kiosk as password.seed.
function Show-PasswordDialog {
    param($Kiosk)
    $kind = Get-LauncherKind $Kiosk
    if (-not $kind) { return }

    $who = $(if ($kind -eq 'PBI') { 'the Power BI account' } elseif ($kind -eq 'NG') { 'the Mach2 station account' } else { "every screen's sign-in account (not the web pages')" })
    Show-Overlay -Title ('Sign-in password for {0}' -f $Kiosk.Host) `
        -Subtitle ("The new password for {0}. The launcher encrypts it for the kiosk account, checks it reads back, and wipes what you typed." -f $who) `
        -Password -PasswordLabel 'New password' -OkText 'Hand it over' -WithLog `
        -Note 'Only the password changes; the account stays the one in the kiosk config.' `
        -Data @{ Host = $Kiosk.Host; Kind = $kind; Screen = (Get-ScreenTarget $Kiosk).Screen } `
        -OnOk {
            param($Values, $Data)
            if (-not $Values.Password) {
                $UI.OverlayNote.Text = 'Type the password first.'
                $UI.OverlayNote.Foreground = $Brush.Crit
                return $false
            }
            if ($Values.Password -cne $Values.Password2) {
                $UI.OverlayNote.Text = 'The two did not match. Nothing was changed.'
                $UI.OverlayNote.Foreground = $Brush.Crit
                return $false
            }
            [void](Get-FleetCredential)
            $UI.OverlayOk.IsEnabled = $false
            $UI.OverlayLogPanel.Visibility = 'Visible'
            Write-OverlayLog 'writing password.seed ...'
            Set-HostBusy $Data.Host 'setting the password'
            $secure = $UI.OverlayPass.SecurePassword
            $UI.OverlayPass.Password = ''
            $UI.OverlayPass2.Password = ''

            [void](Start-FleetJob -Name 'password' -Context @{ Target = $Data.Host; Kind = $Data.Kind; Screen = $Data.Screen; Secret = $secure } `
                    -OnSay { param($t) Write-OverlayLog $t } -Body {
                    $share = Open-KioskShare -HostName $Ctx.Target
                    if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
                    $plain = $null
                    try {
                        # A web page signs in to nothing.
                        $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen | Where-Object { $_.Kind -ne 'WEB' })
                        if ($dirs.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Detail = 'no launcher that signs in on this screen' } }
                        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Ctx.Secret)
                        try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
                        finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }

                        $seeds = @()
                        foreach ($d in $dirs) {
                            $seed = Join-Path $d.Dir 'password.seed'
                            $tmp = "$seed.tmp"
                            [IO.File]::WriteAllText($tmp, $plain, (New-Object Text.UTF8Encoding($false)))
                            Move-Item -LiteralPath $tmp -Destination $seed -Force
                            $seeds += $seed
                        }
                        Say 'written - waiting for the launcher to store it'
                        $deadline = (Get-Date).AddSeconds(30)
                        while ((Get-Date) -lt $deadline) {
                            if (@($seeds | Where-Object { Test-Path -LiteralPath $_ }).Count -eq 0) {
                                return [pscustomobject]@{ Ok = $true; Detail = 'stored; the launcher uses it from the next sign-in on' }
                            }
                            Start-Sleep -Milliseconds 500
                        }
                        return [pscustomobject]@{ Ok = $true; Detail = 'not taken yet - the launcher stores it when it next starts'; Waiting = $true }
                    }
                    catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
                    finally { $plain = $null; Close-KioskShare -Share $share }
                } -Done {
                    param($Result, $Err, $Ctx)
                    Set-HostBusy $Ctx.Target $null
                    $r = Get-JobValue $Result
                    if ($Err -or -not $r) { Set-OverlayFinished ("failed: {0}" -f $(if ($Err) { $Err } else { 'no answer' })) 'CRITICAL'; return }
                    Write-OverlayLog $r.Detail
                    Set-OverlayFinished $r.Detail $(if ($r.Ok) { $(if ($r.Waiting) { 'WARNING' } else { 'OK' }) } else { 'CRITICAL' })
                })
            return $false
        }
}

# Opens the kiosk's Public Documents folder in Explorer.
function Open-KioskFolder {
    param($Kiosk)
    if (-not $Kiosk) { return }
    $path = ($KioskRootTemplate -f $Kiosk.Host) + '\' + $PublicDocsRel
    try { Start-Process explorer.exe $path }
    catch { Show-Toast ("Could not open {0}: {1}" -f $path, $_.Exception.Message) 'WARNING' }
}

# ---------------------------------------------------------------------------
# The kiosk's own settings
#
# Both launchers keep one JSON file per screen on the kiosk and watch it: a
# changed config applies within seconds, without a restart. So the editor
# reads that file over the share, shows it, and writes it back - and the
# same card, filled from EXAMPLE.json instead, is how a kiosk that has no
# config yet gets one (which is what a new kiosk needs before a deploy will
# touch it).
# ---------------------------------------------------------------------------
$ConfigPrimary = @{
    NG  = @('DisplayURL', 'LoginURL', 'UserName', 'ScreenSelect')
    PBI = @('DisplayURL', 'UserName', 'ScreenSelect')
    WEB = @('DisplayURL', 'TargetMatch', 'ScreenSelect')
}
# The settings a config cannot do without.
$ConfigRequired = @{ NG = @('DisplayURL', 'UserName'); PBI = @('DisplayURL', 'UserName'); WEB = @('DisplayURL') }
$ConfigLabels = @{
    NG  = @{
        DisplayURL   = @{ Label = 'Dashboard URL'; Hint = 'The station page this screen shows.' }
        LoginURL     = @{ Label = 'Sign-in URL'; Hint = "Left empty, it becomes the dashboard URL's host plus /prelogin?clear=true." }
        UserName     = @{ Label = 'Station user'; Hint = 'The Niagara account the launcher signs in as.' }
        ScreenSelect = @{ Label = 'Screen'; Hint = '1 is the first screen. A second screen (S2) usually shows 2.' }
    }
    PBI = @{
        DisplayURL   = @{ Label = 'Report URL'; Hint = 'The Power BI report this screen shows.' }
        UserName     = @{ Label = 'Power BI account'; Hint = 'The account the launcher signs in as.' }
        ScreenSelect = @{ Label = 'Screen'; Hint = '1 is the first screen.' }
    }
    WEB = @{
        DisplayURL   = @{ Label = 'Page URL'; Hint = 'The web page this screen shows. No sign-in: the launcher shows the page as it comes.' }
        TargetMatch  = @{ Label = 'Stays on'; Hint = 'path (the page and the pages under it), host (anywhere on the site) or exact (only this address).' }
        ScreenSelect = @{ Label = 'Screen'; Hint = '1 is the first screen. A second screen (S2) usually shows 2.' }
    }
}

# Reads a launcher's EXAMPLE.json as the starting config for a new kiosk or screen.
function Get-ConfigTemplate {
    # EXAMPLE.json as it ships here, in file order, with the kiosk's own name
    # where the example had one.
    param([string]$Kind, [string]$HostName, [string]$Instance = 'S1')

    $folder = @{ NG = 'Mach2LauncherNG'; PBI = 'PbiLauncher'; WEB = 'WebLauncher' }[$Kind]
    $path = Join-Path $ScriptDir "$folder\EXAMPLE.json"
    $pairs = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path)) { return @($pairs) }
    try { $json = @(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path)))[0] }
    catch { return @($pairs) }

    foreach ($p in $json.PSObject.Properties) {
        $value = [string]$p.Value
        switch ($p.Name) {
            'LogName' {
                # Each screen its own log: the central folder holds every kiosk's.
                $suffix = $(if ($Instance -and $Instance -ne 'S1') { "_$Instance" } else { '' })
                $value = switch ($Kind) { 'NG' { "${HostName}${suffix}_Mach2LauncherNG.log" } 'PBI' { "PbiLauncher_$HostName$suffix.log" } default { "WebLauncher_$HostName$suffix.log" } }
            }
            'DisplayURL' { $value = '' }
            'LoginURL' { $value = '' }
            'UserName' { $value = '' }
        }
        [void]$pairs.Add([pscustomobject]@{ Key = $p.Name; Value = $value })
    }
    return @($pairs)
}

# Builds the config editor fields: important ones first, the rest under "More settings".
function New-ConfigFieldList {
    <#
        The card's fields for a config: the few that matter first, the
        password, then everything else in the file under "More settings".
    #>
    param([string]$Kind, [array]$Pairs, [switch]$IsNew)

    $labels = $ConfigLabels[$Kind]
    $primary = $ConfigPrimary[$Kind]
    $fields = New-Object System.Collections.ArrayList

    foreach ($key in $primary) {
        # A key the file does not have is still offered: both launchers need
        # DisplayURL and UserName, and a config missing one is broken.
        $pair = @($Pairs | Where-Object { $_.Key -eq $key })[0]
        $label = $key
        $hint = ''
        if ($labels.ContainsKey($key)) { $label = $labels[$key].Label; $hint = $labels[$key].Hint }
        [void]$fields.Add(@{ Key = $key; Label = $label; Value = $(if ($pair) { $pair.Value } else { '' }); Hint = $hint })
    }

    # A web page signs in to nothing.
    if ($Kind -ne 'WEB') {
    [void]$fields.Add(@{
            Key   = '__password'; Kind = 'password'; Label = 'Sign-in password'
            Hint  = $(if ($IsNew) { 'Handed to the launcher as password.seed; it encrypts it for the kiosk account.' }
                else { 'Leave both empty to keep the password already stored on the kiosk.' })
        })
    }

    $rest = @($Pairs | Where-Object { $primary -notcontains $_.Key })
    if ($rest.Count) {
        foreach ($pair in $rest) {
            $field = @{ Key = $pair.Key; Label = $pair.Key; Value = $pair.Value; Advanced = $true }
            if ($pair.Key -in @('EnableRefresh', 'KioskMode', 'UsePriScreen', 'ScheduledRestartEnabled', 'DisableStartup',
                    'DebugLogging', 'Watchdog', 'StopOldLauncher', 'InPrivate', 'StaySignedIn', 'BackButton')) {
                $field.Kind = 'bool'
                $field.Hint = 'on'
            }
            [void]$fields.Add($field)
        }
    }
    return @($fields)
}

# Opens a kiosk screen's launcher config for editing (or EXAMPLE.json for a new one) and saves it.
function Show-ConfigEditor {
    <#
        Reads the kiosk's config over the share and opens it. A kiosk with no
        config yet - a new one - gets the fields from EXAMPLE.json instead,
        which is exactly what the deploy asks for before it will install.
    #>
    param($Kiosk, [string]$HostName, [string]$Kind, [string]$Instance)

    if ($Kiosk) { $HostName = $Kiosk.Host }
    if ($Kiosk -and (-not $Kind -or $Kind -eq 'ALL')) {
        # Only one screen, or one picked in the card: that one.
        $target = Get-ScreenTarget $Kiosk
        $screens = @(if ($Kiosk.PSObject.Properties['Screens']) { $Kiosk.Screens })
        if ($target.Screen) { $Kind = $target.Kind; $Instance = $target.Screen }
        elseif ($screens.Count -eq 1) { $Kind = $KindOfScreenLauncher[[string]$screens[0].Launcher]; $Instance = [string]$screens[0].Screen }
        elseif ($TabKinds.ContainsKey([string]$Kiosk.Tab)) { $Kind = $TabKinds[[string]$Kiosk.Tab] }
    }
    if (-not $HostName -or -not $Kind -or $Kind -eq 'ALL') { return }

    [void](Get-FleetCredential)
    Show-Overlay -Title ('Config for {0}' -f $HostName) -Subtitle 'reading the kiosk ...' -WithLog -OnOk { $true }
    Set-OverlayFinished '' 'OK'
    Write-OverlayLog 'reading ...'

    [void](Start-FleetJob -Name 'config-read' -Context @{ Target = $HostName; Kind = $Kind; Instance = $Instance } -Body {
            $share = Open-KioskShare -HostName $Ctx.Target
            if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
            try {
                $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen)
                $instances = @($dirs | ForEach-Object { $_.Instance })
                $instance = $(if ($Ctx.Instance) { $Ctx.Instance } elseif ($instances.Count) { $instances[0] } else { 'S1' })
                # Which launcher has which screen, so a new config does not
                # land on a screen another launcher shows.
                $taken = @{}
                foreach ($d in @(Get-LauncherDirs -Root $share.Root -Kind 'ALL' -HostName $Ctx.Target)) { if ($d.Kind -ne $Ctx.Kind) { $taken[$d.Instance] = $d.Kind } }

                $dir = @($dirs | Where-Object { $_.Instance -eq $instance })[0]
                $pairs = @()
                $exists = $false
                $password = 'none stored'
                if ($dir) {
                    $config = Read-KioskJson -Path (Join-Path $dir.Dir "$($Ctx.Target).json")
                    if ($config) {
                        $exists = $true
                        $pairs = @($config.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Value = [string]$_.Value } })
                    }
                    if (Test-Path -LiteralPath (Join-Path $dir.Dir 'password.seed')) { $password = 'a new one is waiting for the launcher' }
                    elseif (@(Get-ChildItem -LiteralPath $dir.Dir -Filter '*.cred' -File -ErrorAction SilentlyContinue).Count) { $password = 'stored, encrypted for the kiosk account' }
                }
                return [pscustomobject]@{
                    Ok = $true; Exists = $exists; Instance = $instance; Instances = $instances
                    Pairs = $pairs; Password = $password; Taken = $taken
                }
            }
            catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
            finally { Close-KioskShare -Share $share }
        } -Done {
            param($Result, $Err, $Ctx)
            $r = Get-JobValue $Result
            if ($Err -or -not $r) { Write-OverlayLog ("could not read it: {0}" -f $(if ($Err) { $Err } else { 'no answer' })); return }
            if (-not $r.Ok) { Write-OverlayLog $r.Detail; return }

            $pairs = @($r.Pairs)
            $isNew = (-not $r.Exists)
            if ($isNew) { $pairs = @(Get-ConfigTemplate -Kind $Ctx.Kind -HostName $Ctx.Target -Instance $r.Instance) }

            $where = ('screen {0}, {1}' -f $r.Instance, $LauncherNames[$Ctx.Kind])
            $subtitle = $(if ($isNew) {
                    'No config on the kiosk yet: this is EXAMPLE.json, for you to fill in. Saving it writes {0}.json, which is what a new kiosk needs before a deploy will install anything.' -f $Ctx.Target
                }
                else { 'The launcher reads its config every few seconds, so a change applies without a restart. Password: {0}.' -f $r.Password })
            if (@($r.Instances).Count -gt 1) { $subtitle += ('  This kiosk has {0}; this is {1}.' -f (@($r.Instances) -join ', '), $r.Instance) }

            $fields = @(New-ConfigFieldList -Kind $Ctx.Kind -Pairs $pairs -IsNew:$isNew)
            if ($isNew) {
                # Which screen this config is for: a second screen on the same
                # PC is S2, with its own folder, config and shortcut - and any
                # launcher: Power BI on S1 and the Mach2 dashboard on S2.
                $takenText = @(@($r.Taken.Keys) | Sort-Object | ForEach-Object { '{0} ({1})' -f $_, $LauncherNames[$r.Taken[$_]] })
                $fields = @(@{ Key = '__instance'; Label = 'Screen folder'; Value = $r.Instance
                        Hint = ('S1 is the first screen, S2 the second, each with its own config.{0}' -f $(if ($takenText.Count) { ' Taken already: ' + ($takenText -join ', ') + '.' } else { '' }))
                    }) + $fields
            }

            Show-Overlay -Title ('{0} - {1}' -f $Ctx.Target, $where) -Subtitle $subtitle `
                -Fields $fields `
                -OkText $(if ($isNew) { 'Write it to the kiosk' } else { 'Save to the kiosk' }) -WithLog `
                -Data @{ Host = $Ctx.Target; Kind = $Ctx.Kind; Instance = $r.Instance; Pairs = $pairs; IsNew = $isNew; Taken = $r.Taken } `
                -OnOk {
                param($Values, $Data)
                $typed = Get-OverlayFields
                if ($typed['__password'] -cne $typed['__password.Again']) {
                    $UI.OverlayNote.Text = 'The two passwords did not match. Nothing was saved.'
                    $UI.OverlayNote.Foreground = $Brush.Crit
                    return $false
                }
                $missing = @($ConfigRequired[$Data.Kind] | Where-Object { -not $typed[$_] })
                if ($missing.Count) {
                    $UI.OverlayNote.Text = ('Still empty: {0}.' -f ($missing -join ', '))
                    $UI.OverlayNote.Foreground = $Brush.Crit
                    return $false
                }

                # Back into file order, with what was typed, and any setting
                # the file was missing added at the end.
                $pairs = @(foreach ($p in @($Data.Pairs)) {
                        $v = $(if ($typed.ContainsKey($p.Key)) { $typed[$p.Key] } else { $p.Value })
                        [pscustomobject]@{ Key = $p.Key; Value = [string]$v }
                    })
                foreach ($key in $ConfigPrimary[$Data.Kind]) {
                    if (@($pairs | Where-Object { $_.Key -eq $key }).Count) { continue }
                    if (-not $typed.ContainsKey($key)) { continue }
                    $pairs += [pscustomobject]@{ Key = $key; Value = [string]$typed[$key] }
                }
                $secret = Get-OverlayFieldSecret '__password'
                if (-not $typed['__password']) { $secret = $null }

                $instance = [string]$Data.Instance
                if ($typed.ContainsKey('__instance')) {
                    $instance = ("$($typed['__instance'])").Trim().ToUpperInvariant()
                    if ($instance -notmatch '^S\d+$') {
                        $UI.OverlayNote.Text = 'A screen folder is named like S1 or S2.'
                        $UI.OverlayNote.Foreground = $Brush.Crit
                        return $false
                    }
                    if ($Data.Taken -and $Data.Taken.ContainsKey($instance)) {
                        $UI.OverlayNote.Text = ('{0} shows {1} already - one launcher per screen. Pick another screen folder.' -f $instance, $LauncherNames[$Data.Taken[$instance]])
                        $UI.OverlayNote.Foreground = $Brush.Crit
                        return $false
                    }
                }

                $UI.OverlayOk.IsEnabled = $false
                $UI.OverlayLogPanel.Visibility = 'Visible'
                Write-OverlayLog ('writing {0}.json to {1} ...' -f $Data.Host, $instance)
                Set-HostBusy $Data.Host 'writing the config'

                [void](Start-FleetJob -Name 'config-write' -Context @{
                        Target = $Data.Host; Kind = $Data.Kind; Instance = $instance; Pairs = $pairs
                        Secret = $secret; IsNew = [bool]$Data.IsNew
                    } -OnSay { param($t) Write-OverlayLog $t } -Body {
                        $share = Open-KioskShare -HostName $Ctx.Target
                        if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
                        $plain = $null
                        try {
                            $dir = Get-ScreenDir -Root $share.Root -Kind $Ctx.Kind -Instance $Ctx.Instance -HostName $Ctx.Target
                            # One launcher per screen, checked again on the kiosk itself.
                            $other = @(Get-LauncherDirs -Root $share.Root -Kind 'ALL' -HostName $Ctx.Target -Screen $Ctx.Instance | Where-Object { $_.Kind -ne $Ctx.Kind })
                            if ($other.Count) { return [pscustomobject]@{ Ok = $false; Detail = ('{0} already has a config for {1} Launcher - one launcher per screen' -f $Ctx.Instance, $other[0].Kind) } }
                            if (-not (Test-Path -LiteralPath $dir)) {
                                New-Item -ItemType Directory -Path $dir -Force | Out-Null
                                Say "created $dir"
                            }

                            # A sign-in URL left empty is the dashboard's host.
                            $values = [ordered]@{}
                            foreach ($p in @($Ctx.Pairs)) { $values[$p.Key] = [string]$p.Value }
                            # Only the kiosk's first Mach2 screen is the watchdog:
                            # two on one PC would both want to restart it. S2
                            # can be the first where S1 shows Power BI.
                            if ($Ctx.Kind -eq 'NG' -and $Ctx.IsNew -and $values.Contains('Watchdog')) {
                                $ng = @(Get-LauncherDirs -Root $share.Root -Kind 'NG' -HostName $Ctx.Target | Where-Object { $_.Instance -ne $Ctx.Instance })
                                $first = -not @($ng | Where-Object { [string]::CompareOrdinal($_.Instance, $Ctx.Instance) -lt 0 }).Count
                                $values['Watchdog'] = $(if ($first) { '1' } else { '0' })
                                Say $(if ($first) { 'the first Mach2 screen here, so it is the watchdog' } else { 'not the first Mach2 screen here, so it is not the watchdog' })
                            }
                            if ($Ctx.Kind -eq 'NG' -and $values.Contains('LoginURL') -and -not $values['LoginURL'] -and $values['DisplayURL']) {
                                try {
                                    $u = [uri]$values['DisplayURL']
                                    $values['LoginURL'] = ('{0}://{1}/prelogin?clear=true' -f $u.Scheme, $u.Authority)
                                    Say ('sign-in URL: {0}' -f $values['LoginURL'])
                                }
                                catch { }
                            }

                            $configPath = Join-Path $dir "$($Ctx.Target).json"
                            if (Test-Path -LiteralPath $configPath) {
                                $backup = '{0}.bak-{1}' -f $configPath, (Get-Date -Format 'yyyyMMdd-HHmmss')
                                Copy-Item -LiteralPath $configPath -Destination $backup -Force
                                Say ('the old one is kept as {0}' -f (Split-Path -Leaf $backup))
                            }
                            $json = ConvertTo-Json -InputObject ([pscustomobject]$values) -Depth 4
                            $tmp = "$configPath.tmp"
                            [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
                            Move-Item -LiteralPath $tmp -Destination $configPath -Force

                            $out = [pscustomobject]@{ Ok = $true; Detail = 'saved'; Path = $configPath; Password = '' }
                            if ($Ctx.Secret) {
                                $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Ctx.Secret)
                                try { $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
                                finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
                                $seed = Join-Path $dir 'password.seed'
                                [IO.File]::WriteAllText("$seed.tmp", $plain, (New-Object Text.UTF8Encoding($false)))
                                Move-Item -LiteralPath "$seed.tmp" -Destination $seed -Force
                                Say 'password.seed written'
                                $deadline = (Get-Date).AddSeconds(20)
                                while ((Get-Date) -lt $deadline) {
                                    if (-not (Test-Path -LiteralPath $seed)) { break }
                                    Start-Sleep -Milliseconds 500
                                }
                                $out.Password = $(if (Test-Path -LiteralPath $seed) { 'waiting for the launcher to store it' } else { 'stored by the launcher' })
                            }
                            return $out
                        }
                        catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
                        finally { $plain = $null; Close-KioskShare -Share $share }
                    } -Done {
                        param($Result, $Err, $Ctx)
                        Set-HostBusy $Ctx.Target $null
                        $r = Get-JobValue $Result
                        if ($Err -or -not $r) { Set-OverlayFinished ("failed: {0}" -f $(if ($Err) { $Err } else { 'no answer' })) 'CRITICAL'; return }
                        if (-not $r.Ok) { Set-OverlayFinished $r.Detail 'CRITICAL'; return }

                        Write-OverlayLog ('saved to {0}' -f $r.Path)
                        if ($r.Password) { Write-OverlayLog ('password: {0}' -f $r.Password) }
                        $note = $(if ($Ctx.IsNew) { ('Written. The kiosk can be deployed to now: {0}, on {1}.' -f $LauncherNames[$Ctx.Kind], $Ctx.Instance) }
                            else { 'Saved. The launcher reads it again within seconds.' })
                        Set-OverlayFinished $note 'OK'
                        Show-Toast ('{0}: config saved.' -f $Ctx.Target) 'OK'
                        $script:ConfigWritten[$Ctx.Target] = $true
                        if ($script:TargetRows) {
                            $row = @($script:TargetRows | Where-Object { $_.Host -eq $Ctx.Target })[0]
                            if ($row) { $row.Note = 'config written, launcher not installed' }
                        }
                        $script:LiveObs.Remove($Ctx.Target)
                        if ($script:DetailHost -eq $Ctx.Target) { Update-Detail }
                    })
                return $false
            }
        })
}

# Asks which screen's config to edit, or which new screen and launcher to add.
function Show-InstancePicker {
    <#
        Which screen's config: each screen the kiosk has, with its launcher,
        and a new screen - the next free one - with any of the three. That
        is how a kiosk gets its S2, and how Power BI on S1 and the Mach2
        dashboard on S2 are set up.
    #>
    param($Kiosk, [string]$HostName, [switch]$NewOnly)
    if ($Kiosk) { $HostName = $Kiosk.Host }
    $screens = @(if ($Kiosk -and $Kiosk.PSObject.Properties['Screens']) { $Kiosk.Screens })
    $options = @()
    foreach ($s in @(if (-not $NewOnly) { $screens })) {
        $kind = $KindOfScreenLauncher[[string]$s.Launcher]
        $options += @{ Value = ('{0}|{1}' -f $s.Screen, $kind); Text = ('{0}  -  {1}  ({2})' -f $s.Screen, $LauncherNames[$kind], $s.State) }
    }
    $used = @($screens | ForEach-Object { [int]([string]$_.Screen).Substring(1) })
    $next = 1
    while ($used -contains $next) { $next++ }
    foreach ($kind in @('NG', 'PBI', 'WEB')) {
        $options += @{ Value = ('S{0}|{1}|new' -f $next, $kind); Text = ('New screen S{0}  -  {1}' -f $next, $LauncherNames[$kind]) }
    }
    $default = $(if ($screens.Count -and -not $NewOnly) { $options[0].Value } elseif ($Kiosk -and $TabKinds.ContainsKey([string]$Kiosk.Tab)) { 'S1|{0}|new' -f $TabKinds[[string]$Kiosk.Tab] } else { $options[0].Value })

    Show-Overlay -Title ('Which screen on {0}?' -f $HostName) `
        -Subtitle 'Each screen has its own config and its own launcher: Mach2 dashboard, Power BI report or a web page.' `
        -Fields @(@{ Key = 'Pick'; Kind = 'choice'; Label = 'Screen'; Value = $default; Options = $options
                Hint = 'A new screen gets its config from the launcher''s EXAMPLE.json. Deploy that launcher afterwards to start it.' }) `
        -OkText 'Open it' -Data @{ Host = $HostName } -OnOk {
        param($Values, $Data)
        $pick = [string](Get-OverlayFields)['Pick']
        if ($pick -notmatch '^(S\d+)\|(NG|PBI|WEB)') { return $false }
        Show-ConfigEditor -HostName $Data.Host -Kind $Matches[2] -Instance $Matches[1]
        return $false
    }
}

# Opens the config editor for the chosen screen of a kiosk.
function Open-KioskConfig {
    param($Kiosk)
    if (-not $Kiosk) { return }
    # A screen picked in the card: straight to it. Otherwise ask - which
    # also offers a new screen.
    $target = Get-ScreenTarget $Kiosk
    if ($target.Screen) { Show-ConfigEditor -HostName $Kiosk.Host -Kind $target.Kind -Instance $target.Screen; return }
    # One screen, or none yet (a new kiosk: its tab's launcher, on S1):
    # straight into it. Several: which one. A new screen is Add screen...
    $screens = @(if ($Kiosk.PSObject.Properties['Screens']) { $Kiosk.Screens })
    if ($screens.Count -le 1) { Show-ConfigEditor -Kiosk $Kiosk; return }
    Show-InstancePicker -Kiosk $Kiosk
}

# ---------------------------------------------------------------------------
# Running something long: the collector, or a deploy
#
# These are separate PowerShell processes, exactly as they would be from a
# prompt, with their output tailed into the Activity view. The command is
# written to Logs\run\<stamp>.ps1 first: that is what makes the quoting
# honest, and it leaves behind the command that actually ran.
# ---------------------------------------------------------------------------
# Appends text to the Activity view's output box.
function Write-Console {
    param([string]$Text)
    if (-not $Text) { return }
    $box = $UI.ConsoleBox
    $atEnd = ($box.SelectionStart -ge ($box.Text.Length - 2))
    $box.AppendText($Text)
    if ($atEnd) { $box.ScrollToEnd() }
}

# Runs the collector or a deploy script as a separate process and tails its output.
function Start-FleetProcess {
    <#
        $Command is one line of PowerShell, already quoted. $Kind is 'scan'
        or 'deploy': a scan drives the progress bar in the header, a deploy
        opens the Activity view.
    #>
    param([string]$Title, [string]$Command, [string]$Kind = 'deploy', [switch]$Quiet)

    if ($script:Run -and $script:Run.Proc -and -not $script:Run.Proc.HasExited) {
        Show-Toast ('{0} is still running - wait for it or stop it in Activity.' -f $script:Run.Title) 'WARNING'
        return $false
    }

    # A fortnight of commands and their output is worth keeping; beyond that
    # the folder is just growing.
    foreach ($old in @(Get-ChildItem -LiteralPath $RunDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) })) {
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }

    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $runner = Join-Path $RunDir "$Kind-$stamp.ps1"
    $outPath = Join-Path $RunDir "$Kind-$stamp.out.txt"
    $errPath = Join-Path $RunDir "$Kind-$stamp.err.txt"

    $lines = @(
        "# Kiosk Fleet Manager, $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) - $Title",
        '[Console]::OutputEncoding = [Text.Encoding]::UTF8',
        "`$ProgressPreference = 'SilentlyContinue'",
        ("Set-Location -LiteralPath '{0}'" -f ($ScriptDir -replace "'", "''")),
        $Command,
        'exit $LASTEXITCODE'
    )
    [IO.File]::WriteAllText($runner, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

    try {
        $proc = Start-Process powershell.exe -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) `
            -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        # Touching the handle is what makes ExitCode readable later; without
        # it the process object forgets the code the moment it exits.
        try { [void]$proc.Handle } catch { }
    }
    catch {
        Show-Toast ("Could not start it: {0}" -f $_.Exception.Message) 'CRITICAL'
        return $false
    }

    $script:Run = [pscustomobject]@{
        Title = $Title; Kind = $Kind; Proc = $proc; Out = $outPath; Err = $errPath
        OutPos = 0; ErrPos = 0; Started = Get-Date; Runner = $runner; Quiet = [bool]$Quiet
    }
    if ($Kind -eq 'scan') {
        $script:ScanStartedAt = Get-Date
        $script:ScanProgress = $null
        $UI.ScanPanel.Visibility = 'Visible'
        $UI.ScanBar.Value = 0
        $UI.ScanText.Text = 'scanning'
    }
    if (-not $Quiet) {
        if (-not $script:ConsoleUsed) { $UI.ConsoleBox.Text = ''; $script:ConsoleUsed = $true }
        Write-Console ("`r`n===== {0}  {1} =====`r`n" -f $Title, (Get-Date).ToString('HH:mm:ss'))
        Write-Console ("     {0}`r`n`r`n" -f $Command)
    }
    $UI.BadgeRunBox.Visibility = 'Visible'
    $UI.BadgeRun.Text = $(if ($Kind -eq 'scan') { 'scanning' } else { 'running' })
    $UI.BtnStopRun.IsEnabled = $true
    $UI.ActivityState.Text = ('{0} - started {1}' -f $Title, (Get-Date).ToString('HH:mm:ss'))
    return $true
}

# Returns what has been written to a file since the last read.
function Read-NewText {
    # Whatever has been written to a file since we last looked.
    param([string]$Path, [ref]$Position)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            if ($fs.Length -le $Position.Value) { return '' }
            [void]$fs.Seek($Position.Value, [IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ($fs.Length - $Position.Value)
            $read = $fs.Read($buf, 0, $buf.Length)
            $Position.Value = $Position.Value + $read
            return [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        }
        finally { $fs.Dispose() }
    }
    catch { return '' }
}

# Follows a running scan/deploy process and shows its output and result.
function Update-RunState {
    if (-not $script:Run) { return }
    $r = $script:Run

    $pos = $r.OutPos
    $text = Read-NewText -Path $r.Out -Position ([ref]$pos)
    $r.OutPos = $pos
    if ($text -and -not $r.Quiet) { Write-Console $text }

    $pos = $r.ErrPos
    $text = Read-NewText -Path $r.Err -Position ([ref]$pos)
    $r.ErrPos = $pos
    if ($text -and -not $r.Quiet) { Write-Console $text }

    if ($r.Kind -eq 'scan') { Update-ScanProgress }

    if (-not $r.Proc.HasExited) {
        $el = (Get-Date) - $r.Started
        $UI.ActivityState.Text = ('{0} - running for {1}:{2:00}' -f $r.Title, [int][math]::Floor($el.TotalMinutes), $el.Seconds)
        return
    }

    # Finished: catch the last of the output, then tidy up.
    Start-Sleep -Milliseconds 100
    $pos = $r.OutPos
    $tail = Read-NewText -Path $r.Out -Position ([ref]$pos)
    $r.OutPos = $pos
    if ($tail -and -not $r.Quiet) { Write-Console $tail }
    $pos = $r.ErrPos
    $tail = Read-NewText -Path $r.Err -Position ([ref]$pos)
    $r.ErrPos = $pos
    if ($tail -and -not $r.Quiet) { Write-Console $tail }

    $code = $r.Proc.ExitCode
    $secs = [int]((Get-Date) - $r.Started).TotalSeconds
    if (-not $r.Quiet) { Write-Console ("`r`n===== {0}: finished with code {1} after {2}s =====`r`n" -f $r.Title, $code, $secs) }
    $UI.ActivityState.Text = ('{0} - finished with code {1} after {2}s' -f $r.Title, $code, $secs)
    $UI.BadgeRunBox.Visibility = 'Collapsed'
    $UI.BtnStopRun.IsEnabled = $false

    if ($r.Kind -eq 'scan') {
        $UI.ScanPanel.Visibility = 'Collapsed'
        $script:ScanProgress = $null
        $script:NextScanAt = (Get-Date).AddMinutes($AutoScanMinutes)
        Update-AutoText
        Request-FleetRefresh -Force
        if (-not $r.Quiet) { Show-Toast $(if ($code -eq 0) { 'Scan finished.' } else { "The scan ended with code $code." }) $(if ($code -eq 0) { 'OK' } else { 'WARNING' }) }
    }
    else {
        Update-ReportList
        Show-Toast $(if ($code -eq 0) { ('{0} finished. Scan now brings the result onto the dashboard.' -f $r.Title) }
            else { ('{0} ended with code {1} - the output is in Activity.' -f $r.Title, $code) }) $(if ($code -eq 0) { 'OK' } else { 'CRITICAL' }) 10
    }
    $script:Run = $null
}

# Asks for confirmation and stops the running scan or deploy.
function Stop-FleetRun {
    if (-not $script:Run -or -not $script:Run.Proc -or $script:Run.Proc.HasExited) { return }
    Show-Overlay -Title 'Stop it?' -Body ("{0} is still running. Stopping it leaves whatever it was in the middle of half done; a kiosk mid-install would need the deploy running again." -f $script:Run.Title) `
        -OkText 'Stop it' -Danger -OnOk {
        try {
            $script:Run.Proc.Kill()
            Write-Console "`r`n===== stopped =====`r`n"
            Show-Toast 'Stopped.' 'WARNING'
        }
        catch { Show-Toast ("Could not stop it: {0}" -f $_.Exception.Message) 'CRITICAL' }
        return $true
    }
}

# --- S / A: the collector --------------------------------------------------
# Starts a fleet scan (the collector) now.
function Start-Scan {
    param([switch]$Auto)

    if (-not (Test-Path -LiteralPath $CollectorPath)) {
        Show-Toast ("The collector is not here: {0}" -f $CollectorPath) 'CRITICAL'
        return
    }
    $hasCred = Test-Path -LiteralPath $CredentialFile
    if (-not $hasCred -and $Auto) {
        # Without the credential every watchdog kiosk comes back NO_ACCESS,
        # and those false outages would be written into the history.
        $script:AutoScan = $false
        Update-AutoText
        Show-Toast 'Auto-scan needs the saved kiosk-admin credential. Run Save-KioskCredential.ps1 once.' 'WARNING' 10
        return
    }

    $cmd = "& '{0}'" -f ($CollectorPath -replace "'", "''")
    if ($hasCred) { $cmd += " -CredentialFile '{0}'" -f ($CredentialFile -replace "'", "''") }
    $cmd += " -ProgressFile '{0}'" -f ($ScanProgressPath -replace "'", "''")

    if (Start-FleetProcess -Title 'Fleet scan' -Command $cmd -Kind 'scan' -Quiet:$Auto) {
        if (-not $Auto) { Show-View -Name 'Activity' }
    }
}

# Updates the header progress bar from the collector's progress file.
function Update-ScanProgress {
    # The collector rewrites the progress file as it moves from kiosk to
    # kiosk. One caught mid-write simply fails to parse, and the last good
    # reading stands.
    if (-not $script:Run -or $script:Run.Kind -ne 'scan') { return }
    try {
        $p = (Read-SharedText -Path $ScanProgressPath) | ConvertFrom-Json
        if ($p -and $p.Pid -eq $script:Run.Proc.Id) { $script:ScanProgress = $p }
    }
    catch { }

    $p = $script:ScanProgress
    $el = (Get-Date) - $script:ScanStartedAt
    $clock = '{0}:{1:00}' -f [int][math]::Floor($el.TotalMinutes), $el.Seconds
    if ($p -and $p.Total -gt 0) {
        if ($p.Phase -eq 'saving') {
            $UI.ScanBar.Value = 100
            $UI.ScanText.Text = "saving  $clock"
        }
        else {
            $done = [math]::Max(0, [int]$p.Index - 1)
            $UI.ScanBar.Value = [int](100 * ($done / [double]$p.Total))
            $UI.ScanText.Text = '{0}/{1} {2}  {3}' -f $p.Index, $p.Total, $p.Host, $clock
        }
    }
    else { $UI.ScanText.Text = "starting  $clock" }
}

# Shows when the next automatic scan is due.
function Update-AutoText {
    if ($script:AutoScan) {
        $mins = 0
        if ($script:NextScanAt) { $mins = [math]::Max(0, [int][math]::Ceiling(($script:NextScanAt - (Get-Date)).TotalMinutes)) }
        $UI.AutoText.Text = 'every {0} min, next in {1} min' -f $AutoScanMinutes, $mins
    }
    else { $UI.AutoText.Text = 'off - the scheduled collector keeps the data fresh' }
    $UI.BtnAuto.IsChecked = $script:AutoScan
}

# Turns automatic scanning on or off and schedules the next scan.
function Enable-AutoScan {
    <#
        Turning auto-scan on schedules the next collection from the last one
        that actually happened, so switching it on next to a scheduled task -
        or just after a manual scan - does not sweep the whole fleet again
        for nothing.
    #>
    if (-not (Test-Path -LiteralPath $CredentialFile)) {
        $script:AutoScan = $false
        Update-AutoText
        Show-Toast 'Auto-scan needs the saved kiosk-admin credential. Run Save-KioskCredential.ps1 once.' 'WARNING' 10
        return
    }
    $script:AutoScan = $true
    $next = Get-Date
    if ($script:State) {
        $f = Get-FleetFreshness -State $script:State -StaleMinutes $StaleMinutes
        if ($f.LastRun) {
            $candidate = $f.LastRun.AddMinutes($AutoScanMinutes)
            if ($candidate -gt $next) { $next = $candidate }
        }
    }
    $script:NextScanAt = $next
    Update-AutoText
}

# ---------------------------------------------------------------------------
# The deploy view
# ---------------------------------------------------------------------------
$ProductInfo = @{
    'NG' = @{
        Name = 'Mach2 Launcher NG'; Tab = 'Mach2'; Script = 'Deploy-Mach2LauncherNG.ps1'
        Note = 'The launcher and the watchdog in one. Carries the settings over from Mach2Launcher.exe, and retires that and the MWST watchdog. Roll back puts both of them back.'
    }
    'PBI' = @{
        Name = 'PBI Launcher'; Tab = 'PBI'; Script = 'Deploy-PbiLauncher.ps1'
        Note = 'Replaces PowerBILauncher.exe, carrying its settings over. Roll back puts the old launcher back.'
    }
    'WEB' = @{
        Name = 'Web Launcher'; Tab = '*'; Script = 'Deploy-WebLauncher.ps1'
        Note = 'One web page on a screen, full screen, kept there - no sign-in. Any kiosk can have one on a free screen: write its config first (Config... on the kiosk, or Add a kiosk...), then install. Roll back removes it and puts back any old launcher it replaced.'
    }
}

# Returns the deploy script for the product picked on the Deploy page.
function Get-DeployScriptPath {
    switch ($script:Product) {
        'NG' { return $DeployNgPath }
        'PBI' { return $DeployPbiPath }
        default { return $DeployWebPath }
    }
}

# Picks the product (Mach2 NG, PBI, Web) on the Deploy page.
function Set-DeployProduct {
    param([string]$Name)

    $script:Product = $Name
    $script:NavSetting = $true
    $UI.ProdNg.IsChecked = ($Name -eq 'NG')
    $UI.ProdPbi.IsChecked = ($Name -eq 'PBI')
    $UI.ProdWeb.IsChecked = ($Name -eq 'WEB')
    $script:NavSetting = $false

    $info = $ProductInfo[$Name]
    $UI.ProductNote.Text = $info.Note
    $UI.TargetTitle.Text = $(if ($info.Tab -eq '*') { 'KIOSKS  (all)' } else { ('KIOSKS  ({0})' -f $info.Tab) })

    # Web Launcher has no old config to rewrite from.
    $UI.OptUpdateConfig.Visibility = $(if ($Name -eq 'WEB') { 'Collapsed' } else { 'Visible' })
    $UI.OptKeepWatchdog.Visibility = $(if ($Name -eq 'NG') { 'Visible' } else { 'Collapsed' })

    Update-DeployTargets
    Update-DeployPreview
}

# Picks Install or Rollback on the Deploy page.
function Set-DeployMode {
    param([string]$Mode)
    $script:NavSetting = $true
    $UI.ModeInstall.IsChecked = ($Mode -eq 'Install')
    $UI.ModeRollback.IsChecked = ($Mode -eq 'Rollback')
    $script:NavSetting = $false
    Update-DeployPreview
}

# Cleans up a typed kiosk name ("\\PC-01 " -> "PC-01") and rejects invalid ones.
function Get-KioskHostName {
    # Normalises a hand-typed name ("  \\PC-01 " -> "PC-01") and rejects
    # anything that clearly is not one, so junk never reaches a deploy.
    param([string]$Text)
    if (-not $Text) { return $null }
    $name = $Text.Trim().Trim('\')
    if ($name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { return $name }
    return $null
}

# Adds a kiosk the last scan did not see to the deploy list.
function Show-AddHostDialog {
    <#
        A kiosk the last scan never saw - a new one, or one that was off -
        can still be deployed to. It joins the list as NOT SCANNED, ticked,
        and its config is opened next: a kiosk with no <HOST>.json is what
        the deploy refuses with NO_CONFIG.
    #>
    Show-Overlay -Title 'Add a kiosk' `
        -Subtitle ('It joins the list for {0} even though the last scan did not see it.' -f $ProductInfo[$script:Product].Name) `
        -Body 'For a kiosk that is new, was switched off, or is not in the master list yet. The deploy checks it is really there.' `
        -Fields @(
            @{ Key = 'Host'; Label = 'Kiosk name'; Hint = 'The name the kiosk answers to on the network.' }
            @{ Key = 'Setup'; Kind = 'bool'; Label = 'Settings'; Value = '1'
               Hint = 'fill in its URL, account and password next' }
        ) -OkText 'Add it' -Data @{ Product = $script:Product } -OnOk {
        param($Values, $Data)
        $typed = Get-OverlayFields
        $name = Get-KioskHostName $typed['Host']
        if (-not $name) {
            $UI.OverlayNote.Text = 'That is not a kiosk name.'
            $UI.OverlayNote.Foreground = $Brush.Crit
            return $false
        }
        $known = @($script:TargetRows | Where-Object { $_.Host -eq $name })[0]
        if (-not $known) {
            [void]$script:ExtraTargets[$Data.Product].Add($name)
            Update-DeployTargets
            $known = @($script:TargetRows | Where-Object { $_.Host -eq $name })[0]
        }
        if ($known) { $known.Selected = $true }
        Update-DeployPreview

        if ($typed['Setup'] -eq '1') {
            # Straight into its config, which is also how it gets one.
            # Which screen, and which launcher's config: the picker offers a new
            # screen with the product being deployed.
            Show-ConfigEditor -HostName $name -Kind $(if ($Data.Product -in @('PBI', 'WEB')) { $Data.Product } else { 'NG' })
            return $false
        }
        Show-Toast ('{0} is in the list.' -f $name) 'OK'
        return $true
    }
}

# Fills the Deploy page's kiosk list for the picked product.
function Update-DeployTargets {
    if (-not $script:State -or -not $script:State.Ok) { return }
    $tab = $ProductInfo[$script:Product].Tab
    # Web Launcher can go on any kiosk's free screen: all of them.
    $kiosks = $(if ($tab -eq '*') { @($script:State.Hosts) } else { @(Get-TabKiosks -Tab $tab) })

    # Kiosks typed in by hand, which the last scan knows nothing about.
    foreach ($extra in @($script:ExtraTargets[$script:Product])) {
        if (@($kiosks | Where-Object { $_.Host -eq $extra }).Count -gt 0) { continue }
        $kiosks += [pscustomobject]@{
            Host = $extra; Location = ''; Type = ''; Tab = $tab; Status = 'NOT SCANNED'
            StatusRow = $null; Reboots24 = 0; Script24 = 0; Episodes24 = 0
            HasWatchdog = $false; Days = @{}; Pbi = $null; Ng = $null; Web = $null; Screens = @(); Tabs = @($tab)
        }
    }

    if (-not $script:TargetRows) {
        $script:TargetRows = New-Object System.Collections.ObjectModel.ObservableCollection[KioskFleet.FleetRow]
        $UI.DeployGrid.ItemsSource = $script:TargetRows
        $rowView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:TargetRows)
        $rowView.Filter = [Predicate[object]] {
            param($item)
            return (Test-RowMatchesFilter -Row $item -Text $script:DeployFilterText)
        }
    }

    # Which kiosks are on the tab can change; the ticks stay with the kiosks
    # that are still there.
    Sync-Rows -Collection $script:TargetRows -Kiosks $kiosks -DayKeys $script:State.DayKeys -MaxDaily 1
    foreach ($row in $script:TargetRows) {
        $k = Get-Kiosk $row.Host
        if (-not $k) {
            $row.Note = $(if ($script:ConfigWritten[$row.Host]) { 'config written, launcher not installed' } else { 'not in the last scan' })
            $row.LauncherBrush = $Brush.Faint
            continue
        }
        $lv = Get-LauncherView -Kiosk $k -Tab $(if ($tab -eq '*') { 'Web' } else { $tab })
        $ver = $(if ($k.StatusRow) { [string]$k.StatusRow.AgentVersion } else { '' })
        $bits = @()
        if ($lv.Installed) { $bits += ('{0} v{1}' -f $LauncherNames[$lv.Kind], $lv.Version) }
        elseif ($lv.State) { $bits += $lv.State }
        # What is on which screen already: one launcher per screen.
        $screens = @(if ($k.PSObject.Properties['Screens']) { $k.Screens })
        if ($screens.Count -gt 1 -or ($screens.Count -and $tab -eq '*')) { $bits += (@($screens | ForEach-Object { '{0} {1}' -f $_.Screen, $LauncherNames[$KindOfScreenLauncher[[string]$_.Launcher]] }) -join ', ') }
        if ($ver -and -not $lv.Installed) { $bits += ('agent v{0}' -f $ver) }
        $row.Note = ($bits -join ', ')
    }
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:TargetRows).Refresh()

    $UI.DeployEmpty.Text = $(if ($tab -eq '*') { 'No kiosks in the data.' } else { "No $tab kiosks in the data." })
    $UI.DeployEmpty.Visibility = $(if ($kiosks.Count) { 'Collapsed' } else { 'Visible' })
    Update-DeployPreview
}

# Returns the ticked kiosks on the Deploy page, sorted by name.
function Get-DeploySelection {
    # Sorted by name, not by whatever the table happens to be sorted by, so
    # the same ticks always produce the same command.
    if (-not $script:TargetRows) { return @() }
    return @($script:TargetRows | Where-Object { $_.Selected } | ForEach-Object { $_.Host } | Sort-Object)
}

# Builds the deploy script's arguments from the Deploy page options.
function Get-DeployArguments {
    param([switch]$DryRun)

    $hosts = @(Get-DeploySelection)
    $rollback = [bool]$UI.ModeRollback.IsChecked
    $list = New-Object System.Collections.ArrayList

    [void]$list.Add('-Hosts ' + ((@($hosts | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" })) -join ','))
    if ($rollback) { [void]$list.Add('-Rollback') }

    if ($UI.OptRestart.IsChecked) {
        $secs = 60
        [void][int]::TryParse(("$($UI.OptWarnSecs.Text)").Trim(), [ref]$secs)
        $mins = 12
        [void][int]::TryParse(("$($UI.OptVerifyMins.Text)").Trim(), [ref]$mins)
        [void]$list.Add('-Restart')
        [void]$list.Add("-RestartWarningSeconds $secs")
        [void]$list.Add("-VerifyMinutes $mins")
    }
    if ($UI.OptForce.IsChecked) { [void]$list.Add('-Force') }
    if ($UI.OptUpdateConfig.IsChecked -and -not $rollback -and $script:Product -ne 'WEB') { [void]$list.Add('-UpdateConfig') }
    if ($UI.OptKeepLegacy.IsChecked -and -not $rollback) { [void]$list.Add('-KeepLegacy') }
    if ($script:Product -eq 'NG' -and $UI.OptKeepWatchdog.IsChecked -and -not $rollback) { [void]$list.Add('-KeepWatchdog') }

    $kioskUser = ("$($UI.OptKioskUser.Text)").Trim()
    if ($kioskUser) { [void]$list.Add("-KioskUser '{0}'" -f ($kioskUser -replace "'", "''")) }

    if (Test-Path -LiteralPath $CredentialFile) {
        [void]$list.Add("-CredentialFile '{0}'" -f (Get-RelativeFleetPath $CredentialFile))
    }
    if ($DryRun) { [void]$list.Add('-WhatIf') }
    return @($list)
}

# Shortens a path under the toolkit folder to a relative one.
function Get-RelativeFleetPath {
    param([string]$Path)
    if ($Path -like "$ScriptDir\*") { return $Path.Substring($ScriptDir.Length + 1) }
    return $Path
}

# Builds the exact deploy command line shown in the preview.
function Get-DeployCommand {
    param([switch]$DryRun)
    $file = '.\' + (Split-Path -Leaf (Get-DeployScriptPath))
    $cmdArgs = @(Get-DeployArguments -DryRun:$DryRun)
    return ('& ''{0}'' {1}' -f $file, ($cmdArgs -join ' '))
}

# Shows the deploy command that the current ticks and options would run.
function Update-DeployPreview {
    if (-not $UI.DeployPreview) { return }
    $hosts = @(Get-DeploySelection)
    if ($hosts.Count -eq 0) {
        $UI.DeployPreview.Text = '(tick the kiosks to deploy to)'
        $UI.DeployNote.Text = 'Start with one kiosk.'
        $UI.BtnDeployRun.IsEnabled = $false
        $UI.BtnDryRun.IsEnabled = $false
        return
    }
    $UI.BtnDeployRun.IsEnabled = $true
    $UI.BtnDryRun.IsEnabled = $true

    $file = '.\' + (Split-Path -Leaf (Get-DeployScriptPath))
    $cmdArgs = @(Get-DeployArguments)
    $UI.DeployPreview.Text = ('{0} {1}' -f $file, ($cmdArgs -join " `r`n    "))

    $what = $(if ($UI.ModeRollback.IsChecked) { 'Roll back' } else { 'Install or update' })
    $note = '{0} on {1} kiosk{2}.' -f $what, $hosts.Count, $(if ($hosts.Count -eq 1) { '' } else { 's' })
    if ($UI.OptRestart.IsChecked) { $note += ' Each one restarts, one at a time, and the first failure stops the run.' }
    else { $note += ' It takes effect at the next logon.' }
    $UI.DeployNote.Text = $note
}

# Confirms and runs the deploy for the ticked kiosks.
function Start-Deploy {
    param([switch]$DryRun)

    $hosts = @(Get-DeploySelection)
    if ($hosts.Count -eq 0) { return }
    $info = $ProductInfo[$script:Product]
    $rollback = [bool]$UI.ModeRollback.IsChecked
    $what = $(if ($rollback) { 'Roll back {0}' -f $info.Name } else { 'Install / update {0}' -f $info.Name })
    $cmd = Get-DeployCommand -DryRun:$DryRun

    if ($DryRun) {
        [void](Get-FleetCredential)
        if (Start-FleetProcess -Title ("Dry run: $what") -Command $cmd -Kind 'deploy') { Show-View -Name 'Activity' }
        return
    }

    $body = "{0} on:`r`n`r`n    {1}`r`n`r`n{2}" -f $what, ($hosts -join ', '),
        $(if ($UI.OptRestart.IsChecked) {
                'Each kiosk restarts after the change, with a countdown on its screen, and the deploy waits for it to come back. They go one at a time, and the first one that fails stops the run.'
            }
            else { 'The change takes effect the next time each kiosk logs on.' })

    Show-Overlay -Title 'Deploy' -Subtitle $info.Name -Body $body `
        -Note 'A dry run first changes nothing and shows what would happen.' `
        -OkText $(if ($rollback) { 'Roll back' } else { 'Deploy' }) -Danger:([bool]$UI.OptRestart.IsChecked) `
        -Data @{ What = $what; Command = $cmd } -OnOk {
        param($Values, $Data)
        [void](Get-FleetCredential)
        if (Start-FleetProcess -Title $Data.What -Command $Data.Command -Kind 'deploy') { Show-View -Name 'Activity' }
        return $true
    }
}

# Lists the deploy reports saved in Reports\.
function Update-ReportList {
    if (-not $script:ReportRows) {
        $script:ReportRows = New-Object System.Collections.ObjectModel.ObservableCollection[KioskFleet.ReportRow]
        $UI.ReportGrid.ItemsSource = $script:ReportRows
    }
    $script:ReportRows.Clear()
    $files = @(Get-ChildItem -LiteralPath $LogDir -Filter '*deploy*.csv' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 40)
    foreach ($f in $files) {
        $row = New-Object KioskFleet.ReportRow
        $row.Name = $f.Name
        $row.When = $f.LastWriteTime.ToString('ddd dd MMM HH:mm')
        $row.Kind = switch -Wildcard ($f.Name) {
            'm2ng-deploy*' { 'Mach2 Launcher NG' }
            'web-deploy*' { 'Web Launcher' }
            default { 'PBI Launcher' }
        }
        $row.Path = $f.FullName
        $script:ReportRows.Add($row)
    }
}

# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------
# Written out one by one rather than in a loop: a handler scriptblock does
# not keep the loop's variables, and a closure that did would lose sight of
# the script's own state instead.
$UI.NavOverview.Add_Click({ if (-not $script:NavSetting) { Show-View -Name 'Overview' } })
$UI.NavMach2.Add_Click({ if (-not $script:NavSetting) { Show-View -Name 'Mach2' } })
$UI.NavPbi.Add_Click({ if (-not $script:NavSetting) { Show-View -Name 'PBI' } })
$UI.NavWeb.Add_Click({ if (-not $script:NavSetting) { Show-View -Name 'Web' } })
$UI.NavOther.Add_Click({ if (-not $script:NavSetting) { Show-View -Name 'Other' } })
$UI.NavDeploy.Add_Click({ if (-not $script:NavSetting) { Show-View -Name 'Deploy' } })
$UI.NavActivity.Add_Click({ if (-not $script:NavSetting) { Show-View -Name 'Activity' } })

$UI.BtnScan.Add_Click({ Start-Scan })
$UI.BtnAuto.Add_Click({
        if ($script:NavSetting) { return }
        if ($UI.BtnAuto.IsChecked) { Enable-AutoScan } else { $script:AutoScan = $false; Update-AutoText }
    })

$UI.FilterBox.Add_TextChanged({
        $script:Filter = $UI.FilterBox.Text
        $UI.FilterHint.Visibility = $(if ($UI.FilterBox.Text) { 'Collapsed' } else { 'Visible' })
        if ($script:Rows) {
            [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows).Refresh()
            Update-KioskEmpty
        }
    })
$UI.BtnOnlyProblems.Add_Click({
        $script:OnlyProblems = [bool]$UI.BtnOnlyProblems.IsChecked
        if ($script:Rows) {
            [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows).Refresh()
            Update-KioskEmpty
        }
    })

# Shows a "nothing to show" note when the kiosk table is empty.
function Update-KioskEmpty {
    if (-not $script:Rows) { return }
    $rowView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
    $shown = @($rowView | ForEach-Object { $_ }).Count
    if ($script:Rows.Count -eq 0) {
        $UI.KioskEmpty.Text = "No $($script:Tab) kiosks in the data."
        $UI.KioskEmpty.Visibility = 'Visible'
    }
    elseif ($shown -eq 0) {
        $UI.KioskEmpty.Text = $(if ($script:OnlyProblems) { 'Nothing on this tab needs attention.' } else { 'Nothing matches the filter.' })
        $UI.KioskEmpty.Visibility = 'Visible'
    }
    else { $UI.KioskEmpty.Visibility = 'Collapsed' }
}

$UI.ScreenPick.Add_SelectionChanged({
        if ($script:NavSetting -or -not $script:DetailHost) { return }
        $item = $UI.ScreenPick.SelectedItem
        $script:ScreenChoice[$script:DetailHost] = $(if ($item) { [string]$item.Tag } else { '' })
        Update-ActionButtons
    })

$UI.KioskGrid.Add_SelectionChanged({
        $row = $UI.KioskGrid.SelectedItem
        $script:Selected = $(if ($row) { $row.Host } else { $null })
        Update-Detail
    })

$UI.AttentionGrid.Add_MouseDoubleClick({
        $row = $UI.AttentionGrid.SelectedItem
        if ($row) { Select-KioskTab -Tab $row.Tab -HostName $row.Host }
    })

$UI.BtnDeploySelected.Add_Click({
        Set-DeployProduct $(if ($script:Tab -eq 'PBI') { 'PBI' } elseif ($script:Tab -eq 'Web') { 'WEB' } else { 'NG' })
        Show-View -Name 'Deploy'
    })

# --- the kiosk's own buttons ---
$UI.BtnRestart.Add_Click({ Show-RestartDialog (Get-SelectedKiosk) })
$UI.BtnRemote.Add_Click({ Start-RemoteControl (Get-SelectedKiosk) })
$UI.BtnMessage.Add_Click({ Show-MessageDialog (Get-SelectedKiosk) })
$UI.BtnOpenShare.Add_Click({ Open-KioskFolder (Get-SelectedKiosk) })
$UI.BtnLive.Add_Click({ Invoke-LiveRead (Get-SelectedKiosk) })
$UI.BtnSnapshot.Add_Click({ Invoke-Snapshot (Get-SelectedKiosk) })
$UI.BtnReload.Add_Click({ Send-LauncherControl -Kiosk (Get-SelectedKiosk) -FileName 'refresh.txt' -Doing 'reloading the page' })
$UI.BtnRelaunch.Add_Click({ Send-LauncherControl -Kiosk (Get-SelectedKiosk) -FileName 'relaunch.txt' -Doing 'restarting the browser' })
$UI.BtnLog.Add_Click({ Show-LauncherLog (Get-SelectedKiosk) })
$UI.BtnConfig.Add_Click({ Open-KioskConfig (Get-SelectedKiosk) })
$UI.BtnAddScreen.Add_Click({ $k = Get-SelectedKiosk; if ($k) { Show-InstancePicker -Kiosk $k -NewOnly } })
$UI.BtnPassword.Add_Click({ Show-PasswordDialog (Get-SelectedKiosk) })
$UI.BtnDeployThis.Add_Click({
        $k = Get-SelectedKiosk
        if (-not $k) { return }
        # The launcher of the screen picked in the card, else the tab's.
        $target = Get-ScreenTarget $k
        Set-DeployProduct $(if ($target.Screen) { $target.Kind } elseif ($script:Tab -eq 'Web') { 'WEB' } elseif ($script:Tab -eq 'PBI' -or $k.Tab -eq 'PBI') { 'PBI' } else { 'NG' })
        foreach ($row in $script:TargetRows) { $row.Selected = ($row.Host -eq $k.Host) }
        Update-DeployPreview
        Show-View -Name 'Deploy'
    })

$UI.BtnHold.Add_Click({
        $k = Get-SelectedKiosk
        if (-not $k) { return }
        $holding = ($script:HoldState.ContainsKey($k.Host) -and $script:HoldState[$k.Host])
        if ($holding) {
            Send-LauncherControl -Kiosk $k -FileName 'hold.txt' -Doing 'carrying on' -Delete
            return
        }
        Show-Overlay -Title ('Hold {0}?' -f $k.Host) `
            -Body 'Hold leaves the screen exactly as it is: no checks, no reloads, no sign-in, and no restarts from the watchdog until you resume. The kiosk keeps showing whatever is on it now.' `
            -OkText 'Hold' -Data @{ Host = $k.Host } -OnOk {
            param($Values, $Data)
            Send-LauncherControl -Kiosk (Get-Kiosk $Data.Host) -FileName 'hold.txt' -Doing 'holding'
            return $true
        }
    })

$UI.BtnStopLauncher.Add_Click({
        $k = Get-SelectedKiosk
        if (-not $k) { return }
        Show-Overlay -Title ('Stop the launcher on {0}?' -f $k.Host) `
            -Body 'Stop closes the browser and ends the launcher. The screen stays empty until the kiosk restarts or its user logs on again. On a Mach2 kiosk that also stops the watchdog, so nothing is watching the screen.' `
            -OkText 'Stop the launcher' -Danger -Data @{ Host = $k.Host } -OnOk {
            param($Values, $Data)
            Send-LauncherControl -Kiosk (Get-Kiosk $Data.Host) -FileName 'kill.txt' -Doing 'stopping the launcher'
            return $true
        }
    })

$UI.BtnOpenSnapshot.Add_Click({
        if ($script:LastSnapshot -and (Test-Path -LiteralPath $script:LastSnapshot)) {
            try { Invoke-Item -LiteralPath $script:LastSnapshot } catch { Show-Toast $_.Exception.Message 'WARNING' }
        }
    })

# --- deploy ---
$UI.ProdNg.Add_Click({ if (-not $script:NavSetting) { Set-DeployProduct 'NG' } })
$UI.ProdPbi.Add_Click({ if (-not $script:NavSetting) { Set-DeployProduct 'PBI' } })
$UI.ProdWeb.Add_Click({ if (-not $script:NavSetting) { Set-DeployProduct 'WEB' } })
$UI.ModeInstall.Add_Click({ if (-not $script:NavSetting) { Set-DeployMode 'Install' } })
$UI.ModeRollback.Add_Click({ if (-not $script:NavSetting) { Set-DeployMode 'Rollback' } })

$UI.DeployFilter.Add_TextChanged({
        $script:DeployFilterText = $UI.DeployFilter.Text
        $UI.DeployFilterHint.Visibility = $(if ($UI.DeployFilter.Text) { 'Collapsed' } else { 'Visible' })
        if ($script:TargetRows) { [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:TargetRows).Refresh() }
    })
$UI.BtnSelAll.Add_Click({
        if (-not $script:TargetRows) { return }
        $rowView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:TargetRows)
        foreach ($row in @($rowView | ForEach-Object { $_ })) { $row.Selected = $true }
        Update-DeployPreview
    })
$UI.BtnSelNone.Add_Click({
        if (-not $script:TargetRows) { return }
        foreach ($row in $script:TargetRows) { $row.Selected = $false }
        Update-DeployPreview
    })
$UI.BtnAddHost.Add_Click({ Show-AddHostDialog })
$UI.DeployGrid.Add_MouseDoubleClick({
        $row = $UI.DeployGrid.SelectedItem
        if ($row) { $row.Selected = -not $row.Selected; Update-DeployPreview }
    })
foreach ($n in @('OptRestart', 'OptForce', 'OptUpdateConfig', 'OptKeepLegacy', 'OptKeepWatchdog')) {
    $UI[$n].Add_Click({ Update-DeployPreview })
}
$UI.OptWarnSecs.Add_TextChanged({ Update-DeployPreview })
$UI.OptVerifyMins.Add_TextChanged({ Update-DeployPreview })
$UI.OptKioskUser.Add_TextChanged({ Update-DeployPreview })
$UI.BtnCopyCommand.Add_Click({
        try {
            [System.Windows.Clipboard]::SetText((Get-DeployCommand))
            Show-Toast 'The command is on the clipboard.' 'OK' 4
        }
        catch { Show-Toast ("Could not copy it: {0}" -f $_.Exception.Message) 'WARNING' }
    })
$UI.BtnDryRun.Add_Click({ Start-Deploy -DryRun })
$UI.BtnDeployRun.Add_Click({ Start-Deploy })

# A tick in the list: the checkbox's Checked/Unchecked bubble up to the grid,
# and the handler sets the row itself rather than trusting the binding to
# have done it first, then redraws the command.
#
# (This used to queue the redraw with Dispatcher.BeginInvoke([action]{...},
# 'Background'). PowerShell picks the overload that hands 'Background' to the
# action as an argument, the dispatcher throws "Parameter count mismatch",
# and the first real click on a row closed the window.)
$onTick = {
    param($Sender, $E)
    $cb = $E.OriginalSource
    if ($cb -is [System.Windows.Controls.CheckBox] -and $cb.DataContext -is [KioskFleet.FleetRow]) {
        $cb.DataContext.Selected = [bool]$cb.IsChecked
    }
    Update-DeployPreview
}
$UI.DeployGrid.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::CheckedEvent, [System.Windows.RoutedEventHandler]$onTick)
$UI.DeployGrid.AddHandler([System.Windows.Controls.Primitives.ToggleButton]::UncheckedEvent, [System.Windows.RoutedEventHandler]$onTick)

# --- activity ---
$UI.BtnStopRun.Add_Click({ Stop-FleetRun })
$UI.BtnClearConsole.Add_Click({ $UI.ConsoleBox.Text = '' })
$UI.BtnOpenLogs.Add_Click({ try { Start-Process explorer.exe $LogDir } catch { } })
$UI.BtnSaveOutput.Add_Click({
        $dlg = New-Object Microsoft.Win32.SaveFileDialog
        $dlg.Filter = 'Text file (*.txt)|*.txt'
        $dlg.FileName = 'kiosk-fleet-output_{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
        if ($dlg.ShowDialog()) {
            try {
                [IO.File]::WriteAllText($dlg.FileName, $UI.ConsoleBox.Text)
                Show-Toast ('Saved to {0}' -f $dlg.FileName) 'OK'
            }
            catch { Show-Toast ("Could not save it: {0}" -f $_.Exception.Message) 'CRITICAL' }
        }
    })
$UI.ReportGrid.Add_MouseDoubleClick({
        $row = $UI.ReportGrid.SelectedItem
        if ($row -and (Test-Path -LiteralPath $row.Path)) {
            try { Invoke-Item -LiteralPath $row.Path } catch { Show-Toast $_.Exception.Message 'WARNING' }
        }
    })

# --- the modal card ---
$UI.OverlayMore.Add_Click({
        $UI.OverlayAdvanced.Visibility = $(if ($UI.OverlayMore.IsChecked) { 'Visible' } else { 'Collapsed' })
    })
$UI.OverlayCancel.Add_Click({ Hide-Overlay })
$UI.OverlayOk.Add_Click({
        if (-not $script:OverlayAction) { Hide-Overlay; return }
        $values = @{
            Input1    = $UI.OverlayInput.Text
            Input2    = $UI.OverlayInput2.Text
            Password  = $UI.OverlayPass.Password
            Password2 = $UI.OverlayPass2.Password
        }
        $action = $script:OverlayAction
        $keep = $false
        try { $keep = (& $action $values $script:OverlayData) }
        catch {
            $UI.OverlayNote.Text = $_.Exception.Message
            $UI.OverlayNote.Foreground = $Brush.Crit
            return
        }
        if ($keep -eq $true) { Hide-Overlay }
    })
$UI.OverlayInput.Add_KeyDown({ if ($_.Key -eq 'Return') { $UI.OverlayOk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })
$UI.OverlayPass2.Add_KeyDown({ if ($_.Key -eq 'Return') { $UI.OverlayOk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent))) } })

# --- keys ---
$Window.Add_PreviewKeyDown({
        if ($_.Key -eq 'Escape' -and $UI.Overlay.Visibility -eq 'Visible') {
            Hide-Overlay
            $_.Handled = $true
            return
        }
        if ($_.Key -eq 'F5') { Request-FleetRefresh -Force; $_.Handled = $true; return }
        if ($_.Key -eq 'F' -and [System.Windows.Input.Keyboard]::Modifiers -eq 'Control') {
            if ($script:View -in @('Mach2', 'PBI', 'Web', 'Other')) { [void]$UI.FilterBox.Focus(); $UI.FilterBox.SelectAll(); $_.Handled = $true }
        }
    })

$Window.Add_Closing({
        if ($script:Run -and $script:Run.Proc -and -not $script:Run.Proc.HasExited) {
            $answer = [System.Windows.MessageBox]::Show(
                ("{0} is still running. Closing the manager leaves it running to the end in the background, and you lose sight of its output.`r`n`r`nClose anyway?" -f $script:Run.Title),
                'Kiosk Fleet Manager', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { $_.Cancel = $true; return }
        }
        foreach ($t in @($script:Tick, $script:Poll, $script:DataTimer, $script:Toast)) { if ($t) { $t.Stop() } }
        try { $script:Pool.Close(); $script:Pool.Dispose() } catch { }
    })

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------
$script:Tick = New-Object System.Windows.Threading.DispatcherTimer
$script:Tick.Interval = [timespan]::FromSeconds(1)
$script:Tick.Add_Tick({
        $UI.ClockText.Text = (Get-Date).ToString('ddd dd MMM  HH:mm:ss')
        Update-Freshness
        if ($script:AutoScan) {
            Update-AutoText
            if (-not $script:Run -and $script:NextScanAt -and (Get-Date) -ge $script:NextScanAt) { Start-Scan -Auto }
        }
    })

$script:Poll = New-Object System.Windows.Threading.DispatcherTimer
$script:Poll.Interval = [timespan]::FromMilliseconds(250)
$script:Poll.Add_Tick({
        Update-Jobs
        Update-RunState
    })

$script:DataTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:DataTimer.Interval = [timespan]::FromSeconds($RefreshSeconds)
$script:DataTimer.Add_Tick({ Request-FleetRefresh })

# ---------------------------------------------------------------------------
# Open
# ---------------------------------------------------------------------------
$script:CsvFile = Resolve-FleetEventsCsv -ScriptDir $ScriptDir -CsvPath $CsvPath
$script:ViewerPath = Get-CmRcViewerPath -Explicit $RemoteControlPath
$script:DeployFilterText = ''

# The first read is done here and not in the background, so the window opens
# with the fleet already on it rather than blank for a second.
$script:CsvStamp = Get-FleetStamp -Path $script:CsvFile
$script:State = Read-FleetState -Path $script:CsvFile

if ($View -in @('Mach2', 'PBI', 'Web', 'Other')) { $script:Tab = $View }
Set-DeployProduct $(if ($script:Tab -eq 'PBI') { 'PBI' } else { 'NG' })
$UI.OptWarnSecs.Text = "$RestartWarningSeconds"
$UI.ConsoleBox.Text = @"
Nothing has run yet.

A scan, a dry run or a deploy prints here as it happens, and the command that
started it is kept in Logs\run so you can see exactly what ran.
"@
Update-Everything
Update-ReportList
Update-AutoText
Show-View -Name $View
if ($script:AutoScan) { Enable-AutoScan }

if ($Screenshot) {
    # Render every view to PNG without showing anything: for the tests and
    # the documentation.
    if (-not (Test-Path -LiteralPath $Screenshot)) { New-Item -ItemType Directory -Path $Screenshot -Force | Out-Null }
    $w = 1500
    $h = 880
    $root = $Window.Content
    $root.Background = $Window.FindResource('BgWindow')
    $shots = @()
    foreach ($v in @('Overview', 'Mach2', 'PBI', 'Deploy', 'Activity')) {
        Show-View -Name $v
        if ($v -in @('Mach2', 'PBI') -and $script:Rows.Count -gt 0) {
            $UI.KioskGrid.SelectedIndex = 0
            $script:Selected = $script:Rows[0].Host
            Update-Detail
        }
        $root.Measure((New-Object System.Windows.Size($w, $h)))
        $root.Arrange((New-Object System.Windows.Rect(0, 0, $w, $h)))
        $root.UpdateLayout()
        # Priority first: that overload is the unambiguous one.
        [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action] { })

        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($root)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $path = Join-Path $Screenshot ("fleet-manager-{0}.png" -f $v.ToLowerInvariant())
        $fs = [IO.File]::Create($path)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
        $shots += $path
    }
    try { $script:Pool.Close() } catch { }
    $shots
    return
}

if ($NoShow) {
    # Everything is built and the data is loaded, but no window is shown:
    # this is what the tests drive. The runspace pool is left open for them,
    # and closed by whoever dot-sourced this.
    return
}

$script:Tick.Start()
$script:Poll.Start()
$script:DataTimer.Start()
try { [void]$Window.ShowDialog() }
catch {
    # The dispatcher's handler catches errors inside the window; this is for
    # whatever still gets past it. The console is hidden, so say it in a box.
    Write-ManagerError 'the window closed' $_
    [void][System.Windows.MessageBox]::Show(
        ("The Kiosk Fleet Manager stopped:`r`n`r`n{0}`r`n`r`nThe details are in {1}." -f $_.Exception.Message, $ManagerLogPath),
        'Kiosk Fleet Manager', 'OK', 'Error')
}
