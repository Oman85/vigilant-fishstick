#Requires -Version 5.1
<#
.SYNOPSIS
    Kiosk Fleet Web: the fleet dashboard and manager as a web server on the
    intranet, with separate rights for admins and operators.

.DESCRIPTION
    The Kiosk Fleet Manager window (Show-FleetManager.ps1) in a browser, so
    nobody needs the folder, PowerShell or the kiosk-admin credential on
    their own PC. It reads the same single file the Power BI report reads -
    MWST_FleetEvents.csv and the collector's status file next to it - and
    does the same things to a kiosk, over its admin share, as the window.

    It runs as one service account: the account that holds the saved
    kiosk-admin credential (Config\kiosk-admin.cred.xml, DPAPI, so it opens
    only for the account that saved it). People who use the page never see
    that credential. They sign in as themselves:

      Windows   their own domain account (Kerberos/NTLM; on a domain PC in
                the intranet zone there is no prompt at all). The role
                comes from AD groups: -AdminGroup and -OperatorGroup.
      Local     an account in Config\web-users.json (Set-FleetWebUser.ps1),
                for when AD is not there. Passwords are PBKDF2 hashes.

    Operators see everything and can do what cannot break a kiosk: scan
    now, read live, screenshot, reload, restart the browser, a message on
    the screen, the launcher log. Admins can also restart a kiosk,
    hold/resume, stop the launcher, set the sign-in password, edit the
    kiosk config, deploy and roll back, run auto-scan, stop a run, and read
    the audit log. Everything anyone does to a kiosk is written to
    Logs\web-audit.log with who did it.

    Install-FleetWeb.ps1 sets it up as a scheduled task that starts with
    the PC. Docs\Fleet-Web.md has the whole story.

.PARAMETER Prefix
    Where to listen, as HttpListener prefixes. Default http://+:8080/ (every
    address, port 8080). https://+:8443/ once a certificate is bound to the
    port (Install-FleetWeb.ps1 -CertificateThumbprint).

.PARAMETER AllowHttp
    Plain HTTP on the network. Without it only https:// prefixes and
    http://localhost are accepted. With Windows sign-in no password crosses
    the wire, but a local account's password and every page do, unencrypted.

.PARAMETER AdminGroup
    The AD group whose members are admins. DOMAIN\Group is safest.

.PARAMETER OperatorGroup
    The AD group whose members are operators.

.PARAMETER NoWindowsAuth
    Local accounts only.

.PARAMETER NoLocalAccounts
    Windows sign-in only; Config\web-users.json is ignored.

.PARAMETER IdleMinutes
    Sign out after this long without the page open. Default 30.

.PARAMETER SessionHours
    Sign out after this long whatever happens. Default 10.

.EXAMPLE
    .\Start-FleetWeb.ps1 -AllowHttp -AdminGroup 'CONTOSO\KioskFleet-Admins' -OperatorGroup 'CONTOSO\KioskFleet-Operators'

.EXAMPLE
    .\Start-FleetWeb.ps1 -Prefix 'https://+:8443/' -AdminGroup 'CONTOSO\KioskFleet-Admins' -OperatorGroup 'CONTOSO\KioskFleet-Operators'
#>

[CmdletBinding()]
param(
    [string[]]$Prefix = @('http://+:8080/'),
    [switch]$AllowHttp,
    [string]$AdminGroup = 'KioskFleet-Admins',
    [string]$OperatorGroup = 'KioskFleet-Operators',
    [switch]$NoWindowsAuth,
    [switch]$NoLocalAccounts,
    [string]$UsersFile,
    [ValidateRange(5, 1440)][int]$IdleMinutes = 30,
    [ValidateRange(1, 24)][int]$SessionHours = 10,
    [string]$CsvPath,
    [ValidateRange(1, 3600)][int]$RefreshSeconds = 5,
    [ValidateRange(1, 10080)][int]$StaleMinutes = 45,
    [ValidateRange(1, 1440)][int]$AutoScanMinutes = 15,
    [switch]$AutoScan,
    [string]$CredentialFile,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$SccmSiteServer,
    [string]$RestartMessage = "IT is restarting this kiosk remotely. Please do not switch it off - it will come back on its own.",
    [ValidateRange(0, 3600)][int]$RestartWarningSeconds = 60,
    # For the tests: a local folder standing in for each kiosk's C: drive,
    # and a stand-in for the collector.
    [string]$RootTemplate = '\\{0}\C$',
    [string]$CollectorPath,
    [string]$LogDir
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$WebVersion = '1.00'

# Windows PowerShell 5.1 writes an array inside an object as
# {"value":[...],"Count":n} when the array carries type data; without it the
# browser gets the plain array it expects.
if ($PSVersionTable.PSVersion.Major -lt 6) { Remove-TypeData System.Array -ErrorAction SilentlyContinue }

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$LibNames = @('MWST.Remote', 'MWST.KioskList', 'MWST.Message', 'PBI.Launcher', 'M2.LauncherNG', 'MWST.FleetState', 'Fleet.Actions')
foreach ($lib in $LibNames) { . (Join-Path $ScriptDir "Lib\$lib.ps1") }
. (Join-Path $ScriptDir 'Lib\Fleet.WebAuth.ps1')

$OnWindows = ($PSVersionTable.PSEdition -eq 'Desktop') -or $IsWindows
if (-not $CredentialFile) { $CredentialFile = Join-Path $ScriptDir 'Config\kiosk-admin.cred.xml' }
if (-not $UsersFile) { $UsersFile = Join-Path $ScriptDir 'Config\web-users.json' }
if (-not $CollectorPath) { $CollectorPath = Join-Path $ScriptDir 'Collect-MWSTFleet.ps1' }

if (-not $LogDir) { $LogDir = Join-Path $ScriptDir 'Logs' }
$RunDir           = Join-Path $LogDir 'run'
$SnapshotDir      = Join-Path $LogDir 'snapshots'
$WebDir           = Join-Path $ScriptDir 'Web'
$AuditPath        = Join-Path $LogDir 'web-audit.log'
$ServerLogPath    = Join-Path $LogDir 'fleet-web.log'
$ScanProgressPath = Join-Path $LogDir 'autoscan.progress.json'
foreach ($d in @($LogDir, $RunDir, $SnapshotDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

$PowerShellExe = Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $PowerShellExe)) { $PowerShellExe = (Get-Process -Id $PID).Path }

# ---------------------------------------------------------------------------
# What is allowed to listen where
# ---------------------------------------------------------------------------
$WindowsAuth = (-not $NoWindowsAuth) -and $OnWindows
$LocalAuth = (-not $NoLocalAccounts)
if (-not $WindowsAuth -and -not $LocalAuth) { throw 'Nobody could sign in: -NoLocalAccounts needs Windows sign-in, which needs Windows.' }

$Https = $false
foreach ($p in $Prefix) {
    if ($p -notmatch '^(https?)://([^/]+)/$') { throw "A prefix looks like http://+:8080/ or https://+:8443/ - not '$p'." }
    $scheme = $Matches[1]
    $authority = $Matches[2]
    $hostPart = ($authority -replace ':\d+$', '')
    if ($scheme -eq 'https') { $Https = $true; continue }
    $loopback = ($hostPart -in @('localhost', '127.0.0.1', '[::1]'))
    if (-not $loopback -and -not $AllowHttp) {
        throw ("'{0}' is plain HTTP on the network. Use https:// with a certificate (Install-FleetWeb.ps1 -CertificateThumbprint), or say -AllowHttp to accept it unencrypted." -f $p)
    }
}

# ---------------------------------------------------------------------------
# Logs: the server's own, and the audit trail of who did what
# ---------------------------------------------------------------------------
$script:LogLock = New-Object object
function Write-WebLog {
    param([string]$Text, $Problem)
    $line = '{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Text
    if ($Problem) {
        $ex = $(if ($Problem -is [System.Management.Automation.ErrorRecord]) { $Problem.Exception } else { $Problem })
        $line += "`r`n  {0}: {1}" -f $ex.GetType().FullName, $ex.Message
        if ($Problem -is [System.Management.Automation.ErrorRecord] -and $Problem.ScriptStackTrace) { $line += "`r`n  " + ($Problem.ScriptStackTrace -replace "\r?\n", "`r`n  ") }
    }
    try { [IO.File]::AppendAllText($ServerLogPath, $line + "`r`n") } catch { }
    Write-Host $line
}

function Write-FleetAudit {
    <#
        One JSON line per thing done, or refused, with who and from where.
        Never a password: only what was done and to what.
    #>
    param($Session, [string]$Ip, [string]$Action, [string]$Target = '', [string]$Result = '', [string]$Detail = '')
    $entry = [ordered]@{
        Time   = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
        User   = $(if ($Session) { [string]$Session.User } else { '' })
        Role   = $(if ($Session) { [string]$Session.Role } else { '' })
        Via    = $(if ($Session) { [string]$Session.Source } else { '' })
        Ip     = $Ip
        Action = $Action
        Target = $Target
        Result = $Result
        Detail = $(if ($Detail.Length -gt 600) { $Detail.Substring(0, 600) } else { $Detail })
    }
    try { [IO.File]::AppendAllText($AuditPath, (ConvertTo-Json -InputObject ([pscustomobject]$entry) -Compress) + "`n", (New-Object Text.UTF8Encoding($false))) }
    catch { Write-WebLog "could not write the audit log: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
$script:State          = $null
$script:FleetJson      = 'null'
$script:FleetStamp     = ''
$script:Reading        = $false
$script:NextStateCheck = Get-Date
$script:CsvFile        = Resolve-FleetEventsCsv -ScriptDir $ScriptDir -CsvPath $CsvPath
$script:Sessions       = @{}
$script:Failures       = @{}
$script:Jobs           = @{}
$script:Busy           = @{}
$script:LiveObs        = @{}
$script:HoldState      = @{}
$script:Snapshots      = @{}
$script:ConfigWritten  = @{}
$script:Run            = $null
$script:RunLog         = New-Object System.Text.StringBuilder
$script:RunLogBase     = 0
$script:RunSerial      = 0
$script:RunLast        = $null
$script:ScanProgress   = $null
$script:AutoScanOn     = $false
$script:NextScanAt     = $null
$script:UsersStamp     = ''
$script:NextSweep      = Get-Date

$script:Credential = $Credential
$script:CredentialNote = ''
if (-not $script:Credential) {
    if (Test-Path -LiteralPath $CredentialFile) {
        try { $script:Credential = Import-StoredCredential -Path $CredentialFile }
        catch { $script:CredentialNote = ('the saved kiosk-admin credential does not open for {0}: {1}' -f [Environment]::UserName, $_.Exception.Message) }
    }
    else { $script:CredentialNote = ('no saved kiosk-admin credential - run Save-KioskCredential.ps1 as {0}' -f [Environment]::UserName) }
}

# ---------------------------------------------------------------------------
# Background work: anything that touches a kiosk takes seconds, or half a
# minute when the kiosk is off. It runs in a runspace pool, and the browser
# asks for the answer by job id.
# ---------------------------------------------------------------------------
$script:Pool = [runspacefactory]::CreateRunspacePool(1, 6)
$script:Pool.Open()

$JobScript = @'
param($Ctx)
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($PSVersionTable.PSVersion.Major -lt 6) { Remove-TypeData System.Array -ErrorAction SilentlyContinue }
foreach ($lib in $Ctx.Libs) { . (Join-Path $Ctx.ScriptDir "Lib\$lib.ps1") }
Invoke-FleetAction -Ctx $Ctx
'@

function Start-WebJob {
    param(
        [Parameter(Mandatory)][string]$Action,
        [string]$Label = '',
        [string]$Target = '',
        [hashtable]$Context = @{},
        $Session,
        [string]$Ip = '',
        [string]$AuditAction = ''
    )
    $id = (New-FleetToken).Substring(0, 22)
    $ctx = @{
        ScriptDir = $ScriptDir; RootTemplate = $RootTemplate; Credential = $script:Credential; Libs = $LibNames
        Say = [System.Collections.Queue]::Synchronized((New-Object System.Collections.Queue))
        Who = $(if ($Session) { '{0} ({1})' -f $Session.User, $Session.Role } else { 'Kiosk Fleet Web' })
        Action = $Action; Target = $Target
    }
    foreach ($k in $Context.Keys) { $ctx[$k] = $Context[$k] }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:Pool
    [void]$ps.AddScript($JobScript)
    [void]$ps.AddArgument($ctx)
    $job = [pscustomobject]@{
        Id = $id; Action = $Action; Label = $Label; Target = $Target; Ps = $ps; Handle = $null; Ctx = $ctx
        User = $(if ($Session) { $Session.User } else { '' }); Session = $Session; Ip = $Ip; AuditAction = $AuditAction
        Started = Get-Date; Finished = $null; Done = $false; Ok = $null; Detail = ''; Result = $null
        Lines = (New-Object System.Collections.Generic.List[string])
    }
    $job.Handle = $ps.BeginInvoke()
    $script:Jobs[$id] = $job
    if ($Target) { $script:Busy[$Target] = $Label }
    return $job
}

function Complete-WebJob {
    # What a finished job changes on the server, before anyone asks for it.
    param($Job)
    $r = $Job.Result
    $t = $Job.Target
    switch ($Job.Action) {
        'read-state' {
            $script:Reading = $false
            if ($r -and $r.State) {
                $script:State = $r.State
                $script:FleetJson = $r.Json
            }
            elseif ($Job.Detail) { Write-WebLog "could not read the fleet: $($Job.Detail)" }
            return
        }
        'live' {
            if ($r -and $r.Ok) {
                $script:LiveObs[$t] = [pscustomobject]@{ At = (Get-Date).ToString('HH:mm:ss'); Lines = @($r.Lines) }
                $script:HoldState[$t] = [bool]$r.Hold
            }
        }
        'control' {
            if ($r -and $r.Ok -and $Job.Ctx.File -eq 'hold.txt') { $script:HoldState[$t] = (-not $Job.Ctx['Remove']) }
        }
        'snapshot' {
            if ($r -and $r.Ok -and $r.File) {
                $script:Snapshots[$t] = [pscustomobject]@{ File = $r.File; Caption = ('{0} {1}  |  {2}  |  {3}' -f $r.Instance, (Get-Date).ToString('HH:mm:ss'), $r.State, $r.Url) }
            }
        }
        'config-write' {
            if ($r -and $r.Ok) {
                $script:ConfigWritten[$t] = $true
                [void]$script:LiveObs.Remove($t)
            }
        }
    }
}

function Update-WebJobs {
    foreach ($job in @($script:Jobs.Values)) {
        if ($job.Done) { continue }
        while ($job.Ctx.Say.Count -gt 0) { $job.Lines.Add([string]$job.Ctx.Say.Dequeue()) }
        if (-not $job.Handle.IsCompleted) { continue }

        $result = $null; $err = $null
        try { $result = $job.Ps.EndInvoke($job.Handle) }
        catch { $err = $_.Exception.Message }
        if (-not $err -and $job.Ps.Streams.Error.Count -gt 0) { $err = (@($job.Ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ') }
        while ($job.Ctx.Say.Count -gt 0) { $job.Lines.Add([string]$job.Ctx.Say.Dequeue()) }
        try { $job.Ps.Dispose() } catch { }

        $items = @($result | Where-Object { $null -ne $_ })
        $r = $(if ($items.Count) { $items[$items.Count - 1] } else { $null })
        $job.Result = $r
        $job.Done = $true
        $job.Finished = Get-Date
        $job.Ok = [bool]($r -and $r.Ok)
        $job.Detail = $(if ($r -and $r.Detail) { [string]$r.Detail } elseif ($err) { $err } elseif (-not $r) { 'no answer' } else { '' })
        if ($job.Target) { [void]$script:Busy.Remove($job.Target) }
        # Only the password and the secret config fields are secrets, and
        # neither is kept once the job is over.
        $job.Ctx.Remove('Secret')
        try { Complete-WebJob -Job $job }
        catch { Write-WebLog "after $($job.Action) on $($job.Target)" $_ }
        if ($job.AuditAction) {
            Write-FleetAudit -Session $job.Session -Ip $job.Ip -Action $job.AuditAction -Target $job.Target `
                -Result $(if ($job.Ok) { $(if ($r.Waiting) { 'waiting' } else { 'ok' }) } else { 'failed' }) -Detail $job.Detail
        }
    }
}

function Get-FleetStamp {
    param([string]$Path)
    $parts = @()
    foreach ($p in @($Path, [System.IO.Path]::ChangeExtension($Path, '.status.json'))) {
        try {
            $f = Get-Item -LiteralPath $p -ErrorAction Stop
            $parts += ('{0}|{1}' -f $f.LastWriteTimeUtc.Ticks, $f.Length)
        }
        catch { $parts += 'none' }
    }
    return ($parts -join ';')
}

function Request-StateRefresh {
    param([switch]$Force)
    if ($script:Reading) { return }
    $stamp = Get-FleetStamp -Path $script:CsvFile
    if (-not $Force -and $stamp -eq $script:FleetStamp -and $script:State) { return }
    $script:Reading = $true
    $script:FleetStamp = $stamp
    [void](Start-WebJob -Action 'read-state' -Context @{ Csv = $script:CsvFile })
}

function Get-StateKiosk {
    param([string]$HostName)
    if (-not $script:State -or -not $script:State.Ok) { return $null }
    return @($script:State.Hosts | Where-Object { $_.Host -eq $HostName })[0]
}

# ---------------------------------------------------------------------------
# Long runs: the collector and the deploys, as separate PowerShell processes
# exactly as from a prompt, their output kept for the Activity view
# ---------------------------------------------------------------------------
$RunLogLimit = 2MB

function Add-RunText {
    param([string]$Text)
    if (-not $Text) { return }
    [void]$script:RunLog.Append($Text)
    if ($script:RunLog.Length -gt $RunLogLimit) {
        $drop = $script:RunLog.Length - [int]($RunLogLimit * 0.75)
        [void]$script:RunLog.Remove(0, $drop)
        $script:RunLogBase += $drop
    }
}

function Read-NewText {
    param([string]$Path, [ref]$Position)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        try {
            if ($fs.Length -le $Position.Value) { return '' }
            [void]$fs.Seek($Position.Value, [IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ($fs.Length - $Position.Value)
            $read = $fs.Read($buf, 0, $buf.Length)
            $Position.Value = $Position.Value + $read
            return [Text.Encoding]::UTF8.GetString($buf, 0, $read)
        }
        finally { $fs.Dispose() }
    }
    catch { return '' }
}

function Start-FleetRun {
    <#
        $Command is one line of PowerShell, built here from checked values.
        It is written to Logs\run\<kind>-<time>.ps1 first, which makes the
        quoting honest and leaves behind exactly what ran and who ran it.
    #>
    param([string]$Title, [string]$Command, [string]$Kind = 'deploy', [switch]$Quiet, $Session)

    if ($script:Run) { return "$($script:Run.Title) is still running" }

    foreach ($old in @(Get-ChildItem -LiteralPath $RunDir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) })) {
        Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
    }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $runner = Join-Path $RunDir "$Kind-$stamp.ps1"
    $outPath = Join-Path $RunDir "$Kind-$stamp.out.txt"
    $errPath = Join-Path $RunDir "$Kind-$stamp.err.txt"
    $who = $(if ($Session) { '{0} ({1})' -f $Session.User, $Session.Role } else { 'auto-scan' })
    $lines = @(
        "# Kiosk Fleet Web, $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) - $Title - for $who",
        '[Console]::OutputEncoding = [Text.Encoding]::UTF8',
        "`$ProgressPreference = 'SilentlyContinue'",
        ("Set-Location -LiteralPath '{0}'" -f ($ScriptDir -replace "'", "''")),
        $Command,
        'exit $LASTEXITCODE'
    )
    [IO.File]::WriteAllText($runner, ($lines -join "`r`n"), (New-Object Text.UTF8Encoding($false)))

    $a = @{
        FilePath = $PowerShellExe; PassThru = $true
        # One string, quoted: a folder with a space in it must still work.
        ArgumentList = ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $runner)
        RedirectStandardOutput = $outPath; RedirectStandardError = $errPath
    }
    if ($OnWindows) { $a.WindowStyle = 'Hidden' }
    try {
        $proc = Start-Process @a
        # Touching the handle is what keeps ExitCode readable after it ends.
        try { [void]$proc.Handle } catch { }
    }
    catch { return "could not start it: $($_.Exception.Message)" }

    $script:RunSerial++
    $script:Run = [pscustomobject]@{
        Serial = $script:RunSerial; Title = $Title; Kind = $Kind; Proc = $proc; Out = $outPath; Err = $errPath
        OutPos = 0; ErrPos = 0; Started = Get-Date; Runner = $runner; Quiet = [bool]$Quiet; Who = $who; Session = $Session
    }
    if ($Kind -eq 'scan') { $script:ScanProgress = $null }
    if (-not $Quiet) {
        Add-RunText ("`r`n===== {0}  {1}  ({2}) =====`r`n" -f $Title, (Get-Date).ToString('HH:mm:ss'), $who)
        Add-RunText ("     {0}`r`n`r`n" -f $Command)
    }
    return $null
}

function Update-ScanProgress {
    # The collector rewrites its progress file as it moves from kiosk to
    # kiosk; one caught mid-write fails to parse and the last reading stands.
    if (-not $script:Run -or $script:Run.Kind -ne 'scan') { return }
    try {
        $p = (Read-SharedText -Path $ScanProgressPath) | ConvertFrom-Json
        if ($p -and $p.Pid -eq $script:Run.Proc.Id) { $script:ScanProgress = $p }
    }
    catch { }
}

function Update-Run {
    if (-not $script:Run) { return }
    $r = $script:Run
    foreach ($which in @('Out', 'Err')) {
        $pos = $r."${which}Pos"
        $text = Read-NewText -Path $r.$which -Position ([ref]$pos)
        $r."${which}Pos" = $pos
        if ($text -and -not $r.Quiet) { Add-RunText $text }
    }
    if ($r.Kind -eq 'scan') { Update-ScanProgress }
    if (-not $r.Proc.HasExited) { return }

    Start-Sleep -Milliseconds 100
    foreach ($which in @('Out', 'Err')) {
        $pos = $r."${which}Pos"
        $text = Read-NewText -Path $r.$which -Position ([ref]$pos)
        if ($text -and -not $r.Quiet) { Add-RunText $text }
    }
    $code = $r.Proc.ExitCode
    $secs = [int]((Get-Date) - $r.Started).TotalSeconds
    if (-not $r.Quiet) { Add-RunText ("`r`n===== {0}: finished with code {1} after {2}s =====`r`n" -f $r.Title, $code, $secs) }
    $script:RunLast = [pscustomobject]@{ Title = $r.Title; Kind = $r.Kind; Code = $code; Seconds = $secs; Finished = (Get-Date).ToString('HH:mm:ss'); Who = $r.Who }
    Write-FleetAudit -Session $r.Session -Ip '' -Action $(if ($r.Kind -eq 'scan') { 'scan-finished' } else { 'deploy-finished' }) -Target $r.Title `
        -Result $(if ($code -eq 0) { 'ok' } else { 'failed' }) -Detail ("exit code $code after ${secs}s")
    $script:Run = $null
    if ($r.Kind -eq 'scan') {
        $script:ScanProgress = $null
        $script:NextScanAt = (Get-Date).AddMinutes($AutoScanMinutes)
        Request-StateRefresh -Force
    }
}

function Start-Scan {
    param([switch]$Auto, $Session)
    if (-not (Test-Path -LiteralPath $CollectorPath)) { return "the collector is not here: $CollectorPath" }
    $hasCred = Test-Path -LiteralPath $CredentialFile
    if ($Auto -and -not $hasCred) {
        # Without the credential every watchdog kiosk comes back NO_ACCESS,
        # and those false outages would be written into the history.
        $script:AutoScanOn = $false
        return 'auto-scan needs the saved kiosk-admin credential: run Save-KioskCredential.ps1 as the service account'
    }
    $cmd = "& '{0}'" -f ($CollectorPath -replace "'", "''")
    if ($hasCred) { $cmd += " -CredentialFile '{0}'" -f ($CredentialFile -replace "'", "''") }
    $cmd += " -ProgressFile '{0}'" -f ($ScanProgressPath -replace "'", "''")
    return (Start-FleetRun -Title 'Fleet scan' -Command $cmd -Kind 'scan' -Quiet:$Auto -Session $Session)
}

function Enable-AutoScan {
    # The next scan is due from the last one that actually happened, so
    # switching it on next to the scheduled task does not sweep twice.
    if (-not (Test-Path -LiteralPath $CredentialFile)) { return 'auto-scan needs the saved kiosk-admin credential: run Save-KioskCredential.ps1 as the service account' }
    $script:AutoScanOn = $true
    $next = Get-Date
    if ($script:State) {
        $f = Get-FleetFreshness -State $script:State -StaleMinutes $StaleMinutes
        if ($f.LastRun) {
            $candidate = $f.LastRun.AddMinutes($AutoScanMinutes)
            if ($candidate -gt $next) { $next = $candidate }
        }
    }
    $script:NextScanAt = $next
    return $null
}

# ---------------------------------------------------------------------------
# Sessions
# ---------------------------------------------------------------------------
$CookieName = 'kfw_session'

function New-WebSession {
    param([string]$User, [string]$Role, [string]$Source, [string]$Ip)
    $token = New-FleetToken
    $s = [pscustomobject]@{
        Token = $token; User = $User; Role = $Role; Source = $Source; Csrf = (New-FleetToken)
        Created = Get-Date; LastSeen = Get-Date; Ip = $Ip
    }
    $script:Sessions[$token] = $s
    return $s
}

function Get-WebSession {
    param($Request)
    $c = $Request.Cookies[$CookieName]
    if (-not $c -or -not $c.Value) { return $null }
    $s = $script:Sessions[[string]$c.Value]
    if (-not $s) { return $null }
    $now = Get-Date
    if (($now - $s.LastSeen).TotalMinutes -gt $IdleMinutes -or ($now - $s.Created).TotalHours -gt $SessionHours) {
        [void]$script:Sessions.Remove($s.Token)
        return $null
    }
    $s.LastSeen = $now
    return $s
}

function Get-SessionCookie {
    param([string]$Token, [switch]$Clear)
    $v = $(if ($Clear) { "$CookieName=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0" } else { "$CookieName=$Token; Path=/; HttpOnly; SameSite=Strict" })
    if ($Https) { $v += '; Secure' }
    return $v
}

function Sync-LocalSessions {
    # A local account removed, disabled or given another role in
    # web-users.json takes effect at once, without a restart.
    if (-not $LocalAuth) { return }
    $stamp = $(try { $f = Get-Item -LiteralPath $UsersFile -ErrorAction Stop; '{0}|{1}' -f $f.LastWriteTimeUtc.Ticks, $f.Length } catch { 'none' })
    if ($stamp -eq $script:UsersStamp) { return }
    $script:UsersStamp = $stamp
    $users = @()
    try { $users = @(Read-FleetWebUsers -Path $UsersFile) } catch { Write-WebLog 'could not read the local accounts' $_; return }
    foreach ($s in @($script:Sessions.Values | Where-Object { $_.Source -eq 'local' })) {
        $u = @($users | Where-Object { ([string]$_.Name).Equals($s.User, [StringComparison]::OrdinalIgnoreCase) })[0]
        if (-not $u -or $u.Disabled -or -not $FleetRoleRank.ContainsKey([string]$u.Role)) { [void]$script:Sessions.Remove($s.Token); continue }
        $s.Role = [string]$u.Role
    }
}

function Test-LoginLocked {
    param([string]$Key)
    $f = $script:Failures[$Key]
    return ($f -and $f.Until -and (Get-Date) -lt $f.Until)
}

function Add-LoginFailure {
    # Five wrong passwords for a name, or twenty from one address, inside a
    # quarter of an hour: that name or address waits a quarter of an hour.
    param([string]$Key, [int]$Limit)
    $now = Get-Date
    $f = $script:Failures[$Key]
    if (-not $f -or ($now - $f.First).TotalMinutes -gt 15) { $f = [pscustomobject]@{ Count = 0; First = $now; Until = $null }; $script:Failures[$Key] = $f }
    $f.Count++
    if ($f.Count -ge $Limit) { $f.Until = $now.AddMinutes(15) }
}

# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
$Utf8 = New-Object Text.UTF8Encoding($false)
$StaticFiles = @{
    '/'           = @{ File = 'index.html'; Type = 'text/html; charset=utf-8' }
    '/index.html' = @{ File = 'index.html'; Type = 'text/html; charset=utf-8' }
    '/app.js'     = @{ File = 'app.js'; Type = 'text/javascript; charset=utf-8' }
    '/app.css'    = @{ File = 'app.css'; Type = 'text/css; charset=utf-8' }
}

function Set-CommonHeaders {
    param($Response)
    $h = $Response.Headers
    $h['X-Content-Type-Options'] = 'nosniff'
    $h['X-Frame-Options'] = 'DENY'
    $h['Referrer-Policy'] = 'no-referrer'
    $h['Content-Security-Policy'] = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    $h['Cache-Control'] = 'no-store'
    if ($Https) { $h['Strict-Transport-Security'] = 'max-age=31536000' }
}

function Send-Bytes {
    param($Response, [int]$Status, [byte[]]$Bytes, [string]$Type)
    $Response.StatusCode = $Status
    $Response.ContentType = $Type
    $Response.ContentLength64 = $Bytes.Length
    if ($Bytes.Length) { $Response.OutputStream.Write($Bytes, 0, $Bytes.Length) }
}

function Send-Json {
    param($Response, [int]$Status = 200, $Object, [string]$Raw)
    $text = $(if ($PSBoundParameters.ContainsKey('Raw')) { $Raw } else { ConvertTo-Json -InputObject $Object -Depth 12 -Compress })
    Send-Bytes -Response $Response -Status $Status -Bytes $Utf8.GetBytes($text) -Type 'application/json; charset=utf-8'
}

function Send-Error {
    param($Response, [int]$Status, [string]$Message)
    Send-Json -Response $Response -Status $Status -Object ([pscustomobject]@{ error = $Message })
}

function Read-JsonBody {
    param($Request)
    if (-not $Request.HasEntityBody) { return [pscustomobject]@{} }
    if ([string]$Request.ContentType -notlike 'application/json*') { throw [System.ArgumentException]'send JSON' }
    if ($Request.ContentLength64 -gt 262144) { throw [System.ArgumentException]'too large' }
    $reader = New-Object IO.StreamReader($Request.InputStream, $Utf8)
    try {
        $buf = New-Object char[] 262145
        $n = $reader.ReadBlock($buf, 0, $buf.Length)
        if ($n -gt 262144) { throw [System.ArgumentException]'too large' }
        $text = New-Object string($buf, 0, $n)
    }
    finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    try { return (ConvertFrom-Json -InputObject $text) } catch { throw [System.ArgumentException]'that is not JSON' }
}

function Test-SameOrigin {
    # A browser always says where a POST comes from; another site's page
    # must not be able to use someone's session here.
    param($Request)
    $origin = $Request.Headers['Origin']
    if (-not $origin) { return $true }
    $mine = '{0}://{1}' -f $Request.Url.Scheme, $Request.Url.Authority
    return ($origin -eq $mine)
}

function Test-Csrf {
    param($Request, $Session)
    $sent = [string]$Request.Headers['X-Fleet-Csrf']
    if (-not $sent -or -not $Session) { return $false }
    return (Test-FleetBytesEqual ($Utf8.GetBytes($sent)) ($Utf8.GetBytes([string]$Session.Csrf)))
}

function Get-BodyText {
    param($Body, [string]$Name, [int]$Max = 400)
    $p = $Body.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value) { return '' }
    $v = [string]$p.Value
    if ($v.Length -gt $Max) { throw [System.ArgumentException]"$Name is too long" }
    return $v
}

function Get-BodyBool {
    param($Body, [string]$Name)
    $p = $Body.PSObject.Properties[$Name]
    return [bool]($p -and $p.Value -eq $true)
}

function Get-BodyInt {
    param($Body, [string]$Name, [int]$Default, [int]$Min, [int]$Max, [string]$Say)
    $p = $Body.PSObject.Properties[$Name]
    if (-not $p -or $null -eq $p.Value -or "$($p.Value)" -eq '') { return $Default }
    $n = 0
    if (-not [int]::TryParse(("$($p.Value)").Trim(), [ref]$n) -or $n -lt $Min -or $n -gt $Max) { throw [System.ArgumentException]$Say }
    return $n
}

function ConvertTo-SecureText {
    param([string]$Plain)
    $s = New-Object System.Security.SecureString
    foreach ($ch in $Plain.ToCharArray()) { $s.AppendChar($ch) }
    $s.MakeReadOnly()
    return $s
}

# ---------------------------------------------------------------------------
# The answers
# ---------------------------------------------------------------------------
function Get-MeObject {
    param($Session, $Request)
    $local = $Request.IsLocal
    return [pscustomobject]@{
        user = $(if ($Session) { $Session.User } else { $null })
        role = $(if ($Session) { $Session.Role } else { $null })
        via = $(if ($Session) { $Session.Source } else { $null })
        csrf = $(if ($Session) { $Session.Csrf } else { $null })
        allowed = $(if ($Session) { @(Get-FleetAllowedActions -Role $Session.Role) } else { @() })
        methods = [pscustomobject]@{ windows = $WindowsAuth; local = $LocalAuth }
        insecure = (-not $Request.IsSecureConnection -and -not $local)
        version = $WebVersion
        idleMinutes = $IdleMinutes
    }
}

function Get-StateJson {
    param($Session, [string]$Since)
    $fresh = Get-FleetFreshness -State $script:State -StaleMinutes $StaleMinutes
    $run = $null
    if ($script:Run) {
        $el = (Get-Date) - $script:Run.Started
        $p = $script:ScanProgress
        $scan = $null
        if ($script:Run.Kind -eq 'scan') {
            $pct = 0; $text = 'starting'
            if ($p -and $p.Total -gt 0) {
                if ($p.Phase -eq 'saving') { $pct = 100; $text = 'saving' }
                else { $pct = [int](100 * ([math]::Max(0, [int]$p.Index - 1) / [double]$p.Total)); $text = '{0}/{1} {2}' -f $p.Index, $p.Total, $p.Host }
            }
            $scan = [pscustomobject]@{ pct = $pct; text = $text }
        }
        $run = [pscustomobject]@{
            serial = $script:Run.Serial; title = $script:Run.Title; kind = $script:Run.Kind; who = $script:Run.Who; quiet = $script:Run.Quiet
            elapsed = ('{0}:{1:00}' -f [int][math]::Floor($el.TotalMinutes), $el.Seconds); scan = $scan
        }
    }
    $mins = 0
    if ($script:AutoScanOn -and $script:NextScanAt) { $mins = [math]::Max(0, [int][math]::Ceiling(($script:NextScanAt - (Get-Date)).TotalMinutes)) }
    $dyn = [pscustomobject]@{
        stamp = $script:FleetStamp
        fresh = [pscustomobject]@{ text = $fresh.Text; stale = $fresh.Stale; lastRun = $(if ($fresh.LastRun) { $fresh.LastRun.ToString('ddd dd MMM HH:mm') } else { 'never' }) }
        busy = [pscustomobject]$script:Busy
        live = [pscustomobject]$script:LiveObs
        hold = [pscustomobject]$script:HoldState
        snapshots = [pscustomobject]$script:Snapshots
        configWritten = @($script:ConfigWritten.Keys)
        run = $run
        lastRun = $script:RunLast
        autoscan = [pscustomobject]@{ on = $script:AutoScanOn; minutes = $AutoScanMinutes; nextIn = $mins }
        credential = [pscustomobject]@{ ok = [bool]$script:Credential; note = $script:CredentialNote }
        clock = (Get-Date).ToString('ddd dd MMM  HH:mm:ss')
        restart = [pscustomobject]@{ message = $RestartMessage; seconds = $RestartWarningSeconds }
        remoteControl = $(if ($SccmSiteServer) { $SccmSiteServer.Trim().Trim('\') } else { '' })
        rootTemplate = $RootTemplate
        csv = $script:CsvFile
    }
    $dynJson = ConvertTo-Json -InputObject $dyn -Depth 8 -Compress
    $fleet = $(if ($Since -and $Since -eq $script:FleetStamp -and $script:State) { 'null' } else { $script:FleetJson })
    return ('{{"fleet":{0},"live":{1}}}' -f $fleet, $dynJson)
}

$KioskActions = @{
    'live'         = @{ Perm = 'live'; Label = 'reading'; Launcher = $true }
    'snapshot'     = @{ Perm = 'snapshot'; Label = 'taking a screenshot'; Launcher = $true }
    'reload'       = @{ Perm = 'reload'; Label = 'reloading the page'; Launcher = $true; File = 'refresh.txt' }
    'relaunch'     = @{ Perm = 'relaunch'; Label = 'restarting the browser'; Launcher = $true; File = 'relaunch.txt' }
    'hold'         = @{ Perm = 'hold'; Label = 'holding'; Launcher = $true; File = 'hold.txt' }
    'resume'       = @{ Perm = 'resume'; Label = 'carrying on'; Launcher = $true; File = 'hold.txt'; Remove = $true }
    'stop'         = @{ Perm = 'stop'; Label = 'stopping the launcher'; Launcher = $true; File = 'kill.txt' }
    'log'          = @{ Perm = 'log'; Label = 'reading the log'; Launcher = $true }
    'password'     = @{ Perm = 'password'; Label = 'setting the password'; Launcher = $true }
    'restart'      = @{ Perm = 'restart'; Label = 'restarting' }
    'message'      = @{ Perm = 'message'; Label = 'sending a message' }
    'config-read'  = @{ Perm = 'config'; Label = 'reading the config'; AnyHost = $true }
    'config-write' = @{ Perm = 'config'; Label = 'writing the config'; AnyHost = $true }
}

function Resolve-KioskTarget {
    # What a launcher button acts on: one screen (and its launcher), or
    # every launcher on every screen. Kind '' is a kiosk with no launcher.
    param($Kiosk, [string]$Screen, [string]$Kind)
    if ($Screen) {
        if ($Screen -notmatch '^S\d{1,2}$' -or $Kind -notin @('NG', 'PBI', 'WEB')) { throw [System.ArgumentException]'pick a screen like S1 and its launcher' }
        $has = @($Kiosk.Screens | Where-Object { [string]$_.Screen -eq $Screen -and $FleetKindOfScreenLauncher[[string]$_.Launcher] -eq $Kind }).Count
        if (-not $has) { throw [System.ArgumentException]"$($Kiosk.Host) has no $Kind screen $Screen" }
        return [pscustomobject]@{ Screen = $Screen; Kind = $Kind }
    }
    $screens = @(if ($Kiosk.PSObject.Properties['Screens']) { $Kiosk.Screens })
    if ($screens.Count -or $Kiosk.Ng -or $Kiosk.Pbi -or ($Kiosk.PSObject.Properties['Web'] -and $Kiosk.Web)) { return [pscustomobject]@{ Screen = ''; Kind = 'ALL' } }
    if ($FleetTabKinds.ContainsKey([string]$Kiosk.Tab)) { return [pscustomobject]@{ Screen = ''; Kind = $FleetTabKinds[[string]$Kiosk.Tab] } }
    return [pscustomobject]@{ Screen = ''; Kind = '' }
}

function Invoke-KioskAction {
    param($Context, $Session, [string]$HostName, [string]$Action)
    $req = $Context.Request; $res = $Context.Response
    $ip = [string]$req.RemoteEndPoint.Address
    $spec = $KioskActions[$Action]
    if (-not $spec) { return (Send-Error $res 404 'no such action') }
    if (-not (Test-FleetPermission -Role $Session.Role -Action $spec.Perm)) {
        Write-FleetAudit -Session $Session -Ip $ip -Action $Action -Target $HostName -Result 'refused' -Detail 'not allowed for this role'
        return (Send-Error $res 403 'Your role cannot do that.')
    }
    $name = Get-FleetHostName $HostName
    if (-not $name) { return (Send-Error $res 400 'that is not a kiosk name') }
    $kiosk = Get-StateKiosk $name
    if (-not $kiosk -and -not $spec['AnyHost']) { return (Send-Error $res 404 "$name is not in the last scan") }
    if ($script:Busy.ContainsKey($name)) { return (Send-Error $res 409 ('{0} is busy: {1}' -f $name, $script:Busy[$name])) }
    if (-not $script:Credential -and $RootTemplate -like '\\*') { return (Send-Error $res 503 ("The server cannot reach kiosks: $($script:CredentialNote)")) }

    $body = Read-JsonBody $req
    $ctx = @{}
    $auditDetail = ''

    if ($spec['Launcher']) {
        $t = Resolve-KioskTarget -Kiosk $kiosk -Screen (Get-BodyText $body 'screen' 4) -Kind (Get-BodyText $body 'kind' 4)
        if (-not $t.Kind) { return (Send-Error $res 400 "$name has no launcher") }
        $ctx.Kind = $t.Kind; $ctx.Screen = $t.Screen
        $auditDetail = $(if ($t.Screen) { "$($t.Screen) $($t.Kind)" } else { 'all screens' })
    }

    switch ($Action) {
        { $_ -in @('reload', 'relaunch', 'hold', 'resume', 'stop') } {
            $ctx.File = $spec['File']; $ctx.Remove = [bool]$spec['Remove']
            $jobAction = 'control'
        }
        'live' { $jobAction = 'live' }
        'log' { $jobAction = 'log'; $ctx.Lines = 60 }
        'snapshot' { $jobAction = 'snapshot'; $ctx.Dest = $SnapshotDir }
        'password' {
            if ($ctx.Kind -eq 'WEB') { return (Send-Error $res 400 'a web page screen signs in to nothing') }
            $p1 = Get-BodyText $body 'password' 256
            $p2 = Get-BodyText $body 'password2' 256
            if (-not $p1) { return (Send-Error $res 400 'Type the password first.') }
            if ($p1 -cne $p2) { return (Send-Error $res 400 'The two did not match. Nothing was changed.') }
            $ctx.Secret = ConvertTo-SecureText $p1
            $p1 = $null; $p2 = $null
            $jobAction = 'password'
        }
        'restart' {
            $secs = Get-BodyInt $body 'seconds' $RestartWarningSeconds 0 3600 'The countdown has to be a whole number of seconds, 0 to 3600.'
            $ctx.Secs = $secs
            $ctx.Message = (Get-BodyText $body 'message' 500).Trim()
            $auditDetail = "countdown ${secs}s"
            $jobAction = 'restart'
        }
        'message' {
            if (-not $kiosk.Ng -and $kiosk.Tab -ne 'Mach2') { return (Send-Error $res 400 'Only Mach2 kiosks have a watchdog to show a message.') }
            $text = (Get-BodyText $body 'text' 1000).Trim()
            if (-not $text) { return (Send-Error $res 400 'Type the message first.') }
            $ctx.Text = $text
            $ctx.Secs = Get-BodyInt $body 'seconds' 60 5 900 'Between 5 and 900 seconds.'
            $auditDetail = $text
            $jobAction = 'message'
        }
        'config-read' {
            $kind = Get-BodyText $body 'kind' 4
            if ($kind -notin @('NG', 'PBI', 'WEB')) { return (Send-Error $res 400 'which launcher: NG, PBI or WEB') }
            $instance = (Get-BodyText $body 'instance' 4).ToUpperInvariant()
            if ($instance -and $instance -notmatch '^S\d{1,2}$') { return (Send-Error $res 400 'A screen folder is named like S1 or S2.') }
            $ctx.Kind = $kind; $ctx.Instance = $instance
            $auditDetail = "$instance $kind"
            $jobAction = 'config-read'
        }
        'config-write' {
            $kind = Get-BodyText $body 'kind' 4
            if ($kind -notin @('NG', 'PBI', 'WEB')) { return (Send-Error $res 400 'which launcher: NG, PBI or WEB') }
            $instance = (Get-BodyText $body 'instance' 4).Trim().ToUpperInvariant()
            if ($instance -notmatch '^S\d{1,2}$') { return (Send-Error $res 400 'A screen folder is named like S1 or S2.') }
            $values = @{}
            $vp = $body.PSObject.Properties['values']
            if ($vp -and $vp.Value) {
                foreach ($p in $vp.Value.PSObject.Properties) {
                    if ($p.Name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,63}$') { return (Send-Error $res 400 "'$($p.Name)' is not a setting") }
                    $v = [string]$p.Value
                    if ($v.Length -gt 4000) { return (Send-Error $res 400 "$($p.Name) is too long") }
                    $values[$p.Name] = $v.Trim()
                }
            }
            $missing = @($FleetConfigRequired[$kind] | Where-Object { $values.ContainsKey($_) -and -not $values[$_] })
            if ($missing.Count) { return (Send-Error $res 400 ('Still empty: {0}.' -f ($missing -join ', '))) }
            $p1 = Get-BodyText $body 'password' 256
            $p2 = Get-BodyText $body 'password2' 256
            if ($p1 -cne $p2) { return (Send-Error $res 400 'The two passwords did not match. Nothing was saved.') }
            if ($p1 -and $kind -ne 'WEB') { $ctx.Secret = ConvertTo-SecureText $p1 }
            $p1 = $null; $p2 = $null
            $ctx.Kind = $kind; $ctx.Instance = $instance; $ctx.Values = $values
            $auditDetail = ('{0} {1}; {2}{3}' -f $instance, $kind, ((@($values.Keys | Sort-Object) | ForEach-Object { '{0}={1}' -f $_, $values[$_] }) -join ', '), $(if ($ctx.Secret) { '; new sign-in password' } else { '' }))
            $jobAction = 'config-write'
        }
    }

    $job = Start-WebJob -Action $jobAction -Label $spec.Label -Target $name -Context $ctx -Session $Session -Ip $ip -AuditAction $Action
    Write-FleetAudit -Session $Session -Ip $ip -Action $Action -Target $name -Result 'started' -Detail $auditDetail
    Send-Json $res 202 ([pscustomobject]@{ job = $job.Id; label = $spec.Label })
}

function Get-JobObject {
    param($Job)
    $r = $Job.Result
    $extra = $null
    if ($Job.Done -and $r) {
        switch ($Job.Action) {
            'live' { $extra = [pscustomobject]@{ lines = @($r.Lines); hold = [bool]$r.Hold } }
            'log' { $extra = [pscustomobject]@{ lines = @($r.Lines); path = [string]$r.Path } }
            'snapshot' { $extra = [pscustomobject]@{ file = [string]$r.File; instance = [string]$r.Instance; state = [string]$r.State; url = [string]$r.Url } }
            'config-read' {
                $extra = [pscustomobject]@{
                    kind = $r.Kind; isNew = [bool]$r.IsNew; instance = $r.Instance; instances = @($r.Instances)
                    password = $r.Password; taken = $r.Taken; fields = @($r.Fields)
                }
            }
            'config-write' { $extra = [pscustomobject]@{ isNew = [bool]$r.IsNew; path = [string]$r.Path; password = [string]$r.Password } }
            'message' { $extra = [pscustomobject]@{ status = [string]$r.Status } }
        }
    }
    return [pscustomobject]@{
        id = $Job.Id; action = $Job.Action; target = $Job.Target; done = $Job.Done; ok = $Job.Ok
        waiting = [bool]($r -and $r.PSObject.Properties['Waiting'] -and $r.Waiting)
        detail = $Job.Detail; lines = @($Job.Lines); result = $extra
    }
}

function Get-DeployRequest {
    param($Body)
    $product = Get-BodyText $Body 'product' 10
    $hosts = @()
    $hp = $Body.PSObject.Properties['hosts']
    if ($hp -and $hp.Value) { $hosts = @($hp.Value | ForEach-Object { [string]$_ }) }
    if ($hosts.Count -gt 500) { throw [System.ArgumentException]'too many kiosks at once' }
    $a = @{
        Product = $product; Hosts = $hosts
        Rollback = (Get-BodyBool $Body 'rollback'); Restart = (Get-BodyBool $Body 'restart')
        WarnSeconds = (Get-BodyInt $Body 'warnSeconds' $RestartWarningSeconds 0 600 'The countdown has to be 0 to 600 seconds.')
        VerifyMinutes = (Get-BodyInt $Body 'verifyMinutes' 12 2 60 'The wait has to be 2 to 60 minutes.')
        Force = (Get-BodyBool $Body 'force'); UpdateConfig = (Get-BodyBool $Body 'updateConfig')
        KeepLegacy = (Get-BodyBool $Body 'keepLegacy'); KeepWatchdog = (Get-BodyBool $Body 'keepWatchdog')
        RegisterTask = (Get-BodyBool $Body 'registerTask'); KioskUser = (Get-BodyText $Body 'kioskUser' 104).Trim()
        CredentialFile = $CredentialFile; ScriptDir = $ScriptDir; DryRun = (Get-BodyBool $Body 'dryRun')
    }
    try { return (Get-FleetDeployCommand @a) }
    catch { throw [System.ArgumentException]$_.Exception.Message }
}

function Get-ReportFiles {
    $files = @()
    $files += @(Get-ChildItem -LiteralPath $LogDir -Filter '*deploy*.csv' -File -ErrorAction SilentlyContinue)
    $files += @(Get-ChildItem -LiteralPath $RunDir -Filter '*.out.txt' -File -ErrorAction SilentlyContinue)
    return @($files | Sort-Object LastWriteTime -Descending | Select-Object -First 60)
}

function Invoke-ApiRequest {
    param($Context, $Session, [string]$Path, [string]$Method)
    $req = $Context.Request; $res = $Context.Response
    $ip = [string]$req.RemoteEndPoint.Address

    if ($Method -eq 'POST') {
        if (-not (Test-SameOrigin $req)) { return (Send-Error $res 403 'wrong origin') }
        if (-not (Test-Csrf $req $Session)) { return (Send-Error $res 403 'The page is out of date - reload it.') }
    }

    if ($Path -eq '/api/state' -and $Method -eq 'GET') {
        return (Send-Json -Response $res -Raw (Get-StateJson -Session $Session -Since ([string]$req.QueryString['since'])))
    }
    if ($Path -match '^/api/kiosks/([^/]+)/([a-z-]+)$' -and $Method -eq 'POST') {
        return (Invoke-KioskAction -Context $Context -Session $Session -HostName ([uri]::UnescapeDataString($Matches[1])) -Action $Matches[2])
    }
    if ($Path -match '^/api/jobs/([A-Za-z0-9_-]{10,40})$' -and $Method -eq 'GET') {
        $job = $script:Jobs[$Matches[1]]
        if (-not $job -or ($job.User -ne $Session.User -and $Session.Role -ne 'admin')) { return (Send-Error $res 404 'no such job') }
        return (Send-Json $res 200 (Get-JobObject $job))
    }
    if ($Path -match '^/api/snapshots/([A-Za-z0-9._-]{1,120}\.png)$' -and $Method -eq 'GET') {
        $file = Join-Path $SnapshotDir $Matches[1]
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return (Send-Error $res 404 'no such picture') }
        return (Send-Bytes -Response $res -Status 200 -Bytes ([IO.File]::ReadAllBytes($file)) -Type 'image/png')
    }
    if ($Path -eq '/api/run' -and $Method -eq 'GET') {
        $from = 0
        [void][long]::TryParse([string]$req.QueryString['from'], [ref]$from)
        $start = [math]::Max(0, $from - $script:RunLogBase)
        $total = $script:RunLogBase + $script:RunLog.Length
        $text = $(if ($start -lt $script:RunLog.Length) { $script:RunLog.ToString([int]$start, [int]($script:RunLog.Length - $start)) } else { '' })
        return (Send-Json $res 200 ([pscustomobject]@{ from = [math]::Max($from, $script:RunLogBase); next = $total; text = $text; running = [bool]$script:Run; last = $script:RunLast }))
    }
    if ($Path -eq '/api/scan' -and $Method -eq 'POST') {
        if (-not (Test-FleetPermission $Session.Role 'scan')) { return (Send-Error $res 403 'Your role cannot do that.') }
        $why = Start-Scan -Session $Session
        Write-FleetAudit -Session $Session -Ip $ip -Action 'scan' -Result $(if ($why) { 'refused' } else { 'started' }) -Detail ([string]$why)
        if ($why) { return (Send-Error $res 409 $why) }
        return (Send-Json $res 202 ([pscustomobject]@{ ok = $true }))
    }
    if ($Path -eq '/api/autoscan' -and $Method -eq 'POST') {
        if (-not (Test-FleetPermission $Session.Role 'autoscan')) { return (Send-Error $res 403 'Your role cannot do that.') }
        $on = Get-BodyBool (Read-JsonBody $req) 'on'
        $why = $null
        if ($on) { $why = Enable-AutoScan } else { $script:AutoScanOn = $false }
        Write-FleetAudit -Session $Session -Ip $ip -Action 'autoscan' -Target $(if ($on) { 'on' } else { 'off' }) -Result $(if ($why) { 'refused' } else { 'ok' }) -Detail ([string]$why)
        if ($why) { return (Send-Error $res 409 $why) }
        return (Send-Json $res 200 ([pscustomobject]@{ on = $script:AutoScanOn }))
    }
    if ($Path -eq '/api/run/stop' -and $Method -eq 'POST') {
        if (-not (Test-FleetPermission $Session.Role 'stoprun')) { return (Send-Error $res 403 'Your role cannot do that.') }
        if (-not $script:Run) { return (Send-Error $res 409 'nothing is running') }
        $title = $script:Run.Title
        try { $script:Run.Proc.Kill(); Add-RunText "`r`n===== stopped by $($Session.User) =====`r`n" }
        catch { return (Send-Error $res 500 "could not stop it: $($_.Exception.Message)") }
        Write-FleetAudit -Session $Session -Ip $ip -Action 'stop-run' -Target $title -Result 'ok'
        return (Send-Json $res 200 ([pscustomobject]@{ ok = $true }))
    }
    if ($Path -in @('/api/deploy/preview', '/api/deploy') -and $Method -eq 'POST') {
        if (-not (Test-FleetPermission $Session.Role 'deploy')) { return (Send-Error $res 403 'Your role cannot do that.') }
        $body = Read-JsonBody $req
        $d = Get-DeployRequest $body
        if ($Path -eq '/api/deploy/preview') {
            return (Send-Json $res 200 ([pscustomobject]@{ command = $d.Command; preview = $d.Preview; title = $d.Title; hosts = @($d.Hosts) }))
        }
        $dry = Get-BodyBool $body 'dryRun'
        $title = $(if ($dry) { "Dry run: $($d.Title)" } else { $d.Title })
        $why = Start-FleetRun -Title $title -Command $d.Command -Kind 'deploy' -Session $Session
        Write-FleetAudit -Session $Session -Ip $ip -Action $(if ($dry) { 'deploy-dryrun' } else { 'deploy' }) -Target (@($d.Hosts) -join ',') `
            -Result $(if ($why) { 'refused' } else { 'started' }) -Detail $(if ($why) { $why } else { $d.Command })
        if ($why) { return (Send-Error $res 409 $why) }
        return (Send-Json $res 202 ([pscustomobject]@{ ok = $true; title = $title }))
    }
    if ($Path -eq '/api/reports' -and $Method -eq 'GET') {
        $rows = @(foreach ($f in Get-ReportFiles) {
                $kind = switch -Wildcard ($f.Name) {
                    'm2ng-deploy*' { 'Mach2 Launcher NG' } 'pbi-deploy*' { 'PBI Launcher' } 'web-deploy*' { 'Web Launcher' }
                    'scan-*' { 'Scan output' } 'deploy-*' { 'Deploy output' } default { 'PBI Launcher or MWST watchdog' }
                }
                [pscustomobject]@{ name = $f.Name; when = $f.LastWriteTime.ToString('ddd dd MMM HH:mm'); kind = $kind; size = $f.Length }
            })
        return (Send-Json $res 200 ([pscustomobject]@{ reports = $rows }))
    }
    if ($Path -match '^/api/reports/([A-Za-z0-9._-]{1,160})$' -and $Method -eq 'GET') {
        $f = @(Get-ReportFiles | Where-Object { $_.Name -eq $Matches[1] })[0]
        if (-not $f) { return (Send-Error $res 404 'no such report') }
        $res.Headers['Content-Disposition'] = ('attachment; filename="{0}"' -f $f.Name)
        $type = $(if ($f.Extension -eq '.csv') { 'text/csv; charset=utf-8' } else { 'text/plain; charset=utf-8' })
        return (Send-Bytes -Response $res -Status 200 -Bytes ([IO.File]::ReadAllBytes($f.FullName)) -Type $type)
    }
    if ($Path -eq '/api/audit' -and $Method -eq 'GET') {
        if (-not (Test-FleetPermission $Session.Role 'audit')) { return (Send-Error $res 403 'Your role cannot do that.') }
        $entries = @()
        if (Test-Path -LiteralPath $AuditPath) {
            $lines = @((Read-SharedText -Path $AuditPath) -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 400)
            [array]::Reverse($lines)
            $entries = @(foreach ($l in $lines) { try { ConvertFrom-Json -InputObject $l } catch { } })
        }
        return (Send-Json $res 200 ([pscustomobject]@{ entries = $entries }))
    }
    if ($Path -eq '/api/deploy/products' -and $Method -eq 'GET') {
        $list = @(foreach ($k in $FleetDeployProducts.Keys) { [pscustomobject]@{ id = $k; name = $FleetDeployProducts[$k].Name; tab = $FleetDeployProducts[$k].Tab; note = $FleetDeployProducts[$k].Note } })
        return (Send-Json $res 200 ([pscustomobject]@{ products = $list }))
    }
    Send-Error $res 404 'not here'
}

function Invoke-FleetRequest {
    # Every request: the page itself, signing in and out, and the API.
    param($Context)
    $req = $Context.Request; $res = $Context.Response
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod
    $ip = [string]$req.RemoteEndPoint.Address
    Set-CommonHeaders $res

    if ($method -eq 'GET' -and $StaticFiles.ContainsKey($path)) {
        $s = $StaticFiles[$path]
        $file = Join-Path $WebDir $s.File
        $res.Headers['Cache-Control'] = 'no-cache'
        return (Send-Bytes -Response $res -Status 200 -Bytes ([IO.File]::ReadAllBytes($file)) -Type $s.Type)
    }
    if ($path -eq '/favicon.ico') { $res.StatusCode = 204; return }

    if ($path -eq '/auth/windows') {
        if (-not $WindowsAuth) { return (Send-Error $res 404 'Windows sign-in is off here.') }
        $principal = $Context.User
        if (-not $principal -or -not $principal.Identity -or -not $principal.Identity.IsAuthenticated) { return (Send-Error $res 401 'Windows did not say who you are.') }
        $name = [string]$principal.Identity.Name
        $role = $null
        foreach ($pair in @(@('admin', $AdminGroup), @('operator', $OperatorGroup))) {
            if ($role -or -not $pair[1]) { continue }
            try { if ($principal.IsInRole($pair[1])) { $role = $pair[0] } }
            catch { Write-WebLog "could not check $name against $($pair[1])" $_ }
        }
        if (-not $role) {
            Write-FleetAudit -Session ([pscustomobject]@{ User = $name; Role = ''; Source = 'windows' }) -Ip $ip -Action 'sign-in' -Result 'refused' -Detail "in neither $AdminGroup nor $OperatorGroup"
            return (Send-Error $res 403 ("{0} is in neither {1} nor {2}. Ask for one of them." -f $name, $AdminGroup, $OperatorGroup))
        }
        $s = New-WebSession -User $name -Role $role -Source 'windows' -Ip $ip
        $res.Headers.Add('Set-Cookie', (Get-SessionCookie $s.Token))
        Write-FleetAudit -Session $s -Ip $ip -Action 'sign-in' -Result 'ok'
        if ([string]$req.Headers['Accept'] -like '*text/html*') { $res.Redirect('/'); return }
        return (Send-Json $res 200 (Get-MeObject -Session $s -Request $req))
    }

    if ($path -eq '/api/login' -and $method -eq 'POST') {
        if (-not $LocalAuth) { return (Send-Error $res 404 'Local accounts are off here.') }
        if (-not (Test-SameOrigin $req)) { return (Send-Error $res 403 'wrong origin') }
        $body = Read-JsonBody $req
        $name = (Get-BodyText $body 'user' 64).Trim()
        $pass = Get-BodyText $body 'password' 256
        $userKey = 'u:' + $name.ToLowerInvariant()
        $ipKey = 'ip:' + $ip
        if ((Test-LoginLocked $userKey) -or (Test-LoginLocked $ipKey)) {
            Write-FleetAudit -Session ([pscustomobject]@{ User = $name; Role = ''; Source = 'local' }) -Ip $ip -Action 'sign-in' -Result 'refused' -Detail 'locked out for now'
            return (Send-Error $res 429 'Too many wrong passwords. Try again in 15 minutes.')
        }
        $users = @()
        try { $users = @(Read-FleetWebUsers -Path $UsersFile) } catch { Write-WebLog 'could not read the local accounts' $_ }
        $u = $(if ($name -and $pass) { Find-FleetLocalUser -Users $users -Name $name -Password $pass } else { $null })
        $pass = $null
        if (-not $u) {
            Add-LoginFailure -Key $userKey -Limit 5
            Add-LoginFailure -Key $ipKey -Limit 20
            Write-FleetAudit -Session ([pscustomobject]@{ User = $name; Role = ''; Source = 'local' }) -Ip $ip -Action 'sign-in' -Result 'failed'
            return (Send-Error $res 401 'That name and password do not match.')
        }
        [void]$script:Failures.Remove($userKey)
        $s = New-WebSession -User ([string]$u.Name) -Role ([string]$u.Role) -Source 'local' -Ip $ip
        $res.Headers.Add('Set-Cookie', (Get-SessionCookie $s.Token))
        Write-FleetAudit -Session $s -Ip $ip -Action 'sign-in' -Result 'ok'
        return (Send-Json $res 200 (Get-MeObject -Session $s -Request $req))
    }

    $session = Get-WebSession $req

    if ($path -eq '/api/me' -and $method -eq 'GET') {
        return (Send-Json $res $(if ($session) { 200 } else { 401 }) (Get-MeObject -Session $session -Request $req))
    }
    if ($path -eq '/api/logout' -and $method -eq 'POST') {
        if ($session -and (Test-Csrf $req $session)) {
            [void]$script:Sessions.Remove($session.Token)
            Write-FleetAudit -Session $session -Ip $ip -Action 'sign-out' -Result 'ok'
        }
        $res.Headers.Add('Set-Cookie', (Get-SessionCookie -Clear))
        return (Send-Json $res 200 ([pscustomobject]@{ ok = $true }))
    }

    if ($path -like '/api/*') {
        if (-not $session) { return (Send-Error $res 401 'Sign in first.') }
        return (Invoke-ApiRequest -Context $Context -Session $session -Path $path -Method $method)
    }
    Send-Error $res 404 'not here'
}

function Invoke-Housekeeping {
    Update-WebJobs
    Update-Run
    $now = Get-Date
    if ($now -ge $script:NextStateCheck) {
        Request-StateRefresh
        $script:NextStateCheck = $now.AddSeconds($RefreshSeconds)
    }
    if ($script:AutoScanOn -and -not $script:Run -and $script:NextScanAt -and $now -ge $script:NextScanAt) {
        $why = Start-Scan -Auto
        if ($why) { Write-WebLog "auto-scan: $why"; $script:NextScanAt = $now.AddMinutes($AutoScanMinutes) }
    }
    if ($now -ge $script:NextSweep) {
        $script:NextSweep = $now.AddSeconds(5)
        Sync-LocalSessions
        foreach ($s in @($script:Sessions.Values)) {
            if (($now - $s.LastSeen).TotalMinutes -gt $IdleMinutes -or ($now - $s.Created).TotalHours -gt $SessionHours) { [void]$script:Sessions.Remove($s.Token) }
        }
        foreach ($j in @($script:Jobs.Values)) {
            if ($j.Done -and ($now - $j.Finished).TotalMinutes -gt 15) { [void]$script:Jobs.Remove($j.Id) }
        }
        foreach ($k in @($script:Failures.Keys)) {
            $f = $script:Failures[$k]
            if (($now - $f.First).TotalMinutes -gt 30 -and (-not $f.Until -or $now -gt $f.Until)) { [void]$script:Failures.Remove($k) }
        }
    }
}

# ---------------------------------------------------------------------------
# Open
# ---------------------------------------------------------------------------
foreach ($f in @('index.html', 'app.js', 'app.css')) {
    if (-not (Test-Path -LiteralPath (Join-Path $WebDir $f))) { throw "The page is missing: $(Join-Path $WebDir $f)" }
}
if ($LocalAuth -and -not $WindowsAuth -and -not @(Read-FleetWebUsers -Path $UsersFile | Where-Object { -not $_.Disabled }).Count) {
    Write-WebLog "No local accounts yet and Windows sign-in is off: nobody can sign in. Add one with Set-FleetWebUser.ps1."
}

# The first read here, so the first page already has the fleet on it.
$script:FleetStamp = Get-FleetStamp -Path $script:CsvFile
$script:State = Read-FleetState -Path $script:CsvFile
$script:FleetJson = ConvertTo-Json -InputObject (ConvertTo-FleetView -State $script:State) -Depth 12 -Compress
if ($AutoScan) { $why = Enable-AutoScan; if ($why) { Write-WebLog "auto-scan: $why" } }

$listener = New-Object System.Net.HttpListener
foreach ($p in $Prefix) { $listener.Prefixes.Add($p) }
# A browser that goes away mid-answer is not an error worth stopping for.
$listener.IgnoreWriteExceptions = $true
# Requests are answered one at a time, so a client that stalls mid-request
# must not hold everyone else up for long. (HTTP.sys only, so Windows only.)
if ($OnWindows) {
    try {
        $listener.TimeoutManager.EntityBody = [TimeSpan]::FromSeconds(10)
        $listener.TimeoutManager.HeaderWait = [TimeSpan]::FromSeconds(10)
        $listener.TimeoutManager.IdleConnection = [TimeSpan]::FromSeconds(60)
    }
    catch { }
}
if ($WindowsAuth) {
    # Negotiate (Kerberos, or NTLM where there is no SPN) only on the one
    # address that signs people in; everything else is the session cookie.
    # The choice is made in compiled code because HttpListener may call it
    # on a thread where a PowerShell script block cannot run.
    if (-not ('FleetWeb.AuthSelector' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Net;
namespace FleetWeb {
    public static class AuthSelector {
        public static AuthenticationSchemes Select(HttpListenerRequest request) {
            if (string.Equals(request.Url.AbsolutePath, "/auth/windows", StringComparison.OrdinalIgnoreCase))
                return AuthenticationSchemes.Negotiate;
            return AuthenticationSchemes.Anonymous;
        }
        public static readonly AuthenticationSchemeSelector Selector = new AuthenticationSchemeSelector(Select);
    }
}
'@
    }
    $listener.AuthenticationSchemeSelectorDelegate = [FleetWeb.AuthSelector]::Selector
}
else { $listener.AuthenticationSchemes = [System.Net.AuthenticationSchemes]::Anonymous }

try { $listener.Start() }
catch {
    $msg = $_.Exception.Message
    if ($msg -match 'denied') { $msg += ' - the address needs reserving for this account: Install-FleetWeb.ps1 does it, or netsh http add urlacl url=<prefix> user=<account>.' }
    throw "Could not listen on $($Prefix -join ', '): $msg"
}

Write-WebLog ('Kiosk Fleet Web {0} on {1} as {2}. Sign-in: {3}. {4}' -f $WebVersion, ($Prefix -join ', '), [Environment]::UserName,
    ((@($(if ($WindowsAuth) { "Windows (admins: $AdminGroup, operators: $OperatorGroup)" }), $(if ($LocalAuth) { 'local accounts' })) | Where-Object { $_ }) -join ' + '),
    $(if ($script:Credential) { 'Kiosk-admin credential loaded.' } else { "WARNING: $($script:CredentialNote)" }))
if (-not $Https -and $AllowHttp) { Write-WebLog 'WARNING: plain HTTP - pages and local-account passwords cross the network unencrypted.' }
Write-FleetAudit -Session $null -Ip '' -Action 'server-start' -Result 'ok' -Detail ("$($Prefix -join ', ') as $([Environment]::UserName)")

try {
    $pending = $listener.GetContextAsync()
    while ($listener.IsListening) {
        $ready = $false
        try { $ready = $pending.Wait(250) }
        catch { Write-WebLog 'the listener stopped' $_; break }
        if ($ready) {
            $context = $pending.Result
            $pending = $listener.GetContextAsync()
            try { Invoke-FleetRequest -Context $context }
            catch [System.ArgumentException] {
                try { Send-Error $context.Response 400 $_.Exception.Message } catch { }
            }
            catch {
                Write-WebLog ("{0} {1}" -f $context.Request.HttpMethod, $context.Request.Url.AbsolutePath) $_
                try { Send-Error $context.Response 500 'Something went wrong on the server; it is in Logs\fleet-web.log.' } catch { }
            }
            finally { try { $context.Response.Close() } catch { } }
        }
        try { Invoke-Housekeeping }
        catch { Write-WebLog 'housekeeping' $_ }
    }
}
finally {
    Write-FleetAudit -Session $null -Ip '' -Action 'server-stop' -Result 'ok'
    try { $listener.Stop(); $listener.Close() } catch { }
    try { $script:Pool.Close(); $script:Pool.Dispose() } catch { }
}
