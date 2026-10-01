#Requires -Version 5.1
<#
.SYNOPSIS
    Tests how PBI Launcher fits into the fleet tools: the launcher reader in
    Lib\PBI.Launcher.ps1, the collector's statuses for Power BI kiosks, the
    dashboard's PBI tab, and its P (launcher) and D (deploy) menus.

.DESCRIPTION
    Nothing here touches a real kiosk or the published CSV. Kiosks are
    folders under -WorkRoot standing in for their C: drives, named
    127.0.0.2 - 127.0.0.7 so that they answer a ping. The collector runs from
    a copy in -WorkRoot, so its Logs\ mirror is the copy's, not the fleet's.

    The dashboard's functions are loaded without its main loop; prompts,
    key presses and the deploy scripts are replaced by stand-ins that
    record what they were asked. A small background job plays the launcher:
    it takes control files, answers snapshot.txt and stores password.seed.

    Takes about a minute.

.EXAMPLE
    .\Tests\Test-FleetIntegration.ps1
#>
[CmdletBinding()]
param(
    [string]$FleetRoot = (Join-Path $PSScriptRoot '..'),
    [string]$WorkRoot = (Join-Path $env:TEMP 'KioskFleetTests'),
    [switch]$KeepWorkRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
$FleetRoot = (Resolve-Path -LiteralPath $FleetRoot).ProviderPath
$User = 'kiosk@contoso.test'

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

if (Test-Path -LiteralPath $WorkRoot) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force }
New-Item -ItemType Directory -Path $WorkRoot -Force | Out-Null
$KioskDir = Join-Path $WorkRoot 'kiosks'
$Template = Join-Path $KioskDir '{0}'

# ---------------------------------------------------------------------------
# Fake kiosks
# ---------------------------------------------------------------------------
$PbiRel = 'Users\Public\Documents\PbiLauncher'
$BootIso = '2026-09-15T06:00:00.0000000Z'

function New-FakeKiosk {
    param([string]$Name, [switch]$Legacy, [switch]$Installed)
    $root = $Template -f $Name
    New-Item -ItemType Directory -Path (Join-Path $root 'Users\Public\Documents') -Force | Out-Null
    if ($Legacy) {
        $d = Join-Path $root 'Users\Public\Documents\Launchers\Launcher S1'
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'PowerBILauncher.exe'), 'fake')
    }
    if ($Installed) {
        $d = Join-Path $root $PbiRel
        New-Item -ItemType Directory -Path (Join-Path $d 'Status') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $d 'PbiLauncher.ps1'), '# fake')
    }
    return $root
}

function Set-FakeStatus {
    param([string]$Root, [string]$Instance, [string]$State, [string]$SignedInAs = $User,
          [double]$AgeMinutes = 0.1, [double]$StateMinutes = 30, [string]$UserName = $User, [string]$Detail = '', [string]$LastError = '')
    $now = [DateTime]::UtcNow
    $s = [ordered]@{
        Host = $Instance; Instance = $Instance; LauncherVersion = '2.0.0'; State = $State
        StateSinceUtc = $now.AddMinutes(-$StateMinutes).ToString('o'); Detail = $Detail
        UserName = $UserName; SignedInAs = $SignedInAs; EdgeVersion = 'Edg/153.0.4234.32'
        BrowserStarts = 1; Reloads = 4; SignIns = 1; LastShownUtc = $now.AddMinutes(-1).ToString('o')
        LastError = $LastError; PcBootUtc = $BootIso; UpdatedUtc = $now.AddMinutes(-$AgeMinutes).ToString('o')
    }
    $path = Join-Path $Root "$PbiRel\Status\$Instance.status.json"
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $s))
}

# ---------------------------------------------------------------------------
Start-Section 'Lib: launcher status -> host status'
# ---------------------------------------------------------------------------
. (Join-Path $FleetRoot 'Lib\MWST.Remote.ps1')
. (Join-Path $FleetRoot 'Lib\MWST.KioskList.ps1')
. (Join-Path $FleetRoot 'Lib\PBI.Launcher.ps1')

$cases = @(
    @{ State = 'SHOWING'; Age = 0.2; Expect = 'OK' }
    @{ State = 'BROWSING'; Age = 0.2; Expect = 'OK' }
    @{ State = 'SHOWING'; Age = 9; Expect = 'LAUNCHER_STALE' }
    @{ State = 'SHOWING'; Age = $null; Expect = 'LAUNCHER_STALE' }
    @{ State = 'STOPPED'; Age = 900; Expect = 'LAUNCHER_STOPPED' }
    @{ State = 'DISABLED'; Age = 900; Expect = 'LAUNCHER_DISABLED' }
    @{ State = 'ERROR'; Age = 0.2; Expect = 'LAUNCHER_ERROR' }
    @{ State = 'SIGNIN_BLOCKED'; Age = 0.2; Expect = 'SIGNIN_BLOCKED' }
    @{ State = 'RECOVERING'; Age = 0.2; Expect = 'RECOVERING' }
    @{ State = 'WAITING_DISPLAY'; Age = 0.2; Expect = 'NO_DISPLAY' }
    @{ State = 'HOLD'; Age = 0.2; Expect = 'HOLD' }
    @{ State = 'UNSUPERVISED'; Age = 0.2; Expect = 'UNSUPERVISED' }
    @{ State = 'SHOWING'; Age = 0.2; Signed = 'someone@contoso.test'; Expect = 'WRONG_ACCOUNT' }
    @{ State = 'SHOWING'; Age = 0.2; Signed = 'KIOSK@CONTOSO.TEST'; Expect = 'OK' }
    @{ State = 'LOADING'; Age = 0.2; StateMin = 16; Expect = 'NOT_SHOWING' }
    @{ State = 'SIGNING_IN'; Age = 0.2; StateMin = 3; Expect = 'OK' }
)
$bad = @()
foreach ($c in $cases) {
    $signed = if ($c.ContainsKey('Signed')) { $c.Signed } else { $User }
    $inst = [pscustomobject]@{ State = $c.State; AgeMinutes = $c.Age; StateMinutes = $(if ($c.StateMin) { $c.StateMin } else { 1 }); UserName = $User; SignedInAs = $signed }
    $got = (Get-PbiInstanceStatus -Instance $inst)[0]
    if ($got -ne $c.Expect) { $bad += "$($c.State)/$($c.Age)/$signed -> $got (expected $($c.Expect))" }
}
Test-Check "all $($cases.Count) state mappings" ($bad.Count -eq 0) ($bad -join '; ')
Test-Check 'user names are compared without case' ((Get-PbiInstanceStatus -Instance ([pscustomobject]@{ State = 'SHOWING'; AgeMinutes = 0; StateMinutes = 0; UserName = 'A@B.C'; SignedInAs = 'a@b.c' }))[0] -eq 'OK')

$r = New-FakeKiosk 'lib-none'
$o = Get-PbiLauncherObservation -Root $r
Test-Check 'no launcher at all: not installed, no status, launcher=none' (-not $o.Installed -and -not $o.LegacyLauncher -and $null -eq $o.Status -and $o.Summary -eq 'launcher=none')

$r = New-FakeKiosk 'lib-old' -Legacy
$o = Get-PbiLauncherObservation -Root $r
Test-Check 'old launcher only: launcher=old, no status' ($o.LegacyLauncher -and -not $o.Installed -and $null -eq $o.Status -and $o.Summary -eq 'launcher=old')

$r = New-FakeKiosk 'lib-notrun' -Installed -Legacy
$o = Get-PbiLauncherObservation -Root $r
Test-Check 'installed, never started: LAUNCHER_NOT_RUN' ($o.Installed -and $o.LegacyLauncher -and $o.Status -eq 'LAUNCHER_NOT_RUN' -and $o.Severity -eq 'WARNING') $o.Status

$r = New-FakeKiosk 'lib-two' -Installed
Set-FakeStatus -Root $r -Instance 'LEFT' -State 'SHOWING'
Set-FakeStatus -Root $r -Instance 'RIGHT' -State 'SIGNIN_BLOCKED' -StateMinutes 5
$o = Get-PbiLauncherObservation -Root $r
Test-Check 'two launchers: the worse one decides' ($o.Status -eq 'SIGNIN_BLOCKED' -and @($o.Instances).Count -eq 2) $o.Status
Test-Check 'summary lists both, with the account' ($o.Summary -match 'launcher=S1:SHOWING as=kiosk@contoso.test' -and $o.Summary -match 'launcher=S1:SIGNIN_BLOCKED') $o.Summary
Test-Check 'PC start time and version come through' ($o.PcBootUtc -and $o.PcBootUtc.Kind -eq 'Utc' -and $o.PcBootUtc.Hour -eq 6 -and $o.LauncherVersion -eq '2.0.0') ("{0:o} v{1}" -f $o.PcBootUtc, $o.LauncherVersion)

$r = New-FakeKiosk 'lib-broken' -Installed
[IO.File]::WriteAllText((Join-Path $r "$PbiRel\Status\X.status.json"), '{ half a file')
$o = Get-PbiLauncherObservation -Root $r
Test-Check 'unreadable status file: LAUNCHER_NOT_RUN, no exception' ($o.Status -eq 'LAUNCHER_NOT_RUN' -and $o.Summary -match 'unreadable') $o.Summary

$r = New-FakeKiosk 'lib-oldstatus' -Installed
# A status file from before PcBootUtc / SignedInAs existed
[IO.File]::WriteAllText((Join-Path $r "$PbiRel\Status\OLD.status.json"), (ConvertTo-Json @{ Instance = 'OLD'; State = 'SHOWING'; LauncherVersion = '2.0.0'; UpdatedUtc = [DateTime]::UtcNow.ToString('o'); StateSinceUtc = [DateTime]::UtcNow.ToString('o') }))
$o = Get-PbiLauncherObservation -Root $r
Test-Check 'status file without the newer fields still reads OK' ($o.Status -eq 'OK' -and -not $o.PcBootUtc) $o.Status

$o = Get-PbiLauncherObservation -Root (Join-Path $KioskDir 'lib-two')
$entry = ConvertTo-PbiSidecarEntry -Observation $o
$back = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $entry -Depth 8)
Test-Check 'sidecar entry survives JSON with both instances' ($back.Installed -and @($back.Instances).Count -eq 2 -and @($back.Instances | Where-Object { $_.Instance -eq 'LEFT' })[0].SignedInAs -eq $User -and $back.Instances[0].UpdatedUtc -match 'Z$')

# ---------------------------------------------------------------------------
Start-Section 'Collector: Power BI kiosks'
# ---------------------------------------------------------------------------
$sandbox = Join-Path $WorkRoot 'fleet'
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $FleetRoot 'Collect-MWSTFleet.ps1') -Destination $sandbox
Copy-Item -LiteralPath (Join-Path $FleetRoot 'Lib') -Destination $sandbox -Recurse

$k2 = New-FakeKiosk '127.0.0.2' -Installed -Legacy
Set-FakeStatus -Root $k2 -Instance '127.0.0.2' -State 'SHOWING'
[IO.File]::WriteAllText((Join-Path $k2 "$PbiRel\127.0.0.2.json"), (ConvertTo-Json @{ DisplayURL = 'https://app.powerbi.com/groups/me/reports/abc'; UserName = $User; LogPath = ''; LogName = 'PbiLauncher_TEST.log' }))
[IO.File]::WriteAllText((Join-Path $k2 "$PbiRel\127.0.0.2.cred"), 'fake')
$k3 = New-FakeKiosk '127.0.0.3' -Installed
Set-FakeStatus -Root $k3 -Instance '127.0.0.3' -State 'SHOWING' -SignedInAs 'SHAPE-USER@contoso.test'
$null = New-FakeKiosk '127.0.0.4' -Legacy
$k5 = New-FakeKiosk '127.0.0.5' -Installed
Set-FakeStatus -Root $k5 -Instance '127.0.0.5' -State 'SHOWING' -AgeMinutes 30
$k6 = New-FakeKiosk '127.0.0.6' -Installed
Set-FakeStatus -Root $k6 -Instance '127.0.0.6' -State 'SIGNIN_BLOCKED' -Detail 'Microsoft asks for the password, and none is stored.'
$null = New-FakeKiosk '127.0.0.7'

$list = Join-Path $WorkRoot 'kiosks.csv'
@(
    [pscustomobject]@{ Host = '127.0.0.2'; Location = 'PBI GOOD'; Type = 'PBI - SR'; Active = 'Y'; HasMwst = '' }
    [pscustomobject]@{ Host = '127.0.0.3'; Location = 'PBI WRONG'; Type = 'PBI'; Active = 'Y'; HasMwst = '' }
    [pscustomobject]@{ Host = '127.0.0.4'; Location = 'PBI OLD'; Type = 'PBI'; Active = 'Y'; HasMwst = '' }
    [pscustomobject]@{ Host = '127.0.0.5'; Location = 'PBI STALE'; Type = 'Power BI'; Active = 'Y'; HasMwst = '' }
    [pscustomobject]@{ Host = '127.0.0.6'; Location = 'PBI BLOCKED'; Type = 'PBI'; Active = 'Y'; HasMwst = '' }
    [pscustomobject]@{ Host = '127.0.0.7'; Location = 'MACH LINE'; Type = 'Mach2'; Active = 'Y'; HasMwst = 'Y' }
) | Export-Csv -LiteralPath $list -NoTypeInformation

$csv = Join-Path $WorkRoot 'out\MWST_FleetEvents.csv'
New-Item -ItemType Directory -Path (Split-Path -Parent $csv) -Force | Out-Null
function Invoke-Collector {
    $argv = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $sandbox 'Collect-MWSTFleet.ps1'),
              '-KioskList', $list, '-OutputCsv', $csv, '-KioskRootTemplate', $Template,
              '-AgentPathTemplate', (Join-Path $Template 'Users\Public\Documents'))
    # One collector at a time per PC: if the Kiosk Fleet Manager's auto-scan
    # or the scheduled task is scanning the real fleet, wait for it.
    $deadline = (Get-Date).AddMinutes(12)
    while ($true) {
        $out = & powershell.exe @argv 2>&1 | Out-String
        if ($out -notmatch 'Another collector run is in progress' -or (Get-Date) -gt $deadline) { break }
        Write-Host '  (a real scan is running on this PC; waiting for it to finish)' -ForegroundColor DarkGray
        Start-Sleep -Seconds 20
    }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = $out }
}
function Get-StatusRows {
    $rows = @(Import-Csv -LiteralPath $csv | Where-Object { $_.EventType -eq 'HOST_STATUS' })
    $latest = @{}
    foreach ($row in $rows) {
        if (-not $latest.ContainsKey($row.Host) -or [string]::CompareOrdinal($row.EventTimeUtc, $latest[$row.Host].EventTimeUtc) -gt 0) { $latest[$row.Host] = $row }
    }
    return [pscustomobject]@{ All = $rows; Latest = $latest }
}

$run = Invoke-Collector
Test-Check 'collector run completes' (Test-Path -LiteralPath $csv) ("exit {0}" -f $run.Code)
if (-not (Test-Path -LiteralPath $csv)) { Write-Host $run.Output }
$s = Get-StatusRows
$L = $s.Latest
$expect = @{ '127.0.0.2' = 'OK'; '127.0.0.3' = 'WRONG_ACCOUNT'; '127.0.0.4' = 'OK'; '127.0.0.5' = 'LAUNCHER_STALE'; '127.0.0.6' = 'SIGNIN_BLOCKED'; '127.0.0.7' = 'NO_AGENT' }
foreach ($h in ($expect.Keys | Sort-Object)) {
    $got = if ($L.ContainsKey($h)) { $L[$h].Outcome } else { '(no row)' }
    Test-Check ("{0} ({1}) -> {2}" -f $h, $(if ($L[$h]) { $L[$h].Location } else { '' }), $expect[$h]) ($got -eq $expect[$h]) $got
}
Test-Check 'severity follows: WRONG_ACCOUNT and SIGNIN_BLOCKED are CRITICAL' ($L['127.0.0.3'].Severity -eq 'CRITICAL' -and $L['127.0.0.6'].Severity -eq 'CRITICAL')
Test-Check 'launcher kiosks report pbi-<version> as agent' ($L['127.0.0.2'].AgentVersion -eq 'pbi-2.0.0') $L['127.0.0.2'].AgentVersion
Test-Check 'old-launcher kiosk has no agent version' (-not $L['127.0.0.4'].AgentVersion) $L['127.0.0.4'].AgentVersion
Test-Check 'Power BI kiosks leave WatchdogRunning empty' (-not $L['127.0.0.2'].WatchdogRunning -and -not $L['127.0.0.3'].WatchdogRunning)
Test-Check 'boot time comes from the launcher' ($L['127.0.0.2'].BootTimeUtc -eq '2026-09-15T06:00:00Z' -and $L['127.0.0.2'].UptimeHours) ("{0} up {1} h" -f $L['127.0.0.2'].BootTimeUtc, $L['127.0.0.2'].UptimeHours)
Test-Check 'detail carries the launcher summary' ($L['127.0.0.2'].Detail -match 'launcher=S1:SHOWING as=kiosk@contoso.test' -and $L['127.0.0.4'].Detail -match 'launcher=old') $L['127.0.0.2'].Detail
$side = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText([IO.Path]::ChangeExtension($csv, '.status.json')))
$pl = $side.PbiLaunchers
Test-Check 'status file lists every reachable Power BI kiosk' ($pl -and $pl.'127.0.0.2' -and $pl.'127.0.0.4' -and -not $pl.'127.0.0.7') (($pl.PSObject.Properties.Name) -join ',')
Test-Check 'status file keeps the details' ($pl.'127.0.0.3'.Instances[0].SignedInAs -eq 'SHAPE-USER@contoso.test' -and $pl.'127.0.0.4'.LegacyLauncher -and -not $pl.'127.0.0.4'.Installed)

$count1 = $s.All.Count
$run = Invoke-Collector
$s = Get-StatusRows
Test-Check 'an unchanged fleet adds no status rows on the next scan' ($s.All.Count -eq $count1) ("{0} -> {1}" -f $count1, $s.All.Count)

Set-FakeStatus -Root $k3 -Instance '127.0.0.3' -State 'SHOWING'
$run = Invoke-Collector
$s = Get-StatusRows
Test-Check 'a fixed account is a change: one new row, back to OK' ($s.All.Count -eq $count1 + 1 -and $s.Latest['127.0.0.3'].Outcome -eq 'OK') ("{0} rows, {1}" -f $s.All.Count, $s.Latest['127.0.0.3'].Outcome)
Set-FakeStatus -Root $k3 -Instance '127.0.0.3' -State 'SHOWING' -SignedInAs 'SHAPE-USER@contoso.test'
$run = Invoke-Collector

# ---------------------------------------------------------------------------
Start-Section 'Dashboard: PBI tab'
# ---------------------------------------------------------------------------
$dash = Join-Path $FleetRoot 'Show-FleetDashboard.ps1'
$frame = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dash -Once -Tab PBI -CsvPath $csv -NoColour -Ascii 2>&1 | Out-String
Test-Check 'renders the PBI tab' ($frame -match 'KIOSK FLEET' -and $frame -match '2 PBI \(5\)') ($frame -split "`n" | Select-Object -First 1)
Test-Check 'launcher columns are there' ($frame -match 'LAUNCHER' -and $frame -match 'SIGNED IN AS')
$line3 = @($frame -split "`r?`n" | Where-Object { $_ -match '127\.0\.0\.3 ' })[0]
Test-Check 'the wrong account is shown on its row' ($line3 -match 'WRONG_ACCOUNT' -and $line3 -match 'SHAPE-USER@conto' -and $line3 -match 'SHOWING') $line3
$line4 = @($frame -split "`r?`n" | Where-Object { $_ -match '127\.0\.0\.4 ' })[0]
Test-Check "a kiosk on the old launcher says so" ($line4 -match 'old launcher') $line4
$line5 = @($frame -split "`r?`n" | Where-Object { $_ -match '127\.0\.0\.5 ' })[0]
Test-Check 'a stale launcher shows its last state in brackets' ($line5 -match 'LAUNCHER_STALE' -and $line5 -match '\(SHOWING\)') $line5
Test-Check 'uptime is shown from the boot time' ((@($frame -split "`r?`n" | Where-Object { $_ -match '127\.0\.0\.2 ' })[0]) -match '\s\d+[hd]\s*$')
Test-Check 'status chips count the launcher statuses' ($frame -match '\* 2 OK\s+\* 1 LAUNCHER_STALE\s+\* 1 SIGNIN_BLOCKED\s+\* 1 WRONG_ACCOUNT') (@($frame -split "`r?`n" | Where-Object { $_ -match '\* \d+ OK' })[0])

$frameM = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dash -Once -Tab Mach2 -CsvPath $csv -NoColour -Ascii 2>&1 | Out-String
Test-Check 'the Mach2 tab has no launcher columns' ($frameM -notmatch 'SIGNED IN AS' -and $frameM -match '127\.0\.0\.7')

# ---------------------------------------------------------------------------
Start-Section 'Dashboard: P and D menus'
# ---------------------------------------------------------------------------
# The dashboard without its main loop: every top-level statement up to
# "$csvFile = Resolve-EventsCsv", with the parameters set here.
$ast = [Management.Automation.Language.Parser]::ParseFile($dash, [ref]$null, [ref]$null)
$sb = New-Object System.Text.StringBuilder
foreach ($st in $ast.EndBlock.Statements) {
    $text = $st.Extent.Text
    if ($text -match '^\$csvFile\s*=') { break }
    if ($text -match '^\$ScriptDir\s*=') { $text = "`$ScriptDir = '$($FleetRoot -replace "'", "''")'" }
    [void]$sb.AppendLine($text)
}
$loader = Join-Path $WorkRoot 'dashboard-functions.ps1'
[IO.File]::WriteAllText($loader, $sb.ToString())

$CsvPath = $csv; $RefreshSeconds = 5; $StaleMinutes = 45; $AutoScanMinutes = 15; $Tab = 'PBI'
$Once = $false; $Ascii = $true; $NoColour = $true; $CredentialFile = $null; $Credential = $null
$RemoteControlPath = $null; $SccmSiteServer = $null
$RestartMessage = 'test'; $RestartWarningSeconds = 60
. $loader

# Stand-ins
$KioskRootTemplate = $Template
$SnapshotDir = Join-Path $WorkRoot 'snapshots'
$script:Answers = New-Object System.Collections.Queue
$script:Prompts = New-Object System.Collections.Generic.List[string]
$script:FleetCalls = New-Object System.Collections.Generic.List[object]
$script:Opened = New-Object System.Collections.Generic.List[string]
$script:Messages = 0
function Read-Host {
    param([Parameter(Position = 0)]$Prompt, [switch]$AsSecureString)
    $script:Prompts.Add([string]$Prompt)
    if ($script:Answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
    $v = [string]$script:Answers.Dequeue()
    if ($AsSecureString) {
        $ss = New-Object Security.SecureString
        foreach ($ch in $v.ToCharArray()) { $ss.AppendChar($ch) }
        return $ss
    }
    return $v
}
function Wait-AnyKey { param([string]$Text) }
function Clear-Host { }
function Start-Sleep { param([int]$Seconds, [int]$Milliseconds) Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds ([math]::Min(200, [math]::Max($Milliseconds, 1))) }
function Get-FleetCredential { return $null }
function Invoke-FleetScript { param([string]$Path, [hashtable]$Arguments) $script:FleetCalls.Add([pscustomobject]@{ Script = (Split-Path -Leaf $Path); Args = $Arguments }) }
function Invoke-Item { param([string]$LiteralPath) $script:Opened.Add($LiteralPath) }
function Invoke-KioskMessage { $script:Messages++ }
function Set-Answers { $script:Answers.Clear(); $script:Prompts.Clear(); $script:FleetCalls.Clear(); foreach ($a in $args) { $script:Answers.Enqueue($a) } }
function Invoke-Quiet([scriptblock]$Block) { & $Block 6>&1 | Out-String -Width 1000 }

$state = Read-FleetState -Path $csv
$script:Tab = 'PBI'
$shown = @(Get-ShownHosts -State $state)
Test-Check 'the fleet state has the launcher details attached' (@($shown | Where-Object { $_.Pbi }).Count -eq 5 -and (Get-PbiDisplay -Kiosk @($shown | Where-Object { $_.Host -eq '127.0.0.6' })[0]).State -eq 'SIGNIN_BLOCKED')

foreach ($width in 100, 120, 170) {
    $lines = Build-Frame -State $state -Size ([pscustomobject]@{ Width = $width; Height = 30 })
    Add-Footer -Lines $lines -Size ([pscustomobject]@{ Width = $width; Height = 30 }) -Countdown 5
    $long = @($lines | Where-Object { $_.Length -gt $width })
    Test-Check "PBI tab fits a $width-column window" ($long.Count -eq 0) $(if ($long) { "$($long.Count) line(s), e.g. $($long[0].Length): $($long[0])" })
}
$footer = $lines[$lines.Count - 1]
Test-Check 'footer on the PBI tab offers P and D, not M' ($footer -match '\bP power bi launcher' -and $footer -match '\bD deploy' -and $footer -notmatch '\bM message') $footer
$script:Tab = 'Mach2'
$lines = Build-Frame -State $state -Size ([pscustomobject]@{ Width = 170; Height = 30 })
Add-Footer -Lines $lines -Size ([pscustomobject]@{ Width = 170; Height = 30 }) -Countdown 5
$footer = $lines[$lines.Count - 1]
Test-Check 'footer on the Mach2 tab offers M and D, not P' ($footer -match '\bM message' -and $footer -match '\bD deploy' -and $footer -notmatch '\bP power') $footer
$lines = New-Object System.Collections.Generic.List[string]
Add-Footer -Lines $lines -Size ([pscustomobject]@{ Width = 80; Height = 5 }) -Countdown 5
Test-Check 'footer shortens itself in an 80-column window' ($lines[$lines.Count - 1].Length -le 80) ("{0}: {1}" -f $lines[$lines.Count - 1].Length, $lines[$lines.Count - 1])
$script:Tab = 'PBI'

# The kiosk list the menus print
$out = Invoke-Quiet { Write-KioskList -Hosts $shown }
Test-Check 'menu kiosk list shows the launcher state and account' ($out -match '127\.0\.0\.3.*\[WRONG_ACCOUNT\]\s+SHOWING as SHAPE-USER@contoso\.test' -and $out -match '127\.0\.0\.4.*old launcher') (($out -split "`n" | Where-Object { $_ -match '127\.0\.0\.3' }) -join '')

# A stand-in launcher on 127.0.0.2
$folder = Join-Path $k2 $PbiRel
New-Item -ItemType Directory -Path (Join-Path $folder 'Logs') -Force | Out-Null
$logLines = @(
    '<![LOG[PBI Launcher start]LOG]!><time="10:00:00.000+000" date="09-17-2026" component="PbiLauncher" context="X" type="1" thread="1" file="PbiLauncher.ps1">'
    '<![LOG[Microsoft rejected the password]LOG]!><time="10:00:05.000+000" date="09-17-2026" component="PbiLauncher" context="X" type="3" thread="1" file="PbiLauncher.ps1">'
    "<![LOG[The page keeps refusing to be read: first line`r`n    at second line]LOG]!><time=`"10:00:09.000+000`" date=`"09-17-2026`" component=`"PbiLauncher`" context=`"X`" type=`"2`" thread=`"1`" file=`"PbiLauncher.ps1`">"
)
[IO.File]::WriteAllText((Join-Path $folder 'Logs\PbiLauncher_TEST.log'), (($logLines -join "`r`n") + "`r`n"))

$responder = Start-Job -ArgumentList $folder -ScriptBlock {
    param($Folder)
    $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
    $end = (Get-Date).AddMinutes(4)
    while ((Get-Date) -lt $end -and -not (Test-Path (Join-Path $Folder 'responder.stop'))) {
        foreach ($n in 'refresh.txt', 'relaunch.txt', 'kill.txt') {
            $p = Join-Path $Folder $n
            if (Test-Path $p) { Add-Content -Path (Join-Path $Folder 'responder.log') -Value $n; [IO.File]::Delete($p) }
        }
        $snap = Join-Path $Folder 'snapshot.txt'
        if (Test-Path $snap) {
            [IO.File]::Delete($snap)
            $base = Join-Path $Folder 'Status\127.0.0.2'
            [IO.File]::WriteAllBytes("$base.png", $png)
            $info = [ordered]@{ TakenUtc = [DateTime]::UtcNow.ToString('o'); State = 'SHOWING'; Detail = 'Report on screen.'; Url = 'https://app.powerbi.com/groups/me/reports/abc'; Title = 'Report'; Accounts = @('kiosk@contoso.test'); Visuals = 12; Image = '127.0.0.2.png'; Error = '' }
            [IO.File]::WriteAllText("$base.snapshot.json.tmp", (ConvertTo-Json $info))
            Move-Item -LiteralPath "$base.snapshot.json.tmp" -Destination "$base.snapshot.json" -Force
        }
        $seed = Join-Path $Folder 'password.seed'
        if (Test-Path $seed) {
            Copy-Item -LiteralPath $seed -Destination (Join-Path $Folder 'seed-seen.txt') -Force
            [IO.File]::Delete($seed)
        }
        Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 150
    }
}
Microsoft.PowerShell.Utility\Start-Sleep -Seconds 2

try {
    $kiosk = Open-PbiKiosk -HostName '127.0.0.2'
    Test-Check 'opens a kiosk folder' ($kiosk -and $kiosk.Folder -eq $folder)
    $cfg = Read-PbiKioskConfig -Kiosk $kiosk
    Test-Check 'reads the kiosk config' ($cfg.UserName -eq $User -and $cfg.LogName -eq 'PbiLauncher_TEST.log')

    $out = Invoke-Quiet { $script:LiveObs = Write-PbiLauncherLive -Kiosk $kiosk -Config $cfg }
    Test-Check 'live view: state, account, password, old launcher' ($out -match 'Status\s+OK' -and $out -match 'SHOWING for 3\dm' -and $out -match 'signed in as kiosk@contoso\.test' -and $out -match 'stored, encrypted' -and $out -match 'PowerBILauncher\.exe is still on this kiosk')
    Test-Check 'live view returns the observation' ($script:LiveObs.Installed -and $script:LiveObs.Status -eq 'OK')

    $noKiosk = [pscustomobject]@{ Host = 'nobody'; Root = (Join-Path $KioskDir 'lib-notrun'); Folder = (Join-Path $KioskDir "lib-notrun\$PbiRel") }
    $out = Invoke-Quiet { $script:Sent = Send-PbiControlFile -Kiosk $noKiosk -Name 'refresh.txt' -WaitSeconds 1 }
    Test-Check 'a control file nobody takes: says so, file stays' (-not $script:Sent -and $out -match 'Not taken' -and (Test-Path (Join-Path $noKiosk.Folder 'refresh.txt')))

    $out = Invoke-Quiet { Show-PbiLogTail -Kiosk $kiosk -Config $cfg }
    Test-Check 'log tail: entries in order, with dates, multi-line kept' ($out -match '17\.09\.\s*10:00:00\s+PBI Launcher start' -and $out -match '10:00:05\s+Microsoft rejected' -and $out -match 'first line\s*\r?\n\s+at second line')

    # --- the P menu, driven through its prompts
    Set-Answers '127.0.0.2' '1' '4' 'y' '4' '5' 'no' 'I' 'W' 'B' '2' 'YES' '3' 'P' 'Secret"1 x' 'Secret"1 x' 'L' 'X' ''
    $out = Invoke-Quiet { Invoke-PbiLauncherMenu -State $state -Shown $shown }
    Test-Check 'P menu: every answer used, no extra prompt' ($script:Answers.Count -eq 0) ("{0} left; prompts: {1}" -f $script:Answers.Count, ($script:Prompts -join ' | '))
    $taken = if (Test-Path (Join-Path $folder 'responder.log')) { @(Get-Content (Join-Path $folder 'responder.log')) } else { @() }
    Test-Check '[1] reload: refresh.txt sent and taken' ($taken -contains 'refresh.txt' -and $out -match 'The launcher has taken it')
    Test-Check '[4] hold then [4] resume: hold.txt gone again' (-not (Test-Path (Join-Path $folder 'hold.txt')) -and $out -match 'hold.txt is in place' -and $out -match 'hold.txt is gone')
    Test-Check '[5] stop without YES: nothing sent' ($taken -notcontains 'kill.txt' -and -not (Test-Path (Join-Path $folder 'kill.txt')))
    $calls = $script:FleetCalls.ToArray()
    Test-Check '[I] dry run: Deploy-PbiLauncher -Hosts 127.0.0.2 -WhatIf' ($calls.Count -ge 1 -and $calls[0].Script -eq 'Deploy-PbiLauncher.ps1' -and ((@($calls[0].Args.Hosts) -join ',') -eq '127.0.0.2') -and $calls[0].Args.WhatIf -and -not $calls[0].Args.Restart -and -not $calls[0].Args.Rollback) (($calls | ForEach-Object { ($_.Args.Keys | Sort-Object) -join '+' }) -join '; ')
    Test-Check '[B] with restart: -Rollback -Restart after YES' ($calls.Count -eq 2 -and $calls[1].Args.Rollback -and $calls[1].Args.Restart -and -not $calls[1].Args.WhatIf)
    $shots = @(Get-ChildItem -LiteralPath $SnapshotDir -Filter '127.0.0.2_127.0.0.2_*.png' -ErrorAction SilentlyContinue)
    Test-Check '[3] screenshot: copied to Logs\snapshots and opened' ($shots.Count -eq 1 -and $script:Opened.Count -eq 1 -and $script:Opened[0] -eq $shots[0].FullName -and $out -match 'visuals on the page: 12')
    $seen = if (Test-Path (Join-Path $folder 'seed-seen.txt')) { [IO.File]::ReadAllText((Join-Path $folder 'seed-seen.txt')) } else { $null }
    Test-Check '[P] password: seed written exactly (no BOM, no newline) and taken' ($seen -ceq 'Secret"1 x' -and -not (Test-Path (Join-Path $folder 'password.seed')) -and $out -match 'Stored\.') ("seed '{0}'" -f $seen)
    $raw = [IO.File]::ReadAllBytes((Join-Path $folder 'seed-seen.txt'))
    Test-Check '[P] seed file starts with the password, not a BOM' ($raw[0] -eq [byte][char]'S')
    Test-Check '[L] log shown from the configured log name' ($out -match 'PbiLauncher_TEST\.log')
    Test-Check 'the password never appears on screen' ($out -notmatch 'Secret')

    Set-Answers '127.0.0.2' 'P' 'abc' 'abd' ''
    $out = Invoke-Quiet { Invoke-PbiLauncherMenu -State $state -Shown $shown }
    Test-Check '[P] passwords that differ: nothing written' ($out -match 'did not match' -and -not (Test-Path (Join-Path $folder 'password.seed')) -and $script:Answers.Count -eq 0)

    Set-Answers '127.0.0.7'
    $out = Invoke-Quiet { Invoke-PbiLauncherMenu -State $state -Shown $shown }
    Test-Check 'P menu refuses a Mach2 kiosk' ($out -match 'is a Mach2 kiosk' -and $script:Answers.Count -eq 0)

    Set-Answers '127.0.0.4' '1' 'I' '1' 'y' ''
    $out = Invoke-Quiet { Invoke-PbiLauncherMenu -State $state -Shown $shown }
    Test-Check 'P menu on a kiosk without PBI Launcher: only install is offered' ($out -match 'not installed' -and $out -match '\[I\] install' -and $out -notmatch '\[1\] reload')
    Test-Check '... and [I] installs: Deploy-PbiLauncher -Hosts 127.0.0.4' ($script:FleetCalls.ToArray().Count -eq 1 -and ((@($script:FleetCalls[0].Args.Hosts) -join ',') -eq '127.0.0.4') -and $script:FleetCalls[0].Args.Keys.Count -eq 1) (($script:FleetCalls | ForEach-Object { ($_.Args.Keys | Sort-Object) -join '+' }) -join '; ')

    # --- the D menu
    $script:Tab = 'PBI'
    Set-Answers 'R 127.0.0.3' '1' 'y'
    $null = Invoke-Quiet { Invoke-DeployMenu -State $state -Hosts $shown }
    $c = $script:FleetCalls.ToArray()
    Test-Check 'D on PBI, "R host", now: Deploy-PbiLauncher -Rollback' ($c.Count -eq 1 -and $c[0].Script -eq 'Deploy-PbiLauncher.ps1' -and $c[0].Args.Rollback -and -not $c[0].Args.Restart -and ((@($c[0].Args.Hosts) -join ',') -eq '127.0.0.3'))

    Set-Answers '1,127.0.0.3' 'W'
    $null = Invoke-Quiet { Invoke-DeployMenu -State $state -Hosts $shown }
    $c = $script:FleetCalls.ToArray()
    $first = $shown[0].Host
    Test-Check 'D on PBI with a number and a name, dry run' ($c.Count -eq 1 -and $c[0].Args.WhatIf -and ((@($c[0].Args.Hosts) -join ',') -eq "$first,127.0.0.3")) (@($c[0].Args.Hosts) -join ',')

    Set-Answers '127.0.0.7'
    $out = Invoke-Quiet { Invoke-DeployMenu -State $state -Hosts $shown }
    Test-Check 'D on PBI refuses a Mach2 kiosk' ($script:FleetCalls.Count -eq 0 -and $out -match 'Not PBI kiosks: 127\.0\.0\.7')

    $script:Tab = 'Mach2'
    $mach = @(Get-ShownHosts -State $state)
    Set-Answers '127.0.0.7' '2' 'YES'
    $null = Invoke-Quiet { Invoke-DeployMenu -State $state -Hosts $mach }
    $c = $script:FleetCalls.ToArray()
    Test-Check 'D on Mach2 with restart: Deploy-Mach2LauncherNG -Restart' ($c.Count -eq 1 -and $c[0].Script -eq 'Deploy-Mach2LauncherNG.ps1' -and $c[0].Args.Restart -and -not $c[0].Args.Rollback -and ((@($c[0].Args.Hosts) -join ',') -eq '127.0.0.7')) (($c | ForEach-Object { ($_.Args.Keys | Sort-Object) -join '+' }) -join '; ')

    Set-Answers '127.0.0.7' '2' 'yes'
    $null = Invoke-Quiet { Invoke-DeployMenu -State $state -Hosts $mach }
    Test-Check 'a restart needs YES in capitals' ($script:FleetCalls.Count -eq 0)

    Set-Answers 'R 127.0.0.7' 'W'
    $null = Invoke-Quiet { Invoke-DeployMenu -State $state -Hosts $mach }
    $c = $script:FleetCalls.ToArray()
    Test-Check 'D on Mach2, "R host", dry run: Deploy-Mach2LauncherNG -Rollback -WhatIf' ($c.Count -eq 1 -and $c[0].Script -eq 'Deploy-Mach2LauncherNG.ps1' -and $c[0].Args.Rollback -and $c[0].Args.WhatIf) (($c | ForEach-Object { ($_.Args.Keys | Sort-Object) -join '+' }) -join '; ')

    Set-Answers '127.0.0.2'
    $out = Invoke-Quiet { Invoke-DeployMenu -State $state -Hosts $mach }
    Test-Check 'D on Mach2 refuses a Power BI kiosk' ($script:FleetCalls.Count -eq 0 -and $out -match 'Not Mach2 kiosks: 127\.0\.0\.2')

    $script:Tab = 'Other'
    Set-Answers
    $out = Invoke-Quiet { Invoke-DeployMenu -State $state -Hosts @() }
    Test-Check 'D on Other explains itself and asks nothing' ($out -match 'goes by kiosk type' -and $script:Prompts.Count -eq 0)

    # --- the message menu refuses Power BI screens
    $script:Tab = 'PBI'
    Set-Answers '127.0.0.2' ''
    $out = Invoke-Quiet { Invoke-MessageMenu -Hosts $shown }
    Test-Check 'M refuses a Power BI screen' ($out -match 'is a Power BI screen' -and $script:Messages -eq 0 -and $script:Answers.Count -eq 0)
}
finally {
    [IO.File]::WriteAllText((Join-Path $folder 'responder.stop'), '')
    $responder | Wait-Job -Timeout 10 | Out-Null
    $responder | Remove-Job -Force
}

# ---------------------------------------------------------------------------
Start-Section 'Collector: one launcher per screen, any mix'
# ---------------------------------------------------------------------------
# 127.0.0.8: a Power BI kiosk (in the list) whose S2 shows a Mach2 dashboard
# on Mach2 Launcher NG - which is its watchdog too. 127.0.0.9: a web page on
# a kiosk typed Web. 127.0.0.10: PBI Launcher from before the screen folders.
function Write-StatusFile {
    param([string]$Dir, [string]$Name, [hashtable]$Values)
    New-Item -ItemType Directory -Path (Join-Path $Dir 'Status') -Force | Out-Null
    $now = [DateTime]::UtcNow
    $s = [ordered]@{ Instance = $Name; State = 'SHOWING'; Detail = ''; LauncherVersion = '2.0.1'; EdgeVersion = 'Edg/153.0.4234.48'
        StateSinceUtc = $now.AddMinutes(-20).ToString('o'); UpdatedUtc = $now.AddSeconds(-10).ToString('o'); LastShownUtc = $now.ToString('o')
        BrowserStarts = 1; Reloads = 0; SignIns = 1; PcBootUtc = $BootIso; LastError = '' }
    foreach ($k in $Values.Keys) { $s[$k] = $Values[$k] }
    [IO.File]::WriteAllText((Join-Path $Dir "Status\$Name.status.json"), (ConvertTo-Json -InputObject $s))
}
$k8 = New-FakeKiosk '127.0.0.8'
$pub8 = Join-Path $k8 'Users\Public\Documents'
New-Item -ItemType Directory -Path (Join-Path $pub8 'PbiLauncher\S1'), (Join-Path $pub8 'Mach2LauncherNG\S2') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $pub8 'PbiLauncher\PbiLauncher.ps1'), '# fake')
[IO.File]::WriteAllText((Join-Path $pub8 'PbiLauncher\S1\127.0.0.8.json'), '{ "DisplayURL": "https://app.powerbi.com/x" }')
Write-StatusFile -Dir (Join-Path $pub8 'PbiLauncher\S1') -Name 'S1' -Values @{ State = 'SIGNIN_BLOCKED'; Detail = 'Microsoft asks for the password, and none is stored.'; UserName = $User; Screen = 'S1'; Launcher = 'PBI' }
[IO.File]::WriteAllText((Join-Path $pub8 'Mach2LauncherNG\Mach2LauncherNG.ps1'), '# fake')
[IO.File]::WriteAllText((Join-Path $pub8 'Mach2LauncherNG\S2\127.0.0.8.json'), '{ "DisplayURL": "http://station/x" }')
Write-StatusFile -Dir (Join-Path $pub8 'Mach2LauncherNG\S2') -Name 'S2' -Values @{ LauncherVersion = '1.01NG'; Watchdog = $true; ScreenWhitePercent = 64 }
[IO.File]::WriteAllText((Join-Path $pub8 'mwst.log'), '[2026-09-24 12:00:00] [INFO] Heartbeat')

$k9 = New-FakeKiosk '127.0.0.9'
$web9 = Join-Path $k9 'Users\Public\Documents\WebLauncher'
New-Item -ItemType Directory -Path (Join-Path $web9 'S1') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $web9 'WebLauncher.ps1'), '# fake')
[IO.File]::WriteAllText((Join-Path $web9 'S1\127.0.0.9.json'), '{ "DisplayURL": "https://intranet.test/board" }')
Write-StatusFile -Dir (Join-Path $web9 'S1') -Name 'S1' -Values @{ LauncherVersion = '1.0.0'; Launcher = 'WEB'; Screen = 'S1'; Title = 'Board' }

$k10 = New-FakeKiosk '127.0.0.10' -Installed
Set-FakeStatus -Root $k10 -Instance '127.0.0.10' -State 'SHOWING'
[IO.File]::WriteAllText((Join-Path $k10 "$PbiRel\127.0.0.10.json"), '{ "DisplayURL": "https://app.powerbi.com/y" }')

$list = Join-Path $WorkRoot 'kiosks-mixed.csv'
@(
    [pscustomobject]@{ Host = '127.0.0.8'; Location = 'PBI + MACH2'; Type = 'PBI'; Active = 'Y'; HasMwst = '' }
    [pscustomobject]@{ Host = '127.0.0.9'; Location = 'WEB PAGE'; Type = 'Web'; Active = 'Y'; HasMwst = '' }
    [pscustomobject]@{ Host = '127.0.0.10'; Location = 'PBI 2.0.0'; Type = 'PBI'; Active = 'Y'; HasMwst = '' }
) | Export-Csv -LiteralPath $list -NoTypeInformation
$csv = Join-Path $WorkRoot 'out-mixed\MWST_FleetEvents.csv'
New-Item -ItemType Directory -Path (Split-Path -Parent $csv) -Force | Out-Null
$run = Invoke-Collector
$s = Get-StatusRows
$L = $s.Latest
Test-Check 'a Web kiosk in the list is scanned' ($L.ContainsKey('127.0.0.9')) (($L.Keys | Sort-Object) -join ',')
Test-Check 'PBI S1 + Mach2 S2: the worse screen decides (SIGNIN_BLOCKED on S1)' ($L['127.0.0.8'].Outcome -eq 'SIGNIN_BLOCKED' -and $L['127.0.0.8'].Severity -eq 'CRITICAL') $L['127.0.0.8'].Outcome
Test-Check 'and both launchers are in its detail' ($L['127.0.0.8'].Detail -match 'launcher=S1:SIGNIN_BLOCKED' -and $L['127.0.0.8'].Detail -match 'launcher=S2:SHOWING screen=64%') $L['127.0.0.8'].Detail
Test-Check 'the Mach2 screen makes it a watchdog kiosk, though the list says PBI' ($L['127.0.0.8'].WatchdogRunning -eq 'TRUE') $L['127.0.0.8'].WatchdogRunning
Test-Check 'a web page: OK, web-<version> as agent, web= in the detail' ($L['127.0.0.9'].Outcome -eq 'OK' -and $L['127.0.0.9'].AgentVersion -eq 'web-1.0.0' -and $L['127.0.0.9'].Detail -match 'web=S1:SHOWING') "$($L['127.0.0.9'].Outcome) $($L['127.0.0.9'].AgentVersion) $($L['127.0.0.9'].Detail)"
Test-Check 'PBI Launcher 2.0.0 next to its script still reads, as S1' ($L['127.0.0.10'].Outcome -eq 'OK' -and $L['127.0.0.10'].Detail -match 'launcher=S1:SHOWING') $L['127.0.0.10'].Detail
$side = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText([IO.Path]::ChangeExtension($csv, '.status.json')))
Test-Check 'the status file has each launcher under its own name, with the screen' (
    $side.PbiLaunchers.'127.0.0.8'.Instances[0].Screen -eq 'S1' -and $side.Mach2Launchers.'127.0.0.8'.Instances[0].Screen -eq 'S2' -and
    $side.WebLaunchers.'127.0.0.9'.Instances[0].Screen -eq 'S1' -and @($side.WebLaunchers.'127.0.0.9'.Screens) -contains 'S1')

. (Join-Path $FleetRoot 'Lib\MWST.FleetState.ps1')
$fs = Read-FleetState -Path $csv
$e8 = @($fs.Hosts | Where-Object { $_.Host -eq '127.0.0.8' })[0]
$e9 = @($fs.Hosts | Where-Object { $_.Host -eq '127.0.0.9' })[0]
Test-Check 'fleet state: the mixed kiosk is on the PBI and the Mach2 tab, screens S1 and S2' ($e8 -and @($e8.Tabs) -contains 'PBI' -and @($e8.Tabs) -contains 'Mach2' -and (@($e8.Screens | ForEach-Object { "$($_.Screen):$($_.Launcher)" }) -join ',') -eq 'S1:PBI,S2:MACH2') $(if ($e8) { "$($e8.Tabs -join '/') $(@($e8.Screens | ForEach-Object { "$($_.Screen):$($_.Launcher)" }) -join ',')" })
Test-Check 'fleet state: the web page kiosk is on the Web tab' ($e9 -and $e9.Tab -eq 'Web' -and @($e9.Tabs) -contains 'Web') $(if ($e9) { $e9.Tab })

$frameW = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dash -Once -Tab Web -CsvPath $csv -NoColour -Ascii 2>&1 | Out-String
Test-Check 'the dashboard has a Web tab with the web page kiosk' ($frameW -match '\d Web \(1\)' -and $frameW -match '127\.0\.0\.9') (@($frameW -split "`r?`n" | Where-Object { $_ -match 'Web \(' })[0])
$frameM = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $dash -Once -Tab Mach2 -CsvPath $csv -NoColour -Ascii 2>&1 | Out-String
Test-Check 'and lists the mixed kiosk on its Mach2 tab too' ($frameM -match '127\.0\.0\.8') (@($frameM -split "`r?`n" | Where-Object { $_ -match 'Mach2 \(' })[0])

# ---------------------------------------------------------------------------
$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("{0} checks, {1} failed." -f $script:Results.Count, $failed.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
foreach ($f in $failed) { Write-Host ("  FAIL {0}: {1} {2}" -f $f.Section, $f.Check, $f.Detail) -ForegroundColor Red }
if (-not $KeepWorkRoot -and $failed.Count -eq 0) { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction SilentlyContinue }
exit $(if ($failed.Count) { 3 } else { 0 })
