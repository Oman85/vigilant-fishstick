# MWST Fleet V6.1

White-screen watchdog for the MACH2 kiosks, and the reporting that feeds Power BI.

Part of [Kiosk Fleet](../README.md). The Power BI screens, and the launcher that now runs on them, are in [PowerBI-Launcher.md](PowerBI-Launcher.md). The collector and dashboard described here cover both kinds of kiosk.

**Being retired.** Mach2 Launcher ver 1.00NG ([Mach2-Launcher-NG.md](Mach2-Launcher-NG.md)) has this watchdog built in and replaces it, kiosk by kiosk, together with `Mach2Launcher.exe`. It writes the same ledger and log described here, so everything below about the ledger, the CSV and counting reboots holds for it too. Its `AgentVersion` is `1.00NG`, and its restarts can also be of kind `BROWSER` (`WATCHDOG_BROWSER`). The deploy described here is for kiosks not yet moved.

The collector reports its version as `6.1`, in every `COLLECTOR_RUN` row. The watchdog reports `7.0`, or `6.1` on kiosks that haven't been upgraded yet, in the CSV's `AgentVersion` column.

Everything ends up in **one CSV**, `MWST_FleetEvents.csv`: a long fact table with one row per event. It syncs to SharePoint next to the master kiosk list, and Power BI reads it from there.

```
 kiosk                                          this PC, every 15 min               SharePoint
 ─────                                          ─────────────────────               ──────────
 Windows System log ─┐ read locally                                            ┌──► MWST_FleetEvents.csv ──► Power BI
 (1074 / 6005 / 6008)│ by the agent                                            │
                     ▼                                                         │
 mwstv4.ps1 ──► mwst_events.csv ────── C$ ──►   Collect-MWSTFleet.ps1 ──────────┤
            ──► mwst.log (liveness) ── C$ ──►   (merge, dedupe, reconcile)      └──► Logs\MWST_FleetEvents.csv (local copy)
```

Everything crosses the network over the admin share (`C$`) only. Nothing needs remote event log access: each kiosk reads its own System log and copies the reboot records into its ledger.

```
```

## Files

| File | What it is |
|---|---|
| `Agent\mwstv4.ps1` | The V7.0 watchdog, with the [loop guard](#loop-guard-agent-v70) and a [console window kept off the screen](#console-window-agent-v70). Deployed to `C:\Users\Public\Documents\` on each kiosk. It keeps the old file name and path so no launcher has to change to find it; the "v4" in the name is historical. |
| `Agent\MWSTv6_Launcher.bat` | Launcher V7.0, started at logon by the `MWST v6.1` task. Hides its own window, waits 60 seconds for the kiosk app, then starts the watchdog. Deployed with `-RegisterLauncherTask`. The file and task names stay as they are, so a redeploy replaces them rather than adding a second watchdog. |
| `Agent\archive\mwstv4_v6.1.ps1` | The previous watchdog, kept for rollback. |
| `Collect-MWSTFleet.ps1` | The collector. One run is one scan of the fleet. |
| `Deploy-MWSTAgent.ps1` | Pushes the agent to kiosks over `C$`. It keeps a backup of the old file, verifies the hash, and swaps the new file in atomically, so a failed copy never leaves a kiosk without its script. Refuses to ship a script that doesn't parse. Supports `-WhatIf`. |
| `Save-KioskCredential.ps1` | Saves the kiosk-admin credential, DPAPI-encrypted to your account. Tests it before saving. |
| `Install-CollectorTask.ps1` | Registers the 15-minute scheduled task. `-Unregister` removes it. |
| `Run-Collector.bat` | Manual run. Extra arguments pass through. |
| `Show-FleetDashboard.ps1` | Live terminal dashboard and management point (Kiosk Fleet Manager), started by `Start-KioskManager.bat`. Reads the same CSV as Power BI. |
| `Reports\MWST_FleetEvents.pq` | Power Query import with explicit types. `Reports\Measures.dax` has the measures. |
| `Lib\` | Shared code: kiosk list reader (.xlsx without Excel), remote helpers, PBI Launcher status reader. |
| `Logs\` | `collector.log`, local copy of the CSV, deploy reports. |
| `Config\` | `kiosk-admin.cred.xml`, created by `Save-KioskCredential.ps1`. |

## Setup

Run these from `C:\KIOSK_FLEET` in Windows PowerShell, signed in as yourself.

**1. Save the kiosk-admin credential.** It is tested against a kiosk before it is saved. Run this again whenever that password changes.

```powershell
.\Save-KioskCredential.ps1
```

**2. First run.** This picks up whatever the kiosks have already collected.

```powershell
.\Run-Collector.bat
```

Reboot history from *before* the new agent is deployed arrives when each kiosk first runs it: the agent's first scan reaches 30 days back into that kiosk's System log, including reboots by the old watchdog, which are recognised from its shutdown comment. (`-EventLookbackDays` only affects the optional `-RemoteEventLog` path.)

**3. Schedule it.**

```powershell
.\Install-CollectorTask.ps1 -RunNow
```

**4. Deploy the new watchdog.** Pilot on one healthy kiosk first. Always include `-RegisterLauncherTask`: it ships the launcher that hides the watchdog's window. `-RebootAndVerify` restarts each kiosk and checks that the watchdog came up cleanly, stopping at the first kiosk that fails.

```powershell
.\Deploy-MWSTAgent.ps1 -Hosts SHCZ5KPI12473 -CredentialFile .\Config\kiosk-admin.cred.xml -RegisterLauncherTask -TaskDomain SHAPE -RebootAndVerify
.\Deploy-MWSTAgent.ps1 -CredentialFile .\Config\kiosk-admin.cred.xml -RegisterLauncherTask -TaskDomain SHAPE -RebootAndVerify
```

Registering the task also re-enables it on a kiosk where it was disabled by hand.

Without `-RebootAndVerify`, the new version takes effect the next time the watchdog starts (the kiosk's next logon or reboot). Until then the kiosk shows `AGENT_OUTDATED`. That is harmless, because its reboots are still caught through the event log.

**5. Power BI.** See [Power BI](#power-bi) below.

## How every reboot is caught

A watchdog reboot has up to three independent witnesses:

1. **The ledger row.** The agent writes `RESTART_TRIGGERED` to `mwst_events.csv` and flushes it through the disk's write cache *before* it calls `shutdown.exe`.
2. **Windows event 1074.** `shutdown.exe` makes Windows log the request, including the comment. The comment carries `MWST-WATCHDOG <kind> id=<first 8 of EventId>`, so the collector ties it back to the exact ledger row. Windows writes this itself, independently of the watchdog. The agent copies these records out of the local System log into the ledger — verbatim, interpreting nothing — so they reach the collector without anyone reading an event log across the network.
3. **The confirmation.** On the next start, the agent compares a pending-restart marker against the OS boot time and writes `RESTART_CONFIRMED`, or `RESTART_FAILED` if the machine never actually rebooted.

Any one witness is enough for the reboot to be counted. When several agree, it is counted once.

**Safety net.** Every boot (event 6005) must be explained by a reboot record. A boot that nothing explains is counted in its own right as `UNEXPLAINED`, so a reboot that left no other trace still shows up. The one exception is the first boot in a kiosk's history, because whatever caused it happened before the data starts.

**One boot, one count.** Between two boots there is exactly one shutdown, however many records describe it. Windows logs two 1074s for a single restart from the Start menu (Explorer asks, winlogon executes), and a feature update logs a burst of them. Within each boot interval exactly one row is flagged, in this order of preference:

1. the watchdog's own 1074
2. any other 1074
3. an unexpected-shutdown record

**A reboot that doesn't happen is recorded too.** Sometimes the kiosk is still up ten minutes after the watchdog asked for a reboot, for example because someone ran `shutdown /a`, or a shutdown was already pending. When that happens the agent writes `RESTART_FAILED` and goes back to watching the screen. The old agent exited at that point and left the kiosk unwatched.

**History starts when a kiosk is upgraded.** A kiosk's records only count from the moment it first ran V6.1. Anything it reports from before that is dropped, because the old watchdog is not a reliable witness to its own behaviour — on TV3 it rebooted the kiosk 174 times in one day, which would swamp every count in the report. The cutoff is per kiosk, read from its own first `AGENT_START`, so the remaining kiosks clean themselves up as you deploy them. `-KeepPreUpgradeHistory` keeps the old rows if you ever want to look back.

**Nothing is lost between scans.** The CSV is a cache of durable sources: the kiosks' ledgers are never trimmed, and their System logs keep weeks of history. A missed scan, a locked file or a failed write just means the next run picks it up. After a gap, such as you being on leave or a kiosk's event log being unreachable, the collector automatically reads back far enough to cover it.

## Loop guard (agent V7.0)

V6.1 restarted a kiosk whenever its screen stayed white or blank for two minutes, however often that happened. If the screen is bad again straight after every boot, that is a reboot loop: on 16 Sep 2026 it restarted ROLL003 ten times in an hour, because the screen read black from the moment the watchdog started. What it saw was its own console window, not the dashboard; see [Console window](#console-window-agent-v70).

V7.0 restarts such a kiosk **twice**, then stops and waits for a person:

- **A restart only counts as having helped after 5 minutes of normal screen** (30 checks in a row). A single good reading proves nothing: a page flashing up during boot would reset the count, and the loop would never end.
- **After 2 restarts in a row that didn't help** (within 60 minutes of each other), the guard **holds**. The watchdog keeps watching and logging, but doesn't restart. It writes `LOOP_GUARD_ENGAGED` once, and the collector shows the kiosk as `LOOP_GUARD`. Without that, a watchdog that has given up would look healthy, since its log is still fresh.
- **While holding, it tries one more restart every 2 hours**, in case the cause has cleared by itself (a network outage, say). A restart that helps releases the guard like any other.
- **Once the screen has been normal for 5 minutes**, it writes `LOOP_GUARD_RELEASED`, and the count starts again from zero.

The count is kept in `mwst_loopguard.json` next to the ledger. Like the pending-restart marker, it is flushed through the disk cache before `shutdown.exe` is called. A restart that never actually happens (`RESTART_FAILED`) is not counted.

The settings are at the top of the agent: `$LoopGuardMaxRestarts`, `$LoopGuardWindowMinutes`, `$LoopGuardHealthyChecks` and `$LoopGuardRetryMinutes` (`0` turns the retry off).

**When a kiosk shows `LOOP_GUARD`,** go and look at its screen. Whatever made it black or white was not fixed by restarting. Once the screen is right, the watchdog releases the guard by itself after 5 minutes. To reset the count without waiting, delete `mwst_loopguard.json` and restart the watchdog. The release is still recorded, because the agent reads the open hold from its ledger.

## Console window (agent V7.0)

The watchdog judges the screen from a screenshot, so anything on top of the kiosk app counts. Under V6.1 that included the watchdog's own console. The launcher opened it full width, black, and it stayed on top of the Mach2 dashboard. On ROLL003 on 16 Sep, Mach2 logged in and ran normally after every boot, yet every check read under 1% white and the kiosk was restarted again and again.

From V7.0 the window never shows:

- **The launcher hides it first**, before the kiosk app comes up. The 60-second wait still happens, but out of sight. The banner is only seen if the window couldn't be hidden.
- **The watchdog hides it again when it starts**, for a kiosk still on an older launcher.
- **Before every screen check it hides the window again** if something brought it back. That is logged as a warning.

`AGENT_START` records the result as `Window=`:

| Value | Meaning |
|---|---|
| `hidden` | The launcher hid the window before the watchdog started. |
| `hidden-by-watchdog` | The window was on screen until the watchdog started, so the launcher is older than V7.0. Redeploy with `-RegisterLauncherTask`. `-RebootAndVerify` notes it. |
| `not-hideable` | The console isn't a classic console window (Windows Terminal), so the watchdog can't hide it. `-RebootAndVerify` already fails such a kiosk on `Console=`. |

The message window from the dashboard is separate, and screen checks pause while it is up.

## The CSV

UTF-8 with BOM, comma-separated, every field quoted. Timestamps are ISO 8601, decimals use `.`, and booleans are `TRUE`/`FALSE`. An empty field means "not applicable".

| Column | Meaning |
|---|---|
| `EventId` | Stable unique key. GUID for agent events, `EVT-<host>-<record>-<time>` for event-log rows, `STAT-<host>-<scan>` for status rows, `RUN-<scan>` for collector runs. |
| `EventTimeUtc` | When it happened, UTC (`2026-09-10T13:09:34Z`). |
| `EventTimeLocal` | Same moment in local time. Use this in reports. |
| `EventDate` | Local date. Relate your Date table to this. |
| `Host` | Kiosk name, upper case. |
| `Location`, `KioskType`, `RestartGroup` | From the kiosk list. Refreshed on every run, so a kiosk that moves shows its whole history under its new location. |
| `EventCategory` | `REBOOT`, `SCREEN`, `AGENT`, `STATUS`, `COLLECTOR`. |
| `EventType` | See below. |
| `Severity` | `INFO`, `WARNING`, `CRITICAL`. |
| `Outcome` | Depends on the type: `RECOVERED` / `REBOOT` for episodes, `CONFIRMED` / `FAILED` for restarts, the host status for `HOST_STATUS`. |
| **`IsScriptReboot`** | `TRUE` on exactly one row per reboot the watchdog caused. |
| **`IsCanonicalReboot`** | `TRUE` on exactly one row per reboot of any cause. |
| `RebootTrigger` | `WATCHDOG_WHITE`, `WATCHDOG_LOWWHITE`, `EXTERNAL`, `UNEXPECTED`, `UNEXPLAINED`. |
| `WhitePercent` | Screen white %, at the event. |
| `StreakChecks` | Consecutive bad checks. |
| `DurationSeconds` | Episode length, downtime for `RESTART_CONFIRMED`, scan time for `COLLECTOR_RUN`. |
| `Reachable`, `WatchdogRunning`, `MinutesSinceLastLog` | Status rows only. |
| `AgentVersion` | Watchdog version, or `legacy` for the old agent. |
| `BootTimeUtc`, `UptimeHours` | Boot time of the session the row belongs to. |
| `Source` | `Agent`, `EventLog`, `Collector`. |
| `ScanId`, `CollectedUtc` | Which collector run picked the row up. |
| `Detail` | Human-readable context. |

### Event types

| EventType | Source | Counted as a reboot? |
|---|---|---|
| `RESTART_TRIGGERED` | Agent | Only when no 1074 corroborates it |
| `REBOOT_SCRIPT` | Event log 1074 tagged by the watchdog | Yes, unless the agent reported that reboot as failed |
| `RESTART_CONFIRMED` | Agent, after the reboot | No, it corroborates |
| `RESTART_FAILED` | Agent | No, no reboot happened. This is a fault worth alerting on. |
| `REBOOT_EXTERNAL` | Event log 1074, other process (updates, a person) | Yes, once per boot interval |
| `REBOOT_UNEXPECTED` | Event log 6008 (power loss, hard hang) | Yes, unless a 1074 in the same interval already accounts for that boot |
| `BOOT` | Event log 6005 | Only if nothing explains it (`UNEXPLAINED`). A Windows feature upgrade typically leaves one or two of these. |
| `WHITE_EPISODE_START` / `_END` | Agent | No |
| `LOWWHITE_EPISODE_START` / `_END` | Agent | No |
| `AGENT_START` / `AGENT_STOP` / `AGENT_ERROR` / `AGENT_RECOVERED` | Agent | No |
| `LOOP_GUARD_ENGAGED` / `LOOP_GUARD_RELEASED` | Agent V7.0: the watchdog stopped / resumed restarting a screen that restarts did not fix. See [Loop guard](#loop-guard-agent-v70). | No |
| `HOST_STATUS` | Collector, when a host's status changes and at least daily | No |
| `COLLECTOR_RUN` | Collector, when the CSV is rewritten and at least hourly | No |

**Never count `EventType` rows to get reboot numbers.** One reboot legitimately produces a trigger, a 1074, a boot and a confirmation. Count the flags.

### Host status (`Outcome` on `HOST_STATUS` rows)

| Status | Meaning |
|---|---|
| `OK` | All good. |
| `OFFLINE` | No ping and no SMB. |
| `NO_ACCESS` | Reachable, but the admin share can't be read. Usually the stored credential is wrong or expired. |
| `NO_AGENT` | Watchdog expected, but there's no trace of it on the kiosk. |
| `STALE` | `mwst.log` hasn't been written for over 10 minutes, so the watchdog isn't running. |
| `LOOP_GUARD` | The watchdog is running, but it has stopped restarting a screen that two restarts in a row did not fix. Someone has to look at the kiosk. |
| `AGENT_OUTDATED` | Old watchdog still running (log present, no ledger). Clears after deploy + reboot. |
| `EVENTLOG_UNAVAILABLE` | Fine, but the remote event log couldn't be read, so one reboot witness is missing. |
| `INACTIVE` | Deliberately not scanned — `ACTIVE` is not `Y` in the kiosk list. Shown greyed out, and never counted as a problem. |

Power BI kiosks that run PBI Launcher get the launcher's own statuses instead (`WRONG_ACCOUNT`, `SIGNIN_BLOCKED`, `LAUNCHER_STALE` and others), and `pbi-<version>` as their `AgentVersion`. See [PowerBI-Launcher.md](PowerBI-Launcher.md#in-the-fleet-tools). Those still on the old `PowerBILauncher.exe` stay ping-only, as before.

## Power BI

1. **Get data > Blank query > Advanced Editor.** Paste `Reports\MWST_FleetEvents.pq`, set `FilePath` to the synced CSV, and name the query `Events`.
   The query types every column with an `en-US` culture. That matters in a Czech locale, where automatic detection would misread `85.5` and the ISO dates.
2. For scheduled refresh in the Power BI Service, swap the `Source` step for the SharePoint URL shown in the file's header comment. No gateway is needed.
3. Relate a Date table to `Events[EventDate]`.

Measures:

```dax
Script Reboots = CALCULATE ( COUNTROWS ( Events ), Events[IsScriptReboot] = TRUE () )

All Reboots = CALCULATE ( COUNTROWS ( Events ), Events[IsCanonicalReboot] = TRUE () )

White Screen Reboots = CALCULATE ( [Script Reboots], Events[RebootTrigger] = "WATCHDOG_WHITE" )

Low-White Reboots = CALCULATE ( [Script Reboots], Events[RebootTrigger] = "WATCHDOG_LOWWHITE" )

Unplanned Reboots = CALCULATE ( [All Reboots], Events[RebootTrigger] IN { "UNEXPECTED", "UNEXPLAINED" } )

Failed Restarts = CALCULATE ( COUNTROWS ( Events ), Events[EventType] = "RESTART_FAILED" )

Last Collected = CALCULATE ( MAX ( Events[EventTimeLocal] ), ALL ( Events ), Events[EventType] = "COLLECTOR_RUN" )

Current Status =
VAR LastSeen =
    CALCULATE ( MAX ( Events[EventTimeLocal] ), Events[EventType] = "HOST_STATUS" )
RETURN
    CALCULATE (
        SELECTEDVALUE ( Events[Outcome] ),
        Events[EventType] = "HOST_STATUS",
        Events[EventTimeLocal] = LastSeen
    )
```

To get a fleet status table, put `Host` and `Location` on rows and add `Current Status`.

`Last Collected` tells a quiet fleet apart from a dead collector: when the task is healthy it's never more than an hour old while you're signed in.

## Operations

- **Log:** `Logs\collector.log`. It has one line per run with host counts, new events, and anything that went wrong.
- **`MWST_FleetEvents.status.json`** sits next to the CSV and records when the collector last *ran*, which is a different thing from when the data last *changed*. On a quiet fleet nothing changes for hours while the collector keeps checking every 15 minutes, so anything judging freshness from the CSV alone would call a healthy fleet stale. The dashboard reads this file; it is rewritten on every run and is a few hundred bytes.
- **How long a scan takes:** kiosks are read 8 at a time (`-ParallelHosts`), which puts a 42-kiosk scan at roughly 20-30 seconds. Nearly all of that is waiting for kiosks to answer: opening a kiosk's admin share takes milliseconds on most of them and up to 20 seconds on a few, and reading them one after another used to make the same scan take 11 minutes. `-ParallelHosts 1` goes back to one at a time. A kiosk that has not answered after `-HostTimeoutSeconds` (180 by default) is recorded with whatever was read before the deadline, logged as *gave up reading it*, and the scan carries on without it.
- **Password changed:** run `Save-KioskCredential.ps1` again. Until you do, kiosks show `NO_ACCESS`.
- **Kiosk added or removed:** edit the master kiosk list. The next run follows it.
- **Which kiosks get scanned:** a kiosk with `ACTIVE` set to anything other than `Y` is skipped, and the collector logs how many it skipped. `HAS MWST = Y` marks the kiosks that run the watchdog. A blank `ACTIVE` is not a decision — those rows fall back to the `HAS MWST` rule (plus Power BI screens, which are always reachability-checked), so half-filling the column cannot silently empty the fleet.
- **Scans only run while you're signed in.** That's by design, because your OneDrive and the encrypted credential both need your session. Nothing is lost in between.
- **Run the collector on one PC only.** Two collectors writing the same SharePoint file produce OneDrive conflict copies.
- **And only from `C:\KIOSK_FLEET`.** The older copy in `C:\MWST_FLEET` writes the same file but knows nothing about PBI Launcher, so its scans would flip every Power BI kiosk back to a plain ping status. Two collectors on the same PC never run at the same time (they share a lock), but they still take turns overwriting each other's statuses.
- **Event logs are read on the kiosk, not across the network.** The zero-trust policy blocks the RPC that remote event log access needs, so each kiosk reads its own System log (which needs no special rights — the log grants read to whoever is logged on) and copies the records into its ledger. The first scan on a kiosk reaches 30 days back; after that it picks up new records at every start and hourly. If the firewall is ever opened, `-RemoteEventLog` reads them across the network as well; the two routes produce identical rows, so running both cannot double-count.
- **Don't save the CSV from Excel.** In a Czech locale Excel rewrites it with semicolons. The collector detects this and refuses to overwrite the file (it logs an error and keeps writing the local copy). Delete the mangled file and the next run rebuilds it from the local copy.
- **Starting over:** delete both `MWST_FleetEvents.csv` copies (SharePoint folder and `Logs\`), then rerun with `-EventLookbackDays 365`. Deleting only one is undone by the other.
- **SharePoint versions:** each rewrite of the CSV creates a version in SharePoint. The collector only rewrites when something changed, or hourly for the heartbeat, to keep that in check.
- **Retention:** 400 days by default (`-RetentionDays`). Collector-run rows are kept for 30.
- **Launcher task and console:** `Deploy-MWSTAgent.ps1 -RegisterLauncherTask` registers a task that runs `%windir%\System32\conhost.exe %windir%\System32\cmd.exe /c "…\MWSTv6_Launcher.bat"`. The explicit `conhost.exe` is there to keep the launcher in the classic console, which is what its `MODE CON` and `COLOR` are written for, rather than in Windows Terminal. The V7.0 watchdog records the console it actually got as `Console=` in its `AGENT_START` row (`conhost`, or `pseudoconsole` for Windows Terminal or another terminal app), and `-RebootAndVerify` fails a kiosk that isn't on `conhost`. It records whether the window was hidden as `Window=` (see [Console window](#console-window-agent-v70)). If a kiosk isn't on `conhost`, set the kiosk account's default terminal to *Windows Console Host* with the Group Policy *User Configuration › Administrative Templates › Windows Components › Windows Terminal › Default terminal application*.
- **Rolling back the watchdog:** `.\Deploy-MWSTAgent.ps1 -AgentSource .\Agent\archive\mwstv4_v6.1.ps1 -Hosts <kiosk>` puts V6.1 back. It takes effect at the next watchdog start, like any other deploy.

## Coming from C:\MACH2_REPORT

Nothing here depends on the old folder. SQLite, the HTML dashboards and the per-run snapshot CSVs are all gone. Once you're happy with the new data, the old folder can be archived.

The only thing carried over is the watchdog itself. Its detection thresholds and behaviour are unchanged; screen sampling is faster (same pixels, same result); and it now records everything it does.
