<#
.SYNOPSIS
    Turning the fleet events CSV into the state both front ends draw: the
    Kiosk Fleet Manager window (Show-FleetManager.ps1) and the terminal
    dashboard (Show-FleetDashboard.ps1).

.DESCRIPTION
    Dot-sourced after Lib\MWST.Remote.ps1 (for Read-SharedText) and
    Lib\MWST.KioskList.ps1 (for Resolve-KioskListPath).

    Nothing here draws anything or knows about colours: it reads the same
    single CSV the Power BI report reads, plus the collector's status
    sidecar next to it, and returns one object per kiosk with its latest
    status, reboot counts, a week of daily counts, and the launcher details
    the collector left behind.
#>

Set-StrictMode -Off

# How bad a status is, for sorting: trouble at the top, and the kiosks that
# are deliberately not watched at the bottom.
$StatusRank = @{
    'OFFLINE' = 0; 'LOOP_GUARD' = 1; 'NO_AGENT' = 2; 'STALE' = 3
    'LAUNCHER_STALE' = 1; 'LAUNCHER_STOPPED' = 1; 'LAUNCHER_ERROR' = 1; 'SIGNIN_BLOCKED' = 1; 'WRONG_ACCOUNT' = 1
    'NO_ACCESS' = 4; 'AGENT_OUTDATED' = 5; 'EVENTLOG_UNAVAILABLE' = 6
    'RECOVERING' = 5; 'NOT_SHOWING' = 5; 'NO_DISPLAY' = 5; 'HOLD' = 6; 'UNSUPERVISED' = 6; 'LAUNCHER_DISABLED' = 6; 'LAUNCHER_NOT_RUN' = 6
    'OK' = 9; 'INACTIVE' = 10
}
$CriticalStatuses = @('OFFLINE', 'STALE', 'NO_AGENT', 'LOOP_GUARD', 'LAUNCHER_STALE', 'LAUNCHER_STOPPED', 'LAUNCHER_ERROR', 'SIGNIN_BLOCKED', 'WRONG_ACCOUNT')
$WarningStatuses = @('NO_ACCESS', 'AGENT_OUTDATED', 'EVENTLOG_UNAVAILABLE', 'RECOVERING', 'NOT_SHOWING', 'NO_DISPLAY', 'HOLD', 'UNSUPERVISED', 'LAUNCHER_DISABLED', 'LAUNCHER_NOT_RUN')

function Test-NeedsAttention {
    # INACTIVE is a decision, not a fault: those kiosks are deliberately not
    # scanned, so they must not be counted as problems or the headline is
    # permanently wrong.
    param($Kiosk)
    return ($Kiosk.Status -ne 'OK' -and $Kiosk.Status -ne 'INACTIVE')
}

function Get-FleetSeverity {
    # OK / CRITICAL / WARNING / INACTIVE / UNKNOWN - what a front end colours by.
    param([string]$Status)
    if ($Status -eq 'OK') { return 'OK' }
    if ($Status -eq 'INACTIVE') { return 'INACTIVE' }
    if ($Status -in $CriticalStatuses) { return 'CRITICAL' }
    if ($Status -in $WarningStatuses) { return 'WARNING' }
    return 'UNKNOWN'
}

function Get-ShortType {
    param([string]$Type)
    if (-not $Type) { return '' }
    $t = $Type.Trim()
    if ($t -match '^(PBI|POWER\s*BI)') { return 'PBI' }
    if ($t -match '^MACH') { return 'Mach2' }
    if ($t -match '^WEB') { return 'Web' }
    return ($t -split '[\s\-]')[0]
}

function Get-KioskTab {
    # Every PBI variant ("PBI - SR", "PBI - NO SCRIPT - ...") goes on the PBI
    # tab; anything that is neither PBI, Mach2 nor Web, a blank type
    # included, goes on Other rather than nowhere.
    param([string]$Type)
    switch (Get-ShortType $Type) {
        'Mach2' { return 'Mach2' }
        'PBI'   { return 'PBI' }
        'Web'   { return 'Web' }
        default { return 'Other' }
    }
}

# The tab a launcher's screens belong on.
$LauncherTab = @{ 'MACH2' = 'Mach2'; 'PBI' = 'PBI'; 'WEB' = 'Web' }

function Get-KioskScreens {
    <#
        A kiosk's screens, whatever runs on them: one object per screen
        folder (S1, S2, ...) with the launcher (MACH2, PBI, WEB), its state
        and the folder on the kiosk, from what the collector left in its
        status file. A screen with a config that has not reported yet has
        State NOT_RUN. Sorted by screen.
    #>
    param($Entry)

    $out = @{}
    foreach ($pair in @(@('MACH2', $Entry.Ng), @('PBI', $Entry.Pbi), @('WEB', $Entry.Web))) {
        $kind = $pair[0]; $l = $pair[1]
        if (-not $l) { continue }
        foreach ($i in @($l.Instances)) {
            if (-not $i) { continue }
            $screen = if ($i.PSObject.Properties['Screen'] -and $i.Screen) { [string]$i.Screen } elseif ($kind -eq 'MACH2') { [string]$i.Instance } else { 'S1' }
            $key = "$screen|$kind"
            if ($out.ContainsKey($key)) { continue }
            $out[$key] = [pscustomobject]@{
                Screen = $screen.ToUpperInvariant(); Launcher = $kind; Instance = [string]$i.Instance
                State = [string]$i.State; HostStatus = [string]$i.HostStatus; Detail = [string]$i.Detail
                Version = [string]$i.Version
                Folder = $(if ($i.PSObject.Properties['Folder'] -and $i.Folder) { [string]$i.Folder } else { '' })
                Watchdog = $(if ($i.PSObject.Properties['Watchdog']) { [bool]$i.Watchdog } else { $false })
                Source = $i
            }
        }
        if ($l.PSObject.Properties['Screens']) {
            foreach ($s in @($l.Screens | Where-Object { $_ })) {
                $key = "$([string]$s)|$kind"
                if ($out.ContainsKey($key)) { continue }
                $out[$key] = [pscustomobject]@{
                    Screen = ([string]$s).ToUpperInvariant(); Launcher = $kind; Instance = [string]$s
                    State = 'NOT_RUN'; HostStatus = 'LAUNCHER_NOT_RUN'; Detail = 'config written, no status yet'; Version = ''
                    Folder = ''; Watchdog = $false; Source = $null
                }
            }
        }
    }
    return @($out.Values | Sort-Object Screen, Launcher)
}

function Get-KioskTabs {
    # Every tab a kiosk belongs on: one per launcher it runs on any screen,
    # plus its list type's. A PBI kiosk with a Mach2 dashboard on S2 is on
    # both tabs. Nothing known about it: its type's tab, Other included.
    param([string]$Type, [array]$Screens)
    $tabs = New-Object System.Collections.Generic.List[string]
    $typeTab = Get-KioskTab $Type
    if ($typeTab -ne 'Other') { $tabs.Add($typeTab) }
    foreach ($s in @($Screens)) {
        $tab = $LauncherTab[[string]$s.Launcher]
        if ($tab -and -not $tabs.Contains($tab)) { $tabs.Add($tab) }
    }
    if ($tabs.Count -eq 0) { $tabs.Add($typeTab) }
    return @($tabs)
}

function Format-Minutes {
    # 7m, 5h, 3d
    param($Minutes)
    if ($null -eq $Minutes -or "$Minutes" -eq '') { return '' }
    $m = [double]$Minutes
    if ($m -lt 0) { $m = 0 }
    if ($m -lt 60) { return '{0}m' -f [int][math]::Floor($m) }
    if ($m -lt 2880) { return '{0}h' -f [int][math]::Floor($m / 60) }
    return '{0}d' -f [int][math]::Floor($m / 1440)
}

function ConvertFrom-FleetIsoTime {
    # The collector's UTC stamps ("2026-09-18T14:33:33Z") as a UTC DateTime,
    # or $null. Never throws: a half-written file must not stop a redraw.
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    $t = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, "yyyy-MM-dd'T'HH:mm:ss'Z'", $inv, $styles, [ref]$t)) { return $t }
    if ([datetime]::TryParse($Text, $inv, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { return $t.ToUniversalTime() }
    return $null
}

function Resolve-FleetEventsCsv {
    <#
        The CSV to read: the one next to the master kiosk list when that is
        synced here (the file Power BI reads), otherwise the local mirror.
    #>
    param([Parameter(Mandatory)][string]$ScriptDir, [string]$CsvPath)

    if ($CsvPath) { return $CsvPath }

    $listInfo = Resolve-KioskListPath -ScriptDir $ScriptDir
    if ($listInfo.Path -and $listInfo.IsMaster) {
        $candidate = Join-Path (Split-Path -Parent $listInfo.Path) 'MWST_FleetEvents.csv'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return (Join-Path $ScriptDir 'Logs\MWST_FleetEvents.csv')
}

function Read-FleetState {
    <#
        Everything a front end needs, in one pass over the CSV: the latest
        status per kiosk, reboot counts, a week of daily counts for the
        sparklines, and when the collector last ran.
    #>
    param([string]$Path)

    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    $state = [pscustomobject]@{
        Ok            = $false
        Error         = $null
        Hosts         = @()
        LastCollected = $null
        LastRun       = $null
        RowCount      = 0
        DayKeys       = @()
        Pbi           = @{}
        Ng            = @{}
        Web           = @{}
        Sidecar       = $null
        Path          = $Path
        ReadAt        = Get-Date
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        $state.Error = "No CSV yet at $Path - run the collector once."
        return $state
    }

    $rows = $null
    try {
        $text = Read-SharedText -Path $Path
        if ([string]::IsNullOrWhiteSpace($text)) { $state.Error = 'CSV is empty.'; return $state }
        $rows = @($text | ConvertFrom-Csv)
    }
    catch {
        $state.Error = "Could not read the CSV: $($_.Exception.Message)"
        return $state
    }

    $state.RowCount = $rows.Count

    # When the collector last ran, as opposed to when it last changed
    # anything. On a quiet fleet those are hours apart, and only the first one
    # answers "is this screen still being kept up to date".
    $sidecarPath = [System.IO.Path]::ChangeExtension($Path, '.status.json')
    if (Test-Path -LiteralPath $sidecarPath) {
        try {
            $sc = (Read-SharedText -Path $sidecarPath) | ConvertFrom-Json
            $state.Sidecar = $sc
            if ($sc -and $sc.LastRunUtc) { $state.LastRun = $sc.LastRunUtc }
            if ($sc -and $sc.PbiLaunchers) {
                foreach ($p in $sc.PbiLaunchers.PSObject.Properties) { $state.Pbi[$p.Name] = $p.Value }
            }
            if ($sc -and $sc.PSObject.Properties['Mach2Launchers'] -and $sc.Mach2Launchers) {
                foreach ($p in $sc.Mach2Launchers.PSObject.Properties) { $state.Ng[$p.Name] = $p.Value }
            }
            if ($sc -and $sc.PSObject.Properties['WebLaunchers'] -and $sc.WebLaunchers) {
                foreach ($p in $sc.WebLaunchers.PSObject.Properties) { $state.Web[$p.Name] = $p.Value }
            }
        }
        catch { }
    }

    # Seven day buckets, oldest first, for the sparklines.
    $today = (Get-Date).Date
    $dayKeys = @()
    for ($d = 6; $d -ge 0; $d--) { $dayKeys += $today.AddDays(-$d).ToString('yyyy-MM-dd', $inv) }
    $state.DayKeys = $dayKeys

    $cutoff24 = (Get-Date).AddHours(-24)
    $byHost = @{}

    foreach ($r in $rows) {
        if ($r.EventType -eq 'COLLECTOR_RUN') {
            if (-not $state.LastCollected -or [string]::CompareOrdinal($r.EventTimeUtc, $state.LastCollected) -gt 0) {
                $state.LastCollected = $r.EventTimeUtc
            }
            continue
        }

        $h = $r.Host
        if (-not $h) { continue }

        if (-not $byHost.ContainsKey($h)) {
            $byHost[$h] = [pscustomobject]@{
                Host = $h; Location = ''; Type = ''; Tab = ''; Tabs = @(); Status = 'UNKNOWN'
                StatusRow = $null; Reboots24 = 0; Script24 = 0; Episodes24 = 0
                HasWatchdog = $false; Days = @{}; Pbi = $null; Ng = $null; Web = $null; Screens = @()
            }
        }
        $entry = $byHost[$h]

        if ($r.EventType -eq 'HOST_STATUS') {
            # Only kiosks that run the watchdog get a WatchdogRunning value;
            # for a Power BI screen the column is empty.
            if ($r.WatchdogRunning) { $entry.HasWatchdog = $true }
            if (-not $entry.StatusRow -or [string]::CompareOrdinal($r.EventTimeUtc, $entry.StatusRow.EventTimeUtc) -gt 0) {
                $entry.StatusRow = $r
                $entry.Status    = if ($r.Outcome) { $r.Outcome } else { 'UNKNOWN' }
            }
        }

        if ($r.Location) { $entry.Location = $r.Location }
        if ($r.KioskType) { $entry.Type = $r.KioskType }

        if ($r.IsCanonicalReboot -eq 'TRUE') {
            if ($r.EventDate) {
                if (-not $entry.Days.ContainsKey($r.EventDate)) { $entry.Days[$r.EventDate] = 0 }
                $entry.Days[$r.EventDate]++
            }
            $when = $null
            try { $when = [datetime]::ParseExact($r.EventTimeLocal, "yyyy-MM-dd'T'HH:mm:ss", $inv) } catch { }
            if ($when -and $when -ge $cutoff24) {
                $entry.Reboots24++
                if ($r.IsScriptReboot -eq 'TRUE') { $entry.Script24++ }
            }
        }

        if ($r.EventType -eq 'WHITE_EPISODE_START' -or $r.EventType -eq 'LOWWHITE_EPISODE_START') {
            $when = $null
            try { $when = [datetime]::ParseExact($r.EventTimeLocal, "yyyy-MM-dd'T'HH:mm:ss", $inv) } catch { }
            if ($when -and $when -ge $cutoff24) { $entry.Episodes24++ }
        }
    }

    # Only once every row is in: the type can arrive on any of them.
    foreach ($entry in $byHost.Values) {
        if ($state.Pbi.ContainsKey($entry.Host)) { $entry.Pbi = $state.Pbi[$entry.Host] }
        if ($state.Ng.ContainsKey($entry.Host)) { $entry.Ng = $state.Ng[$entry.Host] }
        if ($state.Web.ContainsKey($entry.Host)) { $entry.Web = $state.Web[$entry.Host] }
        $entry.Screens = @(Get-KioskScreens -Entry $entry)
        $entry.Tabs = @(Get-KioskTabs -Type $entry.Type -Screens $entry.Screens)
        # The tab it opens on: its type's, or - for a type that says nothing
        # (Other) - the first launcher it runs.
        $entry.Tab = Get-KioskTab $entry.Type
        if ($entry.Tab -eq 'Other' -and $entry.Tabs[0] -ne 'Other') { $entry.Tab = $entry.Tabs[0] }
    }

    # Trouble first, then the kiosks that actually run a watchdog - they are
    # the ones with a story to tell, and burying them under twenty ping-only
    # Power BI screens is how you end up scrolling to find the one that
    # matters (or having it cut off the bottom of the screen).
    $state.Hosts = @($byHost.Values | Sort-Object `
        @{ Expression = { if ($StatusRank.ContainsKey($_.Status)) { $StatusRank[$_.Status] } else { 8 } } }, `
        @{ Expression = { if ($_.HasWatchdog) { 0 } else { 1 } } }, `
        @{ Expression = { $_.Location } }, `
        @{ Expression = { $_.Host } })
    $state.Ok = $true
    return $state
}

function Get-FleetFreshness {
    <#
        How old the data on screen is, and whether that is a problem in
        itself: a dead collector must never look like a healthy fleet.
    #>
    param($State, [int]$StaleMinutes = 45)

    $out = [pscustomobject]@{ Text = 'collector has never run'; Stale = $true; Minutes = $null; LastRun = $null }
    $stamp = if ($State -and $State.LastRun) { $State.LastRun } elseif ($State) { $State.LastCollected } else { $null }
    $lastUtc = ConvertFrom-FleetIsoTime $stamp
    if (-not $lastUtc) { return $out }

    $out.LastRun = $lastUtc.ToLocalTime()
    $mins = [int]((Get-Date).ToUniversalTime() - $lastUtc).TotalMinutes
    if ($mins -lt 0) { $mins = 0 }
    $out.Minutes = $mins
    if ($mins -lt $StaleMinutes) {
        $out.Stale = $false
        $out.Text = if ($mins -le 1) { 'collected just now' } else { "collected $mins min ago" }
    }
    elseif ($mins -lt 1440) { $out.Text = "STALE - collector last ran $([int]($mins / 60)) h ago" }
    else { $out.Text = "STALE - collector last ran $([int]($mins / 1440)) days ago" }
    return $out
}
