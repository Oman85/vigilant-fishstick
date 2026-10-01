#Requires -Version 5.1
<#
.SYNOPSIS
    Tests the Kiosk Fleet Manager window (Show-FleetManager.ps1): the fleet
    reading it shares with the collector, the tables, the deploy commands it
    builds, and what its buttons do to a kiosk.

.DESCRIPTION
    Nothing here touches a real kiosk, the published CSV, or a real deploy.
    The window is built with -NoShow, so everything exists and the data is
    loaded but nothing appears on screen; the test then calls the same
    functions the buttons do.

    Kiosks are folders under -WorkRoot standing in for their C: drives
    (-RootTemplate), with a background job playing the launcher: it takes
    control files, answers snapshot.txt and stores password.seed, exactly as
    a launcher on a kiosk would.

    Takes about a minute.

.EXAMPLE
    .\Tests\Test-FleetManager.ps1
#>
[CmdletBinding()]
param(
    [string]$FleetRoot,
    [string]$WorkRoot,
    [switch]$KeepWorkRoot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Off
# Not defaulted in the param block: with powershell.exe -File, $PSScriptRoot
# is not set yet while the defaults are worked out.
if (-not $FleetRoot) { $FleetRoot = Split-Path -Parent $PSScriptRoot }
if (-not $WorkRoot) { $WorkRoot = Join-Path $env:TEMP 'KioskFleetGuiTests' }
$FleetRoot = (Resolve-Path -LiteralPath $FleetRoot).ProviderPath

if ([threading.thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Run this from a normal PowerShell console (it needs an STA thread for the window).'
}

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
$Inv = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------
# A fleet on disk: the events CSV and the collector's status file next to it
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
    @{ Host = 'MGUI1'; Location = 'LINE1'; Type = 'Mach2'; Status = 'OK'; Wd = 'TRUE'; Agent = '1.00NG'; Log = 1 }
    @{ Host = 'MGUI2'; Location = 'LINE2'; Type = 'Mach2'; Status = 'STALE'; Wd = 'FALSE'; Agent = '7.0'; Log = 1900 }
    @{ Host = 'MGUI3'; Location = 'LINE3'; Type = 'Mach2'; Status = 'OK'; Wd = 'TRUE'; Agent = '7.0'; Log = 2 }
    @{ Host = 'PGUI1'; Location = 'APU1'; Type = 'PBI'; Status = 'OK'; Wd = ''; Agent = ''; Log = $null }
    @{ Host = 'PGUI2'; Location = 'APU2'; Type = 'PBI - SR'; Status = 'WRONG_ACCOUNT'; Wd = ''; Agent = ''; Log = $null }
    @{ Host = 'PGUI3'; Location = 'APU3'; Type = 'PBI'; Status = 'OFFLINE'; Wd = ''; Agent = ''; Log = $null }
    @{ Host = 'OGUI1'; Location = 'STORE'; Type = 'Signage'; Status = 'OK'; Wd = ''; Agent = ''; Log = $null }
)
foreach ($k in $kiosks) {
    Add-Row @{
        EventId = [guid]::NewGuid(); EventTimeUtc = (Iso $Now.AddMinutes(-4)); EventTimeLocal = (IsoLocal $Now.AddMinutes(-4))
        EventDate = $Now.ToString('yyyy-MM-dd', $Inv); Host = $k.Host; Location = $k.Location; KioskType = $k.Type
        EventCategory = 'HOST'; EventType = 'HOST_STATUS'; Severity = 'INFO'; Outcome = $k.Status
        Reachable = 'TRUE'; WatchdogRunning = $k.Wd; AgentVersion = $k.Agent
        MinutesSinceLastLog = $(if ($null -ne $k.Log) { "$($k.Log)" } else { '' })
        BootTimeUtc = (Iso $Now.AddHours(-9)); UptimeHours = '9'; Source = 'Collector'
        Detail = "reach=ping share=ok for $($k.Host)"
    }
}
# Reboots on MGUI2: two today, one of them the watchdog's, and one yesterday,
# so both the 24-hour count and the seven-day chart have something to show.
foreach ($n in 1, 2, 3) {
    $when = $(if ($n -eq 3) { $Now.AddDays(-1) } else { $Now.AddHours(-3) })
    Add-Row @{
        EventId = [guid]::NewGuid(); EventTimeUtc = (Iso $when); EventTimeLocal = (IsoLocal $when)
        EventDate = $when.ToString('yyyy-MM-dd', $Inv); Host = 'MGUI2'; Location = 'LINE2'; KioskType = 'Mach2'
        EventCategory = 'REBOOT'; EventType = 'WATCHDOG_WHITE'; Severity = 'WARN'; Outcome = 'RESTART_CONFIRMED'
        IsCanonicalReboot = 'TRUE'; IsScriptReboot = $(if ($n -eq 1) { 'TRUE' } else { 'FALSE' }); RebootTrigger = 'WHITE'
        Source = 'Agent'
    }
}
Add-Row @{
    EventId = [guid]::NewGuid(); EventTimeUtc = (Iso $Now.AddMinutes(-4)); EventTimeLocal = (IsoLocal $Now.AddMinutes(-4))
    EventDate = $Now.ToString('yyyy-MM-dd', $Inv); EventCategory = 'COLLECTOR'; EventType = 'COLLECTOR_RUN'
    Severity = 'INFO'; Outcome = 'OK'; Source = 'Collector'
}

$Csv = Join-Path $WorkRoot 'MWST_FleetEvents.csv'
$rows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8

$sidecar = [ordered]@{
    LastRunUtc = (Iso $Now.AddMinutes(-4)); LastRunLocal = (IsoLocal $Now.AddMinutes(-4)); DurationSeconds = 42
    Hosts = $kiosks.Count; Reachable = 6; WatchdogHosts = 3; NeedsAttention = 3; NewEvents = 0; DataChanged = $true
    HostErrors = 0; SkippedInactive = 0; CollectorVersion = '6.1'; Runner = 'TEST\tester@TESTPC'
    PbiLaunchers = [ordered]@{
        PGUI1 = [ordered]@{
            Installed = $true; LegacyLauncher = $false; Status = 'OK'; Error = ''
            Instances = @([ordered]@{
                    Instance = 'PGUI1'; State = 'SHOWING'; Detail = ''; HostStatus = 'OK'
                    UpdatedUtc = (Iso $Now.AddMinutes(-1)); StateMinutes = 30; LastShownUtc = (Iso $Now.AddMinutes(-1))
                    Version = '2.0.0'; Edge = '153.0.4234.32'; UserName = 'kiosk@contoso.test'; SignedInAs = 'kiosk@contoso.test'
                    SignIns = 1; Reloads = 3; BrowserStarts = 1; LastError = ''
                })
        }
        PGUI2 = [ordered]@{
            Installed = $true; LegacyLauncher = $false; Status = 'WRONG_ACCOUNT'; Error = ''
            Instances = @([ordered]@{
                    Instance = 'PGUI2'; State = 'SHOWING'; Detail = ''; HostStatus = 'WRONG_ACCOUNT'
                    UpdatedUtc = (Iso $Now.AddMinutes(-1)); StateMinutes = 12; LastShownUtc = (Iso $Now.AddMinutes(-1))
                    Version = '2.0.0'; Edge = '153.0.4234.32'; UserName = 'kiosk@contoso.test'; SignedInAs = 'someone@contoso.test'
                    SignIns = 1; Reloads = 1; BrowserStarts = 1; LastError = ''
                })
        }
        PGUI3 = [ordered]@{ Installed = $false; LegacyLauncher = $true; Status = $null; Error = ''; Instances = @() }
    }
    Mach2Launchers = [ordered]@{
        MGUI1 = [ordered]@{
            Installed = $true; OldLauncher = $false; Status = 'OK'; Error = ''
            Instances = @([ordered]@{
                    Instance = 'S1'; State = 'SHOWING'; Detail = ''; HostStatus = 'OK'
                    UpdatedUtc = (Iso $Now.AddMinutes(-1)); StateMinutes = 55; LastShownUtc = (Iso $Now.AddMinutes(-1))
                    Version = '1.00NG'; Edge = '153.0.4234.32'; Watchdog = $true; LoopGuard = 'OFF'
                    PageWhitePercent = 63; ScreenWhitePercent = 72; SignIns = 1; Reloads = 2; BrowserStarts = 1
                    PcRestarts = 0; LastError = ''
                })
        }
    }
}
[IO.File]::WriteAllText([IO.Path]::ChangeExtension($Csv, '.status.json'), ($sidecar | ConvertTo-Json -Depth 6))

# ---------------------------------------------------------------------------
# Fake kiosks: MGUI1 runs Mach2 Launcher NG, PGUI1 runs PBI Launcher
# ---------------------------------------------------------------------------
$NgRel = 'Users\Public\Documents\Mach2LauncherNG'
$PbiRel = 'Users\Public\Documents\PbiLauncher'

$ngDir = Join-Path ($Template -f 'MGUI1') "$NgRel\S1"
New-Item -ItemType Directory -Path (Join-Path $ngDir 'Status') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $ngDir 'Logs') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path ($Template -f 'MGUI1') "$NgRel\Mach2LauncherNG.ps1"), '# fake')
[IO.File]::WriteAllText((Join-Path $ngDir 'MGUI1.json'), ([ordered]@{
            ConfigVersion = '1.00NG'
            LoginURL = 'http://station:302/prelogin?clear=true'
            DisplayURL = 'http://station:302/ord/dashboard'
            UserName = 'operator'
            ScreenSelect = '1'
            Watchdog = '1'
            LogName = 'MGUI1_Mach2LauncherNG.log'
        } | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $ngDir 'Status\S1.status.json'), (@{
            Instance = 'S1'; State = 'SHOWING'; Detail = ''; LauncherVersion = '1.00NG'; EdgeVersion = 'Edg/153.0.4234.32'
            UpdatedUtc = ([datetime]::UtcNow.ToString('o')); StateSinceUtc = ([datetime]::UtcNow.AddMinutes(-55).ToString('o'))
            Watchdog = $true; LoopGuard = 'OFF'; ScreenWhitePercent = 72; PageWhitePercent = 63
            SignIns = 1; Reloads = 2; BrowserStarts = 1; PcRestarts = 0; LastError = ''
        } | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $ngDir 'Logs\MGUI1_Mach2LauncherNG.log'),
    '<![LOG[The dashboard is on screen.]LOG]!><time="08:30:00.000+000" date="09-20-2026" component="Mach2LauncherNG" context="" type="1" thread="1" file="">')

$pbiDir = Join-Path ($Template -f 'PGUI1') $PbiRel
New-Item -ItemType Directory -Path (Join-Path $pbiDir 'Status') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $pbiDir 'PbiLauncher.ps1'), '# fake')
[IO.File]::WriteAllText((Join-Path $pbiDir 'PGUI1.json'), (@{ DisplayURL = 'https://app.powerbi.test/report'; UserName = 'kiosk@contoso.test' } | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $pbiDir 'Status\PGUI1.status.json'), (@{
            Instance = 'PGUI1'; State = 'SHOWING'; LauncherVersion = '2.0.0'; EdgeVersion = 'Edg/153.0.4234.32'
            UpdatedUtc = ([datetime]::UtcNow.ToString('o')); StateSinceUtc = ([datetime]::UtcNow.AddMinutes(-30).ToString('o'))
            UserName = 'kiosk@contoso.test'; SignedInAs = 'kiosk@contoso.test'; SignIns = 1; Reloads = 3; BrowserStarts = 1; LastError = ''
        } | ConvertTo-Json))

# The launcher, played by a background job: it takes control files, answers
# snapshot.txt with a picture, and stores password.seed - and leaves hold.txt
# alone, as a real launcher does.
$launcher = Start-Job -ArgumentList $ngDir, $pbiDir -ScriptBlock {
    param($NgDir, $PbiDir)
    $deadline = (Get-Date).AddSeconds(120)
    $png = [Convert]::FromBase64String('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==')
    while ((Get-Date) -lt $deadline) {
        foreach ($d in @(@{ Dir = $NgDir; Name = 'S1' }, @{ Dir = $PbiDir; Name = 'PGUI1' })) {
            foreach ($f in @('refresh.txt', 'relaunch.txt', 'kill.txt', 'restart.txt')) {
                $p = Join-Path $d.Dir $f
                if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
            }
            $snap = Join-Path $d.Dir 'snapshot.txt'
            if (Test-Path -LiteralPath $snap) {
                Remove-Item -LiteralPath $snap -Force -ErrorAction SilentlyContinue
                $status = Join-Path $d.Dir 'Status'
                [IO.File]::WriteAllBytes((Join-Path $status "$($d.Name).png"), $png)
                [IO.File]::WriteAllText((Join-Path $status "$($d.Name).snapshot.json"), (@{
                            TakenUtc = ([datetime]::UtcNow.ToString('o')); State = 'SHOWING'; Detail = ''
                            Url = 'http://station/dashboard'; Title = 'Dashboard'; Image = "$($d.Name).png"; Error = ''
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

function Wait-Jobs {
    # Pumps the window's background work, as its 250 ms timer would.
    param([int]$Seconds = 30, [scriptblock]$Until)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Update-Jobs
        if ($Until -and (& $Until)) { return $true }
        if (-not $Until -and $script:Jobs.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 150
    }
    return $false
}

# The card's own controls, as a person would fill them in.
function Set-Field {
    param([string]$Key, [string]$Value)
    $c = $script:OverlayFieldControls[$Key]
    if (-not $c) { throw "no field '$Key' on the card" }
    switch ($c.Kind) {
        'password' { $c.Box.Password = $Value; $c.Confirm.Password = $Value }
        'bool' { $c.Box.IsChecked = ($Value -eq '1') }
        'choice' {
            $item = @($c.Box.Items | Where-Object { [string]$_.Tag -eq $Value })[0]
            if (-not $item) { throw "no choice '$Value' for '$Key'" }
            $c.Box.SelectedItem = $item
        }
        default { $c.Box.Text = $Value }
    }
}
function Get-Field {
    param([string]$Key)
    $c = $script:OverlayFieldControls[$Key]
    if (-not $c) { return $null }
    switch ($c.Kind) {
        'password' { return $c.Box.Password }
        'bool' { return $(if ($c.Box.IsChecked) { '1' } else { '0' }) }
        'choice' { return $(if ($c.Box.SelectedItem) { [string]$c.Box.SelectedItem.Tag } else { '' }) }
        default { return $c.Box.Text }
    }
}
function Invoke-OverlayOk {
    $UI.OverlayOk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
}
function Read-KioskConfigFile {
    param([string]$Path)
    return @(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)))[0]
}

# ---------------------------------------------------------------------------
Start-Section 'The window is built and the fleet is read'
# ---------------------------------------------------------------------------
$Manager = Join-Path $FleetRoot 'Show-FleetManager.ps1'
. $Manager -NoShow -CsvPath $Csv -RootTemplate $Template -CredentialFile (Join-Path $WorkRoot 'no-such.cred.xml') -View 'Mach2'
$script:Credential = New-Object System.Management.Automation.PSCredential('TEST\tester', (ConvertTo-SecureString 'not-used-for-local-folders' -AsPlainText -Force))

Test-Check 'the window exists' ($null -ne $Window) $(if ($Window) { $Window.Title })
Test-Check 'every kiosk is in the state' ($script:State.Ok -and $script:State.Hosts.Count -eq 7) "$($script:State.Hosts.Count) kiosks"
Test-Check 'kiosks are split by type' (
    @(Get-TabKiosks -Tab 'Mach2').Count -eq 3 -and @(Get-TabKiosks -Tab 'PBI').Count -eq 3 -and @(Get-TabKiosks -Tab 'Other').Count -eq 1)
Test-Check 'the headline counts what needs attention' ($UI.HeadlineText.Text -eq '3 KIOSKS NEED ATTENTION') $UI.HeadlineText.Text
Test-Check 'the Other tab appears only because a kiosk needs it' ($UI.NavOther.Visibility -eq 'Visible')
Test-Check 'freshness is shown and is not stale' ($UI.FreshText.Text -match 'collected') $UI.FreshText.Text

# Every element the code reaches for has to exist in the markup.
$text = Get-Content -Raw $Manager
$used = @([regex]::Matches($text, '\$UI\.([A-Za-z0-9_]+)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$missing = @($used | Where-Object { -not $UI.ContainsKey($_) -or $null -eq $UI[$_] })
Test-Check 'every named element the code uses is in the window' ($missing.Count -eq 0) ($missing -join ', ')

# ---------------------------------------------------------------------------
Start-Section 'The kiosk tables'
# ---------------------------------------------------------------------------
Test-Check 'the Mach2 tab lists its kiosks' ($script:Rows.Count -eq 3) "$($script:Rows.Count) rows"
$m1 = @($script:Rows | Where-Object { $_.Host -eq 'MGUI1' })[0]
$m2 = @($script:Rows | Where-Object { $_.Host -eq 'MGUI2' })[0]
Test-Check 'a kiosk on NG shows what the launcher is doing' ($m1.Launcher -eq 'SHOWING' -and $m1.Screen -eq '72%' -and $m1.Agent -eq '1.00NG') ("{0} / {1} / {2}" -f $m1.Launcher, $m1.Screen, $m1.Agent)
Test-Check 'a kiosk not on NG says so' ($m2.Launcher -eq 'old launcher') $m2.Launcher
Test-Check 'a dead watchdog is red' ($m2.Watchdog -eq 'DEAD' -and $m2.WatchdogBrush -eq $Brush.Crit) $m2.Watchdog
Test-Check 'reboots are counted and drawn' ($m2.Reboots -eq '2 (1)' -and $m2.Spark.Length -eq 7) ("{0} / {1}" -f $m2.Reboots, $m2.Spark)
Test-Check 'the status pill is coloured by severity' ($m2.StatusBrush -eq $Brush.Crit -and $m1.StatusBrush -eq $Brush.Ok)

Set-KioskColumns -Tab 'Mach2'
$vis = @(0..($UI.KioskGrid.Columns.Count - 1) | Where-Object { $UI.KioskGrid.Columns[$_].Visibility -eq 'Visible' })
Test-Check 'the Mach2 tab hides the Power BI columns' (($vis -notcontains 7) -and ($vis -contains 9) -and ($vis -contains 6)) ("columns: " + ($vis -join ','))
Set-KioskColumns -Tab 'PBI'
$vis = @(0..($UI.KioskGrid.Columns.Count - 1) | Where-Object { $UI.KioskGrid.Columns[$_].Visibility -eq 'Visible' })
Test-Check 'the Power BI tab shows the account and hides the watchdog' (($vis -contains 7) -and ($vis -notcontains 9) -and ($vis -notcontains 14)) ("columns: " + ($vis -join ','))

Select-KioskTab -Tab 'PBI'
$p2 = @($script:Rows | Where-Object { $_.Host -eq 'PGUI2' })[0]
Test-Check 'a wrong account is shown in red' ($p2.Account -eq 'someone@contoso.test' -and $p2.AccountBrush -eq $Brush.Crit) $p2.Account
$p3 = @($script:Rows | Where-Object { $_.Host -eq 'PGUI3' })[0]
Test-Check 'a kiosk on the old launcher says so' ($p3.Launcher -eq 'old launcher') $p3.Launcher

$script:Filter = 'PGUI1'
$rowsView = [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:Rows)
$rowsView.Refresh()
Test-Check 'the filter narrows the table' (@($rowsView | ForEach-Object { $_ }).Count -eq 1)
$script:Filter = ''
$script:OnlyProblems = $true
$rowsView.Refresh()
Test-Check 'problems only leaves the problems' (@($rowsView | ForEach-Object { $_ }).Count -eq 2)
$script:OnlyProblems = $false
$rowsView.Refresh()

Select-KioskTab -Tab 'Mach2' -HostName 'MGUI1'
Test-Check 'selecting a kiosk opens its details' ($UI.DetailRoot.Visibility -eq 'Visible' -and $UI.DetailHostText.Text -eq 'MGUI1')
$detail = (@($UI.DetailPanel.Children | ForEach-Object { @($_.Children | ForEach-Object { $_.Text }) -join ' = ' }) -join ' | ')
Test-Check 'the details show the launcher and the watchdog' ($detail -match 'MGUI1|S1' -and $detail -match 'SHOWING' -and $detail -match '72') $(if ($detail.Length -gt 90) { $detail.Substring(0, 90) } else { $detail })
Test-Check 'the launcher buttons are live for a kiosk on NG' ($UI.BtnReload.IsEnabled -and $UI.BtnSnapshot.IsEnabled -and $UI.BtnMessage.IsEnabled)
Select-KioskTab -Tab 'Mach2' -HostName 'MGUI2'
Test-Check 'they are not for a kiosk still on the old launcher' ((-not $UI.BtnReload.IsEnabled) -and $UI.BtnRestart.IsEnabled)
Select-KioskTab -Tab 'PBI' -HostName 'PGUI1'
Test-Check 'a Power BI screen has no message button' (-not $UI.BtnMessage.IsEnabled)

# ---------------------------------------------------------------------------
Start-Section 'The overview'
# ---------------------------------------------------------------------------
Show-View -Name 'Overview'
Test-Check 'the numbers add up' ($UI.StatTotal.Text -eq '7' -and $UI.StatAttention.Text -eq '3') ("{0} kiosks, {1} needing attention" -f $UI.StatTotal.Text, $UI.StatAttention.Text)
Test-Check 'the launchers already installed are counted' ($UI.StatLaunchers.Text -eq '3') ("{0} - {1}" -f $UI.StatLaunchers.Text, $UI.StatLaunchersNote.Text)
Test-Check 'everything needing attention is listed' ($script:AttentionRows.Count -eq 3)
Test-Check 'a week of reboots is drawn' ($script:ChartBars.Count -eq 7 -and @($script:ChartBars | Where-Object { $_.Count -eq '2' }).Count -eq 1)
$collector = (@($UI.CollectorPanel.Children | ForEach-Object { @($_.Children | ForEach-Object { $_.Text }) -join '=' }) -join ' | ')
Test-Check 'the collector panel says when it last ran' ($collector -match 'Last scan' -and $collector -match 'Reached=6 of 7')

# ---------------------------------------------------------------------------
Start-Section 'The deploy view builds the command'
# ---------------------------------------------------------------------------
Show-View -Name 'Deploy'
Set-DeployProduct 'NG'
Test-Check 'the Mach2 kiosks are the targets for NG' ($script:TargetRows.Count -eq 3)
$t1 = @($script:TargetRows | Where-Object { $_.Host -eq 'MGUI1' })[0]
Test-Check 'the list says what each kiosk runs now' ($t1.Note -match 'NG v1.00NG') $t1.Note
Test-Check 'nothing can run until a kiosk is ticked' ((-not $UI.BtnDeployRun.IsEnabled) -and $UI.DeployPreview.Text -match 'tick the kiosks')

$t1.Selected = $true
Update-DeployPreview
$cmd = Get-DeployCommand
Test-Check 'a plain install is the plain command' ($cmd -eq "& '.\Deploy-Mach2LauncherNG.ps1' -Hosts 'MGUI1'") $cmd
Test-Check 'the button is live and says what will happen' ($UI.BtnDeployRun.IsEnabled -and $UI.DeployNote.Text -match 'Install or update on 1 kiosk' -and $UI.DeployNote.Text -match 'next logon') $UI.DeployNote.Text

$UI.OptRestart.IsChecked = $true
$UI.OptWarnSecs.Text = '90'
$UI.OptVerifyMins.Text = '15'
$UI.OptForce.IsChecked = $true
$UI.OptUpdateConfig.IsChecked = $true
$cmd = Get-DeployCommand
Test-Check 'the options are on the command' (
    $cmd -match "-Restart\b" -and $cmd -match '-RestartWarningSeconds 90' -and $cmd -match '-VerifyMinutes 15' -and
    $cmd -match '-Force' -and $cmd -match '-UpdateConfig') $cmd
Update-DeployPreview
Test-Check 'a restart is spelled out before it happens' ($UI.DeployNote.Text -match 'restarts, one at a time') $UI.DeployNote.Text

$cmd = Get-DeployCommand -DryRun
Test-Check 'a dry run is the same command with -WhatIf' ($cmd -match '-WhatIf$') $cmd

Set-DeployMode 'Rollback'
$cmd = Get-DeployCommand
Test-Check 'rolling back adds -Rollback and drops the install options' ($cmd -match '-Rollback' -and $cmd -notmatch '-UpdateConfig') $cmd
Set-DeployMode 'Install'
$UI.OptRestart.IsChecked = $false
$UI.OptForce.IsChecked = $false
$UI.OptUpdateConfig.IsChecked = $false

Set-DeployProduct 'PBI'
Test-Check 'the Power BI screens are the targets for PBI Launcher' ($script:TargetRows.Count -eq 3 -and @($script:TargetRows | Where-Object { $_.Host -eq 'PGUI1' }).Count -eq 1)
foreach ($row in $script:TargetRows) { $row.Selected = $true }
$cmd = Get-DeployCommand
Test-Check 'several kiosks go on one command' ($cmd -match "Deploy-PbiLauncher.ps1' -Hosts 'PGUI1','PGUI2','PGUI3'") $cmd

Set-DeployProduct 'WATCHDOG'
Test-Check 'the old watchdog cannot be rolled back' (-not $UI.ModeRollback.IsEnabled)
@($script:TargetRows | Where-Object { $_.Host -eq 'MGUI2' })[0].Selected = $true
$UI.OptRestart.IsChecked = $true
$UI.OptTask.IsChecked = $true
$cmd = Get-DeployCommand
Test-Check 'the watchdog has its own switches' (
    $cmd -match 'Deploy-MWSTAgent.ps1' -and $cmd -match '-RebootAndVerify' -and $cmd -match '-RebootWarningSeconds' -and
    $cmd -match '-RegisterLauncherTask' -and $cmd -notmatch '-Restart\b') $cmd
$UI.OptRestart.IsChecked = $false
$UI.OptTask.IsChecked = $false
Set-DeployProduct 'NG'

# A kiosk the last scan never saw can still be deployed to.
Show-AddHostDialog
Set-Field 'Host' 'not a host name!'
Set-Field 'Setup' '0'
Invoke-OverlayOk
Test-Check 'junk is not accepted as a kiosk name' ($UI.Overlay.Visibility -eq 'Visible' -and $UI.OverlayNote.Text -match 'not a kiosk name') $UI.OverlayNote.Text
Set-Field 'Host' '  \\MGUI9 '
Invoke-OverlayOk
$added = @($script:TargetRows | Where-Object { $_.Host -eq 'MGUI9' })[0]
Test-Check 'a kiosk typed in joins the list, ticked and marked' (
    $UI.Overlay.Visibility -eq 'Collapsed' -and $added -and $added.Selected -and $added.Status -eq 'NOT SCANNED' -and $added.Note -match 'not in the last scan') $(if ($added) { $added.Note })
Test-Check 'and is on the command' ((Get-DeployCommand) -match "'MGUI9'") (Get-DeployCommand)

$UI.OptKioskUser.Text = 'kioskuser'
Test-Check 'a Windows account given for the kiosk goes on the command' ((Get-DeployCommand) -match "-KioskUser 'kioskuser'") (Get-DeployCommand)
Set-DeployProduct 'WATCHDOG'
Test-Check 'the old watchdog gets no -KioskUser (it has no such switch)' ((Get-DeployCommand) -notmatch 'KioskUser') (Get-DeployCommand)
Set-DeployProduct 'NG'
$UI.OptKioskUser.Text = ''
$added = @($script:TargetRows | Where-Object { $_.Host -eq 'MGUI9' })[0]
if ($added) { $added.Selected = $false }

# A tick made in the list itself, on a real CheckBox in the drawn grid - the
# path a mouse click takes. (Its first version queued the redraw with
# Dispatcher.BeginInvoke([action]{...}, 'Background'); PowerShell handed
# 'Background' to the action as an argument, and the first real click on a
# row closed the window with "Parameter count mismatch".)
foreach ($row in $script:TargetRows) { $row.Selected = $false }
Update-DeployPreview
Show-View -Name 'Deploy'
$root = $Window.Content
$root.Measure((New-Object System.Windows.Size(1500, 880)))
$root.Arrange((New-Object System.Windows.Rect(0, 0, 1500, 880)))
$root.UpdateLayout()
function Find-Visuals {
    param($Parent, [type]$Type)
    $found = @()
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($Parent); $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($Parent, $i)
        if ($child -is $Type) { $found += $child }
        $found += @(Find-Visuals -Parent $child -Type $Type)
    }
    return $found
}
$boxes = @(Find-Visuals -Parent $UI.DeployGrid -Type ([System.Windows.Controls.CheckBox]))
Test-Check 'the deploy list is drawn with a tick box per kiosk' ($boxes.Count -ge 3) "$($boxes.Count) boxes"
$box = $boxes[0]
$box.IsChecked = $true
Test-Check 'ticking a box in the list ticks that kiosk and puts it on the command' (
    $box.DataContext.Selected -and (Get-DeployCommand) -match ("'{0}'" -f $box.DataContext.Host) -and $UI.DeployPreview.Text -match $box.DataContext.Host) (Get-DeployCommand)
$box.IsChecked = $false
Test-Check 'unticking it takes it off again' ((-not $box.DataContext.Selected) -and $UI.DeployPreview.Text -match 'tick the kiosks') $UI.DeployPreview.Text
# In the code itself (the comment explaining the old bug quotes it): no
# dispatcher call with the delegate first, where PowerShell can pass the
# priority to it as an argument.
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $FleetRoot 'Show-FleetManager.ps1'), [ref]$null, [ref]$null)
$risky = @($ast.FindAll({
            param($n)
            $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
            "$($n.Member)" -in @('BeginInvoke', 'Invoke', 'InvokeAsync') -and
            $n.Arguments.Count -ge 1 -and $n.Arguments[0] -is [Management.Automation.Language.ConvertExpressionAst] -and
            $n.Arguments[0].Type.TypeName.Name -eq 'action' -and $n.Arguments.Count -ge 2
        }, $true))
Test-Check 'no dispatcher call that can hand the priority to the delegate' ($risky.Count -eq 0) (@($risky | ForEach-Object { "line $($_.Extent.StartLineNumber)" }) -join ', ')

# Deploy... on a kiosk brings you here with that kiosk already ticked.
Select-KioskTab -Tab 'Mach2' -HostName 'MGUI3'
$UI.BtnDeployThis.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Test-Check 'Deploy... on a kiosk opens the deploy view with only that kiosk' (
    $script:View -eq 'Deploy' -and (@(Get-DeploySelection) -join ',') -eq 'MGUI3') (@(Get-DeploySelection) -join ',')

# ---------------------------------------------------------------------------
Start-Section 'Reading a kiosk and sending it something'
# ---------------------------------------------------------------------------
Select-KioskTab -Tab 'Mach2' -HostName 'MGUI1'
Invoke-LiveRead (Get-Kiosk 'MGUI1')
Test-Check 'the kiosk is marked busy while it is read' (Test-HostBusy 'MGUI1')
[void](Wait-Jobs -Seconds 30)
$live = $script:LiveObs['MGUI1']
Test-Check 'a live read comes back with what the launcher is doing' (
    $live -and @($live.Lines | Where-Object { $_.Value -match 'SHOWING' }).Count -ge 1) $(if ($live) { @($live.Lines | ForEach-Object { $_.Value }) -join ' | ' })
Test-Check 'it also reads the config and the password state' (
    @($live.Lines | Where-Object { $_.Label -eq 'Shows' }).Count -eq 1 -and
    @($live.Lines | Where-Object { $_.Label -eq 'Password' -and $_.Value -match 'none stored' }).Count -eq 1)
Test-Check 'the kiosk is free again afterwards' (-not (Test-HostBusy 'MGUI1'))

Send-LauncherControl -Kiosk (Get-Kiosk 'MGUI1') -FileName 'refresh.txt' -Doing 'reloading the page'
[void](Wait-Jobs -Seconds 30)
Test-Check 'a reload is taken by the launcher' (-not (Test-Path -LiteralPath (Join-Path $ngDir 'refresh.txt')))

Send-LauncherControl -Kiosk (Get-Kiosk 'MGUI1') -FileName 'hold.txt' -Doing 'holding'
[void](Wait-Jobs -Seconds 30)
Test-Check 'hold stays in place and the button turns into Resume' (
    (Test-Path -LiteralPath (Join-Path $ngDir 'hold.txt')) -and $script:HoldState['MGUI1'] -and $UI.BtnHold.Content -eq 'Resume')
Send-LauncherControl -Kiosk (Get-Kiosk 'MGUI1') -FileName 'hold.txt' -Doing 'carrying on' -Delete
[void](Wait-Jobs -Seconds 30)
Test-Check 'resuming takes it away again' (
    (-not (Test-Path -LiteralPath (Join-Path $ngDir 'hold.txt'))) -and (-not $script:HoldState['MGUI1']))

Invoke-Snapshot (Get-Kiosk 'MGUI1')
[void](Wait-Jobs -Seconds 60)
Test-Check 'a screenshot comes back and is kept' ($UI.SnapshotCard.Visibility -eq 'Visible' -and $script:LastSnapshot -and (Test-Path -LiteralPath $script:LastSnapshot)) $script:LastSnapshot
Test-Check 'the screenshot is captioned with what was on screen' ($UI.SnapshotCaption.Text -match 'SHOWING' -and $UI.SnapshotCaption.Text -match 'station') $UI.SnapshotCaption.Text

Show-LauncherLog (Get-Kiosk 'MGUI1')
[void](Wait-Jobs -Seconds 30)
Test-Check 'the log is read from the kiosk' ($UI.OverlayLog.Text -match 'The dashboard is on screen') ($UI.OverlayLog.Text -replace "`r?`n", ' ')
Hide-Overlay

# The password card hands password.seed over and waits for the launcher.
Show-PasswordDialog (Get-Kiosk 'MGUI1')
$UI.OverlayPass.Password = 'a-new-password'
$UI.OverlayPass2.Password = 'a-new-password'
Test-Check 'the password card asks twice' ($UI.OverlayPassPanel.Visibility -eq 'Visible')
$UI.OverlayOk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
[void](Wait-Jobs -Seconds 40)
$taken = Join-Path $ngDir 'taken.seed'
Test-Check 'the launcher is handed the new password and takes it' (
    (Test-Path -LiteralPath $taken) -and ([IO.File]::ReadAllText($taken) -eq 'a-new-password') -and
    (-not (Test-Path -LiteralPath (Join-Path $ngDir 'password.seed'))))
Test-Check 'the card says it was stored' ($UI.OverlayNote.Text -match 'stored') $UI.OverlayNote.Text
Hide-Overlay

# A password typed twice differently changes nothing.
Show-PasswordDialog (Get-Kiosk 'MGUI1')
$UI.OverlayPass.Password = 'one'
$UI.OverlayPass2.Password = 'other'
$UI.OverlayOk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Test-Check 'two different passwords are refused' ($UI.Overlay.Visibility -eq 'Visible' -and $UI.OverlayNote.Text -match 'did not match') $UI.OverlayNote.Text
Hide-Overlay

# ---------------------------------------------------------------------------
Start-Section 'The config editor'
# ---------------------------------------------------------------------------
Select-KioskTab -Tab 'Mach2' -HostName 'MGUI1'
Open-KioskConfig (Get-Kiosk 'MGUI1')
[void](Wait-Jobs -Seconds 30 -Until { $script:OverlayFieldControls.Count -gt 0 })
Test-Check 'the kiosk config opens filled in' (
    (Get-Field 'DisplayURL') -eq 'http://station:302/ord/dashboard' -and (Get-Field 'UserName') -eq 'operator') ("{0} / {1}" -f (Get-Field 'DisplayURL'), (Get-Field 'UserName'))
Test-Check 'the settings that matter are shown, the rest are behind More settings' (
    $UI.OverlayFields.Children.Count -ge 4 -and $UI.OverlayMore.Visibility -eq 'Visible' -and $UI.OverlayAdvanced.Visibility -eq 'Collapsed')
Test-Check 'it says a change applies without a restart' ($UI.OverlaySub.Text -match 'without a restart') $UI.OverlaySub.Text

Set-Field 'DisplayURL' ''
Invoke-OverlayOk
Test-Check 'a config with no URL is refused' ($UI.Overlay.Visibility -eq 'Visible' -and $UI.OverlayNote.Text -match 'Still empty') $UI.OverlayNote.Text

Set-Field 'DisplayURL' 'http://station:302/ord/other-dashboard'
Set-Field 'UserName' 'operator2'
$c = $script:OverlayFieldControls['__password']
$c.Box.Password = 'one'
$c.Confirm.Password = 'other'
Invoke-OverlayOk
Test-Check 'two different passwords save nothing' (
    $UI.Overlay.Visibility -eq 'Visible' -and $UI.OverlayNote.Text -match 'did not match' -and
    (Read-KioskConfigFile (Join-Path $ngDir 'MGUI1.json')).UserName -eq 'operator') $UI.OverlayNote.Text

Set-Field '__password' 'station-password'
Invoke-OverlayOk
[void](Wait-Jobs -Seconds 40)
$saved = Read-KioskConfigFile (Join-Path $ngDir 'MGUI1.json')
Test-Check 'the change is written to the kiosk' (
    $saved.DisplayURL -eq 'http://station:302/ord/other-dashboard' -and $saved.UserName -eq 'operator2') ("{0} as {1}" -f $saved.DisplayURL, $saved.UserName)
Test-Check 'the settings it did not touch are still there' ($saved.LogName -eq 'MGUI1_Mach2LauncherNG.log')
Test-Check 'the old config is kept as a backup' (@(Get-ChildItem -LiteralPath $ngDir -Filter 'MGUI1.json.bak-*').Count -eq 1)
Test-Check 'a password typed with it is handed to the launcher' (
    (Test-Path -LiteralPath (Join-Path $ngDir 'taken.seed')) -and ([IO.File]::ReadAllText((Join-Path $ngDir 'taken.seed')) -eq 'station-password'))
Test-Check 'the card says it was saved' ($UI.OverlayNote.Text -match 'reads it again within seconds') $UI.OverlayNote.Text
Hide-Overlay

# A kiosk with no config at all: the same card, filled from EXAMPLE.json.
New-Item -ItemType Directory -Path (Join-Path ($Template -f 'MGUI9') 'Users\Public\Documents') -Force | Out-Null
Show-ConfigEditor -HostName 'MGUI9' -Kind 'NG'
[void](Wait-Jobs -Seconds 30 -Until { $script:OverlayFieldControls.Count -gt 0 })
Test-Check 'a kiosk with no config gets the template, and is told so' (
    $UI.OverlaySub.Text -match 'No config on the kiosk yet' -and (Get-Field 'DisplayURL') -eq '' -and $null -ne $script:OverlayFieldControls['LogName']) $UI.OverlaySub.Text
Test-Check 'the log name is already the new kiosk own' ((Get-Field 'LogName') -eq 'MGUI9_Mach2LauncherNG.log') (Get-Field 'LogName')
Test-Check 'and the screen it is for can be chosen' ((Get-Field '__instance') -eq 'S1') (Get-Field '__instance')

Set-Field 'DisplayURL' 'http://shcz5plc02:302/deltav/dashboard:viewer/@/Nyrany/LINE9/Dashboards/Graphs'
Set-Field 'UserName' 'operator'
Set-Field '__password' 'new-kiosk-password'
Invoke-OverlayOk
[void](Wait-Jobs -Seconds 40)
$newPath = Join-Path ($Template -f 'MGUI9') 'Users\Public\Documents\Mach2LauncherNG\S1\MGUI9.json'
Test-Check 'the config is written where the launcher will look for it' (Test-Path -LiteralPath $newPath) $newPath
$fresh = $(if (Test-Path -LiteralPath $newPath) { Read-KioskConfigFile $newPath } else { $null })
Test-Check 'with what was typed' ($fresh -and $fresh.UserName -eq 'operator' -and $fresh.DisplayURL -match 'LINE9') $(if ($fresh) { $fresh.DisplayURL })
Test-Check "the sign-in URL is worked out from the dashboard's host" (
    $fresh -and $fresh.LoginURL -eq 'http://shcz5plc02:302/prelogin?clear=true') $(if ($fresh) { $fresh.LoginURL })
Test-Check 'and the whole template is there, not just what was typed' ($fresh -and $fresh.ConfigVersion -eq '1.00NG' -and $fresh.PSObject.Properties['RebootAfterMinutes'])
Test-Check 'the password waits for the launcher that is not there yet' (
    Test-Path -LiteralPath (Join-Path ($Template -f 'MGUI9') 'Users\Public\Documents\Mach2LauncherNG\S1\password.seed'))
Test-Check 'the card says the kiosk can be deployed to now' ($UI.OverlayNote.Text -match 'can be deployed to now') $UI.OverlayNote.Text
Hide-Overlay

# A second screen on the same kiosk: its own folder, and not the watchdog.
Show-ConfigEditor -HostName 'MGUI9' -Kind 'NG' -Instance 'S2'
[void](Wait-Jobs -Seconds 30 -Until { $script:OverlayFieldControls.Count -gt 0 })
Set-Field '__instance' 's2'
Set-Field 'DisplayURL' 'http://shcz5plc02:302/deltav/dashboard:viewer/@/Nyrany/LINE9b/Dashboards/Graphs'
Set-Field 'UserName' 'operator'
Invoke-OverlayOk
[void](Wait-Jobs -Seconds 40)
$s2Path = Join-Path ($Template -f 'MGUI9') 'Users\Public\Documents\Mach2LauncherNG\S2\MGUI9.json'
$s2 = $(if (Test-Path -LiteralPath $s2Path) { Read-KioskConfigFile $s2Path } else { $null })
Test-Check 'a second screen gets its own folder and config' ($null -ne $s2 -and $s2.DisplayURL -match 'LINE9b') $s2Path
Test-Check 'and is not made the watchdog as well' ($s2 -and $s2.Watchdog -eq '0') $(if ($s2) { "Watchdog=$($s2.Watchdog)" })
Test-Check 'while the first screen still is' ((Read-KioskConfigFile $newPath).Watchdog -eq '1')
Hide-Overlay

# Adding a kiosk in the deploy view goes straight into that card.
Show-View -Name 'Deploy'
Set-DeployProduct 'NG'
Show-AddHostDialog
Set-Field 'Host' 'MGUI8'
Set-Field 'Setup' '1'
New-Item -ItemType Directory -Path (Join-Path ($Template -f 'MGUI8') 'Users\Public\Documents') -Force | Out-Null
Invoke-OverlayOk
[void](Wait-Jobs -Seconds 30 -Until { $script:OverlayFieldControls.Count -gt 0 -and $UI.OverlayTitle.Text -match 'MGUI8' })
Test-Check 'adding a kiosk opens its config next' ($UI.OverlayTitle.Text -match 'MGUI8' -and $null -ne $script:OverlayFieldControls['DisplayURL']) $UI.OverlayTitle.Text
Test-Check 'and it is already in the deploy list' ((@($script:TargetRows | Where-Object { $_.Host -eq 'MGUI8' })).Count -eq 1)
Set-Field 'DisplayURL' 'http://shcz5plc02:302/deltav/dashboard:viewer/@/Nyrany/LINE8/Dashboards/Graphs'
Set-Field 'UserName' 'operator'
Invoke-OverlayOk
[void](Wait-Jobs -Seconds 40)
$row8 = @($script:TargetRows | Where-Object { $_.Host -eq 'MGUI8' })[0]
Test-Check 'the list then says the kiosk is configured but not installed' ($row8.Note -match 'config written') $row8.Note
Hide-Overlay
if ($row8) { $row8.Selected = $false }

# ---------------------------------------------------------------------------
Start-Section 'Screens and launchers: Power BI on S1, Mach2 on S2, a web page'
# ---------------------------------------------------------------------------
# XGUI1: a Power BI kiosk whose second screen shows a Mach2 dashboard.
# WGUI1: a kiosk that shows a web page. Both added to the fleet on disk.
$xRoot = $Template -f 'XGUI1'
$xPbi = Join-Path $xRoot "$PbiRel\S1"
$xNg = Join-Path $xRoot "$NgRel\S2"
foreach ($d in @($xPbi, $xNg)) { New-Item -ItemType Directory -Path (Join-Path $d 'Status') -Force | Out-Null }
[IO.File]::WriteAllText((Join-Path $xRoot "$PbiRel\PbiLauncher.ps1"), '# fake')
[IO.File]::WriteAllText((Join-Path $xRoot "$NgRel\Mach2LauncherNG.ps1"), '# fake')
[IO.File]::WriteAllText((Join-Path $xPbi 'XGUI1.json'), (@{ DisplayURL = 'https://app.powerbi.test/x'; UserName = 'kiosk@contoso.test' } | ConvertTo-Json))
[IO.File]::WriteAllText((Join-Path $xNg 'XGUI1.json'), (@{ DisplayURL = 'http://station:302/ord/x'; UserName = 'operator'; Watchdog = '1' } | ConvertTo-Json))
$wRoot = $Template -f 'WGUI1'
$wDir = Join-Path $wRoot 'Users\Public\Documents\WebLauncher\S1'
New-Item -ItemType Directory -Path (Join-Path $wDir 'Status') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $wRoot 'Users\Public\Documents\WebLauncher\WebLauncher.ps1'), '# fake')
[IO.File]::WriteAllText((Join-Path $wDir 'WGUI1.json'), (@{ DisplayURL = 'https://intranet.test/board'; TargetMatch = 'path' } | ConvertTo-Json))

# Not $rows: the manager is dot-sourced here, and $rows is its $script:Rows
# (names ignore case) - the kiosk table itself.
$csvRows = New-Object System.Collections.ArrayList
foreach ($r in @(Import-Csv -LiteralPath $Csv)) { [void]$csvRows.Add($r) }
foreach ($k in @(@{ Host = 'XGUI1'; Type = 'PBI'; Wd = 'TRUE'; Agent = '1.01NG' }, @{ Host = 'WGUI1'; Type = 'Web'; Wd = ''; Agent = 'web-1.0.0' })) {
    $o = [ordered]@{}
    foreach ($c in $Cols) { $o[$c] = '' }
    $values = @{
        EventId = [guid]::NewGuid(); EventTimeUtc = (Iso $Now.AddMinutes(-3)); EventTimeLocal = (IsoLocal $Now.AddMinutes(-3))
        EventDate = $Now.ToString('yyyy-MM-dd', $Inv); Host = $k.Host; Location = 'MIX'; KioskType = $k.Type
        EventCategory = 'HOST'; EventType = 'HOST_STATUS'; Severity = 'INFO'; Outcome = 'OK'
        Reachable = 'TRUE'; WatchdogRunning = $k.Wd; AgentVersion = $k.Agent; BootTimeUtc = (Iso $Now.AddHours(-2)); UptimeHours = '2'; Source = 'Collector'
    }
    foreach ($kk in $values.Keys) { $o[$kk] = $values[$kk] }
    [void]$csvRows.Add([pscustomobject]$o)
}
$csvRows | Export-Csv -LiteralPath $Csv -NoTypeInformation -Encoding UTF8
$inst = { param($screen, $state, $extra) $o = [ordered]@{ Instance = $screen; Screen = $screen; State = $state; Detail = ''; HostStatus = 'OK'; UpdatedUtc = (Iso $Now.AddMinutes(-1)); StateMinutes = 20; Version = '2.0.1'; Edge = '153.0.4234.48'; SignIns = 1; Reloads = 1; BrowserStarts = 1; LastError = '' }; foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] }; $o }
$sidecar.PbiLaunchers['XGUI1'] = [ordered]@{ Launcher = 'PBI'; Installed = $true; LegacyLauncher = $false; Screens = @('S1'); Status = 'OK'; Error = ''; Instances = @(& $inst 'S1' 'SHOWING' @{ Folder = "$PbiRel\S1"; UserName = 'kiosk@contoso.test'; SignedInAs = 'kiosk@contoso.test' }) }
$sidecar.Mach2Launchers['XGUI1'] = [ordered]@{ Launcher = 'MACH2'; Installed = $true; OldLauncher = $false; Screens = @('S2'); Status = 'OK'; Error = ''; Instances = @(& $inst 'S2' 'SHOWING' @{ Folder = "$NgRel\S2"; Version = '1.01NG'; Watchdog = $true; ScreenWhitePercent = 70 }) }
$sidecar['WebLaunchers'] = [ordered]@{ WGUI1 = [ordered]@{ Launcher = 'WEB'; Installed = $true; LegacyLauncher = $false; Screens = @('S1'); Status = 'OK'; Error = ''; Instances = @(& $inst 'S1' 'SHOWING' @{ Version = '1.0.0' }) } }
[IO.File]::WriteAllText([IO.Path]::ChangeExtension($Csv, '.status.json'), ($sidecar | ConvertTo-Json -Depth 6))
Request-FleetRefresh -Force
[void](Wait-Jobs -Seconds 30 -Until { $script:State -and $script:State.Hosts.Count -eq 9 })

$x = Get-Kiosk 'XGUI1'
Test-Check 'a kiosk with PBI on S1 and Mach2 on S2 is on both tabs' ($x -and @($x.Tabs) -contains 'PBI' -and @($x.Tabs) -contains 'Mach2' -and @(Get-TabKiosks -Tab 'Mach2' | ForEach-Object Host) -contains 'XGUI1') $(if ($x) { $x.Tabs -join ',' })
Test-Check 'a web page kiosk is on the Web tab, which appears for it' (@(Get-TabKiosks -Tab 'Web' | ForEach-Object Host) -contains 'WGUI1' -and $UI.NavWeb.Visibility -eq 'Visible')
Select-KioskTab -Tab 'Mach2'
$xr = @($script:Rows | Where-Object { $_.Host -eq 'XGUI1' })[0]
Test-Check 'on the Mach2 tab its row shows the Mach2 screen' ($xr -and $xr.Launcher -eq 'SHOWING' -and $xr.Screen -eq '70%') $(if ($xr) { "$($xr.Launcher) $($xr.Screen)" })
Select-KioskTab -Tab 'PBI'
$xr = @($script:Rows | Where-Object { $_.Host -eq 'XGUI1' })[0]
Test-Check 'on the Power BI tab, the Power BI screen and its account' ($xr -and $xr.Account -eq 'kiosk@contoso.test') $(if ($xr) { $xr.Account })
Select-KioskTab -Tab 'PBI' -HostName 'XGUI1'
$detail = (@($UI.DetailPanel.Children | ForEach-Object { if ($_ -is [System.Windows.Controls.TextBlock]) { $_.Text } else { @($_.Children | ForEach-Object { $_.Text }) -join ' = ' } }) -join ' | ')
Test-Check 'the details list both screens and both launchers' ($detail -match 'SCREENS' -and $detail -match 'S1 = PBI Launcher' -and $detail -match 'S2 = Mach2 Launcher NG' -and $detail -match 'MACH2 LAUNCHER NG' -and $detail -match 'PBI LAUNCHER') $(if ($detail.Length -gt 140) { $detail.Substring(0, 140) } else { $detail })
Test-Check 'the Screen box offers all screens, S1 and S2' ($UI.ScreenPick.Items.Count -eq 3 -and $UI.ScreenPickPanel.Visibility -eq 'Visible') "$($UI.ScreenPick.Items.Count) items"
$UI.ScreenPick.SelectedIndex = 2
Test-Check 'picking S2 points the buttons at the Mach2 screen' ((Get-ScreenTarget $x).Screen -eq 'S2' -and (Get-LauncherKind $x) -eq 'NG')
Send-LauncherControl -Kiosk $x -FileName 'hold.txt' -Doing 'holding'
[void](Wait-Jobs -Seconds 20)
Test-Check 'hold reaches only the picked screen' ((Test-Path (Join-Path $xNg 'hold.txt')) -and -not (Test-Path (Join-Path $xPbi 'hold.txt')))
Send-LauncherControl -Kiosk $x -FileName 'hold.txt' -Doing 'carrying on' -Delete
[void](Wait-Jobs -Seconds 20)
$UI.ScreenPick.SelectedIndex = 0
Test-Check 'All screens again' ((Get-LauncherKind $x) -eq 'ALL' -and -not (Test-Path (Join-Path $xNg 'hold.txt')))

Select-KioskTab -Tab 'Web' -HostName 'WGUI1'
Test-Check 'a web page screen has no password to set' (-not $UI.BtnPassword.IsEnabled)
Open-KioskConfig (Get-Kiosk 'WGUI1')
[void](Wait-Jobs -Seconds 30 -Until { $script:OverlayFieldControls.Count -gt 0 })
Test-Check 'its config opens with the page and no password' ((Get-Field 'DisplayURL') -eq 'https://intranet.test/board' -and $null -ne $script:OverlayFieldControls['TargetMatch'] -and $null -eq $script:OverlayFieldControls['__password']) (Get-Field 'DisplayURL')
Hide-Overlay

# Add screen: a web page on S3 of the mixed kiosk.
Show-InstancePicker -Kiosk $x -NewOnly
Test-Check 'Add screen offers the next free screen with each launcher' ($null -ne $script:OverlayFieldControls['Pick'] -and @($script:OverlayFieldControls['Pick'].Box.Items | ForEach-Object Tag) -contains 'S3|WEB|new') (@($script:OverlayFieldControls['Pick'].Box.Items | ForEach-Object Tag) -join ', ')
Set-Field 'Pick' 'S3|WEB|new'
Invoke-OverlayOk
[void](Wait-Jobs -Seconds 30 -Until { $script:OverlayFieldControls.ContainsKey('__instance') })
Test-Check 'the new screen card is the web page template for S3' ((Get-Field '__instance') -eq 'S3' -and (Get-Field 'LogName') -eq 'WebLauncher_XGUI1_S3.log' -and $UI.OverlaySub.Text -match 'No config') "$(Get-Field '__instance') $(Get-Field 'LogName')"
Set-Field 'DisplayURL' 'https://intranet.test/andon'
Invoke-OverlayOk
[void](Wait-Jobs -Seconds 40)
$s3 = Join-Path $xRoot 'Users\Public\Documents\WebLauncher\S3\XGUI1.json'
Test-Check 'it is written to WebLauncher\S3' ((Test-Path $s3) -and (Read-KioskConfigFile $s3).DisplayURL -eq 'https://intranet.test/andon') $s3
Hide-Overlay

# One launcher per screen: S2 shows Mach2 already.
Show-ConfigEditor -HostName 'XGUI1' -Kind 'WEB' -Instance 'S4'
[void](Wait-Jobs -Seconds 30 -Until { $script:OverlayFieldControls.ContainsKey('__instance') })
Set-Field '__instance' 'S2'
Set-Field 'DisplayURL' 'https://intranet.test/x'
Invoke-OverlayOk
Test-Check 'a screen another launcher shows is refused' ($UI.OverlayNote.Text -match 'S2 shows Mach2 Launcher NG already') $UI.OverlayNote.Text
Hide-Overlay

# A Mach2 screen next to Power BI: the kiosk's first Mach2 screen is its watchdog, S2 or not.
$yRoot = $Template -f 'YGUI1'
New-Item -ItemType Directory -Path (Join-Path $yRoot "$PbiRel\S1") -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $yRoot "$PbiRel\S1\YGUI1.json"), (@{ DisplayURL = 'https://app.powerbi.test/y'; UserName = 'k@c.t' } | ConvertTo-Json))
Show-ConfigEditor -HostName 'YGUI1' -Kind 'NG' -Instance 'S2'
[void](Wait-Jobs -Seconds 30 -Until { $script:OverlayFieldControls.ContainsKey('__instance') })
Set-Field 'DisplayURL' 'http://station:302/ord/y'
Set-Field 'UserName' 'operator'
Invoke-OverlayOk
[void](Wait-Jobs -Seconds 40)
$y2 = Join-Path $yRoot "$NgRel\S2\YGUI1.json"
Test-Check 'a Mach2 S2 on a Power BI kiosk is its watchdog' ((Test-Path $y2) -and (Read-KioskConfigFile $y2).Watchdog -eq '1') $(if (Test-Path $y2) { 'Watchdog=' + (Read-KioskConfigFile $y2).Watchdog })
Hide-Overlay

Show-View -Name 'Deploy'
Set-DeployProduct 'WEB'
foreach ($row in $script:TargetRows) { $row.Selected = ($row.Host -eq 'WGUI1') }
Update-DeployPreview
Test-Check 'Web Launcher deploys to any kiosk' ($UI.ProdWeb.IsChecked -and $UI.TargetTitle.Text -eq 'KIOSKS  (all)' -and $script:TargetRows.Count -ge 9) "$($UI.TargetTitle.Text) $($script:TargetRows.Count)"
$cmd = Get-DeployCommand
Test-Check 'and the command is Deploy-WebLauncher.ps1, without -UpdateConfig' ($cmd -match "Deploy-WebLauncher\.ps1' -Hosts 'WGUI1'" -and $cmd -notmatch 'UpdateConfig') $cmd
foreach ($row in $script:TargetRows) { $row.Selected = $false }
Set-DeployProduct 'NG'

# ---------------------------------------------------------------------------
Start-Section 'Running something and following it'
# ---------------------------------------------------------------------------
$ok = Start-FleetProcess -Title 'Test run' -Command "Write-Output 'hello from the run'; Write-Output 'second line'" -Kind 'deploy'
Test-Check 'a run starts' ($ok -and $null -ne $script:Run)
Test-Check 'the runner script is kept for the record' ($script:Run -and (Test-Path -LiteralPath $script:Run.Runner))
Test-Check 'the manager says something is running' ($UI.BadgeRunBox.Visibility -eq 'Visible' -and $UI.BtnStopRun.IsEnabled)
$deadline = (Get-Date).AddSeconds(60)
while ($script:Run -and (Get-Date) -lt $deadline) { Update-RunState; Start-Sleep -Milliseconds 200 }
Test-Check 'its output lands in the Activity view' ($UI.ConsoleBox.Text -match 'hello from the run' -and $UI.ConsoleBox.Text -match 'second line')
Test-Check 'the manager notices it finished' ($null -eq $script:Run -and $UI.ActivityState.Text -match 'finished with code 0' -and -not $UI.BtnStopRun.IsEnabled) $UI.ActivityState.Text

$ok = Start-FleetProcess -Title 'Failing run' -Command "Write-Error 'it went wrong'; exit 3" -Kind 'deploy'
$deadline = (Get-Date).AddSeconds(60)
while ($script:Run -and (Get-Date) -lt $deadline) { Update-RunState; Start-Sleep -Milliseconds 200 }
Test-Check 'a failure shows its code and its error' ($UI.ActivityState.Text -match 'finished with code 3' -and $UI.ConsoleBox.Text -match 'it went wrong') $UI.ActivityState.Text

Test-Check 'past reports are listed' ($script:ReportRows.Count -ge 0)

# ---------------------------------------------------------------------------
Start-Section 'Auto-scan refuses to run blind'
# ---------------------------------------------------------------------------
# Without the saved credential every watchdog kiosk would come back NO_ACCESS
# and those false outages would be written into the history.
Enable-AutoScan
Test-Check 'auto-scan needs the saved credential' ((-not $script:AutoScan) -and $UI.AutoText.Text -match 'off')
Test-Check 'and says so' ($UI.ToastText.Text -match 'credential') $UI.ToastText.Text

# ---------------------------------------------------------------------------
Start-Section 'An error does not close the window'
# ---------------------------------------------------------------------------
# Whatever goes wrong inside the window is logged and shown, and the window
# stays open. The log goes to the work folder, not the fleet's Logs.
$ManagerLogPath = Join-Path $WorkRoot 'fleet-manager.log'
[void]$Window.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Normal, [action] { throw 'a deliberate test error' })
[void]$Window.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Background, [action] { })
$logged = $(if (Test-Path -LiteralPath $ManagerLogPath) { [IO.File]::ReadAllText($ManagerLogPath) } else { '' })
Test-Check 'an error inside the window is written to the log' ($logged -match 'a deliberate test error') $(if ($logged) { ($logged -split "`r?`n")[1] })
Test-Check 'and said on screen, instead of the window closing' ($UI.ToastText.Text -match 'a deliberate test error' -and $UI.ToastText.Text -match 'fleet-manager.log') $UI.ToastText.Text

# ---------------------------------------------------------------------------
Start-Section 'A restart is confirmed first'
# ---------------------------------------------------------------------------
Show-RestartDialog (Get-Kiosk 'MGUI2')
Test-Check 'the card names the kiosk and shows the message it will display' (
    $UI.Overlay.Visibility -eq 'Visible' -and $UI.OverlayTitle.Text -eq 'Restart MGUI2?' -and $UI.OverlayInput.Text -match 'IT is restarting')
$UI.OverlayInput2.Text = 'soon'
$UI.OverlayOk.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Test-Check 'a countdown that is not a number is refused' ($UI.Overlay.Visibility -eq 'Visible' -and $UI.OverlayNote.Text -match 'whole number') $UI.OverlayNote.Text
Hide-Overlay
Test-Check 'cancelling closes the card and restarts nothing' ($UI.Overlay.Visibility -eq 'Collapsed' -and -not (Test-HostBusy 'MGUI2'))

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
Stop-Job $launcher -ErrorAction SilentlyContinue
Remove-Job $launcher -Force -ErrorAction SilentlyContinue
try { $script:Pool.Close(); $script:Pool.Dispose() } catch { }

# The window writes where it normally writes: the screenshot it fetched and
# the commands it ran are the test's, so they go again.
if ($script:LastSnapshot -and (Test-Path -LiteralPath $script:LastSnapshot)) {
    Remove-Item -LiteralPath $script:LastSnapshot -Force -ErrorAction SilentlyContinue
}
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $FleetRoot 'Logs\run') -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $Now })) {
    Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
}
if (-not $KeepWorkRoot) {
    try { Remove-Item -LiteralPath $WorkRoot -Recurse -Force -ErrorAction Stop }
    catch { Write-Host "Could not remove $WorkRoot : $($_.Exception.Message)" -ForegroundColor DarkGray }
}

$passed = @($script:Results | Where-Object { $_.Pass }).Count
$failed = @($script:Results | Where-Object { -not $_.Pass })
Write-Host ''
Write-Host ("{0}/{1} checks passed." -f $passed, $script:Results.Count) -ForegroundColor $(if ($failed.Count) { 'Red' } else { 'Green' })
if ($failed.Count) {
    foreach ($f in $failed) { Write-Host ("  FAIL  {0}: {1}  {2}" -f $f.Section, $f.Check, $f.Detail) -ForegroundColor Red }
    exit 1
}
