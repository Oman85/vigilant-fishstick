@echo off
setlocal
rem Manual collector run. Extra arguments are passed through, e.g.
rem   Run-Collector.bat -EventLookbackDays 365
rem   Run-Collector.bat -DryRun

set "HERE=%~dp0"
set "CRED=%HERE%Config\kiosk-admin.cred.xml"
set "CREDARG="

if exist "%CRED%" (
    set CREDARG=-CredentialFile "%CRED%"
) else (
    echo No saved kiosk-admin credential - scanning as %USERDOMAIN%\%USERNAME%.
    echo Run Save-KioskCredential.ps1 first if that account is not admin on the kiosks.
    echo.
)

"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%HERE%Collect-MWSTFleet.ps1" %CREDARG% %*

echo.
pause
