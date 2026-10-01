# Kiosk Fleet Web

The fleet dashboard and manager as a web page on the intranet: the same fleet, the same views and the same things to do to a kiosk as the [Kiosk Fleet Manager](Fleet-Manager.md) window, in a browser, for anyone allowed. Nobody needs this folder, PowerShell or the kiosk-admin credential on their own PC.

```
 browser ──(Windows sign-in or local account)──► Start-FleetWeb.ps1   (HttpListener, PowerShell 5.1, one service account)
                                                        │
   reads   MWST_FleetEvents.csv + .status.json  ◄───────┤ the collector, every 15 min (or Scan now / Auto-scan here)
   runs    Collect-MWSTFleet.ps1, Deploy-*.ps1  ◄───────┤ separate processes, output in Activity
   sends   control files, messages, password.seed ─────►│ the kiosk's C$ share, with the saved kiosk-admin credential
   writes  Logs\web-audit.log  ◄────────────────────────┘ who did what, to which kiosk, and how it went
```

Part of [Kiosk Fleet](../README.md).

## Who can do what

Everyone signs in as themselves. There are two roles:

| | Operator | Admin |
|---|:-:|:-:|
| See every view: Overview, Mach2, Power BI, Web pages, Other, Activity | ✓ | ✓ |
| **Scan now** | ✓ | ✓ |
| **Read live**, **Screenshot**, **Log** | ✓ | ✓ |
| **Reload**, **Restart browser** | ✓ | ✓ |
| **Message...** on a Mach2 kiosk | ✓ | ✓ |
| **Restart...** a kiosk | | ✓ |
| **Hold / Resume**, **Stop** the launcher | | ✓ |
| **Password...** (the sign-in password) | | ✓ |
| **Config...** and **Add screen...** (the kiosk's own settings) | | ✓ |
| **Deploy**: install, update, roll back, dry run, add a kiosk | | ✓ |
| **Auto-scan**, stopping a run | | ✓ |
| **Audit log** | | ✓ |

The page only shows an operator the buttons they can use, and the server checks the role again on every request, so a hand-made request gets *403* and an entry in the audit log, not an action. The split lives in one table, `$FleetPermissions` in `Lib\Fleet.WebAuth.ps1`.

## Signing in

**Windows (the normal way).** People use their own domain account. On a domain PC with the address in the Local intranet zone there is no prompt at all (Kerberos, or NTLM where there is no SPN). The role comes from AD groups:

- `-AdminGroup`: its members are admins. Default `KioskFleet-Admins`.
- `-OperatorGroup`: its members are operators. Default `KioskFleet-Operators`.

Write them as `DOMAIN\Group`. Someone in both is an admin; someone in neither is refused, and the refusal goes in the audit log. Leaving the group takes effect at their next sign-in.

**Local accounts (break-glass).** These are for when Windows sign-in cannot work: no AD, a PC outside the domain, or AD itself being the problem. They live in `Config\web-users.json`, each with a role and a salted PBKDF2-SHA256 hash; the password itself is never stored.

```powershell
.\Set-FleetWebUser.ps1 -Name breakglass -Role admin           # add, or set its password (asked twice)
.\Set-FleetWebUser.ps1 -Name nightshift -Role operator
.\Set-FleetWebUser.ps1 -Name nightshift -Role admin -RoleOnly # change the role, keep the password
.\Set-FleetWebUser.ps1 -Name nightshift -Disable              # or -Enable, or -Remove
.\Set-FleetWebUser.ps1 -List
```

A password has at least 12 characters and three kinds of character (or at least 20 characters). The running server picks up any change within seconds: a removed or disabled account is signed out at once.

Both ways end in the same session: an `HttpOnly`, `SameSite=Strict` cookie (also `Secure` over HTTPS). It lapses after `-IdleMinutes` (30) with no page open, and after `-SessionHours` (10) no matter what. Five wrong passwords for one name within 15 minutes lock that name for 15 minutes; twenty from one address lock the address. Every change is also checked for a CSRF token and the page's own origin.

## Setting it up

On the one PC that serves it. That should be the PC that runs the collector, since everything here assumes [one collector](../README.md#one-collector).

1. **A service account** with admin rights on the kiosks: an AD account, or better a gMSA (`DOMAIN\name$`, no password to keep). The server runs as this account and nobody else's.
2. **The kiosk-admin credential, saved as that account.** The file is DPAPI-encrypted and only opens for the account that saved it:
   ```bat
   runas /user:CONTOSO\svc-kioskfleet "powershell -NoProfile -ExecutionPolicy Bypass -File C:\KioskFleet\Save-KioskCredential.ps1"
   ```
   A gMSA cannot log on interactively, so run `Save-KioskCredential.ps1` from a one-off scheduled task as the gMSA instead.
3. **The two AD groups**, with people in them.
4. **Install**, as an administrator:
   ```powershell
   # HTTP for now, until there is a certificate:
   .\Install-FleetWeb.ps1 -ServiceAccount 'CONTOSO\svc-kioskfleet' -AllowHttp `
       -AdminGroup 'CONTOSO\KioskFleet-Admins' -OperatorGroup 'CONTOSO\KioskFleet-Operators'

   # With a certificate for this PC's name from the internal CA:
   .\Install-FleetWeb.ps1 -ServiceAccount 'CONTOSO\gmsa-kioskfleet$' -CertificateThumbprint 3F1C...A9 `
       -AdminGroup 'CONTOSO\KioskFleet-Admins' -OperatorGroup 'CONTOSO\KioskFleet-Operators'
   ```
   That reserves the address for the service account (`netsh http add urlacl`), binds the certificate for HTTPS (`netsh http add sslcert`), opens the port on the domain firewall profile, restricts `Config\web-users.json` to the service account and the PC's administrators, and registers the scheduled task **Kiosk Fleet Web**. The task starts at boot, runs as the service account, and restarts within a minute if the server stops. It then prints whatever is still left to do.
5. **Kerberos** (optional, so there is no NTLM): `setspn -S HTTP/<this PC's FQDN> CONTOSO\svc-kioskfleet`, and put the address in the Local intranet zone by GPO.
6. `Start-ScheduledTask -TaskName 'Kiosk Fleet Web'`, then open `http://<PC>:8080/` (or `https://<PC>:8443/`).

To move from HTTP to HTTPS later, run step 4 again with `-CertificateThumbprint`. `.\Install-FleetWeb.ps1 -Uninstall` takes it all away again; the accounts file and the logs stay.

To try it from a console without installing anything: `Start-FleetWeb.bat -Prefix http://localhost:8080/`. That runs as you, with your saved credential, and only you can reach it.

### HTTP or HTTPS

Without a certificate the server only listens on the network if you say `-AllowHttp`. Windows sign-in sends no password even then. A local account's password does cross the network as typed, though, and so does every page. The page says so in a yellow bar. Get a certificate from the internal CA and switch when you can.

## What is different from the window

- **Remote control** and **Open share** run on your own PC, not on the server. The card shows the `CmRcViewer.exe` command or the `\\kiosk\C$\...` path to copy.
- **One run at a time, for everyone.** A scan or a deploy started by one person shows in everyone's Activity, with who started it. A second one waits for the first.
- **One thing at a time per kiosk, for everyone.** While someone's action on a kiosk is going, its buttons are greyed on every screen.
- **Read live, Hold and screenshots are shared.** What one person read is on the kiosk's card for everyone, with the time it was read.
- **The deploy command is built on the server** from the ticks and options, never from text the browser sends. The preview is exactly what will run. As in the window, it is written to `Logs\run\<time>.ps1` first, now with who asked for it.
- **Control files say who asked**, as the web user: `2026-10-01T09:12:00 by CONTOSO\jsmith (operator) from Kiosk Fleet Web`.

## The audit log

`Logs\web-audit.log` holds one JSON line per event:

- signing in (and failing to), signing out
- every action on a kiosk: when it started and how it ended
- every refusal, with the reason
- scans and deploys, with the command and the exit code
- the server starting and stopping

A config change records what each setting was set to. A password is never written there, nor anywhere else on the server. Admins can read the newest 400 entries in **Audit log** on the page.

The server's own errors go to `Logs\fleet-web.log`.

## Options

| | |
|---|---|
| `-Prefix` | Where to listen. Default `http://+:8080/`. |
| `-AllowHttp` | Allow plain HTTP on the network. |
| `-AdminGroup`, `-OperatorGroup` | The AD groups for the two roles. |
| `-NoWindowsAuth`, `-NoLocalAccounts` | One way of signing in only. |
| `-UsersFile` | The local accounts. Default `Config\web-users.json`. |
| `-IdleMinutes`, `-SessionHours` | How long a session lasts. Defaults 30 and 10. |
| `-CsvPath`, `-RefreshSeconds`, `-StaleMinutes` | As for the window. |
| `-AutoScan`, `-AutoScanMinutes` | Start with auto-scan on; how often. |
| `-RestartMessage`, `-RestartWarningSeconds` | What a restart shows on the kiosk by default. |
| `-CredentialFile`, `-SccmSiteServer` | As for the window. |

## How it is built

- **`Start-FleetWeb.ps1`** is the server: `System.Net.HttpListener`, one loop answering requests and doing its housekeeping every quarter second. Windows sign-in is HTTP.sys Negotiate on `/auth/windows` only; everything else is the session cookie.
- **`Lib\Fleet.Actions.ps1`** does the work on a kiosk, with no window attached: live read, control files, screenshot, log, password, config, restart, message. It also builds the view of each kiosk the page draws, and the deploy command lines. Each action runs in a background runspace, and the page follows it by job id.
- **`Lib\Fleet.WebAuth.ps1`** holds the roles, the permission table, the password hashes and the accounts file.
- **`Web\`** is the page: `index.html`, `app.css`, `app.js`. It uses no framework and nothing from the internet, and has a strict content security policy. Nothing the server sends is put in as HTML.
- The fleet is read by the same `Lib\MWST.FleetState.ps1` as the window and the terminal dashboard, so all three show the same thing.

## Tests

```powershell
.\Tests\Test-FleetWeb.ps1
```

It runs the real server on `http://localhost:<port>/` with local accounts, against fake kiosks under `%TEMP%\KioskFleetWebTests` with a background job playing the launcher, and a stand-in collector. It checks:

- signing in, lockout, disabling an account, and signing out
- that an operator is refused every admin action, and that the refusal is logged
- CSRF, origin, path and name checks
- the fleet the page gets
- reload, restart browser, live read, screenshot, log, hold and resume
- the password hand-over, and that the password is in no log
- the config editor, for an existing kiosk and a new one
- the deploy commands, including refusing names with code in them
- a scan from start to finish
- the audit log

It takes about a minute and touches no real kiosk, AD or published CSV. On Windows, listening on localhost may need an elevated console.
