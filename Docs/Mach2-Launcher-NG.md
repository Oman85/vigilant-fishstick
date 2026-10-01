# Mach2 Launcher ver 1.02NG

Shows the Mach2 dashboard full screen on a Mach2 kiosk, keeps it there, and is the kiosk's watchdog. It replaces three programs on each kiosk:

- `Mach2Launcher.exe` (2.0.0.13) and the `StartupLauncher.exe` (1.0.0.5) that started it
- the MWST white-screen watchdog (`mwstv4.ps1`, V7.0), its launcher batch file and its logon task

The kiosks are not interactive. Nobody uses the screens, so anything other than the dashboard is put right.

Part of [Kiosk Fleet](../README.md). It writes the watchdog's ledger and log in the watchdog's format and place, so the collector, the Power BI report and the Kiosk Fleet Manager read an NG kiosk as they read a watchdog kiosk. The watchdog itself is described in [Mach2-Watchdog.md](Mach2-Watchdog.md). Everything said there about the ledger, the CSV and reboot counting still holds.

The scripts are versioned **ver X.XXNG**. This is ver 1.02NG: the launcher, `Deploy-Mach2LauncherNG.ps1` and `Get-Mach2LauncherNGStatus.ps1`. The number is `$LauncherVersion` at the top of the launcher. The collector and the dashboard recognise any `X.XXNG`. The config format is still `1.00NG`: 1.01NG and 1.02NG only add optional settings.

**1.02NG** makes the launcher wait for a slow station instead of giving up on it. On TV3, whose link is slow, the station took longer than the launcher's patience to answer the password. The page stopped answering DevTools while it worked, the launcher read that as a dead browser, restarted Edge in the middle of the sign-in and typed the password again; two of those and the lockout guard blocked the kiosk for an hour, over and over, with the dashboard never coming up.

- A page that has gone quiet is now given `PageStalledSeconds` (60) before Edge is restarted, instead of three failed checks in a row, and a **sign-in in flight gets `SignInWaitSeconds` (90)** - restarting Edge there throws the sign-in away and spends one of the two password attempts.
- The password is not typed again into a form that has not answered yet: after it is sent, the launcher waits `SignInSettleSeconds` (10, was 3) and ignores a page that is still loading.
- How long a single page read may take is `PageReadTimeoutSeconds` (15).
- Raise all four on a kiosk with a slow link. They can be changed in the kiosk's config while the launcher runs; it reloads within seconds.

**1.01NG** fixes what the first kiosk (TV4) showed after 1.00NG:

- The deploy moves the old `StartupLauncher` shortcut out of the Startup folder instead of renaming it there. Windows had been showing *"Select an app to open this .disabled-by-Mach2LauncherNG file"* over the dashboard at every logon.
- The launcher stops the old `Mach2Launcher.exe` for its screen when it finds it running (`StopOldLauncher`). The logon script puts the old shortcut back at every logon, so the two had been running side by side.
- Rollback now reads 1.00NG's `migration.json`, where an empty list was written as `{}`. Before, rolling back a kiosk like TV4 would have failed.

```
 logon ─► Startup\Mach2 Launcher NG S1.lnk ─► conhost ─► powershell (hidden) ─► Mach2LauncherNG.ps1 -Instance S1
                                                                                   │            │
  C:\Users\Public\Documents\Mach2LauncherNG\                                       │ DevTools   │ the watchdog
    Mach2LauncherNG.ps1                                                            │ 127.0.0.1  │
    S1\  <HOST>.json   settings (old Mach2Launcher files work as they are)         ▼            ▼
         <HOST>.cred   the station password, DPAPI-encrypted for the kiosk   Edge, full screen,   C:\Users\Public\Documents\
         Status\       status file, read by the collector and the tools     InPrivate ─►         mwst.log, mwst_events.csv,
         Logs\         CMTrace log (also copied to RemoteLogPath)           Mach2 (Niagara)      mwst_inbox, loop guard ...
    S2\  ...           a second screen, if the kiosk has one                 dashboard
```

**Screens and other launchers.** A screen number belongs to one launcher. A kiosk can show Power BI ([PBI Launcher](PowerBI-Launcher.md)) or a web page ([Web Launcher](Web-Launcher.md)) on S1 and a Mach2 dashboard on S2. The watchdog is always the kiosk's first Mach2 screen, S2 in that case. The deploy leaves a screen another launcher has alone. The collector reads all three launchers on every kiosk, and the Kiosk Fleet Manager lists such a kiosk on both tabs.

## What is different

### From the old launcher

| | Old (`Mach2Launcher.exe`) | New |
|---|---|---|
| Driving Edge | Selenium and `msedgedriver.exe`, which must match Edge exactly. The launcher updated the driver from a share. | Edge's own DevTools protocol. There is no driver to keep in step with Edge. |
| Password | Plain text in `<HOST>.json`. | DPAPI-encrypted for the kiosk account in `<HOST>.cred`. |
| The station drops the session | The page lands on `/login`, the launcher cannot navigate back ("Not at display URL and couldn't navigate to it, relauching launcher!"), and starts all over with a new Edge. This is the most common error in the old launchers' logs. | Signs in again on the page it is on, then opens the dashboard. Same Edge. |
| Wrong password | Retried on every start. That can lock the account out. | One try, then nothing for 60 minutes. A new `password.seed` retries at once. |
| After sign-in | Waits for the station's home page, then navigates. | The same, and it also works when the station returns to the dashboard by itself. |
| A white, dark or failing page | Not noticed. The watchdog restarted the PC after 2 minutes. | Seen on the page itself (a DevTools screenshot, the watchdog's measure): reload, then a new Edge, then a PC restart (see below). |
| Anywhere but the dashboard | Relaunched itself. | Opens the dashboard again after 15 seconds (at once right after sign-in). |
| A second window | Stayed on top. | Closed within seconds. |
| Startup check | `StartupLauncher` waited 45 s for a log line; on the pilot it logs `Launcher success = False` after every boot, because it watches a log file name the launcher does not write. | Gone. The launcher reports its own state. |
| Temp folder | Emptied the user's `%TEMP%` on every start. | Left alone. |

Everything the old config set still works: dashboard and login address, user and field names, screen, zoom, interval and daily refresh, scheduled restart, startup delay, disable, central log folder, and `kill.txt` / `relaunch.txt` / `restart.txt` / `refresh.txt`.

### From the watchdog

| | Watchdog V7.0 | Launcher NG |
|---|---|---|
| What it watches | A screenshot of the primary screen: white (85% or more) or dark (under 10%). | The same screenshot, of its own screen, plus the page as Edge draws it, plus what Edge is doing: signed in, on the dashboard, a station error, Edge hung or gone, another window. |
| White or dark for 2 minutes | Restart the PC. | Reload after 30 s, a new Edge after another minute. The PC is restarted after 5 minutes (`RebootAfterMinutes`) of a problem on this PC. |
| The station is down | A white error page for 2 minutes, then a restart that cannot help. Then the loop guard holds. | No restart for 30 minutes (`OutageRebootMinutes`). It keeps retrying with growing pauses. |
| A sign-in that needs a person | White login page, restart, loop guard. | `SIGNIN_BLOCKED` and no restart. The collector shows the kiosk as `SIGNIN_BLOCKED`. |
| Its console on the screen | Hidden by the launcher and again by the watchdog (V7.0). | Hidden at start and before every screen check. `AGENT_START` records `Console=` and `Window=` as before. |
| Ledger, log, loop guard, messages, reboot records | | Unchanged: the same files, rows and rules. See [The watchdog](#the-watchdog). |

## Files

| File | What it is |
|---|---|
| `Mach2LauncherNG\Mach2LauncherNG.ps1` | The launcher, and the watchdog. Windows PowerShell 5.1, no modules, no other files. |
| `Mach2LauncherNG\Start-Mach2LauncherNG.cmd` | Starts it by hand, the way the startup shortcut does: `Start-Mach2LauncherNG.cmd S1`. |
| `Mach2LauncherNG\EXAMPLE.json` | Config template. |
| `Deploy-Mach2LauncherNG.ps1` | Installs on kiosks over `C$`: migrates the old config, retires the old launcher and the old watchdog. Also `-Rollback` and `-Command`. |
| `Get-Mach2LauncherNGStatus.ps1` | What every Mach2 kiosk's launcher is doing, screen by screen. |
| `Lib\M2.LauncherNG.ps1` | Reads a kiosk's launcher status for the collector. |
| `Tests\Test-Mach2LauncherNG.ps1` | The launcher against `Tests\Mach2Fixture.ps1`, a stand-in Niagara station, plus the collector reading its ledger. About 15 minutes. |
| `Tests\Test-Mach2Deploy.ps1` | Deploy, rollback, commands, status tool and startup shortcut, against fake kiosks. About 2 minutes. |

## Rollout

Run from `C:\KIOSK_FLEET` in Windows PowerShell, or from the Kiosk Fleet Manager: **D** on the Mach2 tab does the same install, restart or rollback for the kiosks you pick.

**0. The kiosk list.** The collector only reads kiosks with `HAS MWST = Y`. Set it for every Mach2 kiosk you move to NG, including those that never had the watchdog (W005 and the others). Otherwise nobody sees their watchdog data.

**1. Dry run on one kiosk.** Shows what would change and changes nothing.

```powershell
.\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI12473 -WhatIf
```

**2. Pilot.** Installs, restarts the kiosk (60-second warning on its screen), and waits until every screen shows its dashboard and the watchdog has started with its console hidden.

```powershell
.\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI12473 -Restart
```

Then look at the screen, and at the status:

```powershell
.\Get-Mach2LauncherNGStatus.ps1 -Hosts SHCZ5KPI12473
```

On the pilot, check what the tests could only imitate:

- **Sign-in.** The log should say `Sign-in: entered user name operator.`, then `Sign-in: entered the password.`, then `Signed in.`.
- **The readings.** The status tool's `SCREEN` and `PAGE` columns should read about what the watchdog logged for this kiosk: 72% on LASER020. If a kiosk's normal dashboard reads 85% or more, or under 10%, set `WhiteHighPercent` / `WhiteLowPercent` for it.
- **The old programs are off.** The deploy report says `task disabled: \MWST v6.1`, and after the restart no `Mach2Launcher.exe` or `mwstv4.ps1` is running (the deploy checks this and says so).

**3. The rest.** One kiosk at a time. The run stops at the first kiosk that does not come back showing its dashboard.

```powershell
.\Deploy-Mach2LauncherNG.ps1 -AllMach2Kiosks -Restart
```

Without `-Restart`, the new launcher starts at each kiosk's next logon. Until then the old ones keep running. The old launcher may stop before that (see the deploy's warning), so restart soon.

### What the deploy does on each kiosk

1. Finds the old launcher's configs: `<HOST>.json` next to `Mach2Launcher.exe` in `C:\Users\Public\Documents\Mach2Launchers\Launcher S<n>\`. There is one per screen. A `Launcher S2` folder with no config (as on LASER020) is not a screen.
2. Installs the three files in `C:\Users\Public\Documents\Mach2LauncherNG`. The copy is hash-checked, the previous version is kept as `.bak-<time>`, and the new file is swapped into place in one step.
3. Makes a folder per screen (`S1`, `S2`) with `<HOST>.json` from the old config: same settings, no password, and `Mach2Launcher` becomes `Mach2LauncherNG` in the log name, in the same central folder (`\\shghmgt09\Mach2Launcher\Logs`). `The lowest Mach2 screen gets `"Watchdog": "1"`, the others `"0"`. A screen that PBI Launcher or Web Launcher has already is skipped. An existing new config is kept unless you pass `-UpdateConfig`.
4. If a screen has no `<HOST>.cred` yet, writes `password.seed` there from the old config. The launcher encrypts it for the kiosk account on its first start and deletes it.
5. Puts `Mach2 Launcher NG S<n>.lnk` in the kiosk account's Startup folder.
6. Retires the old launcher, reversibly, by **renaming its JSON files** (`<name>.disabled-by-Mach2LauncherNG`, where they were). Each moved screen's `Launcher S<n>\<HOST>.json` is renamed: the old launcher cannot run without it, and the logon script `Mach2LauncherShortcuts.ps1` makes no `Mach2Launcher - S<n>` shortcut without it. `StartupLauncher\<HOST>.json` and `startup.json` are renamed too, once nothing `StartupLauncher` starts still has a config. The logon script puts the `StartupLauncher` shortcut back at every logon, but without its config it starts nothing. On a kiosk where it also starts a Power BI launcher that is not moved yet, it is kept (`StartupLauncher kept: …` in the report). The `StartupLauncher` shortcut is also **moved out** of the Startup folder, into `Mach2LauncherNG\Retired shortcuts\<account>\`. If `StartupLauncher` also starts something that is not Mach2, its shortcut stays.
   - It is moved, not renamed in place. Windows opens *everything* in a Startup folder at logon, whatever it is called. The `*.disabled-by-Mach2LauncherNG` that 1.00NG left there made Windows show *"Select an app to open this file"* on top of the dashboard at every logon. A redeploy moves any such leftover out too.
   - `Mach2LauncherShortcuts.ps1` on the kiosks copies the `StartupLauncher` shortcut back at every logon, and the old launcher has no setting that keeps it off (its configs have no `DisableStartup`). The renamed JSON files are what keeps it off now; as a second line, each screen's launcher still stops the old one for its screen whenever it finds it running (`StopOldLauncher`, below). On TV4, after the 1.00NG deploy, the two were running side by side.
7. Retires the old watchdog, reversibly. Every enabled task that runs `MWSTv*_Launcher.bat` or `mwstv4.ps1` is disabled over CIM/DCOM (the watchdog deploy registered it the same way), and a Startup shortcut to it is moved out the same way. Its files stay. If the task cannot be disabled, the report says so. The launcher also stops the old watchdog, and its batch file, whenever it finds them running in its session: two watchdogs must never restart the same PC.
8. Records everything it changed in `migration.json`, including where each retired shortcut came from and where it went.

Results per kiosk: `INSTALLED`, `VERIFIED` (with `-Restart`), `NO_CONFIG` (no old launcher to copy settings from: put `<HOST>.json` in `...\Mach2LauncherNG\S1` first), `OFFLINE`, `NO_ACCESS`, `FAILED`, `HALTED`. The report is `Logs\m2ng-deploy_<time>.csv`.

### Rollback

```powershell
.\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI12473 -Rollback -Restart
```

This removes the new shortcuts and moves the old launcher's and the old watchdog's shortcuts back into the Startup folder (or renames them back, where 1.00NG renamed them). It renames the old JSON files back, sets `DisableStartup` back to 0 where it had been set, enables the watchdog's task again, and stops the new launcher (`kill.txt` in each screen's folder). The installed files stay. The old watchdog also has its own deploy: `.\Deploy-MWSTAgent.ps1 -Hosts <kiosk> -RegisterLauncherTask -TaskDomain SHAPE`.

## Password

The launcher never needs the password in plain text on the kiosk for more than a moment:

- **From your PC** (after the password changed):
  ```powershell
  .\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI12473 -SignInCredential (Get-Credential operator)
  ```
- **At the kiosk:** drop `password.seed` (the password, one line) into the screen's folder.
- **At the kiosk, as the kiosk account:** `Mach2LauncherNG.ps1 -Instance S1 -SetPassword`.

A running launcher picks up a new password at once. `<HOST>.cred` decrypts only for the Windows account that saved it, on that PC.

Once every kiosk shows `SHOWING`, delete the old configs' `Password` values. Rollback needs them only as long as you might roll back.

## Configuration

`<HOST>.json` in the screen's folder. It is re-read when it changes, so an edit applies without a restart. Settings that affect Edge itself (address, screen, zoom, mode) start a new Edge. `Watchdog` and `WatchdogPath` take a launcher restart. Values are strings, as in the old files. `"1"`/`"0"` mean yes/no.

Settings the old launcher had:

| Key | Default | |
|---|---|---|
| `DisplayURL` | (required) | The dashboard. |
| `LoginURL` | | Where a fresh sign-in starts (`/prelogin?clear=true`). Without it, the dashboard address is used, and the station redirects to its sign-in. |
| `UserName` | | The station user (`operator`). |
| `Password` | | The old plain-text password. It works, but use `password.seed` instead. |
| `UsernameFieldName` / `PasswordFieldName` / `LoginButtonID` | `j_username` / `j_password` / `login-submit` | Niagara's. |
| `KioskMode` | `1` | Full-screen window. |
| `UsePriScreen` / `ScreenSelect` | `0` / `1` | The primary screen, or `\\.\DISPLAYn`. A screen that is not there yet is waited for (`DisplayWaitSeconds`, 120), then the primary is used. |
| `ZoomPercent` | `100` | 25–500. |
| `EnableRefresh` + `BrowserRefreshDelay` | `0` / `30` | Reload every n minutes. |
| `ForcedRefreshTime` | | Daily reload, `HH:mm`. |
| `ScheduledRestartEnabled` / `ScheduledRestartTime` / `RestartDelay` | `0` / – / `30` | Daily PC restart. |
| `StartupDelay` | `0` | Seconds to wait before starting. |
| `DisableStartup` | `0` | `1`: exit at once. That stops the watchdog too. |
| `LogPath` / `RemoteLogPath` / `LogName` | `Logs\` / – / `Mach2LauncherNG_<HOST>_<screen>.log` | |
| `DebugLogging` | `0` | Logs every page check. |

These are ignored, because there is no Selenium any more: `ZoomDelay`, `ElementTimeout`, `UpdateEdgeDriver`, `EdgeDriverSharePath`, `EdgeDriverSelfUpdate`, `EdgeDriverDownloadPath`, `EdgeDriverBackupLimit`, `KillEdgeDriver`, `TempCleanup`, `LogDelay`, `LoginDelay`, `JsonVer`.

New, all optional:

| Key | Default | |
|---|---|---|
| `Watchdog` | `1` on the first Mach2 screen, else `0` | This screen's launcher is the kiosk's watchdog. Only one can be: a second one says so in its log and just keeps its screen. The first Mach2 screen is S1 usually, S2 where Power BI or a web page has S1. |
| `StopOldLauncher` | `1` | Stop the old `Mach2Launcher.exe` for this screen (`Launcher S1` for S1) whenever it is found running, with the `msedgedriver.exe` it runs and the Edge that opened. Checked every 20 s, not while on hold. `0` leaves the old one alone: the deploy writes that with `-KeepLegacy`. From 1.01NG. |
| `WatchdogPath` | `C:\Users\Public\Documents` | Where the watchdog's files are. Leave it: the collector and the dashboard look there. |
| `RebootAfterMinutes` | `5` | Restart the PC once a problem on this PC has kept the dashboard off the screen this long. `0` = never. |
| `OutageRebootMinutes` | `30` | Restart the PC once the dashboard has been missing this long for any other reason (station down, network). `0` = never. |
| `PageReadTimeoutSeconds` | `15` | How long one read of the page may take before it counts as no answer. |
| `PageStalledSeconds` | `60` | How long the page may give no answer at all before Edge is restarted. |
| `SignInWaitSeconds` | `90` | The same, while a sign-in is in flight, and how long a sign-in page may sit there before the sign-in is started over. Raise it on a slow link: restarting Edge mid-sign-in spends one of the two password attempts, and two of them block the kiosk for `LoginRetryMinutes`. |
| `SignInSettleSeconds` | `10` | How long the station is given to answer the password before the launcher acts on what the page shows. Stops the password being typed into a form that is still being checked. |
| `WhiteHighPercent` / `WhiteLowPercent` / `WhitePixelLevel` | `85` / `10` / `235` | The watchdog's measure of white and dark. |
| `BadScreenSeconds` | `30` | How long a white or dark dashboard is given before it is reloaded. |
| `EpisodeGraceSeconds` | `120` | No white or dark episodes until the dashboard has been on screen once, or this long after the start: the desktop showing before Edge is up is not screen trouble. (The old watchdog's launcher waited 60 s for the same reason.) |
| `ScreenCheck` | `1` | Photograph the screen, as the watchdog did. `0` judges by the page alone. |
| `LoopGuardMaxRestarts` / `LoopGuardWindowMinutes` / `LoopGuardHealthyMinutes` / `LoopGuardRetryMinutes` | `2` / `60` / `5` / `120` | See [Loop guard](#loop-guard). |
| `OffTargetSeconds` | `15` | How long another page is left before the dashboard is opened again. |
| `HealthCheckSeconds` | `10` | How often everything is checked. |
| `ErrorPhrases` / `ErrorChecksBeforeReload` | see script / `3` | Page text that means the station is failing (`HTTP ERROR`, `Service Unavailable`, Edge's own error texts). |
| `MaxReloadsBeforeRelaunch` | `1` | Every second recovery step is a new Edge. |
| `LoginRetryMinutes` | `60` | Pause after the station rejects the sign-in. |
| `LoginHosts` | the hosts of `DisplayURL` and `LoginURL` | The only hosts the password is typed on. |
| `RequireHttps` | `0` | The stations are HTTP (`http://shcz5plc02:302`). Niagara's login page does its own challenge-response, as it did for the old launcher. |
| `InPrivate` | `1` | A clean session every Edge start. |
| `BrowserMode` | `app` | `kiosk`: Edge's own kiosk mode. |
| `Supervised` | `1` | `0`: only start Edge and keep it open. The screen checks and restarts still work. |
| `RestartConfirmSeconds` | `600` | How long after asking for a restart it is recorded as `RESTART_FAILED`. |
| `CredentialFile`, `ProfileDir`, `EdgePath`, `DebugPort`, `BrowserLanguage`, `ExtraBrowserArgs`, `ParkMouse`, `DisplayWaitSeconds` | | Rarely needed; see `Read-LauncherConfig` in the script. |

## Controlling a running launcher

Create the file in the screen's folder, or use `-Command` from your PC. `-Instance S2` picks one screen; without it every screen gets the file.

| File | `-Command` | Effect |
|---|---|---|
| `kill.txt` | `Stop` | Stop the launcher, and so the watchdog, and close Edge. `AGENT_STOP` in the ledger; the collector shows `STALE` after 10 minutes. |
| `relaunch.txt` | `Relaunch` | New Edge. |
| `refresh.txt` | `Refresh` | Reload the dashboard. |
| `restart.txt` | – | Restart the PC in 10 s. |
| `hold.txt` | `Hold` / `Resume` | Pause: no reloads, no restarts, no episodes, until the file is deleted. |
| `snapshot.txt` | `Snapshot` | A screenshot of the page as `Status\<screen>.png`, with the address, state and readings in `Status\<screen>.snapshot.json`. |

```powershell
.\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI9114 -Command Refresh -Instance S2
```

Messages from the Kiosk Fleet Manager (**M**) work as they did with the watchdog.

## Status

```powershell
.\Get-Mach2LauncherNGStatus.ps1
```

| State | Meaning |
|---|---|
| `SHOWING` | The dashboard is on screen. |
| `LOADING` | Opening the dashboard or waiting for it to draw. |
| `SIGNING_IN` | Going through the station's sign-in. |
| `RECOVERING` | Fixing something. The detail says what, and when the next attempt is. |
| `SIGNIN_BLOCKED` | **Needs a person:** wrong or missing password, the account locked. The detail says which. |
| `RESTARTING_PC` | The watchdog asked Windows to restart. |
| `WAITING_DISPLAY` | The configured screen is not connected yet. |
| `HOLD` | `hold.txt` is present. |
| `ERROR` | Edge will not start. Retried with growing pauses. |
| `UNSUPERVISED` | Edge is only kept open. |
| `STALE` | (status tool) The status file has not been written for 3 minutes, so the launcher is not running. |
| `NOT_INSTALLED`, `OLD_LAUNCHER`, `NO_STATUS`, `OFFLINE`, `NO_ACCESS` | (status tool) |

`WD` marks the screen that is the watchdog. `SCREEN` and `PAGE` are the last white readings; normal is between 10% and 85%.

## In the fleet tools

**Collector and Power BI.** An NG kiosk is read as a watchdog kiosk: the ledger, `mwst.log`'s age, the loop guard. Its `AgentVersion` is its version (`1.01NG`), and the collector trusts NG data as it trusts watchdog 6.1 and later. After the watchdog's own statuses (`STALE`, `LOOP_GUARD`), the launcher's status decides. It uses the same names as PBI Launcher's: `SIGNIN_BLOCKED`, `LAUNCHER_ERROR`, `RECOVERING`, `NOT_SHOWING`, `NO_DISPLAY`, `HOLD`, `UNSUPERVISED`, `LAUNCHER_STOPPED`, `LAUNCHER_DISABLED`, `LAUNCHER_STALE` (for a second screen), `LAUNCHER_NOT_RUN`. `Detail` carries `launcher=S1:SHOWING screen=72.4% age=0.2m v1.00NG`, and the collector's status file has the details under `Mach2Launchers`. The measures `Browser Reboots` and `Kiosks on Mach2 Launcher NG` are in `Reports\Measures.dax`.

**Kiosk Fleet Manager.** **Deploy** installs, updates or rolls back NG, and **Add a kiosk...** writes a new kiosk's config first. On a Mach2 kiosk: **Read live**, **Screenshot**, **Reload**, **Restart browser**, **Hold**, **Stop**, **Log**, **Config**, **Password**, and **Message** as to watchdog V7.0. The Mach2 table's `AGENT` column shows the NG version. See [Fleet-Manager.md](Fleet-Manager.md).

## The watchdog

Only the watchdog screen (S1) does this, in `C:\Users\Public\Documents`, exactly where and how watchdog V7.0 did. [Mach2-Watchdog.md](Mach2-Watchdog.md) has the ledger's columns and event types.

- **`mwst.log`**: a heartbeat every 3 minutes (`Heartbeat: Mach2 Launcher 1.01NG alive, dashboard SHOWING, screen 72.4% white, page 71.9% white.`), state changes and everything below. The collector calls a kiosk `STALE` when this file is 10 minutes old.
- **`mwst_events.csv`**: `AGENT_START` / `AGENT_STOP` / `AGENT_ERROR` / `AGENT_RECOVERED`, white and dark episodes (from the screen reading, or the page's without one; from the first time the dashboard is on screen, or after `EpisodeGraceSeconds`), `RESTART_TRIGGERED` / `RESTART_CONFIRMED` / `RESTART_FAILED`, `LOOP_GUARD_ENGAGED` / `LOOP_GUARD_RELEASED`, messages, and Windows' 1074 / 6005 / 6008 records copied verbatim.
- **The messages inbox** `mwst_inbox`, as before.

### When the PC is restarted

Each check sorts what it finds:

| Found | Counts as | Restart after |
|---|---|---|
| The dashboard on screen, not white, not dark | healthy | never |
| Edge closed by itself, will not start, or hangs; the dashboard page white or dark; the page fine but the screen not (something over it) | a problem on this PC | `RebootAfterMinutes` (5) of it. Loading and signing in between two such checks do not stop the clock; two quiet minutes do. |
| Edge's error page (station or network down), a station error on the page, the page somewhere else, loading, signing in | anything else | `OutageRebootMinutes` (30) |
| A sign-in that needs a person, a screen not connected, `hold.txt`, a message on screen | a person's job | never |

Before a restart, the launcher has already reloaded the page and started a new Edge.

The restart itself is the watchdog's, step for step. A `RESTART_TRIGGERED` row is flushed to disk first, then the pending-restart marker. Then comes `shutdown.exe /r /t 15 /f` with the comment `MWST-WATCHDOG <kind> id=<first 8 of the row's EventId> - Mach2 Launcher 1.01NG: <reason>`, which lands in event 1074. The next start confirms it (`RESTART_CONFIRMED`), or, if the PC is still up 10 minutes later, records `RESTART_FAILED`. The kind is `WHITE` or `LOWWHITE` when the screen (or page) read white or dark at the time, and `BROWSER` otherwise. The collector counts all three as script reboots (`WATCHDOG_WHITE`, `WATCHDOG_LOWWHITE`, `WATCHDOG_BROWSER`).

Restarts that someone asked for (`restart.txt`, `ScheduledRestartEnabled`) are tagged `[MACH2-LAUNCHER-NG]` instead, and count as `EXTERNAL`.

### Loop guard

The same as V7.0. After 2 restarts in a row that did not bring the dashboard back (within 60 minutes of each other), the watchdog holds. It writes `LOOP_GUARD_ENGAGED` once, the collector shows `LOOP_GUARD`, and there are no more restarts except one retry every 2 hours. The launcher keeps reloading and restarting Edge meanwhile. Once the dashboard has been on screen for 5 minutes, it writes `LOOP_GUARD_RELEASED`. The count is in `mwst_loopguard.json`; deleting it resets the guard.

## How problems are handled

| The screen shows… | The launcher… |
|---|---|
| The station's sign-in (user name page, then password page, or both on one) | Types the user name, then the password (only on the station's host), and opens the dashboard. |
| "Login Failed" after the password | Stops for `LoginRetryMinutes`. Never more than two password attempts in that window. `SIGNIN_BLOCKED`. |
| The station's home page, or any other page | Opens the dashboard: at once after a sign-in, else after 15 s. |
| A white or dark dashboard | Waits 30 s (it may be loading), then reloads. The next steps are a new Edge, then a reload, with growing pauses. The watchdog restarts the PC after 5 minutes. |
| `HTTP ERROR 500` and the like | Reloads after 3 checks, then with growing pauses (0, 1, 2, 5, 10, 15 min). |
| Edge's error page (station unreachable) | Opens the dashboard again after 0 s, 30 s, 1, 2, 4, then every 5 minutes. |
| A second window | Closes it (a blank one after 10 s, any other after 5 s). |
| The page fine, the screen not | Puts Edge back to full screen and in front, twice, then starts a new Edge. |
| No answer (hung page) | New Edge after 3 checks. |
| Edge closed or crashed | New Edge, which signs in again by itself. |
| Its own console window | Hides it. |
| The old watchdog running | Stops it. |

## Troubleshooting

- **`SIGNIN_BLOCKED`, "rejected the sign-in".** The password changed, or the account is locked in Niagara. Use `-SignInCredential` (see [Password](#password)).
- **`SIGNIN_BLOCKED`, "the password was already entered twice", on a kiosk with a slow link.** The station is not rejecting the password; the launcher is giving up before the station answers. The log shows *"Cannot read the page"* and *"the page stopped responding"* between the two attempts. Raise `SignInWaitSeconds` (and `PageReadTimeoutSeconds` if one read alone takes longer than 15s) in that kiosk's config; the launcher reloads it within seconds and the block is lifted. 1.02NG waits far longer than 1.01NG did.
- **`SIGNIN_BLOCKED`, "only accepts sign-in over HTTPS".** The station was set to require a secure connection. Change `DisplayURL` and `LoginURL` to `https://`.
- **The dashboard is reloaded again and again although it looks right.** Its normal reading is above `WhiteHighPercent` or below `WhiteLowPercent`. `snapshot.txt` and the status file show the readings. Adjust the thresholds for that kiosk.
- **`RECOVERING`: "the dashboard page is fine but the screen reads …".** Something is over Edge: a Windows dialog, another program's window. The launcher brings Edge back to the front. If that keeps happening, look at the screen.
- **`UNSUPERVISED` with a policy message.** The Edge policy *Allow remote debugging* (`RemoteDebuggingAllowed`) is off for this PC. The old launcher's `msedgedriver` needed it too.
- **"Select an app to open this .disabled-by-Mach2LauncherNG file" at logon.** A 1.00NG deploy renamed the old shortcut inside the Startup folder, and Windows tries to open it. Deploy again (1.01NG or later): it moves the file out. Add `-Restart` to clear the dialog on screen now.
- **The old launcher or watchdog still runs.** Something else starts it. On most Mach2 kiosks that is `Mach2LauncherShortcuts.ps1` putting the `StartupLauncher` shortcut back at logon. From 1.01NG the launcher stops both whenever it finds them, logging *"Stopped the old Mach2Launcher.exe …"*. The deploy's `-Restart` check says if either is still there a minute after the dashboard came up. If so, look for `"StopOldLauncher": "0"` in the config.
- **`Launcher S2` exists but no second launcher was installed.** It has no `<HOST>.json`, so it was never a screen. See `LastLauncher` in the old `StartupLauncher` config.
- **To watch it work**, run it on the kiosk in a console, as the kiosk account, after stopping the running one with `kill.txt`:
  `powershell -ExecutionPolicy Bypass -File C:\Users\Public\Documents\Mach2LauncherNG\Mach2LauncherNG.ps1 -Instance S1 -ShowConsole`

## Security notes

- Edge's DevTools port listens on 127.0.0.1 only, on a random port. Any program running on the kiosk could use it, as with the old launcher's `msedgedriver`.
- The password is only typed into a visible password field on a `LoginHosts` host. Those are the station's own hosts, taken from the config.
- `<HOST>.cred` decrypts only for the kiosk account on that kiosk. `password.seed` is overwritten and deleted as soon as it has been read.
- The launcher runs as the kiosk account and needs no admin rights: it restarts the PC through `shutdown.exe`, as the watchdog did. The deploy needs admin rights on the kiosks' `C$` and CIM, for the watchdog's task.

## Tests

```powershell
.\Tests\Test-Mach2LauncherNG.ps1   # launcher + watchdog against a stand-in station; the collector reading it (~15 min)
.\Tests\Test-Mach2LauncherNG.ps1 -Only OldLauncher   # stopping the old launcher, against stand-in processes (~10 s)
.\Tests\Test-Mach2Deploy.ps1       # deploy, rollback, commands, status tool, startup shortcut (~2 min)
```

None of them contacts a real station or kiosk, writes the published CSV, or restarts this PC: the launcher runs with `-SimulateRestart` and `-Headless`. The launcher test starts a stand-in for the old watchdog (a `mwstv4.ps1` under `%TEMP%`) to check that the launcher stops it. Don't run the two at the same time: both start launchers that want to be this session's watchdog.
