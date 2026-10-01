# Web Launcher 1.0.0

Shows one web page full screen on a kiosk screen and keeps it there. There is no sign-in and no password: the launcher shows the page as it comes, and puts it back when it goes wrong.

Part of [Kiosk Fleet](../README.md). It is [PBI Launcher](PowerBI-Launcher.md) without Power BI, and it is generated from it, so both share the same core. A screen can show a web page next to a Power BI report or a Mach2 dashboard on another screen of the same kiosk.

```
 logon ─► Startup\Web Launcher S2.lnk ─► conhost ─► powershell (hidden) ─► WebLauncher.ps1 -Instance S2
                                                                             │
     C:\Users\Public\Documents\WebLauncher\                                  │ DevTools protocol
       WebLauncher.ps1                                                       │ 127.0.0.1 only
       S2\  <HOST>.json   the page and the settings                         ▼
            Status\       status file, read by the collector            Microsoft Edge, full screen,
            Logs\         CMTrace log (also copied to RemoteLogPath)     InPrivate ─► the page
```

## What it does

| The screen shows… | The launcher… |
|---|---|
| The page | `SHOWING`. Reloads it every `RefreshMinutes` / at `ForcedRefreshTime`, if set. |
| Another page of the same site | Nothing, as long as it counts as the page (see `TargetMatch`). |
| Another page, after the page was up | `BROWSING`: someone followed a link. The page gets a **Back** button, and the configured page comes back by itself after `ReturnAfterSeconds` (120) without use. Links that would open a new window open in the kiosk window. |
| Another page before the page was ever up | Opens the page again after `OffTargetSeconds` (20). A site may take a redirect or two to get there. |
| Edge's own error page (site or network down) | Opens the page again after 0 s, 30 s, 1, 2, 4, then every 5 minutes. |
| Error text on the page (`HTTP ERROR`, `503 Service Unavailable`, … - `ErrorPhrases`) | Reloads after 3 checks, then with growing pauses (0, 1, 3, 7, 15, 30 min). Every fourth attempt is a new Edge. |
| Nothing: no text, no pictures, for `BlankReloadSeconds` (120) | Reloads, the same way. |
| A second window | Closes it (or brings the link into the kiosk window). |
| No answer, a crashed page, Edge closed | New Edge. |

It never restarts the PC on its own, except with `RebootAfterRelaunches` or a `ScheduledRestartTime`. The kiosk's watchdog, if it has one, is Mach2 Launcher NG on another screen.

## Files

| File | What it is |
|---|---|
| `WebLauncher\WebLauncher.ps1` | The launcher. Generated from `PbiLauncher\PbiLauncher.ps1` by `Tools\Build-WebLauncher.ps1`: **change PbiLauncher.ps1 and rebuild**, not this file. `Tests\Test-WebLauncher.ps1` fails if the two have drifted apart. |
| `WebLauncher\Start-WebLauncher.cmd` | Starts it by hand, the way the startup shortcut does: `Start-WebLauncher.cmd S2`. |
| `WebLauncher\EXAMPLE.json` | Config template. |
| `Deploy-WebLauncher.ps1` | Installs on kiosks over `C$`, one startup shortcut per screen; `-Rollback`; `-Command`. |
| `Get-WebLauncherStatus.ps1` | What every web page screen is doing (`Get-PbiLauncherStatus.ps1 -Launcher Web`). |
| `Tools\Build-WebLauncher.ps1` (+ `.Parts.ps1`) | Builds the launcher from PBI Launcher: drops the sign-in, password, account and Power BI code by name, and puts in the web page's own config, page check and health check. |

## Setting one up

1. **The config.** In the Kiosk Fleet Manager, select the kiosk and press **Add screen...**, then choose *New screen S2 - Web Launcher* (or the next free screen). Fill in the page URL. That writes `WebLauncher\S2\<HOST>.json`. By hand: copy `EXAMPLE.json` there and set `DisplayURL`.
2. **Deploy.** In **Deploy** pick *Web Launcher* (every kiosk is listed, since any kiosk can get a web page on a free screen), tick the kiosk, dry run, then deploy. Or:

   ```powershell
   .\Deploy-WebLauncher.ps1 -Hosts SHCZ5KPI11980 -WhatIf
   .\Deploy-WebLauncher.ps1 -Hosts SHCZ5KPI11980 -Restart
   ```

   With `-Restart` the kiosk restarts (countdown on its screen) and the deploy waits until every web page screen reports `SHOWING`.

**What the deploy does:** installs the three files (hash-checked, the previous copy kept as `.bak-<time>`), puts `Web Launcher S<n>.lnk` in the kiosk account's Startup folder for every screen with a config, and records it all in `migration.json`. It refuses a screen that Mach2 Launcher NG or PBI Launcher has (one launcher per screen). If an old launcher (`Mach2Launcher.exe` or `PowerBILauncher.exe` in `Launcher S<n>`) ran on that screen, its `<HOST>.json` is renamed (`.disabled-by-WebLauncher`), and so are `StartupLauncher`'s configs once nothing it starts is still configured, exactly as the other deploys retire it (see [Mach2-Launcher-NG.md](Mach2-Launcher-NG.md#what-the-deploy-does-on-each-kiosk)). `-KeepLegacy` leaves the old launcher alone.

Results: `INSTALLED`, `VERIFIED` (with `-Restart`), `NO_CONFIG` (no screen has a config yet), `OFFLINE`, `NO_ACCESS`, `FAILED`, `HALTED`. The report is `Logs\web-deploy_<time>.csv`.

**Rollback** (`-Rollback`) removes the shortcuts, renames the old launcher's JSON back and stops the launcher on every screen (`kill.txt`). The files and configs stay.

## Configuration

`<HOST>.json` in the screen's folder (`WebLauncher\S2`). It is re-read when it changes; settings that affect Edge itself (URL, screen, zoom, mode) start a new Edge.

| Key | Default | |
|---|---|---|
| `DisplayURL` | (required) | The page. `http`, `https` or `file`. |
| `TargetMatch` | `path` | Which pages count as the page: `path` - the same host, and a path that starts with the configured one (a site that redirects `/` to `/home`, or moves between its own pages under it, stays "on the page"); `host` - anywhere on the same host; `exact` - only this address. |
| `KioskMode` | `1` | Full-screen window. |
| `UsePriScreen` / `ScreenSelect` | `0` / `1` | The primary screen, or `\\.\DISPLAYn`. A screen that is not there yet is waited for (`DisplayWaitSeconds`, 120). |
| `ZoomPercent` | `100` | 25–500. |
| `EnableRefresh` + `BrowserRefreshDelay`, or `RefreshMinutes` | off | Reload every n minutes. |
| `ForcedRefreshTime` | | Daily reload, `HH:mm` (several: comma-separated). |
| `BackButton` / `BackButtonText` / `BackButtonPosition` | `1` / `Back` / `bottom-left` | The button on a linked page. |
| `ReturnAfterSeconds` | `120` | Back to the page after a linked page has not been used this long. `0` = never. |
| `KeepLinksInWindow` | `1` | Links that would open a new window open in the kiosk window. |
| `ErrorPhrases` | see script | Text on the page that means the site is failing. |
| `BlankReloadSeconds` | `120` | How long a page with nothing on it is given. `0` = never reload for it. |
| `OffTargetSeconds` | `20` | How long another page is left before the page is opened again (before the page was ever up). |
| `InPrivate` | `1` | A clean session every Edge start. |
| `ScheduledRestartEnabled` / `ScheduledRestartTime` / `RestartDelay` | `0` / – / `30` | Daily PC restart. |
| `StartupDelay`, `DisableStartup`, `LogPath`, `RemoteLogPath`, `LogName`, `DebugLogging`, `HealthCheckSeconds`, `RebootAfterRelaunches`, `Supervised`, `BrowserMode`, `ProfileDir`, `EdgePath`, `DebugPort`, `ExtraBrowserArgs` | | As in [PBI Launcher](PowerBI-Launcher.md#configuration). The default log is `WebLauncher_<HOST>.log` on S1, `WebLauncher_<HOST>_S<n>.log` on other screens. |

## Controlling a running launcher

The same control files as PBI Launcher, in the screen's folder: `kill.txt`, `relaunch.txt`, `refresh.txt`, `restart.txt`, `hold.txt`, `snapshot.txt`. From your PC:

```powershell
.\Deploy-WebLauncher.ps1 -Hosts SHCZ5KPI11980 -Command Refresh -Instance S2
```

or the kiosk's buttons in the Kiosk Fleet Manager, with the **Screen** box set to the web page's screen.

## Status

```powershell
.\Get-WebLauncherStatus.ps1 -Hosts SHCZ5KPI11980
```

States: `SHOWING`, `BROWSING`, `LOADING`, `RECOVERING`, `WAITING_DISPLAY`, `HOLD`, `ERROR`, `UNSUPERVISED`, `DISABLED`, `STOPPED`, `RESTARTING_PC`; the tool adds `STALE`, `NOT_INSTALLED`, `NO_STATUS`, `OFFLINE`, `NO_ACCESS`.

The collector reads `WebLauncher\S<n>\Status\` on every kiosk it scans and gives the kiosk the same host statuses as PBI Launcher (`LAUNCHER_STALE`, `LAUNCHER_ERROR`, `RECOVERING`, …), worst screen first. A kiosk that only shows web pages reports `web-<version>` as its agent and `web=S1:SHOWING …` in the detail. The Kiosk Fleet Manager shows web page screens on its **Web pages** tab. A kiosk typed `Web` in the master kiosk list is scanned like a Power BI kiosk (ping and launchers, no watchdog expected).

## Tests

```powershell
.\Tests\Test-WebLauncher.ps1   # the build, the URL rule, the deploy on fake kiosks, the launcher against a stand-in site (~3 min)
```
