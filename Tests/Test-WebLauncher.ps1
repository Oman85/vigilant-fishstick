#Requires -Version 5.1
<#
.SYNOPSIS
    Tests WebLauncher.ps1: that it is what Tools\Build-WebLauncher.ps1 makes
    of PbiLauncher.ps1, its URL rule, and end-to-end runs in a screen folder
    against FixtureServer.ps1's plain site (/site) with a headless Edge.

.DESCRIPTION
    Nothing here touches a real kiosk. Each run gets its own folder and Edge
    profile under -WorkRoot; the launcher only ever closes Edge processes
    that use its own profile.

    Takes about three minutes.

.EXAMPLE
    .\Tests\Test-WebLauncher.ps1
#>
[CmdletBinding()]
param(
    [string]$WorkRoot,
    [int]$Port = 18769,
    [switch]$KeepWorkRoot
)

$ErrorActionPreference = 'Stop'
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectDir = (Resolve-Path -LiteralPath (Join-Path $here '..')).ProviderPath
if (-not $WorkRoot) { $WorkRoot = Join-Path $env:TEMP 'WebLauncherTests' }
$Launcher = Join-Path $ProjectDir 'WebLauncher\WebLauncher.ps1'
$Base = "http://127.0.0.1:$Port"
$HostName = $env:COMPUTERNAME.ToUpperInvariant()
$Utf8 = New-Object Text.UTF8Encoding($false)
$script:Results = New-Object System.Collections.Generic.List[object]

function Test-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Check = $Name; Pass = $Pass; Detail = $Detail })
    $suffix = if ($Detail) { "  ($Detail)" } else { '' }
    Write-Host ("  [{0}] {1}{2}" -f $(if ($Pass) { 'PASS' } else { 'FAIL' }), $Name, $suffix) -ForegroundColor $(if ($Pass) { 'Green' } else { 'Red' })
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

function Read-SharedFile {
    param([string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try { return (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
}

function Invoke-Http {
    param([string]$PathAndQuery)
    $wc = New-Object Net.WebClient; $wc.Proxy = $null
    try { return $wc.DownloadString("$Base$PathAndQuery") } finally { $wc.Dispose() }
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

# --- a small DevTools client --------------------------------------------------
function Invoke-DevToolsHttp {
    param([int]$DevPort, [string]$Path)
    $r = [Net.WebRequest]::Create("http://127.0.0.1:$DevPort$Path"); $r.Proxy = $null
    $resp = $r.GetResponse()
    try { return (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } finally { $resp.Close() }
}
function Get-MainPage {
    param($Run)
    $devPort = [int](@(Get-Content -LiteralPath (Join-Path $Run.Profile 'DevToolsActivePort'))[0])
    # Assigned first: ConvertFrom-Json hands an array over as one object.
    $list = ConvertFrom-Json -InputObject (Invoke-DevToolsHttp -DevPort $devPort -Path '/json/list')
    $page = @($list | Where-Object { $_.type -eq 'page' -and $_.url -notlike 'devtools://*' })[0]
    return [pscustomobject]@{ Port = $devPort; Id = $page.id; Url = [string]$page.url }
}
function Invoke-TestCdp {
    param([int]$DevPort, [string]$TargetId, [string]$Method, [hashtable]$Params = @{})
    $ws = New-Object Net.WebSockets.ClientWebSocket
    try {
        if (-not $ws.ConnectAsync([Uri]"ws://127.0.0.1:$DevPort/devtools/page/$TargetId", [Threading.CancellationToken]::None).Wait(5000)) { throw 'connect timed out' }
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{ id = 1; method = $Method; params = $Params } -Compress -Depth 5))
        if (-not $ws.SendAsync([ArraySegment[byte]]::new($bytes), 'Text', $true, [Threading.CancellationToken]::None).Wait(5000)) { throw 'send timed out' }
        $buf = New-Object byte[] 262144
        while ($true) {
            $ms = New-Object IO.MemoryStream
            do {
                $t = $ws.ReceiveAsync([ArraySegment[byte]]::new($buf), [Threading.CancellationToken]::None)
                if (-not $t.Wait(10000)) { throw 'receive timed out' }
                $ms.Write($buf, 0, $t.Result.Count)
            } while (-not $t.Result.EndOfMessage)
            $msg = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($ms.ToArray()))
            if ($msg.PSObject.Properties['id'] -and $msg.id -eq 1) { return $msg.result }
        }
    }
    finally { $ws.Dispose() }
}

# --- a launcher run in a screen folder ------------------------------------------
function New-Run {
    param([string]$Name, [string]$Screen = 'S2', [System.Collections.IDictionary]$Settings = @{})
    $root = Join-Path $WorkRoot $Name
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    $dir = Join-Path $root $Screen
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -LiteralPath $Launcher -Destination (Join-Path $root 'WebLauncher.ps1')
    $cfg = [ordered]@{ DisplayURL = "$Base/site"; HealthCheckSeconds = '2'; DisplayWaitSeconds = '0'; DebugLogging = '1'; ProfileDir = (Join-Path $root 'Profile') }
    foreach ($k in $Settings.Keys) { $cfg[$k] = $Settings[$k] }
    [IO.File]::WriteAllText((Join-Path $dir "$HostName.json"), (ConvertTo-Json -InputObject ([pscustomobject]$cfg)), $Utf8)
    return [pscustomobject]@{ Root = $root; Dir = $dir; Screen = $Screen; Profile = (Join-Path $root 'Profile'); Process = $null }
}
function Start-Run {
    param($Run)
    $Run.Process = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Run.Root 'stderr.txt') -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Run.Root 'WebLauncher.ps1')), '-Instance', $Run.Screen, '-Headless', '-ExitAfterSeconds', '600')
    $null = $Run.Process.Handle
}
function Stop-Run {
    param($Run)
    if ($Run.Process -and -not $Run.Process.HasExited) {
        New-Item -ItemType File -Path (Join-Path $Run.Dir 'kill.txt') -Force | Out-Null
        if (-not $Run.Process.WaitForExit(30000)) { Test-Check 'launcher stops on kill.txt' $false 'had to be killed'; Stop-Process -Id $Run.Process.Id -Force }
    }
    $pattern = [regex]::Escape($Run.Profile)
    Get-CimInstance Win32_Process -Filter "Name = 'msedge.exe'" | Where-Object { $_.CommandLine -match $pattern } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
function Get-Status {
    param($Run)
    $p = Join-Path $Run.Dir "Status\$($Run.Screen).status.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (ConvertFrom-Json -InputObject (Read-SharedFile $p)) } catch { return $null }
}
function Wait-State { param($Run, [string]$State, [int]$TimeoutSec = 60) return (Wait-Until -TimeoutSec $TimeoutSec -Condition { (Get-Status $Run).State -eq $State }) }
function Get-LogText {
    param($Run)
    return ((@(Get-ChildItem -LiteralPath $Run.Dir -Recurse -Filter '*.log' -File -ErrorAction SilentlyContinue) | ForEach-Object { Read-SharedFile $_.FullName }) -join "`n")
}

# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null

Write-Host "`n== Built from PBI Launcher" -ForegroundColor Cyan
$built = Join-Path $WorkRoot 'WebLauncher.built.ps1'
$null = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ProjectDir 'Tools\Build-WebLauncher.ps1') -Destination $built 2>&1
Test-Check 'the build runs and its result parses' ((Test-Path $built) -and $LASTEXITCODE -eq 0)
Test-Check 'WebLauncher.ps1 is what the build makes of today''s PbiLauncher.ps1 (rebuild after changing it)' ((Test-Path $built) -and (Get-FileHash $built).Hash -eq (Get-FileHash $Launcher).Hash)
$text = [IO.File]::ReadAllText($Launcher)
Test-Check 'no sign-in or password code left' ($text -notmatch 'function (Invoke-LoginStep|Import-PasswordSeed|Invoke-SetPassword)' -and $text -notmatch 'password\.seed')

Write-Host "`n== The URL rule (TargetMatch)" -ForegroundColor Cyan
$ast = [Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$null, [ref]$null)
$fn = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Test-IsTargetUrl' }, $true) | Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
$cases = @(
    @('http://a/board', 'http://a/board', 'path', $true), @('http://a/board/day?x=1', 'http://a/board', 'path', $true), @('http://a/boards', 'http://a/board', 'path', $false)
    @('http://a/other', 'http://a/board', 'path', $false), @('http://b/board', 'http://a/board', 'path', $false), @('http://a/anything', 'http://a/', 'path', $true)
    @('http://a/other', 'http://a/board', 'host', $true), @('http://a/board?x=2', 'http://a/board?x=1', 'exact', $false), @('http://a/board/', 'http://a/board', 'exact', $true)
)
$bad = @($cases | Where-Object { (Test-IsTargetUrl -Current $_[0] -Target $_[1] -Match $_[2]) -ne $_[3] } | ForEach-Object { "$($_[0]) vs $($_[1]) ($($_[2]))" })
Test-Check "all $($cases.Count) cases" ($bad.Count -eq 0) ($bad -join '; ')

Write-Host "`n== Deploy-WebLauncher.ps1 on fake kiosks" -ForegroundColor Cyan
$Deploy = Join-Path $ProjectDir 'Deploy-WebLauncher.ps1'
$Fake = Join-Path $WorkRoot 'kiosks'
$Template = Join-Path $Fake '{0}'
$Reports = Join-Path $WorkRoot 'reports'
$StartupRel = 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
function New-FakeKiosk {
    param([string]$Name, [string[]]$WebScreens = @(), [string]$OldMach2Screen, [string]$NgScreen)
    $c = Join-Path $Fake $Name
    $pub = Join-Path $c 'Users\Public\Documents'
    New-Item -ItemType Directory -Path (Join-Path $c "Users\$Name\$StartupRel") -Force | Out-Null
    New-Item -ItemType Directory -Path $pub -Force | Out-Null
    foreach ($s in $WebScreens) {
        New-Item -ItemType Directory -Path (Join-Path $pub "WebLauncher\$s") -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $pub "WebLauncher\$s\$Name.json"), '{ "DisplayURL": "https://intranet.example.com/board" }', $Utf8)
    }
    if ($OldMach2Screen) {
        $d = Join-Path $pub "Mach2Launchers\Launcher $OldMach2Screen"
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $d 'Mach2Launcher.exe') -Value 'fake'
        [IO.File]::WriteAllText((Join-Path $d "$Name.json"), '[{ "DisplayURL": "http://station/dashboard" }]', $Utf8)
        $sl = Join-Path $pub 'Mach2Launchers\StartupLauncher'
        New-Item -ItemType Directory -Path $sl -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sl 'StartupLauncher.exe') -Value 'fake'
        [IO.File]::WriteAllText((Join-Path $sl "$Name.json"), ('[{ "LauncherPath1": "C:\\Users\\Public\\Documents\\Mach2Launchers\\Launcher ' + $OldMach2Screen + '", "LauncherName1": "Mach2Launcher.exe" }]'), $Utf8)
    }
    if ($NgScreen) {
        New-Item -ItemType Directory -Path (Join-Path $pub "Mach2LauncherNG\$NgScreen") -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $pub "Mach2LauncherNG\$NgScreen\$Name.json"), '{ "DisplayURL": "http://station/dashboard" }', $Utf8)
    }
}
function Invoke-Deploy {
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Deploy @Arguments -RootTemplate $Template -ReportDir $Reports 2>&1
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = (($out | ForEach-Object { "$_" }) -join "`n") }
}
function Get-LatestReport { @(Import-Csv -LiteralPath (Get-ChildItem -LiteralPath $Reports -Filter 'web-deploy_*.csv' | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName) }
function Get-TreeFingerprint { param([string]$Path) ((Get-ChildItem -LiteralPath $Path -Recurse -File | Sort-Object FullName | ForEach-Object { '{0}|{1}' -f $_.FullName, $_.Length }) -join "`n") }

New-FakeKiosk WK1 -WebScreens S2 -OldMach2Screen S2
New-FakeKiosk WK2
New-FakeKiosk WK3 -WebScreens S1 -NgScreen S1
$wk1 = Join-Path $Fake 'WK1'
$wk1Old = Join-Path $wk1 'Users\Public\Documents\Mach2Launchers\Launcher S2\WK1.json'
$wk1Sl = Join-Path $wk1 'Users\Public\Documents\Mach2Launchers\StartupLauncher\WK1.json'
$wk1Startup = Join-Path $wk1 "Users\WK1\$StartupRel"

$before = Get-TreeFingerprint $Fake
$r = Invoke-Deploy @('-Hosts', 'WK1', '-WhatIf')
Test-Check 'WhatIf changes nothing' ((Get-TreeFingerprint $Fake) -eq $before)
$r = Invoke-Deploy @('-Hosts', 'WK1,WK2,WK3')
$by = @{}; foreach ($row in (Get-LatestReport)) { $by[$row.Host] = $row }
Test-Check 'WK1: INSTALLED on its configured screen S2' ($by['WK1'].Result -eq 'INSTALLED' -and $by['WK1'].Instances -eq 'S2' -and (Test-Path (Join-Path $wk1 'Users\Public\Documents\WebLauncher\WebLauncher.ps1'))) "$($by['WK1'].Result) $($by['WK1'].Instances) $($by['WK1'].Detail)"
$l = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $wk1Startup 'Web Launcher S2.lnk'))
Test-Check 'WK1: startup shortcut conhost > hidden PowerShell > WebLauncher -Instance S2' ($l.TargetPath -ieq 'C:\Windows\System32\conhost.exe' -and $l.Arguments -like '*-File "C:\Users\Public\Documents\WebLauncher\WebLauncher.ps1" -Instance S2') $l.Arguments
Test-Check 'WK1: the old Mach2 launcher on S2 retired - its config and StartupLauncher''s renamed' (-not (Test-Path $wk1Old) -and (Test-Path "$wk1Old.disabled-by-WebLauncher") -and -not (Test-Path $wk1Sl) -and $by['WK1'].Legacy -eq 'JSON renamed 2') $by['WK1'].Legacy
Test-Check 'WK2: NO_CONFIG (nothing to show)' ($by['WK2'].Result -eq 'NO_CONFIG') $by['WK2'].Result
Test-Check 'WK3: S1 belongs to Mach2 Launcher NG - NO_CONFIG, and says why' ($by['WK3'].Result -eq 'NO_CONFIG' -and $by['WK3'].Detail -like '*S1 belongs to Mach2 Launcher NG*') "$($by['WK3'].Result) $($by['WK3'].Detail)"
$null = Invoke-Deploy @('-Hosts', 'WK1', '-Command', 'Refresh', '-Instance', 'S2')
Test-Check '-Command Refresh -Instance S2' (Test-Path (Join-Path $wk1 'Users\Public\Documents\WebLauncher\S2\refresh.txt'))
$r = Invoke-Deploy @('-Hosts', 'WK1', '-Rollback')
$row = @(Get-LatestReport)[0]
Test-Check 'rollback: shortcut gone, old configs back, launcher told to stop' ($row.Result -eq 'ROLLED_BACK' -and -not (Test-Path (Join-Path $wk1Startup 'Web Launcher S2.lnk')) -and (Test-Path $wk1Old) -and (Test-Path $wk1Sl) -and (Test-Path (Join-Path $wk1 'Users\Public\Documents\WebLauncher\S2\kill.txt'))) "$($row.Result) $($row.Legacy) $($row.Detail)"
$r = Invoke-Deploy @('-Hosts', 'WK1', '-Instance', 'S1')
Test-Check 'refuses -Instance without -Command' ($r.Code -ne 0 -and $r.Text -match 'Instance goes with -Command')

$script:EventsFile = Join-Path $WorkRoot 'events.jsonl'
$pwFile = Join-Path $WorkRoot 'pw.txt'
[IO.File]::WriteAllText($pwFile, 'unused', $Utf8)
$server = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $here 'FixtureServer.ps1')), '-Port', $Port, '-EventsFile', ('"{0}"' -f $script:EventsFile), '-PasswordFile', ('"{0}"' -f $pwFile))
try {
    if (-not (Wait-Until -TimeoutSec 20 -Condition { (Invoke-Http '/control?reset=1') -eq 'ok' })) { throw 'The fixture server did not start.' }

    Write-Host "`n== On screen S2: shows the page, stays on it, follows links" -ForegroundColor Cyan
    $run = New-Run -Name 'Main' -Screen 'S2' -Settings @{ ReturnAfterSeconds = '10'; ErrorChecksBeforeReload = '2' }
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        Test-Check 'status SHOWING' (Wait-State $run 'SHOWING' 60) "$((Get-Status $run).State) $((Get-Status $run).Detail)"
        $st = Get-Status $run
        Test-Check 'status file in S2\Status, as Web Launcher on screen S2' ($st.Launcher -eq 'WEB' -and $st.Screen -eq 'S2' -and $st.Instance -eq 'S2' -and $st.Title -eq 'Board') "$($st.Launcher) $($st.Screen) $($st.Title)"
        Test-Check 'its own log name for a second screen' (Test-Path (Join-Path $run.Dir "Logs\WebLauncher_${HostName}_S2.log"))
        Test-Check 'no sign-in was tried' (@(Get-FixtureEvents -SinceUtc $t0 -Name 'login-page').Count -eq 0 -and @(Get-FixtureEvents -SinceUtc $t0 -Name 'user').Count -eq 0)

        $page = Get-MainPage $run
        $null = Invoke-TestCdp -DevPort $page.Port -TargetId $page.Id -Method 'Page.navigate' -Params @{ url = "$Base/site/page2" }
        Start-Sleep -Seconds 8
        Test-Check 'a page under the configured path is still the page (TargetMatch path)' ((Get-Status $run).State -eq 'SHOWING' -and (Get-MainPage $run).Url -like '*/site/page2') "$((Get-Status $run).State) $((Get-MainPage $run).Url)"

        $null = Invoke-TestCdp -DevPort $page.Port -TargetId $page.Id -Method 'Page.navigate' -Params @{ url = "$Base/linked?kind=out" }
        Test-Check 'a page elsewhere, after the page was up: BROWSING' (Wait-State $run 'BROWSING' 15) "$((Get-Status $run).State) $((Get-Status $run).Detail)"
        Test-Check '...with a Back button on it' (Wait-Until -TimeoutSec 10 -Condition { [bool](Invoke-TestCdp -DevPort $page.Port -TargetId $page.Id -Method 'Runtime.evaluate' -Params @{ expression = "!!document.getElementById('pbil-back')"; returnByValue = $true }).result.value })
        Test-Check '...and back on the page by itself after ReturnAfterSeconds unused' (Wait-Until -TimeoutSec 40 -Condition { (Get-MainPage $run).Url -like "$Base/site*" -and (Get-Status $run).State -eq 'SHOWING' }) "$((Get-MainPage $run).Url) $((Get-Status $run).State)"

        $null = Invoke-Http '/control?siteerror=1'
        $t1 = [DateTime]::UtcNow
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        Test-Check 'refresh.txt reloads the page' (Wait-Until -TimeoutSec 15 -Condition { @(Get-FixtureEvents -SinceUtc $t1 -Name 'site').Count -ge 1 -and -not (Test-Path (Join-Path $run.Dir 'refresh.txt')) })
        Test-Check 'error text on the page: RECOVERING, and reloaded' (Wait-Until -TimeoutSec 40 -Condition { (Get-LogText $run) -match "Reloading the page \(the page shows 'HTTP ERROR'" }) "$((Get-Status $run).State) $((Get-Status $run).Detail)"
        $null = Invoke-Http '/control?reset=1'
        Test-Check '...and SHOWING again once the site is fine' (Wait-State $run 'SHOWING' 90) "$((Get-Status $run).State) $((Get-Status $run).Detail)"

        New-Item -ItemType File -Path (Join-Path $run.Dir 'hold.txt') -Force | Out-Null
        Test-Check 'hold.txt: HOLD' (Wait-State $run 'HOLD' 15)
        Remove-Item (Join-Path $run.Dir 'hold.txt')
        Test-Check '...and back to SHOWING without it' (Wait-State $run 'SHOWING' 20)
        $err = if (Test-Path (Join-Path $run.Root 'stderr.txt')) { (Read-SharedFile (Join-Path $run.Root 'stderr.txt')).Trim() } else { '' }
        Test-Check 'nothing written to stderr' ($err -eq '') $err
    }
    finally { Stop-Run $run }
    Test-Check 'kill.txt: STOPPED' ((Get-Status $run).State -eq 'STOPPED') (Get-Status $run).State

    Write-Host "`n== A page that shows nothing" -ForegroundColor Cyan
    $null = Invoke-Http '/control?siteblank=1'
    $run = New-Run -Name 'Blank' -Screen 'S1' -Settings @{ BlankReloadSeconds = '8' }
    Start-Run $run
    try {
        Test-Check 'LOADING, then reloaded after BlankReloadSeconds' (Wait-Until -TimeoutSec 60 -Condition { (Get-LogText $run) -match 'the page has shown nothing for' }) "$((Get-Status $run).State) $((Get-Status $run).Detail)"
        Test-Check 'the first screen keeps the plain log name' (Test-Path (Join-Path $run.Dir "Logs\WebLauncher_$HostName.log"))
    }
    finally { Stop-Run $run; $null = Invoke-Http '/control?reset=1' }
}
finally {
    try { $null = Invoke-Http '/stop' } catch {}
    Start-Sleep -Seconds 1
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force }
}

$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("{0} checks, {1} failed." -f $script:Results.Count, $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
foreach ($f in $failed) { Write-Host ("  FAIL {0} {1}" -f $f.Check, $f.Detail) -ForegroundColor Red }
if (-not $KeepWorkRoot -and $failed.Count -eq 0) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue }
exit $failed.Count
