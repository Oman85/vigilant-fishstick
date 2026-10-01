@echo off
setlocal
rem Kiosk Fleet Web in this console, for trying it out or watching its log.
rem As a server it runs from the scheduled task Install-FleetWeb.ps1 sets up.
rem
rem Extra arguments pass through, e.g.
rem   Start-FleetWeb.bat -Prefix http://localhost:8080/
rem   Start-FleetWeb.bat -AllowHttp -AdminGroup CONTOSO\KioskFleet-Admins -OperatorGroup CONTOSO\KioskFleet-Operators

title Kiosk Fleet Web
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-FleetWeb.ps1" %*
