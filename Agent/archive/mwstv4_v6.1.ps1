#Requires -Version 5.1
<#
.SYNOPSIS
    MWST kiosk white-screen watchdog, V6.1.

.DESCRIPTION
    Runs on each kiosk. Samples the primary screen every few seconds and
    reboots the machine when the KPI display has been stuck blank-white (or
    blank-dark) for long enough to be certain it is not just a slow refresh.

    Detection behaviour is unchanged from the previous version. What is new is
    the record it keeps. Alongside the human-readable mwst.log it now appends
    to mwst_events.csv - a machine-readable ledger with one row per event and
    a unique EventId per row. The fleet collector reads that ledger instead of
    re-parsing prose out of the log, which is what makes reboot counting exact
    rather than approximate.

    Three things make a triggered reboot impossible to miss:

      1. The RESTART_TRIGGERED row is written and flushed all the way to disk
         (FileStream.Flush($true), not just to the OS write cache) BEFORE
         shutdown.exe is called. A forced reboot cannot swallow it.

      2. The shutdown comment carries a machine-readable tag including the
         EventId, so the Windows System log entry that shutdown.exe generates
         (User32 event 1074) can be matched back to this exact row by the
         collector - an independent second witness that survives even if this
         whole folder is wiped.

      3. A pending-restart marker is left on disk. On the next start the
         watchdog compares it against the OS boot time and writes either
         RESTART_CONFIRMED (the machine really did come back) or
         RESTART_FAILED (the shutdown was blocked or cancelled). A reboot that
         silently did not happen is a fault worth seeing, not a gap.

      4. If the machine is still up ten minutes after asking to reboot, the
         watchdog records RESTART_FAILED straight away and goes back to
         watching the screen. (The previous version exited at this point,
         leaving the kiosk with no watchdog until its next logon.)

    The ledger is append-only and is never overwritten in place. It rolls over
    to mwst_events_<timestamp>.csv only when it exceeds MaxEventCsvBytes; the
    collector reads every mwst_events*.csv it finds, so a rollover loses
    nothing.

.NOTES
    Deployed to C:\Users\Public\Documents\mwstv4.ps1 and started by
    MWSTv5_Launcher.bat. The file name and path are deliberately unchanged so
    the launcher does not need touching - despite the "v4" in its name, this
    is V6.1.
#>

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$AgentVersion = "6.1"

# --- Detection configuration (unchanged thresholds) ---
$WhiteLimit            = 235   # per-channel value above which a pixel counts as "white"
$WhiteChecksNeeded     = 12    # consecutive over-threshold checks before rebooting
$WhiteHighThreshold    = 85    # trigger when the screen is AT LEAST this % white
$WhiteLowThreshold     = 10    # trigger when the screen is BELOW this % white
$LowWhiteChecksNeeded  = 12
$CheckIntervalSeconds  = 10
$SampleStep            = 20    # sample every Nth pixel in both axes
$HeartbeatEveryNChecks = 20

# --- Local Windows event log ---
# Remote event log access (the RPC behind Get-WinEvent -ComputerName) is
# closed by the zero-trust policy, so each kiosk reads its own System log and
# copies the reboot records into the ledger. The collector then picks them up
# over the admin share it already uses - nothing new has to cross the
# network. Reading the local System log needs no special rights.
$EventScanIntervalMinutes = 60
# One day, not a month: the collector discards anything a kiosk reports from
# before it started running this agent, because the previous watchdog was not
# a reliable witness. Backfilling further would only bloat the ledger with
# rows that are thrown away.
$EventBackfillDays        = 1
$WatchedEventIds          = @(1074, 6005, 6008)

# --- Storage configuration ---
$MaxLogSizeBytes     = 5MB     # mwst.log rollover
$MaxEventCsvBytes    = 8MB     # mwst_events.csv rollover (rows are ~200 bytes)
$RestartDelaySeconds = 15      # shutdown.exe /t

# $PSScriptRoot is only populated when this runs as a .ps1 file. If it is empty
# (pasted into a console, or run via Invoke-Expression) fall back to a fixed
# folder so the watchdog still records what it does.
$ScriptFolder = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\Users\Public\Documents" }
if (-not (Test-Path -LiteralPath $ScriptFolder)) {
    New-Item -ItemType Directory -Path $ScriptFolder -Force | Out-Null
}

$LogPath      = Join-Path $ScriptFolder "mwst.log"
$EventCsvPath = Join-Path $ScriptFolder "mwst_events.csv"
$PendingPath  = Join-Path $ScriptFolder "mwst_pending_restart.txt"
$EvtStatePath = Join-Path $ScriptFolder "mwst_evtlog_state.txt"

$EventCsvHeader = "EventId,EventTimeUtc,EventTimeLocal,Host,EventType,Severity,Outcome,WhitePercent,StreakChecks,DurationSeconds,AgentVersion,BootTimeUtc,Detail"

$HostName = $env:COMPUTERNAME
$Inv      = [System.Globalization.CultureInfo]::InvariantCulture


# ---------------------------------------------------------------------------
# Human-readable log
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"

    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -ge $MaxLogSizeBytes)) {
            $archiveName = "mwst_{0}.log" -f (Get-Date -Format "yyyyMMdd_HHmmss")
            Rename-Item -LiteralPath $LogPath -NewName $archiveName -ErrorAction SilentlyContinue
        }

        [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine)
    }
    catch {
        # Never let a logging failure kill the watchdog - fall back to console.
        Write-Host "[$timestamp] [ERROR] Failed to write to log file: $($_.Exception.Message)" -ForegroundColor Red
    }

    switch ($Level) {
        "WARN"  { Write-Host $line -ForegroundColor Yellow }
        "ERROR" { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }
}


# ---------------------------------------------------------------------------
# Event ledger
# ---------------------------------------------------------------------------
function ConvertTo-CsvField {
    # Every field is quoted, and embedded quotes are doubled. Quoting
    # unconditionally means an error message containing a comma can never
    # shift the columns of a row, and Power Query still type-detects quoted
    # numbers correctly.
    param([object]$Value)

    if ($null -eq $Value) { return '""' }
    $s = [string]$Value
    return '"' + $s.Replace('"', '""') + '"'
}

function Get-BootTimeUtc {
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        return $os.LastBootUpTime.ToUniversalTime()
    }
    catch {
        # WMI can be briefly unavailable very early in a boot. The tick counter
        # is good to the second either way.
        try { return (Get-Date).ToUniversalTime().AddMilliseconds(-1 * [Environment]::TickCount) }
        catch { return $null }
    }
}

function Format-Utc {
    param($Value)
    if ($null -eq $Value) { return "" }
    return ([datetime]$Value).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ", $Inv)
}

function Add-LedgerLine {
    param([string]$Line, [switch]$Durable)

    # Roll over before writing, not after, so a single row is never split
    # across two files.
    if ((Test-Path -LiteralPath $EventCsvPath) -and
        ((Get-Item -LiteralPath $EventCsvPath).Length -ge $MaxEventCsvBytes)) {
        $archiveName = "mwst_events_{0}.csv" -f (Get-Date -Format "yyyyMMdd_HHmmss")
        Rename-Item -LiteralPath $EventCsvPath -NewName $archiveName -ErrorAction SilentlyContinue
    }

    $needHeader = (-not (Test-Path -LiteralPath $EventCsvPath)) -or
                  ((Get-Item -LiteralPath $EventCsvPath).Length -eq 0)

    $text = ""
    if ($needHeader) { $text += $EventCsvHeader + "`r`n" }
    $text += $Line + "`r`n"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)

    if ($needHeader) {
        # UTF-8 BOM, written once, so Excel and Power Query both read the file
        # as UTF-8 without being told.
        $bytes = @([byte]0xEF, [byte]0xBB, [byte]0xBF) + $bytes
    }

    # The collector reads this file over the network with a share mode that
    # allows our writes, but antivirus, a backup agent or someone opening it
    # in Excel may not be so polite. A short retry turns "row lost" into
    # "row written 200 ms late".
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            $fs = New-Object System.IO.FileStream(
                $EventCsvPath,
                [System.IO.FileMode]::Append,
                [System.IO.FileAccess]::Write,
                ([System.IO.FileShare]::Read -bor [System.IO.FileShare]::Delete))
            try {
                $fs.Write($bytes, 0, $bytes.Length)
                if ($Durable) { $fs.Flush($true) } else { $fs.Flush() }
            }
            finally {
                $fs.Dispose()
            }
            return
        }
        catch [System.IO.IOException] {
            if ($attempt -ge 10) { throw }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Write-EventRow {
    <#
        Appends one row to the ledger.

        -Durable opens the file and calls Flush($true), which forces the bytes
        through the disk's own write cache before returning. It is slower, so
        it is used only where losing the row would mean losing the record of a
        reboot.
    #>
    param(
        [Parameter(Mandatory)][string]$EventType,
        [ValidateSet("INFO", "WARNING", "CRITICAL")][string]$Severity = "INFO",
        [string]$Outcome = "",
        [object]$WhitePercent = $null,
        [object]$StreakChecks = $null,
        [object]$DurationSeconds = $null,
        [string]$Detail = "",
        [string]$EventId,
        [datetime]$EventTime = ([datetime]::MinValue),
        [switch]$OmitBootTime,
        [switch]$Durable
    )

    if (-not $EventId) { $EventId = [guid]::NewGuid().ToString() }

    # Rows normally describe something happening right now. A record copied
    # out of the Windows event log keeps its own timestamp instead.
    $now = if ($EventTime -eq [datetime]::MinValue) { Get-Date } else { $EventTime }
    $local = if ($now.Kind -eq [System.DateTimeKind]::Utc) { $now.ToLocalTime() } else { $now }

    $fields = @(
        $EventId
        (Format-Utc $now)
        $local.ToString("yyyy-MM-ddTHH:mm:ss", $Inv)
        $HostName
        $EventType
        $Severity
        $Outcome
        $(if ($null -ne $WhitePercent)    { [math]::Round([double]$WhitePercent, 2).ToString($Inv) } else { "" })
        $(if ($null -ne $StreakChecks)    { ([int]$StreakChecks).ToString($Inv) } else { "" })
        $(if ($null -ne $DurationSeconds) { [math]::Round([double]$DurationSeconds, 0).ToString($Inv) } else { "" })
        $AgentVersion
        $(if ($OmitBootTime) { "" } else { Format-Utc $script:BootTimeUtc })
        $Detail
    )

    $line = ($fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ","

    try {
        Add-LedgerLine -Line $line -Durable:$Durable
    }
    catch {
        Write-Log "Failed to write event '$EventType' to ledger: $($_.Exception.Message)" "ERROR"
    }

    return $EventId
}


# ---------------------------------------------------------------------------
# Pending-restart reconciliation
# ---------------------------------------------------------------------------
function Resolve-PendingRestart {
    <#
        Called once at startup. The marker is written just before shutdown.exe
        is invoked, so finding one here means the previous run asked for a
        reboot and we are now in a position to say whether it happened.

        The comparison is against the OS boot time, not the clock: if the
        machine has booted since the marker was written, the reboot took
        effect. If it has not, and enough time has passed that a pending
        shutdown would long since have fired, the reboot was blocked or
        cancelled - which is a fault, and is recorded as one.
    #>
    if (-not (Test-Path -LiteralPath $PendingPath)) { return }

    # Read with a few retries. Antivirus is at its busiest right after boot,
    # and a marker that is merely locked for a moment must not be mistaken
    # for a corrupt one - discarding it would lose the confirmation of a
    # reboot. If it stays locked, leave it for the next start.
    $raw = $null
    $readOk = $false
    for ($attempt = 1; $attempt -le 5 -and -not $readOk; $attempt++) {
        try {
            $raw = Get-Content -LiteralPath $PendingPath -Raw -ErrorAction Stop
            $readOk = $true
        }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds (400 * $attempt) }
        catch { break }
    }
    if (-not $readOk) {
        Write-Log "Pending-restart marker could not be read yet; leaving it for the next start." "WARN"
        return
    }

    # Empty or unparseable means a crash while it was being written. There is
    # nothing to confirm, so it goes.
    $marker = $null
    if ($raw) { try { $marker = $raw | ConvertFrom-Json -ErrorAction Stop } catch {} }
    if ($null -eq $marker) {
        Write-Log "Pending-restart marker is empty or corrupt, discarding it." "WARN"
        Remove-Item -LiteralPath $PendingPath -Force -ErrorAction SilentlyContinue
        return
    }

    $triggeredUtc  = $null
    $markerBootUtc = $null
    try { $triggeredUtc  = [datetime]::Parse($marker.TriggeredUtc, $Inv, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}
    try { $markerBootUtc = [datetime]::Parse($marker.BootTimeUtc,  $Inv, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch {}

    if ($null -eq $triggeredUtc -or $null -eq $markerBootUtc) {
        Write-Log "Pending-restart marker has no usable timestamps, discarding it." "WARN"
        Remove-Item -LiteralPath $PendingPath -Force -ErrorAction SilentlyContinue
        return
    }

    $currentBootUtc = $script:BootTimeUtc

    if ($null -ne $currentBootUtc -and $currentBootUtc -gt $markerBootUtc.AddSeconds(30)) {
        # The machine booted after the marker was written: the reboot worked.
        $downtime = ($currentBootUtc - $triggeredUtc).TotalSeconds
        Write-EventRow -EventType "RESTART_CONFIRMED" -Severity "WARNING" -Outcome "CONFIRMED" `
            -DurationSeconds $downtime `
            -Detail ("Kind={0}; TriggerEventId={1}; reboot requested at {2} took effect, machine booted at {3}. Reason: {4}" -f `
                     $marker.Kind, $marker.EventId, (Format-Utc $triggeredUtc), (Format-Utc $currentBootUtc), $marker.Reason) | Out-Null
        Write-Log ("Confirmed the reboot requested at {0} (down for {1:N0}s). Trigger event {2}." -f `
                   (Format-Utc $triggeredUtc), $downtime, $marker.EventId) "WARN"
        Remove-Item -LiteralPath $PendingPath -Force -ErrorAction SilentlyContinue
        return
    }

    # Same boot session. That is expected if the watchdog was simply restarted
    # while the 15-second shutdown timer was still counting down, so give it a
    # grace period before calling the reboot a failure.
    $ageMinutes = ((Get-Date).ToUniversalTime() - $triggeredUtc).TotalMinutes
    if ($ageMinutes -lt 10) {
        Write-Log ("A restart requested {0:N1} minutes ago is still pending; leaving the marker in place." -f $ageMinutes) "WARN"
        return
    }

    Write-EventRow -EventType "RESTART_FAILED" -Severity "CRITICAL" -Outcome "FAILED" `
        -DurationSeconds ($ageMinutes * 60) `
        -Detail ("Kind={0}; TriggerEventId={1}; reboot requested at {2} never took effect - the machine has not booted since. Reason: {3}" -f `
                 $marker.Kind, $marker.EventId, (Format-Utc $triggeredUtc), $marker.Reason) | Out-Null
    Write-Log ("Restart requested at {0} did NOT take effect - still on the same boot session {1:N0} minutes later." -f `
               (Format-Utc $triggeredUtc), $ageMinutes) "ERROR"
    Remove-Item -LiteralPath $PendingPath -Force -ErrorAction SilentlyContinue
}


function Invoke-WatchdogRestart {
    <#
        The one path that reboots the kiosk. Order matters and is deliberate:
        ledger row first (flushed to disk), then the marker, then shutdown.
        Everything that has to survive the reboot is on disk before anything
        is asked to happen.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,       # WHITE | LOWWHITE
        [Parameter(Mandatory)][int]$StreakChecks,
        [Parameter(Mandatory)][double]$WhitePercent,
        [Parameter(Mandatory)][double]$EpisodeSeconds,
        [string]$EpisodeId
    )

    $eventId = [guid]::NewGuid().ToString()
    $shortId = $eventId.Substring(0, 8)

    $reason = if ($Kind -eq "WHITE") {
        "screen at least $WhiteHighThreshold% white for $StreakChecks consecutive checks"
    } else {
        "screen below $WhiteLowThreshold% white for $StreakChecks consecutive checks"
    }

    Write-EventRow -EventId $eventId -EventType "RESTART_TRIGGERED" -Severity "CRITICAL" -Outcome "REBOOT" `
        -WhitePercent $WhitePercent -StreakChecks $StreakChecks -DurationSeconds $EpisodeSeconds `
        -Detail ("{0}: {1}. EpisodeId={2}" -f $Kind, $reason, $EpisodeId) -Durable | Out-Null

    # The marker is what lets the next run confirm the reboot really happened.
    $marker = [pscustomobject]@{
        EventId      = $eventId
        Kind         = $Kind
        Reason       = $reason
        TriggeredUtc = Format-Utc (Get-Date)
        BootTimeUtc  = Format-Utc $script:BootTimeUtc
    }
    try {
        $json = $marker | ConvertTo-Json -Compress
        $fs = New-Object System.IO.FileStream($PendingPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush($true)
        }
        finally { $fs.Dispose() }
    }
    catch {
        Write-Log "Could not write the pending-restart marker: $($_.Exception.Message)" "ERROR"
    }

    # The comment lands verbatim in Windows System event 1074. The MWST-WATCHDOG
    # prefix identifies the reboot as ours rather than an update or a person,
    # and id=<short> ties that event back to the ledger row above. 1074 is
    # written by Windows itself, so this record survives even if this entire
    # folder is deleted or the machine is reimaged.
    $comment = "MWST-WATCHDOG $Kind id=$shortId - $reason"
    if ($comment.Length -gt 500) { $comment = $comment.Substring(0, 500) }

    Write-Log "Triggering restart ($Kind). Event $eventId. $reason" "ERROR"

    try {
        # Output is captured so it cannot leak into this function's return
        # value, and so a refusal ("a shutdown is already scheduled") ends up
        # in the RESTART_FAILED row below.
        $shutdownOutput = & shutdown.exe /r /t $RestartDelaySeconds /f /c $comment 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            throw ("shutdown.exe exited with code {0}: {1}" -f $LASTEXITCODE, $shutdownOutput.Trim())
        }
    }
    catch {
        Write-EventRow -EventType "RESTART_FAILED" -Severity "CRITICAL" -Outcome "FAILED" `
            -Detail ("Kind={0}; TriggerEventId={1}; shutdown.exe could not be invoked: {2}" -f $Kind, $eventId, $_.Exception.Message) -Durable | Out-Null
        Write-Log "shutdown.exe failed: $($_.Exception.Message)" "ERROR"
        Remove-Item -LiteralPath $PendingPath -Force -ErrorAction SilentlyContinue
        return $false
    }

    return $true
}


# ---------------------------------------------------------------------------
# Screen sampling
# ---------------------------------------------------------------------------
function Get-WhitePercent {
    <#
        Returns the percentage of sampled pixels that are white, or $null if
        the screen could not be read this cycle.

        Samples the same grid as before (every $SampleStep-th pixel in both
        axes) but reads it through LockBits and one Marshal.Copy instead of
        thousands of GetPixel calls. Same pixels, same answer, a fraction of
        the CPU - which matters on a kiosk that is also driving a dashboard.
    #>
    $bitmap   = $null
    $graphics = $null
    $data     = $null

    try {
        $primaryScreen = [Windows.Forms.Screen]::PrimaryScreen
        if ($null -eq $primaryScreen) {
            return [pscustomobject]@{ Percent = $null; Error = "PrimaryScreen is null - no interactive desktop session." }
        }

        $screen = $primaryScreen.Bounds
        if ($screen.Width -le 0 -or $screen.Height -le 0) {
            return [pscustomobject]@{ Percent = $null; Error = "Screen bounds are zero-sized." }
        }

        $bitmap   = New-Object Drawing.Bitmap $screen.Width, $screen.Height
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($screen.Location, [Drawing.Point]::Empty, $screen.Size)

        $rect = New-Object Drawing.Rectangle 0, 0, $bitmap.Width, $bitmap.Height
        $data = $bitmap.LockBits($rect, [Drawing.Imaging.ImageLockMode]::ReadOnly, [Drawing.Imaging.PixelFormat]::Format32bppArgb)

        $stride = $data.Stride
        $bytes  = New-Object byte[] ($stride * $bitmap.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)

        $white = 0
        $total = 0

        for ($y = 0; $y -lt $bitmap.Height; $y += $SampleStep) {
            $rowStart = $y * $stride
            for ($x = 0; $x -lt $bitmap.Width; $x += $SampleStep) {
                # Format32bppArgb is little-endian BGRA in memory.
                $i = $rowStart + ($x * 4)
                $total++
                if ($bytes[$i]     -gt $WhiteLimit -and
                    $bytes[$i + 1] -gt $WhiteLimit -and
                    $bytes[$i + 2] -gt $WhiteLimit) {
                    $white++
                }
            }
        }

        if ($total -eq 0) {
            return [pscustomobject]@{ Percent = $null; Error = "No pixels sampled." }
        }

        return [pscustomobject]@{ Percent = (($white / $total) * 100); Error = $null }
    }
    catch {
        return [pscustomobject]@{ Percent = $null; Error = $_.Exception.Message }
    }
    finally {
        if ($data -and $bitmap) { try { $bitmap.UnlockBits($data) } catch {} }
        if ($graphics) { $graphics.Dispose() }
        if ($bitmap)   { $bitmap.Dispose() }
    }
}


# ---------------------------------------------------------------------------
# Windows System log -> ledger
#
# The collector cannot read these kiosks' event logs across the network, so
# the kiosk copies the records out itself. They go into the same ledger as
# everything else and travel over the admin share the collector already uses.
#
# Records are copied VERBATIM - id, provider, record number, properties - and
# are not interpreted here. The collector classifies them with exactly the
# same code it uses for a record read remotely, so a reboot collected either
# way ends up as the same row with the same EventId, and collecting it both
# ways cannot double-count it.
# ---------------------------------------------------------------------------
function Get-EvtScanState {
    if (-not (Test-Path -LiteralPath $EvtStatePath)) { return $null }
    try { return (Get-Content -LiteralPath $EvtStatePath -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { return $null }
}

function Set-EvtScanState {
    param([long]$LastRecordId, [datetime]$ScannedUtc)
    try {
        ([pscustomobject]@{ LastRecordId = $LastRecordId; ScannedUtc = (Format-Utc $ScannedUtc) } | ConvertTo-Json -Compress) |
            Set-Content -LiteralPath $EvtStatePath -Encoding UTF8 -ErrorAction Stop
    }
    catch { Write-Log "Could not save the event-log scan position: $($_.Exception.Message)" "WARN" }
}

function Write-WinEventRow {
    param([Parameter(Mandatory)]$Record)

    $props = @()
    foreach ($p in $Record.Properties) {
        $v = [string]$p.Value
        if ($v.Length -gt 400) { $v = $v.Substring(0, 400) }
        $props += $v
    }

    $msg = ""
    if ($Record.Message) {
        $msg = ($Record.Message -replace '\s+', ' ').Trim()
        if ($msg.Length -gt 300) { $msg = $msg.Substring(0, 300) }
    }

    $payload = [pscustomobject]@{
        Id       = [int]$Record.Id
        Provider = [string]$Record.ProviderName
        RecordId = [long]$Record.RecordId
        Props    = $props
        Msg      = $msg
    } | ConvertTo-Json -Compress

    $utc = $Record.TimeCreated.ToUniversalTime()

    # Same EventId the collector would give this record if it had read the log
    # remotely, so the two routes can never produce two rows for one event.
    Write-EventRow -EventId ("EVT-{0}-{1}-{2}" -f $HostName.ToUpperInvariant(), $Record.RecordId, $utc.ToString("yyyyMMddHHmmss", $Inv)) `
        -EventType "WINEVENT" -Severity "INFO" -EventTime $utc -OmitBootTime -Detail $payload | Out-Null
}

function Copy-SystemLogToLedger {
    param([switch]$Startup)

    $state = Get-EvtScanState
    $lastRecordId = 0

    # First scan on this kiosk: the short backfill window, because anything
    # older than the upgrade is discarded by the collector anyway.
    $since = (Get-Date).AddDays(-$EventBackfillDays)

    if ($state) {
        try { $lastRecordId = [long]$state.LastRecordId } catch { $lastRecordId = 0 }
        try {
            # Every later scan reaches back to the last one, however long ago
            # that was - a kiosk switched off for a fortnight must not come
            # back with a fortnight-shaped hole in its history. (Taking the
            # later of this and the backfill window would do exactly that.)
            # The extra day covers a record written while the previous scan
            # was running; record numbers stop anything being copied twice.
            $stateTime = [datetime]::Parse($state.ScannedUtc, $Inv, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $since = $stateTime.ToLocalTime().AddDays(-1)
        }
        catch {}
    }

    $records = @()
    try {
        $records = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = $WatchedEventIds; StartTime = $since } -ErrorAction Stop)
    }
    catch {
        if ($_.FullyQualifiedErrorId -notlike 'NoMatchingEventsFound*') {
            Write-Log "Could not read the local System log: $($_.Exception.Message)" "ERROR"
            if ($Startup) {
                Write-EventRow -EventType "AGENT_ERROR" -Severity "WARNING" `
                    -Detail ("Local System log could not be read, so reboots by anything other than this watchdog cannot be reported: {0}" -f $_.Exception.Message) | Out-Null
            }
            return 0
        }
    }

    if ($records.Count -eq 0) {
        Set-EvtScanState -LastRecordId $lastRecordId -ScannedUtc (Get-Date).ToUniversalTime()
        return 0
    }

    $maxRecordId = [long](($records | Measure-Object -Property RecordId -Maximum).Maximum)
    if ($maxRecordId -lt $lastRecordId) {
        # Numbering restarted, so the log was cleared. Take everything again;
        # the collector drops whatever it already has.
        Write-Log "System log looks cleared (highest record $maxRecordId is below the last one seen, $lastRecordId). Re-reading it." "WARN"
        $lastRecordId = 0
    }

    $written = 0
    foreach ($rec in ($records | Sort-Object RecordId)) {
        if ($rec.RecordId -le $lastRecordId) { continue }
        Write-WinEventRow -Record $rec
        $written++
    }

    Set-EvtScanState -LastRecordId $maxRecordId -ScannedUtc (Get-Date).ToUniversalTime()
    if ($written -gt 0) { Write-Log "Copied $written Windows reboot record(s) into the ledger." }
    return $written
}


# ---------------------------------------------------------------------------
# Episode helpers
#
# An episode is one unbroken run of over- or under-threshold checks. It opens
# on the first bad check and closes when the screen recovers or the machine is
# rebooted, so one white-screen incident is one pair of rows in the ledger
# rather than a dozen near-identical ones.
# ---------------------------------------------------------------------------
function Close-WhiteEpisode {
    param([string]$Outcome, [double]$Percent)
    if (-not $script:WhiteEpisodeId) { return }
    $seconds = ((Get-Date) - $script:WhiteEpisodeStart).TotalSeconds
    Write-EventRow -EventType "WHITE_EPISODE_END" -Severity "WARNING" -Outcome $Outcome `
        -WhitePercent $Percent -StreakChecks $script:FailedChecks -DurationSeconds $seconds `
        -Detail ("EpisodeId={0}; peak {1:N1}% white" -f $script:WhiteEpisodeId, $script:WhiteEpisodePeak) | Out-Null
    $script:WhiteEpisodeId = $null
}

function Close-LowEpisode {
    param([string]$Outcome, [double]$Percent)
    if (-not $script:LowEpisodeId) { return }
    $seconds = ((Get-Date) - $script:LowEpisodeStart).TotalSeconds
    Write-EventRow -EventType "LOWWHITE_EPISODE_END" -Severity "WARNING" -Outcome $Outcome `
        -WhitePercent $Percent -StreakChecks $script:LowWhiteFailedChecks -DurationSeconds $seconds `
        -Detail ("EpisodeId={0}; trough {1:N1}% white" -f $script:LowEpisodeId, $script:LowEpisodeTrough) | Out-Null
    $script:LowEpisodeId = $null
}


# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
$script:BootTimeUtc = Get-BootTimeUtc

Write-Log "Watchdog v$AgentVersion started. WhiteLimit=$WhiteLimit HighThreshold=$WhiteHighThreshold% (need $WhiteChecksNeeded) LowThreshold=$WhiteLowThreshold% (need $LowWhiteChecksNeeded) IntervalSeconds=$CheckIntervalSeconds"
Write-Log "Log file: $LogPath"
Write-Log "Event ledger: $EventCsvPath"

# Answer the previous run's outstanding question before opening a new chapter.
Resolve-PendingRestart

Write-EventRow -EventType "AGENT_START" -Severity "INFO" `
    -Detail ("Watchdog v{0} started. Interval={1}s, WhiteHigh={2}%/{3} checks, WhiteLow={4}%/{5} checks, PS={6}" -f `
             $AgentVersion, $CheckIntervalSeconds, $WhiteHighThreshold, $WhiteChecksNeeded, `
             $WhiteLowThreshold, $LowWhiteChecksNeeded, $PSVersionTable.PSVersion.ToString()) | Out-Null

# Copy Windows' own reboot records into the ledger. Done at startup so that
# the reboot which just happened - whoever caused it - is recorded straight
# away, and then periodically while the kiosk stays up.
$script:LastEventScan = Get-Date
Copy-SystemLogToLedger -Startup | Out-Null

$script:FailedChecks         = 0
$script:LowWhiteFailedChecks = 0
$CheckCount                  = 0
$ConsecutiveErrors           = 0

$script:WhiteEpisodeId    = $null
$script:WhiteEpisodeStart = $null
$script:WhiteEpisodePeak  = 0.0
$script:LowEpisodeId      = $null
$script:LowEpisodeStart   = $null
$script:LowEpisodeTrough  = 100.0

# The loop never ends by itself. It is left either by an unexpected error
# (catch) or by being stopped - Ctrl+C, the console closing, Windows shutting
# down - which runs only the finally block.
$ExitReason = "Watchdog stopped (console closed, Ctrl+C, or Windows shutting down)."
$script:RestartRequested = $false
$script:StopRecorded     = $false


# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
try {
    while ($true) {
        $CheckCount++

        if (((Get-Date) - $script:LastEventScan).TotalMinutes -ge $EventScanIntervalMinutes) {
            Copy-SystemLogToLedger | Out-Null
            $script:LastEventScan = Get-Date
        }

        $sample = Get-WhitePercent

        if ($null -eq $sample.Percent) {
            $ConsecutiveErrors++
            Write-Log "Screen check failed: $($sample.Error)" "ERROR"

            # One failure is noise; a run of them means the session is gone and
            # is worth a row in the ledger. It must never itself reboot the
            # machine - a watchdog that reboots when it cannot see is worse
            # than one that waits.
            if ($ConsecutiveErrors -eq 6) {
                Write-EventRow -EventType "AGENT_ERROR" -Severity "WARNING" `
                    -StreakChecks $ConsecutiveErrors `
                    -Detail ("Screen could not be sampled {0} times in a row: {1}" -f $ConsecutiveErrors, $sample.Error) | Out-Null
            }

            Start-Sleep -Seconds $CheckIntervalSeconds
            continue
        }

        if ($ConsecutiveErrors -ge 6) {
            Write-EventRow -EventType "AGENT_RECOVERED" -Severity "INFO" `
                -WhitePercent $sample.Percent -StreakChecks $ConsecutiveErrors `
                -Detail ("Screen sampling recovered after {0} consecutive failures." -f $ConsecutiveErrors) | Out-Null
        }
        $ConsecutiveErrors = 0

        $whitePercent = [double]$sample.Percent

        if ($whitePercent -ge $WhiteHighThreshold) {
            if ($script:LowEpisodeId) {
                Close-LowEpisode -Outcome "RECOVERED" -Percent $whitePercent
                $script:LowWhiteFailedChecks = 0
            }

            if ($script:FailedChecks -eq 0) {
                $script:WhiteEpisodeId    = [guid]::NewGuid().ToString()
                $script:WhiteEpisodeStart = Get-Date
                $script:WhiteEpisodePeak  = $whitePercent
                Write-EventRow -EventType "WHITE_EPISODE_START" -Severity "WARNING" `
                    -WhitePercent $whitePercent -StreakChecks 1 `
                    -Detail ("EpisodeId={0}; screen reached {1:N1}% white (threshold {2}%)" -f $script:WhiteEpisodeId, $whitePercent, $WhiteHighThreshold) | Out-Null
            }

            $script:FailedChecks++
            if ($whitePercent -gt $script:WhiteEpisodePeak) { $script:WhiteEpisodePeak = $whitePercent }
            Write-Log ("White screen detected: {0:N1}% white ({1}/{2})" -f $whitePercent, $script:FailedChecks, $WhiteChecksNeeded) "WARN"
        }
        elseif ($whitePercent -lt $WhiteLowThreshold) {
            if ($script:WhiteEpisodeId) {
                Close-WhiteEpisode -Outcome "RECOVERED" -Percent $whitePercent
                $script:FailedChecks = 0
            }

            if ($script:LowWhiteFailedChecks -eq 0) {
                $script:LowEpisodeId     = [guid]::NewGuid().ToString()
                $script:LowEpisodeStart  = Get-Date
                $script:LowEpisodeTrough = $whitePercent
                Write-EventRow -EventType "LOWWHITE_EPISODE_START" -Severity "WARNING" `
                    -WhitePercent $whitePercent -StreakChecks 1 `
                    -Detail ("EpisodeId={0}; screen fell to {1:N1}% white (threshold {2}%)" -f $script:LowEpisodeId, $whitePercent, $WhiteLowThreshold) | Out-Null
            }

            $script:LowWhiteFailedChecks++
            if ($whitePercent -lt $script:LowEpisodeTrough) { $script:LowEpisodeTrough = $whitePercent }
            Write-Log ("Low-white screen detected: {0:N1}% white ({1}/{2})" -f $whitePercent, $script:LowWhiteFailedChecks, $LowWhiteChecksNeeded) "WARN"
        }
        else {
            if ($script:WhiteEpisodeId -or $script:LowEpisodeId) {
                Write-Log ("Screen recovered: {0:N1}% white. Resetting failed-check counters." -f $whitePercent)
                Close-WhiteEpisode -Outcome "RECOVERED" -Percent $whitePercent
                Close-LowEpisode   -Outcome "RECOVERED" -Percent $whitePercent
            }
            elseif (($CheckCount % $HeartbeatEveryNChecks) -eq 0) {
                # Heartbeats stay in mwst.log only. The collector reads the
                # log's last-write time for liveness, so putting a row in the
                # ledger every few minutes would bloat it for no gain.
                Write-Log ("Heartbeat: watchdog alive, screen normal ({0:N1}% white)." -f $whitePercent)
            }

            $script:FailedChecks         = 0
            $script:LowWhiteFailedChecks = 0
        }

        $restartKind = $null
        if ($script:FailedChecks -ge $WhiteChecksNeeded) {
            $restartKind    = "WHITE"
            $episodeSeconds = ((Get-Date) - $script:WhiteEpisodeStart).TotalSeconds
            $episodeId      = $script:WhiteEpisodeId
            $streak         = $script:FailedChecks
            Close-WhiteEpisode -Outcome "REBOOT" -Percent $whitePercent
        }
        elseif ($script:LowWhiteFailedChecks -ge $LowWhiteChecksNeeded) {
            $restartKind    = "LOWWHITE"
            $episodeSeconds = ((Get-Date) - $script:LowEpisodeStart).TotalSeconds
            $episodeId      = $script:LowEpisodeId
            $streak         = $script:LowWhiteFailedChecks
            Close-LowEpisode -Outcome "REBOOT" -Percent $whitePercent
        }

        if ($restartKind) {
            $script:RestartRequested = [bool](Invoke-WatchdogRestart -Kind $restartKind -StreakChecks $streak -WhitePercent $whitePercent `
                                                                     -EpisodeSeconds $episodeSeconds -EpisodeId $episodeId)
            if ($script:RestartRequested) {
                # Normally the machine is gone within $RestartDelaySeconds and
                # nothing below ever runs. Still being here ten minutes later
                # means the reboot was cancelled or blocked: record that now,
                # rather than whenever the watchdog next starts, and carry on
                # watching. If the screen is still bad, the next episode asks
                # again.
                Start-Sleep -Seconds 610
                Resolve-PendingRestart
                $script:RestartRequested = $false
            }
            $script:FailedChecks         = 0
            $script:LowWhiteFailedChecks = 0
        }

        Start-Sleep -Seconds $CheckIntervalSeconds
    }
}
catch {
    $ExitReason = "Watchdog terminated unexpectedly: $($_.Exception.Message)"
    Write-Log $ExitReason "ERROR"
    try { Write-EventRow -EventType "AGENT_STOP" -Severity "CRITICAL" -Detail $ExitReason -Durable | Out-Null } catch {}
    $script:StopRecorded = $true
    throw
}
finally {
    if ($script:RestartRequested) { $ExitReason = "Watchdog stopped by the reboot it requested." }
    Write-Log "Watchdog loop exited. $ExitReason"
    if (-not $script:StopRecorded) {
        try { Write-EventRow -EventType "AGENT_STOP" -Severity "INFO" -Detail $ExitReason -Durable | Out-Null } catch {}
    }
}
