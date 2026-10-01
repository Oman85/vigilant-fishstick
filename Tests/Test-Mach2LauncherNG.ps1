#Requires -Version 5.1
<#
.SYNOPSIS
    Tests Mach2 Launcher ver 1.00NG: unit checks on its helpers, end-to-end
    runs against Mach2Fixture.ps1 with a headless Edge, and the collector
    reading what it writes.

.DESCRIPTION
    Nothing here touches a real station, kiosk or the published CSV, and no
    PC is restarted: the launcher runs with -SimulateRestart, which records
    every restart it would make without calling shutdown.exe, and with
    -Headless, which leaves this PC's screen alone. Each scenario gets its
    own folder under -WorkRoot, with its own Edge profile and its own
    watchdog folder (WatchdogPath) standing in for Public\Documents; the
    launcher only closes Edge processes that use its own profile.

    One scenario starts a stand-in for the old watchdog (a script named
    mwstv4.ps1 under -WorkRoot) to check that the launcher stops it.

    Takes about fifteen minutes.

.EXAMPLE
    .\Tests\Test-Mach2LauncherNG.ps1

.EXAMPLE
    .\Tests\Test-Mach2LauncherNG.ps1 -Only Unit, Watchdog
#>
[CmdletBinding()]
param(
    [string]$Launcher = (Join-Path $PSScriptRoot '..\Mach2LauncherNG\Mach2LauncherNG.ps1'),
    [string]$FleetRoot = (Join-Path $PSScriptRoot '..'),
    [string]$WorkRoot = (Join-Path $env:TEMP 'Mach2LauncherNGTests'),
    [int]$Port = 18771,
    [ValidateSet('Unit', 'OldLauncher', 'Main', 'Watchdog', 'LoopGuard', 'Outage', 'WrongPassword', 'SlowStation', 'SinglePage', 'SecondScreen', 'Disabled', 'Collector')]
    [string[]]$Only,
    [switch]$KeepWorkRoot
)

$ErrorActionPreference = 'Stop'
$Launcher = (Resolve-Path -LiteralPath $Launcher).ProviderPath
# What the real launcher writes into the ledger and its status: read from
# the script, so the checks follow a version bump.
$LauncherVersionUnderTest = if ((Get-Content -LiteralPath $Launcher -TotalCount 200) -join "`n" -match "\`$LauncherVersion = '([^']+)'") { $Matches[1] } else { '?' }
$FleetRoot = (Resolve-Path -LiteralPath $FleetRoot).ProviderPath
$User = 'operator'
# Quotes, an ampersand, angle brackets, a plus and a non-ASCII letter: all
# that could go wrong between the seed file, JSON, DevTools and a form post.
$Password = 'Mach2&Pass"w0rd <+' + [char]0x17E + '>'
$Base = "http://127.0.0.1:$Port"
$Dashboard = "$Base/deltav/dashboard:viewer/@/Nyrany/TEST/Dashboards/Graphs"
$Utf8 = New-Object Text.UTF8Encoding($false)

$script:Results = New-Object System.Collections.Generic.List[object]
$script:LedgerRuns = @{}

function Test-Check {
    param([Parameter(Mandatory)][string]$Scenario, [Parameter(Mandatory)][string]$Name, [bool]$Pass, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Scenario = $Scenario; Check = $Name; Pass = $Pass; Detail = $Detail })
    $suffix = if ($Detail) { "  ($Detail)" } else { '' }
    Write-Host ("  [{0}] {1}{2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $suffix) -ForegroundColor $(if ($Pass) { 'Green' } else { 'Red' })
}

function Invoke-Http {
    param([string]$PathAndQuery)
    $wc = New-Object Net.WebClient
    $wc.Proxy = $null
    try { return $wc.DownloadString("$Base$PathAndQuery") } finally { $wc.Dispose() }
}

function Read-SharedFile {
    param([string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try { return (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
}

function Get-FixtureEvents {
    param([DateTime]$SinceUtc = [DateTime]::MinValue, [string]$Name)
    if (-not (Test-Path -LiteralPath $script:EventsFile)) { return @() }
    $out = foreach ($line in ((Read-SharedFile $script:EventsFile) -split "`n")) {
        if (-not $line.Trim()) { continue }
        $e = ConvertFrom-Json -InputObject $line
        if ([DateTime]::Parse($e.t, $null, [Globalization.DateTimeStyles]::RoundtripKind) -lt $SinceUtc) { continue }
        if ($Name -and $e.name -ne $Name) { continue }
        $e
    }
    return @($out)
}

function Wait-Until {
    param([Parameter(Mandatory)][scriptblock]$Condition, [int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try { if (& $Condition) { return $true } } catch {}
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Get-ProfileEdge {
    param([string]$ProfileDir)
    $pattern = [regex]::Escape($ProfileDir) + '(?:"|\\?\s|\\?$)'
    return @(Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" | Where-Object { $_.CommandLine -match $pattern })
}

function New-Run {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Settings,
        [string]$Instance = 'S1',
        [switch]$LegacyArray,
        [string]$Seed
    )
    $dir = Join-Path $WorkRoot $Name
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    $idir = Join-Path $dir $Instance
    $wd = Join-Path $dir 'wd'
    New-Item -ItemType Directory -Path $idir, $wd -Force | Out-Null
    Copy-Item -LiteralPath $Launcher -Destination (Join-Path $dir 'Mach2LauncherNG.ps1')

    $cfg = [ordered]@{}
    foreach ($k in $Settings.Keys) { $cfg[$k] = $Settings[$k] }
    if (-not $cfg.Contains('DisplayURL')) { $cfg['DisplayURL'] = $Dashboard }
    if (-not $cfg.Contains('LoginURL')) { $cfg['LoginURL'] = "$Base/prelogin?clear=true" }
    if (-not $cfg.Contains('UserName')) { $cfg['UserName'] = $User }
    $cfg['ProfileDir'] = Join-Path $dir 'Profile'
    $cfg['WatchdogPath'] = $wd
    $cfg['DisplayWaitSeconds'] = '0'
    foreach ($d in @(@('HealthCheckSeconds', '2'), @('DebugLogging', '1'), @('BadScreenSeconds', '4'), @('OffTargetSeconds', '3'),
            @('RebootAfterMinutes', '10'), @('RestartConfirmSeconds', '15'), @('EpisodeGraceSeconds', '0'))) {
        if (-not $cfg.Contains($d[0])) { $cfg[$d[0]] = $d[1] }
    }
    $obj = if ($LegacyArray) { , @([pscustomobject]$cfg) } else { [pscustomobject]$cfg }
    $configPath = Join-Path $idir "$env:COMPUTERNAME.json"
    [IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject $obj -Depth 5), $Utf8)
    if ($PSBoundParameters.ContainsKey('Seed')) { [IO.File]::WriteAllText((Join-Path $idir 'password.seed'), $Seed, $Utf8) }

    return [pscustomobject]@{
        Name = $Name; Instance = $Instance; Dir = $dir; InstanceDir = $idir; Config = $configPath; Profile = (Join-Path $dir 'Profile')
        Wd = $wd; Ledger = (Join-Path $wd 'mwst_events.csv'); WdLog = (Join-Path $wd 'mwst.log')
        Cred = (Join-Path $idir "$env:COMPUTERNAME.cred"); Process = $null; Stderr = (Join-Path $dir 'stderr.txt')
    }
}

function Start-Run {
    param($Run)
    $Run.Process = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardError $Run.Stderr -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Run.Dir 'Mach2LauncherNG.ps1')),
        '-Instance', $Run.Instance, '-Headless', '-SimulateRestart', '-ExitAfterSeconds', '900')
    # Windows PowerShell only reports ExitCode for a process whose handle was
    # opened while it ran.
    $null = $Run.Process.Handle
}

function Stop-Run {
    param($Run, [string]$Scenario)
    if (-not $Run.Process) { return }
    if (-not $Run.Process.HasExited) {
        New-Item -ItemType File -Path (Join-Path $Run.InstanceDir 'kill.txt') -Force | Out-Null
        if (-not $Run.Process.WaitForExit(30000)) {
            Test-Check $Scenario 'launcher stops on kill.txt' $false 'had to be killed'
            Stop-Process -Id $Run.Process.Id -Force
        }
    }
    foreach ($p in Get-ProfileEdge $Run.Profile) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-LauncherStatus {
    param($Run)
    $p = Join-Path $Run.InstanceDir "Status\$($Run.Instance).status.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($p))) } catch { return $null }
}

function Wait-State {
    param($Run, [string[]]$State, [int]$TimeoutSec = 60)
    return (Wait-Until -TimeoutSec $TimeoutSec -Condition { $st = Get-LauncherStatus $Run; $st -and $st.State -in $State })
}

function Get-LogText {
    param($Run)
    $files = @(Get-ChildItem -LiteralPath $Run.InstanceDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.log', '.lo_') })
    return (($files | ForEach-Object { Read-SharedFile $_.FullName }) -join "`n")
}

function Get-Ledger {
    # Complete lines only, as the collector reads it.
    param($Run, [string]$Type)
    if (-not (Test-Path -LiteralPath $Run.Ledger)) { return @() }
    $text = Read-SharedFile $Run.Ledger
    $cut = $text.LastIndexOf("`n")
    if ($cut -lt 0) { return @() }
    $rows = @($text.Substring(0, $cut + 1).TrimStart([char]0xFEFF) | ConvertFrom-Csv)
    if ($Type) { $rows = @($rows | Where-Object { $_.EventType -eq $Type }) }
    return $rows
}

function Get-ErrorLines {
    param([string]$Log)
    return (([regex]::Matches($Log, '<!\[LOG\[([^\]]*)\]LOG\]!>[^>]*type="3"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 3) -join ' | ')
}

function Test-NoPasswordLeak {
    param($Run, [string]$Scenario)
    $files = @(Get-ChildItem -LiteralPath $Run.Dir -Recurse -File | Where-Object { $_.FullName -notlike "$($Run.Profile)*" })
    $leaks = @($files | Where-Object { (Read-SharedFile $_.FullName).Contains($Password) } | ForEach-Object { $_.Name })
    Test-Check $Scenario 'password appears in no launcher or watchdog file' ($leaks.Count -eq 0) ($leaks -join ', ')
}

function Send-Control {
    param($Run, [string]$File)
    New-Item -ItemType File -Path (Join-Path $Run.InstanceDir $File) -Force | Out-Null
}

# ---------------------------------------------------------------------------
# The collector's own code, for turning ledger rows into report rows
# ---------------------------------------------------------------------------
function Import-CollectorFunctions {
    $path = Join-Path $FleetRoot 'Collect-MWSTFleet.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
    $wanted = 'ConvertFrom-UtcIso', 'Format-UtcIso', 'Format-LocalIso', 'Format-Number', 'New-FleetRow', 'ConvertFrom-LedgerRow',
    'ConvertFrom-LedgerWinEvent', 'ConvertFrom-RebootEvent', 'Test-TrustedAgentVersion'
    $text = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true) | ForEach-Object { $_.Extent.Text })
    $text += @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -in @('$Columns', '$CategoryByType') }, $false) | ForEach-Object { $_.Extent.Text })
    $text += '$Inv = [Globalization.CultureInfo]::InvariantCulture; $TrustedFromAgentVersion = ''6.1''; $ColumnSet = @{}; foreach ($c in $Columns) { $ColumnSet[$c] = $true }'
    return (($text + ". '$((Join-Path $FleetRoot 'Lib\M2.LauncherNG.ps1') -replace "'", "''")'") -join "`n")
}
$CollectorCode = Import-CollectorFunctions

# ---------------------------------------------------------------------------
# Unit checks - the launcher's helpers, loaded without running it
# ---------------------------------------------------------------------------
function Invoke-UnitTests {
    $sc = 'Unit'
    Write-Host "`n== $sc" -ForegroundColor Cyan

    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$errors)
    Test-Check $sc 'launcher parses' ($errors.Count -eq 0) (($errors | ForEach-Object { $_.Message }) -join '; ')
    Test-Check $sc "version is ver 1.02NG" ((Get-Content -LiteralPath $Launcher -TotalCount 200) -join "`n" -match "\`$LauncherVersion = '1.02NG'")

    $wanted = 'Get-ConfigValue', 'ConvertTo-Flag', 'ConvertTo-Number', 'ConvertTo-StringList', 'ConvertTo-TimesOfDay', 'ConvertTo-WebUri',
    'Read-LauncherConfig', 'Test-IsTargetUrl', 'ConvertTo-ArgumentString', 'Test-DailyDue', 'Get-ReadingKind', 'Measure-BitmapWhite',
    'Get-LoopGuardDecision', 'ConvertTo-CsvField', 'Format-Utc', 'Test-FirstMach2Screen'
    foreach ($d in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)) { . ([scriptblock]::Create($d.Extent.Text)) }
    $phrases = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$DefaultErrorPhrases' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($phrases.Extent.Text))
    $Here = Join-Path $WorkRoot 'unit\S1'
    $ScriptDir = Join-Path $WorkRoot 'unit'
    $Instance = 'S1'
    $ComputerName = $env:COMPUTERNAME.ToUpperInvariant()
    $Invariant = [Globalization.CultureInfo]::InvariantCulture
    $script:NativeReady = $false
    Add-Type -AssemblyName System.Web
    Add-Type -AssemblyName System.Drawing
    New-Item -ItemType Directory -Path $Here -Force | Out-Null

    # The pilot kiosk's config (LASER020), exactly as Mach2Launcher 2.0.0.13 reads it.
    $legacy = @'
[
 {
   "JsonVer": "1.0.0.16",
   "LoginURL": "http://SHCZ5PLC02:302/prelogin?clear=true",
   "DisplayURL": "http://shcz5plc02:302/deltav/dashboard:viewer/@/Nyrany/LASER020/Dashboards/Graphs",
   "ZoomPercent": "100",
   "ZoomDelay": "500",
   "UsePriScreen": "1",
   "ScreenSelect": "0",
   "KioskMode": "1",
   "ElementTimeout": "30",
   "ForcedRefreshTime": "12:00",
   "EnableRefresh": "1",
   "BrowserRefreshDelay": "30",
   "UpdateEdgeDriver": "1",
   "EdgeDriverSharePath": "\\\\shghmgt09\\MSEdgeDriver",
   "LogPath": "",
   "RemoteLogPath": "\\\\shghmgt09\\Mach2Launcher\\Logs",
   "LogName": "LASER020_Mach2Launcher.log",
   "LogDelay": "0",
   "TempCleanup": "1",
   "KillEdgeDriver": "1",
   "StartupDelay": "0",
   "DisableStartup": "0",
   "DebugLogging": "0",
   "ScheduledRestartEnabled": "0",
   "ScheduledRestartTime": "06:00",
   "RestartDelay": "30",
   "EdgeDriverSelfUpdate": "0",
   "EdgeDriverDownloadPath": "$env:TEMP",
   "EdgeDriverBackupLimit": "5",
   "UsernameFieldName": "j_username",
   "UserName": "operator",
   "PasswordFieldName": "j_password",
   "Password": "not-a-real-password",
   "LoginButtonID": "login-submit",
   "LoginDelay": "1000"
 }
]
'@
    $lp = Join-Path $Here 'legacy.json'
    [IO.File]::WriteAllText($lp, $legacy)
    $c = Read-LauncherConfig -Path $lp
    Test-Check $sc 'old config: dashboard and login address' ($c.DisplayUrl -eq 'http://shcz5plc02:302/deltav/dashboard:viewer/@/Nyrany/LASER020/Dashboards/Graphs' -and $c.LoginUrl -eq 'http://shcz5plc02:302/prelogin?clear=true') "$($c.DisplayUrl) | $($c.LoginUrl)"
    Test-Check $sc 'old config: the password only goes to the station' (@($c.LoginHosts).Count -eq 1 -and $c.LoginHosts[0] -eq 'shcz5plc02') (@($c.LoginHosts) -join ',')
    Test-Check $sc 'old config: Niagara field names and user' ($c.UserField -eq 'j_username' -and $c.PasswordField -eq 'j_password' -and $c.SubmitButtonId -eq 'login-submit' -and $c.UserName -eq 'operator' -and $c.LegacyPassword -eq 'not-a-real-password')
    Test-Check $sc 'old config: refresh every 30 min and daily at 12:00' ($c.RefreshMinutes -eq 30 -and @($c.RefreshTimes).Count -eq 1 -and $c.RefreshTimes[0] -eq [TimeSpan]'12:00')
    Test-Check $sc 'old config: primary screen, full screen, no zoom, no restart' ($c.UsePrimaryScreen -and $c.FullScreenWindow -and $c.ZoomPercent -eq 100 -and $null -eq $c.RestartTime)
    Test-Check $sc 'old config: same central log folder' ($c.RemoteLogDir -eq '\\shghmgt09\Mach2Launcher\Logs' -and $c.LogName -eq 'LASER020_Mach2Launcher.log')
    Test-Check $sc 'S1 is the watchdog by default, with the watchdog''s thresholds' ($c.Watchdog -and $c.WhiteHighPercent -eq 85 -and $c.WhiteLowPercent -eq 10 -and $c.WhitePixelLevel -eq 235 -and $c.RebootAfterMinutes -eq 5 -and $c.OutageRebootMinutes -eq 30)
    Test-Check $sc 'old config: read without complaints' ($c.Problems.Count -eq 0) ($c.Problems -join '; ')
    $Instance = 'S2'
    Test-Check $sc 'S2 is not the watchdog by default' (-not (Read-LauncherConfig -Path $lp).Watchdog)
    # Power BI or a web page on S1, the Mach2 dashboard on S2: S2 is the
    # kiosk's first (only) Mach2 screen, so it is the watchdog.
    $ScriptDir = Join-Path $WorkRoot 'unit-mixed'
    New-Item -ItemType Directory -Path (Join-Path $ScriptDir 'S2') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $ScriptDir "S2\$ComputerName.json"), '{}')
    Test-Check $sc 'S2 is the watchdog when it is the only Mach2 screen (PBI or a web page on S1)' ((Read-LauncherConfig -Path $lp).Watchdog)
    New-Item -ItemType Directory -Path (Join-Path $ScriptDir 'S1') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $ScriptDir "S1\$ComputerName.json"), '{}')
    Test-Check $sc '...but not once there is a Mach2 S1' (-not (Read-LauncherConfig -Path $lp).Watchdog)
    $ScriptDir = Join-Path $WorkRoot 'unit'
    $Instance = 'S1'

    $bad = Join-Path $Here 'bad.json'
    [IO.File]::WriteAllText($bad, '{ "DisplayURL": "not a url" }')
    $threw = $false
    try { $null = Read-LauncherConfig -Path $bad } catch { $threw = $_.Exception.Message -like '*not a web address*' }
    Test-Check $sc 'a bad DisplayURL is refused' $threw
    [IO.File]::WriteAllText($bad, '{ "DisplayURL": "http://x.test/d", "LoginURL": "nope", "RefreshTimes": "7:5x, 14:30", "WhiteLowPercent": "90", "UsernameFieldName": "a\"b" }')
    $c = Read-LauncherConfig -Path $bad
    Test-Check $sc 'bad values are reported and replaced' ($c.Problems.Count -eq 4 -and -not $c.LoginUrl -and @($c.RefreshTimes).Count -eq 1 -and $c.WhiteLowPercent -eq 10 -and $c.UserField -eq 'j_username') ($c.Problems -join ' | ')

    # Test-IsTargetUrl
    $t = 'http://shcz5plc02:302/deltav/dashboard:viewer/@/Nyrany/LASER020/Dashboards/Graphs'
    Test-Check $sc 'the dashboard, host in capitals = on target' (Test-IsTargetUrl -Current 'http://SHCZ5PLC02:302/deltav/dashboard:viewer/@/Nyrany/LASER020/Dashboards/Graphs' -Target $t)
    Test-Check $sc 'the dashboard over HTTPS, or with @ escaped, or a slash = on target' ((Test-IsTargetUrl -Current 'https://shcz5plc02/deltav/dashboard:viewer/@/Nyrany/LASER020/Dashboards/Graphs' -Target $t) -and (Test-IsTargetUrl -Current 'http://shcz5plc02:302/deltav/dashboard:viewer/%40/Nyrany/LASER020/Dashboards/Graphs/' -Target $t))
    Test-Check $sc 'home page, another dashboard, the login = off target' (-not (Test-IsTargetUrl -Current 'http://shcz5plc02:302/deltav/home' -Target $t) -and -not (Test-IsTargetUrl -Current 'http://shcz5plc02:302/deltav/dashboard:viewer/@/Nyrany/LASER021/Dashboards/Graphs' -Target $t) -and -not (Test-IsTargetUrl -Current 'http://shcz5plc02:302/login' -Target $t))
    Test-Check $sc 'another station = off target' (-not (Test-IsTargetUrl -Current 'http://shcz5plc03:302/deltav/dashboard:viewer/@/Nyrany/LASER020/Dashboards/Graphs' -Target $t))
    Test-Check $sc 'query in the configured address must match' ((Test-IsTargetUrl -Current 'http://x.test/d?a=1&b=2' -Target 'http://x.test/d?a=1') -and -not (Test-IsTargetUrl -Current 'http://x.test/d?a=2' -Target 'http://x.test/d?a=1'))

    # White readings
    $cfg = [pscustomobject]@{ WhiteHighPercent = 85; WhiteLowPercent = 10 }
    Test-Check $sc 'readings: 90 white, 5 dark, 72 (the pilot) normal, none unknown' ((Get-ReadingKind 90 $cfg) -eq 'WHITE' -and (Get-ReadingKind 85 $cfg) -eq 'WHITE' -and (Get-ReadingKind 5 $cfg) -eq 'LOWWHITE' -and (Get-ReadingKind 72.3 $cfg) -eq '' -and (Get-ReadingKind $null $cfg) -eq '')
    $bmp = New-Object Drawing.Bitmap 200, 100
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.Clear([Drawing.Color]::White)
    $white = Measure-BitmapWhite -Bitmap $bmp -Step 2 -Level 235
    $g.FillRectangle([Drawing.Brushes]::Black, 0, 0, 100, 100)
    $half = Measure-BitmapWhite -Bitmap $bmp -Step 2 -Level 235
    $g.Clear([Drawing.Color]::FromArgb(240, 240, 230))
    $offWhite = Measure-BitmapWhite -Bitmap $bmp -Step 2 -Level 235
    $g.Dispose(); $bmp.Dispose()
    Test-Check $sc 'pixel count: white 100%, half 50%, not quite white 0%' ($white -eq 100 -and [math]::Abs($half - 50) -lt 1 -and $offWhite -eq 0) "$white / $half / $offWhite"

    # Loop guard decisions
    $gc = [pscustomobject]@{ LoopGuardMaxRestarts = 2; LoopGuardWindowMinutes = 60; LoopGuardRetryMinutes = 120 }
    $now = [DateTime]::UtcNow
    $script:LoopState = [pscustomobject]@{ Restarts = @(); HoldReported = $false }
    $d0 = Get-LoopGuardDecision -NowUtc $now -Config $gc
    $script:LoopState.Restarts = @($now.AddMinutes(-10))
    $d1 = Get-LoopGuardDecision -NowUtc $now -Config $gc
    $script:LoopState.Restarts = @($now.AddMinutes(-20), $now.AddMinutes(-10))
    $d2 = Get-LoopGuardDecision -NowUtc $now -Config $gc
    $script:LoopState.Restarts = @($now.AddMinutes(-200), $now.AddMinutes(-130))
    $d3 = Get-LoopGuardDecision -NowUtc $now -Config $gc
    $script:LoopState.Restarts = @($now.AddMinutes(-90))
    $d4 = Get-LoopGuardDecision -NowUtc $now -Config $gc
    Test-Check $sc 'loop guard: allow, allow, hold, retry after 2 h, and a lone old restart is forgotten' ($d0.Action -eq 'Allow' -and $d1.Action -eq 'Allow' -and $d2.Action -eq 'Hold' -and $d3.Action -eq 'Retry' -and $d4.Action -eq 'Allow' -and @($d4.Restarts).Count -eq 0) ("{0} {1} {2} {3} {4}" -f $d0.Action, $d1.Action, $d2.Action, $d3.Action, $d4.Action)

    # Argument quoting, daily times
    $s = ConvertTo-ArgumentString -Arguments @('--user-data-dir="C:\A B\P"', '--app="http://x.test/d:v/@/a"', '--kiosk', '--x=C:\no space')
    Test-Check $sc 'argument quoting' ($s -eq '--user-data-dir="C:\A B\P" --app="http://x.test/d:v/@/a" --kiosk --x="C:\no space"') $s
    $done = @{}
    $at = (Get-Date).TimeOfDay.Add([TimeSpan]::FromMinutes(-2))
    if ($at -lt [TimeSpan]::Zero) { $at = [TimeSpan]::Zero }
    Test-Check $sc 'daily time fires once' ((Test-DailyDue -At $at -Tag 't' -Done $done) -and -not (Test-DailyDue -At $at -Tag 't' -Done $done))

    # What the collector makes of the new launcher's rows
    . ([scriptblock]::Create($CollectorCode))
    Test-Check $sc 'collector trusts 1.00NG data (and still 7.0, not legacy)' ((Test-TrustedAgentVersion '1.00NG') -and (Test-TrustedAgentVersion '7.0') -and -not (Test-TrustedAgentVersion 'legacy') -and -not (Test-TrustedAgentVersion '5.0'))
    $row = [pscustomobject]@{ EventId = [guid]::NewGuid().ToString(); EventTimeUtc = '2026-09-18T08:00:00Z'; EventType = 'RESTART_TRIGGERED'; Severity = 'CRITICAL'; Outcome = 'REBOOT'
        WhitePercent = ''; StreakChecks = '40'; DurationSeconds = '300'; AgentVersion = '1.00NG'; BootTimeUtc = '2026-09-18T00:02:44Z'; Detail = 'BROWSER: Edge will not start for 5 min. EpisodeId=; Instance=S1; LoopGuard=1/2' }
    $f = ConvertFrom-LedgerRow -Row $row -HostName 'KIOSK' -ScanId 's' -CollectedUtc '2026-09-18T08:05:00Z'
    Test-Check $sc 'collector: a BROWSER restart is a watchdog restart (WATCHDOG_BROWSER)' ($f -and $f.RebootTrigger -eq 'WATCHDOG_BROWSER' -and $f.AgentVersion -eq '1.00NG' -and $f.EventCategory -eq 'REBOOT') $(if ($f) { $f.RebootTrigger })
    $payload = ConvertTo-Json -Compress -InputObject ([pscustomobject]@{ Id = 1074; Provider = 'User32'; RecordId = 4711
            Props = @('C:\Windows\system32\shutdown.exe (KIOSK)', 'KIOSK', 'Other (Planned)', '0x80000000', 'restart', 'MWST-WATCHDOG BROWSER id=1a2b3c4d - Mach2 Launcher 1.00NG: Edge will not start', 'SHAPE\KIOSK'); Msg = '' })
    $we = [pscustomobject]@{ EventId = 'EVT-KIOSK-4711-20260918080000'; EventTimeUtc = '2026-09-18T08:00:00Z'; EventType = 'WINEVENT'; Detail = $payload }
    $f = ConvertFrom-LedgerRow -Row $we -HostName 'KIOSK' -ScanId 's' -CollectedUtc 'x'
    Test-Check $sc 'collector: its 1074 comment is read as the watchdog''s, with the row id' ($f -and $f.EventType -eq 'REBOOT_SCRIPT' -and $f.RebootTrigger -eq 'WATCHDOG_BROWSER' -and $f.Detail -like 'id=1a2b3c4d;*') $(if ($f) { "$($f.EventType) $($f.RebootTrigger)" })
    $payload = $payload.Replace('MWST-WATCHDOG BROWSER id=1a2b3c4d - Mach2 Launcher 1.00NG: Edge will not start', 'Mach2 Launcher 1.00NG: scheduled daily restart [MACH2-LAUNCHER-NG]')
    $f = ConvertFrom-LedgerRow -Row ([pscustomobject]@{ EventId = 'x'; EventTimeUtc = '2026-09-18T08:00:00Z'; EventType = 'WINEVENT'; Detail = $payload }) -HostName 'KIOSK' -ScanId 's' -CollectedUtc 'x'
    Test-Check $sc 'collector: a restart.txt or daily restart is not the watchdog''s (EXTERNAL)' ($f -and $f.EventType -eq 'REBOOT_EXTERNAL') $(if ($f) { $f.EventType })
}

# ---------------------------------------------------------------------------
# End-to-end scenarios
# ---------------------------------------------------------------------------
function Invoke-MainScenario {
    $sc = 'Main'
    Write-Host "`n== $sc (old-format config, seed file, the watchdog's files, everything the station does)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    New-Item -ItemType Directory -Path (Join-Path $WorkRoot 'central-logs') -Force | Out-Null

    $run = New-Run -Name $sc -LegacyArray -Seed $Password -Settings ([ordered]@{
            JsonVer = '1.0.0.16'; LoginURL = "$Base/prelogin?clear=true"; DisplayURL = $Dashboard; ZoomPercent = '100'; ZoomDelay = '500'
            UsePriScreen = '1'; ScreenSelect = '0'; KioskMode = '1'; ElementTimeout = '30'; ForcedRefreshTime = '12:00'; EnableRefresh = '1'
            BrowserRefreshDelay = '30'; UpdateEdgeDriver = '1'; EdgeDriverSharePath = '\\nowhere\MSEdgeDriver'; LogPath = ''
            RemoteLogPath = (Join-Path $WorkRoot 'central-logs'); LogName = 'TEST_Mach2LauncherNG.log'; LogDelay = '0'; TempCleanup = '1'
            KillEdgeDriver = '1'; StartupDelay = '0'; DisableStartup = '0'; ScheduledRestartEnabled = '0'; ScheduledRestartTime = '06:00'
            RestartDelay = '30'; EdgeDriverSelfUpdate = '0'; UsernameFieldName = 'j_username'; UserName = $User; PasswordFieldName = 'j_password'
            Password = ''; LoginButtonID = 'login-submit'; LoginDelay = '1000'
        })

    # A stand-in for the old watchdog, which the launcher must stop.
    $oldDir = Join-Path $run.Dir 'old'
    New-Item -ItemType Directory -Path $oldDir -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $oldDir 'mwstv4.ps1'), 'Start-Sleep -Seconds 600')
    $old = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $oldDir 'mwstv4.ps1')))

    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        # 1. sign in (two steps), open the dashboard
        Test-Check $sc 'reaches SHOWING after signing in' (Wait-State $run 'SHOWING' 90) ((Get-LauncherStatus $run).State)
        $ev = Get-FixtureEvents -SinceUtc $t0
        $users = @($ev | Where-Object name -eq 'user')
        $pw = @($ev | Where-Object name -eq 'password')
        Test-Check $sc 'typed the user name on the first page' ($users.Count -eq 1 -and $users[0].user -eq $User) (($users | ForEach-Object user) -join ',')
        Test-Check $sc 'typed the right password on the second, once' ($pw.Count -eq 1 -and $pw[0].ok -and $pw[0].user -eq $User) ("{0} attempt(s), length {1}" -f $pw.Count, ($pw | ForEach-Object length))
        Test-Check $sc 'password.seed consumed, encrypted file written' (-not (Test-Path -LiteralPath (Join-Path $run.InstanceDir 'password.seed')) -and (Test-Path -LiteralPath $run.Cred))
        Test-Check $sc 'the old watchdog was stopped' (Wait-Until -TimeoutSec 20 -Condition { $old.HasExited }) ''
        Test-Check $sc '...and the log says so' ((Get-LogText $run) -match 'Stopped the old MWST watchdog')
        $st = Get-LauncherStatus $run
        Test-Check $sc 'status: ver 1.02NG, the watchdog, one sign-in, one Edge' ($st.LauncherVersion -eq '1.02NG' -and $st.Watchdog -and $st.SignIns -eq 1 -and $st.BrowserStarts -eq 1) ("v{0} wd={1} signins={2} starts={3}" -f $st.LauncherVersion, $st.Watchdog, $st.SignIns, $st.BrowserStarts)
        Test-Check $sc 'status: the dashboard page reads normal (between 10% and 85% white)' ($null -ne $st.PageWhitePercent -and $st.PageWhitePercent -gt 10 -and $st.PageWhitePercent -lt 85) ([string]$st.PageWhitePercent)
        Test-Check $sc 'central log written' (Test-Path -LiteralPath (Join-Path $WorkRoot 'central-logs\TEST_Mach2LauncherNG.log'))

        # 2. the watchdog's files, in the watchdog's format
        $header = (Read-SharedFile $run.Ledger).TrimStart([char]0xFEFF).Split("`n")[0].Trim()
        Test-Check $sc "ledger has the watchdog's header" ($header -eq 'EventId,EventTimeUtc,EventTimeLocal,Host,EventType,Severity,Outcome,WhitePercent,StreakChecks,DurationSeconds,AgentVersion,BootTimeUtc,Detail') $header
        $start = @(Get-Ledger $run 'AGENT_START')
        Test-Check $sc 'AGENT_START by 1.02NG, with Console= and Window=' ($start.Count -eq 1 -and $start[0].AgentVersion -eq '1.02NG' -and $start[0].Detail -match 'Console=\S+' -and $start[0].Detail -match 'Window=hidden' -and $start[0].Detail -match 'Instance=S1' -and $start[0].BootTimeUtc) $(if ($start) { $start[0].Detail })
        Test-Check $sc 'mwst.log written (the collector''s liveness check)' ((Read-SharedFile $run.WdLog) -match 'started as the watchdog')
        Test-Check $sc 'message inbox created' (Test-Path -LiteralPath (Join-Path $run.Wd 'mwst_inbox'))

        # 3. messages from the Kiosk Fleet Manager
        $inbox = Join-Path $run.Wd 'mwst_inbox'
        $id = [guid]::NewGuid().ToString()
        $msg = ConvertTo-Json -Compress ([pscustomobject]@{ Id = $id; Title = 'Test'; Text = 'Hello from the test'; Seconds = 3; From = 'test'; ExpiresUtc = [DateTime]::UtcNow.AddMinutes(5).ToString('o') })
        [IO.File]::WriteAllText((Join-Path $inbox "msg_1_$($id.Substring(0, 8)).json"), $msg, $Utf8)
        $expiredId = [guid]::NewGuid().ToString()
        $msg = ConvertTo-Json -Compress ([pscustomobject]@{ Id = $expiredId; Text = 'too late'; Seconds = 3; ExpiresUtc = [DateTime]::UtcNow.AddMinutes(-5).ToString('o') })
        [IO.File]::WriteAllText((Join-Path $inbox "msg_0_$($expiredId.Substring(0, 8)).json"), $msg, $Utf8)
        $ok = Wait-Until -TimeoutSec 30 -Condition { @(Get-Ledger $run 'MESSAGE_CLOSED' | Where-Object { $_.Detail -like "MessageId=$id*" }).Count -eq 1 }
        $closed = @(Get-Ledger $run 'MESSAGE_CLOSED' | Where-Object { $_.Detail -like "MessageId=$id*" })
        Test-Check $sc 'a message is shown and closed by its countdown (MESSAGE_SHOWN, MESSAGE_CLOSED TIMEOUT)' ($ok -and @(Get-Ledger $run 'MESSAGE_SHOWN' | Where-Object { $_.Detail -like "MessageId=$id*" }).Count -eq 1 -and $closed[0].Outcome -eq 'TIMEOUT') $(if ($closed) { $closed[0].Outcome })
        Test-Check $sc 'an expired message is dropped with MESSAGE_EXPIRED' (@(Get-Ledger $run 'MESSAGE_EXPIRED' | Where-Object { $_.Detail -like "MessageId=$expiredId*" }).Count -eq 1 -and @(Get-ChildItem $inbox -Filter 'msg_*').Count -eq 0)

        # 4. snapshot.txt
        $snapBase = Join-Path $run.InstanceDir "Status\$($run.Instance)"
        Send-Control $run 'snapshot.txt'
        $ok = Wait-Until -TimeoutSec 30 -Condition { -not (Test-Path -LiteralPath (Join-Path $run.InstanceDir 'snapshot.txt')) -and (Test-Path -LiteralPath "$snapBase.snapshot.json") }
        $snap = if ($ok) { ConvertFrom-Json -InputObject ([IO.File]::ReadAllText("$snapBase.snapshot.json")) } else { $null }
        $isPng = $false
        if (Test-Path -LiteralPath "$snapBase.png") { $b = [IO.File]::ReadAllBytes("$snapBase.png"); $isPng = $b.Length -gt 1000 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 }
        Test-Check $sc 'snapshot.txt: a PNG and what the page shows' ($snap -and -not $snap.Error -and $isPng -and $snap.Url -like '*/Dashboards/Graphs' -and $snap.State -eq 'SHOWING') $(if ($snap) { "$($snap.State) $($snap.Url) $($snap.Error)" })

        # 5. the station drops the session: signs in again in the same Edge
        $t1 = [DateTime]::UtcNow
        $null = Invoke-Http '/control?logout=1'
        $ok = Wait-Until -TimeoutSec 60 -Condition { @(Get-FixtureEvents -SinceUtc $t1 -Name 'password' | Where-Object { $_.ok }).Count -eq 1 -and (Get-LauncherStatus $run).State -eq 'SHOWING' }
        Test-Check $sc 'session dropped by the station: signed in again, dashboard back' $ok
        $st = Get-LauncherStatus $run
        Test-Check $sc '...without a new Edge (the old launcher relaunched itself here)' ($st.BrowserStarts -eq 1 -and $st.SignIns -eq 2) ("starts={0} signins={1}" -f $st.BrowserStarts, $st.SignIns)

        # 6. after sign-in the station opens its home page
        $t2 = [DateTime]::UtcNow
        $null = Invoke-Http '/control?home=1&logout=1'
        $ok = Wait-Until -TimeoutSec 60 -Condition { @(Get-FixtureEvents -SinceUtc $t2 -Name 'home').Count -ge 1 -and @(Get-FixtureEvents -SinceUtc $t2 -Name 'dashboard').Count -ge 1 -and (Get-LauncherStatus $run).State -eq 'SHOWING' }
        Test-Check $sc 'station opens /deltav/home after sign-in: straight on to the dashboard' ($ok -and (Get-LogText $run) -match 'signed in; the station opened')
        $null = Invoke-Http '/control?home=0'

        # 7. the dashboard goes white: WHITE episode, reloaded after BadScreenSeconds
        $t3 = [DateTime]::UtcNow
        $null = Invoke-Http '/control?white=1'
        Send-Control $run 'refresh.txt'
        $ok = Wait-Until -TimeoutSec 40 -Condition { @(Get-FixtureEvents -SinceUtc $t3 -Name 'dashboard' | Where-Object { $_.white }).Count -ge 2 }
        Test-Check $sc 'a white dashboard is reloaded on its own' $ok ("{0} load(s)" -f @(Get-FixtureEvents -SinceUtc $t3 -Name 'dashboard').Count)
        $ws = @(Get-Ledger $run 'WHITE_EPISODE_START')
        Test-Check $sc '...and WHITE_EPISODE_START is in the ledger, with the reading' ($ws.Count -ge 1 -and [double]$ws[-1].WhitePercent -ge 85) $(if ($ws) { $ws[-1].WhitePercent })
        Test-Check $sc '...status RECOVERING or LOADING meanwhile' ((Get-LauncherStatus $run).State -in @('RECOVERING', 'LOADING')) ((Get-LauncherStatus $run).State)
        $null = Invoke-Http '/control?white=0'
        Send-Control $run 'refresh.txt'
        Test-Check $sc 'back to SHOWING once it draws again' (Wait-State $run 'SHOWING' 40)
        $we = @(Get-Ledger $run 'WHITE_EPISODE_END')
        Test-Check $sc '...and the episode is closed RECOVERED' ($we.Count -ge 1 -and $we[-1].Outcome -eq 'RECOVERED') $(if ($we) { $we[-1].Outcome })

        # 8. the dashboard goes dark
        $null = Invoke-Http '/control?dark=1'
        Send-Control $run 'refresh.txt'
        $ok = Wait-Until -TimeoutSec 30 -Condition { @(Get-Ledger $run 'LOWWHITE_EPISODE_START').Count -ge 1 }
        Test-Check $sc 'a dark dashboard is a LOWWHITE episode' $ok
        $null = Invoke-Http '/control?dark=0'
        Send-Control $run 'refresh.txt'
        Test-Check $sc 'back to SHOWING, episode closed' ((Wait-State $run 'SHOWING' 40) -and @(Get-Ledger $run 'LOWWHITE_EPISODE_END').Count -ge 1)

        # 9. the station answers with an error
        $t4 = [DateTime]::UtcNow
        $null = Invoke-Http '/control?error=1'
        Send-Control $run 'refresh.txt'
        $ok = Wait-Until -TimeoutSec 40 -Condition { @(Get-FixtureEvents -SinceUtc $t4 -Name 'dashboard' | Where-Object { $_.error }).Count -ge 2 }
        Test-Check $sc 'a station error page is reloaded after three checks' $ok
        Test-Check $sc '...status RECOVERING' ((Get-LauncherStatus $run).State -eq 'RECOVERING') ((Get-LauncherStatus $run).State)
        $null = Invoke-Http '/control?error=0'
        Send-Control $run 'refresh.txt'
        Test-Check $sc 'back to SHOWING once the station is fine' (Wait-State $run 'SHOWING' 60)

        # 10. a second window (opened through DevTools: Edge's popup blocker
        # stops a page opening one by itself). It is not in the InPrivate
        # session, so by the time it is closed the station may have sent it
        # to /login.
        $port = [int](@(Get-Content -LiteralPath (Join-Path $run.Profile 'DevToolsActivePort'))[0])
        $req = [Net.WebRequest]::Create("http://127.0.0.1:$port/json/new?$Base/deltav/home")
        $req.Method = 'PUT'; $req.Proxy = $null; $req.ContentLength = 0
        $req.GetResponse().Close()
        $t6 = Get-Date
        Test-Check $sc 'a second window is closed' (Wait-Until -TimeoutSec 30 -Condition { (Get-LogText $run) -match 'Closed an extra window: http://127\.0\.0\.1:\d+/' })
        Test-Check $sc '...within seconds, and the dashboard stays' (((Get-Date) - $t6).TotalSeconds -lt 20 -and (Get-LauncherStatus $run).State -eq 'SHOWING') ('{0:0} s' -f ((Get-Date) - $t6).TotalSeconds)

        # 11. Edge is closed: a new one, which signs in again (InPrivate)
        Test-Check $sc 'Edge runs InPrivate' (@(Get-ProfileEdge $run.Profile | Where-Object { $_.CommandLine -match '--inprivate' }).Count -gt 0)
        $t5 = [DateTime]::UtcNow
        foreach ($p in Get-ProfileEdge $run.Profile) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        $ok = Wait-Until -TimeoutSec 60 -Condition { $s = Get-LauncherStatus $run; $s.BrowserStarts -eq 2 -and $s.State -eq 'SHOWING' }
        Test-Check $sc 'a closed Edge is started again and the dashboard comes back' $ok ("starts={0} state={1}" -f (Get-LauncherStatus $run).BrowserStarts, (Get-LauncherStatus $run).State)
        Test-Check $sc '...signing in again from the stored password' (@(Get-FixtureEvents -SinceUtc $t5 -Name 'password' | Where-Object { $_.ok }).Count -eq 1)

        # 12. relaunch.txt, hold.txt
        Send-Control $run 'relaunch.txt'
        Test-Check $sc 'relaunch.txt restarts Edge' (Wait-Until -TimeoutSec 45 -Condition { $s = Get-LauncherStatus $run; $s.BrowserStarts -eq 3 -and $s.State -eq 'SHOWING' })
        Send-Control $run 'hold.txt'
        Test-Check $sc 'hold.txt pauses it' (Wait-State $run 'HOLD' 15)
        Remove-Item -LiteralPath (Join-Path $run.InstanceDir 'hold.txt')
        Test-Check $sc 'deleting hold.txt resumes it' (Wait-State $run 'SHOWING' 20)

        # 13. nothing that should not be there
        Test-Check $sc 'no PC restart asked for in all this' (@(Get-Ledger $run 'RESTART_TRIGGERED').Count -eq 0 -and (Get-LogText $run) -notmatch 'SimulateRestart')
        Test-NoPasswordLeak -Run $run -Scenario $sc
        $log = Get-LogText $run
        Test-Check $sc 'log has no ERROR lines' (-not ($log -match 'type="3"')) (Get-ErrorLines $log)
        $stderr = Read-SharedFile $run.Stderr
        Test-Check $sc 'launcher wrote nothing to stderr' (-not $stderr.Trim()) $stderr

        # 14. kill.txt
        Send-Control $run 'kill.txt'
        Test-Check $sc 'kill.txt stops the launcher' ($run.Process.WaitForExit(30000))
        Test-Check $sc '...closes its Edge' ((Wait-Until -TimeoutSec 15 -Condition { @(Get-ProfileEdge $run.Profile).Count -eq 0 }))
        $stop = @(Get-Ledger $run 'AGENT_STOP')
        Test-Check $sc '...status STOPPED, AGENT_STOP in the ledger' ((Get-LauncherStatus $run).State -eq 'STOPPED' -and $stop.Count -eq 1 -and $stop[0].Detail -match 'kill\.txt') $(if ($stop) { $stop[0].Detail })
        Test-Check $sc 'exit code 0' ($run.Process.ExitCode -eq 0) $run.Process.ExitCode
    }
    finally {
        Stop-Run $run $sc
        if (-not $old.HasExited) { Stop-Process -Id $old.Id -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-WatchdogScenario {
    $sc = 'Watchdog'
    Write-Host "`n== $sc (a dashboard that stays white: the PC is restarted - simulated)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1&white=1'
    $run = New-Run -Name $sc -Seed $Password -Settings ([ordered]@{ RebootAfterMinutes = '0.25'; BadScreenSeconds = '3'; RestartConfirmSeconds = '15' })
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        $ok = Wait-Until -TimeoutSec 90 -Condition { @(Get-Ledger $run 'RESTART_TRIGGERED').Count -ge 1 }
        Test-Check $sc 'RESTART_TRIGGERED once the dashboard has been white for RebootAfterMinutes' $ok
        $markerSeen = Test-Path -LiteralPath (Join-Path $run.Wd 'mwst_pending_restart.txt')
        $guard = if (Test-Path -LiteralPath (Join-Path $run.Wd 'mwst_loopguard.json')) { ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $run.Wd 'mwst_loopguard.json'))) } else { $null }
        $rt = @(Get-Ledger $run 'RESTART_TRIGGERED')[0]
        Test-Check $sc 'the row: WHITE, with the reading, time, version and loop-guard count' ($rt.Detail -like 'WHITE: the dashboard is white*' -and [double]$rt.WhitePercent -ge 85 -and [double]$rt.DurationSeconds -ge 14 -and $rt.AgentVersion -eq $LauncherVersionUnderTest -and $rt.Detail -match 'LoopGuard=1/2' -and $rt.Severity -eq 'CRITICAL') $(if ($rt) { $rt.Detail })
        Test-Check $sc 'the pending-restart marker and the loop-guard count are on disk' ($markerSeen -and $guard -and @($guard.Restarts).Count -eq 1)
        $short = $rt.EventId.Substring(0, 8)
        Test-Check $sc 'shutdown.exe would have been run with the MWST-WATCHDOG tag and the row id' ((Get-LogText $run) -match ('SimulateRestart: not running shutdown\.exe /r /t 15 /f /c "MWST-WATCHDOG WHITE id=' + $short)) $short
        Test-Check $sc 'the white episode is closed with REBOOT' (@(Get-Ledger $run 'WHITE_EPISODE_END' | Where-Object { $_.Outcome -eq 'REBOOT' }).Count -eq 1)
        # The status file is saved at the end of the tick that wrote the
        # row, a moment after it: give it that moment.
        $restarting = Wait-Until -TimeoutSec 10 -Condition { (Get-LauncherStatus $run).State -eq 'RESTARTING_PC' }
        Test-Check $sc 'status RESTARTING_PC' $restarting ((Get-LauncherStatus $run).State)

        $ok = Wait-Until -TimeoutSec 45 -Condition { @(Get-Ledger $run 'RESTART_FAILED').Count -ge 1 }
        $rf = @(Get-Ledger $run 'RESTART_FAILED')
        Test-Check $sc 'still up after RestartConfirmSeconds: RESTART_FAILED' ($ok -and $rf[0].Detail -match 'never took effect' -and $rf[0].Detail -match $rt.EventId) $(if ($rf) { $rf[0].Detail })
        Test-Check $sc '...the marker is gone, and a restart that did not happen is not counted' (-not (Test-Path -LiteralPath (Join-Path $run.Wd 'mwst_pending_restart.txt')) -and -not (Test-Path -LiteralPath (Join-Path $run.Wd 'mwst_loopguard.json')))
        Test-Check $sc '...and the launcher carries on' (Wait-Until -TimeoutSec 20 -Condition { (Get-LauncherStatus $run).State -ne 'RESTARTING_PC' }) ((Get-LauncherStatus $run).State)

        # Every row reads in the collector.
        . ([scriptblock]::Create($CollectorCode))
        $rows = @(Get-Ledger $run)
        $conv = @($rows | ForEach-Object { ConvertFrom-LedgerRow -Row $_ -HostName 'TEST' -ScanId 's' -CollectedUtc 'x' })
        $nulls = @($conv | Where-Object { -not $_ }).Count
        $trig = @($conv | Where-Object { $_ -and $_.EventType -eq 'RESTART_TRIGGERED' })
        Test-Check $sc "the collector reads every one of the $($rows.Count) ledger rows" ($nulls -eq 0) "$nulls unreadable"
        Test-Check $sc '...and counts the restart as the watchdog''s (WATCHDOG_WHITE)' ($trig.Count -ge 1 -and $trig[0].RebootTrigger -eq 'WATCHDOG_WHITE') $(if ($trig) { $trig[0].RebootTrigger })
        $script:LedgerRuns['Watchdog'] = $run.Wd
    }
    finally { Stop-Run $run $sc; $null = Invoke-Http '/control?reset=1' }
}

function Invoke-LoopGuardScenario {
    $sc = 'LoopGuard'
    Write-Host "`n== $sc (two restarts in a row did not help; a restart from before is confirmed)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1&white=1'
    $run = New-Run -Name $sc -Seed $Password -Settings ([ordered]@{ RebootAfterMinutes = '0.2'; BadScreenSeconds = '3'; LoopGuardHealthyMinutes = '0.25'; EpisodeGraceSeconds = '120' })
    $now = [DateTime]::UtcNow
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
    $fmt = { param($t) $t.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
    [IO.File]::WriteAllText((Join-Path $run.Wd 'mwst_loopguard.json'), (ConvertTo-Json -Compress ([pscustomobject]@{ HoldReported = $false; Restarts = @((& $fmt $now.AddMinutes(-20)), (& $fmt $now.AddMinutes(-10))) })))
    $markerId = [guid]::NewGuid().ToString()
    [IO.File]::WriteAllText((Join-Path $run.Wd 'mwst_pending_restart.txt'), (ConvertTo-Json -Compress ([pscustomobject]@{ EventId = $markerId; Kind = 'WHITE'; Reason = 'test'; TriggeredUtc = (& $fmt $boot.AddMinutes(-3)); BootTimeUtc = (& $fmt $boot.AddDays(-1)) })))
    Start-Run $run
    try {
        $ok = Wait-Until -TimeoutSec 30 -Condition { @(Get-Ledger $run 'RESTART_CONFIRMED').Count -eq 1 }
        $rc = @(Get-Ledger $run 'RESTART_CONFIRMED')
        Test-Check $sc 'a marker from before this boot: RESTART_CONFIRMED' ($ok -and $rc[0].Detail -match $markerId -and $rc[0].Detail -match 'took effect') $(if ($rc) { $rc[0].Detail })
        $ok = Wait-Until -TimeoutSec 90 -Condition { @(Get-Ledger $run 'LOOP_GUARD_ENGAGED').Count -eq 1 }
        Test-Check $sc 'white again: LOOP_GUARD_ENGAGED instead of a third restart' ($ok -and @(Get-Ledger $run 'RESTART_TRIGGERED').Count -eq 0)
        # The ledger row is written mid-tick, the status file at the end of it.
        $ok = Wait-Until -TimeoutSec 10 -Condition { (Get-LauncherStatus $run).LoopGuard -like 'holding*' }
        $st = Get-LauncherStatus $run
        Test-Check $sc 'status shows the hold' $ok $st.LoopGuard
        Start-Sleep -Seconds 10
        Test-Check $sc 'the hold is written once, and still no restart' (@(Get-Ledger $run 'LOOP_GUARD_ENGAGED').Count -eq 1 -and @(Get-Ledger $run 'RESTART_TRIGGERED').Count -eq 0)
        Test-Check $sc 'no screen episode before the dashboard was ever on screen (EpisodeGraceSeconds)' (@(Get-Ledger $run 'WHITE_EPISODE_START').Count -eq 0)
        $null = Invoke-Http '/control?white=0'
        Send-Control $run 'refresh.txt'
        Test-Check $sc 'the dashboard comes back' (Wait-State $run 'SHOWING' 60)
        $ok = Wait-Until -TimeoutSec 60 -Condition { @(Get-Ledger $run 'LOOP_GUARD_RELEASED').Count -eq 1 -and -not (Test-Path -LiteralPath (Join-Path $run.Wd 'mwst_loopguard.json')) -and -not (Get-LauncherStatus $run).LoopGuard }
        Test-Check $sc 'LOOP_GUARD_RELEASED after LoopGuardHealthyMinutes on screen, count cleared' $ok
    }
    finally { Stop-Run $run $sc; $null = Invoke-Http '/control?reset=1' }
}

function Invoke-OutageScenario {
    $sc = 'Outage'
    Write-Host "`n== $sc (the station cannot be reached: no quick restart, then one after OutageRebootMinutes)" -ForegroundColor Cyan
    $run = New-Run -Name $sc -Settings ([ordered]@{ DisplayURL = 'http://127.0.0.1:1/deltav/dashboard:viewer/@/Nyrany/TEST/Dashboards/Graphs'; LoginURL = ''; RebootAfterMinutes = '0.1'; OutageRebootMinutes = '0.7'; RestartConfirmSeconds = '600' })
    $t0 = Get-Date
    Start-Run $run
    try {
        $ok = Wait-Until -TimeoutSec 30 -Condition { (Get-LogText $run) -match 'Edge shows an error page' }
        Test-Check $sc 'notices the Edge error page' $ok
        Test-Check $sc 'status RECOVERING' ((Get-LauncherStatus $run).State -eq 'RECOVERING') ((Get-LauncherStatus $run).State)
        while (((Get-Date) - $t0).TotalSeconds -lt 30) { Start-Sleep -Seconds 1 }
        Test-Check $sc 'no restart after RebootAfterMinutes (6 s): a restart does not fix a station outage' (@(Get-Ledger $run 'RESTART_TRIGGERED').Count -eq 0)
        $tries = ([regex]::Matches((Get-LogText $run), 'Opening the dashboard \(Edge shows an error page')).Count
        Test-Check $sc 'backs off instead of hammering (<= 3 tries in 30 s)' ($tries -ge 1 -and $tries -le 3) "$tries tries"
        $ok = Wait-Until -TimeoutSec 60 -Condition { @(Get-Ledger $run 'RESTART_TRIGGERED').Count -ge 1 }
        $rt = @(Get-Ledger $run 'RESTART_TRIGGERED')
        Test-Check $sc 'a restart after OutageRebootMinutes (42 s), kind BROWSER' ($ok -and $rt[0].Detail -like 'BROWSER: Edge shows an error page*') $(if ($rt) { $rt[0].Detail })
    }
    finally { Stop-Run $run $sc }
}

function Invoke-WrongPasswordScenario {
    $sc = 'WrongPassword'
    Write-Host "`n== $sc (lockout protection; no restart while a person is needed)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    $run = New-Run -Name $sc -Seed 'definitely-wrong' -Settings ([ordered]@{ ConfigVersion = '1.00NG'; RebootAfterMinutes = '0.1'; OutageRebootMinutes = '0.2' })
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        Test-Check $sc 'SIGNIN_BLOCKED after the station rejects the password' (Wait-State $run 'SIGNIN_BLOCKED' 60) ((Get-LauncherStatus $run).Detail)
        Test-Check $sc '...saying why' ((Get-LauncherStatus $run).Detail -match 'rejected the sign-in as operator') ((Get-LauncherStatus $run).Detail)
        Start-Sleep -Seconds 20
        $bad = @(Get-FixtureEvents -SinceUtc $t0 -Name 'password')
        Test-Check $sc 'tried the wrong password exactly once' ($bad.Count -eq 1 -and -not $bad[0].ok) ("{0} attempt(s)" -f $bad.Count)
        Test-Check $sc 'no PC restart for it (a person is needed)' (@(Get-Ledger $run 'RESTART_TRIGGERED').Count -eq 0)
        $t1 = [DateTime]::UtcNow
        [IO.File]::WriteAllText((Join-Path $run.InstanceDir 'password.seed'), $Password, $Utf8)
        Test-Check $sc 'a new password.seed lifts the block and signs in' (Wait-State $run 'SHOWING' 60) ((Get-LauncherStatus $run).State)
        Test-Check $sc '...with one attempt' (@(Get-FixtureEvents -SinceUtc $t1 -Name 'password' | Where-Object { $_.ok }).Count -eq 1)
        Test-NoPasswordLeak -Run $run -Scenario $sc
    }
    finally { Stop-Run $run $sc }
}

function Invoke-SlowStationScenario {
    # TV3, 2026-09-25: the station took so long over the password that the
    # page stopped answering DevTools. The launcher read that as a dead
    # browser, restarted Edge mid-sign-in, typed the password again, and after
    # two of those the lockout guard blocked the kiosk for an hour - all while
    # the station was merely slow.
    $sc = 'SlowStation'
    Write-Host "`n== $sc (a slow station: the page goes quiet while it signs in)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    $null = Invoke-Http '/control?slowlogin=3000&blockms=40000'
    $run = New-Run -Name $sc -Seed $Password -Settings ([ordered]@{
            PageReadTimeoutSeconds = '10'; PageStalledSeconds = '25'; SignInWaitSeconds = '120'; SignInSettleSeconds = '10'
        })
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        Test-Check $sc 'reaches the dashboard even though the page went quiet' (Wait-State $run 'SHOWING' 180) ((Get-LauncherStatus $run).State)
        $log = Get-LogText $run
        Test-Check $sc 'waited rather than restarting Edge' ($log -notmatch 'stopped responding') ($log -split "`n" | Select-String 'Restarting Edge' | Select-Object -First 1)
        Test-Check $sc '...and said what it was waiting for' ($log -match 'signing in')
        Test-Check $sc 'the password was entered once, not typed again into the waiting form' (@([regex]::Matches($log, 'entered the password')).Count -eq 1)
        Test-Check $sc 'the station was asked once' (@(Get-FixtureEvents -SinceUtc $t0 -Name 'password').Count -eq 1)
        Test-Check $sc 'never blocked' ($log -notmatch 'already entered twice' -and (Get-LauncherStatus $run).State -ne 'SIGNIN_BLOCKED')
        Test-NoPasswordLeak -Run $run -Scenario $sc
    }
    finally { Stop-Run $run $sc; $null = Invoke-Http '/control?reset=1' }

    # The same slow station with the patience turned down to what it was
    # before these settings existed. It gives up on the page, which is what
    # the checks above are worth: the waiting is what saves the sign-in, not
    # something else about this fixture.
    $null = Invoke-Http '/control?reset=1&logout=1'
    $null = Invoke-Http '/control?slowlogin=3000&blockms=40000'
    $run2 = New-Run -Name "${sc}Impatient" -Seed $Password -Settings ([ordered]@{
            PageReadTimeoutSeconds = '5'; PageStalledSeconds = '10'; SignInWaitSeconds = '10'; SignInSettleSeconds = '3'
        })
    Start-Run $run2
    try {
        Test-Check $sc 'with the wait turned down it gives up on the page, as it used to' `
            (Wait-Until -TimeoutSec 120 -Condition { (Get-LogText $run2) -match 'stopped responding' })
    }
    finally { Stop-Run $run2 $sc; $null = Invoke-Http '/control?reset=1' }
}

function Invoke-SinglePageScenario {
    $sc = 'SinglePage'
    Write-Host "`n== $sc (user name and password on one page; plain-text password from an old config)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1&singlepage=1'
    $run = New-Run -Name $sc -LegacyArray -Settings ([ordered]@{ JsonVer = '1.0.0.16'; Password = $Password; LoginURL = '' })
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        Test-Check $sc 'reaches SHOWING' (Wait-State $run 'SHOWING' 90) ((Get-LauncherStatus $run).State)
        $ev = Get-FixtureEvents -SinceUtc $t0
        Test-Check $sc 'filled in both on the one page, one password' (@($ev | Where-Object { $_.name -eq 'login-page' -and $_.single }).Count -ge 1 -and @($ev | Where-Object { $_.name -eq 'password' -and $_.ok }).Count -eq 1 -and @($ev | Where-Object name -eq 'user').Count -eq 0)
        Test-Check $sc 'plain-text password copied into the encrypted file, with a warning' ((Test-Path -LiteralPath $run.Cred) -and (Get-LogText $run) -match 'plain-text Password')
    }
    finally { Stop-Run $run $sc; $null = Invoke-Http '/control?reset=1' }
}

function Invoke-SecondScreenScenario {
    $sc = 'SecondScreen'
    Write-Host "`n== $sc (S2: keeps its screen, not the watchdog)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    $run = New-Run -Name $sc -Instance 'S2' -Seed $Password -Settings ([ordered]@{ RebootAfterMinutes = '0.1' })
    # A two-screen Mach2 kiosk: S1 has its config too (not started here), so
    # S2 is not the first Mach2 screen. Alone, S2 would be the watchdog - as
    # where Power BI or a web page has S1 (see Unit).
    $s1 = Join-Path (Split-Path -Parent $run.InstanceDir) 'S1'
    New-Item -ItemType Directory -Path $s1 -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $s1 "$($env:COMPUTERNAME.ToUpperInvariant()).json"), '{ "DisplayURL": "http://station/s1" }', $Utf8)
    Start-Run $run
    try {
        Test-Check $sc 'reaches SHOWING' (Wait-State $run 'SHOWING' 90) ((Get-LauncherStatus $run).State)
        Test-Check $sc 'not the watchdog: no ledger, no mwst.log' (-not (Get-LauncherStatus $run).Watchdog -and -not (Test-Path -LiteralPath $run.Ledger) -and -not (Test-Path -LiteralPath $run.WdLog))
        Test-Check $sc 'status file named after the instance' (Test-Path -LiteralPath (Join-Path $run.InstanceDir 'Status\S2.status.json'))
        Test-Check $sc 'its log says what it is' ((Get-LogText $run) -match 'Not the watchdog')
    }
    finally { Stop-Run $run $sc }
}

function Invoke-DisabledScenario {
    $sc = 'Disabled'
    Write-Host "`n== $sc (DisableStartup = 1)" -ForegroundColor Cyan
    $run = New-Run -Name $sc -LegacyArray -Settings ([ordered]@{ JsonVer = '1.0.0.16'; DisableStartup = '1' })
    Start-Run $run
    try {
        Test-Check $sc 'exits at once' ($run.Process.WaitForExit(30000))
        Test-Check $sc 'status DISABLED, no Edge' ((Get-LauncherStatus $run).State -eq 'DISABLED' -and @(Get-ProfileEdge $run.Profile).Count -eq 0)
        $stop = @(Get-Ledger $run 'AGENT_STOP')
        Test-Check $sc 'the ledger says the watchdog is not running, and why' (@(Get-Ledger $run 'AGENT_START').Count -eq 1 -and $stop.Count -eq 1 -and $stop[0].Detail -match 'DisableStartup') $(if ($stop) { $stop[0].Detail })
    }
    finally { Stop-Run $run $sc }
}

# ---------------------------------------------------------------------------
# The collector reading kiosks on the new launcher
# ---------------------------------------------------------------------------
function Invoke-CollectorScenario {
    $sc = 'Collector'
    Write-Host "`n== $sc (statuses and rows for kiosks on 1.00NG)" -ForegroundColor Cyan
    $cr = Join-Path $WorkRoot 'collector'
    if (Test-Path -LiteralPath $cr) { Remove-Item -LiteralPath $cr -Recurse -Force }
    $sandbox = Join-Path $cr 'fleet'
    New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $FleetRoot 'Collect-MWSTFleet.ps1') -Destination $sandbox
    Copy-Item -LiteralPath (Join-Path $FleetRoot 'Lib') -Destination $sandbox -Recurse
    $template = Join-Path $cr 'kiosks\{0}'
    $now = [DateTime]::UtcNow
    $fmt = { param($t) $t.ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture) }
    $header = 'EventId,EventTimeUtc,EventTimeLocal,Host,EventType,Severity,Outcome,WhitePercent,StreakChecks,DurationSeconds,AgentVersion,BootTimeUtc,Detail'

    function New-NgKiosk {
        param([string]$Name, [string]$State, [string]$Detail = '', [string[]]$ExtraRows = @(), [string]$CopyLedgerFrom)
        $pub = Join-Path ($template -f $Name) 'Users\Public\Documents'
        $ng = Join-Path $pub 'Mach2LauncherNG'
        New-Item -ItemType Directory -Path (Join-Path $ng 'S1\Status') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $ng 'Mach2LauncherNG.ps1'), '# fake')
        [IO.File]::WriteAllText((Join-Path $pub 'mwst.log'), "[x] [INFO] Heartbeat`r`n")
        $ledger = Join-Path $pub 'mwst_events.csv'
        if ($CopyLedgerFrom -and (Test-Path -LiteralPath (Join-Path $CopyLedgerFrom 'mwst_events.csv'))) { Copy-Item -LiteralPath (Join-Path $CopyLedgerFrom 'mwst_events.csv') -Destination $ledger }
        else {
            $start = '"{0}","{1}","{1}","{2}","AGENT_START","INFO","","","","","1.00NG","{3}","Mach2 Launcher 1.00NG started, watchdog built in. Instance=S1"' -f [guid]::NewGuid(), (& $fmt $now.AddMinutes(-30)), $Name, (& $fmt $now.AddHours(-2))
            [IO.File]::WriteAllText($ledger, ($header + "`r`n" + $start + "`r`n" + (($ExtraRows | ForEach-Object { $_ + "`r`n" }) -join '')), (New-Object Text.UTF8Encoding($true)))
        }
        $s = [ordered]@{
            Host = $Name; Instance = 'S1'; LauncherVersion = '1.00NG'; State = $State; StateSinceUtc = $now.AddMinutes(-5).ToString('o'); Detail = $Detail
            Watchdog = $true; LoopGuard = ''; PageWhitePercent = 71.9; ScreenWhitePercent = 72.4; EdgeVersion = 'Edg/153.0.4234.32'
            BrowserStarts = 1; Reloads = 3; SignIns = 1; PcRestarts = 0; LastShownUtc = $now.ToString('o'); LastError = ''; PcBootUtc = $now.AddHours(-2).ToString('o'); UpdatedUtc = $now.AddSeconds(-20).ToString('o')
        }
        $script:NgStatus[(Join-Path $ng 'S1\Status\S1.status.json')] = $s
    }
    # Written again right before each read: waiting for a real scan to
    # finish must not make them stale.
    $script:NgStatus = @{}
    $refresh = {
        foreach ($k in @($script:NgStatus.Keys)) {
            $s = $script:NgStatus[$k]
            $s.UpdatedUtc = [DateTime]::UtcNow.AddSeconds(-20).ToString('o')
            [IO.File]::WriteAllText($k, (ConvertTo-Json -InputObject $s))
        }
    }

    # 127.0.0.8: blocked sign-in, with the Watchdog scenario's real ledger
    New-NgKiosk -Name '127.0.0.8' -State 'SIGNIN_BLOCKED' -Detail 'The station rejected the sign-in as operator' -CopyLedgerFrom $script:LedgerRuns['Watchdog']
    # 127.0.0.9: all good, and a 1074 of a BROWSER restart copied in by the launcher
    $payload = (ConvertTo-Json -Compress -InputObject ([pscustomobject]@{ Id = 1074; Provider = 'User32'; RecordId = 99
                Props = @('C:\Windows\system32\shutdown.exe (K)', 'K', 'Other (Planned)', '0x80000000', 'restart', 'MWST-WATCHDOG BROWSER id=1a2b3c4d - Mach2 Launcher 1.00NG: Edge will not start for 5.0 min', 'SHAPE\K'); Msg = '' })).Replace('"', '""')
    $row1074 = '"EVT-127.0.0.9-99-{0}","{1}","{1}","127.0.0.9","WINEVENT","INFO","","","","","1.00NG","","{2}"' -f $now.AddMinutes(-20).ToString('yyyyMMddHHmmss'), (& $fmt $now.AddMinutes(-20)), $payload
    $rowTrig = '"1a2b3c4d-0000-4000-8000-000000000001","{0}","{0}","127.0.0.9","RESTART_TRIGGERED","CRITICAL","REBOOT","","30","300","1.00NG","{1}","BROWSER: Edge will not start for 5.0 min. EpisodeId=; Instance=S1; LoopGuard=1/2"' -f (& $fmt $now.AddMinutes(-20).AddSeconds(-1)), (& $fmt $now.AddHours(-3))
    New-NgKiosk -Name '127.0.0.9' -State 'SHOWING' -ExtraRows @($rowTrig, $row1074)

    $list = Join-Path $cr 'kiosks.csv'
    @(
        [pscustomobject]@{ Host = '127.0.0.8'; Location = 'NG BLOCKED'; Type = 'Mach2'; Active = 'Y'; HasMwst = 'Y' }
        [pscustomobject]@{ Host = '127.0.0.9'; Location = 'NG GOOD'; Type = 'Mach2'; Active = 'Y'; HasMwst = 'Y' }
    ) | Export-Csv -LiteralPath $list -NoTypeInformation
    $csv = Join-Path $cr 'out\MWST_FleetEvents.csv'
    New-Item -ItemType Directory -Path (Split-Path -Parent $csv) -Force | Out-Null
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $sandbox 'Collect-MWSTFleet.ps1'), '-KioskList', $list, '-OutputCsv', $csv,
        '-KioskRootTemplate', $template, '-AgentPathTemplate', (Join-Path $template 'Users\Public\Documents'))
    # Only one collector runs at a time on a PC (a machine-wide lock). If the
    # Kiosk Fleet Manager's auto-scan or the scheduled task is scanning the
    # real fleet right now, wait for it.
    $deadline = (Get-Date).AddMinutes(12)
    while ($true) {
        & $refresh
        $out = & powershell.exe @argv 2>&1 | Out-String
        if ($out -notmatch 'Another collector run is in progress' -or (Get-Date) -gt $deadline) { break }
        Write-Host '  (a real scan is running on this PC; waiting for it to finish)' -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }
    Test-Check $sc 'collector run completes' (Test-Path -LiteralPath $csv) $(if (-not (Test-Path -LiteralPath $csv)) { $out })
    if (-not (Test-Path -LiteralPath $csv)) { return }
    $rows = @(Import-Csv -LiteralPath $csv)
    $st = @{}; foreach ($r in @($rows | Where-Object EventType -eq 'HOST_STATUS')) { $st[$r.Host] = $r }
    Test-Check $sc 'a blocked sign-in is the kiosk''s status (CRITICAL), though the watchdog runs' ($st['127.0.0.8'].Outcome -eq 'SIGNIN_BLOCKED' -and $st['127.0.0.8'].Severity -eq 'CRITICAL' -and $st['127.0.0.8'].WatchdogRunning -eq 'TRUE') ("{0} {1}" -f $st['127.0.0.8'].Outcome, $st['127.0.0.8'].Severity)
    Test-Check $sc 'a kiosk showing its dashboard is OK' ($st['127.0.0.9'].Outcome -eq 'OK') $st['127.0.0.9'].Outcome
    # .8's ledger is the real launcher's (from the Watchdog scenario); .9's
    # rows are written here as 1.00NG's.
    Test-Check $sc 'the agent version is what each kiosk''s launcher wrote' ($st['127.0.0.8'].AgentVersion -eq $LauncherVersionUnderTest -and $st['127.0.0.9'].AgentVersion -eq '1.00NG') ("{0} / {1}" -f $st['127.0.0.8'].AgentVersion, $st['127.0.0.9'].AgentVersion)
    Test-Check $sc 'the detail carries the launcher summary' ($st['127.0.0.8'].Detail -match 'launcher=S1:SIGNIN_BLOCKED screen=72\.4% age=0\.\dm v1\.00NG') $st['127.0.0.8'].Detail
    $w = @($rows | Where-Object { $_.Host -eq '127.0.0.8' -and $_.EventType -eq 'RESTART_TRIGGERED' })
    Test-Check $sc 'the launcher''s real ledger arrives: RESTART_TRIGGERED as WATCHDOG_WHITE' ($w.Count -ge 1 -and $w[0].RebootTrigger -eq 'WATCHDOG_WHITE') $(if ($w) { $w[0].RebootTrigger } else { 'none - did the Watchdog scenario run?' })
    $b = @($rows | Where-Object { $_.Host -eq '127.0.0.9' -and $_.EventType -eq 'REBOOT_SCRIPT' })
    Test-Check $sc 'its 1074 is a script reboot, WATCHDOG_BROWSER, counted once' ($b.Count -eq 1 -and $b[0].RebootTrigger -eq 'WATCHDOG_BROWSER' -and @($rows | Where-Object { $_.Host -eq '127.0.0.9' -and $_.IsScriptReboot -eq 'TRUE' }).Count -eq 1) $(if ($b) { "$($b[0].RebootTrigger) script=$($b[0].IsScriptReboot)" })
    $side = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText([IO.Path]::ChangeExtension($csv, '.status.json')))
    Test-Check $sc 'the collector''s status file has the launchers'' details' ($side.Mach2Launchers.'127.0.0.8'.Instances[0].State -eq 'SIGNIN_BLOCKED' -and $side.Mach2Launchers.'127.0.0.9'.Instances[0].ScreenWhitePercent -eq 72.4)

    # the status tool on the same kiosks
    $tool = Join-Path $FleetRoot 'Get-Mach2LauncherNGStatus.ps1'
    & $refresh
    $sr = @(& $tool -Hosts '127.0.0.8,127.0.0.9' -RootTemplate $template -FleetRoot $FleetRoot -PassThru)
    Test-Check $sc 'status tool: states, the watchdog mark and readings' (@($sr | Where-Object { $_.Host -eq '127.0.0.8' })[0].State -eq 'SIGNIN_BLOCKED' -and @($sr | Where-Object { $_.Host -eq '127.0.0.9' })[0].Watchdog -eq '*' -and @($sr | Where-Object { $_.Host -eq '127.0.0.9' })[0].Screen -eq '72%') (($sr | ForEach-Object { "$($_.Host)=$($_.State)" }) -join ' ')
}

# ---------------------------------------------------------------------------
# The old launcher: stopped for this screen, and nothing else touched
#
# On the kiosks the StartupLauncher shortcut comes back at every logon
# (Mach2LauncherShortcuts.ps1) and starts Mach2Launcher.exe again, which
# then fights the new launcher for the screen - seen on TV4 after its
# deploy. Stop-OldLauncher is run here against real processes: a small
# program copied as Mach2Launcher.exe, msedgedriver.exe and msedge.exe,
# each starting the next as the real ones do.
# ---------------------------------------------------------------------------
function Invoke-OldLauncherTests {
    $sc = 'OldLauncher'
    Write-Host "`n== $sc" -ForegroundColor Cyan

    $ast = [Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Stop-OldLauncher' }, $true) | Select-Object -First 1
    Test-Check $sc 'the launcher has Stop-OldLauncher' ($null -ne $fn)
    if (-not $fn) { return }
    . ([scriptblock]::Create($fn.Extent.Text))

    # The stand-in: starts whatever FAKE_<its own name> lists ("path?args",
    # separated by |), then waits. The list travels to its children in the
    # environment, so one setting describes the whole tree.
    $base = Join-Path $WorkRoot 'oldlauncher'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    $fake = Join-Path $base 'fake.exe'
    Add-Type -OutputType ConsoleApplication -OutputAssembly $fake -TypeDefinition @'
using System; using System.Diagnostics; using System.IO; using System.Threading;
public static class FakeProcess {
    public static void Main(string[] args) {
        string me = Path.GetFileNameWithoutExtension(Process.GetCurrentProcess().MainModule.FileName);
        string spec = Environment.GetEnvironmentVariable("FAKE_" + me);
        if (!string.IsNullOrEmpty(spec)) {
            foreach (string item in spec.Split('|')) {
                string[] parts = item.Split(new[] { '?' }, 2);
                ProcessStartInfo psi = new ProcessStartInfo(parts[0], parts.Length > 1 ? parts[1] : "");
                psi.UseShellExecute = false; psi.CreateNoWindow = true;
                Process.Start(psi);
            }
        }
        Thread.Sleep(600000);
    }
}
'@
    $s1 = Join-Path $base 'Mach2Launchers\Launcher S1'
    $s2 = Join-Path $base 'Mach2Launchers\Launcher S2'
    $other = Join-Path $base 'Launchers\Launcher S1'
    foreach ($d in @($s1, $s2, $other)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    foreach ($n in @('Mach2Launcher.exe', 'msedgedriver.exe', 'msedge.exe')) { Copy-Item $fake (Join-Path $s1 $n) }
    Copy-Item $fake (Join-Path $s2 'Mach2Launcher.exe')
    Copy-Item $fake (Join-Path $other 'msedgedriver.exe')
    $ownProfile = Join-Path $base 'NG-Profile-S1'

    $started = New-Object System.Collections.Generic.List[int]
    $env:FAKE_Mach2Launcher = Join-Path $s1 'msedgedriver.exe'
    $env:FAKE_msedgedriver = ('{0}?--remote-debugging-port=0|{0}?--user-data-dir="{1}"' -f (Join-Path $s1 'msedge.exe'), $ownProfile)
    try {
        # Screen 1's old launcher, with its driver and two Edge processes:
        # one it opened, and one that - however unlikely - carries this
        # launcher's own profile and must be left alone.
        $root1 = Start-Process -FilePath (Join-Path $s1 'Mach2Launcher.exe') -PassThru -WindowStyle Hidden
        $started.Add($root1.Id)
    }
    finally { Remove-Item Env:\FAKE_Mach2Launcher, Env:\FAKE_msedgedriver -ErrorAction SilentlyContinue }
    # Screen 2's old launcher, and some other launcher's driver in a
    # "Launcher S1" folder with no Mach2Launcher.exe beside it.
    $root2 = Start-Process -FilePath (Join-Path $s2 'Mach2Launcher.exe') -PassThru -WindowStyle Hidden
    $lone = Start-Process -FilePath (Join-Path $other 'msedgedriver.exe') -PassThru -WindowStyle Hidden
    $started.Add($root2.Id); $started.Add($lone.Id)

    $fakes = { @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'Mach2Launcher.exe' OR Name = 'msedgedriver.exe' OR Name = 'msedge.exe'" |
            Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) }) }
    $deadline = (Get-Date).AddSeconds(15)
    while (@(& $fakes).Count -lt 6 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
    $before = @(& $fakes)
    Test-Check $sc 'six stand-in processes are running' ($before.Count -eq 6) ("{0}: {1}" -f $before.Count, (($before | ForEach-Object { "$($_.Name)[$($_.ProcessId)]" }) -join ' '))

    try {
        # What Stop-OldLauncher reads from the launcher around it.
        $Instance = 'S1'
        $LauncherVersion = 'test'
        $OldLauncherCheckSeconds = 20
        $script:Logged = New-Object System.Collections.Generic.List[string]
        function Write-Log { param([string]$Message, [string]$Level = 'INFO') $script:Logged.Add("$Level $Message") }
        $script:Status = [ordered]@{ State = 'SHOWING'; OldLauncherStops = 0 }
        $config = [pscustomobject]@{ StopOldLauncher = $true; ProfileDir = $ownProfile }

        $script:LastOldLauncherCheckUtc = [DateTime]::MinValue
        Stop-OldLauncher -Config ([pscustomobject]@{ StopOldLauncher = $false; ProfileDir = $ownProfile })
        Test-Check $sc 'StopOldLauncher = 0 leaves the old launcher alone' (@(& $fakes).Count -eq 6)

        $script:Status.State = 'HOLD'
        Stop-OldLauncher -Config $config
        Test-Check $sc 'on hold, nothing is touched' (@(& $fakes).Count -eq 6)
        $script:Status.State = 'SHOWING'

        $script:LastOldLauncherCheckUtc = [DateTime]::MinValue
        Stop-OldLauncher -Config $config
        Start-Sleep -Milliseconds 800
        $after = @(& $fakes)
        # @() around every call: one match comes back as the process itself,
        # and a CIM process has no .Count of its own.
        $has = { param($name, $folder) @($after | Where-Object { $_.Name -eq $name -and (Split-Path -Parent $_.ExecutablePath) -eq $folder }) }
        Test-Check $sc "screen 1's old launcher is stopped" (@(& $has 'Mach2Launcher.exe' $s1).Count -eq 0)
        Test-Check $sc 'and its msedgedriver, and the Edge that driver opened' (
            @(& $has 'msedgedriver.exe' $s1).Count -eq 0 -and
            @($after | Where-Object { $_.Name -eq 'msedge.exe' -and $_.CommandLine -notmatch [regex]::Escape($ownProfile) }).Count -eq 0)
        Test-Check $sc "an Edge on this launcher's own profile is left alone" (
            @($after | Where-Object { $_.Name -eq 'msedge.exe' -and $_.CommandLine -match [regex]::Escape($ownProfile) }).Count -eq 1)
        $left = (@($after | ForEach-Object { '{0}@{1}' -f $_.Name, (Split-Path -Parent $_.ExecutablePath).Replace($base, '~') }) -join ' ')
        Test-Check $sc "screen 2's old launcher is not this instance's to stop" (@(& $has 'Mach2Launcher.exe' $s2).Count -eq 1) $left
        Test-Check $sc 'a driver with no old Mach2 launcher beside it is left alone' (@(& $has 'msedgedriver.exe' $other).Count -eq 1) $left
        Test-Check $sc 'it says what it stopped, and counts it' (
            @($script:Logged | Where-Object { $_ -match '^WARN Stopped the old Mach2Launcher\.exe' }).Count -eq 1 -and $script:Status.OldLauncherStops -eq 1) (@($script:Logged) -join ' | ')

        $n = $script:Logged.Count
        Stop-OldLauncher -Config $config
        Test-Check $sc 'the next look within 20 s costs nothing' ($script:Logged.Count -eq $n)
        $script:LastOldLauncherCheckUtc = [DateTime]::MinValue
        Stop-OldLauncher -Config $config
        Test-Check $sc 'with nothing left to stop, it says nothing' ($script:Logged.Count -eq $n)
    }
    finally {
        foreach ($p in @(& $fakes)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$all = -not $Only

if ($all -or 'Unit' -in $Only) { Invoke-UnitTests }
if ($all -or 'OldLauncher' -in $Only) { Invoke-OldLauncherTests }

$e2e = @('Main', 'Watchdog', 'LoopGuard', 'Outage', 'WrongPassword', 'SlowStation', 'SinglePage', 'SecondScreen', 'Disabled') | Where-Object { $all -or $_ -in $Only }
if ($e2e) {
    $script:EventsFile = Join-Path $WorkRoot 'events.jsonl'
    $pwFile = Join-Path $WorkRoot 'fixture-password.txt'
    [IO.File]::WriteAllText($pwFile, $Password, $Utf8)
    $server = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $PSScriptRoot 'Mach2Fixture.ps1')),
        '-Port', $Port, '-EventsFile', ('"{0}"' -f $script:EventsFile), '-PasswordFile', ('"{0}"' -f $pwFile), '-UserName', $User)
    try {
        if (-not (Wait-Until -TimeoutSec 20 -Condition { (Invoke-Http '/control?reset=1') -eq 'ok' })) { throw 'The fixture station did not start.' }
        foreach ($name in $e2e) {
            switch ($name) {
                'Main' { Invoke-MainScenario }
                'Watchdog' { Invoke-WatchdogScenario }
                'LoopGuard' { Invoke-LoopGuardScenario }
                'Outage' { Invoke-OutageScenario }
                'WrongPassword' { Invoke-WrongPasswordScenario }
                'SlowStation' { Invoke-SlowStationScenario }
                'SinglePage' { Invoke-SinglePageScenario }
                'SecondScreen' { Invoke-SecondScreenScenario }
                'Disabled' { Invoke-DisabledScenario }
            }
        }
    }
    finally {
        try { $null = Invoke-Http '/stop' } catch {}
        if (-not $server.WaitForExit(5000)) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    }
}
if ($all -or 'Collector' -in $Only) { Invoke-CollectorScenario }

$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("{0} checks, {1} failed." -f $script:Results.Count, $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
foreach ($f in $failed) { Write-Host ("  FAIL {0}: {1} {2}" -f $f.Scenario, $f.Check, $f.Detail) -ForegroundColor Red }
if (-not $KeepWorkRoot -and $failed.Count -eq 0) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue }
exit $failed.Count
