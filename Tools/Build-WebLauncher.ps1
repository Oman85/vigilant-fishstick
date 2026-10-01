#Requires -Version 5.1
<#
.SYNOPSIS
    Builds WebLauncher\WebLauncher.ps1 from PbiLauncher\PbiLauncher.ps1.

.DESCRIPTION
    Web Launcher is PBI Launcher without Power BI: the same Edge handling,
    DevTools client, screens, control files, status file, links and Back
    button, refresh and recovery - and none of the sign-in, the password,
    the account checks, Power BI's full screen and navigation, or the report
    and licence detection.

    Rather than two copies of that core drifting apart, the Web Launcher is
    generated: the PBI-only functions are dropped by name (through the
    PowerShell parser, not by line numbers), a few are replaced by the
    versions below, and the names are changed. Run it after changing
    PbiLauncher.ps1; Tests\Test-WebLauncher.ps1 checks the result.

.EXAMPLE
    .\Tools\Build-WebLauncher.ps1
#>
[CmdletBinding()]
param(
    [string]$Source,
    [string]$Destination
)

$ErrorActionPreference = 'Stop'
# In the body: under -File, $PSScriptRoot is empty in parameter defaults.
$here = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Source) { $Source = Join-Path $here '..\PbiLauncher\PbiLauncher.ps1' }
if (-not $Destination) { $Destination = Join-Path $here '..\WebLauncher\WebLauncher.ps1' }
$Source = (Resolve-Path -LiteralPath $Source).ProviderPath
$text = [IO.File]::ReadAllText($Source)
$nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }

# ---------------------------------------------------------------------------
# What goes
# ---------------------------------------------------------------------------
$drop = @(
    'Save-SignInPassword', 'Read-SignInPassword', 'Import-PasswordSeed', 'Get-SignInPassword', 'Invoke-SetPassword',
    'Send-Text', 'Send-Key', 'Send-Click',
    'Test-FullScreenAttemptAllowed', 'Invoke-ReportFullScreen', 'Invoke-WrongAccount',
    'Set-LoginBlocked', 'Clear-LoginBlock', 'Invoke-LoginStep'
)

# ---------------------------------------------------------------------------
# What is replaced
# ---------------------------------------------------------------------------
$replace = @{}

$replace['Get-EffectiveUrl'] = @'
function Get-EffectiveUrl {
    # The address as configured: no Power BI switches to add.
    param([string]$Url, [string]$Mode)
    return $Url
}
'@

$replace['Read-LauncherConfig'] = @'
function Read-LauncherConfig {
    <#
        Reads the config into one object with typed, validated values. Only
        DisplayURL is required; see EXAMPLE.json for the rest.
    #>
    param([Parameter(Mandatory)][string]$Path)

    $problems = New-Object System.Collections.Generic.List[string]
    $parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path))
    $raw = @($parsed)[0]
    if ($null -eq $raw) { throw "Config file is empty: $Path" }

    $url = [string](Get-ConfigValue $raw @('DisplayURL', 'URL'))
    if (-not $url) { throw "DisplayURL is missing in $Path" }
    $uri = $null
    if (-not [Uri]::TryCreate($url.Trim(), [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('https', 'http', 'file')) {
        throw "DisplayURL is not a web address: $url"
    }
    $url = $uri.AbsoluteUri

    $instance = $script:Instance

    $browserMode = ([string](Get-ConfigValue $raw @('BrowserMode') 'app')).ToLowerInvariant()
    if ($browserMode -notin @('app', 'kiosk')) { $problems.Add("BrowserMode '$browserMode' is not app or kiosk; using app."); $browserMode = 'app' }

    $match = ([string](Get-ConfigValue $raw @('TargetMatch') 'path')).ToLowerInvariant()
    if ($match -notin @('path', 'host', 'exact')) { $problems.Add("TargetMatch '$match' is not path, host or exact; using path."); $match = 'path' }

    $refreshMinutes = Get-ConfigValue $raw @('RefreshMinutes')
    if ($null -ne $refreshMinutes) { $refreshMinutes = ConvertTo-Number $refreshMinutes 0 0 10080 }
    elseif (ConvertTo-Flag (Get-ConfigValue $raw @('EnableRefresh')) $false) { $refreshMinutes = ConvertTo-Number (Get-ConfigValue $raw @('BrowserRefreshDelay')) 15 1 10080 }
    else { $refreshMinutes = 0 }

    $refreshTimes = @(ConvertTo-TimesOfDay -Values (ConvertTo-StringList (Get-ConfigValue $raw @('RefreshTimes', 'ForcedRefreshTime'))) -What 'refresh' -Problems $problems)

    $restartTime = $null
    if (ConvertTo-Flag (Get-ConfigValue $raw @('ScheduledRestartEnabled')) $false) {
        $t = @(ConvertTo-TimesOfDay -Values (ConvertTo-StringList (Get-ConfigValue $raw @('ScheduledRestartTime'))) -What 'restart' -Problems $problems)
        if ($t.Count -gt 0) { $restartTime = $t[0] }
    }

    $defaultLog = if ($instance -ieq 'S1') { "WebLauncher_$ComputerName.log" } else { "WebLauncher_${ComputerName}_$instance.log" }
    $logName = [IO.Path]::GetFileName([string](Get-ConfigValue $raw @('LogName') $defaultLog))

    $profileDir = [string](Get-ConfigValue $raw @('ProfileDir') (Join-Path $env:LOCALAPPDATA "WebLauncher\Profile-$instance"))
    $profileDir = [Environment]::ExpandEnvironmentVariables($profileDir).TrimEnd('\')

    $logDir = [string](Get-ConfigValue $raw @('LogPath') (Join-Path $Here 'Logs'))
    if (-not $logDir) { $logDir = Join-Path $Here 'Logs' }
    $logDir = [Environment]::ExpandEnvironmentVariables($logDir)

    $cfg = [pscustomobject]@{
        Path                     = $Path
        Instance                 = $instance
        DisplayUrl               = $url
        TargetMatch              = $match
        UserName                 = ''
        LoginHosts               = @()
        ReportHosts              = @()
        BrowserMode              = $browserMode
        InPrivate                = ConvertTo-Flag (Get-ConfigValue $raw @('InPrivate')) $true
        FullScreenWindow         = ConvertTo-Flag (Get-ConfigValue $raw @('KioskMode', 'FullScreenWindow')) $true
        ReportFullScreen         = 'none'
        HideNavigation           = $false
        UsePrimaryScreen         = ConvertTo-Flag (Get-ConfigValue $raw @('UsePriScreen', 'UsePrimaryScreen')) $false
        ScreenNumber             = [int](ConvertTo-Number (Get-ConfigValue $raw @('ScreenSelect', 'ScreenNumber')) 1 1 16)
        DisplayWaitSeconds       = [int](ConvertTo-Number (Get-ConfigValue $raw @('DisplayWaitSeconds')) 120 0 3600)
        ZoomPercent              = [int](ConvertTo-Number (Get-ConfigValue $raw @('ZoomPercent')) 100 25 500)
        BrowserLanguage          = [string](Get-ConfigValue $raw @('BrowserLanguage') '')
        ExtraBrowserArgs         = @(ConvertTo-StringList (Get-ConfigValue $raw @('ExtraBrowserArgs')))
        EdgePath                 = [string](Get-ConfigValue $raw @('EdgePath') '')
        ProfileDir               = $profileDir
        DebugPort                = [int](ConvertTo-Number (Get-ConfigValue $raw @('DebugPort')) 0 0 65535)
        RefreshMinutes           = [double]$refreshMinutes
        RefreshTimes             = $refreshTimes
        RestartTime              = $restartTime
        RestartDelaySeconds      = [int](ConvertTo-Number (Get-ConfigValue $raw @('RestartDelay')) 30 0 600)
        StartupDelaySeconds      = [int](ConvertTo-Number (Get-ConfigValue $raw @('StartupDelay')) 0 0 3600)
        Disabled                 = ConvertTo-Flag (Get-ConfigValue $raw @('DisableStartup')) $false
        HealthCheckSeconds       = ConvertTo-Number (Get-ConfigValue $raw @('HealthCheckSeconds')) 20 1 600
        BlankReloadSeconds       = ConvertTo-Number (Get-ConfigValue $raw @('BlankReloadSeconds')) 120 0 7200
        OffTargetSeconds         = ConvertTo-Number (Get-ConfigValue $raw @('OffTargetSeconds')) 20 0 3600
        Supervised               = ConvertTo-Flag (Get-ConfigValue $raw @('Supervised')) $true
        BackButton               = ConvertTo-Flag (Get-ConfigValue $raw @('BackButton')) $true
        BackButtonText           = [string](Get-ConfigValue $raw @('BackButtonText') 'Back')
        BackButtonPosition       = ([string](Get-ConfigValue $raw @('BackButtonPosition') 'bottom-left')).ToLowerInvariant()
        ReturnAfterSeconds       = [int](ConvertTo-Number (Get-ConfigValue $raw @('ReturnAfterSeconds')) 120 0 86400)
        KeepLinksInWindow        = ConvertTo-Flag (Get-ConfigValue $raw @('KeepLinksInWindow')) $true
        ErrorChecksBeforeReload  = [int](ConvertTo-Number (Get-ConfigValue $raw @('ErrorChecksBeforeReload')) 3 1 100)
        MaxReloadsBeforeRelaunch = [int](ConvertTo-Number (Get-ConfigValue $raw @('MaxReloadsBeforeRelaunch')) 3 1 100)
        RebootAfterRelaunches    = [int](ConvertTo-Number (Get-ConfigValue $raw @('RebootAfterRelaunches')) 0 0 100)
        ErrorPhrases             = @(ConvertTo-StringList (Get-ConfigValue $raw @('ErrorPhrases') $DefaultErrorPhrases))
        ParkMouse                = ConvertTo-Flag (Get-ConfigValue $raw @('ParkMouse')) $true
        LogDir                   = $logDir
        RemoteLogDir             = [string](Get-ConfigValue $raw @('RemoteLogPath') '')
        LogName                  = $logName
        DebugLogging             = ConvertTo-Flag (Get-ConfigValue $raw @('DebugLogging')) $false
        JsonVersion              = [string](Get-ConfigValue $raw @('ConfigVersion', 'JsonVer') '')
        Problems                 = $problems
        EffectiveUrl             = ''
        BrowserSignature         = ''
    }
    if ($cfg.BackButtonPosition -notin @('top-left', 'top-right', 'bottom-left', 'bottom-right')) {
        $problems.Add("BackButtonPosition '$($cfg.BackButtonPosition)' is not top-left, top-right, bottom-left or bottom-right; using bottom-left.")
        $cfg.BackButtonPosition = 'bottom-left'
    }
    $cfg.EffectiveUrl = $cfg.DisplayUrl

    # Anything that needs a new Edge when it changes. Everything else in the
    # file applies on the next tick.
    $cfg.BrowserSignature = (@(
            $cfg.EffectiveUrl, $cfg.BrowserMode, $cfg.InPrivate, $cfg.FullScreenWindow, $cfg.UsePrimaryScreen, $cfg.ScreenNumber,
            $cfg.ZoomPercent, $cfg.BrowserLanguage, ($cfg.ExtraBrowserArgs -join ' '), $cfg.EdgePath, $cfg.ProfileDir, $cfg.DebugPort
        ) -join '|')

    return $cfg
}
'@

$replace['Get-PageState'] = @'
function Get-PageState {
    param([Parameter(Mandatory)]$Config)
    $options = [ordered]@{ phrases = @($Config.ErrorPhrases) }
    return (Invoke-PageJs -Config $Config -Expression ('P.state({0})' -f (ConvertTo-Json -InputObject $options -Compress -Depth 4)))
}
'@

$replace['Test-IsTargetUrl'] = @'
function Test-IsTargetUrl {
    <#
        Is the page the one to show? TargetMatch decides:
          path  (default) the same host, and a path that starts with the
                configured one - so a site that redirects / to /home, or
                moves between its own pages under it, is still "on it"
          host  any page on the same host
          exact the same host, path and query
    #>
    param([string]$Current, [string]$Target, [string]$Match = 'path')

    $c = $null; $t = $null
    if (-not [Uri]::TryCreate($Current, [UriKind]::Absolute, [ref]$c)) { return $false }
    if (-not [Uri]::TryCreate($Target, [UriKind]::Absolute, [ref]$t)) { return $false }
    if ($c.Host -ne $t.Host) { return $false }
    if ($Match -eq 'host') { return $true }

    $tp = $t.AbsolutePath.TrimEnd('/').ToLowerInvariant()
    $cp = $c.AbsolutePath.TrimEnd('/').ToLowerInvariant()
    if ($Match -eq 'exact') { return ($cp -eq $tp -and $c.Query -eq $t.Query) }
    return (-not $tp -or $cp -eq $tp -or $cp.StartsWith($tp + '/'))
}
'@

$replace['Get-TargetKey'] = @'
function Get-TargetKey {
    # Test-IsTargetUrl's rule in a form the page script can apply itself.
    param([Parameter(Mandatory)][string]$Url, [string]$Match = 'path')

    $u = [Uri]$Url
    return [ordered]@{
        host  = $u.Host.ToLowerInvariant()
        path  = $u.AbsolutePath.TrimEnd('/').ToLowerInvariant()
        query = $u.Query
        match = $Match
    }
}
'@

$replace['Initialize-Status'] = @'
function Initialize-Status {
    param($Config)
    $script:Status = [ordered]@{
        Host            = $ComputerName
        Instance        = $Config.Instance
        Launcher        = 'WEB'
        Screen          = $Instance
        LauncherVersion = $LauncherVersion
        WindowsUser     = "$env:USERDOMAIN\$env:USERNAME"
        Pid             = $PID
        StartedUtc      = [DateTime]::UtcNow.ToString('o')
        State           = 'STARTING'
        StateSinceUtc   = [DateTime]::UtcNow.ToString('o')
        Detail          = ''
        DisplayUrl      = $Config.DisplayUrl
        CurrentUrl      = ''
        Title           = ''
        Supervised      = $true
        EdgeVersion     = ''
        BrowserPid      = 0
        BrowserStarts   = 0
        Reloads         = 0
        PcBootUtc       = ''
        LastShownUtc    = ''
        LastReloadUtc   = ''
        LastError       = ''
        UpdatedUtc      = ''
    }
}
'@

$replace['Save-Snapshot'] = @'
function Save-Snapshot {
    <#
        snapshot.txt: what the screen shows, for someone who is not in front
        of it. Status\<screen>.png (a screenshot of the page) and
        Status\<screen>.snapshot.json (address, title, state).
    #>
    param([Parameter(Mandatory)]$Config)

    $base = Join-Path $script:StatusDir $script:InstanceName
    $info = [ordered]@{
        TakenUtc = [DateTime]::UtcNow.ToString('o')
        State    = $script:Status.State
        Detail   = $script:Status.Detail
        Url      = ''
        Title    = ''
        Image    = ''
        Error    = ''
    }
    try {
        if (-not $script:Supervised) { throw 'not available unsupervised (no DevTools connection)' }
        if (-not $script:Browser) { throw 'Edge is not running' }
        $st = Get-PageState -Config $Config
        if ($st) { $info.Url = [string]$st.url; $info.Title = [string]$st.title }
        $shot = Invoke-Cdp -Config $Config -Method 'Page.captureScreenshot' -Params @{ format = 'png' } -TimeoutSec 30
        $png = "$base.png"
        [IO.File]::WriteAllBytes("$png.tmp", [Convert]::FromBase64String([string]$shot.data))
        Move-Item -LiteralPath "$png.tmp" -Destination $png -Force
        $info.Image = Split-Path -Leaf $png
        Write-Log "snapshot.txt: saved a screenshot of $($info.Url)."
    }
    catch {
        $info.Error = Get-ErrorText $_
        Write-Log "snapshot.txt: no screenshot - $($info.Error)" 'WARN'
    }
    try { Write-JsonFile -Path "$base.snapshot.json" -Object $info } catch {}
}
'@

$replace['Invoke-SupervisedTick'] = @'
function Invoke-SupervisedTick {
    # Returns the number of seconds to sleep before the next tick.
    param([Parameter(Mandatory)]$Config)

    $s = $script:Session
    $now = [DateTime]::UtcNow

    # --- the browser -------------------------------------------------------
    $health = Get-BrowserHealth -Config $Config
    if ($health -eq 'hung') {
        $s.BrowserHung++
        Write-Log ("Edge is running but not answering (check {0})." -f $s.BrowserHung) 'WARN'
        if ($s.BrowserHung -ge 3) { Restart-Browser -Config $Config -Why 'Edge stopped answering' }
        return 5
    }
    if ($health -eq 'gone') {
        if ($script:Browser) {
            Write-Log 'Edge has closed.' 'WARN'
            $script:Browser = $null
            Disconnect-Cdp
            $s.Relaunches.Add($now)
        }
        if ($now -lt $s.NextLaunchUtc) { return 2 }
        Set-State 'LAUNCHING'
        try {
            Start-Browser -Config $Config -Reason $(if ($script:Status.BrowserStarts -eq 0) { 'startup' } else { 'Edge had closed' })
            $s.LaunchFailures = 0
        }
        catch { Register-LaunchFailure -ErrorRecord $_ }
        return 2
    }
    $s.BrowserHung = 0

    # --- the page -----------------------------------------------------------
    $st = $null
    try { $st = Get-PageState -Config $Config }
    catch {
        $text = Get-ErrorText $_
        if ($text -match 'refused|Page script failed') {
            # Usually mid-navigation: the page's script context is being
            # replaced. Only a page that keeps refusing is a problem.
            $s.CdpRefused++
            if ($s.CdpRefused -lt 10) { return 2 }
            $s.CdpRefused = 0
            Write-Log "The page keeps refusing to be read: $text" 'WARN'
            Open-Target -Config $Config -Why 'the page could not be read'
            return 3
        }
        $s.CdpFailures++
        Write-Log ("Cannot read the page (check {0}): {1}" -f $s.CdpFailures, $text) 'WARN'
        if ($s.CdpFailures -ge 3) {
            $s.CdpFailures = 0
            Restart-Browser -Config $Config -Why 'the page stopped responding'
        }
        return 3
    }
    $s.CdpFailures = 0
    $s.CdpRefused = 0
    if (-not $st) { return 2 }
    try {
        if (@(Invoke-StrayPages -Config $Config -MainOnSignIn $false)[-1]) { return 2 }
    }
    catch { Write-Log ("Checking for extra windows failed: {0}" -f (Get-ErrorText $_)) 'DEBUG' }

    $script:Status.CurrentUrl = [string]$st.url
    $script:Status.Title = [string]$st.title
    if (-not $s.LoggedScreen -and $st.screen) {
        $s.LoggedScreen = $true
        Write-Log ("Page window: {0},{1}, screen {2}x{3}, viewport {4}x{5}, pixel ratio {6}." -f $st.screen.x, $st.screen.y, $st.screen.w, $st.screen.h, $st.screen.iw, $st.screen.ih, $st.screen.dpr)
    }
    Write-Log ("Page: {0} ready={1} text={2} errors={3}" -f $st.url, $st.ready, $st.textLen, (@($st.errors) -join ';')) 'DEBUG'

    $url = [string]$st.url
    $pageHost = [string]$st.host

    # --- an Edge error page, or nothing ------------------------------------
    if ($url -match '^(chrome|edge)-error:' -or $url -eq 'about:blank' -or $url -eq '' -or $url -match '^(chrome|edge)://') {
        if ($now -lt $s.NextNavigateUtc) { return 3 }
        $s.NavigateStreak++
        # 0 s, 30 s, 1, 2, 4 min, then every 5 min.
        $waits = @(0, 30, 60, 120, 240, 300)
        $s.NextNavigateUtc = $now.AddSeconds($waits[[math]::Min($s.NavigateStreak, $waits.Count - 1)])
        $why = if ($url -match 'error') { 'Edge showed an error page - network or site down?' } else { "the page was $url" }
        Set-State 'RECOVERING' $why
        Open-Target -Config $Config -Why $why
        return 3
    }

    # --- somewhere other than the page ------------------------------------
    $onTarget = Test-IsTargetUrl -Current $url -Target $Config.EffectiveUrl -Match $Config.TargetMatch
    if (-not $onTarget) {
        if ($s.ShownSinceLoad -or $s.Browsing) {
            # The page was up, so this is someone who followed a link out of
            # it. Leave them be: the page has a Back button and goes home by
            # itself after ReturnAfterSeconds without use. The launcher only
            # steps in if that did not happen.
            Start-Browsing -Url $url
            $idle = $null
            if ($st.back -and $null -ne $st.back.idle) { $idle = [double]$st.back.idle }
            if ($Config.ReturnAfterSeconds -gt 0) {
                if ($null -ne $idle) { $unused = $idle; $limit = $Config.ReturnAfterSeconds + 15 }
                else { $unused = ($now - $s.BrowsingSinceUtc).TotalSeconds; $limit = $Config.ReturnAfterSeconds }
                if ($unused -ge $limit) {
                    Open-Target -Config $Config -Why ("{0} has not been used for {1:0} s" -f $pageHost, $unused)
                    return 3
                }
            }
            $detail = "someone opened $pageHost from the page"
            if ($Config.ReturnAfterSeconds -gt 0) { $detail += "; back to it after $($Config.ReturnAfterSeconds) s unused" }
            Set-State 'BROWSING' $detail
            return [math]::Min(5, $Config.HealthCheckSeconds)
        }
        # A site may take a few redirects to get there; only step in if it
        # does not.
        if ($s.OffTargetSinceUtc -eq [DateTime]::MinValue) { $s.OffTargetSinceUtc = $now; return 3 }
        if ($now -lt $s.OffTargetSinceUtc.AddSeconds($Config.OffTargetSeconds)) { return 3 }
        $s.OffTargetSinceUtc = [DateTime]::MinValue
        Set-State 'LOADING' "the page was on $url, not the configured address"
        Open-Target -Config $Config -Why "the page was on $url"
        return 3
    }
    $s.OffTargetSinceUtc = [DateTime]::MinValue
    $s.NavigateStreak = 0
    $s.NextNavigateUtc = [DateTime]::MinValue

    # --- on the page --------------------------------------------------------
    if ($s.Browsing) {
        Write-Log ("Back on the page after {0:0} s away." -f ($now - $s.BrowsingSinceUtc).TotalSeconds)
        $s.Browsing = $false
        Reset-PageLoad -Config $Config
    }
    $errors = @($st.errors)
    $sinceLoad = ($now - $s.PageLoadedUtc).TotalSeconds

    if ($errors.Count -gt 0) {
        $s.HealthyStreak = 0
        $s.ErrorStreak++
        if ($s.ErrorStreak -eq 1) { Write-Log ("The page shows: {0}" -f ($errors -join '; ')) 'WARN' }
        if ($s.ErrorStreak -ge $Config.ErrorChecksBeforeReload) {
            Invoke-Recovery -Config $Config -Why ("the page shows '{0}'" -f ($errors -join "', '"))
        }
        return [math]::Min(5, $Config.HealthCheckSeconds)
    }
    $s.ErrorStreak = 0

    # Loaded, and not an empty page.
    $drawn = $st.ready -eq 'complete' -and ([int]$st.textLen -gt 0 -or [int]$st.media -gt 0)
    if (-not $drawn) {
        $s.HealthyStreak = 0
        if ($Config.BlankReloadSeconds -gt 0 -and $sinceLoad -gt $Config.BlankReloadSeconds) {
            Invoke-Recovery -Config $Config -Why ("the page has shown nothing for {0:0} s" -f $sinceLoad)
        }
        elseif ($script:Status.State -ne 'RECOVERING') {
            Set-State 'LOADING' 'waiting for the page to load'
        }
        return 3
    }

    $s.HealthyStreak++
    if ($s.HealthyStreak -ge 2 -and $s.Recoveries -gt 0) {
        Write-Log ("The page is back after {0} recovery step(s)." -f $s.Recoveries)
        $s.Recoveries = 0
        $s.LastRecoveryUtc = [DateTime]::MinValue
    }
    Set-State 'SHOWING' ''
    $s.ShownSinceLoad = $true
    $script:Status.LastShownUtc = [DateTime]::UtcNow.ToString('o')

    # --- refresh ------------------------------------------------------------
    if ($now -ge $s.NextIntervalRefreshUtc) {
        Invoke-Reload -Config $Config -Why ("every {0} min" -f $Config.RefreshMinutes)
        return 3
    }
    foreach ($t in $Config.RefreshTimes) {
        if (Test-DailyDue -At $t -Tag 'refresh' -Done $s.TimedDone) {
            Invoke-Reload -Config $Config -Why ('daily refresh at {0:hh\:mm}' -f $t)
            return 3
        }
    }
    return $Config.HealthCheckSeconds
}
'@

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
$ast = [Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$null)
$functions = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false))
$names = @($functions | ForEach-Object { $_.Name })
foreach ($n in @($drop + @($replace.Keys))) { if ($names -notcontains $n) { throw "PbiLauncher.ps1 has no function $n any more - update Build-WebLauncher.ps1." } }

# From the end, so offsets stay valid.
$edits = @($functions | Where-Object { $drop -contains $_.Name -or $replace.ContainsKey($_.Name) } | Sort-Object { $_.Extent.StartOffset } -Descending)
foreach ($f in $edits) {
    $new = if ($replace.ContainsKey($f.Name)) { $replace[$f.Name].Replace("`r`n", "`n").Replace("`n", $nl) } else { '' }
    $text = $text.Substring(0, $f.Extent.StartOffset) + $new + $text.Substring($f.Extent.EndOffset)
}

. (Join-Path $here 'Build-WebLauncher.Parts.ps1')
$text = Invoke-WebLauncherTextEdits -Text $text -NewLine $nl

$tokens = $null; $errors = $null
[void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ("The generated Web Launcher does not parse: {0} (line {1})" -f $errors[0].Message, $errors[0].Extent.StartLineNumber) }

$dir = Split-Path -Parent $Destination
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllText($Destination, $text, (New-Object Text.UTF8Encoding($true)))
Write-Host ("Built {0} ({1:N0} bytes) from {2}." -f $Destination, $text.Length, $Source)
