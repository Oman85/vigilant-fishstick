<#
.SYNOPSIS
    Reading Mach2 Launcher ver 1.00NG's state on a Mach2 kiosk, over the
    admin share.

.DESCRIPTION
    Dot-sourced by the collector and the status tool. Each launcher instance
    (one per screen: S1, S2, ...) keeps
    Mach2LauncherNG\<instance>\Status\<instance>.status.json up to date every
    few seconds; this turns those files into one host status in the
    collector's vocabulary.

    The launcher is also the kiosk's watchdog, and writes the watchdog's
    ledger and log as the MWST watchdog did, so the collector's watchdog
    statuses (STALE, LOOP_GUARD, ...) still come first. These only add what
    the watchdog files cannot say - that the screen shows a sign-in page
    that needs a person, for example:

      LAUNCHER_STALE     status not written for -StaleMinutes: not running  CRITICAL
      LAUNCHER_STOPPED   stopped (kill.txt) - the screen is empty          CRITICAL
      LAUNCHER_ERROR     Edge will not start                              CRITICAL
      SIGNIN_BLOCKED     the station sign-in needs a person               CRITICAL
      RECOVERING         fixing a white, dark or failing dashboard        WARNING
      NOT_SHOWING        loading or signing in for over 15 minutes        WARNING
      NO_DISPLAY         the configured screen is not connected           WARNING
      HOLD               paused with hold.txt                             WARNING
      UNSUPERVISED       only keeping Edge open                           WARNING
      LAUNCHER_DISABLED  DisableStartup is set                            WARNING
      LAUNCHER_NOT_RUN   installed, never started (no restart yet?)       WARNING
      OK                 the dashboard is on screen, or restarting the PC
#>

Set-StrictMode -Off

$M2NgFolderName = 'Mach2LauncherNG'
$M2NgStateRank = @{
    'LAUNCHER_STALE' = 1; 'LAUNCHER_STOPPED' = 2; 'LAUNCHER_ERROR' = 3; 'SIGNIN_BLOCKED' = 4
    'RECOVERING' = 20; 'NOT_SHOWING' = 21; 'NO_DISPLAY' = 22; 'HOLD' = 23; 'UNSUPERVISED' = 24
    'LAUNCHER_DISABLED' = 25; 'LAUNCHER_NOT_RUN' = 26; 'OK' = 99
}

# Parses an ISO time from a Mach2 Launcher NG status file.
function ConvertFrom-M2NgIsoTime {
    param([string]$Text)
    if (-not $Text) { return $null }
    $t = [datetime]::MinValue
    if ([datetime]::TryParse($Text, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) {
        return $t.ToUniversalTime()
    }
    return $null
}

# Tells whether a version string is a Mach2 Launcher NG version (e.g. 1.02NG).
function Test-Mach2NgVersion {
    # "1.00NG" and later: the watchdog is built into the launcher.
    param([string]$Version)
    return ([string]$Version).Trim() -match '^\d+\.\d+NG$'
}

# Turns one Mach2 NG screen's status file into a kiosk status and severity.
function Get-Mach2NgInstanceStatus {
    # One instance's status file -> host status and severity.
    param([Parameter(Mandatory)]$Instance, [int]$StaleMinutes = 5, [int]$NotShowingMinutes = 15)

    $state = [string]$Instance.State
    switch ($state) {
        'STOPPED' { return @('LAUNCHER_STOPPED', 'CRITICAL') }
        'DISABLED' { return @('LAUNCHER_DISABLED', 'WARNING') }
    }
    if ($null -eq $Instance.AgeMinutes -or $Instance.AgeMinutes -gt $StaleMinutes) { return @('LAUNCHER_STALE', 'CRITICAL') }
    switch ($state) {
        'ERROR' { return @('LAUNCHER_ERROR', 'CRITICAL') }
        'SIGNIN_BLOCKED' { return @('SIGNIN_BLOCKED', 'CRITICAL') }
        'RECOVERING' { return @('RECOVERING', 'WARNING') }
        'WAITING_DISPLAY' { return @('NO_DISPLAY', 'WARNING') }
        'HOLD' { return @('HOLD', 'WARNING') }
        'UNSUPERVISED' { return @('UNSUPERVISED', 'WARNING') }
    }
    if ($state -in @('LOADING', 'SIGNING_IN', 'STARTING', 'LAUNCHING') -and $null -ne $Instance.StateMinutes -and $Instance.StateMinutes -gt $NotShowingMinutes) {
        return @('NOT_SHOWING', 'WARNING')
    }
    return @('OK', 'INFO')
}

# Reads everything about a kiosk's Mach2 Launcher NG from its admin share.
function Get-Mach2NgObservation {
    <#
        Everything knowable about a kiosk's Mach2 Launcher NG from its admin
        share. $Folder is the kiosk's Public Documents (where the watchdog's
        files are); the caller has already authenticated the share. Never
        throws.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [datetime]$NowUtc = [datetime]::UtcNow,
        [int]$StaleMinutes = 5
    )

    $obs = [pscustomobject]@{
        Launcher        = 'MACH2'
        Installed       = $false
        OldLauncher     = $false
        Screens         = @()        # screen folders with a config: S1, S2, ...
        Instances       = @()
        Status          = $null      # host status, or $null when NG is not installed
        Severity        = $null
        Summary         = ''
        LauncherVersion = ''
        PcBootUtc       = $null
        Error           = ''
    }
    try {
        $old = Join-Path $Folder 'Mach2Launchers'
        if (Test-Path -LiteralPath $old) {
            $obs.OldLauncher = @(Get-ChildItem -LiteralPath $old -Directory -Filter 'Launcher S*' -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Mach2Launcher.exe') }).Count -gt 0
        }
        $root = Join-Path $Folder $M2NgFolderName
        $obs.Installed = Test-Path -LiteralPath (Join-Path $root 'Mach2LauncherNG.ps1')
        $obs.Screens = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match '^S\d+$' -and @(Get-ChildItem -LiteralPath $_.FullName -Filter '*.json' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'EXAMPLE.json' }).Count -gt 0
            } | Sort-Object Name | ForEach-Object { $_.Name.ToUpperInvariant() })
        if (-not $obs.Installed) {
            $obs.Summary = if ($obs.OldLauncher) { 'launcher=old' } else { '' }
            return $obs
        }

        $files = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                Get-ChildItem -LiteralPath (Join-Path $_.FullName 'Status') -Filter '*.status.json' -File -ErrorAction SilentlyContinue
            })
        if ($files.Count -eq 0) {
            $obs.Status = 'LAUNCHER_NOT_RUN'
            $obs.Severity = 'WARNING'
            $obs.Summary = 'launcher=NG installed, not started'
            return $obs
        }

        $worst = $null
        $instances = @()
        foreach ($f in $files) {
            $s = $null
            try { $s = ConvertFrom-Json -InputObject (Read-SharedText -Path $f.FullName) } catch { continue }
            $updated = ConvertFrom-M2NgIsoTime ([string]$s.UpdatedUtc)
            $since = ConvertFrom-M2NgIsoTime ([string]$s.StateSinceUtc)
            $inst = [pscustomobject]@{
                Instance           = [string]$s.Instance
                Screen             = $f.Directory.Parent.Name.ToUpperInvariant()
                Folder             = ('Users\Public\Documents\{0}\{1}' -f $M2NgFolderName, $f.Directory.Parent.Name)
                Launcher           = 'MACH2'
                State              = [string]$s.State
                Detail             = [string]$s.Detail
                UpdatedUtc         = $updated
                AgeMinutes         = $(if ($updated) { [math]::Round(($NowUtc - $updated).TotalMinutes, 1) } else { $null })
                StateMinutes       = $(if ($since) { [math]::Round(($NowUtc - $since).TotalMinutes, 1) } else { $null })
                LastShownUtc       = ConvertFrom-M2NgIsoTime ([string]$s.LastShownUtc)
                LauncherVersion    = [string]$s.LauncherVersion
                EdgeVersion        = ([string]$s.EdgeVersion) -replace '^Edg/', ''
                Watchdog           = [bool]$s.Watchdog
                LoopGuard          = [string]$s.LoopGuard
                PageWhitePercent   = $s.PageWhitePercent
                ScreenWhitePercent = $s.ScreenWhitePercent
                SignIns            = $s.SignIns
                Reloads            = $s.Reloads
                BrowserStarts      = $s.BrowserStarts
                PcRestarts         = $s.PcRestarts
                LastError          = [string]$s.LastError
                PcBootUtc          = $(if ($s.PSObject.Properties['PcBootUtc']) { ConvertFrom-M2NgIsoTime ([string]$s.PcBootUtc) } else { $null })
                HostStatus         = ''
                Severity           = ''
            }
            $hs = Get-Mach2NgInstanceStatus -Instance $inst -StaleMinutes $StaleMinutes
            $inst.HostStatus = $hs[0]
            $inst.Severity = $hs[1]
            $instances += $inst
            if (-not $worst -or $M2NgStateRank[$inst.HostStatus] -lt $M2NgStateRank[$worst.HostStatus]) { $worst = $inst }
        }
        if (-not $worst) {
            $obs.Status = 'LAUNCHER_NOT_RUN'
            $obs.Severity = 'WARNING'
            $obs.Summary = 'launcher=NG status unreadable'
            return $obs
        }

        $obs.Instances = $instances
        $obs.Status = $worst.HostStatus
        $obs.Severity = $worst.Severity
        $obs.LauncherVersion = $worst.LauncherVersion
        $obs.PcBootUtc = $worst.PcBootUtc
        $obs.Summary = (@($instances | Sort-Object Instance | ForEach-Object {
                    $w = if ($null -ne $_.ScreenWhitePercent) { " screen=$($_.ScreenWhitePercent)%" } elseif ($null -ne $_.PageWhitePercent) { " page=$($_.PageWhitePercent)%" } else { '' }
                    'launcher={0}:{1}{2} age={3}m v{4}' -f $_.Instance, $_.State, $w, $_.AgeMinutes, $_.LauncherVersion
                }) -join '; ')
    }
    catch { $obs.Error = $_.Exception.Message }
    return $obs
}

# Shrinks a Mach2 NG observation to the details kept in the collector's status file.
function ConvertTo-Mach2NgSidecarEntry {
    # The per-kiosk details a dashboard can show, small enough for the
    # collector's status file.
    param([Parameter(Mandatory)]$Observation)
    $iso = { param($t) if ($t) { $t.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) } else { '' } }
    return [pscustomobject]@{
        Launcher    = 'MACH2'
        Installed   = $Observation.Installed
        OldLauncher = $Observation.OldLauncher
        Screens     = @($Observation.Screens)
        Status      = $Observation.Status
        Error       = $Observation.Error
        Instances   = @($Observation.Instances | ForEach-Object {
                [pscustomobject]@{
                    Instance = $_.Instance; Screen = $_.Screen; Folder = $_.Folder; State = $_.State; Detail = $_.Detail; HostStatus = $_.HostStatus
                    UpdatedUtc = (& $iso $_.UpdatedUtc); StateMinutes = $_.StateMinutes; LastShownUtc = (& $iso $_.LastShownUtc)
                    Version = $_.LauncherVersion; Edge = $_.EdgeVersion; Watchdog = $_.Watchdog; LoopGuard = $_.LoopGuard
                    PageWhitePercent = $_.PageWhitePercent; ScreenWhitePercent = $_.ScreenWhitePercent
                    SignIns = $_.SignIns; Reloads = $_.Reloads; BrowserStarts = $_.BrowserStarts; PcRestarts = $_.PcRestarts; LastError = $_.LastError
                }
            })
    }
}
