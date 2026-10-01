# Kiosk Fleet

One place to watch and manage every kiosk screen:

- **Mach2 kiosks** run Mach2 Launcher ver 1.02NG (`Mach2LauncherNG\Mach2LauncherNG.ps1`), which shows the Mach2 dashboard and is the white-screen watchdog as well. It replaces `Mach2Launcher.exe` and the MWST watchdog. → [Docs/Mach2-Launcher-NG.md](Docs/Mach2-Launcher-NG.md)
  Kiosks not moved to it yet run `Mach2Launcher.exe` and the MWST watchdog (`Agent\mwstv4.ps1`). → [Docs/Mach2-Watchdog.md](Docs/Mach2-Watchdog.md)
- **Power BI kiosks** run PBI Launcher (`PbiLauncher\PbiLauncher.ps1`), which replaces `PowerBILauncher.exe`. → [Docs/PowerBI-Launcher.md](Docs/PowerBI-Launcher.md)
- **Web pages** run on Web Launcher (`WebLauncher\WebLauncher.ps1`): one page, full screen, no sign-in. → [Docs/Web-Launcher.md](Docs/Web-Launcher.md)

**Screens.** Every launcher keeps each screen in a folder of its own (`S1`, `S2`, …), and a screen number belongs to one launcher. So one kiosk can show a Power BI report on S1 and a Mach2 dashboard on S2, or a web page next to either. The collector reads all three launchers on every kiosk, and the manager lists the kiosk on each tab it has a screen for. **Add screen...** on a kiosk sets up the next screen with any launcher.

**Retiring the old launchers.** All three deploys rename the old launchers' JSON files instead of fighting their shortcuts: `Launcher S<n>\<HOST>.json` for each moved screen, and `StartupLauncher`'s configs once it has nothing left to start. The kiosks' logon script (`Mach2LauncherShortcuts.ps1`) puts the `StartupLauncher` shortcut back at every logon, but without a config neither it nor the old launcher does anything (`Lib\MWST.LegacyLauncher.ps1`). `-Rollback` renames them back.

```
 Mach2 kiosk                      this PC                                     SharePoint
 ───────────                      ───────                                     ──────────
 Mach2LauncherNG ─ ledger ─ C$ ─┐
 (or mwstv4.ps1)                │
                                ├─► Collect-MWSTFleet.ps1 ──────────────────► MWST_FleetEvents.csv ──► Power BI report
 Power BI kiosk                 │   (every 15 min, or Scan now)               MWST_FleetEvents.status.json
 ──────────────                 │                                                   │
 PbiLauncher.ps1 ─ status ─ C$ ─┘                                                   ▼
                 ◄─ control files, password.seed ─ C$ ──  Kiosk Fleet Manager (Start-KioskManager.bat)
 Mach2LauncherNG ◄─ deploy, messages ───────────── C$ ──    Overview  Mach2  Power BI  Deploy  Activity
```

Everything goes over the kiosks' admin share (`C$`), plus CIM over DCOM for task registration and restarts. That is all the kiosks allow.

## Start

```bat
Start-KioskManager.bat
```

The first time on a PC, save the kiosk-admin credential. It is DPAPI-encrypted for your account and tested against a kiosk first:

```powershell
.\Save-KioskCredential.ps1
```

## Kiosk Fleet Manager

A window reading the same CSV as the Power BI report, so it opens instantly and needs no credentials until you ask it to do something to a kiosk. → [Docs/Fleet-Manager.md](Docs/Fleet-Manager.md)

| View | |
|---|---|
| **Overview** | The headline, the numbers, everything needing attention, a week of reboots, and how fresh the data is. |
| **Mach2** | The Mach2 kiosks: the NG launcher screen by screen, how white the screen is, the watchdog, log age, version, uptime, reboots. |
| **Power BI** | The Power BI screens: what the launcher is doing and for how long, which account Power BI is signed in as, its version, uptime. |
| **Web pages** | The web page screens: what Web Launcher is doing and for how long, its version, uptime. |
| **Deploy** | Pick a launcher, pick kiosks, pick options; the command is shown before anything runs, and a dry run changes nothing. |
| **Activity** | The live output of whatever is running, and the reports of what ran before. |

Selecting a kiosk opens its details and the things you can do to it: **Restart** (with a message and countdown on its screen), **Remote control** (SCCM), **Message** (Mach2), **Config** (the kiosk's own settings, which the launcher picks up within seconds), and for a kiosk running a launcher **Read live**, **Screenshot** (what is on the screen this second), **Reload**, **Restart browser**, **Hold/Resume**, **Stop**, **Log**, **Password** and **Deploy**. **Scan now** and **Auto-scan** run the collector when you cannot wait for the scheduled one.

A **new kiosk** starts in Deploy: **Add a kiosk...**, then its URL, account and password. That writes the `<HOST>.json` the deploy needs, and the kiosk is ticked and ready to install.

The tables are as of the last scan; **Read live** reads a kiosk now. Sort by any column, filter with `Ctrl+F`, read the CSV again with `F5`.

The same fleet in a console, for a session with no desktop: `Start-FleetDashboard.bat` (`Tab` `1` `2` `3` to switch tabs, `R` `C` `M` `P` `D` `S` `A` `F`, `Q` to quit).

## Files

| | |
|---|---|
| `Start-KioskManager.bat` | Kiosk Fleet Manager, the window (`Show-FleetManager.ps1`). |
| `Start-FleetDashboard.bat` | The same fleet in a console (`Show-FleetDashboard.ps1`). |
| `Run-Collector.bat` | One scan by hand (`Collect-MWSTFleet.ps1`). Kiosks are read 8 at a time (`-ParallelHosts`), so a full scan is seconds rather than minutes. |
| `Install-CollectorTask.ps1` | The 15-minute scheduled scan, as an alternative to auto-scan. |
| `Save-KioskCredential.ps1` | Kiosk-admin credential → `Config\kiosk-admin.cred.xml`. |
| `Deploy-Mach2LauncherNG.ps1` | Mach2 Launcher NG to Mach2 kiosks, retiring `Mach2Launcher.exe` and the MWST watchdog; `-Rollback`; `-Command`. |
| `Get-Mach2LauncherNGStatus.ps1` | A live table of every Mach2 kiosk's launcher, screen by screen. |
| `Deploy-MWSTAgent.ps1` | The MWST watchdog on its own, to Mach2 kiosks not on NG. |
| `Deploy-PbiLauncher.ps1` | PBI Launcher to Power BI kiosks; `-Rollback`; `-Command` (Stop, Refresh, Relaunch, Hold, Resume, Snapshot). |
| `Get-PbiLauncherStatus.ps1` | A live table of every Power BI kiosk's launcher, screen by screen. |
| `Deploy-WebLauncher.ps1` | Web Launcher to any kiosk with a web page screen configured; `-Rollback`; `-Command`. |
| `Get-WebLauncherStatus.ps1` | A live table of every web page screen. |
| `Send-KioskMessage.ps1` | A message on a Mach2 kiosk, from the command line. |
| `Mach2LauncherNG\` | Mach2 Launcher NG, its start script and config template. |
| `Agent\` | The MWST watchdog and its logon launcher. |
| `PbiLauncher\` | The launcher, its start script and config template. |
| `WebLauncher\` | Web Launcher (generated from PBI Launcher), its start script and config template. |
| `Tools\` | `Build-WebLauncher.ps1`: rebuilds `WebLauncher.ps1` after a change to `PbiLauncher.ps1`. |
| `Lib\` | Kiosk list reader, admin-share helpers, message helper, the fleet state both front ends draw (`MWST.FleetState.ps1`), and the launchers' status readers, and the old launchers' retirement (`MWST.LegacyLauncher.ps1`). |
| `Reports\` | Power Query (`MWST_FleetEvents.pq`) and measures (`Measures.dax`) for the Power BI report. |
| `Config\` | The saved credential. |
| `Logs\` | Collector log, local copy of the CSV, deploy reports, screenshots, and the commands the manager ran (`run\`). |
| `Docs\` | The guides linked above. |
| `Tests\` | See below. |

## One collector

The CSV lives on SharePoint next to the master kiosk list, and every copy of the collector writes it. Run it from **this folder only**, on **one PC**:

- `C:\MWST_FLEET` (the watchdog tools before this folder) and `C:\PBI LAUNCHER` (the launcher before this folder) still work, but the old collector knows nothing about PBI Launcher. Each of its scans would reset the Power BI kiosks to a plain ping status, and the next scan from here would set them back, adding a row each time. Don't use the old dashboard's `S` or `A`, and don't schedule the old collector.
- Two collectors on one PC never overlap (they share a lock). Two PCs would produce OneDrive conflict copies.

## Tests

```powershell
.\Tests\Test-FleetManager.ps1       # the manager window: tables, deploy commands, kiosk actions (~1 min)
.\Tests\Test-FleetIntegration.ps1   # collector statuses, dashboard PBI tab, P and D menus (~1 min)
.\Tests\Test-Deploy.ps1             # PBI Launcher deploy, rollback, commands, status tool (~1 min)
.\Tests\Test-PbiLauncher.ps1        # the launcher against a fake tenant in headless Edge (~15 min)
.\Tests\Test-Mach2LauncherNG.ps1    # Mach2 Launcher NG and its watchdog against a fake station (~15 min)
.\Tests\Test-Mach2Deploy.ps1        # Mach2 Launcher NG deploy, rollback, commands, status tool (~2 min)
.\Tests\Test-WebLauncher.ps1        # Web Launcher: the build, the deploy, the launcher against a stand-in site (~3 min)
```

None of them contacts a real kiosk, station or tenant, writes the published CSV, or restarts this PC. Run the two Mach2 ones one after the other, not together.
