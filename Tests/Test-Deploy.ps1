#Requires -Version 5.1
<#
.SYNOPSIS
    Tests Deploy-PbiLauncher.ps1 against fake kiosks - folders that stand in
    for each kiosk's C: drive - and checks that the startup shortcut it
    creates really starts the launcher.

.DESCRIPTION
    No real kiosk is contacted. The fake kiosks:

      KIOSK1  old launcher, StartupLauncher starts only Power BI
      KIOSK2  old launcher, StartupLauncher also starts a Mach2 launcher
      KIOSK3  nothing installed
      KIOSK4  two old Power BI launchers (two screens: S1 and S2)
      KIOSK5  old launcher, but the kiosk account has no profile
      KIOSK6  old launcher 1.0.0.14: files directly in Launcher S1
      KIOSK7  as the first version left LASER APT
      KIOSK8  PBI Launcher 2.0.0: its config next to the script
      KIOSK9  two old Power BI screens, but Mach2 Launcher NG has S1

    Takes about a minute.
#>
[CmdletBinding()]
param(
    [string]$Deploy = (Join-Path $PSScriptRoot '..\Deploy-PbiLauncher.ps1'),
    [string]$WorkRoot = (Join-Path $env:TEMP 'PbiDeployTests'),
    [int]$Port = 18767,
    [switch]$KeepWorkRoot
)

$ErrorActionPreference = 'Stop'
$Deploy = (Resolve-Path -LiteralPath $Deploy).ProviderPath
$ProjectDir = Split-Path -Parent $Deploy
$Fake = Join-Path $WorkRoot 'kiosks'
$Template = Join-Path $Fake '{0}'
$Reports = Join-Path $WorkRoot 'reports'
$LegacyPassword = 'Old-Plain"Text&Pass'
$Results = New-Object System.Collections.Generic.List[object]
$Shell = New-Object -ComObject WScript.Shell
$Utf8 = New-Object Text.UTF8Encoding($false)

function Test-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    $Results.Add([pscustomobject]@{ Check = $Name; Pass = $Pass; Detail = $Detail })
    $suffix = if ($Detail) { "  ($Detail)" } else { '' }
    Write-Host ("  [{0}] {1}{2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $suffix) -ForegroundColor $(if ($Pass) { 'Green' } else { 'Red' })
}

function New-Link {
    param([string]$Path, [string]$Target)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $l = $Shell.CreateShortcut($Path)
    $l.TargetPath = $Target
    $l.Save()
}

function New-FakeKiosk {
    param([string]$Name, [switch]$Mach2Too, [switch]$TwoScreens, [switch]$NoLegacy, [switch]$NoProfile, [switch]$Flat)
    $c = Join-Path $Fake $Name
    $pub = Join-Path $c 'Users\Public\Documents\Launchers'
    New-Item -ItemType Directory -Path $pub -Force | Out-Null
    if (-not $NoProfile) { New-Item -ItemType Directory -Path (Join-Path $c "Users\$Name\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup") -Force | Out-Null }
    if ($NoLegacy) { return }

    $screens = if ($TwoScreens) { @('S1', 'S2') } else { @('S1') }
    foreach ($s in $screens) {
        $d = if ($Flat) { Join-Path $pub "Launcher $s" } else { Join-Path $pub "Launcher $s\PowerBILauncher" }
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'PowerBILauncher.exe') -Value 'fake'
        $legacy = @"
[
 {
   "JsonVer": "1.0.0.3",
   "LoginURL": "https://app.powerbi.com/singleSignOn?",
   "DisplayURL": "https://app.powerbi.com/groups/me/apps/11111111-2222-3333-4444-555555555555/reports/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/f697b112e6aa1d830b4e?experience=power-bi",
   "ZoomPercent": "100",
   "UsePriScreen": "0",
   "ScreenSelect": "1",
   "KioskMode": "1",
   "ForcedRefreshTime": "07:55",
   "EnableRefresh": "1",
   "BrowserRefreshDelay": "15",
   "UserName": "SHPowerBIKiosk@contoso.test",
   "UpdateEdgeDriver": "1",
   "EdgeDriverSharePath": "\\\\server\\MSEdgeDriver",
   "LogPath": "",
   "RemoteLogPath": "\\\\server\\MISCLaunchersLogs",
   "LogName": "PowerBI_$Name-ROLL007_APU1.log",
   "Password": "$($LegacyPassword.Replace('"', '\"'))",
   "StartupDelay": "0",
   "DisableStartup": "0",
   "DebugLogging": "0",
   "ScheduledRestartEnabled": "0",
   "ScheduledRestartTime": "06:00",
   "RestartDelay": "30",
   "StaySignedIn": "1"
 }
]
"@
        [IO.File]::WriteAllText((Join-Path $d "$Name.json"), $legacy, $Utf8)
    }

    $sl = Join-Path $pub 'StartupLauncher'
    New-Item -ItemType Directory -Path $sl -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sl 'StartupLauncher.exe') -Value 'fake'
    $second = if ($Mach2Too) {
        New-Item -ItemType Directory -Path (Join-Path $pub 'Launcher S2') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pub 'Launcher S2\Mach2Launcher.exe') -Value 'fake'
        [IO.File]::WriteAllText((Join-Path $pub "Launcher S2\$Name.json"), '[{ "DisplayURL": "http://station/dashboard" }]', $Utf8)
        '"LauncherPath2": "C:\\Users\\Public\\Documents\\Launchers\\Launcher S2", "LauncherName2": "Mach2Launcher.exe",'
    }
    else { '"LauncherPath2": "C:\\Users\\Public\\Documents\\Launchers\\Launcher S2", "LauncherName2": "Launcher.exe",' }
    $sj = @"
[{ "JsonVer": "1.0.0.3", "LastLauncher": "1",
   "LauncherPath1": "C:\\Users\\Public\\Documents\\Launchers\\Launcher S1$(if (-not $Flat) { '\\PowerBILauncher' })", "LauncherName1": "PowerBILauncher.exe",
   $second
   "LauncherPath3": "C:\\Users\\Public\\Documents\\Launchers\\Launcher S3", "LauncherName3": "Launcher.exe",
   "LauncherPath4": "C:\\Users\\Public\\Documents\\Launchers\\Launcher S4", "LauncherName4": "Launcher.exe" }]
"@
    [IO.File]::WriteAllText((Join-Path $sl "$Name.json"), $sj, $Utf8)
    if (-not $NoProfile) {
        New-Link -Path (Join-Path $c "Users\$Name\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\StartupLauncher.exe.lnk") -Target 'C:\Users\Public\Documents\Launchers\StartupLauncher\StartupLauncher.exe'
    }
}

function Invoke-Deploy {
    param([string[]]$Arguments)
    # Continue: under Stop, Windows PowerShell turns the child's stderr into
    # a terminating error, and some of these runs are meant to fail.
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Deploy @Arguments -RootTemplate $Template -ReportDir $Reports 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (($out | ForEach-Object { "$_" }) -join "`n") }
}

function Get-TreeFingerprint {
    param([string]$Path)
    return ((Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName | ForEach-Object {
                '{0}|{1}' -f $_.FullName.Substring($Path.Length), (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }) -join "`n")
}

function Get-LatestReport {
    $f = Get-ChildItem -LiteralPath $Reports -Filter 'deploy_*.csv' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return @(Import-Csv -LiteralPath $f.FullName)
}

# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
New-FakeKiosk KIOSK1
New-FakeKiosk KIOSK2 -Mach2Too
New-FakeKiosk KIOSK3 -NoLegacy
New-FakeKiosk KIOSK4 -TwoScreens
New-FakeKiosk KIOSK5 -NoProfile
New-FakeKiosk KIOSK6 -Flat
# LASER APT as the first version left it: the renamed shortcut that made
# Windows ask what to open it with, and a fresh one put back at logon. Its
# old config has no DisableStartup, which the deploy has to add.
New-FakeKiosk KIOSK7
$k7Legacy = Join-Path $Fake 'KIOSK7\Users\Public\Documents\Launchers\Launcher S1\PowerBILauncher\KIOSK7.json'
[IO.File]::WriteAllText($k7Legacy, (([IO.File]::ReadAllText($k7Legacy)) -replace '\s*"DisableStartup"\s*:\s*"[^"]*",?', ''), (New-Object Text.UTF8Encoding($false)))
$k7Startup = Join-Path $Fake 'KIOSK7\Users\KIOSK7\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
Copy-Item (Join-Path $k7Startup 'StartupLauncher.exe.lnk') (Join-Path $k7Startup 'StartupLauncher.exe.lnk.disabled-by-PbiLauncher')
$k1 = Join-Path $Fake 'KIOSK1'
$k1Install = Join-Path $k1 'Users\Public\Documents\PbiLauncher'
$k1Startup = Join-Path $k1 'Users\KIOSK1\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
$k1Legacy = Join-Path $k1 'Users\Public\Documents\Launchers\Launcher S1\PowerBILauncher\KIOSK1.json'
$k1S1 = Join-Path $k1Install 'S1'
$k1Sl = Join-Path $k1 'Users\Public\Documents\Launchers\StartupLauncher'
# KIOSK8: what PBI Launcher 2.0.0 left - config, password and status next
# to the script, one shortcut without a screen.
New-FakeKiosk KIOSK8 -NoLegacy
$k8 = Join-Path $Fake 'KIOSK8'
$k8Install = Join-Path $k8 'Users\Public\Documents\PbiLauncher'
$k8Startup = Join-Path $k8 'Users\KIOSK8\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
New-Item -ItemType Directory -Path (Join-Path $k8Install 'Status') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $k8Install 'PbiLauncher.ps1') -Value '# 2.0.0'
[IO.File]::WriteAllText((Join-Path $k8Install 'KIOSK8.json'), '{ "ConfigVersion": "2.0", "DisplayURL": "https://app.powerbi.com/x", "UserName": "a@b.c" }', $Utf8)
Set-Content -LiteralPath (Join-Path $k8Install 'KIOSK8.cred') -Value '{}'
[IO.File]::WriteAllText((Join-Path $k8Install 'Status\KIOSK8.status.json'), '{ "Instance": "KIOSK8", "State": "SHOWING" }', $Utf8)
New-Link -Path (Join-Path $k8Startup 'PBI Launcher.lnk') -Target 'C:\Windows\System32\conhost.exe'
# KIOSK9: Mach2 Launcher NG has S1 already.
New-FakeKiosk KIOSK9 -TwoScreens
New-Item -ItemType Directory -Path (Join-Path $Fake 'KIOSK9\Users\Public\Documents\Mach2LauncherNG\S1') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $Fake 'KIOSK9\Users\Public\Documents\Mach2LauncherNG\S1\KIOSK9.json'), '{ "DisplayURL": "http://station/dashboard" }', $Utf8)

Write-Host "`n== WhatIf" -ForegroundColor Cyan
$before = Get-TreeFingerprint $Fake
$r = Invoke-Deploy @('-Hosts', 'KIOSK1', '-WhatIf')
Test-Check 'WhatIf changes nothing' ((Get-TreeFingerprint $Fake) -eq $before) ($r.Text -split "`n" | Select-String 'FAILED|Exception' | Select-Object -First 2)
Test-Check 'WhatIf run reports WHATIF' ($r.Text -match 'WHATIF')

Write-Host "`n== Install on six fake kiosks" -ForegroundColor Cyan
$r = Invoke-Deploy @('-Hosts', 'KIOSK1,KIOSK2,KIOSK3,KIOSK4,KIOSK5,KIOSK6')
$rep = Get-LatestReport
$by = @{}; foreach ($row in $rep) { $by[$row.Host] = $row }
Test-Check 'KIOSK1 INSTALLED' ($by['KIOSK1'].Result -eq 'INSTALLED') "$($by['KIOSK1'].Result) $($by['KIOSK1'].Detail)"
Test-Check 'KIOSK2 INSTALLED' ($by['KIOSK2'].Result -eq 'INSTALLED') "$($by['KIOSK2'].Result) $($by['KIOSK2'].Detail)"
Test-Check 'KIOSK3 NO_CONFIG (nothing to migrate)' ($by['KIOSK3'].Result -eq 'NO_CONFIG') $by['KIOSK3'].Result
$k4Install = Join-Path $Fake 'KIOSK4\Users\Public\Documents\PbiLauncher'
$k4Startup = Join-Path $Fake 'KIOSK4\Users\KIOSK4\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
Test-Check 'KIOSK4: two old screens, two screen folders, two shortcuts' ($by['KIOSK4'].Result -eq 'INSTALLED' -and $by['KIOSK4'].Instances -eq 'S1,S2' -and (Test-Path (Join-Path $k4Install 'S1\KIOSK4.json')) -and (Test-Path (Join-Path $k4Install 'S2\KIOSK4.json')) -and (Test-Path (Join-Path $k4Startup 'PBI Launcher S1.lnk')) -and (Test-Path (Join-Path $k4Startup 'PBI Launcher S2.lnk'))) "$($by['KIOSK4'].Result) $($by['KIOSK4'].Instances) $($by['KIOSK4'].Detail)"
Test-Check 'KIOSK4: the second screen gets its own log name' ((Get-Content -Raw (Join-Path $k4Install 'S2\KIOSK4.json') | ConvertFrom-Json).LogName -eq 'PbiLauncher_KIOSK4-ROLL007_APU1.log' -or (Get-Content -Raw (Join-Path $k4Install 'S2\KIOSK4.json') | ConvertFrom-Json).LogName -like '*KIOSK4*')
Test-Check 'KIOSK5 FAILED (no kiosk profile)' ($by['KIOSK5'].Result -eq 'FAILED' -and $by['KIOSK5'].Detail -like '*no profile*') "$($by['KIOSK5'].Result) $($by['KIOSK5'].Detail)"
Test-Check 'exit code 1 because of KIOSK5' ($r.Code -eq 1) $r.Code
$k6 = Join-Path $Fake 'KIOSK6'
$k6Legacy = Join-Path $k6 'Users\Public\Documents\Launchers\Launcher S1\KIOSK6.json'
$k6Startup = Join-Path $k6 'Users\KIOSK6\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
Test-Check 'KIOSK6 (1.0.0.14 layout): old config found and migrated' ($by['KIOSK6'].Result -eq 'INSTALLED' -and $by['KIOSK6'].Config -eq 'S1:FROM_OLD_LAUNCHER' -and $by['KIOSK6'].Password -eq 'S1:SEED_FROM_OLD_LAUNCHER') "$($by['KIOSK6'].Result) $($by['KIOSK6'].Config) $($by['KIOSK6'].Legacy) $($by['KIOSK6'].Detail)"
Test-Check 'KIOSK6: old launcher retired (shortcut moved out, config renamed)' (
    (Test-Path (Join-Path $k6 'Users\Public\Documents\PbiLauncher\Retired shortcuts\KIOSK6\StartupLauncher.exe.lnk')) -and
    -not (Test-Path (Join-Path $k6Startup 'StartupLauncher.exe.lnk')) -and -not (Test-Path $k6Legacy) -and (Test-Path "$k6Legacy.disabled-by-PbiLauncher"))
Test-Check 'KIOSK6: warned that the old launcher may stop before the restart' ($by['KIOSK6'].Detail -match 'WARNING: the old launcher now exits')
Test-Check 'KIOSK3/5 got no files' (-not (Test-Path (Join-Path $Fake 'KIOSK3\Users\Public\Documents\PbiLauncher\PbiLauncher.ps1')) -and -not (Test-Path (Join-Path $Fake 'KIOSK5\Users\Public\Documents\PbiLauncher')))

$srcHash = (Get-FileHash (Join-Path $ProjectDir 'PbiLauncher\PbiLauncher.ps1')).Hash
Test-Check 'launcher installed intact' ((Get-FileHash (Join-Path $k1Install 'PbiLauncher.ps1')).Hash -eq $srcHash)
Test-Check 'Start-PbiLauncher.cmd and EXAMPLE.json installed' ((Test-Path (Join-Path $k1Install 'Start-PbiLauncher.cmd')) -and (Test-Path (Join-Path $k1Install 'EXAMPLE.json')))

$cfg = Get-Content -Raw (Join-Path $k1S1 'KIOSK1.json') | ConvertFrom-Json
Test-Check 'config migrated: report, user, refresh, central log' ($cfg.DisplayURL -like '*aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee*' -and $cfg.UserName -eq 'SHPowerBIKiosk@contoso.test' -and $cfg.EnableRefresh -eq '1' -and $cfg.BrowserRefreshDelay -eq '15' -and $cfg.ForcedRefreshTime -eq '07:55' -and $cfg.RemoteLogPath -eq '\\server\MISCLaunchersLogs')
Test-Check 'config migrated: new log name, enabled, version 2.0' ($cfg.LogName -eq 'PbiLauncher_KIOSK1-ROLL007_APU1.log' -and $cfg.DisableStartup -eq '0' -and $cfg.ConfigVersion -eq '2.0') $cfg.LogName
Test-Check 'config migrated: no password, no Selenium settings' (-not $cfg.PSObject.Properties['Password'] -and -not $cfg.PSObject.Properties['EdgeDriverSharePath'] -and -not ((Get-Content -Raw (Join-Path $k1S1 'KIOSK1.json')).Contains($LegacyPassword)))
Test-Check 'password handed over as password.seed, in the screen folder' ((Test-Path (Join-Path $k1S1 'password.seed')) -and ([IO.File]::ReadAllText((Join-Path $k1S1 'password.seed')) -ceq $LegacyPassword)) $by['KIOSK1'].Password

$newLink = Join-Path $k1Startup 'PBI Launcher S1.lnk'
$l = if (Test-Path $newLink) { $Shell.CreateShortcut($newLink) } else { $null }
Test-Check 'startup shortcut: conhost > hidden PowerShell > launcher -Instance S1' ($l -and $l.TargetPath -ieq 'C:\Windows\System32\conhost.exe' -and $l.Arguments -like '*powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\Public\Documents\PbiLauncher\PbiLauncher.ps1" -Instance S1' -and $l.WorkingDirectory -eq 'C:\Users\Public\Documents\PbiLauncher') $(if ($l) { "$($l.TargetPath) $($l.Arguments)" })
$k1Retired = Join-Path $k1Install 'Retired shortcuts\KIOSK1'
Test-Check 'old StartupLauncher shortcut moved out of the Startup folder' ((Test-Path (Join-Path $k1Retired 'StartupLauncher.exe.lnk')) -and -not (Test-Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk')))
# Windows opens everything in a Startup folder at logon; anything that is
# not a shortcut there is "opened" with a Select-an-app dialog.
Test-Check 'nothing is left in the Startup folder that Windows would ask about' (@(Get-ChildItem $k1Startup -File | Where-Object { $_.Extension -ne '.lnk' }).Count -eq 0) ((Get-ChildItem $k1Startup -File | ForEach-Object Name) -join ', ')
Test-Check 'old config renamed out of the way, password untouched' (-not (Test-Path $k1Legacy) -and (Get-Content -Raw "$k1Legacy.disabled-by-PbiLauncher").Contains('"Password"'))
Test-Check 'StartupLauncher has nothing left to start: its config renamed too' (-not (Test-Path (Join-Path $k1Sl 'KIOSK1.json')) -and (Test-Path (Join-Path $k1Sl 'KIOSK1.json.disabled-by-PbiLauncher')))
$m = Get-Content -Raw (Join-Path $k1Install 'migration.json') | ConvertFrom-Json
Test-Check 'migration.json records where the retired shortcut came from and went' (
    $m.KioskUser -eq 'KIOSK1' -and @($m.RetiredShortcuts).Count -eq 1 -and @($m.LegacyJsonRenamed).Count -eq 2 -and
    @($m.RetiredShortcuts)[0].To -eq 'C:\Users\Public\Documents\PbiLauncher\Retired shortcuts\KIOSK1\StartupLauncher.exe.lnk') ((@($m.RetiredShortcuts) | ForEach-Object { "$($_.From) -> $($_.To)" }) -join ' | ')

$k2 = Join-Path $Fake 'KIOSK2'
$k2Startup = Join-Path $k2 'Users\KIOSK2\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
Test-Check 'KIOSK2: StartupLauncher and its config kept (it still starts Mach2 on S2)' ((Test-Path (Join-Path $k2Startup 'StartupLauncher.exe.lnk')) -and (Test-Path (Join-Path $k2 'Users\Public\Documents\Launchers\StartupLauncher\KIOSK2.json')) -and $by['KIOSK2'].Detail -like '*StartupLauncher kept*Mach2Launcher.exe*') $by['KIOSK2'].Detail
Test-Check 'KIOSK2: its old Power BI config renamed' (-not (Test-Path (Join-Path $k2 'Users\Public\Documents\Launchers\Launcher S1\PowerBILauncher\KIOSK2.json')))

Write-Host "`n== Second run" -ForegroundColor Cyan
Set-Content -LiteralPath (Join-Path $k1S1 'KIOSK1.json') -Value ((Get-Content -Raw (Join-Path $k1S1 'KIOSK1.json')) -replace '"DebugLogging":\s*"0"', '"DebugLogging": "1"') -NoNewline
$r = Invoke-Deploy @('-Hosts', 'KIOSK1')
$row = @(Get-LatestReport)[0]
Test-Check 'files UP_TO_DATE, config KEPT (local edit survives), seed still waiting' ($row.Files -eq 'UP_TO_DATE' -and $row.Config -eq 'S1:KEPT' -and $row.Password -eq 'S1:SEED_WAITING' -and (Get-Content -Raw (Join-Path $k1S1 'KIOSK1.json')) -match '"DebugLogging": "1"') "$($row.Files) $($row.Config) $($row.Password)"
$m = Get-Content -Raw (Join-Path $k1Install 'migration.json') | ConvertFrom-Json
Test-Check 'migration.json still holds the first run''s changes' (@($m.RetiredShortcuts).Count -eq 1 -and @($m.LegacyJsonRenamed).Count -eq 2)

# On the pilot, something put the StartupLauncher shortcut back at logon.
New-Link -Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk') -Target 'C:\Users\Public\Documents\Launchers\StartupLauncher\StartupLauncher.exe'
$r = Invoke-Deploy @('-Hosts', 'KIOSK1')
$row = @(Get-LatestReport)[0]
Test-Check 'a restored StartupLauncher shortcut is moved out again, and reported' (
    $row.Result -eq 'INSTALLED' -and $row.Detail -like '*is back*' -and -not (Test-Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk')) -and
    (Test-Path (Join-Path $k1Retired 'StartupLauncher.exe.lnk')) -and @(Get-ChildItem $k1Startup -Filter '*.disabled-by-PbiLauncher').Count -eq 0) $row.Detail

Write-Host "`n== New password, -UpdateConfig" -ForegroundColor Cyan
Remove-Item (Join-Path $k1S1 'password.seed')
Set-Content (Join-Path $k1S1 'KIOSK1.cred') -Value '{}'
$r = Invoke-Deploy @('-Hosts', 'KIOSK1')
Test-Check 'an existing .cred is not overwritten by the old password' (@(Get-LatestReport)[0].Password -eq 'S1:ALREADY_STORED' -and -not (Test-Path (Join-Path $k1S1 'password.seed')))
# -SignInCredential cannot be passed through powershell.exe -File, so this
# part runs in-process.
$cred = New-Object Management.Automation.PSCredential('SHPowerBIKiosk@contoso.test', (ConvertTo-SecureString 'Brand-New-Pass1' -AsPlainText -Force))
& $Deploy -Hosts KIOSK1 -RootTemplate $Template -ReportDir $Reports -SignInCredential $cred -UpdateConfig *> $null
$row = @(Get-LatestReport)[0]
Test-Check '-SignInCredential writes a new seed' ($row.Password -eq 'S1:SEED_FROM_PARAMETER' -and [IO.File]::ReadAllText((Join-Path $k1S1 'password.seed')) -ceq 'Brand-New-Pass1')
Test-Check '-UpdateConfig rewrites from the old config, with a backup' ($row.Config -eq 'S1:FROM_OLD_LAUNCHER' -and (Get-Content -Raw (Join-Path $k1S1 'KIOSK1.json')) -match '"DebugLogging":\s*"0"' -and @(Get-ChildItem $k1S1 -Filter 'KIOSK1.json.bak-*').Count -ge 1) "$($row.Config) $($row.Detail)"

Write-Host "`n== Commands" -ForegroundColor Cyan
$null = Invoke-Deploy @('-Hosts', 'KIOSK1', '-Command', 'Refresh')
Test-Check '-Command Refresh drops refresh.txt in the screen folder' (Test-Path (Join-Path $k1S1 'refresh.txt'))
$null = Invoke-Deploy @('-Hosts', 'KIOSK1', '-Command', 'Hold')
Test-Check '-Command Hold drops hold.txt' (Test-Path (Join-Path $k1S1 'hold.txt'))
$null = Invoke-Deploy @('-Hosts', 'KIOSK1', '-Command', 'Resume')
Test-Check '-Command Resume removes hold.txt' (-not (Test-Path (Join-Path $k1S1 'hold.txt')))
$null = Invoke-Deploy @('-Hosts', 'KIOSK1', '-Command', 'Snapshot')
Test-Check '-Command Snapshot drops snapshot.txt' (Test-Path (Join-Path $k1S1 'snapshot.txt'))
$null = Invoke-Deploy @('-Hosts', 'KIOSK4', '-Command', 'Hold', '-Instance', 'S2')
Test-Check '-Command Hold -Instance S2 reaches only S2' ((Test-Path (Join-Path $k4Install 'S2\hold.txt')) -and -not (Test-Path (Join-Path $k4Install 'S1\hold.txt')))
$r = Invoke-Deploy @('-Hosts', 'KIOSK3', '-Command', 'Stop')
Test-Check '-Command on a kiosk without the launcher: NOT_INSTALLED' (@(Get-LatestReport)[0].Result -eq 'NOT_INSTALLED')

Write-Host "`n== Rollback" -ForegroundColor Cyan
$r = Invoke-Deploy @('-Hosts', 'KIOSK1', '-Rollback')
$row = @(Get-LatestReport)[0]
Test-Check 'ROLLED_BACK' ($row.Result -eq 'ROLLED_BACK') "$($row.Result) $($row.Legacy) $($row.Detail)"
Test-Check 'new shortcut removed, old one back' (-not (Test-Path $newLink) -and (Test-Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk')) -and -not (Test-Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk.disabled-by-PbiLauncher')))
Test-Check 'old config and StartupLauncher''s renamed back' ((Test-Path $k1Legacy) -and -not (Test-Path "$k1Legacy.disabled-by-PbiLauncher") -and (Test-Path (Join-Path $k1Sl 'KIOSK1.json')) -and $row.Legacy -match 'JSON renamed back 2') $row.Legacy
Test-Check 'new launcher told to stop, files kept' ((Test-Path (Join-Path $k1S1 'kill.txt')) -and (Test-Path (Join-Path $k1Install 'PbiLauncher.ps1')))
Test-Check 'migration.json archived' (-not (Test-Path (Join-Path $k1Install 'migration.json')) -and @(Get-ChildItem $k1Install -Filter 'migration.json.rolledback-*').Count -eq 1)
Remove-Item (Join-Path $k1S1 'kill.txt')
$r = Invoke-Deploy @('-Hosts', 'KIOSK1')
Test-Check 'install again after rollback works' (@(Get-LatestReport)[0].Result -eq 'INSTALLED' -and (Test-Path $newLink) -and -not (Test-Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk')) -and (Test-Path (Join-Path $k1Retired 'StartupLauncher.exe.lnk')))

Write-Host "`n== A kiosk the first version left with the Select-an-app dialog (LASER APT)" -ForegroundColor Cyan
$r = Invoke-Deploy @('-Hosts', 'KIOSK7')
$row = @(Get-LatestReport)[0]
$k7Install = Join-Path $Fake 'KIOSK7\Users\Public\Documents\PbiLauncher'
Test-Check 'the renamed shortcut and the one put back are both out of the Startup folder' (
    $row.Result -eq 'INSTALLED' -and (@(Get-ChildItem $k7Startup -File | ForEach-Object Name) -join ',') -eq 'PBI Launcher S1.lnk') ((Get-ChildItem $k7Startup -File | ForEach-Object Name) -join ', ')
Test-Check 'one retired copy is kept, under its real name' ((@(Get-ChildItem (Join-Path $k7Install 'Retired shortcuts\KIOSK7') -File | ForEach-Object Name) -join ',') -eq 'StartupLauncher.exe.lnk')
Test-Check 'the report says the renamed one was cleared' ($row.Detail -like '*had renamed out of the Startup folder*') $row.Detail
Test-Check 'its old config (no DisableStartup) is renamed like any other' (-not (Test-Path $k7Legacy) -and $row.Legacy -match 'JSON renamed 2') $row.Legacy
$r = Invoke-Deploy @('-Hosts', 'KIOSK7', '-Rollback')
Test-Check 'rolling back puts exactly one StartupLauncher shortcut back, and the old config on again' (
    @(Get-LatestReport)[0].Result -eq 'ROLLED_BACK' -and (@(Get-ChildItem $k7Startup -File | ForEach-Object Name) -join ',') -eq 'StartupLauncher.exe.lnk' -and
    (Test-Path $k7Legacy)) ((Get-ChildItem $k7Startup -File | ForEach-Object Name) -join ', ')

Write-Host "`n== PBI Launcher 2.0.0's layout moves into S1 (KIOSK8)" -ForegroundColor Cyan
$r = Invoke-Deploy @('-Hosts', 'KIOSK8')
$row = @(Get-LatestReport)[0]
Test-Check 'config, password and status moved into S1' ($row.Result -eq 'INSTALLED' -and (Test-Path (Join-Path $k8Install 'S1\KIOSK8.json')) -and (Test-Path (Join-Path $k8Install 'S1\KIOSK8.cred')) -and (Test-Path (Join-Path $k8Install 'S1\Status\KIOSK8.status.json')) -and -not (Test-Path (Join-Path $k8Install 'KIOSK8.json')) -and $row.Detail -like '*into S1*') "$($row.Result) $($row.Config) $($row.Detail)"
Test-Check 'its config kept, its stored password kept' ($row.Config -eq 'S1:KEPT' -and $row.Password -eq 'S1:ALREADY_STORED') "$($row.Config) $($row.Password)"
Test-Check '2.0.0''s single shortcut replaced by the screen''s' ((Test-Path (Join-Path $k8Startup 'PBI Launcher S1.lnk')) -and -not (Test-Path (Join-Path $k8Startup 'PBI Launcher.lnk')))

Write-Host "`n== One launcher per screen: Mach2 Launcher NG has S1 (KIOSK9)" -ForegroundColor Cyan
$r = Invoke-Deploy @('-Hosts', 'KIOSK9')
$row = @(Get-LatestReport)[0]
$k9Install = Join-Path $Fake 'KIOSK9\Users\Public\Documents\PbiLauncher'
Test-Check 'only S2 is set up for Power BI; S1 is left to Mach2' ($row.Result -eq 'INSTALLED' -and $row.Instances -eq 'S2' -and (Test-Path (Join-Path $k9Install 'S2\KIOSK9.json')) -and -not (Test-Path (Join-Path $k9Install 'S1')) -and $row.Detail -like '*S1 belongs to Mach2 Launcher NG*') "$($row.Result) $($row.Instances) $($row.Detail)"

Write-Host "`n== Argument checks" -ForegroundColor Cyan
$r = Invoke-Deploy @()
Test-Check 'refuses to run without -Hosts or -AllPbiKiosks' ($r.Code -ne 0 -and $r.Text -match 'AllPbiKiosks')
$r = Invoke-Deploy @('-Hosts', 'KIOSK1', '-Restart')
Test-Check 'refuses -Restart on test roots' ($r.Code -ne 0 -and $r.Text -match 'Restart needs real kiosks')
$r = Invoke-Deploy @('-Hosts', 'KIOSK1', '-Instance', 'S1')
Test-Check 'refuses -Instance without -Command' ($r.Code -ne 0 -and $r.Text -match 'Instance goes with -Command')

Write-Host "`n== Get-PbiLauncherStatus" -ForegroundColor Cyan
$statusTool = Join-Path $ProjectDir 'Get-PbiLauncherStatus.ps1'
$k2Status = Join-Path $k2 'Users\Public\Documents\PbiLauncher\S1\Status'
$k2Status2 = Join-Path $k2 'Users\Public\Documents\PbiLauncher\S2\Status'
New-Item -ItemType Directory -Path $k2Status, $k2Status2 -Force | Out-Null
$now = [DateTime]::UtcNow
[IO.File]::WriteAllText((Join-Path $k2Status 'S1.status.json'), (ConvertTo-Json ([pscustomobject]@{
                Instance = 'S1'; State = 'SHOWING'; StateSinceUtc = $now.AddHours(-3).ToString('o'); LastShownUtc = $now.ToString('o')
                UpdatedUtc = $now.AddSeconds(-10).ToString('o'); LauncherVersion = '2.0.0'; EdgeVersion = 'Edg/153.0.1'; SignIns = 1; Reloads = 12; BrowserStarts = 1; Detail = ''; LastError = ''
            })), $Utf8)
[IO.File]::WriteAllText((Join-Path $k2Status2 'S2.status.json'), (ConvertTo-Json ([pscustomobject]@{
                Instance = 'S2'; State = 'SHOWING'; StateSinceUtc = $now.AddHours(-30).ToString('o'); LastShownUtc = $now.AddHours(-20).ToString('o')
                UpdatedUtc = $now.AddHours(-20).ToString('o'); LauncherVersion = '2.0.0'; EdgeVersion = ''; SignIns = 0; Reloads = 0; BrowserStarts = 1; Detail = ''; LastError = ''
            })), $Utf8)
$rows = @(& $statusTool -Hosts 'KIOSK1,KIOSK2,KIOSK3,KIOSK8' -RootTemplate $Template -PassThru)
$get = { param($h, $i) @($rows | Where-Object { $_.Host -eq $h -and (-not $i -or $_.Instance -eq $i) })[0] }
Test-Check 'status: installed but never run = NO_STATUS' ((& $get 'KIOSK1').State -eq 'NO_STATUS') (& $get 'KIOSK1').State
Test-Check 'status: fresh SHOWING reported as is, with its screen and numbers' ((& $get 'KIOSK2' 'S1').State -eq 'SHOWING' -and (& $get 'KIOSK2' 'S1').Screen -eq 'S1' -and (& $get 'KIOSK2' 'S1').Reloads -eq 12 -and (& $get 'KIOSK2' 'S1').Edge -eq '153.0.1' -and (& $get 'KIOSK2' 'S1').For -eq '3h')
Test-Check 'status: a status moved into S1 by the deploy is read there' ((& $get 'KIOSK8').Screen -eq 'S1' -and (& $get 'KIOSK8').Instance -eq 'KIOSK8') "$((& $get 'KIOSK8').Screen) $((& $get 'KIOSK8').State)"
Test-Check 'status: a status file not written for 20 h = STALE' ((& $get 'KIOSK2' 'S2').State -eq 'STALE' -and (& $get 'KIOSK2' 'S2').Detail -like '*last said SHOWING*') "$((& $get 'KIOSK2' 'S2').State) $((& $get 'KIOSK2' 'S2').Detail)"
Test-Check 'status: no launcher = NOT_INSTALLED' ((& $get 'KIOSK3').State -eq 'NOT_INSTALLED') (& $get 'KIOSK3').State
$printed = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $statusTool -Hosts 'KIOSK1,KIOSK2,KIOSK3' -RootTemplate $Template 2>&1 | Out-String
Test-Check 'status: table prints' ($LASTEXITCODE -eq 0 -and $printed -match 'KIOSK2\s+S1\s+SHOWING' -and $printed -match 'STALE') ($printed.Trim() -split "`n" | Select-Object -First 2)

# ---------------------------------------------------------------------------
Write-Host "`n== The startup shortcut starts the launcher" -ForegroundColor Cyan
# The same shortcut the deploy builds, pointed at a local copy and told to
# run headless, then opened the way Windows opens Startup items.
$ast = [Management.Automation.Language.Parser]::ParseFile($Deploy, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-LauncherShortcut' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
$script:Shell = $Shell
$InstallLocal = Join-Path $WorkRoot 'local-install'
New-Item -ItemType Directory -Path $InstallLocal -Force | Out-Null
Copy-Item (Join-Path $ProjectDir 'PbiLauncher\PbiLauncher.ps1') $InstallLocal
$pwFile = Join-Path $WorkRoot 'pw.txt'
[IO.File]::WriteAllText($pwFile, 'Shortcut-Test-1', $Utf8)
$InstallS1 = Join-Path $InstallLocal 'S1'
New-Item -ItemType Directory -Path $InstallS1 -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $InstallS1 'password.seed'), 'Shortcut-Test-1', $Utf8)
$cfg = [ordered]@{
    DisplayURL = "http://127.0.0.1:$Port/report"; UserName = 'pbi.kiosk@contoso.test'
    ProfileDir = (Join-Path $InstallLocal 'Profile'); LoginHosts = '127.0.0.2'; ReportHosts = '127.0.0.1'; TestAllowHttpLogin = '1'
    HealthCheckSeconds = '2'; DisplayWaitSeconds = '0'
}
[IO.File]::WriteAllText((Join-Path $InstallS1 "$env:COMPUTERNAME.json"), (ConvertTo-Json ([pscustomobject]$cfg)), $Utf8)
$lnk = Join-Path $WorkRoot 'PBI Launcher S1.lnk'
New-LauncherShortcut -Path $lnk -InstanceName S1 -ExtraArguments '-Headless -ExitAfterSeconds 40'

$server = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $PSScriptRoot 'FixtureServer.ps1')), '-Port', $Port, '-EventsFile', ('"{0}"' -f (Join-Path $WorkRoot 'events.jsonl')), '-PasswordFile', ('"{0}"' -f $pwFile))
try {
    Start-Sleep -Seconds 3
    $shownAt = $null
    Start-Process -FilePath $lnk
    $statusFile = Join-Path $InstallS1 'Status\S1.status.json'
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $shownAt) {
        if (Test-Path $statusFile) {
            try { if ((Get-Content -Raw $statusFile | ConvertFrom-Json).State -eq 'SHOWING') { $shownAt = Get-Date } } catch {}
        }
        Start-Sleep -Milliseconds 500
    }
    Test-Check 'opening the shortcut starts the launcher on screen S1, which shows the report' ([bool]$shownAt)
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like "*$InstallLocal*" })
    $parent = if ($procs.Count) { (Get-CimInstance Win32_Process -Filter "ProcessId = $($procs[0].ParentProcessId)").Name } else { '' }
    Test-Check 'the launcher runs under conhost.exe' ($parent -eq 'conhost.exe') $parent
    $log = Get-Content -Raw (Get-ChildItem (Join-Path $InstallS1 'Logs') -File | Select-Object -First 1).FullName
    Test-Check 'its console was already hidden (-WindowStyle Hidden)' ($log -match 'Console window: hidden\.') ([regex]::Match($log, 'Console window: [^\]]*').Value)
    # Let it finish on its own (ExitAfterSeconds).
    $null = Wait-Process -Id ($procs | ForEach-Object ProcessId) -Timeout 60 -ErrorAction SilentlyContinue
}
finally {
    try { $wc = New-Object Net.WebClient; $wc.Proxy = $null; $null = $wc.DownloadString("http://127.0.0.1:$Port/stop") } catch {}
    Start-Sleep -Seconds 1
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
    Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" | Where-Object { $_.CommandLine -like "*$InstallLocal*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

$failed = @($Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("{0} checks, {1} failed." -f $Results.Count, $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
foreach ($f in $failed) { Write-Host ("  FAIL {0} {1}" -f $f.Check, $f.Detail) -ForegroundColor Red }
if (-not $KeepWorkRoot -and $failed.Count -eq 0) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue }
exit $failed.Count
