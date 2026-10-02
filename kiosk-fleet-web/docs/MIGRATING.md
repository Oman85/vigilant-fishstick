# From the PowerShell Kiosk Fleet to Kiosk Fleet Web 2

Kiosk Fleet Web 2 replaces `Start-FleetWeb.ps1`, its scheduled task, and the scheduled collector (`Collect-MWSTFleet.ps1`). It runs on Linux, in Docker. The kiosks don't change: the same launchers, the same files on their `C$` share, and the same events CSV for the Power BI report.

## What maps to what

| PowerShell | Kiosk Fleet Web 2 |
|---|---|
| `Start-FleetWeb.ps1`, `Install-FleetWeb.ps1` | The container (`docker compose up -d`). |
| Windows sign-in, `-AdminGroup`, `-OperatorGroup` | Gone. Everyone has an account of the app. |
| `Set-FleetWebUser.ps1`, `Config\web-users.json` | *Users* on the page, or `kfw user ...`. Old accounts: `kfw user import web-users.json`. |
| `Save-KioskCredential.ps1`, `Config\kiosk-admin.cred.xml` | `KIOSK_ADMIN_USER` + `KIOSK_ADMIN_PASSWORD_FILE` (a Docker secret). |
| `Collect-MWSTFleet.ps1`, `Install-CollectorTask.ps1` | Auto-scan, on by default every 15 minutes; *Scan now*; `kfw scan`. |
| The kiosk list found through OneDrive | Uploaded in *Settings*, or `KFW_KIOSK_LIST`. |
| `MWST_FleetEvents.csv` next to the master list | `/data/MWST_FleetEvents.csv`, plus `KFW_PUBLISH_CSV` for the published copy. |
| `Logs\web-audit.log` | The *Audit log* view; *Download all (CSV)*. |
| `Logs\run\`, deploy reports | `/data/logs/run/` (scan output). |
| `Deploy-*.ps1` from the Deploy view | Still `Deploy-*.ps1`, run on Windows. The Deploy view builds the command to copy. |
| `Show-FleetManager.ps1`, `Show-FleetDashboard.ps1` | Still work against the same CSV, if anyone needs them. |

## Moving over

1. Start the container with the kiosk-admin credential, as in the README, and make the first admin account.
2. Upload the master kiosk list in *Settings*, then test one kiosk (*Test a kiosk...*).
3. Bring the history across. Copy the current `MWST_FleetEvents.csv` (and its `.status.json`) into the volume before the first scan:
   ```bash
   docker compose cp MWST_FleetEvents.csv kfw:/data/
   docker compose cp MWST_FleetEvents.status.json kfw:/data/
   ```
   If the SharePoint folder is mounted with `KFW_PUBLISH_CSV` set, there is nothing to copy: the collector reads the published file and merges it with its own.
4. Import the accounts: `kfw user import web-users.json`. Their passwords carry over. People who signed in with Windows get new accounts in *Users*; tick "choose their own at first sign-in".
5. **Stop the old collector**: `Install-CollectorTask.ps1 -Unregister`, turn off auto-scan in the old manager, and `Install-FleetWeb.ps1 -Uninstall`. Two collectors writing the same CSV make OneDrive conflict copies.
6. Keep the Kiosk Fleet folder on one Windows admin PC for deploys and roll-backs.

## Behaviour that is the same

- Every host status (OFFLINE, NO_ACCESS, NO_AGENT, STALE, LOOP_GUARD, the launcher statuses, AGENT_OUTDATED, INACTIVE) is decided as before.
- Reboot counting is the same: one boot is one reboot, `IsCanonicalReboot` / `IsScriptReboot`, the upgrade cutoff, and retention.
- The CSV columns, their order, the quoting and the BOM are unchanged. Status rows are written on change and as a daily keepalive; COLLECTOR_RUN rows hourly; the status file on every run.
- Control files, `password.seed`, the message inbox, snapshots and the config editor work as in the manager. Control files now say `by alice (admin) from Kiosk Fleet Web`.

## Behaviour that differs

- Restarts go over WMI/DCOM through impacket, and call the same `Win32ShutdownTracker` with the same flags.
- `-RemoteEventLog` is not available. Remote event-log reading was off by default; the agents' ledgers carry the same 1074/6005/6008 records with the same EventIds.
- A kiosk's log on a drive other than C: is not read; only `C$` is opened.
- The collector's version shows as `6.2-py` in the CSV's COLLECTOR_RUN rows and in the status file.
