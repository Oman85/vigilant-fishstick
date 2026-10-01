#Requires -Version 5.1
<#
.SYNOPSIS
    MWST kiosk white-screen watchdog, V7.0.

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

    New in V7.0: a loop guard. A kiosk whose screen is bad again straight
    after every restart - V6.1 restarted ROLL003 ten times in an hour
    because its screen read black the moment the watchdog started (it was
    photographing its own console window; see below) - is restarted twice,
    and then left alone:

      - A restart only counts as having helped once the screen has read
        normal for $LoopGuardHealthyChecks checks in a row (five minutes).
        A single good reading proves nothing: a page flashing past during
        boot would reset the count and the loop would never end.

      - After $LoopGuardMaxRestarts restarts in a row that did not help, the
        guard holds. The watchdog keeps watching and logging but does not
        restart, and records LOOP_GUARD_ENGAGED once, which the collector
        turns into a LOOP_GUARD status: a kiosk whose watchdog has given up
        must not look healthy just because its log is fresh.

      - While holding, one more restart is allowed every
        $LoopGuardRetryMinutes, in case whatever broke the screen has since
        cleared (a network outage, say). If it helps, the guard is released
        like any other.

      - Once the screen has been normal for $LoopGuardHealthyChecks checks,
        LOOP_GUARD_RELEASED is recorded and the count starts again from zero.

    The count lives in mwst_loopguard.json, written through the disk cache
    before shutdown.exe is called, like the pending-restart marker. Deleting
    it resets the guard by hand; the release is still recorded once the
    screen is normal, because the ledger remembers the hold.

    Also new in V7.0: messages from the dashboard. The dashboard drops a
    message file into mwst_inbox over the admin share; the watchdog shows it
    on the kiosk in a large window with an OK button and a countdown, and
    records MESSAGE_SHOWN and MESSAGE_CLOSED (OK pressed, or timed out). The
    watchdog is the only process IT runs inside the kiosk's desktop session,
    which is why it is the one that does this - nothing started remotely can
    put a window on that screen here. Screen checks pause while a message is
    up, because the window is part of what they photograph.

    Also new in V7.0: the watchdog's own console window stays off the screen.
    The screen checks photograph whatever is on the display, and on ROLL003
    that was the watchdog's console - black, full width, on top of a Mach2
    dashboard that was working - so every check read under 1% white and the
    kiosk was restarted over and over. The launcher hides the window before
    the kiosk app comes up. The watchdog hides it again at startup, in case
    an older launcher left it up, and before every check, in case something
    brought it back. AGENT_START records the result as Window=.

    The ledger is append-only and is never overwritten in place. It rolls over
    to mwst_events_<timestamp>.csv only when it exceeds MaxEventCsvBytes; the
    collector reads every mwst_events*.csv it finds, so a rollover loses
    nothing.

.NOTES
    Deployed to C:\Users\Public\Documents\mwstv4.ps1 and started by
    MWSTv6_Launcher.bat, which the "MWST v6.1" logon task runs (older kiosks:
    MWSTv5_Launcher.bat). The file name and path are deliberately unchanged
    so no launcher has to change to find it - despite the "v4" in its name,
    this is V7.0. V6.1 is kept as Agent\archive\mwstv4_v6.1.ps1.
#>

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$AgentVersion = "7.0"

# --- Detection configuration (unchanged thresholds) ---
$WhiteLimit            = 235   # per-channel value above which a pixel counts as "white"
$WhiteChecksNeeded     = 12    # consecutive over-threshold checks before rebooting
$WhiteHighThreshold    = 85    # trigger when the screen is AT LEAST this % white
$WhiteLowThreshold     = 10    # trigger when the screen is BELOW this % white
$LowWhiteChecksNeeded  = 12
$CheckIntervalSeconds  = 10
$SampleStep            = 20    # sample every Nth pixel in both axes
$HeartbeatEveryNChecks = 20

# --- Loop guard ---
$LoopGuardMaxRestarts   = 2     # restarts in a row that did not help before the guard holds
$LoopGuardWindowMinutes = 60    # ...counted as "in a row" only this close together
$LoopGuardHealthyChecks = 30    # normal checks in a row that prove a restart helped (5 min)
$LoopGuardRetryMinutes  = 120   # while holding, one more restart at most this often; 0 = never

# --- Messages from the dashboard ---
$MessageMaxSeconds = 900        # longest a message may stay on screen
$MessageMaxChars   = 1000

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
$LoopStatePath = Join-Path $ScriptFolder "mwst_loopguard.json"
$InboxPath     = Join-Path $ScriptFolder "mwst_inbox"

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


# ---------------------------------------------------------------------------
# Loop guard
#
# $script:LoopState.Restarts     UTC times of restarts in a row that have not
#                                (yet) been followed by a healthy screen
# $script:LoopState.HoldReported LOOP_GUARD_ENGAGED is in the ledger with no
#                                LOOP_GUARD_RELEASED after it
# ---------------------------------------------------------------------------
function Read-LoopGuardState {
    $state = [pscustomobject]@{ Restarts = @(); HoldReported = $false }
    if (-not (Test-Path -LiteralPath $LoopStatePath)) { return $state }

    # Retried for the same reason as the pending-restart marker: antivirus is
    # busiest just after boot, and a count lost to a momentary lock is a loop
    # that gets two more restarts than it should.
    $raw = $null
    for ($attempt = 1; $attempt -le 5 -and $null -eq $raw; $attempt++) {
        try { $raw = Get-Content -LiteralPath $LoopStatePath -Raw -ErrorAction Stop }
        catch [System.IO.IOException] { Start-Sleep -Milliseconds (400 * $attempt) }
        catch { break }
    }

    try {
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        $state.HoldReported = [bool]$data.HoldReported
        $state.Restarts = @($data.Restarts | ForEach-Object {
            # Windows PowerShell leaves these as strings; newer versions
            # convert ISO dates on their own.
            if ($_ -is [datetime]) { $_.ToUniversalTime() }
            else { try { [datetime]::Parse([string]$_, $Inv, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch {} }
        } | Where-Object { $_ } | Sort-Object)
    }
    catch {
        Write-Log "Loop-guard state could not be read, starting the count from zero: $($_.Exception.Message)" "WARN"
    }
    return $state
}

function Save-LoopGuardState {
    # Flushed through the disk cache: the count is what stops the next boot
    # from restarting again, so it has to survive the restart it precedes.
    # An empty state is a deleted file, not a file saying "nothing".
    try {
        if ($script:LoopState.Restarts.Count -eq 0 -and -not $script:LoopState.HoldReported) {
            Remove-Item -LiteralPath $LoopStatePath -Force -ErrorAction SilentlyContinue
            return
        }

        $json = [pscustomobject]@{
            HoldReported = $script:LoopState.HoldReported
            Restarts     = @($script:LoopState.Restarts | ForEach-Object { Format-Utc $_ })
        } | ConvertTo-Json -Compress

        $fs = New-Object System.IO.FileStream($LoopStatePath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        try {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $fs.Write($bytes, 0, $bytes.Length)
            $fs.Flush($true)
        }
        finally { $fs.Dispose() }
    }
    catch {
        Write-Log "Could not save the loop-guard state: $($_.Exception.Message)" "ERROR"
    }
}

function Test-LedgerHoldOpen {
    <#
        Whether the ledger's last loop-guard row is LOOP_GUARD_ENGAGED. Only
        asked when the state file is missing - usually because someone deleted
        it to reset the guard - so that the release is still recorded once the
        screen is healthy, and the collector stops showing a hold that is no
        longer there.

        Matches the quoted EventType field. Inside a quoted Detail the quotes
        would be doubled, so a Detail mentioning the name cannot match.
    #>
    if (-not (Test-Path -LiteralPath $EventCsvPath)) { return $false }
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = New-Object System.IO.FileStream($EventCsvPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            [void]$fs.Seek([math]::Max([long]0, $fs.Length - 262144), [System.IO.SeekOrigin]::Begin)
            $text = (New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)).ReadToEnd()
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
        What to do about a screen that has been bad for long enough to restart:

          Allow  fewer than $LoopGuardMaxRestarts unhelpful restarts in a row
          Retry  the guard is holding, but $LoopGuardRetryMinutes have passed
                 since the last restart - one more attempt
          Hold   do not restart

        Restarts is the run of restarts that counts, for the caller to extend.
    #>
    param([Parameter(Mandatory)][datetime]$NowUtc)

    $restarts = @($script:LoopState.Restarts)
    $last = if ($restarts.Count -gt 0) { $restarts[-1] } else { $null }

    # Before the guard holds, restarts far apart are not a loop - a kiosk off
    # overnight between two of them is not stuck. Once it holds, only a
    # healthy screen or the retry timer ends it; time alone does not.
    if ($restarts.Count -lt $LoopGuardMaxRestarts -and $last -and ($NowUtc - $last).TotalMinutes -gt $LoopGuardWindowMinutes) {
        $restarts = @()
        $last = $null
    }

    $decision = [pscustomobject]@{
        Action       = 'Allow'
        Restarts     = $restarts
        Since        = $(if ($restarts.Count -gt 0) { $restarts[0] } else { $null })
        NextRetryUtc = $null
    }
    if ($restarts.Count -lt $LoopGuardMaxRestarts) { return $decision }

    if ($LoopGuardRetryMinutes -gt 0) { $decision.NextRetryUtc = $last.AddMinutes($LoopGuardRetryMinutes) }
    $decision.Action = if ($decision.NextRetryUtc -and $NowUtc -ge $decision.NextRetryUtc) { 'Retry' } else { 'Hold' }
    return $decision
}

function Write-LoopGuardHold {
    param([Parameter(Mandatory)]$Decision, [string]$Kind, [double]$WhitePercent, [int]$StreakChecks)

    $retry = if ($Decision.NextRetryUtc) { "next attempt after {0}" -f (Format-Utc $Decision.NextRetryUtc) } else { 'no automatic retry' }
    $text = ("Kind={0}; {1} restart(s) since {2} did not fix the screen, so the watchdog is not restarting the kiosk again; {3}. Released once the screen is normal for {4} checks in a row." -f `
             $Kind, $Decision.Restarts.Count, (Format-Utc $Decision.Since), $retry, $LoopGuardHealthyChecks)

    Write-EventRow -EventType "LOOP_GUARD_ENGAGED" -Severity "CRITICAL" -Outcome "HOLD" `
        -WhitePercent $WhitePercent -StreakChecks $StreakChecks -Detail $text -Durable | Out-Null
    Write-Log "Loop guard engaged. $text" "ERROR"
}

function Reset-LoopGuard {
    # Called once the screen has been normal for $LoopGuardHealthyChecks
    # checks: whatever restarts came before, they worked.
    param([double]$WhitePercent)

    if ($script:LoopState.Restarts.Count -eq 0 -and -not $script:LoopState.HoldReported) { return }

    if ($script:LoopState.HoldReported) {
        Write-EventRow -EventType "LOOP_GUARD_RELEASED" -Severity "INFO" -Outcome "RECOVERED" `
            -WhitePercent $WhitePercent -StreakChecks $LoopGuardHealthyChecks `
            -Detail ("Screen normal for {0} checks in a row after {1} unhelpful restart(s); the watchdog restarts the kiosk again if the screen goes bad." -f `
                     $LoopGuardHealthyChecks, $script:LoopState.Restarts.Count) -Durable | Out-Null
        Write-Log "Loop guard released: the screen has been normal for $LoopGuardHealthyChecks checks." "WARN"
    }
    else {
        Write-Log ("The last restart helped: screen normal for {0} checks. Loop-guard count cleared." -f $LoopGuardHealthyChecks)
    }

    $script:LoopState.Restarts     = @()
    $script:LoopState.HoldReported = $false
    Save-LoopGuardState
}

function Undo-LoopGuardRestart {
    # A restart that never happened - shutdown.exe refused, or the kiosk was
    # still up ten minutes later - is not part of a loop.
    $restarts = @($script:LoopState.Restarts)
    if ($restarts.Count -eq 0) { return }
    $script:LoopState.Restarts = @($restarts | Select-Object -First ($restarts.Count - 1))
    Save-LoopGuardState
}


function Invoke-WatchdogRestart {
    <#
        The one path that reboots the kiosk. Order matters and is deliberate:
        ledger row first (flushed to disk), then the marker, then shutdown.
        Everything that has to survive the reboot is on disk before anything
        is asked to happen. The loop-guard count is saved by the caller,
        before this is called.
    #>
    param(
        [Parameter(Mandatory)][string]$Kind,       # WHITE | LOWWHITE
        [Parameter(Mandatory)][int]$StreakChecks,
        [Parameter(Mandatory)][double]$WhitePercent,
        [Parameter(Mandatory)][double]$EpisodeSeconds,
        [string]$EpisodeId,
        [string]$Note
    )

    $eventId = [guid]::NewGuid().ToString()
    $shortId = $eventId.Substring(0, 8)

    $reason = if ($Kind -eq "WHITE") {
        "screen at least $WhiteHighThreshold% white for $StreakChecks consecutive checks"
    } else {
        "screen below $WhiteLowThreshold% white for $StreakChecks consecutive checks"
    }

    # The Detail must keep starting with "<Kind>:" - the collector reads the
    # trigger kind from there. The loop-guard note goes at the end.
    $detail = "{0}: {1}. EpisodeId={2}" -f $Kind, $reason, $EpisodeId
    if ($Note) { $detail += "; $Note" }

    Write-EventRow -EventId $eventId -EventType "RESTART_TRIGGERED" -Severity "CRITICAL" -Outcome "REBOOT" `
        -WhitePercent $WhitePercent -StreakChecks $StreakChecks -DurationSeconds $EpisodeSeconds `
        -Detail $detail -Durable | Out-Null

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

    Write-Log "Triggering restart ($Kind). Event $eventId. $reason$(if ($Note) { ". $Note" })" "ERROR"

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


function Get-ConsoleHostKind {
    <#
        Which kind of window this watchdog's console is in, as seen from
        inside it. It is the only reliable place to ask: the launcher is
        started through conhost.exe precisely to keep it in the classic
        console, and whether that worked cannot be told from outside.

          conhost        a real window of class ConsoleWindowClass
          pseudoconsole  a hidden stand-in of class PseudoConsoleWindow - the
                         console belongs to Windows Terminal or another
                         terminal application
          none           no console at all
    #>
    try {
        if (-not ([System.Management.Automation.PSTypeName]'MwstConsoleProbe').Type) {
            Add-Type -Namespace '' -Name MwstConsoleProbe -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@ -ErrorAction Stop
        }
        $hwnd = [MwstConsoleProbe]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return 'none' }

        $name = New-Object System.Text.StringBuilder 256
        [void][MwstConsoleProbe]::GetClassName($hwnd, $name, $name.Capacity)
        switch ($name.ToString()) {
            'ConsoleWindowClass'  { return 'conhost' }
            'PseudoConsoleWindow' { return 'pseudoconsole' }
            default               { return 'other:' + ($name.ToString() -replace '[\s,;]', '_') }
        }
    }
    catch { return 'unknown' }
}

function Hide-ConsoleWindow {
    <#
        Takes this watchdog's console window off the screen if it is on it,
        and returns $true only when it had to - the launcher normally hides
        the window before the watchdog starts.

        A visible console is not just in the way of the kiosk app: it is part
        of what Get-WhitePercent photographs, so a black console over a
        working dashboard reads as a black screen.

        Only a classic console window can be hidden from in here. Under
        Windows Terminal the handle is a stand-in that is never visible, and
        the real window belongs to another process.
    #>
    if ($script:ConsoleHost -ne 'conhost') { return $false }
    try {
        $hwnd = [MwstConsoleProbe]::GetConsoleWindow()
        if ($hwnd -eq [IntPtr]::Zero -or -not [MwstConsoleProbe]::IsWindowVisible($hwnd)) { return $false }
        [void][MwstConsoleProbe]::ShowWindow($hwnd, 0)   # SW_HIDE
        return $true
    }
    catch { return $false }
}


# ---------------------------------------------------------------------------
# Messages from the dashboard
#
# The dashboard writes msg_<time>_<id>.json into mwst_inbox over the admin
# share (under a temporary name first, then renamed, so a half-written file
# is never picked up). The file is removed as soon as it is taken, so the
# dashboard can tell "picked up" from "still waiting". INTERACTIVE has
# Modify on everything under Public\Documents, which is what lets the kiosk
# account remove a file the admin account wrote.
#
# The window is a separate powershell.exe sharing this console, so the
# watchdog keeps running while it is up, and no new console is opened for
# Windows to hand to Windows Terminal.
# ---------------------------------------------------------------------------
$script:MessageProc     = $null
$script:MessageShown    = $null
$script:MessageDeadline = $null
$script:MessageFile     = Join-Path $InboxPath "showing.json"

function ConvertTo-LedgerText {
    # Message text on one line and shortened, for the ledger's Detail.
    param([string]$Text, [int]$Max = 200)
    $t = ($Text -replace '\s+', ' ').Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max - 3) + '...' }
    return $t
}

function Read-InboxMessage {
    <#
        The oldest message that can be shown, or $null. Unreadable and expired
        ones are removed on the way, each with a ledger row, so the dashboard
        learns what became of them.
    #>
    if (-not (Test-Path -LiteralPath $InboxPath)) { return $null }

    foreach ($file in @(Get-ChildItem -LiteralPath $InboxPath -Filter 'msg_*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)) {
        $raw = $null
        try { $raw = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8) }
        catch [System.IO.IOException] { continue }   # locked for a moment: next check
        catch { $raw = $null }

        $msg = $null
        if ($raw) { try { $msg = $raw | ConvertFrom-Json -ErrorAction Stop } catch {} }
        $id = if ($msg -and $msg.Id) { [string]$msg.Id } else { $file.BaseName }

        $problem = $null
        if (-not $msg -or [string]::IsNullOrWhiteSpace([string]$msg.Text)) {
            $problem = @('MESSAGE_REJECTED', 'REJECTED', "unreadable or empty message file $($file.Name)")
        }
        else {
            $expires = $null
            try { $expires = [datetime]::Parse([string]$msg.ExpiresUtc, $Inv, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() } catch {}
            if ($expires -and (Get-Date).ToUniversalTime() -gt $expires) {
                $problem = @('MESSAGE_EXPIRED', 'EXPIRED', "not shown: it expired at $(Format-Utc $expires) before this watchdog saw it")
            }
        }

        if ($problem) {
            try { Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop } catch { continue }
            Write-EventRow -EventType $problem[0] -Severity "WARNING" -Outcome $problem[1] -Detail ("MessageId={0}; {1}" -f $id, $problem[2]) | Out-Null
            Write-Log ("Message {0} dropped: {1}." -f $id, $problem[2]) "WARN"
            continue
        }

        $seconds = 60
        if ($msg.Seconds) { try { $seconds = [int]$msg.Seconds } catch {} }
        $seconds = [math]::Max(5, [math]::Min($MessageMaxSeconds, $seconds))

        $text  = [string]$msg.Text
        if ($text.Length -gt $MessageMaxChars) { $text = $text.Substring(0, $MessageMaxChars) }
        $title = if ($msg.Title) { [string]$msg.Title } else { 'Message from IT' }
        if ($title.Length -gt 80) { $title = $title.Substring(0, 80) }

        return [pscustomobject]@{
            Id = $id; Title = $title; Text = $text; Seconds = $seconds
            From = [string]$msg.From; File = $file.FullName; StartedAt = $null
        }
    }
    return $null
}

function Get-MessageWindowScript {
    # Runs in its own powershell.exe. Exit code: 0 OK pressed, 2 timed out,
    # 1 failed. __MESSAGE_FILE__ is replaced with the path it reads.
    return @'
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

    # Docking is laid out from the last control added, so Fill goes in first.
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
        # The largest font the text fits at.
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

    # The window reads its text from a file, not from the command line:
    # nothing to quote, and no length limit.
    $json = [pscustomobject]@{ Title = $Message.Title; Text = $Message.Text; Seconds = $Message.Seconds } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($script:MessageFile, $json, (New-Object System.Text.UTF8Encoding($false)))

    $code = (Get-MessageWindowScript).Replace('__MESSAGE_FILE__', $script:MessageFile.Replace("'", "''"))
    $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($code))

    $script:MessageProc = Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -NoNewWindow -PassThru -ErrorAction Stop `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded)
    # Reading Handle while the window is up is what keeps ExitCode readable
    # after it closes. Without it, ExitCode comes back empty and every message
    # is recorded as a failed window.
    $null = $script:MessageProc.Handle
    $script:MessageDeadline = (Get-Date).AddSeconds($Message.Seconds + 30)
}

function Update-KioskMessage {
    <#
        Called once per check: follows the message on screen, and shows the
        next one once the screen is free. $true while one is up.
    #>
    if ($script:MessageProc) {
        $proc = $script:MessageProc
        if (-not $proc.HasExited -and (Get-Date) -lt $script:MessageDeadline) { return $true }

        if (-not $proc.HasExited) {
            # Its own timer should have closed it half a minute ago.
            try { $proc.Kill() } catch {}
            $outcome = 'KILLED'; $how = 'the window did not close by itself and was ended'
        }
        else {
            switch ($proc.ExitCode) {
                0       { $outcome = 'ACKNOWLEDGED'; $how = 'OK pressed' }
                2       { $outcome = 'TIMEOUT';      $how = 'closed by its countdown' }
                default { $outcome = 'ERROR';        $how = "the window failed (exit code $($proc.ExitCode))" }
            }
        }

        $shown = $script:MessageShown
        $severity = if ($outcome -eq 'ACKNOWLEDGED' -or $outcome -eq 'TIMEOUT') { 'INFO' } else { 'WARNING' }
        Write-EventRow -EventType "MESSAGE_CLOSED" -Severity $severity -Outcome $outcome `
            -DurationSeconds ((Get-Date) - $shown.StartedAt).TotalSeconds `
            -Detail ("MessageId={0}; {1}" -f $shown.Id, $how) | Out-Null
        Write-Log ("Message {0} closed: {1}. Screen checks resume." -f $shown.Id, $how)

        Remove-Item -LiteralPath $script:MessageFile -Force -ErrorAction SilentlyContinue
        $script:MessageProc  = $null
        $script:MessageShown = $null
    }

    $next = Read-InboxMessage
    if (-not $next) { return $false }

    # Out of the inbox before anything else: a message that cannot be shown
    # must not come back every ten seconds. Not removable means not ours to
    # take yet.
    try { Remove-Item -LiteralPath $next.File -Force -ErrorAction Stop } catch { return $false }

    try { Start-MessageWindow -Message $next }
    catch {
        Write-EventRow -EventType "MESSAGE_REJECTED" -Severity "WARNING" -Outcome "REJECTED" `
            -Detail ("MessageId={0}; the message window could not be opened: {1}" -f $next.Id, $_.Exception.Message) | Out-Null
        Write-Log "Message $($next.Id) could not be shown: $($_.Exception.Message)" "ERROR"
        return $false
    }

    $next.StartedAt = Get-Date
    $script:MessageShown = $next
    Write-EventRow -EventType "MESSAGE_SHOWN" -Severity "INFO" -Outcome "SHOWN" -DurationSeconds $next.Seconds `
        -Detail ("MessageId={0}; From={1}; Seconds={2}; Text={3}" -f $next.Id, $next.From, $next.Seconds, (ConvertTo-LedgerText $next.Text)) | Out-Null
    Write-Log ("Showing message {0} from {1} for up to {2}s, screen checks paused: {3}" -f $next.Id, $next.From, $next.Seconds, (ConvertTo-LedgerText $next.Text))
    return $true
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

$script:LoopState = Read-LoopGuardState
if (-not (Test-Path -LiteralPath $LoopStatePath) -and (Test-LedgerHoldOpen)) {
    $script:LoopState.HoldReported = $true
    Write-Log "The ledger shows the loop guard holding, but its state file is gone - taken as a manual reset. The hold is recorded as released once the screen has been normal for $LoopGuardHealthyChecks checks." "WARN"
}
elseif ($script:LoopState.Restarts.Count -gt 0) {
    Write-Log ("Loop guard: {0} restart(s) in a row since {1} have not yet been followed by a normal screen (holds at {2})." -f `
               $script:LoopState.Restarts.Count, (Format-Utc $script:LoopState.Restarts[0]), $LoopGuardMaxRestarts) "WARN"
}
# The inbox is also how the dashboard knows a V7 watchdog has run here.
try {
    if (-not (Test-Path -LiteralPath $InboxPath)) { New-Item -ItemType Directory -Path $InboxPath -Force | Out-Null }
}
catch { Write-Log ("Could not create the message inbox {0}: {1}" -f $InboxPath, $_.Exception.Message) "WARN" }
# A window from before this watchdog started is not one it can follow.
Remove-Item -LiteralPath $script:MessageFile -Force -ErrorAction SilentlyContinue

$script:GuardHolding  = $false   # restarts are currently being withheld
$script:HoldAnnounced = $false   # LOOP_GUARD_ENGAGED already written by this run
$script:HealthyChecks = 0

$script:ConsoleHost = Get-ConsoleHostKind
if ($script:ConsoleHost -eq 'conhost') {
    Write-Log "Console: classic console host."
}
else {
    Write-Log "Console: $($script:ConsoleHost), not the classic console host. The launcher's window size and colours may not apply." "WARN"
}

# Before the first screen check, so the window is never in the picture.
if (Hide-ConsoleWindow) {
    $script:ConsoleWindow = 'hidden-by-watchdog'
    Write-Log "Console window was on screen and has been hidden: it would cover the kiosk app and be counted in the screen checks. The launcher should have hidden it - is it older than V7.0?" "WARN"
}
elseif ($script:ConsoleHost -eq 'conhost') {
    $script:ConsoleWindow = 'hidden'
    Write-Log "Console window: hidden."
}
else {
    $script:ConsoleWindow = 'not-hideable'
    Write-Log "Console window cannot be hidden from here: if it is on screen, it covers the kiosk app and is counted in the screen checks." "WARN"
}

Write-EventRow -EventType "AGENT_START" -Severity "INFO" `
    -Detail ("Watchdog v{0} started. Interval={1}s, WhiteHigh={2}%/{3} checks, WhiteLow={4}%/{5} checks, PS={6}, Console={7}, Window={8}" -f `
             $AgentVersion, $CheckIntervalSeconds, $WhiteHighThreshold, $WhiteChecksNeeded, `
             $WhiteLowThreshold, $LowWhiteChecksNeeded, $PSVersionTable.PSVersion.ToString(), $script:ConsoleHost, $script:ConsoleWindow) | Out-Null

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

        if (Update-KioskMessage) {
            # The message window is on the screen being sampled: judging the
            # screen now would be judging the message. Counters stay where
            # they are and carry on once it closes.
            Start-Sleep -Seconds $CheckIntervalSeconds
            continue
        }

        # Something brought the console back - someone at the kiosk, most
        # likely. Hide it and let the screen repaint, or this check would
        # photograph it.
        if (Hide-ConsoleWindow) {
            Write-Log "Console window was back on screen; hidden again before the screen check." "WARN"
            Start-Sleep -Milliseconds 500
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
            $script:HealthyChecks = 0
            if ($whitePercent -gt $script:WhiteEpisodePeak) { $script:WhiteEpisodePeak = $whitePercent }
            # While the guard holds, the hold message below replaces this line;
            # one of these every ten seconds for hours would bury the log.
            if (-not $script:GuardHolding) {
                Write-Log ("White screen detected: {0:N1}% white ({1}/{2})" -f $whitePercent, $script:FailedChecks, $WhiteChecksNeeded) "WARN"
            }
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
            $script:HealthyChecks = 0
            if ($whitePercent -lt $script:LowEpisodeTrough) { $script:LowEpisodeTrough = $whitePercent }
            if (-not $script:GuardHolding) {
                Write-Log ("Low-white screen detected: {0:N1}% white ({1}/{2})" -f $whitePercent, $script:LowWhiteFailedChecks, $LowWhiteChecksNeeded) "WARN"
            }
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
            $script:GuardHolding         = $false

            $script:HealthyChecks++
            if ($script:HealthyChecks -eq $LoopGuardHealthyChecks) { Reset-LoopGuard -WhitePercent $whitePercent }
        }

        $restartKind = $null
        if ($script:FailedChecks -ge $WhiteChecksNeeded) { $restartKind = "WHITE" }
        elseif ($script:LowWhiteFailedChecks -ge $LowWhiteChecksNeeded) { $restartKind = "LOWWHITE" }

        if ($restartKind) {
            $nowUtc   = (Get-Date).ToUniversalTime()
            $decision = Get-LoopGuardDecision -NowUtc $nowUtc
            $streak   = if ($restartKind -eq "WHITE") { $script:FailedChecks } else { $script:LowWhiteFailedChecks }

            if ($decision.Action -eq 'Hold') {
                # The counters keep climbing and the episode stays open: the
                # screen is still bad, and the ledger should say so for as
                # long as it is. The check repeats every cycle, so the retry
                # timer is noticed as soon as it runs out.
                if (-not $script:HoldAnnounced) {
                    Write-LoopGuardHold -Decision $decision -Kind $restartKind -WhitePercent $whitePercent -StreakChecks $streak
                    $script:LoopState.HoldReported = $true
                    Save-LoopGuardState
                    $script:HoldAnnounced = $true
                }
                elseif (($CheckCount % $HeartbeatEveryNChecks) -eq 0) {
                    $next = if ($decision.NextRetryUtc) { "next attempt after " + (Format-Utc $decision.NextRetryUtc) } else { "no automatic retry" }
                    Write-Log ("Loop guard holding: screen {0:N1}% white ({1}), not restarting; {2}." -f $whitePercent, $restartKind, $next) "WARN"
                }
                $script:GuardHolding = $true
            }
            else {
                if ($restartKind -eq "WHITE") {
                    $episodeSeconds = ((Get-Date) - $script:WhiteEpisodeStart).TotalSeconds
                    $episodeId      = $script:WhiteEpisodeId
                    Close-WhiteEpisode -Outcome "REBOOT" -Percent $whitePercent
                }
                else {
                    $episodeSeconds = ((Get-Date) - $script:LowEpisodeStart).TotalSeconds
                    $episodeId      = $script:LowEpisodeId
                    Close-LowEpisode -Outcome "REBOOT" -Percent $whitePercent
                }

                $note = if ($decision.Action -eq 'Retry') {
                    "LoopGuard=retry after {0} unhelpful restart(s) since {1}" -f $decision.Restarts.Count, (Format-Utc $decision.Since)
                } else {
                    "LoopGuard={0}/{1}" -f ($decision.Restarts.Count + 1), $LoopGuardMaxRestarts
                }

                # Counted before shutdown.exe is asked, and through the disk
                # cache: after the restart it is the only memory of it.
                $script:LoopState.Restarts = @(@($decision.Restarts) + $nowUtc | Select-Object -Last 10)
                Save-LoopGuardState

                $script:RestartRequested = [bool](Invoke-WatchdogRestart -Kind $restartKind -StreakChecks $streak -WhitePercent $whitePercent `
                                                                         -EpisodeSeconds $episodeSeconds -EpisodeId $episodeId -Note $note)
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
                Undo-LoopGuardRestart
                $script:FailedChecks         = 0
                $script:LowWhiteFailedChecks = 0
                $script:GuardHolding         = $false
            }
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
