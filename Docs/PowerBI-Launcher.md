# PBI Launcher 2.0.1

Shows a Power BI report full screen on the Power BI kiosks and keeps it there. It replaces `PowerBILauncher.exe` (1.0.0.11) and the `StartupLauncher.exe` that started it.

Part of [Kiosk Fleet](../README.md): the fleet collector reports each launcher's state, and the Kiosk Fleet Manager controls it (see [In the fleet tools](#in-the-fleet-tools)).

```
 logon ─► Startup\PBI Launcher S1.lnk ─► conhost ─► powershell (hidden) ─► PbiLauncher.ps1 -Instance S1
                                                                             │
     C:\Users\Public\Documents\PbiLauncher\                                  │ DevTools protocol
       PbiLauncher.ps1                                                       │ 127.0.0.1 only
       S1\  <HOST>.json   settings (old 1.0.0.3 files work as they are)       ▼
            <HOST>.cred   sign-in password, DPAPI-encrypted for the kiosk  Microsoft Edge, full screen,
            Status\       status file, read by Get-PbiLauncherStatus      InPrivate ─► Power BI report
            Logs\         CMTrace log (also copied to RemoteLogPath)
       S2\  ...           a second screen, if the kiosk has one
```

**Screens.** Each screen has a folder of its own (`S1`, `S2`, …), as with [Mach2 Launcher NG](Mach2-Launcher-NG.md) and [Web Launcher](Web-Launcher.md). A screen number belongs to one launcher, so a kiosk can show Power BI on S1 and a Mach2 dashboard or a web page on S2. Up to 2.0.0 the config sat next to the script. A kiosk not deployed to since still runs from there, and the next deploy moves it into `S1`.

## What is different from the old launcher

| | Old (`PowerBILauncher.exe`) | New (`PbiLauncher.ps1`) |
|---|---|---|
| Driving Edge | Selenium + `msedgedriver.exe`, which must match Edge exactly. Every Edge update broke kiosks until the driver share was updated. | Edge's built-in DevTools protocol. No driver, nothing to keep in step with Edge. |
| Password | Plain text in `<HOST>.json`. | DPAPI-encrypted for the kiosk account in `<HOST>.cred`. A plain `Password` in an old config still works, with a warning, and is copied into the encrypted file. |
| Sign-in | InPrivate: full sign-in on every start. | Also InPrivate by default, for the same reason (see next row), with an unattended sign-in on every Edge start. Power BI's own e-mail page is used, so Microsoft is told the account up front. |
| Right account | Not checked. | The launcher reads which account Power BI is signed in as. If it isn't `UserName`, it signs out and signs in again; after three tries in an hour it stops with `SIGNIN_BLOCKED`. On a domain PC, Edge outside InPrivate signs Microsoft sites in with the **Windows account** by itself, which is what the first pilot run showed. |
| Wrong password | Retried on every start. That can lock the account out. | One try, then no retries for 60 minutes (`LoginRetryMinutes`). A new `password.seed` retries at once. |
| MFA prompt | Stuck. | Stops and says so (`SIGNIN_BLOCKED`). `hold.txt` lets a person sign in. |
| Leaving the report | A typo (`$DisplayUR`) relaunched the launcher on any URL change, recursively. | The page is compared by report ID, so Power BI changing the page or query string does not count. A new Edge replaces the old one; the script never restarts itself. |
| Full screen | Clicked a hard-coded XPath. | Real clicks on View → Full screen, found by label, re-applied after every reload and whenever Power BI drops out of it. |
| Links in the report | A link opened a browser window over the report, or the launcher relaunched itself. | The linked page opens in the kiosk window with a **Back to report** button, and the report comes back by itself when nobody uses the page. See [Links in the report](#links-in-the-report). |
| Edge's own sign-in | InPrivate, so none. | Also switched off (`msImplicitSignin`, sync), for when `InPrivate` is set to `0`. Otherwise Edge signs a new profile in with the Windows account and shows a sync dialog over the report. |
| Problems on the page | Not detected. | Power BI errors, a report that draws nothing, Edge error pages, a hung or crashed page and a closed Edge are each fixed automatically, with growing pauses between attempts. |
| Startup check | `StartupLauncher` waited 45 s for a log line; the log kept in `PROJECTS\Launchers` shows `Launcher success = False` after every boot. | Gone. The launcher reports its own state. |
| Visibility | Log files only. | CMTrace log plus a status file per kiosk; `Get-PbiLauncherStatus.ps1` shows the whole fleet. |
| Temp folder | Emptied the user's `%TEMP%` on every start. | Left alone. |

Everything the old config set still works: report URL, user, screen, zoom, interval and daily refresh, scheduled restart, startup delay, disable, central log folder, `kill.txt` / `relaunch.txt` / `restart.txt` / `refresh.txt`.

## Files

| File | What it is |
|---|---|
| `PbiLauncher\PbiLauncher.ps1` | The launcher. Windows PowerShell 5.1, no modules, no other files. |
| `PbiLauncher\Start-PbiLauncher.cmd` | Starts it by hand, the way the startup shortcut does: `Start-PbiLauncher.cmd S1`. |
| `PbiLauncher\EXAMPLE.json` | Config template. |
| `Deploy-PbiLauncher.ps1` | Installs on kiosks over `C$`, migrates the old config, retires the old launcher; `-Rollback`; `-Command`. |
| `Get-PbiLauncherStatus.ps1` | What every Power BI kiosk is doing, screen by screen. |
| `Lib\PBI.Launcher.ps1` | Reads a kiosk's launcher status files for the collector and the dashboard. |
| `Tests\` | `Test-PbiLauncher.ps1` (launcher, ~15 min), `Test-Deploy.ps1` (deploy and status, ~1 min), `Test-FleetIntegration.ps1` (collector, dashboard, P and D menus, ~1 min), `FixtureServer.ps1` (fake sign-in pages and a report with links). |
| `Logs\` | Deploy reports (`deploy_<time>.csv`), screenshots from the dashboard (`snapshots\`). |

The deploy and status scripts use the fleet tools next to them: the kiosk list reader and admin-share helpers in `Lib\`, and the saved kiosk-admin credential (`Config\kiosk-admin.cred.xml`). `-FleetRoot` points them somewhere else.

## Rollout

Run from `C:\KIOSK_FLEET` in Windows PowerShell, or use the Kiosk Fleet Manager: **D** on the PBI tab does the same install, restart or rollback for the kiosks you pick.

**1. Dry run on one kiosk.** Shows what would change and changes nothing.

```powershell
.\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980 -WhatIf
```

**2. Pilot.** Installs, restarts the kiosk (60-second warning on its screen), and waits until the launcher reports the report on screen.

```powershell
.\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980 -Restart
```

Then look at the screen, and at the status:

```powershell
.\Get-PbiLauncherStatus.ps1 -Hosts SHCZ5KPI11980
```

Check two things on the pilot kiosk, because the tests could only imitate them:

- **Sign-in.** The launcher's selectors use the IDs of Microsoft's real sign-in page (`loginfmt`, `passwd`, `idSIButton9`, `KmsiCheckboxField`). On first start it should sign in by itself; the log says `Sign-in: entered user name …`, `… the password`, `… 'Stay signed in?'`, `Signed in.`
- **Full screen.** The log says `Power BI is in full screen.` If it says `View menu was not found`, Power BI's UI is in another language or has changed: set `ViewMenuLabels` / `FullScreenLabels`, or use `"FullScreen": "chromeless"`.
- **Links.** Click a link in the report: the page should open full screen with the **Back to report** button, and the button should bring the report back (log: `Someone opened …`, `Back on the report after …`).

**3. The rest.** One kiosk at a time; the run stops at the first kiosk that does not come back showing its report.

```powershell
.\Deploy-PbiLauncher.ps1 -AllPbiKiosks -Restart
```

`-AllPbiKiosks` takes every Power BI kiosk from the master kiosk list, except those with `ACTIVE = N` and the `PBI - NO SCRIPT` type. Without `-Restart` the new launcher starts at each kiosk's next logon.

### What the deploy does on each kiosk

1. Finds the old launcher's configs: `<HOST>.json` next to `PowerBILauncher.exe` under `C:\Users\Public\Documents\Launchers\Launcher S<n>\` or `…\Launcher S<n>\PowerBILauncher\` (or `Mach2Launchers`). `Launcher S2` is screen S2, so a kiosk with two old Power BI launchers gets two screens.
2. Installs the three files in `C:\Users\Public\Documents\PbiLauncher\`. The copy is hash-checked, the previous version is kept as `.bak-<time>`, and the new file is swapped into place in one step.
3. **Moves a 2.0.0 install into `S1`.** A config next to the script is moved into `S1` with its `<HOST>.cred`, `password.seed`, `hold.txt` and `Status\` (`moved … into S1` in the report).
4. Writes each screen's `S<n>\<HOST>.json` from its old config: same settings, no password, log file renamed from `PowerBI_…` to `PbiLauncher_…` in the same central folder. An existing new config is kept unless you pass `-UpdateConfig`. A screen that [Mach2 Launcher NG](Mach2-Launcher-NG.md) or [Web Launcher](Web-Launcher.md) has already is left to it (`S1 belongs to Mach2 Launcher NG`).
5. If a screen has no `<HOST>.cred` yet, writes `password.seed` there from the old config. The launcher encrypts it on its first start and deletes it.
6. Puts `PBI Launcher S<n>.lnk` in the kiosk account's Startup folder, one per screen, and removes 2.0.0's single `PBI Launcher.lnk`.
7. Retires the old launcher, reversibly, by **renaming its JSON files** (`<name>.disabled-by-PbiLauncher`, next to where they were):
   - each moved screen's old `<HOST>.json`: the old launcher does not run without it, and the kiosks' logon script (`Mach2LauncherShortcuts.ps1`) makes no shortcut for a screen without one;
   - `StartupLauncher\<HOST>.json` and `startup.json`, once nothing `StartupLauncher` starts is still configured. On a kiosk moved one screen at a time, it keeps starting the other old launcher until that one is moved too (`StartupLauncher kept: … still starts …`).

   The `StartupLauncher` shortcut is also moved out of the Startup folder, into `PbiLauncher\Retired shortcuts\<account>\`. The logon script puts it back at every logon; without its config it now starts nothing. (2.0.0 set `DisableStartup = 1` in the old config instead; that is still undone by a rollback.) Everything changed is listed in `migration.json`, the renames under `LegacyJsonRenamed`.

   The shortcut is moved rather than renamed in place. Windows opens *everything* in a Startup folder at logon, whatever it is called. The `*.disabled-by-PbiLauncher` that the first version left there made Windows show *"Select an app to open this file"* on top of the report at every logon (LASER APT). A redeploy moves any such leftover out too.

Results per kiosk: `INSTALLED`, `VERIFIED` (with `-Restart`: every screen showing its report), `NO_CONFIG` (no old launcher to copy settings from: put `<HOST>.json` in `PbiLauncher\S1` first - **Config...** in the Kiosk Fleet Manager does that), `OFFLINE`, `NO_ACCESS`, `FAILED`, `HALTED`. The `Instances` column lists the screens.

### Rollback

```powershell
.\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980 -Rollback -Restart
```

This removes the new shortcuts and moves the old one back into the Startup folder (or renames it back, where the first version renamed it). It renames the old JSON files back (and sets `DisableStartup` back to 0 where 2.0.0 had set it) and stops the new launcher on every screen (`kill.txt`). The installed files stay, so installing again later is quick.

## Password

The launcher never needs the password in plain text on the kiosk for more than a moment:

- **From your PC** (after the account's password changed):
  ```powershell
  .\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980 -SignInCredential (Get-Credential SHPowerBITopCZAPU1@shapecorp.com)
  ```
- **At the kiosk:** drop `password.seed` (the password, one line) into the screen's folder (`PbiLauncher\S1`).
- **At the kiosk, as the kiosk account:** `PbiLauncher.ps1 -Instance S1 -SetPassword`.

A running launcher picks up a new password immediately. `<HOST>.cred` only decrypts for the Windows account that saved it, on that PC. The file is written by the launcher itself, which runs as the kiosk account.

Once every kiosk shows `SHOWING`, delete the old configs (they still hold the password in plain text), or at least their `Password` values. Rollback needs them only as long as you might roll back.

## Configuration

`<HOST>.json` in the screen's folder (`PbiLauncher\S1`). It is re-read when it changes, so an edit applies without a restart; settings that affect Edge itself (URL, screen, zoom, mode) start a new Edge. Values are strings, as in the old files; `"1"`/`"0"` are yes/no.

Settings the old launcher had:

| Key | Default | |
|---|---|---|
| `DisplayURL` | (required) | The report. |
| `UserName` | | Power BI account. |
| `Password` | | Old plain-text password. Works, but use `password.seed` instead. |
| `StaySignedIn` | `1` | Answer to "Stay signed in?". Only matters with `InPrivate` = `0`. |
| `KioskMode` | `1` | Full-screen window. |
| `UsePriScreen` / `ScreenSelect` | `0` / `1` | Primary screen, or `\\.\DISPLAYn`. A screen that is not there yet is waited for (`DisplayWaitSeconds`, 120), then the primary is used. |
| `ZoomPercent` | `100` | 25–500. |
| `EnableRefresh` + `BrowserRefreshDelay` | `0` / `15` | Reload every n minutes. |
| `ForcedRefreshTime` | | Daily reload, `HH:mm`. |
| `ScheduledRestartEnabled` / `ScheduledRestartTime` / `RestartDelay` | `0` / – / `30` | Daily PC restart. Skipped if the PC started less than 30 minutes ago. |
| `StartupDelay` | `0` | Seconds to wait before starting. |
| `DisableStartup` | `0` | `1`: exit at once. |
| `LogPath` / `RemoteLogPath` / `LogName` | `Logs\` / – / `PbiLauncher_<HOST>.log` | |
| `DebugLogging` | `0` | Logs every page check. |

Ignored because there is no Selenium any more: `LoginURL`, `UsernameFieldID`, `PasswordFieldID`, `SubmitBtnID`, `UpdateEdgeDriver`, `EdgeDriverSharePath`, `KillEdgeDriver`, `TempCleanup`, `ElementTimeout`, `ZoomDelay`, `LogDelay`, `JsonVer`.

New, all optional:

| Key | Default | |
|---|---|---|
| `RefreshMinutes` | | Interval reload; overrides the `EnableRefresh` pair. `0` = off. |
| `RefreshTimes` | | Several daily reloads: `"07:55, 13:55"`. |
| `FullScreen` | `click` | `click` (View → Full screen), `chromeless` (adds `chromeless=1` to the URL; Microsoft doesn't document it), `none`. |
| `ViewMenuLabels` / `FullScreenLabels` | `View, Zobrazit` / `Full screen, Fullscreen, Celá obrazovka` | For a Power BI UI in another language. |
| `InPrivate` | `1` | `0` keeps the sign-in in the launcher's Edge profile across restarts, **but on a domain PC Edge then signs Power BI in with the Windows account**. Only for PCs whose Windows account is not a work account. |
| `BrowserMode` | `app` | `kiosk`: Edge's own kiosk mode (always InPrivate). |
| `LoginRetryMinutes` | `60` | Pause after Microsoft rejects the sign-in. |
| `HealthCheckSeconds` | `20` | How often the page is checked. |
| `BlankReloadSeconds` | `180` | Reload a report that has drawn nothing for this long. `0` = off. |
| `ErrorChecksBeforeReload` | `3` | Checks in a row showing a Power BI error before reloading. |
| `ErrorPhrases` | see script | Text that marks a page as broken. |
| `MaxReloadsBeforeRelaunch` | `3` | Every 4th recovery step starts a new Edge instead of reloading. |
| `RebootAfterRelaunches` | `0` (off) | Restart the PC after this many new Edges in 2 hours without the report coming back. Never within an hour of boot, at most once per 12 hours. |
| `Supervised` | `1` | `0`: only start Edge and keep it open. |
| `Instance` | the screen | Ignored in a screen folder: the screen (`S1`) is the instance. Only a config next to the script (2.0.0) is named by it or by its file name. A second screen is a second folder, `S2`, with its own config and startup shortcut. |
| `CredentialFile`, `ProfileDir`, `EdgePath`, `DebugPort`, `BrowserLanguage`, `ExtraBrowserArgs`, `ParkMouse`, `VisualSelector`, `CanvasSelector`, `LoginHosts`, `ReportHosts` | | Rarely needed; see `Read-LauncherConfig` in the script. |

## Links in the report

People can follow links in the report (table hyperlinks, buttons with a Web URL action, links to other reports):

- **The linked page opens in the kiosk window, full screen.** A link that would open a new window, by `target="_blank"` or by `window.open`, is kept in the kiosk window. A window that still gets opened (a link inside an embedded frame, say) is closed within about two seconds and its page shown in the kiosk window instead.
- **Every page that isn't the report has a Back to report button** (bottom left by default), which reopens the report and puts it back in full screen.
- **The report comes back by itself** after `ReturnAfterSeconds` (120) with nobody touching the page. For the last 30 seconds the button counts down. Moving the mouse, touching, scrolling or typing restarts the wait. `0` turns this off.
- While someone is on a linked page, the status is `BROWSING`. The launcher doesn't run its health checks on someone else's site, and interval reloads wait until the report is back.
- The report can also leave the screen for reasons that have nothing to do with a person, for example a redirect straight after sign-in. That is only treated as browsing if the report had been on screen; otherwise the launcher reopens the report after 20 seconds, as before.

| Key | Default | |
|---|---|---|
| `BackButton` | `1` | `0` hides the button. Links are still kept in the window, and the report still comes back when unused. |
| `BackButtonText` | `Back to report` | For example `Zpět na report`. |
| `BackButtonPosition` | `bottom-left` | `top-left`, `top-right`, `bottom-left`, `bottom-right`. |
| `ReturnAfterSeconds` | `120` | Back to the report after this long unused. `0` = only by the button. |
| `KeepLinksInWindow` | `1` | `0`: links open new windows as the site intends; those are closed after a minute. |

The button is drawn by a small script the launcher adds to every page Edge loads. It lives in its own shadow DOM and uses no inline HTML, so a site's styles or security policy can't hide or block it. Sign-in pages get the button but no countdown, so a slow sign-in is never interrupted.

## Controlling a running launcher

Create the file in the screen's folder (`PbiLauncher\S1`), or use `-Command` from your PC. `-Instance S2` picks one screen; without it every screen gets the file.

| File | `-Command` | Effect |
|---|---|---|
| `kill.txt` | `Stop` | Stop the launcher and close Edge. |
| `relaunch.txt` | `Relaunch` | New Edge. |
| `refresh.txt` | `Refresh` | Reload the report. |
| `restart.txt` | – | Restart the PC in 10 s. |
| `hold.txt` | `Hold` / `Resume` | Pause: the launcher does nothing until the file is deleted. Use it to sign in by hand. |
| `snapshot.txt` | `Snapshot` | Save a screenshot of the page as `Status\<screen>.png`, with the address, state and signed-in account in `Status\<screen>.snapshot.json`. |

```powershell
.\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980,SHCZ5KPI11982 -Command Refresh
.\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980 -Command Hold -Instance S2
```

Closing the Edge window at the kiosk just gets it reopened. Use `kill.txt` or `hold.txt` to keep it closed.

## Status

```powershell
.\Get-PbiLauncherStatus.ps1
```

| State | Meaning |
|---|---|
| `SHOWING` | Report on screen. |
| `BROWSING` | Someone followed a link out of the report (see [Links in the report](#links-in-the-report)). |
| `LOADING` | Opening the report or switching to full screen. |
| `SIGNING_IN` | Going through Microsoft's sign-in. |
| `RECOVERING` | Fixing a problem (the detail says which, and when the next attempt is). |
| `SIGNIN_BLOCKED` | **Needs a person:** wrong or missing password, MFA, wrong account. The detail says which. |
| `WAITING_DISPLAY` | The configured screen is not connected yet. |
| `HOLD` | `hold.txt` is present. |
| `ERROR` | Edge will not start, or Power BI refuses the account: no license (sent to signup.microsoft.com) or throttled (429). Retried with growing pauses (1, 2, 5, 10, then every 15 min); Detail says which and when the next try is. |
| `UNSUPERVISED` | Edge is only kept open: `Supervised = 0`, or the Edge policy `RemoteDebuggingAllowed` is off. |
| `STALE` | (status tool) The launcher has not written its status for 3 minutes, so it is not running. |
| `NOT_INSTALLED`, `NO_STATUS`, `OFFLINE`, `NO_ACCESS` | (status tool) |

The log (`Logs\` and `RemoteLogPath`) is in CMTrace format and says what happened and why: every state change, sign-in step, reload and recovery. The password is never written anywhere.

## In the fleet tools

### Collector and Power BI report

On every scan the collector reads the status files of every screen (`PbiLauncher\S<n>\Status\*.status.json`, and `PbiLauncher\Status\` on a kiosk not moved yet) over `C$`, next to its ping - on every kiosk it scans, not only Power BI ones, since any screen can run any launcher - and turns the launcher's state into the kiosk's status in `MWST_FleetEvents.csv`:

| Status | Severity | Meaning |
|---|---|---|
| `LAUNCHER_STALE` | critical | The status file has not been written for 5 minutes (`-PbiStaleMinutes`), so the launcher is not running. |
| `LAUNCHER_STOPPED` | critical | Stopped with `kill.txt`. The screen is empty until the next logon. |
| `LAUNCHER_ERROR` | critical | Edge will not start, or Power BI refuses the account (no license, 429). |
| `SIGNIN_BLOCKED` | critical | Sign-in needs a person: password, MFA or repeated wrong account. |
| `WRONG_ACCOUNT` | critical | Power BI is signed in as someone other than `UserName`. |
| `RECOVERING` | warning | Fixing an error or a blank report. |
| `NOT_SHOWING` | warning | Loading or signing in for more than 15 minutes. |
| `NO_DISPLAY` | warning | The configured screen is not connected. |
| `HOLD` | warning | `hold.txt` is in place. |
| `UNSUPERVISED` | warning | Only keeping Edge open. |
| `LAUNCHER_DISABLED` | warning | `DisableStartup` is set. |
| `LAUNCHER_NOT_RUN` | warning | Installed, but has not started yet (no restart or logon since). |
| `OK` | | Report on screen, or someone is using a link from it. |

With several screens on one kiosk - two Power BI screens, or Power BI next to a Mach2 dashboard or a web page - the worst screen decides. The row's `AgentVersion` is `pbi-<version>` (the `Kiosks on PBI Launcher` measure counts them) unless the kiosk has a watchdog (Mach2 Launcher NG on another screen), `BootTimeUtc` and `UptimeHours` come from the launcher, and `Detail` carries each screen's state and signed-in account (`launcher=S1:SHOWING as=… age=0.2m v2.0.1`). A kiosk still on the old `PowerBILauncher.exe` keeps its plain ping status, with `launcher=old` in the detail.

The launcher's details (state, for how long, account, counters, last error) also go into `MWST_FleetEvents.status.json` under `PbiLaunchers`, for the dashboard.

### Kiosk Fleet Manager

The PBI tab adds the columns `LAUNCHER` (the launcher's state; `old launcher` or `no launcher` where it is not installed; in brackets when stale), `FOR`, `SIGNED IN AS` (red when it is the wrong account), `VER` and `UPTIME`, as of the last scan.

The window's **Kiosk Fleet Manager** does all of this per screen; see [Fleet-Manager.md](Fleet-Manager.md). The console dashboard's **P** opens one Power BI kiosk (its first Power BI screen) and reads its launcher live:

| Key | |
|---|---|
| `1` | Reload the report (`refresh.txt`). |
| `2` | Restart Edge (`relaunch.txt`). |
| `3` | Screenshot: `snapshot.txt`, then the picture is copied to `Logs\snapshots\` and opened, with the address, state, signed-in account and number of visuals. |
| `4` | Hold, or resume a held launcher. |
| `5` | Stop the launcher (`kill.txt`, typed `YES`). |
| `L` | The last 40 lines of the launcher's log, warnings and errors in colour. |
| `P` | Set the sign-in password: typed twice, handed over as `password.seed`, and the menu waits until the launcher has stored it. |
| `I` | Install or update (`Deploy-PbiLauncher.ps1`), now, with a restart, or as a dry run. |
| `B` | Roll back to the old launcher, the same way. |

Each control file is waited for: the menu says when the launcher has taken it, or that nobody did (launcher not running). **D** on the PBI tab installs, updates or (with `R` in front of the kiosk numbers) rolls back several kiosks at once. **M** refuses Power BI kiosks, which have no watchdog to show a message.

## How problems are handled

| The page shows… | The launcher… |
|---|---|
| Microsoft sign-in | Types the account into Power BI's e-mail page (or picks its tile, or types the user name), types the password (only into a visible password field on `login.microsoftonline.com` over HTTPS, for the configured account), answers "Stay signed in?". |
| Power BI signed in as another account | Clears the session, starts a clean Edge and signs in again. Three times in an hour at most, then `SIGNIN_BLOCKED`. |
| A rejected sign-in | Stops for `LoginRetryMinutes`. Never more than two password attempts in that window. |
| MFA or "more information required" | Stops for 30 minutes and says a person is needed. |
| A Power BI error (`ErrorPhrases`) | Reloads after 3 checks. |
| A report that has drawn nothing for 3 minutes | Reloads. |
| Both of the above, again and again | Waits 0, 1, 3, 7, 15, then 30 minutes between attempts; every 4th attempt is a new Edge. |
| An Edge error page (network down) | Opens the report again after 0 s, 30 s, 1, 2, 4, then every 5 minutes. |
| Another page, after someone followed a link | Leaves it: Back button, and back to the report after `ReturnAfterSeconds` unused. |
| Another page, any other time | Opens the report again after 20 s (allowing for redirects). |
| A new window from a link | Closes it and shows its page in the kiosk window (about 2 s). |
| Any other extra window | Closes it: a sign-in popup after a minute, a blank one after 10 s. |
| No answer (hung page) | New Edge after 3 checks. |
| Edge closed or crashed | New Edge, which signs in again by itself. |

## Troubleshooting

- **"Select an app to open this .disabled-by-PbiLauncher file" at logon.** The first version of the deploy renamed the old shortcut inside the Startup folder, and Windows tries to open it. Deploy again: it moves the file out. Add `-Restart` to clear the dialog on screen now.
- **`SIGNIN_BLOCKED`, "rejected".** The password changed. Run `-SignInCredential` (see [Password](#password)).
- **Power BI shows the kiosk's own (Windows) account.** Edge's Windows single sign-on. Keep `InPrivate` at `1`. The status file's `SignedInAs` and the log (`signed in as …, not …`) show what the launcher found.
- **`SIGNIN_BLOCKED`, "extra verification".** On the kiosk: create `hold.txt`, sign in in the Edge window, and delete `hold.txt`. Long term, the kiosk account needs a Conditional Access exception, as it had for the old launcher.
- **`UNSUPERVISED` with a policy message.** The Edge policy *Allow remote debugging* (`RemoteDebuggingAllowed`) is disabled for this PC. The policy covers the same remote-debugging switches that `msedgedriver` uses, so the old launcher depended on it as well.
- **The console window shows.** The log line `Console window:` says why. `still visible` means the console is Windows Terminal: start the launcher through the shortcut or `Start-PbiLauncher.cmd`, which use `conhost`.
- **Report on the wrong screen.** The log lists the screens at startup (`Screen DISPLAY1: …`); set `ScreenSelect`.
- **`Cannot find the report canvas`.** Power BI changed its page, so blank-report detection is off for it; everything else still works. Set `CanvasSelector` / `VisualSelector`, or `BlankReloadSeconds: 0`.
- **To watch it work**, run it on the kiosk in a console, as the kiosk account:
  `powershell -ExecutionPolicy Bypass -File C:\Users\Public\Documents\PbiLauncher\PbiLauncher.ps1 -ShowConsole`
  Stop the running one first with `kill.txt`.

## Security notes

- Edge's DevTools port listens on 127.0.0.1 only, on a random port. Any program running on the kiosk could use it, as with the old launcher's `msedgedriver`.
- The password is typed only into a visible password field on a sign-in host from `LoginHosts`, over HTTPS, when the page shows the configured account.
- `<HOST>.cred` decrypts only for the kiosk account on that kiosk. `password.seed` is overwritten and deleted as soon as it has been read.
- The Back button script runs in every page the kiosk shows. It replaces `window.open` so that web links stay in the kiosk window; sign-in popups and blank windows are passed through unchanged. It sends nothing anywhere; the launcher only reads how long the page has been unused.
- Edge runs InPrivate, so Windows single sign-on can't sign Power BI in with the PC's account, and nothing of the session is kept on disk after Edge closes. The launcher also checks the signed-in user name and signs out anything else.
- The launcher runs as the kiosk account and needs no admin rights. The deploy needs admin rights on the kiosks' `C$`.

## Tests

```powershell
.\Tests\Test-PbiLauncher.ps1       # launcher: unit checks + headless Edge against a fake tenant
.\Tests\Test-Deploy.ps1            # deploy, rollback, commands, status tool, startup shortcut
.\Tests\Test-FleetIntegration.ps1  # collector statuses, dashboard PBI tab, P and D menus
```

None of them contacts a real tenant or kiosk, or writes the published CSV. The launcher tests use a headless Edge with its own profile; an Edge you have open is left alone.
