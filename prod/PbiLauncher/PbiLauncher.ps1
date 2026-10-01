#Requires -Version 5.1
<#
.SYNOPSIS
    PBI Launcher 2.0: shows a Power BI report full screen on a kiosk and keeps
    it on screen.

.DESCRIPTION
    Replaces PowerBILauncher.exe (1.0.0.11) and the StartupLauncher.exe that
    started it.

    For as long as the kiosk account is signed in, it:

      - starts Microsoft Edge full screen on the configured display,
        InPrivate, so Windows single sign-on cannot sign Power BI in with
        the kiosk's own account
      - signs in to Microsoft as the configured account, with a password
        kept DPAPI-encrypted on the kiosk, and signs out any other account
        Power BI turns up with
      - opens the report and switches Power BI to full screen
      - reloads the report on an interval and at fixed times of day
      - watches the page and puts things right without anyone at the kiosk:
        a sign-in prompt, a Power BI error, a report that never draws, a
        hung or crashed page, a closed browser
      - lets people follow links in the report: the linked page opens in
        the kiosk window (never in a new one), with a "Back to report"
        button, and the report comes back by itself after
        ReturnAfterSeconds (120) without use
      - writes a CMTrace log (locally and to the central share) and a status
        file that can be read over the admin share

    Edge is driven over its DevTools protocol on a port that only this PC
    can reach. There is no msedgedriver.exe and no WebDriver.dll, so an Edge
    update can no longer stop the launcher.

  Folders

    PbiLauncher.ps1 sits in C:\Users\Public\Documents\PbiLauncher. Each
    screen has a folder of its own next to it (S1, S2, ...), holding its
    config (<COMPUTERNAME>.json), password, control files, Status\ and
    Logs\. -Instance names the folder; S1 is the default. A screen number
    belongs to one launcher: PBI on S1 and Mach2 Launcher NG on S2 is fine,
    both on S1 is not.

    Before 2.0.1 everything sat next to the script. A kiosk the deploy has
    not moved yet (a config there, none in S1) keeps working from there.

  Configuration

    <COMPUTERNAME>.json in the screen's folder. A 1.0.0.3 file from the old
    launcher works as it is; see EXAMPLE.json for every setting. The file is
    re-read when it changes, so an edit takes effect without a restart.

  Sign-in password

    Never stored in plain text by this launcher. Two ways to give it one:

      - drop password.seed (the password on one line) into the screen's
        folder. The launcher encrypts it for the kiosk account into
        <COMPUTERNAME>.cred and deletes the seed.
      - run  PbiLauncher.ps1 -Instance S1 -SetPassword  as the kiosk account.

    A plain "Password" in an old config still works, with a warning in the
    log, and is copied into the encrypted file on first use.

    If Microsoft rejects the password, the launcher stops trying for
    LoginRetryMinutes so that it cannot lock the account out. A new
    password.seed clears that at once.

  Control files (create them in the screen's folder)

    kill.txt      stop the launcher and close Edge
    relaunch.txt  restart Edge
    refresh.txt   reload the report
    restart.txt   restart the PC in 10 seconds
    snapshot.txt  save a screenshot and a page summary in Status\
    hold.txt      pause: the launcher watches but does nothing, so someone
                  can use the browser (for example to sign in with MFA).
                  Delete it to resume.

    Each file except hold.txt is deleted when it is acted on.

.PARAMETER Instance
    The screen's folder next to this script. Default S1.

.PARAMETER ConfigPath
    Config file. Default: <COMPUTERNAME>.json, then config.json, in the
    screen's folder.

.PARAMETER SetPassword
    Ask for the Power BI password, save it encrypted for the current Windows
    account, and exit. Run it as the kiosk account.

.PARAMETER ShowConsole
    Keep the console window on screen and echo the log to it.

.PARAMETER Headless
    Run Edge without a window. For testing only.

.PARAMETER ExitAfterSeconds
    Stop after this long. For testing only.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\Public\Documents\PbiLauncher\PbiLauncher.ps1 -Instance S1

.EXAMPLE
    .\PbiLauncher.ps1 -Instance S1 -SetPassword

.EXAMPLE
    .\PbiLauncher.ps1 -Instance S2 -ShowConsole
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]*$')][string]$Instance,
    [string]$ConfigPath,
    [switch]$SetPassword,
    [switch]$ShowConsole,
    [switch]$Headless,
    [ValidateRange(0, 604800)][int]$ExitAfterSeconds = 0
)

# Strict mode is deliberate. The old launcher's worst bug was a misspelt
# variable ($DisplayUR) that silently read as empty and relaunched it in a
# loop; strict mode turns that kind of mistake into an error on first use.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$LauncherVersion = '2.0.1'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ComputerName = $env:COMPUTERNAME.ToUpperInvariant()

# The screen's folder. Left out, it is S1 - unless S1 has no config and the
# script's own folder does: a kiosk from before the screen folders, which
# the deploy has not moved yet, keeps working where it is.
$script:LegacyLayout = $false
if (-not $Instance) {
    $Instance = 'S1'
    $inS1 = @(@("$ComputerName.json", 'config.json') | Where-Object { Test-Path -LiteralPath (Join-Path (Join-Path $ScriptDir 'S1') $_) }).Count -gt 0
    $atRoot = @(@("$ComputerName.json", 'config.json') | Where-Object { Test-Path -LiteralPath (Join-Path $ScriptDir $_) }).Count -gt 0
    if ($ConfigPath -or (-not $inS1 -and $atRoot)) { $script:LegacyLayout = $true }
}
$Here = if ($script:LegacyLayout) { $ScriptDir } else { Join-Path $ScriptDir $Instance }
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
    if ('PbiLauncherNative.Api' -as [type]) { $script:NativeReady = $true; return }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace PbiLauncherNative {
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
    # The console must never sit on top of the report. The shortcut starts
    # PowerShell hidden already; this covers any other way of starting it.
    # Returns what it found, for the log.
    if (-not $script:NativeReady) { return 'unknown (no native helpers)' }
    try {
        $h = [PbiLauncherNative.Api]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return 'none' }
        if (-not [PbiLauncherNative.Api]::IsWindowVisible($h)) { return 'hidden' }
        [void][PbiLauncherNative.Api]::ShowWindow($h, 0)
        if ([PbiLauncherNative.Api]::IsWindowVisible($h)) {
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
    $line = '<![LOG[{0}]LOG]!><time="{1}+000" date="{2}" component="PbiLauncher" context="{3}" type="{4}" thread="{5}" file="PbiLauncher.ps1">' -f `
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
    'Something went wrong',
    "Couldn't load",
    "Can't display this visual",
    "Couldn't retrieve the data",
    "This content isn't available",
    'Content not available',
    'Your session has timed out',
    'session has expired',
    "We couldn't connect",
    "The report couldn't be loaded",
    "Hmm, we can't reach this page",
    "This page isn't working"
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

# Adds Power BI's chromeless switch to the address when FullScreen = "chromeless".
function Get-EffectiveUrl {
    # FullScreen = "chromeless" asks Power BI for a page without its header
    # and navigation through the URL instead of the View menu. Undocumented
    # by Microsoft, so "click" stays the default.
    param([string]$Url, [string]$Mode)
    if ($Mode -ne 'chromeless' -or $Url -match '[?&]chromeless=') { return $Url }
    $fragment = ''
    $i = $Url.IndexOf('#')
    if ($i -ge 0) { $fragment = $Url.Substring($i); $Url = $Url.Substring(0, $i) }
    $sep = if ($Url.Contains('?')) { '&' } else { '?' }
    return "$Url${sep}chromeless=1$fragment"
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
        Reads the config into one object with typed, validated values. Keys
        from the old launcher (1.0.0.3) are accepted as they are; the newer
        keys are optional. Anything the old launcher needed only for Selenium
        (driver share, field IDs, zoom delay, log delay) is ignored.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $problems = New-Object System.Collections.Generic.List[string]
    $parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
    # The old format wraps the settings in a one-element array.
    $raw = @($parsed)[0]
    if ($null -eq $raw) { throw "Config file is empty: $Path" }

    $url = [string](Get-ConfigValue $raw @('DisplayURL'))
    if (-not $url) { throw "DisplayURL is missing in $Path" }
    $uri = $null
    if (-not [Uri]::TryCreate($url.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('https', 'http')) {
        throw "DisplayURL is not a web address: $url"
    }
    $url = $uri.AbsoluteUri

    # In a screen folder the screen is the instance: the status file, the
    # fleet tools and the other launchers on the kiosk all go by it. Only
    # the old layout names it from the config or the file.
    if ($script:LegacyLayout) {
        $instance = [string](Get-ConfigValue $raw @('Instance') ([IO.Path]::GetFileNameWithoutExtension($Path)))
        $instance = ($instance -replace '[^A-Za-z0-9_.-]', '_')
    }
    else { $instance = $script:Instance }

    $browserMode = ([string](Get-ConfigValue $raw @('BrowserMode') 'app')).ToLowerInvariant()
    if ($browserMode -notin @('app', 'kiosk')) { $problems.Add("BrowserMode '$browserMode' is not app or kiosk; using app."); $browserMode = 'app' }

    $fullScreen = ([string](Get-ConfigValue $raw @('FullScreen') 'click')).ToLowerInvariant()
    if ($fullScreen -notin @('click', 'chromeless', 'none')) { $problems.Add("FullScreen '$fullScreen' is not click, chromeless or none; using click."); $fullScreen = 'click' }

    # Refresh: RefreshMinutes wins; otherwise the old EnableRefresh +
    # BrowserRefreshDelay pair.
    $refreshMinutes = Get-ConfigValue $raw @('RefreshMinutes')
    if ($null -ne $refreshMinutes) {
        $refreshMinutes = ConvertTo-Number $refreshMinutes 0 0 10080
    }
    elseif (ConvertTo-Flag (Get-ConfigValue $raw @('EnableRefresh')) $false) {
        $refreshMinutes = ConvertTo-Number (Get-ConfigValue $raw @('BrowserRefreshDelay')) 15 1 10080
    }
    else { $refreshMinutes = 0 }

    $refreshTimes = @(ConvertTo-TimesOfDay -Values (ConvertTo-StringList (Get-ConfigValue $raw @('RefreshTimes', 'ForcedRefreshTime'))) -What 'refresh' -Problems $problems)

    $restartTime = $null
    if (ConvertTo-Flag (Get-ConfigValue $raw @('ScheduledRestartEnabled')) $false) {
        $t = @(ConvertTo-TimesOfDay -Values (ConvertTo-StringList (Get-ConfigValue $raw @('ScheduledRestartTime'))) -What 'restart' -Problems $problems)
        if ($t.Count -gt 0) { $restartTime = $t[0] }
    }

    $zoom = [int](ConvertTo-Number (Get-ConfigValue $raw @('ZoomPercent')) 100 25 500)

    # Screens after the first get their own name: the central log folder
    # holds every kiosk's.
    $defaultLog = if ($script:LegacyLayout -or $instance -ieq 'S1') { "PbiLauncher_$ComputerName.log" } else { "PbiLauncher_${ComputerName}_$instance.log" }
    $logName = [string](Get-ConfigValue $raw @('LogName') $defaultLog)
    $logName = [IO.Path]::GetFileName($logName)

    $userName = [string](Get-ConfigValue $raw @('UserName') '')
    $credFile = [string](Get-ConfigValue $raw @('CredentialFile') "$ComputerName.cred")
    if (-not [IO.Path]::IsPathRooted($credFile)) { $credFile = Join-Path $Here $credFile }

    $profileDir = [string](Get-ConfigValue $raw @('ProfileDir') (Join-Path $env:LOCALAPPDATA "PbiLauncher\Profile-$instance"))
    $profileDir = [Environment]::ExpandEnvironmentVariables($profileDir).TrimEnd('\')

    $logDir = [string](Get-ConfigValue $raw @('LogPath') (Join-Path $Here 'Logs'))
    $logDir = [Environment]::ExpandEnvironmentVariables($logDir)

    $cfg = [pscustomobject]@{
        Path                     = $Path
        Instance                 = $instance
        DisplayUrl               = $url
        UserName                 = $userName.Trim()
        LegacyPassword           = [string](Get-ConfigValue $raw @('Password') '')
        CredentialFile           = $credFile
        StaySignedIn             = ConvertTo-Flag (Get-ConfigValue $raw @('StaySignedIn')) $true
        LoginHosts               = @(ConvertTo-StringList (Get-ConfigValue $raw @('LoginHosts') 'login.microsoftonline.com') | ForEach-Object { $_.ToLowerInvariant() })
        ReportHosts              = @(ConvertTo-StringList (Get-ConfigValue $raw @('ReportHosts') '*.powerbi.com'))
        AllowHttpLogin           = ConvertTo-Flag (Get-ConfigValue $raw @('TestAllowHttpLogin')) $false
        LoginRetryMinutes        = ConvertTo-Number (Get-ConfigValue $raw @('LoginRetryMinutes')) 60 1 1440
        BrowserMode              = $browserMode
        InPrivate                = ConvertTo-Flag (Get-ConfigValue $raw @('InPrivate')) $true
        FullScreenWindow         = ConvertTo-Flag (Get-ConfigValue $raw @('KioskMode', 'FullScreenWindow')) $true
        ReportFullScreen         = $fullScreen
        ViewMenuLabels           = @(ConvertTo-StringList (Get-ConfigValue $raw @('ViewMenuLabels') @('View', 'Zobrazit')))
        FullScreenLabels         = @(ConvertTo-StringList (Get-ConfigValue $raw @('FullScreenLabels') @('Full screen', 'Fullscreen', 'Celá obrazovka')))
        HideNavigation           = ConvertTo-Flag (Get-ConfigValue $raw @('HideNavigation')) $true
        HideNavigationLabels     = @(ConvertTo-StringList (Get-ConfigValue $raw @('HideNavigationLabels') @('Hide navigation', 'Skrýt navigaci')))
        UsePrimaryScreen         = ConvertTo-Flag (Get-ConfigValue $raw @('UsePriScreen', 'UsePrimaryScreen')) $false
        ScreenNumber             = [int](ConvertTo-Number (Get-ConfigValue $raw @('ScreenSelect', 'ScreenNumber')) 1 1 16)
        DisplayWaitSeconds       = [int](ConvertTo-Number (Get-ConfigValue $raw @('DisplayWaitSeconds')) 120 0 3600)
        ZoomPercent              = $zoom
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
        BlankReloadSeconds       = ConvertTo-Number (Get-ConfigValue $raw @('BlankReloadSeconds')) 180 0 7200
        VisualSelector           = [string](Get-ConfigValue $raw @('VisualSelector') 'visual-container, .visual-container, .visualContainer, .visualContainerHost, [class*="visual-container"], dashboard-tile, .dashboardTile, tile-container')
        CanvasSelector           = [string](Get-ConfigValue $raw @('CanvasSelector') 'exploration-container, .explorationContainer, #pvExplorationHost, .reportCanvas, .displayArea, dashboard-canvas, .dashboardContainer')
        Supervised               = ConvertTo-Flag (Get-ConfigValue $raw @('Supervised')) $true
        BackButton               = ConvertTo-Flag (Get-ConfigValue $raw @('BackButton')) $true
        BackButtonText           = [string](Get-ConfigValue $raw @('BackButtonText') 'Back to report')
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
    $cfg.EffectiveUrl = Get-EffectiveUrl -Url $cfg.DisplayUrl -Mode $cfg.ReportFullScreen

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
        Launcher        = 'PBI'
        Screen          = $(if ($script:LegacyLayout) { '' } else { $Instance })
        LauncherVersion = $LauncherVersion
        WindowsUser     = "$env:USERDOMAIN\$env:USERNAME"
        Pid             = $PID
        StartedUtc      = [DateTime]::UtcNow.ToString('o')
        State           = 'STARTING'
        StateSinceUtc   = [DateTime]::UtcNow.ToString('o')
        Detail          = ''
        DisplayUrl      = $Config.DisplayUrl
        UserName        = $Config.UserName
        CurrentUrl      = ''
        Supervised      = $true
        EdgeVersion     = ''
        BrowserPid      = 0
        BrowserStarts   = 0
        Reloads         = 0
        SignIns         = 0
        SignedInAs      = ''
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
# Sign-in password (DPAPI, current Windows account)
# ---------------------------------------------------------------------------
$PasswordEntropy = [Text.Encoding]::UTF8.GetBytes('PbiLauncher.SignIn.v2')
$SeedPath = Join-Path $Here 'password.seed'

# Encrypts the sign-in password for the kiosk account (DPAPI) and saves it.
function Save-SignInPassword {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Password, [string]$UserName)

    $plain = [Text.Encoding]::UTF8.GetBytes($Password)
    try { $enc = [Security.Cryptography.ProtectedData]::Protect($plain, $PasswordEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }

    Write-JsonFile -Path $Path -Object ([ordered]@{
            Format       = 'PbiLauncher-DPAPI-CurrentUser-1'
            Note         = 'Encrypted for WindowsUser on ComputerName. Nobody else can read it. Replace it with password.seed or PbiLauncher.ps1 -SetPassword.'
            WindowsUser  = "$env:USERDOMAIN\$env:USERNAME"
            ComputerName = $ComputerName
            SignInUser   = $UserName
            SavedUtc     = [DateTime]::UtcNow.ToString('o')
            Data         = [Convert]::ToBase64String($enc)
        })
}

# Decrypts the saved sign-in password.
function Read-SignInPassword {
    param([Parameter(Mandatory)][string]$Path)
    $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
    $enc = [Convert]::FromBase64String([string]$doc.Data)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($enc, $PasswordEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($plain) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
}

# Picks up a password.seed file, saves the password encrypted and deletes the seed.
function Import-PasswordSeed {
    # password.seed is how a password reaches the kiosk without anyone typing
    # it there: the deploy script (or a person) drops it, the launcher
    # encrypts it for the kiosk account and deletes it.
    param([Parameter(Mandatory)]$Config)

    if (-not (Test-Path -LiteralPath $SeedPath)) { return $false }
    try {
        $text = [IO.File]::ReadAllText($SeedPath)
        $pw = ($text -split "`r?`n")[0]
        if (-not $pw) { throw 'the file is empty' }

        Save-SignInPassword -Path $Config.CredentialFile -Password $pw -UserName $Config.UserName
        if ((Read-SignInPassword -Path $Config.CredentialFile) -cne $pw) { throw 'the encrypted copy did not read back the same' }

        # Overwrite before deleting, so the plain text is not left behind in
        # the file's old clusters.
        $len = [IO.File]::ReadAllBytes($SeedPath).Length
        [IO.File]::WriteAllBytes($SeedPath, (New-Object byte[] $len))
        Remove-Item -LiteralPath $SeedPath -Force
        $pw = $null

        Write-Log ("Imported the sign-in password from password.seed into {0}, encrypted for {1}\{2}. The seed file is deleted." -f (Split-Path -Leaf $Config.CredentialFile), $env:USERDOMAIN, $env:USERNAME)
        return $true
    }
    catch {
        Write-Log ("Could not import password.seed: {0}" -f $_.Exception.Message) 'ERROR'
        return $false
    }
}

# Returns the sign-in password when a sign-in needs it.
function Get-SignInPassword {
    # Read on demand rather than kept in memory: a sign-in happens rarely.
    param([Parameter(Mandatory)]$Config)

    if (Test-Path -LiteralPath $Config.CredentialFile) {
        try { return (Read-SignInPassword -Path $Config.CredentialFile) }
        catch {
            Write-Log ("Cannot decrypt {0}: {1}. It only opens for the Windows account that saved it - drop a new password.seed." -f (Split-Path -Leaf $Config.CredentialFile), $_.Exception.Message) 'ERROR'
            return $null
        }
    }
    if ($Config.LegacyPassword) {
        Write-Log 'Using the plain-text Password from the config file. It has been copied into an encrypted file - remove it from the config.' 'WARN'
        try {
            Save-SignInPassword -Path $Config.CredentialFile -Password $Config.LegacyPassword -UserName $Config.UserName
            # Our own write, not a new password: it must not reset the
            # sign-in attempt count.
            if ($script:Session) { $script:Session.Login.CredStamp = [string](Get-Item -LiteralPath $Config.CredentialFile).LastWriteTimeUtc.Ticks }
        }
        catch { Write-Log "Could not save the encrypted copy: $($_.Exception.Message)" 'WARN' }
        return $Config.LegacyPassword
    }
    return $null
}

# Prompts for the sign-in password and saves it encrypted (-SetPassword mode).
function Invoke-SetPassword {
    param($Config)

    $user = if ($Config -and $Config.UserName) { $Config.UserName } else { '(UserName not set in the config)' }
    $file = if ($Config) { $Config.CredentialFile } else { Join-Path $Here "$ComputerName.cred" }
    Write-Host ''
    Write-Host "Power BI account : $user"
    Write-Host "Saved to         : $file"
    Write-Host "Readable only by : $env:USERDOMAIN\$env:USERNAME on $ComputerName"
    Write-Host 'Run this as the kiosk account - the launcher runs as that account and nobody else can decrypt the file.' -ForegroundColor Yellow
    Write-Host ''

    $a = Read-Host 'Password' -AsSecureString
    $b = Read-Host 'Password again' -AsSecureString
    $toPlain = {
        param([Security.SecureString]$Secure)
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
        try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
        finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    $pa = & $toPlain $a
    $pb = & $toPlain $b
    if (-not $pa) { Write-Host 'Nothing entered - nothing saved.' -ForegroundColor Red; return 1 }
    if ($pa -cne $pb) { Write-Host 'The two entries differ - nothing saved.' -ForegroundColor Red; return 1 }

    $un = if ($Config) { $Config.UserName } else { '' }
    Save-SignInPassword -Path $file -Password $pa -UserName $un
    if ((Read-SignInPassword -Path $file) -cne $pa) { Write-Host 'Saved, but it did not read back the same.' -ForegroundColor Red; return 1 }
    Write-Host 'Saved. A running launcher picks it up on its next sign-in.' -ForegroundColor Green
    return 0
}

# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------
# Lists the connected monitors and their positions.
function Get-Monitors {
    if ($script:NativeReady) {
        return @([PbiLauncherNative.Api]::GetMonitors() | ForEach-Object {
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
        that the primary screen is used, so the report shows somewhere.
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
    # A cursor resting on the report shows tooltips. Park it in the top
    # right corner of the kiosk screen, as the old StartupLauncher did.
    param($Screen)
    if (-not $script:NativeReady -or -not $Screen) { return }
    try { [void][PbiLauncherNative.Api]::SetCursorPos($Screen.X + $Screen.Width - 1, $Screen.Y) } catch {}
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
        come back with a "Restore pages?" bubble over the report.
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
    # dialog over the report, and can sign Power BI in as that account
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
        # In app and kiosk mode Edge opens the report itself; a page that is
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
        cross-site redirect (the report to Microsoft sign-in) Edge can list
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
        # The report if it is there, else any web page, and an Edge-internal
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

# Notes that someone left the report through a link (starts the return-to-report timer).
function Start-Browsing {
    # Someone has left the report through a link.
    param([string]$Url)
    $s = $script:Session
    if ($s.Browsing) { return }
    $s.Browsing = $true
    $s.BrowsingSinceUtc = [DateTime]::UtcNow
    Write-Log ("Someone opened {0} from the report." -f $Url)
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
  // Visible to a person: a real size, not pushed off the page, not
  // transparent or aria-hidden anywhere up the tree. Strict on purpose -
  // sign-in pages keep off-screen decoy fields for password managers, and
  // the password must never go into one of those.
  P.vis = function (el) {
    if (!el || !el.getBoundingClientRect) return false;
    var r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return false;
    if (r.right <= 0 || r.bottom <= 0) return false;
    // Only for inputs: menus give most of their items tabindex -1.
    if (el.tagName === 'INPUT' && el.tabIndex < 0) return false;
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      if (n.getAttribute('aria-hidden') === 'true') return false;
      var s = window.getComputedStyle(n);
      if (s.visibility === 'hidden' || s.display === 'none' || parseFloat(s.opacity || '1') < 0.1) return false;
    }
    return true;
  };
  P.list = function (sel, root) {
    try { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); } catch (e) { return []; }
  };
  P.first = function (sel, root) {
    var a = P.list(sel, root);
    for (var i = 0; i < a.length; i++) { if (P.vis(a[i])) return a[i]; }
    return null;
  };
  P.norm = function (s) { return (s || '').replace(/\s+/g, ' ').trim().toLowerCase(); };
  P.byLabel = function (sel, labels, root, whole) {
    var a = P.list(sel, root);
    for (var i = 0; i < a.length; i++) {
      var el = a[i];
      var texts = [P.norm(el.getAttribute('aria-label')), P.norm(el.getAttribute('title')), P.norm(el.textContent), P.norm(el.value)];
      var hit = false;
      for (var j = 0; j < labels.length && !hit; j++) {
        var l = P.norm(labels[j]);
        if (!l) continue;
        for (var k = 0; k < texts.length; k++) {
          var t = texts[k];
          if (t && (whole ? (t === l || t.indexOf(l + ' ') === 0) : t.indexOf(l) >= 0)) { hit = true; break; }
        }
      }
      // Text first, visibility second: a report page has hundreds of
      // buttons, and checking visibility is the expensive part.
      if (hit && P.vis(el)) return el;
    }
    return null;
  };
  P.xpath = function (xp) {
    try {
      var el = document.evaluate(xp, document, null, XPathResult.FIRST_ORDERED_NODE_TYPE, null).singleNodeValue;
      return P.vis(el) ? el : null;
    } catch (e) { return null; }
  };
  P.text = function () { return (document.body && (document.body.innerText || '')) || ''; };
  P.find = function (kind, arg) {
    switch (kind) {
      case 'user': return P.first('input[name="loginfmt"]') || P.first('input[type="email"]');
      case 'pass': return P.first('input[name="passwd"]') || P.first('input[type="password"]');
      case 'submit': return P.first('#idSIButton9') || P.first('input[type="submit"]') || P.first('button[type="submit"]');
      case 'kmsiYes': return P.first('#idSIButton9') || P.byLabel('button, input[type="submit"], input[type="button"]', ['Yes'], null, true);
      case 'kmsiNo': return P.first('#idBtn_Back') || P.byLabel('button, input[type="submit"], input[type="button"]', ['No'], null, true);
      case 'tile':
        if (!arg) return null;
        var want = P.norm(arg);
        var tiles = P.list('[data-test-id], #tilesHolder [role="button"], .tile-container [role="button"]');
        for (var i = 0; i < tiles.length; i++) {
          var id = P.norm(tiles[i].getAttribute('data-test-id'));
          if (!P.vis(tiles[i])) continue;
          if (id === want || (id !== 'othertile' && P.norm(tiles[i].innerText).indexOf(want) >= 0)) return tiles[i];
        }
        return null;
      case 'otherTile': return P.first('#otherTile') || P.first('[data-test-id="otherTile"]') || P.byLabel('[role="button"], button', ['Use another account'], null, false);
      // Power BI's own "Enter your work or school email" page.
      case 'pbiEmail': return /singlesignon/i.test(location.pathname) ? (P.first('input#email') || P.first('input[type="email"]')) : null;
      case 'pbiSubmit': return P.first('#submitBtn') || P.first('button[type="submit"]');
      case 'view':
        var bar = document.querySelector('#exploration-container-app-bars');
        return (bar && P.byLabel('button', arg, bar, true))
          || P.byLabel('app-bar button, [role="toolbar"] button, [role="menubar"] button, header button', arg, null, true)
          || P.xpath('//*[@id="exploration-container-app-bars"]/app-bar/div/div[2]/button[3]');
      case 'hideNav':
        // A Power BI app's page list ("Hide navigation" - once hidden the
        // same button says "Show navigation", which never matches).
        return P.byLabel('button, [role="button"]', arg, null, true);
      case 'fullscreen':
        // The open menu first; any button only as a last resort.
        return P.byLabel('[role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], .mat-mdc-menu-item, .mat-menu-item', arg, null, false)
          || P.byLabel('.cdk-overlay-container button, [role="menu"] button', arg, null, false)
          || P.byLabel('button', arg, null, false);
    }
    return null;
  };
  P.rect = function (kind, arg) {
    var el = P.find(kind, arg);
    if (!el) return null;
    if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'center' });
    var r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  };
  P.focus = function (kind, arg) {
    var el = P.find(kind, arg);
    if (!el) return false;
    el.focus();
    if (el.value) {
      el.value = '';
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    return document.activeElement === el;
  };
  P.valueLength = function (kind) {
    var el = P.find(kind);
    return (el && typeof el.value === 'string') ? el.value.length : -1;
  };
  P.state = function (o) {
    var user = o.user, phrases = o.phrases, loginHosts = o.loginHosts, viewLabels = o.viewLabels;
    var t = P.text();
    var low = t.toLowerCase();
    var host = location.hostname.toLowerCase();
    var s = {
      url: location.href, host: host, proto: location.protocol, title: document.title,
      ready: document.readyState, textLen: t.length,
      onLogin: loginHosts.indexOf(host) >= 0,
      user: false, pass: false, kmsi: false, tiles: false, tileForUser: false, otherTile: false,
      displayName: '', loginError: '', mfa: false, pbiEmail: false,
      visuals: 0, canvasFound: false, canvasContent: 0, viewButton: false, hideNavButton: false, loading: false,
      docFullscreen: false, errors: [], screen: null, back: null, accounts: []
    };
    if (s.onLogin) {
      var err = P.first('#usernameError, #passwordError, #idTD_Error, #service_exception_message, #errorText, .alert-error');
      s.loginError = err ? (err.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 300) : '';
      s.user = !!P.find('user');
      s.pass = !!P.find('pass');
      s.kmsi = !!document.querySelector('#KmsiCheckboxField, #KmsiDescription') || /stay signed in\?/i.test(t);
      s.tiles = !!P.first('#tilesHolder, [data-test-id="otherTile"], #otherTile');
      s.tileForUser = !!P.find('tile', user);
      s.otherTile = !!P.find('otherTile');
      var dn = P.first('#displayName, #idDiv_Identity, .identity');
      s.displayName = dn ? (dn.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 200) : '';
      s.mfa = !!document.querySelector('#idDiv_SAOTCAS_Title, #idDiv_SAOTCC_Title, #idDiv_SAOTCS_Title, #idDiv_SAASDS_Title, #idDiv_SAASTO_Title, #idTxtBx_SAOTCC_OTC, #ProofUpDescription')
        || /approve sign.?in request|enter code|verify your identity|more information required/i.test(t);
    }
    s.pbiEmail = !!P.find('pbiEmail');
    // Has the report drawn? Visual containers are the direct sign; failing
    // that, pictures (svg, canvas, img) inside the report canvas.
    s.visuals = P.list(o.visualSel).length;
    var area = P.first(o.canvasSel);
    s.canvasFound = !!area;
    s.canvasContent = 0;
    if (area) {
      var parts = P.list('svg, canvas, img', area);
      for (var c = 0; c < parts.length && s.canvasContent < 3; c++) {
        var pr = parts[c].getBoundingClientRect();
        if (pr.width >= 20 && pr.height >= 20) s.canvasContent++;
      }
    }
    s.viewButton = !!P.find('view', viewLabels);
    s.hideNavButton = o.hideNavLabels.length > 0 && !!P.find('hideNav', o.hideNavLabels);
    s.loading = !!P.first('#pbi-svg-loading');
    s.docFullscreen = !!(document.fullscreenElement || document.webkitFullscreenElement);
    var b = window.__pbilBack;
    s.back = b ? { present: !!b.present, idle: b.idle(), onReport: !!b.onReport } : null;
    // The account the page is signed in as: Power BI keeps it in its
    // sign-in library's (MSAL) cache. User names only.
    s.accounts = [];
    // Reading the storage itself throws on pages that have none (Edge's
    // own error page), so the whole read sits inside the try.
    ['localStorage', 'sessionStorage'].forEach(function (name) {
      try {
        var st = window[name];
        for (var a = 0; a < st.length; a++) {
          var v = st.getItem(st.key(a)) || '';
          if (v.indexOf('"username"') < 0) continue;
          try { var acct = JSON.parse(v); if (acct && typeof acct.username === 'string' && s.accounts.indexOf(acct.username) < 0) s.accounts.push(acct.username); } catch (e) {}
        }
      } catch (e) {}
    });
    for (var i = 0; i < phrases.length; i++) {
      if (phrases[i] && low.indexOf(phrases[i].toLowerCase()) >= 0) s.errors.push(phrases[i]);
    }
    s.screen = { x: window.screenX, y: window.screenY, w: screen.width, h: screen.height, iw: window.innerWidth, ih: window.innerHeight, dpr: window.devicePixelRatio };
    return s;
  };
  window.__pbil2 = P;
})();
'@

# Put into every page Edge loads (Page.addScriptToEvaluateOnNewDocument),
# before the page's own scripts. On any top-level page that is not the
# report it shows a "Back to report" button and returns to the report after
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
    var p = low(location.pathname).replace(/\/+$/, '');
    if (k.id) return p.indexOf(k.id) >= 0;
    if (p !== k.path) return false;
    var have = {};
    location.search.replace(/^\?/, '').split('&').forEach(function (kv) {
      if (!kv) return;
      var i = kv.indexOf('=');
      var name = i < 0 ? kv : kv.slice(0, i), value = i < 0 ? '' : kv.slice(i + 1);
      try { name = decodeURIComponent(name.replace(/\+/g, ' ')); value = decodeURIComponent(value.replace(/\+/g, ' ')); } catch (e) {}
      have[low(name)] = low(value);
    });
    for (var q in k.query) { if (have[q] !== k.query[q]) return false; }
    return true;
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
      // Back on the report within the same page (Power BI moves between
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
        key         = (Get-TargetKey -Url $Config.EffectiveUrl)
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

# Asks the page what it is showing (report, sign-in page, error, ...).
function Get-PageState {
    param([Parameter(Mandatory)]$Config)
    $options = [ordered]@{
        user       = $Config.UserName
        phrases    = @($Config.ErrorPhrases)
        loginHosts = @($Config.LoginHosts)
        viewLabels = @($Config.ViewMenuLabels)
        hideNavLabels = $(if ($Config.HideNavigation) { @($Config.HideNavigationLabels) } else { @() })
        visualSel  = $Config.VisualSelector
        canvasSel  = $Config.CanvasSelector
    }
    return (Invoke-PageJs -Config $Config -Expression ('P.state({0})' -f (ConvertTo-Json -InputObject $options -Compress -Depth 4)))
}

# Clicks a page element with a real mouse click through Edge.
function Send-Click {
    # A real mouse click through Edge's input pipeline, not element.click():
    # Power BI's full screen needs a user gesture, and Microsoft's sign-in
    # buttons behave as they do for a person.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Kind, $Arg = $null)

    $rect = Invoke-PageJs -Config $Config -Expression ('P.rect({0}, {1})' -f (ConvertTo-JsLiteral $Kind), (ConvertTo-JsLiteral $Arg))
    if (-not $rect) { return $false }
    $x = [double]$rect.x; $y = [double]$rect.y
    foreach ($type in @('mouseMoved', 'mousePressed', 'mouseReleased')) {
        $p = @{ type = $type; x = $x; y = $y }
        if ($type -ne 'mouseMoved') { $p.button = 'left'; $p.clickCount = 1 }
        $null = Invoke-Cdp -Config $Config -Method 'Input.dispatchMouseEvent' -Params $p
    }
    return $true
}

# Types text into a page field (e-mail or password).
function Send-Text {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Text)

    if (-not (Invoke-PageJs -Config $Config -Expression ('P.focus({0})' -f (ConvertTo-JsLiteral $Kind)))) { return $false }
    $null = Invoke-Cdp -Config $Config -Method 'Input.insertText' -Params @{ text = $Text }
    $len = Invoke-PageJs -Config $Config -Expression ('P.valueLength({0})' -f (ConvertTo-JsLiteral $Kind))
    return ([int]$len -eq $Text.Length)
}

# Presses Enter or Escape in the page.
function Send-Key {
    param([Parameter(Mandatory)]$Config, [ValidateSet('Enter', 'Escape')][string]$Key)
    $code = if ($Key -eq 'Enter') { 13 } else { 27 }
    $down = @{ type = 'keyDown'; key = $Key; code = $Key; windowsVirtualKeyCode = $code; nativeVirtualKeyCode = $code }
    if ($Key -eq 'Enter') { $down.text = "`r" }
    $null = Invoke-Cdp -Config $Config -Method 'Input.dispatchKeyEvent' -Params $down
    $null = Invoke-Cdp -Config $Config -Method 'Input.dispatchKeyEvent' -Params @{ type = 'keyUp'; key = $Key; code = $Key; windowsVirtualKeyCode = $code; nativeVirtualKeyCode = $code }
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

# Tells whether an address is the configured Power BI report.
function Test-IsTargetUrl {
    <#
        Is the page on the configured report? Compared by the report (or
        dashboard) ID, not the whole URL: Power BI rewrites the page segment
        and query string as it pleases, and the old launcher's exact
        comparison relaunched itself every time it did.
    #>
    param([string]$Current, [string]$Target)

    $c = $null; $t = $null
    if (-not [Uri]::TryCreate($Current, [UriKind]::Absolute, [ref]$c)) { return $false }
    if (-not [Uri]::TryCreate($Target, [UriKind]::Absolute, [ref]$t)) { return $false }
    if ($c.Host -ne $t.Host) { return $false }

    $tp = $t.AbsolutePath.TrimEnd('/').ToLowerInvariant()
    $cp = $c.AbsolutePath.TrimEnd('/').ToLowerInvariant()

    $ids = [regex]::Matches($tp, '/(reports|rdlreports|dashboards|scorecards)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    if ($ids.Count -gt 0) { return $cp.Contains($ids[$ids.Count - 1].Value) }

    if ($cp -ne $tp) { return $false }
    # reportEmbed?reportId=..., view?r=... (publish to web)
    $tq = [Web.HttpUtility]::ParseQueryString($t.Query)
    $cq = [Web.HttpUtility]::ParseQueryString($c.Query)
    foreach ($key in @('reportId', 'dashboardId', 'r')) {
        if ($tq[$key] -and $tq[$key] -ne $cq[$key]) { return $false }
    }
    return $true
}

# Builds the rule the page script uses to recognise the report address.
function Get-TargetKey {
    # Test-IsTargetUrl's rule in a form the page script can apply itself:
    # the host, plus the report ID in the path - or, without one, the whole
    # path and the ID query parameters.
    param([Parameter(Mandatory)][string]$Url)

    $u = [Uri]$Url
    $path = $u.AbsolutePath.TrimEnd('/').ToLowerInvariant()
    $ids = [regex]::Matches($path, '/(reports|rdlreports|dashboards|scorecards)/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
    $query = [ordered]@{}
    if ($ids.Count -eq 0) {
        $q = [Web.HttpUtility]::ParseQueryString($u.Query)
        foreach ($k in @('reportId', 'dashboardId', 'r')) {
            if ($q[$k]) { $query[$k.ToLowerInvariant()] = $q[$k].ToLowerInvariant() }
        }
    }
    return [ordered]@{
        host  = $u.Host.ToLowerInvariant()
        id    = $(if ($ids.Count -gt 0) { $ids[$ids.Count - 1].Value } else { '' })
        path  = $path
        query = $query
    }
}

# Navigates to the configured Power BI report.
function Open-Target {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)
    Write-Log "Opening the report ($Why)."
    $r = Invoke-Cdp -Config $Config -Method 'Page.navigate' -Params @{ url = $Config.EffectiveUrl } -TimeoutSec 30
    $errText = $r.PSObject.Properties['errorText']
    if ($errText -and $errText.Value) { Write-Log ("Edge could not open the report: {0}" -f $errText.Value) 'WARN' }
    Reset-PageLoad -Config $Config
}

# Reloads the page, bypassing the cache.
function Invoke-Reload {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)
    Write-Log "Reloading the report ($Why)."
    try { $null = Invoke-Cdp -Config $Config -Method 'Page.reload' -Params @{ ignoreCache = $false } -TimeoutSec 30 }
    catch {
        Write-Log ("Reload failed ({0}); opening the report instead." -f (Get-ErrorText $_)) 'WARN'
        Open-Target -Config $Config -Why $Why
    }
    $script:Status.Reloads++
    $script:Status.LastReloadUtc = [DateTime]::UtcNow.ToString('o')
    Reset-PageLoad -Config $Config
}

# Reloads the page or restarts Edge, with growing pauses, when the report is not right.
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

# Limits how often Power BI full screen is tried (3 per load, then every 10 min).
function Test-FullScreenAttemptAllowed {
    # Three tries per page load, then one round every ten minutes.
    $s = $script:Session
    if ($s.FullScreenTries -lt 3) { return $true }
    if ([DateTime]::UtcNow -ge $s.FullScreenLastUtc.AddMinutes(10)) {
        $s.FullScreenTries = 0
        return $true
    }
    return $false
}

# Clicks Power BI's View > Full screen, as a person would.
function Invoke-ReportFullScreen {
    # Power BI's View > Full screen, as a person would click it.
    param([Parameter(Mandatory)]$Config)

    $s = $script:Session
    $s.FullScreenTries++
    $s.FullScreenLastUtc = [DateTime]::UtcNow

    if (-not (Send-Click -Config $Config -Kind 'view' -Arg @($Config.ViewMenuLabels))) {
        if (-not $s.FullScreenWarned) { Write-Log "Power BI's View menu was not found, so the report is not in full screen. If the UI is not in English, set ViewMenuLabels." 'WARN' }
        $s.FullScreenWarned = $true
        return
    }
    Start-Sleep -Milliseconds 1500
    if (-not (Send-Click -Config $Config -Kind 'fullscreen' -Arg @($Config.FullScreenLabels))) {
        Send-Key -Config $Config -Key Escape
        if (-not $s.FullScreenWarned) { Write-Log "Power BI's View menu opened, but it has no Full screen item. If the UI is not in English, set FullScreenLabels." 'WARN' }
        $s.FullScreenWarned = $true
        return
    }
    Start-Sleep -Milliseconds 2000

    $st = Get-PageState -Config $Config
    if ($st -and -not $st.viewButton) {
        $s.FullScreenDone = $true
        $s.FullScreenWarned = $false
        Write-Log 'Power BI is in full screen.'
        # Move the synthetic pointer off the report, so no tooltip stays up.
        try { $null = Invoke-Cdp -Config $Config -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseMoved'; x = 0; y = 0 } } catch {}
    }
    else {
        Write-Log ("Clicked Full screen, but Power BI still shows its menu bar (attempt {0})." -f $s.FullScreenTries) 'WARN'
    }
}

# Signs out and back in when Power BI is signed in with the wrong account.
function Invoke-WrongAccount {
    <#
        Power BI is signed in, but not as UserName - on a domain PC that is
        Windows single sign-on handing over the PC's own account. Sign out
        (clear the session, start a clean Edge) and sign in again; after
        three tries in an hour, stop and say so.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string[]]$Accounts)

    $s = $script:Session
    $l = $s.Login
    $now = [DateTime]::UtcNow
    $who = $Accounts -join ', '
    $script:Status.SignedInAs = $who
    if ($now -lt $l.BlockedUntilUtc) {
        Set-State 'SIGNIN_BLOCKED' $l.BlockedReason
        return
    }
    for ($i = $s.WrongAccountTimes.Count - 1; $i -ge 0; $i--) {
        if ($s.WrongAccountTimes[$i] -lt $now.AddMinutes(-60)) { $s.WrongAccountTimes.RemoveAt($i) }
    }
    if ($s.WrongAccountTimes.Count -ge 3) {
        $hint = if ($Config.InPrivate) { 'Something on this PC signs it in regardless' } else { 'Turn InPrivate back on in the config' }
        Set-LoginBlocked -Reason ("Power BI keeps signing in as {0} instead of {1}. {2}." -f $who, $Config.UserName, $hint) -Minutes 30
        return
    }
    $s.WrongAccountTimes.Add($now)
    Write-Log ("Power BI is signed in as {0}, not {1}. Signing out and starting again." -f $who, $Config.UserName) 'WARN'
    Set-State 'SIGNING_IN' "signed in as $who - signing out"

    # A new InPrivate Edge is a clean session by itself; a kept profile has
    # its cookies and site data cleared first.
    try { $null = Invoke-Cdp -Config $Config -Method 'Network.clearBrowserCookies' } catch {}
    $origins = @(([Uri]$Config.EffectiveUrl).GetLeftPart([UriPartial]::Authority)) + @($Config.LoginHosts | ForEach-Object { "https://$_" })
    foreach ($o in $origins) {
        try { $null = Invoke-Cdp -Config $Config -Method 'Storage.clearDataForOrigin' -Params @{ origin = $o; storageTypes = 'all' } } catch {}
    }
    Restart-Browser -Config $Config -Why "signed in as $who instead of $($Config.UserName)"
}

# Pauses sign-in attempts for a while (e.g. after a rejected password).
function Set-LoginBlocked {
    param([Parameter(Mandatory)][string]$Reason, [Parameter(Mandatory)][double]$Minutes)
    $l = $script:Session.Login
    $l.BlockedUntilUtc = [DateTime]::UtcNow.AddMinutes($Minutes)
    $l.BlockedReason = $Reason
    $script:Status.LastError = $Reason
    Write-Log ("{0} Trying again at {1:HH:mm}." -f $Reason, $l.BlockedUntilUtc.ToLocalTime()) 'ERROR'
    Set-State 'SIGNIN_BLOCKED' $Reason
}

# Lifts the pause on sign-in attempts.
function Clear-LoginBlock {
    param([string]$Why)
    $l = $script:Session.Login
    if ($l.BlockedUntilUtc -gt [DateTime]::UtcNow) {
        Write-Log "Sign-in may be tried again: $Why"
        # The page still shows Microsoft's last error, which would read as a
        # fresh rejection. Start the sign-in again from the report.
        $l.RestartFlow = $true
    }
    $l.BlockedUntilUtc = [DateTime]::MinValue
    $l.BlockedReason = ''
    $l.PasswordTimes.Clear()
    $l.Repeats = 0
    $l.LastAction = ''
}

# Does the next step of Microsoft's sign-in (account, password, stay signed in).
function Invoke-LoginStep {
    <#
        One step of Microsoft's sign-in, chosen from what the page shows:
        account picker, user name, password, "Stay signed in?", or Power BI's
        own e-mail prompt. Called every couple of seconds while a sign-in
        page is up.

        The password is only ever typed into a visible password field, on a
        configured sign-in host over HTTPS, on a page that is not showing a
        different account. After Microsoft rejects it, nothing is typed for
        LoginRetryMinutes; and never more than twice in that window whatever
        happens, so the account cannot be locked out.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$St)

    $l = $script:Session.Login
    $now = [DateTime]::UtcNow
    if ($l.SinceUtc -eq [DateTime]::MinValue) { $l.SinceUtc = $now }

    if ($now -lt $l.BlockedUntilUtc) {
        Set-State 'SIGNIN_BLOCKED' $l.BlockedReason
        return
    }
    if ($l.BlockedReason) {
        # The wait is over. Same as a lifted block: start from the report.
        Write-Log 'The sign-in wait is over; trying again.'
        $l.BlockedReason = ''
        $l.LastAction = ''
        $l.RestartFlow = $true
    }
    if ($l.RestartFlow) {
        $l.RestartFlow = $false
        $l.SinceUtc = $now
        $l.LastActionUtc = $now
        Set-State 'SIGNING_IN' 'starting the sign-in again'
        Open-Target -Config $Config -Why 'starting the sign-in again'
        return
    }
    # Give the page time to react to the last step.
    if ($now -lt $l.LastActionUtc.AddSeconds(3)) { return }

    Set-State 'SIGNING_IN' ("sign-in page on {0}" -f $St.host)

    if ($St.onLogin -and $St.mfa) {
        Set-LoginBlocked -Reason 'Microsoft wants extra verification (MFA or security info). Sign in once at the kiosk: create hold.txt, sign in in the Edge window, then delete hold.txt.' -Minutes 30
        return
    }

    if ($St.onLogin -and $St.loginError) {
        if ($l.LastAction -in @('password', 'user') -and $now -lt $l.LastActionUtc.AddMinutes(3)) {
            Set-LoginBlocked -Reason ("Microsoft rejected the {0}: '{1}'. Not retrying for {2} min so the account is not locked out - drop a new password.seed to retry now." -f $(if ($l.LastAction -eq 'user') { 'user name' } else { 'password' }), ([string]$St.loginError).TrimEnd('.'), $Config.LoginRetryMinutes) -Minutes $Config.LoginRetryMinutes
            return
        }
        Write-Log ("The sign-in page shows an error: {0}" -f $St.loginError) 'WARN'
    }

    $action = ''
    if ($St.onLogin -and $St.kmsi -and -not $St.pass -and -not $St.user) {
        $kind = if ($Config.StaySignedIn) { 'kmsiYes' } else { 'kmsiNo' }
        if (Send-Click -Config $Config -Kind $kind) { $action = 'kmsi' }
    }
    elseif ($St.onLogin -and $St.tiles -and -not $St.pass -and -not $St.user) {
        if ($St.tileForUser -and (Send-Click -Config $Config -Kind 'tile' -Arg $Config.UserName)) { $action = 'tile' }
        elseif ($St.otherTile -and (Send-Click -Config $Config -Kind 'otherTile')) { $action = 'other-account' }
    }
    elseif ($St.pass -and -not $St.user -and -not $St.pbiEmail) {
        # Only once no user name field is showing: the user name always
        # comes first, and a page asking for both is not one to trust with
        # the password.
        $problem = ''
        if (-not $St.onLogin) { $problem = "a password field on $($St.host), which is not a sign-in host (LoginHosts)" }
        elseif ($St.proto -ne 'https:' -and -not $Config.AllowHttpLogin) { $problem = 'a sign-in page that is not HTTPS' }
        elseif ($Config.UserName -and $St.displayName -and $St.displayName -notlike ('*' + $Config.UserName.ToLowerInvariant() + '*')) {
            $problem = "the sign-in page is for '$($St.displayName)', not $($Config.UserName)"
        }
        if ($problem) {
            Write-Log "Not typing the password: $problem. Starting the sign-in over." 'WARN'
            $l.Repeats++
            if ($l.Repeats -ge 3) { Set-LoginBlocked -Reason "Sign-in keeps landing on $problem." -Minutes 15; return }
            Open-Target -Config $Config -Why 'restart sign-in'
            $l.LastAction = 'restart'; $l.LastActionUtc = $now
            return
        }

        $cutoff = $now.AddMinutes(-$Config.LoginRetryMinutes)
        for ($i = $l.PasswordTimes.Count - 1; $i -ge 0; $i--) { if ($l.PasswordTimes[$i] -lt $cutoff) { $l.PasswordTimes.RemoveAt($i) } }
        if ($l.PasswordTimes.Count -ge 2) {
            Set-LoginBlocked -Reason ('The password was already entered twice in {0} min without getting past sign-in.' -f $Config.LoginRetryMinutes) -Minutes $Config.LoginRetryMinutes
            return
        }

        $pw = Get-SignInPassword -Config $Config
        if (-not $pw) {
            Set-LoginBlocked -Reason 'Microsoft asks for the password, and none is stored. Drop password.seed into the screen folder, or run PbiLauncher.ps1 -Instance <screen> -SetPassword as the kiosk account.' -Minutes 15
            return
        }
        try {
            if (Send-Text -Config $Config -Kind 'pass' -Text $pw) {
                $l.PasswordTimes.Add($now)
                if (-not (Send-Click -Config $Config -Kind 'submit')) { Send-Key -Config $Config -Key Enter }
                $action = 'password'
            }
        }
        finally { $pw = $null }
    }
    elseif ($St.user -or $St.pbiEmail) {
        if (-not $Config.UserName) {
            Set-LoginBlocked -Reason 'Microsoft asks which account to use, and UserName is not set in the config.' -Minutes 15
            return
        }
        $kind = if ($St.user) { 'user' } else { 'pbiEmail' }
        if (Send-Text -Config $Config -Kind $kind -Text $Config.UserName) {
            $submit = if ($St.user) { 'submit' } else { 'pbiSubmit' }
            if (-not (Send-Click -Config $Config -Kind $submit)) { Send-Key -Config $Config -Key Enter }
            $action = 'user'
        }
    }

    if ($action) {
        if ($action -eq $l.LastAction -and $now -lt $l.LastActionUtc.AddMinutes(2)) { $l.Repeats++ } else { $l.Repeats = 0 }
        $l.LastAction = $action
        $l.LastActionUtc = $now
        $l.SinceUtc = $now
        $shown = switch ($action) {
            'user' { "entered user name $($Config.UserName)" }
            'password' { 'entered the password' }
            'kmsi' { "answered 'Stay signed in?' with $(if ($Config.StaySignedIn) { 'Yes' } else { 'No' })" }
            'tile' { "picked the account tile for $($Config.UserName)" }
            default { "chose 'Use another account'" }
        }
        Write-Log "Sign-in: $shown."
        if ($l.Repeats -ge 4) {
            Set-LoginBlocked -Reason "Sign-in is going round in circles (step '$action' repeated)." -Minutes 15
        }
        return
    }

    # Nothing to do on this page. Microsoft sometimes parks on an
    # interstitial; after five minutes start again from the report.
    if ($now -gt $l.SinceUtc.AddMinutes(5)) {
        Write-Log ("Stuck on a sign-in page for 5 min ({0}); starting over." -f $St.url) 'WARN'
        $l.SinceUtc = $now
        Open-Target -Config $Config -Why 'sign-in stalled'
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
    $comment = "PBI Launcher: $Why [PBI-LAUNCHER]"
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

# Restarts the PC when repeated Edge restarts fail to bring the report back (opt-in).
function Test-RebootEscalation {
    # Opt-in (RebootAfterRelaunches > 0): restart the PC when new Edges keep
    # failing to bring the report back. Never within an hour of boot, and at
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
    Invoke-PcRestart -Why ("Edge was restarted {0} times in 2 h without the report coming back" -f $recent) -DelaySeconds 60
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
        of it. Status\<instance>.png (a screenshot of the page) and
        Status\<instance>.snapshot.json (address, state, signed-in account).
    #>
    param([Parameter(Mandatory)]$Config)

    $base = Join-Path $script:StatusDir $script:InstanceName
    $info = [ordered]@{
        TakenUtc  = [DateTime]::UtcNow.ToString('o')
        State     = $script:Status.State
        Detail    = $script:Status.Detail
        Url       = ''
        Title     = ''
        Accounts  = @()
        Visuals   = $null
        Image     = ''
        Error     = ''
    }
    try {
        if (-not $script:Supervised) { throw 'not available unsupervised (no DevTools connection)' }
        if (-not $script:Browser) { throw 'Edge is not running' }
        $st = Get-PageState -Config $Config
        if ($st) {
            $info.Url = [string]$st.url
            $info.Title = [string]$st.title
            $info.Accounts = @($st.accounts)
            $info.Visuals = $st.visuals
        }
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
        if ($script:Browser -and $script:Supervised -and $script:Session.RefusedStreak -gt 0) {
            # Reloading Power BI's refusal page would only refuse again; try
            # the report now, for whoever has just fixed the account.
            $script:Session.NextRefusedUtc = [DateTime]::MinValue
            Open-Target -Config $Config -Why 'refresh.txt'
        }
        elseif ($script:Browser -and $script:Supervised) {
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
        if (@(Invoke-StrayPages -Config $Config -MainOnSignIn ([bool]$st.onLogin))[-1]) { return 2 }
    }
    catch { Write-Log ("Checking for extra windows failed: {0}" -f (Get-ErrorText $_)) 'DEBUG' }

    $script:Status.CurrentUrl = [string]$st.url
    if (-not $s.LoggedScreen -and $st.screen) {
        $s.LoggedScreen = $true
        Write-Log ("Page window: {0},{1}, screen {2}x{3}, viewport {4}x{5}, pixel ratio {6}." -f $st.screen.x, $st.screen.y, $st.screen.w, $st.screen.h, $st.screen.iw, $st.screen.ih, $st.screen.dpr)
    }
    Write-Log ("Page: {0} visuals={1} view={2} errors={3} login={4}/{5}/{6}" -f $st.url, $st.visuals, $st.viewButton, (@($st.errors) -join ';'), $st.onLogin, $st.user, $st.pass) 'DEBUG'

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

    # --- sign-in ------------------------------------------------------------
    # Power BI's own e-mail prompt only counts away from the report itself,
    # so an e-mail box on a report page is never taken for a sign-in.
    $onReport = Test-IsTargetUrl -Current $url -Target $Config.EffectiveUrl
    $isReportHost = @($Config.ReportHosts | Where-Object { $pageHost -like $_ }).Count -gt 0
    if ($st.pbiEmail -and ($onReport -or -not $isReportHost)) { $st.pbiEmail = $false }
    if ($st.onLogin -or $st.pbiEmail) {
        $s.OffTargetSinceUtc = [DateTime]::MinValue
        Invoke-LoginStep -Config $Config -St $st
        return 2
    }
    if ($s.Login.SinceUtc -ne [DateTime]::MinValue) {
        # Past the sign-in pages.
        if ($s.Login.LastAction) {
            $script:Status.SignIns++
            Write-Log 'Signed in.'
            $s.Login.PasswordTimes.Clear()
        }
        $s.Login.SinceUtc = [DateTime]::MinValue
        $s.Login.LastAction = ''
        $s.Login.Repeats = 0
    }

    # --- the right account? --------------------------------------------------
    if ($isReportHost -and $Config.UserName) {
        $accounts = @(@($st.accounts) | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($accounts.Count -gt 0) {
            if (@($accounts | Where-Object { $_ -ieq $Config.UserName }).Count -eq 0) {
                Invoke-WrongAccount -Config $Config -Accounts $accounts
                return 3
            }
            $script:Status.SignedInAs = $Config.UserName
        }
    }

    # --- Power BI refusing the account ----------------------------------------
    # No license (Power BI sends the report to signup.microsoft.com with
    # pbi_source=web_nolicense_redirect) or its own error page, 429 when it
    # throttles. Not someone browsing, and reopening every few seconds only
    # earns every kiosk on the account a 429 - so an ERROR, and waits of
    # 1, 2, 5, 10, then 15 min between tries.
    $refused = ''
    if ($url -match 'nolicense') {
        $refused = "Power BI has no license for $($Config.UserName) (redirected to sign up) - check the account's Power BI license and access to the report"
    }
    elseif ($isReportHost -and $url -match '/ErrorPage\?') {
        $code = if ($url -match '[?&]code=(\d+)') { $Matches[1] } else { '' }
        $type = if ($url -match '[?&]errorType=([^&]+)') { [uri]::UnescapeDataString($Matches[1]) } else { '' }
        $refused = if ($code -eq '429') { "Power BI is throttling $($Config.UserName) (429 $type) - too many reloads on this account" }
                   else { ("Power BI error page (code {0} {1})" -f $code, $type).Trim() }
    }
    if ($refused) {
        $s.OffTargetSinceUtc = [DateTime]::MinValue
        $s.Browsing = $false
        $s.LastRefusedUtc = $now
        $script:Status.LastError = $refused
        if ($now -lt $s.NextRefusedUtc) {
            Set-State 'ERROR' ("{0}; next try {1:HH:mm}" -f $refused, $s.NextRefusedUtc.ToLocalTime())
            return 5
        }
        $waits = @(60, 120, 300, 600, 900)
        $s.NextRefusedUtc = $now.AddSeconds($waits[[math]::Min($s.RefusedStreak, $waits.Count - 1)])
        $s.RefusedStreak++
        Set-State 'ERROR' ("{0}; next try {1:HH:mm}" -f $refused, $s.NextRefusedUtc.ToLocalTime())
        Open-Target -Config $Config -Why ("Power BI refused the report (try {0})" -f $s.RefusedStreak)
        return 5
    }

    # --- somewhere other than the report ------------------------------------
    if (-not $onReport) {
        if ($s.ShownSinceLoad -or $s.Browsing) {
            # The report was up, so this is someone who followed a link out
            # of it. Leave them be: the page has a Back button and goes home
            # by itself after ReturnAfterSeconds without use. The launcher
            # only steps in if that did not happen, and skips its health
            # checks meanwhile - someone else's site is not ours to reload.
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
            $detail = "someone opened $pageHost from the report"
            if ($Config.ReturnAfterSeconds -gt 0) { $detail += "; back to the report after $($Config.ReturnAfterSeconds) s unused" }
            Set-State 'BROWSING' $detail
            return [math]::Min(5, $Config.HealthCheckSeconds)
        }
        # Right after sign-in Power BI takes a few redirects to get back to
        # the report; only step in if it does not.
        if ($s.OffTargetSinceUtc -eq [DateTime]::MinValue) { $s.OffTargetSinceUtc = $now; return 3 }
        if ($now -lt $s.OffTargetSinceUtc.AddSeconds(20)) { return 3 }
        $s.OffTargetSinceUtc = [DateTime]::MinValue
        Set-State 'LOADING' 'the page was not on the report'
        Open-Target -Config $Config -Why "the page was on $url"
        return 3
    }
    $s.OffTargetSinceUtc = [DateTime]::MinValue
    $s.NavigateStreak = 0
    $s.NextNavigateUtc = [DateTime]::MinValue

    # --- on the report --------------------------------------------------------
    if ($s.Browsing) {
        # Back from a link - by the Back button, the page's own timer, or us.
        # A fresh start for the checks below, full screen included.
        Write-Log ("Back on the report after {0:0} s away." -f ($now - $s.BrowsingSinceUtc).TotalSeconds)
        $s.Browsing = $false
        Reset-PageLoad -Config $Config
    }
    $isPowerBi = $isReportHost
    $errors = @($st.errors)
    $sinceLoad = ($now - $s.PageLoadedUtc).TotalSeconds
    if (-not $isPowerBi) { $drawn = $st.ready -eq 'complete' }
    elseif ($st.loading) { $drawn = $false }
    elseif ([int]$st.visuals -gt 0 -or [int]$st.canvasContent -gt 0) { $drawn = $true }
    elseif ($st.canvasFound) { $drawn = $false }
    elseif ($sinceLoad -ge 60) {
        # A page layout the selectors do not know. Better to call it drawn
        # than to reload a working report over and over.
        $drawn = $true
        if (-not $s.CanvasWarned) {
            Write-Log 'Cannot find the report canvas on this page, so a blank report cannot be detected here. If Power BI changed its page, set CanvasSelector / VisualSelector.' 'WARN'
            $s.CanvasWarned = $true
        }
    }
    else { $drawn = $false }

    if ($errors.Count -gt 0) {
        $s.HealthyStreak = 0
        $s.ErrorStreak++
        if ($s.ErrorStreak -eq 1) { Write-Log ("The report shows: {0}" -f ($errors -join '; ')) 'WARN' }
        if ($s.ErrorStreak -ge $Config.ErrorChecksBeforeReload) {
            Invoke-Recovery -Config $Config -Why ("the report shows '{0}'" -f ($errors -join "', '"))
        }
        return [math]::Min(5, $Config.HealthCheckSeconds)
    }
    $s.ErrorStreak = 0

    if (-not $drawn) {
        $s.HealthyStreak = 0
        if ($Config.BlankReloadSeconds -gt 0 -and $sinceLoad -gt $Config.BlankReloadSeconds) {
            Invoke-Recovery -Config $Config -Why ("the report has drawn nothing for {0:0} s" -f $sinceLoad)
        }
        elseif ($script:Status.State -ne 'RECOVERING') {
            Set-State 'LOADING' 'waiting for the report to draw'
        }
        return 3
    }

    # Drawn and error-free.
    $s.HealthyStreak++
    if ($s.HealthyStreak -ge 2 -and $s.Recoveries -gt 0) {
        Write-Log ("The report is back after {0} recovery step(s)." -f $s.Recoveries)
        $s.Recoveries = 0
        $s.LastRecoveryUtc = [DateTime]::MinValue
    }
    # Power BI shows the report for a moment before refusing it again, so the
    # waits only start over once it has let the report be for 10 minutes.
    if ($s.RefusedStreak -gt 0 -and $now -gt $s.LastRefusedUtc.AddMinutes(10)) {
        Write-Log ("Power BI has shown the report for 10 minutes after refusing it {0} time(s)." -f $s.RefusedStreak)
        $s.RefusedStreak = 0
        $s.NextRefusedUtc = [DateTime]::MinValue
        $script:Status.LastError = ''
    }

    # A Power BI app shows its page list beside the report; hide it, as the
    # old launcher (1.0.0.14) did. With chromeless=true in the address there
    # is no View menu, so this is what makes the report fill the screen.
    if ($isPowerBi -and $Config.HideNavigation -and $st.hideNavButton) {
        if ($s.NavHidden) {
            Write-Log "Power BI's navigation pane is showing again; hiding it." 'WARN'
            $s.NavHidden = $false
            $s.NavTries = 0
        }
        if ($s.NavTries -lt 3) {
            $s.NavTries++
            Set-State 'LOADING' 'hiding the Power BI navigation pane'
            if (Send-Click -Config $Config -Kind 'hideNav' -Arg @($Config.HideNavigationLabels)) {
                Start-Sleep -Milliseconds 1000
                $after = Get-PageState -Config $Config
                if ($after -and -not $after.hideNavButton) {
                    $s.NavHidden = $true
                    Write-Log "Hid Power BI's navigation pane."
                }
                else { Write-Log ("Clicked Hide navigation, but the pane is still there (attempt {0})." -f $s.NavTries) 'WARN' }
            }
            return 3
        }
    }

    $needsFullScreen = $isPowerBi -and $Config.ReportFullScreen -eq 'click' -and $st.viewButton -and -not $st.docFullscreen
    if ($needsFullScreen) {
        if ($s.FullScreenDone) {
            Write-Log 'Power BI left full screen; switching it back.' 'WARN'
            $s.FullScreenDone = $false
            $s.FullScreenTries = 0
        }
        if (Test-FullScreenAttemptAllowed) {
            Set-State 'LOADING' 'switching Power BI to full screen'
            Invoke-ReportFullScreen -Config $Config
            return 3
        }
    }

    # The report is up. Without full screen it is still worth showing - and
    # still worth refreshing - so a View menu that cannot be found does not
    # hold everything else up.
    Set-State 'SHOWING' $(if ($needsFullScreen) { 'Power BI is not in full screen (see the log)' } else { '' })
    $s.ShownSinceLoad = $true

    # --- scheduled reloads --------------------------------------------------
    foreach ($t in $Config.RefreshTimes) {
        if (Test-DailyDue -At $t -Tag 'refresh' -Done $s.TimedDone) {
            Invoke-Reload -Config $Config -Why ('daily refresh at {0:hh\:mm}' -f $t)
            return 3
        }
    }
    if ($now -ge $s.NextIntervalRefreshUtc) {
        Invoke-Reload -Config $Config -Why ('every {0} min' -f $Config.RefreshMinutes)
        return 3
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
    if (-not $ShowConsole -and -not $SetPassword) { $consoleState = Hide-ConsoleWindow }

    # --- config -------------------------------------------------------------
    $configFile = $null
    $config = $null
    try {
        $configFile = Resolve-ConfigPath -Explicit $ConfigPath
        $config = Read-LauncherConfig -Path $configFile
    }
    catch {
        if ($SetPassword) {
            Write-Host "Config: $($_.Exception.Message)" -ForegroundColor Yellow
            return (Invoke-SetPassword -Config $null)
        }
        # Nowhere configured to log to yet: use the default local log.
        $script:InstanceName = $ComputerName
        Initialize-Log -Config ([pscustomobject]@{ LogDir = (Join-Path $Here 'Logs'); LogName = "PbiLauncher_$ComputerName.log"; RemoteLogDir = '' })
        Write-Log ("PBI Launcher {0} cannot start: {1}" -f $LauncherVersion, $_.Exception.Message) 'ERROR'
        return 1
    }

    if ($SetPassword) { return (Invoke-SetPassword -Config $config) }

    $script:InstanceName = $config.Instance
    $script:DebugLogging = $config.DebugLogging
    Initialize-Log -Config $config
    Initialize-Status -Config $config
    Read-PersistentState
    $script:Session = New-Session

    Write-Log '##### PBI Launcher start #####'
    Write-Log ("PBI Launcher {0} on {1} as {2}\{3}, PowerShell {4}, PID {5}." -f $LauncherVersion, $ComputerName, $env:USERDOMAIN, $env:USERNAME, $PSVersionTable.PSVersion, $PID)
    Write-Log ("Config {0} (version {1}); report {2}" -f $configFile, $(if ($config.JsonVersion) { $config.JsonVersion } else { '-' }), $config.DisplayUrl)
    foreach ($p in $config.Problems) { Write-Log $p 'WARN' }
    if ($config.LegacyPassword) { Write-Log 'The config holds a plain-text Password. It still works, but remove it once the encrypted file exists.' 'WARN' }
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
    $mutex = New-Object Threading.Mutex($false, ('Local\PbiLauncher-' + $config.Instance))
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        Write-Log "Another PBI Launcher is already running for $($config.Instance) in this session; exiting." 'WARN'
        return 0
    }

    try {
        if ($config.Disabled) {
            Write-Log 'DisableStartup is set in the config; exiting.' 'WARN'
            Set-State 'DISABLED'
            Save-Status
            return 0
        }

        [void](Import-PasswordSeed -Config $config)
        if (Test-Path -LiteralPath $config.CredentialFile) {
            $script:Session.Login.CredStamp = [string](Get-Item -LiteralPath $config.CredentialFile).LastWriteTimeUtc.Ticks
        }
        elseif (-not $config.LegacyPassword) {
            Write-Log 'No sign-in password is stored, so every sign-in needs a person. To sign in unattended, drop password.seed into the screen folder.' 'WARN'
        }

        $script:EdgePath = Find-EdgePath -Configured $config.EdgePath
        Write-Log ("Edge: {0} ({1})" -f $script:EdgePath, (Get-Item -LiteralPath $script:EdgePath).VersionInfo.ProductVersion)

        $blockedBy = Get-RemoteDebuggingPolicy
        if ($blockedBy) {
            $script:Supervised = $false
            $script:UnsupervisedWhy = 'Edge policy RemoteDebuggingAllowed = 0: the launcher can only keep Edge open'
            Write-Log "Edge policy RemoteDebuggingAllowed = 0 ($blockedBy). The launcher can only start Edge and keep it open: no automatic sign-in, full screen, health checks or interval refresh. Allow remote debugging for this PC to get them back." 'ERROR'
        }
        elseif (-not $config.Supervised) {
            $script:Supervised = $false
            $script:UnsupervisedWhy = 'Supervised = 0 in the config: the launcher only keeps Edge open'
            Write-Log 'Supervised = 0: the launcher only starts Edge and keeps it open (no sign-in, full screen, health checks or interval refresh). Changing this takes a launcher restart.' 'WARN'
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
                        $script:Status.UserName = $config.UserName
                        Clear-LoginBlock -Why 'the config changed'
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

                # A new password: try signing in again straight away.
                if (Import-PasswordSeed -Config $config) { Clear-LoginBlock -Why 'a new password was saved' }
                if (Test-Path -LiteralPath $config.CredentialFile) {
                    $credStamp = [string](Get-Item -LiteralPath $config.CredentialFile).LastWriteTimeUtc.Ticks
                    if ($credStamp -ne [string]$script:Session.Login.CredStamp) {
                        $script:Session.Login.CredStamp = $credStamp
                        Clear-LoginBlock -Why 'the saved password changed'
                    }
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
        Write-Log '##### PBI Launcher end #####'
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
