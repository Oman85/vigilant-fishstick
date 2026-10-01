@echo off
REM Bump LauncherVersion whenever this file changes. The watchdog version is
REM read from the script itself, so it is always the one about to start.
set "LauncherVersion=7.0"
set "AgentScript=C:\Users\Public\Documents\mwstv4.ps1"

REM Hide this window before anything else. The kiosk app starts at the same
REM logon, and this window must never sit on top of it: the watchdog
REM photographs the screen, so a console over the dashboard reads as a black
REM screen. PowerShell started with -WindowStyle Hidden hides the console it
REM shares with this batch file; the watchdog checks again when it starts.
REM The banner below is only seen if hiding failed (Windows Terminal).
C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command "exit"

MODE CON: cols=290 lines=40
REM color 1F
color 02
title MACH 2 Kiosk WST
cls
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@      @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo @@@@@@@@@            @@@@@@@       @@@       @@@@@@@@@@             @@@@@@@                 @@@@@@@@                    @
echo @@@@@@                  @@@@                   @@@@@                  @@@@                    @@@@                      @
echo @@@@@                   @@@                    @@@@        @@@@       @@@@                    @@@      @@@@@@@@@@@@@@@@@@
echo @@@@        @@@@@@@@@@@@@@@       @@@@@@      @@@@@@@@@@@@@@@@@       @@@       @@@@@@        @@@      @@@@@@@@@@@@@@@@@@
echo @@@@                  @@@@        @@@@@       @@@@@                  @@@@       @@@@@@       @@@@@                    @@@
echo @@@@@                  @@@       @@@@@@       @@@                    @@@       @@@@@@        @@@@                    @@@@
echo @@@@@@@@@@@@@@@@       @@@      @@@@@@       @@@       @@@@@@       @@@@       @@@@@@       @@@      @@@@@@@@@@@@@@@@@@@@
echo @@        @@@@@       @@@       @@@@@        @@@       @@@@         @@@                    @@@@       @@@@@@@@@@@@@@ @@@@
echo @@                   @@@@      @@@@@@       @@@@                   @@@@                   @@@@@                      @@@@
echo @@@@              @@@@@@       @@@@@        @@@@@                  @@@       @@@      @@@@@@@@@@                     @@@@
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@       @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
echo @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@                                                                                                                                                                                                                                                                                                                                           

echo.
echo                                               *** APU1 PRODUCTION TEST ***

REM The line in the script reads:  $AgentVersion = "7.0"
set "AgentVersion=?"
if exist "%AgentScript%" for /f "tokens=2 delims==" %%v in ('findstr /b /l /c:"$AgentVersion" "%AgentScript%"') do set "AgentVersion=%%v"
set "AgentVersion=%AgentVersion:"=%"
set "AgentVersion=%AgentVersion: =%"
echo                                              Watchdog v%AgentVersion%  -  Launcher v%LauncherVersion%
echo.

setlocal enabledelayedexpansion
set "spinner=|/-\"
REM Gives the kiosk app time to bring its dashboard up before the first screen check.
set "LoadSeconds=60"

<nul set /p "=.                                           Starting kiosk... "
for /L %%i in (1,1,%LoadSeconds%) do (
    set /a "idx=%%i %% 4"
    for %%s in (!idx!) do set "char=!spinner:~%%s,1!"
    <nul set /p "=!char!"
    timeout /t 1 /nobreak >nul
    <nul set /p "="
)
echo.

C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -File "%AgentScript%"