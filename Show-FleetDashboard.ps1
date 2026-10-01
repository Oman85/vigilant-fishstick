#Requires -Version 5.1
<#
.SYNOPSIS
    The terminal dashboard: the Mach2 kiosks (Mach2 Launcher NG, or the MWST
    watchdog) and the Power BI screens (PBI Launcher), in a console.

.DESCRIPTION
    The console version of Show-FleetManager.ps1 - the same fleet, the same
    file, the same actions - for a session with no desktop. The window is
    the usual way in: Start-KioskManager.bat.

    The terminal counterpart to the Power BI report. It reads
    MWST_FleetEvents.csv - the same single file Power BI reads - and redraws
    every few seconds. Reading a local file costs nothing, so the refresh is
    fast and needs no credentials: the dashboard opens instantly, read-only.

    Collection is the scheduled collector's job, not this tool's. Press S to
    run a scan on demand when you cannot wait for the next one.

    The screen is exception-first. When the fleet is healthy it is a green
    headline and an empty attention list; when something breaks, that becomes
    the biggest thing on screen. Freshness is always on display, because a
    dead collector otherwise looks exactly like a healthy fleet - every kiosk
    keeps showing its last known state.

    Mach2 kiosks and Power BI screens are on separate tabs, each with the
    columns its kiosks have data for: the watchdog's on Mach2, PBI
    Launcher's on PBI (what the screen is doing, for how long, which account
    Power BI is signed in as). The launcher details come from the collector's
    status file, so they are as fresh as the last scan; the P menu reads a
    kiosk live.

    The headline stays fleet-wide, and every tab label carries its own count
    of kiosks needing attention - trouble on the tab you are not looking at
    still shows. A third tab, Other, appears only if some kiosk's type is
    neither, so no kiosk can drop off the screen for having an unexpected
    type.

    Keys
      Tab / Shift+Tab, 1 2 3
         switch tabs: 1 Mach2, 2 PBI, 3 Other (when there is one)
      R  restart a kiosk over CIM/DCOM, with a warning message and
         countdown you can edit, and a typed confirmation before it fires.
         The list is the current tab's; a hostname from any tab can be typed
      C  open SCCM remote control (CmRcViewer.exe) for a kiosk, picked the
         same way
      M  show a message on a kiosk: a large window with an OK button and a
         countdown, put up by the kiosk's watchdog (V7.0 or later, or Mach2
         Launcher ver 1.00NG, which has the watchdog built in). The
         dashboard waits until it is on screen and says so, or says why not.
         Mach2 kiosks only
      P  Power BI launcher: reload the report, restart Edge, take a
         screenshot of the screen, hold/resume, stop, read the log, set the
         sign-in password, install/update or roll back. Power BI kiosks
      D  deploy to a kiosk: Mach2 Launcher ver 1.00NG (launcher and watchdog
         in one) on the Mach2 tab, PBI Launcher on the PBI tab, with or
         without a restart, or a dry run first. R in front of the kiosks
         rolls back to the old launcher (and, on Mach2, the MWST watchdog)
      S  run the collector now, showing its output
      A  keep the data fresh: run a scan every -AutoScanMinutes in the
         background, so the dashboard does the scheduled task's job for as
         long as it is open. While a scan runs, the line above the keys
         becomes a progress bar showing which kiosk it has reached
      F  toggle between all of the tab's kiosks and only those needing
         attention
      Q  quit (Ctrl+C also works)

    Credentials are asked for only when something needs them. If
    Config\kiosk-admin.cred.xml exists it is used silently; otherwise the same
    native Windows credential dialog the old dashboard used appears the first
    time you press R or S.

.PARAMETER CsvPath
    The events CSV. Default: next to the SharePoint master kiosk list if it is
    synced here, otherwise Logs\MWST_FleetEvents.csv.

.PARAMETER RefreshSeconds
    Redraw interval. Default 5. This only re-reads a local file.

.PARAMETER StaleMinutes
    Flag the data as stale when the last collector run is older than this.
    Default 45 (the collector runs every 15 minutes).

.PARAMETER AutoScanMinutes
    How often the A key's auto-scan runs a collection. Default 15, matching
    the scheduled collector.

.PARAMETER Tab
    Tab to open on: Mach2 (default), PBI, or Other.

.PARAMETER Once
    Draw one frame and exit.

.PARAMETER Ascii
    Plain ASCII instead of line-drawing and block characters.

.PARAMETER NoColour
    No colour at all. Colour is also skipped automatically if the terminal
    cannot do it.

.EXAMPLE
    .\Show-FleetDashboard.ps1

.EXAMPLE
    .\Show-FleetDashboard.ps1 -Once

.EXAMPLE
    .\Show-FleetDashboard.ps1 -Tab PBI
#>

[CmdletBinding()]
param(
    [string]$CsvPath,
    [ValidateRange(1, 3600)][int]$RefreshSeconds = 5,
    [ValidateRange(1, 10080)][int]$StaleMinutes = 45,
    [ValidateRange(1, 1440)][int]$AutoScanMinutes = 15,
    [ValidateSet('Mach2', 'PBI', 'Web', 'Other')][string]$Tab = 'Mach2',
    [switch]$Once,
    [switch]$Ascii,
    [switch]$NoColour,
    [string]$CredentialFile,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$RemoteControlPath,
    [string]$SccmSiteServer,
    [string]$RestartMessage = "IT is restarting this kiosk remotely. Please do not switch it off - it will come back on its own.",
    [ValidateRange(0, 3600)][int]$RestartWarningSeconds = 60
)

Set-StrictMode -Off

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'Lib\MWST.KioskList.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.Remote.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.Message.ps1')
. (Join-Path $ScriptDir 'Lib\PBI.Launcher.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.FleetState.ps1')

$Inv = [System.Globalization.CultureInfo]::InvariantCulture
if (-not $CredentialFile)   { $CredentialFile   = Join-Path $ScriptDir 'Config\kiosk-admin.cred.xml' }
$CollectorPath = Join-Path $ScriptDir 'Collect-MWSTFleet.ps1'
$DeployPbiPath = Join-Path $ScriptDir 'Deploy-PbiLauncher.ps1'
$DeployNgPath = Join-Path $ScriptDir 'Deploy-Mach2LauncherNG.ps1'
$KioskRootTemplate = '\\{0}\C$'
$PbiFolderRel = 'Users\Public\Documents\PbiLauncher'
$ScanProgressPath = Join-Path $ScriptDir 'Logs\autoscan.progress.json'

$script:RestartMessage        = $RestartMessage
$script:RestartWarningSeconds = $RestartWarningSeconds
$script:Credential            = $Credential
$script:ShowOnlyProblems      = $false
$script:Tab                   = $Tab
$script:MessageSeconds        = 60
$script:AutoScan              = $false
$script:NextScanAt            = $null
$script:ScanProc              = $null
$script:ScanStartedAt         = $null
$script:ScanProgress          = $null
$script:ScanNote              = ''


# ---------------------------------------------------------------------------
# Terminal: colour, glyphs, and a flicker-free redraw
# ---------------------------------------------------------------------------
$E = [char]27

function Enable-VirtualTerminal {
    # Windows PowerShell 5.1 does not turn on VT sequences by itself, so ANSI
    # colour only works if we ask the console for it. Returns $false when
    # there is no console to ask (output redirected), and the dashboard then
    # runs without colour rather than spraying escape codes into a file.
    try {
        if (-not ([System.Management.Automation.PSTypeName]'MwstVT').Type) {
            Add-Type -Namespace '' -Name MwstVT -MemberDefinition @'
[DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int nStdHandle);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
[DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
'@ -ErrorAction Stop
        }
        $handle = [MwstVT]::GetStdHandle(-11)
        $mode = 0
        if (-not [MwstVT]::GetConsoleMode($handle, [ref]$mode)) { return $false }
        if (($mode -band 0x4) -ne 0) { return $true }
        return [MwstVT]::SetConsoleMode($handle, $mode -bor 0x4)
    }
    catch { return $false }
}

$script:UseColour = (-not $NoColour) -and (Enable-VirtualTerminal)

# Palette. Colour carries meaning here and nothing else - status, and the one
# headline. Everything structural is dim grey so the eye goes to the colour.
$Colour = @{
    Text   = '38;2;228;233;240'
    Dim    = '38;2;122;134;154'
    Faint  = '38;2;80;90;106'
    Ok     = '38;2;74;222;128'
    Warn   = '38;2;250;204;21'
    Crit   = '38;2;248;113;113'
    Accent = '38;2;56;189;248'
    Head   = '1;38;2;236;241;248'
    OkBar   = '1;38;2;10;18;30;48;2;74;222;128'
    CritBar = '1;38;2;10;18;30;48;2;248;113;113'
    WarnBar = '1;38;2;10;18;30;48;2;250;204;21'
    TabOn   = '1;38;2;10;18;30;48;2;56;189;248'
}

function Paint {
    # Colour is applied only after text has been padded to its final width,
    # so invisible escape codes never take part in the column arithmetic.
    param([string]$Text, [string]$Style)
    if (-not $script:UseColour -or -not $Style) { return $Text }
    return "$E[${Style}m$Text$E[0m"
}

$Glyph = if ($Ascii) {
    @{ Rule = '-'; Dot = '*'; Spark = @('_', '.', '-', '=', '#'); Arrow = '>'; BarFull = '#'; BarEmpty = '.'; Ellipsis = '~' }
} else {
    @{
        Ellipsis = [string][char]0x2026
        Rule     = [string][char]0x2500
        Dot      = [string][char]0x25CF
        Spark    = @([string][char]0x2581, [string][char]0x2583, [string][char]0x2585, [string][char]0x2587, [string][char]0x2588)
        Arrow    = [string][char]0x276F
        BarFull  = [string][char]0x2588
        BarEmpty = [string][char]0x2591
    }
}

function Get-ConsoleSize {
    $w = 140; $h = 40
    try {
        $raw = $Host.UI.RawUI
        if ($raw -and $raw.WindowSize -and $raw.WindowSize.Width -gt 20) {
            $w = $raw.WindowSize.Width
            $h = $raw.WindowSize.Height
        }
    }
    catch { }
    return [pscustomobject]@{ Width = $w; Height = $h }
}

function Fit {
    # Truncate or pad to an exact visible width.
    param([string]$Text, [int]$Width)
    if ($null -eq $Text) { $Text = '' }
    if ($Width -le 0) { return '' }
    if ($Text.Length -gt $Width) {
        if ($Width -le 1) { return $Text.Substring(0, $Width) }
        return $Text.Substring(0, $Width - 1) + $Glyph.Ellipsis
    }
    return $Text.PadRight($Width)
}

$script:LastSize = $null

function Write-Frame {
    <#
        Redraws by parking the cursor at the top and overwriting, clearing
        each line as it goes. Clear-Host on every cycle - what the old
        dashboard did - makes the whole screen blink several times a minute.
    #>
    param([System.Collections.Generic.List[string]]$Lines, $Size)

    if (-not $script:LastSize -or $script:LastSize.Width -ne $Size.Width -or $script:LastSize.Height -ne $Size.Height) {
        Clear-Host
        $script:LastSize = $Size
    }

    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Size.Height - 1; $i++) {
        $line = if ($i -lt $Lines.Count) { $Lines[$i] } else { '' }
        [void]$sb.Append($line)
        if ($script:UseColour) { [void]$sb.Append("$E[K") }   # erase the rest of the line
        if ($i -lt $Size.Height - 2) { [void]$sb.Append("`r`n") }
    }

    try {
        [Console]::SetCursorPosition(0, 0)
        [Console]::Write($sb.ToString())
    }
    catch {
        Clear-Host
        Write-Host $sb.ToString()
    }
}


# ---------------------------------------------------------------------------
# Reading the fleet CSV
#
# The reading itself - Read-FleetState, the status ranks, Format-Minutes -
# lives in Lib\MWST.FleetState.ps1, shared with the Kiosk Fleet Manager
# window (Show-FleetManager.ps1) so both show the same fleet. What is left
# here is how this screen draws it.
# ---------------------------------------------------------------------------
function Resolve-EventsCsv {
    return (Resolve-FleetEventsCsv -ScriptDir $ScriptDir -CsvPath $CsvPath)
}

function Get-StatusStyle {
    param([string]$Status)
    if ($Status -eq 'OK') { return $Colour.Ok }
    if ($Status -eq 'INACTIVE') { return $Colour.Faint }
    if ($Status -in $CriticalStatuses) { return $Colour.Crit }
    if ($Status -in $WarningStatuses) { return $Colour.Warn }
    return $Colour.Dim
}

function Get-PbiDisplay {
    <#
        What the PBI tab shows for a kiosk's launcher, from the collector's
        last scan: state, how long in it, signed-in account, version.
    #>
    param($Kiosk)

    $out = [pscustomobject]@{ State = ''; For = ''; Account = ''; Version = ''; Style = $Colour.Dim; Known = $false }
    $p = $Kiosk.Pbi
    if (-not $p) { return $out }
    $out.Known = $true
    if (-not $p.Installed) {
        $out.State = if ($p.LegacyLauncher) { 'old launcher' } else { 'no launcher' }
        $out.Style = $Colour.Faint
        return $out
    }
    $inst = @($p.Instances)
    if ($inst.Count -eq 0) {
        $out.State = 'not started'
        $out.Style = $Colour.Warn
        return $out
    }
    $i = $inst[0]
    $out.State = if ($inst.Count -gt 1) { (($inst | ForEach-Object { $_.State }) -join '/') } else { [string]$i.State }
    $out.For = Format-Minutes $i.StateMinutes
    $out.Account = [string]$i.SignedInAs
    $out.Version = [string]$i.Version
    $out.Style = switch ([string]$i.State) {
        'SHOWING'  { $Colour.Ok }
        'BROWSING' { $Colour.Accent }
        { $_ -in @('LOADING', 'SIGNING_IN', 'LAUNCHING', 'STARTING', 'RESTARTING_PC') } { $Colour.Text }
        { $_ -in @('SIGNIN_BLOCKED', 'ERROR', 'STOPPED') } { $Colour.Crit }
        default    { $Colour.Warn }
    }
    if ($i.HostStatus -eq 'LAUNCHER_STALE') { $out.State = "($($i.State))"; $out.Style = $Colour.Crit }
    return $out
}

function Get-Sparkline {
    param($Entry, [string[]]$DayKeys, [int]$Max)

    if ($Max -lt 1) { $Max = 1 }
    $out = ''
    foreach ($k in $DayKeys) {
        $n = 0
        if ($Entry.Days.ContainsKey($k)) { $n = $Entry.Days[$k] }
        if ($n -le 0) {
            $out += if ($Ascii) { ' ' } else { [string][char]0x00B7 }
        }
        else {
            $idx = [int][math]::Ceiling(($n / [double]$Max) * ($Glyph.Spark.Count - 1))
            if ($idx -lt 0) { $idx = 0 }
            if ($idx -ge $Glyph.Spark.Count) { $idx = $Glyph.Spark.Count - 1 }
            $out += $Glyph.Spark[$idx]
        }
    }
    return $out
}


# ---------------------------------------------------------------------------
# Credentials - asked for only when something actually needs them
# ---------------------------------------------------------------------------
function Add-CredUIType {
    if (([System.Management.Automation.PSTypeName]'MwstCredUI').Type) { return }
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

function Show-CredentialPrompt {
    param(
        [string]$Caption = 'MWST Fleet Dashboard',
        [string]$Message = 'Enter the AD account with admin rights on the kiosks'
    )

    Add-CredUIType

    $info = New-Object MwstCredUI+CREDUI_INFO
    $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf([type][MwstCredUI+CREDUI_INFO])
    $info.hwndParent = [IntPtr]::Zero
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

function Get-FleetCredential {
    # The saved DPAPI credential first - the collector already uses it, so
    # there is usually nothing to type. Otherwise ask, once, and keep it for
    # the rest of the session.
    if ($script:Credential) { return $script:Credential }

    if (Test-Path -LiteralPath $CredentialFile) {
        try {
            $script:Credential = Import-StoredCredential -Path $CredentialFile
            return $script:Credential
        }
        catch {
            Write-Host "Saved credential could not be read: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    try { $script:Credential = Show-CredentialPrompt }
    catch {
        Write-Host "Credential dialog failed ($($_.Exception.Message)); falling back to a prompt." -ForegroundColor Yellow
        $user = Read-Host 'AD admin username (DOMAIN\user)'
        if (-not [string]::IsNullOrWhiteSpace($user)) {
            $script:Credential = New-Object System.Management.Automation.PSCredential(
                $user, (Read-Host "Password for $user" -AsSecureString))
        }
    }
    return $script:Credential
}


# ---------------------------------------------------------------------------
# Kiosk picker, shared by the restart and remote-control menus
# ---------------------------------------------------------------------------
function Get-KioskHostName {
    # Normalises a hand-typed name ("  \\PC-01 " -> "PC-01") and rejects
    # anything that clearly is not one, so junk never reaches a restart.
    param([string]$Text)

    if (-not $Text) { return $null }
    $name = $Text.Trim().Trim('\')
    if ($name -match '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') { return $name }
    return $null
}

function Write-KioskList {
    param([array]$Hosts)

    if (-not $Hosts -or $Hosts.Count -eq 0) {
        Write-Host '  Nothing on screen - type a hostname instead.' -ForegroundColor Yellow
        return
    }

    for ($i = 0; $i -lt $Hosts.Count; $i++) {
        $k = $Hosts[$i]
        $colour = Get-StatusConsoleColour $k.Status
        # Power BI kiosks: what the launcher was doing at the last scan.
        # Mach2 kiosks: the watchdog version.
        $ver = if ($k.Pbi) {
            $pd = Get-PbiDisplay -Kiosk $k
            $as = if ($pd.Account) { " as $($pd.Account)" } else { '' }
            "  $($pd.State)$as"
        }
        elseif ($k.StatusRow -and $k.StatusRow.AgentVersion) { "  v$($k.StatusRow.AgentVersion)" }
        else { '' }
        Write-Host ('  {0,3}) ' -f ($i + 1)) -NoNewline
        Write-Host ('{0,-16} {1,-6} {2,-18} [{3}]{4}' -f $k.Host, (Get-ShortType $k.Type), $k.Location, $k.Status, $ver) -ForegroundColor $colour
    }
}

function Resolve-KioskSelection {
    param([string]$Selection, [array]$Hosts)

    $idx = 0
    if ([int]::TryParse($Selection, [ref]$idx)) {
        if ($Hosts -and $idx -ge 1 -and $idx -le $Hosts.Count) { return $Hosts[$idx - 1].Host }
        Write-Host 'No kiosk with that number on screen.' -ForegroundColor Red
        Start-Sleep -Seconds 2
        return $null
    }

    $name = Get-KioskHostName $Selection
    if (-not $name) {
        Write-Host 'Not a valid hostname.' -ForegroundColor Red
        Start-Sleep -Seconds 2
    }
    return $name
}


# ---------------------------------------------------------------------------
# R - restart a kiosk
# ---------------------------------------------------------------------------
function Get-RestartWarningSummary {
    if ($script:RestartWarningSeconds -le 0) { return 'no warning - the kiosk restarts immediately' }
    if ([string]::IsNullOrWhiteSpace($script:RestartMessage)) {
        return ('{0}s countdown dialog, no message text' -f $script:RestartWarningSeconds)
    }
    return ('{0}s: "{1}"' -f $script:RestartWarningSeconds, $script:RestartMessage)
}

function Set-RestartMessageInteractive {
    Write-Host ''
    $current = if ([string]::IsNullOrWhiteSpace($script:RestartMessage)) { '(none)' } else { $script:RestartMessage }
    Write-Host ("Current message: {0}" -f $current) -ForegroundColor Cyan
    Write-Host "Blank keeps it, '-' removes the message entirely." -ForegroundColor DarkGray
    $new = Read-Host 'New message'
    if ([string]::IsNullOrWhiteSpace($new)) { return }

    if ($new.Trim() -eq '-') {
        $script:RestartMessage = ''
        Write-Host 'Message removed.' -ForegroundColor Yellow
    }
    else {
        $script:RestartMessage = $new.Trim()
        Write-Host 'Message updated.' -ForegroundColor Green
    }
    Start-Sleep -Seconds 1
}

function Set-RestartWarningSecondsInteractive {
    Write-Host ''
    Write-Host ('Current countdown: {0}s' -f $script:RestartWarningSeconds) -ForegroundColor Cyan
    Write-Host 'How long the kiosk shows the message before restarting (0 = at once, no dialog).' -ForegroundColor DarkGray
    $new = Read-Host 'New countdown in seconds'
    if ([string]::IsNullOrWhiteSpace($new)) { return }

    $secs = 0
    if (-not [int]::TryParse($new.Trim(), [ref]$secs) -or $secs -lt 0 -or $secs -gt 3600) {
        Write-Host 'Enter a whole number of seconds between 0 and 3600.' -ForegroundColor Red
        Start-Sleep -Seconds 2
        return
    }

    $script:RestartWarningSeconds = $secs
    Write-Host 'Countdown updated.' -ForegroundColor Green
    Start-Sleep -Seconds 1
}

function Invoke-KioskRestart {
    param([string]$Target, [System.Management.Automation.PSCredential]$Credential)

    # Over CIM/DCOM (Lib\MWST.Remote.ps1). A countdown of 0 restarts at
    # once, with nothing on the screen.
    $comment = if ($script:RestartWarningSeconds -gt 0) { "$($script:RestartMessage)".Trim() } else { '' }

    Write-Host ("`nRestarting {0} ({1}) ..." -f $Target, (Get-RestartWarningSummary)) -ForegroundColor Yellow
    $send = Send-KioskRestart -HostName $Target -Credential $Credential -WarningSeconds $script:RestartWarningSeconds -Comment $comment
    if ($send.Sent) { Write-Host ("Sent over {0}. It restarts and comes back on its own." -f $send.Via) -ForegroundColor Green }
    else { Write-Host ("Restart failed: {0}" -f $send.Detail) -ForegroundColor Red }
}

function Invoke-RestartMenu {
    param([array]$Hosts)

    while ($true) {
        Clear-Host
        $script:LastSize = $null
        Write-Host '=== Restart a kiosk ===' -ForegroundColor Yellow
        Write-Host ''

        Write-KioskList -Hosts $Hosts
        Write-Host ''
        Write-Host ('  Kiosk sees: {0}' -f (Get-RestartWarningSummary)) -ForegroundColor Cyan
        Write-Host '  [M] change message   [T] change countdown   [Enter] cancel' -ForegroundColor DarkGray
        Write-Host ''

        $selection = Read-Host 'Number or hostname to restart'
        if ([string]::IsNullOrWhiteSpace($selection)) { return }
        $selection = $selection.Trim()

        if ($selection -in @('M', 'm')) { Set-RestartMessageInteractive; continue }
        if ($selection -in @('T', 't')) { Set-RestartWarningSecondsInteractive; continue }

        $target = Resolve-KioskSelection -Selection $selection -Hosts $Hosts
        if (-not $target) { continue }

        $confirm = Read-Host "Type YES to force-restart $target now"
        if ($confirm -cne 'YES') {
            Write-Host 'Cancelled.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }

        Invoke-KioskRestart -Target $target -Credential (Get-FleetCredential)

        Write-Host "`nPress any key to return to the dashboard..." -ForegroundColor White
        [Console]::ReadKey($true) | Out-Null
        return
    }
}


# ---------------------------------------------------------------------------
# C - SCCM remote control
# ---------------------------------------------------------------------------
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

function Start-KioskRemoteControl {
    param([string]$Target, [string]$ViewerPath, [System.Management.Automation.PSCredential]$Credential)

    $argList = @($Target)
    if (-not [string]::IsNullOrWhiteSpace($SccmSiteServer)) {
        $argList += "\\$($SccmSiteServer.Trim().Trim('\'))"
    }

    $startArgs = @{
        FilePath         = $ViewerPath
        ArgumentList     = $argList
        WorkingDirectory = (Split-Path -Parent $ViewerPath)
    }
    if ($Credential) { $startArgs.Credential = $Credential }

    $asWho = if ($Credential) { $Credential.UserName } else { "$env:USERDOMAIN\$env:USERNAME" }
    Write-Host ("`nOpening remote control for {0} as {1} ..." -f $Target, $asWho) -ForegroundColor Yellow
    try {
        Start-Process @startArgs
        Write-Host 'Viewer launched - it opens in its own window, the dashboard keeps refreshing.' -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host ("Could not launch the viewer: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $false
    }
}

function Invoke-RemoteControlMenu {
    param([array]$Hosts, [string]$ViewerPath)

    # Remote control rights normally follow the signed-in console user, so
    # default to them and let U switch to the kiosk-admin account.
    $useAdmin = $false

    while ($true) {
        Clear-Host
        $script:LastSize = $null
        Write-Host '=== Remote control a kiosk (SCCM) ===' -ForegroundColor Yellow
        Write-Host ''

        if (-not $ViewerPath -or -not (Test-Path -LiteralPath $ViewerPath)) {
            Write-Host 'CmRcViewer.exe (SCCM remote control) was not found on this machine.' -ForegroundColor Red
            Write-Host 'Install the Configuration Manager console, or start the dashboard with' -ForegroundColor DarkGray
            Write-Host '-RemoteControlPath <path to CmRcViewer.exe>.' -ForegroundColor DarkGray
            Write-Host "`nPress any key to return..." -ForegroundColor White
            [Console]::ReadKey($true) | Out-Null
            return
        }

        Write-KioskList -Hosts $Hosts
        Write-Host ''
        $asWho = if ($useAdmin) { 'the kiosk-admin account' } else { "$env:USERDOMAIN\$env:USERNAME" }
        Write-Host ('  Connect as: {0}' -f $asWho) -ForegroundColor Cyan
        Write-Host '  [U] switch account   [Enter] cancel' -ForegroundColor DarkGray
        Write-Host ''

        $selection = Read-Host 'Number or hostname to remote control'
        if ([string]::IsNullOrWhiteSpace($selection)) { return }
        $selection = $selection.Trim()

        if ($selection -in @('U', 'u')) { $useAdmin = -not $useAdmin; continue }

        $target = Resolve-KioskSelection -Selection $selection -Hosts $Hosts
        if (-not $target) { continue }

        $cred = if ($useAdmin) { Get-FleetCredential } else { $null }
        if (Start-KioskRemoteControl -Target $target -ViewerPath $ViewerPath -Credential $cred) {
            Start-Sleep -Seconds 2
            return
        }

        Write-Host "`nPress any key to return to the menu..." -ForegroundColor White
        [Console]::ReadKey($true) | Out-Null
    }
}


# ---------------------------------------------------------------------------
# M - show a message on a kiosk
# ---------------------------------------------------------------------------
function Test-AgentAtLeast {
    # Whether a reported agent version is at least $Minimum. "legacy" and
    # anything else unparseable is not.
    param([string]$Version, [string]$Minimum)
    $v = $null; $min = $null
    # Mach2 Launcher ver 1.00NG and later: the watchdog built into the
    # launcher, with everything the V7.0 watchdog could do.
    if ("$Version".Trim() -match '^\d+\.\d+NG$') { return $true }
    if (-not [version]::TryParse("$Version".Trim(), [ref]$v)) { return $false }
    [void][version]::TryParse($Minimum, [ref]$min)
    return ($v -ge $min)
}

function Invoke-MessageMenu {
    param([array]$Hosts)

    while ($true) {
        Clear-Host
        $script:LastSize = $null
        Write-Host '=== Show a message on a kiosk (watchdog V7.0 or later) ===' -ForegroundColor Yellow
        Write-Host ''

        Write-KioskList -Hosts $Hosts
        Write-Host ''
        Write-Host ('  Stays on screen for {0}s unless OK is pressed.' -f $script:MessageSeconds) -ForegroundColor Cyan
        Write-Host '  [T] change how long   [Enter] cancel' -ForegroundColor DarkGray
        Write-Host ''

        $selection = Read-Host 'Number or hostname'
        if ([string]::IsNullOrWhiteSpace($selection)) { return }
        $selection = $selection.Trim()

        if ($selection -in @('T', 't')) {
            $new = Read-Host 'Seconds on screen (5-900)'
            $secs = 0
            if ([int]::TryParse("$new".Trim(), [ref]$secs) -and $secs -ge 5 -and $secs -le 900) { $script:MessageSeconds = $secs }
            elseif (-not [string]::IsNullOrWhiteSpace($new)) {
                Write-Host 'Enter a whole number of seconds between 5 and 900.' -ForegroundColor Red
                Start-Sleep -Seconds 2
            }
            continue
        }

        $target = Resolve-KioskSelection -Selection $selection -Hosts $Hosts
        if (-not $target) { continue }

        # Only a known old version is refused here. A typed hostname, or a
        # kiosk upgraded since the last scan, is left to the send itself,
        # which checks for the inbox a V7.0 watchdog creates.
        $known = @($Hosts | Where-Object { $_.Host -eq $target }) | Select-Object -First 1
        if ($known -and $known.Tab -eq 'PBI' -and -not $known.HasWatchdog) {
            Write-Host ''
            Write-Host "$target is a Power BI screen. It has no watchdog to show a message; P has what PBI Launcher can do." -ForegroundColor Red
            Wait-AnyKey 'Press any key to return to the menu...'
            continue
        }
        $ver = if ($known -and $known.StatusRow) { [string]$known.StatusRow.AgentVersion } else { '' }
        if ($ver -and -not (Test-AgentAtLeast -Version $ver -Minimum '7.0')) {
            Write-Host ''
            Write-Host "$target runs watchdog v$ver. Messages need V7.0 or later." -ForegroundColor Red
            Write-Host "`nPress any key to return to the menu..." -ForegroundColor White
            [Console]::ReadKey($true) | Out-Null
            continue
        }

        Write-Host ''
        Write-Host "Message for $target. One line; type \n where a new line should start." -ForegroundColor Cyan
        $text = Read-Host '>'
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        $text = $text.Trim().Replace('\n', "`n")

        $confirm = Read-Host ("Show it on {0} for up to {1}s? (y/N)" -f $target, $script:MessageSeconds)
        if ($confirm -notin @('y', 'Y')) {
            Write-Host 'Cancelled.' -ForegroundColor Yellow
            Start-Sleep -Seconds 1
            continue
        }

        Write-Host ''
        $r = Invoke-KioskMessage -HostName $target -Text $text -Seconds $script:MessageSeconds -Credential (Get-FleetCredential) `
                                 -Progress { param($s) Write-Host "  $s" -ForegroundColor DarkCyan }
        $colour = switch ($r.Status) {
            'SHOWN'        { 'Green' }
            'ACKNOWLEDGED' { 'Green' }
            'TIMEOUT'      { 'Cyan' }
            default        { 'Red' }
        }
        Write-Host ''
        Write-Host ("  {0}: {1}" -f $r.Status, $r.Detail) -ForegroundColor $colour
        Write-Host "`nPress any key to return to the dashboard..." -ForegroundColor White
        [Console]::ReadKey($true) | Out-Null
        return
    }
}


# ---------------------------------------------------------------------------
# P - PBI Launcher on a Power BI kiosk
#
# Everything goes through the kiosk's admin share, as the collector's reads
# do. The launcher watches its folder for control files - refresh.txt,
# relaunch.txt, snapshot.txt, hold.txt, kill.txt - and acts within a couple
# of seconds, deleting the file (all but hold.txt) to say it has.
# ---------------------------------------------------------------------------
$PbiStaleMinutes = 5
$SnapshotDir = Join-Path $ScriptDir 'Logs\snapshots'

function Wait-AnyKey {
    param([string]$Text = 'Press any key to return...')
    Write-Host "`n$Text" -ForegroundColor White
    [Console]::ReadKey($true) | Out-Null
}

function Get-StatusConsoleColour {
    param([string]$Status)
    if ($Status -eq 'OK') { return 'Green' }
    if ($Status -eq 'INACTIVE') { return 'DarkGray' }
    if ($Status -in $CriticalStatuses) { return 'Red' }
    return 'Yellow'
}

function Get-PbiHosts {
    # The P menu's list: the Power BI kiosks on screen, or - from another
    # tab, or when the filter hides them all - every Power BI kiosk.
    param($State, [array]$Shown)
    $list = @($Shown | Where-Object { $_.Tab -eq 'PBI' -or @($_.Tabs) -contains 'PBI' })
    if ($list.Count -eq 0 -and $State) { $list = @($State.Hosts | Where-Object { $_.Tab -eq 'PBI' -or @($_.Tabs) -contains 'PBI' }) }
    return $list
}

function Open-PbiKiosk {
    # The kiosk's admin share, authenticated with the fleet credential.
    # $null, having said why, when the kiosk cannot be read.
    param([string]$HostName)

    $root = $KioskRootTemplate -f $HostName
    $drive = $null
    if ($root.StartsWith('\\')) {
        Write-Host "Connecting to $HostName ..." -ForegroundColor DarkCyan
        $reach = Test-HostReachable -HostName $HostName
        if (-not $reach.Ok) {
            Write-Host "$HostName is not reachable: $($reach.Error)" -ForegroundColor Red
            return $null
        }
        try { $drive = Connect-KioskShare -Folder "$root\Users" -Credential (Get-FleetCredential) }
        catch {
            # An open session to the kiosk under another name refuses a
            # second one, but the share may well be readable through it.
            if (-not (Test-Path -LiteralPath "$root\Users")) {
                Write-Host "Cannot open ${root}: $($_.Exception.Message)" -ForegroundColor Red
                return $null
            }
        }
    }
    if (-not (Test-Path -LiteralPath "$root\Users")) {
        Write-Host "Cannot read $root." -ForegroundColor Red
        Disconnect-KioskShare -Drive $drive
        return $null
    }
    # The launcher's folder for this kiosk's (first) Power BI screen: S1, S2
    # ... since 2.0.1, or the launcher's own folder on a kiosk not moved yet.
    $folder = Join-Path $root $PbiFolderRel
    foreach ($d in @(Get-ChildItem -LiteralPath $folder -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^S\d+$' } | Sort-Object Name)) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName "$HostName.json")) { $folder = $d.FullName; break }
    }
    return [pscustomobject]@{ Host = $HostName; Root = $root; Folder = $folder; Drive = $drive }
}

function Read-PbiKioskConfig {
    param($Kiosk)
    $path = Join-Path $Kiosk.Folder "$($Kiosk.Host).json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $c = ConvertFrom-Json -InputObject (Read-SharedText -Path $path)
        return @($c)[0]
    }
    catch { return $null }
}

function ConvertTo-KioskSharePath {
    # A path as the kiosk sees it (D:\Logs) -> the same place over the
    # network. C: is the kiosk root the menu already has open.
    param($Kiosk, [string]$Path)
    if ($Path -match '^([A-Za-z]):\\?(.*)$') {
        if ($Matches[1] -ieq 'C') { return (Join-Path $Kiosk.Root $Matches[2]) }
        return ('\\{0}\{1}$\{2}' -f $Kiosk.Host, $Matches[1].ToUpperInvariant(), $Matches[2])
    }
    return $Path
}

function Write-PbiLauncherLive {
    # Reads the launcher as it is right now and prints it. Returns the
    # observation.
    param($Kiosk, $Config)

    $obs = Get-PbiLauncherObservation -Root $Kiosk.Root -StaleMinutes $PbiStaleMinutes -HostName $Kiosk.Host
    if ($obs.Error) { Write-Host "  Could not read the launcher: $($obs.Error)" -ForegroundColor Red }

    $old = if ($obs.LegacyLauncher) { 'PowerBILauncher.exe is still on this kiosk' } else { 'not on this kiosk' }
    if (-not $obs.Installed) {
        Write-Host '  PBI Launcher is not installed.' -ForegroundColor Yellow
        Write-Host "  Old launcher: $old" -ForegroundColor DarkGray
        return $obs
    }

    Write-Host ('  Status     {0}' -f $obs.Status) -ForegroundColor (Get-StatusConsoleColour $obs.Status)
    if ($Config) {
        Write-Host ('  Report     {0}' -f $Config.DisplayURL) -ForegroundColor DarkGray
        Write-Host ('  Account    {0}' -f $Config.UserName) -ForegroundColor DarkGray
    }
    else {
        Write-Host ("  Config     {0}.json is missing or unreadable" -f $Kiosk.Host) -ForegroundColor Yellow
    }
    $pw = if (Test-Path -LiteralPath (Join-Path $Kiosk.Folder 'password.seed')) { 'a new one is waiting for the launcher (password.seed)' }
          elseif (@(Get-ChildItem -LiteralPath $Kiosk.Folder -Filter '*.cred' -File -ErrorAction SilentlyContinue).Count) { 'stored, encrypted for the kiosk account' }
          else { 'none stored - signing in needs a person' }
    Write-Host ('  Password   {0}' -f $pw) -ForegroundColor DarkGray
    Write-Host ('  Old one    {0}' -f $old) -ForegroundColor DarkGray
    if (Test-Path -LiteralPath (Join-Path $Kiosk.Folder 'hold.txt')) {
        Write-Host '  ON HOLD    hold.txt is in place: no checks, no reloads until [4] resumes' -ForegroundColor Yellow
    }
    if (Test-Path -LiteralPath (Join-Path $Kiosk.Folder 'kill.txt')) {
        Write-Host '  STOPPING   kill.txt is waiting - the launcher also stops at its next start while it is there' -ForegroundColor Yellow
    }

    foreach ($i in @($obs.Instances)) {
        Write-Host ''
        $age = if ($null -eq $i.AgeMinutes) { 'never' }
               elseif ($i.AgeMinutes -lt 1) { '{0}s ago' -f [int][math]::Max(0, $i.AgeMinutes * 60) }
               else { (Format-Minutes $i.AgeMinutes) + ' ago' }
        Write-Host ('  {0}  {1} for {2}' -f $i.Instance, $i.State, (Format-Minutes $i.StateMinutes)) -ForegroundColor (Get-StatusConsoleColour $i.HostStatus)
        if ($i.Detail) { Write-Host "     $($i.Detail)" -ForegroundColor Gray }
        $as = if ($i.SignedInAs) { $i.SignedInAs } else { '(not seen yet)' }
        Write-Host ('     signed in as {0}' -f $as) -ForegroundColor $(if ($i.HostStatus -eq 'WRONG_ACCOUNT') { 'Red' } else { 'Gray' })
        Write-Host ('     v{0}, Edge {1}, status written {2}' -f $i.LauncherVersion, $i.EdgeVersion, $age) -ForegroundColor DarkGray
        Write-Host ('     reloads {0}, sign-ins {1}, Edge starts {2}' -f $i.Reloads, $i.SignIns, $i.BrowserStarts) -ForegroundColor DarkGray
        if ($i.LastShownUtc) { Write-Host ('     report last on screen {0}' -f $i.LastShownUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray }
        if ($i.LastError) { Write-Host ('     last error: {0}' -f $i.LastError) -ForegroundColor DarkYellow }
    }
    if ($obs.PcBootUtc) {
        Write-Host ''
        Write-Host ('  PC up since {0} ({1})' -f $obs.PcBootUtc.ToLocalTime().ToString('yyyy-MM-dd HH:mm'), (Format-Minutes ([datetime]::UtcNow - $obs.PcBootUtc).TotalMinutes)) -ForegroundColor DarkGray
    }
    return $obs
}

function Send-PbiControlFile {
    # Drops a control file and waits for the launcher to take it. hold.txt
    # stays in place by design, so that one is not waited for.
    param($Kiosk, [string]$Name, [int]$WaitSeconds = 20)

    $path = Join-Path $Kiosk.Folder $Name
    try {
        [IO.File]::WriteAllText($path, ('{0} by {1}\{2} from Kiosk Fleet Manager' -f (Get-Date -Format s), $env:USERDOMAIN, $env:USERNAME))
    }
    catch {
        Write-Host "Could not write ${Name}: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    if ($Name -eq 'hold.txt') {
        Write-Host 'hold.txt is in place; the launcher holds within seconds.' -ForegroundColor Green
        return $true
    }

    Write-Host "Sent $Name, waiting for the launcher to take it ..." -ForegroundColor DarkCyan
    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Host 'The launcher has taken it.' -ForegroundColor Green
            return $true
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "Not taken within $WaitSeconds s - is the launcher running? The file stays, and the launcher acts on it when it next looks." -ForegroundColor Yellow
    return $false
}

function Get-PbiLauncherSnapshot {
    <#
        snapshot.txt makes the launcher save Status\<instance>.png and
        Status\<instance>.snapshot.json. This waits for them, copies the
        picture to Logs\snapshots and opens it. Returns the copy's path.
    #>
    param($Kiosk, $Observation, [switch]$NoOpen)

    $names = @($Observation.Instances | ForEach-Object { $_.Instance } | Where-Object { $_ })
    if ($names.Count -eq 0) { $names = @($Kiosk.Host) }
    $statusDir = Join-Path $Kiosk.Folder 'Status'
    $before = @{}
    foreach ($n in $names) {
        $p = Join-Path $statusDir "$n.snapshot.json"
        $before[$n] = if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).LastWriteTimeUtc } else { [datetime]::MinValue }
    }

    if (-not (Send-PbiControlFile -Kiosk $Kiosk -Name 'snapshot.txt')) { return $null }

    # With several launchers in one folder, whichever sees the file first
    # answers.
    Write-Host 'Waiting for the screenshot ...' -ForegroundColor DarkCyan
    $deadline = (Get-Date).AddSeconds(45)
    $info = $null
    $got = $null
    while (-not $info -and (Get-Date) -lt $deadline) {
        foreach ($n in $names) {
            $p = Join-Path $statusDir "$n.snapshot.json"
            if (-not (Test-Path -LiteralPath $p)) { continue }
            if ((Get-Item -LiteralPath $p).LastWriteTimeUtc -le $before[$n]) { continue }
            try {
                $j = ConvertFrom-Json -InputObject (Read-SharedText -Path $p)
                $info = @($j)[0]
                $got = $n
                break
            }
            catch { }   # caught mid-write; the next pass reads it
        }
        if (-not $info) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $info) {
        Write-Host 'No screenshot came back within 45 s.' -ForegroundColor Yellow
        return $null
    }

    Write-Host ''
    Write-Host ('  {0}  {1}' -f $info.State, $info.Detail) -ForegroundColor Gray
    if ($info.Url) { Write-Host "  $($info.Url)" -ForegroundColor DarkGray }
    if ($info.Title) { Write-Host "  title: $($info.Title)" -ForegroundColor DarkGray }
    if (@($info.Accounts).Count) { Write-Host ('  signed in as {0}' -f (@($info.Accounts) -join ', ')) -ForegroundColor DarkGray }
    if ($null -ne $info.Visuals) { Write-Host "  visuals on the page: $($info.Visuals)" -ForegroundColor DarkGray }
    if ($info.Error) {
        Write-Host "  No screenshot: $($info.Error)" -ForegroundColor Yellow
        return $null
    }

    $src = Join-Path $statusDir ([string]$info.Image)
    if (-not $info.Image -or -not (Test-Path -LiteralPath $src)) {
        Write-Host "  The picture is missing: $src" -ForegroundColor Yellow
        return $null
    }
    if (-not (Test-Path -LiteralPath $SnapshotDir)) { New-Item -ItemType Directory -Path $SnapshotDir -Force | Out-Null }
    $dest = Join-Path $SnapshotDir ('{0}_{1}_{2}.png' -f $Kiosk.Host, $got, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    Copy-Item -LiteralPath $src -Destination $dest -Force
    Write-Host "  Saved $dest" -ForegroundColor Green
    if (-not $NoOpen) {
        try { Invoke-Item -LiteralPath $dest }
        catch { Write-Host "  Could not open it: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    return $dest
}

function Read-FileTail {
    # The end of a file that is still being written to, without pulling all
    # of a large log across the network.
    param([string]$Path, [int]$Bytes = 262144)

    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        if ($fs.Length -gt $Bytes) { [void]$fs.Seek(-$Bytes, [IO.SeekOrigin]::End) }
        $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    }
    finally { $fs.Dispose() }
}

function Show-PbiLogTail {
    # The last entries of the launcher's log (CMTrace format), warnings in
    # yellow and errors in red.
    param($Kiosk, $Config, [int]$Count = 40)

    $dir = Join-Path $Kiosk.Folder 'Logs'
    $name = "PbiLauncher_$($Kiosk.Host).log"
    if ($Config) {
        if ($Config.PSObject.Properties['LogPath'] -and $Config.LogPath) { $dir = ConvertTo-KioskSharePath -Kiosk $Kiosk -Path ([string]$Config.LogPath) }
        if ($Config.PSObject.Properties['LogName'] -and $Config.LogName) { $name = [string]$Config.LogName }
    }
    $path = Join-Path $dir $name
    if (-not (Test-Path -LiteralPath $path)) {
        $newest = Get-ChildItem -LiteralPath $dir -Filter '*.log' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if (-not $newest) {
            Write-Host "No log at $path" -ForegroundColor Yellow
            return
        }
        $path = $newest.FullName
    }

    try { $text = Read-FileTail -Path $path }
    catch {
        Write-Host "Could not read ${path}: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    $entries = [regex]::Matches($text, '<!\[LOG\[(?<m>.*?)\]LOG\]!><time="(?<t>\d\d:\d\d:\d\d)[^"]*" date="(?<d>[^"]*)"[^>]*?type="(?<ty>\d)"',
        [Text.RegularExpressions.RegexOptions]::Singleline)
    Write-Host $path -ForegroundColor DarkGray
    Write-Host ''
    for ($i = [math]::Max(0, $entries.Count - $Count); $i -lt $entries.Count; $i++) {
        $e = $entries[$i]
        $colour = switch ($e.Groups['ty'].Value) { '3' { 'Red' } '2' { 'Yellow' } default { 'Gray' } }
        $d = $e.Groups['d'].Value
        if ($d -match '^(\d\d)-(\d\d)-\d{4}$') { $d = "$($Matches[2]).$($Matches[1])." }
        $msg = $e.Groups['m'].Value.TrimEnd() -replace "\r?\n", "`n                "
        Write-Host ('{0,-7}{1}  {2}' -f $d, $e.Groups['t'].Value, $msg) -ForegroundColor $colour
    }
    if ($entries.Count -eq 0) { Write-Host '(no entries)' -ForegroundColor DarkGray }
}

function Set-PbiSignInPassword {
    <#
        Hands a new Power BI password to the launcher as password.seed. The
        launcher encrypts it for the kiosk account (DPAPI), checks it reads
        back, wipes and deletes the seed, and retries a sign-in it had given
        up on.
    #>
    param($Kiosk, $Config)

    if (-not (Test-Path -LiteralPath $Kiosk.Folder)) {
        Write-Host 'PBI Launcher is not installed here - install it first ([I]).' -ForegroundColor Yellow
        return
    }
    $user = if ($Config -and $Config.UserName) { [string]$Config.UserName } else { '(the account in the kiosk config)' }
    Write-Host "New password for $user." -ForegroundColor Cyan
    Write-Host 'Only the password is used; the account stays the one in the config. Enter on its own cancels.' -ForegroundColor DarkGray
    $s1 = Read-Host 'Password' -AsSecureString
    if ($s1.Length -eq 0) { return }
    $s2 = Read-Host 'Again' -AsSecureString

    $b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s1)
    $b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s2)
    $p1 = $null
    try {
        $p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
        if ($p1 -cne [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)) {
            Write-Host 'The two did not match. Nothing was changed.' -ForegroundColor Red
            return
        }
        $seed = Join-Path $Kiosk.Folder 'password.seed'
        $tmp = "$seed.tmp"
        [IO.File]::WriteAllText($tmp, $p1, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath $tmp -Destination $seed -Force
    }
    catch {
        Write-Host "Could not write password.seed: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
    finally {
        $p1 = $null
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)
    }

    Write-Host 'password.seed written, waiting for the launcher to store it ...' -ForegroundColor DarkCyan
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath (Join-Path $Kiosk.Folder 'password.seed'))) {
            Write-Host 'Stored. The launcher uses it from the next sign-in on.' -ForegroundColor Green
            return
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Host 'Not taken yet - the launcher is not running, or is busy. It stores the password when it next starts.' -ForegroundColor Yellow
}

function Invoke-FleetScript {
    # Runs a deploy script here in the window, with the fleet credential.
    param([string]$Path, [hashtable]$Arguments)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Host "Not found: $Path" -ForegroundColor Red
        return
    }
    $cred = Get-FleetCredential
    if ($cred) { $Arguments.Credential = $cred }
    Write-Host ''
    try { & $Path @Arguments | Out-Host }
    catch { Write-Host "Failed: $($_.Exception.Message)" -ForegroundColor Red }
}

function Read-DeployMode {
    # Now / now with a restart / dry run. $null to cancel, otherwise the
    # switches to add, as a hashtable.
    param([string]$What, [string[]]$Targets, [string]$RestartLabel)

    Write-Host ''
    Write-Host ("{0}: {1}" -f $What, ($Targets -join ', ')) -ForegroundColor Cyan
    Write-Host '  [1] do it; it takes effect at the next logon' -ForegroundColor Cyan
    Write-Host ("  [2] do it, then {0}" -f $RestartLabel) -ForegroundColor Cyan
    Write-Host '  [W] dry run - show what would change, change nothing' -ForegroundColor Cyan
    Write-Host '  [Enter] cancel' -ForegroundColor DarkGray
    $c = ("$(Read-Host 'Choice')").Trim().ToUpperInvariant()
    if ($c -eq 'W') { return @{ WhatIf = $true } }
    if ($c -eq '1') {
        if ((Read-Host 'Go ahead? (y/N)') -notin @('y', 'Y')) { return $null }
        return @{}
    }
    if ($c -eq '2') {
        Write-Host 'Each kiosk restarts (with a 60 s warning on its screen), one at a time; the first one that fails stops the run.' -ForegroundColor Yellow
        if ((Read-Host ("Type YES to restart {0}" -f ($Targets -join ', '))) -cne 'YES') { return $null }
        return @{ Restart = $true }
    }
    return $null
}

function Invoke-PbiLauncherMenu {
    param($State, [array]$Shown)

    $hosts = @(Get-PbiHosts -State $State -Shown $Shown)
    Clear-Host
    $script:LastSize = $null
    Write-Host '=== PBI Launcher (Power BI kiosks) ===' -ForegroundColor Yellow
    Write-Host ''
    Write-KioskList -Hosts $hosts
    Write-Host ''
    $selection = Read-Host 'Number or hostname'
    if ([string]::IsNullOrWhiteSpace($selection)) { return }
    $target = Resolve-KioskSelection -Selection $selection.Trim() -Hosts $hosts
    if (-not $target) { return }

    $known = @($State.Hosts | Where-Object { $_.Host -eq $target }) | Select-Object -First 1
    if ($known -and $known.Tab -eq 'Mach2') {
        Write-Host "$target is a Mach2 kiosk: it runs the watchdog, not PBI Launcher." -ForegroundColor Red
        Wait-AnyKey
        return
    }

    $kiosk = Open-PbiKiosk -HostName $target
    if (-not $kiosk) { Wait-AnyKey; return }
    try {
        while ($true) {
            Clear-Host
            $script:LastSize = $null
            $where = if ($known -and $known.Location) { "  ($($known.Location))" } else { '' }
            Write-Host ('=== PBI Launcher on {0}{1} ===' -f $target, $where) -ForegroundColor Yellow
            Write-Host ''
            $config = Read-PbiKioskConfig -Kiosk $kiosk
            $obs = Write-PbiLauncherLive -Kiosk $kiosk -Config $config
            $hold = Test-Path -LiteralPath (Join-Path $kiosk.Folder 'hold.txt')

            Write-Host ''
            if ($obs.Installed) {
                Write-Host '  [1] reload the report    [2] restart Edge        [3] screenshot' -ForegroundColor Cyan
                Write-Host ('  [4] {0}[5] stop the launcher   [L] log' -f $(if ($hold) { 'resume               ' } else { 'hold (pause)         ' })) -ForegroundColor Cyan
                Write-Host '  [P] set the password     [I] update              [B] roll back to the old launcher' -ForegroundColor Cyan
            }
            else {
                Write-Host '  [I] install PBI Launcher (settings come from the old launcher)' -ForegroundColor Cyan
            }
            Write-Host '  [R] read again   [Enter] back to the dashboard' -ForegroundColor DarkGray
            Write-Host ''

            $c = ("$(Read-Host 'Choice')").Trim().ToUpperInvariant()
            if (-not $c) { return }
            if ($c -eq 'R') { continue }
            if (-not $obs.Installed -and $c -ne 'I') { continue }
            Write-Host ''

            # Not "continue" inside the switch: in PowerShell that only
            # leaves the switch, so a flag says whether to pause afterwards.
            $pause = $true
            switch ($c) {
                '1' { [void](Send-PbiControlFile -Kiosk $kiosk -Name 'refresh.txt') }
                '2' { [void](Send-PbiControlFile -Kiosk $kiosk -Name 'relaunch.txt') }
                '3' { [void](Get-PbiLauncherSnapshot -Kiosk $kiosk -Observation $obs) }
                '4' {
                    if ($hold) {
                        try {
                            [IO.File]::Delete((Join-Path $kiosk.Folder 'hold.txt'))
                            Write-Host 'hold.txt is gone; the launcher carries on within seconds.' -ForegroundColor Green
                        }
                        catch { Write-Host "Could not delete hold.txt: $($_.Exception.Message)" -ForegroundColor Red }
                    }
                    else {
                        Write-Host 'Hold leaves the screen as it is: no checks, no reloads, no sign-in until you resume.' -ForegroundColor DarkGray
                        if ((Read-Host 'Hold? (y/N)') -in @('y', 'Y')) { [void](Send-PbiControlFile -Kiosk $kiosk -Name 'hold.txt') }
                        else { $pause = $false }
                    }
                }
                '5' {
                    Write-Host 'Stop closes Edge and ends the launcher. The screen stays empty until the kiosk restarts or its user logs on again.' -ForegroundColor Yellow
                    if ((Read-Host "Type YES to stop PBI Launcher on $target") -ceq 'YES') { [void](Send-PbiControlFile -Kiosk $kiosk -Name 'kill.txt') }
                    else { $pause = $false }
                }
                'L' { Show-PbiLogTail -Kiosk $kiosk -Config $config }
                'P' { Set-PbiSignInPassword -Kiosk $kiosk -Config $config }
                { $_ -in @('I', 'B') } {
                    $rollback = ($c -eq 'B')
                    $what = if ($rollback) { 'Roll back to the old PowerBILauncher.exe' } elseif ($obs.Installed) { 'Update PBI Launcher' } else { 'Install PBI Launcher' }
                    $label = if ($rollback) { 'restart the kiosk and wait for it to come back' } else { 'restart the kiosk and wait for the report on screen' }
                    $mode = Read-DeployMode -What $what -Targets @($target) -RestartLabel $label
                    if ($null -eq $mode) { $pause = $false }
                    else {
                        $params = @{ Hosts = @($target) } + $mode
                        if ($rollback) { $params.Rollback = $true }
                        Invoke-FleetScript -Path $DeployPbiPath -Arguments $params
                    }
                }
                default { $pause = $false }
            }
            if ($pause) { Wait-AnyKey 'Press any key to go back to the kiosk...' }
        }
    }
    finally { Disconnect-KioskShare -Drive $kiosk.Drive }
}


# ---------------------------------------------------------------------------
# D - deploy to kiosks: Mach2 Launcher ver 1.00NG (launcher and watchdog in
# one) on the Mach2 tab, PBI Launcher on PBI
# ---------------------------------------------------------------------------
function Resolve-KioskSelections {
    # "3", "3,5", "PC-01 PC-02" -> host names. $null when any part is wrong.
    param([string]$Selection, [array]$Hosts)

    $out = @()
    foreach ($part in @($Selection -split '[,;\s]+' | Where-Object { $_ })) {
        $h = Resolve-KioskSelection -Selection $part -Hosts $Hosts
        if (-not $h) { return $null }
        if ($out -notcontains $h) { $out += $h }
    }
    if ($out.Count -eq 0) { return $null }
    return ,$out
}

function Invoke-DeployMenu {
    param($State, [array]$Hosts)

    $kind = $script:Tab
    Clear-Host
    $script:LastSize = $null
    if ($kind -eq 'Other') {
        Write-Host 'Deploying goes by kiosk type: Mach2 Launcher NG from the Mach2 tab, PBI Launcher from the PBI tab.' -ForegroundColor Yellow
        Write-Host 'Kiosks on the Other tab have a type in the kiosk list that is neither; fix the list first.' -ForegroundColor DarkGray
        Wait-AnyKey
        return
    }

    if ($kind -eq 'Mach2') {
        Write-Host '=== Deploy Mach2 Launcher ver 1.00NG (Mach2 kiosks) ===' -ForegroundColor Yellow
        Write-Host 'Installs or updates the launcher, which is the watchdog as well. Carries the settings over from Mach2Launcher.exe,' -ForegroundColor DarkGray
        Write-Host 'and retires that and the MWST watchdog. (The watchdog on its own: Deploy-MWSTAgent.ps1.)' -ForegroundColor DarkGray
    }
    else {
        Write-Host '=== Deploy PBI Launcher (Power BI kiosks) ===' -ForegroundColor Yellow
        Write-Host 'Installs or updates PBI Launcher, carrying the settings over from the old launcher, and retires that.' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-KioskList -Hosts $Hosts
    Write-Host ''
    Write-Host '  Put R in front to roll back to the old launcher instead (R 3,5).' -ForegroundColor DarkGray
    Write-Host '  Start with one kiosk. [Enter] cancels.' -ForegroundColor DarkGray
    Write-Host ''
    $selection = ("$(Read-Host 'Kiosks (numbers or hostnames, comma-separated)')").Trim()
    if (-not $selection) { return }

    $rollback = $false
    if ($selection -match '^[Rr]\s+(.+)$') {
        $rollback = $true
        $selection = $Matches[1]
    }
    $targets = Resolve-KioskSelections -Selection $selection -Hosts $Hosts
    if (-not $targets) { return }

    # A kiosk the dashboard knows to be of the other type is refused; a name
    # it has never seen is left to the deploy script.
    $wrong = @($targets | Where-Object {
            $name = $_
            $k = @($State.Hosts | Where-Object { $_.Host -eq $name }) | Select-Object -First 1
            $k -and $k.Tab -ne $kind
        })
    if ($wrong.Count) {
        Write-Host ('Not {0} kiosks: {1}. Nothing was done.' -f $kind, ($wrong -join ', ')) -ForegroundColor Red
        Wait-AnyKey
        return
    }

    if ($kind -eq 'Mach2') {
        $what = if ($rollback) { 'Roll back to Mach2Launcher.exe and the MWST watchdog' } else { 'Install / update Mach2 Launcher NG' }
        $label = if ($rollback) { 'restart each kiosk and wait for it to come back' } else { 'restart each kiosk and wait for the dashboard on screen' }
        $mode = Read-DeployMode -What $what -Targets $targets -RestartLabel $label
        if ($null -eq $mode) { return }
        $params = @{ Hosts = $targets } + $mode
        if ($rollback) { $params.Rollback = $true }
        Invoke-FleetScript -Path $DeployNgPath -Arguments $params
    }
    else {
        $what = if ($rollback) { 'Roll back to the old PowerBILauncher.exe' } else { 'Install / update PBI Launcher' }
        $label = if ($rollback) { 'restart each kiosk and wait for it to come back' } else { 'restart each kiosk and wait for the report on screen' }
        $mode = Read-DeployMode -What $what -Targets $targets -RestartLabel $label
        if ($null -eq $mode) { return }
        $params = @{ Hosts = $targets } + $mode
        if ($rollback) { $params.Rollback = $true }
        Invoke-FleetScript -Path $DeployPbiPath -Arguments $params
    }
    Write-Host ''
    Write-Host 'S (scan now) brings the result onto the dashboard.' -ForegroundColor DarkGray
    Wait-AnyKey 'Press any key to return to the dashboard...'
}


# ---------------------------------------------------------------------------
# S - run the collector now
# ---------------------------------------------------------------------------
function Invoke-ScanNow {
    Clear-Host
    $script:LastSize = $null
    Write-Host '=== Running a fleet scan ===' -ForegroundColor Yellow
    Write-Host ''

    if (-not (Test-Path -LiteralPath $CollectorPath)) {
        Write-Host "Collector not found at $CollectorPath" -ForegroundColor Red
        Write-Host "`nPress any key to return..." -ForegroundColor White
        [Console]::ReadKey($true) | Out-Null
        return
    }

    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CollectorPath)
    if (Test-Path -LiteralPath $CredentialFile) {
        $argv += @('-CredentialFile', $CredentialFile)
    }
    else {
        Write-Host 'No saved credential; the scan will run as you and may not reach the kiosks.' -ForegroundColor Yellow
        Write-Host 'Run Save-KioskCredential.ps1 once to fix that.' -ForegroundColor DarkGray
        Write-Host ''
    }

    & powershell.exe @argv

    Write-Host "`nPress any key to return to the dashboard..." -ForegroundColor White
    [Console]::ReadKey($true) | Out-Null
}


# ---------------------------------------------------------------------------
# A - auto-scan
#
# The same collection the scheduled task performs, run from here for as long
# as the dashboard is open. It runs as a separate hidden process so the screen
# keeps redrawing while a scan is in flight; a scan takes the better part of a
# minute against the whole fleet, and freezing the dashboard for that long
# every quarter of an hour would make it useless.
#
# If the collector is also running on a schedule, nothing collides: it takes a
# machine-wide lock and a second instance exits without scanning.
# ---------------------------------------------------------------------------
function Start-BackgroundScan {
    if ($script:ScanProc -and -not $script:ScanProc.HasExited) { return }

    if (-not (Test-Path -LiteralPath $CollectorPath)) {
        $script:ScanNote = 'collector missing'
        $script:AutoScan = $false
        return
    }

    $logDir = Join-Path $ScriptDir 'Logs'
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

    try {
        $script:ScanProgress  = $null
        $script:ScanStartedAt = Get-Date
        $script:ScanProc = Start-Process powershell.exe -PassThru -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $CollectorPath, '-CredentialFile', $CredentialFile,
                            '-ProgressFile', $ScanProgressPath) `
            -RedirectStandardOutput (Join-Path $logDir 'autoscan.out.txt') `
            -RedirectStandardError  (Join-Path $logDir 'autoscan.err.txt')
        $script:ScanNote = 'scanning'
    }
    catch {
        $script:ScanNote = 'scan failed to start'
        $script:ScanProc = $null
        $script:NextScanAt = (Get-Date).AddMinutes($AutoScanMinutes)
    }
}

function Read-ScanProgress {
    # The collector rewrites this file as it moves from kiosk to kiosk. A
    # file from an earlier run carries another PID and is ignored; one caught
    # mid-write fails to parse, and the last good reading simply stands.
    if (-not (Test-Path -LiteralPath $ScanProgressPath)) { return }
    try {
        $p = (Read-SharedText -Path $ScanProgressPath) | ConvertFrom-Json
        if ($p -and $p.Pid -eq $script:ScanProc.Id) { $script:ScanProgress = $p }
    }
    catch { }
}

function Update-ScanState {
    # Called once a second: follows a running scan, notices a finished one,
    # and starts the next one when it falls due.
    if ($script:ScanProc -and $script:ScanProc.HasExited) {
        $code = $script:ScanProc.ExitCode
        $script:ScanNote = if ($code -eq 0) { 'scanned ' + (Get-Date).ToString('HH:mm') } else { "scan exit $code" }
        $script:ScanProc = $null
        $script:ScanProgress = $null
        $script:NextScanAt = (Get-Date).AddMinutes($AutoScanMinutes)
    }
    elseif ($script:ScanProc) {
        Read-ScanProgress
    }

    if ($script:AutoScan -and -not $script:ScanProc -and $script:NextScanAt -and (Get-Date) -ge $script:NextScanAt) {
        Start-BackgroundScan
    }
}

function Enable-AutoScan {
    <#
        Turning auto-scan on schedules the next collection from the last one
        that actually happened, so switching it on next to a scheduled task -
        or just after a manual scan - does not trigger a redundant sweep of
        the whole fleet.
    #>
    param($State)

    if (-not (Test-Path -LiteralPath $CredentialFile)) {
        # Without the kiosk-admin credential every watchdog kiosk would come
        # back NO_ACCESS, and those false outages would be written into the
        # history as though they were real.
        $script:ScanNote = 'needs saved credential'
        return
    }

    $script:AutoScan = $true
    $next = Get-Date

    if ($State -and $State.LastCollected) {
        try {
            $lastUtc = [datetime]::ParseExact($State.LastCollected, "yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
            $candidate = $lastUtc.ToLocalTime().AddMinutes($AutoScanMinutes)
            if ($candidate -gt $next) { $next = $candidate }
        }
        catch { }
    }

    $script:NextScanAt = $next
}


# ---------------------------------------------------------------------------
# Tabs
# ---------------------------------------------------------------------------
function Get-VisibleTabs {
    # Mach2 and PBI are always there, even when empty, so that 1 and 2 never
    # change meaning. Other exists only while some kiosk belongs on it.
    param($State)

    $tabs = @('Mach2', 'PBI')
    # Web and Other exist only while some kiosk belongs on them.
    if (@($State.Hosts | Where-Object { $_.Tab -eq 'Web' -or @($_.Tabs) -contains 'Web' }).Count -gt 0) { $tabs += 'Web' }
    if (@($State.Hosts | Where-Object { $_.Tab -eq 'Other' }).Count -gt 0) { $tabs += 'Other' }
    return $tabs
}

function Select-Tab {
    # -Jump picks a tab by position (0 = the first), -Move steps through them
    # and wraps. With neither, it only makes sure the current tab still
    # exists - Other disappears once its last kiosk is reclassified.
    param($State, [int]$Move = 0, $Jump = $null)

    $tabs = @(Get-VisibleTabs -State $State)
    if ($null -ne $Jump) {
        if ($Jump -lt $tabs.Count) { $script:Tab = $tabs[$Jump] }
        return
    }

    $i = [array]::IndexOf($tabs, $script:Tab)
    if ($i -lt 0) { $i = 0; $Move = 0 }
    $script:Tab = $tabs[($i + $Move + $tabs.Count) % $tabs.Count]
}

function Get-TabHosts {
    param($State)
    # A kiosk is on every tab it has a screen for (Power BI on S1, Mach2 on S2).
    return @($State.Hosts | Where-Object { $_.Tab -eq $script:Tab -or @($_.Tabs) -contains $script:Tab })
}

function Get-ShownHosts {
    # What the table lists, and therefore what R and C offer by number - the
    # two must never disagree.
    param($State)

    $hosts = @(Get-TabHosts -State $State)
    if ($script:ShowOnlyProblems) { return @($hosts | Where-Object { Test-NeedsAttention $_ }) }
    return $hosts
}

function Get-TabBar {
    <#
        One label per tab, with its kiosk count and - in red, whichever tab is
        selected - how many of its kiosks need attention. Without colour the
        selected tab is bracketed instead.
    #>
    param($State)

    $tabs = @(Get-VisibleTabs -State $State)
    $bar = '  '
    for ($i = 0; $i -lt $tabs.Count; $i++) {
        $name  = $tabs[$i]
        $hosts = @($State.Hosts | Where-Object { $_.Tab -eq $name -or @($_.Tabs) -contains $name })
        $bad   = @($hosts | Where-Object { Test-NeedsAttention $_ }).Count
        $label = ' {0} {1} ({2}) ' -f ($i + 1), $name, $hosts.Count

        if ($name -eq $script:Tab) {
            $bar += if ($script:UseColour) { Paint $label $Colour.TabOn } else { "[$label]" }
        }
        else {
            $bar += if ($script:UseColour) { Paint $label $Colour.Dim } else { " $label " }
        }
        if ($bad -gt 0) {
            $bar += Paint (' {0} {1} need{2} attention' -f $Glyph.Dot, $bad, $(if ($bad -eq 1) { 's' } else { '' })) $Colour.Crit
        }
        $bar += '    '
    }
    return $bar
}


# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------
function Build-Frame {
    param($State, $Size)

    $w = $Size.Width
    $lines = New-Object System.Collections.Generic.List[string]
    $rule = $Glyph.Rule * $w

    # --- title bar
    $title = ' KIOSK FLEET  Mach2 Launcher NG + PBI Launcher'
    $clock = (Get-Date).ToString('ddd dd MMM  HH:mm:ss') + ' '
    $mid = $w - $title.Length - $clock.Length
    if ($mid -lt 0) { $mid = 0 }
    $lines.Add((Paint $title $Colour.Head) + (' ' * $mid) + (Paint $clock $Colour.Dim))
    $lines.Add((Paint $rule $Colour.Faint))

    if (-not $State.Ok) {
        $lines.Add('')
        $lines.Add((Paint (Fit "  $($State.Error)" $w) $Colour.Warn))
        $lines.Add('')
        # The comma matters: a bare "return $lines" lets the pipeline unroll
        # the list into a plain fixed-size array, and the caller can no longer
        # add the footer to it.
        return ,$lines
    }

    # --- headline: the one thing visible from across the room
    $attention = @($State.Hosts | Where-Object { Test-NeedsAttention $_ })
    $headText = if ($attention.Count -eq 0) {
        "  ALL $($State.Hosts.Count) KIOSKS OK  "
    }
    else {
        "  $($attention.Count) KIOSK$(if ($attention.Count -eq 1) { '' } else { 'S' }) NEED$(if ($attention.Count -eq 1) { 'S' } else { '' }) ATTENTION  "
    }
    $headStyle = if ($attention.Count -eq 0) { $Colour.OkBar } else { $Colour.CritBar }

    # --- freshness: a dead collector must never look like a healthy fleet
    # Prefer the sidecar's "last ran" over the CSV's "last changed": a quiet
    # fleet changes nothing for hours while still being checked every quarter
    # of an hour, and reporting the latter makes a healthy fleet look dead.
    $stamp = if ($State.LastRun) { $State.LastRun } else { $State.LastCollected }

    $freshText = 'collector has never run'
    $freshStyle = $Colour.Crit
    if ($stamp) {
        $lastUtc = $null
        try {
            $lastUtc = [datetime]::ParseExact($stamp, "yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv,
                [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
        }
        catch { }
        if ($lastUtc) {
            $mins = [int]((Get-Date).ToUniversalTime() - $lastUtc).TotalMinutes
            if ($mins -lt $StaleMinutes) {
                $freshText = if ($mins -le 1) { 'collected just now' } else { "collected $mins min ago" }
                $freshStyle = $Colour.Dim
            }
            elseif ($mins -lt 1440) {
                $freshText = "STALE - collector last ran $([int]($mins / 60)) h ago"
                $freshStyle = $Colour.Crit
            }
            else {
                $freshText = "STALE - collector last ran $([int]($mins / 1440)) days ago"
                $freshStyle = $Colour.Crit
            }
        }
    }

    $gap = $w - $headText.Length - $freshText.Length - 2
    if ($gap -lt 1) { $gap = 1 }
    $lines.Add((Paint $headText $headStyle) + (' ' * $gap) + (Paint $freshText $freshStyle) + ' ')
    $lines.Add('')

    # --- tabs. Everything above stays fleet-wide; everything below is for
    # the selected tab only.
    $lines.Add((Get-TabBar -State $State))

    $tabHosts     = @(Get-TabHosts -State $State)
    $tabAttention = @($tabHosts | Where-Object { Test-NeedsAttention $_ })

    # Columns only for data the tab actually has. PBI screens are ping-only:
    # no watchdog, no log, no uptime, and no reboot history unless the
    # collector was told to read every kiosk's event log.
    $showWatchdog = @($tabHosts | Where-Object { $_.HasWatchdog }).Count -gt 0
    $showLauncher = @($tabHosts | Where-Object { $_.Pbi }).Count -gt 0
    $showReboots  = @($tabHosts | Where-Object { $_.HasWatchdog -or $_.Days.Count -gt 0 }).Count -gt 0
    $types        = @($tabHosts | ForEach-Object { $_.Type } | Select-Object -Unique)
    $showType     = $types.Count -gt 1

    # --- counts by status
    $counts = @{}
    foreach ($k in $tabHosts) {
        if (-not $counts.ContainsKey($k.Status)) { $counts[$k.Status] = 0 }
        $counts[$k.Status]++
    }
    $chips = '  '
    # Known statuses in a fixed order, then anything else that turns up.
    $chipOrder = @('OK') + $CriticalStatuses + $WarningStatuses + @('INACTIVE')
    $chipOrder += @($counts.Keys | Where-Object { $_ -notin $chipOrder } | Sort-Object)
    foreach ($s in $chipOrder) {
        if (-not $counts.ContainsKey($s)) { continue }
        $chips += (Paint "$($Glyph.Dot) " (Get-StatusStyle $s)) + (Paint ("{0} {1}   " -f $counts[$s], $s) $Colour.Text)
    }
    # A row of zeros would claim these screens were watched and nothing
    # happened, when nothing was watched at all.
    if ($showReboots) {
        $reb = ($tabHosts | Measure-Object -Property Reboots24 -Sum).Sum
        $scr = ($tabHosts | Measure-Object -Property Script24 -Sum).Sum
        $eps = ($tabHosts | Measure-Object -Property Episodes24 -Sum).Sum
        $chips += (Paint ("| last 24h: {0} reboots ({1} by watchdog), {2} screen events" -f ([int]$reb), ([int]$scr), ([int]$eps)) $Colour.Dim)
    }
    $lines.Add($chips)
    $lines.Add('')

    # --- table
    if ($tabHosts.Count -eq 0) {
        $lines.Add((Paint "  No $($script:Tab) kiosks in the data." $Colour.Dim))
        return ,$lines
    }

    $shown = @(Get-ShownHosts -State $State)
    if ($script:ShowOnlyProblems -and $tabAttention.Count -eq 0) {
        $lines.Add((Paint '  Nothing on this tab needs attention. Press F to show all of it.' $Colour.Ok))
        $lines.Add('')
    }

    $maxDaily = 1
    foreach ($k in $tabHosts) {
        foreach ($v in $k.Days.Values) { if ($v -gt $maxDaily) { $maxDaily = $v } }
    }

    # Columns sized to the window; Location gives up space first. TYPE shows
    # the full type, because on a tab of mixed types the variant ("PBI - SR")
    # is the part that differs.
    $cHost = 15; $cStat = 21; $cWd = 9; $cAge = 7; $cUp = 7; $cVer = 7; $cReb = 8; $cSpark = 7
    $cLaunch = 14; $cFor = 5; $cAcct = 34; $cLver = 6
    $cType = [math]::Min(28, [math]::Max(4, [int]($types | Measure-Object -Property Length -Maximum).Maximum))
    $fixed = 2 + 2 + $cHost + 1 + 1 + $cStat
    if ($showType)     { $fixed += 1 + $cType }
    if ($showWatchdog) { $fixed += 1 + $cWd + 1 + $cAge + 1 + $cUp + 1 + $cVer }
    if ($showReboots)  { $fixed += 1 + $cReb + 1 + $cSpark }
    if ($showLauncher) {
        $fixed += 1 + $cLaunch + 1 + $cFor + 1 + $cAcct + 1 + $cLver + 1 + $cUp
        # In a narrow window the launcher columns give way before the
        # location does: the account first (its start is what matters), then
        # the version, then how long.
        $short = ($fixed + 1 + 10) - $w
        if ($short -gt 0) {
            $cut = [math]::Min($short, $cAcct - 14)
            $cAcct -= $cut
            $fixed -= $cut
            $short -= $cut
        }
        if ($short -gt 0) { $fixed -= 1 + $cLver; $short -= 1 + $cLver; $cLver = 0 }
        if ($short -gt 0) { $fixed -= 1 + $cFor; $cFor = 0 }
    }
    $cLoc = [math]::Max(8, [math]::Min(30, $w - $fixed - 1))

    $header = '  ' + '  ' + (Fit 'KIOSK' $cHost)
    if ($showType) { $header += ' ' + (Fit 'TYPE' $cType) }
    $header += ' ' + (Fit 'LOCATION' $cLoc) + ' ' + (Fit 'STATUS' $cStat)
    if ($showWatchdog) {
        $header += ' ' + (Fit 'WATCHDOG' $cWd) + ' ' + (Fit 'LOG' $cAge) + ' ' + (Fit 'UPTIME' $cUp) + ' ' + (Fit 'AGENT' $cVer)
    }
    if ($showReboots) { $header += ' ' + (Fit 'REB 24H' $cReb) + ' ' + (Fit '7 DAYS' $cSpark) }
    if ($showLauncher) {
        $header += ' ' + (Fit 'LAUNCHER' $cLaunch)
        if ($cFor) { $header += ' ' + (Fit 'FOR' $cFor) }
        $header += ' ' + (Fit 'SIGNED IN AS' $cAcct)
        if ($cLver) { $header += ' ' + (Fit 'VER' $cLver) }
        $header += ' ' + (Fit 'UPTIME' $cUp)
    }
    $lines.Add((Paint (Fit $header $w) $Colour.Dim))

    # Leave room for the footer.
    $available = $Size.Height - $lines.Count - 3
    $count = 0

    foreach ($k in $shown) {
        if ($count -ge $available) {
            $lines.Add((Paint ("  ... and {0} more - press F to filter" -f ($shown.Count - $count)) $Colour.Dim))
            break
        }

        $row = $k.StatusRow
        $style = Get-StatusStyle $k.Status

        $logAge = ''
        $uptime = ''
        $wd = ''
        $ver = ''
        if ($row) {
            if ($row.MinutesSinceLastLog) { $logAge = '{0}m' -f [int][double]$row.MinutesSinceLastLog }
            if ($row.UptimeHours) {
                $h = [double]$row.UptimeHours
                $uptime = if ($h -ge 48) { '{0}d' -f [int]($h / 24) } else { '{0}h' -f [int]$h }
            }
            $wd = switch ($row.WatchdogRunning) { 'TRUE' { 'running' } 'FALSE' { 'DEAD' } default { '' } }
            $ver = $row.AgentVersion
        }

        $rebText = if ($k.Reboots24 -gt 0) { '{0}' -f $k.Reboots24 } else { '' }
        if ($k.Script24 -gt 0) { $rebText = '{0} ({1})' -f $k.Reboots24, $k.Script24 }

        $line = '  ' + (Paint $Glyph.Dot $style) + ' ' + (Paint (Fit $k.Host $cHost) $Colour.Text)
        if ($showType) { $line += ' ' + (Paint (Fit $k.Type $cType) $Colour.Dim) }
        $line += ' ' + (Paint (Fit $k.Location $cLoc) $Colour.Text) +
                 ' ' + (Paint (Fit $k.Status $cStat) $style)
        if ($showWatchdog) {
            $line += ' ' + (Paint (Fit $wd $cWd) $(if ($wd -eq 'DEAD') { $Colour.Crit } else { $Colour.Dim })) +
                     ' ' + (Paint (Fit $logAge $cAge) $Colour.Dim) +
                     ' ' + (Paint (Fit $uptime $cUp) $Colour.Dim) +
                     ' ' + (Paint (Fit $ver $cVer) $Colour.Dim)
        }
        if ($showReboots) {
            $line += ' ' + (Paint (Fit $rebText $cReb) $(if ($k.Script24 -gt 0) { $Colour.Warn } else { $Colour.Dim })) +
                     ' ' + (Paint (Get-Sparkline -Entry $k -DayKeys $State.DayKeys -Max $maxDaily) $Colour.Accent)
        }

        if ($showLauncher) {
            $pd = Get-PbiDisplay -Kiosk $k
            $up = ''
            if ($row -and $row.BootTimeUtc) {
                try {
                    $boot = [datetime]::ParseExact($row.BootTimeUtc, "yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv,
                        [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
                    $up = Format-Minutes ((Get-Date).ToUniversalTime() - $boot).TotalMinutes
                }
                catch { }
            }
            # A signed-in account other than the configured one is the
            # WRONG_ACCOUNT status; the name itself is shown in red then.
            $acctStyle = if ($k.Status -eq 'WRONG_ACCOUNT') { $Colour.Crit } else { $Colour.Dim }
            $line += ' ' + (Paint (Fit $pd.State $cLaunch) $pd.Style)
            if ($cFor) { $line += ' ' + (Paint (Fit $pd.For $cFor) $Colour.Dim) }
            $line += ' ' + (Paint (Fit $pd.Account $cAcct) $acctStyle)
            if ($cLver) { $line += ' ' + (Paint (Fit $pd.Version $cLver) $Colour.Dim) }
            $line += ' ' + (Paint (Fit $up $cUp) $Colour.Dim)
        }

        $lines.Add($line)
        $count++
    }

    # Comma-wrapped so this stays a List and the caller can still append the
    # footer; returning it bare hands back a fixed-size array instead.
    return ,$lines
}

function Get-ScanProgressLine {
    <#
        While a background scan runs, the rule above the key bar becomes its
        progress bar. Taking over an existing line rather than adding one
        means nothing on screen moves when a scan starts or finishes.
    #>
    param([int]$Width)

    $p = $script:ScanProgress
    $done = 0; $total = 0; $what = 'starting'
    if ($p -and $p.Total -gt 0) {
        $total = [int]$p.Total
        if ($p.Phase -eq 'saving') {
            $done = $total
            $what = 'saving results'
        }
        else {
            # Index is the kiosk being scanned now, so one fewer is finished.
            $done = [math]::Max(0, [int]$p.Index - 1)
            $what = '{0}/{1}  {2}' -f $p.Index, $total, $p.Host
        }
    }
    $fraction = if ($total -gt 0) { $done / [double]$total } else { 0 }

    $elapsed = if ($script:ScanStartedAt) { (Get-Date) - $script:ScanStartedAt } else { [timespan]::Zero }
    $clock = '{0}:{1:00}' -f [int][math]::Floor($elapsed.TotalMinutes), $elapsed.Seconds

    $left  = ($Glyph.Rule * 2) + ' scanning '
    $right = ' {0,3}%  {1}  {2} ' -f [int][math]::Floor(100 * $fraction), $what, $clock

    # Sized for the longest label a scan will show, not the current one, so
    # the bar does not jump in length as it moves from kiosk to kiosk.
    $barWidth = [math]::Min(40, $Width - $left.Length - [math]::Max($right.Length, 36) - 2)
    if ($barWidth -lt 10) {
        # Too narrow for a bar worth drawing; the words alone still say it.
        return (Paint (Fit ('scanning ' + $right.Trim()) $Width) $Colour.Accent)
    }

    $filled = [int][math]::Round($barWidth * $fraction)
    $tail = $Width - $left.Length - $barWidth - $right.Length

    return (Paint $left $Colour.Accent) +
           (Paint ($Glyph.BarFull * $filled) $Colour.Accent) +
           (Paint ($Glyph.BarEmpty * ($barWidth - $filled)) $Colour.Faint) +
           (Paint $right $Colour.Text) +
           (Paint ($Glyph.Rule * $tail) $Colour.Faint)
}

function Add-Footer {
    # Typed, so that even if a caller hands over a plain array it is converted
    # to a list that can be appended to.
    param(
        [System.Collections.Generic.List[string]]$Lines,
        $Size,
        [int]$Countdown
    )

    while ($Lines.Count -lt $Size.Height - 3) { $Lines.Add('') }

    if ($script:ScanProc) { $Lines.Add((Get-ScanProgressLine -Width $Size.Width)) }
    else { $Lines.Add((Paint ($Glyph.Rule * $Size.Width) $Colour.Faint)) }

    $filter = if ($script:ShowOnlyProblems) { 'problems only' } else { 'all kiosks' }

    $auto = if ($script:ScanProc) {
        'scanning now'
    }
    elseif ($script:AutoScan) {
        $mins = 0
        if ($script:NextScanAt) { $mins = [math]::Max(0, [int][math]::Ceiling(($script:NextScanAt - (Get-Date)).TotalMinutes)) }
        "auto {0}m (next {1}m)" -f $AutoScanMinutes, $mins
    }
    else { 'auto-scan off' }

    # Built as a plain string and a painted one side by side, so the padding
    # is measured on what is actually visible rather than on a hand-counted
    # constant that goes wrong the moment a label changes.
    # M is for the watchdog and P for PBI Launcher, so each shows on its own
    # tab (both work from any tab).
    $parts = @(
        @{ Key = 'R'; Label = ' restart   ' },
        @{ Key = 'C'; Label = ' remote control   ' }
    )
    if ($script:Tab -ne 'PBI') { $parts += @{ Key = 'M'; Label = ' message   ' } }
    if ($script:Tab -ne 'Mach2') { $parts += @{ Key = 'P'; Label = ' power bi launcher   ' } }
    $parts += @(
        @{ Key = 'D'; Label = ' deploy   ' },
        @{ Key = 'S'; Label = ' scan now   ' },
        @{ Key = 'A'; Label = " $auto   " },
        @{ Key = 'F'; Label = " $filter   " },
        @{ Key = 'Tab'; Label = ' next tab   ' },
        @{ Key = 'Q'; Label = ' quit' }
    )
    # On a narrow window the labels shrink to their first word, then go.
    $note = if ($script:ScanNote) { "$($script:ScanNote)   " } else { '' }
    $rightLen = $note.Length + ("redraw in {0}s " -f $Countdown).Length
    $full = 2 + (($parts | ForEach-Object { $_.Key.Length + $_.Label.Length }) | Measure-Object -Sum).Sum
    if ($full + $rightLen + 1 -gt $Size.Width) {
        foreach ($p in $parts) { $p.Label = ' ' + (($p.Label.Trim() -split ' ')[0]) + '  ' }
        $short = 2 + (($parts | ForEach-Object { $_.Key.Length + $_.Label.Length }) | Measure-Object -Sum).Sum
        if ($short + $rightLen + 1 -gt $Size.Width) {
            foreach ($p in $parts) { $p.Label = ' ' }
        }
    }

    $plain = '  '
    $keys  = '  '
    foreach ($p in $parts) {
        $plain += $p.Key + $p.Label
        $keys  += (Paint $p.Key $Colour.Accent) + (Paint $p.Label $Colour.Dim)
    }

    $right = $note + ("redraw in {0}s " -f $Countdown)

    $gap = $Size.Width - $plain.Length - $right.Length
    if ($gap -lt 1) { $gap = 1 }
    $Lines.Add($keys + (' ' * $gap) + (Paint $right $Colour.Faint))
}


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$csvFile = Resolve-EventsCsv
$RemoteControlPath = Get-CmRcViewerPath -Explicit $RemoteControlPath

$cursorWasVisible = $true
try { $cursorWasVisible = [Console]::CursorVisible } catch { }

try {
    try { [Console]::CursorVisible = $false } catch { }
    Clear-Host

    while ($true) {
        $size = Get-ConsoleSize
        $state = Read-FleetState -Path $csvFile
        Select-Tab -State $state
        $shown = @(Get-ShownHosts -State $state)

        if ($Once) {
            $lines = Build-Frame -State $state -Size $size
            Write-Frame -Lines $lines -Size $size
            break
        }

        # Redraw once a second so the clock ticks, and re-read the CSV every
        # -RefreshSeconds. Keys are polled throughout so the tool never feels
        # stuck waiting for a timer.
        for ($waited = $RefreshSeconds; $waited -gt 0; $waited--) {
            Update-ScanState

            $lines = Build-Frame -State $state -Size $size
            Add-Footer -Lines $lines -Size $size -Countdown $waited
            Write-Frame -Lines $lines -Size $size

            $action  = $null
            $tabMove = 0
            $tabJump = $null
            for ($tick = 0; $tick -lt 10; $tick++) {
                Start-Sleep -Milliseconds 100
                $ready = $false
                try { $ready = [Console]::KeyAvailable } catch { }
                if (-not $ready) { continue }

                $key = [Console]::ReadKey($true)
                if ($key.Modifiers.HasFlag([ConsoleModifiers]::Control)) { continue }
                switch ($key.Key) {
                    ([ConsoleKey]::R) { $action = 'Restart' }
                    ([ConsoleKey]::C) { $action = 'RemoteControl' }
                    ([ConsoleKey]::M) { $action = 'Message' }
                    ([ConsoleKey]::P) { $action = 'Pbi' }
                    ([ConsoleKey]::D) { $action = 'Deploy' }
                    ([ConsoleKey]::S) { $action = 'Scan' }
                    ([ConsoleKey]::A) { $action = 'Auto' }
                    ([ConsoleKey]::F) { $action = 'Filter' }
                    ([ConsoleKey]::Q) { $action = 'Quit' }
                    ([ConsoleKey]::Tab) {
                        $action  = 'Tab'
                        $tabMove = if ($key.Modifiers.HasFlag([ConsoleModifiers]::Shift)) { -1 } else { 1 }
                    }
                    { $_ -in @([ConsoleKey]::D1, [ConsoleKey]::NumPad1) } { $action = 'Tab'; $tabJump = 0 }
                    { $_ -in @([ConsoleKey]::D2, [ConsoleKey]::NumPad2) } { $action = 'Tab'; $tabJump = 1 }
                    { $_ -in @([ConsoleKey]::D3, [ConsoleKey]::NumPad3) } { $action = 'Tab'; $tabJump = 2 }
                }
                if ($action) { break }
            }

            if ($action) {
                try { [Console]::CursorVisible = $true } catch { }
                switch ($action) {
                    'Restart'       { Invoke-RestartMenu -Hosts $shown }
                    'RemoteControl' { Invoke-RemoteControlMenu -Hosts $shown -ViewerPath $RemoteControlPath }
                    'Message'       { Invoke-MessageMenu -Hosts $shown }
                    'Pbi'           { Invoke-PbiLauncherMenu -State $state -Shown $shown }
                    'Deploy'        { Invoke-DeployMenu -State $state -Hosts $shown }
                    'Scan'          { Invoke-ScanNow }
                    'Auto'          {
                        if ($script:AutoScan) {
                            $script:AutoScan = $false
                            $script:ScanNote = ''
                        }
                        else { Enable-AutoScan -State $state }
                    }
                    'Filter'        { $script:ShowOnlyProblems = -not $script:ShowOnlyProblems }
                    'Tab'           { Select-Tab -State $state -Move $tabMove -Jump $tabJump }
                    'Quit'          { return }
                }
                try { [Console]::CursorVisible = $false } catch { }
                break
            }
        }
    }
}
catch [System.Management.Automation.PipelineStoppedException] {
    # Ctrl+C
}
finally {
    try { [Console]::CursorVisible = $cursorWasVisible } catch { }
    if ($script:UseColour) { [Console]::Write("$E[0m") }
    Write-Host ''
}
