# Kiosk launchers

Each launcher shows a web page full screen in Edge and keeps it there (signs in,
reloads, restarts Edge, logs). Needs only Windows PowerShell 5.1 and Edge.

| Folder | Shows |
|---|---|
| `Mach2LauncherNG\` | Mach2 (Niagara) dashboard; also the kiosk's watchdog |
| `PbiLauncher\` | Power BI report |
| `WebLauncher\` | Any web page, no sign-in |

## Install (per screen)

1. Copy the launcher folder to `C:\Users\Public\Documents\` (e.g. `...\Documents\PbiLauncher\`).
2. Create a screen folder `S1` (`S2` for a second screen) and in it a copy of
   `EXAMPLE.json` named `<COMPUTERNAME>.json`. Fill in `DisplayURL`,
   `UserName`, `ScreenSelect` and `LogName` (Mach2 also `LoginURL`, and
   `Watchdog` = `1` on its first Mach2 screen, `0` on others).
3. Password (Mach2/PBI): put `password.seed` (the password, one line) in the
   screen folder; the launcher encrypts it at first logon and deletes it. For
   Mach2, copy the prefilled `Mach2LauncherNG\password.seed` (user and password
   `operator`).
4. Create a scheduled task that starts it when the kiosk account logs on, one
   per screen (run as admin/SYSTEM; set the three values first):

   ```powershell
   $l = 'PbiLauncher'; $n = 'S1'; $u = 'DOMAIN\kioskuser'   # or Mach2LauncherNG / WebLauncher
   $a = New-ScheduledTaskAction -Execute 'C:\Windows\System32\conhost.exe' -WorkingDirectory "C:\Users\Public\Documents\$l" `
        -Argument "`"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"C:\Users\Public\Documents\$l\$l.ps1`" -Instance $n"
   $t = New-ScheduledTaskTrigger -AtLogOn -User $u
   $p = New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive
   $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
   Register-ScheduledTask -TaskName "$l $n" -Action $a -Trigger $t -Principal $p -Settings $s -Force
   ```

   `Interactive` makes it run on the kiosk account's desktop, so Edge is
   visible. `ExecutionTimeLimit 0` stops Windows killing it after 3 days.
   conhost keeps Windows Terminal from opening over the page.

It starts at the kiosk account's next logon. One launcher per screen number.

## Troubleshooting

- Log: `S1\Logs\` (CMTrace format). Stop it: create `kill.txt` in `S1\`.
- `No config file`: the `.json` is missing or not named after the computer.
- Stuck at sign-in: wrong password; drop a new `password.seed`.
