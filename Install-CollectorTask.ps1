#Requires -Version 5.1
<#
.SYNOPSIS
    Registers the collector as a scheduled task: every 15 minutes, under your
    account, while you are signed in.

.DESCRIPTION
    Why your account, and why only while signed in:

      - the published CSV goes into your OneDrive-synced SharePoint folder,
        which only syncs while you are signed in anyway, and
      - the kiosk-admin credential is DPAPI-encrypted to your account, which
        can only decrypt it from a normal interactive logon.

    Scans pause while you are signed out. Nothing is lost by that: each
    kiosk's ledger and System log hold everything until the next scan, and
    the first run after you sign in collects it all.

    The task also runs 3 minutes after you sign in, so the day's first scan
    does not wait for the next quarter-hour, and OneDrive has a moment to
    start first.

    It is launched through "conhost.exe --headless", so no console window
    flashes up every 15 minutes. -VisibleWindow runs powershell.exe directly
    instead, which is useful when troubleshooting.

    Registering a task for your own account needs no admin rights.

.PARAMETER IntervalMinutes
    Scan interval. Default 15.

.PARAMETER CredentialFile
    Default: Config\kiosk-admin.cred.xml (create it with Save-KioskCredential.ps1).

.PARAMETER ExtraArguments
    Appended to the collector's command line, e.g. '-EventLogAllHosts'.

.PARAMETER VisibleWindow
    Show the console window during each run.

.PARAMETER RunNow
    Start the task once immediately after registering it.

.PARAMETER Unregister
    Remove the task.

.EXAMPLE
    .\Install-CollectorTask.ps1 -RunNow

.EXAMPLE
    .\Install-CollectorTask.ps1 -Unregister
#>

[CmdletBinding()]
param(
    [ValidateRange(5, 1440)][int]$IntervalMinutes = 15,
    [string]$TaskName = 'MWST Fleet Collector',
    [string]$TaskPath = '\MWST\',
    [string]$CredentialFile,
    [string]$ExtraArguments = '',
    [switch]$VisibleWindow,
    [switch]$RunNow,
    [switch]$Unregister
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'Lib\MWST.Remote.ps1')

if ($Unregister) {
    if (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false
        Write-Host "Removed scheduled task $TaskPath$TaskName."
    }
    else {
        Write-Host "No scheduled task $TaskPath$TaskName to remove."
    }
    return
}

$collector = Join-Path $ScriptDir 'Collect-MWSTFleet.ps1'
if (-not (Test-Path -LiteralPath $collector)) { throw "Collector not found: $collector" }

if (-not $CredentialFile) { $CredentialFile = Join-Path $ScriptDir 'Config\kiosk-admin.cred.xml' }
if (-not (Test-Path -LiteralPath $CredentialFile)) {
    throw "No saved credential at $CredentialFile. Run .\Save-KioskCredential.ps1 first."
}

# Prove the credential decrypts for this account now, rather than finding
# out from a column of NO_ACCESS rows tomorrow.
$cred = Import-StoredCredential -Path $CredentialFile
Write-Host "Credential file OK ($($cred.UserName))."

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$conhost    = Join-Path $env:SystemRoot 'System32\conhost.exe'

$psArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -CredentialFile "{1}"' -f $collector, $CredentialFile
if ($ExtraArguments) { $psArgs += " $ExtraArguments" }

if ($VisibleWindow -or -not (Test-Path -LiteralPath $conhost)) {
    $action = New-ScheduledTaskAction -Execute $powershell -Argument $psArgs -WorkingDirectory $ScriptDir
}
else {
    $action = New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "{0}" {1}' -f $powershell, $psArgs) -WorkingDirectory $ScriptDir
}

$user = "$env:USERDOMAIN\$env:USERNAME"

# Start on the next interval boundary so scan times line up with the clock
# (xx:00, xx:15, ...), which makes ScanIds easy to read.
$now = Get-Date
$minutesToday = [math]::Ceiling(($now - $now.Date).TotalMinutes / $IntervalMinutes) * $IntervalMinutes
$start = $now.Date.AddMinutes($minutesToday)

$repeat = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$logon  = New-ScheduledTaskTrigger -AtLogOn -User $user
$logon.Delay = 'PT3M'

$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

# IgnoreNew: if a scan is still running when the next is due, skip rather than
# queue. The collector has its own lock as well, for manual runs.
$settings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -StartWhenAvailable `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

$description = "Collects MWST kiosk watchdog events into MWST_FleetEvents.csv for Power BI. Installed from $ScriptDir."

Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath `
    -Action $action -Trigger @($repeat, $logon) -Principal $principal -Settings $settings `
    -Description $description -Force | Out-Null

$task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
Write-Host ''
Write-Host "Registered $TaskPath$TaskName" -ForegroundColor Green
Write-Host "  runs as   $user (only while signed in)"
Write-Host "  every     $IntervalMinutes min from $($start.ToString('HH:mm')), and 3 min after sign-in"
Write-Host "  command   $($task.Actions[0].Execute) $($task.Actions[0].Arguments)"
Write-Host "  log       $(Join-Path $ScriptDir 'Logs\collector.log')"

if ($RunNow) {
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
    Write-Host ''
    Write-Host 'Started a run now. Follow it in Logs\collector.log.'
}
