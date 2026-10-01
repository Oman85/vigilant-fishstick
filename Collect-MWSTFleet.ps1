#Requires -Version 5.1
<#
.SYNOPSIS
    MWST Fleet V6.1 collector: gathers watchdog events from every kiosk into
    one CSV for Power BI. Also reads PBI Launcher's status on Power BI kiosks.

.DESCRIPTION
    One run is one scan of the fleet. For every kiosk on the list it:

      - checks the kiosk is reachable (ping, falling back to SMB on 445)
      - reads the watchdog's event ledger (mwst_events*.csv) over the admin share
      - checks how recently mwst.log was written, to tell whether the watchdog
        is still alive
      - takes the kiosk's Windows System log records for:
          1074  a process asked for a restart or shutdown (the watchdog's own
                reboots are tagged MWST-WATCHDOG in the comment; the previous
                agent's comment text is recognised too)
          6008  the previous shutdown was unexpected (power loss, hard hang)
          6005  the machine booted

        These arrive through the ledger: remote event log access is closed on
        this network, so each kiosk reads its own System log and copies the
        records in verbatim. -RemoteEventLog reads them across the network
        instead, where the firewall permits it. Both routes are classified by
        the same code and produce the same rows with the same EventIds, so
        either one, or both at once, gives the same answer.

    and merges everything into a single CSV: a long fact table with one row
    per event. Every row has a stable EventId, so reading the same ledger or
    event log again on the next scan never duplicates anything.

    WHY NO REBOOT IS MISSED
    A reboot triggered by the watchdog has up to three independent witnesses:
    the ledger row the agent flushes to disk before calling shutdown.exe, the
    1074 event Windows writes when shutdown.exe runs, and the agent's
    RESTART_CONFIRMED row once the machine is back. Any one of them is enough
    for the reboot to be counted, and when several agree it is counted once.

    On top of that, every boot (6005) has to be explained by some reboot
    record. A boot that is not explained is counted in its own right, as
    UNEXPLAINED - so even a reboot that left no other trace still shows up.

    The other direction matters as much: one boot is one reboot, however many
    records describe it. A restart from the Start menu alone makes Windows
    log two 1074s (Explorer asks, winlogon executes), and a feature update
    logs a burst of them. Update-RebootFlags gives each boot exactly one row.

    COUNTING REBOOTS IN POWER BI
      IsScriptReboot    = TRUE   exactly one row per reboot the watchdog caused
      IsCanonicalReboot = TRUE   exactly one row per reboot, whatever the cause
    Count rows with one of these flags. Do not count EventType rows directly:
    a single reboot legitimately produces several of them.

    THE CSV IS A CACHE OF DURABLE SOURCES
    The file is rewritten in full on each run that has something new to add
    (atomically, via a temp file and File.Replace). Because everything in it
    is re-derivable from the kiosks' ledgers and event logs, a failed write, a
    locked file or a missed scan loses nothing - the next successful run
    picks it all up again. Two copies are kept: the published one (next to
    the SharePoint kiosk list by default) and a local one in Logs\. Each run
    reads both and merges them, so if either is lost the other restores it.

    WHAT IS LEFT OUT
    A kiosk's records only count from the moment it started running the
    current agent (see -TrustedFromAgentVersion). Everything it reports from
    before that is dropped, because the previous watchdog is not a reliable
    witness to its own behaviour - on one kiosk it rebooted 174 times in a
    single day, which would swamp every count in the report. The cutoff is
    per kiosk, taken from its own first AGENT_START, so kiosks upgraded later
    clean themselves up as they go.

    Only rows within -ReconcileDays have their reboot flags recomputed.
    Older rows keep the flags they were written with, so historical counts do
    not drift as retention trims the edges of the data.

.PARAMETER KioskList
    .xlsx, .csv or .txt kiosk list. Default: the SharePoint master found via
    OneDrive sync, falling back to a copy next to this script.

.PARAMETER SheetName
    Worksheet to read. Default: every worksheet, merged by hostname.

.PARAMETER IncludeAllHosts
    Scan every row of the list, not just HAS MWST = Y rows plus Power BI kiosks.

.PARAMETER OutputCsv
    The published CSV. Default: MWST_FleetEvents.csv in the same folder as the
    SharePoint master list, so it syncs to SharePoint alongside it. If the
    master is not synced on this machine, Logs\MWST_FleetEvents.csv.

.PARAMETER AgentPathTemplate
    Folder holding the watchdog's files on each kiosk. {0} is the host name.

.PARAMETER EventLookbackDays
    How far back to read each kiosk's System log. 7 is plenty for a 15-minute
    schedule; use a large value once, on the first run, to backfill history.
    Extended automatically after a gap - the collector not having run for a
    while, or a kiosk's event log having been unreadable - so that a gap never
    turns into a hole in the data.

.PARAMETER StaleMinutes
    If mwst.log has not been written for longer than this, the watchdog is
    considered dead. The agent logs a heartbeat about every 3.5 minutes.

.PARAMETER KioskRootTemplate
    Each kiosk's C: drive over the admin share. {0} is the host name. Power
    BI kiosks are read here for PBI Launcher's status files.

.PARAMETER PbiStaleMinutes
    A PBI Launcher status file older than this means the launcher is not
    running (it rewrites the file every few seconds).

.PARAMETER RetentionDays
    Rows older than this are dropped from the CSV.

.PARAMETER RunRowRetentionDays
    COLLECTOR_RUN rows are kept for this many days only.

.PARAMETER ReconcileDays
    Reboot flags are recomputed for rows newer than this.

.PARAMETER KeepaliveHours
    A HOST_STATUS row is written when a host's status changes, and at least
    this often even if it does not, so a quiet host is distinguishable from
    one that is no longer being scanned.

.PARAMETER HeartbeatMinutes
    When nothing else has changed, the CSV is still rewritten this often with
    a COLLECTOR_RUN row, so Power BI can show when data was last collected.
    Each rewrite of a file in SharePoint creates a new version of it, which
    is why this is not done on every run.

.PARAMETER PingTimeoutMs
    Per-attempt timeout for the reachability check.

.PARAMETER EventLogAllHosts
    With -RemoteEventLog, also read the System log of kiosks that do not run
    the watchdog (Power BI kiosks). Off by default to keep scans fast.

.PARAMETER RemoteEventLog
    Read each kiosk's System log across the network as well. Off by default:
    the RPC this needs is closed by the zero-trust policy, and every blocked
    host would cost the scan a long timeout. The kiosks' own agents copy
    these records into their ledgers instead. Turning it on cannot duplicate
    anything - a record collected either way has the same EventId. These
    reads are made one host after another, so a scan with this on is as slow
    as scans used to be.

.PARAMETER ParallelHosts
    How many kiosks are read at the same time. Almost all of a scan is spent
    waiting for kiosks to answer, so this is what decides how long it takes:
    8 kiosks at a time turns an eleven-minute scan into about ninety seconds.
    1 reads them one after another, as the collector used to.

.PARAMETER HostTimeoutSeconds
    A kiosk that has not finished being read after this long is given up on.
    It is recorded with what was read before the deadline and the scan carries
    on. One unresponsive kiosk used to be able to hold up everything behind
    it.

.PARAMETER TrustedFromAgentVersion
    Data is only trusted from the moment a kiosk started running this agent
    version. Each kiosk's own cutoff is its first AGENT_START at or above it;
    anything it reports from before that is dropped. The previous watchdog
    could reboot a kiosk every couple of minutes, so its history would skew
    every count in the report.

.PARAMETER KeepPreUpgradeHistory
    Keep those older rows instead. Use it if you want to look back at how a
    kiosk behaved before it was upgraded.

.PARAMETER Credential
    Alternate credential for the kiosks' admin share and event log.

.PARAMETER CredentialFile
    A credential saved with Save-KioskCredential.ps1. Used for unattended runs.

.PARAMETER DryRun
    Scan and report, but write nothing.

.PARAMETER ProgressFile
    Also record how far through the scan this run is in a small JSON file,
    for a caller that runs the scan hidden and cannot see Write-Progress
    (the dashboard's auto-scan).

.EXAMPLE
    .\Collect-MWSTFleet.ps1

.EXAMPLE
    .\Collect-MWSTFleet.ps1 -EventLookbackDays 365
    First run: backfill every reboot still held in the kiosks' System logs.

.EXAMPLE
    .\Collect-MWSTFleet.ps1 -Credential (Get-Credential) -DryRun
#>

[CmdletBinding()]
param(
    [string]$KioskList,
    [string]$SheetName,
    [switch]$IncludeAllHosts,
    [string]$OutputCsv,
    [string]$AgentPathTemplate = '\\{0}\C$\Users\Public\Documents',
    [ValidateRange(1, 3650)][int]$EventLookbackDays = 7,
    [ValidateRange(1, 1440)][int]$StaleMinutes = 10,
    [string]$KioskRootTemplate = '\\{0}\C$',
    [ValidateRange(1, 1440)][int]$PbiStaleMinutes = 5,
    [ValidateRange(30, 3650)][int]$RetentionDays = 400,
    [ValidateRange(1, 3650)][int]$RunRowRetentionDays = 30,
    [ValidateRange(1, 3650)][int]$ReconcileDays = 30,
    [ValidateRange(1, 720)][int]$KeepaliveHours = 24,
    [ValidateRange(1, 1440)][int]$HeartbeatMinutes = 60,
    [ValidateRange(100, 10000)][int]$PingTimeoutMs = 1500,
    [switch]$EventLogAllHosts,
    [switch]$RemoteEventLog,
    [ValidateRange(1, 32)][int]$ParallelHosts = 8,
    [ValidateRange(15, 900)][int]$HostTimeoutSeconds = 180,
    [string]$TrustedFromAgentVersion = '6.1',
    [switch]$KeepPreUpgradeHistory,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredentialFile,
    [switch]$DryRun,
    [string]$ProgressFile
)

Set-StrictMode -Off
$CollectorVersion = '6.2'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'Lib\MWST.KioskList.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.Remote.ps1')
. (Join-Path $ScriptDir 'Lib\PBI.Launcher.ps1')
. (Join-Path $ScriptDir 'Lib\M2.LauncherNG.ps1')

$Inv          = [System.Globalization.CultureInfo]::InvariantCulture
$LogDir       = Join-Path $ScriptDir 'Logs'
$CollectorLog = Join-Path $LogDir 'collector.log'
$OutputName   = 'MWST_FleetEvents.csv'
$LocalCsv     = Join-Path $LogDir $OutputName

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

# The CSV layout. Every row, from every source, has exactly these columns in
# exactly this order - Power BI binds to column names and types, so the
# layout only ever grows at the end, never changes in the middle.
$Columns = @(
    'EventId', 'EventTimeUtc', 'EventTimeLocal', 'EventDate',
    'Host', 'Location', 'KioskType', 'RestartGroup',
    'EventCategory', 'EventType', 'Severity', 'Outcome',
    'IsCanonicalReboot', 'IsScriptReboot', 'RebootTrigger',
    'WhitePercent', 'StreakChecks', 'DurationSeconds',
    'Reachable', 'WatchdogRunning', 'MinutesSinceLastLog',
    'AgentVersion', 'BootTimeUtc', 'UptimeHours',
    'Source', 'ScanId', 'CollectedUtc', 'Detail'
)
$ColumnSet = @{}
foreach ($c in $Columns) { $ColumnSet[$c] = $true }

$CategoryByType = @{
    'RESTART_TRIGGERED'      = 'REBOOT'
    'RESTART_CONFIRMED'      = 'REBOOT'
    'RESTART_FAILED'         = 'REBOOT'
    'REBOOT_SCRIPT'          = 'REBOOT'
    'REBOOT_EXTERNAL'        = 'REBOOT'
    'REBOOT_UNEXPECTED'      = 'REBOOT'
    'BOOT'                   = 'REBOOT'
    'WHITE_EPISODE_START'    = 'SCREEN'
    'WHITE_EPISODE_END'      = 'SCREEN'
    'LOWWHITE_EPISODE_START' = 'SCREEN'
    'LOWWHITE_EPISODE_END'   = 'SCREEN'
    'AGENT_START'            = 'AGENT'
    'AGENT_STOP'             = 'AGENT'
    'AGENT_ERROR'            = 'AGENT'
    'AGENT_RECOVERED'        = 'AGENT'
    'LOOP_GUARD_ENGAGED'     = 'AGENT'
    'LOOP_GUARD_RELEASED'    = 'AGENT'
    'MESSAGE_SHOWN'          = 'AGENT'
    'MESSAGE_CLOSED'         = 'AGENT'
    'MESSAGE_EXPIRED'        = 'AGENT'
    'MESSAGE_REJECTED'       = 'AGENT'
    'HOST_STATUS'            = 'STATUS'
    'COLLECTOR_RUN'          = 'COLLECTOR'
}


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-CollectorLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    try {
        if ((Test-Path -LiteralPath $CollectorLog) -and ((Get-Item -LiteralPath $CollectorLog).Length -ge 5MB)) {
            $previous = "$CollectorLog.1"
            Remove-Item -LiteralPath $previous -Force -ErrorAction SilentlyContinue
            Rename-Item -LiteralPath $CollectorLog -NewName (Split-Path $previous -Leaf) -ErrorAction SilentlyContinue
        }
        [System.IO.File]::AppendAllText($CollectorLog, $line + [Environment]::NewLine)
    }
    catch {}

    switch ($Level) {
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'ERROR' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}

function Write-ScanProgress {
    <#
        Write-Progress goes nowhere when the scan runs hidden with its output
        redirected, so with -ProgressFile the position is also dropped into a
        file the dashboard polls. The PID lets it tell this run's file from a
        previous run's. Best effort: progress must never fail a scan.
    #>
    param([string]$Phase, [int]$Index, [int]$Total, [string]$HostName)

    if (-not $ProgressFile) { return }
    try {
        $json = [pscustomobject]@{ Pid = $PID; Phase = $Phase; Index = $Index; Total = $Total; Host = $HostName } |
                ConvertTo-Json -Compress
        [System.IO.File]::WriteAllText($ProgressFile, $json)
    }
    catch { }
}


# ---------------------------------------------------------------------------
# Value formatting
#
# Everything is written culture-invariant: ISO 8601 timestamps, "." as the
# decimal separator, TRUE/FALSE for booleans, and an empty string for
# "not applicable". The Power Query in Reports\ imports with en-US culture so
# a Czech-locale report reads these correctly.
# ---------------------------------------------------------------------------
function Format-UtcIso {
    param([datetime]$Value)
    return $Value.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv)
}

function Format-LocalIso {
    param([datetime]$Value)
    return $Value.ToLocalTime().ToString("yyyy-MM-dd'T'HH:mm:ss", $Inv)
}

function ConvertFrom-UtcIso {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text.Trim(), "yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv, $styles, [ref]$parsed)) { return $parsed }
    if ([datetime]::TryParse($Text.Trim(), $Inv, $styles, [ref]$parsed)) { return $parsed }
    return $null
}

function Format-Number {
    param($Value, [int]$Decimals = 2)

    if ($null -eq $Value) { return '' }
    $d = 0.0
    if ($Value -is [string]) {
        if ($Value.Trim() -eq '') { return '' }
        if (-not [double]::TryParse($Value.Trim(), [System.Globalization.NumberStyles]::Float, $Inv, [ref]$d)) { return '' }
    }
    else {
        try { $d = [double]$Value } catch { return '' }
    }
    return [math]::Round($d, $Decimals).ToString($Inv)
}

function Format-Bool {
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value) { return 'TRUE' }
    return 'FALSE'
}

function Test-TrustedAgentVersion {
    # Is this the agent version whose data we trust? "legacy", blank, or
    # anything older than -TrustedFromAgentVersion is not.
    param([string]$Version)

    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    # Mach2 Launcher ver 1.00NG and later carry the watchdog built in.
    if (Test-Mach2NgVersion $Version) { return $true }
    $v = $null
    if (-not [version]::TryParse($Version.Trim(), [ref]$v)) { return $false }
    $min = $null
    if (-not [version]::TryParse($TrustedFromAgentVersion.Trim(), [ref]$min)) { return $true }
    return ($v -ge $min)
}

function Get-UpgradeCutoffs {
    <#
        The moment each kiosk started running a trusted agent: the earliest
        AGENT_START it ever reported at that version. Rows older than a
        kiosk's cutoff are dropped. A kiosk with no such row - a Power BI
        screen, or one not upgraded yet - has no cutoff, and keeps what
        little it reports (the collector's own status rows).
    #>
    param($Rows)

    $cutoffs = @{}
    foreach ($r in $Rows) {
        if ($r.EventType -ne 'AGENT_START' -or -not $r.Host) { continue }
        if (-not (Test-TrustedAgentVersion $r.AgentVersion)) { continue }
        if (-not $cutoffs.ContainsKey($r.Host) -or [string]::CompareOrdinal($r.EventTimeUtc, $cutoffs[$r.Host]) -lt 0) {
            $cutoffs[$r.Host] = $r.EventTimeUtc
        }
    }
    return $cutoffs
}

function New-FleetRow {
    <#
        The only way a row is created. Fills every column (empty when not
        given), derives the category and the local-time columns, and refuses
        unknown column names so a typo fails loudly instead of silently
        producing an empty column.
    #>
    param([Parameter(Mandatory)][hashtable]$Values)

    $row = [ordered]@{}
    foreach ($c in $Columns) { $row[$c] = '' }

    foreach ($k in $Values.Keys) {
        if (-not $row.Contains($k)) { throw "New-FleetRow: unknown column '$k'" }
        $v = $Values[$k]
        $row[$k] = if ($null -eq $v) { '' } else { [string]$v }
    }

    if (-not $row['EventCategory'] -and $CategoryByType.ContainsKey($row['EventType'])) {
        $row['EventCategory'] = $CategoryByType[$row['EventType']]
    }
    if (-not $row['IsCanonicalReboot']) { $row['IsCanonicalReboot'] = 'FALSE' }
    if (-not $row['IsScriptReboot'])    { $row['IsScriptReboot']    = 'FALSE' }

    # Local time is always derived from UTC on this machine rather than taken
    # from the source, so every row agrees on DST and time zone.
    $t = ConvertFrom-UtcIso $row['EventTimeUtc']
    if ($t) {
        $row['EventTimeLocal'] = Format-LocalIso $t
        $row['EventDate']      = $t.ToLocalTime().ToString('yyyy-MM-dd', $Inv)
    }

    # One physical line per row. Quoted newlines are legal CSV, but they are
    # also the first thing to break a hand-rolled parser downstream.
    $detail = ($row['Detail'] -replace '[\r\n\t]+', ' ').Trim()
    if ($detail.Length -gt 1000) { $detail = $detail.Substring(0, 1000) }
    $row['Detail'] = $detail

    return [pscustomobject]$row
}


# ---------------------------------------------------------------------------
# Reading and writing the fleet CSV
# ---------------------------------------------------------------------------
function Read-FleetCsv {
    <#
        Returns .Exists, .Error and .Rows. A file that exists but cannot be
        read, or does not look like one of ours, comes back with .Error set -
        and the caller must then leave it alone rather than overwrite it with
        a version that is missing its history. The classic way to get here is
        someone opening the CSV in Excel and saving it: in a Czech locale that
        rewrites it with semicolons and local dates.
    #>
    param([string]$Path)

    $result = [pscustomobject]@{
        Exists = $false
        Error  = $null
        Rows   = New-Object System.Collections.Generic.List[object]
    }

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $result }
    $result.Exists = $true

    try {
        $text = Read-SharedText -Path $Path
        if ([string]::IsNullOrWhiteSpace($text)) { return $result }

        $firstLine = ($text -split "`r?`n", 2)[0]
        $header = @($firstLine.Split(',') | ForEach-Object { $_.Trim().Trim('"') })

        if (($header -notcontains 'EventId') -or ($header -notcontains 'EventTimeUtc') -or ($header -notcontains 'EventType')) {
            $result.Error = "Unrecognised layout (first line: '$($firstLine.Substring(0, [math]::Min(80, $firstLine.Length)))'). Was it saved from Excel?"
            return $result
        }

        $sameLayout = (($header -join ',') -ceq ($Columns -join ','))

        foreach ($r in @($text | ConvertFrom-Csv)) {
            if ([string]::IsNullOrWhiteSpace($r.EventId)) { continue }

            if ($sameLayout) {
                $result.Rows.Add($r)
            }
            else {
                # Written by an older or newer layout: carry across the columns
                # we know and let New-FleetRow fill in the rest.
                $values = @{}
                foreach ($p in $r.PSObject.Properties) {
                    if ($ColumnSet.ContainsKey($p.Name)) { $values[$p.Name] = $p.Value }
                }
                $result.Rows.Add((New-FleetRow -Values $values))
            }
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Write-FleetCsv {
    <#
        Writes to a temp file in the destination folder, then swaps it in with
        File.Replace. Readers - Power BI, OneDrive's uploader - see either the
        old file or the new one, never half of one. Retries cover the file
        being briefly held by OneDrive or an open Power BI refresh.
    #>
    param([Parameter(Mandatory)]$Rows, [Parameter(Mandatory)][string]$Path)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { throw "Folder does not exist: $dir" }

    $tmp = Join-Path $dir ('~{0}.{1}.tmp' -f [System.IO.Path]::GetFileNameWithoutExtension($Path), [guid]::NewGuid().ToString('N').Substring(0, 8))

    try {
        # Export-Csv in Windows PowerShell 5.1 quotes every field and, with
        # -Encoding UTF8, writes a BOM - both of which Power Query and Excel
        # handle without being told anything.
        $Rows | Select-Object -Property $Columns | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8

        $lastError = $null
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            try {
                if (Test-Path -LiteralPath $Path) {
                    [System.IO.File]::Replace($tmp, $Path, [NullString]::Value)
                }
                else {
                    [System.IO.File]::Move($tmp, $Path)
                }
                return
            }
            catch {
                $lastError = $_.Exception.Message
                Start-Sleep -Seconds ([math]::Min(2 * $attempt, 10))
            }
        }

        # Some sync clients refuse ReplaceFile outright. An in-place overwrite
        # is not atomic, but it is better than not publishing at all.
        try {
            Copy-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
            return
        }
        catch {
            throw "Could not replace '$Path': $lastError / $($_.Exception.Message)"
        }
    }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}


# ---------------------------------------------------------------------------
# Agent ledger
# ---------------------------------------------------------------------------
function Write-StatusSidecar {
    <#
        A few hundred bytes next to the CSV recording when the collector last
        RAN, which is a different fact from when the data last CHANGED - and
        the CSV can only tell you the second one.

        Without this, a quiet fleet looks dead. The CSV is only rewritten when
        something changed, or hourly for the heartbeat, so anything reading it
        for freshness reports an hour-old "last collected" while the collector
        is in fact running every fifteen minutes. Writing this on every run
        keeps that signal honest without churning the big file.
    #>
    param([Parameter(Mandatory)][string]$CsvPath, [Parameter(Mandatory)][hashtable]$Values)

    $path = [System.IO.Path]::ChangeExtension($CsvPath, '.status.json')
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { return }

    $json = ([pscustomobject]$Values | ConvertTo-Json -Compress -Depth 8)
    $tmp = Join-Path $dir ('~status.{0}.tmp' -f [guid]::NewGuid().ToString('N').Substring(0, 8))

    try {
        [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($true)))
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                if (Test-Path -LiteralPath $path) { [System.IO.File]::Replace($tmp, $path, [NullString]::Value) }
                else { [System.IO.File]::Move($tmp, $path) }
                return
            }
            catch { Start-Sleep -Milliseconds (200 * $attempt) }
        }
    }
    catch { }
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function ConvertFrom-LedgerWinEvent {
    <#
        A Windows System-log record that the kiosk's own agent copied into its
        ledger, because remote event log access is closed on this network.

        The agent copies records verbatim and interprets nothing. Rebuilding
        the record here and handing it to ConvertFrom-RebootEvent means a
        reboot is classified by exactly the same code whether its record came
        over the network or through the ledger - one place to get it right,
        and the same EventId either way, so both routes cannot double-count.
    #>
    param($Row, [string]$HostName, [string]$ScanId, [string]$CollectedUtc)

    $payload = $null
    try { $payload = [string]$Row.Detail | ConvertFrom-Json } catch { return $null }
    if (-not $payload -or -not $payload.Id) { return $null }

    $t = ConvertFrom-UtcIso ([string]$Row.EventTimeUtc)
    if (-not $t) { return $null }

    $props = @()
    if ($null -ne $payload.Props) { $props = @($payload.Props | ForEach-Object { [pscustomobject]@{ Value = $_ } }) }

    $record = [pscustomobject]@{
        Id           = [int]$payload.Id
        ProviderName = [string]$payload.Provider
        RecordId     = $payload.RecordId
        TimeCreated  = $t
        Properties   = $props
        Message      = [string]$payload.Msg
    }

    return ConvertFrom-RebootEvent -Record $record -HostName $HostName -ScanId $ScanId -CollectedUtc $CollectedUtc
}

function ConvertFrom-LedgerRow {
    param($Row, [string]$HostName, [string]$ScanId, [string]$CollectedUtc)

    if ((([string]$Row.EventType).Trim().ToUpperInvariant()) -eq 'WINEVENT') {
        return ConvertFrom-LedgerWinEvent -Row $Row -HostName $HostName -ScanId $ScanId -CollectedUtc $CollectedUtc
    }

    $id = [string]$Row.EventId
    if ($id -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') { return $null }

    $t = ConvertFrom-UtcIso ([string]$Row.EventTimeUtc)
    if (-not $t) { return $null }

    $type = ([string]$Row.EventType).Trim().ToUpperInvariant()
    if (-not $type) { return $null }

    $detail  = [string]$Row.Detail
    $trigger = ''
    if ($type -eq 'RESTART_TRIGGERED' -or $type -eq 'RESTART_CONFIRMED' -or $type -eq 'RESTART_FAILED') {
        $trigger = if ($detail -match '^(?:Kind=)?(LOWWHITE|WHITE|BROWSER)\b') { 'WATCHDOG_' + $Matches[1].ToUpperInvariant() } else { 'WATCHDOG' }
    }

    $boot = ConvertFrom-UtcIso ([string]$Row.BootTimeUtc)

    return New-FleetRow -Values @{
        EventId         = $id.ToLowerInvariant()
        EventTimeUtc    = (Format-UtcIso $t)
        Host            = $HostName
        EventType       = $type
        Severity        = ([string]$Row.Severity).Trim().ToUpperInvariant()
        Outcome         = ([string]$Row.Outcome).Trim().ToUpperInvariant()
        RebootTrigger   = $trigger
        WhitePercent    = (Format-Number $Row.WhitePercent 2)
        StreakChecks    = (Format-Number $Row.StreakChecks 0)
        DurationSeconds = (Format-Number $Row.DurationSeconds 0)
        AgentVersion    = ([string]$Row.AgentVersion).Trim()
        BootTimeUtc     = $(if ($boot) { Format-UtcIso $boot } else { '' })
        Source          = 'Agent'
        ScanId          = $ScanId
        CollectedUtc    = $CollectedUtc
        Detail          = $detail
    }
}


# ---------------------------------------------------------------------------
# Windows System log
# ---------------------------------------------------------------------------
function Get-RebootEvents {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][datetime]$SinceUtc,
        [System.Management.Automation.PSCredential]$Credential
    )

    $params = @{
        ComputerName    = $HostName
        FilterHashtable = @{ LogName = 'System'; Id = @(1074, 6005, 6008); StartTime = $SinceUtc.ToLocalTime() }
        ErrorAction     = 'Stop'
    }
    if ($Credential) { $params['Credential'] = $Credential }

    try {
        return [pscustomobject]@{ Ok = $true; Records = @(Get-WinEvent @params); Error = $null }
    }
    catch {
        # "No events found" is an error to Get-WinEvent but a perfectly good
        # answer to us. The error id is language-independent; the message is
        # not, and kiosks may not all be English builds.
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            return [pscustomobject]@{ Ok = $true; Records = @(); Error = $null }
        }
        return [pscustomobject]@{ Ok = $false; Records = @(); Error = $_.Exception.Message }
    }
}

function ConvertFrom-RebootEvent {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)][string]$HostName,
        [string]$ScanId,
        [string]$CollectedUtc
    )

    $utc = $Record.TimeCreated.ToUniversalTime()

    # RecordId is unique within a log; the timestamp is added so that a log
    # cleared and restarted from RecordId 1 still cannot collide with history.
    $values = @{
        EventId      = ('EVT-{0}-{1}-{2}' -f $HostName, $Record.RecordId, $utc.ToString('yyyyMMddHHmmss', $Inv))
        EventTimeUtc = (Format-UtcIso $utc)
        Host         = $HostName
        Source       = 'EventLog'
        ScanId       = $ScanId
        CollectedUtc = $CollectedUtc
    }

    $props = @($Record.Properties | ForEach-Object { [string]$_.Value })

    if ($Record.Id -eq 1074 -and $Record.ProviderName -eq 'User32') {
        # "The process %1 has initiated the %5 of computer %2 on behalf of
        #  user %7 for the following reason: %3 ... Comment: %6"
        $process = if ($props.Count -gt 0) { $props[0] } else { '' }
        $reason  = if ($props.Count -gt 2) { $props[2] } else { '' }
        $kindTxt = if ($props.Count -gt 4) { $props[4] } else { '' }
        $comment = if ($props.Count -gt 5) { $props[5] } else { '' }
        $user    = if ($props.Count -gt 6) { $props[6] } else { '' }

        # Searched across every property rather than just %6, so a different
        # property order on some Windows build cannot hide our tag.
        $all = $props -join ' | '
        $kind = $null
        $token = $null
        if ($all -match 'MWST-WATCHDOG\s+(LOWWHITE|WHITE|BROWSER)\b(?:\s+id=([0-9a-fA-F]{8}))?') {
            $kind = $Matches[1].ToUpperInvariant()
            if ($Matches[2]) { $token = $Matches[2].ToLowerInvariant() }
        }
        elseif ($all -match 'KPI screen has been below') { $kind = 'LOWWHITE' }   # previous agent
        elseif ($all -match 'KPI screen has been white') { $kind = 'WHITE' }      # previous agent

        $detail = 'Process={0}; User={1}; Type={2}; Reason={3}; Comment={4}' -f $process, $user, $kindTxt, $reason, $comment

        if ($kind) {
            $values['EventType']     = 'REBOOT_SCRIPT'
            $values['Severity']      = 'CRITICAL'
            $values['Outcome']       = 'REBOOT'
            $values['RebootTrigger'] = 'WATCHDOG_' + $kind
            $values['Detail']        = $(if ($token) { "id=$token; $detail" } else { "legacy-agent; $detail" })
        }
        else {
            $values['EventType']     = 'REBOOT_EXTERNAL'
            $values['Severity']      = 'WARNING'
            $values['Outcome']       = 'REBOOT'
            $values['RebootTrigger'] = 'EXTERNAL'
            $values['Detail']        = $detail
        }
    }
    elseif ($Record.Id -eq 6008 -and $Record.ProviderName -eq 'EventLog') {
        $msg = if ($Record.Message) { $Record.Message } else { 'Previous shutdown was unexpected. ' + ($props -join ' ') }
        $values['EventType']     = 'REBOOT_UNEXPECTED'
        $values['Severity']      = 'CRITICAL'
        $values['Outcome']       = 'UNEXPECTED'
        $values['RebootTrigger'] = 'UNEXPECTED'
        $values['Detail']        = $msg
    }
    elseif ($Record.Id -eq 6005 -and $Record.ProviderName -eq 'EventLog') {
        $values['EventType'] = 'BOOT'
        $values['Severity']  = 'INFO'
        $values['Outcome']   = 'BOOT'
        $values['Detail']    = 'System booted (event log service started).'
    }
    else {
        return $null
    }

    return New-FleetRow -Values $values
}


# ---------------------------------------------------------------------------
# Reboot reconciliation
# ---------------------------------------------------------------------------
function Get-IdToken {
    param([string]$Text)
    if ($Text -match '\bid=([0-9a-fA-F]{8})\b') { return $Matches[1].ToLowerInvariant() }
    return $null
}

function Update-RebootFlags {
    <#
        Decides, per host, which row is THE row for each physical reboot.

        The unit is the boot interval: between two consecutive boots (6005)
        there was exactly one shutdown, however many records describe it.
        Windows alone writes two 1074s for one restart from the Start menu
        (Explorer asks, winlogon executes), and a feature update writes a
        burst of them. So each event-log record is assigned to the boot it
        led to, and within one interval exactly one wins:

          REBOOT_SCRIPT      first choice - the watchdog's shutdown.exe call
                             as logged by Windows. Out of the running if the
                             agent later reported that reboot as failed.
          REBOOT_EXTERNAL    next - update, operator, or other process.
          REBOOT_UNEXPECTED  last - power loss or hard hang. A 6008 is
                             written just after the boot that follows the
                             failure, so it belongs to the interval ending at
                             that boot.
        Ties go to the latest record.

        Agent rows are handled on their own:

          RESTART_TRIGGERED  counts only when no REBOOT_SCRIPT corroborates it
                             (event log unreadable, or already rolled over).
                             Matched by the id= token; by time only for the
                             previous agent, which had no token. Triggers are
                             never merged with one another - the agent only
                             asks again after its first request has failed.
          RESTART_CONFIRMED  never counts; it corroborates.
          RESTART_FAILED     never counts; no reboot happened.

        And the safety net:

          BOOT               counts, as UNEXPLAINED, when nothing explains
                             it - provided the previous boot is in the data
                             too. Without that, the interval began before our
                             history does, and "unexplained" would be a guess.

        Returns the number of field changes, so the caller knows whether the
        file needs rewriting.
    #>
    param(
        [Parameter(Mandatory)]$Rows,
        [Parameter(Mandatory)][datetime]$RecomputeFromUtc,
        [Parameter(Mandatory)]$NewIds
    )

    $changed = 0
    $byHost = @{}

    foreach ($r in $Rows) {
        if ($r.EventCategory -ne 'REBOOT' -or -not $r.Host) { continue }
        $t = ConvertFrom-UtcIso $r.EventTimeUtc
        if (-not $t) { continue }
        if (-not $byHost.ContainsKey($r.Host)) { $byHost[$r.Host] = New-Object System.Collections.Generic.List[object] }
        $byHost[$r.Host].Add([pscustomobject]@{ Row = $r; Time = $t })
    }

    foreach ($hostKey in @($byHost.Keys)) {
        $items = @($byHost[$hostKey] | Sort-Object Time)

        # Triggers the agent later reported as never having taken effect.
        $failedTriggers = @{}
        foreach ($it in $items) {
            if ($it.Row.EventType -eq 'RESTART_FAILED' -and $it.Row.Detail -match 'TriggerEventId=([0-9a-fA-F-]{36})') {
                $failedTriggers[$Matches[1].ToLowerInvariant()] = $true
            }
        }

        # --- Event-log records: one winner per boot interval ---
        $priority       = @{ 'REBOOT_SCRIPT' = 1; 'REBOOT_EXTERNAL' = 2; 'REBOOT_UNEXPECTED' = 3 }
        $boots          = @($items | Where-Object { $_.Row.EventType -eq 'BOOT' } | ForEach-Object { $_.Time })
        $decision       = @{}   # EventId -> canonical
        $winners        = @{}   # interval key -> item
        $explainedBoots = @{}   # interval key -> $true

        foreach ($it in $items) {
            $type = $it.Row.EventType
            if (-not $priority.ContainsKey($type)) { continue }

            if ($type -eq 'REBOOT_SCRIPT') {
                $token = Get-IdToken $it.Row.Detail
                $wasFailed = $false
                if ($token) {
                    foreach ($fid in $failedTriggers.Keys) { if ($fid.StartsWith($token)) { $wasFailed = $true } }
                }
                if ($wasFailed) { $decision[$it.Row.EventId] = $false; continue }
            }

            # Interval key: the boot this record led to ('open' if that boot
            # has not happened yet, or the machine is still off).
            $key = $null
            if ($type -eq 'REBOOT_UNEXPECTED') {
                # The boot this record was written during: the nearest one,
                # within half an hour - usually the very same second. Taking
                # "the latest boot in a window" instead goes wrong when the
                # machine restarts again a minute later, which is exactly what
                # happens after a power loss with an update pending.
                $t0 = $it.Time
                $b = @($boots | Where-Object { [math]::Abs(($_ - $t0).TotalMinutes) -le 30 } |
                       Sort-Object { [math]::Abs(($_ - $t0).TotalSeconds) }) | Select-Object -First 1
                if ($b) { $key = 'b' + $b.Ticks }
            }
            if (-not $key) {
                $t0 = $it.Time
                $b = @($boots | Where-Object { $_ -gt $t0 }) | Select-Object -First 1
                $key = if ($b) { 'b' + $b.Ticks } else { 'open' }
            }

            $explainedBoots[$key] = $true
            $decision[$it.Row.EventId] = $false

            $cur = $winners[$key]
            if (-not $cur -or
                $priority[$type] -lt $priority[$cur.Row.EventType] -or
                ($priority[$type] -eq $priority[$cur.Row.EventType] -and $it.Time -ge $cur.Time)) {
                $winners[$key] = $it
            }
        }
        foreach ($w in $winners.Values) { $decision[$w.Row.EventId] = $true }

        $scriptEvents = @($items | Where-Object { $_.Row.EventType -eq 'REBOOT_SCRIPT' })
        $prevBoot = $null

        foreach ($it in $items) {
            $r = $it.Row
            $recompute = ($it.Time -ge $RecomputeFromUtc) -or $NewIds.Contains($r.EventId) -or [string]::IsNullOrEmpty($r.IsCanonicalReboot)

            if ($recompute) {
                $type      = $r.EventType
                $trigger   = $r.RebootTrigger
                $canonical = $false

                if ($decision.ContainsKey($r.EventId)) {
                    $canonical = $decision[$r.EventId]
                }
                elseif ($type -eq 'RESTART_TRIGGERED') {
                    $id = $r.EventId.ToLowerInvariant()
                    if ($failedTriggers.ContainsKey($id)) {
                        $canonical = $false
                    }
                    else {
                        $corroborated = $false
                        foreach ($s in $scriptEvents) {
                            $token = Get-IdToken $s.Row.Detail
                            if ($token) {
                                if ($id.StartsWith($token)) { $corroborated = $true; break }
                            }
                            elseif ([math]::Abs(($s.Time - $it.Time).TotalMinutes) -le 15) {
                                $corroborated = $true; break
                            }
                        }
                        $canonical = -not $corroborated
                    }
                }
                elseif ($type -eq 'BOOT') {
                    # Explained by any event-log record assigned to this boot,
                    # or by a watchdog request since the previous boot.
                    $explained = $explainedBoots.ContainsKey('b' + $it.Time.Ticks)
                    if (-not $explained) {
                        foreach ($x in $items) {
                            if ($x.Row.EventType -ne 'RESTART_TRIGGERED') { continue }
                            if ($failedTriggers.ContainsKey($x.Row.EventId.ToLowerInvariant())) { continue }
                            if ($x.Time -le $it.Time -and (-not $prevBoot -or $x.Time -gt $prevBoot)) { $explained = $true; break }
                        }
                    }

                    $canonical = (-not $explained) -and ($null -ne $prevBoot)
                    $trigger   = if ($canonical) { 'UNEXPLAINED' } else { '' }
                }

                $canonText  = if ($canonical) { 'TRUE' } else { 'FALSE' }
                $scriptText = if ($canonical -and $trigger -like 'WATCHDOG*') { 'TRUE' } else { 'FALSE' }

                if ($r.IsCanonicalReboot -cne $canonText) { $r.IsCanonicalReboot = $canonText; $changed++ }
                if ($r.IsScriptReboot -cne $scriptText)   { $r.IsScriptReboot = $scriptText;   $changed++ }
                if ($r.RebootTrigger -cne $trigger)       { $r.RebootTrigger = $trigger;       $changed++ }
            }

            if ($r.EventType -eq 'BOOT') { $prevBoot = $it.Time }
        }
    }

    return $changed
}


# ---------------------------------------------------------------------------
# Host status
# ---------------------------------------------------------------------------
function Get-HostStatus {
    <#
        One status per host per scan, worst condition first:

          OFFLINE               no ping and no SMB                   CRITICAL
          NO_ACCESS             reachable, admin share not readable  WARNING
          NO_AGENT              watchdog expected, no trace of it    CRITICAL
          STALE                 mwst.log not written recently        CRITICAL
          LOOP_GUARD            running, but has stopped restarting  CRITICAL
                                a screen that restarts did not fix
          AGENT_OUTDATED        running, but no ledger (old agent)   WARNING
          EVENTLOG_UNAVAILABLE  fine, but one reboot witness missing WARNING
          OK

        Power BI kiosks with PBI Launcher get the launcher's own statuses
        instead (see Lib\PBI.Launcher.ps1); without it they stay ping-only.
        Mach2 kiosks on Mach2 Launcher ver 1.00NG get its statuses after the
        watchdog's (see Lib\M2.LauncherNG.ps1).
    #>
    param($Kiosk, $Obs)

    if (-not $Obs.Reachable) { return [pscustomobject]@{ Status = 'OFFLINE'; Severity = 'CRITICAL' } }

    # A kiosk's screens can run different launchers (PBI on S1, Mach2 on
    # S2, a web page on S3). Each says how its screen is; the kiosk is its
    # worst screen. They share one vocabulary (Lib\PBI.Launcher.ps1).
    $launchers = @(@($Obs.Pbi, $Obs.Web, $Obs.Ng) | Where-Object { $_ -and $_.Status })
    $worst = $null
    foreach ($l in $launchers) {
        $rank = if ($PbiStateRank.ContainsKey([string]$l.Status)) { $PbiStateRank[[string]$l.Status] } else { 50 }
        if (-not $worst -or $rank -lt $worst.Rank) { $worst = [pscustomobject]@{ Status = $l.Status; Severity = $l.Severity; Rank = $rank } }
    }

    if ($Kiosk.RunsWatchdog -or $Obs.WatchdogFound) {
        if ($Obs.ShareOk -ne $true)                      { return [pscustomobject]@{ Status = 'NO_ACCESS';      Severity = 'WARNING' } }
        if (-not $Obs.LogFound -and -not $Obs.LedgerFound) { return [pscustomobject]@{ Status = 'NO_AGENT';     Severity = 'CRITICAL' } }
        if ($null -eq $Obs.LogAgeMinutes -or $Obs.LogAgeMinutes -gt $StaleMinutes) {
            return [pscustomobject]@{ Status = 'STALE'; Severity = 'CRITICAL' }
        }
        # After STALE: a hold only means something while the watchdog that
        # declared it is still running. Its log is fresh, so without this the
        # kiosk would read OK while its screen stays broken.
        if ($Obs.LoopGuard)                              { return [pscustomobject]@{ Status = 'LOOP_GUARD';     Severity = 'CRITICAL' } }
        # Mach2 Launcher NG is the watchdog as well: what the launchers add
        # is what the watchdog's files cannot say, such as a sign-in that
        # needs a person (see Lib\M2.LauncherNG.ps1).
        if ($worst -and $worst.Status -ne 'OK')          { return [pscustomobject]@{ Status = $worst.Status;   Severity = $worst.Severity } }
        if (-not $Obs.LedgerFound)                       { return [pscustomobject]@{ Status = 'AGENT_OUTDATED'; Severity = 'WARNING' } }
    }
    elseif ($Obs.IsPbi -or $Obs.IsWeb -or $launchers.Count) {
        if ($Obs.ShareOk -eq $false) { return [pscustomobject]@{ Status = 'NO_ACCESS'; Severity = 'WARNING' } }
        if ($worst) { return [pscustomobject]@{ Status = $worst.Status; Severity = $worst.Severity } }
    }

    if ($Obs.EventLogOk -eq $false) { return [pscustomobject]@{ Status = 'EVENTLOG_UNAVAILABLE'; Severity = 'WARNING' } }

    return [pscustomobject]@{ Status = 'OK'; Severity = 'INFO' }
}

function Get-StatusSignature {
    # What counts as "the status changed". Deliberately excludes values that
    # move on every scan (log age, uptime), or every row would be a change.
    # Whether the event log was readable is included, because it decides how
    # far back later scans have to read.
    param($Row)
    $eventLog = if ($Row.Detail -match 'eventlog=(ok|FAIL)') { $Matches[1] } else { '' }
    return '{0}|{1}|{2}|{3}|{4}|{5}' -f $Row.Outcome, $Row.Reachable, $Row.WatchdogRunning, $Row.AgentVersion, $Row.BootTimeUtc, $eventLog
}

function Test-StatusRowNeeded {
    # A status row is written when something about the kiosk changed, and
    # otherwise once a day so that silence is never ambiguous.
    param($Row, $Previous, [datetime]$NowUtc, [int]$Keepalive)

    if (-not $Previous) { return $true }
    $prevTime = ConvertFrom-UtcIso $Previous.EventTimeUtc
    $fresh = $prevTime -and (($NowUtc - $prevTime).TotalHours -lt $Keepalive)
    return -not ($fresh -and ((Get-StatusSignature $Previous) -ceq (Get-StatusSignature $Row)))
}

function Get-EventLogGapStart {
    <#
        For one host's status rows: when did the current run of scans that
        could not read its event log begin? $null if the latest scan read it.
        Status rows are written on change plus a daily keepalive, so the run
        is walked back through every consecutive failing row - the keepalives
        must not make an old gap look recent.
    #>
    param($StatusRows)

    $start = $null
    foreach ($r in @($StatusRows | Sort-Object EventTimeUtc -Descending)) {
        if ($r.Reachable -eq 'FALSE' -or $r.Detail -match 'eventlog=FAIL') { $start = $r.EventTimeUtc }
        else { break }
    }
    if ($start) { return ConvertFrom-UtcIso $start }
    return $null
}


# ---------------------------------------------------------------------------
# Reading the kiosks
# ---------------------------------------------------------------------------
function Invoke-KioskFetch {
    <#
        Everything that has to be read off the kiosks, several kiosks at once.

        Nearly all of a scan is waiting for a kiosk's admin share to open:
        milliseconds on most of them, twenty seconds on a handful, and one
        kiosk at a time that came to eleven minutes for forty-two kiosks.
        Reading them together costs nothing extra - the collector is idle
        either way - and the scan then takes about as long as its slowest
        kiosk.

        Only reading happens here. What the rows mean - conversion, the
        upgrade cutoff, dedupe, the status row - stays in the scan loop, in
        kiosk-list order, so the published file never depends on which kiosk
        answered first.

        Each worker publishes its result object before it starts and fills it
        in as it goes. A kiosk that has to be given up on therefore still
        reports how far it got, instead of coming back as nothing at all.
    #>
    param(
        [Parameter(Mandatory)]$Kiosks,
        [Parameter(Mandatory)][string]$ScriptDir,
        [Parameter(Mandatory)][string]$AgentPathTemplate,
        [Parameter(Mandatory)][string]$KioskRootTemplate,
        [Parameter(Mandatory)][datetime]$NowUtc,
        [System.Management.Automation.PSCredential]$Credential,
        [int]$PingTimeoutMs = 1500,
        [int]$PbiStaleMinutes = 5,
        [int]$Parallel = 8,
        [int]$TimeoutSeconds = 180
    )

    # A worker has only the libraries to work from: a runspace does not
    # inherit this script's functions.
    $worker = {
        param($Ctx)

        $f = $Ctx.Result
        # Set on entry, not on submission: with more kiosks than workers, a
        # kiosk waits its turn, and that wait is neither its own slowness nor
        # a reason to give up on it.
        $f.StartedUtc = [DateTime]::UtcNow
        try {
            . (Join-Path $Ctx.ScriptDir 'Lib\MWST.Remote.ps1')
            . (Join-Path $Ctx.ScriptDir 'Lib\PBI.Launcher.ps1')
            . (Join-Path $Ctx.ScriptDir 'Lib\M2.LauncherNG.ps1')

            $h = $Ctx.HostName
            $reach = Test-HostReachable -HostName $h -TimeoutMs $Ctx.PingTimeoutMs
            $f.Reachable = $reach.Ok
            $f.Method    = $reach.Method
            if (-not $reach.Ok) { [void]$f.Notes.Add($reach.Error) }

            # --- Launchers and the watchdog, over the admin share ---
            # Any screen can run any launcher - Power BI on S1 and the Mach2
            # dashboard on S2 - so all three are looked for on every kiosk,
            # whatever its type in the list. One session for all of it.
            if ($f.Reachable) {
                $root = $Ctx.KioskRootTemplate -f $h
                $folder = $Ctx.AgentPathTemplate -f $h
                $drive = $null
                try {
                    $drive = Connect-KioskShare -Folder "$root\Users" -Credential $Ctx.Credential
                    $f.PbiShareOk = [bool](Test-Path -LiteralPath "$root\Users")
                    if ($f.PbiShareOk) {
                        $f.Pbi = Get-PbiLauncherObservation -Root $root -NowUtc $Ctx.NowUtc -StaleMinutes $Ctx.PbiStaleMinutes -HostName $h
                        if ($f.Pbi.Error) { [void]$f.Notes.Add("PBI Launcher: $($f.Pbi.Error)") }
                        $f.Web = Get-WebLauncherObservation -Root $root -NowUtc $Ctx.NowUtc -StaleMinutes $Ctx.PbiStaleMinutes -HostName $h
                        if ($f.Web.Error) { [void]$f.Notes.Add("Web Launcher: $($f.Web.Error)") }
                    }
                    elseif ($Ctx.IsPbi -or $Ctx.IsWeb) { [void]$f.Notes.Add("Cannot open $root") }

                    # Mach2 Launcher NG, where it is installed. It is the
                    # watchdog as well, so its ledger is read even on a
                    # kiosk the list calls Power BI.
                    if (Test-Path -LiteralPath $folder) {
                        $f.Ng = Get-Mach2NgObservation -Folder $folder -NowUtc $Ctx.NowUtc -StaleMinutes $Ctx.PbiStaleMinutes
                        if ($f.Ng.Error) { [void]$f.Notes.Add("Launcher: $($f.Ng.Error)") }
                    }

                    if ($Ctx.RunsWatchdog -or ($f.Ng -and $f.Ng.Installed)) {
                        $f.ShareOk = [bool](Test-Path -LiteralPath $folder)
                        if (-not $f.ShareOk) {
                            [void]$f.Notes.Add("Cannot open $folder")
                        }
                        else {
                            $logFile = Join-Path $folder 'mwst.log'
                            if (Test-Path -LiteralPath $logFile) {
                                $f.LogFound = $true
                                $f.LogAgeMinutes = ($Ctx.NowUtc - (Get-Item -LiteralPath $logFile).LastWriteTimeUtc).TotalMinutes
                            }
                            else {
                                $f.LogFound = $false
                            }

                            $f.Ledger = Read-AgentLedger -Folder $folder
                            foreach ($e in $f.Ledger.Errors) { [void]$f.Notes.Add($e) }
                        }
                    }
                }
                catch {
                    $f.ShareOk = $false
                    $f.PbiShareOk = $false
                    [void]$f.Notes.Add("Share: $($_.Exception.Message)")
                }
                finally {
                    Disconnect-KioskShare -Drive $drive
                }
            }
        }
        catch { $f.Fatal = $_.Exception.Message }
        finally { $f.Seconds = [Math]::Round(([DateTime]::UtcNow - $f.StartedUtc).TotalSeconds, 1) }
    }

    $results = [hashtable]::Synchronized(@{})
    $pool = [runspacefactory]::CreateRunspacePool(1, [Math]::Max(1, $Parallel))
    $pool.Open()
    $jobs = New-Object System.Collections.Generic.List[object]

    try {
        foreach ($k in $Kiosks) {
            $h = $k.Host.ToUpperInvariant()
            $result = [pscustomobject]@{
                Host          = $h
                Reachable     = $false
                Method        = $null
                ShareOk       = $null
                LogFound      = $null
                LogAgeMinutes = $null
                Ledger        = $null
                Ng            = $null
                Pbi           = $null
                Web           = $null
                PbiShareOk    = $null
                Notes         = (New-Object System.Collections.Generic.List[string])
                Fatal         = $null
                TimedOut      = $false
                StartedUtc    = $null
                Seconds       = 0
            }
            $results[$h] = $result

            $ctx = @{
                HostName          = $h
                Result            = $result
                ScriptDir         = $ScriptDir
                RunsWatchdog      = [bool]$k.RunsWatchdog
                IsPbi             = [bool](Test-IsPowerBiKiosk -Type $k.Type)
                IsWeb             = [bool](Test-IsWebKiosk -Type $k.Type)
                AgentPathTemplate = $AgentPathTemplate
                KioskRootTemplate = $KioskRootTemplate
                Credential        = $Credential
                NowUtc            = $NowUtc
                PingTimeoutMs     = $PingTimeoutMs
                PbiStaleMinutes   = $PbiStaleMinutes
            }

            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($worker.ToString()).AddArgument($ctx)
            $jobs.Add([pscustomobject]@{
                Host = $h; Ps = $ps; Handle = $ps.BeginInvoke(); Result = $result
                Finished = $false; Abandoned = $false
            })
        }

        # If every worker were to hang at once, nothing would ever reach its
        # own deadline because nothing else would ever start. This is the
        # longest the queue could honestly take, and the scan stops waiting.
        $hardStop = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds * ([Math]::Ceiling($jobs.Count / [double][Math]::Max(1, $Parallel)) + 1))

        $done = 0
        while ($done -lt $jobs.Count) {
            Start-Sleep -Milliseconds 150
            $outOfTime = ([DateTime]::UtcNow -gt $hardStop)
            foreach ($j in $jobs) {
                if ($j.Finished) { continue }
                # A kiosk still queued has no deadline yet; it has not been
                # given the chance to answer.
                $late = ($null -ne $j.Result.StartedUtc -and ([DateTime]::UtcNow - $j.Result.StartedUtc).TotalSeconds -gt $TimeoutSeconds)
                if (-not $j.Handle.IsCompleted -and -not $late -and -not $outOfTime) { continue }

                if ($j.Handle.IsCompleted) {
                    try { $null = $j.Ps.EndInvoke($j.Handle) }
                    catch { if (-not $j.Result.Fatal) { $j.Result.Fatal = $_.Exception.Message } }
                    $j.Ps.Dispose()
                }
                else {
                    # Stopped without waiting: a runspace stuck in an SMB call
                    # can ignore Stop for a long time, and the scan must not
                    # wait for it a second time. Left undisposed on purpose.
                    [void]$j.Result.Notes.Add($(if ($j.Result.StartedUtc) { "Gave up reading this kiosk after ${TimeoutSeconds}s" } else { 'Never got its turn: the scan ran out of time' }))
                    $j.Result.TimedOut = $true
                    $j.Abandoned = $true
                    try { [void]$j.Ps.BeginStop($null, $null) } catch { }
                }

                if ($j.Result.StartedUtc -and -not $j.Result.Seconds) {
                    $j.Result.Seconds = [Math]::Round(([DateTime]::UtcNow - $j.Result.StartedUtc).TotalSeconds, 1)
                }
                $j.Finished = $true
                $done++
                Write-Progress -Activity 'MWST fleet scan' -Status "reading kiosks ($done/$($jobs.Count)) $($j.Host)" -PercentComplete ([int](100 * $done / $jobs.Count))
                Write-ScanProgress -Phase 'scanning' -Index $done -Total $jobs.Count -HostName $j.Host
            }
        }
    }
    finally {
        # A pool with an abandoned runspace in it can block on Close, so it is
        # left to die with the process.
        if (-not @($jobs | Where-Object { $_.Abandoned }).Count) {
            try { $pool.Close(); $pool.Dispose() } catch { }
        }
    }

    return $results
}

# ===========================================================================
# Main
# ===========================================================================

# One collector at a time. A manual run during a scheduled one would
# otherwise race it to the CSV. The mutex is released automatically if the
# process dies.
$mutex = $null
$hasLock = $false
try {
    $mutex = New-Object System.Threading.Mutex($false, 'Global\MWST_FLEET_COLLECTOR')
}
catch {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\MWST_FLEET_COLLECTOR')
}
try { $hasLock = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $hasLock = $true }

if (-not $hasLock) {
    Write-CollectorLog 'Another collector run is in progress; exiting without scanning.' 'WARN'
    $mutex.Dispose()
    exit 0
}

$exitCode = 0

try {
    $scanStart     = Get-Date
    $nowUtc        = $scanStart.ToUniversalTime()
    $scanId        = $nowUtc.ToString("yyyyMMdd'T'HHmmss'Z'", $Inv)
    $collectedUtc  = Format-UtcIso $nowUtc
    $retentionCutoffIso = Format-UtcIso $nowUtc.AddDays(-$RetentionDays)
    $runCutoffIso       = Format-UtcIso $nowUtc.AddDays(-$RunRowRetentionDays)

    Write-CollectorLog ("Scan {0} starting (collector v{1}, run by {2}\{3} on {4}{5})." -f `
        $scanId, $CollectorVersion, $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME, $(if ($DryRun) { ', DRY RUN' } else { '' }))

    # --- Credential -------------------------------------------------------
    if (-not $Credential -and $CredentialFile) {
        $Credential = Import-StoredCredential -Path $CredentialFile
        Write-CollectorLog "Using stored credential for $($Credential.UserName)."
    }

    # --- Kiosk list -------------------------------------------------------
    if ($KioskList) {
        $item = Get-Item -LiteralPath $KioskList -ErrorAction Stop
        $listInfo = [pscustomobject]@{
            Path = $item.FullName; Source = 'explicit -KioskList'; IsMaster = $false
            Modified = $item.LastWriteTime; ShortcutOnly = $null
        }
    }
    else {
        $listInfo = Resolve-KioskListPath -ScriptDir $ScriptDir
    }
    Write-KioskListSource -ListInfo $listInfo

    if (-not $listInfo.Path) { throw 'No kiosk list found; nothing to scan.' }

    $kiosks = @(Import-KioskList -Path $listInfo.Path -SheetName $SheetName -IncludeAll:$IncludeAllHosts)
    if ($kiosks.Count -eq 0) { throw "Kiosk list '$($listInfo.Path)' yielded no hosts." }

    $watchdogCount = @($kiosks | Where-Object { $_.RunsWatchdog }).Count
    Write-CollectorLog ("{0} host(s) from {1}: {2} run the watchdog, {3} ping-only." -f `
        $kiosks.Count, $listInfo.Source, $watchdogCount, ($kiosks.Count - $watchdogCount))

    # Skipping a kiosk is a decision worth seeing in the log: a mistyped or
    # unfilled ACTIVE column otherwise removes kiosks from the report with
    # nothing anywhere to say that it happened.
    if ($script:KioskListStats -and $script:KioskListStats.Inactive -gt 0) {
        Write-CollectorLog ("{0} kiosk(s) skipped: ACTIVE is set to something other than Y in the list." -f `
            $script:KioskListStats.Inactive) 'WARN'
    }

    # --- Output location --------------------------------------------------
    if (-not $OutputCsv) {
        if ($listInfo.IsMaster) {
            $OutputCsv = Join-Path (Split-Path -Parent $listInfo.Path) $OutputName
        }
        else {
            $OutputCsv = $LocalCsv
            Write-CollectorLog 'SharePoint master list not synced here; publishing to Logs\ only.' 'WARN'
        }
    }
    $samePath = ([System.IO.Path]::GetFullPath($OutputCsv) -eq [System.IO.Path]::GetFullPath($LocalCsv))

    # --- Existing data: published copy and local copy, merged -------------
    $known    = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $allRows  = New-Object System.Collections.Generic.List[object]
    $dirty    = $false

    $primary = Read-FleetCsv -Path $OutputCsv
    $primaryWritable = -not $primary.Error
    if ($primary.Error) {
        Write-CollectorLog "Published CSV could not be read and will NOT be overwritten this run: $($primary.Error)" 'ERROR'
        $exitCode = 1
    }
    foreach ($r in $primary.Rows) { if ($known.Add($r.EventId)) { $allRows.Add($r) } }

    $localWritable = $true
    if (-not $samePath) {
        $local = Read-FleetCsv -Path $LocalCsv
        if ($local.Error) {
            Write-CollectorLog "Local CSV could not be read and will NOT be overwritten this run: $($local.Error)" 'ERROR'
            $localWritable = $false
        }
        $restored = 0
        foreach ($r in $local.Rows) { if ($known.Add($r.EventId)) { $allRows.Add($r); $restored++ } }
        if ($restored -gt 0) {
            Write-CollectorLog "Merged $restored row(s) from the local copy that were missing from the published CSV."
            $dirty = $true
        }
        if (-not $primary.Exists -and $local.Exists) { $dirty = $true }
    }

    # Latest status row per host, for change detection.
    $lastStatus = @{}
    $lastRunIso = $null
    foreach ($r in $allRows) {
        if ($r.EventType -eq 'HOST_STATUS') {
            $prev = $lastStatus[$r.Host]
            if (-not $prev -or [string]::CompareOrdinal($r.EventTimeUtc, $prev.EventTimeUtc) -gt 0) { $lastStatus[$r.Host] = $r }
        }
        elseif ($r.EventType -eq 'COLLECTOR_RUN') {
            if (-not $lastRunIso -or [string]::CompareOrdinal($r.EventTimeUtc, $lastRunIso) -gt 0) { $lastRunIso = $r.EventTimeUtc }
        }
    }

    # How far back to read each kiosk's System log: EventLookbackDays, but
    # never less than the time since this collector last ran - a fortnight's
    # leave must not leave a fortnight-sized hole - and, per kiosk, never
    # less than the time since its event log was last readable.
    $floorUtc       = $nowUtc.AddDays(-$RetentionDays)
    $globalSinceUtc = $nowUtc.AddDays(-$EventLookbackDays)
    if ($lastRunIso) {
        $prevRun = ConvertFrom-UtcIso $lastRunIso
        if ($prevRun -and $prevRun.AddDays(-1) -lt $globalSinceUtc) {
            $globalSinceUtc = $prevRun.AddDays(-1)
            Write-CollectorLog ("Last collector run was {0:N1} day(s) ago; reading event logs back to {1}." -f `
                ($nowUtc - $prevRun).TotalDays, (Format-UtcIso $globalSinceUtc))
        }
    }
    if ($globalSinceUtc -lt $floorUtc) { $globalSinceUtc = $floorUtc }

    $statusHistory = @{}
    foreach ($r in $allRows) {
        if ($r.EventType -ne 'HOST_STATUS') { continue }
        if (-not $statusHistory.ContainsKey($r.Host)) { $statusHistory[$r.Host] = New-Object System.Collections.Generic.List[object] }
        $statusHistory[$r.Host].Add($r)
    }

    Write-CollectorLog ("Loaded {0} existing row(s). Scanning {1} kiosk(s), {2} at a time..." -f $allRows.Count, $kiosks.Count, $ParallelHosts)

    # --- Scan ---------------------------------------------------------------
    $newIds      = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $newRows     = New-Object System.Collections.Generic.List[object]
    $hostResults = New-Object System.Collections.Generic.List[object]
    $pbiDetails = @{}
    $webDetails = @{}
    $ngDetails = @{}
    $stats = @{ Reachable = 0; LedgersRead = 0; EventLogsRead = 0; HostErrors = 0; InvalidLedgerRows = 0 }

    $readStart = Get-Date
    $fetched = Invoke-KioskFetch -Kiosks $kiosks -ScriptDir $ScriptDir -AgentPathTemplate $AgentPathTemplate `
        -KioskRootTemplate $KioskRootTemplate -NowUtc $nowUtc -Credential $Credential `
        -PingTimeoutMs $PingTimeoutMs -PbiStaleMinutes $PbiStaleMinutes `
        -Parallel $ParallelHosts -TimeoutSeconds $HostTimeoutSeconds

    $slow = @($fetched.Values | Where-Object { $_.Seconds -ge 10 } | Sort-Object Seconds -Descending)
    Write-CollectorLog ("Read {0} kiosk(s) in {1:N0}s{2}." -f $kiosks.Count, ((Get-Date) - $readStart).TotalSeconds,
        $(if ($slow.Count) { '; slowest ' + (($slow | Select-Object -First 3 | ForEach-Object { '{0} {1:N0}s' -f $_.Host, $_.Seconds }) -join ', ') } else { '' }))

    foreach ($k in $kiosks) {
        $h = $k.Host.ToUpperInvariant()
        $fetch = $fetched[$h]

        $obs = [pscustomobject]@{
            Reachable     = $false
            Method        = $null
            ShareOk       = $null
            LogFound      = $null
            LedgerFound   = $null
            LedgerFiles   = 0
            LogAgeMinutes = $null
            EventLogOk    = $null
            LoopGuard     = $false
            WinEventRows  = 0
            PreUpgrade    = 0
            AgentVersion  = ''
            LedgerBootUtc = $null
            EventBootUtc  = $null
            NewEvents     = 0
            IsPbi         = [bool](Test-IsPowerBiKiosk -Type $k.Type)
            IsWeb         = [bool](Test-IsWebKiosk -Type $k.Type)
            WatchdogFound = $false
            Pbi           = $null
            Web           = $null
            Ng            = $null
            Notes         = New-Object System.Collections.Generic.List[string]
        }

        try {
            # What Invoke-KioskFetch read off this kiosk. Everything below
            # works from that; nothing here touches the network.
            $obs.Reachable = $fetch.Reachable
            $obs.Method    = $fetch.Method
            if ($obs.Reachable) { $stats.Reachable++ }
            foreach ($n in $fetch.Notes) { $obs.Notes.Add($n) }
            if ($fetch.Fatal) {
                $stats.HostErrors++
                $obs.Notes.Add("Scan error: $($fetch.Fatal)")
                Write-CollectorLog "${h}: $($fetch.Fatal)" 'WARN'
            }
            elseif ($fetch.TimedOut) {
                $stats.HostErrors++
                Write-CollectorLog ("{0}: gave up reading it after {1}s" -f $h, $HostTimeoutSeconds) 'WARN'
            }

            # Mach2 Launcher NG, where it is installed - on any kiosk: a
            # screen of a Power BI kiosk can show a Mach2 dashboard.
            if ($fetch.Ng -and $fetch.Ng.Installed) {
                $obs.Ng = $fetch.Ng
                $obs.WatchdogFound = $true
                $ngDetails[$h] = ConvertTo-Mach2NgSidecarEntry -Observation $fetch.Ng
            }

            # --- Ledger and liveness, over the admin share ---
            if ($obs.Reachable -and ($k.RunsWatchdog -or $obs.WatchdogFound)) {
                $obs.ShareOk = $fetch.ShareOk

                if ($obs.ShareOk) {
                    $obs.LogFound      = $fetch.LogFound
                    $obs.LogAgeMinutes = $fetch.LogAgeMinutes

                    $latest = $null
                    if ($fetch.Ledger) {
                        $ledger = $fetch.Ledger
                        $obs.LedgerFiles = $ledger.Files
                        $obs.LedgerFound = ($ledger.Files -gt 0)
                        if ($obs.LedgerFound) { $stats.LedgersRead++ }

                        # Converted first, filtered second: a kiosk's cutoff
                        # is its own AGENT_START row, which may appear after
                        # the records it should exclude.
                        $converted = New-Object System.Collections.Generic.List[object]
                        $latest = $null
                        $guard  = $null
                        foreach ($lr in $ledger.Rows) {
                            $row = ConvertFrom-LedgerRow -Row $lr -HostName $h -ScanId $scanId -CollectedUtc $collectedUtc
                            if (-not $row) { $stats.InvalidLedgerRows++; continue }

                            # Whether the loop guard holds is whatever its last
                            # row says. By file order, not by time: the rows are
                            # read oldest first, and a kiosk clock corrected
                            # after a boot can stamp a later row earlier.
                            if ($row.EventType -like 'LOOP_GUARD_*') { $guard = $row }

                            if ($row.Source -eq 'EventLog') { $obs.WinEventRows++ }
                            if ($row.EventType -eq 'BOOT') {
                                $bootT = ConvertFrom-UtcIso $row.EventTimeUtc
                                if ($bootT -and (-not $obs.EventBootUtc -or $bootT -gt $obs.EventBootUtc)) { $obs.EventBootUtc = $bootT }
                            }

                            # Only the agent's own rows carry a boot time; a
                            # copied Windows record has none of its own.
                            # -ge: on a same-second tie the later row in file order wins.
                            if ($row.BootTimeUtc -and (-not $latest -or [string]::CompareOrdinal($row.EventTimeUtc, $latest.EventTimeUtc) -ge 0)) { $latest = $row }

                            $converted.Add($row)
                        }

                        # Dropped here rather than only at pruning time, so
                        # they do not re-enter on every scan and rewrite the
                        # published file for nothing.
                        $hostCutoff = $null
                        if (-not $KeepPreUpgradeHistory) {
                            $hostCutoff = (Get-UpgradeCutoffs -Rows $converted)[$h]
                        }

                        foreach ($row in $converted) {
                            if ($hostCutoff -and [string]::CompareOrdinal($row.EventTimeUtc, $hostCutoff) -lt 0) { $obs.PreUpgrade++; continue }
                            if ($known.Contains($row.EventId) -or $newIds.Contains($row.EventId)) { continue }
                            if ([string]::CompareOrdinal($row.EventTimeUtc, $retentionCutoffIso) -lt 0) { continue }

                            [void]$newIds.Add($row.EventId)
                            $newRows.Add($row)
                            $obs.NewEvents++
                        }

                        $obs.LoopGuard = [bool]($guard -and $guard.EventType -eq 'LOOP_GUARD_ENGAGED')
                    }

                    if ($latest) {
                        $obs.AgentVersion  = $latest.AgentVersion
                        $obs.LedgerBootUtc = ConvertFrom-UtcIso $latest.BootTimeUtc
                    }
                    elseif ($obs.LogFound) {
                        $obs.AgentVersion = 'legacy'
                    }
                }
            }

            # --- PBI Launcher and Web Launcher, on any kiosk ---
            # Their status files, over the same admin share. A Power BI kiosk
            # still on the old PowerBILauncher.exe (or none) stays ping-only.
            if ($obs.Reachable) {
                if ($null -eq $obs.ShareOk -and ($obs.IsPbi -or $obs.IsWeb)) { $obs.ShareOk = $fetch.PbiShareOk }
                if ($fetch.PbiShareOk -and $fetch.Pbi -and ($obs.IsPbi -or $fetch.Pbi.Installed -or $fetch.Pbi.Screens.Count)) {
                    $obs.Pbi = $fetch.Pbi
                    $pbiDetails[$h] = ConvertTo-PbiSidecarEntry -Observation $fetch.Pbi
                }
                if ($fetch.PbiShareOk -and $fetch.Web -and ($obs.IsWeb -or $fetch.Web.Installed -or $fetch.Web.Screens.Count)) {
                    $obs.Web = $fetch.Web
                    $webDetails[$h] = ConvertTo-PbiSidecarEntry -Observation $fetch.Web
                }
            }

            # --- System log, read across the network ---
            # Off unless asked for: the RPC behind Get-WinEvent -ComputerName
            # is closed by the zero-trust policy, and each blocked host would
            # cost this scan a long timeout. The kiosks copy these records
            # into their ledgers themselves, which the loop above reads.
            if ($RemoteEventLog -and $obs.Reachable -and ($k.RunsWatchdog -or $EventLogAllHosts)) {
                $hostSinceUtc = $globalSinceUtc
                if ($statusHistory.ContainsKey($h)) {
                    $gap = Get-EventLogGapStart -StatusRows $statusHistory[$h]
                    if ($gap -and $gap.AddDays(-1) -lt $hostSinceUtc) { $hostSinceUtc = $gap.AddDays(-1) }
                }
                if ($hostSinceUtc -lt $floorUtc) { $hostSinceUtc = $floorUtc }
                if ($hostSinceUtc -lt $nowUtc.AddDays(-$EventLookbackDays - 1)) {
                    $obs.Notes.Add(("event log read back {0:N0} days to cover a gap" -f ($nowUtc - $hostSinceUtc).TotalDays))
                }

                $ev = Get-RebootEvents -HostName $h -SinceUtc $hostSinceUtc -Credential $Credential
                $obs.EventLogOk = $ev.Ok
                if ($ev.Ok) { $stats.EventLogsRead++ } else { $obs.Notes.Add("EventLog: $($ev.Error)") }

                foreach ($rec in $ev.Records) {
                    $row = ConvertFrom-RebootEvent -Record $rec -HostName $h -ScanId $scanId -CollectedUtc $collectedUtc
                    if (-not $row) { continue }

                    if ($row.EventType -eq 'BOOT') {
                        $bootT = ConvertFrom-UtcIso $row.EventTimeUtc
                        if (-not $obs.EventBootUtc -or $bootT -gt $obs.EventBootUtc) { $obs.EventBootUtc = $bootT }
                    }

                    if ($known.Contains($row.EventId) -or $newIds.Contains($row.EventId)) { continue }
                    if ([string]::CompareOrdinal($row.EventTimeUtc, $retentionCutoffIso) -lt 0) { continue }

                    [void]$newIds.Add($row.EventId)
                    $newRows.Add($row)
                    $obs.NewEvents++
                }
            }
        }
        catch {
            $stats.HostErrors++
            $obs.Notes.Add("Scan error: $($_.Exception.Message)")
            Write-CollectorLog "${h}: $($_.Exception.Message)" 'WARN'
        }

        # --- Status row ---
        # The ledger's boot time is authoritative once the agent has run since
        # the latest boot; if it has not, the System log's newer boot wins.
        $bootUtc = $obs.LedgerBootUtc
        if ($obs.EventBootUtc -and (-not $bootUtc -or $obs.EventBootUtc -gt $bootUtc.AddMinutes(10))) { $bootUtc = $obs.EventBootUtc }
        if (-not $bootUtc -and $obs.Pbi -and $obs.Pbi.PcBootUtc) { $bootUtc = $obs.Pbi.PcBootUtc }
        if (-not $bootUtc -and $obs.Web -and $obs.Web.PcBootUtc) { $bootUtc = $obs.Web.PcBootUtc }
        # The watchdog's version where there is one; otherwise the launcher's.
        if (-not $obs.WatchdogFound -or -not $obs.AgentVersion) {
            if ($obs.Pbi -and $obs.Pbi.LauncherVersion) { $obs.AgentVersion = "pbi-$($obs.Pbi.LauncherVersion)" }
            elseif ($obs.Web -and $obs.Web.LauncherVersion) { $obs.AgentVersion = "web-$($obs.Web.LauncherVersion)" }
        }

        $watchdogRunning = $null
        if (($k.RunsWatchdog -or $obs.WatchdogFound) -and $obs.Reachable -and $obs.ShareOk) {
            $watchdogRunning = ($null -ne $obs.LogAgeMinutes -and $obs.LogAgeMinutes -le $StaleMinutes)
        }

        $st = Get-HostStatus -Kiosk $k -Obs $obs

        $checks = New-Object System.Collections.Generic.List[string]
        $checks.Add('reach=' + $(if ($obs.Reachable) { $obs.Method } else { 'FAIL' }))
        if ($null -ne $obs.ShareOk)     { $checks.Add('share=' + $(if ($obs.ShareOk) { 'ok' } else { 'FAIL' })) }
        if ($null -ne $obs.LogFound)    { $checks.Add('log=' + $(if ($obs.LogFound) { (Format-Number $obs.LogAgeMinutes 1) + 'm' } else { 'missing' })) }
        if ($null -ne $obs.LedgerFound) { $checks.Add('ledger=' + $(if ($obs.LedgerFound) { "ok($($obs.LedgerFiles))" } else { 'missing' })) }
        if ($obs.LoopGuard)             { $checks.Add('loopguard=HOLD') }
        if ($null -ne $obs.EventLogOk)  { $checks.Add('eventlog=' + $(if ($obs.EventLogOk) { 'ok' } else { 'FAIL' })) }
        elseif (($k.RunsWatchdog -or $obs.WatchdogFound) -and $obs.ShareOk) { $checks.Add("eventlog=agent($($obs.WinEventRows))") }
        if ($obs.Pbi -and $obs.Pbi.Summary) { $checks.Add($obs.Pbi.Summary) }
        if ($obs.Web -and $obs.Web.Summary) { $checks.Add($obs.Web.Summary) }
        if ($obs.Ng -and $obs.Ng.Summary) { $checks.Add($obs.Ng.Summary) }
        $checks.Add("new=$($obs.NewEvents)")
        $detail = ($checks -join ' ')
        if ($obs.Notes.Count -gt 0) { $detail += ' | ' + ($obs.Notes -join ' | ') }

        $statusRow = New-FleetRow -Values @{
            EventId             = "STAT-$h-$scanId"
            EventTimeUtc        = $collectedUtc
            Host                = $h
            EventType           = 'HOST_STATUS'
            Severity            = $st.Severity
            Outcome             = $st.Status
            Reachable           = (Format-Bool $obs.Reachable)
            WatchdogRunning     = (Format-Bool $watchdogRunning)
            MinutesSinceLastLog = (Format-Number $obs.LogAgeMinutes 1)
            AgentVersion        = $obs.AgentVersion
            BootTimeUtc         = $(if ($bootUtc) { Format-UtcIso $bootUtc } else { '' })
            UptimeHours         = $(if ($bootUtc) { Format-Number ($nowUtc - $bootUtc).TotalHours 1 } else { '' })
            Source              = 'Collector'
            ScanId              = $scanId
            CollectedUtc        = $collectedUtc
            Detail              = $detail
        }

        $writeStatus = Test-StatusRowNeeded -Row $statusRow -Previous $lastStatus[$h] -NowUtc $nowUtc -Keepalive $KeepaliveHours
        if ($writeStatus) {
            [void]$newIds.Add($statusRow.EventId)
            $newRows.Add($statusRow)
        }

        $hostResults.Add([pscustomobject]@{
            Host      = $h
            Type      = $k.Type
            Location  = $k.Location
            Status    = $st.Status
            Watchdog  = $(if ($null -eq $watchdogRunning) { '' } elseif ($watchdogRunning) { 'running' } else { 'DEAD' })
            LogAgeMin = (Format-Number $obs.LogAgeMinutes 1)
            Agent      = $obs.AgentVersion
            Launcher   = (@(@($obs.Pbi, $obs.Web, $obs.Ng) | Where-Object { $_ } | ForEach-Object { $_.Instances } | Sort-Object Screen | ForEach-Object { '{0}:{1}' -f $_.Screen, $_.State }) -join ',')
            NewEvents  = $obs.NewEvents
            PreUpgrade = $obs.PreUpgrade
            Notes     = ($obs.Notes -join ' | ')
        })
    }
    Write-Progress -Activity 'MWST fleet scan' -Completed
    Write-ScanProgress -Phase 'saving' -Index $kiosks.Count -Total $kiosks.Count

    # Kiosks deliberately excluded from scanning get a status of their own.
    # Without it their last real status stays on the dashboard for ever -
    # a decommissioned screen frozen on OFFLINE, counted as a problem no one
    # can fix. They are not contacted; this only records the decision.
    if ($script:KioskListStats -and $script:KioskListStats.InactiveRows) {
        foreach ($dead in $script:KioskListStats.InactiveRows) {
            $dh = $dead.Host.ToUpperInvariant()

            $statusRow = New-FleetRow -Values @{
                EventId      = "STAT-$dh-$scanId"
                EventTimeUtc = $collectedUtc
                Host         = $dh
                Location     = $dead.Location
                KioskType    = $dead.Type
                RestartGroup = $dead.RestartGroup
                EventType    = 'HOST_STATUS'
                Severity     = 'INFO'
                Outcome      = 'INACTIVE'
                Source       = 'Collector'
                ScanId       = $scanId
                CollectedUtc = $collectedUtc
                Detail       = ("not scanned: ACTIVE is '{0}' in the kiosk list" -f $dead.Active)
            }

            if (Test-StatusRowNeeded -Row $statusRow -Previous $lastStatus[$dh] -NowUtc $nowUtc -Keepalive $KeepaliveHours) {
                [void]$newIds.Add($statusRow.EventId)
                $newRows.Add($statusRow)
            }
        }
    }

    if ($stats.InvalidLedgerRows -gt 0) {
        Write-CollectorLog "$($stats.InvalidLedgerRows) ledger row(s) were malformed and skipped." 'WARN'
    }

    # --- Merge ------------------------------------------------------------
    foreach ($r in $newRows) {
        [void]$known.Add($r.EventId)
        $allRows.Add($r)
    }
    $eventRowCount = @($newRows | Where-Object { $_.EventType -ne 'HOST_STATUS' }).Count
    if ($newRows.Count -gt 0) { $dirty = $true }

    # Kiosk attributes follow the current list, so a kiosk moved to another
    # location slices under its new location across its whole history.
    $meta = @{}
    foreach ($k in $kiosks) { $meta[$k.Host.ToUpperInvariant()] = $k }
    # Inactive kiosks keep their attributes up to date too, so a screen that
    # is moved while switched off still slices under the right location.
    if ($script:KioskListStats -and $script:KioskListStats.InactiveRows) {
        foreach ($dead in $script:KioskListStats.InactiveRows) {
            $dk = $dead.Host.ToUpperInvariant()
            if (-not $meta.ContainsKey($dk)) { $meta[$dk] = $dead }
        }
    }
    $metaChanges = 0
    foreach ($r in $allRows) {
        if (-not $r.Host) { continue }
        $m = $meta[$r.Host]
        if (-not $m) { continue }
        if ($r.Location -cne [string]$m.Location)         { $r.Location = [string]$m.Location; $metaChanges++ }
        if ($r.KioskType -cne [string]$m.Type)            { $r.KioskType = [string]$m.Type; $metaChanges++ }
        if ($r.RestartGroup -cne [string]$m.RestartGroup) { $r.RestartGroup = [string]$m.RestartGroup; $metaChanges++ }
    }
    if ($metaChanges -gt 0) { $dirty = $true }

    $flagChanges = Update-RebootFlags -Rows $allRows -RecomputeFromUtc $nowUtc.AddDays(-$ReconcileDays) -NewIds $newIds
    if ($flagChanges -gt 0) { $dirty = $true }

    # --- Retention ----------------------------------------------------------
    # Cutoffs are recomputed over everything, not just this scan's rows, so
    # history already in the file is cleared out the first time this runs.
    $upgradeCutoffs = @{}
    if (-not $KeepPreUpgradeHistory) { $upgradeCutoffs = Get-UpgradeCutoffs -Rows $allRows }

    $kept = New-Object System.Collections.Generic.List[object]
    $preUpgradePruned = 0
    foreach ($r in $allRows) {
        if ($r.EventTimeUtc) {
            if ([string]::CompareOrdinal($r.EventTimeUtc, $retentionCutoffIso) -lt 0) { continue }
            if ($r.EventType -eq 'COLLECTOR_RUN' -and [string]::CompareOrdinal($r.EventTimeUtc, $runCutoffIso) -lt 0) { continue }
            if ($r.Host -and $upgradeCutoffs.ContainsKey($r.Host) -and
                [string]::CompareOrdinal($r.EventTimeUtc, $upgradeCutoffs[$r.Host]) -lt 0) { $preUpgradePruned++; continue }
        }
        $kept.Add($r)
    }
    $pruned = $allRows.Count - $kept.Count
    if ($pruned -gt 0) { $dirty = $true }
    if ($preUpgradePruned -gt 0) {
        Write-CollectorLog "Dropped $preUpgradePruned row(s) from before kiosks upgraded to agent $TrustedFromAgentVersion (use -KeepPreUpgradeHistory to keep them)." 'WARN'
    }

    # --- Heartbeat ----------------------------------------------------------
    $heartbeatDue = $true
    if ($lastRunIso) {
        $lastRun = ConvertFrom-UtcIso $lastRunIso
        if ($lastRun -and (($nowUtc - $lastRun).TotalMinutes -lt $HeartbeatMinutes)) { $heartbeatDue = $false }
    }

    $scriptRebootsNew = @($newRows | Where-Object { $_.EventType -eq 'RESTART_TRIGGERED' -or $_.EventType -eq 'REBOOT_SCRIPT' }).Count
    $summary = "hosts={0} reachable={1} watchdog_hosts={2} ledgers_read={3} eventlogs_read={4} new_events={5} status_rows={6} flag_changes={7} pruned={8} pre_upgrade_skipped={9} host_errors={10}" -f `
        $kiosks.Count, $stats.Reachable, $watchdogCount, $stats.LedgersRead, $stats.EventLogsRead,
        $eventRowCount, ($newRows.Count - $eventRowCount), $flagChanges, $pruned,
        (@($hostResults | Measure-Object -Property PreUpgrade -Sum).Sum), $stats.HostErrors

    # --- Write --------------------------------------------------------------
    $elapsedSeconds = ((Get-Date) - $scanStart).TotalSeconds
    $dataChanged = $false

    if ($dirty -or $heartbeatDue) {
        $elapsed = $elapsedSeconds
        $runRow = New-FleetRow -Values @{
            EventId         = "RUN-$scanId"
            EventTimeUtc    = $collectedUtc
            EventType       = 'COLLECTOR_RUN'
            Severity        = $(if ($stats.HostErrors -gt 0 -or -not $primaryWritable) { 'WARNING' } else { 'INFO' })
            Outcome         = $(if ($stats.HostErrors -gt 0 -or -not $primaryWritable) { 'PARTIAL' } else { 'OK' })
            DurationSeconds = (Format-Number $elapsed 0)
            Source          = 'Collector'
            ScanId          = $scanId
            CollectedUtc    = $collectedUtc
            Detail          = ("v{0}; {1}; list={2}; runner={3}\{4}@{5}" -f $CollectorVersion, $summary, $listInfo.Path, $env:USERDOMAIN, $env:USERNAME, $env:COMPUTERNAME)
        }
        $kept.Add($runRow)

        $sorted = @($kept | Sort-Object -Property EventTimeUtc, EventId)

        if ($DryRun) {
            Write-CollectorLog ("DRY RUN: would write {0} row(s) to {1}" -f $sorted.Count, $OutputCsv)
        }
        else {
            if ($primaryWritable) {
                try {
                    Write-FleetCsv -Rows $sorted -Path $OutputCsv
                    $dataChanged = $true
                    Write-CollectorLog ("Wrote {0} row(s) to {1}" -f $sorted.Count, $OutputCsv)
                }
                catch {
                    Write-CollectorLog "Could not write the published CSV: $($_.Exception.Message)" 'ERROR'
                    $exitCode = 1
                }
            }

            if (-not $samePath -and $localWritable) {
                try {
                    Write-FleetCsv -Rows $sorted -Path $LocalCsv
                }
                catch {
                    Write-CollectorLog "Could not write the local CSV: $($_.Exception.Message)" 'ERROR'
                    $exitCode = 1
                }
            }
        }
    }
    else {
        Write-CollectorLog 'Nothing new; CSV left untouched.'
    }

    # Written on every run, changed data or not - this is the only thing that
    # tells a dashboard the collector is still alive on a quiet fleet.
    if (-not $DryRun) {
        $needAttention = @($hostResults | Where-Object { $_.Status -ne 'OK' }).Count
        $sidecar = @{
            LastRunUtc       = $collectedUtc
            LastRunLocal     = (Format-LocalIso $nowUtc)
            DurationSeconds  = [int]$elapsedSeconds
            Hosts            = $kiosks.Count
            Reachable        = $stats.Reachable
            WatchdogHosts    = $watchdogCount
            NeedsAttention   = $needAttention
            NewEvents        = $eventRowCount
            DataChanged      = $dataChanged
            HostErrors       = $stats.HostErrors
            SkippedInactive  = $(if ($script:KioskListStats) { $script:KioskListStats.Inactive } else { 0 })
            CollectorVersion = $CollectorVersion
            Runner           = "$env:USERDOMAIN\$env:USERNAME@$env:COMPUTERNAME"
            # Live PBI Launcher details for the dashboard. Kept here rather
            # than in the CSV: they change far more often than a host status
            # should, and this file is rewritten on every run anyway.
            PbiLaunchers     = [pscustomobject]$pbiDetails
            # The same for Mach2 kiosks on Mach2 Launcher ver 1.00NG.
            Mach2Launchers   = [pscustomobject]$ngDetails
            # And for screens showing a web page (Web Launcher).
            WebLaunchers     = [pscustomobject]$webDetails
        }
        if ($primaryWritable) { Write-StatusSidecar -CsvPath $OutputCsv -Values $sidecar }
        if (-not $samePath -and $localWritable) { Write-StatusSidecar -CsvPath $LocalCsv -Values $sidecar }
    }

    Write-CollectorLog "Scan $scanId done in $([math]::Round(((Get-Date) - $scanStart).TotalSeconds, 1))s. $summary"
    if ($scriptRebootsNew -gt 0) {
        Write-CollectorLog "$scriptRebootsNew new watchdog reboot record(s) collected this run." 'WARN'
    }

    # --- Console summary ----------------------------------------------------
    if ([Environment]::UserInteractive) {
        $hostResults | Sort-Object @{ Expression = { if ($_.Status -eq 'OK') { 1 } else { 0 } } }, Host |
            Format-Table Host, Type, Location, Status, Watchdog, LogAgeMin, Agent, Launcher, NewEvents -AutoSize |
            Out-String -Width 200 | Write-Host

        $byType = $newRows | Where-Object { $_.EventType -ne 'HOST_STATUS' } | Group-Object EventType | Sort-Object Name
        if ($byType) {
            Write-Host 'New events this run:'
            foreach ($g in $byType) { Write-Host ("  {0,-24} {1}" -f $g.Name, $g.Count) }
        }
    }
}
catch {
    Write-CollectorLog "Scan failed: $($_.Exception.Message)" 'ERROR'
    $exitCode = 1
}
finally {
    if ($hasLock) { try { $mutex.ReleaseMutex() } catch {} }
    if ($mutex) { $mutex.Dispose() }
}

exit $exitCode
