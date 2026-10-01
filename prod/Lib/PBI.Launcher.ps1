<#
.SYNOPSIS
    Reading PBI Launcher's state on a Power BI kiosk, over the admin share.

.DESCRIPTION
    Dot-sourced by the collector and the dashboard. Each launcher keeps
    Status\<instance>.status.json in its folder up to date (every few seconds
    while it runs); this turns those files into one host status in the
    collector's vocabulary, plus the details the dashboard shows.

    Host statuses for Power BI kiosks, worst first:

      LAUNCHER_STALE     status not written for -StaleMinutes: not running  CRITICAL
      LAUNCHER_STOPPED   stopped (kill.txt) - the screen is empty          CRITICAL
      LAUNCHER_ERROR     Edge will not start, or Power BI refuses the     CRITICAL
                         account (no license, 429 throttling)
      SIGNIN_BLOCKED     sign-in needs a person (password, MFA)           CRITICAL
      WRONG_ACCOUNT      Power BI signed in as someone else               CRITICAL
      RECOVERING         fixing an error or blank report                  WARNING
      NOT_SHOWING        loading or signing in for over 15 minutes        WARNING
      NO_DISPLAY         the configured screen is not connected           WARNING
      HOLD               paused with hold.txt                             WARNING
      UNSUPERVISED       only keeping Edge open                           WARNING
      LAUNCHER_DISABLED  DisableStartup is set                            WARNING
      LAUNCHER_NOT_RUN   installed, never started (no restart yet?)       WARNING
      OK                 showing the report, or someone is using a link

    A kiosk without PBI Launcher keeps the plain ping status it always had;
    the observation still says whether the old PowerBILauncher.exe is there,
    so a rollout can be followed.
#>

Set-StrictMode -Off

$PbiStateRank = @{
    'LAUNCHER_STALE' = 1; 'LAUNCHER_STOPPED' = 2; 'LAUNCHER_ERROR' = 3; 'SIGNIN_BLOCKED' = 4; 'WRONG_ACCOUNT' = 5
    'RECOVERING' = 20; 'NOT_SHOWING' = 21; 'NO_DISPLAY' = 22; 'HOLD' = 23; 'UNSUPERVISED' = 24
    'LAUNCHER_DISABLED' = 25; 'LAUNCHER_NOT_RUN' = 26; 'OK' = 99
}

# Parses an ISO time from a PBI/Web Launcher status file.
function ConvertFrom-PbiIsoTime {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = [datetime]::MinValue
    if ([datetime]::TryParse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) {
        return $t.ToUniversalTime()
    }
    return $null
}

# Turns one PBI/Web Launcher screen's status file into a kiosk status and severity.
function Get-PbiInstanceStatus {
    # One launcher instance's status file -> host status and severity.
    param([Parameter(Mandatory)]$Instance, [int]$StaleMinutes = 5, [int]$NotShowingMinutes = 15)

    $state = [string]$Instance.State
    switch ($state) {
        'STOPPED'  { return @('LAUNCHER_STOPPED', 'CRITICAL') }
        'DISABLED' { return @('LAUNCHER_DISABLED', 'WARNING') }
    }
    if ($null -eq $Instance.AgeMinutes -or $Instance.AgeMinutes -gt $StaleMinutes) { return @('LAUNCHER_STALE', 'CRITICAL') }
    switch ($state) {
        'ERROR'           { return @('LAUNCHER_ERROR', 'CRITICAL') }
        'SIGNIN_BLOCKED'  { return @('SIGNIN_BLOCKED', 'CRITICAL') }
        'RECOVERING'      { return @('RECOVERING', 'WARNING') }
        'WAITING_DISPLAY' { return @('NO_DISPLAY', 'WARNING') }
        'HOLD'            { return @('HOLD', 'WARNING') }
        'UNSUPERVISED'    { return @('UNSUPERVISED', 'WARNING') }
    }
    if ($Instance.UserName -and $Instance.SignedInAs -and $Instance.SignedInAs -ne $Instance.UserName) {
        return @('WRONG_ACCOUNT', 'CRITICAL')
    }
    if ($state -in @('LOADING', 'SIGNING_IN', 'STARTING', 'LAUNCHING') -and $null -ne $Instance.StateMinutes -and $Instance.StateMinutes -gt $NotShowingMinutes) {
        return @('NOT_SHOWING', 'WARNING')
    }
    return @('OK', 'INFO')
}

# Lists a launcher's screen folders (S1, S2, ...) on a kiosk.
function Get-LauncherScreenFolders {
    <#
        Where a launcher keeps its screens under C:\Users\Public\Documents\
        <Name>: one folder per screen (S1, S2, ...), and - for PBI Launcher
        before 2.0.1 - the launcher's own folder, which counts as S1. Each
        entry: Screen, Folder (relative to the kiosk's C:), Path (as given),
        HasConfig.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name, [string]$HostName)

    $rel = "Users\Public\Documents\$Name"
    $base = Join-Path $Root $rel
    $out = @()
    if (-not (Test-Path -LiteralPath $base)) { return $out }
    $hasConfig = {
        param($dir)
        if ($HostName -and (Test-Path -LiteralPath (Join-Path $dir "$HostName.json"))) { return $true }
        if (Test-Path -LiteralPath (Join-Path $dir 'config.json')) { return $true }
        return (@(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @('EXAMPLE.json', 'migration.json') -and $_.Name -notlike '*.status.json' }).Count -gt 0)
    }
    foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^S\d+$' } | Sort-Object Name)) {
        $out += [pscustomobject]@{ Screen = $d.Name.ToUpperInvariant(); Folder = "$rel\$($d.Name)"; Path = $d.FullName; HasConfig = [bool](& $hasConfig $d.FullName) }
    }
    # The layout from before the screen folders: config and Status\ next to
    # the script. It is the kiosk's first screen.
    if (@($out | Where-Object { $_.Screen -eq 'S1' -and $_.HasConfig }).Count -eq 0 -and
        ((Test-Path -LiteralPath (Join-Path $base 'Status')) -or ($HostName -and (Test-Path -LiteralPath (Join-Path $base "$HostName.json"))))) {
        $out = @([pscustomobject]@{ Screen = 'S1'; Folder = $rel; Path = $base; HasConfig = [bool]($HostName -and (Test-Path -LiteralPath (Join-Path $base "$HostName.json"))); Legacy = $true }) +
               @($out | Where-Object { $_.Screen -ne 'S1' })
    }
    return $out
}

# Reads everything about a kiosk's Web Launcher from its admin share.
function Get-WebLauncherObservation {
    # Web Launcher keeps the same status file as PBI Launcher, in its own
    # folder. See Get-PbiLauncherObservation.
    param([Parameter(Mandatory)][string]$Root, [datetime]$NowUtc = [datetime]::UtcNow, [int]$StaleMinutes = 5, [string]$HostName)
    return (Get-PbiLauncherObservation -Root $Root -NowUtc $NowUtc -StaleMinutes $StaleMinutes -HostName $HostName -Name 'WebLauncher')
}

# Reads everything about a kiosk's PBI (or Web) Launcher from its admin share.
function Get-PbiLauncherObservation {
    <#
        Everything knowable about a kiosk's PBI Launcher (or, with -Name
        WebLauncher, its Web Launcher) from its admin share. $Root is the
        kiosk's C: drive (\\HOST\C$); the caller has already authenticated
        the share. Never throws.
    #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [datetime]$NowUtc = [datetime]::UtcNow,
        [int]$StaleMinutes = 5,
        [string]$HostName,
        [ValidateSet('PbiLauncher', 'WebLauncher')][string]$Name = 'PbiLauncher'
    )

    $obs = [pscustomobject]@{
        Launcher        = $(if ($Name -eq 'WebLauncher') { 'WEB' } else { 'PBI' })
        Installed       = $false
        LegacyLauncher  = $false
        Screens         = @()        # screen folders with a config: S1, S2, ...
        Instances       = @()
        Status          = $null      # host status, or $null when the launcher is not installed
        Severity        = $null
        Summary         = ''         # one line for the collector's Detail column
        LauncherVersion = ''
        PcBootUtc       = $null
        Error           = ''
    }
    try {
        if ($Name -eq 'PbiLauncher') {
            foreach ($rel in @('Users\Public\Documents\Launchers', 'Users\Public\Documents\Mach2Launchers')) {
                $base = Join-Path $Root $rel
                if (-not (Test-Path -LiteralPath $base)) { continue }
                foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory -Filter 'Launcher S*' -ErrorAction SilentlyContinue)) {
                    if ((Test-Path -LiteralPath (Join-Path $d.FullName 'PowerBILauncher.exe')) -or
                        (Test-Path -LiteralPath (Join-Path $d.FullName 'PowerBILauncher\PowerBILauncher.exe'))) { $obs.LegacyLauncher = $true }
                }
            }
        }

        $folder = Join-Path $Root "Users\Public\Documents\$Name"
        $obs.Installed = Test-Path -LiteralPath (Join-Path $folder "$Name.ps1")
        $screenFolders = @(Get-LauncherScreenFolders -Root $Root -Name $Name -HostName $HostName)
        $obs.Screens = @($screenFolders | Where-Object { $_.HasConfig } | ForEach-Object { $_.Screen })
        $tag = if ($Name -eq 'WebLauncher') { 'web' } else { 'launcher' }
        if (-not $obs.Installed) {
            $obs.Summary = if ($obs.LegacyLauncher) { "$tag=old" } elseif ($obs.Screens.Count) { "$tag=config written, not installed" } else { "$tag=none" }
            return $obs
        }

        $files = @()
        $screenOf = @{}
        foreach ($sf in $screenFolders) {
            foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $sf.Path 'Status') -Filter '*.status.json' -File -ErrorAction SilentlyContinue)) {
                $files += $f
                $screenOf[$f.FullName] = $sf
            }
        }
        if ($files.Count -eq 0) {
            $obs.Status = 'LAUNCHER_NOT_RUN'
            $obs.Severity = 'WARNING'
            $obs.Summary = "$tag=installed, not started"
            return $obs
        }

        $worst = $null
        $instances = @()
        foreach ($f in $files) {
            $s = $null
            try { $s = ConvertFrom-Json -InputObject (Read-SharedText -Path $f.FullName) } catch { continue }
            $updated = ConvertFrom-PbiIsoTime ([string]$s.UpdatedUtc)
            $since = ConvertFrom-PbiIsoTime ([string]$s.StateSinceUtc)
            $sf = $screenOf[$f.FullName]
            $inst = [pscustomobject]@{
                Instance        = [string]$s.Instance
                Screen          = $sf.Screen
                Folder          = $sf.Folder
                Launcher        = $obs.Launcher
                State           = [string]$s.State
                Detail          = [string]$s.Detail
                UpdatedUtc      = $updated
                AgeMinutes      = $(if ($updated) { [math]::Round(($NowUtc - $updated).TotalMinutes, 1) } else { $null })
                StateMinutes    = $(if ($since) { [math]::Round(($NowUtc - $since).TotalMinutes, 1) } else { $null })
                LastShownUtc    = ConvertFrom-PbiIsoTime ([string]$s.LastShownUtc)
                LauncherVersion = [string]$s.LauncherVersion
                EdgeVersion     = ([string]$s.EdgeVersion) -replace '^Edg/', ''
                UserName        = $(if ($s.PSObject.Properties['UserName']) { [string]$s.UserName } else { '' })
                SignedInAs      = $(if ($s.PSObject.Properties['SignedInAs']) { [string]$s.SignedInAs } else { '' })
                SignIns         = $s.SignIns
                Reloads         = $s.Reloads
                BrowserStarts   = $s.BrowserStarts
                LastError       = [string]$s.LastError
                PcBootUtc       = $(if ($s.PSObject.Properties['PcBootUtc']) { ConvertFrom-PbiIsoTime ([string]$s.PcBootUtc) } else { $null })
                HostStatus      = ''
                Severity        = ''
            }
            $hs = Get-PbiInstanceStatus -Instance $inst -StaleMinutes $StaleMinutes
            $inst.HostStatus = $hs[0]
            $inst.Severity = $hs[1]
            $instances += $inst
            if (-not $worst -or $PbiStateRank[$inst.HostStatus] -lt $PbiStateRank[$worst.HostStatus]) { $worst = $inst }
        }
        if (-not $worst) {
            $obs.Status = 'LAUNCHER_NOT_RUN'
            $obs.Severity = 'WARNING'
            $obs.Summary = "$tag=status unreadable"
            return $obs
        }

        $obs.Instances = $instances
        $obs.Status = $worst.HostStatus
        $obs.Severity = $worst.Severity
        $obs.LauncherVersion = $worst.LauncherVersion
        $obs.PcBootUtc = $worst.PcBootUtc
        $obs.Summary = (@($instances | ForEach-Object {
                    $as = if ($_.SignedInAs) { " as=$($_.SignedInAs)" } else { '' }
                    '{0}={1}:{2}{3} age={4}m v{5}' -f $tag, $_.Screen, $_.State, $as, $_.AgeMinutes, $_.LauncherVersion
                }) -join '; ')
    }
    catch { $obs.Error = $_.Exception.Message }
    return $obs
}

# Shrinks a PBI/Web observation to the details kept in the collector's status file.
function ConvertTo-PbiSidecarEntry {
    # The per-kiosk details the dashboard shows, small enough to keep in the
    # collector's status file.
    param([Parameter(Mandatory)]$Observation)
    $iso = { param($t) if ($t) { $t.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) } else { '' } }
    return [pscustomobject]@{
        Launcher       = $Observation.Launcher
        Installed      = $Observation.Installed
        LegacyLauncher = $Observation.LegacyLauncher
        Screens        = @($Observation.Screens)
        Status         = $Observation.Status
        Error          = $Observation.Error
        Instances      = @($Observation.Instances | ForEach-Object {
                [pscustomobject]@{
                    Instance = $_.Instance; Screen = $_.Screen; Folder = $_.Folder; State = $_.State; Detail = $_.Detail; HostStatus = $_.HostStatus
                    UpdatedUtc = (& $iso $_.UpdatedUtc); StateMinutes = $_.StateMinutes; LastShownUtc = (& $iso $_.LastShownUtc)
                    Version = $_.LauncherVersion; Edge = $_.EdgeVersion; UserName = $_.UserName; SignedInAs = $_.SignedInAs
                    SignIns = $_.SignIns; Reloads = $_.Reloads; BrowserStarts = $_.BrowserStarts; LastError = $_.LastError
                }
            })
    }
}
