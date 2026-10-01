#Requires -Version 5.1
<#
.SYNOPSIS
    A stand-in for a Mach2 (Niagara 4) station, for testing Mach2 Launcher
    ver 1.00NG without one.

.DESCRIPTION
    Plain HTTP on 127.0.0.1, like the stations (http://shcz5plc02:302).
    The pages use what the real ones use: /prelogin with j_username and
    #login-submit in #main-login-form, a password page with j_password,
    /j_security_check, ?auth=fail with #login-failed, a session cookie, a
    redirect to /login when the session is gone, and /deltav/home after
    sign-in. The dashboard lives under /deltav/dashboard:viewer/...

    Every request of interest is appended to -EventsFile as a JSON line.

    /control?key=value changes behaviour:
      white=1       the dashboard loads but draws nothing (a white screen)
      dark=1        the dashboard draws black
      error=1       the station answers the dashboard with HTTP ERROR 500
      home=1        after sign-in the station opens /deltav/home, not the
                    page that was asked for
      singlepage=1  /login asks for user name and password on one page
      logout=1      every existing session is invalid from now on; an open
                    dashboard notices within two seconds and goes to /login
      delay=ms      how long the dashboard takes to draw
      slowlogin=ms  how long the station takes to answer the password, as a
                    slow link makes it
      blockms=ms    the page after sign-in blocks its own thread this long,
                    which is what makes a slow kiosk's page unreadable: the
                    launcher's DevTools calls get no answer until it ends
      reset=1       all of the above back to defaults
#>
param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$EventsFile,
    [Parameter(Mandatory)][string]$PasswordFile,
    [string]$UserName = 'operator'
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web
# From a file, so a password with quotes or non-ASCII characters arrives
# intact rather than through the command line.
$Password = [IO.File]::ReadAllText($PasswordFile)
$state = @{}
function Reset-State {
    $script:state.white = $false; $script:state.dark = $false; $script:state.error = $false; $script:state.home = $false
    $script:state.singlepage = $false; $script:state.delay = 300
    $script:state.slowlogin = 0; $script:state.blockms = 0
    if (-not $script:state.ContainsKey('gen')) { $script:state.gen = 1 }
    $script:state.ru = ''
}
Reset-State

function Add-Event {
    param([string]$Name, [hashtable]$Data = @{})
    $o = [ordered]@{ t = [DateTime]::UtcNow.ToString('o'); name = $Name }
    foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] }
    [IO.File]::AppendAllText($EventsFile, (ConvertTo-Json -InputObject $o -Compress) + "`n")
}

function ConvertFrom-Query {
    param([string]$Text)
    $h = @{}
    if (-not $Text) { return $h }
    $q = [Web.HttpUtility]::ParseQueryString($Text)
    foreach ($k in $q.AllKeys) { if ($k) { $h[$k] = $q[$k] } }
    return $h
}

function Page {
    param([string]$Title, [string]$Body, [string]$BodyStyle = '')
    return @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>$Title</title>
<style>
html, body { margin: 0; height: 100%; font-family: Segoe UI, sans-serif }
body { background: #ffffff; $BodyStyle }
#outer-login-form-container { margin: 60px auto; width: 420px }
.login-input, input[type=password] { display: block; width: 300px; height: 28px; margin: 8px 0 }
#login-failed { display: none; color: #b00 }
.bar { height: 10vh; background: #263238; color: #fff; font-size: 3vh; line-height: 10vh; padding-left: 20px }
.panel { position: absolute; width: 45vw; height: 38vh }
</style></head><body onload="if (window.checkFail) checkFail()">$Body</body></html>
"@
}

function Get-LoginPage {
    param([string]$Action = '/login', [switch]$WithPassword, [bool]$Failed)
    $pw = if ($WithPassword) { '<input type="password" name="j_password" id="password">' } else { '' }
    $failStyle = if ($Failed) { ' style="display: block"' } else { '' }
    return (Page 'Login' @"
<script>function checkFail() { if (/[?&]auth=fail/.test(location.search)) document.getElementById('login-failed').setAttribute('style', 'display: block'); }</script>
<div id="outer-login-form-container"><div id="login-title">ShapeCzech_Mach2_fixture</div>
<div id="login-failed"$failStyle>Login Failed</div>
<form id="main-login-form" method="POST" action="$Action">
<label class="login-label">Username:</label>
<input class="login-input" type="text" name="j_username" autofocus autocomplete="on">
$pw
<input id="login-submit" type="submit" value="Login">
</form></div>
"@)
}

$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'), $Port)
$listener.Start()
Add-Event 'server-started' @{ port = $Port }

$stop = $false
while (-not $stop) {
    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 15; continue }
    $client = $listener.AcceptTcpClient()
    try {
        $client.ReceiveTimeout = 1500
        $client.SendTimeout = 3000
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
        $requestLine = $reader.ReadLine()
        if (-not $requestLine) { continue }
        $cookie = ''
        $length = 0
        while ($true) {
            $h = $reader.ReadLine()
            if ($null -eq $h -or $h -eq '') { break }
            if ($h -match '^Cookie:\s*(.*)$') { $cookie = $Matches[1] }
            if ($h -match '^Content-Length:\s*(\d+)') { $length = [int]$Matches[1] }
        }
        $body = ''
        if ($length -gt 0) {
            $buf = New-Object char[] $length
            $read = 0
            while ($read -lt $length) { $n = $reader.Read($buf, $read, $length - $read); if ($n -le 0) { break }; $read += $n }
            $body = New-Object string($buf, 0, $read)
        }
        $parts = $requestLine.Split(' ')
        $method = $parts[0]
        $target = $parts[1]
        $path = [Uri]::UnescapeDataString(($target -split '\?')[0])
        $q = ConvertFrom-Query $(if ($target.Contains('?')) { $target.Substring($target.IndexOf('?') + 1) } else { '' })
        $form = ConvertFrom-Query $body
        $authed = $cookie -match ('(?:^|;\s*)niagara_session=' + $state.gen + '(?:;|$)')

        $status = '200 OK'
        $headers = @('Content-Type: text/html; charset=utf-8', 'Cache-Control: no-store')
        $out = ''

        if ($path -like '/deltav/dashboard:viewer/*') {
            if (-not $authed) {
                Add-Event 'dashboard-redirect'
                $state.ru = $target
                $status = '302 Found'
                $headers += 'Location: /login'
            }
            elseif ($state.error) {
                Add-Event 'dashboard' @{ error = $true }
                $status = '500 Server Error'
                $out = Page 'Error 500 Server Error' "<h2>HTTP ERROR 500 Server Error</h2><p>Problem accessing $path. Reason:</p><pre>    Server Error</pre>"
            }
            else {
                Add-Event 'dashboard' @{ white = $state.white; dark = $state.dark }
                $panels = @(
                    '<div class="panel" style="left:2vw;top:12vh;background:#2e7d32"></div>',
                    '<div class="panel" style="left:52vw;top:12vh;background:#1565c0"></div>',
                    '<div class="panel" style="left:2vw;top:55vh;background:#f9a825"></div>',
                    '<div class="panel" style="left:52vw;top:55vh;background:#6a1b9a"></div>'
                ) -join ''
                $draw = if ($state.white) { '' } else { "setTimeout(function () { document.getElementById('dash').innerHTML = '$panels'; }, $($state.delay));" }
                # Blocks the page's own thread, so DevTools gets no answer
                # either - a slow kiosk, not a dead browser.
                if ($state.blockms -gt 0) { $draw = ("var __end = Date.now() + $($state.blockms); while (Date.now() < __end) { } " + $draw) }
                $bodyStyle = if ($state.dark) { 'background: #000000' } else { '' }
                $bar = if ($state.white -or $state.dark) { '' } else { '<div class="bar">LASER TEST - Graphs</div>' }
                # The page notices a lost session itself, as the station's
                # web client does, and goes to the sign-in.
                $out = Page 'Graphs' @"
$bar<div id="dash"></div>
<script>
$draw
setInterval(function () { fetch('/deltav/ping', { credentials: 'same-origin' }).then(function (r) { if (r.status === 401) location.href = '/login'; }); }, 2000);
</script>
"@ $bodyStyle
            }
        }
        else {
            switch ($path) {
                '/deltav/ping' {
                    $headers = @('Content-Type: text/plain', 'Cache-Control: no-store')
                    if ($authed) { $out = 'ok' } else { $status = '401 Unauthorized'; $out = 'no session' }
                }
                '/deltav/home' {
                    if (-not $authed) { $status = '302 Found'; $headers += 'Location: /login'; break }
                    Add-Event 'home'
                    $out = Page 'Home' '<div class="bar">Mach2 home</div><p><a href="/deltav/area/">Areas</a></p>'
                }
                '/prelogin' {
                    Add-Event 'prelogin-page' @{ clear = $q.ContainsKey('clear') }
                    $out = Get-LoginPage -Action '/login' -Failed ($q['auth'] -eq 'fail')
                }
                '/login' {
                    if ($method -eq 'POST') {
                        # Niagara's second step: the password for this user.
                        Add-Event 'user' @{ user = $form['j_username'] }
                        $u = [Web.HttpUtility]::HtmlEncode([string]$form['j_username'])
                        $out = Page 'Login' @"
<div id="outer-login-form-container"><div id="login-failed">Login Failed</div>
<form id="login-form" method="POST" action="/j_security_check">
<div class="login-group">User: <span id="login-user">$u</span></div>
<input type="hidden" name="j_username" value="$u">
<input type="password" name="j_password" id="password">
<input id="login-submit" type="submit" value="Login">
</form></div>
"@
                        break
                    }
                    Add-Event 'login-page' @{ single = $state.singlepage; failed = ($q['auth'] -eq 'fail') }
                    $out = if ($state.singlepage) { Get-LoginPage -Action '/j_security_check' -WithPassword -Failed ($q['auth'] -eq 'fail') }
                    else { Get-LoginPage -Action '/login' -Failed ($q['auth'] -eq 'fail') }
                }
                '/j_security_check' {
                    if ($state.slowlogin -gt 0) { Start-Sleep -Milliseconds $state.slowlogin }
                    $ok = ([string]$form['j_password'] -ceq $Password) -and ([string]$form['j_username'] -eq $UserName)
                    Add-Event 'password' @{ ok = $ok; user = $form['j_username']; length = ([string]$form['j_password']).Length }
                    $status = '302 Found'
                    if (-not $ok) { $headers += 'Location: /login?auth=fail' }
                    else {
                        $headers += ('Set-Cookie: niagara_session=' + $state.gen + '; Path=/; HttpOnly')
                        $next = if (-not $state.home -and $state.ru) { $state.ru } else { '/deltav/home' }
                        $headers += "Location: $next"
                    }
                }
                '/event' {
                    $data = @{}
                    foreach ($k in $q.Keys) { if ($k -ne 'name') { $data[$k] = $q[$k] } }
                    Add-Event $q['name'] $data
                    $headers = @('Content-Type: text/plain'); $out = 'ok'
                }
                '/control' {
                    if ($q.ContainsKey('reset')) { Reset-State }
                    foreach ($k in $q.Keys) {
                        switch ($k) {
                            'reset' { }
                            'logout' { $state.gen++ }
                            'delay' { $state.delay = [int]$q[$k] }
                            'slowlogin' { $state.slowlogin = [int]$q[$k] }
                            'blockms' { $state.blockms = [int]$q[$k] }
                            default { $state[$k] = ($q[$k] -eq '1') }
                        }
                    }
                    Add-Event 'control' @{ query = $target }
                    $headers = @('Content-Type: text/plain'); $out = 'ok'
                }
                '/stop' { $headers = @('Content-Type: text/plain'); $out = 'bye' }
                default {
                    if ($path -like '/ord/*') { $out = Page 'Station' '<p>station:|slot:/</p>'; break }
                    $status = '404 Not Found'; $headers = @('Content-Type: text/plain'); $out = 'not found'
                }
            }
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes($out)
        $head = "HTTP/1.1 $status`r`n" + (($headers + "Content-Length: $($bytes.Length)", 'Connection: close') -join "`r`n") + "`r`n`r`n"
        $hb = [Text.Encoding]::ASCII.GetBytes($head)
        $stream.Write($hb, 0, $hb.Length)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        if ($path -eq '/stop') { $stop = $true }
    }
    catch {
        # A speculative connection that never sent a request, or a client
        # that went away. Neither matters here.
    }
    finally { $client.Close() }
}
$listener.Stop()
