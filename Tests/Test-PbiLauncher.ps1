#Requires -Version 5.1
<#
.SYNOPSIS
    Tests PbiLauncher.ps1: unit checks on its helpers, then end-to-end runs
    against FixtureServer.ps1 with a headless Edge.

.DESCRIPTION
    Nothing here touches a real tenant or the kiosk fleet. Each scenario
    gets its own folder and Edge profile under -WorkRoot; the launcher only
    ever closes Edge processes that use its own profile, so an Edge you have
    open is left alone.

    Takes about fifteen minutes.

.EXAMPLE
    .\Tests\Test-PbiLauncher.ps1

.EXAMPLE
    .\Tests\Test-PbiLauncher.ps1 -Only Unit, WrongPassword
#>
[CmdletBinding()]
param(
    [string]$Launcher = (Join-Path $PSScriptRoot '..\PbiLauncher\PbiLauncher.ps1'),
    [string]$WorkRoot = (Join-Path $env:TEMP 'PbiLauncherTests'),
    [int]$Port = 18765,
    [ValidateSet('Unit', 'Main', 'Links', 'ChromelessApp', 'Account', 'KeptProfile', 'WrongPassword', 'PickerAndLegacyPassword', 'Mfa', 'EdgeErrorPage', 'Refused', 'ScreenFolder', 'Unsupervised', 'MissingScreen', 'Disabled')]
    [string[]]$Only,
    [switch]$KeepWorkRoot
)

$ErrorActionPreference = 'Stop'
$Launcher = (Resolve-Path -LiteralPath $Launcher).ProviderPath
$User = 'pbi.kiosk@contoso.test'
# Quotes, an ampersand, angle brackets and a non-ASCII letter: everything
# that could go wrong between the seed file, JSON, DevTools and the page.
$Password = 'Kiosk&Pass"w0rd <' + [char]0x17E + '>'
$Base = "http://127.0.0.1:$Port"

$script:Results = New-Object System.Collections.Generic.List[object]

function Test-Check {
    param([Parameter(Mandatory)][string]$Scenario, [Parameter(Mandatory)][string]$Name, [bool]$Pass, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Scenario = $Scenario; Check = $Name; Pass = $Pass; Detail = $Detail })
    $mark = if ($Pass) { 'PASS' } else { 'FAIL' }
    $color = if ($Pass) { 'Green' } else { 'Red' }
    $suffix = if ($Detail) { "  ($Detail)" } else { '' }
    Write-Host ("  [{0}] {1}{2}" -f $mark, $Name, $suffix) -ForegroundColor $color
}

function Invoke-Http {
    param([string]$PathAndQuery)
    $wc = New-Object Net.WebClient
    $wc.Proxy = $null
    try { return $wc.DownloadString("$Base$PathAndQuery") } finally { $wc.Dispose() }
}

function Get-FixtureEvents {
    param([DateTime]$SinceUtc = [DateTime]::MinValue, [string]$Name)
    if (-not (Test-Path -LiteralPath $script:EventsFile)) { return @() }
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($script:EventsFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try { $text = (New-Object IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
    $out = foreach ($line in ($text -split "`n")) {
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

function Get-LauncherStatus {
    param($Run)
    $p = Join-Path $Run.Dir "Status\$($Run.Instance).status.json"
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($p))) } catch { return $null }
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
        [switch]$LegacyArray,
        [string]$Seed
    )
    $dir = Join-Path $WorkRoot $Name
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -LiteralPath $Launcher -Destination (Join-Path $dir 'PbiLauncher.ps1')

    $cfg = [ordered]@{}
    foreach ($k in $Settings.Keys) { $cfg[$k] = $Settings[$k] }
    $cfg['Instance'] = $Name
    $cfg['ProfileDir'] = Join-Path $dir 'Profile'
    $cfg['LoginHosts'] = '127.0.0.2'
    $cfg['ReportHosts'] = '127.0.0.1'
    $cfg['TestAllowHttpLogin'] = '1'
    $cfg['DisplayWaitSeconds'] = '0'
    if (-not $cfg.Contains('HealthCheckSeconds')) { $cfg['HealthCheckSeconds'] = '2' }
    if (-not $cfg.Contains('DebugLogging')) { $cfg['DebugLogging'] = '1' }

    $obj = if ($LegacyArray) { , @([pscustomobject]$cfg) } else { [pscustomobject]$cfg }
    $configPath = Join-Path $dir "$env:COMPUTERNAME.json"
    [IO.File]::WriteAllText($configPath, (ConvertTo-Json -InputObject $obj -Depth 5), (New-Object Text.UTF8Encoding($false)))

    if ($PSBoundParameters.ContainsKey('Seed')) {
        [IO.File]::WriteAllText((Join-Path $dir 'password.seed'), $Seed, (New-Object Text.UTF8Encoding($false)))
    }

    return [pscustomobject]@{
        Name = $Name; Instance = $Name; Dir = $dir; Config = $configPath; Profile = (Join-Path $dir 'Profile')
        Cred = (Join-Path $dir "$env:COMPUTERNAME.cred"); Process = $null
        Log = (Join-Path $dir "Logs\$(if ($cfg.Contains('LogName')) { $cfg['LogName'] } else { "PbiLauncher_$($env:COMPUTERNAME.ToUpperInvariant()).log" })")
    }
}

function Start-Run {
    param($Run)
    $script:Stderr = Join-Path $Run.Dir 'stderr.txt'
    $Run.Process = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardError $script:Stderr -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $Run.Dir 'PbiLauncher.ps1')),
        '-Headless', '-ExitAfterSeconds', '900')
    # Read the handle now: Windows PowerShell only reports ExitCode for a
    # Start-Process process whose handle was opened while it ran.
    $null = $Run.Process.Handle
}

function Stop-Run {
    param($Run, [string]$Scenario)
    if (-not $Run.Process) { return }
    if (-not $Run.Process.HasExited) {
        New-Item -ItemType File -Path (Join-Path $Run.Dir 'kill.txt') -Force | Out-Null
        if (-not $Run.Process.WaitForExit(30000)) {
            Test-Check $Scenario 'launcher stops on kill.txt' $false 'had to be killed'
            Stop-Process -Id $Run.Process.Id -Force
        }
    }
    foreach ($p in Get-ProfileEdge $Run.Profile) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Get-LogText {
    param($Run)
    $files = @(Get-ChildItem -LiteralPath $Run.Dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.log', '.lo_') })
    $parts = foreach ($f in $files) { Read-SharedFile $f.FullName }
    return ($parts -join "`n")
}

function Read-SharedFile {
    param([string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try { return (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8)).ReadToEnd() } finally { $fs.Dispose() }
}

function Test-NoPasswordLeak {
    param($Run, [string]$Scenario)
    $files = @(Get-ChildItem -LiteralPath $Run.Dir -Recurse -File | Where-Object { $_.FullName -notlike "$($Run.Profile)*" })
    $leaks = @($files | Where-Object { (Read-SharedFile $_.FullName).Contains($Password) } | ForEach-Object { $_.Name })
    Test-Check $Scenario 'password appears in no launcher file (logs, status, cred)' ($leaks.Count -eq 0) ($leaks -join ', ')
}

# --- A small DevTools client, to click in the launcher's Edge like a person --
function Get-DevToolsPort {
    param($Run)
    return [int](@(Get-Content -LiteralPath (Join-Path $Run.Profile 'DevToolsActivePort'))[0])
}

function Invoke-DevToolsHttp {
    param([int]$Port, [string]$Path, [string]$Method = 'GET')
    $r = [Net.WebRequest]::Create("http://127.0.0.1:$Port$Path")
    $r.Method = $Method; $r.Proxy = $null
    if ($Method -ne 'GET') { $r.ContentLength = 0 }
    $resp = $r.GetResponse()
    try { return (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } finally { $resp.Close() }
}

function Get-TestPages {
    param([int]$Port)
    $parsed = ConvertFrom-Json -InputObject (Invoke-DevToolsHttp -Port $Port -Path '/json/list')
    return @(@($parsed) | Where-Object { $_.type -eq 'page' })
}

function Invoke-TestCdp {
    param([int]$Port, [string]$TargetId, [string]$Method, [hashtable]$Params = @{})
    $ws = New-Object Net.WebSockets.ClientWebSocket
    try {
        if (-not $ws.ConnectAsync([Uri]"ws://127.0.0.1:$Port/devtools/page/$TargetId", [Threading.CancellationToken]::None).Wait(5000)) { throw 'connect timed out' }
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

function Invoke-TestJs {
    param([int]$Port, [string]$TargetId, [string]$Expression)
    $r = Invoke-TestCdp -Port $Port -TargetId $TargetId -Method 'Runtime.evaluate' -Params @{ expression = "JSON.stringify($Expression)"; returnByValue = $true }
    if (-not $r.result.PSObject.Properties['value'] -or $null -eq $r.result.value) { return $null }
    return (ConvertFrom-Json -InputObject $r.result.value)
}

function Send-TestClick {
    # $Element: a JS expression that yields the element.
    param([int]$Port, [string]$TargetId, [string]$Element)
    $rect = Invoke-TestJs -Port $Port -TargetId $TargetId -Expression "(function () { var el = $Element; if (!el) return null; el.scrollIntoView({ block: 'center' }); var r = el.getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 }; })()"
    if (-not $rect) { return $false }
    foreach ($type in 'mouseMoved', 'mousePressed', 'mouseReleased') {
        $p = @{ type = $type; x = [double]$rect.x; y = [double]$rect.y }
        if ($type -ne 'mouseMoved') { $p.button = 'left'; $p.clickCount = 1 }
        $null = Invoke-TestCdp -Port $Port -TargetId $TargetId -Method 'Input.dispatchMouseEvent' -Params $p
    }
    return $true
}

$BackButtonElement = "(function () { var h = document.getElementById('pbil-back'); return h && h.shadowRoot ? h.shadowRoot.querySelector('button') : null; })()"

# ---------------------------------------------------------------------------
# Unit checks - the launcher's helper functions, loaded without running it
# ---------------------------------------------------------------------------
function Invoke-UnitTests {
    $sc = 'Unit'
    Write-Host "`n== $sc" -ForegroundColor Cyan

    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($Launcher, [ref]$tokens, [ref]$errors)
    Test-Check $sc 'launcher parses' ($errors.Count -eq 0) (($errors | ForEach-Object { $_.Message }) -join '; ')

    $wanted = 'Get-ConfigValue', 'ConvertTo-Flag', 'ConvertTo-Number', 'ConvertTo-StringList', 'ConvertTo-TimesOfDay',
    'Get-EffectiveUrl', 'Read-LauncherConfig', 'Test-IsTargetUrl', 'ConvertTo-ArgumentString', 'Test-DailyDue', 'ConvertTo-JsLiteral',
    'Write-JsonFile', 'Save-SignInPassword', 'Read-SignInPassword', 'Invoke-SetPassword'
    $defs = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $wanted }, $true)
    foreach ($d in $defs) { . ([scriptblock]::Create($d.Extent.Text)) }
    $phrases = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$DefaultErrorPhrases' }, $false) | Select-Object -First 1
    . ([scriptblock]::Create($phrases.Extent.Text))
    $Here = Join-Path $WorkRoot 'unit'
    $ComputerName = $env:COMPUTERNAME.ToUpperInvariant()
    $Invariant = [Globalization.CultureInfo]::InvariantCulture
    Add-Type -AssemblyName System.Web
    New-Item -ItemType Directory -Path $Here -Force | Out-Null

    # Test-IsTargetUrl
    $app = 'https://app.powerbi.com/groups/me/apps/11111111-2222-3333-4444-555555555555/reports/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/f697b112e6aa1d830b4e?experience=power-bi'
    Test-Check $sc 'same report, other page and query = on target' (Test-IsTargetUrl -Current 'https://app.powerbi.com/groups/me/apps/11111111-2222-3333-4444-555555555555/reports/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/ReportSection2?ctid=x&experience=power-bi' -Target $app)
    Test-Check $sc 'other report = off target' (-not (Test-IsTargetUrl -Current 'https://app.powerbi.com/groups/me/apps/11111111-2222-3333-4444-555555555555/reports/99999999-bbbb-cccc-dddd-eeeeeeeeeeee/f697b112e6aa1d830b4e' -Target $app))
    Test-Check $sc 'Power BI home = off target' (-not (Test-IsTargetUrl -Current 'https://app.powerbi.com/home?experience=power-bi' -Target $app))
    Test-Check $sc 'sign-in host = off target' (-not (Test-IsTargetUrl -Current 'https://login.microsoftonline.com/common/oauth2/authorize?x=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -Target $app))
    $embed = 'https://app.powerbi.com/reportEmbed?reportId=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee&autoAuth=true&ctid=t'
    Test-Check $sc 'reportEmbed, same reportId = on target' (Test-IsTargetUrl -Current 'https://app.powerbi.com/reportEmbed?autoAuth=true&reportId=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' -Target $embed)
    Test-Check $sc 'reportEmbed, other reportId = off target' (-not (Test-IsTargetUrl -Current 'https://app.powerbi.com/reportEmbed?reportId=bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee' -Target $embed))
    Test-Check $sc 'report ID matched case-insensitively' (Test-IsTargetUrl -Current ($app.ToUpperInvariant() -replace 'HTTPS://APP.POWERBI.COM', 'https://app.powerbi.com') -Target $app)

    # Get-EffectiveUrl
    Test-Check $sc 'chromeless appended before the fragment' ((Get-EffectiveUrl -Url 'https://x.test/r?a=1#p' -Mode 'chromeless') -eq 'https://x.test/r?a=1&chromeless=1#p')
    Test-Check $sc 'chromeless not doubled' ((Get-EffectiveUrl -Url 'https://x.test/r?chromeless=1' -Mode 'chromeless') -eq 'https://x.test/r?chromeless=1')
    Test-Check $sc 'click mode leaves the URL alone' ((Get-EffectiveUrl -Url 'https://x.test/r' -Mode 'click') -eq 'https://x.test/r')

    # ConvertTo-ArgumentString
    $s = ConvertTo-ArgumentString -Arguments @('--user-data-dir="C:\A B\P"', '--app="https://x.test/r?a=1&b=2"', '--kiosk', '--x=C:\no space', 'plain')
    Test-Check $sc 'argument quoting' ($s -eq '--user-data-dir="C:\A B\P" --app="https://x.test/r?a=1&b=2" --kiosk --x="C:\no space" plain') $s

    # ConvertTo-JsLiteral keeps a one-item array an array
    Test-Check $sc 'one-item array stays a JS array' ((ConvertTo-JsLiteral @('View')) -eq '["View"]') (ConvertTo-JsLiteral @('View'))

    # Read-LauncherConfig with a file in the old launcher's exact shape
    $legacy = @'
[
 {
   "JsonVer": "1.0.0.3",
   "LoginURL": "https://app.powerbi.com/singleSignOn?",
   "DisplayURL": "https://app.powerbi.com/groups/me/apps/11111111-2222-3333-4444-555555555555/reports/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/f697b112e6aa1d830b4e?experience=power-bi",
   "ZoomPercent": "125",
   "ZoomDelay": "500",
   "UsePriScreen": "0",
   "ScreenSelect": "2",
   "KioskMode": "1",
   "ElementTimeout": "30",
   "ForcedRefreshTime": "07:55",
   "EnableRefresh": "1",
   "BrowserRefreshDelay": "15",
   "UsernameFieldID": "email",
   "UserName": "SHPowerBIKiosk@contoso.test",
   "UpdateEdgeDriver": "1",
   "EdgeDriverSharePath": "\\\\server\\MSEdgeDriver",
   "LogPath": "",
   "RemoteLogPath": "\\\\server\\MISCLaunchersLogs",
   "LogName": "PowerBI_HOST-ROLL007_APU1.log",
   "LogDelay": "0",
   "TempCleanup": "1",
   "KillEdgeDriver": "1",
   "PasswordFieldID": "passwd",
   "Password": "not-a-real-password",
   "SubmitBtnID": "idSIButton9",
   "StartupDelay": "5",
   "DisableStartup": "0",
   "DebugLogging": "0",
   "ScheduledRestartEnabled": "1",
   "ScheduledRestartTime": "6:00",
   "RestartDelay": "30",
   "StaySignedIn": "1"
 }
]
'@
    $lp = Join-Path $Here 'legacy.json'
    [IO.File]::WriteAllText($lp, $legacy)
    $c = Read-LauncherConfig -Path $lp
    Test-Check $sc 'legacy: interval refresh 15 min' ($c.RefreshMinutes -eq 15) $c.RefreshMinutes
    Test-Check $sc 'legacy: forced refresh 07:55' ((@($c.RefreshTimes).Count -eq 1) -and ($c.RefreshTimes[0] -eq [TimeSpan]'07:55'))
    Test-Check $sc 'legacy: scheduled restart 06:00' ($c.RestartTime -eq [TimeSpan]'06:00')
    Test-Check $sc 'legacy: screen 2, not primary, full screen window' ($c.ScreenNumber -eq 2 -and -not $c.UsePrimaryScreen -and $c.FullScreenWindow)
    Test-Check $sc 'legacy: zoom 125' ($c.ZoomPercent -eq 125)
    Test-Check $sc 'legacy: user, password, stay signed in' ($c.UserName -eq 'SHPowerBIKiosk@contoso.test' -and $c.LegacyPassword -eq 'not-a-real-password' -and $c.StaySignedIn)
    Test-Check $sc 'legacy: logs to the same central file' ($c.RemoteLogDir -eq '\\server\MISCLaunchersLogs' -and $c.LogName -eq 'PowerBI_HOST-ROLL007_APU1.log')
    Test-Check $sc 'legacy: startup delay 5 s, not disabled' ($c.StartupDelaySeconds -eq 5 -and -not $c.Disabled)
    Test-Check $sc 'legacy: default full screen by View menu' ($c.ReportFullScreen -eq 'click' -and $c.EffectiveUrl -eq $c.DisplayUrl)
    Test-Check $sc 'legacy: no problems reported' ($c.Problems.Count -eq 0) ($c.Problems -join '; ')

    $bad = Join-Path $Here 'bad.json'
    [IO.File]::WriteAllText($bad, '{ "DisplayURL": "not a url" }')
    $threw = $false
    try { $null = Read-LauncherConfig -Path $bad } catch { $threw = $_.Exception.Message -like '*not a web address*' }
    Test-Check $sc 'a bad DisplayURL is refused' $threw

    [IO.File]::WriteAllText($bad, '{ "DisplayURL": "https://x.test/", "RefreshTimes": "7:5x, 25:00, 14:30", "FullScreen": "maybe" }')
    $c = Read-LauncherConfig -Path $bad
    Test-Check $sc 'bad times and modes are reported, good ones kept' ($c.Problems.Count -eq 3 -and @($c.RefreshTimes).Count -eq 1 -and $c.ReportFullScreen -eq 'click') ($c.Problems -join ' | ')

    # -SetPassword, with Read-Host answered by the test
    Add-Type -AssemblyName System.Security
    $PasswordEntropy = [Text.Encoding]::UTF8.GetBytes('PbiLauncher.SignIn.v2')
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $script:Answers = New-Object System.Collections.Queue
    function Read-Host { param([string]$Prompt, [switch]$AsSecureString) ConvertTo-SecureString $script:Answers.Dequeue() -AsPlainText -Force }
    $credFile = Join-Path $Here 'set.cred'
    $cfgObj = [pscustomobject]@{ UserName = $User; CredentialFile = $credFile }
    $script:Answers.Enqueue($Password); $script:Answers.Enqueue($Password)
    $code = Invoke-SetPassword -Config $cfgObj *>&1 | Where-Object { $_ -is [int] } | Select-Object -Last 1
    Test-Check $sc '-SetPassword saves a password that decrypts back' ($code -eq 0 -and (Read-SignInPassword -Path $credFile) -ceq $Password)
    Test-Check $sc '-SetPassword file holds no plain text' (-not ([IO.File]::ReadAllText($credFile)).Contains($Password))
    $script:Answers.Enqueue('one'); $script:Answers.Enqueue('two')
    $code = Invoke-SetPassword -Config $cfgObj *>&1 | Where-Object { $_ -is [int] } | Select-Object -Last 1
    Test-Check $sc '-SetPassword refuses two different entries and keeps the old file' ($code -eq 1 -and (Read-SignInPassword -Path $credFile) -ceq $Password)
    Remove-Item Function:\Read-Host

    # Test-DailyDue fires once, within the window only
    $done = @{}
    $now = Get-Date
    $at = $now.TimeOfDay.Add([TimeSpan]::FromMinutes(-2))
    if ($at -lt [TimeSpan]::Zero) { $at = [TimeSpan]::Zero }
    $first = Test-DailyDue -At $at -Tag 't' -Done $done
    $second = Test-DailyDue -At $at -Tag 't' -Done $done
    $later = Test-DailyDue -At ($now.TimeOfDay.Add([TimeSpan]::FromMinutes(-30))) -Tag 'u' -Done $done
    Test-Check $sc 'daily time fires once, not after its window' ($first -and -not $second -and -not $later)
}

# ---------------------------------------------------------------------------
# End-to-end scenarios
# ---------------------------------------------------------------------------
function Wait-State {
    param($Run, [string[]]$State, [int]$TimeoutSec = 60)
    return (Wait-Until -TimeoutSec $TimeoutSec -Condition { $st = Get-LauncherStatus $Run; $st -and $st.State -in $State })
}

function Invoke-MainScenario {
    $sc = 'Main'
    Write-Host "`n== $sc (old-format config, seed file, full flow)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    New-Item -ItemType Directory -Path (Join-Path $WorkRoot 'central-logs') -Force | Out-Null

    $run = New-Run -Name $sc -LegacyArray -Seed $Password -Settings @{
        JsonVer = '1.0.0.3'; LoginURL = 'https://app.powerbi.com/singleSignOn?'; DisplayURL = "$Base/report"
        ZoomPercent = '100'; ZoomDelay = '500'; UsePriScreen = '0'; ScreenSelect = '1'; KioskMode = '1'
        ElementTimeout = '30'; ForcedRefreshTime = '07:55'; EnableRefresh = '0'; BrowserRefreshDelay = '15'
        UsernameFieldID = 'email'; UserName = $User; UpdateEdgeDriver = '1'; EdgeDriverSharePath = '\\nowhere\MSEdgeDriver'
        LogPath = ''; RemoteLogPath = (Join-Path $WorkRoot 'central-logs'); LogName = 'PowerBI_TEST-MAIN.log'; LogDelay = '0'
        TempCleanup = '1'; KillEdgeDriver = '1'; PasswordFieldID = 'passwd'; Password = ''; SubmitBtnID = 'idSIButton9'
        StartupDelay = '0'; DisableStartup = '0'; ScheduledRestartEnabled = '0'; ScheduledRestartTime = '06:00'
        RestartDelay = '30'; StaySignedIn = '1'; BlankReloadSeconds = '10'
    }
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        # 1. first start: sign in, open the report, full screen
        Test-Check $sc 'reaches SHOWING after signing in' (Wait-State $run 'SHOWING' 90) ((Get-LauncherStatus $run).State)
        $ev = Get-FixtureEvents -SinceUtc $t0
        $users = @($ev | Where-Object name -eq 'user')
        $pw = @($ev | Where-Object name -eq 'password')
        Test-Check $sc 'typed the configured user name' ($users.Count -eq 1 -and $users[0].user -eq $User) (($users | ForEach-Object user) -join ',')
        Test-Check $sc 'typed the right password, once' ($pw.Count -eq 1 -and $pw[0].ok) ("{0} attempt(s), length {1}" -f $pw.Count, ($pw | ForEach-Object length))
        Test-Check $sc "answered 'Stay signed in' with Yes" (@($ev | Where-Object { $_.name -eq 'kmsi' -and $_.answer -eq 'yes' }).Count -eq 1)
        Test-Check $sc 'left the decoy password fields on the user-name page alone' (@($ev | Where-Object name -eq 'decoy-filled').Count -eq 0)
        $fs = @($ev | Where-Object name -eq 'fullscreen')
        $view = @($ev | Where-Object name -eq 'view')
        Test-Check $sc 'clicked View > Full screen with real (trusted) clicks' ($fs.Count -ge 1 -and $view.Count -ge 1 -and $fs[0].trusted -eq 'true' -and $view[0].trusted -eq 'true')
        $nav = @($ev | Where-Object name -eq 'hidenav')
        Test-Check $sc "hid the app's navigation pane first, once" ($nav.Count -eq 1 -and $nav[0].trusted -eq 'true') ("{0} click(s)" -f $nav.Count)
        Test-Check $sc 'password.seed consumed' (-not (Test-Path -LiteralPath (Join-Path $run.Dir 'password.seed')))
        Test-Check $sc 'encrypted password file written' (Test-Path -LiteralPath $run.Cred)
        Test-Check $sc 'central log written' (Test-Path -LiteralPath (Join-Path $WorkRoot 'central-logs\PowerBI_TEST-MAIN.log'))
        $st = Get-LauncherStatus $run
        Test-Check $sc 'status file reports the version, Edge and sign-in' ($st.LauncherVersion -eq $(if ([IO.File]::ReadAllText($Launcher) -match "LauncherVersion = '([^']+)'") { $Matches[1] }) -and $st.EdgeVersion -and $st.SignIns -eq 1 -and $st.BrowserStarts -eq 1) ("v{0} {1} signins={2} starts={3}" -f $st.LauncherVersion, $st.EdgeVersion, $st.SignIns, $st.BrowserStarts)
        Test-Check $sc 'status file has the PC start time' ([bool]$st.PcBootUtc) ([string]$st.PcBootUtc)

        # 1b. snapshot.txt: a screenshot and what the page shows
        $snapBase = Join-Path $run.Dir "Status\$($run.Instance)"
        New-Item -ItemType File -Path (Join-Path $run.Dir 'snapshot.txt') -Force | Out-Null
        $script:Snap = $null
        $ok = Wait-Until -TimeoutSec 30 -Condition {
            if (Test-Path -LiteralPath (Join-Path $run.Dir 'snapshot.txt')) { return $false }
            $script:Snap = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText("$snapBase.snapshot.json"))
            return [bool]$script:Snap
        }
        $snap = $script:Snap
        $png = "$snapBase.png"
        $isPng = $false
        if (Test-Path -LiteralPath $png) { $b = [IO.File]::ReadAllBytes($png); $isPng = $b.Length -gt 1000 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47 }
        Test-Check $sc 'snapshot.txt: taken, deleted, and a PNG saved' ($ok -and $snap -and -not $snap.Error -and $isPng -and $snap.Image -eq (Split-Path -Leaf $png)) $(if ($snap) { "error='$($snap.Error)' image='$($snap.Image)'" } else { 'no snapshot.json' })
        Test-Check $sc 'snapshot.json names the page, state and signed-in account' ($snap -and $snap.Url -like '*/report*' -and @($snap.Accounts) -contains $User -and $snap.State -eq 'SHOWING' -and $snap.Visuals -ge 1) $(if ($snap) { "{0} {1} [{2}] visuals={3}" -f $snap.State, $snap.Url, (@($snap.Accounts) -join ','), $snap.Visuals })
        Test-Check $sc 'the report is still SHOWING after the snapshot' (Wait-Until -TimeoutSec 10 -Condition { (Get-LauncherStatus $run).State -eq 'SHOWING' }) ((Get-LauncherStatus $run).State)

        # 2. interval refresh, switched on by editing the config while running
        $json = [IO.File]::ReadAllText($run.Config) -replace '"EnableRefresh":\s*"0"', '"RefreshMinutes": "0.2"'
        [IO.File]::WriteAllText($run.Config, $json)
        $t1 = [DateTime]::UtcNow
        $ok = Wait-Until -TimeoutSec 50 -Condition { @(Get-FixtureEvents -SinceUtc $t1 -Name 'report').Count -ge 2 -and @(Get-FixtureEvents -SinceUtc $t1 -Name 'fullscreen').Count -ge 2 }
        Test-Check $sc 'config edit applied live: reloads every 12 s and re-enters full screen' $ok ("{0} reloads" -f @(Get-FixtureEvents -SinceUtc $t1 -Name 'report').Count)
        [IO.File]::WriteAllText($run.Config, ($json -replace '"RefreshMinutes":\s*"0.2"', '"RefreshMinutes": "0"'))
        Start-Sleep -Seconds 4
        $null = Wait-State $run 'SHOWING' 30

        # 3. Power BI shows an error: reload after three checks
        $null = Invoke-Http '/control?error=1'
        $t2 = [DateTime]::UtcNow
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        $ok = Wait-Until -TimeoutSec 40 -Condition { @(Get-FixtureEvents -SinceUtc $t2 -Name 'report' | Where-Object { $_.error }).Count -ge 2 }
        Test-Check $sc 'refresh.txt reloads; an error page is reloaded on its own' $ok
        Test-Check $sc 'status says RECOVERING meanwhile' ((Get-LauncherStatus $run).State -in @('RECOVERING', 'LOADING')) ((Get-LauncherStatus $run).State)
        Test-Check $sc 'refresh.txt deleted' (-not (Test-Path -LiteralPath (Join-Path $run.Dir 'refresh.txt')))
        $null = Invoke-Http '/control?error=0'
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        Test-Check $sc 'back to SHOWING once the error clears' (Wait-State $run 'SHOWING' 30)
        Start-Sleep -Seconds 5

        # 4. a report that never draws
        $null = Invoke-Http '/control?blank=1'
        $t3 = [DateTime]::UtcNow
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        $ok = Wait-Until -TimeoutSec 40 -Condition { @(Get-FixtureEvents -SinceUtc $t3 -Name 'report' | Where-Object { $_.blank }).Count -ge 2 }
        Test-Check $sc 'a report that draws nothing is reloaded after BlankReloadSeconds' $ok
        $null = Invoke-Http '/control?blank=0'
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        Test-Check $sc 'back to SHOWING' (Wait-State $run 'SHOWING' 30)

        # 5. the session expires: sign in again with the stored password
        $null = Invoke-Http '/control?logout=1'
        $t4 = [DateTime]::UtcNow
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        $ok = Wait-Until -TimeoutSec 60 -Condition { @(Get-FixtureEvents -SinceUtc $t4 -Name 'password' | Where-Object { $_.ok }).Count -eq 1 -and (Get-LauncherStatus $run).State -eq 'SHOWING' }
        Test-Check $sc 'expired session: signs in again from the encrypted file' $ok
        Test-Check $sc 'sign-in counter at 2' ((Get-LauncherStatus $run).SignIns -eq 2) ((Get-LauncherStatus $run).SignIns)

        # 6. Edge is closed: a new one, InPrivate, so it signs in again.
        Test-Check $sc 'Edge runs InPrivate (no Windows single sign-on)' (@(Get-ProfileEdge $run.Profile | Where-Object { $_.CommandLine -match '--inprivate' }).Count -gt 0)
        Test-Check $sc 'status shows the signed-in account' ((Get-LauncherStatus $run).SignedInAs -eq $User) ((Get-LauncherStatus $run).SignedInAs)
        $t5 = [DateTime]::UtcNow
        foreach ($p in Get-ProfileEdge $run.Profile) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        $ok = Wait-Until -TimeoutSec 60 -Condition { $st = Get-LauncherStatus $run; $st.BrowserStarts -eq 2 -and $st.State -eq 'SHOWING' }
        Test-Check $sc 'closed Edge is started again and the report comes back' $ok ("starts={0} state={1}" -f (Get-LauncherStatus $run).BrowserStarts, (Get-LauncherStatus $run).State)
        Test-Check $sc '...signing in again from the stored password' (@(Get-FixtureEvents -SinceUtc $t5 -Name 'password' | Where-Object { $_.ok }).Count -eq 1)

        # 7. relaunch.txt
        New-Item -ItemType File -Path (Join-Path $run.Dir 'relaunch.txt') -Force | Out-Null
        $ok = Wait-Until -TimeoutSec 45 -Condition { $st = Get-LauncherStatus $run; $st.BrowserStarts -eq 3 -and $st.State -eq 'SHOWING' }
        Test-Check $sc 'relaunch.txt restarts Edge' $ok

        # 8. hold.txt
        New-Item -ItemType File -Path (Join-Path $run.Dir 'hold.txt') -Force | Out-Null
        Test-Check $sc 'hold.txt pauses the launcher' (Wait-State $run 'HOLD' 15)
        Remove-Item -LiteralPath (Join-Path $run.Dir 'hold.txt')
        Test-Check $sc 'deleting hold.txt resumes it' (Wait-State $run 'SHOWING' 20)

        # 9. no password anywhere it should not be
        Test-NoPasswordLeak -Run $run -Scenario $sc
        $log = Get-LogText $run
        Test-Check $sc 'log has no ERROR lines' (-not ($log -match 'type="3"')) (([regex]::Matches($log, '<!\[LOG\[([^\]]*)\]LOG\]!>[^>]*type="3"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 3) -join ' | ')
        $stderr = Read-SharedFile $script:Stderr
        Test-Check $sc 'launcher wrote nothing to stderr' (-not $stderr.Trim()) $stderr

        # 10. kill.txt
        New-Item -ItemType File -Path (Join-Path $run.Dir 'kill.txt') -Force | Out-Null
        Test-Check $sc 'kill.txt stops the launcher' ($run.Process.WaitForExit(30000))
        Test-Check $sc '...closes its Edge' ((Wait-Until -TimeoutSec 15 -Condition { @(Get-ProfileEdge $run.Profile).Count -eq 0 }))
        Test-Check $sc '...and deletes kill.txt, status STOPPED' (-not (Test-Path -LiteralPath (Join-Path $run.Dir 'kill.txt')) -and (Get-LauncherStatus $run).State -eq 'STOPPED')
        Test-Check $sc 'exit code 0' ($run.Process.ExitCode -eq 0) $run.Process.ExitCode
    }
    finally { Stop-Run $run $sc }
}

function Invoke-LinksScenario {
    $sc = 'Links'
    Write-Host "`n== $sc (links in the report, Back button, return when unused)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    $run = New-Run -Name $sc -Seed $Password -Settings @{ DisplayURL = "$Base/report"; UserName = $User; ReturnAfterSeconds = '15' }
    Start-Run $run
    try {
        if (-not (Wait-State $run 'SHOWING' 90)) { Test-Check $sc 'reaches SHOWING' $false ((Get-LauncherStatus $run).State); return }
        $null = Wait-Until -TimeoutSec 10 -Condition { (Get-LogText $run) -match 'Power BI is in full screen' }
        $port = Get-DevToolsPort $run
        $main = @(Get-TestPages $port | Where-Object { $_.url -like "$Base/report*" })[0].id
        $url = { [string]@(Get-TestPages $port | Where-Object id -eq $main)[0].url }
        $hasButton = { [bool](Invoke-TestJs -Port $port -TargetId $main -Expression "!!$BackButtonElement") }

        Test-Check $sc 'page script is in the report, but shows no button there' ((Invoke-TestJs -Port $port -TargetId $main -Expression 'window.__pbilBack && window.__pbilBack.onReport') -and -not (& $hasButton))

        # 1. a same-window link
        $t1 = [DateTime]::UtcNow
        $null = Send-TestClick -Port $port -TargetId $main -Element "document.getElementById('sameLink')"
        Test-Check $sc 'same-window link opens' (Wait-Until -TimeoutSec 10 -Condition { (& $url) -like '*/linked?kind=same' })
        Test-Check $sc 'the linked page has a Back button' (Wait-Until -TimeoutSec 5 -Condition { & $hasButton })
        Test-Check $sc 'status BROWSING' (Wait-State $run 'BROWSING' 10) ((Get-LauncherStatus $run).Detail)
        $reportsBefore = @(Get-FixtureEvents -SinceUtc $t1 -Name 'report').Count
        Start-Sleep -Seconds 8
        Test-Check $sc "the linked page is left alone (its error text is not the launcher's to fix)" (@(Get-FixtureEvents -SinceUtc $t1 -Name 'report').Count -eq $reportsBefore -and (& $url) -like '*/linked?kind=same')

        # 2. the Back button
        $t2 = [DateTime]::UtcNow
        Test-Check $sc 'Back button can be pressed' (Send-TestClick -Port $port -TargetId $main -Element $BackButtonElement)
        Test-Check $sc '...and the report is back' (Wait-Until -TimeoutSec 10 -Condition { (& $url) -like "$Base/report*" })
        Test-Check $sc '...full screen again, status SHOWING' (Wait-Until -TimeoutSec 20 -Condition { (Get-LauncherStatus $run).State -eq 'SHOWING' -and @(Get-FixtureEvents -SinceUtc $t2 -Name 'fullscreen').Count -gt 0 })
        Test-Check $sc '...logged as a return, not as a fault' ((Get-LogText $run) -match 'Back on the report after' -and (Get-LogText $run) -notmatch 'left full screen')

        # 3. a target=_blank link stays in the kiosk window
        $null = Send-TestClick -Port $port -TargetId $main -Element "document.getElementById('newLink')"
        $extra = $false
        $deadline = (Get-Date).AddSeconds(4)
        while ((Get-Date) -lt $deadline) { if (@(Get-TestPages $port).Count -gt 1) { $extra = $true }; Start-Sleep -Milliseconds 200 }
        Test-Check $sc 'new-window link opens in the kiosk window, no second window' ((-not $extra) -and (& $url) -like '*/linked?kind=new')

        # 4. while someone uses the page it stays; once unused it goes home
        $deadline = (Get-Date).AddSeconds(22)
        while ((Get-Date) -lt $deadline) {
            $null = Invoke-TestCdp -Port $port -TargetId $main -Method 'Input.dispatchMouseEvent' -Params @{ type = 'mouseMoved'; x = (100 + (Get-Random -Maximum 200)); y = 300 }
            Start-Sleep -Seconds 3
        }
        Test-Check $sc 'in use: still on the linked page after 22 s (ReturnAfterSeconds = 15)' ((& $url) -like '*/linked?kind=new')
        $script:sawCountdown = $false
        $back = Wait-Until -TimeoutSec 30 -Condition {
            try { if ((Invoke-TestJs -Port $port -TargetId $main -Expression "($BackButtonElement || {}).textContent || ''") -match '\(\d+ s\)') { $script:sawCountdown = $true } } catch {}
            (& $url) -like "$Base/report*"
        }
        Test-Check $sc 'unused: back to the report by itself, with a countdown on the button first' ($back -and $script:sawCountdown)
        $null = Wait-State $run 'SHOWING' 20

        # 5. a Web URL button (window.open)
        $null = Send-TestClick -Port $port -TargetId $main -Element "document.getElementById('openBtn')"
        Start-Sleep -Seconds 3
        Test-Check $sc 'window.open opens in the kiosk window, no second window' (@(Get-TestPages $port).Count -eq 1 -and (& $url) -like '*/linked?kind=open')
        $null = Send-TestClick -Port $port -TargetId $main -Element $BackButtonElement
        $null = Wait-State $run 'SHOWING' 20

        # 6. a window that still gets opened is moved into the kiosk window
        $t6 = [DateTime]::UtcNow
        $null = Invoke-DevToolsHttp -Port $port -Path "/json/new?$Base/linked?kind=stray" -Method PUT
        $ok = Wait-Until -TimeoutSec 10 -Condition { @(Get-TestPages $port).Count -eq 1 -and (& $url) -like '*/linked?kind=stray' }
        Test-Check $sc 'a second window is closed and its page shown in the kiosk window' $ok ((Get-TestPages $port | ForEach-Object url) -join ', ')
        Test-Check $sc '...within a few seconds' ((([DateTime]::UtcNow) - $t6).TotalSeconds -lt 8) ('{0:0.0} s' -f (([DateTime]::UtcNow) - $t6).TotalSeconds)
        Test-Check $sc '...with its Back button' (Wait-Until -TimeoutSec 5 -Condition { & $hasButton })
        $null = Send-TestClick -Port $port -TargetId $main -Element $BackButtonElement
        Test-Check $sc 'back to SHOWING' (Wait-State $run 'SHOWING' 20)

        # 7. BackButton = 0: no button, links still kept, still goes home
        $json = [IO.File]::ReadAllText($run.Config) -replace '"ReturnAfterSeconds":\s*"15"', '"ReturnAfterSeconds": "6", "BackButton": "0"'
        [IO.File]::WriteAllText($run.Config, $json)
        $null = Wait-Until -TimeoutSec 15 -Condition { (Get-LogText $run) -match 'The config file changed' }
        $null = Wait-State $run 'SHOWING' 20
        Start-Sleep -Seconds 3
        $null = Send-TestClick -Port $port -TargetId $main -Element "document.getElementById('sameLink')"
        $null = Wait-Until -TimeoutSec 10 -Condition { (& $url) -like '*/linked?kind=same' }
        Start-Sleep -Seconds 2
        Test-Check $sc 'BackButton = 0: no button on the linked page' (-not (& $hasButton))
        Test-Check $sc '...but it still goes home when unused (6 s)' (Wait-Until -TimeoutSec 20 -Condition { (& $url) -like "$Base/report*" })

        $log = Get-LogText $run
        Test-Check $sc 'log has no ERROR lines' (-not ($log -match 'type="3"')) (([regex]::Matches($log, '<!\[LOG\[([^\]]*)\]LOG\]!>[^>]*type="3"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 3) -join ' | ')
        Test-Check $sc "Edge's sync dialog never appeared, the profile is not signed in to Windows' account" ($log -notmatch 'edge://' -and ([IO.File]::ReadAllText((Join-Path $run.Profile 'Default\Preferences'))) -notmatch '"account_info":\s*\[\s*\{')
        Test-Check $sc 'no Back button script failures' ($log -notmatch 'Back button')
        $stderr = Read-SharedFile $script:Stderr
        Test-Check $sc 'launcher wrote nothing to stderr' (-not $stderr.Trim()) $stderr
    }
    finally { Stop-Run $run $sc }
}

function Invoke-ChromelessAppScenario {
    $sc = 'ChromelessApp'
    Write-Host "`n== $sc (the pilot kiosk's 1.0.0.4 config: app URL with chromeless=true)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    # The LASER APT kiosk's settings, with test values for the tenant.
    $run = New-Run -Name $sc -LegacyArray -Seed $Password -Settings ([ordered]@{
            JsonVer = '1.0.0.4'; LoginURL = 'https://app.powerbi.com/singleSignOn?'
            DisplayURL = "$Base/report?ctid=3b65aa6d-5645-40dc-bf71-7f7c92aefe38&experience=power-bi&chromeless=true"
            ZoomPercent = '100'; ZoomDelay = '500'; UsePriScreen = '1'; ScreenSelect = '0'; KioskMode = '1'; ElementTimeout = '30'
            ForcedRefreshTime = '07:55'; EnableRefresh = '1'; BrowserRefreshDelay = '150'; UpdateEdgeDriver = '1'
            EdgeDriverSharePath = '\\nowhere\MSEdgeDriver'; LogPath = ''; RemoteLogPath = ''; LogName = 'PbiLauncher_Launcher_LASER_APT.log'
            LogDelay = '0'; TempCleanup = '1'; KillEdgeDriver = '1'; StartupDelay = '0'; DisableStartup = '0'
            ScheduledRestartEnabled = '0'; ScheduledRestartTime = '06:00'; RestartDelay = '30'; EdgeDriverSelfUpdate = '0'
            EdgeDriverDownloadPath = '$env:TEMP'; UsernameFieldID = 'email'; UserName = $User; PasswordFieldID = 'passwd'
            SubmitBtnID = 'idSIButton9'; StaySignedIn = '1'
        })
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        Test-Check $sc 'reaches SHOWING' (Wait-State $run 'SHOWING' 90) ((Get-LauncherStatus $run).State)
        Start-Sleep -Seconds 6
        $ev = Get-FixtureEvents -SinceUtc $t0
        $nav = @($ev | Where-Object name -eq 'hidenav')
        Test-Check $sc 'hid the navigation pane (what 1.0.0.14 does)' ($nav.Count -eq 1 -and $nav[0].trusted -eq 'true') ("{0} click(s)" -f $nav.Count)
        Test-Check $sc 'no View menu in chromeless mode, so no full-screen clicks and no warning' (@($ev | Where-Object { $_.name -in @('view', 'fullscreen') }).Count -eq 0 -and (Get-LogText $run) -notmatch 'View menu')
        $st = Get-LauncherStatus $run
        Test-Check $sc 'status SHOWING without remarks' ($st.State -eq 'SHOWING' -and -not $st.Detail) $st.Detail
        $log = Get-LogText $run
        Test-Check $sc 'config read without complaints' ($log -notmatch 'type="2"' -and $log -match 'report http://127\.0\.0\.1:\d+/report\?ctid=') (([regex]::Matches($log, '<!\[LOG\[([^\]]*)\]LOG\]!>[^>]*type="2"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -First 3) -join ' | ')
        # A reload brings the pane back; it is hidden again.
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        Test-Check $sc 'after a reload the pane is hidden again' (Wait-Until -TimeoutSec 20 -Condition { @(Get-FixtureEvents -SinceUtc $t0 -Name 'hidenav').Count -eq 2 })
    }
    finally { Stop-Run $run $sc }
}

function Invoke-AccountScenario {
    $sc = 'Account'
    Write-Host "`n== $sc (Power BI's e-mail page, signed in as the wrong account)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1&sso=1'
    $run = New-Run -Name $sc -Seed $Password -Settings @{ DisplayURL = "$Base/report"; UserName = $User }
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        Test-Check $sc 'reaches SHOWING' (Wait-State $run 'SHOWING' 90) ((Get-LauncherStatus $run).State)
        $ev = Get-FixtureEvents -SinceUtc $t0
        $sso = @($ev | Where-Object name -eq 'pbi-sso')
        Test-Check $sc "typed the account into Power BI's e-mail page" ($sso.Count -eq 1 -and $sso[0].email -eq $User) (($sso | ForEach-Object email) -join ',')
        Test-Check $sc '...then only the password (no user-name page)' (@($ev | Where-Object { $_.name -eq 'password' -and $_.ok }).Count -eq 1 -and @($ev | Where-Object name -eq 'login-page').Count -eq 0)

        # Windows single sign-on hands over the PC's account: the session is
        # valid, but for another user.
        $null = Invoke-Http '/control?wrong=once'
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        $ok = Wait-Until -TimeoutSec 90 -Condition { $st = Get-LauncherStatus $run; $st.BrowserStarts -eq 2 -and $st.State -eq 'SHOWING' -and $st.SignedInAs -eq $User }
        Test-Check $sc 'wrong account noticed: clean Edge, signed in again as the configured account' $ok ("starts={0} state={1} as={2}" -f (Get-LauncherStatus $run).BrowserStarts, (Get-LauncherStatus $run).State, (Get-LauncherStatus $run).SignedInAs)
        Test-Check $sc '...and logged who it was' ((Get-LogText $run) -match 'signed in as kiosk\.windows@contoso\.test, not')

        # It keeps happening: stop after three tries and say so.
        $null = Invoke-Http '/control?wrong=always'
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        $ok = Wait-Until -TimeoutSec 180 -Condition { $st = Get-LauncherStatus $run; $st.State -eq 'SIGNIN_BLOCKED' -and $st.Detail -like '*keeps signing in as kiosk.windows@contoso.test*' }
        Test-Check $sc 'always the wrong account: SIGNIN_BLOCKED after three tries' $ok ("{0} '{1}' starts={2}" -f (Get-LauncherStatus $run).State, (Get-LauncherStatus $run).Detail, (Get-LauncherStatus $run).BrowserStarts)
        # 1 at start, 1 for the first wrong account, 2 more before giving up
        # (three strikes in the hour).
        Test-Check $sc '...having started Edge four times in all' ((Get-LauncherStatus $run).BrowserStarts -eq 4) ((Get-LauncherStatus $run).BrowserStarts)
        Test-NoPasswordLeak -Run $run -Scenario $sc
    }
    finally { Stop-Run $run $sc; $null = Invoke-Http '/control?reset=1' }
}

function Invoke-KeptProfileScenario {
    $sc = 'KeptProfile'
    Write-Host "`n== $sc (InPrivate = 0: the sign-in survives a new Edge)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    $run = New-Run -Name $sc -Seed $Password -Settings @{ DisplayURL = "$Base/report"; UserName = $User; InPrivate = '0'; FullScreen = 'none' }
    Start-Run $run
    try {
        Test-Check $sc 'reaches SHOWING' (Wait-State $run 'SHOWING' 90) ((Get-LauncherStatus $run).State)
        Test-Check $sc 'Edge is not InPrivate' (@(Get-ProfileEdge $run.Profile | Where-Object { $_.CommandLine -match '--inprivate' }).Count -eq 0)
        # Chromium writes cookies to disk every 30 s.
        Start-Sleep -Seconds 35
        $t1 = [DateTime]::UtcNow
        foreach ($p in Get-ProfileEdge $run.Profile) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        $ok = Wait-Until -TimeoutSec 60 -Condition { $st = Get-LauncherStatus $run; $st.BrowserStarts -eq 2 -and $st.State -eq 'SHOWING' }
        Test-Check $sc 'new Edge shows the report without signing in again' ($ok -and @(Get-FixtureEvents -SinceUtc $t1 -Name 'password').Count -eq 0)
    }
    finally { Stop-Run $run $sc }
}

function Invoke-WrongPasswordScenario {
    $sc = 'WrongPassword'
    Write-Host "`n== $sc (lockout protection, new-format config)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    $run = New-Run -Name $sc -Seed 'definitely-wrong' -Settings @{
        ConfigVersion = '2.0'; DisplayURL = "$Base/report"; UserName = $User; LoginRetryMinutes = '60'; FullScreen = 'none'
    }
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        Test-Check $sc 'blocks after the password is rejected' (Wait-State $run 'SIGNIN_BLOCKED' 60) ((Get-LauncherStatus $run).Detail)
        Start-Sleep -Seconds 15
        $bad = @(Get-FixtureEvents -SinceUtc $t0 -Name 'password')
        Test-Check $sc 'tried the wrong password exactly once' ($bad.Count -eq 1 -and -not $bad[0].ok) ("{0} attempt(s)" -f $bad.Count)

        $t1 = [DateTime]::UtcNow
        [IO.File]::WriteAllText((Join-Path $run.Dir 'password.seed'), $Password, (New-Object Text.UTF8Encoding($false)))
        Test-Check $sc 'a new password.seed lifts the block and signs in' (Wait-State $run 'SHOWING' 60) ((Get-LauncherStatus $run).State)
        Test-Check $sc '...with one attempt' (@(Get-FixtureEvents -SinceUtc $t1 -Name 'password' | Where-Object { $_.ok }).Count -eq 1)
        Test-Check $sc 'FullScreen = none: no View clicks' (@(Get-FixtureEvents -SinceUtc $t0 -Name 'view').Count -eq 0)
        Test-NoPasswordLeak -Run $run -Scenario $sc
    }
    finally { Stop-Run $run $sc }
}

function Invoke-PickerScenario {
    $sc = 'PickerAndLegacyPassword'
    Write-Host "`n== $sc (account picker, plain-text password from an old config)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1&picker=1'
    $run = New-Run -Name $sc -LegacyArray -Settings @{
        JsonVer = '1.0.0.3'; DisplayURL = "$Base/report"; UserName = $User; Password = $Password; KioskMode = '1'; StaySignedIn = '0'
    }
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        Test-Check $sc 'reaches SHOWING' (Wait-State $run 'SHOWING' 90) ((Get-LauncherStatus $run).State)
        $ev = Get-FixtureEvents -SinceUtc $t0
        Test-Check $sc 'picked its own account tile' (@($ev | Where-Object { $_.name -eq 'user' -and $_.user -eq $User }).Count -eq 1 -and @($ev | Where-Object { $_.name -eq 'user' -and $_.user -ne $User }).Count -eq 0)
        Test-Check $sc "answered 'Stay signed in' with No (StaySignedIn = 0)" (@($ev | Where-Object { $_.name -eq 'kmsi' -and $_.answer -eq 'no' }).Count -eq 1)
        Test-Check $sc 'plain-text password copied into the encrypted file' (Test-Path -LiteralPath $run.Cred)
        Test-Check $sc 'log warns about the plain-text password' ((Get-LogText $run) -match 'plain-text Password')
    }
    finally { Stop-Run $run $sc; $null = Invoke-Http '/control?reset=1' }
}

function Invoke-MfaScenario {
    $sc = 'Mfa'
    Write-Host "`n== $sc (extra verification needs a person)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1&mfa=1'
    $run = New-Run -Name $sc -Seed $Password -Settings @{ DisplayURL = "$Base/report"; UserName = $User }
    Start-Run $run
    try {
        $ok = Wait-Until -TimeoutSec 60 -Condition { $st = Get-LauncherStatus $run; $st.State -eq 'SIGNIN_BLOCKED' -and $st.Detail -like '*extra verification*' }
        Test-Check $sc 'MFA prompt: stops and says a person is needed' $ok ((Get-LauncherStatus $run).Detail)
    }
    finally { Stop-Run $run $sc; $null = Invoke-Http '/control?reset=1' }
}

function Invoke-EdgeErrorScenario {
    $sc = 'EdgeErrorPage'
    Write-Host "`n== $sc (site unreachable)" -ForegroundColor Cyan
    $run = New-Run -Name $sc -Settings @{ DisplayURL = 'http://127.0.0.1:1/report'; UserName = $User }
    Start-Run $run
    try {
        $ok = Wait-Until -TimeoutSec 45 -Condition { (Get-LogText $run) -match 'Edge showed an error page' }
        Test-Check $sc 'notices the Edge error page and retries' $ok
        Test-Check $sc 'status RECOVERING' ((Get-LauncherStatus $run).State -eq 'RECOVERING') ((Get-LauncherStatus $run).State)
        Start-Sleep -Seconds 20
        $tries = ([regex]::Matches((Get-LogText $run), 'Opening the report \(Edge showed an error page')).Count
        Test-Check $sc 'backs off instead of hammering (<= 3 tries in ~30 s)' ($tries -ge 1 -and $tries -le 3) "$tries tries"
    }
    finally { Stop-Run $run $sc }
}

function Invoke-RefusedScenario {
    # 2026-09-24: the kiosk account lost its license. Power BI showed the
    # report for a moment, then sent it to sign up, and after a while
    # answered 429; the launcher took it for someone browsing and reopened
    # the report every 25 s on 8 kiosks.
    $sc = 'Refused'
    Write-Host "`n== $sc (Power BI refuses the account: no license, then 429)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    # ReturnAfterSeconds 10: the page's own return timer would fire several
    # times in the 40 s below if it still ran on a refusal page.
    $run = New-Run -Name $sc -Seed $Password -Settings @{ DisplayURL = "$Base/report"; UserName = $User; ReturnAfterSeconds = '10' }
    Start-Run $run
    try {
        if (-not (Wait-State $run 'SHOWING' 90)) { Test-Check $sc 'reaches SHOWING' $false ((Get-LauncherStatus $run).State); return }
        $null = Invoke-Http '/control?refuse=nolicense'
        $t1 = [DateTime]::UtcNow
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        $ok = Wait-Until -TimeoutSec 30 -Condition { $st = Get-LauncherStatus $run; $st.State -eq 'ERROR' -and $st.Detail -like '*no license*' }
        Test-Check $sc 'no license: status ERROR, not BROWSING' $ok ((Get-LauncherStatus $run) | Select-Object State, Detail | Out-String)
        Start-Sleep -Seconds 40
        $tries = @(Get-FixtureEvents -SinceUtc $t1 -Name 'refused').Count
        Test-Check $sc 'waits a minute before trying again, the page timer too (<= 2 tries in ~45 s)' ($tries -ge 1 -and $tries -le 2) "$tries tries"
        Test-Check $sc 'never called it browsing' ((Get-LogText $run) -notmatch 'someone opened')

        $null = Invoke-Http '/control?refuse=429'
        $ok = Wait-Until -TimeoutSec 90 -Condition { $st = Get-LauncherStatus $run; $st.State -eq 'ERROR' -and $st.Detail -like '*throttling*429*' }
        Test-Check $sc '429: status ERROR, says throttling' $ok ((Get-LauncherStatus $run).Detail)

        $null = Invoke-Http '/control?refuse=no'
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        Test-Check $sc 'refresh.txt tries the report at once and it shows again' (Wait-State $run 'SHOWING' 45) ((Get-LauncherStatus $run) | Select-Object State, Detail | Out-String)
    }
    finally { Stop-Run $run $sc; $null = Invoke-Http '/control?reset=1' }
}

function Invoke-ScreenFolderScenario {
    # 2.0.1: each screen in a folder of its own next to the script, as the
    # deploy sets it up - here S2, so that a Mach2 dashboard or a web page
    # can have S1.
    $sc = 'ScreenFolder'
    Write-Host "`n== $sc (PbiLauncher.ps1 -Instance S2, config in S2\)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    $run = New-Run -Name $sc -Seed $Password -Settings @{ DisplayURL = "$Base/report"; UserName = $User; FullScreen = 'none' }
    $s2 = Join-Path $run.Dir 'S2'
    New-Item -ItemType Directory -Path $s2 -Force | Out-Null
    Move-Item -LiteralPath $run.Config -Destination (Join-Path $s2 (Split-Path -Leaf $run.Config))
    Move-Item -LiteralPath (Join-Path $run.Dir 'password.seed') -Destination (Join-Path $s2 'password.seed')
    $script:Stderr = Join-Path $run.Dir 'stderr.txt'
    $run.Process = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -RedirectStandardError $script:Stderr -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $run.Dir 'PbiLauncher.ps1')), '-Instance', 'S2', '-Headless', '-ExitAfterSeconds', '600')
    $null = $run.Process.Handle
    $statusPath = Join-Path $s2 'Status\S2.status.json'
    $read = { if (Test-Path -LiteralPath $statusPath) { try { ConvertFrom-Json -InputObject (Read-SharedFile $statusPath) } catch { $null } } }
    try {
        Test-Check $sc 'signs in and shows the report from S2' (Wait-Until -TimeoutSec 90 -Condition { (& $read).State -eq 'SHOWING' }) ((& $read).State)
        $st = & $read
        Test-Check $sc 'its status is S2''s, in S2\Status, as PBI Launcher on screen S2' ($st.Instance -eq 'S2' -and $st.Screen -eq 'S2' -and $st.Launcher -eq 'PBI') "$($st.Instance) $($st.Screen) $($st.Launcher)"
        Test-Check $sc 'the password is kept in S2, the seed gone' ((Test-Path (Join-Path $s2 "$env:COMPUTERNAME.cred")) -and -not (Test-Path (Join-Path $s2 'password.seed')))
        Test-Check $sc 'a second screen writes a log of its own name' (Test-Path (Join-Path $s2 ('Logs\PbiLauncher_{0}_S2.log' -f $env:COMPUTERNAME.ToUpperInvariant())))
        Test-Check $sc 'nothing lands next to the script' (-not (Test-Path (Join-Path $run.Dir 'Status')) -and -not (Test-Path (Join-Path $run.Dir 'Logs')))
    }
    finally {
        if (-not $run.Process.HasExited) {
            New-Item -ItemType File -Path (Join-Path $s2 'kill.txt') -Force | Out-Null
            if (-not $run.Process.WaitForExit(30000)) { Test-Check $sc 'launcher stops on kill.txt in S2' $false 'had to be killed'; Stop-Process -Id $run.Process.Id -Force }
        }
        foreach ($p in Get-ProfileEdge $run.Profile) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-UnsupervisedScenario {
    $sc = 'Unsupervised'
    Write-Host "`n== $sc (Supervised = 0: only keeps Edge open)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1'
    $run = New-Run -Name $sc -Settings @{ DisplayURL = "$Base/report"; UserName = $User; Supervised = '0' }
    $t0 = [DateTime]::UtcNow
    Start-Run $run
    try {
        Test-Check $sc 'status UNSUPERVISED' (Wait-State $run 'UNSUPERVISED' 30) ((Get-LauncherStatus $run).State)
        $edge = @(Get-ProfileEdge $run.Profile)
        Test-Check $sc 'Edge runs without a DevTools port' ($edge.Count -gt 0 -and -not @($edge | Where-Object { $_.CommandLine -match 'remote-debugging' }).Count)
        Test-Check $sc 'Edge opened the report address' (Wait-Until -TimeoutSec 20 -Condition { @(Get-FixtureEvents -SinceUtc $t0 | Where-Object { $_.name -in @('report', 'report-redirect') }).Count -gt 0 })
        Test-Check $sc 'no sign-in attempted' (@(Get-FixtureEvents -SinceUtc $t0 -Name 'user').Count -eq 0)
        foreach ($p in $edge) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        Test-Check $sc 'a closed Edge is started again' (Wait-Until -TimeoutSec 40 -Condition { (Get-LauncherStatus $run).BrowserStarts -eq 2 -and @(Get-ProfileEdge $run.Profile).Count -gt 0 })
        New-Item -ItemType File -Path (Join-Path $run.Dir 'refresh.txt') -Force | Out-Null
        Test-Check $sc 'refresh.txt restarts Edge (no way to reload it otherwise)' (Wait-Until -TimeoutSec 40 -Condition { (Get-LauncherStatus $run).BrowserStarts -eq 3 })
        New-Item -ItemType File -Path (Join-Path $run.Dir 'kill.txt') -Force | Out-Null
        Test-Check $sc 'kill.txt stops it and closes Edge' ($run.Process.WaitForExit(30000) -and (Wait-Until -TimeoutSec 15 -Condition { @(Get-ProfileEdge $run.Profile).Count -eq 0 }))
    }
    finally { Stop-Run $run $sc }
}

function Invoke-MissingScreenScenario {
    $sc = 'MissingScreen'
    Write-Host "`n== $sc (configured screen not connected)" -ForegroundColor Cyan
    $null = Invoke-Http '/control?reset=1&logout=1'
    $run = New-Run -Name $sc -Seed $Password -Settings @{ DisplayURL = "$Base/report"; UserName = $User; ScreenSelect = '9'; FullScreen = 'none' }
    $json = [IO.File]::ReadAllText($run.Config) -replace '"DisplayWaitSeconds":\s*"0"', '"DisplayWaitSeconds": "6"'
    [IO.File]::WriteAllText($run.Config, $json)
    Start-Run $run
    try {
        Test-Check $sc 'waits for the screen first' (Wait-State $run 'WAITING_DISPLAY' 15) ((Get-LauncherStatus $run).Detail)
        Test-Check $sc 'then uses the primary screen and shows the report' (Wait-State $run 'SHOWING' 60) ((Get-LauncherStatus $run).State)
        Test-Check $sc 'log says which screen it could not find' ((Get-LogText $run) -match 'Screen 9 not found')
    }
    finally { Stop-Run $run $sc }
}

function Invoke-DisabledScenario {
    $sc = 'Disabled'
    Write-Host "`n== $sc (DisableStartup = 1)" -ForegroundColor Cyan
    $run = New-Run -Name $sc -LegacyArray -Settings @{ JsonVer = '1.0.0.3'; DisplayURL = "$Base/report"; DisableStartup = '1' }
    Start-Run $run
    try {
        Test-Check $sc 'exits at once' ($run.Process.WaitForExit(30000))
        Test-Check $sc 'status DISABLED, no Edge' ((Get-LauncherStatus $run).State -eq 'DISABLED' -and @(Get-ProfileEdge $run.Profile).Count -eq 0)
    }
    finally { Stop-Run $run $sc }
}

# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$all = -not $Only

if ($all -or 'Unit' -in $Only) { Invoke-UnitTests }

$e2e = @('Main', 'Links', 'ChromelessApp', 'Account', 'KeptProfile', 'WrongPassword', 'PickerAndLegacyPassword', 'Mfa', 'EdgeErrorPage', 'Refused', 'ScreenFolder', 'Unsupervised', 'MissingScreen', 'Disabled') | Where-Object { $all -or $_ -in $Only }
if ($e2e) {
    $script:EventsFile = Join-Path $WorkRoot 'events.jsonl'
    $pwFile = Join-Path $WorkRoot 'fixture-password.txt'
    [IO.File]::WriteAllText($pwFile, $Password, (New-Object Text.UTF8Encoding($false)))
    $server = Start-Process -FilePath powershell.exe -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $PSScriptRoot 'FixtureServer.ps1')),
        '-Port', $Port, '-EventsFile', ('"{0}"' -f $script:EventsFile), '-PasswordFile', ('"{0}"' -f $pwFile), '-UserName', $User)
    try {
        if (-not (Wait-Until -TimeoutSec 20 -Condition { (Invoke-Http '/control?reset=1') -eq 'ok' })) { throw 'The fixture server did not start.' }
        foreach ($name in $e2e) {
            switch ($name) {
                'Main' { Invoke-MainScenario }
                'Links' { Invoke-LinksScenario }
                'ChromelessApp' { Invoke-ChromelessAppScenario }
                'Account' { Invoke-AccountScenario }
                'KeptProfile' { Invoke-KeptProfileScenario }
                'WrongPassword' { Invoke-WrongPasswordScenario }
                'PickerAndLegacyPassword' { Invoke-PickerScenario }
                'Mfa' { Invoke-MfaScenario }
                'EdgeErrorPage' { Invoke-EdgeErrorScenario }
                'Refused' { Invoke-RefusedScenario }
                'ScreenFolder' { Invoke-ScreenFolderScenario }
                'Unsupervised' { Invoke-UnsupervisedScenario }
                'MissingScreen' { Invoke-MissingScreenScenario }
                'Disabled' { Invoke-DisabledScenario }
            }
        }
    }
    finally {
        try { $null = Invoke-Http '/stop' } catch {}
        if (-not $server.WaitForExit(5000)) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    }
}

$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("{0} checks, {1} failed." -f $script:Results.Count, $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
foreach ($f in $failed) { Write-Host ("  FAIL {0}: {1} {2}" -f $f.Scenario, $f.Check, $f.Detail) -ForegroundColor Red }
if (-not $KeepWorkRoot -and $failed.Count -eq 0) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue }
exit $failed.Count
