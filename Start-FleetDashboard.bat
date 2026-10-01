@echo off
setlocal
rem The terminal dashboard: the same fleet as the Kiosk Fleet Manager window
rem (Start-KioskManager.bat), in a console, for a session that has no desktop.
rem Extra arguments pass through, e.g.  Start-FleetDashboard.bat -Tab PBI

rem UTF-8, so the status dots and sparklines render in plain conhost too.
chcp 65001 >nul
mode con: cols=170 lines=48
title Kiosk Fleet - terminal dashboard

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0Show-FleetDashboard.ps1" %*
