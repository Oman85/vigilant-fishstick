@echo off
rem Starts Web Launcher the way the startup shortcut does: in the classic
rem console (not Windows Terminal), hidden. The first argument is the
rem screen's folder (S1 when left out); the rest are passed on.
rem To watch it work instead, run:
rem   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WebLauncher.ps1" -Instance S1 -ShowConsole
rem The folder first: shift moves %0 as well.
set "HERE=%~dp0"
set "INSTANCE=%~1"
if "%INSTANCE%"=="" (set "INSTANCE=S1") else shift
start "" "%windir%\System32\conhost.exe" "%windir%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HERE%WebLauncher.ps1" -Instance %INSTANCE% %1 %2 %3 %4 %5 %6 %7 %8 %9