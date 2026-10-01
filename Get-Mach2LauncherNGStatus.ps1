#Requires -Version 5.1
<#
.SYNOPSIS
    Status ver 1.02NG: shows what Mach2 Launcher ver 1.02NG is doing on each
    Mach2 kiosk, screen by screen.

.DESCRIPTION
    Reads the status file every launcher instance keeps up to date
    (C:\Users\Public\Documents\Mach2LauncherNG\<instance>\Status\<instance>.status.json)
    over the admin share. Nothing on the kiosk is changed.

    State is the launcher's own, except:

      STALE          the status file has not been written for 3 minutes, so
                     the launcher (and with it the watchdog) is not running.
                     The last state it reported is shown too.
      NOT_INSTALLED  no Mach2 Launcher NG on the kiosk (OLD_LAUNCHER: the old
                     Mach2Launcher.exe is there)
      NO_STATUS      installed, but it has not run yet
      OFFLINE / NO_ACCESS

    Launcher states: SHOWING (all good), LOADING, SIGNING_IN, RECOVERING,
    SIGNIN_BLOCKED (needs a person - see Detail), WAITING_DISPLAY, HOLD,
    ERROR, UNSUPERVISED, DISABLED, STOPPED, RESTARTING_PC.

    WD is * on the instance that is the kiosk's watchdog; SCREEN and PAGE are
    the last white readings of the screen and of the dashboard page (normal
    is between 10% and 85%).

.PARAMETER Hosts
    Kiosks to check. Default: every active Mach2 kiosk in the kiosk list.

.PARAMETER PassThru
    Return the rows as objects instead of printing a table.

.EXAMPLE
    .\Get-Mach2LauncherNGStatus.ps1

.EXAMPLE
    .\Get-Mach2LauncherNGStatus.ps1 -Hosts SHCZ5KPI12473

.EXAMPLE
    .\Get-Mach2LauncherNGStatus.ps1 -PassThru | Where-Object State -ne SHOWING
#>
[CmdletBinding()]
param(
    [string[]]$Hosts,
    [string]$KioskList,
    [string]$FleetRoot,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredentialFile,
    [switch]$PassThru,
    # For testing: a local folder standing in for each kiosk's C: drive.
    [string]$RootTemplate = '\\{0}\C$'
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
if (-not $FleetRoot) { $FleetRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }

foreach ($lib in @('MWST.Remote.ps1', 'MWST.KioskList.ps1')) {
    $p = Join-Path $FleetRoot "Lib\$lib"
    if (-not (Test-Path -LiteralPath $p)) { throw "Fleet library not found: $p. Point -FleetRoot at the fleet tools." }
    . $p
}

$remote = $RootTemplate.StartsWith('\\')
if ($remote -and -not $Credential) {
    if (-not $CredentialFile) {
        $default = Join-Path $FleetRoot 'Config\kiosk-admin.cred.xml'
        if (Test-Path -LiteralPath $default) { $CredentialFile = $default }
    }
    if ($CredentialFile) { $Credential = Import-StoredCredential -Path $CredentialFile }
}

$targets = @()
if ($Hosts) {
    $targets = @($Hosts | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Host = $_.ToUpperInvariant(); Location = '' } })
}
else {
    $listPath = $KioskList
    if (-not $listPath) {
        $info = Resolve-KioskListPath -ScriptDir $FleetRoot
        if (-not $info.Path) { Write-KioskListSource -ListInfo $info; throw 'No kiosk list found; use -Hosts.' }
        $listPath = $info.Path
    }
    $targets = @(Import-KioskList -Path $listPath -IncludeAll | Where-Object {
            [string]$_.Type -match '^\s*MACH' -and -not ($_.Active -and $_.Active.Trim().ToUpperInvariant().StartsWith('N'))
        } | ForEach-Object { [pscustomobject]@{ Host = $_.Host.ToUpperInvariant(); Location = $_.Location } })
}

function Format-Age {
    param([string]$Utc)
    if (-not $Utc) { return '' }
    $t = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($Utc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { return '' }
    $span = [DateTime]::UtcNow - $t.ToUniversalTime()
    if ($span.TotalSeconds -lt 0) { return 'now' }
    if ($span.TotalMinutes -lt 1) { return ('{0:0}s' -f $span.TotalSeconds) }
    if ($span.TotalHours -lt 1) { return ('{0:0}m' -f $span.TotalMinutes) }
    if ($span.TotalDays -lt 2) { return ('{0:0.#}h' -f $span.TotalHours) }
    return ('{0:0}d' -f $span.TotalDays)
}

function Format-Percent {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    return ('{0:0}%' -f [double]$Value)
}

$rows = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($t in $targets) {
    $i++
    Write-Progress -Activity 'Mach2 Launcher NG status' -Status $t.Host -PercentComplete (100 * $i / [math]::Max(1, $targets.Count))
    $base = [ordered]@{
        Host = $t.Host; Location = $t.Location; Instance = ''; State = ''; For = ''; LastShown = ''; Updated = ''
        Version = ''; Watchdog = ''; LoopGuard = ''; Screen = ''; Page = ''; SignIns = ''; Reloads = ''; EdgeStarts = ''; PcRestarts = ''; Detail = ''
    }
    $drive = $null
    try {
        $root = $RootTemplate -f $t.Host
        if ($remote) {
            $reach = Test-HostReachable -HostName $t.Host
            if (-not $reach.Ok) { $base.State = 'OFFLINE'; $base.Detail = $reach.Error; $rows.Add([pscustomobject]$base); continue }
            try { $drive = Connect-KioskShare -Folder "$root\Users" -Credential $Credential }
            catch { $base.State = 'NO_ACCESS'; $base.Detail = $_.Exception.Message; $rows.Add([pscustomobject]$base); continue }
        }
        $dir = Join-Path $root 'Users\Public\Documents\Mach2LauncherNG'
        if (-not (Test-Path -LiteralPath (Join-Path $dir 'Mach2LauncherNG.ps1'))) {
            if (-not (Test-Path -LiteralPath (Join-Path $root 'Users'))) { $base.State = 'NO_ACCESS' }
            elseif (@(Get-ChildItem -LiteralPath (Join-Path $root 'Users\Public\Documents\Mach2Launchers') -Directory -Filter 'Launcher S*' -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Mach2Launcher.exe') }).Count) { $base.State = 'OLD_LAUNCHER' }
            else { $base.State = 'NOT_INSTALLED' }
            $rows.Add([pscustomobject]$base)
            continue
        }
        $files = @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ChildItem -LiteralPath (Join-Path $_.FullName 'Status') -Filter '*.status.json' -File -ErrorAction SilentlyContinue
            })
        if ($files.Count -eq 0) {
            $base.State = 'NO_STATUS'
            $base.Detail = 'installed, not run yet (starts at the next logon)'
            $rows.Add([pscustomobject]$base)
            continue
        }
        foreach ($f in $files) {
            $row = [pscustomobject]$base
            try { $s = ConvertFrom-Json -InputObject (Read-SharedText -Path $f.FullName) }
            catch { $row.State = 'UNREADABLE'; $row.Detail = $_.Exception.Message; $rows.Add($row); continue }
            $row.Instance = $s.Instance
            $row.State = $s.State
            $row.For = Format-Age $s.StateSinceUtc
            $row.LastShown = Format-Age $s.LastShownUtc
            $row.Updated = Format-Age $s.UpdatedUtc
            $row.Version = $s.LauncherVersion
            $row.Watchdog = if ($s.Watchdog) { '*' } else { '' }
            $row.LoopGuard = [string]$s.LoopGuard
            $row.Screen = Format-Percent $s.ScreenWhitePercent
            $row.Page = Format-Percent $s.PageWhitePercent
            $row.SignIns = $s.SignIns
            $row.Reloads = $s.Reloads
            $row.EdgeStarts = $s.BrowserStarts
            $row.PcRestarts = $s.PcRestarts
            $row.Detail = if ($s.Detail) { $s.Detail } elseif ($s.State -ne 'SHOWING' -and $s.LastError) { $s.LastError } else { '' }
            if ($row.LoopGuard) { $row.Detail = ("loop guard {0}. {1}" -f $row.LoopGuard, $row.Detail).Trim() }

            $updated = [DateTime]::MinValue
            $isFinal = $s.State -in @('STOPPED', 'DISABLED')
            if ([DateTime]::TryParse([string]$s.UpdatedUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$updated) -and
                -not $isFinal -and ([DateTime]::UtcNow - $updated.ToUniversalTime()).TotalMinutes -gt 3) {
                $row.Detail = ("launcher not running; last said {0} {1}" -f $s.State, $row.Detail).Trim()
                $row.State = 'STALE'
            }
            $rows.Add($row)
        }
    }
    catch {
        $base.State = 'ERROR'
        $base.Detail = $_.Exception.Message
        $rows.Add([pscustomobject]$base)
    }
    finally { Disconnect-KioskShare -Drive $drive }
}
Write-Progress -Activity 'Mach2 Launcher NG status' -Completed

if ($PassThru) { return $rows }

$order = @{ SIGNIN_BLOCKED = 0; ERROR = 1; STALE = 2; OFFLINE = 3; NO_ACCESS = 4; RECOVERING = 5; UNSUPERVISED = 6; WAITING_DISPLAY = 7; HOLD = 8; STOPPED = 9; OLD_LAUNCHER = 10; NOT_INSTALLED = 11; NO_STATUS = 12 }
$sorted = $rows | Sort-Object @{ e = { if ($order.ContainsKey($_.State)) { $order[$_.State] } else { 50 } } }, Host, Instance
$fmt = '{0,-15} {1,-14} {2,-4} {3,-15} {4,6} {5,7} {6,7} {7,-7} {8,2} {9,6} {10,5}  {11}'
Write-Host ($fmt -f 'Host', 'Location', 'Scr', 'State', 'for', 'shown', 'updated', 'ver', 'WD', 'SCREEN', 'PAGE', 'detail') -ForegroundColor DarkGray
foreach ($r in $sorted) {
    $color = switch ($r.State) {
        'SHOWING' { 'Green' }
        { $_ -in @('LOADING', 'SIGNING_IN', 'RESTARTING_PC') } { 'Cyan' }
        { $_ -in @('SIGNIN_BLOCKED', 'ERROR', 'STALE', 'OFFLINE', 'NO_ACCESS', 'UNREADABLE') } { 'Red' }
        { $_ -in @('NOT_INSTALLED', 'OLD_LAUNCHER', 'NO_STATUS', 'STOPPED', 'DISABLED') } { 'DarkGray' }
        default { 'Yellow' }
    }
    $loc = [string]$r.Location
    Write-Host ($fmt -f $r.Host, $loc.Substring(0, [math]::Min(14, $loc.Length)), $r.Instance, $r.State, $r.For, $r.LastShown, $r.Updated, $r.Version, $r.Watchdog, $r.Screen, $r.Page, $r.Detail) -ForegroundColor $color
}
Write-Host ''
$rows | Group-Object State | Sort-Object Count -Descending | ForEach-Object { Write-Host ("{0,4} {1}" -f $_.Count, $_.Name) }
