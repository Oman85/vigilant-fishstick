# Kiosk Fleet Manager

The window for every kind of kiosk screen: Mach2 dashboards on [Mach2 Launcher NG](Mach2-Launcher-NG.md) (or still the [MWST watchdog](Mach2-Watchdog.md)), Power BI reports on [PBI Launcher](PowerBI-Launcher.md), and web pages on [Web Launcher](Web-Launcher.md) - one launcher per screen, in any mix on one kiosk.

It reads the same single file the Power BI report reads, so it opens instantly, costs nothing to keep open, and needs no credentials until you ask it to do something to a kiosk.

```
 Start-KioskManager.bat ─► Show-FleetManager.ps1  (WPF window, PowerShell 5.1)
                                  │
   reads   MWST_FleetEvents.csv + .status.json ◄── the collector, every 15 min
                                  │
   runs    Collect-MWSTFleet.ps1, Deploy-*.ps1        separate processes, output in Activity
   sends   control files, messages, password.seed ─► the kiosk's C$ share
   reads   the launcher's status, log and screenshot ◄─ the same share
```

Part of [Kiosk Fleet](../README.md). The terminal dashboard (`Start-FleetDashboard.bat`) shows the same fleet in a console, for a session with no desktop.

## The views

| | |
|---|---|
| **Overview** | The headline, the numbers, everything needing attention, a week of reboots, and how fresh the data is. Double-click a kiosk to open it. |
| **Mach2** | The Mach2 kiosks: what the NG launcher is doing on each screen, how white the screen is, the watchdog, its log age and version, uptime and reboots. |
| **Power BI** | The Power BI screens: what the launcher is doing and for how long, which account Power BI is signed in as, its version and the PC's uptime. |
| **Web pages** | The web page screens (Web Launcher): what the launcher is doing and for how long, its version and the PC's uptime. Appears once some kiosk shows a web page or is typed `Web` in the master list. |
| **Deploy** | Pick a launcher, pick kiosks, pick options. The command is shown before anything runs, and a dry run changes nothing. |
| **Activity** | The live output of whatever is running, and the reports of what ran before. |

The headline stays fleet-wide and each tab carries its own count, so trouble on the tab you are not looking at still shows. A kiosk is on **every tab it has a screen for**: a Power BI kiosk whose S2 shows a Mach2 dashboard is on the Power BI tab and the Mach2 tab, and each tab's row shows that tab's launcher. **Other** appears only while some kiosk's type in the master list is neither Mach2 nor Power BI - no kiosk can drop off the screen for having an unexpected type.

Everything on the tables is as of the last scan. **Read live** on a kiosk reads it now.

## A kiosk

Selecting a kiosk opens its details: what the last scan saw, its uptime and reboots, the watchdog, a **SCREENS** list when it has more than one (`S1 - PBI Launcher - SHOWING`, `S2 - Mach2 Launcher NG - SHOWING`), and each launcher it runs, screen by screen. Below that are the things you can do to it.

With more than one screen the card has a **Screen** box: *All screens*, or one of them. The launcher buttons - Reload, Restart browser, Hold, Stop, Screenshot, Log, Password, Config - act on what it says. A web page screen has no password to set.

| Button | What it does | Needs |
|---|---|---|
| **Restart...** | Over CIM/DCOM (`Win32ShutdownTracker`), with a message and a countdown on the kiosk screen, both editable in the card. | nothing extra |
| **Remote control** | SCCM remote control (`CmRcViewer.exe`), in its own window. | the ConfigMgr console |
| **Message...** | A window on the kiosk screen with an OK button and a countdown, put up by its watchdog. The card follows it: shown, acknowledged, timed out, or why not. | Mach2 kiosk, watchdog V7.0 or Mach2 Launcher NG |
| **Open share** | `\\<kiosk>\C$\Users\Public\Documents` in Explorer. | |
| **Read live** | Reads the launcher over the share now: what it is doing, what it shows, which account it signs in as, whether a password is stored, whether it is on hold. | a launcher |
| **Screenshot** | Asks the launcher for a picture of what is on the screen this second, and shows it in the details. Saved in `Logs\snapshots`. | a launcher |
| **Reload** | `refresh.txt`: reload the page. | a launcher |
| **Restart browser** | `relaunch.txt`: a new browser. | a launcher |
| **Hold / Resume** | `hold.txt`: no checks, no reloads, no sign-in and no restarts until you resume. For working on a kiosk without the launcher fighting you. | a launcher |
| **Stop** | `kill.txt`: closes the browser and ends the launcher. The screen stays empty until the kiosk restarts. On a Mach2 kiosk that also stops the watchdog. | a launcher |
| **Log** | The end of the launcher's own log from the kiosk. | a launcher |
| **Config...** | The kiosk's own settings - see [The config editor](#the-config-editor). | |
| **Add screen...** | A new screen on this kiosk - the next free one (S2, S3, …) - with Mach2 Launcher NG, PBI Launcher or Web Launcher. Opens its config, filled from that launcher's `EXAMPLE.json`. | |
| **Password...** | Hands a new sign-in password to the launcher as `password.seed`. The launcher encrypts it for the kiosk account, checks it reads back, and wipes the seed. Only the password changes; the account stays the one in the kiosk config. | a launcher |
| **Deploy...** | Opens Deploy with this kiosk already ticked. | |

A control file is waited for: the launcher deletes it when it has acted, which is how the manager can say *the launcher has taken it* rather than *the file is there*. `hold.txt` stays by design.

While something is being done to a kiosk its buttons are greyed: one thing at a time per kiosk, several kiosks at once.

## The config editor

Each launcher keeps one settings file per screen on the kiosk - `<HOST>.json` in `Mach2LauncherNG\S1\`, `PbiLauncher\S1\` or `WebLauncher\S1\` (`S2`, … for other screens) - and **watches it**: a change applies within seconds, without restarting anything. **Config...** on a kiosk reads that file over the share and shows it:

- The settings that matter are at the top: the **URL** the screen shows, the **sign-in URL** (Mach2), the **account** it signs in as (not for a web page), **which pages count as the page** (`TargetMatch`, web page), and which **screen**. A **sign-in password** can be set at the same time; left empty, whatever is stored on the kiosk stays. A web page has none.
- **More settings** opens the rest of the file - refresh, scheduled restart, zoom, kiosk mode, log paths, the watchdog's minutes - each key exactly as the launcher reads it, so nothing is hidden and nothing is lost on saving.
- Saving keeps the old file as `<HOST>.json.bak-<time>` on the kiosk, writes the new one, and hands the password over as `password.seed` if one was typed.

A kiosk with several screens (S1, S2) asks which one first, unless the card's **Screen** box already says; each screen has its own config, and may run a different launcher.

**A kiosk with no config yet** - a new one - gets the same card filled from `EXAMPLE.json`, with its log name already set and a **screen folder** to write it to (`S1`, or `S2` for a second screen on the same PC). **Add screen...** is the same card for another screen of a kiosk that has one already: pick *New screen S2 - Web Launcher*, say. A screen another launcher has is refused (one launcher per screen). A new Mach2 screen is the watchdog only if it is the kiosk's first Mach2 screen - so S2 is, where Power BI has S1. That is exactly what a deploy needs: without `<HOST>.json` the deploy stops with `NO_CONFIG` and tells you to put one there. Filling this card in *is* putting one there. A sign-in URL left empty becomes the dashboard URL's host plus `/prelogin?clear=true`.

Mach2's `Watchdog` and `WatchdogPath` are the two settings a running launcher will not pick up live; it keeps the ones it started with until it restarts.

## Deploy

1. **What to install** - Mach2 Launcher NG, PBI Launcher, Web Launcher, or the old MWST watchdog on its own (for Mach2 kiosks not moved to NG yet). Web Launcher lists every kiosk: any kiosk can get a web page on a free screen, once its config is written (**Add screen...**).
2. **Kiosks** - the kiosks of that type, with what each one runs now. Tick them. Start with one. **Add a kiosk...** takes a name the last scan never saw - a new kiosk, one that was switched off, or one not in the master list yet - puts it in the list as `NOT SCANNED`, and opens its config so you can enter the URL, the account and the password before deploying. Its row then says *config written, launcher not installed*.
3. **Mode** - install / update, or roll back. The old watchdog has no roll back.
4. **Options** - restart each kiosk and wait for it (with the countdown its screen shows and how long to wait for it to come back), copy the files even if they are there, rewrite the kiosk config from the old launcher, leave the old launcher in place. **Windows account** is the account the kiosk logs on as, for the startup shortcut: left empty the deploy works it out, and a new kiosk whose account is not named after it needs it filled in (`-KioskUser`).
5. **The command** - exactly what will run, with the kiosks and switches spelled out. **copy** puts it on the clipboard for a prompt.
6. **Dry run** changes nothing and shows what would happen. **Deploy** asks once more, then runs it.

The run happens in a separate PowerShell process, as it would from a prompt, and its output appears in **Activity** as it goes. The command is written to `Logs\run\<time>.ps1` first: that is what makes the quoting honest, and it leaves behind exactly what ran.

A deploy does not change what is on screen: the kiosks only report the new state at the next scan. **Scan now** brings it in.

## Scanning

Collection is the scheduled collector's job. Two buttons exist for when you cannot wait:

- **Scan now** runs `Collect-MWSTFleet.ps1` once, with its output in Activity and a progress bar in the header showing which kiosk it has reached.
- **Auto-scan** keeps doing that every 15 minutes (`-AutoScanMinutes`) for as long as the window is open, quietly. The first one is scheduled from the last scan that actually happened, so switching it on next to a scheduled task does not sweep the fleet twice.

Auto-scan refuses to start without the saved kiosk-admin credential: without it every watchdog kiosk comes back `NO_ACCESS`, and those false outages would be written into the history as though they were real.

If the collector is also running on a schedule nothing collides - it takes a machine-wide lock and a second run exits without scanning.

## Credentials

Nothing is asked for until something needs it. `Config\kiosk-admin.cred.xml` is used silently when it exists; otherwise the Windows credential dialog appears the first time you press a button that touches a kiosk, and the answer is kept for as long as the window is open.

Save it once per PC:

```powershell
.\Save-KioskCredential.ps1
```

Deploys and scans are separate processes and get the credential by file (`-CredentialFile`), never on a command line.

That is the account with admin rights on the kiosks. The **sign-in password** a launcher uses - the Niagara station user, or the Power BI account - is a different thing: it is typed into the config card or **Password...**, goes straight to the kiosk as `password.seed`, and the launcher encrypts it there for the kiosk account. It is never written on this PC and never appears on a command line.

## Keys

| | |
|---|---|
| `F5` | Read the CSV again now |
| `Ctrl+F` | Jump to the filter box |
| `Esc` | Close the card that is open |

The tables sort by any column, and the filter box matches the kiosk name, location, status, launcher state or account.

## Freshness

The window re-reads the CSV whenever it changes, and says in the header how long ago the collector last ran. Past `-StaleMinutes` (45 by default, against a 15-minute collector) that line turns red and says **STALE**: a dead collector otherwise looks exactly like a healthy fleet, because every kiosk keeps showing its last known state.

## Options

| | |
|---|---|
| `-View` | Open on `Overview` (default), `Mach2`, `PBI`, `Web`, `Other`, `Deploy` or `Activity`. |
| `-CsvPath` | The events CSV. Default: next to the SharePoint master kiosk list when that is synced here, otherwise `Logs\MWST_FleetEvents.csv`. |
| `-RefreshSeconds` | How often to look for new data. Default 5; the file is only re-read when it has changed. |
| `-StaleMinutes` | When to call the data stale. Default 45. |
| `-AutoScanMinutes` | Auto-scan interval. Default 15. |
| `-AutoScan` | Start with auto-scan on. |
| `-RestartMessage`, `-RestartWarningSeconds` | What a restart shows on the kiosk by default. |
| `-CredentialFile`, `-RemoteControlPath`, `-SccmSiteServer` | Where the tools are, when they are not in the usual places. |
| `-Screenshot <folder>` | Render every view to PNG and exit, without showing a window. For the tests and this guide. |

```powershell
.\Show-FleetManager.ps1 -View Deploy
```

## How it is built

One file, `Show-FleetManager.ps1`: WPF markup in a here-string, the look and the layout, then the code that fills it. No code-behind, no modules, no designer.

- **Reading the fleet** is `Lib\MWST.FleetState.ps1`, shared with the terminal dashboard, so both show the same thing.
- **The tables** bind to a small class with change notification (`KioskFleet.FleetRow`), so a refresh updates the rows in place and the selection, sort and scroll position survive.
- **Anything touching a kiosk** runs in a background runspace and comes back to a callback on the UI thread. The window keeps redrawing while a kiosk that is switched off takes half a minute to say so.
- **Long-running programs** (the collector, the deploy scripts) are separate processes with their output tailed into Activity.
- A callback is handed what it needs (`$Ctx` from the job, `$Data` from the card): a PowerShell scriptblock does not keep the variables of the function that made it, so a handler written as `{ ... $Kiosk.Host ... }` would quietly act on nothing.
- A dispatcher call takes the priority **first**: `Dispatcher.Invoke([DispatcherPriority]::Background, [action]{...})`. Written the other way round, PowerShell picks the overload that passes the priority to the action as an argument, and it fails with *Parameter count mismatch* - which is how the first version closed itself on the first real click in the deploy list. The tests check for it.

## When something goes wrong

An error inside the window no longer closes it. It is written to `Logs\fleet-manager.log` with its full stack, and shown as a red toast; the window carries on. If something still gets past that, a message box says so before the window goes, instead of it simply disappearing (it runs from a hidden console, so there is nowhere else for the message to appear).

Send `Logs\fleet-manager.log` along with the report of what you clicked.

## Tests

```powershell
.\Tests\Test-FleetManager.ps1
```

Builds the whole window without showing it (`-NoShow`) and drives the same functions the buttons do, against fake kiosks under `%TEMP%\KioskFleetGuiTests` with a background job playing the launcher. It checks the tables and the details, every deploy command it can build, a live read, control files, a screenshot, the log, the password hand-over, editing a config and writing a new one from the template, a run from start to finish, and that a restart is confirmed first. Nothing touches a real kiosk, the published CSV or a real deploy.
