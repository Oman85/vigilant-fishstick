# Kiosk Fleet Web

Every kiosk screen, and what can be done to it, in a browser. It runs on Linux in one Docker container.

It is the Kiosk Fleet dashboard and manager, rebuilt as a standalone web app:

- **The dashboard**: Overview, Mach2, Power BI, Web pages and Other, with everything that needs attention at the top, a week of reboots, and every kiosk's details.
- **Kiosk actions**: Read live, Screenshot, Reload, Restart browser, Hold / Resume, Stop, Log, Message, the sign-in Password, the kiosk's own Config (including a new screen or a new kiosk), and Restart the PC.
- **The collector**: *Scan now* and *Auto-scan*. It writes the same `MWST_FleetEvents.csv` and `.status.json` as `Collect-MWSTFleet.ps1`, so the Power BI report keeps working unchanged.
- **Accounts**: sign-in with accounts of the app itself, with no Windows or AD sign-in. Admins manage the accounts on the page. There are two roles, operator and admin.
- **An audit log** of every sign-in, every action on a kiosk, every scan and every account change. It can be searched on the page and downloaded as CSV.
- **The deploy command builder**: pick a launcher, kiosks and options, and copy the command for the PowerShell deploy scripts.

```
 browser ──(account + role)──► kfw (FastAPI, Python 3.12)          one container, /data volume
                                 │
   reads   kiosk list (.xlsx/.csv/.txt, uploaded in Settings)
   scans   every kiosk's C$ over SMB ──────────────► MWST_FleetEvents.csv + .status.json
   sends   control files, messages, password.seed ─► the kiosk's C$ share, as the kiosk-admin account
   restarts the PC over WMI/DCOM
   writes  audit log, accounts, sessions ──────────► /data/kfw.sqlite3
```

## Try it

```bash
docker build -t kiosk-fleet-web .
docker run --rm -p 8080:8080 -e KFW_DEMO=1 kiosk-fleet-web
```

The log prints a one-time link, `http://<server>:8080/setup?token=...`. Open it to make the first admin account. The demo fleet is folders standing in for kiosks, with a thread playing their launchers. Every button works on it, and nothing touches a real kiosk.

## Run it for real

1. **The kiosk-admin account.** This is a domain account with admin rights on the kiosks. It is the same account `Save-KioskCredential.ps1` saved, and the kiosks only need to allow what they already allow: their `C$` share (SMB, port 445), plus WMI/DCOM for restarts.
   ```bash
   mkdir -p secrets
   printf '%s' 'the-password' > secrets/kiosk_admin_password.txt
   chmod 640 secrets/kiosk_admin_password.txt && sudo chgrp 10001 secrets/kiosk_admin_password.txt   # readable by the container's user
   ```
   Then set `KIOSK_ADMIN_USER` in `docker-compose.yml` to `DOMAIN\name` or `name@domain`.
2. **Start it.**
   ```bash
   docker compose up -d --build
   docker compose logs kfw | grep setup     # the one-time link for the first admin
   ```
   Alternatively, set `KFW_ADMIN_USER` and `KFW_ADMIN_PASSWORD(_FILE)` and that account is made at the first start.
3. **Upload the kiosk list** in *Settings*. This is the master kiosk list `.xlsx` (NAME/HOST, TYPE, HAS MWST, ACTIVE, LOCATION, RESTART GROUP), a `.csv`, or a `.txt` with one name per line. Then use *Test a kiosk...* on one kiosk to check the credential and the network.
4. **Add people** in *Users*.

Auto-scan starts by itself, every 15 minutes, once there is a credential and a list. *Scan now* runs one at any time.

### Finding the kiosks

The container resolves kiosk names through Docker's DNS, which asks the host's resolvers. If short names like `MWEB1` don't resolve, add the domain suffix (`dns_search:` in `docker-compose.yml`). The container needs to reach the kiosks on 445 (SMB). For restarts it also needs 135 and the dynamic RPC ports (WMI/DCOM), as the PowerShell tools did. *Test a kiosk...* in Settings shows what works.

### HTTPS

Put it behind a reverse proxy. `deploy/docker-compose.https.yml` adds Caddy with your internal CA's certificate:

```bash
docker compose -f docker-compose.yml -f deploy/docker-compose.https.yml up -d
```

Edit `deploy/Caddyfile` first. Alternatively, `KFW_TLS_CERT` and `KFW_TLS_KEY` make the app serve HTTPS itself. Over plain HTTP the page shows a yellow bar, because passwords cross the network as typed.

### The Power BI report

The events CSV lives in `/data/MWST_FleetEvents.csv`. To publish it where the report reads it, mount the synced SharePoint folder and set `KFW_PUBLISH_CSV`, for example `/publish/MWST_FleetEvents.csv`. The collector keeps both copies, and each one restores the other. The format is the PowerShell collector's, column for column.

Run **one collector**. Once this server scans, turn off the scheduled `Collect-MWSTFleet.ps1` (`Install-CollectorTask.ps1 -Unregister`) and any auto-scan in the old manager. Two collectors writing the same file make OneDrive conflict copies.

## Who can do what

| | Operator | Admin |
|---|:-:|:-:|
| Every view: Overview, Mach2, Power BI, Web pages, Other, Activity | ✓ | ✓ |
| **Scan now** | ✓ | ✓ |
| **Read live**, **Screenshot**, **Log** | ✓ | ✓ |
| **Reload**, **Restart browser** | ✓ | ✓ |
| **Message...** on a Mach2 kiosk | ✓ | ✓ |
| **Restart...** a kiosk, **Hold / Resume**, **Stop** | | ✓ |
| **Password...**, **Config...**, **Add screen...** | | ✓ |
| **Deploy** command builder, **Auto-scan**, stopping a run | | ✓ |
| **Audit log**, **Users**, **Settings** | | ✓ |

The page only shows the buttons a role can use. The server checks the role again on every request, so a hand-made request gets *403* and an audit entry. The table lives in `kfw/auth.py`.

## Accounts and sessions

- Passwords are stored as salted PBKDF2-SHA256 hashes. A password needs at least 12 characters and three kinds of character, or at least 20 characters.
- An admin can add an account with a temporary password ("choose their own at first sign-in"), change a role, disable or remove an account, reset a password, and sign someone out everywhere. A change takes effect at once, on every session. The last admin cannot be removed, disabled or demoted.
- Everyone can change their own password (**Password** at the top). Doing so signs out their other sessions.
- Five wrong passwords for a name within 15 minutes lock that name for 15 minutes. Twenty wrong passwords from one address lock the address.
- A session is an `HttpOnly`, `SameSite=Strict` cookie, `Secure` over HTTPS. It lapses after 30 minutes idle (`KFW_IDLE_MINUTES`) and after 10 hours whatever happens (`KFW_SESSION_HOURS`). Every change also needs a CSRF token and the page's own origin.

From the command line, inside the container:

```bash
docker compose exec kfw kfw user list
docker compose exec kfw kfw user add alice --role admin       # asks for the password twice
docker compose exec kfw kfw user passwd alice
docker compose exec kfw kfw user role alice operator
docker compose exec kfw kfw user disable alice                # enable, remove
```

Accounts from the PowerShell server's `Config\web-users.json` carry over with their passwords, because the hash format is the same:

```bash
docker compose cp web-users.json kfw:/data/
docker compose exec kfw kfw user import /data/web-users.json
```

## Settings

All settings are environment variables. A `_FILE` variant reads the value from a file (Docker secrets).

| Variable | Default | |
|---|---|---|
| `KIOSK_ADMIN_USER`, `KIOSK_ADMIN_PASSWORD(_FILE)` | | The account with admin rights on the kiosks. |
| `KFW_ROOT_TEMPLATE` | `\\{0}\C$` | Each kiosk's C: drive; `{0}` is its name. A local path makes each kiosk a folder (tests, demos). |
| `KFW_SMB_AUTH` | `ntlm` | `ntlm`, `negotiate` or `kerberos`. |
| `KFW_KIOSK_LIST` | | A fixed kiosk list file. Without it, the list is the one uploaded in Settings. |
| `KFW_PUBLISH_CSV` | | A second copy of the events CSV, for the Power BI report. |
| `KFW_AUTOSCAN`, `KFW_AUTOSCAN_MINUTES` | `true`, `15` | Scan by itself, and how often. |
| `KFW_PARALLEL_HOSTS`, `KFW_HOST_TIMEOUT_SECONDS` | `8`, `180` | Kiosks read at once, and when to give up on one. |
| `KFW_STALE_MINUTES` | `45` | When the dashboard calls its data stale. |
| `KFW_RETENTION_DAYS`, `KFW_RECONCILE_DAYS`, `KFW_TRUSTED_FROM_AGENT_VERSION` | `400`, `30`, `6.1` | As for `Collect-MWSTFleet.ps1`. |
| `KFW_IDLE_MINUTES`, `KFW_SESSION_HOURS` | `30`, `10` | How long a session lasts. |
| `KFW_SECURE_COOKIES` | `auto` | `auto` (over HTTPS), `true` or `false`. |
| `KFW_TRUST_PROXY` | `false` | Believe `X-Forwarded-*` headers, behind your own proxy. |
| `KFW_TLS_CERT`, `KFW_TLS_KEY` | | Serve HTTPS directly. |
| `KFW_ADMIN_USER`, `KFW_ADMIN_PASSWORD(_FILE)` | | The first admin account, made at the first start. |
| `KFW_RESTART_MESSAGE`, `KFW_RESTART_WARNING_SECONDS` | | What a restart shows on the kiosk by default. |
| `KFW_SCCM_SITE_SERVER` | | Added to the remote-control command the page shows. |
| `KFW_DEMO` | | `1`: a pretend fleet to try it on. |
| `TZ` | `Europe/Prague` | The local-time columns of the events CSV follow it. |

## What is in /data

| | |
|---|---|
| `kfw.sqlite3` | Accounts, sessions, the audit log. |
| `kiosk-list.*` | The uploaded kiosk list. |
| `MWST_FleetEvents.csv`, `.status.json` | The events, as the Power BI report reads them. |
| `logs/collector.log` | The collector's log. |
| `logs/run/` | Each scan's output, kept for two weeks (*Activity → Reports*). |
| `logs/snapshots/` | Screenshots taken from the page. |

Back up the volume; nothing else holds state.

## What is different from the PowerShell version

- **There is no Windows or AD sign-in.** Everyone has an account of the app, and admins manage the accounts on the page.
- **Deploys are not run from here.** `Deploy-*.ps1` install software over CIM and the Windows admin share, which stays a Windows job. The Deploy view builds the exact command (`-WhatIf` by default) to run from the Kiosk Fleet folder on a Windows PC. Writing a new kiosk's config, which a deploy needs first, is done here.
- **The collector does not read event logs across the network** (`-RemoteEventLog`). This was off by default, and the kiosks' agents copy the same records into their ledgers.
- **Remote control** and **Open share** run on your own PC. The page shows the command or the path to copy.
- **The kiosk-admin credential** comes from the environment, not a DPAPI file.

More in [docs/MIGRATING.md](docs/MIGRATING.md).

## Development

```bash
python -m venv .venv && . .venv/bin/activate
pip install -e '.[test]'
pytest -q                      # about 20 s; nothing touches the network (docs/TESTING.md)
KFW_DATA_DIR=./data kfw serve --demo --port 8080   # the app on a pretend fleet
```

| | |
|---|---|
| `kfw/app.py` | The web app: the page, sign-in, the API. |
| `kfw/auth.py`, `kfw/db.py` | Roles, password hashes, accounts, sessions, audit (SQLite). |
| `kfw/services.py` | The fleet as last read, kiosk jobs on worker threads, scans as child processes. |
| `kfw/actions.py` | What can be done to a kiosk, and the deploy command lines. |
| `kfw/collector.py` | The collector (a port of `Collect-MWSTFleet.ps1` v6.2). |
| `kfw/launchers.py` | Reading the launchers' status files and the watchdog's ledger. |
| `kfw/fleetstate.py` | From the events CSV to what the page draws. |
| `kfw/kiosk_fs.py`, `kfw/remote.py` | A kiosk's C: drive over SMB (or a folder); ping; restarts over WMI. |
| `kfw/kiosklist.py` | The kiosk list: .xlsx, .csv, .txt. |
| `kfw/web/` | The page: no framework, nothing from the internet, a strict content security policy. |
| `kfw/demo.py` | The pretend fleet, for `--demo` and the tests. |
