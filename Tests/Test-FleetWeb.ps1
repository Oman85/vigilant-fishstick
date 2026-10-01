#Requires -Version 5.1
<#
.SYNOPSIS
    Tests Kiosk Fleet Web (Start-FleetWeb.ps1): signing in, what each role
    may and may not do, the fleet it serves, what its buttons do to a
    kiosk, the config editor, deploy commands, a scan, and the audit log.

.DESCRIPTION
    Nothing here touches a real kiosk, the published CSV, a real deploy or
    AD. The server runs on http://localhost:<port>/ with local accounts
    only, against a fleet on disk under -WorkRoot: kiosks are folders
    standing in for their C: drives (-RootTemplate), with a background job
    playing the launcher, and the collector is a stand-in script. Its logs
    go to -WorkRoot too.

    On Windows, listening on localhost may need an elevated console (or a
    URL reservation for your account).

    Takes about a minute.

.EXAMPLE
    .\Tests\Test-FleetWeb.ps1
#>
[CmdletBinding()]
param(
    [string]$FleetRoot,
    [string]$WorkRoot,
    [int]$Port,
    [switch]$KeepWorkRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
if (-not $FleetRoot) { $FleetRoot = Split-Path -Parent $PSScriptRoot }
if (-not $WorkRoot) { $WorkRoot = Join-Path ([IO.Path]::GetTempPath()) 'KioskFleetWebTests' }
$FleetRoot = (Resolve-Path -LiteralPath $FleetRoot).ProviderPath
if (-not $Port) { $Port = Get-Random -Minimum 18100 -Maximum 18900 }
$Base = "http://localhost:$Port"

$script:Results = New-Object System.Collections.Generic.List[object]
function Test-Check {
    param([Parameter(Mandatory)][string]$Name, [bool]$Pass, [string]$Detail = '')
    $script:Results.Add([pscustomobject]@{ Section = $script:Section; Check = $Name; Pass = $Pass; Detail = $Detail })
    $mark = if ($Pass) { 'PASS' } else { 'FAIL' }
    $suffix = if ($Detail) { "  ($Detail)" } else { '' }
    Write-Host ("  [{0}] {1}{2}" -f $mark, $Name, $suffix) -ForegroundColor $(if ($Pass) { 'Green' } else { 'Red' })
}
function Start-Section([string]$Name) {
    $script:Section = $Name
    Write-Host "`n== $Name" -ForegroundColor Cyan
}
function P {
    # A path under a root, written Windows-style, with this system's separators.
    param([string]$Root, [string]$Rel)
    return (Join-Path $Root ($Rel.Replace('\', [string][IO.Path]::DirectorySeparatorChar)))
}

if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$KioskDir = Join-Path $WorkRoot 'kiosks'
$Template = Join-Path $KioskDir '{0}'
$LogDir = Join-Path $WorkRoot 'logs'
$UsersFile = Join-Path $WorkRoot 'web-users.json'
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------
# A fleet on disk: the events CSV and the collector's status file
# ---------------------------------------------------------------------------
$Now = Get-Date
function Iso { param($When) $When.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $Inv) }
function IsoLocal { param($When) $When.ToString("yyyy-MM-dd'T'HH:mm:ss", $Inv) }
$Cols = @('EventId', 'EventTimeUtc', 'EventTimeLocal', 'EventDate', 'Host', 'Location', 'KioskType', 'RestartGroup',
    'EventCategory', 'EventType', 'Severity', 'Outcome', 'IsCanonicalReboot', 'IsScriptReboot', 'RebootTrigger',
    'WhitePercent', 'StreakChecks', 'DurationSeconds', 'Reachable', 'WatchdogRunning', 'MinutesSinceLastLog',
    'AgentVersion', 'BootTimeUtc', 'UptimeHours', 'Source', 'ScanId', 'CollectedUtc', 'Detail')
$rows = New-Object System.Collections.ArrayList
function Add-Row {
    param([hashtable]$Values)
    $o = [ordered]@{}
    foreach ($c in $Cols) { $o[$c] = '' }
    foreach ($k in $Values.Keys) { $o[$k] = $Values[$k] }
    [void]$rows.Add([pscustomobject]$o)
}
$kiosks = @(
    @{ Host = 'MWEB1'; Location = 'LINE1'; Type = 'Mach2'; Status = 'OK'; Wd = 'TRUE'; Agent = '1.00NG'; Log = 1 }
    @{ Host = 'MWEB2'; Location = 'LINE2'; Type = 'Mach2'; Status = 'STALE'; Wd = 'FALSE'; Agent = '7.0'; Log = 1900 }
    @{ Host = 'MWEB3'; Location = 'LINE3'; Type = 'Mach2'; Status = 'OK'; Wd = 'TRUE'; Agent = '6.1'; Log = 2 }
    @{ Host = 'PWEB1'; Location = 'APU1'; Type = 'PBI'; Status = 'OK'; Wd = ''; Agent = ''; Log = $null }
    @{ Host = 'PWEB2'; Location = 'APU2'; Type = 'PBI - SR'; Status = 'WRONG_ACCOUNT'; Wd = ''; Agent = ''; Log = $null }
    @{ Host = 'PWEB3'; Location = 'APU3'; Type = 'PBI'; Status = 'OFFLINE'; Wd = ''; Agent = ''; Log = $null }
    @{ Host = 'OWEB1'; Location = 'STORE'; Type = 'Signage'; Status = 'OK'; Wd = ''; Agent = ''; Log = $null }
)
foreach ($k in $kiosks) {
    Add-Row @{
        EventId = [guid]::NewGuid(); EventTimeUtc = (Iso $Now.AddMinutes(-4)); EventTimeLocal = (IsoLocal $Now.AddMinutes(-4))
        EventDate = $Now.ToString('yyyy-MM-dd', $Inv); Host = $k.Host; Location = $k.Location; KioskType = $k.Type
        EventCategory = 'HOST'; EventType = 'HOST_STATUS'; Severity = 'INFO'; Outcome = $k.Status
        Reachable = 'TRUE'; WatchdogRunning = $k.Wd; AgentVersion = $k.Agent
        MinutesSinceLastLog = $(if ($null -ne $k.Log) { "$($k.Log)" } else { '' })
        BootTimeUtc = (Iso $Now.AddHours(-9)); UptimeHours = '9'; Source = 'Collector'; Detail = "reach=ping share=ok for $($k.Host)"
    }
}
foreach ($n in 1, 2, 3) {
    $when = $(if ($n -eq 3) { $Now.AddDays(-1) } else { $Now.AddHours(-3) })
    Add-Row @{
        EventId = [guid]::NewGuid(); EventTimeUtc = (Iso $when); EventTimeLocal = (IsoLocal $when)
        EventDate = $when.ToString('yyyy-MM-dd', $Inv); Host = 'MWEB2'; Location = 'LINE2'; KioskType = 'Mach2'
        EventCategory = 'REBOOT'; EventType = 'WATCHDOG_WHITE'; Severity = 'WARN'; Outcome = 'RESTART_CONFIRMED'
        IsCanonicalReboot = 'TRUE'; IsScriptReboot = $(if ($n -eq 1) { 'TRUE' } else { 'FALSE' }); RebootTrigger = 'WHITE'; Source = 'Agent'
    }
}
Add-Row @{
    EventId = [guid]::NewGuid(); EventTimeUtc = (Iso $Now.AddMinutes(-4)); EventTimeLocal = (IsoLocal $Now.AddMinutes(-4))
    EventDate = $Now.ToString('yyyy-MM-dd', $Inv); EventCategory = 'COLLECTOR'; EventType = 'COLLECTOR_RUN'; Severity = 'INFO'; Outcome = 'OK'; Source = 'Collector'
}
$Csv = Join-Path $WorkRoot 'MWST_FleetEvents.csv'
$rows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
$sidecar = [ordered]@{
    LastRunUtc = (Iso $Now.AddMinutes(-4)); DurationSeconds = 42; Hosts = $kiosks.Count; Reachable = 6; NewEvents = 0
    CollectorVersion = '6.1'; Runner = 'TEST\tester@TESTPC'
    PbiLaunchers = [ordered]@{
        PWEB1 = [ordered]@{ Installed = $true; LegacyLauncher = $false; Status = 'OK'; Error = ''
            Instances = @([ordered]@{ Instance = 'PWEB1'; State = 'SHOWING'; HostStatus = 'OK'; UpdatedUtc = (Iso $Now.AddMinutes(-1)); StateMinutes = 30
                    Version = '2.0.0'; Edge = '153.0'; SignedInAs = 'kiosk@contoso.test'; SignIns = 1; Reloads = 3; BrowserStarts = 1; LastError = '' }) }
        PWEB2 = [ordered]@{ Installed = $true; LegacyLauncher = $false; Status = 'WRONG_ACCOUNT'; Error = ''
            Instances = @([ordered]@{ Instance = 'PWEB2'; State = 'SHOWING'; HostStatus = 'WRONG_ACCOUNT'; UpdatedUtc = (Iso $Now.AddMinutes(-1)); StateMinutes = 12
                    Version = '2.0.0'; Edge = '153.0'; SignedInAs = 'someone@contoso.test'; SignIns = 1; Reloads = 1; BrowserStarts = 1; LastError = '' }) }
    }
    Mach2Launchers = [ordered]@{
        MWEB1 = [ordered]@{ Installed = $true; OldLauncher = $false; Status = 'OK'; Error = ''
            Instances = @([ordered]@{ Instance = 'S1'; State = 'SHOWING'; HostStatus = 'OK'; UpdatedUtc = (Iso $Now.AddMinutes(-1)); StateMinutes = 55
                    Version = '1.00NG'; Edge = '153.0'; Watchdog = $true; LoopGuard = 'OFF'; PageWhitePercent = 63; ScreenWhitePercent = 72
                    SignIns = 1; Reloads = 2; BrowserStarts = 1; PcRestarts = 0; LastError = '' }) }
    }
}
[IO.File]::WriteAllText([IO.Path]::ChangeExtension($Csv, '.status.json'), ($sidecar | ConvertTo-Json -Depth 6))

# ---------------------------------------------------------------------------
# Fake kiosks: MWEB1 runs Mach2 Launcher NG on S1, PWEB1 runs PBI Launcher
# ---------------------------------------------------------------------------
$ngDir = P ($Template -f 'MWEB1') 'Users\Public\Documents\Mach2LauncherNG\S1'
$pbiDir = P ($Template -f 'PWEB1') 'Users\Public\Documents\PbiLauncher'
foreach ($d in @((Join-Path $ngDir 'Status'), (Join-Path $ngDir 'Logs'), (Join-Path $pbiDir 'Status'), (P ($Template -f 'NEWWEB1') 'Users'))) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}
[IO.File]::WriteAllText((Join-Path (Split-Path -Parent $ngDir) 'Mach2LauncherNG.ps1'), '# fake')
[IO.File]::WriteAllText((Join-Path $pbiDir 'PbiLauncher.ps1'), '# fake')
[IO.File]::WriteAllText((Join-Path $ngDir 'MWEB1.json'), ([ordered]@{
            ConfigVersion = '1.00NG'; LoginURL = 'http://station:302/prelogin?clear=true'; DisplayURL = 'http://station:302/ord/dashboard'
            UserName = 'operator'; ScreenSelect = '1'; Watchdog = '1'; LogName = 'MWEB1_Mach2LauncherNG.log'
        } | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $ngDir 'Status/S1.status.json'), (@{
            Instance = 'S1'; State = 'SHOWING'; LauncherVersion = '1.00NG'; EdgeVersion = 'Edg/153.0'; UpdatedUtc = ([datetime]::UtcNow.ToString('o'))
            StateSinceUtc = ([datetime]::UtcNow.AddMinutes(-55).ToString('o')); Watchdog = $true; LoopGuard = 'OFF'; ScreenWhitePercent = 72; PageWhitePercent = 63
            SignIns = 1; Reloads = 2; BrowserStarts = 1; PcRestarts = 0; LastError = ''
        } | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $ngDir 'Logs/MWEB1_Mach2LauncherNG.log'),
    '<![LOG[The dashboard is on screen.]LOG]!><time="08:30:00.000+000" date="09-20-2026" component="Mach2LauncherNG" context="" type="1" thread="1" file="">')
[IO.File]::WriteAllText((Join-Path $pbiDir 'PWEB1.json'), (@{ DisplayURL = 'https://app.powerbi.test/report'; UserName = 'kiosk@contoso.test' } | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $pbiDir 'Status/PWEB1.status.json'), (@{
            Instance = 'PWEB1'; State = 'SHOWING'; LauncherVersion = '2.0.0'; EdgeVersion = 'Edg/153.0'; UpdatedUtc = ([datetime]::UtcNow.ToString('o'))
            StateSinceUtc = ([datetime]::UtcNow.AddMinutes(-30).ToString('o')); UserName = 'kiosk@contoso.test'; SignedInAs = 'kiosk@contoso.test'
            SignIns = 1; Reloads = 3; BrowserStarts = 1; LastError = ''
        } | ConvertTo-Json))

# The launcher, played by a background job: it takes control files, answers
# snapshot.txt with a picture, and stores password.seed - and leaves
# hold.txt alone, as a real launcher does.
$launcher = Start-Job -ArgumentList $ngDir, $pbiDir -ScriptBlock {
    param($NgDir, $PbiDir)
    $deadline = (Get-Date).AddSeconds(240)
    $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
    while ((Get-Date) -lt $deadline) {
        foreach ($d in @(@{ Dir = $NgDir; Name = 'S1' }, @{ Dir = $PbiDir; Name = 'PWEB1' })) {
            foreach ($f in @('refresh.txt', 'relaunch.txt', 'kill.txt')) {
                $p = Join-Path $d.Dir $f
                if (Test-Path -LiteralPath $p) {
                    Start-Sleep -Milliseconds 100
                    try { Copy-Item -LiteralPath $p -Destination (Join-Path $d.Dir "taken.$f") -Force } catch { Add-Content -LiteralPath (Join-Path $d.Dir "launcher-errors.txt") -Value $_.Exception.Message }
                    Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
                }
            }
            $snap = Join-Path $d.Dir 'snapshot.txt'
            if (Test-Path -LiteralPath $snap) {
                Remove-Item -LiteralPath $snap -Force -ErrorAction SilentlyContinue
                $status = Join-Path $d.Dir 'Status'
                [IO.File]::WriteAllBytes((Join-Path $status "$($d.Name).png"), $png)
                [IO.File]::WriteAllText((Join-Path $status "$($d.Name).snapshot.json"), (@{
                            TakenUtc = ([datetime]::UtcNow.ToString('o')); State = 'SHOWING'; Url = 'http://station/dashboard'; Title = 'Dashboard'; Image = "$($d.Name).png"; Error = ''
                        } | ConvertTo-Json))
            }
            $seed = Join-Path $d.Dir 'password.seed'
            if (Test-Path -LiteralPath $seed) {
                Copy-Item -LiteralPath $seed -Destination (Join-Path $d.Dir 'taken.seed') -Force
                Remove-Item -LiteralPath $seed -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Milliseconds 150
    }
}

# The collector, played by a script that says something and takes a while.
$FakeCollector = Join-Path $WorkRoot 'Fake-Collector.ps1'
[IO.File]::WriteAllText($FakeCollector, @'
param([string]$CredentialFile, [string]$ProgressFile)
Write-Output 'fake collector: scanning 7 kiosks'
Start-Sleep -Seconds 3
Write-Output 'fake collector: done'
exit 0
'@)

# ---------------------------------------------------------------------------
# HTTP, without anything that throws on a 4xx: every answer is looked at
# ---------------------------------------------------------------------------
Add-Type -AssemblyName System.Net.Http
function New-Client {
    $h = New-Object System.Net.Http.HttpClientHandler
    $h.CookieContainer = New-Object System.Net.CookieContainer
    $h.AllowAutoRedirect = $false
    $c = New-Object System.Net.Http.HttpClient($h)
    $c.Timeout = [TimeSpan]::FromSeconds(60)
    return [pscustomobject]@{ Http = $c; Cookies = $h.CookieContainer; Csrf = $null }
}
function Invoke-Api {
    param($Client, [string]$Method = 'GET', [string]$Path, $Body, [switch]$NoCsrf, [string]$Origin, [string]$Raw)
    $req = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), "$Base$Path")
    if ($Method -ne 'GET' -and $Client.Csrf -and -not $NoCsrf) { [void]$req.Headers.TryAddWithoutValidation('X-Fleet-Csrf', $Client.Csrf) }
    if ($Origin) { [void]$req.Headers.TryAddWithoutValidation('Origin', $Origin) }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $req.Content = New-Object System.Net.Http.StringContent((ConvertTo-Json -InputObject $Body -Depth 6 -Compress), [Text.Encoding]::UTF8, 'application/json')
    }
    elseif ($Raw) { $req.Content = New-Object System.Net.Http.StringContent($Raw, [Text.Encoding]::UTF8, 'application/json') }
    $res = $Client.Http.SendAsync($req).GetAwaiter().GetResult()
    $text = $res.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $json = $null
    if ($res.Content.Headers.ContentType -and $res.Content.Headers.ContentType.MediaType -eq 'application/json') { try { $json = ConvertFrom-Json -InputObject $text } catch { } }
    $headers = @{}
    foreach ($h in $res.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
    foreach ($h in $res.Content.Headers) { $headers[$h.Key] = ($h.Value -join ', ') }
    return [pscustomobject]@{ Status = [int]$res.StatusCode; Json = $json; Text = $text; Headers = $headers; Bytes = $res.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult() }
}
function Connect-As {
    param([string]$Name, [string]$Password)
    $c = New-Client
    $r = Invoke-Api $c POST '/api/login' -Body @{ user = $Name; password = $Password }
    if ($r.Status -eq 200) { $c.Csrf = $r.Json.csrf }
    return [pscustomobject]@{ Client = $c; Login = $r }
}
function Wait-Job2 {
    # Follows a kiosk job to the end, as the page does.
    param($Client, [string]$Id, [int]$Seconds = 60)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $r = Invoke-Api $Client GET "/api/jobs/$Id"
        if ($r.Status -ne 200) { return $r.Json }
        if ($r.Json.done) { return $r.Json }
        Start-Sleep -Milliseconds 300
    }
    return $null
}
function Invoke-KioskJob {
    param($Client, [string]$HostName, [string]$Action, [hashtable]$Body = @{})
    $r = Invoke-Api $Client POST "/api/kiosks/$HostName/$Action" -Body $Body
    if ($r.Status -ne 202) { return [pscustomobject]@{ Started = $r; Job = $null } }
    return [pscustomobject]@{ Started = $r; Job = (Wait-Job2 $Client $r.Json.job) }
}
function Read-Audit {
    $p = Join-Path $LogDir 'web-audit.log'
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    return @([IO.File]::ReadAllLines($p) | Where-Object { $_ } | ForEach-Object { ConvertFrom-Json -InputObject $_ })
}

# ---------------------------------------------------------------------------
Start-Section 'Local accounts'
# ---------------------------------------------------------------------------
$SetUser = Join-Path $FleetRoot 'Set-FleetWebUser.ps1'
$AdminPass = 'Correct-Horse-42!'
$OpPass = 'Battery-Staple-77?'
& $SetUser -Name webadmin -Role admin -Password (ConvertTo-SecureString $AdminPass -AsPlainText -Force) -UsersFile $UsersFile | Out-Null
& $SetUser -Name webop -Role operator -Password (ConvertTo-SecureString $OpPass -AsPlainText -Force) -UsersFile $UsersFile | Out-Null
$usersText = [IO.File]::ReadAllText($UsersFile)
Test-Check 'two accounts are written' (@((ConvertFrom-Json $usersText).Users).Count -eq 2)
Test-Check 'no password is stored, only a hash' (($usersText -notmatch [regex]::Escape($AdminPass)) -and ($usersText -match 'PBKDF2-SHA256'))
$weak = $null
try { & $SetUser -Name weakling -Role operator -Password (ConvertTo-SecureString 'short' -AsPlainText -Force) -UsersFile $UsersFile | Out-Null } catch { $weak = $_.Exception.Message }
Test-Check 'a weak password is refused' ($weak -match 'stronger') $weak

# ---------------------------------------------------------------------------
Start-Section 'The server starts'
# ---------------------------------------------------------------------------
$psExe = (Get-Process -Id $PID).Path
$serverArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f (Join-Path $FleetRoot 'Start-FleetWeb.ps1')),
    '-Prefix', "http://localhost:$Port/", '-NoWindowsAuth', '-UsersFile', ('"{0}"' -f $UsersFile), '-CsvPath', ('"{0}"' -f $Csv),
    '-RootTemplate', ('"{0}"' -f $Template), '-CredentialFile', ('"{0}"' -f (Join-Path $WorkRoot 'no-such.cred.xml')),
    '-CollectorPath', ('"{0}"' -f $FakeCollector), '-LogDir', ('"{0}"' -f $LogDir), '-RefreshSeconds', '1')
$serverOut = Join-Path $WorkRoot 'server.out.txt'
$serverErr = Join-Path $WorkRoot 'server.err.txt'
$server = Start-Process -FilePath $psExe -ArgumentList ($serverArgs -join ' ') -PassThru -RedirectStandardOutput $serverOut -RedirectStandardError $serverErr

try {
    $anon = New-Client
    $up = $false
    for ($i = 0; $i -lt 60 -and -not $up; $i++) {
        Start-Sleep -Milliseconds 500
        try { $r = Invoke-Api $anon GET '/api/me'; $up = ($r.Status -in @(200, 401)) } catch { }
        if ($server.HasExited) { break }
    }
    Test-Check 'it answers' $up $(if (-not $up) { (Get-Content -Raw -ErrorAction SilentlyContinue $serverErr) + (Get-Content -Raw -ErrorAction SilentlyContinue $serverOut) })
    if (-not $up) { throw 'the server did not start' }

    $page = Invoke-Api $anon GET '/'
    Test-Check 'the page is served' ($page.Status -eq 200 -and $page.Text -match '<title>Kiosk Fleet</title>')
    Test-Check 'with a content security policy' ($page.Headers['Content-Security-Policy'] -match "default-src 'self'")
    Test-Check 'and cannot be framed' ($page.Headers['X-Frame-Options'] -eq 'DENY')
    $js = Invoke-Api $anon GET '/app.js'
    Test-Check 'the script is served as JavaScript' ($js.Status -eq 200 -and $js.Headers['Content-Type'] -like 'text/javascript*')
    $me = Invoke-Api $anon GET '/api/me'
    Test-Check 'signed out, /api/me says how to sign in' ($me.Status -eq 401 -and $me.Json.methods.local -eq $true -and $me.Json.methods.windows -eq $false)
    Test-Check 'signed out, the fleet is not served' ((Invoke-Api $anon GET '/api/state').Status -eq 401)
    Test-Check 'signed out, nothing can be done to a kiosk' ((Invoke-Api $anon POST '/api/kiosks/MWEB1/reload' -Body @{}).Status -eq 401)
    Test-Check 'a path outside the page is not served' ((Invoke-Api $anon GET '/../Start-FleetWeb.ps1').Status -eq 404)

    # -----------------------------------------------------------------------
    Start-Section 'Signing in'
    # -----------------------------------------------------------------------
    $bad = Connect-As 'webop' 'wrong-password'
    Test-Check 'a wrong password is refused' ($bad.Login.Status -eq 401) $bad.Login.Json.error
    $ghost = Connect-As 'nobody' 'whatever-it-is'
    Test-Check 'an unknown name gets the same answer' ($ghost.Login.Status -eq 401 -and $ghost.Login.Json.error -eq $bad.Login.Json.error)
    $op = Connect-As 'webop' $OpPass
    Test-Check 'the operator signs in' ($op.Login.Status -eq 200 -and $op.Login.Json.role -eq 'operator') "$($op.Login.Status)"
    $cookie = $op.Login.Headers['Set-Cookie']
    Test-Check 'the session cookie is HttpOnly and SameSite=Strict' ($cookie -match 'HttpOnly' -and $cookie -match 'SameSite=Strict') $cookie
    Test-Check 'the operator may not deploy' (@($op.Login.Json.allowed) -notcontains 'deploy' -and @($op.Login.Json.allowed) -contains 'reload')
    $adm = Connect-As 'WEBADMIN' $AdminPass
    Test-Check 'the admin signs in (name in any case)' ($adm.Login.Status -eq 200 -and $adm.Login.Json.role -eq 'admin')
    $O = $op.Client
    $A = $adm.Client

    # -----------------------------------------------------------------------
    Start-Section 'The fleet'
    # -----------------------------------------------------------------------
    $st = Invoke-Api $O GET '/api/state'
    $fleet = $st.Json.fleet
    Test-Check 'the state is served' ($st.Status -eq 200 -and $fleet.Ok -eq $true) "$($st.Status)"
    Test-Check 'every kiosk is in it' (@($fleet.Kiosks).Count -eq 7) "$(@($fleet.Kiosks).Count)"
    Test-Check 'the attention count is right' ($fleet.Attention -eq 3) "$($fleet.Attention)"
    Test-Check 'tabs are counted' ($fleet.Tabs.Mach2.Count -eq 3 -and $fleet.Tabs.PBI.Count -eq 3 -and $fleet.Tabs.Other.Count -eq 1)
    Test-Check 'seven days of reboots' (@($fleet.Chart).Count -eq 7 -and (@($fleet.Chart | ForEach-Object { $_.Count }) | Measure-Object -Sum).Sum -eq 3)
    $m1 = @($fleet.Kiosks | Where-Object { $_.Host -eq 'MWEB1' })[0]
    Test-Check 'a kiosk carries its launcher per tab' ($m1.Launchers.Mach2.State -eq 'SHOWING' -and $m1.Launchers.Mach2.Screen -eq '72%')
    Test-Check 'a kiosk carries its details' (@($m1.Detail | Where-Object { $_.Title -eq 'MACH2 LAUNCHER NG' }).Count -eq 1)
    Test-Check 'and arrays stay arrays' ($m1.Days -is [array] -and $m1.Tabs -is [array])
    $m3 = @($fleet.Kiosks | Where-Object { $_.Host -eq 'MWEB3' })[0]
    Test-Check 'an old watchdog cannot take a message' ($m3.MessageOk -eq $false -and $m3.MessageWhy -match '7\.0')
    Test-Check 'freshness is worked out' ($st.Json.live.fresh.text -match 'collected') $st.Json.live.fresh.text
    $same = Invoke-Api $O GET ("/api/state?since=" + [uri]::EscapeDataString($st.Json.live.stamp))
    Test-Check 'an unchanged fleet is not sent again' ($same.Status -eq 200 -and $null -eq $same.Json.fleet)

    # -----------------------------------------------------------------------
    Start-Section 'What an operator may not do'
    # -----------------------------------------------------------------------
    foreach ($act in @('restart', 'hold', 'stop', 'password', 'config-read', 'config-write')) {
        $r = Invoke-Api $O POST "/api/kiosks/MWEB1/$act" -Body @{ kind = 'NG'; instance = 'S1'; seconds = 0; password = 'x'; password2 = 'x' }
        Test-Check "no $act" ($r.Status -eq 403) "$($r.Status)"
    }
    Test-Check 'no deploy' ((Invoke-Api $O POST '/api/deploy' -Body @{ product = 'NG'; hosts = @('MWEB1') }).Status -eq 403)
    Test-Check 'no deploy preview' ((Invoke-Api $O POST '/api/deploy/preview' -Body @{ product = 'NG'; hosts = @('MWEB1') }).Status -eq 403)
    Test-Check 'no auto-scan' ((Invoke-Api $O POST '/api/autoscan' -Body @{ on = $true }).Status -eq 403)
    Test-Check 'no audit log' ((Invoke-Api $O GET '/api/audit').Status -eq 403)
    Test-Check 'the restart that was refused is in the audit log' (@(Read-Audit | Where-Object { $_.User -eq 'webop' -and $_.Action -eq 'restart' -and $_.Result -eq 'refused' }).Count -eq 1)
    Test-Check 'nothing was dropped on the kiosk' (-not (Test-Path -LiteralPath (Join-Path $ngDir 'hold.txt')) -and -not (Test-Path -LiteralPath (Join-Path $ngDir 'kill.txt')))

    # -----------------------------------------------------------------------
    Start-Section 'The page cannot be used from somewhere else'
    # -----------------------------------------------------------------------
    Test-Check 'a POST without the CSRF token is refused' ((Invoke-Api $O POST '/api/kiosks/MWEB1/reload' -Body @{} -NoCsrf).Status -eq 403)
    Test-Check 'a POST from another origin is refused' ((Invoke-Api $O POST '/api/kiosks/MWEB1/reload' -Body @{} -Origin 'http://evil.example').Status -eq 403)
    Test-Check 'a sign-in from another origin is refused' ((Invoke-Api (New-Client) POST '/api/login' -Body @{ user = 'webop'; password = $OpPass } -Origin 'http://evil.example').Status -eq 403)
    Test-Check 'a body that is not JSON is refused' ((Invoke-Api $O POST '/api/kiosks/MWEB1/reload' -Raw '{not json').Status -eq 400)
    Test-Check 'a kiosk name with a path in it is refused' ((Invoke-Api $O POST '/api/kiosks/..%5C..%5Cetc/live' -Body @{}).Status -in @(400, 404))
    Test-Check 'a kiosk not in the scan is refused' ((Invoke-Api $O POST '/api/kiosks/NOPE1/live' -Body @{}).Status -eq 404)
    Test-Check 'a screen the kiosk does not have is refused' ((Invoke-Api $O POST '/api/kiosks/MWEB1/reload' -Body @{ screen = 'S7'; kind = 'NG' }).Status -eq 400)
    Test-Check 'a picture outside the snapshot folder is not served' ((Invoke-Api $O GET '/api/snapshots/..%2F..%2Fweb-users.png').Status -eq 404)
    Test-Check 'a report outside the logs is not served' ((Invoke-Api $O GET '/api/reports/..%2Fweb-users.json').Status -eq 404)

    # -----------------------------------------------------------------------
    Start-Section 'What an operator can do'
    # -----------------------------------------------------------------------
    $r = Invoke-KioskJob $O 'MWEB1' 'reload'
    Test-Check 'reload is started' ($r.Started.Status -eq 202) "$($r.Started.Status) $($r.Started.Json.error)"
    Test-Check 'and the launcher took it' ($r.Job.ok -and $r.Job.detail -match 'taken') $r.Job.detail
    $taken = Join-Path $ngDir 'taken.refresh.txt'
    Test-Check 'the control file says who asked' ((Test-Path -LiteralPath $taken) -and ([IO.File]::ReadAllText($taken) -match 'webop \(operator\)'))
    $r = Invoke-KioskJob $O 'PWEB1' 'relaunch'
    Test-Check 'restart the browser on a Power BI kiosk' ($r.Job.ok -and (Test-Path -LiteralPath (Join-Path $pbiDir 'taken.relaunch.txt'))) $r.Job.detail
    $r = Invoke-KioskJob $O 'PWEB1' 'live'
    Test-Check 'read live' ($r.Job.ok -and @($r.Job.result.lines | Where-Object { $_.Label -eq 'Signs in as' -and $_.Value -eq 'kiosk@contoso.test' }).Count -eq 1) $r.Job.detail
    $st = Invoke-Api $O GET '/api/state'
    Test-Check 'the live read is on the kiosk card for everyone' ($null -ne $st.Json.live.live.PWEB1)
    $r = Invoke-KioskJob $O 'MWEB1' 'snapshot'
    Test-Check 'a screenshot comes back' ($r.Job.ok -and $r.Job.result.file -match '^MWEB1_S1_.*\.png$') $r.Job.detail
    if ($r.Job.result.file) {
        $img = Invoke-Api $O GET "/api/snapshots/$($r.Job.result.file)"
        Test-Check 'and is served as a picture' ($img.Status -eq 200 -and $img.Headers['Content-Type'] -eq 'image/png' -and $img.Bytes.Length -gt 50)
    }
    $r = Invoke-KioskJob $O 'MWEB1' 'log'
    Test-Check 'the launcher log' ($r.Job.ok -and ($r.Job.result.lines -join "`n") -match 'The dashboard is on screen') $r.Job.detail
    $r = Invoke-Api $O POST '/api/kiosks/PWEB1/message' -Body @{ text = 'hello'; seconds = 30 }
    Test-Check 'a message to a Power BI kiosk is refused (no watchdog)' ($r.Status -eq 400) $r.Json.error
    $r = Invoke-Api $O POST '/api/kiosks/MWEB1/message' -Body @{ text = ''; seconds = 30 }
    Test-Check 'an empty message is refused' ($r.Status -eq 400) $r.Json.error
    $r = Invoke-Api $A GET "/api/jobs/doesnotexist0000"
    Test-Check 'an unknown job is not found' ($r.Status -eq 404)

    # -----------------------------------------------------------------------
    Start-Section 'What an admin can do'
    # -----------------------------------------------------------------------
    $r = Invoke-KioskJob $A 'MWEB1' 'hold'
    Test-Check 'hold' ($r.Job.ok -and (Test-Path -LiteralPath (Join-Path $ngDir 'hold.txt'))) $r.Job.detail
    Test-Check 'the hold is on the card' ((Invoke-Api $O GET '/api/state').Json.live.hold.MWEB1 -eq $true)
    $r = Invoke-KioskJob $A 'MWEB1' 'resume'
    Test-Check 'resume' ($r.Job.ok -and -not (Test-Path -LiteralPath (Join-Path $ngDir 'hold.txt'))) $r.Job.detail
    $r = Invoke-Api $A POST '/api/kiosks/MWEB1/restart' -Body @{ message = 'x'; seconds = 99999 }
    Test-Check 'a restart with a silly countdown is refused before it goes anywhere' ($r.Status -eq 400) $r.Json.error
    $r = Invoke-Api $A POST '/api/kiosks/PWEB1/password' -Body @{ password = 'One-Secret-1'; password2 = 'Another-1' }
    Test-Check 'two different passwords are refused' ($r.Status -eq 400) $r.Json.error
    $secret = 'Kiosk-Sign-In-' + (Get-Random)
    $r = Invoke-KioskJob $A 'PWEB1' 'password' @{ password = $secret; password2 = $secret }
    Test-Check 'the sign-in password is handed over' ($r.Job.ok -and ([IO.File]::ReadAllText((Join-Path $pbiDir 'taken.seed')) -eq $secret)) $r.Job.detail
    Test-Check 'and is not in the audit log or the server log' (
        -not ([IO.File]::ReadAllText((Join-Path $LogDir 'web-audit.log')) -match [regex]::Escape($secret)) -and
        -not ((Get-Content -Raw -ErrorAction SilentlyContinue (Join-Path $LogDir 'fleet-web.log')) -match [regex]::Escape($secret)))

    # -----------------------------------------------------------------------
    Start-Section 'The config editor'
    # -----------------------------------------------------------------------
    $r = Invoke-KioskJob $A 'MWEB1' 'config-read' @{ kind = 'NG'; instance = 'S1' }
    $f = @($r.Job.result.fields)
    Test-Check 'a config is read' ($r.Job.ok -and -not $r.Job.result.isNew -and @($f | Where-Object { $_.Key -eq 'DisplayURL' -and $_.Value -eq 'http://station:302/ord/dashboard' }).Count -eq 1) $r.Job.detail
    Test-Check 'with a password field and the rest as more settings' (@($f | Where-Object { $_.Kind -eq 'password' }).Count -eq 1 -and @($f | Where-Object { $_.Key -eq 'Watchdog' -and $_.Kind -eq 'bool' -and $_.Advanced }).Count -eq 1)
    $values = @{}
    foreach ($x in $f) { if ($x.Kind -ne 'password') { $values[$x.Key] = $x.Value } }
    $values['DisplayURL'] = 'http://station:302/ord/other'
    $values['Injected'] = 'should not appear'
    $r = Invoke-KioskJob $A 'MWEB1' 'config-write' @{ kind = 'NG'; instance = 'S1'; values = $values; password = ''; password2 = '' }
    $cfg = ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $ngDir 'MWEB1.json')))
    Test-Check 'a change is saved' ($r.Job.ok -and $cfg.DisplayURL -eq 'http://station:302/ord/other') $r.Job.detail
    Test-Check 'a key the file does not have is not added' (-not $cfg.PSObject.Properties['Injected'])
    Test-Check 'the old one is kept' (@(Get-ChildItem -LiteralPath $ngDir -Filter 'MWEB1.json.bak-*').Count -ge 1)
    $r = Invoke-Api $A POST '/api/kiosks/MWEB1/config-write' -Body @{ kind = 'NG'; instance = 'S1'; values = @{ DisplayURL = '' } }
    Test-Check 'a required setting left empty is refused' ($r.Status -eq 400) $r.Json.error
    $r = Invoke-KioskJob $A 'NEWWEB1' 'config-read' @{ kind = 'WEB' }
    Test-Check 'a new kiosk gets EXAMPLE.json' ($r.Job.ok -and $r.Job.result.isNew -and @($r.Job.result.fields | Where-Object { $_.Key -eq 'LogName' -and $_.Value -eq 'WebLauncher_NEWWEB1.log' }).Count -eq 1) $r.Job.detail
    $vals = @{}
    foreach ($x in @($r.Job.result.fields)) { if ($x.Kind -ne 'password') { $vals[$x.Key] = $x.Value } }
    $vals['DisplayURL'] = 'https://intranet.test/board'
    $r = Invoke-KioskJob $A 'NEWWEB1' 'config-write' @{ kind = 'WEB'; instance = 'S1'; values = $vals }
    $newCfg = P ($Template -f 'NEWWEB1') 'Users\Public\Documents\WebLauncher\S1\NEWWEB1.json'
    Test-Check 'and it is written where the deploy looks' ($r.Job.ok -and (Test-Path -LiteralPath $newCfg) -and (ConvertFrom-Json ([IO.File]::ReadAllText($newCfg))).DisplayURL -eq 'https://intranet.test/board') $r.Job.detail
    $r = Invoke-KioskJob $A 'NEWWEB1' 'config-write' @{ kind = 'NG'; instance = 'S1'; values = @{ DisplayURL = 'http://s/d'; UserName = 'u' } }
    Test-Check 'a screen another launcher has is refused' (-not $r.Job.ok -and $r.Job.detail -match 'one launcher per screen') $r.Job.detail

    # -----------------------------------------------------------------------
    Start-Section 'Deploy'
    # -----------------------------------------------------------------------
    $r = Invoke-Api $A POST '/api/deploy/preview' -Body @{ product = 'NG'; hosts = @('MWEB2', 'MWEB1'); restart = $true; warnSeconds = 30; verifyMinutes = 10; keepWatchdog = $true }
    Test-Check 'the command is built' ($r.Status -eq 200 -and $r.Json.command -eq "& '.\Deploy-Mach2LauncherNG.ps1' -Hosts 'MWEB1','MWEB2' -Restart -RestartWarningSeconds 30 -VerifyMinutes 10 -KeepWatchdog") $r.Json.command
    $r = Invoke-Api $A POST '/api/deploy/preview' -Body @{ product = 'PBI'; hosts = @('PWEB1'); rollback = $true; updateConfig = $true; keepLegacy = $true }
    Test-Check 'a roll back drops what does not apply' ($r.Json.command -eq "& '.\Deploy-PbiLauncher.ps1' -Hosts 'PWEB1' -Rollback") $r.Json.command
    $r = Invoke-Api $A POST '/api/deploy/preview' -Body @{ product = 'WATCHDOG'; hosts = @('MWEB3'); rollback = $true; restart = $true; registerTask = $true; kioskUser = 'kiosk1' }
    Test-Check 'the old watchdog has its own switches' ($r.Json.command -eq "& '.\Deploy-MWSTAgent.ps1' -Hosts 'MWEB3' -RebootAndVerify -RebootWarningSeconds 60 -RegisterLauncherTask") $r.Json.command
    $r = Invoke-Api $A POST '/api/deploy/preview' -Body @{ product = 'NG'; hosts = @("x'; Remove-Item C:\ -Recurse; '") }
    Test-Check 'a kiosk name with code in it is refused' ($r.Status -eq 400) $r.Json.error
    $r = Invoke-Api $A POST '/api/deploy/preview' -Body @{ product = 'NG'; hosts = @('MWEB1'); kioskUser = "a'b" }
    Test-Check 'an account name with a quote in it is refused' ($r.Status -eq 400) $r.Json.error
    $r = Invoke-Api $A POST '/api/deploy/preview' -Body @{ product = 'EVIL'; hosts = @('MWEB1') }
    Test-Check 'an unknown product is refused' ($r.Status -eq 400) $r.Json.error
    $r = Invoke-Api $A POST '/api/deploy/preview' -Body @{ product = 'NG'; hosts = @() }
    Test-Check 'no kiosks ticked is refused' ($r.Status -eq 400) $r.Json.error

    # -----------------------------------------------------------------------
    Start-Section 'Scanning'
    # -----------------------------------------------------------------------
    $r = Invoke-Api $O POST '/api/scan'
    Test-Check 'an operator can start a scan' ($r.Status -eq 202) "$($r.Status) $($r.Json.error)"
    $r2 = Invoke-Api $A POST '/api/scan'
    Test-Check 'a second one waits for the first' ($r2.Status -eq 409) $r2.Json.error
    $deadline = (Get-Date).AddSeconds(40)
    $out = $null
    do {
        Start-Sleep -Milliseconds 500
        $out = Invoke-Api $O GET '/api/run?from=0'
    } while ((Get-Date) -lt $deadline -and ($out.Json.running -or $out.Json.text -notmatch 'finished with code'))
    Test-Check 'its output comes through' ($out.Json.text -match 'fake collector: done') $(if ($out) { $out.Json.text.Substring(0, [math]::Min(200, $out.Json.text.Length)) })
    Test-Check 'and it finishes' ($out.Json.text -match 'finished with code 0')
    Test-Check 'it says who started it' ($out.Json.text -match 'webop \(operator\)')
    $rep = Invoke-Api $O GET '/api/reports'
    $scanOut = @($rep.Json.reports | Where-Object { $_.name -like 'scan-*.out.txt' })[0]
    Test-Check 'the output is kept as a report' ($null -ne $scanOut)
    if ($scanOut) { Test-Check 'and can be downloaded' ((Invoke-Api $O GET "/api/reports/$($scanOut.name)").Text -match 'fake collector') }

    # -----------------------------------------------------------------------
    Start-Section 'The audit log'
    # -----------------------------------------------------------------------
    $au = Invoke-Api $A GET '/api/audit'
    Test-Check 'an admin can read it' ($au.Status -eq 200 -and @($au.Json.entries).Count -gt 10) "$(@($au.Json.entries).Count) entries"
    $log = @(Read-Audit)
    Test-Check 'sign-ins are in it' (@($log | Where-Object { $_.Action -eq 'sign-in' -and $_.Result -eq 'ok' -and $_.User -eq 'webop' }).Count -ge 1)
    Test-Check 'wrong passwords are in it' (@($log | Where-Object { $_.Action -eq 'sign-in' -and $_.Result -eq 'failed' }).Count -ge 2)
    Test-Check 'what was done, by whom, and how it went' (@($log | Where-Object { $_.Action -eq 'reload' -and $_.User -eq 'webop' -and $_.Result -eq 'ok' -and $_.Target -eq 'MWEB1' }).Count -eq 1)
    Test-Check 'config changes say what changed' (@($log | Where-Object { $_.Action -eq 'config-write' -and $_.Detail -match 'DisplayURL=http://station:302/ord/other' }).Count -ge 1)

    # -----------------------------------------------------------------------
    Start-Section 'Locking out, disabling and signing out'
    # -----------------------------------------------------------------------
    for ($i = 0; $i -lt 5; $i++) { [void](Connect-As 'webadmin' 'not-the-password') }
    $locked = Connect-As 'webadmin' $AdminPass
    Test-Check 'five wrong passwords lock the name for a while' ($locked.Login.Status -eq 429) "$($locked.Login.Status)"
    Test-Check 'an existing session is not affected' ((Invoke-Api $A GET '/api/state').Status -eq 200)

    & $SetUser -Name webop -Disable -UsersFile $UsersFile | Out-Null
    $gone = $false
    for ($i = 0; $i -lt 20 -and -not $gone; $i++) { Start-Sleep -Milliseconds 500; $gone = ((Invoke-Api $O GET '/api/state').Status -eq 401) }
    Test-Check 'a disabled account is signed out at once' $gone
    Test-Check 'and cannot sign in' ((Connect-As 'webop' $OpPass).Login.Status -eq 401)

    $r = Invoke-Api $A POST '/api/logout'
    Test-Check 'signing out' ($r.Status -eq 200 -and (Invoke-Api $A GET '/api/state').Status -eq 401)
}
finally {
    if ($server -and -not $server.HasExited) { try { $server.Kill() } catch { } }
    Stop-Job $launcher -ErrorAction SilentlyContinue
    Remove-Job $launcher -Force -ErrorAction SilentlyContinue
}

$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ('{0} checks, {1} failed' -f $script:Results.Count, $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
if ($failed.Count) {
    Write-Host "The server's own log: $(Join-Path $LogDir 'fleet-web.log')"
    $failed | Format-Table Section, Check, Detail -AutoSize | Out-String -Width 220 | Write-Host
}
if (-not $KeepWorkRoot -and -not $failed.Count) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue }
if ($failed.Count) { exit 1 }
