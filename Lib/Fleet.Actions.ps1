<#
.SYNOPSIS
    What the front ends do to a kiosk, without any front end: reading its
    launcher live, control files, screenshots, the launcher log, the sign-in
    password, the kiosk config, restarts and messages - and the per-kiosk
    view a front end draws from the fleet state.

.DESCRIPTION
    Dot-sourced after Lib\MWST.Remote.ps1, Lib\MWST.KioskList.ps1,
    Lib\MWST.Message.ps1, Lib\PBI.Launcher.ps1, Lib\M2.LauncherNG.ps1 and
    Lib\MWST.FleetState.ps1.

    The web dashboard (Start-FleetWeb.ps1) runs these in background
    runspaces through Invoke-FleetAction. The logic is the Kiosk Fleet
    Manager window's (Show-FleetManager.ps1), taken out of its callbacks so
    nothing here knows about a window, a card or a browser: every action
    takes a context hashtable and returns one object saying what happened.

    The context ($Ctx) always has:
      ScriptDir     the fleet folder
      RootTemplate  '\\{0}\C$', or a local folder per kiosk for the tests
      Credential    the kiosk-admin credential
      Say           a synchronized queue; progress lines go on it
      Who           who asked, written into control files ("DOMAIN\user")
#>

Set-StrictMode -Off

$FleetLauncherFolders = [ordered]@{ NG = 'Mach2LauncherNG'; PBI = 'PbiLauncher'; WEB = 'WebLauncher' }
$FleetLauncherNames = @{ NG = 'Mach2 Launcher NG'; PBI = 'PBI Launcher'; WEB = 'Web Launcher' }
$FleetTabKinds = @{ Mach2 = 'NG'; PBI = 'PBI'; Web = 'WEB' }
$FleetKindTabs = @{ NG = 'Mach2'; PBI = 'PBI'; WEB = 'Web' }
$FleetKindOfScreenLauncher = @{ MACH2 = 'NG'; PBI = 'PBI'; WEB = 'WEB' }
$FleetLiveStaleMinutes = 5

# A name a kiosk answers to on the network: nothing else may reach a share
# path, a control file or a deploy command line.
$FleetHostPattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$'

$script:FleetSay = $null
function Say {
    param([string]$Text)
    if ($script:FleetSay) { [void]$script:FleetSay.Enqueue($Text) }
}

function Get-FleetHostName {
    # Normalises a typed name ("  \\PC-01 " -> "PC-01"), or $null for
    # anything that is not one.
    param([string]$Text)
    if (-not $Text) { return $null }
    $name = $Text.Trim().Trim('\')
    if ($name -match $FleetHostPattern) { return $name }
    return $null
}

# ---------------------------------------------------------------------------
# The kiosk's share and its launcher folders
# ---------------------------------------------------------------------------
function Get-PublicDocs {
    # <root>\Users\Public\Documents, built a part at a time so the separators
    # are always the system's own.
    param([string]$Root)
    return (Join-Path (Join-Path (Join-Path $Root 'Users') 'Public') 'Documents')
}

function Open-KioskShare {
    # The kiosk's C$ with the fleet credential, or an object with .Error. An
    # open session under another name refuses a second one, but the share is
    # often readable through it anyway, so that is tried too.
    param([string]$HostName, [string]$RootTemplate, [System.Management.Automation.PSCredential]$Credential)
    $root = $RootTemplate -f $HostName
    $out = [pscustomobject]@{ Host = $HostName; Root = $root; Drive = $null; Error = $null }
    if ($root -like '\\*') {
        $reach = Test-HostReachable -HostName $HostName
        if (-not $reach.Ok) { $out.Error = "offline: $($reach.Error)"; return $out }
        try { $out.Drive = Connect-KioskShare -Folder "$root\Users" -Credential $Credential }
        catch { }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'Users'))) {
        if ($out.Drive) { Disconnect-KioskShare -Drive $out.Drive; $out.Drive = $null }
        $out.Error = "cannot read $root"
    }
    return $out
}

function Close-KioskShare {
    param($Share)
    if ($Share -and $Share.Drive) { Disconnect-KioskShare -Drive $Share.Drive }
}

function Get-LauncherDirs {
    # Where a kiosk's launchers keep their control files and status, one
    # entry per screen folder (S1, S2, ...) that holds the kiosk's
    # <HOST>.json - and PBI Launcher's own folder, from before the screen
    # folders, as its S1. -Kind NG, PBI or WEB, or ALL; -Screen narrows it.
    param([string]$Root, [string]$Kind, [string]$HostName, [string]$Screen)
    $kinds = if ($Kind -eq 'ALL' -or -not $Kind) { @($FleetLauncherFolders.Keys) } else { @($Kind) }
    $out = @()
    foreach ($k in $kinds) {
        $base = Join-Path (Get-PublicDocs $Root) $FleetLauncherFolders[$k]
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

function Get-ScreenDir {
    # The folder a screen's config goes in: <launcher>\S<n>, or PBI
    # Launcher's own folder where its old S1 config still lives.
    param([string]$Root, [string]$Kind, [string]$Instance, [string]$HostName)
    $base = Join-Path (Get-PublicDocs $Root) $FleetLauncherFolders[$Kind]
    if ($Kind -eq 'PBI' -and $Instance -eq 'S1' -and -not (Test-Path -LiteralPath (Join-Path (Join-Path $base 'S1') "$HostName.json")) -and (Test-Path -LiteralPath (Join-Path $base "$HostName.json"))) { return $base }
    return (Join-Path $base $Instance)
}

function Read-KioskJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return @(ConvertFrom-Json -InputObject (Read-SharedText -Path $Path))[0] } catch { return $null }
}

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

function ConvertFrom-SecureText {
    param([System.Security.SecureString]$Secure)
    if (-not $Secure) { return $null }
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Write-PasswordSeed {
    # password.seed next to the config: the launcher encrypts it for the
    # kiosk account and deletes it. Written whole and then moved, so the
    # launcher never reads half a password.
    param([string]$Dir, [string]$Plain)
    $seed = Join-Path $Dir 'password.seed'
    [IO.File]::WriteAllText("$seed.tmp", $Plain, (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath "$seed.tmp" -Destination $seed -Force
    return $seed
}

# ---------------------------------------------------------------------------
# What a front end draws: one kiosk, as the last scan saw it
# ---------------------------------------------------------------------------
function Get-FleetLauncherView {
    <#
        What a kiosk's launcher was doing at the last scan, from the
        collector's status file: the same reading for every launcher. -Tab
        picks the launcher that tab is about; without it, the kiosk's own
        tab's, then whichever it has.
    #>
    param($Kiosk, [string]$Tab)

    $out = [pscustomobject]@{
        Kind = ''; Known = $false; Installed = $false; Old = $false
        State = ''; For = ''; Account = ''; Version = ''; Screen = ''
        Severity = 'UNKNOWN'; Instances = @(); Status = ''; Error = ''
    }
    if (-not $Kiosk) { return $out }

    $entry = $null
    $want = if ($Tab -and $FleetTabKinds.ContainsKey($Tab)) { $FleetTabKinds[$Tab] } elseif ($FleetTabKinds.ContainsKey([string]$Kiosk.Tab)) { $FleetTabKinds[[string]$Kiosk.Tab] } else { '' }
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
    elseif ($out.Kind -eq 'NG') {
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

function New-FleetDetailRow {
    param([string]$Label, [string]$Value, [string]$Sev = '', [switch]$Wrap)
    return [pscustomobject]@{ Label = $Label; Value = $Value; Sev = $Sev; Wrap = [bool]$Wrap }
}

function Get-FleetKioskDetail {
    # The details card as sections of label/value rows, coloured by
    # severity name: what the window draws on the right of the table.
    param($Kiosk)
    $k = $Kiosk
    $sections = New-Object System.Collections.ArrayList
    $rows = New-Object System.Collections.ArrayList

    $row0 = $k.StatusRow
    if ($row0) {
        $when = ConvertFrom-FleetIsoTime ([string]$row0.EventTimeUtc)
        [void]$rows.Add((New-FleetDetailRow 'Seen' $(if ($when) { $when.ToLocalTime().ToString('ddd dd MMM HH:mm') } else { '' })))
        if ($row0.Detail) { [void]$rows.Add((New-FleetDetailRow 'Detail' ([string]$row0.Detail) 'DIM' -Wrap)) }
        if ($row0.BootTimeUtc) {
            $boot = ConvertFrom-FleetIsoTime ([string]$row0.BootTimeUtc)
            if ($boot) { [void]$rows.Add((New-FleetDetailRow 'PC up since' ('{0}  ({1})' -f $boot.ToLocalTime().ToString('dd MMM HH:mm'), (Format-Minutes ([datetime]::UtcNow - $boot).TotalMinutes)))) }
        }
    }
    else { [void]$rows.Add((New-FleetDetailRow 'Seen' 'no status row yet' 'WARNING')) }
    [void]$rows.Add((New-FleetDetailRow 'Reboots 24h' ('{0}{1}' -f $k.Reboots24, $(if ($k.Script24) { " ($($k.Script24) by the watchdog)" } else { '' }))))
    [void]$rows.Add((New-FleetDetailRow 'Screen events' ("$($k.Episodes24) in 24h")))
    [void]$sections.Add([pscustomobject]@{ Title = 'LAST SCAN'; Rows = @($rows) })

    if ($k.HasWatchdog -and $row0) {
        $rows = New-Object System.Collections.ArrayList
        $wd = switch ("$($row0.WatchdogRunning)") { 'TRUE' { 'running' } 'FALSE' { 'DEAD' } default { 'unknown' } }
        [void]$rows.Add((New-FleetDetailRow 'State' $wd $(if ($wd -eq 'DEAD') { 'CRITICAL' } else { 'OK' })))
        [void]$rows.Add((New-FleetDetailRow 'Version' ([string]$row0.AgentVersion)))
        if ($row0.MinutesSinceLastLog) { [void]$rows.Add((New-FleetDetailRow 'Last wrote' ('{0} ago' -f (Format-Minutes ([double]$row0.MinutesSinceLastLog))))) }
        [void]$sections.Add([pscustomobject]@{ Title = 'WATCHDOG'; Rows = @($rows) })
    }

    $kinds = @()
    foreach ($kk in @('NG', 'PBI', 'WEB')) {
        $e = switch ($kk) { 'NG' { $k.Ng } 'PBI' { $k.Pbi } 'WEB' { if ($k.PSObject.Properties['Web']) { $k.Web } } }
        if ($e) { $kinds += $kk }
    }
    if ($kinds.Count -eq 0 -and $FleetTabKinds.ContainsKey([string]$k.Tab)) { $kinds = @($FleetTabKinds[[string]$k.Tab]) }
    $screens = @(if ($k.PSObject.Properties['Screens']) { $k.Screens })
    if ($screens.Count -gt 1 -or $kinds.Count -gt 1) {
        $rows = New-Object System.Collections.ArrayList
        foreach ($s in $screens) {
            [void]$rows.Add((New-FleetDetailRow ([string]$s.Screen) ('{0}  -  {1}' -f $FleetLauncherNames[$FleetKindOfScreenLauncher[[string]$s.Launcher]], $s.State) (Get-FleetSeverity ([string]$s.HostStatus))))
        }
        [void]$sections.Add([pscustomobject]@{ Title = 'SCREENS'; Rows = @($rows) })
    }
    foreach ($kind in $kinds) {
        $rows = New-Object System.Collections.ArrayList
        $lv = Get-FleetLauncherView -Kiosk $k -Tab $FleetKindTabs[$kind]
        if (-not $lv.Known) {
            $why = $(if ($kind -eq 'NG') { 'not installed - this kiosk still runs Mach2Launcher.exe and the MWST watchdog' } else { 'nothing was read at the last scan' })
            [void]$rows.Add((New-FleetDetailRow 'Installed' $why 'DIM' -Wrap))
        }
        elseif (-not $lv.Installed) {
            $why = $(if ($lv.Old) { 'no - still on the old launcher' } elseif (@($screens | Where-Object { $FleetKindOfScreenLauncher[[string]$_.Launcher] -eq $kind }).Count) { 'no - config written, launcher not installed' } else { 'no' })
            [void]$rows.Add((New-FleetDetailRow 'Installed' $why 'WARNING' -Wrap))
        }
        elseif ($lv.Instances.Count -eq 0) {
            [void]$rows.Add((New-FleetDetailRow 'State' 'installed, never started' 'WARNING'))
        }
        foreach ($i in $lv.Instances) {
            $label = $(if ($i.PSObject.Properties['Screen'] -and $i.Screen) { [string]$i.Screen } else { [string]$i.Instance })
            [void]$rows.Add((New-FleetDetailRow $label ('{0} for {1}' -f $i.State, (Format-Minutes $i.StateMinutes)) (Get-FleetSeverity ([string]$i.HostStatus))))
            if ($i.Detail) { [void]$rows.Add((New-FleetDetailRow '' ([string]$i.Detail) 'DIM' -Wrap)) }
            if ($kind -eq 'PBI') {
                $acct = $(if ($i.SignedInAs) { [string]$i.SignedInAs } else { 'not seen yet' })
                [void]$rows.Add((New-FleetDetailRow 'Signed in as' $acct $(if ($k.Status -eq 'WRONG_ACCOUNT') { 'CRITICAL' } else { 'DIM' })))
            }
            elseif ($kind -eq 'NG') {
                $w = @()
                if ($null -ne $i.ScreenWhitePercent -and "$($i.ScreenWhitePercent)" -ne '') { $w += "screen $($i.ScreenWhitePercent)%" }
                if ($null -ne $i.PageWhitePercent -and "$($i.PageWhitePercent)" -ne '') { $w += "page $($i.PageWhitePercent)%" }
                if ($w.Count) { [void]$rows.Add((New-FleetDetailRow 'White' ($w -join ', ') 'DIM')) }
                if ($i.Watchdog) { [void]$rows.Add((New-FleetDetailRow 'Watchdog' 'this screen is the watchdog' 'DIM')) }
                if ($i.LoopGuard -and "$($i.LoopGuard)" -ne 'OFF' -and "$($i.LoopGuard)" -ne '') { [void]$rows.Add((New-FleetDetailRow 'Loop guard' ([string]$i.LoopGuard) 'CRITICAL')) }
                if ($i.PcRestarts) { [void]$rows.Add((New-FleetDetailRow 'PC restarts' ("$($i.PcRestarts)") 'DIM')) }
            }
            [void]$rows.Add((New-FleetDetailRow 'Version' ('v{0}   Edge {1}' -f $i.Version, $i.Edge) 'DIM'))
            $counts = $(if ($kind -eq 'WEB') { '{0} reloads, {1} browser starts' -f $i.Reloads, $i.BrowserStarts }
                else { '{0} reloads, {1} sign-ins, {2} browser starts' -f $i.Reloads, $i.SignIns, $i.BrowserStarts })
            [void]$rows.Add((New-FleetDetailRow 'Counts' $counts 'DIM'))
            $upd = ConvertFrom-FleetIsoTime ([string]$i.UpdatedUtc)
            if ($upd) { [void]$rows.Add((New-FleetDetailRow 'Status written' ((Format-Minutes ([datetime]::UtcNow - $upd).TotalMinutes) + ' ago') 'DIM')) }
            if ($i.LastError) { [void]$rows.Add((New-FleetDetailRow 'Last error' ([string]$i.LastError) 'WARNING' -Wrap)) }
        }
        if ($lv.Error) { [void]$rows.Add((New-FleetDetailRow 'Could not read' ([string]$lv.Error) 'WARNING' -Wrap)) }
        if ($lv.Installed -and $lv.Old) { [void]$rows.Add((New-FleetDetailRow 'Old launcher' 'still on this kiosk' 'DIM')) }
        [void]$sections.Add([pscustomobject]@{ Title = $FleetLauncherNames[$kind].ToUpperInvariant(); Rows = @($rows) })
    }
    return @($sections)
}

function ConvertTo-FleetKioskView {
    # One kiosk as a front end draws it: the row on each tab, the details,
    # its screens, and what can be done to it.
    param($Kiosk, [string[]]$DayKeys)

    $k = $Kiosk
    $row0 = $k.StatusRow
    $logAge = ''; $uptime = ''; $watchdog = ''; $agent = ''; $note = ''
    if ($row0) {
        if ($row0.MinutesSinceLastLog) { $logAge = '{0}m' -f [int][double]$row0.MinutesSinceLastLog }
        if ($row0.UptimeHours) {
            $h = [double]$row0.UptimeHours
            $uptime = $(if ($h -ge 48) { '{0}d' -f [int]($h / 24) } else { '{0}h' -f [int]$h })
        }
        elseif ($row0.BootTimeUtc) {
            $boot = ConvertFrom-FleetIsoTime ([string]$row0.BootTimeUtc)
            if ($boot) { $uptime = Format-Minutes (([datetime]::UtcNow - $boot).TotalMinutes) }
        }
        $watchdog = switch ("$($row0.WatchdogRunning)") { 'TRUE' { 'running' } 'FALSE' { 'DEAD' } default { '' } }
        $agent = [string]$row0.AgentVersion
        $note = [string]$row0.Detail
    }
    $reb = ''
    if ($k.Reboots24 -gt 0) { $reb = '{0}' -f $k.Reboots24 }
    if ($k.Script24 -gt 0) { $reb = '{0} ({1})' -f $k.Reboots24, $k.Script24 }

    $days = @(foreach ($d in $DayKeys) { if ($k.Days.ContainsKey($d)) { [int]$k.Days[$d] } else { 0 } })

    $launchers = [ordered]@{}
    foreach ($tab in @('Mach2', 'PBI', 'Web', 'Other')) {
        $lv = Get-FleetLauncherView -Kiosk $k -Tab $(if ($tab -eq 'Other') { '' } else { $tab })
        $launchers[$tab] = [pscustomobject]@{
            Kind = $lv.Kind; Known = $lv.Known; Installed = $lv.Installed; State = $lv.State; For = $lv.For
            Account = $lv.Account; Version = $lv.Version; Screen = $lv.Screen; Severity = $lv.Severity
        }
    }

    $screens = @(foreach ($s in @(if ($k.PSObject.Properties['Screens']) { $k.Screens })) {
            $kind = $FleetKindOfScreenLauncher[[string]$s.Launcher]
            [pscustomobject]@{
                Screen = [string]$s.Screen; Kind = $kind; Name = $FleetLauncherNames[$kind]
                State = [string]$s.State; Severity = (Get-FleetSeverity ([string]$s.HostStatus))
            }
        })

    $installed = @(@($k.Ng, $k.Pbi, $(if ($k.PSObject.Properties['Web']) { $k.Web })) | Where-Object { $_ -and $_.Installed })
    $ver = $(if ($row0) { [string]$row0.AgentVersion } else { '' })
    $messageOk = ($k.Tab -eq 'Mach2' -or [bool]$k.Ng)
    $messageWhy = $(if ($messageOk) { '' } else { 'Only Mach2 kiosks have a watchdog to show a message' })
    if ($messageOk -and $ver -and -not (Test-Mach2NgVersion $ver)) {
        $v = $null
        if (-not ([version]::TryParse($ver.Trim(), [ref]$v)) -or $v -lt [version]'7.0') {
            $messageOk = $false
            $messageWhy = ('runs watchdog v{0}; messages need V7.0 or later, or Mach2 Launcher NG' -f $ver)
        }
    }

    return [pscustomobject]@{
        Host = $k.Host; Location = $k.Location; Type = $k.Type; Tab = $k.Tab; Tabs = @($k.Tabs)
        Status = $k.Status; Severity = (Get-FleetSeverity $k.Status); Attention = [bool](Test-NeedsAttention $k)
        Rank = $(if ($StatusRank.ContainsKey($k.Status)) { $StatusRank[$k.Status] } else { 8 })
        LogAge = $logAge; Uptime = $uptime; Watchdog = $watchdog; Agent = $agent; Reboots = $reb; Days = $days; Note = $note
        Launchers = $launchers; Screens = $screens; Detail = @(Get-FleetKioskDetail -Kiosk $k)
        HasLauncher = ($installed.Count -gt 0); MessageOk = $messageOk; MessageWhy = $messageWhy
        Reboots24 = [int]$k.Reboots24; Script24 = [int]$k.Script24; Episodes24 = [int]$k.Episodes24
    }
}

function Get-FleetDeployNotes {
    # What each kiosk runs, as the deploy list shows it, per product.
    param($Kiosk)
    $k = $Kiosk
    $out = [ordered]@{}
    $ver = $(if ($k.StatusRow) { [string]$k.StatusRow.AgentVersion } else { '' })
    $screens = @(if ($k.PSObject.Properties['Screens']) { $k.Screens })
    foreach ($product in @('NG', 'PBI', 'WEB', 'WATCHDOG')) {
        $tab = switch ($product) { 'NG' { 'Mach2' } 'PBI' { 'PBI' } 'WEB' { '*' } default { 'Mach2' } }
        $lv = Get-FleetLauncherView -Kiosk $k -Tab $(if ($tab -eq '*') { 'Web' } else { $tab })
        $bits = @()
        if ($lv.Installed) { $bits += ('{0} v{1}' -f $FleetLauncherNames[$lv.Kind], $lv.Version) }
        elseif ($lv.State) { $bits += $lv.State }
        if ($screens.Count -gt 1 -or ($screens.Count -and $tab -eq '*')) {
            $bits += (@($screens | ForEach-Object { '{0} {1}' -f $_.Screen, $FleetLauncherNames[$FleetKindOfScreenLauncher[[string]$_.Launcher]] }) -join ', ')
        }
        if ($product -eq 'WATCHDOG' -and $ver) { $bits += ('watchdog v{0}' -f $ver) }
        elseif ($ver -and -not $lv.Installed) { $bits += ('agent v{0}' -f $ver) }
        $out[$product] = ($bits -join ', ')
    }
    return [pscustomobject]$out
}

function ConvertTo-FleetView {
    <#
        The whole fleet as a front end needs it, in one object: the
        headline, the numbers, a week of reboots, the collector's own
        report, and every kiosk. Freshness is left out - it changes by the
        minute, so the caller works it out when it answers.
    #>
    param($State)

    if (-not $State -or -not $State.Ok) {
        return [pscustomobject]@{ Ok = $false; Error = $(if ($State) { [string]$State.Error } else { 'not read yet' }); Kiosks = @() }
    }

    $hosts = @($State.Hosts)
    $kiosks = @(foreach ($k in $hosts) {
            $v = ConvertTo-FleetKioskView -Kiosk $k -DayKeys $State.DayKeys
            $v | Add-Member -NotePropertyName DeployNotes -NotePropertyValue (Get-FleetDeployNotes -Kiosk $k)
            $v
        })

    $attention = @($hosts | Where-Object { Test-NeedsAttention $_ })
    $crit = @($attention | Where-Object { (Get-FleetSeverity $_.Status) -eq 'CRITICAL' }).Count
    $onTab = { param($t) @($hosts | Where-Object { $_.Tab -eq $t -or @($_.Tabs) -contains $t }) }
    $tabs = [ordered]@{}
    foreach ($t in @('Mach2', 'PBI', 'Web', 'Other')) {
        $list = @(& $onTab $t)
        $tabs[$t] = [pscustomobject]@{ Count = $list.Count; Attention = @($list | Where-Object { Test-NeedsAttention $_ }).Count }
    }

    $totals = @{}
    foreach ($k in $hosts) { foreach ($d in $k.Days.Keys) { if (-not $totals.ContainsKey($d)) { $totals[$d] = 0 }; $totals[$d] += $k.Days[$d] } }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $chart = @(foreach ($d in $State.DayKeys) {
            $day = [datetime]::ParseExact($d, 'yyyy-MM-dd', $inv)
            [pscustomobject]@{ Day = $d; Label = $day.ToString('ddd'); Long = $day.ToString('ddd dd MMM'); Count = $(if ($totals.ContainsKey($d)) { [int]$totals[$d] } else { 0 }) }
        })

    $ng = @($hosts | Where-Object { $_.StatusRow -and (Test-Mach2NgVersion ([string]$_.StatusRow.AgentVersion)) }).Count
    $pbi = @($hosts | Where-Object { $_.Pbi -and $_.Pbi.Installed }).Count
    $web = @($hosts | Where-Object { $_.PSObject.Properties['Web'] -and $_.Web -and $_.Web.Installed }).Count

    $collector = $null
    $sc = $State.Sidecar
    if ($sc) {
        $collector = [pscustomobject]@{
            Took = [int]$sc.DurationSeconds; Reachable = $sc.Reachable; Hosts = $sc.Hosts; NewEvents = $sc.NewEvents
            Version = [string]$sc.CollectorVersion; Runner = [string]$sc.Runner
        }
    }

    return [pscustomobject]@{
        Ok = $true; Error = $null
        Total = $hosts.Count; Attention = $attention.Count; Critical = $crit
        Inactive = @($hosts | Where-Object { $_.Status -eq 'INACTIVE' }).Count
        Reboots24 = [int](($hosts | Measure-Object -Property Reboots24 -Sum).Sum)
        Script24 = [int](($hosts | Measure-Object -Property Script24 -Sum).Sum)
        Episodes24 = [int](($hosts | Measure-Object -Property Episodes24 -Sum).Sum)
        Launchers = [pscustomobject]@{ Ng = $ng; Pbi = $pbi; Web = $web }
        Tabs = $tabs; Chart = $chart; DayKeys = @($State.DayKeys)
        Collector = $collector; RowCount = $State.RowCount; File = (Split-Path -Leaf ([string]$State.Path))
        Kiosks = $kiosks
    }
}

# ---------------------------------------------------------------------------
# The kiosk's own settings
# ---------------------------------------------------------------------------
$FleetConfigPrimary = @{
    NG  = @('DisplayURL', 'LoginURL', 'UserName', 'ScreenSelect')
    PBI = @('DisplayURL', 'UserName', 'ScreenSelect')
    WEB = @('DisplayURL', 'TargetMatch', 'ScreenSelect')
}
$FleetConfigRequired = @{ NG = @('DisplayURL', 'UserName'); PBI = @('DisplayURL', 'UserName'); WEB = @('DisplayURL') }
$FleetConfigBools = @('EnableRefresh', 'KioskMode', 'UsePriScreen', 'ScheduledRestartEnabled', 'DisableStartup',
    'DebugLogging', 'Watchdog', 'StopOldLauncher', 'InPrivate', 'StaySignedIn', 'BackButton')
$FleetConfigLabels = @{
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

function Get-FleetConfigTemplate {
    # EXAMPLE.json as it ships here, in file order, with the kiosk's own name
    # where the example had one.
    param([string]$ScriptDir, [string]$Kind, [string]$HostName, [string]$Instance = 'S1')

    $path = Join-Path $ScriptDir (Join-Path $FleetLauncherFolders[$Kind] 'EXAMPLE.json')
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

function New-FleetConfigFieldList {
    # The editor's fields: the few that matter first, the password, then
    # everything else in the file as advanced settings.
    param([string]$Kind, [array]$Pairs, [switch]$IsNew)

    $labels = $FleetConfigLabels[$Kind]
    $primary = $FleetConfigPrimary[$Kind]
    $fields = New-Object System.Collections.ArrayList
    foreach ($key in $primary) {
        $pair = @($Pairs | Where-Object { $_.Key -eq $key })[0]
        $label = $key; $hint = ''
        if ($labels.ContainsKey($key)) { $label = $labels[$key].Label; $hint = $labels[$key].Hint }
        [void]$fields.Add([pscustomobject]@{ Key = $key; Label = $label; Value = $(if ($pair) { [string]$pair.Value } else { '' }); Hint = $hint; Kind = 'text'; Advanced = $false })
    }
    if ($Kind -ne 'WEB') {
        [void]$fields.Add([pscustomobject]@{
                Key = '__password'; Label = 'Sign-in password'; Value = ''; Kind = 'password'; Advanced = $false
                Hint = $(if ($IsNew) { 'Handed to the launcher as password.seed; it encrypts it for the kiosk account.' }
                    else { 'Leave both empty to keep the password already stored on the kiosk.' })
            })
    }
    foreach ($pair in @($Pairs | Where-Object { $primary -notcontains $_.Key })) {
        $isBool = ($FleetConfigBools -contains $pair.Key)
        [void]$fields.Add([pscustomobject]@{ Key = $pair.Key; Label = $pair.Key; Value = [string]$pair.Value; Hint = ''; Kind = $(if ($isBool) { 'bool' } else { 'text' }); Advanced = $true })
    }
    return @($fields)
}

# ---------------------------------------------------------------------------
# The actions. Each one returns an object with Ok and Detail at least.
# ---------------------------------------------------------------------------
function Invoke-FleetLiveRead {
    param([hashtable]$Ctx)
    $share = Open-KioskShare -HostName $Ctx.Target -RootTemplate $Ctx.RootTemplate -Credential $Ctx.Credential
    if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
    try {
        $parts = @()
        if ($Ctx.Kind -in @('ALL', 'NG')) { $parts += Get-Mach2NgObservation -Folder (Get-PublicDocs $share.Root) -StaleMinutes $FleetLiveStaleMinutes }
        if ($Ctx.Kind -in @('ALL', 'PBI')) { $parts += Get-PbiLauncherObservation -Root $share.Root -StaleMinutes $FleetLiveStaleMinutes -HostName $Ctx.Target }
        if ($Ctx.Kind -in @('ALL', 'WEB')) { $parts += Get-WebLauncherObservation -Root $share.Root -StaleMinutes $FleetLiveStaleMinutes -HostName $Ctx.Target }
        $obs = [pscustomobject]@{
            Installed = [bool]@($parts | Where-Object { $_.Installed }).Count
            Instances = @($parts | ForEach-Object { $_.Instances } | Where-Object { $_ -and (-not $Ctx.Screen -or ([string]$_.Screen -eq $Ctx.Screen)) })
            Error     = (@($parts | Where-Object { $_.Error } | ForEach-Object { $_.Error }) -join '; ')
        }

        $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen)
        $lines = New-Object System.Collections.ArrayList
        $hold = $false
        $config = $null
        if (-not $obs.Installed) { [void]$lines.Add((New-FleetDetailRow 'Installed' 'no' 'WARNING')) }
        foreach ($d in $dirs) {
            if (-not $config) { $config = Read-KioskJson -Path (Join-Path $d.Dir "$($Ctx.Target).json") }
            if (Test-Path -LiteralPath (Join-Path $d.Dir 'hold.txt')) {
                $hold = $true
                [void]$lines.Add((New-FleetDetailRow ('{0} {1}' -f $d.Instance, $d.Kind) 'on hold (hold.txt) - no checks, no reloads' 'WARNING' -Wrap))
            }
            if (Test-Path -LiteralPath (Join-Path $d.Dir 'kill.txt')) {
                [void]$lines.Add((New-FleetDetailRow $d.Instance 'kill.txt is waiting - the launcher stops when it sees it' 'WARNING' -Wrap))
            }
        }
        foreach ($i in @($obs.Instances)) {
            $as = $(if ($i.PSObject.Properties['SignedInAs'] -and $i.SignedInAs) { " as $($i.SignedInAs)" } else { '' })
            $label = $(if ($i.PSObject.Properties['Screen'] -and $i.Screen) { '{0} {1}' -f $i.Screen, $i.Launcher } else { [string]$i.Instance })
            [void]$lines.Add((New-FleetDetailRow $label ('{0}{1}, {2} old' -f $i.State, $as, (Format-Minutes $i.AgeMinutes)) $(if ($i.Severity -eq 'CRITICAL') { 'CRITICAL' } else { 'DIM' }) -Wrap))
            if ($i.Detail) { [void]$lines.Add((New-FleetDetailRow '' ([string]$i.Detail) 'DIM' -Wrap)) }
        }
        if ($config) {
            $url = $(if ($config.PSObject.Properties['DisplayURL']) { [string]$config.DisplayURL } elseif ($config.PSObject.Properties['URL']) { [string]$config.URL } else { '' })
            if ($url) { [void]$lines.Add((New-FleetDetailRow 'Shows' $url 'DIM' -Wrap)) }
            $user = $(if ($config.PSObject.Properties['UserName']) { [string]$config.UserName } else { '' })
            if ($user) { [void]$lines.Add((New-FleetDetailRow 'Signs in as' $user 'DIM')) }
        }
        $pwState = 'none stored - signing in needs a person'
        if (-not @($dirs | Where-Object { $_.Kind -ne 'WEB' }).Count) { $pwState = 'none needed (a web page)' }
        foreach ($d in @($dirs | Where-Object { $_.Kind -ne 'WEB' })) {
            if (Test-Path -LiteralPath (Join-Path $d.Dir 'password.seed')) { $pwState = 'a new one is waiting for the launcher'; break }
            if (@(Get-ChildItem -LiteralPath $d.Dir -Filter '*.cred' -File -ErrorAction SilentlyContinue).Count) { $pwState = 'stored, encrypted for the kiosk account' }
        }
        [void]$lines.Add((New-FleetDetailRow 'Password' $pwState 'DIM'))
        if ($obs.Error) { [void]$lines.Add((New-FleetDetailRow 'Error' ([string]$obs.Error) 'WARNING' -Wrap)) }

        return [pscustomobject]@{ Ok = $true; Detail = 'read just now'; Hold = $hold; Lines = @($lines); Instances = @($dirs | ForEach-Object { $_.Instance }); Installed = $obs.Installed }
    }
    catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
    finally { Close-KioskShare -Share $share }
}

function Send-FleetControl {
    # Drops a control file in each of the kiosk's launcher folders (or
    # removes it, for -Remove) and waits for the launcher to take it.
    param([hashtable]$Ctx)
    $share = Open-KioskShare -HostName $Ctx.Target -RootTemplate $Ctx.RootTemplate -Credential $Ctx.Credential
    if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
    try {
        $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen)
        if ($dirs.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Detail = 'the launcher is not installed here' } }
        $taken = 0; $sent = 0
        foreach ($d in $dirs) {
            $path = Join-Path $d.Dir $Ctx.File
            if ($Ctx['Remove']) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
                $sent++; $taken++
                continue
            }
            [IO.File]::WriteAllText($path, ('{0} by {1} from Kiosk Fleet Web' -f (Get-Date -Format s), $Ctx.Who))
            $sent++
            Say ('{0} {1}: {2} written' -f $d.Instance, $d.Kind, $Ctx.File)
            if (Wait-ControlFileTaken -Path $path -Seconds 20) { $taken++ }
        }
        $detail = $(if ($taken -ge $sent) { 'the launcher has taken it' } else { 'not taken within 20 s - it stays, and the launcher acts on it when it next looks' })
        return [pscustomobject]@{ Ok = $true; Detail = $detail; Sent = $sent; Taken = $taken; Waiting = ($taken -lt $sent); Instances = @($dirs | ForEach-Object { $_.Instance }) }
    }
    catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
    finally { Close-KioskShare -Share $share }
}

function Invoke-FleetSnapshot {
    param([hashtable]$Ctx)
    $share = Open-KioskShare -HostName $Ctx.Target -RootTemplate $Ctx.RootTemplate -Credential $Ctx.Credential
    if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
    try {
        $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen)
        if ($dirs.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Detail = 'the launcher is not installed here' } }

        $before = @{}
        foreach ($d in $dirs) {
            foreach ($f in @(Get-ChildItem -LiteralPath $d.Status -Filter '*.snapshot.json' -File -ErrorAction SilentlyContinue)) { $before[$f.FullName] = $f.LastWriteTimeUtc }
            [IO.File]::WriteAllText((Join-Path $d.Dir 'snapshot.txt'), ('{0} by {1} from Kiosk Fleet Web' -f (Get-Date -Format s), $Ctx.Who))
        }
        Say 'asked the launcher for a picture'

        $deadline = (Get-Date).AddSeconds(45)
        $info = $null; $where = $null
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

        $out = [pscustomobject]@{ Ok = $true; Detail = 'screenshot saved'; Image = ''; File = ''; State = [string]$info.State; Url = [string]$info.Url; Title = [string]$info.Title; Instance = $where.Instance }
        if ($info.Error -or -not $info.Image) {
            $out.Ok = $false
            $out.Detail = $(if ($info.Error) { [string]$info.Error } else { 'the launcher saved no picture' })
            return $out
        }
        # Only a file name the launcher wrote into its own Status folder.
        $leaf = Split-Path -Leaf ([string]$info.Image)
        $src = Join-Path $where.Status $leaf
        if (-not (Test-Path -LiteralPath $src)) { $out.Ok = $false; $out.Detail = "the picture is missing: $src"; return $out }
        if (-not (Test-Path -LiteralPath $Ctx.Dest)) { New-Item -ItemType Directory -Path $Ctx.Dest -Force | Out-Null }
        $name = '{0}_{1}_{2}.png' -f $Ctx.Target, $where.Instance, (Get-Date -Format 'yyyyMMdd-HHmmss')
        $dest = Join-Path $Ctx.Dest $name
        Copy-Item -LiteralPath $src -Destination $dest -Force
        $out.Image = $dest
        $out.File = $name
        return $out
    }
    catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
    finally { Close-KioskShare -Share $share }
}

function Read-FleetLauncherLog {
    param([hashtable]$Ctx)
    $share = Open-KioskShare -HostName $Ctx.Target -RootTemplate $Ctx.RootTemplate -Credential $Ctx.Credential
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
            if ($config.PSObject.Properties['LogName'] -and $config.LogName) { $name = Split-Path -Leaf ([string]$config.LogName) }
        }
        $path = $(if ($name) { Join-Path $logDir $name } else { '' })
        if (-not $path -or -not (Test-Path -LiteralPath $path)) {
            $newest = @(Get-ChildItem -LiteralPath $logDir -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)[0]
            if (-not $newest) { return [pscustomobject]@{ Ok = $false; Detail = "no log in $logDir" } }
            $path = $newest.FullName
        }

        $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            if ($fs.Length -gt 262144) { [void]$fs.Seek(-262144, [IO.SeekOrigin]::End) }
            $reader = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)
            try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
        }
        finally { $fs.Dispose() }

        $entries = [regex]::Matches($text, '<!\[LOG\[(?<m>.*?)\]LOG\]!><time="(?<t>\d\d:\d\d:\d\d)[^"]*" date="(?<d>[^"]*)"[^>]*?type="(?<ty>\d)"',
            [Text.RegularExpressions.RegexOptions]::Singleline)
        $count = $(if ($Ctx.Lines) { [int]$Ctx.Lines } else { 60 })
        $out = New-Object System.Collections.ArrayList
        for ($i = [math]::Max(0, $entries.Count - $count); $i -lt $entries.Count; $i++) {
            $e = $entries[$i]
            $d2 = $e.Groups['d'].Value
            if ($d2 -match '^(\d\d)-(\d\d)-\d{4}$') { $d2 = "$($Matches[2]).$($Matches[1])." }
            $mark = switch ($e.Groups['ty'].Value) { '3' { '!' } '2' { '*' } default { ' ' } }
            [void]$out.Add(('{0} {1,-7}{2}  {3}' -f $mark, $d2, $e.Groups['t'].Value, ($e.Groups['m'].Value.TrimEnd() -replace "\r?\n", ' ')))
        }
        if ($entries.Count -eq 0) { [void]$out.Add('(no entries)') }
        return [pscustomobject]@{ Ok = $true; Detail = $path; Path = $path; Lines = @($out) }
    }
    catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
    finally { Close-KioskShare -Share $share }
}

function Set-FleetSignInPassword {
    param([hashtable]$Ctx)
    $share = Open-KioskShare -HostName $Ctx.Target -RootTemplate $Ctx.RootTemplate -Credential $Ctx.Credential
    if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
    $plain = $null
    try {
        # A web page signs in to nothing.
        $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target -Screen $Ctx.Screen | Where-Object { $_.Kind -ne 'WEB' })
        if ($dirs.Count -eq 0) { return [pscustomobject]@{ Ok = $false; Detail = 'no launcher that signs in on this screen' } }
        $plain = ConvertFrom-SecureText $Ctx.Secret
        $seeds = @(foreach ($d in $dirs) { Write-PasswordSeed -Dir $d.Dir -Plain $plain })
        $plain = $null
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
}

function Read-FleetKioskConfig {
    # The config of one screen, or - for a kiosk with none yet - the
    # launcher's EXAMPLE.json, as editor fields.
    param([hashtable]$Ctx)
    $share = Open-KioskShare -HostName $Ctx.Target -RootTemplate $Ctx.RootTemplate -Credential $Ctx.Credential
    if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
    try {
        $dirs = @(Get-LauncherDirs -Root $share.Root -Kind $Ctx.Kind -HostName $Ctx.Target)
        $instances = @($dirs | ForEach-Object { $_.Instance })
        $instance = $(if ($Ctx.Instance) { $Ctx.Instance } elseif ($instances.Count) { $instances[0] } else { 'S1' })
        # Which launcher has which screen, so a new config does not land on
        # a screen another launcher shows.
        $taken = [ordered]@{}
        foreach ($d in @(Get-LauncherDirs -Root $share.Root -Kind 'ALL' -HostName $Ctx.Target)) { if ($d.Kind -ne $Ctx.Kind) { $taken[$d.Instance] = $d.Kind } }

        $dir = @($dirs | Where-Object { $_.Instance -eq $instance })[0]
        $pairs = @(); $exists = $false; $password = 'none stored'
        if ($dir) {
            $config = Read-KioskJson -Path (Join-Path $dir.Dir "$($Ctx.Target).json")
            if ($config) {
                $exists = $true
                $pairs = @($config.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Value = [string]$_.Value } })
            }
            if (Test-Path -LiteralPath (Join-Path $dir.Dir 'password.seed')) { $password = 'a new one is waiting for the launcher' }
            elseif (@(Get-ChildItem -LiteralPath $dir.Dir -Filter '*.cred' -File -ErrorAction SilentlyContinue).Count) { $password = 'stored, encrypted for the kiosk account' }
        }
        if (-not $exists) { $pairs = @(Get-FleetConfigTemplate -ScriptDir $Ctx.ScriptDir -Kind $Ctx.Kind -HostName $Ctx.Target -Instance $instance) }
        return [pscustomobject]@{
            Ok = $true; Detail = ''; Kind = $Ctx.Kind; Exists = $exists; IsNew = (-not $exists); Instance = $instance; Instances = $instances
            Password = $password; Taken = [pscustomobject]$taken
            Fields = @(New-FleetConfigFieldList -Kind $Ctx.Kind -Pairs $pairs -IsNew:(-not $exists))
        }
    }
    catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
    finally { Close-KioskShare -Share $share }
}

function Write-FleetKioskConfig {
    <#
        Saves one screen's config. The file is read again here rather than
        trusting what came back from the editor: its keys and their order
        are the file's (or EXAMPLE.json's for a new one), and only those -
        plus the few every config needs - can be set. The old file is kept
        as <HOST>.json.bak-<time>.
    #>
    param([hashtable]$Ctx)
    $share = Open-KioskShare -HostName $Ctx.Target -RootTemplate $Ctx.RootTemplate -Credential $Ctx.Credential
    if ($share.Error) { return [pscustomobject]@{ Ok = $false; Detail = $share.Error } }
    $plain = $null
    try {
        $dir = Get-ScreenDir -Root $share.Root -Kind $Ctx.Kind -Instance $Ctx.Instance -HostName $Ctx.Target
        # One launcher per screen, checked on the kiosk itself.
        $other = @(Get-LauncherDirs -Root $share.Root -Kind 'ALL' -HostName $Ctx.Target -Screen $Ctx.Instance | Where-Object { $_.Kind -ne $Ctx.Kind })
        if ($other.Count) { return [pscustomobject]@{ Ok = $false; Detail = ('{0} already has a config for {1} - one launcher per screen' -f $Ctx.Instance, $FleetLauncherNames[$other[0].Kind]) } }

        $configPath = Join-Path $dir "$($Ctx.Target).json"
        $existing = Read-KioskJson -Path $configPath
        $isNew = (-not $existing)
        $pairs = $(if ($existing) { @($existing.PSObject.Properties | ForEach-Object { [pscustomobject]@{ Key = $_.Name; Value = [string]$_.Value } }) }
            else { @(Get-FleetConfigTemplate -ScriptDir $Ctx.ScriptDir -Kind $Ctx.Kind -HostName $Ctx.Target -Instance $Ctx.Instance) })

        $values = [ordered]@{}
        foreach ($p in $pairs) { $values[$p.Key] = [string]$p.Value }
        foreach ($key in $FleetConfigPrimary[$Ctx.Kind]) { if (-not $values.Contains($key)) { $values[$key] = '' } }
        $typed = $Ctx['Values']
        foreach ($key in @($values.Keys)) {
            if ($typed.ContainsKey($key)) { $values[$key] = [string]$typed[$key] }
        }
        $missing = @($FleetConfigRequired[$Ctx.Kind] | Where-Object { -not $values[$_] })
        if ($missing.Count) { return [pscustomobject]@{ Ok = $false; Detail = ('still empty: {0}' -f ($missing -join ', ')) } }

        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Say "created $dir"
        }
        # Only the kiosk's first Mach2 screen is the watchdog: two on one PC
        # would both want to restart it. S2 can be the first where S1 shows
        # Power BI.
        if ($Ctx.Kind -eq 'NG' -and $isNew -and $values.Contains('Watchdog')) {
            $ng = @(Get-LauncherDirs -Root $share.Root -Kind 'NG' -HostName $Ctx.Target | Where-Object { $_.Instance -ne $Ctx.Instance })
            $first = -not @($ng | Where-Object { [string]::CompareOrdinal($_.Instance, $Ctx.Instance) -lt 0 }).Count
            $values['Watchdog'] = $(if ($first) { '1' } else { '0' })
            Say $(if ($first) { 'the first Mach2 screen here, so it is the watchdog' } else { 'not the first Mach2 screen here, so it is not the watchdog' })
        }
        # A sign-in URL left empty is the dashboard's host.
        if ($Ctx.Kind -eq 'NG' -and $values.Contains('LoginURL') -and -not $values['LoginURL'] -and $values['DisplayURL']) {
            try {
                $u = [uri]$values['DisplayURL']
                $values['LoginURL'] = ('{0}://{1}/prelogin?clear=true' -f $u.Scheme, $u.Authority)
                Say ('sign-in URL: {0}' -f $values['LoginURL'])
            }
            catch { }
        }

        if (Test-Path -LiteralPath $configPath) {
            $backup = '{0}.bak-{1}' -f $configPath, (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $configPath -Destination $backup -Force
            Say ('the old one is kept as {0}' -f (Split-Path -Leaf $backup))
        }
        $json = ConvertTo-Json -InputObject ([pscustomobject]$values) -Depth 4
        [IO.File]::WriteAllText("$configPath.tmp", $json, (New-Object Text.UTF8Encoding($false)))
        Move-Item -LiteralPath "$configPath.tmp" -Destination $configPath -Force
        Say "saved $configPath"

        $out = [pscustomobject]@{ Ok = $true; IsNew = $isNew; Path = $configPath; Password = ''
            Detail = $(if ($isNew) { 'Written. The kiosk can be deployed to now: {0}, on {1}.' -f $FleetLauncherNames[$Ctx.Kind], $Ctx.Instance } else { 'Saved. The launcher reads it again within seconds.' })
        }
        if ($Ctx.Secret -and $Ctx.Kind -ne 'WEB') {
            $plain = ConvertFrom-SecureText $Ctx.Secret
            $seed = Write-PasswordSeed -Dir $dir -Plain $plain
            $plain = $null
            Say 'password.seed written'
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                if (-not (Test-Path -LiteralPath $seed)) { break }
                Start-Sleep -Milliseconds 500
            }
            $out.Password = $(if (Test-Path -LiteralPath $seed) { 'waiting for the launcher to store it' } else { 'stored by the launcher' })
            Say ('password: {0}' -f $out.Password)
        }
        return $out
    }
    catch { return [pscustomobject]@{ Ok = $false; Detail = $_.Exception.Message } }
    finally { $plain = $null; Close-KioskShare -Share $share }
}

function Invoke-FleetRestart {
    # Over CIM/DCOM (Lib\MWST.Remote.ps1). A countdown of 0 restarts at
    # once, with nothing on the screen.
    param([hashtable]$Ctx)
    $comment = $(if ($Ctx.Secs -gt 0) { [string]$Ctx.Message } else { '' })
    Say ('restarting {0} ...' -f $Ctx.Target)
    $r = Send-KioskRestart -HostName $Ctx.Target -Credential $Ctx.Credential -WarningSeconds $Ctx.Secs -Comment $comment
    if ($r -and $r.Sent) { return [pscustomobject]@{ Ok = $true; Detail = ('sent over {0} - the kiosk restarts and comes back on its own' -f $r.Via) } }
    return [pscustomobject]@{ Ok = $false; Detail = $(if ($r -and $r.Detail) { [string]$r.Detail } else { 'it did not go through' }) }
}

function Invoke-FleetMessage {
    param([hashtable]$Ctx)
    $folder = ($Ctx.RootTemplate + '\Users\Public\Documents')
    $r = Invoke-KioskMessage -HostName $Ctx.Target -Text $Ctx.Text -Seconds $Ctx.Secs -Credential $Ctx.Credential `
        -FolderTemplate $folder -Progress { param($s) Say $s }
    $ok = ("$($r.Status)" -in @('SHOWN', 'ACKNOWLEDGED', 'TIMEOUT'))
    return [pscustomobject]@{ Ok = $ok; Status = [string]$r.Status; Detail = ('{0}: {1}' -f $r.Status, $r.Detail); Waiting = ("$($r.Status)" -eq 'TIMEOUT') }
}

function Invoke-FleetAction {
    # The one way in for a background runspace: $Ctx.Action picks the work.
    param([hashtable]$Ctx)
    $script:FleetSay = $Ctx.Say
    switch ($Ctx.Action) {
        'live' { return (Invoke-FleetLiveRead -Ctx $Ctx) }
        'control' { return (Send-FleetControl -Ctx $Ctx) }
        'snapshot' { return (Invoke-FleetSnapshot -Ctx $Ctx) }
        'log' { return (Read-FleetLauncherLog -Ctx $Ctx) }
        'password' { return (Set-FleetSignInPassword -Ctx $Ctx) }
        'config-read' { return (Read-FleetKioskConfig -Ctx $Ctx) }
        'config-write' { return (Write-FleetKioskConfig -Ctx $Ctx) }
        'restart' { return (Invoke-FleetRestart -Ctx $Ctx) }
        'message' { return (Invoke-FleetMessage -Ctx $Ctx) }
        'read-state' {
            $state = Read-FleetState -Path $Ctx.Csv
            $view = ConvertTo-FleetView -State $state
            return [pscustomobject]@{ Ok = $true; State = $state; Json = (ConvertTo-Json -InputObject $view -Depth 12 -Compress) }
        }
        default { return [pscustomobject]@{ Ok = $false; Detail = "unknown action '$($Ctx.Action)'" } }
    }
}

# ---------------------------------------------------------------------------
# Deploy command lines
# ---------------------------------------------------------------------------
$FleetDeployProducts = [ordered]@{
    NG       = @{ Name = 'Mach2 Launcher NG'; Tab = 'Mach2'; Script = 'Deploy-Mach2LauncherNG.ps1'
        Note = 'The launcher and the watchdog in one. Carries the settings over from Mach2Launcher.exe, and retires that and the MWST watchdog. Roll back puts both of them back.' }
    PBI      = @{ Name = 'PBI Launcher'; Tab = 'PBI'; Script = 'Deploy-PbiLauncher.ps1'
        Note = 'Replaces PowerBILauncher.exe, carrying its settings over. Roll back puts the old launcher back.' }
    WEB      = @{ Name = 'Web Launcher'; Tab = '*'; Script = 'Deploy-WebLauncher.ps1'
        Note = 'One web page on a screen, full screen, kept there - no sign-in. Any kiosk can have one on a free screen: write its config first (Config... on the kiosk, or Add a kiosk...), then install. Roll back removes it and puts back any old launcher it replaced.' }
    WATCHDOG = @{ Name = 'MWST watchdog'; Tab = 'Mach2'; Script = 'Deploy-MWSTAgent.ps1'
        Note = 'The old white-screen watchdog on its own, for Mach2 kiosks not moved to the NG launcher yet. It has no roll back.' }
}

function Get-FleetDeployCommand {
    <#
        The deploy command line for a set of choices, built here from
        checked values only - never from text a browser sent - so what runs
        is exactly what was previewed. Throws on anything that is not valid.
    #>
    param(
        [Parameter(Mandatory)][string]$Product,
        [string[]]$Hosts,
        [switch]$Rollback,
        [switch]$Restart,
        [int]$WarnSeconds = 60,
        [int]$VerifyMinutes = 12,
        [switch]$Force,
        [switch]$UpdateConfig,
        [switch]$KeepLegacy,
        [switch]$KeepWatchdog,
        [switch]$RegisterTask,
        [string]$KioskUser,
        [string]$CredentialFile,
        [string]$ScriptDir,
        [switch]$DryRun
    )
    if (-not $FleetDeployProducts.Contains($Product)) { throw "unknown product '$Product'" }
    foreach ($h in @($Hosts)) { if (-not (Get-FleetHostName $h)) { throw ("'{0}' is not a kiosk name" -f $h) } }
    # Sorted by name, so the same ticks always make the same command.
    $hostList = @($Hosts | ForEach-Object { Get-FleetHostName $_ } | Sort-Object -Unique)
    if ($hostList.Count -eq 0) { throw 'no kiosks ticked' }
    if ($WarnSeconds -lt 0 -or $WarnSeconds -gt 600) { throw 'the countdown has to be 0 to 600 seconds' }
    if ($VerifyMinutes -lt 2 -or $VerifyMinutes -gt 60) { throw 'the wait has to be 2 to 60 minutes' }
    if ($KioskUser -and $KioskUser -notmatch '^[A-Za-z0-9][A-Za-z0-9 ._@\\-]{0,103}$') { throw 'that is not a Windows account name' }

    $isWd = ($Product -eq 'WATCHDOG')
    $list = New-Object System.Collections.ArrayList
    [void]$list.Add('-Hosts ' + ((@($hostList | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" })) -join ','))
    if ($Rollback -and -not $isWd) { [void]$list.Add('-Rollback') }
    if ($Restart) {
        if ($isWd) {
            [void]$list.Add('-RebootAndVerify')
            [void]$list.Add("-RebootWarningSeconds $WarnSeconds")
        }
        else {
            [void]$list.Add('-Restart')
            [void]$list.Add("-RestartWarningSeconds $WarnSeconds")
            [void]$list.Add("-VerifyMinutes $VerifyMinutes")
        }
    }
    if ($Force) { [void]$list.Add('-Force') }
    if (-not $isWd) {
        if ($UpdateConfig -and -not $Rollback -and $Product -ne 'WEB') { [void]$list.Add('-UpdateConfig') }
        if ($KeepLegacy -and -not $Rollback) { [void]$list.Add('-KeepLegacy') }
        if ($Product -eq 'NG' -and $KeepWatchdog -and -not $Rollback) { [void]$list.Add('-KeepWatchdog') }
        if ($KioskUser) { [void]$list.Add("-KioskUser '{0}'" -f ($KioskUser -replace "'", "''")) }
    }
    elseif ($RegisterTask) { [void]$list.Add('-RegisterLauncherTask') }

    if ($CredentialFile -and (Test-Path -LiteralPath $CredentialFile)) {
        $rel = $CredentialFile
        if ($ScriptDir -and $CredentialFile.StartsWith($ScriptDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $rel = $CredentialFile.Substring($ScriptDir.Length + 1) }
        [void]$list.Add("-CredentialFile '{0}'" -f ($rel -replace "'", "''"))
    }
    if ($DryRun) { [void]$list.Add('-WhatIf') }

    $file = '.\' + $FleetDeployProducts[$Product].Script
    return [pscustomobject]@{
        Product = $Product; Hosts = $hostList; Arguments = @($list)
        Command = ('& ''{0}'' {1}' -f $file, (@($list) -join ' '))
        Preview = ('{0} {1}' -f $file, (@($list) -join "`n    "))
        Title = $(if ($Rollback -and -not $isWd) { 'Roll back {0}' -f $FleetDeployProducts[$Product].Name } else { 'Install / update {0}' -f $FleetDeployProducts[$Product].Name })
    }
}
