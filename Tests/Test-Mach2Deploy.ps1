#Requires -Version 5.1
<#
.SYNOPSIS
    Tests Deploy-Mach2LauncherNG.ps1 and Get-Mach2LauncherNGStatus.ps1
    against fake kiosks - folders that stand in for each kiosk's C: drive -
    and checks that the startup shortcut the deploy creates really starts
    the launcher.

.DESCRIPTION
    No real kiosk is contacted, and the old watchdog's logon task is not
    touched (a test root has no Task Scheduler to reach). The fake kiosks:

      M2K1  one screen: Mach2Launcher.exe in Launcher S1 (and an unused
            Launcher S2), StartupLauncher, the old watchdog's files and a
            Startup shortcut to it
      M2K2  two screens: a config in Launcher S1 and in Launcher S2
      M2K3  nothing installed
      M2K4  old launcher, but the kiosk account has no profile
      M2K5  StartupLauncher also starts a Power BI launcher

    Do not run it at the same time as Test-Mach2LauncherNG.ps1: both start
    launchers that want to be this session's watchdog.

    Takes about a minute and a half.
#>
[CmdletBinding()]
param(
    [string]$Deploy = (Join-Path $PSScriptRoot '..\Deploy-Mach2LauncherNG.ps1'),
    [string]$WorkRoot = (Join-Path $env:TEMP 'Mach2DeployTests'),
    [int]$Port = 18773,
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
$StartupRel = 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'

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

function New-LegacyConfig {
    param([string]$Name, [string]$Screen)
    return @"
[
 {
   "JsonVer": "1.0.0.16",
   "LoginURL": "http://SHCZ5PLC02:302/prelogin?clear=true",
   "DisplayURL": "http://shcz5plc02:302/deltav/dashboard:viewer/@/Nyrany/W0$($Screen.Substring(1))/Dashboards/Graphs",
   "ZoomPercent": "100",
   "ZoomDelay": "500",
   "UsePriScreen": "$(if ($Screen -eq 'S1') { '1' } else { '0' })",
   "ScreenSelect": "$($Screen.Substring(1))",
   "KioskMode": "1",
   "ElementTimeout": "30",
   "ForcedRefreshTime": "12:00",
   "EnableRefresh": "1",
   "BrowserRefreshDelay": "30",
   "UpdateEdgeDriver": "1",
   "EdgeDriverSharePath": "\\\\shghmgt09\\MSEdgeDriver",
   "LogPath": "",
   "RemoteLogPath": "\\\\shghmgt09\\Mach2Launcher\\Logs",
   "LogName": "Mach2Launcher_${Name}_${Screen}_W0$($Screen.Substring(1)).log",
   "StartupDelay": "0",
   "DisableStartup": "0",
   "DebugLogging": "0",
   "ScheduledRestartEnabled": "0",
   "ScheduledRestartTime": "06:00",
   "RestartDelay": "30",
   "UsernameFieldName": "j_username",
   "UserName": "operator",
   "PasswordFieldName": "j_password",
   "Password": "$($LegacyPassword.Replace('"', '\"'))",
   "LoginButtonID": "login-submit",
   "LoginDelay": "1000"
 }
]
"@
}

function New-FakeKiosk {
    param([string]$Name, [string[]]$Screens = @('S1'), [switch]$NoLegacy, [switch]$NoProfile, [switch]$Watchdog, [switch]$PbiToo)
    $c = Join-Path $Fake $Name
    $pub = Join-Path $c 'Users\Public\Documents'
    $m2 = Join-Path $pub 'Mach2Launchers'
    New-Item -ItemType Directory -Path $pub -Force | Out-Null
    if (-not $NoProfile) { New-Item -ItemType Directory -Path (Join-Path $c "Users\$Name\$StartupRel") -Force | Out-Null }
    if ($NoLegacy) { return }
    foreach ($s in @('S1', 'S2')) {
        $d = Join-Path $m2 "Launcher $s"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'Mach2Launcher.exe') -Value 'fake'
        if ($s -in $Screens) { [IO.File]::WriteAllText((Join-Path $d "$Name.json"), (New-LegacyConfig -Name $Name -Screen $s), $Utf8) }
    }
    $sl = Join-Path $m2 'StartupLauncher'
    New-Item -ItemType Directory -Path $sl -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $sl 'StartupLauncher.exe') -Value 'fake'
    $second = '"LauncherPath2": "C:\\Users\\Public\\Documents\\Mach2Launchers\\Launcher S2", "LauncherName2": "Mach2Launcher.exe",'
    if ($PbiToo) {
        New-Item -ItemType Directory -Path (Join-Path $pub 'Launchers\Launcher S3') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $pub 'Launchers\Launcher S3\PowerBILauncher.exe') -Value 'fake'
        [IO.File]::WriteAllText((Join-Path $pub "Launchers\Launcher S3\$Name.json"), '[{ "DisplayURL": "https://app.powerbi.com/x" }]', $Utf8)
        $second = '"LauncherPath2": "C:\\Users\\Public\\Documents\\Launchers\\Launcher S3", "LauncherName2": "PowerBILauncher.exe",'
    }
    $sj = @"
[{ "JsonVer": "1.0.0.3", "LastLauncher": "$($Screens.Count)",
   "LauncherPath1": "C:\\Users\\Public\\Documents\\Mach2Launchers\\Launcher S1", "LauncherName1": "Mach2Launcher.exe",
   $second
   "LauncherPath3": "C:\\Users\\Public\\Documents\\Mach2Launchers\\Launcher S3", "LauncherName3": "Mach2Launcher.exe",
   "LauncherPath4": "C:\\Users\\Public\\Documents\\Mach2Launchers\\Launcher S4", "LauncherName4": "Mach2Launcher.exe" }]
"@
    [IO.File]::WriteAllText((Join-Path $sl "$Name.json"), $sj, $Utf8)
    if (-not $NoProfile) {
        New-Link -Path (Join-Path $c "Users\$Name\$StartupRel\StartupLauncher.exe.lnk") -Target 'C:\Users\Public\Documents\Mach2Launchers\StartupLauncher\StartupLauncher.exe'
    }
    if ($Watchdog) {
        Set-Content -LiteralPath (Join-Path $pub 'mwstv4.ps1') -Value '# old watchdog'
        Set-Content -LiteralPath (Join-Path $pub 'MWSTv6_Launcher.bat') -Value '@echo off'
        New-Link -Path (Join-Path $c "Users\$Name\$StartupRel\MWST Watchdog.lnk") -Target 'C:\Users\Public\Documents\MWSTv6_Launcher.bat'
    }
}

function Invoke-Deploy {
    param([string[]]$Arguments)
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
    $f = Get-ChildItem -LiteralPath $Reports -Filter 'm2ng-deploy_*.csv' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    return @(Import-Csv -LiteralPath $f.FullName)
}

function Read-Json { param([string]$Path) return @(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)))[0] }

# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
New-FakeKiosk M2K1 -Watchdog
New-FakeKiosk M2K2 -Screens S1, S2
New-FakeKiosk M2K3 -NoLegacy
New-FakeKiosk M2K4 -NoProfile
New-FakeKiosk M2K5 -PbiToo
# TV4 as 1.00NG left it: an old config with no DisableStartup, the renamed
# shortcut that made Windows ask what to open it with, and a fresh one the
# logon script (Mach2LauncherShortcuts.ps1) copied back.
New-FakeKiosk M2K6
$k6Legacy = Join-Path $Fake 'M2K6\Users\Public\Documents\Mach2Launchers\Launcher S1\M2K6.json'
[IO.File]::WriteAllText($k6Legacy, (([IO.File]::ReadAllText($k6Legacy)) -replace '\s*"DisableStartup"\s*:\s*"[^"]*",?', ''), $Utf8)
$k6Startup = Join-Path $Fake "M2K6\Users\M2K6\$StartupRel"
Copy-Item (Join-Path $k6Startup 'StartupLauncher.exe.lnk') (Join-Path $k6Startup 'StartupLauncher.exe.lnk.disabled-by-Mach2LauncherNG')
New-FakeKiosk M2K7
$k1 = Join-Path $Fake 'M2K1'
$k1Install = Join-Path $k1 'Users\Public\Documents\Mach2LauncherNG'
$k1Startup = Join-Path $k1 "Users\M2K1\$StartupRel"
$k1Legacy = Join-Path $k1 'Users\Public\Documents\Mach2Launchers\Launcher S1\M2K1.json'

Write-Host "`n== WhatIf" -ForegroundColor Cyan
$before = Get-TreeFingerprint $Fake
$r = Invoke-Deploy @('-Hosts', 'M2K1,M2K2', '-WhatIf')
Test-Check 'WhatIf changes nothing' ((Get-TreeFingerprint $Fake) -eq $before) (($r.Text -split "`n" | Select-String 'FAILED|Exception' | Select-Object -First 2) -join ' | ')
Test-Check 'WhatIf run reports WHATIF' ($r.Text -match 'WHATIF')

Write-Host "`n== Install on five fake kiosks" -ForegroundColor Cyan
$r = Invoke-Deploy @('-Hosts', 'M2K1,M2K2,M2K3,M2K4,M2K5')
$rep = Get-LatestReport
$by = @{}; foreach ($row in $rep) { $by[$row.Host] = $row }
Test-Check 'M2K1 INSTALLED, one screen, S1 the watchdog' ($by['M2K1'].Result -eq 'INSTALLED' -and $by['M2K1'].Instances -eq 'S1 (watchdog: S1)') "$($by['M2K1'].Result) $($by['M2K1'].Instances) $($by['M2K1'].Detail)"
Test-Check 'M2K2 INSTALLED, two screens' ($by['M2K2'].Result -eq 'INSTALLED' -and $by['M2K2'].Instances -eq 'S1,S2 (watchdog: S1)') "$($by['M2K2'].Result) $($by['M2K2'].Instances)"
Test-Check 'M2K3 NO_CONFIG (nothing to migrate)' ($by['M2K3'].Result -eq 'NO_CONFIG') $by['M2K3'].Result
Test-Check 'M2K4 FAILED (no kiosk profile)' ($by['M2K4'].Result -eq 'FAILED' -and $by['M2K4'].Detail -like '*no profile*') "$($by['M2K4'].Result) $($by['M2K4'].Detail)"
Test-Check 'exit code 1 because of M2K4' ($r.Code -eq 1) $r.Code
Test-Check 'M2K3/M2K4 got no files' (-not (Test-Path (Join-Path $Fake 'M2K3\Users\Public\Documents\Mach2LauncherNG')) -and -not (Test-Path (Join-Path $Fake 'M2K4\Users\Public\Documents\Mach2LauncherNG')))

$srcHash = (Get-FileHash (Join-Path $ProjectDir 'Mach2LauncherNG\Mach2LauncherNG.ps1')).Hash
Test-Check 'launcher installed intact, with its start script and template' ((Get-FileHash (Join-Path $k1Install 'Mach2LauncherNG.ps1')).Hash -eq $srcHash -and (Test-Path (Join-Path $k1Install 'Start-Mach2LauncherNG.cmd')) -and (Test-Path (Join-Path $k1Install 'EXAMPLE.json')))

$cfgPath = Join-Path $k1Install 'S1\M2K1.json'
$cfg = Read-Json $cfgPath
Test-Check 'config migrated: dashboard, login, user, Niagara fields' ($cfg.DisplayURL -like '*/Nyrany/W01/Dashboards/Graphs' -and $cfg.LoginURL -like '*prelogin?clear=true' -and $cfg.UserName -eq 'operator' -and $cfg.UsernameFieldName -eq 'j_username' -and $cfg.PasswordFieldName -eq 'j_password' -and $cfg.LoginButtonID -eq 'login-submit')
Test-Check 'config migrated: screen, refresh, central log with the new name' ($cfg.UsePriScreen -eq '1' -and $cfg.EnableRefresh -eq '1' -and $cfg.BrowserRefreshDelay -eq '30' -and $cfg.ForcedRefreshTime -eq '12:00' -and $cfg.RemoteLogPath -eq '\\shghmgt09\Mach2Launcher\Logs' -and $cfg.LogName -eq 'Mach2LauncherNG_M2K1_S1_W01.log') $cfg.LogName
Test-Check 'config migrated: ver 1.00NG, the watchdog, enabled' ($cfg.ConfigVersion -eq '1.00NG' -and $cfg.Watchdog -eq '1' -and $cfg.DisableStartup -eq '0')
Test-Check 'config migrated: no password, no Selenium settings' (-not $cfg.PSObject.Properties['Password'] -and -not $cfg.PSObject.Properties['EdgeDriverSharePath'] -and -not $cfg.PSObject.Properties['ZoomDelay'] -and -not ([IO.File]::ReadAllText($cfgPath)).Contains($LegacyPassword))
Test-Check 'password handed over as password.seed' ([IO.File]::ReadAllText((Join-Path $k1Install 'S1\password.seed')) -ceq $LegacyPassword) $by['M2K1'].Password

$k2Install = Join-Path $Fake 'M2K2\Users\Public\Documents\Mach2LauncherNG'
Test-Check 'two screens: S1 is the watchdog, S2 is not, each its own dashboard' ((Read-Json (Join-Path $k2Install 'S1\M2K2.json')).Watchdog -eq '1' -and (Read-Json (Join-Path $k2Install 'S2\M2K2.json')).Watchdog -eq '0' -and (Read-Json (Join-Path $k2Install 'S2\M2K2.json')).DisplayURL -like '*/W02/*')

$l = $Shell.CreateShortcut((Join-Path $k1Startup 'Mach2 Launcher NG S1.lnk'))
Test-Check 'startup shortcut: conhost > hidden PowerShell > launcher -Instance S1' ($l.TargetPath -ieq 'C:\Windows\System32\conhost.exe' -and $l.Arguments -like '*powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\Users\Public\Documents\Mach2LauncherNG\Mach2LauncherNG.ps1" -Instance S1' -and $l.WorkingDirectory -eq 'C:\Users\Public\Documents\Mach2LauncherNG') "$($l.TargetPath) $($l.Arguments)"
Test-Check 'two screens: two startup shortcuts' ((Test-Path (Join-Path $Fake "M2K2\Users\M2K2\$StartupRel\Mach2 Launcher NG S1.lnk")) -and (Test-Path (Join-Path $Fake "M2K2\Users\M2K2\$StartupRel\Mach2 Launcher NG S2.lnk")))
$k1Retired = Join-Path $k1Install 'Retired shortcuts\M2K1'
Test-Check 'old StartupLauncher shortcut moved out of the Startup folder' ((Test-Path (Join-Path $k1Retired 'StartupLauncher.exe.lnk')) -and -not (Test-Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk')))
# Windows opens everything in a Startup folder at logon; anything that is
# not a shortcut there is "opened" with a Select-an-app dialog.
Test-Check 'nothing is left in the Startup folder that Windows would ask about' (@(Get-ChildItem $k1Startup -File | Where-Object { $_.Extension -ne '.lnk' }).Count -eq 0) ((Get-ChildItem $k1Startup -File | ForEach-Object Name) -join ', ')
Test-Check 'the new launcher stops the old one for its screen (StopOldLauncher = 1)' ($cfg.StopOldLauncher -eq '1')
$legacyText = [IO.File]::ReadAllText("$k1Legacy.disabled-by-Mach2LauncherNG")
Test-Check 'old config renamed out of the way (the logon script makes no shortcut without it), password untouched' (-not (Test-Path $k1Legacy) -and $legacyText.Contains('"Password"'))
$k1Sl = Join-Path $k1 'Users\Public\Documents\Mach2Launchers\StartupLauncher'
Test-Check 'StartupLauncher has nothing left to start: its config renamed too' (-not (Test-Path (Join-Path $k1Sl 'M2K1.json')) -and (Test-Path (Join-Path $k1Sl 'M2K1.json.disabled-by-Mach2LauncherNG')))
Test-Check 'two screens: both old configs and StartupLauncher''s renamed' (-not (Test-Path (Join-Path $Fake 'M2K2\Users\Public\Documents\Mach2Launchers\Launcher S2\M2K2.json')) -and $by['M2K2'].Legacy -match 'JSON renamed 3') $by['M2K2'].Legacy
Test-Check 'old watchdog: its Startup shortcut moved out too, its files kept' ((Test-Path (Join-Path $k1Retired 'MWST Watchdog.lnk')) -and -not (Test-Path (Join-Path $k1Startup 'MWST Watchdog.lnk')) -and (Test-Path (Join-Path $k1 'Users\Public\Documents\mwstv4.ps1')) -and $by['M2K1'].Watchdog -match 'task not checked \(test root\); startup shortcut\(s\) retired 1') $by['M2K1'].Watchdog
$m = Read-Json (Join-Path $k1Install 'migration.json')
$fromTo = @($m.RetiredShortcuts | ForEach-Object { "$($_.From) -> $($_.To)" })
Test-Check 'migration.json records where each retired shortcut came from and went' (
    $m.KioskUser -eq 'M2K1' -and $m.WatchdogInstance -eq 'S1' -and @($m.RetiredShortcuts).Count -eq 2 -and @($m.LegacyJsonRenamed).Count -eq 2 -and @($m.Shortcuts).Count -eq 1 -and
    @($m.RetiredShortcuts | Where-Object { $_.From -like "C:\Users\M2K1\*\Startup\StartupLauncher.exe.lnk" -and $_.To -eq 'C:\Users\Public\Documents\Mach2LauncherNG\Retired shortcuts\M2K1\StartupLauncher.exe.lnk' }).Count -eq 1) ($fromTo -join ' | ')
Test-Check 'the old launcher may stop before the restart: warned' ($by['M2K1'].Detail -match 'WARNING: the old launcher now exits')

$k5Startup = Join-Path $Fake "M2K5\Users\M2K5\$StartupRel"
Test-Check 'M2K5: StartupLauncher kept (it also starts Power BI)' ($by['M2K5'].Result -eq 'INSTALLED' -and (Test-Path (Join-Path $k5Startup 'StartupLauncher.exe.lnk')) -and $by['M2K5'].Detail -like '*PowerBILauncher.exe*') $by['M2K5'].Detail
Test-Check 'M2K5: its old Mach2 config renamed, StartupLauncher''s kept (it still starts Power BI)' (-not (Test-Path (Join-Path $Fake 'M2K5\Users\Public\Documents\Mach2Launchers\Launcher S1\M2K5.json')) -and (Test-Path (Join-Path $Fake 'M2K5\Users\Public\Documents\Mach2Launchers\StartupLauncher\M2K5.json')) -and $by['M2K5'].Detail -like '*StartupLauncher kept*PowerBILauncher.exe*') $by['M2K5'].Detail

Write-Host "`n== Second run" -ForegroundColor Cyan
Set-Content -LiteralPath $cfgPath -Value ((Get-Content -Raw $cfgPath) -replace '"DebugLogging":\s*"0"', '"DebugLogging": "1"') -NoNewline
$r = Invoke-Deploy @('-Hosts', 'M2K1')
$row = @(Get-LatestReport)[0]
Test-Check 'files UP_TO_DATE, config KEPT (local edit survives), seed still waiting' ($row.Files -eq 'UP_TO_DATE' -and $row.Config -eq 'S1:KEPT' -and $row.Password -eq 'S1:SEED_WAITING' -and (Get-Content -Raw $cfgPath) -match '"DebugLogging": "1"') "$($row.Files) $($row.Config) $($row.Password)"
$m = Read-Json (Join-Path $k1Install 'migration.json')
Test-Check 'migration.json still holds the first run''s changes' (@($m.RetiredShortcuts).Count -eq 2 -and @($m.LegacyJsonRenamed).Count -eq 2)
New-Link -Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk') -Target 'C:\Users\Public\Documents\Mach2Launchers\StartupLauncher\StartupLauncher.exe'
$r = Invoke-Deploy @('-Hosts', 'M2K1')
$row = @(Get-LatestReport)[0]
Test-Check 'a StartupLauncher shortcut put back at logon is moved out again, and reported as harmless' (
    $row.Result -eq 'INSTALLED' -and $row.Detail -like '*is back*' -and $row.Detail -like '*stops the old one*' -and
    -not (Test-Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk')) -and (Test-Path (Join-Path $k1Retired 'StartupLauncher.exe.lnk'))) $row.Detail
$m = Read-Json (Join-Path $k1Install 'migration.json')
Test-Check 'and it is still one record, not two' (@($m.RetiredShortcuts).Count -eq 2)

Write-Host "`n== New password, -UpdateConfig" -ForegroundColor Cyan
Remove-Item (Join-Path $k1Install 'S1\password.seed')
Set-Content (Join-Path $k1Install 'S1\M2K1.cred') -Value '{}'
$r = Invoke-Deploy @('-Hosts', 'M2K1')
Test-Check 'an existing .cred is not overwritten by the old password' (@(Get-LatestReport)[0].Password -eq 'S1:ALREADY_STORED' -and -not (Test-Path (Join-Path $k1Install 'S1\password.seed')))
# -SignInCredential cannot be passed through powershell.exe -File.
$cred = New-Object Management.Automation.PSCredential('operator', (ConvertTo-SecureString 'Brand-New-Pass1' -AsPlainText -Force))
& $Deploy -Hosts M2K1 -RootTemplate $Template -ReportDir $Reports -SignInCredential $cred -UpdateConfig *> $null
$row = @(Get-LatestReport)[0]
Test-Check '-SignInCredential writes a new seed' ($row.Password -eq 'S1:SEED_FROM_PARAMETER' -and [IO.File]::ReadAllText((Join-Path $k1Install 'S1\password.seed')) -ceq 'Brand-New-Pass1') $row.Password
Test-Check '-UpdateConfig rewrites from the old config, with a backup' ($row.Config -eq 'S1:FROM_OLD_LAUNCHER' -and (Get-Content -Raw $cfgPath) -match '"DebugLogging":\s*"0"' -and @(Get-ChildItem (Join-Path $k1Install 'S1') -Filter 'M2K1.json.bak-*').Count -ge 1)

Write-Host "`n== Commands" -ForegroundColor Cyan
$null = Invoke-Deploy @('-Hosts', 'M2K2', '-Command', 'Refresh')
Test-Check '-Command Refresh reaches every screen' ((Test-Path (Join-Path $k2Install 'S1\refresh.txt')) -and (Test-Path (Join-Path $k2Install 'S2\refresh.txt')))
$null = Invoke-Deploy @('-Hosts', 'M2K2', '-Command', 'Hold', '-Instance', 'S2')
Test-Check '-Command Hold -Instance S2 reaches only S2' ((Test-Path (Join-Path $k2Install 'S2\hold.txt')) -and -not (Test-Path (Join-Path $k2Install 'S1\hold.txt')))
$null = Invoke-Deploy @('-Hosts', 'M2K2', '-Command', 'Resume')
Test-Check '-Command Resume removes hold.txt' (-not (Test-Path (Join-Path $k2Install 'S2\hold.txt')))
$null = Invoke-Deploy @('-Hosts', 'M2K3', '-Command', 'Stop')
Test-Check '-Command on a kiosk without the launcher: NOT_INSTALLED' (@(Get-LatestReport)[0].Result -eq 'NOT_INSTALLED')

Write-Host "`n== Rollback" -ForegroundColor Cyan
$r = Invoke-Deploy @('-Hosts', 'M2K1', '-Rollback')
$row = @(Get-LatestReport)[0]
Test-Check 'ROLLED_BACK' ($row.Result -eq 'ROLLED_BACK') "$($row.Result) $($row.Legacy) $($row.Watchdog) $($row.Detail)"
Test-Check 'new shortcut removed; old launcher''s and old watchdog''s back' (-not (Test-Path (Join-Path $k1Startup 'Mach2 Launcher NG S1.lnk')) -and (Test-Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk')) -and (Test-Path (Join-Path $k1Startup 'MWST Watchdog.lnk')) -and @(Get-ChildItem $k1Startup -Filter '*.disabled-by-Mach2LauncherNG').Count -eq 0)
Test-Check 'the retired copies are gone from where they were kept' (@(Get-ChildItem $k1Retired -File -ErrorAction SilentlyContinue).Count -eq 0)
Test-Check 'old config and StartupLauncher''s renamed back' ((Test-Path $k1Legacy) -and -not (Test-Path "$k1Legacy.disabled-by-Mach2LauncherNG") -and (Test-Path (Join-Path $k1Sl 'M2K1.json')) -and $row.Legacy -match 'JSON renamed back 2') $row.Legacy
Test-Check 'new launcher told to stop, files kept, migration archived' ((Test-Path (Join-Path $k1Install 'S1\kill.txt')) -and (Test-Path (Join-Path $k1Install 'Mach2LauncherNG.ps1')) -and -not (Test-Path (Join-Path $k1Install 'migration.json')) -and @(Get-ChildItem $k1Install -Filter 'migration.json.rolledback-*').Count -eq 1)
Remove-Item (Join-Path $k1Install 'S1\kill.txt')
$r = Invoke-Deploy @('-Hosts', 'M2K1')
Test-Check 'install again after rollback works' (@(Get-LatestReport)[0].Result -eq 'INSTALLED' -and (Test-Path (Join-Path $k1Startup 'Mach2 Launcher NG S1.lnk')) -and -not (Test-Path (Join-Path $k1Startup 'StartupLauncher.exe.lnk')) -and (Test-Path (Join-Path $k1Retired 'StartupLauncher.exe.lnk')))

Write-Host "`n== A kiosk that 1.00NG left with the Select-an-app dialog (TV4)" -ForegroundColor Cyan
$r = Invoke-Deploy @('-Hosts', 'M2K6')
$row = @(Get-LatestReport)[0]
$k6Install = Join-Path $Fake 'M2K6\Users\Public\Documents\Mach2LauncherNG'
Test-Check 'the renamed shortcut and the one put back are both out of the Startup folder' (
    $row.Result -eq 'INSTALLED' -and @(Get-ChildItem $k6Startup -File | ForEach-Object Name) -join ',' -eq 'Mach2 Launcher NG S1.lnk') ((Get-ChildItem $k6Startup -File | ForEach-Object Name) -join ', ')
Test-Check 'one retired copy is kept, under its real name' (@(Get-ChildItem (Join-Path $k6Install 'Retired shortcuts\M2K6') -File | ForEach-Object Name) -join ',' -eq 'StartupLauncher.exe.lnk')
Test-Check 'the report says the renamed one was cleared' ($row.Detail -like '*1.00NG had renamed out of the Startup folder*') $row.Detail
Test-Check 'an old config with no DisableStartup is not reported as a failure' ($row.Detail -notlike '*could not set DisableStartup*') $row.Detail
$k6Migration = Join-Path $k6Install 'migration.json'
Test-Check 'empty lists are written as lists, not as {}' ([IO.File]::ReadAllText($k6Migration) -notmatch ':\s*\{\s*\}') ([IO.File]::ReadAllText($k6Migration) -replace '\s+', ' ')
# ... but 1.00NG wrote them as {}, as on TV4, where nothing was disabled in
# the old config. Read back, {} is one blank entry: a blank path is C:\.
$old = [IO.File]::ReadAllText($k6Migration)
$old = $old -replace '"LegacyConfigsDisabled"\s*:\s*\[\s*\]', '"LegacyConfigsDisabled": { }' -replace '"WatchdogTasksDisabled"\s*:\s*\[\s*\]', '"WatchdogTasksDisabled": { }'
[IO.File]::WriteAllText($k6Migration, $old, $Utf8)
$r = Invoke-Deploy @('-Hosts', 'M2K6', '-Rollback')
$row6 = @(Get-LatestReport)[0]
Test-Check 'a record with 1.00NG''s {} lists still rolls back' ($row6.Result -eq 'ROLLED_BACK') "$($row6.Result) $($row6.Detail)"
Test-Check 'and the kiosk''s own folders are untouched' ((Test-Path (Join-Path $Fake 'M2K6\Users')) -and (Test-Path (Join-Path $Fake 'M2K6\Users\Public\Documents\Mach2Launchers\Launcher S1\M2K6.json')))
Test-Check 'rolling back puts exactly one StartupLauncher shortcut back' (
    @(Get-LatestReport)[0].Result -eq 'ROLLED_BACK' -and @(Get-ChildItem $k6Startup -File | ForEach-Object Name) -join ',' -eq 'StartupLauncher.exe.lnk') ((Get-ChildItem $k6Startup -File | ForEach-Object Name) -join ', ')

Write-Host "`n== -KeepLegacy" -ForegroundColor Cyan
$r = Invoke-Deploy @('-Hosts', 'M2K7', '-KeepLegacy')
$k7Startup = Join-Path $Fake "M2K7\Users\M2K7\$StartupRel"
$k7Cfg = Read-Json (Join-Path $Fake 'M2K7\Users\Public\Documents\Mach2LauncherNG\S1\M2K7.json')
Test-Check '-KeepLegacy keeps the old shortcut and tells the new launcher to leave the old one running' (
    (Test-Path (Join-Path $k7Startup 'StartupLauncher.exe.lnk')) -and $k7Cfg.StopOldLauncher -eq '0') "StopOldLauncher=$($k7Cfg.StopOldLauncher)"

Write-Host "`n== Argument checks" -ForegroundColor Cyan
$r = Invoke-Deploy @()
Test-Check 'refuses to run without -Hosts or -AllMach2Kiosks' ($r.Code -ne 0 -and $r.Text -match 'AllMach2Kiosks')
$r = Invoke-Deploy @('-Hosts', 'M2K1', '-Restart')
Test-Check 'refuses -Restart on test roots' ($r.Code -ne 0 -and $r.Text -match 'Restart needs real kiosks')
$r = Invoke-Deploy @('-Hosts', 'M2K1', '-Instance', 'S1')
Test-Check 'refuses -Instance without -Command' ($r.Code -ne 0 -and $r.Text -match 'Instance goes with -Command')

Write-Host "`n== Get-Mach2LauncherNGStatus" -ForegroundColor Cyan
$statusTool = Join-Path $ProjectDir 'Get-Mach2LauncherNGStatus.ps1'
$now = [DateTime]::UtcNow
foreach ($pair in @(@('S1', 10, 'SHOWING'), @('S2', 72000, 'SHOWING'))) {
    $d = Join-Path $k2Install "$($pair[0])\Status"
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $d "$($pair[0]).status.json"), (ConvertTo-Json ([pscustomobject]@{
                    Instance = $pair[0]; State = $pair[2]; StateSinceUtc = $now.AddHours(-3).ToString('o'); LastShownUtc = $now.ToString('o'); UpdatedUtc = $now.AddSeconds(-$pair[1]).ToString('o')
                    LauncherVersion = '1.00NG'; Watchdog = ($pair[0] -eq 'S1'); LoopGuard = ''; PageWhitePercent = 71.8; ScreenWhitePercent = $(if ($pair[0] -eq 'S1') { 72.4 } else { $null })
                    SignIns = 1; Reloads = 12; BrowserStarts = 1; PcRestarts = 0; Detail = ''; LastError = ''
                })), $Utf8)
}
$rows = @(& $statusTool -Hosts 'M2K1,M2K2,M2K3,M2K4' -RootTemplate $Template -FleetRoot $ProjectDir -PassThru)
$get = { param($h, $i) @($rows | Where-Object { $_.Host -eq $h -and (-not $i -or $_.Instance -eq $i) })[0] }
Test-Check 'status: installed but never run = NO_STATUS' ((& $get 'M2K1').State -eq 'NO_STATUS') (& $get 'M2K1').State
Test-Check 'status: fresh SHOWING with the watchdog mark and readings' ((& $get 'M2K2' 'S1').State -eq 'SHOWING' -and (& $get 'M2K2' 'S1').Watchdog -eq '*' -and (& $get 'M2K2' 'S1').Screen -eq '72%' -and (& $get 'M2K2' 'S1').Page -eq '72%' -and (& $get 'M2K2' 'S1').For -eq '3h')
Test-Check 'status: a status file not written for 20 h = STALE' ((& $get 'M2K2' 'S2').State -eq 'STALE' -and (& $get 'M2K2' 'S2').Detail -like '*last said SHOWING*') "$((& $get 'M2K2' 'S2').State) $((& $get 'M2K2' 'S2').Detail)"
Test-Check 'status: nothing = NOT_INSTALLED, old launcher = OLD_LAUNCHER' ((& $get 'M2K3').State -eq 'NOT_INSTALLED' -and (& $get 'M2K4').State -eq 'OLD_LAUNCHER') "$((& $get 'M2K3').State) $((& $get 'M2K4').State)"
$printed = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $statusTool -Hosts 'M2K1,M2K2,M2K3' -RootTemplate $Template 2>&1 | Out-String
Test-Check 'status: table prints' ($LASTEXITCODE -eq 0 -and $printed -match 'M2K2\s+S1\s+SHOWING' -and $printed -match 'STALE') (($printed.Trim() -split "`n" | Select-Object -First 2) -join ' | ')

# ---------------------------------------------------------------------------
Write-Host "`n== The startup shortcut starts the launcher" -ForegroundColor Cyan
# The same shortcut the deploy builds, pointed at a local copy and told to
# run headless and never restart this PC, opened the way Windows opens
# Startup items.
$ast = [Management.Automation.Language.Parser]::ParseFile($Deploy, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'New-LauncherShortcut' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
$script:Shell = $Shell
$LauncherVersion = '1.02NG'
$InstallLocal = Join-Path $WorkRoot 'local-install'
$inst = Join-Path $InstallLocal 'S1'
New-Item -ItemType Directory -Path $inst -Force | Out-Null
Copy-Item (Join-Path $ProjectDir 'Mach2LauncherNG\Mach2LauncherNG.ps1') $InstallLocal
$pwFile = Join-Path $WorkRoot 'pw.txt'
[IO.File]::WriteAllText($pwFile, 'Shortcut-Test-1', $Utf8)
[IO.File]::WriteAllText((Join-Path $inst 'password.seed'), 'Shortcut-Test-1', $Utf8)
$cfg = [ordered]@{
    DisplayURL = "http://127.0.0.1:$Port/deltav/dashboard:viewer/@/Nyrany/TEST/Dashboards/Graphs"; LoginURL = "http://127.0.0.1:$Port/prelogin?clear=true"; UserName = 'operator'
    ProfileDir = (Join-Path $InstallLocal 'Profile'); WatchdogPath = (Join-Path $InstallLocal 'wd'); HealthCheckSeconds = '2'; DisplayWaitSeconds = '0'
}
[IO.File]::WriteAllText((Join-Path $inst "$env:COMPUTERNAME.json"), (ConvertTo-Json ([pscustomobject]$cfg)), $Utf8)
$lnk = Join-Path $WorkRoot 'Mach2 Launcher NG S1.lnk'
New-LauncherShortcut -Path $lnk -InstanceName 'S1' -ExtraArguments '-Headless -SimulateRestart -ExitAfterSeconds 45'

$server = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $PSScriptRoot 'Mach2Fixture.ps1')), '-Port', $Port, '-EventsFile', ('"{0}"' -f (Join-Path $WorkRoot 'events.jsonl')), '-PasswordFile', ('"{0}"' -f $pwFile))
try {
    Start-Sleep -Seconds 3
    $shownAt = $null
    Start-Process -FilePath $lnk
    $statusFile = Join-Path $inst 'Status\S1.status.json'
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline -and -not $shownAt) {
        if (Test-Path $statusFile) {
            try { if ((Get-Content -Raw $statusFile | ConvertFrom-Json).State -eq 'SHOWING') { $shownAt = Get-Date } } catch {}
        }
        Start-Sleep -Milliseconds 500
    }
    Test-Check 'opening the shortcut starts the launcher, which signs in and shows the dashboard' ([bool]$shownAt)
    $procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like "*$InstallLocal*" })
    $parent = if ($procs.Count) { (Get-CimInstance Win32_Process -Filter "ProcessId = $($procs[0].ParentProcessId)").Name } else { '' }
    Test-Check 'the launcher runs under conhost.exe' ($parent -eq 'conhost.exe') $parent
    $ledger = Join-Path $InstallLocal 'wd\mwst_events.csv'
    $start = @(if (Test-Path $ledger) { Get-Content $ledger | Where-Object { $_ -like '*"AGENT_START"*' } })
    Test-Check 'its console was already hidden, and the watchdog says so: Console=conhost, Window=hidden' ($start.Count -eq 1 -and $start[0] -match 'Console=conhost' -and $start[0] -match 'Window=hidden') $(if ($start) { $start[0] })
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
