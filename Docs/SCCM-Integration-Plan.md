# Kiosk Fleet toolkit in ConfigMgr / Software Center: plan

Draft of 2026-09-21. Nothing has been created in ConfigMgr yet, and no kiosk
has been changed for this plan. The facts below come from a read-only survey
of site SC1.

## The short version

| Part | Where it goes | How |
|---|---|---|
| **Fleet Manager** (GUI, dashboard, deploy and status tools) | Admin PCs | A Software Center app, *Available* to an IT-admin user collection. Code goes to Program Files. Logs and credentials go to each admin's profile. |
| **Mach2 Launcher NG** | Mach2 kiosks | An application, *Required* for a device collection, hidden from Software Center. It installs locally as SYSTEM and uses the same deploy logic as today (a new `-Local` mode). |
| **PBI Launcher** | Power BI kiosks | Same approach as Mach2 Launcher NG. |
| **Collector** (feeds the CSV, the manager and Power BI) | One server | A single scheduled task under a service account (gMSA). It is not packaged for admin PCs, because a second copy would mean two writers. |
| **Master kiosk list** | A network share (later) | A **setting**, not code. Every tool reads the path from one place. On the day the list moves, one value changes; no new package is needed. |
| **Collections** | ConfigMgr | Built from the master list by a sync script, which runs as a dry run by default. |

Some things stay on the admin-share (C$) channel, because ConfigMgr is not a
real-time channel:

- passwords;
- per-kiosk URLs and configs;
- live commands (Stop, Refresh, Hold, Snapshot, and so on);
- messages to kiosks;
- break-glass repairs.

## What the survey found (read-only)

| Fact | Consequence |
|---|---|
| Site **SC1**, management point `SHGHMGT08.shapecorp.com`. The console and `ConfigurationManager.psd1` are on SHAPE12527. | The collection-sync script and packaging can run from an admin PC. |
| The kiosks are active ConfigMgr clients, version 5.00.9135.1013. | No client work is needed. |
| No collection or application exists for these kiosks. *Shape Visitor Kiosks* (SC100134) holds 7 other machines (`SH*VK*`), none of ours. | Everything is new; nothing needs to be migrated. |
| TV4 is in 32 collections, including **"Workstation \| Maintenance Windows \| Backup"** (SC1001F8). That collection has **three daily 2-hour windows, at 01:00, 09:00 and 17:00**, for all deployment types. TV4 is also in the *Patch: Workstation - Office PCs* collections. | Windows from every collection apply together. A kiosk-only 01:00 window would not remove the 09:00 and 17:00 ones. ConfigMgr may already be able to restart TVs mid-shift for patches. Only TV4 was checked. |
| The Default Client Agent Settings have `PowerShellExecutionPolicy = 1`. I read this as *Bypass*; the product default is *All Signed*. | Unsigned detection scripts would run. Confirm the value in the console. Signing is still recommended (see Security). |
| Reading this PC's own client policy was refused (access denied, not elevated). This account's ConfigMgr security role was not determined. | Someone with *Application Administrator* rights may have to create the objects. |
| The launchers install to `C:\Users\Public\Documents\Mach2LauncherNG` and `...\PbiLauncher`. They start from the kiosk account's Startup folder. The old watchdog is disabled as a scheduled task. | All of this can be done locally as SYSTEM. |
| The deploy already migrates the password from the old launcher's config on the kiosk (`SEED_FROM_OLD_LAUNCHER`). | **No password is needed in any package.** |
| With no config file, NG stops with *"No config file"*. | A package must not create the Startup shortcut on a kiosk that has no config yet. |
| Launcher configs have `ScheduledRestartTime`. EXAMPLE.json uses `06:00`. | An install can take effect at the next scheduled restart, so ConfigMgr does not need to restart the kiosk. |

## 1. The master list on a network drive

Today `Resolve-KioskListPath` (in `Lib\MWST.KioskList.ps1`) searches OneDrive
sync roots for `MASTER_KIOSK LIST.xlsx`. If that fails, it uses a copy next to
the scripts. It has **8 callers**:

- the collector;
- both deploy scripts;
- both status scripts;
- the MWST agent deploy;
- Save-KioskCredential;
- the shared fleet-state lib, which the GUI and the dashboard use.

Changing this one function moves every tool.

### The change

1. **A settings layer**, `Lib\MWST.Settings.ps1`. Each setting is taken from the
   first of these that has it:
   1. The machine policy `HKLM\SOFTWARE\Policies\KioskFleet`. ConfigMgr (a
      configuration baseline) or GPO sets it, so the path can change without
      repackaging.
   2. `Config\fleet-settings.json` beside the scripts, shipped in the package.
   3. `%LOCALAPPDATA%\KioskFleet\fleet-settings.json`, a per-admin override for
      testing.

   The settings:

   | Setting | Meaning |
   |---|---|
   | `KioskListPath` | The UNC path of the master list, for example `\\server\share\KIOSKS\MASTER_KIOSK LIST.xlsx`. Empty means today's OneDrive behaviour. |
   | `AllowOneDriveFallback` | `true` until the move, `false` after it. |
   | `EventsCsvPath` | Where the collector publishes `MWST_FleetEvents.csv`. It no longer follows the list's folder automatically (see Power BI below). |
   | `ListCacheDir` | Where the last good copy of the list is kept. |

2. **The new lookup order in `Resolve-KioskListPath`:**
   1. explicit `-KioskList`;
   2. `KioskListPath` (network);
   3. the cached last good copy, reported as *"cached copy of the network list
      from <time>"*;
   4. OneDrive, only if `AllowOneDriveFallback` is on;
   5. the local fallback, as today.

   Every successful network read refreshes the cache. A share outage then
   degrades to a clearly labelled stale list instead of *"nothing to scan"*.
   This keeps the existing rule: a fallback is reported, never used silently.

3. **Always a UNC path, never a mapped drive letter.** SYSTEM, the collector's
   service account, scheduled tasks and elevated sessions do not see a user's
   `S:` drive.

4. **Two-lists guard.** During the transition, the resolver warns in the
   collector log and in the manager's status bar when it finds both copies and
   the OneDrive one is newer. That means someone edited the old copy.

### The day it moves

1. Copy the workbook to the share.
2. Set `KioskListPath`, and set `AllowOneDriveFallback = false`.
3. Rename the SharePoint copy to `MASTER_KIOSK LIST - MOVED.xlsx`, or make it
   read-only, so nobody keeps editing it.

Nothing is repackaged. Until then the setting stays empty and everything
behaves as it does today.

### Things the move changes

- **Power BI.** Today the collector publishes the CSV **next to the list**,
  which is the SharePoint library, presumably where the report reads it. When
  the list goes to a file share, the CSV must not simply follow it, or the
  report's refresh breaks. `EventsCsvPath` decouples the two. The options are:
  - (a) keep the CSV in SharePoint. That needs an upload step, because a server
    service account has no OneDrive sync.
  - (b) put the CSV on the share and add an **on-premises data gateway** for
    scheduled refresh.

  This is a decision for the report's owner.
- **Co-authoring is lost.** On a file share only one person can edit the
  workbook at a time. The toolkit reads a temp copy, so an open workbook does
  not block scans. This must be tested with the file open in Excel on another
  PC.
- **Share permissions:**
  - Read: the kiosk-admin group, the collector's account and the account that
    runs collection sync.
  - Modify: the list owners.
  - Kiosks: no access; they never read the list.

## 2. Fleet Manager as a Software Center app (admin PCs)

**Application:** *Kiosk Fleet Manager <version>*.

- **Deployment:** script installer, install for system, deployed *Available*
  to a user collection built from the admins' AD group.
- **Install:** `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Install.ps1`
  1. copies the toolkit to `C:\Program Files\KioskFleet\`, where users cannot
     write;
  2. writes `Config\fleet-settings.json`;
  3. creates Start-menu shortcuts: *Kiosk Fleet Manager* (hidden PowerShell,
     the same as `Start-KioskManager.bat`) and *Kiosk Fleet Dashboard*.
- **Detection:** `HKLM\SOFTWARE\KioskFleet\Toolkit` `Version` equals the
  package version, plus `Show-FleetManager.ps1` exists.
- **Uninstall:** removes the folder and the shortcuts. It leaves each admin's
  data.
- **Upgrades:** a new application version supersedes the old one.

### Code change: split code from data

Today the tools write `Logs\`, `Config\`, `Reports\`, `Logs\run\` and
`Logs\snapshots\` next to themselves. That fails under Program Files.

Add `Get-FleetDataRoot`. It keeps today's behaviour (the folder next to the
scripts) when that folder is writable, and uses `%LOCALAPPDATA%\KioskFleet`
otherwise.

This affects:

- `Show-FleetManager.ps1`;
- both deploy scripts;
- both status scripts;
- `Save-KioskCredential.ps1`;
- `Collect-MWSTFleet.ps1`;
- `Install-CollectorTask.ps1`.

### Credentials

`kiosk-admin.cred.xml` is DPAPI: one user, one PC. It cannot be packaged or
copied. On first run, the manager already offers to save a credential; each
admin does this once.

### Tools

None. Restarts and task registration go over CIM/DCOM, so the package no
longer needs `psshutdown64.exe` or `psexec.exe`.

### "Scan now" and Auto-scan

When the collector runs on the server (section 3), the manager reads the
published CSV.

- **Scan now** starts the server task (`schtasks /Run /S <server> /TN "\MWST\MWST Fleet Collector"`)
  if the admin has rights. Otherwise it is hidden.
- **Auto-scan** is off, so a second writer never appears.

### Deploy view

It gains an *"SCCM-managed"* banner for kiosks in the kiosk collections. Hand
deploys stay possible for pilots and repairs. The banner explains that
ConfigMgr will re-apply its version: a hand rollback lasts only until the next
application evaluation (every 7 days by default) unless the kiosk is in
*Kiosks | Excluded*.

## 3. The collector as one server job

**Today:** a scheduled task on one admin's PC. It runs as that user at logon,
with a stored credential. Its mutex (`Global\MWST_FLEET_COLLECTOR`) is **per
machine**, so two PCs running it would both write the same CSV.

**Proposed:**

- It runs on one server, for example `shghmgt09`, which already holds the
  central logs.
- It runs as a **gMSA** (or service account) that is local admin on the kiosks,
  in the same way the kiosk-admin account gets it today. No password is stored.
- `Install-CollectorTask.ps1` gains `-ServiceAccount` and registers a
  non-interactive task.

**Code change:** a lock file with a lease next to the published CSV (for
example `MWST_FleetEvents.lock`, with the host, PID and expiry). A collector on
another machine then waits or backs off instead of merging over the other's
write. It is cheap insurance even with one intended writer.

The collector is **not** a Software Center app for admin PCs.

## 4. The launchers as ConfigMgr applications (kiosks)

There are two applications, **Mach2 Launcher NG** and **PBI Launcher**. Each
is a script installer that runs as SYSTEM.

### Reuse the tested deploy logic

Add a **`-Local` mode** to `Deploy-Mach2LauncherNG.ps1` and `Deploy-PbiLauncher.ps1`.
The tests already run these scripts against a local fake root through
`-RootTemplate`, so the file logic is proven locally. `-Local` changes only the
parts that assume a remote PC:

| Remote today | `-Local` |
|---|---|
| `\\host\C$` root | `C:\`; the host is `$env:COMPUTERNAME` |
| CIM/DCOM session with a credential (old watchdog task, process checks) | Local `Get-ScheduledTask` / `Get-CimInstance`, no credential |
| `-Restart` via CIM/DCOM (`Win32ShutdownTracker`) | Never restarts. The change takes effect at the kiosk's `ScheduledRestartTime` or next logon. The old launcher keeps running until then. |
| 12-minute verify loop | Skipped. The collector and the manager show the result. |
| Report in `Reports\` | A log in `C:\ProgramData\KioskFleet\Logs\` and a summary on stdout (AppEnforce.log) |
| Console output | Exit codes: `0` done; `0` also for *code installed, waiting for a config*; `1603` failed; `1618` retry, because another install is running (the kiosk-user mutex) |

### Rules for a kiosk with no config

If a kiosk has **neither an old launcher to migrate nor a config**:

- install the code;
- **do not** create the Startup shortcut;
- log *"waiting for config"*.

The admin then uses the Fleet Manager's new-kiosk / config editor for the URL
and credential, and that writes the shortcut. This avoids a launcher that
fails at every logon.

### Guard against the wrong app

If the Mach2 app lands on a Power BI kiosk, or the reverse, the installer
refuses: it finds the other product's launcher or config, and exits `1603`
with a clear message.

### Passwords

No password is ever in a package.

- An existing kiosk migrates its own password from the old launcher's config on
  the kiosk, exactly as the C$ deploy does now.
- New kiosks and password changes go through the manager (`password.seed` to
  the kiosk). The launcher encrypts it for the kiosk account.

### Detection

Detection is a script: *"installed version **at or above** the package
version"*, never *"equal"*. With an exact match, ConfigMgr would downgrade a
kiosk that someone hand-deployed a newer build to.

```powershell
$f = 'C:\Users\Public\Documents\Mach2LauncherNG\Mach2LauncherNG.ps1'
$want = [version]'1.1'   # 1.01NG
if (Test-Path -LiteralPath $f) {
    $m = Select-String -LiteralPath $f -Pattern "^\`$LauncherVersion = '(\d+)\.(\d+)NG'" | Select-Object -First 1
    if ($m -and [version]('{0}.{1}' -f [int]$m.Matches[0].Groups[1].Value, [int]$m.Matches[0].Groups[2].Value) -ge $want) { 'Installed' }
}
```

PBI Launcher does the same with its `$LauncherVersion = '2.0.0'` line.

### Uninstall and upgrades

- **Uninstall** = `-Rollback -Local`. It restores the retired shortcuts from
  `Retired shortcuts\<account>\` and re-enables the old watchdog task.
- **Upgrades** use supersedence without uninstalling. The deploy already
  upgrades in place and leaves the existing configs alone.

### Deployment settings

- Required, to *Kiosks | Mach2* or *Kiosks | Power BI*, with *Kiosks | Excluded*
  removed.
- **Hide in Software Center and all notifications**, because the TVs are
  unattended.
- Installation allowed only inside maintenance windows (see 6).
- ConfigMgr restart behaviour: *no specific action*. The script never asks for
  one.

### Package content

A build script, `Sccm\Build-SccmPackages.ps1`, assembles a versioned folder
per app from the repo: the launcher folder, the deploy script, `Lib\`, and the
`Install.ps1`, `Uninstall.ps1` and `Detect.ps1` wrappers. The folder is copied
to the content share, and its ACL lets only admins write. That content runs as
SYSTEM on every kiosk.

## 5. Collections from the master list

`Sync-KioskCollections.ps1` reads the list with the existing `Import-KioskList`
(the ACTIVE column, the type, `RestartGroup`) and maintains **direct
membership rules** in:

| Collection | Members |
|---|---|
| Kiosks \| All | Every ACTIVE kiosk in the list |
| Kiosks \| Mach2 | Mach2 kiosks, meaning not Power BI |
| Kiosks \| Power BI | Power BI kiosks |
| Kiosks \| Pilot | Maintained by hand: TV4, LASER APT, LOG_TV |
| Kiosks \| Wave \<RestartGroup\> | One per restart group, for phased rollout |
| Kiosks \| Excluded | Maintained by hand: kiosks under repair or testing |

How it runs:

- It defaults to **`-WhatIf`**, printing adds and removes. It also reports list
  names that are not ConfigMgr clients.
- It runs after the collector on the server, or by hand from an admin PC with
  the console.
- The alternative is AD groups plus query rules. That is cleaner for rights
  but slower, because it waits for discovery.

## 6. Maintenance windows and restarts

- The launcher installs never restart anything themselves (section 4).
- **The concern is the existing windows.** TV4 inherits the 09:00 and 17:00
  daily windows from SC1001F8, and it is patched as an *Office PC*. Adding a
  kiosk window cannot take those away.
- Proposal for the ConfigMgr team:
  - exclude *Kiosks | All* from SC1001F8 and from the Office-PC patch
    collections;
  - give the kiosks one window outside shifts, for example 01:00-03:00;
  - give the kiosks their own patch deployment.

  This is worth doing even without this project, because a patch restart can
  already black out a TV mid-shift.
- A kiosk client-settings policy (optional) can set short or suppressed restart
  notifications, so a countdown never sits over a dashboard.

## 7. What stays outside ConfigMgr

- Per-kiosk config: URL, zoom, screens, restart time. It is edited in the
  manager's config editor.
- Passwords (`password.seed`).
- Live commands, live read, snapshots, messages and the launcher log.
- **Break-glass:** C$ deploys and rollback from the manager keep working.
  Document that ConfigMgr re-applies its version later unless the kiosk is in
  *Excluded*.
- **Later, optional:** from the manager, trigger *Application Deployment
  Evaluation* on a kiosk (a client notification). The admin would then not
  wait for the policy cycle after fixing a collection.

## 8. Security

- **Content share:** only kiosk admins can write. Anything written there runs
  as SYSTEM on every kiosk.
- **Code signing:** sign all shipped `.ps1` files with the internal
  code-signing certificate, if there is one. Then an *All Signed* client policy
  or GPO does not break detection or install. `Test-FleetManager.ps1` can check
  that every file is signed.
- **The kiosk install folder:** `C:\Users\Public\Documents\...` is writable by
  any local user.
  - The launcher runs as the kiosk user, not SYSTEM, so this is not an
    elevation path.
  - The SYSTEM installer only **copies into** that folder. It never runs
    anything from it. The detection script only reads.
  - Moving the code to Program Files is a possible later step. It is not
    needed now, and it would change paths that the collector and the manager
    use.
- **No secrets in packages, settings or collections.** The collector uses a
  gMSA.

## 9. Code changes (nothing in ConfigMgr yet)

| # | Change | Size |
|---|---|---|
| 1 | `Lib\MWST.Settings.ps1`: policy registry, then shipped JSON, then user JSON | S |
| 2 | `Resolve-KioskListPath`: network path, cache, fallback rules, two-lists warning | S-M |
| 3 | `MWST.FleetState` and the collector: `EventsCsvPath`; the collector's cross-machine lease lock | M |
| 4 | `Get-FleetDataRoot` across the tools (code/data split) | M |
| 5 | `-Local` mode in both deploy scripts: exit codes, no-config rule, wrong-product guard | M |
| 6 | `Sccm\` wrappers (Install, Uninstall, Detect) and `Build-SccmPackages.ps1` | S |
| 7 | `Sync-KioskCollections.ps1` (dry run by default) | M |
| 8 | Fleet Manager: SCCM-managed banner; server-mode Scan now, no Auto-scan | S-M |
| 9 | Tests: settings resolution; the network, cache and OneDrive order; `-Local` against the fake root; detection at, above and below the package version; the no-config and wrong-product cases | M |
| 10 | Docs: this plan becomes `Docs/SCCM.md`; README, Fleet-Manager, and both launcher docs | S |

## 10. Rollout

1. **Decisions and prerequisites** (open questions below). None of these block
   the code work.
2. **Code changes 1-10**, with all suites green. The master-list switch is then
   ready and can be flipped whenever the share exists, independently of
   everything else.
3. **Fleet Manager app** to admins. This is the lowest risk: no kiosk is
   touched.
4. **Collector moved to the server.** The old admin-PC task is unregistered in
   the same change.
5. **Kiosk apps, pilot:**
   - Required to *Kiosks | Pilot*.
   - TV4 and LASER APT already run the new launchers (after their pending
     1.01NG / PBI repair). Detection should say *Installed* and ConfigMgr
     should do nothing. That is the first thing to prove.
   - Then one kiosk still on the old launcher: install, the switch at its
     restart, uninstall = rollback, reinstall.
   - One week.
6. **Waves** by `RestartGroup`, one or two per week, watching the Fleet Manager
   Overview and the deployment status.
7. **Master list move:** whenever the share is ready (section 1, *The day it
   moves*).

## 11. Risks

| Risk | Mitigation |
|---|---|
| ConfigMgr "fixes" a kiosk someone rolled back or hand-upgraded | Detection by version at or above; the *Excluded* collection; the manager's banner |
| Restarts at 09:00 or 17:00 from inherited windows (already possible for patches) | Exclude the kiosks from SC1001F8 and the Office-PC patch collections; add a kiosk-only window |
| Two copies of the master list diverge during the move | The two-lists warning; rename the old copy the same day |
| Share outage: scans stop | The cached last-good list, labelled as such |
| Power BI refresh breaks when the CSV moves | `EventsCsvPath` is separate from the list; decide on the gateway or SharePoint upload first |
| A kiosk gets the app before it has a config | No Startup shortcut without a config; *"waiting for config"* |
| The wrong app for the kiosk type | The installer refuses on the other product's launcher or config |
| The content share is tampered with, and the code runs as SYSTEM everywhere | Share ACLs; signing |
| Mach2: the old watchdog is disabled at install, but the switch waits for the restart | Same as a C$ deploy without `-Restart` today. It is covered by the kiosks' daily `ScheduledRestartTime`; confirm every kiosk has one. |

## 12. Decisions and open questions

1. **Master list share:** the UNC path, and who owns the file.
2. **Events CSV and Power BI** after the move: SharePoint upload, or the share
   plus an on-premises data gateway? Who owns the report?
3. **Collector host and account:** a gMSA on `shghmgt09`? How does the
   kiosk-admin account get local admin on kiosks today (GPO, LAPS, by hand)?
4. **Maintenance windows:** can the kiosks leave SC1001F8 and the Office-PC
   patch collections, and get their own off-shift window? What are the shift
   times?
5. **ConfigMgr rights:** who creates the applications, collections and
   deployments? What is the content source share and the DP group?
6. **Admin user collection:** which AD group?
7. **Code signing:** is an internal certificate available?
8. **Execution policy:** confirm that `PowerShellExecutionPolicy = 1` in the
   Default Client Agent Settings is *Bypass*, and whether a custom setting
   applies to the kiosks.
9. **Restart times:** does every kiosk config have a `ScheduledRestartTime`?
   Installs take effect then.
