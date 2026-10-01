@echo off
setlocal
rem Kiosk Fleet Manager: the window for the Mach2 kiosks (Mach2 Launcher NG)
rem and the Power BI screens (PBI Launcher).
rem
rem Extra arguments pass through, e.g.  Start-KioskManager.bat -View Deploy
rem The terminal version is Start-FleetDashboard.bat.

start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0Show-FleetManager.ps1" %*
