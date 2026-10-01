#Requires -Version 5.1
<#
.SYNOPSIS
    Shows what PBI Launcher (or, with -Launcher Web, Web Launcher) is doing
    on each kiosk, screen by screen.

.DESCRIPTION
    Reads the status file every launcher keeps up to date
    (C:\Users\Public\Documents\PbiLauncher\S<n>\Status\S<n>.status.json, or
    PbiLauncher\Status\ before the screen folders) over the admin share.
    Nothing on the kiosk is changed.

    State is the launcher's own, except:

      STALE          the status file has not been written for 3 minutes, so
                     the launcher is not running (nobody signed in, or it
                     was stopped). The last state it reported is shown too.
      NOT_INSTALLED  no PBI Launcher on the kiosk
      NO_STATUS      installed, but it has not run yet
      OFFLINE / NO_ACCESS

    Launcher states: SHOWING (all good), BROWSING (someone followed a link
    out of the report), LOADING, SIGNING_IN, RECOVERING,
    SIGNIN_BLOCKED (needs a person - see Detail), WAITING_DISPLAY, HOLD,
    ERROR, UNSUPERVISED, DISABLED, STOPPED, RESTARTING_PC.

.PARAMETER Hosts
    Kiosks to check. Default: every active Power BI kiosk in the kiosk list
    (Web kiosks with -Launcher Web).

.PARAMETER Launcher
    PBI (default) or Web. Get-WebLauncherStatus.ps1 is this with -Launcher Web.

.PARAMETER PassThru
    Return the rows as objects instead of printing a table.

.EXAMPLE
    .\Get-PbiLauncherStatus.ps1

.EXAMPLE
    .\Get-PbiLauncherStatus.ps1 -Hosts SHCZ5KPI11980

.EXAMPLE
    .\Get-PbiLauncherStatus.ps1 -PassThru | Where-Object State -ne SHOWING
#>
[CmdletBinding()]
param(
    [string[]]$Hosts,
    [string]$KioskList,
    [string]$FleetRoot,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredentialFile,
    [switch]$PassThru,
    [ValidateSet('PBI', 'Web')][string]$Launcher = 'PBI',
    # For testing: a local folder standing in for each kiosk's C: drive.
    [string]$RootTemplate = '\\{0}\C$'
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
if (-not $FleetRoot) { $FleetRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path } }

$FolderName = if ($Launcher -eq 'Web') { 'WebLauncher' } else { 'PbiLauncher' }
$Title = if ($Launcher -eq 'Web') { 'Web Launcher' } else { 'PBI Launcher' }
foreach ($lib in @('MWST.Remote.ps1', 'MWST.KioskList.ps1', 'PBI.Launcher.ps1')) {
    $p = Join-Path $FleetRoot "Lib\$lib"
    if (-not (Test-Path -LiteralPath $p)) { throw "Fleet library not found: $p. Point -FleetRoot at the MWST fleet tools." }
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
            $(if ($Launcher -eq 'Web') { Test-IsWebKiosk -Type $_.Type } else { Test-IsPowerBiKiosk -Type $_.Type }) -and $_.Type -notmatch 'NO\s*SCRIPT' -and -not ($_.Active -and $_.Active.Trim().ToUpperInvariant().StartsWith('N'))
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

$rows = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($t in $targets) {
    $i++
    Write-Progress -Activity "$Title status" -Status $t.Host -PercentComplete (100 * $i / [math]::Max(1, $targets.Count))
    $base = [ordered]@{
        Host = $t.Host; Location = $t.Location; Screen = ''; Instance = ''; State = ''; For = ''; LastShown = ''; Updated = ''
        Version = ''; Edge = ''; SignedInAs = ''; SignIns = ''; Reloads = ''; EdgeStarts = ''; Detail = ''
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
        $dir = Join-Path $root "Users\Public\Documents\$FolderName"
        if (-not (Test-Path -LiteralPath (Join-Path $dir "$FolderName.ps1"))) {
            $base.State = if (Test-Path -LiteralPath (Join-Path $root 'Users')) { 'NOT_INSTALLED' } else { 'NO_ACCESS' }
            $rows.Add([pscustomobject]$base)
            continue
        }
        # Every screen's folder, and the one from before them (its S1).
        $files = @(); $screenOf = @{}
        foreach ($sf in @(Get-LauncherScreenFolders -Root $root -Name $FolderName -HostName $t.Host)) {
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $sf.Path 'Status') -Filter '*.status.json' -File -ErrorAction SilentlyContinue)) { $files += $f; $screenOf[$f.FullName] = $sf.Screen }
        }
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
            $row.Screen = $screenOf[$f.FullName]
            $row.Instance = $s.Instance
            $row.State = $s.State
            $row.For = Format-Age $s.StateSinceUtc
            $row.LastShown = Format-Age $s.LastShownUtc
            $row.Updated = Format-Age $s.UpdatedUtc
            $row.Version = $s.LauncherVersion
            $row.Edge = ([string]$s.EdgeVersion) -replace '^Edg/', ''
            if ($s.PSObject.Properties['SignedInAs']) { $row.SignedInAs = $s.SignedInAs }
            $row.SignIns = $s.SignIns
            $row.Reloads = $s.Reloads
            $row.EdgeStarts = $s.BrowserStarts
            $row.Detail = if ($s.Detail) { $s.Detail } elseif ($s.State -ne 'SHOWING' -and $s.LastError) { $s.LastError } else { '' }

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
Write-Progress -Activity "$Title status" -Completed

if ($PassThru) { return $rows }

$order = @{ SIGNIN_BLOCKED = 0; ERROR = 1; STALE = 2; OFFLINE = 3; NO_ACCESS = 4; RECOVERING = 5; UNSUPERVISED = 6; WAITING_DISPLAY = 7; HOLD = 8; STOPPED = 9; NOT_INSTALLED = 10; NO_STATUS = 11 }
$sorted = $rows | Sort-Object @{ e = { if ($order.ContainsKey($_.State)) { $order[$_.State] } else { 50 } } }, Host
Write-Host ('{0,-15} {1,-18} {9,-3} {2,-15} {3,6} {4,8} {5,7}  {6,-6} {7,-34} {8}' -f 'Host', 'Location', 'State', 'for', 'shown', 'updated', 'ver', 'signed in as', 'detail', 'scr') -ForegroundColor DarkGray
foreach ($r in $sorted) {
    $color = switch ($r.State) {
        'SHOWING' { 'Green' }
        { $_ -in @('LOADING', 'SIGNING_IN', 'RESTARTING_PC', 'BROWSING') } { 'Cyan' }
        { $_ -in @('SIGNIN_BLOCKED', 'ERROR', 'STALE', 'OFFLINE', 'NO_ACCESS', 'UNREADABLE') } { 'Red' }
        { $_ -in @('NOT_INSTALLED', 'NO_STATUS', 'STOPPED', 'DISABLED') } { 'DarkGray' }
        default { 'Yellow' }
    }
    $line = '{0,-15} {1,-18} {9,-3} {2,-15} {3,6} {4,8} {5,7}  {6,-6} {7,-34} {8}' -f $r.Host, ([string]$r.Location).Substring(0, [math]::Min(18, ([string]$r.Location).Length)), $r.State, $r.For, $r.LastShown, $r.Updated, $r.Version, $r.SignedInAs, $r.Detail, $r.Screen
    Write-Host $line -ForegroundColor $color
}
Write-Host ''
$rows | Group-Object State | Sort-Object Count -Descending | ForEach-Object { Write-Host ("{0,4} {1}" -f $_.Count, $_.Name) }
