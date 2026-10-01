#Requires -Version 5.1
<#
.SYNOPSIS
    Mach2 Launcher ver 1.02NG: shows a Mach2 dashboard full screen on a
    kiosk, keeps it there, and is the kiosk's watchdog.

.DESCRIPTION
    Replaces three programs on a Mach2 kiosk:

      - Mach2Launcher.exe (2.0.0.x) and the StartupLauncher.exe that
        started it
      - the MWST white-screen watchdog (mwstv4.ps1, V7.0) and its logon
        task

    The kiosks are not interactive: nobody uses the screen, so anything
    other than the dashboard is put right.

    For as long as the kiosk account is signed in, it:

      - starts Microsoft Edge full screen on the configured display,
        InPrivate, with a profile of its own
      - signs in to the Mach2 (Niagara) station as the configured user,
        with a password kept DPAPI-encrypted on the kiosk, and signs in
        again whenever the station drops the session
      - opens the dashboard, reloads it on an interval and at fixed times
      - watches the page and puts things right: a sign-in page, a page
        that reads white or dark, a station error, the station
        unreachable, a hung or crashed page, a closed Edge, a window over
        the dashboard

    and, as the watchdog:

      - photographs the screen, as the watchdog did, and records white and
        dark episodes in the watchdog's ledger (mwst_events.csv) and log
        (mwst.log), in the watchdog's format and place, so the fleet
        collector, the Power BI report and the Kiosk Fleet Manager read it
        as before
      - restarts the PC when the dashboard has not been on screen for
        RebootAfterMinutes although the launcher tried reloading and a new
        Edge - but not for a station outage or a sign-in that needs a
        person, which a restart cannot fix (OutageRebootMinutes)
      - keeps every restart provable: the ledger row flushed to disk first,
        the MWST-WATCHDOG tag in the shutdown comment (event 1074), and the
        pending-restart marker confirmed on the next start
      - holds after two restarts in a row that did not help (loop guard)
      - copies Windows' reboot records (1074, 6005, 6008) into the ledger
      - shows messages sent from the Kiosk Fleet Manager (mwst_inbox)
      - stops the old watchdog if anything still starts it

    Edge is driven over its DevTools protocol on a port only this PC can
    reach. There is no msedgedriver.exe and no WebDriver.dll, so an Edge
    update can no longer stop the launcher.

  Folders

    Mach2LauncherNG.ps1 sits in C:\Users\Public\Documents\Mach2LauncherNG.
    Each screen has a folder of its own next to it (S1, S2, ...), holding
    its config (<COMPUTERNAME>.json), control files, Status\ and Logs\.
    -Instance names the folder; S1 is the default.

    Only one instance is the watchdog (Watchdog = 1, S1 by default). The
    watchdog's files stay where the old watchdog kept them
    (WatchdogPath, C:\Users\Public\Documents).

  Sign-in password

    Never stored in plain text by this launcher. Drop password.seed (the
    password on one line) into the instance folder, or run
    Mach2LauncherNG.ps1 -SetPassword as the kiosk account. A plain
    "Password" in an old config still works, with a warning, and is copied
    into the encrypted file.

  Control files (in the instance folder)

    kill.txt      stop the launcher (and so the watchdog) and close Edge
    relaunch.txt  restart Edge
    refresh.txt   reload the dashboard
    restart.txt   restart the PC in 10 seconds
    snapshot.txt  save a screenshot and a page summary in Status\
    hold.txt      pause: the launcher and the watchdog do nothing until it
                  is deleted

.PARAMETER Instance
    The screen's folder next to this script. Default S1.

.PARAMETER ConfigPath
    Config file. Default: <COMPUTERNAME>.json, then config.json, in the
    instance folder.

.PARAMETER SetPassword
    Ask for the Mach2 password, save it encrypted for the current Windows
    account, and exit. Run it as the kiosk account.

.PARAMETER ShowConsole
    Keep the console window on screen and echo the log to it.

.PARAMETER Headless
    Run Edge without a window, and leave the real screen alone (no screen
    checks, no message windows). For testing only.

.PARAMETER ExitAfterSeconds
    Stop after this long. For testing only.

.PARAMETER SimulateRestart
    Record every PC restart the launcher would make, but never call
    shutdown.exe. For testing only.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\Public\Documents\Mach2LauncherNG\Mach2LauncherNG.ps1 -Instance S1

.EXAMPLE
    .\Mach2LauncherNG.ps1 -Instance S1 -SetPassword

.EXAMPLE
    .\Mach2LauncherNG.ps1 -Instance S1 -ShowConsole
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Instance = 'S1',
    [string]$ConfigPath,
    [switch]$SetPassword,
    [switch]$ShowConsole,
    [switch]$Headless,
    [ValidateRange(0, 604800)][int]$ExitAfterSeconds = 0,
    [switch]$SimulateRestart
)

# Strict mode is deliberate: a misspelt variable is an error on first use,
# not an empty value that quietly changes what the kiosk does.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
# Hidden, nobody to show progress bars to - and a module loading for the
# first time (Get-WinEvent's) would write its progress to stderr.
$ProgressPreference = 'SilentlyContinue'

$LauncherVersion = '1.02NG'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Here = Join-Path $ScriptDir $Instance
$ComputerName = $env:COMPUTERNAME.ToUpperInvariant()
$Invariant = [Globalization.CultureInfo]::InvariantCulture
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Drawing

# ---------------------------------------------------------------------------
# Native helpers
# ---------------------------------------------------------------------------
$script:NativeReady = $false

function Initialize-Native {
    # Console hiding, cursor parking and the monitor list. The monitor list
    # comes from EnumDisplayMonitors rather than WinForms' Screen class,
    # which caches the list and never notices a TV switched on later.
    if ('Mach2LauncherNGNative.Api' -as [type]) { $script:NativeReady = $true; return }
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

namespace Mach2LauncherNGNative {
    public static class Api {
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int max);

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

        // Share of sampled pixels brighter than level in all three channels,
        // in a 32-bit BGRA buffer - the watchdog's measure of "white".
        public static double WhitePercent(byte[] px, int width, int height, int stride, int step, int level) {
            long white = 0, total = 0;
            for (int y = 0; y < height; y += step) {
                int row = y * stride;
                for (int x = 0; x < width; x += step) {
                    int i = row + x * 4;
                    total++;
                    if (px[i] > level && px[i + 1] > level && px[i + 2] > level) white++;
                }
            }
            return total == 0 ? -1 : (100.0 * white / total);
        }
    }
}
'@
        $script:NativeReady = $true
    }
    catch {
        # Compiling needs csc.exe. Without it the launcher still works: the
        # console stays visible behind Edge, screens come from WinForms and
        # pixels are counted in PowerShell.
        $script:NativeReady = $false
    }
}

function Get-ConsoleHostKind {
    # conhost (a classic console window), pseudoconsole (Windows Terminal or
    # another terminal app owns it), none, or unknown. Recorded as Console=
    # in AGENT_START, as the watchdog did.
    if (-not $script:NativeReady) { return 'unknown' }
    try {
        $h = [Mach2LauncherNGNative.Api]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return 'none' }
        $name = New-Object System.Text.StringBuilder 256
        [void][Mach2LauncherNGNative.Api]::GetClassName($h, $name, $name.Capacity)
        switch ($name.ToString()) {
            'ConsoleWindowClass' { return 'conhost' }
            'PseudoConsoleWindow' { return 'pseudoconsole' }
            default { return 'other:' + ($name.ToString() -replace '[\s,;]', '_') }
        }
    }
    catch { return 'unknown' }
}

function Hide-ConsoleWindow {
    # The console must never be on the screen: it would cover the dashboard,
    # and the screen checks would photograph it (that is how V6.1 restarted
    # ROLL003 ten times in an hour). Returns what it found.
    if (-not $script:NativeReady) { return 'unknown (no native helpers)' }
    try {
        $h = [Mach2LauncherNGNative.Api]::GetConsoleWindow()
        if ($h -eq [IntPtr]::Zero) { return 'none' }
        if (-not [Mach2LauncherNGNative.Api]::IsWindowVisible($h)) { return 'hidden' }
        [void][Mach2LauncherNGNative.Api]::ShowWindow($h, 0)
        if ([Mach2LauncherNGNative.Api]::IsWindowVisible($h)) {
            return 'still visible (not a classic console - Windows Terminal?)'
        }
        return 'hidden by the launcher'
    }
    catch { return "unknown ($($_.Exception.Message))" }
}

# ---------------------------------------------------------------------------
# Logging (CMTrace format, like the old launcher)
# ---------------------------------------------------------------------------
$script:LogTargets = @()
$script:LogBuffer = New-Object System.Collections.Generic.List[string]
$script:DebugLogging = $false
$script:EchoLog = $false
$MaxLogBytes = 5MB

function New-LogTarget {
    param([string]$Path, [bool]$IsRemote)
    return [pscustomobject]@{ Path = $Path; IsRemote = $IsRemote; DownUntil = [DateTime]::MinValue; Writes = 0; Warned = $false }
}

function Add-LogLine {
    param($Target, [string]$Line)

    if ($Target.DownUntil -gt [DateTime]::UtcNow) { return }
    try {
        # The size is checked now and then rather than on every line: on
        # the central share every metadata call is a network round trip.
        if (($Target.Writes % 200) -eq 0 -and (Test-Path -LiteralPath $Target.Path)) {
            if ((Get-Item -LiteralPath $Target.Path).Length -ge $MaxLogBytes) {
                $old = [IO.Path]::ChangeExtension($Target.Path, '.lo_')
                if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force }
                Move-Item -LiteralPath $Target.Path -Destination $old -Force
            }
        }
        $Target.Writes++
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
    $line = '<![LOG[{0}]LOG]!><time="{1}+000" date="{2}" component="Mach2LauncherNG" context="{3}" type="{4}" thread="{5}" file="Mach2LauncherNG.ps1">' -f `
        $msg, $now.ToString('HH:mm:ss.fff', $Invariant), $now.ToString('MM-dd-yyyy', $Invariant), $Instance, $type, $PID

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
# The watchdog's log and ledger
#
# Same files, same place, same format as the MWST watchdog V7.0, so the
# fleet collector, the Power BI report and the Kiosk Fleet Manager read this
# launcher exactly as they read the watchdog. Only the instance that owns
# the watchdog ($script:WdOn) writes them.
#
#   mwst.log          human-readable; its last-write time is how the
#                     collector tells that the watchdog is running
#   mwst_events.csv   the ledger: one row per event, append-only
# ---------------------------------------------------------------------------
$script:WdOn = $false
$script:StartedUtc = [DateTime]::UtcNow
$script:WdLogPath = ''
$script:LedgerPath = ''
$script:PendingPath = ''
$script:EvtStatePath = ''
$script:LoopStatePath = ''
$script:InboxPath = ''
$script:BootTimeUtc = $null

$EventCsvHeader = 'EventId,EventTimeUtc,EventTimeLocal,Host,EventType,Severity,Outcome,WhitePercent,StreakChecks,DurationSeconds,AgentVersion,BootTimeUtc,Detail'
$MaxWdLogBytes = 5MB
$MaxLedgerBytes = 8MB

function Initialize-WatchdogPaths {
    param([Parameter(Mandatory)][string]$Folder)
    $script:WdLogPath = Join-Path $Folder 'mwst.log'
    $script:LedgerPath = Join-Path $Folder 'mwst_events.csv'
    $script:PendingPath = Join-Path $Folder 'mwst_pending_restart.txt'
    $script:EvtStatePath = Join-Path $Folder 'mwst_evtlog_state.txt'
    $script:LoopStatePath = Join-Path $Folder 'mwst_loopguard.json'
    $script:InboxPath = Join-Path $Folder 'mwst_inbox'
}

function Write-WdLog {
    # A line in mwst.log, in the watchdog's format.
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO')
    if (-not $script:WdOn) { return }
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if ((Test-Path -LiteralPath $script:WdLogPath) -and ((Get-Item -LiteralPath $script:WdLogPath).Length -ge $MaxWdLogBytes)) {
            Rename-Item -LiteralPath $script:WdLogPath -NewName ('mwst_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss')) -ErrorAction SilentlyContinue
        }
        [IO.File]::AppendAllText($script:WdLogPath, $line + [Environment]::NewLine)
    }
    catch { Write-Log "Cannot write mwst.log: $($_.Exception.Message)" 'DEBUG' }
}

function ConvertTo-CsvField {
    # Every field quoted, quotes doubled: a comma in a message can never
    # shift the columns of a row.
    param([object]$Value)
    if ($null -eq $Value) { return '""' }
    return '"' + ([string]$Value).Replace('"', '""') + '"'
}

function Format-Utc {
    param($Value)
    if ($null -eq $Value) { return '' }
    return ([datetime]$Value).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', $Invariant)
}

function Add-LedgerLine {
    param([string]$Line, [switch]$Durable)

    # Roll over before writing, so a row is never split across two files.
    if ((Test-Path -LiteralPath $script:LedgerPath) -and ((Get-Item -LiteralPath $script:LedgerPath).Length -ge $MaxLedgerBytes)) {
        Rename-Item -LiteralPath $script:LedgerPath -NewName ('mwst_events_{0}.csv' -f (Get-Date -Format 'yyyyMMdd_HHmmss')) -ErrorAction SilentlyContinue
    }
    $needHeader = (-not (Test-Path -LiteralPath $script:LedgerPath)) -or ((Get-Item -LiteralPath $script:LedgerPath).Length -eq 0)
    $text = ''
    if ($needHeader) { $text += $EventCsvHeader + "`r`n" }
    $text += $Line + "`r`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($text)
    # UTF-8 BOM once, so Excel and Power Query read the file as UTF-8.
    if ($needHeader) { $bytes = @([byte]0xEF, [byte]0xBB, [byte]0xBF) + $bytes }

    # The collector reads with a share mode that allows our writes; an
    # antivirus scan or someone's Excel may not. A short retry turns "row
    # lost" into "row written 200 ms late".
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $fs = New-Object IO.FileStream($script:LedgerPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
            try {
                $fs.Write($bytes, 0, $bytes.Length)
                if ($Durable) { $fs.Flush($true) } else { $fs.Flush() }
            }
            finally { $fs.Dispose() }
            return
        }
        catch [IO.IOException] {
            if ($attempt -ge 10) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Write-EventRow {
    <#
        One row in the ledger. -Durable flushes it through the disk's own
        write cache: used where losing the row would lose the record of a
        restart. Returns the EventId.
    #>
    param(
        [Parameter(Mandatory)][string]$EventType,
        [ValidateSet('INFO', 'WARNING', 'CRITICAL')][string]$Severity = 'INFO',
        [string]$Outcome = '',
        [object]$WhitePercent = $null,
        [object]$StreakChecks = $null,
        [object]$DurationSeconds = $null,
        [string]$Detail = '',
        [string]$EventId,
        [datetime]$EventTime = ([datetime]::MinValue),
        [switch]$OmitBootTime,
        [switch]$Durable
    )

    if (-not $script:WdOn) { return '' }
    if (-not $EventId) { $EventId = [guid]::NewGuid().ToString() }
    $now = if ($EventTime -eq [datetime]::MinValue) { Get-Date } else { $EventTime }
    $local = if ($now.Kind -eq [DateTimeKind]::Utc) { $now.ToLocalTime() } else { $now }

    $fields = @(
        $EventId
        (Format-Utc $now)
        $local.ToString('yyyy-MM-ddTHH:mm:ss', $Invariant)
        $ComputerName
        $EventType
        $Severity
        $Outcome
        $(if ($null -ne $WhitePercent) { [math]::Round([double]$WhitePercent, 2).ToString($Invariant) } else { '' })
        $(if ($null -ne $StreakChecks) { ([int]$StreakChecks).ToString($Invariant) } else { '' })
        $(if ($null -ne $DurationSeconds) { [math]::Round([double]$DurationSeconds, 0).ToString($Invariant) } else { '' })
        $LauncherVersion
        $(if ($OmitBootTime) { '' } else { Format-Utc $script:BootTimeUtc })
        $Detail
    )
    $line = ($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ','
    try { Add-LedgerLine -Line $line -Durable:$Durable }
    catch { Write-Log "Failed to write '$EventType' to the ledger: $($_.Exception.Message)" 'ERROR' }
    return $EventId
}

function Write-DurableFile {
    # Written through the disk cache: used for what has to survive the
    # restart it precedes (the pending-restart marker, the loop-guard count).
    param([string]$Path, [string]$Text)
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        $fs.Write($bytes, 0, $bytes.Length)
        $fs.Flush($true)
    }
    finally { $fs.Dispose() }
}

function Read-TextWithRetry {
    # Antivirus is busiest just after boot; a file locked for a moment must
    # not be mistaken for a missing or corrupt one.
    param([string]$Path)
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try { return [IO.File]::ReadAllText($Path) }
        catch [IO.FileNotFoundException] { return $null }
        catch [IO.IOException] { Start-Sleep -Milliseconds (400 * $attempt) }
    }
    throw "could not read $Path (locked)"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
# Page text that means the station or the network is at fault. Found on the
# dashboard, it is reloaded after ErrorChecksBeforeReload checks - and it
# never counts towards a PC restart before OutageRebootMinutes.
$DefaultErrorPhrases = @(
    'HTTP ERROR',
    'Problem accessing',
    'Service Unavailable',
    '502 Bad Gateway',
    '503 Service',
    "Hmm, we can't reach this page",
    "This page isn't working",
    "This site can't be reached"
)

function Get-ConfigValue {
    # First of the given keys that is present and not blank. Case-insensitive,
    # like the old launcher's.
    param($Object, [string[]]$Names, $Default = $null)
    foreach ($n in $Names) {
        $p = $Object.PSObject.Properties[$n]
        if (-not $p -or $null -eq $p.Value) { continue }
        if ($p.Value -is [string] -and [string]::IsNullOrWhiteSpace($p.Value)) { continue }
        return $p.Value
    }
    return $Default
}

function ConvertTo-Flag {
    param($Value, [bool]$Default)
    if ($null -eq $Value) { return $Default }
    if ($Value -is [bool]) { return $Value }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    if ($s -in @('1', 'true', 'yes', 'y', 'on')) { return $true }
    if ($s -in @('0', 'false', 'no', 'n', 'off')) { return $false }
    return $Default
}

function ConvertTo-Number {
    param($Value, [double]$Default, [double]$Min = 0, [double]$Max = [double]::MaxValue)
    if ($null -eq $Value) { return $Default }
    $d = 0.0
    if (-not [double]::TryParse(([string]$Value).Trim(), [Globalization.NumberStyles]::Float, $Invariant, [ref]$d)) { return $Default }
    return [math]::Min($Max, [math]::Max($Min, $d))
}

function ConvertTo-StringList {
    param($Value)
    if ($null -eq $Value) { return @() }
    $items = if ($Value -is [string]) { $Value -split '[,;]' } else { @($Value) }
    return @($items | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
}

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

function ConvertTo-WebUri {
    param([string]$Text, [string]$What, [switch]$Optional)
    $uri = $null
    if (-not $Text) {
        if ($Optional) { return $null }
        throw "$What is missing"
    }
    if (-not [Uri]::TryCreate($Text.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('https', 'http')) {
        throw "$What is not a web address: $Text"
    }
    return $uri
}

function Resolve-ConfigPath {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "Config file not found: $Explicit" }
        return (Resolve-Path -LiteralPath $Explicit).ProviderPath
    }
    if (-not (Test-Path -LiteralPath $Here)) {
        throw "No folder for instance $Instance ($Here). Each screen has a folder next to the launcher (S1, S2, ...) with its config."
    }
    foreach ($name in @("$ComputerName.json", 'config.json')) {
        $p = Join-Path $Here $name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    throw "No config file. Expected $ComputerName.json in $Here - copy EXAMPLE.json and fill it in."
}

function Test-FirstMach2Screen {
    # The watchdog, unless the config says otherwise: this kiosk's first
    # Mach2 screen - S1 usually, S2 where Power BI or a web page has S1.
    $screens = @(Get-ChildItem -LiteralPath $ScriptDir -Directory -ErrorAction SilentlyContinue |
            Where-Object { (Test-Path -LiteralPath (Join-Path $_.FullName "$ComputerName.json")) -or (Test-Path -LiteralPath (Join-Path $_.FullName 'config.json')) } |
            ForEach-Object { $_.Name } | Sort-Object)
    if ($screens.Count -eq 0) { return ($Instance -ieq 'S1') }
    return ($screens[0] -ieq $Instance)
}

function Read-LauncherConfig {
    <#
        The config as one object of typed, checked values. A Mach2Launcher
        2.0.0.x file (JSON 1.0.0.16) works as it is; the newer keys are
        optional. What the old launcher needed only for Selenium (driver
        share and updates, zoom and login delays, element timeout) is
        ignored.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $problems = New-Object System.Collections.Generic.List[string]
    $parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
    # The old format wraps the settings in a one-element array.
    $raw = @($parsed)[0]
    if ($null -eq $raw) { throw "Config file is empty: $Path" }

    $display = ConvertTo-WebUri -Text ([string](Get-ConfigValue $raw @('DisplayURL'))) -What 'DisplayURL'
    $login = $null
    try { $login = ConvertTo-WebUri -Text ([string](Get-ConfigValue $raw @('LoginURL'))) -What 'LoginURL' -Optional }
    catch { $problems.Add("$($_.Exception.Message); signing in starts from the dashboard address instead.") }

    $browserMode = ([string](Get-ConfigValue $raw @('BrowserMode') 'app')).ToLowerInvariant()
    if ($browserMode -notin @('app', 'kiosk')) { $problems.Add("BrowserMode '$browserMode' is not app or kiosk; using app."); $browserMode = 'app' }

    # Refresh: RefreshMinutes wins; otherwise the old EnableRefresh +
    # BrowserRefreshDelay pair.
    $refreshMinutes = Get-ConfigValue $raw @('RefreshMinutes')
    if ($null -ne $refreshMinutes) { $refreshMinutes = ConvertTo-Number $refreshMinutes 0 0 10080 }
    elseif (ConvertTo-Flag (Get-ConfigValue $raw @('EnableRefresh')) $false) {
        $refreshMinutes = ConvertTo-Number (Get-ConfigValue $raw @('BrowserRefreshDelay')) 30 1 10080
    }
    else { $refreshMinutes = 0 }

    $refreshTimes = @(ConvertTo-TimesOfDay -Values (ConvertTo-StringList (Get-ConfigValue $raw @('RefreshTimes', 'ForcedRefreshTime'))) -What 'refresh' -Problems $problems)

    $restartTime = $null
    if (ConvertTo-Flag (Get-ConfigValue $raw @('ScheduledRestartEnabled')) $false) {
        $t = @(ConvertTo-TimesOfDay -Values (ConvertTo-StringList (Get-ConfigValue $raw @('ScheduledRestartTime'))) -What 'restart' -Problems $problems)
        if ($t.Count -gt 0) { $restartTime = $t[0] }
    }

    # The password may only be typed on the station's own pages: the hosts
    # of the dashboard and login addresses, unless LoginHosts says others.
    $defaultHosts = @($display.Host)
    if ($login) { $defaultHosts += $login.Host }
    $loginHosts = @(ConvertTo-StringList (Get-ConfigValue $raw @('LoginHosts') ($defaultHosts -join ',')) | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)

    $logName = [string](Get-ConfigValue $raw @('LogName') "Mach2LauncherNG_${ComputerName}_$Instance.log")
    $logName = [IO.Path]::GetFileName($logName)

    $credFile = [string](Get-ConfigValue $raw @('CredentialFile') "$ComputerName.cred")
    if (-not [IO.Path]::IsPathRooted($credFile)) { $credFile = Join-Path $Here $credFile }

    $profileDir = [string](Get-ConfigValue $raw @('ProfileDir') (Join-Path $env:LOCALAPPDATA "Mach2LauncherNG\Profile-$Instance"))
    $profileDir = [Environment]::ExpandEnvironmentVariables($profileDir).TrimEnd('\')

    $logDir = [string](Get-ConfigValue $raw @('LogPath') (Join-Path $Here 'Logs'))
    $logDir = [Environment]::ExpandEnvironmentVariables($logDir)

    $wdPath = [string](Get-ConfigValue $raw @('WatchdogPath') ([Environment]::GetFolderPath('CommonDocuments')))
    $wdPath = [Environment]::ExpandEnvironmentVariables($wdPath).TrimEnd('\')

    $cfg = [pscustomobject]@{
        Path                     = $Path
        DisplayUrl               = $display.AbsoluteUri
        LoginUrl                 = $(if ($login) { $login.AbsoluteUri } else { '' })
        UserName                 = ([string](Get-ConfigValue $raw @('UserName') '')).Trim()
        LegacyPassword           = [string](Get-ConfigValue $raw @('Password') '')
        CredentialFile           = $credFile
        UserField                = [string](Get-ConfigValue $raw @('UsernameFieldName', 'UserField') 'j_username')
        PasswordField            = [string](Get-ConfigValue $raw @('PasswordFieldName', 'PasswordField') 'j_password')
        SubmitButtonId           = [string](Get-ConfigValue $raw @('LoginButtonID', 'SubmitButtonId') 'login-submit')
        LoginHosts               = $loginHosts
        RequireHttps             = ConvertTo-Flag (Get-ConfigValue $raw @('RequireHttps')) $false
        LoginRetryMinutes        = ConvertTo-Number (Get-ConfigValue $raw @('LoginRetryMinutes')) 60 1 1440
        # How patient to be with a slow station. Raise these on a kiosk whose
        # link is slow: a sign-in that is merely slow must not be mistaken for
        # a browser that has stopped answering, because restarting Edge in the
        # middle of one throws the sign-in away and spends a password attempt.
        PageReadTimeoutSeconds   = [int](ConvertTo-Number (Get-ConfigValue $raw @('PageReadTimeoutSeconds')) 15 5 180)
        PageStalledSeconds       = [int](ConvertTo-Number (Get-ConfigValue $raw @('PageStalledSeconds')) 60 10 900)
        SignInWaitSeconds        = [int](ConvertTo-Number (Get-ConfigValue $raw @('SignInWaitSeconds')) 90 10 900)
        SignInSettleSeconds      = [int](ConvertTo-Number (Get-ConfigValue $raw @('SignInSettleSeconds')) 10 3 300)
        BrowserMode              = $browserMode
        InPrivate                = ConvertTo-Flag (Get-ConfigValue $raw @('InPrivate')) $true
        FullScreenWindow         = ConvertTo-Flag (Get-ConfigValue $raw @('KioskMode', 'FullScreenWindow')) $true
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
        HealthCheckSeconds       = ConvertTo-Number (Get-ConfigValue $raw @('HealthCheckSeconds')) 10 1 600
        WhiteHighPercent         = ConvertTo-Number (Get-ConfigValue $raw @('WhiteHighPercent')) 85 1 100
        WhiteLowPercent          = ConvertTo-Number (Get-ConfigValue $raw @('WhiteLowPercent')) 10 0 99
        WhitePixelLevel          = [int](ConvertTo-Number (Get-ConfigValue $raw @('WhitePixelLevel')) 235 0 254)
        BadScreenSeconds         = ConvertTo-Number (Get-ConfigValue $raw @('BadScreenSeconds')) 30 0 3600
        EpisodeGraceSeconds      = ConvertTo-Number (Get-ConfigValue $raw @('EpisodeGraceSeconds')) 120 0 3600
        ErrorPhrases             = @(ConvertTo-StringList (Get-ConfigValue $raw @('ErrorPhrases') $DefaultErrorPhrases))
        ErrorChecksBeforeReload  = [int](ConvertTo-Number (Get-ConfigValue $raw @('ErrorChecksBeforeReload')) 3 1 100)
        MaxReloadsBeforeRelaunch = [int](ConvertTo-Number (Get-ConfigValue $raw @('MaxReloadsBeforeRelaunch')) 1 1 100)
        OffTargetSeconds         = ConvertTo-Number (Get-ConfigValue $raw @('OffTargetSeconds')) 15 0 3600
        Supervised               = ConvertTo-Flag (Get-ConfigValue $raw @('Supervised')) $true
        ParkMouse                = ConvertTo-Flag (Get-ConfigValue $raw @('ParkMouse')) $true
        ScreenCheck              = ConvertTo-Flag (Get-ConfigValue $raw @('ScreenCheck')) $true
        Watchdog                 = ConvertTo-Flag (Get-ConfigValue $raw @('Watchdog')) (Test-FirstMach2Screen)
        StopOldLauncher          = ConvertTo-Flag (Get-ConfigValue $raw @('StopOldLauncher')) $true
        WatchdogPath             = $wdPath
        RebootAfterMinutes       = ConvertTo-Number (Get-ConfigValue $raw @('RebootAfterMinutes')) 5 0 1440
        OutageRebootMinutes      = ConvertTo-Number (Get-ConfigValue $raw @('OutageRebootMinutes')) 30 0 10080
        LoopGuardMaxRestarts     = [int](ConvertTo-Number (Get-ConfigValue $raw @('LoopGuardMaxRestarts')) 2 1 20)
        LoopGuardWindowMinutes   = ConvertTo-Number (Get-ConfigValue $raw @('LoopGuardWindowMinutes')) 60 1 1440
        LoopGuardHealthyMinutes  = ConvertTo-Number (Get-ConfigValue $raw @('LoopGuardHealthyMinutes')) 5 0.1 1440
        LoopGuardRetryMinutes    = ConvertTo-Number (Get-ConfigValue $raw @('LoopGuardRetryMinutes')) 120 0 10080
        RestartConfirmSeconds    = [int](ConvertTo-Number (Get-ConfigValue $raw @('RestartConfirmSeconds')) 600 10 7200)
        LogDir                   = $logDir
        RemoteLogDir             = [string](Get-ConfigValue $raw @('RemoteLogPath') '')
        LogName                  = $logName
        DebugLogging             = ConvertTo-Flag (Get-ConfigValue $raw @('DebugLogging')) $false
        JsonVersion              = [string](Get-ConfigValue $raw @('ConfigVersion', 'JsonVer') '')
        Problems                 = $problems
        BrowserSignature         = ''
    }
    if ($cfg.WhiteLowPercent -ge $cfg.WhiteHighPercent) {
        $problems.Add(("WhiteLowPercent ({0}) is not below WhiteHighPercent ({1}); using 10 and 85." -f $cfg.WhiteLowPercent, $cfg.WhiteHighPercent))
        $cfg.WhiteLowPercent = 10
        $cfg.WhiteHighPercent = 85
    }
    foreach ($field in @('UserField', 'PasswordField', 'SubmitButtonId')) {
        if ($cfg.$field -notmatch '^[A-Za-z0-9_.:-]+$') {
            $problems.Add("$field '$($cfg.$field)' has characters a form field name does not; using the default.")
            $cfg.$field = @{ UserField = 'j_username'; PasswordField = 'j_password'; SubmitButtonId = 'login-submit' }[$field]
        }
    }

    # Anything that needs a new Edge when it changes. Everything else in the
    # file applies on the next tick.
    $cfg.BrowserSignature = (@(
            $cfg.DisplayUrl, $cfg.BrowserMode, $cfg.InPrivate, $cfg.FullScreenWindow, $cfg.UsePrimaryScreen, $cfg.ScreenNumber,
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

function Write-JsonFile {
    param([string]$Path, $Object)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Object -Depth 6), $Utf8NoBom)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Initialize-Status {
    param($Config)
    $script:Status = [ordered]@{
        Host               = $ComputerName
        Instance           = $Instance
        LauncherVersion    = $LauncherVersion
        WindowsUser        = "$env:USERDOMAIN\$env:USERNAME"
        Pid                = $PID
        StartedUtc         = [DateTime]::UtcNow.ToString('o')
        State              = 'STARTING'
        StateSinceUtc      = [DateTime]::UtcNow.ToString('o')
        Detail             = ''
        DisplayUrl         = $Config.DisplayUrl
        UserName           = $Config.UserName
        CurrentUrl         = ''
        Supervised         = $true
        Watchdog           = $false
        LoopGuard          = ''
        PageWhitePercent   = $null
        ScreenWhitePercent = $null
        ProblemSinceUtc    = ''
        ProblemClass       = ''
        EdgeVersion        = ''
        BrowserPid         = 0
        BrowserStarts      = 0
        Reloads            = 0
        SignIns            = 0
        PcRestarts         = 0
        OldLauncherStops   = 0
        PcBootUtc          = ''
        LastShownUtc       = ''
        LastReloadUtc      = ''
        LastError          = ''
        UpdatedUtc         = ''
    }
}

function Set-State {
    param([Parameter(Mandatory)][string]$State, [string]$Detail = '')
    if ($script:Status.State -ne $State -or $script:Status.Detail -ne $Detail) {
        if ($script:Status.State -ne $State) {
            $level = if ($State -in @('SIGNIN_BLOCKED', 'ERROR')) { 'ERROR' } elseif ($State -in @('RECOVERING', 'WAITING_DISPLAY', 'RESTARTING_PC')) { 'WARN' } else { 'INFO' }
            $suffix = if ($Detail) { ": $Detail" } else { '' }
            Write-Log ("State {0} -> {1}{2}" -f $script:Status.State, $State, $suffix) $level
            Write-WdLog ("Launcher {0} -> {1}{2}" -f $script:Status.State, $State, $suffix) $(if ($level -eq 'ERROR') { 'ERROR' } elseif ($level -eq 'WARN') { 'WARN' } else { 'INFO' })
            $script:Status.StateSinceUtc = [DateTime]::UtcNow.ToString('o')
        }
        $script:Status.State = $State
        $script:Status.Detail = $Detail
    }
    if ($State -eq 'SHOWING') { $script:Status.LastShownUtc = [DateTime]::UtcNow.ToString('o') }
}

function Save-Status {
    $script:Status.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
    try { Write-JsonFile -Path (Join-Path $script:StatusDir "$Instance.status.json") -Object $script:Status }
    catch { Write-Log "Cannot write the status file: $($_.Exception.Message)" 'DEBUG' }
}

function Read-PersistentState {
    $p = Join-Path $script:StatusDir "$Instance.state.json"
    $script:PersistentState = @{}
    if (-not (Test-Path -LiteralPath $p)) { return }
    try {
        $o = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($p))
        foreach ($prop in $o.PSObject.Properties) { $script:PersistentState[$prop.Name] = $prop.Value }
    }
    catch { Write-Log "Ignoring an unreadable state file: $($_.Exception.Message)" 'WARN' }
}

function Save-PersistentState {
    try { Write-JsonFile -Path (Join-Path $script:StatusDir "$Instance.state.json") -Object $script:PersistentState }
    catch { Write-Log "Cannot write the state file: $($_.Exception.Message)" 'WARN' }
}

# ---------------------------------------------------------------------------
# Sign-in password (DPAPI, current Windows account)
# ---------------------------------------------------------------------------
$PasswordEntropy = [Text.Encoding]::UTF8.GetBytes('Mach2LauncherNG.SignIn.v1')
$SeedPath = Join-Path $Here 'password.seed'

function Save-SignInPassword {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Password, [string]$UserName)

    $plain = [Text.Encoding]::UTF8.GetBytes($Password)
    try { $enc = [Security.Cryptography.ProtectedData]::Protect($plain, $PasswordEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }

    Write-JsonFile -Path $Path -Object ([ordered]@{
            Format       = 'Mach2LauncherNG-DPAPI-CurrentUser-1'
            Note         = 'Encrypted for WindowsUser on ComputerName. Nobody else can read it. Replace it with password.seed or Mach2LauncherNG.ps1 -SetPassword.'
            WindowsUser  = "$env:USERDOMAIN\$env:USERNAME"
            ComputerName = $ComputerName
            SignInUser   = $UserName
            SavedUtc     = [DateTime]::UtcNow.ToString('o')
            Data         = [Convert]::ToBase64String($enc)
        })
}

function Read-SignInPassword {
    param([Parameter(Mandatory)][string]$Path)
    $doc = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
    $enc = [Convert]::FromBase64String([string]$doc.Data)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($enc, $PasswordEntropy, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    try { return [Text.Encoding]::UTF8.GetString($plain) }
    finally { [Array]::Clear($plain, 0, $plain.Length) }
}

function Import-PasswordSeed {
    # password.seed is how a password reaches the kiosk without anyone
    # typing it there: the deploy script (or a person) drops it, the
    # launcher encrypts it for the kiosk account and deletes it.
    param([Parameter(Mandatory)]$Config)

    if (-not (Test-Path -LiteralPath $SeedPath)) { return $false }
    try {
        $pw = ([IO.File]::ReadAllText($SeedPath) -split "`r?`n")[0]
        if (-not $pw) { throw 'the file is empty' }

        Save-SignInPassword -Path $Config.CredentialFile -Password $pw -UserName $Config.UserName
        if ((Read-SignInPassword -Path $Config.CredentialFile) -cne $pw) { throw 'the encrypted copy did not read back the same' }

        # Overwritten before it is deleted, so the plain text is not left in
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

function Invoke-SetPassword {
    param($Config)

    $user = if ($Config -and $Config.UserName) { $Config.UserName } else { '(UserName not set in the config)' }
    $file = if ($Config) { $Config.CredentialFile } else { Join-Path $Here "$ComputerName.cred" }
    Write-Host ''
    Write-Host "Mach2 user       : $user"
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

    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $un = if ($Config) { $Config.UserName } else { '' }
    Save-SignInPassword -Path $file -Password $pa -UserName $un
    if ((Read-SignInPassword -Path $file) -cne $pa) { Write-Host 'Saved, but it did not read back the same.' -ForegroundColor Red; return 1 }
    Write-Host 'Saved. A running launcher picks it up on its next sign-in.' -ForegroundColor Green
    return 0
}

# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------
function Get-Monitors {
    if ($script:NativeReady) {
        return @([Mach2LauncherNGNative.Api]::GetMonitors() | ForEach-Object {
                $f = $_ -split '\|'
                [pscustomobject]@{ Device = $f[0]; X = [int]$f[1]; Y = [int]$f[2]; Width = [int]$f[3]; Height = [int]$f[4]; Primary = ($f[5] -eq '1') }
            })
    }
    Add-Type -AssemblyName System.Windows.Forms
    return @([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            [pscustomobject]@{ Device = $_.DeviceName; X = $_.Bounds.X; Y = $_.Bounds.Y; Width = $_.Bounds.Width; Height = $_.Bounds.Height; Primary = $_.Primary }
        })
}

function Get-TargetScreen {
    <#
        The monitor Edge goes on. ScreenSelect = n means \\.\DISPLAYn exactly.
        A TV that is still powering up is waited for; after that the primary
        screen is used, so the dashboard shows somewhere.
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

function Move-CursorAside {
    # Nobody uses these screens: the pointer goes to the top right corner of
    # the kiosk screen, where it covers nothing and shows no tooltip.
    param($Screen)
    if (-not $script:NativeReady -or -not $Screen) { return }
    try { [void][Mach2LauncherNGNative.Api]::SetCursorPos($Screen.X + $Screen.Width - 1, $Screen.Y) } catch {}
}

# ---------------------------------------------------------------------------
# White and dark readings
#
# The watchdog's measure: the share of sampled pixels brighter than
# WhitePixelLevel (235) in all three channels. At or above WhiteHighPercent
# (85) the screen is white; below WhiteLowPercent (10) it is dark - black,
# or the desktop. A working Mach2 dashboard reads about 72%.
#
# Two readings: the page, from a DevTools screenshot (what Edge draws, even
# under another window), and the screen, from the display itself (what
# people see - the watchdog's reading).
# ---------------------------------------------------------------------------
function Measure-BitmapWhite {
    param([Parameter(Mandatory)][Drawing.Bitmap]$Bitmap, [int]$Step, [int]$Level)

    $rect = New-Object Drawing.Rectangle 0, 0, $Bitmap.Width, $Bitmap.Height
    $data = $Bitmap.LockBits($rect, [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $bytes = New-Object byte[] ($stride * $Bitmap.Height)
        [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)
    }
    finally { $Bitmap.UnlockBits($data) }

    if ($script:NativeReady) {
        $p = [Mach2LauncherNGNative.Api]::WhitePercent($bytes, $Bitmap.Width, $Bitmap.Height, $stride, $Step, $Level)
        if ($p -lt 0) { return $null }
        return $p
    }
    $white = 0; $total = 0
    for ($y = 0; $y -lt $Bitmap.Height; $y += $Step) {
        $row = $y * $stride
        for ($x = 0; $x -lt $Bitmap.Width; $x += $Step) {
            # Format32bppArgb is BGRA in memory.
            $i = $row + ($x * 4)
            $total++
            if ($bytes[$i] -gt $Level -and $bytes[$i + 1] -gt $Level -and $bytes[$i + 2] -gt $Level) { $white++ }
        }
    }
    if ($total -eq 0) { return $null }
    return (100.0 * $white / $total)
}

function Get-ScreenWhitePercent {
    # The kiosk screen as people see it - the old watchdog's photograph,
    # same pixels (every 20th in both directions), same answer.
    param([Parameter(Mandatory)]$Screen, [int]$Level = 235)

    $bitmap = $null; $graphics = $null
    try {
        if ($Screen.Width -le 0 -or $Screen.Height -le 0) { return [pscustomobject]@{ Percent = $null; Error = 'screen bounds are zero-sized' } }
        $bitmap = New-Object Drawing.Bitmap $Screen.Width, $Screen.Height
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($Screen.X, $Screen.Y, 0, 0, $bitmap.Size)
        return [pscustomobject]@{ Percent = (Measure-BitmapWhite -Bitmap $bitmap -Step 20 -Level $Level); Error = $null }
    }
    catch { return [pscustomobject]@{ Percent = $null; Error = $_.Exception.Message } }
    finally {
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap) { $bitmap.Dispose() }
    }
}

function Get-PageWhitePercent {
    # The page as Edge draws it, from a small DevTools screenshot of the
    # visible part. $null when there is no reading to be had.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$St)

    if (-not $St.screen) { return $null }
    $w = [double]$St.screen.iw; $h = [double]$St.screen.ih
    if ($w -lt 50 -or $h -lt 50) { return $null }
    # No clip and no scale: Edge then copies what is already on the screen.
    # With clip.scale (0.25 here once) it redraws the page at that size to
    # take the picture, and a kiosk showed that for a few frames - the
    # dashboard shrunk into the top-left corner, the rest dark - every so
    # often (SHCZ5KPI11857, 24 Sep 2026). The full-size picture is sampled
    # every 8th pixel instead, about as many as every 2nd at 480 wide.
    $shot = Invoke-Cdp -Config $Config -Method 'Page.captureScreenshot' -Params @{ format = 'png' } -TimeoutSec 20
    [byte[]]$png = [Convert]::FromBase64String([string]$shot.data)
    $ms = New-Object IO.MemoryStream(, $png)
    $bmp = $null
    try {
        $bmp = New-Object Drawing.Bitmap($ms)
        $step = [math]::Max(2, [int][math]::Round($bmp.Width / 240.0))
        return (Measure-BitmapWhite -Bitmap $bmp -Step $step -Level $Config.WhitePixelLevel)
    }
    finally {
        if ($bmp) { $bmp.Dispose() }
        $ms.Dispose()
    }
}

function Get-ReadingKind {
    # WHITE, LOWWHITE or '' (normal) for a reading; the watchdog's names.
    param($Percent, [Parameter(Mandatory)]$Config)
    if ($null -eq $Percent) { return '' }
    if ([double]$Percent -ge $Config.WhiteHighPercent) { return 'WHITE' }
    if ([double]$Percent -lt $Config.WhiteLowPercent) { return 'LOWWHITE' }
    return ''
}

# ---------------------------------------------------------------------------
# Edge
# ---------------------------------------------------------------------------
$script:EdgePath = ''
$script:Supervised = $true
$script:UnsupervisedWhy = ''

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

function Get-RemoteDebuggingPolicy {
    # Edge's RemoteDebuggingAllowed policy. Disabled means no DevTools port:
    # the launcher can then only keep Edge open (and the screen checks and
    # restarts still work).
    foreach ($key in @('HKLM:\SOFTWARE\Policies\Microsoft\Edge', 'HKCU:\SOFTWARE\Policies\Microsoft\Edge')) {
        try {
            $v = (Get-Item -LiteralPath $key -ErrorAction Stop).GetValue('RemoteDebuggingAllowed')
            if ($null -ne $v -and [int]$v -eq 0) { return $key }
        }
        catch {}
    }
    return $null
}

function Get-ProfileBrowserProcesses {
    param([Parameter(Mandatory)][string]$ProfileDir)
    # The whole directory name, so Profile-S1 does not also match Profile-S10.
    $pattern = [regex]::Escape($ProfileDir) + '(?:"|\\?\s|\\?$)'
    return @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'msedge.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine -match $pattern })
}

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

function Initialize-Profile {
    <#
        A profile of the launcher's own. A new one starts with the pop-ups a
        wall screen can do without switched off (save password, translate,
        first run); every start marks the last session as ended cleanly, so a
        killed Edge does not come back with a "Restore pages?" bubble.
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

function ConvertTo-ArgumentString {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object {
                if ($_ -match '^(--[^=]+=)(.*\s.*)$' -and $_ -notmatch '"') { '{0}"{1}"' -f $Matches[1], $Matches[2] }
                elseif ($_ -match '\s' -and $_ -notmatch '"') { '"{0}"' -f $_ }
                else { $_ }
            }) -join ' ')
}

function Start-Browser {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Reason)

    Disconnect-Cdp
    Stop-ProfileBrowsers -ProfileDir $Config.ProfileDir
    Initialize-Profile -ProfileDir $Config.ProfileDir

    $screen = Get-TargetScreen -Config $Config -WaitSeconds 0 -Quiet:($Reason -ne 'startup')
    $script:Session.Screen = $screen
    $url = $Config.DisplayUrl

    $portFile = Join-Path $Config.ProfileDir 'DevToolsActivePort'
    if (Test-Path -LiteralPath $portFile) { Remove-Item -LiteralPath $portFile -Force -ErrorAction SilentlyContinue }

    $a = New-Object System.Collections.Generic.List[string]
    $a.Add("--user-data-dir=`"$($Config.ProfileDir)`"")
    if ($script:Supervised) {
        # Port 0: Edge picks a free port and writes it to DevToolsActivePort,
        # so two launchers (two screens) never collide. 127.0.0.1 only.
        $a.Add("--remote-debugging-port=$($Config.DebugPort)")
    }
    # Nobody uses these screens: no sign-in to Edge, no sync dialog, no
    # translate bar, no swipe-back or pinch zoom from a stray touch.
    foreach ($x in @('--no-first-run', '--no-default-browser-check', '--hide-crash-restore-bubble', '--noerrdialogs',
            '--disable-sync', '--disable-pinch', '--overscroll-history-navigation=0',
            '--disable-features=Translate,msImplicitSignin,TouchpadOverscrollHistoryNavigation')) { $a.Add($x) }
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
            $a.Add('--kiosk')
            $a.Add('--edge-kiosk-type=fullscreen')
            $a.Add($url)
        }
        else {
            if ($Config.FullScreenWindow) { $a.Add('--start-fullscreen') }
            $a.Add("--app=`"$url`"")
        }
    }
    if ($Config.InPrivate -and $Config.BrowserMode -ne 'kiosk') { $a.Add('--inprivate') }
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
            if (@(Get-ProfileBrowserProcesses -ProfileDir $Config.ProfileDir).Count -gt 0) {
                throw 'Edge started but did not open its DevTools port within 45 s. Is remote debugging blocked by policy (RemoteDebuggingAllowed)?'
            }
            throw 'Edge exited straight after starting.'
        }
    }

    $script:Browser = $browser
    $script:Status.BrowserStarts++
    $script:Status.BrowserPid = $proc.Id
    $script:Session.BrowserHung = 0
    $script:Session.StrayPages.Clear()
    if ($Reason -ne 'startup') { $script:Session.Relaunches.Add([DateTime]::UtcNow) }

    if ($script:Supervised) {
        try {
            $v = ConvertFrom-Json -InputObject (Invoke-CdpHttp -Path '/json/version')
            $script:Status.EdgeVersion = [string]$v.Browser
        }
        catch {}
        Connect-Cdp -Config $Config
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

function Stop-Browser {
    param([Parameter(Mandatory)]$Config, [string]$Why = '')
    Disconnect-Cdp
    if ($Why) { Write-Log "Closing Edge: $Why" }
    Stop-ProfileBrowsers -ProfileDir $Config.ProfileDir
    $script:Browser = $null
    $script:Status.BrowserPid = 0
}

function Restart-Browser {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)
    Write-Log "Restarting Edge: $Why" 'WARN'
    Set-State 'RECOVERING' "restarting Edge: $Why"
    $script:Browser = $null
    try { Start-Browser -Config $Config -Reason $Why }
    catch { Register-LaunchFailure -ErrorRecord $_ }
}

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
    Set-Problem -Class 'local' -Why "Edge will not start: $text"
    $script:Browser = $null
}

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

function Restore-BrowserWindow {
    <#
        The page is fine but the screen does not show it: something covers
        Edge, or its window left full screen or was minimised. Brings the
        window back to full screen and to the front. Returns what it did.
    #>
    param([Parameter(Mandatory)]$Config)
    $done = @()
    try {
        $w = Invoke-Cdp -Config $Config -Method 'Browser.getWindowForTarget' -Params @{ targetId = $script:Cdp.TargetId }
        $state = [string]$w.bounds.windowState
        $want = if ($Config.FullScreenWindow -or $Config.BrowserMode -eq 'kiosk') { 'fullscreen' } else { 'normal' }
        if ($state -ne $want) {
            # A minimised window has to become normal before anything else.
            if ($state -ne 'normal') { $null = Invoke-Cdp -Config $Config -Method 'Browser.setWindowBounds' -Params @{ windowId = $w.windowId; bounds = @{ windowState = 'normal' } } }
            if ($want -ne 'normal') { $null = Invoke-Cdp -Config $Config -Method 'Browser.setWindowBounds' -Params @{ windowId = $w.windowId; bounds = @{ windowState = $want } } }
            $done += "window $state -> $want"
        }
    }
    catch { $done += "window state unknown ($(Get-ErrorText $_))" }
    try {
        $null = Invoke-Cdp -Config $Config -Method 'Page.bringToFront'
        $done += 'brought to front'
    }
    catch {}
    if ($Config.ParkMouse -and -not $Headless -and $script:Session.Screen) { Move-CursorAside -Screen $script:Session.Screen }
    return ($done -join ', ')
}

# ---------------------------------------------------------------------------
# DevTools protocol
# ---------------------------------------------------------------------------
$script:Browser = $null
$script:Cdp = $null

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

function Disconnect-Cdp {
    if (-not $script:Cdp) { return }
    try { $script:Cdp.Socket.Abort() } catch {}
    try { $script:Cdp.Socket.Dispose() } catch {}
    $script:Cdp = $null
}

function Get-PageTargets {
    $parsed = ConvertFrom-Json -InputObject (Invoke-CdpHttp -Path '/json/list')
    return @(@($parsed) | Where-Object { $_.type -eq 'page' -and ([string]$_.url) -notlike 'devtools://*' })
}

function Connect-Cdp {
    <#
        Connects to the kiosk page: the dashboard if it is there, else any
        web page, and an Edge-internal page only if there is nothing else.
        The target list is a snapshot - a page can be gone a second later -
        so a failed connection is retried on a fresh list.
    #>
    param([Parameter(Mandatory)]$Config)

    Disconnect-Cdp
    $lastError = ''
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $pages = @(Get-PageTargets)
        if ($pages.Count -eq 0) {
            $created = ConvertFrom-Json -InputObject (Invoke-CdpHttp -Path '/json/new?about:blank' -Method PUT)
            $pages = @($created)
            Write-Log 'Edge had no page open; opened a new one.' 'WARN'
        }
        $web = @($pages | Where-Object { ([string]$_.url) -notmatch '^(edge|chrome|chrome-extension)://' })
        $page = @($pages | Where-Object { Test-IsTargetUrl -Current ([string]$_.url) -Target $Config.DisplayUrl }) + $web + $pages | Select-Object -First 1

        $ws = New-Object Net.WebSockets.ClientWebSocket
        $ws.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
        try { $ws.Options.Proxy = $null } catch {}
        try {
            $task = $ws.ConnectAsync([Uri]([string]$page.webSocketDebuggerUrl), [Threading.CancellationToken]::None)
            if (-not $task.Wait(10000)) { throw 'timed out' }
            $script:Cdp = [pscustomobject]@{ Socket = $ws; NextId = 0; TargetId = [string]$page.id; Buffer = (New-Object byte[] 65536) }
            Write-Log ("Connected to page {0} ({1})." -f $page.id, $page.url) 'DEBUG'
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

function Close-StrayPages {
    <#
        Any page besides the kiosk's own is closed: nobody uses these
        screens, so a second window is something the dashboard or a stray
        touch opened, and it would cover the dashboard. A blank one is given
        ten seconds (it may be filled in), anything else five. A page is
        only closed once it has been seen twice, never on a snapshot taken
        mid-navigation.
    #>

    $s = $script:Session
    if (-not $script:Cdp) { return }
    $others = @(Get-PageTargets | Where-Object { [string]$_.id -ne $script:Cdp.TargetId })
    if ($others.Count -eq 0) { $s.StrayPages.Clear(); return }

    $now = [DateTime]::UtcNow
    $seen = @{}
    foreach ($p in $others) {
        $id = [string]$p.id
        $seen[$id] = $true
        if (-not $s.StrayPages.ContainsKey($id)) { $s.StrayPages[$id] = $now; continue }
        $age = ($now - [DateTime]$s.StrayPages[$id]).TotalSeconds
        $url = [string]$p.url
        $limit = if (-not $url -or $url -eq 'about:blank') { 10 } else { 5 }
        if ($age -lt $limit) { continue }
        try { $null = Invoke-CdpHttp -Path ('/json/close/' + $id) } catch {}
        $s.StrayPages.Remove($id)
        Write-Log ("Closed an extra window: {0}" -f $(if ($url) { $url } else { '(blank)' })) 'WARN'
    }
    foreach ($id in @($s.StrayPages.Keys)) { if (-not $seen.ContainsKey($id)) { $s.StrayPages.Remove($id) } }
}

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

function Invoke-Cdp {
    <#
        One DevTools command, one answer. A protocol error (the page refused)
        is thrown as it is and the connection kept. A transport failure
        (timeout, closed socket) also drops the connection: a WebSocket with
        an abandoned receive cannot be used again; the next call reconnects.
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

# The page-side half: finding the station's sign-in fields and reading the
# page. Injected with every call, because each navigation starts a fresh
# window object. Runs through DevTools, so the station's Content Security
# Policy does not apply to it.
$PageHelperJs = @'
(function () {
  if (window.__m2ng) return;
  var P = {};
  // Visible to a person: a real size, on the page, not transparent or
  // aria-hidden anywhere up the tree. The password only ever goes into a
  // field that passes this.
  P.vis = function (el) {
    if (!el || !el.getBoundingClientRect) return false;
    var r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return false;
    if (r.right <= 0 || r.bottom <= 0) return false;
    if (el.tagName === 'INPUT' && (el.type === 'hidden' || el.tabIndex < 0)) return false;
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
  P.q = function (s) { return String(s).replace(/["\\]/g, '\\$&'); };
  P.find = function (kind, o) {
    switch (kind) {
      case 'user': return P.first('input[name="' + P.q(o.userField) + '"]');
      case 'pass': return P.first('input[name="' + P.q(o.passField) + '"]') || P.first('input[type="password"]');
      case 'submit': return (o.submitId ? P.first('[id="' + P.q(o.submitId) + '"]') : null) || P.first('input[type="submit"]') || P.first('button[type="submit"]');
    }
    return null;
  };
  P.rect = function (kind, o) {
    var el = P.find(kind, o);
    if (!el) return null;
    if (el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'center' });
    var r = el.getBoundingClientRect();
    return { x: r.left + r.width / 2, y: r.top + r.height / 2 };
  };
  P.focus = function (kind, o) {
    var el = P.find(kind, o);
    if (!el) return false;
    el.focus();
    if (el.value) {
      el.value = '';
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    return document.activeElement === el;
  };
  P.valueLength = function (kind, o) {
    var el = P.find(kind, o);
    return (el && typeof el.value === 'string') ? el.value.length : -1;
  };
  P.state = function (o) {
    var body = document.body;
    var t = (body && (body.innerText || '')) || '';
    var low = t.toLowerCase();
    var host = location.hostname.toLowerCase();
    var s = {
      url: location.href, host: host, proto: location.protocol, path: location.pathname, title: document.title,
      ready: document.readyState, textLen: t.length, elements: body ? body.getElementsByTagName('*').length : 0,
      loginHost: o.loginHosts.indexOf(host) >= 0, onLogin: false,
      user: false, userLocked: false, userValue: '', pass: false, submit: false, loginForm: false,
      loginError: '', loginCause: '', errors: [], screen: null
    };
    var u = P.find('user', o);
    var any = document.querySelector('input[name="' + P.q(o.userField) + '"]');
    s.user = !!u && !u.readOnly && !u.disabled;
    s.userLocked = !!u && (u.readOnly || u.disabled);
    s.userValue = u ? (u.value || '') : (any ? (any.value || '') : '');
    s.pass = !!P.find('pass', o);
    s.submit = !!P.find('submit', o);
    s.loginForm = !!document.querySelector('#main-login-form, #login-form, form[action*="j_security_check"]');
    // Niagara shows a failed sign-in as ?auth=fail, and #login-failed.
    var f = document.getElementById('login-failed');
    if (f && P.vis(f)) s.loginError = (f.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 200) || 'Login Failed';
    if (!s.loginError && /[?&]auth=fail(&|$)/i.test(location.search)) s.loginError = 'Login Failed';
    var m = location.search.match(/[?&]loginFailureCause=([^&]+)/i);
    if (m) { try { s.loginCause = decodeURIComponent(m[1]); } catch (e) { s.loginCause = m[1]; } }
    s.onLogin = s.loginHost && (s.user || s.pass || s.loginForm || /^\/(pre)?login(\/|$)/i.test(location.pathname));
    for (var i = 0; i < o.phrases.length; i++) {
      if (o.phrases[i] && low.indexOf(o.phrases[i].toLowerCase()) >= 0) s.errors.push(o.phrases[i]);
    }
    s.screen = { x: window.screenX, y: window.screenY, w: screen.width, h: screen.height, iw: window.innerWidth, ih: window.innerHeight,
      sx: window.scrollX || 0, sy: window.scrollY || 0, dpr: window.devicePixelRatio };
    return s;
  };
  window.__m2ng = P;
})();
'@

function ConvertTo-JsLiteral {
    param($Value)
    if ($null -eq $Value) { return 'null' }
    return (ConvertTo-Json -InputObject $Value -Compress -Depth 5)
}

function Get-PageOptions {
    param([Parameter(Mandatory)]$Config)
    return (ConvertTo-JsLiteral ([ordered]@{
                userField  = $Config.UserField
                passField  = $Config.PasswordField
                submitId   = $Config.SubmitButtonId
                loginHosts = @($Config.LoginHosts)
                phrases    = @($Config.ErrorPhrases)
            }))
}

function Invoke-PageJs {
    # Runs P.<something> in the page and returns its value, parsed.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Expression, [int]$TimeoutSec = 15)

    $full = $PageHelperJs + "`n;(function () { var P = window.__m2ng; return JSON.stringify($Expression); })()"
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

function Get-PageState {
    param([Parameter(Mandatory)]$Config)
    return (Invoke-PageJs -Config $Config -Expression ('P.state({0})' -f (Get-PageOptions -Config $Config)) -TimeoutSec $Config.PageReadTimeoutSeconds)
}

function Send-Click {
    # A real mouse click through Edge's input pipeline, as a person's.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Kind)

    $rect = Invoke-PageJs -Config $Config -Expression ('P.rect({0}, {1})' -f (ConvertTo-JsLiteral $Kind), (Get-PageOptions -Config $Config))
    if (-not $rect) { return $false }
    $x = [double]$rect.x; $y = [double]$rect.y
    foreach ($type in @('mouseMoved', 'mousePressed', 'mouseReleased')) {
        $p = @{ type = $type; x = $x; y = $y }
        if ($type -ne 'mouseMoved') { $p.button = 'left'; $p.clickCount = 1 }
        $null = Invoke-Cdp -Config $Config -Method 'Input.dispatchMouseEvent' -Params $p
    }
    # Move the synthetic pointer off the page again.
    try { $null = Invoke-Cdp -Config $Config -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseMoved'; x = 0; y = 0 } } catch {}
    return $true
}

function Send-Text {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Kind, [Parameter(Mandatory)][string]$Text)

    $opts = Get-PageOptions -Config $Config
    if (-not (Invoke-PageJs -Config $Config -Expression ('P.focus({0}, {1})' -f (ConvertTo-JsLiteral $Kind), $opts))) { return $false }
    $null = Invoke-Cdp -Config $Config -Method 'Input.insertText' -Params @{ text = $Text }
    $len = Invoke-PageJs -Config $Config -Expression ('P.valueLength({0}, {1})' -f (ConvertTo-JsLiteral $Kind), $opts)
    return ([int]$len -eq $Text.Length)
}

function Send-Key {
    param([Parameter(Mandatory)]$Config, [ValidateSet('Enter', 'Escape')][string]$Key)
    $code = if ($Key -eq 'Enter') { 13 } else { 27 }
    $down = @{ type = 'keyDown'; key = $Key; code = $Key; windowsVirtualKeyCode = $code; nativeVirtualKeyCode = $code }
    if ($Key -eq 'Enter') { $down.text = "`r" }
    $null = Invoke-Cdp -Config $Config -Method 'Input.dispatchKeyEvent' -Params $down
    $null = Invoke-Cdp -Config $Config -Method 'Input.dispatchKeyEvent' -Params @{ type = 'keyUp'; key = $Key; code = $Key; windowsVirtualKeyCode = $code; nativeVirtualKeyCode = $code }
}

function Submit-LoginForm {
    param([Parameter(Mandatory)]$Config)
    if (-not (Send-Click -Config $Config -Kind 'submit')) { Send-Key -Config $Config -Key Enter }
}

# ---------------------------------------------------------------------------
# The page
# ---------------------------------------------------------------------------
$script:Session = $null

function New-Session {
    return [pscustomobject]@{
        PageLoadedUtc          = [DateTime]::UtcNow
        NextIntervalRefreshUtc = [DateTime]::MaxValue
        TimedDone              = @{}
        ErrorStreak            = 0
        BadSinceUtc            = [DateTime]::MinValue
        CoveredSinceUtc        = [DateTime]::MinValue
        CoverFixes             = 0
        Recoveries             = 0
        LastRecoveryUtc        = [DateTime]::MinValue
        StrayPages             = @{}
        CdpFailures            = 0
        CdpSilentSinceUtc      = [DateTime]::MinValue
        CdpRefused             = 0
        BrowserHung            = 0
        LaunchFailures         = 0
        NextLaunchUtc          = [DateTime]::MinValue
        Relaunches             = (New-Object System.Collections.Generic.List[DateTime])
        NavigateStreak         = 0
        NextNavigateUtc        = [DateTime]::MinValue
        OffTargetSinceUtc      = [DateTime]::MinValue
        LoggedScreen           = $false
        Screen                 = $null
        PageWhite              = $null
        ScreenWhite            = $null
        ScreenErrors           = 0
        ProblemClass           = 'neutral'
        ProblemWhy             = ''
        Login                  = [pscustomobject]@{
            LastAction      = ''
            LastActionUtc   = [DateTime]::MinValue
            Repeats         = 0
            PasswordTimes   = (New-Object System.Collections.Generic.List[DateTime])
            BlockedUntilUtc = [DateTime]::MinValue
            BlockedReason   = ''
            RestartFlow     = $false
            SinceUtc        = [DateTime]::MinValue
            SignedInUtc     = [DateTime]::MinValue
            CredStamp       = ''
        }
        Wd                     = [pscustomobject]@{
            ProblemSinceUtc   = $null
            LocalSinceUtc     = $null
            LastLocalUtc      = $null
            ProblemTicks      = 0
            HealthySinceUtc   = $null
            HealthyResetDone  = $false
            RestartPendingUtc = $null
            HoldAnnounced     = $false
            GuardHolding      = $false
            WhiteEpisodeId    = $null
            WhiteEpisodeStart = $null
            WhiteEpisodePeak  = 0.0
            WhiteChecks       = 0
            LowEpisodeId      = $null
            LowEpisodeStart   = $null
            LowEpisodeTrough  = 100.0
            LowChecks         = 0
            LastHeartbeatUtc  = [DateTime]::MinValue
            LastEventScanUtc  = [DateTime]::MinValue
            LastOldCheckUtc   = [DateTime]::MinValue
        }
    }
}

function Set-Problem {
    <#
        What this tick found, for the watchdog: ok (dashboard on screen),
        local (something on this PC: Edge, the page drawing white or dark,
        a window over it - a restart may help), outage (the station or the
        network - a restart does not help at first), person (only someone at
        the kiosk can fix it), or neutral (on the way: loading, signing in).
    #>
    param([ValidateSet('ok', 'local', 'outage', 'person', 'neutral')][string]$Class, [string]$Why = '')
    $script:Session.ProblemClass = $Class
    $script:Session.ProblemWhy = $Why
}

function Reset-PageLoad {
    param([Parameter(Mandatory)]$Config)
    $s = $script:Session
    $now = [DateTime]::UtcNow
    $s.PageLoadedUtc = $now
    $s.ErrorStreak = 0
    $s.BadSinceUtc = [DateTime]::MinValue
    $s.NextIntervalRefreshUtc = if ($Config.RefreshMinutes -gt 0) { $now.AddMinutes($Config.RefreshMinutes) } else { [DateTime]::MaxValue }
}

function Test-IsTargetUrl {
    <#
        Is the page on the configured dashboard? Same host and path (both
        compared without regard to case, and the path unescaped); the
        scheme, port and fragment are left out, so a station that moves the
        page to HTTPS does not look like somewhere else. Query parameters in
        the configured address must be there with the same values.
    #>
    param([string]$Current, [string]$Target)

    $c = $null; $t = $null
    if (-not [Uri]::TryCreate($Current, [UriKind]::Absolute, [ref]$c)) { return $false }
    if (-not [Uri]::TryCreate($Target, [UriKind]::Absolute, [ref]$t)) { return $false }
    if ($c.Host -ne $t.Host) { return $false }
    $cp = [Uri]::UnescapeDataString($c.AbsolutePath).TrimEnd('/')
    $tp = [Uri]::UnescapeDataString($t.AbsolutePath).TrimEnd('/')
    if (-not [string]::Equals($cp, $tp, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($t.Query) {
        $tq = [Web.HttpUtility]::ParseQueryString($t.Query)
        $cq = [Web.HttpUtility]::ParseQueryString($c.Query)
        foreach ($k in $tq.AllKeys) {
            if (-not $k) { continue }
            if (-not [string]::Equals([string]$tq[$k], [string]$cq[$k], [StringComparison]::OrdinalIgnoreCase)) { return $false }
        }
    }
    return $true
}

function Open-Url {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$What)
    $r = Invoke-Cdp -Config $Config -Method 'Page.navigate' -Params @{ url = $Url } -TimeoutSec 30
    $errText = $r.PSObject.Properties['errorText']
    if ($errText -and $errText.Value) { Write-Log ("Edge could not open {0}: {1}" -f $What, $errText.Value) 'WARN' }
    Reset-PageLoad -Config $Config
}

function Open-Target {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)
    Write-Log "Opening the dashboard ($Why)."
    Open-Url -Config $Config -Url $Config.DisplayUrl -What 'the dashboard'
}

function Open-LoginStart {
    # A fresh sign-in: the station's own login address (prelogin?clear=true
    # forgets the user name it remembered), else the dashboard, which the
    # station sends to its sign-in.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)
    if ($Config.LoginUrl) {
        Write-Log "Opening the sign-in page ($Why)."
        Open-Url -Config $Config -Url $Config.LoginUrl -What 'the sign-in page'
    }
    else { Open-Target -Config $Config -Why $Why }
}

function Invoke-Reload {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)
    Write-Log "Reloading the dashboard ($Why)."
    try { $null = Invoke-Cdp -Config $Config -Method 'Page.reload' -Params @{ ignoreCache = $true } -TimeoutSec 30 }
    catch {
        Write-Log ("Reload failed ({0}); opening the dashboard instead." -f (Get-ErrorText $_)) 'WARN'
        Open-Target -Config $Config -Why $Why
    }
    $script:Status.Reloads++
    $script:Status.LastReloadUtc = [DateTime]::UtcNow.ToString('o')
    Reset-PageLoad -Config $Config
}

function Invoke-Recovery {
    <#
        The dashboard is on the page but not right. Reload; every
        (MaxReloadsBeforeRelaunch + 1)-th step starts a new Edge instead.
        The pause before each step grows (0, 1, 2, 5, 10, then 15 min), so a
        station outage costs a reload now and then, not a reload loop. If
        none of this helps, the watchdog restarts the PC (RebootAfterMinutes).
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Why)

    $s = $script:Session
    $waits = @(0, 1, 2, 5, 10, 15)
    $due = $s.LastRecoveryUtc.AddMinutes($waits[[math]::Min($s.Recoveries, $waits.Count - 1)])
    if ([DateTime]::UtcNow -lt $due) {
        Set-State 'RECOVERING' ("{0}; next attempt at {1:HH:mm}" -f $Why, $due.ToLocalTime())
        return
    }

    $s.Recoveries++
    $s.LastRecoveryUtc = [DateTime]::UtcNow
    $script:Status.LastError = $Why
    Set-State 'RECOVERING' $Why
    if (($s.Recoveries % ($Config.MaxReloadsBeforeRelaunch + 1)) -eq 0) {
        Restart-Browser -Config $Config -Why "$Why (after $($Config.MaxReloadsBeforeRelaunch) reload(s))"
    }
    else {
        Invoke-Reload -Config $Config -Why $Why
    }
}

# ---------------------------------------------------------------------------
# Signing in to the station
# ---------------------------------------------------------------------------
function Set-LoginBlocked {
    param([Parameter(Mandatory)][string]$Reason, [Parameter(Mandatory)][double]$Minutes)
    $l = $script:Session.Login
    $l.BlockedUntilUtc = [DateTime]::UtcNow.AddMinutes($Minutes)
    $l.BlockedReason = $Reason
    $script:Status.LastError = $Reason
    Write-Log ("{0} Trying again at {1:HH:mm}." -f $Reason, $l.BlockedUntilUtc.ToLocalTime()) 'ERROR'
    Set-State 'SIGNIN_BLOCKED' $Reason
    Set-Problem -Class 'person' -Why $Reason
}

function Clear-LoginBlock {
    param([string]$Why)
    $l = $script:Session.Login
    if ($l.BlockedUntilUtc -gt [DateTime]::UtcNow) {
        Write-Log "Sign-in may be tried again: $Why"
        # The page still shows the station's last "Login Failed", which would
        # read as a fresh rejection. Start the sign-in again.
        $l.RestartFlow = $true
    }
    $l.BlockedUntilUtc = [DateTime]::MinValue
    $l.BlockedReason = ''
    $l.PasswordTimes.Clear()
    $l.Repeats = 0
    $l.LastAction = ''
}

function Invoke-LoginStep {
    <#
        One step of the station's sign-in, chosen from what the page shows.
        Niagara asks for the user name first (prelogin), then the password;
        a one-page form with both works too. Called every couple of seconds
        while a sign-in page is up.

        The password is only ever typed into a visible password field on the
        station's own host (LoginHosts). After the station rejects it,
        nothing is typed for LoginRetryMinutes, and never more than twice in
        that window whatever happens: Niagara locks an account out after a
        few failures.
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$St)

    $l = $script:Session.Login
    $now = [DateTime]::UtcNow
    if ($l.SinceUtc -eq [DateTime]::MinValue) { $l.SinceUtc = $now }
    Set-Problem -Class 'neutral' -Why 'signing in'

    if ($now -lt $l.BlockedUntilUtc) {
        Set-State 'SIGNIN_BLOCKED' $l.BlockedReason
        Set-Problem -Class 'person' -Why $l.BlockedReason
        return
    }
    if ($l.BlockedReason) {
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
        Open-LoginStart -Config $Config -Why 'starting the sign-in again'
        return
    }
    # Give the page time to react to the last step. After the password that
    # means SignInSettleSeconds, not three: on a slow station the form is
    # still on screen while it is being checked, and typing the password into
    # it again spends the second of two attempts for nothing.
    # A page already showing a rejection has answered, so there is nothing to
    # wait for: that is dealt with at once, as it always was.
    $settle = $(if ($l.LastAction -eq 'password' -and -not $St.loginError) { $Config.SignInSettleSeconds } else { 3 })
    if ($now -lt $l.LastActionUtc.AddSeconds($settle)) { return }

    # Nor is a page that is still loading ready to be acted on.
    if ($l.LastAction -eq 'password' -and [string]$St.ready -ne 'complete' -and
        $now -lt $l.LastActionUtc.AddSeconds($Config.SignInWaitSeconds)) {
        return
    }

    Set-State 'SIGNING_IN' ("sign-in page on {0}" -f $St.host)

    if ($St.loginError) {
        if ([string]$St.loginCause -match 'SECURE') {
            Set-LoginBlocked -Reason ("The station only accepts sign-in over HTTPS ({0}). Change DisplayURL and LoginURL to https://." -f $St.loginCause) -Minutes 60
            return
        }
        if ($l.LastAction -in @('password', 'user') -and $now -lt $l.LastActionUtc.AddMinutes(3)) {
            Set-LoginBlocked -Reason ("The station rejected the sign-in as {0} ('{1}'). Not retrying for {2} min so the account is not locked out - drop a new password.seed to retry now." -f $Config.UserName, ([string]$St.loginError).TrimEnd('.'), $Config.LoginRetryMinutes) -Minutes $Config.LoginRetryMinutes
            return
        }
        Write-Log ("The sign-in page shows: {0}" -f $St.loginError) 'DEBUG'
    }

    $action = ''
    $userWanted = $St.user -and -not [string]::Equals([string]$St.userValue, $Config.UserName, [StringComparison]::OrdinalIgnoreCase)
    if ($userWanted) {
        if (-not $Config.UserName) {
            Set-LoginBlocked -Reason 'The station asks for a user name, and UserName is not set in the config.' -Minutes 15
            return
        }
        if (Send-Text -Config $Config -Kind 'user' -Text $Config.UserName) {
            # Niagara's first page has only the user name; a one-page form
            # gets its password on the next step.
            if (-not $St.pass) { Submit-LoginForm -Config $Config }
            $action = 'user'
        }
    }
    elseif ($St.pass) {
        $problem = ''
        if (-not $St.loginHost) { $problem = "a password field on $($St.host), which is not the station (LoginHosts)" }
        elseif ($Config.RequireHttps -and $St.proto -ne 'https:') { $problem = 'a sign-in page that is not HTTPS (RequireHttps)' }
        if ($problem) {
            Write-Log "Not typing the password: $problem. Starting the sign-in over." 'WARN'
            $l.Repeats++
            if ($l.Repeats -ge 3) { Set-LoginBlocked -Reason "Sign-in keeps landing on $problem." -Minutes 15; return }
            Open-LoginStart -Config $Config -Why 'restart sign-in'
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
            Set-LoginBlocked -Reason 'The station asks for the password, and none is stored. Drop password.seed into the launcher''s instance folder, or run Mach2LauncherNG.ps1 -SetPassword as the kiosk account.' -Minutes 15
            return
        }
        try {
            if (Send-Text -Config $Config -Kind 'pass' -Text $pw) {
                $l.PasswordTimes.Add($now)
                Submit-LoginForm -Config $Config
                $action = 'password'
            }
        }
        finally { $pw = $null }
    }
    elseif ($St.user -or $St.userLocked) {
        # The user name is filled in and there is no password field yet.
        Submit-LoginForm -Config $Config
        $action = 'user-submit'
    }

    if ($action) {
        if ($action -eq $l.LastAction -and $now -lt $l.LastActionUtc.AddMinutes(2)) { $l.Repeats++ } else { $l.Repeats = 0 }
        $l.LastAction = $(if ($action -eq 'user-submit') { 'user' } else { $action })
        $l.LastActionUtc = $now
        $l.SinceUtc = $now
        $shown = switch ($action) {
            'user' { "entered user name $($Config.UserName)" }
            'password' { 'entered the password' }
            default { 'sent the user name' }
        }
        Write-Log "Sign-in: $shown."
        if ($l.Repeats -ge 4) { Set-LoginBlocked -Reason "Sign-in is going round in circles (step '$action' repeated)." -Minutes 15 }
        return
    }

    # Nothing to do on this page. After SignInWaitSeconds, start over.
    if ($now -gt $l.SinceUtc.AddSeconds($Config.SignInWaitSeconds)) {
        Write-Log ("Stuck on a sign-in page for {0}s ({1}); starting over." -f $Config.SignInWaitSeconds, $St.url) 'WARN'
        $l.SinceUtc = $now
        Open-LoginStart -Config $Config -Why 'sign-in stalled'
    }
}

# ---------------------------------------------------------------------------
# Watchdog: pending-restart confirmation
#
# The marker is written just before shutdown.exe. Finding one at startup
# means the previous run asked for a restart; the OS boot time says whether
# it happened (RESTART_CONFIRMED) or not (RESTART_FAILED).
# ---------------------------------------------------------------------------
function Resolve-PendingRestart {
    param([int]$GraceSeconds = 600)

    if (-not $script:WdOn -or -not (Test-Path -LiteralPath $script:PendingPath)) { return }
    $raw = $null
    try { $raw = Read-TextWithRetry -Path $script:PendingPath }
    catch {
        Write-WdLog 'Pending-restart marker could not be read yet; leaving it for the next start.' 'WARN'
        return
    }
    $marker = $null
    if ($raw) { try { $marker = ConvertFrom-Json -InputObject $raw } catch {} }
    if ($null -eq $marker) {
        Write-WdLog 'Pending-restart marker is empty or corrupt, discarding it.' 'WARN'
        Remove-Item -LiteralPath $script:PendingPath -Force -ErrorAction SilentlyContinue
        return
    }

    $triggeredUtc = $null; $markerBootUtc = $null
    try { $triggeredUtc = [datetime]::Parse([string]$marker.TriggeredUtc, $Invariant, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch {}
    try { $markerBootUtc = [datetime]::Parse([string]$marker.BootTimeUtc, $Invariant, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch {}
    if ($null -eq $triggeredUtc -or $null -eq $markerBootUtc) {
        Write-WdLog 'Pending-restart marker has no usable timestamps, discarding it.' 'WARN'
        Remove-Item -LiteralPath $script:PendingPath -Force -ErrorAction SilentlyContinue
        return
    }

    $currentBootUtc = $script:BootTimeUtc
    if ($null -ne $currentBootUtc -and $currentBootUtc -gt $markerBootUtc.AddSeconds(30)) {
        $downtime = ($currentBootUtc - $triggeredUtc).TotalSeconds
        $null = Write-EventRow -EventType 'RESTART_CONFIRMED' -Severity 'WARNING' -Outcome 'CONFIRMED' -DurationSeconds $downtime `
            -Detail ("Kind={0}; TriggerEventId={1}; reboot requested at {2} took effect, machine booted at {3}. Reason: {4}" -f `
                $marker.Kind, $marker.EventId, (Format-Utc $triggeredUtc), (Format-Utc $currentBootUtc), $marker.Reason)
        Write-WdLog ("Confirmed the reboot requested at {0} (down for {1:N0}s). Trigger event {2}." -f (Format-Utc $triggeredUtc), $downtime, $marker.EventId) 'WARN'
        Write-Log ("The restart asked for at {0:HH:mm} took effect (down for {1:N0} s)." -f $triggeredUtc.ToLocalTime(), $downtime) 'WARN'
        Remove-Item -LiteralPath $script:PendingPath -Force -ErrorAction SilentlyContinue
        return
    }

    # Same boot session: fine while shutdown.exe's own countdown may still
    # be running; a failure once it cannot be.
    $age = ([DateTime]::UtcNow - $triggeredUtc).TotalSeconds
    if ($age -lt $GraceSeconds) {
        Write-WdLog ("A restart requested {0:N1} minutes ago is still pending; leaving the marker in place." -f ($age / 60)) 'WARN'
        return
    }
    $null = Write-EventRow -EventType 'RESTART_FAILED' -Severity 'CRITICAL' -Outcome 'FAILED' -DurationSeconds $age `
        -Detail ("Kind={0}; TriggerEventId={1}; reboot requested at {2} never took effect - the machine has not booted since. Reason: {3}" -f `
            $marker.Kind, $marker.EventId, (Format-Utc $triggeredUtc), $marker.Reason)
    Write-WdLog ("Restart requested at {0} did NOT take effect - still on the same boot session {1:N0} minutes later." -f (Format-Utc $triggeredUtc), ($age / 60)) 'ERROR'
    Write-Log ("The restart asked for at {0:HH:mm} did not happen." -f $triggeredUtc.ToLocalTime()) 'ERROR'
    Remove-Item -LiteralPath $script:PendingPath -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# Watchdog: loop guard
#
# $script:LoopState.Restarts      restarts in a row not (yet) followed by a
#                                 healthy dashboard
# $script:LoopState.HoldReported  LOOP_GUARD_ENGAGED is in the ledger with
#                                 no LOOP_GUARD_RELEASED after it
# ---------------------------------------------------------------------------
$script:LoopState = [pscustomobject]@{ Restarts = @(); HoldReported = $false }

function Read-LoopGuardState {
    $state = [pscustomobject]@{ Restarts = @(); HoldReported = $false }
    if (-not (Test-Path -LiteralPath $script:LoopStatePath)) { return $state }
    try {
        $data = ConvertFrom-Json -InputObject (Read-TextWithRetry -Path $script:LoopStatePath)
        $state.HoldReported = [bool]$data.HoldReported
        $state.Restarts = @(@($data.Restarts) | ForEach-Object {
                if ($_ -is [datetime]) { $_.ToUniversalTime() }
                else { try { [datetime]::Parse([string]$_, $Invariant, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch {} }
            } | Where-Object { $_ } | Sort-Object)
    }
    catch { Write-WdLog "Loop-guard state could not be read, starting the count from zero: $($_.Exception.Message)" 'WARN' }
    return $state
}

function Save-LoopGuardState {
    # An empty state is a deleted file, not a file saying "nothing".
    try {
        if (@($script:LoopState.Restarts).Count -eq 0 -and -not $script:LoopState.HoldReported) {
            Remove-Item -LiteralPath $script:LoopStatePath -Force -ErrorAction SilentlyContinue
            return
        }
        $json = ConvertTo-Json -Compress -InputObject ([pscustomobject]@{
                HoldReported = $script:LoopState.HoldReported
                Restarts     = @(@($script:LoopState.Restarts) | ForEach-Object { Format-Utc $_ })
            })
        Write-DurableFile -Path $script:LoopStatePath -Text $json
    }
    catch { Write-WdLog "Could not save the loop-guard state: $($_.Exception.Message)" 'ERROR' }
}

function Test-LedgerHoldOpen {
    # Whether the ledger's last loop-guard row is LOOP_GUARD_ENGAGED. Asked
    # when the state file is gone (deleted by hand to reset the guard), so
    # the release is still recorded once the dashboard is back.
    if (-not (Test-Path -LiteralPath $script:LedgerPath)) { return $false }
    try {
        $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
        $fs = New-Object IO.FileStream($script:LedgerPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            [void]$fs.Seek([math]::Max([long]0, $fs.Length - 262144), [IO.SeekOrigin]::Begin)
            $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd()
        }
        finally { $fs.Dispose() }
        $last = $null
        foreach ($m in [regex]::Matches($text, ',"LOOP_GUARD_(ENGAGED|RELEASED)",')) { $last = $m.Groups[1].Value }
        return ($last -eq 'ENGAGED')
    }
    catch { return $false }
}

function Get-LoopGuardDecision {
    <#
        Allow  fewer than LoopGuardMaxRestarts unhelpful restarts in a row
        Retry  holding, but LoopGuardRetryMinutes have passed since the last
        Hold   do not restart
    #>
    param([Parameter(Mandatory)][datetime]$NowUtc, [Parameter(Mandatory)]$Config)

    $restarts = @($script:LoopState.Restarts)
    $last = if ($restarts.Count -gt 0) { $restarts[-1] } else { $null }
    # Before the guard holds, restarts far apart are not a loop. Once it
    # holds, only a healthy dashboard or the retry timer ends it.
    if ($restarts.Count -lt $Config.LoopGuardMaxRestarts -and $last -and ($NowUtc - $last).TotalMinutes -gt $Config.LoopGuardWindowMinutes) {
        $restarts = @(); $last = $null
    }
    $decision = [pscustomobject]@{
        Action       = 'Allow'
        Restarts     = $restarts
        Since        = $(if ($restarts.Count -gt 0) { $restarts[0] } else { $null })
        NextRetryUtc = $null
    }
    if ($restarts.Count -lt $Config.LoopGuardMaxRestarts) { return $decision }
    if ($Config.LoopGuardRetryMinutes -gt 0) { $decision.NextRetryUtc = $last.AddMinutes($Config.LoopGuardRetryMinutes) }
    $decision.Action = if ($decision.NextRetryUtc -and $NowUtc -ge $decision.NextRetryUtc) { 'Retry' } else { 'Hold' }
    return $decision
}

function Write-LoopGuardHold {
    param([Parameter(Mandatory)]$Decision, [Parameter(Mandatory)]$Config, [string]$Kind, $WhitePercent, [int]$StreakChecks, [string]$Why)

    $retry = if ($Decision.NextRetryUtc) { "next attempt after {0}" -f (Format-Utc $Decision.NextRetryUtc) } else { 'no automatic retry' }
    $text = ("Kind={0}; {1} restart(s) since {2} did not bring the dashboard back ({3}), so the PC is not restarted again; {4}. The launcher keeps reloading and restarting Edge. Released once the dashboard has been on screen for {5} min." -f `
            $Kind, @($Decision.Restarts).Count, (Format-Utc $Decision.Since), $Why, $retry, $Config.LoopGuardHealthyMinutes)
    $null = Write-EventRow -EventType 'LOOP_GUARD_ENGAGED' -Severity 'CRITICAL' -Outcome 'HOLD' -WhitePercent $WhitePercent -StreakChecks $StreakChecks -Detail $text -Durable
    Write-WdLog "Loop guard engaged. $text" 'ERROR'
    Write-Log "Loop guard engaged: $text" 'ERROR'
}

function Reset-LoopGuard {
    # The dashboard has been on screen for LoopGuardHealthyMinutes: whatever
    # restarts came before, they worked.
    param($WhitePercent, [Parameter(Mandatory)]$Config)

    if (@($script:LoopState.Restarts).Count -eq 0 -and -not $script:LoopState.HoldReported) { return }
    if ($script:LoopState.HoldReported) {
        $null = Write-EventRow -EventType 'LOOP_GUARD_RELEASED' -Severity 'INFO' -Outcome 'RECOVERED' -WhitePercent $WhitePercent `
            -Detail ("Dashboard on screen for {0} min after {1} unhelpful restart(s); the launcher restarts the PC again if the dashboard cannot be brought back." -f $Config.LoopGuardHealthyMinutes, @($script:LoopState.Restarts).Count) -Durable
        Write-WdLog "Loop guard released: the dashboard has been on screen for $($Config.LoopGuardHealthyMinutes) min." 'WARN'
        Write-Log 'Loop guard released.' 'WARN'
    }
    else {
        Write-WdLog ("The last restart helped: dashboard on screen for {0} min. Loop-guard count cleared." -f $Config.LoopGuardHealthyMinutes)
    }
    $script:LoopState.Restarts = @()
    $script:LoopState.HoldReported = $false
    Save-LoopGuardState
    $script:Session.Wd.HoldAnnounced = $false
    $script:Status.LoopGuard = ''
}

function Undo-LoopGuardRestart {
    # A restart that never happened is not part of a loop.
    $restarts = @($script:LoopState.Restarts)
    if ($restarts.Count -eq 0) { return }
    $script:LoopState.Restarts = @($restarts | Select-Object -First ($restarts.Count - 1))
    Save-LoopGuardState
}

# ---------------------------------------------------------------------------
# Watchdog: the restart
# ---------------------------------------------------------------------------
function Invoke-WatchdogRestart {
    <#
        The one path by which the watchdog restarts the PC. The order is the
        old watchdog's, and deliberate: ledger row first (flushed to disk),
        then the marker, then shutdown.exe. The loop-guard count is saved by
        the caller before this is called.

        The comment lands verbatim in Windows event 1074. "MWST-WATCHDOG
        <kind>" tells the collector the restart was the watchdog's, and
        id=<first 8 of the EventId> ties the event to the ledger row.
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('WHITE', 'LOWWHITE', 'BROWSER')][string]$Kind,
        [Parameter(Mandatory)][string]$Reason,
        [int]$StreakChecks,
        $WhitePercent,
        [double]$EpisodeSeconds,
        [string]$EpisodeId,
        [string]$Note
    )

    $eventId = [guid]::NewGuid().ToString()
    $shortId = $eventId.Substring(0, 8)
    # The Detail must keep starting with "<Kind>:" - the collector reads the
    # trigger from there.
    $detail = "{0}: {1}. EpisodeId={2}; Instance={3}" -f $Kind, $Reason, $EpisodeId, $Instance
    if ($Note) { $detail += "; $Note" }
    $null = Write-EventRow -EventId $eventId -EventType 'RESTART_TRIGGERED' -Severity 'CRITICAL' -Outcome 'REBOOT' `
        -WhitePercent $WhitePercent -StreakChecks $StreakChecks -DurationSeconds $EpisodeSeconds -Detail $detail -Durable

    try {
        Write-DurableFile -Path $script:PendingPath -Text (ConvertTo-Json -Compress -InputObject ([pscustomobject]@{
                    EventId      = $eventId
                    Kind         = $Kind
                    Reason       = $Reason
                    TriggeredUtc = Format-Utc (Get-Date)
                    BootTimeUtc  = Format-Utc $script:BootTimeUtc
                }))
    }
    catch { Write-WdLog "Could not write the pending-restart marker: $($_.Exception.Message)" 'ERROR' }

    $comment = "MWST-WATCHDOG $Kind id=$shortId - Mach2 Launcher ${LauncherVersion}: $Reason"
    if ($comment.Length -gt 500) { $comment = $comment.Substring(0, 500) }
    Write-WdLog ("Triggering restart ({0}). Event {1}. {2}{3}" -f $Kind, $eventId, $Reason, $(if ($Note) { ". $Note" } else { '' })) 'ERROR'
    Write-Log ("Restarting the PC ({0}): {1}. {2}" -f $Kind, $Reason, $Note) 'ERROR'

    if ($SimulateRestart) {
        Write-Log ("SimulateRestart: not running shutdown.exe /r /t 15 /f /c ""{0}""" -f $comment) 'WARN'
        Write-WdLog 'SimulateRestart: shutdown.exe was not run.' 'WARN'
        return $true
    }
    # Continue, not Stop: Windows PowerShell turns a native command's stderr
    # into terminating errors under Stop; the exit code is what matters.
    $ErrorActionPreference = 'Continue'
    $out = & "$env:SystemRoot\System32\shutdown.exe" /r /t 15 /f /c $comment 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        $why = "shutdown.exe exited with code {0}: {1}" -f $LASTEXITCODE, $out.Trim()
        $null = Write-EventRow -EventType 'RESTART_FAILED' -Severity 'CRITICAL' -Outcome 'FAILED' `
            -Detail ("Kind={0}; TriggerEventId={1}; shutdown.exe could not be invoked: {2}" -f $Kind, $eventId, $why) -Durable
        Write-WdLog "shutdown.exe failed: $why" 'ERROR'
        Write-Log "shutdown.exe failed: $why" 'ERROR'
        Remove-Item -LiteralPath $script:PendingPath -Force -ErrorAction SilentlyContinue
        return $false
    }
    return $true
}

function Request-WatchdogRestart {
    # The dashboard has been gone long enough: restart the PC, unless the
    # loop guard says two restarts in a row have not helped.
    param([Parameter(Mandatory)]$Config, $Reading)

    $s = $script:Session
    $w = $s.Wd
    $now = [DateTime]::UtcNow
    $kind = Get-ReadingKind -Percent $Reading -Config $Config
    if (-not $kind) { $kind = 'BROWSER' }
    $why = if ($s.ProblemWhy) { $s.ProblemWhy } else { 'the dashboard is not on screen' }
    $since = if ($w.LocalSinceUtc) { $w.LocalSinceUtc } else { $w.ProblemSinceUtc }
    $minutes = ($now - $since).TotalMinutes
    $reason = "{0} for {1:0.#} min" -f $why, $minutes

    $decision = Get-LoopGuardDecision -NowUtc $now -Config $Config
    if ($decision.Action -eq 'Hold') {
        if (-not $w.HoldAnnounced) {
            Write-LoopGuardHold -Decision $decision -Config $Config -Kind $kind -WhitePercent $Reading -StreakChecks $w.ProblemTicks -Why $why
            $script:LoopState.HoldReported = $true
            Save-LoopGuardState
            $w.HoldAnnounced = $true
        }
        $w.GuardHolding = $true
        $script:Status.LoopGuard = if ($decision.NextRetryUtc) { 'holding; next restart after {0:HH:mm}' -f $decision.NextRetryUtc.ToLocalTime() } else { 'holding' }
        return
    }

    $episodeId = ''
    if ($kind -eq 'WHITE' -and $w.WhiteEpisodeId) { $episodeId = $w.WhiteEpisodeId; Close-WhiteEpisode -Outcome 'REBOOT' -Percent $Reading }
    elseif ($kind -eq 'LOWWHITE' -and $w.LowEpisodeId) { $episodeId = $w.LowEpisodeId; Close-LowEpisode -Outcome 'REBOOT' -Percent $Reading }
    $note = if ($decision.Action -eq 'Retry') {
        "LoopGuard=retry after {0} unhelpful restart(s) since {1}" -f @($decision.Restarts).Count, (Format-Utc $decision.Since)
    }
    else { "LoopGuard={0}/{1}" -f (@($decision.Restarts).Count + 1), $Config.LoopGuardMaxRestarts }

    # Counted before shutdown.exe is asked, and through the disk cache: after
    # the restart it is the only memory of it.
    $script:LoopState.Restarts = @(@($decision.Restarts) + $now | Select-Object -Last 10)
    Save-LoopGuardState

    $ok = Invoke-WatchdogRestart -Kind $kind -Reason $reason -StreakChecks $w.ProblemTicks -WhitePercent $Reading `
        -EpisodeSeconds ($minutes * 60) -EpisodeId $episodeId -Note $note
    if ($ok) {
        $w.RestartPendingUtc = $now
        $w.HoldAnnounced = $false
        $w.GuardHolding = $false
        $script:Status.PcRestarts++
        $script:PersistentState['LastLauncherRestartUtc'] = $now.ToString('o')
        Save-PersistentState
        Set-State 'RESTARTING_PC' $reason
    }
    else {
        Undo-LoopGuardRestart
        $w.ProblemSinceUtc = $now
        $w.LocalSinceUtc = $null
        $w.LastLocalUtc = $null
        $w.ProblemTicks = 0
    }
}

# ---------------------------------------------------------------------------
# Watchdog: white and dark episodes
#
# An episode is one unbroken run of white (or dark) readings. It opens on
# the first and closes when the screen recovers or the PC is restarted, so
# one incident is one pair of rows, as the old watchdog wrote them.
# ---------------------------------------------------------------------------
function Close-WhiteEpisode {
    param([string]$Outcome, $Percent)
    $w = $script:Session.Wd
    if (-not $w.WhiteEpisodeId) { return }
    $null = Write-EventRow -EventType 'WHITE_EPISODE_END' -Severity 'WARNING' -Outcome $Outcome -WhitePercent $Percent -StreakChecks $w.WhiteChecks `
        -DurationSeconds ((Get-Date) - $w.WhiteEpisodeStart).TotalSeconds -Detail ("EpisodeId={0}; peak {1:N1}% white" -f $w.WhiteEpisodeId, $w.WhiteEpisodePeak)
    $w.WhiteEpisodeId = $null
    $w.WhiteChecks = 0
}

function Close-LowEpisode {
    param([string]$Outcome, $Percent)
    $w = $script:Session.Wd
    if (-not $w.LowEpisodeId) { return }
    $null = Write-EventRow -EventType 'LOWWHITE_EPISODE_END' -Severity 'WARNING' -Outcome $Outcome -WhitePercent $Percent -StreakChecks $w.LowChecks `
        -DurationSeconds ((Get-Date) - $w.LowEpisodeStart).TotalSeconds -Detail ("EpisodeId={0}; trough {1:N1}% white" -f $w.LowEpisodeId, $w.LowEpisodeTrough)
    $w.LowEpisodeId = $null
    $w.LowChecks = 0
}

function Update-Episodes {
    param($Reading, [Parameter(Mandatory)]$Config, [string]$Source)
    if ($null -eq $Reading) { return }
    $w = $script:Session.Wd
    $p = [double]$Reading
    switch (Get-ReadingKind -Percent $p -Config $Config) {
        'WHITE' {
            Close-LowEpisode -Outcome 'RECOVERED' -Percent $p
            if (-not $w.WhiteEpisodeId) {
                $w.WhiteEpisodeId = [guid]::NewGuid().ToString()
                $w.WhiteEpisodeStart = Get-Date
                $w.WhiteEpisodePeak = $p
                $null = Write-EventRow -EventType 'WHITE_EPISODE_START' -Severity 'WARNING' -WhitePercent $p -StreakChecks 1 `
                    -Detail ("EpisodeId={0}; {1} reached {2:N1}% white (threshold {3}%)" -f $w.WhiteEpisodeId, $Source, $p, $Config.WhiteHighPercent)
                Write-WdLog ("White {0}: {1:N1}% white." -f $Source, $p) 'WARN'
            }
            $w.WhiteChecks++
            if ($p -gt $w.WhiteEpisodePeak) { $w.WhiteEpisodePeak = $p }
        }
        'LOWWHITE' {
            Close-WhiteEpisode -Outcome 'RECOVERED' -Percent $p
            if (-not $w.LowEpisodeId) {
                $w.LowEpisodeId = [guid]::NewGuid().ToString()
                $w.LowEpisodeStart = Get-Date
                $w.LowEpisodeTrough = $p
                $null = Write-EventRow -EventType 'LOWWHITE_EPISODE_START' -Severity 'WARNING' -WhitePercent $p -StreakChecks 1 `
                    -Detail ("EpisodeId={0}; {1} fell to {2:N1}% white (threshold {3}%)" -f $w.LowEpisodeId, $Source, $p, $Config.WhiteLowPercent)
                Write-WdLog ("Dark {0}: {1:N1}% white." -f $Source, $p) 'WARN'
            }
            $w.LowChecks++
            if ($p -lt $w.LowEpisodeTrough) { $w.LowEpisodeTrough = $p }
        }
        default {
            if ($w.WhiteEpisodeId -or $w.LowEpisodeId) {
                Write-WdLog ("Screen recovered: {0:N1}% white." -f $p)
                Close-WhiteEpisode -Outcome 'RECOVERED' -Percent $p
                Close-LowEpisode -Outcome 'RECOVERED' -Percent $p
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Watchdog: Windows' reboot records -> ledger
#
# Remote event log access is closed on this network, so the kiosk copies
# the records itself, verbatim; the collector classifies them with the same
# code it uses for a record read remotely, so neither route double-counts.
# ---------------------------------------------------------------------------
$EventBackfillDays = 1
$WatchedEventIds = @(1074, 6005, 6008)

function Get-EvtScanState {
    if (-not (Test-Path -LiteralPath $script:EvtStatePath)) { return $null }
    try { return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($script:EvtStatePath))) } catch { return $null }
}

function Set-EvtScanState {
    param([long]$LastRecordId, [datetime]$ScannedUtc)
    try {
        $json = ConvertTo-Json -Compress -InputObject ([pscustomobject]@{ LastRecordId = $LastRecordId; ScannedUtc = (Format-Utc $ScannedUtc) })
        [IO.File]::WriteAllText($script:EvtStatePath, $json, $Utf8NoBom)
    }
    catch { Write-WdLog "Could not save the event-log scan position: $($_.Exception.Message)" 'WARN' }
}

function Write-WinEventRow {
    param([Parameter(Mandatory)]$Record)
    $props = @()
    foreach ($p in $Record.Properties) {
        $v = [string]$p.Value
        if ($v.Length -gt 400) { $v = $v.Substring(0, 400) }
        $props += $v
    }
    $msg = ''
    if ($Record.Message) {
        $msg = ($Record.Message -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
    }
    $payload = ConvertTo-Json -Compress -InputObject ([pscustomobject]@{
            Id = [int]$Record.Id; Provider = [string]$Record.ProviderName; RecordId = [long]$Record.RecordId; Props = $props; Msg = $msg
        })
    $utc = $Record.TimeCreated.ToUniversalTime()
    # The EventId the collector would give this record if it read the log
    # itself, so the two routes can never make two rows of one event.
    $null = Write-EventRow -EventId ("EVT-{0}-{1}-{2}" -f $ComputerName, $Record.RecordId, $utc.ToString('yyyyMMddHHmmss', $Invariant)) `
        -EventType 'WINEVENT' -Severity 'INFO' -EventTime $utc -OmitBootTime -Detail $payload
}

function Copy-SystemLogToLedger {
    param([switch]$Startup)

    $state = Get-EvtScanState
    $lastRecordId = 0
    $since = (Get-Date).AddDays(-$EventBackfillDays)
    if ($state) {
        try { $lastRecordId = [long]$state.LastRecordId } catch { $lastRecordId = 0 }
        try {
            # Back to the last scan however long ago that was, plus a day; the
            # record numbers stop anything being copied twice.
            $since = [datetime]::Parse([string]$state.ScannedUtc, $Invariant, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime().AddDays(-1)
        }
        catch {}
    }

    $records = @()
    try { $records = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $WatchedEventIds; StartTime = $since } -ErrorAction Stop) }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            Write-WdLog "Could not read the local System log: $($_.Exception.Message)" 'ERROR'
            if ($Startup) {
                $null = Write-EventRow -EventType 'AGENT_ERROR' -Severity 'WARNING' `
                    -Detail ("Local System log could not be read, so reboots by anything other than this watchdog cannot be reported: {0}" -f $_.Exception.Message)
            }
            return 0
        }
    }
    if ($records.Count -eq 0) {
        Set-EvtScanState -LastRecordId $lastRecordId -ScannedUtc ([DateTime]::UtcNow)
        return 0
    }
    $maxRecordId = [long](($records | Measure-Object -Property RecordId -Maximum).Maximum)
    if ($maxRecordId -lt $lastRecordId) {
        Write-WdLog "System log looks cleared (highest record $maxRecordId is below the last one seen, $lastRecordId). Re-reading it." 'WARN'
        $lastRecordId = 0
    }
    $written = 0
    foreach ($rec in ($records | Sort-Object RecordId)) {
        if ($rec.RecordId -le $lastRecordId) { continue }
        Write-WinEventRow -Record $rec
        $written++
    }
    Set-EvtScanState -LastRecordId $maxRecordId -ScannedUtc ([DateTime]::UtcNow)
    if ($written -gt 0) { Write-WdLog "Copied $written Windows reboot record(s) into the ledger." }
    return $written
}

# ---------------------------------------------------------------------------
# Watchdog: messages from the Kiosk Fleet Manager
#
# The dashboard drops msg_<time>_<id>.json into mwst_inbox over the admin
# share (under a temporary name first, then renamed). The file is removed
# when it is taken, so the sender can tell "picked up" from "waiting". The
# window is a separate powershell.exe, so the launcher keeps running while
# it is up; screen checks pause meanwhile, because the window is part of
# what they photograph.
# ---------------------------------------------------------------------------
$MessageMaxSeconds = 900
$MessageMaxChars = 1000
$script:MessageProc = $null
$script:MessageShown = $null
$script:MessageDeadline = $null

function ConvertTo-LedgerText {
    param([string]$Text, [int]$Max = 200)
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    return $t
}

function Read-InboxMessage {
    # The oldest message that can be shown, or $null. Unreadable and expired
    # ones are removed on the way, each with a ledger row.
    if (-not (Test-Path -LiteralPath $script:InboxPath)) { return $null }
    foreach ($file in @(Get-ChildItem -LiteralPath $script:InboxPath -Filter 'msg_*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $raw = $null
        try { $raw = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) }
        catch [IO.IOException] { continue }
        catch { $raw = $null }
        $msg = $null
        if ($raw) { try { $msg = ConvertFrom-Json -InputObject $raw } catch {} }
        $hasText = $msg -and $msg.PSObject.Properties['Text'] -and -not [string]::IsNullOrWhiteSpace([string]$msg.Text)
        $id = if ($msg -and $msg.PSObject.Properties['Id'] -and $msg.Id) { [string]$msg.Id } else { $file.BaseName }

        $problem = $null
        if (-not $hasText) { $problem = @('MESSAGE_REJECTED', 'REJECTED', "unreadable or empty message file $($file.Name)") }
        else {
            $expires = $null
            if ($msg.PSObject.Properties['ExpiresUtc']) {
                try { $expires = [datetime]::Parse([string]$msg.ExpiresUtc, $Invariant, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch {}
            }
            if ($expires -and [DateTime]::UtcNow -gt $expires) {
                $problem = @('MESSAGE_EXPIRED', 'EXPIRED', "not shown: it expired at $(Format-Utc $expires) before this watchdog saw it")
            }
        }
        if ($problem) {
            try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch { continue }
            $null = Write-EventRow -EventType $problem[0] -Severity 'WARNING' -Outcome $problem[1] -Detail ("MessageId={0}; {1}" -f $id, $problem[2])
            Write-WdLog ("Message {0} dropped: {1}." -f $id, $problem[2]) 'WARN'
            continue
        }

        $seconds = 60
        if ($msg.PSObject.Properties['Seconds'] -and $msg.Seconds) { try { $seconds = [int]$msg.Seconds } catch {} }
        $seconds = [math]::Max(5, [math]::Min($MessageMaxSeconds, $seconds))
        $text = [string]$msg.Text
        if ($text.Length -gt $MessageMaxChars) { $text = $text.Substring(0, $MessageMaxChars) }
        $title = if ($msg.PSObject.Properties['Title'] -and $msg.Title) { [string]$msg.Title } else { 'Message from IT' }
        if ($title.Length -gt 80) { $title = $title.Substring(0, 80) }
        $from = if ($msg.PSObject.Properties['From']) { [string]$msg.From } else { '' }
        return [pscustomobject]@{ Id = $id; Title = $title; Text = $text; Seconds = $seconds; From = $from; File = $file.FullName; StartedAt = $null }
    }
    return $null
}

function Get-MessageWindowScript {
    # Runs in its own powershell.exe. Exit code: 0 OK pressed, 2 timed out,
    # 1 failed. __MESSAGE_FILE__ is replaced with the file it reads. With
    # -Headless (tests) there is no window: it just waits out the countdown.
    if ($Headless) {
        return @'
$ProgressPreference = 'SilentlyContinue'
$code = 1
try { $m = [System.IO.File]::ReadAllText('__MESSAGE_FILE__', [System.Text.Encoding]::UTF8) | ConvertFrom-Json; Start-Sleep -Seconds ([int]$m.Seconds); $code = 2 } catch { $code = 1 }
exit $code
'@
    }
    return @'
$ProgressPreference = 'SilentlyContinue'
$code = 1
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $m = [System.IO.File]::ReadAllText('__MESSAGE_FILE__', [System.Text.Encoding]::UTF8) | ConvertFrom-Json

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $w = [int]($screen.Width * 0.6)
    $h = [int]($screen.Height * 0.45)
    $navy = [System.Drawing.Color]::FromArgb(30, 58, 138)

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition   = 'Manual'
    $form.Bounds          = New-Object System.Drawing.Rectangle(($screen.X + [int](($screen.Width - $w) / 2)), ($screen.Y + [int](($screen.Height - $h) / 2)), $w, $h)
    $form.TopMost         = $true
    $form.ShowInTaskbar   = $false
    $form.BackColor       = $navy
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.Padding         = New-Object System.Windows.Forms.Padding(32)

    $body = New-Object System.Windows.Forms.Label
    $body.Dock      = 'Fill'
    $body.TextAlign = 'MiddleCenter'
    $body.Text      = [string]$m.Text
    $form.Controls.Add($body)

    $head = New-Object System.Windows.Forms.Label
    $head.Dock      = 'Top'
    $head.Height    = 56
    $head.Text      = [string]$m.Title
    $head.Font      = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    $head.ForeColor = [System.Drawing.Color]::FromArgb(250, 204, 21)
    $form.Controls.Add($head)

    $foot = New-Object System.Windows.Forms.Panel
    $foot.Dock   = 'Bottom'
    $foot.Height = 64
    $form.Controls.Add($foot)

    $clock = New-Object System.Windows.Forms.Label
    $clock.Dock      = 'Fill'
    $clock.TextAlign = 'MiddleLeft'
    $clock.Font      = New-Object System.Drawing.Font('Segoe UI', 14)
    $foot.Controls.Add($clock)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text      = 'OK'
    $ok.Dock      = 'Right'
    $ok.Width     = 200
    $ok.FlatStyle = 'Flat'
    $ok.Font      = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
    $ok.BackColor = [System.Drawing.Color]::White
    $ok.ForeColor = $navy
    $foot.Controls.Add($ok)

    $global:left = [int]$m.Seconds
    $global:code = 2
    $clock.Text  = "Closes in $($global:left) s"

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({
        $global:left--
        if ($global:left -le 0) { $timer.Stop(); $form.Close() }
        else { $clock.Text = "Closes in $($global:left) s" }
    })
    $ok.Add_Click({ $global:code = 0; $form.Close() })

    $form.Add_Shown({
        foreach ($size in 28, 24, 20, 18, 16, 14, 12, 10) {
            $font = New-Object System.Drawing.Font('Segoe UI', $size)
            $need = [System.Windows.Forms.TextRenderer]::MeasureText($body.Text, $font,
                        (New-Object System.Drawing.Size($body.ClientSize.Width, 0)),
                        [System.Windows.Forms.TextFormatFlags]::WordBreak)
            if ($need.Height -le $body.ClientSize.Height) { break }
        }
        $body.Font = $font
        $form.Activate()
        $timer.Start()
    })
    $form.AcceptButton = $ok

    [System.Windows.Forms.Application]::Run($form)
    $code = $global:code
}
catch { $code = 1 }
exit $code
'@
}

function Start-MessageWindow {
    param([Parameter(Mandatory)]$Message)
    $file = Join-Path $script:InboxPath 'showing.json'
    $json = ConvertTo-Json -Compress -InputObject ([pscustomobject]@{ Title = $Message.Title; Text = $Message.Text; Seconds = $Message.Seconds })
    [IO.File]::WriteAllText($file, $json, $Utf8NoBom)
    $code = (Get-MessageWindowScript).Replace('__MESSAGE_FILE__', $file.Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
    $script:MessageProc = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -NoNewWindow -PassThru -ErrorAction Stop `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    # Reading Handle while it runs is what keeps ExitCode readable later.
    $null = $script:MessageProc.Handle
    $script:MessageDeadline = (Get-Date).AddSeconds($Message.Seconds + 30)
}

function Update-KioskMessage {
    # Follows the message on screen and shows the next one once the screen
    # is free. $true while one is up.
    if (-not $script:WdOn) { return $false }
    if ($script:MessageProc) {
        $proc = $script:MessageProc
        if (-not $proc.HasExited -and (Get-Date) -lt $script:MessageDeadline) { return $true }
        if (-not $proc.HasExited) {
            try { $proc.Kill() } catch {}
            $outcome = 'KILLED'; $how = 'the window did not close by itself and was ended'
        }
        else {
            switch ($proc.ExitCode) {
                0 { $outcome = 'ACKNOWLEDGED'; $how = 'OK pressed' }
                2 { $outcome = 'TIMEOUT'; $how = 'closed by its countdown' }
                default { $outcome = 'ERROR'; $how = "the window failed (exit code $($proc.ExitCode))" }
            }
        }
        $shown = $script:MessageShown
        $severity = if ($outcome -in @('ACKNOWLEDGED', 'TIMEOUT')) { 'INFO' } else { 'WARNING' }
        $null = Write-EventRow -EventType 'MESSAGE_CLOSED' -Severity $severity -Outcome $outcome `
            -DurationSeconds ((Get-Date) - $shown.StartedAt).TotalSeconds -Detail ("MessageId={0}; {1}" -f $shown.Id, $how)
        Write-WdLog ("Message {0} closed: {1}. Screen checks resume." -f $shown.Id, $how)
        Write-Log ("Message {0} closed: {1}." -f $shown.Id, $how)
        Remove-Item -LiteralPath (Join-Path $script:InboxPath 'showing.json') -Force -ErrorAction SilentlyContinue
        $script:MessageProc = $null
        $script:MessageShown = $null
    }

    $next = Read-InboxMessage
    if (-not $next) { return $false }
    # Out of the inbox before anything else: a message that cannot be shown
    # must not come back every tick.
    try { Remove-Item -LiteralPath $next.File -Force -ErrorAction Stop } catch { return $false }
    try { Start-MessageWindow -Message $next }
    catch {
        $null = Write-EventRow -EventType 'MESSAGE_REJECTED' -Severity 'WARNING' -Outcome 'REJECTED' `
            -Detail ("MessageId={0}; the message window could not be opened: {1}" -f $next.Id, $_.Exception.Message)
        Write-WdLog "Message $($next.Id) could not be shown: $($_.Exception.Message)" 'ERROR'
        return $false
    }
    $next.StartedAt = Get-Date
    $script:MessageShown = $next
    $null = Write-EventRow -EventType 'MESSAGE_SHOWN' -Severity 'INFO' -Outcome 'SHOWN' -DurationSeconds $next.Seconds `
        -Detail ("MessageId={0}; From={1}; Seconds={2}; Text={3}" -f $next.Id, $next.From, $next.Seconds, (ConvertTo-LedgerText $next.Text))
    Write-WdLog ("Showing message {0} from {1} for up to {2}s, screen checks paused: {3}" -f $next.Id, $next.From, $next.Seconds, (ConvertTo-LedgerText $next.Text))
    Write-Log ("Showing a message from {0} for up to {1} s." -f $next.From, $next.Seconds)
    return $true
}

# ---------------------------------------------------------------------------
# Watchdog: the old watchdog
#
# The deploy disables the old watchdog's logon task. If something starts it
# anyway - a task re-registered by the old deploy script, say - it is
# stopped: two watchdogs would each restart the PC, and both write the
# same ledger. Its launcher batch file is stopped too, while it is still
# counting down to starting it.
# ---------------------------------------------------------------------------
function Stop-OldWatchdog {
    $mySession = (Get-Process -Id $PID).SessionId
    $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe' OR Name = 'cmd.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessId -ne $PID -and $_.SessionId -eq $mySession -and $_.CommandLine -and $_.CommandLine -match '(?i)\\mwstv4\.ps1|MWSTv\d+_Launcher\.bat' })
    foreach ($p in $procs) {
        try {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop
            $what = if ($p.CommandLine -match '(?i)mwstv4\.ps1') { 'the old MWST watchdog (mwstv4.ps1)' } else { 'the old watchdog''s launcher (MWSTv*_Launcher.bat)' }
            Write-Log ("Stopped {0}, PID {1}: this launcher is the watchdog now. Is its logon task still enabled?" -f $what, $p.ProcessId) 'WARN'
            Write-WdLog ("Stopped {0} (PID {1}): Mach2 Launcher {2} is the watchdog now." -f $what, $p.ProcessId, $LauncherVersion) 'WARN'
        }
        catch { Write-Log ("Could not stop the old watchdog (PID {0}): {1}" -f $p.ProcessId, $_.Exception.Message) 'ERROR' }
    }
}

# ---------------------------------------------------------------------------
# The old launcher
#
# Retiring Mach2Launcher.exe at deploy time is not enough on these kiosks:
# Mach2LauncherShortcuts.ps1 puts the StartupLauncher shortcut back in the
# Startup folder at every logon, StartupLauncher starts the old launcher
# again, and the two fight over the screen. The old launcher has no setting
# that keeps it off (its configs have no DisableStartup). So each instance
# stops the old launcher for its own screen - "Launcher S1" for S1 - whenever
# it finds it: Mach2Launcher.exe, the msedgedriver.exe it runs, and the Edge
# that driver opened. Only that tree is touched; this launcher's own Edge is
# neither its child nor on its profile, and is skipped even if it were.
# StopOldLauncher = 0 leaves the old launcher alone.
# ---------------------------------------------------------------------------
$script:LastOldLauncherCheckUtc = [DateTime]::MinValue
$OldLauncherCheckSeconds = 20

function Stop-OldLauncher {
    param([Parameter(Mandatory)]$Config)

    if (-not $Config.StopOldLauncher) { return }
    # hold.txt means hands off the screen, for whoever is working on it.
    if ($script:Status.State -eq 'HOLD') { return }
    $now = [DateTime]::UtcNow
    if (($now - $script:LastOldLauncherCheckUtc).TotalSeconds -lt $OldLauncherCheckSeconds) { return }
    $script:LastOldLauncherCheckUtc = $now

    # Cheap first look: is any old launcher or driver running at all?
    $screenFolder = '\Launcher ' + $Instance + '\'
    $mySession = (Get-Process -Id $PID).SessionId
    $candidates = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Mach2Launcher.exe' OR Name = 'msedgedriver.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $mySession -and $_.ExecutablePath -and $_.ExecutablePath.IndexOf($screenFolder, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
    # A driver counts only next to an old Mach2 launcher: other old
    # launchers kept their own msedgedriver.exe in "Launcher S<n>" folders.
    $roots = @($candidates | Where-Object {
            $_.Name -ieq 'Mach2Launcher.exe' -or (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $_.ExecutablePath) 'Mach2Launcher.exe'))
        })
    if ($roots.Count -eq 0) { return }

    # Everything they started, found by walking parent to child.
    $all = @(Get-CimInstance -ClassName Win32_Process -ErrorAction SilentlyContinue)
    $children = @{}
    foreach ($p in $all) {
        $key = [int]$p.ParentProcessId
        if (-not $children.ContainsKey($key)) { $children[$key] = New-Object System.Collections.Generic.List[object] }
        $children[$key].Add($p)
    }
    $tree = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    $queue = New-Object System.Collections.Generic.Queue[object]
    foreach ($r in $roots) { $queue.Enqueue($r) }
    while ($queue.Count -gt 0) {
        $p = $queue.Dequeue()
        if ($seen.ContainsKey([int]$p.ProcessId)) { continue }
        $seen[[int]$p.ProcessId] = $true
        $tree.Add($p)
        if (-not $children.ContainsKey([int]$p.ProcessId)) { continue }
        foreach ($c in $children[[int]$p.ProcessId]) {
            # Windows reuses process IDs: a process whose own parent died
            # long ago can carry the ID the old launcher has now. A real
            # child is never older than its parent.
            if ($c.CreationDate -and $p.CreationDate -and $c.CreationDate -lt $p.CreationDate) { continue }
            $queue.Enqueue($c)
        }
    }

    $mine = [string]$Config.ProfileDir
    $stopped = 0
    # Deepest first, so nothing is left running without its parent.
    for ($i = $tree.Count - 1; $i -ge 0; $i--) {
        $p = $tree[$i]
        if ([int]$p.ProcessId -eq $PID) { continue }
        if ($mine -and $p.CommandLine -and $p.CommandLine.IndexOf($mine, [StringComparison]::OrdinalIgnoreCase) -ge 0) { continue }
        try {
            Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop
            $stopped++
        }
        catch { }   # gone already: a child dies with its parent
    }

    $launchers = @($roots | Where-Object { $_.Name -ieq 'Mach2Launcher.exe' })
    $what = if ($launchers.Count) { 'the old Mach2Launcher.exe (PID {0})' -f (@($launchers | ForEach-Object { $_.ProcessId }) -join ', ') }
            else { 'the old launcher''s msedgedriver.exe and its Edge' }
    Write-Log ("Stopped {0} and what it had started, {1} process(es): it was running again for this screen - StartupLauncher starts it at logon. Mach2 Launcher {2} shows this screen now." -f $what, $stopped, $LauncherVersion) 'WARN'
    $script:Status.OldLauncherStops++
}

# ---------------------------------------------------------------------------
# Watchdog: one step, after every tick
# ---------------------------------------------------------------------------
$HeartbeatMinutes = 3
$EventScanIntervalMinutes = 60

function Update-Watchdog {
    param([Parameter(Mandatory)]$Config, [string]$Control, [bool]$MessageUp)

    if (-not $script:WdOn) { return }
    $s = $script:Session
    $w = $s.Wd
    $now = [DateTime]::UtcNow

    if (($now - $w.LastEventScanUtc).TotalMinutes -ge $EventScanIntervalMinutes) {
        $w.LastEventScanUtc = $now
        try { $null = Copy-SystemLogToLedger } catch { Write-WdLog "Event log copy failed: $($_.Exception.Message)" 'ERROR' }
    }
    if (($now - $w.LastOldCheckUtc).TotalSeconds -ge 60) {
        $w.LastOldCheckUtc = $now
        try { Stop-OldWatchdog } catch { Write-Log "Looking for the old watchdog failed: $($_.Exception.Message)" 'DEBUG' }
    }

    $reading = if ($null -ne $s.ScreenWhite) { $s.ScreenWhite } else { $s.PageWhite }
    $source = if ($null -ne $s.ScreenWhite) { 'screen' } else { 'dashboard page' }

    if ($w.RestartPendingUtc) {
        # shutdown.exe was asked. Normally the PC is gone within 15 s and
        # nothing here runs again; still being here after
        # RestartConfirmSeconds means the restart was blocked or cancelled.
        if (($now - $w.RestartPendingUtc).TotalSeconds -ge $Config.RestartConfirmSeconds) {
            Resolve-PendingRestart -GraceSeconds $Config.RestartConfirmSeconds
            Undo-LoopGuardRestart
            $w.RestartPendingUtc = $null
            $w.ProblemSinceUtc = $null
            $w.LocalSinceUtc = $null
            $w.LastLocalUtc = $null
            $w.ProblemTicks = 0
            Set-State 'LOADING' 'the PC restart did not happen'
        }
    }
    elseif ($Control -in @('hold', 'restarting') -or $MessageUp -or $script:Status.State -in @('DISABLED', 'STOPPED', 'RESTARTING_PC')) {
        # A person is at the kiosk, a message is up, or the PC is going down.
    }
    else {
        # Right after logon the desktop is on the screen until Edge is up,
        # and that is not screen trouble: the old watchdog's launcher waited
        # 60 s before its first check for the same reason. Episodes start
        # once the dashboard has been on screen, or after EpisodeGraceSeconds.
        if ($script:Status.LastShownUtc -or ($now - $script:StartedUtc).TotalSeconds -ge $Config.EpisodeGraceSeconds) {
            Update-Episodes -Reading $reading -Config $Config -Source $source
        }

        $class = $s.ProblemClass
        if ($script:Status.State -in @('SIGNIN_BLOCKED', 'WAITING_DISPLAY')) { $class = 'person' }
        switch ($class) {
            'ok' {
                $w.ProblemSinceUtc = $null
                $w.LocalSinceUtc = $null
                $w.LastLocalUtc = $null
                $w.ProblemTicks = 0
                $w.GuardHolding = $false
                if (-not $w.HealthySinceUtc) { $w.HealthySinceUtc = $now; $w.HealthyResetDone = $false }
                if (-not $w.HealthyResetDone -and ($now - $w.HealthySinceUtc).TotalMinutes -ge $Config.LoopGuardHealthyMinutes) {
                    Reset-LoopGuard -WhitePercent $reading -Config $Config
                    $w.HealthyResetDone = $true
                }
            }
            'person' {
                $w.ProblemSinceUtc = $null
                $w.LocalSinceUtc = $null
                $w.LastLocalUtc = $null
                $w.ProblemTicks = 0
                $w.HealthySinceUtc = $null
            }
            default {
                # Two clocks. A local problem (something a restart can fix)
                # restarts the PC after RebootAfterMinutes of it; loading and
                # signing in between two local readings do not stop that
                # clock, two quiet minutes do. Anything else - the station
                # down, or never getting anywhere - only after
                # OutageRebootMinutes, however it is made up.
                $w.HealthySinceUtc = $null
                if (-not $w.ProblemSinceUtc) { $w.ProblemSinceUtc = $now; $w.ProblemTicks = 0; $w.LocalSinceUtc = $null; $w.LastLocalUtc = $null }
                $w.ProblemTicks++
                if ($class -eq 'local') {
                    if (-not $w.LocalSinceUtc -or -not $w.LastLocalUtc -or ($now - $w.LastLocalUtc).TotalSeconds -gt 120) { $w.LocalSinceUtc = $now }
                    $w.LastLocalUtc = $now
                }
                elseif ($w.LastLocalUtc -and ($now - $w.LastLocalUtc).TotalSeconds -gt 120) { $w.LocalSinceUtc = $null }
                $due = ($w.LocalSinceUtc -and $Config.RebootAfterMinutes -gt 0 -and ($now - $w.LocalSinceUtc).TotalMinutes -ge $Config.RebootAfterMinutes) -or
                ($Config.OutageRebootMinutes -gt 0 -and ($now - $w.ProblemSinceUtc).TotalMinutes -ge $Config.OutageRebootMinutes)
                if ($due) { Request-WatchdogRestart -Config $Config -Reading $reading }
            }
        }
    }

    $script:Status.ProblemSinceUtc = if ($w.ProblemSinceUtc) { $w.ProblemSinceUtc.ToString('o') } else { '' }
    $script:Status.ProblemClass = if (-not $w.ProblemSinceUtc) { '' } elseif ($w.LocalSinceUtc) { 'local' } else { $s.ProblemClass }

    if (($now - $w.LastHeartbeatUtc).TotalMinutes -ge $HeartbeatMinutes) {
        $w.LastHeartbeatUtc = $now
        $scr = if ($null -ne $s.ScreenWhite) { '{0:N1}%' -f $s.ScreenWhite } else { 'not read' }
        $pg = if ($null -ne $s.PageWhite) { '{0:N1}%' -f $s.PageWhite } else { 'not read' }
        $guard = if ($w.GuardHolding) { ' Loop guard holding.' } else { '' }
        Write-WdLog ("Heartbeat: Mach2 Launcher {0} alive, dashboard {1}, screen {2} white, page {3} white.{4}" -f $LauncherVersion, $script:Status.State, $scr, $pg, $guard)
    }
}

# ---------------------------------------------------------------------------
# Schedules, restarts, control files
# ---------------------------------------------------------------------------
$script:BootTime = [DateTime]::MinValue

function Test-DailyDue {
    # True once per day, within ten minutes after the given time.
    param([TimeSpan]$At, [string]$Tag, [hashtable]$Done)
    $now = Get-Date
    $due = $now.Date + $At
    if ($now -lt $due -or $now -gt $due.AddMinutes(10)) { return $false }
    $key = '{0}|{1}' -f $Tag, $due.ToString('yyyy-MM-dd HH:mm', $Invariant)
    if ($Done.ContainsKey($key)) { return $false }
    $Done[$key] = $true
    return $true
}

function Invoke-PcRestart {
    # A restart someone asked for (restart.txt, the daily schedule) - not
    # the watchdog's, so it is tagged as the launcher's and Windows records
    # it as an ordinary requested restart.
    param([Parameter(Mandatory)][string]$Why, [int]$DelaySeconds = 10)

    $script:PersistentState['LastLauncherRestartUtc'] = [DateTime]::UtcNow.ToString('o')
    Save-PersistentState
    $comment = "Mach2 Launcher ${LauncherVersion}: $Why [MACH2-LAUNCHER-NG]"
    if ($comment.Length -gt 500) { $comment = $comment.Substring(0, 500) }
    Write-Log "Restarting the PC in $DelaySeconds s: $Why" 'WARN'
    Write-WdLog "Restarting the PC in $DelaySeconds s: $Why" 'WARN'
    Set-State 'RESTARTING_PC' $Why
    $script:Status.PcRestarts++
    Save-Status
    if ($SimulateRestart) {
        Write-Log ("SimulateRestart: not running shutdown.exe /r /t {0} /c ""{1}""" -f $DelaySeconds, $comment) 'WARN'
        return
    }
    $ErrorActionPreference = 'Continue'
    $out = & "$env:SystemRoot\System32\shutdown.exe" /r /t $DelaySeconds /c $comment /d p:4:1 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log ("shutdown.exe failed ({0}): {1}" -f $LASTEXITCODE, (($out | ForEach-Object { "$_" }) -join ' ')) 'ERROR'
    }
}

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
    if (($now - $script:BootTime).TotalMinutes -lt 30) {
        Write-Log 'Skipping the scheduled restart: the PC started less than 30 min ago.'
        return
    }
    Invoke-PcRestart -Why 'scheduled daily restart' -DelaySeconds $Config.RestartDelaySeconds
}

function Remove-ControlFile {
    # A control file that cannot be deleted would repeat its action on every
    # tick, so it is only acted on once it is gone.
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

function Save-Snapshot {
    # snapshot.txt: Status\<instance>.png and Status\<instance>.snapshot.json.
    param([Parameter(Mandatory)]$Config)

    $base = Join-Path $script:StatusDir $Instance
    $info = [ordered]@{
        TakenUtc = [DateTime]::UtcNow.ToString('o'); State = $script:Status.State; Detail = $script:Status.Detail
        Url = ''; Title = ''; PageWhitePercent = $script:Status.PageWhitePercent; ScreenWhitePercent = $script:Status.ScreenWhitePercent
        Image = ''; Error = ''
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

function Invoke-ControlFiles {
    # Returns 'exit', 'hold', 'restarting' or ''.
    param([Parameter(Mandatory)]$Config)

    $snapshot = Join-Path $Here 'snapshot.txt'
    if ((Test-Path -LiteralPath $snapshot) -and (Remove-ControlFile $snapshot)) { Save-Snapshot -Config $Config }

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
    if ((Test-Path -LiteralPath $relaunch) -and (Remove-ControlFile $relaunch)) { Restart-Browser -Config $Config -Why 'relaunch.txt' }

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
function Update-ScreenReading {
    # The watchdog's photograph of the kiosk screen, taken before each tick.
    # Not while a message window is up (it would be in the picture), not
    # headless (the screen would be this PC's), and only with ScreenCheck.
    param([Parameter(Mandatory)]$Config, [bool]$MessageUp)

    $s = $script:Session
    $s.ScreenWhite = $null
    if (-not $Config.ScreenCheck -or $Headless -or $MessageUp) { $script:Status.ScreenWhitePercent = $null; return }

    # Something brought the console back: hide it, or it is photographed.
    $console = Hide-ConsoleWindow
    if ($console -eq 'hidden by the launcher') {
        Write-Log 'The launcher''s console window was back on screen; hidden again before the screen check.' 'WARN'
        Start-Sleep -Milliseconds 500
    }
    $screen = if ($s.Screen) { $s.Screen } else { Get-TargetScreen -Config $Config -Quiet }
    $r = Get-ScreenWhitePercent -Screen $screen -Level $Config.WhitePixelLevel
    if ($null -eq $r.Percent) {
        $s.ScreenErrors++
        Write-Log "Screen check failed: $($r.Error)" $(if ($s.ScreenErrors -eq 1) { 'WARN' } else { 'DEBUG' })
        # A run of failures means the session is gone - worth a ledger row,
        # never a restart: a watchdog that restarts when it cannot see is
        # worse than one that waits.
        if ($s.ScreenErrors -eq 6) {
            $null = Write-EventRow -EventType 'AGENT_ERROR' -Severity 'WARNING' -StreakChecks $s.ScreenErrors `
                -Detail ("Screen could not be sampled {0} times in a row: {1}" -f $s.ScreenErrors, $r.Error)
        }
        $script:Status.ScreenWhitePercent = $null
        return
    }
    if ($s.ScreenErrors -ge 6) {
        $null = Write-EventRow -EventType 'AGENT_RECOVERED' -Severity 'INFO' -WhitePercent $r.Percent -StreakChecks $s.ScreenErrors `
            -Detail ("Screen sampling recovered after {0} consecutive failures." -f $s.ScreenErrors)
    }
    $s.ScreenErrors = 0
    $s.ScreenWhite = [double]$r.Percent
    $script:Status.ScreenWhitePercent = [math]::Round($r.Percent, 1)
}

function Invoke-SupervisedTick {
    # Returns the number of seconds to sleep before the next tick.
    param([Parameter(Mandatory)]$Config)

    $s = $script:Session
    $now = [DateTime]::UtcNow
    Set-Problem -Class 'neutral'
    $s.PageWhite = $null

    # --- the browser ---------------------------------------------------------
    $health = Get-BrowserHealth -Config $Config
    if ($health -eq 'hung') {
        $s.BrowserHung++
        Set-Problem -Class 'local' -Why 'Edge is not answering'
        Write-Log ("Edge is running but not answering (check {0})." -f $s.BrowserHung) 'WARN'
        if ($s.BrowserHung -ge 3) { Restart-Browser -Config $Config -Why 'Edge stopped answering' }
        return 5
    }
    if ($health -eq 'gone') {
        # Edge closing by itself, or refusing to start, is this PC's
        # problem; starting it the first time is not.
        if ($script:Browser) {
            Write-Log 'Edge has closed.' 'WARN'
            $script:Browser = $null
            Disconnect-Cdp
            $s.Relaunches.Add($now)
            Set-Problem -Class 'local' -Why 'Edge closed by itself'
        }
        elseif ($s.LaunchFailures -gt 0) { Set-Problem -Class 'local' -Why 'Edge will not start' }
        else { Set-Problem -Class 'neutral' -Why 'starting Edge' }
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

    # --- the page -------------------------------------------------------------
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
            Set-Problem -Class 'local' -Why 'the page cannot be read'
            Write-Log "The page keeps refusing to be read: $text" 'WARN'
            Open-Target -Config $Config -Why 'the page could not be read'
            return 3
        }
        $s.CdpFailures++
        if ($s.CdpFailures -eq 1) { $s.CdpSilentSinceUtc = $now }
        Set-Problem -Class 'local' -Why 'the page is not answering'

        # A station that is merely slow answers eventually. Restarting Edge
        # while it is signing in throws the sign-in away and spends one of the
        # password attempts, so a sign-in in flight gets the longer wait.
        $wait = $Config.PageStalledSeconds
        $signingIn = ($script:Session.Login.LastAction -in @('user', 'password') -and
                      $now -lt $script:Session.Login.LastActionUtc.AddSeconds($Config.SignInWaitSeconds))
        if ($signingIn -and $Config.SignInWaitSeconds -gt $wait) { $wait = $Config.SignInWaitSeconds }

        $silent = ($now - $s.CdpSilentSinceUtc).TotalSeconds
        Write-Log ("Cannot read the page (check {0}, {1:N0}s of {2}s{3}): {4}" -f `
            $s.CdpFailures, $silent, $wait, $(if ($signingIn) { ', signing in' } else { '' }), $text) 'WARN'
        if ($silent -ge $wait) {
            $s.CdpFailures = 0
            Restart-Browser -Config $Config -Why 'the page stopped responding'
        }
        return 3
    }
    $s.CdpFailures = 0
    $s.CdpRefused = 0
    if (-not $st) { return 2 }
    try { Close-StrayPages } catch { Write-Log ("Checking for extra windows failed: {0}" -f (Get-ErrorText $_)) 'DEBUG' }

    $url = [string]$st.url
    $script:Status.CurrentUrl = $url
    if (-not $s.LoggedScreen -and $st.screen) {
        $s.LoggedScreen = $true
        Write-Log ("Page window: {0},{1}, screen {2}x{3}, viewport {4}x{5}, pixel ratio {6}." -f $st.screen.x, $st.screen.y, $st.screen.w, $st.screen.h, $st.screen.iw, $st.screen.ih, $st.screen.dpr)
    }
    Write-Log ("Page: {0} ready={1} elements={2} errors={3} login={4}/{5}/{6}" -f $url, $st.ready, $st.elements, (@($st.errors) -join ';'), $st.onLogin, $st.user, $st.pass) 'DEBUG'

    # --- an Edge error page, or nothing -----------------------------------------
    if ($url -match '^(chrome|edge)-error:' -or $url -eq 'about:blank' -or $url -eq '' -or $url -match '^(chrome|edge)://') {
        $isError = $url -match 'error'
        $why = if ($isError) { 'Edge shows an error page - the station or the network is down' } else { "the page was $url" }
        Set-Problem -Class $(if ($isError) { 'outage' } else { 'neutral' }) -Why $why
        if ($now -lt $s.NextNavigateUtc) { return 3 }
        $s.NavigateStreak++
        # 0 s, 30 s, 1, 2, 4 min, then every 5 min.
        $waits = @(0, 30, 60, 120, 240, 300)
        $s.NextNavigateUtc = $now.AddSeconds($waits[[math]::Min($s.NavigateStreak, $waits.Count - 1)])
        Set-State 'RECOVERING' $why
        Open-Target -Config $Config -Why $why
        return 3
    }

    # --- sign-in ----------------------------------------------------------------
    if ($st.onLogin) {
        $s.OffTargetSinceUtc = [DateTime]::MinValue
        Invoke-LoginStep -Config $Config -St $st
        return 2
    }
    $l = $s.Login
    if ($l.SinceUtc -ne [DateTime]::MinValue) {
        # Past the sign-in pages.
        if ($l.LastAction) {
            $script:Status.SignIns++
            $l.SignedInUtc = $now
            Write-Log 'Signed in.'
            $l.PasswordTimes.Clear()
        }
        $l.SinceUtc = [DateTime]::MinValue
        $l.LastAction = ''
        $l.Repeats = 0
    }

    # --- somewhere other than the dashboard ------------------------------------
    # Nobody uses these screens, so anywhere else is put right - after a
    # moment, since the station redirects on the way (after sign-in it
    # opens its home page; that is left at once).
    if (-not (Test-IsTargetUrl -Current $url -Target $Config.DisplayUrl)) {
        Set-Problem -Class 'neutral' -Why "the page is on $url"
        if ($s.OffTargetSinceUtc -eq [DateTime]::MinValue) { $s.OffTargetSinceUtc = $now }
        $justSignedIn = $now -lt $l.SignedInUtc.AddSeconds(60)
        $grace = if ($justSignedIn -and $st.ready -eq 'complete') { 0 } else { $Config.OffTargetSeconds }
        if ($now -lt $s.OffTargetSinceUtc.AddSeconds($grace)) { return 2 }
        $s.OffTargetSinceUtc = [DateTime]::MinValue
        $why = if ($justSignedIn) { "signed in; the station opened $url" } else { "the page was on $url" }
        Set-State 'LOADING' 'opening the dashboard'
        Open-Target -Config $Config -Why $why
        return 3
    }
    $s.OffTargetSinceUtc = [DateTime]::MinValue
    $s.NavigateStreak = 0
    $s.NextNavigateUtc = [DateTime]::MinValue

    # --- on the dashboard ----------------------------------------------------------
    $errors = @($st.errors)
    if ($errors.Count -gt 0) {
        $why = "the dashboard shows '{0}'" -f ($errors -join "', '")
        Set-Problem -Class 'outage' -Why $why
        $s.ErrorStreak++
        if ($s.ErrorStreak -eq 1) { Write-Log ("The dashboard shows: {0}" -f ($errors -join '; ')) 'WARN' }
        if ($s.ErrorStreak -ge $Config.ErrorChecksBeforeReload) { Invoke-Recovery -Config $Config -Why $why }
        return [math]::Min(5, $Config.HealthCheckSeconds)
    }
    $s.ErrorStreak = 0

    $pagePct = $null
    if ($st.ready -in @('interactive', 'complete')) {
        try { $pagePct = Get-PageWhitePercent -Config $Config -St $st }
        catch { Write-Log ("No page reading: {0}" -f (Get-ErrorText $_)) 'DEBUG' }
    }
    $s.PageWhite = $pagePct
    $script:Status.PageWhitePercent = if ($null -ne $pagePct) { [math]::Round($pagePct, 1) } else { $null }
    $pageKind = Get-ReadingKind -Percent $pagePct -Config $Config
    if ($pageKind) {
        $s.CoveredSinceUtc = [DateTime]::MinValue
        if ($s.BadSinceUtc -eq [DateTime]::MinValue) { $s.BadSinceUtc = $now }
        $why = if ($pageKind -eq 'WHITE') { 'the dashboard is white ({0:0}%)' -f $pagePct } else { 'the dashboard is dark ({0:0}% white)' -f $pagePct }
        Set-Problem -Class 'local' -Why $why
        if ($Config.BadScreenSeconds -gt 0 -and ($now - $s.BadSinceUtc).TotalSeconds -ge $Config.BadScreenSeconds) {
            Invoke-Recovery -Config $Config -Why $why
        }
        elseif ($script:Status.State -ne 'RECOVERING') { Set-State 'LOADING' "waiting for the dashboard to draw - $why" }
        return 3
    }
    $s.BadSinceUtc = [DateTime]::MinValue

    # The page is fine. Is it on the screen?
    $screenKind = Get-ReadingKind -Percent $s.ScreenWhite -Config $Config
    if ($screenKind) {
        if ($s.CoveredSinceUtc -eq [DateTime]::MinValue) { $s.CoveredSinceUtc = $now; $s.CoverFixes = 0 }
        $age = ($now - $s.CoveredSinceUtc).TotalSeconds
        $why = 'the dashboard page is fine but the screen reads {0:0}% white - a window over it, or Edge not full screen' -f $s.ScreenWhite
        Set-Problem -Class 'local' -Why $why
        if ($s.CoverFixes -lt 2 -and $age -ge (10 * $s.CoverFixes)) {
            $s.CoverFixes++
            $did = Restore-BrowserWindow -Config $Config
            Write-Log ("{0}. Put Edge back: {1}." -f $why, $did) 'WARN'
        }
        elseif ($Config.BadScreenSeconds -gt 0 -and $age -ge ($Config.BadScreenSeconds + 20)) {
            $s.CoveredSinceUtc = [DateTime]::MinValue
            Restart-Browser -Config $Config -Why $why
            return 3
        }
        Set-State 'RECOVERING' $why
        return 3
    }
    $s.CoveredSinceUtc = [DateTime]::MinValue

    # Drawn, not white, not dark, on screen.
    if ($s.Recoveries -gt 0) {
        Write-Log ("The dashboard is back after {0} recovery step(s)." -f $s.Recoveries)
        $s.Recoveries = 0
        $s.LastRecoveryUtc = [DateTime]::MinValue
    }
    Set-State 'SHOWING'
    Set-Problem -Class 'ok'

    # --- scheduled reloads --------------------------------------------------------
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

function Invoke-UnsupervisedTick {
    # Edge's DevTools port is blocked by policy: keep Edge running, do the
    # daily refreshes by restarting it, and judge the screen by its reading
    # alone - the old watchdog's view.
    param([Parameter(Mandatory)]$Config)

    $s = $script:Session
    $now = [DateTime]::UtcNow
    if ((Get-BrowserHealth -Config $Config) -eq 'gone') {
        Set-Problem -Class 'local' -Why 'Edge is not running'
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
    $kind = Get-ReadingKind -Percent $s.ScreenWhite -Config $Config
    if ($kind) {
        if ($s.BadSinceUtc -eq [DateTime]::MinValue) { $s.BadSinceUtc = $now }
        Set-Problem -Class 'local' -Why ('the screen reads {0:0}% white' -f $s.ScreenWhite)
        if ($Config.BadScreenSeconds -gt 0 -and ($now - $s.BadSinceUtc).TotalSeconds -ge ($Config.BadScreenSeconds * 2)) {
            $s.BadSinceUtc = [DateTime]::MinValue
            Restart-Browser -Config $Config -Why ('the screen reads {0:0}% white' -f $s.ScreenWhite)
        }
    }
    else {
        $s.BadSinceUtc = [DateTime]::MinValue
        Set-Problem -Class 'ok'
    }
    foreach ($t in $Config.RefreshTimes) {
        if (Test-DailyDue -At $t -Tag 'refresh' -Done $s.TimedDone) { Restart-Browser -Config $Config -Why ('daily refresh at {0:hh\:mm}' -f $t) }
    }
    return [math]::Max(10, $Config.HealthCheckSeconds)
}

function Wait-NextTick {
    # Sleeps until the next tick, but wakes early for a control file or a
    # message in the inbox.
    param([double]$Seconds)

    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    $controls = @(@('kill.txt', 'relaunch.txt', 'refresh.txt', 'restart.txt', 'snapshot.txt') | ForEach-Object { Join-Path $Here $_ })
    while ($true) {
        $left = ($until - [DateTime]::UtcNow).TotalMilliseconds
        if ($left -le 0) { return }
        Start-Sleep -Milliseconds ([int][math]::Min(1000, $left))
        foreach ($c in $controls) {
            if (-not $script:ControlWarned.ContainsKey($c) -and (Test-Path -LiteralPath $c)) { return }
        }
        if ($script:WdOn -and -not $script:MessageProc -and (Test-Path -Path (Join-Path $script:InboxPath 'msg_*.json'))) { return }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
function Invoke-Main {
    $script:EchoLog = [bool]$ShowConsole
    Initialize-Native
    $consoleKind = Get-ConsoleHostKind
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
        $fallbackDir = if (Test-Path -LiteralPath $Here) { Join-Path $Here 'Logs' } else { Join-Path $ScriptDir 'Logs' }
        Initialize-Log -Config ([pscustomobject]@{ LogDir = $fallbackDir; LogName = "Mach2LauncherNG_${ComputerName}_$Instance.log"; RemoteLogDir = '' })
        Write-Log ("Mach2 Launcher {0} cannot start: {1}" -f $LauncherVersion, $_.Exception.Message) 'ERROR'
        return 1
    }
    if ($SetPassword) { return (Invoke-SetPassword -Config $config) }

    $script:DebugLogging = $config.DebugLogging
    Initialize-Log -Config $config
    Initialize-Status -Config $config
    Read-PersistentState
    $script:Session = New-Session

    Write-Log '##### Mach2 Launcher start #####'
    Write-Log ("Mach2 Launcher ver {0}, instance {1}, on {2} as {3}\{4}, PowerShell {5}, PID {6}." -f $LauncherVersion, $Instance, $ComputerName, $env:USERDOMAIN, $env:USERNAME, $PSVersionTable.PSVersion, $PID)
    Write-Log ("Config {0} (version {1}); dashboard {2}" -f $configFile, $(if ($config.JsonVersion) { $config.JsonVersion } else { '-' }), $config.DisplayUrl)
    foreach ($p in $config.Problems) { Write-Log $p 'WARN' }
    if ($config.LegacyPassword) { Write-Log 'The config holds a plain-text Password. It still works, but remove it once the encrypted file exists.' 'WARN' }
    if (-not $script:NativeReady) { Write-Log 'Could not load the native helpers (csc.exe blocked?). The console may stay visible and screens are read through WinForms.' 'WARN' }
    Write-Log ("Console window: {0} ({1})." -f $consoleState, $consoleKind) $(if ($consoleState -like 'still visible*') { 'WARN' } else { 'INFO' })

    try {
        $script:BootTime = (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime
        $script:Status.PcBootUtc = $script:BootTime.ToUniversalTime().ToString('o')
        Write-Log ("PC started {0:yyyy-MM-dd HH:mm:ss} ({1:0.0} h ago)." -f $script:BootTime, ((Get-Date) - $script:BootTime).TotalHours)
    }
    catch { $script:BootTime = (Get-Date).AddMilliseconds(-1 * [Environment]::TickCount) }
    $script:BootTimeUtc = $script:BootTime.ToUniversalTime()

    foreach ($m in @(Get-Monitors)) {
        Write-Log ("Screen {0}: {1}x{2} at {3},{4}{5}" -f $m.Device.TrimStart('\', '.'), $m.Width, $m.Height, $m.X, $m.Y, $(if ($m.Primary) { ' (primary)' } else { '' }))
    }

    # --- one launcher per instance, one watchdog per session ---------------------
    $mutex = New-Object Threading.Mutex($false, ('Local\Mach2LauncherNG-' + $Instance))
    $owned = $false
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        Write-Log "Another Mach2 Launcher is already running for $Instance in this session; exiting." 'WARN'
        return 0
    }
    $wdMutex = $null
    $stopReason = 'Mach2 Launcher stopped (Windows shutting down or the process ended).'
    try {
        if ($config.Watchdog) {
            $wdMutex = New-Object Threading.Mutex($false, 'Local\Mach2LauncherNG-Watchdog')
            $wdOwned = $false
            try { $wdOwned = $wdMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $wdOwned = $true }
            if ($wdOwned) {
                Initialize-WatchdogPaths -Folder $config.WatchdogPath
                if (-not (Test-Path -LiteralPath $config.WatchdogPath)) { New-Item -ItemType Directory -Path $config.WatchdogPath -Force | Out-Null }
                $script:WdOn = $true
            }
            else {
                $wdMutex.Dispose(); $wdMutex = $null
                Write-Log 'Watchdog = 1, but another instance on this PC is the watchdog already; this one only keeps its screen.' 'WARN'
            }
        }
        $script:Status.Watchdog = $script:WdOn
        $script:Supervised = $true

        if ($script:WdOn) {
            Write-WdLog ("Mach2 Launcher {0} started as the watchdog (instance {1}). WhiteLimit={2} High={3}% Low={4}% RebootAfter={5} min OutageRebootAfter={6} min Interval={7}s" -f `
                    $LauncherVersion, $Instance, $config.WhitePixelLevel, $config.WhiteHighPercent, $config.WhiteLowPercent, $config.RebootAfterMinutes, $config.OutageRebootMinutes, $config.HealthCheckSeconds)
            Write-WdLog "Log file: $script:WdLogPath"
            Write-WdLog "Event ledger: $script:LedgerPath"
            Stop-OldWatchdog
            $script:Session.Wd.LastOldCheckUtc = [DateTime]::UtcNow
            Resolve-PendingRestart -GraceSeconds $config.RestartConfirmSeconds
            $script:LoopState = Read-LoopGuardState
            if (-not (Test-Path -LiteralPath $script:LoopStatePath) -and (Test-LedgerHoldOpen)) {
                $script:LoopState.HoldReported = $true
                Write-WdLog 'The ledger shows the loop guard holding, but its state file is gone - taken as a manual reset. The hold is recorded as released once the dashboard is back.' 'WARN'
            }
            if ($script:LoopState.HoldReported) { $script:Status.LoopGuard = 'holding (since before this start)' }
            if (@($script:LoopState.Restarts).Count -gt 0) {
                Write-WdLog ("Loop guard: {0} restart(s) in a row since {1} have not yet been followed by a healthy dashboard (holds at {2})." -f @($script:LoopState.Restarts).Count, (Format-Utc $script:LoopState.Restarts[0]), $config.LoopGuardMaxRestarts) 'WARN'
            }
            try { if (-not (Test-Path -LiteralPath $script:InboxPath)) { New-Item -ItemType Directory -Path $script:InboxPath -Force | Out-Null } }
            catch { Write-WdLog ("Could not create the message inbox {0}: {1}" -f $script:InboxPath, $_.Exception.Message) 'WARN' }
            Remove-Item -LiteralPath (Join-Path $script:InboxPath 'showing.json') -Force -ErrorAction SilentlyContinue

            $window = switch -Wildcard ($consoleState) { 'hidden' { 'hidden' } 'hidden by the launcher' { 'hidden-by-watchdog' } 'none' { 'none' } 'still visible*' { 'not-hideable' } 'left visible*' { 'visible' } default { 'unknown' } }
            $null = Write-EventRow -EventType 'AGENT_START' -Severity 'INFO' `
                -Detail ("Mach2 Launcher {0} started, watchdog built in. Instance={1}, Interval={2}s, WhiteHigh={3}%, WhiteLow={4}%, RebootAfter={5}min, OutageRebootAfter={6}min, PS={7}, Console={8}, Window={9}" -f `
                    $LauncherVersion, $Instance, $config.HealthCheckSeconds, $config.WhiteHighPercent, $config.WhiteLowPercent, $config.RebootAfterMinutes, $config.OutageRebootMinutes, $PSVersionTable.PSVersion.ToString(), $consoleKind, $window)
            $script:Session.Wd.LastEventScanUtc = [DateTime]::UtcNow
            $null = Copy-SystemLogToLedger -Startup
        }
        else {
            Write-Log 'Not the watchdog (Watchdog = 0): this instance keeps its screen but never restarts the PC and writes no ledger.'
        }

        if ($config.Disabled) {
            Write-Log 'DisableStartup is set in the config; exiting.' 'WARN'
            Set-State 'DISABLED'
            $stopReason = 'Mach2 Launcher not started: DisableStartup is set.'
            Save-Status
            return 0
        }

        [void](Import-PasswordSeed -Config $config)
        if (Test-Path -LiteralPath $config.CredentialFile) {
            $script:Session.Login.CredStamp = [string](Get-Item -LiteralPath $config.CredentialFile).LastWriteTimeUtc.Ticks
        }
        elseif (-not $config.LegacyPassword) {
            Write-Log 'No sign-in password is stored, so every sign-in needs a person. To sign in unattended, drop password.seed into the instance folder.' 'WARN'
        }

        $script:EdgePath = Find-EdgePath -Configured $config.EdgePath
        Write-Log ("Edge: {0} ({1})" -f $script:EdgePath, (Get-Item -LiteralPath $script:EdgePath).VersionInfo.ProductVersion)
        $blockedBy = Get-RemoteDebuggingPolicy
        if ($blockedBy) {
            $script:Supervised = $false
            $script:UnsupervisedWhy = 'Edge policy RemoteDebuggingAllowed = 0: the launcher can only keep Edge open'
            Write-Log "Edge policy RemoteDebuggingAllowed = 0 ($blockedBy). The launcher can only start Edge and keep it open: no sign-in, page checks or reloads. The screen checks and restarts still work." 'ERROR'
        }
        elseif (-not $config.Supervised) {
            $script:Supervised = $false
            $script:UnsupervisedWhy = 'Supervised = 0 in the config: the launcher only keeps Edge open'
            Write-Log 'Supervised = 0: the launcher only starts Edge and keeps it open. Changing this takes a launcher restart.' 'WARN'
        }
        $script:Status.Supervised = $script:Supervised

        if ($config.StartupDelaySeconds -gt 0) {
            Write-Log "Waiting $($config.StartupDelaySeconds) s (StartupDelay)."
            Start-Sleep -Seconds $config.StartupDelaySeconds
        }
        # A TV is often slower to wake than the PC.
        $script:Session.Screen = Get-TargetScreen -Config $config -WaitSeconds $config.DisplayWaitSeconds

        $configStamp = (Get-Item -LiteralPath $configFile).LastWriteTimeUtc
        $startedAt = Get-Date
        $tickErrors = 0

        while ($true) {
            if ($ExitAfterSeconds -gt 0 -and ((Get-Date) - $startedAt).TotalSeconds -ge $ExitAfterSeconds) {
                Write-Log 'ExitAfterSeconds reached; stopping.'
                $stopReason = 'Mach2 Launcher stopped: ExitAfterSeconds (test run).'
                Stop-Browser -Config $config
                break
            }

            $sleep = 5
            $control = ''
            $messageUp = $false
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
                        if ($new.WatchdogPath -ne $config.WatchdogPath -or $new.Watchdog -ne $config.Watchdog) {
                            Write-Log 'Watchdog and WatchdogPath changes take a launcher restart; keeping the current ones.' 'WARN'
                            $new.WatchdogPath = $config.WatchdogPath
                            $new.Watchdog = $config.Watchdog
                        }
                        $config = $new
                        $script:Status.DisplayUrl = $config.DisplayUrl
                        $script:Status.UserName = $config.UserName
                        Clear-LoginBlock -Why 'the config changed'
                        if ($config.Disabled) {
                            Write-Log 'DisableStartup is now set; stopping.' 'WARN'
                            Stop-Browser -Config $config -Why 'DisableStartup'
                            Set-State 'DISABLED'
                            $stopReason = 'Mach2 Launcher stopped: DisableStartup was set.'
                            break
                        }
                        if ($relaunch -and $script:Browser) { Restart-Browser -Config $config -Why 'browser settings changed in the config' }
                        elseif ($script:Browser) { Reset-PageLoad -Config $config }
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

                $messageUp = [bool](@(Update-KioskMessage)[-1])
                $control = [string](@(Invoke-ControlFiles -Config $config)[-1])
                if ($control -eq 'exit') {
                    Set-State 'STOPPED' 'kill.txt'
                    $stopReason = 'Mach2 Launcher stopped by kill.txt.'
                    break
                }
                if ($control -eq 'restarting') { $sleep = 30 }
                elseif ($control -eq 'hold') {
                    Set-State 'HOLD' 'hold.txt is present: the launcher and the watchdog are not touching anything'
                    $sleep = 5
                }
                elseif ($script:Session.Wd.RestartPendingUtc) { $sleep = 10 }
                else {
                    Test-ScheduledRestart -Config $config
                    # After restart.txt or the daily restart the PC normally
                    # goes down within seconds. If it has not after five
                    # minutes, the restart was refused: carry on.
                    $restarting = $script:Status.State -eq 'RESTARTING_PC' -and
                    ([DateTime]::UtcNow - [DateTime]::Parse($script:Status.StateSinceUtc, $Invariant, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()).TotalSeconds -lt 300
                    if (-not $restarting) {
                        Update-ScreenReading -Config $config -MessageUp $messageUp
                        # The last value is the pause; anything a helper let
                        # slip into the output before it is ignored.
                        if ($script:Supervised) { $sleep = @(Invoke-SupervisedTick -Config $config)[-1] }
                        else { $sleep = @(Invoke-UnsupervisedTick -Config $config)[-1] }
                    }
                    else { $sleep = 30 }
                }
                try { Stop-OldLauncher -Config $config }
                catch { Write-Log "Looking for the old launcher failed: $(Get-ErrorText $_)" 'DEBUG' }
                Update-Watchdog -Config $config -Control $control -MessageUp $messageUp
                if ($script:Status.State -eq 'RESTARTING_PC') { $sleep = 10 }
                $tickErrors = 0
            }
            catch {
                $tickErrors++
                $text = Get-ErrorText $_
                $script:Status.LastError = $text
                Write-Log ("Unexpected error (#{0}): {1}" -f $tickErrors, $text) 'ERROR'
                if ($tickErrors -eq 6) {
                    $null = Write-EventRow -EventType 'AGENT_ERROR' -Severity 'WARNING' -StreakChecks $tickErrors -Detail ("Mach2 Launcher: {0} unexpected errors in a row, the last: {1}" -f $tickErrors, $text)
                }
                $sleep = [math]::Min(60, 5 * $tickErrors)
                if (($tickErrors % 5) -eq 0) {
                    try { Restart-Browser -Config $config -Why 'repeated unexpected errors' } catch {}
                }
            }

            Save-Status
            $pause = 2.0
            if (-not [double]::TryParse([string]$sleep, [Globalization.NumberStyles]::Float, $Invariant, [ref]$pause) -or $pause -lt 1) { $pause = 2.0 }
            Wait-NextTick -Seconds $pause
        }
    }
    catch {
        $stopReason = "Mach2 Launcher terminated unexpectedly: $(Get-ErrorText $_)"
        throw
    }
    finally {
        Disconnect-Cdp
        if ($script:MessageProc -and -not $script:MessageProc.HasExited) { try { $script:MessageProc.Kill() } catch {} }
        if ($script:Status.State -notin @('STOPPED', 'DISABLED', 'RESTARTING_PC')) { Set-State 'STOPPED' }
        Save-Status
        if ($script:WdOn) {
            $sev = if ($stopReason -like '*unexpectedly*') { 'CRITICAL' } else { 'INFO' }
            try { $null = Write-EventRow -EventType 'AGENT_STOP' -Severity $sev -Detail $stopReason -Durable } catch {}
            Write-WdLog "Watchdog loop exited. $stopReason" $(if ($sev -eq 'CRITICAL') { 'ERROR' } else { 'INFO' })
        }
        Write-Log '##### Mach2 Launcher end #####'
        if ($wdMutex) { try { $wdMutex.ReleaseMutex() } catch {}; $wdMutex.Dispose() }
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
