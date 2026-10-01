<#
    The text edits Build-WebLauncher.ps1 makes after dropping and replacing
    functions: the header and parameters, the page script, the Back button's
    rule, the start-up and the names. Each edit must find what it replaces,
    so a change to PbiLauncher.ps1 that moves one of them fails the build
    instead of producing a launcher that half works.
#>

function Invoke-WebLauncherTextEdits {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$NewLine)

    $script:t = $Text
    $nl = $NewLine
    function Set-Between {
        # Replaces from the start of $From up to (not including) $To.
        param([string]$From, [string]$To, [string]$With)
        $a = $script:t.IndexOf($From)
        if ($a -lt 0) { throw "Build-WebLauncher: cannot find '$From'" }
        $b = $script:t.IndexOf($To, $a + $From.Length)
        if ($b -lt 0) { throw "Build-WebLauncher: cannot find '$To' after '$From'" }
        $script:t = $script:t.Substring(0, $a) + $With.Replace("`r`n", "`n").Replace("`n", $nl) + $script:t.Substring($b)
    }
    function Set-Text {
        param([string]$Old, [string]$New)
        $o = $Old.Replace("`r`n", "`n").Replace("`n", $nl)
        if (-not $script:t.Contains($o)) { throw "Build-WebLauncher: cannot find '$($Old.Substring(0, [math]::Min(70, $Old.Length)))'" }
        $script:t = $script:t.Replace($o, $New.Replace("`r`n", "`n").Replace("`n", $nl))
    }

    # --- header, parameters, folders ------------------------------------------
    Set-Between -From '#Requires -Version 5.1' -To '# Strict mode is deliberate.' -With @'
#Requires -Version 5.1
<#
.SYNOPSIS
    Web Launcher: shows one web page full screen on a kiosk screen and keeps
    it there.

.DESCRIPTION
    Generated from PbiLauncher.ps1 by Tools\Build-WebLauncher.ps1 - change
    that, not this file. The same Edge handling as PBI Launcher, without
    anything Power BI: no sign-in, no password, no account checks.

    For as long as the kiosk account is signed in, it:

      - starts Microsoft Edge full screen on the configured display,
        InPrivate, with a profile of its own
      - opens the page, reloads it on an interval and at fixed times of day
      - watches it and puts things right without anyone at the kiosk: Edge's
        own error page (site or network down), error text on the page, a
        page that shows nothing, a hung or crashed page, a closed browser,
        another page it ended up on
      - lets people follow links: the linked page opens in the kiosk window
        (never in a new one), with a "Back" button, and the page comes back
        by itself after ReturnAfterSeconds (120) without use
      - writes a CMTrace log (locally and to the central share) and a status
        file that the fleet tools read over the admin share

    Which pages count as "the page" is TargetMatch: path (default - the same
    site, under the configured path), host (anywhere on the site) or exact.

  Folders

    WebLauncher.ps1 sits in C:\Users\Public\Documents\WebLauncher. Each
    screen has a folder next to it (S1, S2, ...) holding its config
    (<COMPUTERNAME>.json), control files, Status\ and Logs\. -Instance names
    the folder; S1 is the default. A screen number belongs to one launcher:
    a web page on S2 next to Power BI on S1 is fine, both on S1 is not.

  Control files (in the screen's folder)

    kill.txt      stop the launcher and close Edge
    relaunch.txt  restart Edge
    refresh.txt   reload the page
    restart.txt   restart the PC in 10 seconds
    snapshot.txt  save a screenshot and a page summary in Status\
    hold.txt      pause: the launcher watches but does nothing, so someone
                  can use the browser. Delete it to resume.

    Each file except hold.txt is deleted when it is acted on.

.PARAMETER Instance
    The screen's folder next to this script. Default S1.

.PARAMETER ConfigPath
    Config file. Default: <COMPUTERNAME>.json, then config.json, in the
    screen's folder.

.PARAMETER ShowConsole
    Keep the console window on screen and echo the log to it.

.PARAMETER Headless
    Run Edge without a window. For testing only.

.PARAMETER ExitAfterSeconds
    Stop after this long. For testing only.

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File C:\Users\Public\Documents\WebLauncher\WebLauncher.ps1 -Instance S2

.EXAMPLE
    .\WebLauncher.ps1 -Instance S1 -ShowConsole
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Instance = 'S1',
    [string]$ConfigPath,
    [switch]$ShowConsole,
    [switch]$Headless,
    [ValidateRange(0, 604800)][int]$ExitAfterSeconds = 0
)

'@
    Set-Between -From '$LauncherVersion = ' -To '$Invariant = [Globalization.CultureInfo]::InvariantCulture' -With @'
$LauncherVersion = '1.0.0'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$ComputerName = $env:COMPUTERNAME.ToUpperInvariant()
$script:LegacyLayout = $false
$SetPassword = $false
$Here = Join-Path $ScriptDir $Instance

'@

    # --- error text -------------------------------------------------------------
    Set-Between -From '$DefaultErrorPhrases = @(' -To ('function Get-ConfigValue') -With @'
$DefaultErrorPhrases = @(
    'HTTP ERROR',
    '500 Internal Server Error',
    '502 Bad Gateway',
    '503 Service Unavailable',
    '504 Gateway Time',
    'Service Unavailable',
    "This page isn't working",
    "Hmm, we can't reach this page",
    "This site can't be reached"
)

'@

    # --- the page probe -----------------------------------------------------------
    # A here-string cannot hold its own terminator, so the page script is
    # put together from its parts.
    $pageJs = @'
(function () {
  if (window.__pbil2) return;
  var P = {};
  P.list = function (sel, root) {
    try { return Array.prototype.slice.call((root || document).querySelectorAll(sel)); } catch (e) { return []; }
  };
  P.text = function () { return (document.body && (document.body.innerText || '')) || ''; };
  P.state = function (o) {
    var phrases = o.phrases || [];
    var t = P.text();
    var low = t.toLowerCase();
    var s = {
      url: location.href, host: location.hostname.toLowerCase(), proto: location.protocol, title: document.title,
      ready: document.readyState, textLen: t.trim().length, media: 0, onLogin: false,
      docFullscreen: !!(document.fullscreenElement || document.webkitFullscreenElement),
      errors: [], screen: null, back: null
    };
    // Something to see besides text: pictures, video, frames, big enough
    // to matter. A page of only a picture or a dashboard frame is not empty.
    var m = P.list('img, svg, canvas, video, iframe, object, embed');
    for (var i = 0; i < m.length && s.media < 3; i++) {
      var r = m[i].getBoundingClientRect();
      if (r.width >= 40 && r.height >= 40) s.media++;
    }
    var b = window.__pbilBack;
    s.back = b ? { present: !!b.present, idle: b.idle(), onReport: !!b.onReport } : null;
    for (var j = 0; j < phrases.length; j++) {
      if (phrases[j] && low.indexOf(phrases[j].toLowerCase()) >= 0) s.errors.push(phrases[j]);
    }
    s.screen = { x: window.screenX, y: window.screenY, w: screen.width, h: screen.height, iw: window.innerWidth, ih: window.innerHeight, dpr: window.devicePixelRatio };
    return s;
  };
  window.__pbil2 = P;
})();
'@
    $with = '$PageHelperJs = @''' + "`n" + $pageJs + "`n" + "'@" + "`n`n"
    Set-Between -From '$PageHelperJs = @''' -To '# Put into every page Edge loads' -With $with

    # --- the Back button's rule: TargetMatch -----------------------------------------
    Set-Between -From '  function isReport() {' -To '  function onLogin()' -With @'
  function isReport() {
    var k = O.key;
    if (low(location.hostname) !== k.host) return false;
    if (k.match === 'host') return true;
    var p = low(location.pathname).replace(/\/+$/, '');
    if (k.match === 'exact') return p === k.path && location.search === k.query;
    return !k.path || p === k.path || p.indexOf(k.path + '/') === 0;
  }

'@
    Set-Text '        key         = (Get-TargetKey -Url $Config.EffectiveUrl)' '        key         = (Get-TargetKey -Url $Config.EffectiveUrl -Match $Config.TargetMatch)'

    # --- refresh.txt: no Power BI refusals to go around ----------------------------
    Set-Text @'
        if ($script:Browser -and $script:Supervised -and $script:Session.RefusedStreak -gt 0) {
            # Reloading Power BI's refusal page would only refuse again; try
            # the report now, for whoever has just fixed the account.
            $script:Session.NextRefusedUtc = [DateTime]::MinValue
            Open-Target -Config $Config -Why 'refresh.txt'
        }
        elseif ($script:Browser -and $script:Supervised) {
'@ @'
        if ($script:Browser -and $script:Supervised) {
'@

    # --- start-up: no password to import ---------------------------------------------
    Set-Text '    if (-not $ShowConsole -and -not $SetPassword) { $consoleState = Hide-ConsoleWindow }' '    if (-not $ShowConsole) { $consoleState = Hide-ConsoleWindow }'
    Set-Text @'
        if ($SetPassword) {
            Write-Host "Config: $($_.Exception.Message)" -ForegroundColor Yellow
            return (Invoke-SetPassword -Config $null)
        }
'@ ''
    Set-Text @'
    if ($SetPassword) { return (Invoke-SetPassword -Config $config) }

'@ ''
    Set-Text @'
    if ($config.LegacyPassword) { Write-Log 'The config holds a plain-text Password. It still works, but remove it once the encrypted file exists.' 'WARN' }
'@ ''
    Set-Between -From '        [void](Import-PasswordSeed -Config $config)' -To '        $script:EdgePath = Find-EdgePath' -With ''
    Set-Text @'
                        $script:Status.UserName = $config.UserName
                        Clear-LoginBlock -Why 'the config changed'
'@ ''
    Set-Between -From '                # A new password: try signing in again straight away.' -To '                $control = @(Invoke-ControlFiles' -With ''
    Set-Text "Write-Log (`"Config {0} (version {1}); report {2}`"" "Write-Log (`"Config {0} (version {1}); page {2} (TargetMatch {3})`""
    Set-Text "`$(if (`$config.JsonVersion) { `$config.JsonVersion } else { '-' }), `$config.DisplayUrl)" "`$(if (`$config.JsonVersion) { `$config.JsonVersion } else { '-' }), `$config.DisplayUrl, `$config.TargetMatch)"
    Set-Text 'no automatic sign-in, full screen, health checks or interval refresh' 'no health checks or interval refresh'
    Set-Text '(no sign-in, full screen, health checks or interval refresh)' '(no health checks or interval refresh)'

    # --- no password here: its section header and constants go -----------------------
    Set-Between -From '# Sign-in password (DPAPI, current Windows account)' -To '# Screens' -With ''

    # --- names ---------------------------------------------------------------------
    $script:t = $script:t.Replace('PbiLauncher', 'WebLauncher').Replace('PBI Launcher', 'Web Launcher')
    $script:t = $script:t.Replace('the report', 'the page').Replace('The report', 'The page')
    return $script:t
}
