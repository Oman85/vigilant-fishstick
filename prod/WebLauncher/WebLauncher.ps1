#Requires -Version 5.1
<#
.SYNOPSIS
    Web Launcher: shows one web page full screen on a kiosk screen and keeps
    it there.

.DESCRIPTION
    Generated from WebLauncher.ps1 by Tools\Build-WebLauncher.ps1 - change
    that, not this file. The same Edge handling as Web Launcher, without
    anything Power BI: no sign-in, no password, no account checks.

    For as long as the kiosk account is signed in, it:

      - starts Microsoft Edge full screen on the configured display,
        InPrivate, with a profile of its own
      - opens the page, reloads it on an interval and at fixed times of day
      - watches it and puts things right without anyone at the kiosk: Edge's
        own error page (site or network down), error text on the page, a
        page that shows nothing, a hung or crashed page, a closed browser,
        another page it ended up on
      - lets people follow links: the linked page opens in the kiosk window
        (never in a new one), with a "Back" button, and the page comes back
        by itself after ReturnAfterSeconds (120) without use
      - writes a CMTrace log (locally and to the central share) and a status
        file that the fleet tools read over the admin share

    Which pages count as "the page" is TargetMatch: path (default - the same
    site, under the configured path), host (anywhere on the site) or exact.

  Folders

    WebLauncher.ps1 sits in C:\Users\Public\Documents\WebLauncher. Each
    screen has a folder next to it (S1, S2, ...) holding its config
    (<COMPUTERNAME>.json), control files, Status\ and Logs\. -Instance names
    the folder; S1 is the default. A screen number belongs to one launcher:
    a web page on S2 next to Power BI on S1 is fine, both on S1 is not.

  Control files (in the screen's folder)

    kill.txt      stop the launcher and close Edge
    relaunch.txt  restart Edge
    refresh.txt   reload the page
    restart.txt   restart the PC in 10 seconds
    snapshot.txt  save a screenshot and a page summary in Status\
    hold.txt      pause: the launcher watches but does nothing, so someone
                  can use the browser. Delete it to resume.

    Each file except hold.txt is deleted when it is acted on.

.PARAMETER Instance
    The screen's folder next to this script. Default S1.

.PARAMETER ConfigPath
    Config file. Default: <COMPUTERNAME>.json, then config.json, in the
    screen's folder.

.PARAMETER ShowConsole
    Keep the console window on screen and echo the log to it.

.PARAMETER Headless
    Run Edge without a window. For testing only.

.PARAMETER ExitAfterSeconds
    Stop after this long. For testing only.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\Public\Documents\WebLauncher\WebLauncher.ps1 -Instance S2

.EXAMPLE
    .\WebLauncher.ps1 -Instance S1 -ShowConsole
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Instance = 'S1',
    [string]$ConfigPath,
    [switch]$ShowConsole,
    [switch]$Headless,
    [ValidateRange(0, 604800)][int]$ExitAfterSeconds = 0
)
# Strict mode is deliberate. The old launcher's worst bug was a misspelt
# variable ($DisplayUR) that silently read as empty and relaunched it in a
# loop; strict mode turns that kind of mistake into an error on first use.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$LauncherVersion = '1.0.0'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ComputerName = $env:COMPUTERNAME.ToUpperInvariant()
$script:LegacyLayout = $false
$SetPassword = $false
$Here = Join-Path $ScriptDir $Instance
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web

# ---------------------------------------------------------------------------
# Native helpers
# ---------------------------------------------------------------------------
$script:NativeReady = $false

# Loads the Win32 helpers used to hide the console, park the cursor and list monitors.
function Initialize-Native {
    # Console hiding, cursor parking and the monitor list. The monitor list
    # comes from EnumDisplayMonitors rather than WinForms' Screen class,
    # which caches the list and, without a message loop, never notices a TV
    # that is switched on after the launcher started.
    if ('WebLauncherNative.Api' -as [type]) { $script:NativeReady = $true; return }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace WebLauncherNative {
    public static class Api {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct MONITORINFOEX {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
        }

        private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprcMonitor, IntPtr data);
        [DllImport("user32.dll")] private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX info);

        // One "device|left|top|width|height|primary" string per monitor.
        public static string[] GetMonitors() {
            var list = new List<string>();
            MonitorEnumProc proc = delegate (IntPtr h, IntPtr dc, IntPtr r, IntPtr d) {
                var mi = new MONITORINFOEX();
                mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
                if (GetMonitorInfo(h, ref mi)) {
                    list.Add(string.Format("{0}|{1}|{2}|{3}|{4}|{5}", mi.szDevice,
                        mi.rcMonitor.Left, mi.rcMonitor.Top,
                        mi.rcMonitor.Right - mi.rcMonitor.Left, mi.rcMonitor.Bottom - mi.rcMonitor.Top,
                        (mi.dwFlags & 1) != 0 ? 1 : 0));
                }
                return true;
            };
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, proc, IntPtr.Zero);
            GC.KeepAlive(proc);
            return list.ToArray();
        }
    }
}
'@
        $script:NativeReady = $true
    }
    catch {
        # Compiling needs csc.exe. Without it the launcher still works: the
        # console stays visible behind Edge and screens come from WinForms.
        $script:NativeReady = $false
    }
}

# Hides the launcher's own console window so it never covers the screen.
function Hide-ConsoleWindow {
    # The console must never sit on top of the page. The shortcut starts
    # PowerShell hidden already; this covers any other way of starting it.
    # Returns what it found, for the log.
    if (-not $script:NativeReady) { return 'unknown (no native helpers)' }
    try {
        $h = [WebLauncherNative.Api]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return 'none' }
        if (-not [WebLauncherNative.Api]::IsWindowVisible($h)) { return 'hidden' }
        [void][WebLauncherNative.Api]::ShowWindow($h, 0)
        if ([WebLauncherNative.Api]::IsWindowVisible($h)) {
            return 'still visible (not a classic console - Windows Terminal?)'
        }
        return 'hidden by the launcher'
    }
    catch { return "unknown ($($_.Exception.Message))" }
}

# ---------------------------------------------------------------------------
# Logging (CMTrace format, same as the old launcher)
# ---------------------------------------------------------------------------
$script:LogTargets = @()
$script:LogBuffer = New-Object System.Collections.Generic.List[string]
$script:DebugLogging = $false
$script:EchoLog = $false
$script:InstanceName = ''
$MaxLogBytes = 5MB

# Creates a log destination record (local file or network share).
function New-LogTarget {
    param([string]$Path, [bool]$IsRemote)
    return [pscustomobject]@{ Path = $Path; IsRemote = $IsRemote; DownUntil = [DateTime]::MinValue; Writes = 0; Warned = $false }
}

# Appends one line to a log file, rolling the file over when it gets too big.
function Add-LogLine {
    param($Target, [string]$Line)

    if ($Target.DownUntil -gt [DateTime]::UtcNow) { return }
    try {
        # Check the size now and then rather than on every line: on the
        # central share every metadata call is a network round trip.
        if (($Target.Writes % 200) -eq 0 -and (Test-Path -LiteralPath $Target.Path)) {
            if ((Get-Item -LiteralPath $Target.Path).Length -ge $MaxLogBytes) {
                $old = [IO.Path]::ChangeExtension($Target.Path, '.lo_')
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
                Move-Item -LiteralPath $Target.Path -Destination $old -Force
            }
        }
        $Target.Writes++

        # Shared read/write/delete: CMTrace, a collector or the other side of
        # the share can hold the file open while we append.
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $fs = New-Object IO.FileStream($Target.Path, [IO.FileMode]::Append, [IO.FileAccess]::Write, $share)
        try {
            $bytes = $Utf8NoBom.GetBytes($Line + "`r`n")
            $fs.Write($bytes, 0, $bytes.Length)
        }
        finally { $fs.Dispose() }
        $Target.Warned = $false
    }
    catch {
        # An unreachable share must not slow every tick down, so it is left
        # alone for ten minutes. A local failure is retried on the next line.
        if ($Target.IsRemote) { $Target.DownUntil = [DateTime]::UtcNow.AddMinutes(10) }
        if (-not $Target.Warned -and $script:EchoLog) {
            Write-Host ("Cannot write log {0}: {1}" -f $Target.Path, $_.Exception.Message) -ForegroundColor DarkYellow
        }
        $Target.Warned = $true
    }
}

# Writes a timestamped line to the launcher's log(s).
function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    if ($Level -eq 'DEBUG' -and -not $script:DebugLogging) { return }

    $now = Get-Date
    $type = switch ($Level) { 'WARN' { 2 } 'ERROR' { 3 } default { 1 } }
    $msg = $Text -replace '\]LOG\]', '] LOG]'
    if ($Level -eq 'DEBUG') { $msg = "[debug] $msg" }
    $line = '<![LOG[{0}]LOG]!><time="{1}+000" date="{2}" component="WebLauncher" context="{3}" type="{4}" thread="{5}" file="WebLauncher.ps1">' -f `
        $msg, $now.ToString('HH:mm:ss.fff', $Invariant), $now.ToString('MM-dd-yyyy', $Invariant), $script:InstanceName, $type, $PID

    if ($script:EchoLog) {
        $color = switch ($Level) { 'WARN' { 'Yellow' } 'ERROR' { 'Red' } 'DEBUG' { 'DarkGray' } default { 'Gray' } }
        Write-Host ("{0} {1,-5} {2}" -f $now.ToString('HH:mm:ss', $Invariant), $Level, $Text) -ForegroundColor $color
    }

    if ($script:LogTargets.Count -eq 0) {
        $script:LogBuffer.Add($line)
        return
    }
    foreach ($t in $script:LogTargets) { Add-LogLine -Target $t -Line $line }
}

# Sets up the local log and, if configured, the central (network) log.
function Initialize-Log {
    param([Parameter(Mandatory)]$Config)

    $targets = @()
    $localPath = Join-Path $Config.LogDir $Config.LogName
    try {
        if (-not (Test-Path -LiteralPath $Config.LogDir)) { New-Item -ItemType Directory -Path $Config.LogDir -Force | Out-Null }
        $targets += New-LogTarget -Path $localPath -IsRemote $false
    }
    catch {
        $targets += New-LogTarget -Path (Join-Path $env:TEMP $Config.LogName) -IsRemote $false
    }
    if ($Config.RemoteLogDir) {
        $targets += New-LogTarget -Path (Join-Path $Config.RemoteLogDir $Config.LogName) -IsRemote $true
    }

    $first = ($script:LogTargets.Count -eq 0)
    $script:LogTargets = $targets
    if ($first) {
        foreach ($line in $script:LogBuffer) {
            foreach ($t in $script:LogTargets) { Add-LogLine -Target $t -Line $line }
        }
        $script:LogBuffer.Clear()
    }
}

# Turns a PowerShell error into a short message with the script line number.
function Get-ErrorText {
    param($ErrorRecord)
    $e = $ErrorRecord.Exception
    while ($e -is [AggregateException] -and $e.InnerException) { $e = $e.InnerException }
    $where = ''
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptLineNumber) {
        $where = " (line $($ErrorRecord.InvocationInfo.ScriptLineNumber))"
    }
    return ($e.Message + $where)
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
$DefaultErrorPhrases = @(
    'HTTP ERROR',
    '500 Internal Server Error',
    '502 Bad Gateway',
    '503 Service Unavailable',
    '504 Gateway Time',
    'Service Unavailable',
    "This page isn't working",
    "Hmm, we can't reach this page",
    "This site can't be reached"
)
# Returns the first non-blank value among the given config keys (case-insensitive).
function Get-ConfigValue {
    # First of the given keys that is present and not blank. Key lookup is
    # case-insensitive, like the old launcher's.
    param($Object, [string[]]$Names, $Default = $null)
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if (-not $p -or $null -eq $p.Value) { continue }
        if ($p.Value -is [string] -and [string]::IsNullOrWhiteSpace($p.Value)) { continue }
        return $p.Value
    }
    return $Default
}

# Converts a config value (true/yes/1...) to true/false, with a default.
function ConvertTo-Flag {
    param($Value, [bool]$Default)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -in @('1', 'true', 'yes', 'y', 'on')) { return $true }
    if ($s -in @('0', 'false', 'no', 'n', 'off')) { return $false }
    return $Default
}

# Converts a config value to a number within min/max, with a default.
function ConvertTo-Number {
    param($Value, [double]$Default, [double]$Min = 0, [double]$Max = [double]::MaxValue)
    if ($null -eq $Value) { return $Default }
    $d = 0.0
    $style = [Globalization.NumberStyles]::Float
    if (-not [double]::TryParse(([string]$Value).Trim(), $style, $Invariant, [ref]$d)) { return $Default }
    return [math]::Min($Max, [math]::Max($Min, $d))
}

# Splits a comma/semicolon separated value (or array) into trimmed strings.
function ConvertTo-StringList {
    param($Value)
    if ($null -eq $Value) { return @() }
    $items = if ($Value -is [string]) { $Value -split '[,;]' } else { @($Value) }
    return @($items | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

# Parses "HH:mm" config values into times of day, noting invalid ones.
function ConvertTo-TimesOfDay {
    param([string[]]$Values, [string]$What, [System.Collections.Generic.List[string]]$Problems)
    $out = @()
    foreach ($v in $Values) {
        $t = [TimeSpan]::Zero
        $formats = [string[]]@('h\:mm', 'hh\:mm')
        if ([TimeSpan]::TryParseExact($v, $formats, $Invariant, [ref]$t) -and $t.TotalHours -lt 24) { $out += $t }
        else { $Problems.Add("Ignoring $What time '$v': expected HH:mm.") }
    }
    return $out
}

# Returns the configured address unchanged (kept for parity with PBI Launcher).
function Get-EffectiveUrl {
    # The address as configured: no Power BI switches to add.
    param([string]$Url, [string]$Mode)
    return $Url
}

# Finds the config JSON file to use (the -Config path or the screen folder).
function Resolve-ConfigPath {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "Config file not found: $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).ProviderPath
    }
    foreach ($name in @("$ComputerName.json", 'config.json')) {
        $p = Join-Path $Here $name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "No config file. Expected $ComputerName.json in $Here - copy EXAMPLE.json and fill it in."
}

# Reads the config JSON and returns it as one object of checked, typed values.
function Read-LauncherConfig {
    <#
        Reads the config into one object with typed, validated values. Only
        DisplayURL is required; see EXAMPLE.json for the rest.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $problems = New-Object System.Collections.Generic.List[string]
    $parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
    $raw = @($parsed)[0]
    if ($null -eq $raw) { throw "Config file is empty: $Path" }

    $url = [string](Get-ConfigValue $raw @('DisplayURL', 'URL'))
    if (-not $url) { throw "DisplayURL is missing in $Path" }
    $uri = $null
    if (-not [Uri]::TryCreate($url.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('https', 'http', 'file')) {
        throw "DisplayURL is not a web address: $url"
    }
    $url = $uri.AbsoluteUri

    $instance = $script:Instance

    $browserMode = ([string](Get-ConfigValue $raw @('BrowserMode') 'app')).ToLowerInvariant()
    if ($browserMode -notin @('app', 'kiosk')) { $problems.Add("BrowserMode '$browserMode' is not app or kiosk; using app."); $browserMode = 'app' }

    $match = ([string](Get-ConfigValue $raw @('TargetMatch') 'path')).ToLowerInvariant()
    if ($match -notin @('path', 'host', 'exact')) { $problems.Add("TargetMatch '$match' is not path, host or exact; using path."); $match = 'path' }

    $refreshMinutes = Get-ConfigValue $raw @('RefreshMinutes')
    if ($null -ne $refreshMinutes) { $refreshMinutes = ConvertTo-Number $refreshMinutes 0 0 10080 }
    elseif (ConvertTo-Flag (Get-ConfigValue $raw @('EnableRefresh')) $false) { $refreshMinutes = ConvertTo-Number (Get-ConfigValue $raw @('BrowserRefreshDelay')) 15 1 10080 }
    else { $refreshMinutes = 0 }

    $refreshTimes = @(ConvertTo-TimesOfDay -Values (ConvertTo-StringList (Get-ConfigValue $raw @('RefreshTimes', 'ForcedRefreshTime'))) -What 'refresh' -Problems $problems)

    $restartTime = $null
    if (ConvertTo-Flag (Get-ConfigValue $raw @('ScheduledRestartEnabled')) $false) {
        $t = @(ConvertTo-TimesOfDay -Values (ConvertTo-StringList (Get-ConfigValue $raw @('ScheduledRestartTime'))) -What 'restart' -Problems $problems)
        if ($t.Count -gt 0) { $restartTime = $t[0] }
    }

    $defaultLog = if ($instance -ieq 'S1') { "WebLauncher_$ComputerName.log" } else { "WebLauncher_${ComputerName}_$instance.log" }
    $logName = [IO.Path]::GetFileName([string](Get-ConfigValue $raw @('LogName') $defaultLog))

    $profileDir = [string](Get-ConfigValue $raw @('ProfileDir') (Join-Path $env:LOCALAPPDATA "WebLauncher\Profile-$instance"))
    $profileDir = [Environment]::ExpandEnvironmentVariables($profileDir).TrimEnd('\')

    $logDir = [string](Get-ConfigValue $raw @('LogPath') (Join-Path $Here 'Logs'))
    if (-not $logDir) { $logDir = Join-Path $Here 'Logs' }
    $logDir = [Environment]::ExpandEnvironmentVariables($logDir)

    $cfg = [pscustomobject]@{
        Path                     = $Path
        Instance                 = $instance
        DisplayUrl               = $url
        TargetMatch              = $match
        UserName                 = ''
        LoginHosts               = @()
        ReportHosts              = @()
        BrowserMode              = $browserMode
        InPrivate                = ConvertTo-Flag (Get-ConfigValue $raw @('InPrivate')) $true
        FullScreenWindow         = ConvertTo-Flag (Get-ConfigValue $raw @('KioskMode', 'FullScreenWindow')) $true
        ReportFullScreen         = 'none'
        HideNavigation           = $false
        UsePrimaryScreen         = ConvertTo-Flag (Get-ConfigValue $raw @('UsePriScreen', 'UsePrimaryScreen')) $false
        ScreenNumber             = [int](ConvertTo-Number (Get-ConfigValue $raw @('ScreenSelect', 'ScreenNumber')) 1 1 16)
        DisplayWaitSeconds       = [int](ConvertTo-Number (Get-ConfigValue $raw @('DisplayWaitSeconds')) 120 0 3600)
        ZoomPercent              = [int](ConvertTo-Number (Get-ConfigValue $raw @('ZoomPercent')) 100 25 500)
        BrowserLanguage          = [string](Get-ConfigValue $raw @('BrowserLanguage') '')
        ExtraBrowserArgs         = @(ConvertTo-StringList (Get-ConfigValue $raw @('ExtraBrowserArgs')))
        EdgePath                 = [string](Get-ConfigValue $raw @('EdgePath') '')
        ProfileDir               = $profileDir
        DebugPort                = [int](ConvertTo-Number (Get-ConfigValue $raw @('DebugPort')) 0 0 65535)
        RefreshMinutes           = [double]$refreshMinutes
        RefreshTimes             = $refreshTimes
        RestartTime              = $restartTime
        RestartDelaySeconds      = [int](ConvertTo-Number (Get-ConfigValue $raw @('RestartDelay')) 30 0 600)
        StartupDelaySeconds      = [int](ConvertTo-Number (Get-ConfigValue $raw @('StartupDelay')) 0 0 3600)
        Disabled                 = ConvertTo-Flag (Get-ConfigValue $raw @('DisableStartup')) $false
        HealthCheckSeconds       = ConvertTo-Number (Get-ConfigValue $raw @('HealthCheckSeconds')) 20 1 600
        BlankReloadSeconds       = ConvertTo-Number (Get-ConfigValue $raw @('BlankReloadSeconds')) 120 0 7200
        OffTargetSeconds         = ConvertTo-Number (Get-ConfigValue $raw @('OffTargetSeconds')) 20 0 3600
        Supervised               = ConvertTo-Flag (Get-ConfigValue $raw @('Supervised')) $true
        BackButton               = ConvertTo-Flag (Get-ConfigValue $raw @('BackButton')) $true
        BackButtonText           = [string](Get-ConfigValue $raw @('BackButtonText') 'Back')
        BackButtonPosition       = ([string](Get-ConfigValue $raw @('BackButtonPosition') 'bottom-left')).ToLowerInvariant()
        ReturnAfterSeconds       = [int](ConvertTo-Number (Get-ConfigValue $raw @('ReturnAfterSeconds')) 120 0 86400)
        KeepLinksInWindow        = ConvertTo-Flag (Get-ConfigValue $raw @('KeepLinksInWindow')) $true
        ErrorChecksBeforeReload  = [int](ConvertTo-Number (Get-ConfigValue $raw @('ErrorChecksBeforeReload')) 3 1 100)
        MaxReloadsBeforeRelaunch = [int](ConvertTo-Number (Get-ConfigValue $raw @('MaxReloadsBeforeRelaunch')) 3 1 100)
        RebootAfterRelaunches    = [int](ConvertTo-Number (Get-ConfigValue $raw @('RebootAfterRelaunches')) 0 0 100)
        ErrorPhrases             = @(ConvertTo-StringList (Get-ConfigValue $raw @('ErrorPhrases') $DefaultErrorPhrases))
        ParkMouse                = ConvertTo-Flag (Get-ConfigValue $raw @('ParkMouse')) $true
        LogDir                   = $logDir
        RemoteLogDir             = [string](Get-ConfigValue $raw @('RemoteLogPath') '')
        LogName                  = $logName
        DebugLogging             = ConvertTo-Flag (Get-ConfigValue $raw @('DebugLogging')) $false
        JsonVersion              = [string](Get-ConfigValue $raw @('ConfigVersion', 'JsonVer') '')
        Problems                 = $problems
        EffectiveUrl             = ''
        BrowserSignature         = ''
    }
    if ($cfg.BackButtonPosition -notin @('top-left', 'top-right', 'bottom-left', 'bottom-right')) {
        $problems.Add("BackButtonPosition '$($cfg.BackButtonPosition)' is not top-left, top-right, bottom-left or bottom-right; using bottom-left.")
        $cfg.BackButtonPosition = 'bottom-left'
    }
    $cfg.EffectiveUrl = $cfg.DisplayUrl

    # Anything that needs a new Edge when it changes. Everything else in the
    # file applies on the next tick.
    $cfg.BrowserSignature = (@(
            $cfg.EffectiveUrl, $cfg.BrowserMode, $cfg.InPrivate, $cfg.FullScreenWindow, $cfg.UsePrimaryScreen, $cfg.ScreenNumber,
            $cfg.ZoomPercent, $cfg.BrowserLanguage, ($cfg.ExtraBrowserArgs -join ' '), $cfg.EdgePath, $cfg.ProfileDir, $cfg.DebugPort
        ) -join '|')

    return $cfg
}

# ---------------------------------------------------------------------------
# Status and persistent state
# ---------------------------------------------------------------------------
$script:StatusDir = Join-Path $Here 'Status'
$script:Status = [ordered]@{}
$script:PersistentState = @{}

# Saves an object as JSON via a temp file so the file is never half-written.
function Write-JsonFile {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Object -Depth 6), $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# Creates the status record that the Fleet Manager reads.
function Initialize-Status {
    param($Config)
    $script:Status = [ordered]@{
        Host            = $ComputerName
        Instance        = $Config.Instance
        Launcher        = 'WEB'
        Screen          = $Instance
        LauncherVersion = $LauncherVersion
        WindowsUser     = "$env:USERDOMAIN\$env:USERNAME"
        Pid             = $PID
        StartedUtc      = [DateTime]::UtcNow.ToString('o')
        State           = 'STARTING'
        StateSinceUtc   = [DateTime]::UtcNow.ToString('o')
        Detail          = ''
        DisplayUrl      = $Config.DisplayUrl
        CurrentUrl      = ''
        Title           = ''
        Supervised      = $true
        EdgeVersion     = ''
        BrowserPid      = 0
        BrowserStarts   = 0
        Reloads         = 0
        PcBootUtc       = ''
        LastShownUtc    = ''
        LastReloadUtc   = ''
        LastError       = ''
        UpdatedUtc      = ''
    }
}

# Changes the launcher state (SHOWING, RECOVERING, ...) and logs the change.
function Set-State {
    param([Parameter(Mandatory)][string]$State, [string]$Detail = '')
    if ($script:Status.State -ne $State -or $script:Status.Detail -ne $Detail) {
        if ($script:Status.State -ne $State) {
            $level = if ($State -in @('SIGNIN_BLOCKED', 'ERROR')) { 'ERROR' } elseif ($State -in @('RECOVERING', 'WAITING_DISPLAY')) { 'WARN' } else { 'INFO' }
            $suffix = if ($Detail) { ": $Detail" } else { '' }
            Write-Log ("State {0} -> {1}{2}" -f $script:Status.State, $State, $suffix) $level
            $script:Status.StateSinceUtc = [DateTime]::UtcNow.ToString('o')
        }
        $script:Status.State = $State
        $script:Status.Detail = $Detail
    }
    if ($State -eq 'SHOWING') { $script:Status.LastShownUtc = [DateTime]::UtcNow.ToString('o') }
}

# Writes the current status to Status\<screen>.status.json.
function Save-Status {
    $script:Status.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    try { Write-JsonFile -Path (Join-Path $script:StatusDir "$($script:InstanceName).status.json") -Object $script:Status }
    catch { Write-Log "Cannot write the status file: $($_.Exception.Message)" 'DEBUG' }
}

# Loads the state kept across launcher restarts from Status\<screen>.state.json.
function Read-PersistentState {
    $p = Join-Path $script:StatusDir "$($script:InstanceName).state.json"
    $script:PersistentState = @{}
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        $o = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($p))
        foreach ($prop in $o.PSObject.Properties) { $script:PersistentState[$prop.Name] = $prop.Value }
    }
    catch { Write-Log "Ignoring an unreadable state file: $($_.Exception.Message)" 'WARN' }
}

# Saves the state kept across launcher restarts.
function Save-PersistentState {
    try { Write-JsonFile -Path (Join-Path $script:StatusDir "$($script:InstanceName).state.json") -Object $script:PersistentState }
    catch { Write-Log "Cannot write the state file: $($_.Exception.Message)" 'WARN' }
}

# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------
# Lists the connected monitors and their positions.
function Get-Monitors {
    if ($script:NativeReady) {
        return @([WebLauncherNative.Api]::GetMonitors() | ForEach-Object {
                $f = $_ -split '\|'
                [pscustomobject]@{ Device = $f[0]; X = [int]$f[1]; Y = [int]$f[2]; Width = [int]$f[3]; Height = [int]$f[4]; Primary = ($f[5] -eq '1') }
            })
    }
    Add-Type -AssemblyName System.Windows.Forms
    return @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            [pscustomobject]@{ Device = $_.DeviceName; X = $_.Bounds.X; Y = $_.Bounds.Y; Width = $_.Bounds.Width; Height = $_.Bounds.Height; Primary = $_.Primary }
        })
}

# Picks the monitor Edge is shown on, waiting for a TV that is still powering up.
function Get-TargetScreen {
    <#
        The monitor Edge goes on. ScreenSelect = n means \\.\DISPLAYn - an
        exact match, where the old launcher's "ends with n" also matched
        DISPLAY11 for 1. A TV that is still powering up is waited for; after
        that the primary screen is used, so the page shows somewhere.
    #>
    param([Parameter(Mandatory)]$Config, [int]$WaitSeconds = 0, [switch]$Quiet)

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    $announced = $false
    while ($true) {
        $monitors = @(Get-Monitors)
        $primary = @($monitors | Where-Object { $_.Primary }) + @($monitors) | Select-Object -First 1

        if ($Config.UsePrimaryScreen -and $primary) { return $primary }
        foreach ($m in $monitors) {
            if ($m.Device -match 'DISPLAY(\d+)$' -and [int]$Matches[1] -eq $Config.ScreenNumber) { return $m }
        }

        if ((Get-Date) -ge $deadline) {
            if (-not $Quiet) {
                $seen = ($monitors | ForEach-Object { $_.Device.TrimStart('\', '.') }) -join ', '
                Write-Log ("Screen {0} not found (have: {1}); using the primary screen." -f $Config.ScreenNumber, $seen) 'WARN'
            }
            if ($primary) { return $primary }
            return [pscustomobject]@{ Device = '(none)'; X = 0; Y = 0; Width = 1920; Height = 1080; Primary = $true }
        }
        if (-not $announced) {
            Set-State 'WAITING_DISPLAY' ("screen {0} is not connected yet; waiting up to {1} s" -f $Config.ScreenNumber, $WaitSeconds)
            Save-Status
            $announced = $true
        }
        Start-Sleep -Seconds 5
    }
}

# Moves the mouse pointer to the corner of the kiosk screen.
function Move-CursorAside {
    # A cursor resting on the page shows tooltips. Park it in the top
    # right corner of the kiosk screen, as the old StartupLauncher did.
    param($Screen)
    if (-not $script:NativeReady -or -not $Screen) { return }
    try { [void][WebLauncherNative.Api]::SetCursorPos($Screen.X + $Screen.Width - 1, $Screen.Y) } catch {}
}

# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------
$script:EdgePath = ''
$script:Supervised = $true
$script:UnsupervisedWhy = ''

# Finds msedge.exe (config value, registry or standard install folders).
function Find-EdgePath {
    param([string]$Configured)
    $candidates = @()
    if ($Configured) { $candidates += [Environment]::ExpandEnvironmentVariables($Configured) }
    foreach ($key in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe')) {
        try {
            $v = (Get-Item -LiteralPath $key -ErrorAction Stop).GetValue('')
            if ($v) { $candidates += $v.Trim('"') }
        }
        catch {}
    }
    $candidates += (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
    $candidates += (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe')

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    throw 'Microsoft Edge (msedge.exe) is not installed where expected. Set EdgePath in the config.'
}

# Checks whether Edge policy blocks the DevTools port the launcher uses.
function Get-RemoteDebuggingPolicy {
    # Edge's RemoteDebuggingAllowed policy. Disabled means no DevTools port,
    # and the launcher falls back to starting Edge unsupervised.
    foreach ($key in @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKCU:\SOFTWARE\Policies\Microsoft\Edge')) {
        try {
            $v = (Get-Item -LiteralPath $key -ErrorAction Stop).GetValue('RemoteDebuggingAllowed')
            if ($null -ne $v -and [int]$v -eq 0) { return $key }
        }
        catch {}
    }
    return $null
}

# Finds the Edge processes using this launcher's profile folder.
function Get-ProfileBrowserProcesses {
    param([Parameter(Mandatory)][string]$ProfileDir)
    # Match the whole directory name, so Profile-S1 does not also match
    # Profile-S10.
    $pattern = [regex]::Escape($ProfileDir) + '(?:"|\\?\s|\\?$)'
    return @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern })
}

# Closes any Edge processes left on this launcher's profile.
function Stop-ProfileBrowsers {
    param([Parameter(Mandatory)][string]$ProfileDir)
    $procs = @(Get-ProfileBrowserProcesses -ProfileDir $ProfileDir)
    if ($procs.Count -eq 0) { return }
    Write-Log ("Closing {0} Edge process(es) left on this launcher's profile." -f $procs.Count) 'DEBUG'
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
    }
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline -and @(Get-ProfileBrowserProcesses -ProfileDir $ProfileDir).Count -gt 0) {
        Start-Sleep -Milliseconds 500
    }
}

# Prepares the launcher's own Edge profile (pop-ups off, last session marked clean).
function Initialize-Profile {
    <#
        A profile of the launcher's own, so nothing the kiosk account does in
        its own Edge can interfere. With InPrivate = 0 the Power BI sign-in
        also persists in it.

        A new profile starts with the pop-ups a wall screen can do without
        switched off: save password, translate, first-run. Every start marks
        the last session as having ended cleanly, so a killed Edge does not
        come back with a "Restore pages?" bubble over the page.
    #>
    param([Parameter(Mandatory)][string]$ProfileDir)

    $default = Join-Path $ProfileDir 'Default'
    if (-not (Test-Path -LiteralPath $default)) { New-Item -ItemType Directory -Path $default -Force | Out-Null }
    $prefs = Join-Path $default 'Preferences'

    if (-not (Test-Path -LiteralPath $prefs)) {
        $seed = '{"browser":{"has_seen_welcome_page":true,"check_default_browser":false},' +
        '"credentials_enable_service":false,' +
        '"profile":{"password_manager_enabled":false,"exit_type":"Normal","exited_cleanly":true},' +
        '"translate":{"enabled":false},' +
        '"autofill":{"profile_enabled":false,"credit_card_enabled":false}}'
        [IO.File]::WriteAllText($prefs, $seed, $Utf8NoBom)
        Write-Log "Created a new Edge profile in $ProfileDir."
        return
    }

    try {
        $text = [IO.File]::ReadAllText($prefs)
        $fixed = $text -replace '"exit_type"\s*:\s*"[^"]*"', '"exit_type":"Normal"' -replace '"exited_cleanly"\s*:\s*false', '"exited_cleanly":true'
        if ($fixed -cne $text) { [IO.File]::WriteAllText($prefs, $fixed, $Utf8NoBom) }
    }
    catch { Write-Log "Could not tidy the profile's Preferences: $($_.Exception.Message)" 'DEBUG' }
}

# Joins Edge command-line arguments, quoting any that contain spaces.
function ConvertTo-ArgumentString {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object {
                if ($_ -match '^(--[^=]+=)(.*\s.*)$' -and $_ -notmatch '"') { '{0}"{1}"' -f $Matches[1], $Matches[2] }
                elseif ($_ -match '\s' -and $_ -notmatch '"') { '"{0}"' -f $_ }
                else { $_ }
            }) -join ' ')
}

# Starts Edge full screen on the kiosk monitor with a DevTools port.
function Start-Browser {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Reason)

    Disconnect-Cdp
    Stop-ProfileBrowsers -ProfileDir $Config.ProfileDir
    Initialize-Profile -ProfileDir $Config.ProfileDir

    $screen = Get-TargetScreen -Config $Config -WaitSeconds 0 -Quiet:($Reason -ne 'startup')
    $url = $Config.EffectiveUrl

    $portFile = Join-Path $Config.ProfileDir 'DevToolsActivePort'
    if (Test-Path -LiteralPath $portFile) { Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue }

    $a = New-Object System.Collections.Generic.List[string]
    $a.Add("--user-data-dir=`"$($Config.ProfileDir)`"")
    if ($script:Supervised) {
        # Port 0: Edge picks a free port and writes it to DevToolsActivePort,
        # so two launchers (two screens) can never collide. It listens on
        # 127.0.0.1 only.
        $a.Add("--remote-debugging-port=$($Config.DebugPort)")
    }
    # --disable-features=msImplicitSignin: on a domain PC Edge otherwise signs
    # a new profile in with the Windows account by itself, pops up a sync
    # dialog over the page, and can sign Power BI in as that account
    # instead of the configured one. --disable-sync keeps the dialog away
    # for good.
    foreach ($x in @('--no-first-run', '--no-default-browser-check', '--hide-crash-restore-bubble', '--noerrdialogs',
            '--disable-sync', '--disable-features=Translate,msImplicitSignin')) { $a.Add($x) }
    if ($Config.ZoomPercent -ne 100) {
        $a.Add('--force-device-scale-factor=' + ($Config.ZoomPercent / 100.0).ToString('0.##', $Invariant))
    }
    if ($Config.BrowserLanguage) { $a.Add("--lang=$($Config.BrowserLanguage)") }

    if ($Headless) {
        $a.Add('--headless')
        $a.Add('--window-size=1600,900')
        $a.Add($url)
    }
    else {
        $a.Add(("--window-position={0},{1}" -f $screen.X, $screen.Y))
        $a.Add(("--window-size={0},{1}" -f $screen.Width, $screen.Height))
        if ($Config.BrowserMode -eq 'kiosk') {
            # Edge's own kiosk mode (always InPrivate). "app" - a full-screen
            # app window - is the default.
            $a.Add('--kiosk')
            $a.Add('--edge-kiosk-type=fullscreen')
            $a.Add($url)
        }
        else {
            if ($Config.FullScreenWindow) { $a.Add('--start-fullscreen') }
            $a.Add("--app=`"$url`"")
        }
    }
    if ($Config.InPrivate -and $Config.BrowserMode -ne 'kiosk') {
        # On a domain PC Edge signs Microsoft sites in with the Windows
        # account on its own - Power BI then opens as the kiosk's AD account,
        # not the configured one. InPrivate is the documented way to switch
        # that off; the price is a fresh sign-in whenever Edge starts, which
        # the launcher does unattended. (Kiosk mode is always InPrivate.)
        $a.Add('--inprivate')
    }
    foreach ($x in $Config.ExtraBrowserArgs) { $a.Add($x) }

    $argString = ConvertTo-ArgumentString -Arguments $a
    Write-Log ("Starting Edge ({0}) on {1} at {2},{3} {4}x{5}." -f $Reason, $screen.Device.TrimStart('\', '.'), $screen.X, $screen.Y, $screen.Width, $screen.Height)
    Write-Log "msedge.exe $argString" 'DEBUG'

    $proc = Start-Process -FilePath $script:EdgePath -ArgumentList $argString -PassThru
    $browser = [pscustomobject]@{ Process = $proc; Pid = $proc.Id; Port = 0; StartedUtc = [DateTime]::UtcNow; Screen = $screen }

    if ($script:Supervised) {
        $deadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path -LiteralPath $portFile) {
                try {
                    $first = @(Get-Content -LiteralPath $portFile -ErrorAction Stop)[0]
                    if ($first -match '^\d+$' -and [int]$first -gt 0) { $browser.Port = [int]$first; break }
                }
                catch {}
            }
            Start-Sleep -Milliseconds 300
        }
        if ($browser.Port -eq 0) {
            $alive = @(Get-ProfileBrowserProcesses -ProfileDir $Config.ProfileDir).Count -gt 0
            if ($alive) {
                throw 'Edge started but did not open its DevTools port within 45 s. Is remote debugging blocked by policy (RemoteDebuggingAllowed)?'
            }
            throw 'Edge exited straight after starting.'
        }
    }

    $script:Browser = $browser
    $script:Status.BrowserStarts++
    $script:Status.BrowserPid = $proc.Id
    $script:Session.BrowserHung = 0
    $script:Session.Browsing = $false
    $script:Session.StrayPages.Clear()
    if ($Reason -ne 'startup') { $script:Session.Relaunches.Add([DateTime]::UtcNow) }

    if ($script:Supervised) {
        try {
            $v = ConvertFrom-Json -InputObject (Invoke-CdpHttp -Path '/json/version')
            $script:Status.EdgeVersion = [string]$v.Browser
        }
        catch {}
        Connect-Cdp -Config $Config
        # In app and kiosk mode Edge opens the page itself; a page that is
        # still blank after a few seconds (or a headless one) is sent there.
        $pageUrl = ''
        for ($i = 0; $i -lt 5; $i++) {
            try {
                $st = Get-PageState -Config $Config
                if ($st) { $pageUrl = [string]$st.url }
                if ($pageUrl -and $pageUrl -ne 'about:blank') { break }
            }
            catch {}
            Start-Sleep -Seconds 1
        }
        if (-not $pageUrl -or $pageUrl -eq 'about:blank') { Open-Target -Config $Config -Why 'new browser' }
        Write-Log ("Edge {0} is up (PID {1}, DevTools port {2})." -f $script:Status.EdgeVersion, $proc.Id, $browser.Port)
    }
    else {
        Write-Log ("Edge is up (PID {0}), unsupervised." -f $proc.Id)
    }

    Reset-PageLoad -Config $Config
    if ($Config.ParkMouse -and -not $Headless) { Move-CursorAside -Screen $screen }
}

# Closes the launcher's Edge.
function Stop-Browser {
    param([Parameter(Mandatory)]$Config, [string]$Why = '')
    Disconnect-Cdp
    if ($Why) { Write-Log "Closing Edge: $Why" }
    Stop-ProfileBrowsers -ProfileDir $Config.ProfileDir
    $script:Browser = $null
    $script:Status.BrowserPid = 0
}

# Closes Edge and starts a fresh one.
function Restart-Browser {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)
    Write-Log "Restarting Edge: $Why" 'WARN'
    Set-State 'RECOVERING' "restarting Edge: $Why"
    $script:Browser = $null
    try { Start-Browser -Config $Config -Reason $Why }
    catch { Register-LaunchFailure -ErrorRecord $_ }
}

# Counts a failed Edge start and schedules the next try with a growing wait.
function Register-LaunchFailure {
    param($ErrorRecord)
    $s = $script:Session
    $s.LaunchFailures++
    # 10 s, 30 s, 1 min, 2 min, then every 5 min.
    $waits = @(10, 30, 60, 120, 300)
    $wait = $waits[[math]::Min($s.LaunchFailures - 1, $waits.Count - 1)]
    $s.NextLaunchUtc = [DateTime]::UtcNow.AddSeconds($wait)
    $text = Get-ErrorText $ErrorRecord
    $script:Status.LastError = $text
    Write-Log ("Could not start Edge (attempt {0}): {1}. Next try in {2} s." -f $s.LaunchFailures, $text, $wait) 'ERROR'
    Set-State 'ERROR' "Edge will not start: $text"
    $script:Browser = $null
}

# Checks whether Edge is ok, hung or gone.
function Get-BrowserHealth {
    # ok, hung (process there, DevTools silent) or gone.
    param([Parameter(Mandatory)]$Config)
    if (-not $script:Browser) { return 'gone' }
    if ($script:Supervised) {
        try { $null = Invoke-CdpHttp -Path '/json/version' -TimeoutMs 4000; return 'ok' } catch {}
    }
    $alive = @(Get-ProfileBrowserProcesses -ProfileDir $Config.ProfileDir).Count -gt 0
    if (-not $alive) { return 'gone' }
    if ($script:Supervised) { return 'hung' }
    return 'ok'
}

# ---------------------------------------------------------------------------
# DevTools protocol
# ---------------------------------------------------------------------------
$script:Browser = $null
$script:Cdp = $null

# Makes an HTTP request to Edge's DevTools endpoint.
function Invoke-CdpHttp {
    param([Parameter(Mandatory)][string]$Path, [string]$Method = 'GET', [int]$TimeoutMs = 5000)

    if (-not $script:Browser -or $script:Browser.Port -eq 0) { throw 'No DevTools port.' }
    $req = [Net.WebRequest]::Create(('http://127.0.0.1:{0}{1}' -f $script:Browser.Port, $Path))
    $req.Method = $Method
    # Never through the corporate proxy - this is a loopback call.
    $req.Proxy = $null
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    if ($Method -ne 'GET') { $req.ContentLength = 0 }
    $resp = $req.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $resp.Close() }
}

# Closes the DevTools WebSocket connection.
function Disconnect-Cdp {
    if (-not $script:Cdp) { return }
    try { $script:Cdp.Socket.Abort() } catch {}
    try { $script:Cdp.Socket.Dispose() } catch {}
    $script:Cdp = $null
}

# Lists the pages (tabs) open in Edge, via DevTools.
function Get-PageTargets {
    $parsed = ConvertFrom-Json -InputObject (Invoke-CdpHttp -Path '/json/list')
    return @(@($parsed) | Where-Object { $_.type -eq 'page' -and ([string]$_.url) -notlike 'devtools://*' })
}

# Connects to the kiosk page over DevTools (WebSocket).
function Connect-Cdp {
    <#
        Connects to the page. The target list is only a snapshot: during a
        cross-site redirect (the page to Microsoft sign-in) Edge can list
        the outgoing and the incoming page side by side for a moment, and
        the one picked may be gone a second later. So a failed connection is
        retried on a fresh list, and nothing is closed here - see
        Invoke-StrayPages for that.
    #>
    param([Parameter(Mandatory)]$Config)

    Disconnect-Cdp
    $lastError = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $pages = @(Get-PageTargets)
        if ($pages.Count -eq 0) {
            # Every window was closed while Edge kept running. Open a new one.
            $created = ConvertFrom-Json -InputObject (Invoke-CdpHttp -Path '/json/new?about:blank' -Method PUT)
            $pages = @($created)
            Write-Log 'Edge had no page open; opened a new one.' 'WARN'
        }
        # The page if it is there, else any web page, and an Edge-internal
        # page (a dialog) only if there is nothing else.
        $web = @($pages | Where-Object { ([string]$_.url) -notmatch '^(edge|chrome|chrome-extension)://' })
        $page = @($pages | Where-Object { Test-IsTargetUrl -Current ([string]$_.url) -Target $Config.EffectiveUrl }) + $web + $pages | Select-Object -First 1

        $ws = New-Object Net.WebSockets.ClientWebSocket
        $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
        try { $ws.Options.Proxy = $null } catch {}
        try {
            $task = $ws.ConnectAsync([Uri]([string]$page.webSocketDebuggerUrl), [Threading.CancellationToken]::None)
            if (-not $task.Wait(10000)) { throw 'timed out' }
            $script:Cdp = [pscustomobject]@{ Socket = $ws; NextId = 0; TargetId = [string]$page.id; Buffer = (New-Object byte[] 65536) }
            Write-Log ("Connected to page {0} ({1})." -f $page.id, $page.url) 'DEBUG'
            Register-PageScripts -Config $Config
            return
        }
        catch {
            try { $ws.Abort(); $ws.Dispose() } catch {}
            $lastError = Get-ErrorText $_
            Start-Sleep -Seconds 1
        }
    }
    throw "Cannot connect to the page: $lastError"
}

# Handles extra windows: closes them and opens their address in the kiosk window.
function Invoke-StrayPages {
    <#
        Pages besides the kiosk's own. The page script already keeps links
        in the kiosk window; a new window that slips past it (a link in an
        embedded frame, say) is closed and its address opened in the kiosk
        window instead, where the Back button is (KeepLinksInWindow). A
        sign-in popup gets a minute to finish, a blank one ten seconds,
        anything else is closed after a minute.

        Only a page seen twice, while the launcher's own page answers, is
        acted on - never a snapshot taken mid-navigation, when Edge can
        briefly list the outgoing and the incoming page side by side.
        Returns $true when it sent the kiosk page somewhere.
    #>
    param([Parameter(Mandatory)]$Config, [bool]$MainOnSignIn)

    $s = $script:Session
    if (-not $script:Cdp) { return $false }
    $others = @(Get-PageTargets | Where-Object { [string]$_.id -ne $script:Cdp.TargetId })
    if ($others.Count -eq 0) {
        $s.StrayPages.Clear()
        return $false
    }

    $now = [DateTime]::UtcNow
    $fresh = @($others | Where-Object { -not $s.StrayPages.ContainsKey([string]$_.id) })
    foreach ($p in $fresh) { $s.StrayPages[[string]$p.id] = $now }
    if ($fresh.Count -gt 0) {
        # Give a new window a moment to load its address, then look again.
        Start-Sleep -Milliseconds 1500
        $others = @(Get-PageTargets | Where-Object { [string]$_.id -ne $script:Cdp.TargetId })
        $now = [DateTime]::UtcNow
    }
    # Throws if the kiosk page does not answer.
    $null = Invoke-Cdp -Config $Config -Method 'Runtime.evaluate' -Params @{ expression = '1' } -TimeoutSec 5

    $navigated = $false
    $seen = @{}
    foreach ($p in $others) {
        $id = [string]$p.id
        $seen[$id] = $true
        if (-not $s.StrayPages.ContainsKey($id)) { $s.StrayPages[$id] = $now; continue }
        $age = ($now - [DateTime]$s.StrayPages[$id]).TotalSeconds
        if ($age -lt 1) { continue }

        $url = [string]$p.url
        $pageUri = $null
        $web = [Uri]::TryCreate($url, [UriKind]::Absolute, [ref]$pageUri) -and $pageUri.Scheme -in @('http', 'https')
        $adopt = $false
        if ($web -and $Config.LoginHosts -contains $pageUri.Host.ToLowerInvariant()) { if ($age -lt 60) { continue } }
        elseif ($web -and $Config.KeepLinksInWindow -and -not $MainOnSignIn -and -not $navigated) { $adopt = $true }
        elseif ($web) { if ($age -lt 55) { continue } }
        elseif ($age -lt 10) { continue }

        try { $null = Invoke-CdpHttp -Path ('/json/close/' + $id) } catch {}
        $s.StrayPages.Remove($id)
        if ($adopt) {
            Write-Log ("A link opened a new window ({0}); showing it in the kiosk window instead." -f $url)
            Start-Browsing -Url $url
            $null = Invoke-Cdp -Config $Config -Method 'Page.navigate' -Params @{ url = $url } -TimeoutSec 30
            $navigated = $true
        }
        else {
            Write-Log ("Closed an extra page: {0}" -f $(if ($url) { $url } else { '(blank)' })) 'WARN'
        }
    }
    foreach ($id in @($s.StrayPages.Keys)) { if (-not $seen.ContainsKey($id)) { $s.StrayPages.Remove($id) } }
    return $navigated
}

# Notes that someone left the page through a link (starts the return-to-page timer).
function Start-Browsing {
    # Someone has left the page through a link.
    param([string]$Url)
    $s = $script:Session
    if ($s.Browsing) { return }
    $s.Browsing = $true
    $s.BrowsingSinceUtc = [DateTime]::UtcNow
    Write-Log ("Someone opened {0} from the page." -f $Url)
}

# Sleeps until the next check, waking early for a control file or a message.
function Wait-NextTick {
    # Sleeps until the next tick, but wakes early for a control file or a
    # window that has just opened, so a link reaches the kiosk window in
    # about two seconds rather than one health-check interval.
    param([Parameter(Mandatory)]$Config, [double]$Seconds)

    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    $controls = @(@('kill.txt', 'relaunch.txt', 'refresh.txt', 'restart.txt', 'snapshot.txt') | ForEach-Object { Join-Path $Here $_ })
    while ($true) {
        $left = ($until - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -le 0) { return }
        Start-Sleep -Milliseconds ([int][math]::Min(1000, $left))
        foreach ($c in $controls) {
            if (-not $script:ControlWarned.ContainsKey($c) -and (Test-Path -LiteralPath $c)) { return }
        }
        if (-not ($script:Supervised -and $script:Browser -and $script:Cdp)) { continue }
        try {
            $now = [DateTime]::UtcNow
            foreach ($p in @(Get-PageTargets)) {
                $id = [string]$p.id
                if ($id -eq $script:Cdp.TargetId) { continue }
                if (-not $script:Session.StrayPages.ContainsKey($id)) { return }
                $age = ($now - [DateTime]$script:Session.StrayPages[$id]).TotalSeconds
                if ($age -ge 1 -and $age -lt 12) { return }
            }
        }
        catch {}
    }
}

# Reads one complete message from the DevTools WebSocket.
function Receive-CdpMessage {
    param([Parameter(Mandatory)][DateTime]$DeadlineUtc)

    $c = $script:Cdp
    $ms = New-Object IO.MemoryStream
    try {
        do {
            $left = [int][math]::Floor(($DeadlineUtc - [DateTime]::UtcNow).TotalMilliseconds)
            if ($left -le 0) { throw 'timed out waiting for Edge' }
            $segment = [ArraySegment[byte]]::new($c.Buffer)
            $task = $c.Socket.ReceiveAsync($segment, [Threading.CancellationToken]::None)
            if (-not $task.Wait($left)) { throw 'timed out waiting for Edge' }
            $r = $task.Result
            if ($r.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw 'Edge closed the connection' }
            $ms.Write($c.Buffer, 0, $r.Count)
        } while (-not $r.EndOfMessage)
        return [Text.Encoding]::UTF8.GetString($ms.ToArray())
    }
    finally { $ms.Dispose() }
}

# Sends one DevTools command and waits for its answer.
function Invoke-Cdp {
    <#
        One DevTools command, one answer. A protocol error (the page refused
        the command) is thrown as it is and the connection kept. A transport
        failure (timeout, closed socket) also drops the connection: a
        WebSocket with an abandoned receive cannot be used again, and the
        next call reconnects.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Method,
        [hashtable]$Params = @{},
        [int]$TimeoutSec = 15
    )

    if (-not $script:Cdp) { Connect-Cdp -Config $Config }
    $c = $script:Cdp
    $c.NextId++
    $id = $c.NextId
    $payload = ConvertTo-Json -InputObject @{ id = $id; method = $Method; params = $Params } -Compress -Depth 10
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $payload = $null
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)

    $message = $null
    try {
        try {
            $segment = [ArraySegment[byte]]::new($bytes)
            $send = $c.Socket.SendAsync($segment, [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None)
            if (-not $send.Wait($TimeoutSec * 1000)) { throw 'timed out sending to Edge' }
        }
        finally {
            # The payload may carry the password (Input.insertText).
            [Array]::Clear($bytes, 0, $bytes.Length)
        }

        while ($true) {
            $msg = ConvertFrom-Json -InputObject (Receive-CdpMessage -DeadlineUtc $deadline)
            $idProp = $msg.PSObject.Properties['id']
            # Events (the Page domain is enabled) are not needed here.
            if (-not $idProp) { continue }
            if ([int]$idProp.Value -eq $id) { $message = $msg; break }
        }
    }
    catch {
        Disconnect-Cdp
        throw ("DevTools {0}: {1}" -f $Method, (Get-ErrorText $_))
    }

    $err = $message.PSObject.Properties['error']
    if ($err) { throw ("DevTools {0} refused: {1}" -f $Method, $err.Value.message) }
    return $message.result
}

# The page-side half: element finding and the page probe. Injected with
# every call, because each navigation starts a fresh window object.
$PageHelperJs = @'
(function () {
  if (window.__pbil2) return;
  var P = {};
  P.list = function (sel, root) {
    try { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); } catch (e) { return []; }
  };
  P.text = function () { return (document.body && (document.body.innerText || '')) || ''; };
  P.state = function (o) {
    var phrases = o.phrases || [];
    var t = P.text();
    var low = t.toLowerCase();
    var s = {
      url: location.href, host: location.hostname.toLowerCase(), proto: location.protocol, title: document.title,
      ready: document.readyState, textLen: t.trim().length, media: 0, onLogin: false,
      docFullscreen: !!(document.fullscreenElement || document.webkitFullscreenElement),
      errors: [], screen: null, back: null
    };
    // Something to see besides text: pictures, video, frames, big enough
    // to matter. A page of only a picture or a dashboard frame is not empty.
    var m = P.list('img, svg, canvas, video, iframe, object, embed');
    for (var i = 0; i < m.length && s.media < 3; i++) {
      var r = m[i].getBoundingClientRect();
      if (r.width >= 40 && r.height >= 40) s.media++;
    }
    var b = window.__pbilBack;
    s.back = b ? { present: !!b.present, idle: b.idle(), onReport: !!b.onReport } : null;
    for (var j = 0; j < phrases.length; j++) {
      if (phrases[j] && low.indexOf(phrases[j].toLowerCase()) >= 0) s.errors.push(phrases[j]);
    }
    s.screen = { x: window.screenX, y: window.screenY, w: screen.width, h: screen.height, iw: window.innerWidth, ih: window.innerHeight, dpr: window.devicePixelRatio };
    return s;
  };
  window.__pbil2 = P;
})();
'@

# Put into every page Edge loads (Page.addScriptToEvaluateOnNewDocument),
# before the page's own scripts. On any top-level page that is not the
# report it shows a "Back to report" button and returns to the page after
# ReturnAfterSeconds without use; everywhere it keeps links that would open
# a new window in the kiosk window. DOM APIs and CSSOM only - no innerHTML,
# no style attributes - so a site's Content Security Policy or Trusted
# Types cannot stop it.
$BackButtonJs = @'
(function () {
  var O = __PBIL_OPTIONS__;
  try { if (window.top !== window) return; } catch (e) { return; }
  if (window.__pbilBack) return;
  var S = { present: false, onReport: false, lastInput: Date.now(), leaving: false };
  S.idle = function () { return Math.round((Date.now() - S.lastInput) / 1000); };
  window.__pbilBack = S;

  function low(s) { return String(s || '').toLowerCase(); }
  function isReport() {
    var k = O.key;
    if (low(location.hostname) !== k.host) return false;
    if (k.match === 'host') return true;
    var p = low(location.pathname).replace(/\/+$/, '');
    if (k.match === 'exact') return p === k.path && location.search === k.query;
    return !k.path || p === k.path || p.indexOf(k.path + '/') === 0;
  }
  function onLogin() { return O.loginHosts.indexOf(low(location.hostname)) >= 0; }
  // Power BI refusing the account (no license, its error page with 429):
  // the launcher retries with growing waits, so no timer of our own here.
  function refused() {
    if (/nolicense/i.test(location.href)) return true;
    if (!/^\/errorpage\/?$/i.test(location.pathname)) return false;
    var h = low(location.hostname);
    return O.reportHosts.some(function (p) {
      return new RegExp('^' + low(p).replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.') + '$').test(h);
    });
  }
  function goReport() {
    if (S.leaving) return;
    S.leaving = true;
    try { window.stop(); } catch (e) {}
    location.href = O.url;
  }

  // Links that would open a new window open in this one.
  if (O.keepLinks) {
    var isWeb = function (u) { return /^https?:/i.test(u || ''); };
    var sameWindow = function (t) { t = low(t); return !t || t === '_self' || t === '_top' || t === '_parent'; };
    var nativeOpen = window.open;
    try {
      window.open = function (url, target) {
        var abs = '';
        try { abs = url ? new URL(String(url), location.href).href : ''; } catch (e) {}
        // Sign-in popups and windows opened blank (to be filled in by the
        // caller) are left to Edge.
        if (isWeb(abs) && !sameWindow(target || '_blank') && O.loginHosts.indexOf(low(new URL(abs).hostname)) < 0) {
          location.href = abs;
          return null;
        }
        return nativeOpen.apply(window, arguments);
      };
    } catch (e) {}
    document.addEventListener('click', function (ev) {
      if (ev.defaultPrevented || ev.button !== 0 || ev.ctrlKey || ev.shiftKey || ev.metaKey || ev.altKey) return;
      var a = ev.target && ev.target.closest ? ev.target.closest('a[href]') : null;
      if (!a || sameWindow(a.getAttribute('target')) || !isWeb(a.href)) return;
      ev.preventDefault();
      location.href = a.href;
    }, false);
  }

  // Anything a person does counts as use.
  var touch = function () { S.lastInput = Date.now(); };
  ['pointerdown', 'pointermove', 'mousedown', 'mousemove', 'touchstart', 'keydown', 'wheel'].forEach(function (n) {
    window.addEventListener(n, touch, true);
  });
  document.addEventListener('scroll', touch, true);

  var host = null, clock = null;
  function set(el, props) { for (var p in props) el.style.setProperty(p, props[p], 'important'); }
  function build() {
    host = document.createElement('div');
    host.id = 'pbil-back';
    set(host, { all: 'initial' });
    var pos = O.position.split('-');
    var place = { position: 'fixed', 'z-index': '2147483647', display: 'block', margin: '0', padding: '0' };
    place[pos[0]] = '24px';
    place[pos[1]] = '24px';
    set(host, place);
    var root = host.attachShadow ? host.attachShadow({ mode: 'open' }) : host;
    var btn = document.createElement('button');
    btn.type = 'button';
    btn.setAttribute('aria-label', O.text);
    set(btn, {
      all: 'initial', display: 'flex', 'align-items': 'center', gap: '12px', cursor: 'pointer',
      'font-family': 'Segoe UI, Arial, sans-serif', 'font-size': '24px', 'font-weight': '600', 'line-height': '1.2',
      color: '#ffffff', background: 'rgba(24, 24, 24, 0.9)', border: '2px solid #ffffff', 'border-radius': '14px',
      padding: '14px 28px', 'min-height': '64px', 'box-shadow': '0 4px 18px rgba(0, 0, 0, 0.45)', 'user-select': 'none'
    });
    var arrow = document.createElement('span');
    arrow.textContent = '←';
    set(arrow, { all: 'initial', color: 'inherit', font: 'inherit', 'font-size': '30px' });
    var label = document.createElement('span');
    label.textContent = O.text;
    set(label, { all: 'initial', color: 'inherit', font: 'inherit' });
    clock = document.createElement('span');
    set(clock, { all: 'initial', color: 'inherit', font: 'inherit', 'font-weight': '400', opacity: '0.75' });
    btn.appendChild(arrow);
    btn.appendChild(label);
    btn.appendChild(clock);
    btn.addEventListener('click', function (ev) { ev.preventDefault(); ev.stopPropagation(); goReport(); }, true);
    root.appendChild(btn);
  }

  function tick() {
    if (S.leaving) return;
    S.onReport = isReport();
    if (S.onReport || !O.button) {
      // Back on the page within the same page (Power BI moves between
      // its own pages without reloading).
      if (host && host.parentNode) host.parentNode.removeChild(host);
      S.present = false;
      if (S.onReport) return;
    }
    else {
      var parent = document.body || document.documentElement;
      if (parent) {
        if (!host) build();
        if (host.parentNode !== parent) parent.appendChild(host);
        S.present = true;
      }
    }
    // Home on its own after a while without use - but never in the middle
    // of a sign-in, nor from Power BI refusing the account.
    if (O.returnAfter > 0 && !onLogin() && !refused()) {
      var left = O.returnAfter - S.idle();
      if (clock) clock.textContent = left <= 30 ? '(' + Math.max(0, left) + ' s)' : '';
      if (left <= 0) goReport();
    }
    else if (clock) clock.textContent = '';
  }
  document.addEventListener('DOMContentLoaded', tick);
  setInterval(tick, 1000);
  tick();
})();
'@

# Injects the launcher's page script (links, Back button) into every page Edge loads.
function Register-PageScripts {
    # Every new DevTools connection registers the page script again: Edge
    # drops a connection's scripts when it closes.
    param([Parameter(Mandatory)]$Config)

    if (-not $Config.BackButton -and -not $Config.KeepLinksInWindow -and $Config.ReturnAfterSeconds -le 0) { return }
    $options = [ordered]@{
        url         = $Config.EffectiveUrl
        key         = (Get-TargetKey -Url $Config.EffectiveUrl -Match $Config.TargetMatch)
        loginHosts  = @($Config.LoginHosts)
        reportHosts = @($Config.ReportHosts)
        button      = [bool]$Config.BackButton
        text        = $Config.BackButtonText
        position    = $Config.BackButtonPosition
        returnAfter = [int]$Config.ReturnAfterSeconds
        keepLinks   = [bool]$Config.KeepLinksInWindow
    }
    $source = $BackButtonJs.Replace('__PBIL_OPTIONS__', (ConvertTo-Json -InputObject $options -Compress -Depth 5))
    try {
        # Scripts for new documents only run with the Page domain enabled.
        $null = Invoke-Cdp -Config $Config -Method 'Page.enable'
        $null = Invoke-Cdp -Config $Config -Method 'Page.addScriptToEvaluateOnNewDocument' -Params @{ source = $source }
        # And into the page that is already open.
        $r = Invoke-Cdp -Config $Config -Method 'Runtime.evaluate' -Params @{ expression = $source }
        $ex = $r.PSObject.Properties['exceptionDetails']
        if ($ex) {
            $d = $ex.Value
            $text = if ($d.PSObject.Properties['exception'] -and $d.exception.PSObject.Properties['description']) { $d.exception.description } else { $d.text }
            Write-Log "The Back button script failed in the current page: $text" 'WARN'
        }
    }
    catch { Write-Log ("Could not add the Back button to pages: {0}" -f (Get-ErrorText $_)) 'WARN' }
}

# Converts a value to a JavaScript literal (JSON).
function ConvertTo-JsLiteral {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 5)
}

# Runs a helper JavaScript expression in the page and returns the result.
function Invoke-PageJs {
    # Runs P.<something> in the page and returns its value, parsed.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Expression, [int]$TimeoutSec = 15)

    $full = $PageHelperJs + "`n;(function () { var P = window.__pbil2; return JSON.stringify($Expression); })()"
    $r = Invoke-Cdp -Config $Config -Method 'Runtime.evaluate' -Params @{ expression = $full; returnByValue = $true } -TimeoutSec $TimeoutSec
    $ex = $r.PSObject.Properties['exceptionDetails']
    if ($ex) {
        $d = $ex.Value
        $text = if ($d.PSObject.Properties['exception'] -and $d.exception.PSObject.Properties['description']) { $d.exception.description } else { $d.text }
        throw "Page script failed: $text"
    }
    $v = $r.result.PSObject.Properties['value']
    if (-not $v -or $null -eq $v.Value) { return $null }
    return (ConvertFrom-Json -InputObject ([string]$v.Value))
}

# Asks the page whether it loaded or shows one of the configured error phrases.
function Get-PageState {
    param([Parameter(Mandatory)]$Config)
    $options = [ordered]@{ phrases = @($Config.ErrorPhrases) }
    return (Invoke-PageJs -Config $Config -Expression ('P.state({0})' -f (ConvertTo-Json -InputObject $options -Compress -Depth 4)))
}







# ---------------------------------------------------------------------------
# The page
# ---------------------------------------------------------------------------
$script:Session = $null

# Creates the tracking record (timers, counters) for a new Edge session.
function New-Session {
    return [pscustomobject]@{
        PageLoadedUtc          = [DateTime]::UtcNow
        NextIntervalRefreshUtc = [DateTime]::MaxValue
        TimedDone              = @{}
        FullScreenDone         = $false
        FullScreenTries        = 0
        FullScreenLastUtc      = [DateTime]::MinValue
        FullScreenWarned       = $false
        NavHidden              = $false
        NavTries               = 0
        HealthyStreak          = 0
        ErrorStreak            = 0
        Recoveries             = 0
        LastRecoveryUtc        = [DateTime]::MinValue
        StrayPages             = @{}
        WrongAccountTimes      = (New-Object System.Collections.Generic.List[DateTime])
        ShownSinceLoad         = $false
        Browsing               = $false
        BrowsingSinceUtc       = [DateTime]::MinValue
        CdpFailures            = 0
        CdpRefused             = 0
        BrowserHung            = 0
        LaunchFailures         = 0
        NextLaunchUtc          = [DateTime]::MinValue
        Relaunches             = (New-Object System.Collections.Generic.List[DateTime])
        NavigateStreak         = 0
        NextNavigateUtc        = [DateTime]::MinValue
        RefusedStreak          = 0
        NextRefusedUtc         = [DateTime]::MinValue
        LastRefusedUtc         = [DateTime]::MinValue
        OffTargetSinceUtc      = [DateTime]::MinValue
        LoggedScreen           = $false
        CanvasWarned           = $false
        Login                  = [pscustomobject]@{
            LastAction      = ''
            LastActionUtc   = [DateTime]::MinValue
            Repeats         = 0
            PasswordTimes   = (New-Object System.Collections.Generic.List[DateTime])
            BlockedUntilUtc = [DateTime]::MinValue
            BlockedReason   = ''
            RestartFlow     = $false
            SinceUtc        = [DateTime]::MinValue
            CredStamp       = ''
        }
    }
}

# Resets the page timers and error counters after a new page load.
function Reset-PageLoad {
    param([Parameter(Mandatory)]$Config)
    $s = $script:Session
    $now = [DateTime]::UtcNow
    $s.PageLoadedUtc = $now
    $s.ShownSinceLoad = $false
    $s.NavHidden = $false
    $s.NavTries = 0
    $s.FullScreenDone = $false
    $s.FullScreenTries = 0
    $s.HealthyStreak = 0
    $s.ErrorStreak = 0
    $s.NextIntervalRefreshUtc = if ($Config.RefreshMinutes -gt 0) { $now.AddMinutes($Config.RefreshMinutes) } else { [DateTime]::MaxValue }
}

# Tells whether an address is the configured web page.
function Test-IsTargetUrl {
    <#
        Is the page the one to show? TargetMatch decides:
          path  (default) the same host, and a path that starts with the
                configured one - so a site that redirects / to /home, or
                moves between its own pages under it, is still "on it"
          host  any page on the same host
          exact the same host, path and query
    #>
    param([string]$Current, [string]$Target, [string]$Match = 'path')

    $c = $null; $t = $null
    if (-not [Uri]::TryCreate($Current, [UriKind]::Absolute, [ref]$c)) { return $false }
    if (-not [Uri]::TryCreate($Target, [UriKind]::Absolute, [ref]$t)) { return $false }
    if ($c.Host -ne $t.Host) { return $false }
    if ($Match -eq 'host') { return $true }

    $tp = $t.AbsolutePath.TrimEnd('/').ToLowerInvariant()
    $cp = $c.AbsolutePath.TrimEnd('/').ToLowerInvariant()
    if ($Match -eq 'exact') { return ($cp -eq $tp -and $c.Query -eq $t.Query) }
    return (-not $tp -or $cp -eq $tp -or $cp.StartsWith($tp + '/'))
}

# Builds the rule the page script uses to recognise the configured page.
function Get-TargetKey {
    # Test-IsTargetUrl's rule in a form the page script can apply itself.
    param([Parameter(Mandatory)][string]$Url, [string]$Match = 'path')

    $u = [Uri]$Url
    return [ordered]@{
        host  = $u.Host.ToLowerInvariant()
        path  = $u.AbsolutePath.TrimEnd('/').ToLowerInvariant()
        query = $u.Query
        match = $Match
    }
}

# Navigates to the configured web page.
function Open-Target {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)
    Write-Log "Opening the page ($Why)."
    $r = Invoke-Cdp -Config $Config -Method 'Page.navigate' -Params @{ url = $Config.EffectiveUrl } -TimeoutSec 30
    $errText = $r.PSObject.Properties['errorText']
    if ($errText -and $errText.Value) { Write-Log ("Edge could not open the page: {0}" -f $errText.Value) 'WARN' }
    Reset-PageLoad -Config $Config
}

# Reloads the page, bypassing the cache.
function Invoke-Reload {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)
    Write-Log "Reloading the page ($Why)."
    try { $null = Invoke-Cdp -Config $Config -Method 'Page.reload' -Params @{ ignoreCache = $false } -TimeoutSec 30 }
    catch {
        Write-Log ("Reload failed ({0}); opening the page instead." -f (Get-ErrorText $_)) 'WARN'
        Open-Target -Config $Config -Why $Why
    }
    $script:Status.Reloads++
    $script:Status.LastReloadUtc = [DateTime]::UtcNow.ToString('o')
    Reset-PageLoad -Config $Config
}

# Reloads the page or restarts Edge, with growing pauses, when the page is not right.
function Invoke-Recovery {
    <#
        Something is wrong with a page that is on the right report. Reload,
        and escalate to a new Edge every MaxReloadsBeforeRelaunch-th time.
        The pause before each step doubles (0, 1, 3, 7, 15, 30 min), so a
        Power BI outage costs a reload now and then, not a reload loop.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)

    $s = $script:Session
    $n = $s.Recoveries
    $waitMin = [math]::Min(30, [math]::Pow(2, $n) - 1)
    $due = $s.LastRecoveryUtc.AddMinutes($waitMin)
    if ([DateTime]::UtcNow -lt $due) {
        Set-State 'RECOVERING' ("{0}; next attempt at {1:HH:mm}" -f $Why, $due.ToLocalTime())
        return
    }

    $s.Recoveries++
    $s.LastRecoveryUtc = [DateTime]::UtcNow
    $script:Status.LastError = $Why
    Set-State 'RECOVERING' $Why

    if (($s.Recoveries % ($Config.MaxReloadsBeforeRelaunch + 1)) -eq 0) {
        Restart-Browser -Config $Config -Why "$Why (after $($Config.MaxReloadsBeforeRelaunch) reloads)"
        Test-RebootEscalation -Config $Config
    }
    else {
        Invoke-Reload -Config $Config -Why $Why
    }
}













# ---------------------------------------------------------------------------
# Schedules, restarts, control files
# ---------------------------------------------------------------------------
$script:BootTime = [DateTime]::MinValue

# Returns true once a day, within ten minutes after the given time.
function Test-DailyDue {
    # True once per day, within ten minutes after the given time - so a tick
    # that misses the exact minute still fires, unlike the old HH:mm string
    # comparison.
    param([TimeSpan]$At, [string]$Tag, [hashtable]$Done)
    $now = Get-Date
    $due = $now.Date + $At
    if ($now -lt $due -or $now -gt $due.AddMinutes(10)) { return $false }
    $key = '{0}|{1}' -f $Tag, $due.ToString('yyyy-MM-dd HH:mm', $Invariant)
    if ($Done.ContainsKey($key)) { return $false }
    $Done[$key] = $true
    return $true
}

# Restarts the PC on request (restart.txt or the daily scheduled restart).
function Invoke-PcRestart {
    param([Parameter(Mandatory)][string]$Why, [int]$DelaySeconds = 10)

    $script:PersistentState['LastLauncherRestartUtc'] = [DateTime]::UtcNow.ToString('o')
    Save-PersistentState
    $comment = "Web Launcher: $Why [PBI-LAUNCHER]"
    if ($comment.Length -gt 500) { $comment = $comment.Substring(0, 500) }
    Write-Log "Restarting the PC in $DelaySeconds s: $Why" 'WARN'
    Set-State 'RESTARTING_PC' $Why
    Save-Status
    # Continue, not Stop: Windows PowerShell 5.1 turns a native command's
    # stderr into terminating errors under Stop, and the exit code is what
    # matters here.
    $ErrorActionPreference = 'Continue'
    $out = & "$env:SystemRoot\System32\shutdown.exe" /r /t $DelaySeconds /c $comment /d p:4:1 2>&1
    if ($LASTEXITCODE -ne 0) {
        $text = ($out | ForEach-Object { "$_" }) -join ' '
        Write-Log ("shutdown.exe failed ({0}): {1}" -f $LASTEXITCODE, $text) 'ERROR'
    }
}

# Restarts the PC when repeated Edge restarts fail to bring the page back (opt-in).
function Test-RebootEscalation {
    # Opt-in (RebootAfterRelaunches > 0): restart the PC when new Edges keep
    # failing to bring the page back. Never within an hour of boot, and at
    # most once every 12 hours, so it cannot become a reboot loop.
    param([Parameter(Mandatory)]$Config)

    if ($Config.RebootAfterRelaunches -le 0) { return }
    $now = [DateTime]::UtcNow
    $recent = @($script:Session.Relaunches | Where-Object { $_ -gt $now.AddHours(-2) }).Count
    if ($recent -lt $Config.RebootAfterRelaunches) { return }
    if (($now - $script:BootTime.ToUniversalTime()).TotalMinutes -lt 60) { return }
    $last = [DateTime]::MinValue
    if ($script:PersistentState.ContainsKey('LastLauncherRestartUtc')) {
        [void][DateTime]::TryParse([string]$script:PersistentState['LastLauncherRestartUtc'], $Invariant, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$last)
    }
    if ($last -gt $now.AddHours(-12)) { return }
    Invoke-PcRestart -Why ("Edge was restarted {0} times in 2 h without the page coming back" -f $recent) -DelaySeconds 60
}

# Restarts the PC at the configured daily ScheduledRestartTime.
function Test-ScheduledRestart {
    param([Parameter(Mandatory)]$Config)
    if ($null -eq $Config.RestartTime) { return }
    $now = Get-Date
    $due = $now.Date + $Config.RestartTime
    if ($now -lt $due -or $now -gt $due.AddMinutes(10)) { return }
    $key = $due.ToString('yyyy-MM-dd HH:mm', $Invariant)
    if ($script:PersistentState.ContainsKey('LastScheduledRestart') -and [string]$script:PersistentState['LastScheduledRestart'] -eq $key) { return }
    $script:PersistentState['LastScheduledRestart'] = $key
    Save-PersistentState
    # A PC that has only just started (perhaps from this very restart) is
    # left alone.
    if (($now - $script:BootTime).TotalMinutes -lt 30) {
        Write-Log 'Skipping the scheduled restart: the PC started less than 30 min ago.'
        return
    }
    Invoke-PcRestart -Why 'scheduled daily restart' -DelaySeconds $Config.RestartDelaySeconds
}

# Deletes a control file so its action runs only once.
function Remove-ControlFile {
    # Acting on a control file that cannot be deleted would repeat the action
    # on every tick, so it is only acted on once it is gone.
    param([string]$Path)
    try {
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    }
    catch {
        if (-not $script:ControlWarned.ContainsKey($Path)) {
            Write-Log ("Found {0} but cannot delete it ({1}), so it is ignored." -f (Split-Path -Leaf $Path), $_.Exception.Message) 'ERROR'
            $script:ControlWarned[$Path] = $true
        }
        return $false
    }
}
$script:ControlWarned = @{}

# Saves a screenshot and status snapshot when snapshot.txt asks for one.
function Save-Snapshot {
    <#
        snapshot.txt: what the screen shows, for someone who is not in front
        of it. Status\<screen>.png (a screenshot of the page) and
        Status\<screen>.snapshot.json (address, title, state).
    #>
    param([Parameter(Mandatory)]$Config)

    $base = Join-Path $script:StatusDir $script:InstanceName
    $info = [ordered]@{
        TakenUtc = [DateTime]::UtcNow.ToString('o')
        State    = $script:Status.State
        Detail   = $script:Status.Detail
        Url      = ''
        Title    = ''
        Image    = ''
        Error    = ''
    }
    try {
        if (-not $script:Supervised) { throw 'not available unsupervised (no DevTools connection)' }
        if (-not $script:Browser) { throw 'Edge is not running' }
        $st = Get-PageState -Config $Config
        if ($st) { $info.Url = [string]$st.url; $info.Title = [string]$st.title }
        $shot = Invoke-Cdp -Config $Config -Method 'Page.captureScreenshot' -Params @{ format = 'png' } -TimeoutSec 30
        $png = "$base.png"
        [IO.File]::WriteAllBytes("$png.tmp", [Convert]::FromBase64String([string]$shot.data))
        Move-Item -LiteralPath "$png.tmp" -Destination $png -Force
        $info.Image = Split-Path -Leaf $png
        Write-Log "snapshot.txt: saved a screenshot of $($info.Url)."
    }
    catch {
        $info.Error = Get-ErrorText $_
        Write-Log "snapshot.txt: no screenshot - $($info.Error)" 'WARN'
    }
    try { Write-JsonFile -Path "$base.snapshot.json" -Object $info } catch {}
}

# Acts on control files dropped in the folder (stop, hold, restart, refresh, snapshot).
function Invoke-ControlFiles {
    # Returns 'exit', 'hold', 'restarting' or ''.
    param([Parameter(Mandatory)]$Config)

    $snapshot = Join-Path $Here 'snapshot.txt'
    if ((Test-Path -LiteralPath $snapshot) -and (Remove-ControlFile $snapshot)) {
        Save-Snapshot -Config $Config
    }

    $kill = Join-Path $Here 'kill.txt'
    if (Test-Path -LiteralPath $kill) {
        if (-not (Remove-ControlFile $kill)) {
            Write-Log 'kill.txt stays in place, so the launcher will also stop at its next start until the file is deleted.' 'WARN'
        }
        Write-Log 'kill.txt: stopping.' 'WARN'
        Stop-Browser -Config $Config -Why 'kill.txt'
        return 'exit'
    }

    $restart = Join-Path $Here 'restart.txt'
    if ((Test-Path -LiteralPath $restart) -and (Remove-ControlFile $restart)) {
        Stop-Browser -Config $Config -Why 'restart.txt'
        Invoke-PcRestart -Why 'remote restart request (restart.txt)' -DelaySeconds 10
        return 'restarting'
    }

    $relaunch = Join-Path $Here 'relaunch.txt'
    if ((Test-Path -LiteralPath $relaunch) -and (Remove-ControlFile $relaunch)) {
        Restart-Browser -Config $Config -Why 'relaunch.txt'
    }

    $refresh = Join-Path $Here 'refresh.txt'
    if ((Test-Path -LiteralPath $refresh) -and (Remove-ControlFile $refresh)) {
        if ($script:Browser -and $script:Supervised) {
            try { Invoke-Reload -Config $Config -Why 'refresh.txt' }
            catch { Write-Log ("refresh.txt: {0}" -f (Get-ErrorText $_)) 'WARN' }
        }
        elseif ($script:Browser) { Restart-Browser -Config $Config -Why 'refresh.txt' }
    }

    if (Test-Path -LiteralPath (Join-Path $Here 'hold.txt')) { return 'hold' }
    return ''
}

# ---------------------------------------------------------------------------
# One tick
# ---------------------------------------------------------------------------
# One check of the page through DevTools (sign-in, recovery, refreshes); returns seconds to sleep.
function Invoke-SupervisedTick {
    # Returns the number of seconds to sleep before the next tick.
    param([Parameter(Mandatory)]$Config)

    $s = $script:Session
    $now = [DateTime]::UtcNow

    # --- the browser -------------------------------------------------------
    $health = Get-BrowserHealth -Config $Config
    if ($health -eq 'hung') {
        $s.BrowserHung++
        Write-Log ("Edge is running but not answering (check {0})." -f $s.BrowserHung) 'WARN'
        if ($s.BrowserHung -ge 3) { Restart-Browser -Config $Config -Why 'Edge stopped answering' }
        return 5
    }
    if ($health -eq 'gone') {
        if ($script:Browser) {
            Write-Log 'Edge has closed.' 'WARN'
            $script:Browser = $null
            Disconnect-Cdp
            $s.Relaunches.Add($now)
        }
        if ($now -lt $s.NextLaunchUtc) { return 2 }
        Set-State 'LAUNCHING'
        try {
            Start-Browser -Config $Config -Reason $(if ($script:Status.BrowserStarts -eq 0) { 'startup' } else { 'Edge had closed' })
            $s.LaunchFailures = 0
        }
        catch { Register-LaunchFailure -ErrorRecord $_ }
        return 2
    }
    $s.BrowserHung = 0

    # --- the page -----------------------------------------------------------
    $st = $null
    try { $st = Get-PageState -Config $Config }
    catch {
        $text = Get-ErrorText $_
        if ($text -match 'refused|Page script failed') {
            # Usually mid-navigation: the page's script context is being
            # replaced. Only a page that keeps refusing is a problem.
            $s.CdpRefused++
            if ($s.CdpRefused -lt 10) { return 2 }
            $s.CdpRefused = 0
            Write-Log "The page keeps refusing to be read: $text" 'WARN'
            Open-Target -Config $Config -Why 'the page could not be read'
            return 3
        }
        $s.CdpFailures++
        Write-Log ("Cannot read the page (check {0}): {1}" -f $s.CdpFailures, $text) 'WARN'
        if ($s.CdpFailures -ge 3) {
            $s.CdpFailures = 0
            Restart-Browser -Config $Config -Why 'the page stopped responding'
        }
        return 3
    }
    $s.CdpFailures = 0
    $s.CdpRefused = 0
    if (-not $st) { return 2 }
    try {
        if (@(Invoke-StrayPages -Config $Config -MainOnSignIn $false)[-1]) { return 2 }
    }
    catch { Write-Log ("Checking for extra windows failed: {0}" -f (Get-ErrorText $_)) 'DEBUG' }

    $script:Status.CurrentUrl = [string]$st.url
    $script:Status.Title = [string]$st.title
    if (-not $s.LoggedScreen -and $st.screen) {
        $s.LoggedScreen = $true
        Write-Log ("Page window: {0},{1}, screen {2}x{3}, viewport {4}x{5}, pixel ratio {6}." -f $st.screen.x, $st.screen.y, $st.screen.w, $st.screen.h, $st.screen.iw, $st.screen.ih, $st.screen.dpr)
    }
    Write-Log ("Page: {0} ready={1} text={2} errors={3}" -f $st.url, $st.ready, $st.textLen, (@($st.errors) -join ';')) 'DEBUG'

    $url = [string]$st.url
    $pageHost = [string]$st.host

    # --- an Edge error page, or nothing ------------------------------------
    if ($url -match '^(chrome|edge)-error:' -or $url -eq 'about:blank' -or $url -eq '' -or $url -match '^(chrome|edge)://') {
        if ($now -lt $s.NextNavigateUtc) { return 3 }
        $s.NavigateStreak++
        # 0 s, 30 s, 1, 2, 4 min, then every 5 min.
        $waits = @(0, 30, 60, 120, 240, 300)
        $s.NextNavigateUtc = $now.AddSeconds($waits[[math]::Min($s.NavigateStreak, $waits.Count - 1)])
        $why = if ($url -match 'error') { 'Edge showed an error page - network or site down?' } else { "the page was $url" }
        Set-State 'RECOVERING' $why
        Open-Target -Config $Config -Why $why
        return 3
    }

    # --- somewhere other than the page ------------------------------------
    $onTarget = Test-IsTargetUrl -Current $url -Target $Config.EffectiveUrl -Match $Config.TargetMatch
    if (-not $onTarget) {
        if ($s.ShownSinceLoad -or $s.Browsing) {
            # The page was up, so this is someone who followed a link out of
            # it. Leave them be: the page has a Back button and goes home by
            # itself after ReturnAfterSeconds without use. The launcher only
            # steps in if that did not happen.
            Start-Browsing -Url $url
            $idle = $null
            if ($st.back -and $null -ne $st.back.idle) { $idle = [double]$st.back.idle }
            if ($Config.ReturnAfterSeconds -gt 0) {
                if ($null -ne $idle) { $unused = $idle; $limit = $Config.ReturnAfterSeconds + 15 }
                else { $unused = ($now - $s.BrowsingSinceUtc).TotalSeconds; $limit = $Config.ReturnAfterSeconds }
                if ($unused -ge $limit) {
                    Open-Target -Config $Config -Why ("{0} has not been used for {1:0} s" -f $pageHost, $unused)
                    return 3
                }
            }
            $detail = "someone opened $pageHost from the page"
            if ($Config.ReturnAfterSeconds -gt 0) { $detail += "; back to it after $($Config.ReturnAfterSeconds) s unused" }
            Set-State 'BROWSING' $detail
            return [math]::Min(5, $Config.HealthCheckSeconds)
        }
        # A site may take a few redirects to get there; only step in if it
        # does not.
        if ($s.OffTargetSinceUtc -eq [DateTime]::MinValue) { $s.OffTargetSinceUtc = $now; return 3 }
        if ($now -lt $s.OffTargetSinceUtc.AddSeconds($Config.OffTargetSeconds)) { return 3 }
        $s.OffTargetSinceUtc = [DateTime]::MinValue
        Set-State 'LOADING' "the page was on $url, not the configured address"
        Open-Target -Config $Config -Why "the page was on $url"
        return 3
    }
    $s.OffTargetSinceUtc = [DateTime]::MinValue
    $s.NavigateStreak = 0
    $s.NextNavigateUtc = [DateTime]::MinValue

    # --- on the page --------------------------------------------------------
    if ($s.Browsing) {
        Write-Log ("Back on the page after {0:0} s away." -f ($now - $s.BrowsingSinceUtc).TotalSeconds)
        $s.Browsing = $false
        Reset-PageLoad -Config $Config
    }
    $errors = @($st.errors)
    $sinceLoad = ($now - $s.PageLoadedUtc).TotalSeconds

    if ($errors.Count -gt 0) {
        $s.HealthyStreak = 0
        $s.ErrorStreak++
        if ($s.ErrorStreak -eq 1) { Write-Log ("The page shows: {0}" -f ($errors -join '; ')) 'WARN' }
        if ($s.ErrorStreak -ge $Config.ErrorChecksBeforeReload) {
            Invoke-Recovery -Config $Config -Why ("the page shows '{0}'" -f ($errors -join "', '"))
        }
        return [math]::Min(5, $Config.HealthCheckSeconds)
    }
    $s.ErrorStreak = 0

    # Loaded, and not an empty page.
    $drawn = $st.ready -eq 'complete' -and ([int]$st.textLen -gt 0 -or [int]$st.media -gt 0)
    if (-not $drawn) {
        $s.HealthyStreak = 0
        if ($Config.BlankReloadSeconds -gt 0 -and $sinceLoad -gt $Config.BlankReloadSeconds) {
            Invoke-Recovery -Config $Config -Why ("the page has shown nothing for {0:0} s" -f $sinceLoad)
        }
        elseif ($script:Status.State -ne 'RECOVERING') {
            Set-State 'LOADING' 'waiting for the page to load'
        }
        return 3
    }

    $s.HealthyStreak++
    if ($s.HealthyStreak -ge 2 -and $s.Recoveries -gt 0) {
        Write-Log ("The page is back after {0} recovery step(s)." -f $s.Recoveries)
        $s.Recoveries = 0
        $s.LastRecoveryUtc = [DateTime]::MinValue
    }
    Set-State 'SHOWING' ''
    $s.ShownSinceLoad = $true
    $script:Status.LastShownUtc = [DateTime]::UtcNow.ToString('o')

    # --- refresh ------------------------------------------------------------
    if ($now -ge $s.NextIntervalRefreshUtc) {
        Invoke-Reload -Config $Config -Why ("every {0} min" -f $Config.RefreshMinutes)
        return 3
    }
    foreach ($t in $Config.RefreshTimes) {
        if (Test-DailyDue -At $t -Tag 'refresh' -Done $s.TimedDone) {
            Invoke-Reload -Config $Config -Why ('daily refresh at {0:hh\:mm}' -f $t)
            return 3
        }
    }
    return $Config.HealthCheckSeconds
}

# One check when DevTools is blocked: keeps Edge running and restarts it for refreshes.
function Invoke-UnsupervisedTick {
    # Edge's DevTools port is blocked by policy: keep Edge running and do the
    # daily refreshes by restarting it. Sign-in has to be done by hand once.
    param([Parameter(Mandatory)]$Config)

    $s = $script:Session
    $now = [DateTime]::UtcNow
    if ((Get-BrowserHealth -Config $Config) -eq 'gone') {
        if ($script:Browser) { Write-Log 'Edge has closed.' 'WARN'; $script:Browser = $null }
        if ($now -lt $s.NextLaunchUtc) { return 5 }
        try {
            Start-Browser -Config $Config -Reason $(if ($script:Status.BrowserStarts -eq 0) { 'startup' } else { 'Edge had closed' })
            $s.LaunchFailures = 0
        }
        catch { Register-LaunchFailure -ErrorRecord $_ }
        return 5
    }
    Set-State 'UNSUPERVISED' $script:UnsupervisedWhy
    foreach ($t in $Config.RefreshTimes) {
        if (Test-DailyDue -At $t -Tag 'refresh' -Done $s.TimedDone) { Restart-Browser -Config $Config -Why ('daily refresh at {0:hh\:mm}' -f $t) }
    }
    return [math]::Max(10, $Config.HealthCheckSeconds)
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
# Main entry point: reads the config, starts Edge and runs the check loop.
function Invoke-Main {
    $script:EchoLog = [bool]$ShowConsole
    Initialize-Native
    $consoleState = 'left visible (-ShowConsole)'
    if (-not $ShowConsole) { $consoleState = Hide-ConsoleWindow }

    # --- config -------------------------------------------------------------
    $configFile = $null
    $config = $null
    try {
        $configFile = Resolve-ConfigPath -Explicit $ConfigPath
        $config = Read-LauncherConfig -Path $configFile
    }
    catch {

        # Nowhere configured to log to yet: use the default local log.
        $script:InstanceName = $ComputerName
        Initialize-Log -Config ([pscustomobject]@{ LogDir = (Join-Path $Here 'Logs'); LogName = "WebLauncher_$ComputerName.log"; RemoteLogDir = '' })
        Write-Log ("Web Launcher {0} cannot start: {1}" -f $LauncherVersion, $_.Exception.Message) 'ERROR'
        return 1
    }


    $script:InstanceName = $config.Instance
    $script:DebugLogging = $config.DebugLogging
    Initialize-Log -Config $config
    Initialize-Status -Config $config
    Read-PersistentState
    $script:Session = New-Session

    Write-Log '##### Web Launcher start #####'
    Write-Log ("Web Launcher {0} on {1} as {2}\{3}, PowerShell {4}, PID {5}." -f $LauncherVersion, $ComputerName, $env:USERDOMAIN, $env:USERNAME, $PSVersionTable.PSVersion, $PID)
    Write-Log ("Config {0} (version {1}); page {2} (TargetMatch {3})" -f $configFile, $(if ($config.JsonVersion) { $config.JsonVersion } else { '-' }), $config.DisplayUrl, $config.TargetMatch)
    foreach ($p in $config.Problems) { Write-Log $p 'WARN' }

    if (-not $script:NativeReady) { Write-Log 'Could not load the native helpers (csc.exe blocked?). The console may stay visible and screens are read through WinForms.' 'WARN' }
    Write-Log ("Console window: {0}." -f $consoleState) $(if ($consoleState -like 'still visible*') { 'WARN' } else { 'INFO' })

    try {
        $script:BootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        $script:Status.PcBootUtc = $script:BootTime.ToUniversalTime().ToString('o')
        Write-Log ("PC started {0:yyyy-MM-dd HH:mm:ss} ({1:0.0} h ago)." -f $script:BootTime, ((Get-Date) - $script:BootTime).TotalHours)
    }
    catch { $script:BootTime = Get-Date }

    foreach ($m in @(Get-Monitors)) {
        Write-Log ("Screen {0}: {1}x{2} at {3},{4}{5}" -f $m.Device.TrimStart('\', '.'), $m.Width, $m.Height, $m.X, $m.Y, $(if ($m.Primary) { ' (primary)' } else { '' }))
    }

    # --- one launcher per config ------------------------------------------------
    $mutex = New-Object Threading.Mutex($false, ('Local\WebLauncher-' + $config.Instance))
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        Write-Log "Another Web Launcher is already running for $($config.Instance) in this session; exiting." 'WARN'
        return 0
    }

    try {
        if ($config.Disabled) {
            Write-Log 'DisableStartup is set in the config; exiting.' 'WARN'
            Set-State 'DISABLED'
            Save-Status
            return 0
        }

        $script:EdgePath = Find-EdgePath -Configured $config.EdgePath
        Write-Log ("Edge: {0} ({1})" -f $script:EdgePath, (Get-Item -LiteralPath $script:EdgePath).VersionInfo.ProductVersion)

        $blockedBy = Get-RemoteDebuggingPolicy
        if ($blockedBy) {
            $script:Supervised = $false
            $script:UnsupervisedWhy = 'Edge policy RemoteDebuggingAllowed = 0: the launcher can only keep Edge open'
            Write-Log "Edge policy RemoteDebuggingAllowed = 0 ($blockedBy). The launcher can only start Edge and keep it open: no health checks or interval refresh. Allow remote debugging for this PC to get them back." 'ERROR'
        }
        elseif (-not $config.Supervised) {
            $script:Supervised = $false
            $script:UnsupervisedWhy = 'Supervised = 0 in the config: the launcher only keeps Edge open'
            Write-Log 'Supervised = 0: the launcher only starts Edge and keeps it open (no health checks or interval refresh). Changing this takes a launcher restart.' 'WARN'
        }
        $script:Status.Supervised = $script:Supervised

        if ($config.StartupDelaySeconds -gt 0) {
            Write-Log "Waiting $($config.StartupDelaySeconds) s (StartupDelay)."
            Start-Sleep -Seconds $config.StartupDelaySeconds
        }

        # Wait for the screen once, at startup: a TV is often slower to wake
        # than the PC.
        $null = Get-TargetScreen -Config $config -WaitSeconds $config.DisplayWaitSeconds

        $configStamp = (Get-Item -LiteralPath $configFile).LastWriteTimeUtc
        $startedAt = Get-Date
        $tickErrors = 0

        while ($true) {
            if ($ExitAfterSeconds -gt 0 -and ((Get-Date) - $startedAt).TotalSeconds -ge $ExitAfterSeconds) {
                Write-Log "ExitAfterSeconds reached; stopping."
                Stop-Browser -Config $config
                break
            }

            $sleep = 5
            try {
                # A changed config applies without a restart.
                $stamp = (Get-Item -LiteralPath $configFile).LastWriteTimeUtc
                if ($stamp -ne $configStamp) {
                    $configStamp = $stamp
                    try {
                        $new = Read-LauncherConfig -Path $configFile
                        Write-Log 'The config file changed; reloaded it.'
                        foreach ($p in $new.Problems) { Write-Log $p 'WARN' }
                        $relaunch = $new.BrowserSignature -ne $config.BrowserSignature
                        $script:DebugLogging = $new.DebugLogging
                        if ($new.LogDir -ne $config.LogDir -or $new.LogName -ne $config.LogName -or $new.RemoteLogDir -ne $config.RemoteLogDir) { Initialize-Log -Config $new }
                        $new.Instance = $config.Instance
                        $config = $new
                        $script:Status.DisplayUrl = $config.DisplayUrl

                        if ($config.Disabled) {
                            Write-Log 'DisableStartup is now set; stopping.' 'WARN'
                            Stop-Browser -Config $config -Why 'DisableStartup'
                            Set-State 'DISABLED'
                            break
                        }
                        if ($relaunch -and $script:Browser) { Restart-Browser -Config $config -Why 'browser settings changed in the config' }
                        elseif ($script:Browser) {
                            # Reconnecting registers the page script with the new settings.
                            Disconnect-Cdp
                            Reset-PageLoad -Config $config
                        }
                    }
                    catch { Write-Log ("The config file changed but cannot be used, keeping the previous settings: {0}" -f $_.Exception.Message) 'ERROR' }
                }

                $control = @(Invoke-ControlFiles -Config $config)[-1]
                if ($control -eq 'exit') { Set-State 'STOPPED' 'kill.txt'; break }
                if ($control -eq 'restarting') { $sleep = 30 }
                elseif ($control -eq 'hold') {
                    Set-State 'HOLD' 'hold.txt is present: not touching the browser'
                    $sleep = 5
                }
                else {
                    Test-ScheduledRestart -Config $config
                    # The last value is the pause; anything a helper let slip
                    # into the output before it is ignored.
                    if ($script:Supervised) { $sleep = @(Invoke-SupervisedTick -Config $config)[-1] }
                    else { $sleep = @(Invoke-UnsupervisedTick -Config $config)[-1] }
                    if ($script:Status.State -eq 'RESTARTING_PC') { $sleep = 30 }
                }
                $tickErrors = 0
            }
            catch {
                $tickErrors++
                $text = Get-ErrorText $_
                $script:Status.LastError = $text
                Write-Log ("Unexpected error (#{0}): {1}" -f $tickErrors, $text) 'ERROR'
                $sleep = [math]::Min(60, 5 * $tickErrors)
                if (($tickErrors % 5) -eq 0) {
                    try { Restart-Browser -Config $config -Why 'repeated unexpected errors' } catch {}
                }
            }

            Save-Status
            $pause = 2.0
            if (-not [double]::TryParse([string]$sleep, [Globalization.NumberStyles]::Float, $Invariant, [ref]$pause) -or $pause -lt 1) { $pause = 2.0 }
            Wait-NextTick -Config $config -Seconds $pause
        }
    }
    finally {
        Disconnect-Cdp
        if ($script:Status.State -notin @('STOPPED', 'DISABLED', 'RESTARTING_PC')) { Set-State 'STOPPED' }
        Save-Status
        Write-Log '##### Web Launcher end #####'
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
    return 0
}

$code = 1
try {
    $code = [int](@(Invoke-Main)[-1])
}
catch {
    try { Write-Log ("Fatal: {0}" -f (Get-ErrorText $_)) 'ERROR' } catch {}
    if ($ShowConsole -or $SetPassword) { Write-Host $_ -ForegroundColor Red }
}
exit $code
