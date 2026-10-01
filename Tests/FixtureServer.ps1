#Requires -Version 5.1
<#
.SYNOPSIS
    A stand-in for Microsoft sign-in and a Power BI report, for testing the
    launcher without a tenant.

.DESCRIPTION
    Plain HTTP. The report is on 127.0.0.1 and the sign-in pages on
    127.0.0.2 - two hosts, as with app.powerbi.com and
    login.microsoftonline.com. Pages use the element IDs and names the real
    pages use (loginfmt, passwd, idSIButton9, idBtn_Back, KmsiCheckboxField,
    tilesHolder, exploration-container-app-bars, visual-container), so the
    launcher's selectors are exercised as they are.

    Every request of interest is appended to -EventsFile as a JSON line.

    /control?key=value changes behaviour:
      error=1     report shows "Something went wrong" and no visuals
      blank=1     report draws nothing
      picker=1    sign-in starts with an account picker
      mfa=1       the password is followed by an MFA prompt
      logout=1    every existing session is invalid from now on
      sso=1       signing in starts on Power BI's own e-mail page
      wrong=once  the next report is signed in as another account
                  (as Windows single sign-on does); wrong=always: every one
      delay=ms    how long the report takes to draw
      refuse=nolicense / refuse=429
                  a signed-in report is refused, as Power BI does: sent to
                  sign up for a license, or to its error page with code 429
      siteerror=1 /site shows "HTTP ERROR 500" (Web Launcher tests)
      siteblank=1 /site shows nothing
      reset=1     all of the above back to defaults
#>
param(
    [Parameter(Mandatory)][int]$Port,
    [Parameter(Mandatory)][string]$EventsFile,
    [Parameter(Mandatory)][string]$PasswordFile,
    [string]$UserName = 'pbi.kiosk@contoso.test'
)

$ErrorActionPreference = 'Stop'
# From a file, so a password with quotes or non-ASCII characters arrives
# intact rather than through the command line.
$Password = [IO.File]::ReadAllText($PasswordFile)
$state = @{ error = $false; blank = $false; picker = $false; mfa = $false; sso = $false; gen = 1; delay = 400; wrong = 'no'; refuse = 'no'; siteerror = $false; siteblank = $false }

function Add-Event {
    param([string]$Name, [hashtable]$Data = @{})
    $o = [ordered]@{ t = [DateTime]::UtcNow.ToString('o'); name = $Name }
    foreach ($k in $Data.Keys) { $o[$k] = $Data[$k] }
    [IO.File]::AppendAllText($EventsFile, (ConvertTo-Json -InputObject $o -Compress) + "`n")
}

function Get-Query {
    param([string]$Target)
    $i = $Target.IndexOf('?')
    if ($i -lt 0) { return @{} }
    $q = [Web.HttpUtility]::ParseQueryString($Target.Substring($i + 1))
    $h = @{}
    foreach ($k in $q.AllKeys) { if ($k) { $h[$k] = $q[$k] } }
    return $h
}

function Page {
    param([string]$Title, [string]$Body)
    return @"
<!DOCTYPE html><html><head><meta charset="utf-8"><title>$Title</title>
<style>
body { font-family: Segoe UI, sans-serif; margin: 0 }
#exploration-container-app-bars { height: 40px; background: #eee; display: flex; align-items: center }
#exploration-container-app-bars button { margin: 0 6px }
.menu { display: none; position: absolute; top: 44px; left: 120px; background: #fff; border: 1px solid #999; padding: 4px }
.menu.open { display: block }
.menu button { display: block; width: 140px; margin: 2px 0 }
visual-container { display: inline-block; width: 220px; height: 140px; margin: 12px; background: #cde }
exploration-container { display: block; min-height: 420px }
.moveOffScreen { position: fixed; bottom: 0; left: 0; width: 1px; height: 1px; opacity: 0.01 }
.links { margin: 12px; font-size: 20px }
.links a, .links button { margin: 0 8px; font-size: 20px }
.box { margin: 40px; width: 420px }
input { display: block; width: 300px; margin: 8px 0; height: 28px }
.table { border: 1px solid #aaa; padding: 10px; margin: 6px 0; width: 300px; cursor: pointer }
</style></head><body>$Body</body></html>
"@
}

Add-Type -AssemblyName System.Web
$ReportBase = "http://127.0.0.1:$Port"
$LoginBase = "http://127.0.0.2:$Port"
$listeners = @(
    (New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.1'), $Port)),
    (New-Object Net.Sockets.TcpListener([Net.IPAddress]::Parse('127.0.0.2'), $Port))
)
foreach ($l in $listeners) { $l.Start() }
Add-Event 'server-started' @{ port = $Port }

$stop = $false
while (-not $stop) {
    $client = $null
    foreach ($l in $listeners) { if ($l.Pending()) { $client = $l.AcceptTcpClient(); break } }
    if (-not $client) { Start-Sleep -Milliseconds 15; continue }
    try {
        $client.ReceiveTimeout = 1500
        $client.SendTimeout = 3000
        $stream = $client.GetStream()
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
        $requestLine = $reader.ReadLine()
        if (-not $requestLine) { continue }
        $cookie = ''
        while ($true) {
            $h = $reader.ReadLine()
            if ($null -eq $h -or $h -eq '') { break }
            if ($h -match '^Cookie:\s*(.*)$') { $cookie = $Matches[1] }
        }
        $parts = $requestLine.Split(' ')
        $target = $parts[1]
        $path = ($target -split '\?')[0]
        $q = Get-Query $target
        $authed = $cookie -match ('(?:^|;\s*)auth=' + $state.gen + '(?:;|$)')

        $status = '200 OK'
        $headers = @('Content-Type: text/html; charset=utf-8', 'Cache-Control: no-store')
        $body = ''

        switch ($path) {
            '/report' {
                if (-not $authed) {
                    Add-Event 'report-redirect'
                    # Back to exactly this address after sign-in, as Power BI does.
                    $state.ru = $target
                    $status = '302 Found'
                    $headers += $(if ($state.sso) { "Location: $ReportBase/singleSignOn" } else { "Location: $LoginBase/login" })
                    break
                }
                if ($state.refuse -ne 'no') {
                    Add-Event 'refused' @{ how = $state.refuse }
                    $status = '302 Found'
                    $headers += $(if ($state.refuse -eq '429') { 'Location: /ErrorPage?code=429&errorType=AppMetadataInaccessible&raid=x' }
                                  else { 'Location: /signup?sku=x&ru=' + [Uri]::EscapeDataString("$ReportBase$target&pbi_source=web_nolicense_redirect") })
                    break
                }
                $chromeless = $q['chromeless'] -eq 'true'
                # The account the page is signed in as, where MSAL keeps it.
                $account = $UserName
                if ($state.wrong -ne 'no') {
                    $account = 'kiosk.windows@contoso.test'
                    if ($state.wrong -eq 'once') { $state.wrong = 'no' }
                }
                Add-Event 'report' @{ error = $state.error; blank = $state.blank; chromeless = $chromeless; account = $account }
                # Power BI's spinner stays up until the visuals are drawn.
                $canvas = if ($state.error) {
                    "<div class=`"error`"><h2>Something went wrong</h2><p>Try again later.</p></div><script>document.getElementById('pbi-svg-loading').style.display='none';</script>"
                }
                elseif ($state.blank) { '' }
                else {
                    "<script>setTimeout(function(){ var c=document.getElementById('canvas'); for (var i=0;i<3;i++){ c.appendChild(document.createElement('visual-container')); } document.getElementById('pbi-svg-loading').style.display='none'; }, $($state.delay));</script>"
                }
                # chromeless=true: no header, so no View menu - as in Power BI.
                $appBar = if ($chromeless) { '' } else {
                    @'
<div id="exploration-container-app-bars"><app-bar><div><div></div><div>
<button>File</button><button>Export</button><button id="viewBtn" aria-label="View">View</button>
</div></div></app-bar></div>
'@
                }
                $body = Page 'Fixture report' @"
$appBar
<div class="cdk-overlay-container"><div class="menu" role="menu" id="menu">
<button role="menuitem">Fit to page</button><button role="menuitem" id="fs">Full screen</button>
</div></div>
<div id="appnav"><button id="hideNav">Hide Navigation</button><span id="pagelist"> Pages: Overview | Detail</span></div>
<div id="pbi-svg-loading">Loading report...</div>
<script>localStorage.setItem('fixture-msal-account', JSON.stringify({ homeAccountId: 'x', environment: 'login.windows.net', username: '$account' }));</script>
<div class="links">
<a id="sameLink" href="/linked?kind=same">Same-window link</a> |
<a id="newLink" href="/linked?kind=new" target="_blank" rel="noopener noreferrer">New-window link</a> |
<button id="openBtn" onclick="window.open('/linked?kind=open')">Web URL button</button>
</div>
<exploration-container id="canvas"></exploration-container>
$canvas
<script>
var viewBtn = document.getElementById('viewBtn');
if (viewBtn) viewBtn.addEventListener('click', function (e) {
  fetch('/event?name=view&trusted=' + e.isTrusted);
  document.getElementById('menu').classList.add('open');
});
document.getElementById('fs').addEventListener('click', function (e) {
  fetch('/event?name=fullscreen&trusted=' + e.isTrusted);
  document.getElementById('menu').classList.remove('open');
  document.getElementById('exploration-container-app-bars').style.display = 'none';
  document.getElementById('appnav').style.display = 'none';
});
document.getElementById('hideNav').addEventListener('click', function (e) {
  fetch('/event?name=hidenav&trusted=' + e.isTrusted);
  document.getElementById('pagelist').style.display = 'none';
  e.target.textContent = 'Show Navigation';
});
</script>
"@
            }
            { $_ -eq '/site' -or $_ -like '/site/*' } {
                # A plain web page for Web Launcher: no sign-in, a link within
                # the site and one out of it.
                Add-Event 'site' @{ path = $path; error = $state.siteerror; blank = $state.siteblank }
                $body = if ($state.siteblank) { Page 'Board' '' }
                elseif ($state.siteerror) { Page 'Board' '<div class="box"><h1>HTTP ERROR 500</h1></div>' }
                else {
                    Page 'Board' @'
<div class="box"><h1>Shift board</h1><p>Line 1: running. Line 2: changeover.</p>
<a id="inLink" href="/site/page2">Page 2</a> | <a id="outLink" href="/linked?kind=out">Elsewhere</a></div>
'@
                }
            }
            { $_ -in @('/signup', '/ErrorPage') } {
                $body = Page 'Power BI' '<div class="box"><h1>You need a Power BI license</h1></div>'
            }
            '/linked' {
                Add-Event 'linked' @{ kind = $q['kind'] }
                # Error text on purpose: someone else's page is not the
                # launcher's to reload.
                $body = Page 'Linked page' @"
<div class="box" style="height: 1600px"><h1>Linked page ($($q['kind']))</h1>
<p>Something went wrong - this is someone else's page.</p>
<a id="deeper" href="/linked?kind=deeper">Deeper</a></div>
"@
            }
            '/singleSignOn' {
                # Power BI's own page: the e-mail goes to Microsoft as a hint,
                # so the next page asks straight for that account's password.
                Add-Event 'pbi-sso-page'
                $body = Page 'Sign in | Microsoft Power BI' @"
<div class="box"><div>Enter your work or school email, we'll check if you need to create a new account.</div>
<input type="text" id="email">
<button type="submit" id="submitBtn" onclick="fetch('/event?name=pbi-sso&email=' + encodeURIComponent(document.getElementById('email').value)).then(function () { location.href = '$LoginBase/password?u=' + encodeURIComponent(document.getElementById('email').value); })">Submit</button>
</div>
"@
            }
            '/login' {
                if ($q.ContainsKey('other')) { $state.picker = $false }
                Add-Event 'login-page' @{ picker = $state.picker }
                if ($state.picker) {
                    $body = Page 'Sign in' @"
<div class="box"><div>Pick an account</div><div id="tilesHolder">
<div class="table" role="button" data-test-id="someone.else@contoso.test" onclick="location.href='/password?u=someone.else%40contoso.test'">someone.else@contoso.test</div>
<div class="table" role="button" data-test-id="$UserName" onclick="location.href='/password?u=' + encodeURIComponent('$UserName')">$UserName</div>
<div class="table" role="button" id="otherTile" data-test-id="otherTile" onclick="location.href='/login?other=1'">Use another account</div>
</div></div>
"@
                    break
                }
                $body = Page 'Sign in' @"
<div class="box"><div>Sign in</div>
<input type="email" name="loginfmt" id="i0116" placeholder="Email">
<input type="submit" id="idSIButton9" value="Next" onclick="location.href='/password?u=' + encodeURIComponent(document.getElementById('i0116').value) + (document.getElementById('decoy1').value || document.getElementById('decoy2').value ? '&decoy=1' : '')">
</div>
<!-- Decoy password fields, as Microsoft keeps for password managers. -->
<input type="password" name="passwd" id="decoy1" class="moveOffScreen" tabindex="-1" aria-hidden="true">
<div style="position:absolute; left:-10000px; top:0"><input type="password" id="decoy2" style="width:200px; height:30px"></div>
"@
            }
            '/password' {
                if ($q.ContainsKey('decoy')) { Add-Event 'decoy-filled' }
                Add-Event 'user' @{ user = $q['u'] }
                $err = if ($q.ContainsKey('bad')) { '<div id="passwordError">Your account or password is incorrect.</div>' } else { '' }
                $body = Page 'Enter password' @"
<div class="box"><div id="displayName">$($q['u'])</div>$err
<input type="password" name="passwd" id="i0118" placeholder="Password">
<input type="submit" id="idSIButton9" value="Sign in" onclick="location.href='/checkpw?u=' + encodeURIComponent('$($q['u'])') + '&p=' + encodeURIComponent(document.getElementById('i0118').value)">
</div>
"@
            }
            '/checkpw' {
                $ok = ($q['p'] -ceq $Password) -and ($q['u'] -eq $UserName)
                Add-Event 'password' @{ ok = $ok; user = $q['u']; length = ([string]$q['p']).Length }
                $status = '302 Found'
                if (-not $ok) { $headers += ('Location: /password?bad=1&u=' + [Uri]::EscapeDataString($q['u'])) }
                elseif ($state.mfa) { $headers += 'Location: /mfa' }
                else { $headers += 'Location: /kmsi' }
            }
            '/mfa' {
                Add-Event 'mfa-page'
                $body = Page 'Approve sign in request' '<div class="box"><div id="idDiv_SAOTCAS_Title">Approve sign in request</div></div>'
            }
            '/kmsi' {
                Add-Event 'kmsi-page'
                $body = Page 'Stay signed in' @"
<div class="box"><div id="KmsiDescription">Stay signed in?</div>
<input type="checkbox" id="KmsiCheckboxField"> Don't show this again
<input type="button" id="idBtn_Back" value="No" onclick="location.href='/kmsidone?v=no'">
<input type="submit" id="idSIButton9" value="Yes" onclick="location.href='/kmsidone?v=yes'">
</div>
"@
            }
            '/kmsidone' {
                Add-Event 'kmsi' @{ answer = $q['v'] }
                $status = '302 Found'
                $headers += "Location: $ReportBase/setauth"
            }
            '/setauth' {
                $status = '302 Found'
                # Persistent, like Microsoft's after "Stay signed in".
                $headers += ('Set-Cookie: auth=' + $state.gen + '; Path=/; Max-Age=86400')
                $headers += ('Location: ' + $(if ($state.ContainsKey('ru') -and $state.ru) { $state.ru } else { '/report' }))
            }
            '/event' {
                $data = @{}
                foreach ($k in $q.Keys) { if ($k -ne 'name') { $data[$k] = $q[$k] } }
                Add-Event $q['name'] $data
                $headers = @('Content-Type: text/plain')
                $body = 'ok'
            }
            '/control' {
                # reset first, whatever order the query has.
                if ($q.ContainsKey('reset')) { $state.error = $false; $state.blank = $false; $state.picker = $false; $state.mfa = $false; $state.sso = $false; $state.delay = 400; $state.wrong = 'no'; $state.refuse = 'no'; $state.siteerror = $false; $state.siteblank = $false }
                foreach ($k in $q.Keys) {
                    switch ($k) {
                        'reset' { }
                        'logout' { $state.gen++ }
                        'delay' { $state.delay = [int]$q[$k] }
                        'wrong' { $state.wrong = $q[$k] }
                        'refuse' { $state.refuse = $q[$k] }
                        default { $state[$k] = ($q[$k] -eq '1') }
                    }
                }
                Add-Event 'control' @{ query = $target }
                $headers = @('Content-Type: text/plain')
                $body = 'ok'
            }
            '/stop' {
                $headers = @('Content-Type: text/plain')
                $body = 'bye'
            }
            default {
                $status = '404 Not Found'
                $headers = @('Content-Type: text/plain')
                $body = 'not found'
            }
        }

        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
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
foreach ($l in $listeners) { $l.Stop() }
