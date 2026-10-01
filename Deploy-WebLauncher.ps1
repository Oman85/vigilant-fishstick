#Requires -Version 5.1
<#
.SYNOPSIS
    Installs Web Launcher on kiosks over the admin share - one web page per
    screen - or rolls that back.

.DESCRIPTION
    For each kiosk:

      1. checks it is reachable (ping, then SMB)
      2. installs WebLauncher.ps1, Start-WebLauncher.cmd and EXAMPLE.json in
         C:\Users\Public\Documents\WebLauncher. Hash-verified, the previous
         copy kept as .bak-<timestamp>, swapped into place in one step.
      3. finds the screens to set up: every folder next to it (S1, S2, ...)
         with a <HOST>.json - written by the Kiosk Fleet Manager's Config...
         or by hand from EXAMPLE.json. There is nothing to migrate from: the
         old launchers never showed a plain web page. None: NO_CONFIG. A
         screen Mach2 Launcher NG or PBI Launcher has is left to it.
      4. puts "Web Launcher S<n>.lnk" in the kiosk account's Startup folder,
         one per screen. It runs conhost.exe > powershell.exe -WindowStyle
         Hidden, so the console is the classic one and never shows.
      5. retires an old launcher that ran on one of those screens, reversibly:
         its Launcher S<n>\<HOST>.json is renamed (.disabled-by-WebLauncher),
         so it does not run and the logon script (Mach2LauncherShortcuts.ps1)
         makes no shortcut for it; StartupLauncher's own configs likewise,
         once nothing it starts is still configured (see
         Lib\MWST.LegacyLauncher.ps1). Recorded in migration.json.

    The launcher starts at the kiosk account's next logon. -Restart restarts
    each kiosk right away - one at a time - and waits until every screen
    reports its page on screen (SHOWING). The first kiosk that does not get
    there stops the run.

    -Rollback removes the shortcuts, renames the old launcher's JSON back,
    and stops the launcher (kill.txt). The installed files and configs stay.

    -Command sends one control file to running launchers: Stop (kill.txt),
    Refresh, Relaunch, Hold, Resume (deletes hold.txt) or Snapshot.
    -Instance picks one screen; the default is all of them.

    Every run writes Logs\web-deploy_<timestamp>.csv. Supports -WhatIf.

.PARAMETER Hosts
    Kiosks to work on, as a list or comma-separated.

.PARAMETER AllWebKiosks
    Every active kiosk whose type in the kiosk list is Web.

.PARAMETER KioskUser
    Windows account the kiosk signs in as. Default: the one whose Startup
    folder holds a launcher shortcut, else the account named after the kiosk.

.PARAMETER KeepLegacy
    Install, but leave an old launcher on the same screen as it is.

.PARAMETER Restart
    Restart each kiosk after the change and wait for the result.

.PARAMETER Rollback
    Remove Web Launcher's shortcuts and put the old launcher back.

.PARAMETER Command
    Stop, Refresh, Relaunch, Hold, Resume or Snapshot.

.PARAMETER Instance
    With -Command: the one screen (S1, S2, ...) to send it to.

.PARAMETER RootTemplate
    For testing only: a local folder that stands in for each kiosk's C:
    drive, such as C:\Temp\FakeKiosks\{0}.

.EXAMPLE
    .\Deploy-WebLauncher.ps1 -Hosts SHCZ5KPI11980 -WhatIf

.EXAMPLE
    .\Deploy-WebLauncher.ps1 -Hosts SHCZ5KPI11980 -Restart

.EXAMPLE
    .\Deploy-WebLauncher.ps1 -Hosts SHCZ5KPI11980 -Command Refresh -Instance S2
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$Hosts,
    [switch]$AllWebKiosks,
    [string]$KioskList,
    [string]$FleetRoot,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredentialFile,
    [string]$KioskUser,
    [switch]$KeepLegacy,
    [switch]$Force,
    [switch]$Restart,
    [ValidateRange(0, 600)][int]$RestartWarningSeconds = 60,
    [ValidateRange(2, 60)][int]$VerifyMinutes = 12,
    [switch]$Rollback,
    [ValidateSet('Stop', 'Refresh', 'Relaunch', 'Hold', 'Resume', 'Snapshot')][string]$Command,
    [ValidatePattern('^[A-Za-z0-9_.-]*$')][string]$Instance,
    [string]$RootTemplate = '\\{0}\C$',
    [string]$ReportDir
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $FleetRoot) { $FleetRoot = $ScriptDir }
$SourceDir = Join-Path $ScriptDir 'WebLauncher'
$InstallRel = 'Users\Public\Documents\WebLauncher'
$InstallLocal = "C:\$InstallRel"
$PayloadFiles = @('WebLauncher.ps1', 'Start-WebLauncher.cmd', 'EXAMPLE.json')
$ShortcutPrefix = 'Web Launcher '
$StartupRel = 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$LogDir = if ($ReportDir) { $ReportDir } else { Join-Path $ScriptDir 'Logs' }

foreach ($lib in @('MWST.Remote.ps1', 'MWST.KioskList.ps1', 'MWST.LegacyLauncher.ps1')) {
    $p = Join-Path $FleetRoot "Lib\$lib"
    if (-not (Test-Path -LiteralPath $p)) { throw "Fleet library not found: $p. Point -FleetRoot at the fleet tools." }
    . $p
}

# --- Arguments ------------------------------------------------------------------
if ($Rollback -and $Command) { throw '-Rollback and -Command cannot be combined.' }
$RemoteRoots = $RootTemplate.StartsWith('\\')
if ($Restart -and -not $RemoteRoots) { throw '-Restart needs real kiosks (-RootTemplate is for testing).' }
if ($Command -and $Restart) { throw '-Command and -Restart cannot be combined.' }
if ($Instance -and -not $Command) { throw '-Instance goes with -Command.' }
if (-not $Hosts -and -not $AllWebKiosks) { throw 'Name the kiosks with -Hosts, or use -AllWebKiosks for the whole list.' }
if ($Hosts -and $AllWebKiosks) { throw 'Use -Hosts or -AllWebKiosks, not both.' }

if ($RemoteRoots -and -not $Credential -and -not $CredentialFile) {
    $default = Join-Path $FleetRoot 'Config\kiosk-admin.cred.xml'
    if (Test-Path -LiteralPath $default) { $CredentialFile = $default }
}
if ($CredentialFile -and -not $Credential) { $Credential = Import-StoredCredential -Path $CredentialFile }

foreach ($f in $PayloadFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $f))) { throw "Missing from ${SourceDir}: $f" }
}
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceDir 'WebLauncher.ps1'), [ref]$null, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "WebLauncher.ps1 does not parse - not deploying it: $($parseErrors[0].Message) (line $($parseErrors[0].Extent.StartLineNumber))" }
$LauncherVersion = ''
if ((Get-Content -LiteralPath (Join-Path $SourceDir 'WebLauncher.ps1') -TotalCount 200) -join "`n" -match "\`$LauncherVersion = '([^']+)'") { $LauncherVersion = $Matches[1] }

# --- Targets --------------------------------------------------------------------
$targets = @()
if ($Hosts) {
    $Hosts = @($Hosts | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
    $targets = @($Hosts | ForEach-Object { [pscustomobject]@{ Host = $_.Trim().ToUpperInvariant(); Location = '' } } | Where-Object { $_.Host })
}
else {
    $listPath = $KioskList
    if (-not $listPath) {
        $info = Resolve-KioskListPath -ScriptDir $FleetRoot
        Write-KioskListSource -ListInfo $info
        if (-not $info.Path) { throw 'No kiosk list found.' }
        $listPath = $info.Path
    }
    foreach ($row in @(Import-KioskList -Path $listPath -IncludeAll)) {
        if (-not (Test-IsWebKiosk -Type $row.Type)) { continue }
        if ($row.Active -and $row.Active.Trim().ToUpperInvariant().StartsWith('N')) { continue }
        $targets += [pscustomobject]@{ Host = $row.Host.ToUpperInvariant(); Location = $row.Location }
    }
}
if ($targets.Count -eq 0) { throw 'No kiosks to work on.' }

# --- Helpers ----------------------------------------------------------------------
function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '') } finally { $sha.Dispose() }
    }
    finally { $fs.Dispose() }
}

function Invoke-Retry {
    # For antivirus holding a freshly written file for a moment.
    param([Parameter(Mandatory)][scriptblock]$Action, [int]$Attempts = 6)
    for ($i = 1; ; $i++) {
        try { return (& $Action) }
        catch {
            $io = $_.Exception
            while ($io -and $io -isnot [IO.IOException]) { $io = $io.InnerException }
            if (-not $io -or $i -ge $Attempts) { throw }
            Start-Sleep -Milliseconds (500 * $i)
        }
    }
}

function Install-File {
    # Copy under a temporary name, verify, swap into place in one step;
    # keep the previous copy. Returns UPDATED, UP_TO_DATE or WHATIF.
    param([string]$Source, [string]$Destination)
    $hash = Get-Sha256 -Path $Source
    $exists = Test-Path -LiteralPath $Destination
    if ($exists -and -not $Force -and (Get-Sha256 -Path $Destination) -eq $hash) { return 'UP_TO_DATE' }
    if (-not $PSCmdlet.ShouldProcess($Destination, 'Install')) { return 'WHATIF' }
    $tmp = Join-Path (Split-Path -Parent $Destination) ("~{0}.{1}.tmp" -f (Split-Path -Leaf $Destination), $Stamp)
    try {
        Invoke-Retry { Copy-Item -LiteralPath $Source -Destination $tmp -Force }
        if ((Get-Sha256 -Path $tmp) -ne $hash) { throw "copy of $(Split-Path -Leaf $Source) arrived damaged" }
        if ($exists) { Invoke-Retry { [IO.File]::Replace($tmp, $Destination, "$Destination.bak-$Stamp") } }
        else { Invoke-Retry { [IO.File]::Move($tmp, $Destination) } }
    }
    finally { if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } }
    if ((Get-Sha256 -Path $Destination) -ne $hash) { throw "installed $(Split-Path -Leaf $Destination) does not match" }
    return 'UPDATED'
}

function Write-TextFile {
    param([string]$Path, [string]$Text, [string]$Action = 'Write')
    if (-not $PSCmdlet.ShouldProcess($Path, $Action)) { return $false }
    $tmp = "$Path.$Stamp.tmp"
    Invoke-Retry { [IO.File]::WriteAllText($tmp, $Text, $Utf8NoBom) }
    Invoke-Retry { Move-Item -LiteralPath $tmp -Destination $Path -Force }
    return $true
}

function Read-JsonFile {
    param([string]$Path)
    return (ConvertFrom-Json -InputObject (Read-SharedText -Path $Path))
}

function Get-RecordList {
    # A list from migration.json as non-blank strings ({} reads back as one blank).
    param($Record, [string]$Name)
    if (-not $Record -or -not $Record.PSObject.Properties[$Name]) { return @() }
    return @(@($Record.$Name) | Where-Object { $_ -is [string] -and $_.Trim() })
}

function Merge-Records {
    # {From; To} records, one per original place.
    param($Previous, [array]$New)
    $byFrom = [ordered]@{}
    foreach ($e in @(@($Previous) + @($New) | Where-Object { $_ -and $_.From })) { $byFrom[[string]$e.From] = [pscustomobject]@{ From = [string]$e.From; To = [string]$e.To } }
    return @($byFrom.Values)
}

$script:Shell = New-Object -ComObject WScript.Shell

function New-LauncherShortcut {
    # Built locally, then copied: the target is the kiosk's own path.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$InstanceName, [string]$ExtraArguments = '')
    $lnk = $script:Shell.CreateShortcut($Path)
    $lnk.TargetPath = 'C:\Windows\System32\conhost.exe'
    $lnk.Arguments = ('"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\WebLauncher.ps1" -Instance {1}{2}' -f $InstallLocal, $InstanceName, $(if ($ExtraArguments) { " $ExtraArguments" } else { '' }))
    $lnk.WorkingDirectory = $InstallLocal
    $lnk.WindowStyle = 7
    $lnk.Description = "Web Launcher - the web page on screen $InstanceName"
    $lnk.Save()
}

function Find-KioskAccount {
    # The kiosk account's Startup folder: named, or the one holding a
    # launcher's shortcut, or the account named after the kiosk.
    param([string]$Root, [string]$HostName)
    $usersDir = Join-Path $Root 'Users'
    $candidates = @()
    foreach ($u in @(Get-ChildItem -LiteralPath $usersDir -Directory -ErrorAction SilentlyContinue)) {
        $sf = Join-Path $u.FullName $StartupRel
        if (-not (Test-Path -LiteralPath $sf)) { continue }
        if (@(Get-ChildItem -LiteralPath $sf -Filter '*.lnk' -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(StartupLauncher|Mach2 Launcher NG |PBI Launcher|Web Launcher )' }).Count) { $candidates += $u.Name }
    }
    $user = if ($KioskUser) { $KioskUser } elseif (@($candidates | Select-Object -Unique).Count -eq 1) { $candidates[0] } else { $HostName }
    $profileDir = Join-Path $usersDir $user
    return [pscustomobject]@{ User = $user; ProfileExists = (Test-Path -LiteralPath $profileDir); Folder = (Join-Path $profileDir $StartupRel) }
}

function Read-LauncherStatus {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Read-JsonFile -Path $Path) } catch { return $null }
}

function Wait-LauncherShowing {
    # After a restart: a run that started after it (new PID or start time)
    # reporting SHOWING.
    param([string]$HostName, [string]$StatusPath, $Before)
    $deadline = (Get-Date).AddMinutes($VerifyMinutes)
    $wentDown = $false; $last = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        if (-not (Test-HostReachable -HostName $HostName -TimeoutMs 1000).Ok) { $wentDown = $true; $last = 'offline (restarting)'; continue }
        $st = Read-LauncherStatus -Path $StatusPath
        if (-not $st) { $last = 'no status file yet'; continue }
        if ($Before -and $st.StartedUtc -eq $Before.StartedUtc -and $st.Pid -eq $Before.Pid) { $last = 'waiting for the restart'; continue }
        $last = "$($st.State) $($st.Detail)".Trim()
        if ($st.State -eq 'SHOWING') { return [pscustomobject]@{ Ok = $true; Detail = ("SHOWING {0} (Edge {1}, launcher {2})" -f $st.CurrentUrl, $st.EdgeVersion, $st.LauncherVersion) } }
        if ($st.State -in @('DISABLED', 'UNSUPERVISED')) { return [pscustomobject]@{ Ok = $false; Detail = $last } }
    }
    if (-not $wentDown) { $last = "never went offline - did it restart? Last: $last" }
    return [pscustomobject]@{ Ok = $false; Detail = "not SHOWING after $VerifyMinutes min: $last" }
}

# --- Run ------------------------------------------------------------------------
$action = if ($Rollback) { 'Rollback' } elseif ($Command) { "Command $Command" } else { 'Install' }
Write-Host ("Web Launcher {0} - {1} on {2} kiosk(s){3}" -f $LauncherVersion, $action, $targets.Count, $(if ($WhatIfPreference) { ' (WhatIf)' } else { '' }))
if ($Credential) { Write-Host "Admin share as $($Credential.UserName)" -ForegroundColor DarkGray }

$results = New-Object System.Collections.Generic.List[object]
$halted = $false

foreach ($t in $targets) {
    $h = $t.Host
    $r = [pscustomobject]@{
        Host = $h; Location = $t.Location; Action = $action; Result = ''; Instances = ''; Files = ''; Startup = ''; Legacy = ''; Restart = ''; Verified = ''; Detail = ''
    }
    $results.Add($r)
    if ($halted) { $r.Result = 'HALTED'; $r.Detail = 'an earlier kiosk failed'; continue }

    Write-Host ''
    Write-Host ("{0} {1}" -f $h, $t.Location) -ForegroundColor Cyan
    $notes = New-Object System.Collections.Generic.List[string]
    $drive = $null
    try {
        $root = $RootTemplate -f $h
        if ($RemoteRoots) {
            $reach = Test-HostReachable -HostName $h
            if (-not $reach.Ok) { $r.Result = 'OFFLINE'; $r.Detail = $reach.Error; continue }
            try { $drive = Connect-KioskShare -Folder "$root\Users" -Credential $Credential } catch { $r.Result = 'NO_ACCESS'; $r.Detail = $_.Exception.Message; continue }
        }
        if (-not (Test-Path -LiteralPath "$root\Users")) { $r.Result = 'NO_ACCESS'; $r.Detail = "cannot read $root"; continue }

        $target = Join-Path $root $InstallRel
        $migrationPath = Join-Path $target 'migration.json'
        $existing = @()
        if (Test-Path -LiteralPath $target) {
            $existing = @(Get-ChildItem -LiteralPath $target -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^S\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName "$h.json")) } | ForEach-Object { $_.Name.ToUpperInvariant() } | Sort-Object)
        }
        $statusOf = { param($i) Join-Path $target "$i\Status\$i.status.json" }

        # --- -Command ----------------------------------------------------------
        if ($Command) {
            if (-not (Test-Path -LiteralPath (Join-Path $target 'WebLauncher.ps1'))) { $r.Result = 'NOT_INSTALLED'; continue }
            $which = if ($Instance) { @($Instance.ToUpperInvariant()) } else { $existing }
            if ($which.Count -eq 0) { $r.Result = 'NOT_INSTALLED'; $r.Detail = 'no screen folders'; continue }
            $states = @()
            foreach ($i in $which) {
                $dir = Join-Path $target $i
                if (-not (Test-Path -LiteralPath $dir)) { $notes.Add("no screen $i"); continue }
                if ($Command -eq 'Resume') {
                    $hold = Join-Path $dir 'hold.txt'
                    if ((Test-Path -LiteralPath $hold) -and $PSCmdlet.ShouldProcess($hold, 'Delete')) { Remove-Item -LiteralPath $hold -Force }
                }
                else {
                    $file = @{ Stop = 'kill.txt'; Refresh = 'refresh.txt'; Relaunch = 'relaunch.txt'; Hold = 'hold.txt'; Snapshot = 'snapshot.txt' }[$Command]
                    [void](Write-TextFile -Path (Join-Path $dir $file) -Text ("{0} by {1}\{2}" -f (Get-Date -Format s), $env:USERDOMAIN, $env:USERNAME) -Action 'Create')
                }
                $st = Read-LauncherStatus -Path (& $statusOf $i)
                if ($st) { $states += "$i was $($st.State)" }
            }
            $r.Instances = $which -join ','
            $r.Result = 'SENT'
            if ($states.Count) { $r.Detail = $states -join '; ' }
            continue
        }

        $account = Find-KioskAccount -Root $root -HostName $h

        # --- -Rollback --------------------------------------------------------
        if ($Rollback) {
            $m = $null
            if (Test-Path -LiteralPath $migrationPath) { $m = Read-JsonFile -Path $migrationPath }
            $links = @(Get-RecordList -Record $m -Name 'Shortcuts' | ForEach-Object { ConvertFrom-LegacyKioskPath -Path $_ -Root $root })
            if (Test-Path -LiteralPath $account.Folder) { $links += @(Get-ChildItem -LiteralPath $account.Folder -Filter "$ShortcutPrefix*.lnk" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
            $removed = 0
            foreach ($lp in @($links | Select-Object -Unique)) {
                if ((Test-Path -LiteralPath $lp) -and $PSCmdlet.ShouldProcess($lp, 'Delete')) { Remove-Item -LiteralPath $lp -Force; $removed++ }
            }
            $r.Startup = "removed $removed"
            $back = 0
            if ($m -and $m.PSObject.Properties['LegacyJsonRenamed']) { $back = Undo-LegacyJsonRenames -Root $root -Records @($m.LegacyJsonRenamed) -Cmdlet $PSCmdlet }
            $r.Legacy = "JSON renamed back $back"
            foreach ($i in $existing) { [void](Write-TextFile -Path (Join-Path $target "$i\kill.txt") -Text 'rollback' -Action 'Create') }
            $r.Instances = $existing -join ','
            if ($existing.Count) { $r.Files = 'kept (launcher told to stop)' }
            if ($m -and $PSCmdlet.ShouldProcess($migrationPath, 'Mark as rolled back')) { Move-Item -LiteralPath $migrationPath -Destination "$migrationPath.rolledback-$Stamp" -Force }
            $r.Result = if ($WhatIfPreference) { 'WHATIF' } else { 'ROLLED_BACK' }
        }
        # --- Install -------------------------------------------------------------
        else {
            # One launcher per screen.
            $owners = Get-ScreenOwners -Root $root -HostName $h
            $instances = @($existing | Where-Object {
                    if ($owners.ContainsKey($_) -and $owners[$_] -ne 'WEB') { $notes.Add("$_ belongs to $($ScreenLauncherTitles[$owners[$_]]) on this kiosk - not set up for Web"); $false } else { $true }
                })
            if ($instances.Count -eq 0) {
                $r.Result = 'NO_CONFIG'
                $r.Detail = (@("no screen to set up. Put $h.json (from EXAMPLE.json) in $InstallLocal\S1 (or S2, ...) - Config... in the Kiosk Fleet Manager does that - and run again.") + $notes) -join '; '
                $notes.Clear()
                continue
            }
            if (-not $account.ProfileExists) {
                $r.Result = 'FAILED'
                $r.Detail = "no profile for kiosk account '$($account.User)' on this kiosk - has it ever signed in? Use -KioskUser."
                continue
            }
            $r.Instances = $instances -join ','

            $fileResults = @(foreach ($f in $PayloadFiles) { Install-File -Source (Join-Path $SourceDir $f) -Destination (Join-Path $target $f) })
            $r.Files = if ($fileResults -contains 'WHATIF') { 'WHATIF' } elseif ($fileResults -contains 'UPDATED') { 'UPDATED' } else { 'UP_TO_DATE' }

            $links = @()
            foreach ($i in $instances) {
                $newLink = Join-Path $account.Folder "$ShortcutPrefix$i.lnk"
                if ($PSCmdlet.ShouldProcess($newLink, 'Create startup shortcut')) {
                    if (-not (Test-Path -LiteralPath $account.Folder)) { New-Item -ItemType Directory -Path $account.Folder -Force | Out-Null }
                    $tmpLink = Join-Path $env:TEMP "WebLauncher-$Stamp-$i.lnk"
                    New-LauncherShortcut -Path $tmpLink -InstanceName $i
                    Invoke-Retry { Copy-Item -LiteralPath $tmpLink -Destination $newLink -Force }
                    Remove-Item -LiteralPath $tmpLink -Force
                    $links += ConvertTo-LegacyKioskPath -Path $newLink -Root $root
                }
            }
            $r.Startup = if ($links.Count) { "for $($account.User): $($links.Count) shortcut(s)" } else { 'WHATIF' }

            # An old launcher on these screens: its JSON renamed.
            $jsonRenamed = @()
            if ($KeepLegacy) { $r.Legacy = 'kept (-KeepLegacy)' }
            else {
                $old = Find-LegacyScreenConfigs -Root $root -HostName $h
                foreach ($i in $instances) {
                    foreach ($p in @($old[$i])) {
                        if (-not $p) { continue }
                        try {
                            $to = Disable-LegacyJson -Path $p -Tag 'WebLauncher' -Cmdlet $PSCmdlet
                            if ($to) { $jsonRenamed += [pscustomobject]@{ From = (ConvertTo-LegacyKioskPath -Path $p -Root $root); To = (ConvertTo-LegacyKioskPath -Path $to -Root $root) } }
                        }
                        catch { $notes.Add("could not rename the old $i config: $($_.Exception.Message)") }
                    }
                }
                if ($jsonRenamed.Count) {
                    try {
                        $sl = Invoke-RetireLegacyStartup -Root $root -HostName $h -Tag 'WebLauncher' -Cmdlet $PSCmdlet
                        $jsonRenamed += @($sl.Renamed)
                        foreach ($k in $sl.Kept) { $notes.Add("StartupLauncher kept: $k") }
                    }
                    catch { $notes.Add("could not retire StartupLauncher's config: $($_.Exception.Message)") }
                }
                $r.Legacy = if ($jsonRenamed.Count) { "JSON renamed $($jsonRenamed.Count)" } else { 'no old launcher on these screens' }
            }

            if (-not $WhatIfPreference) {
                $prev = $null
                if (Test-Path -LiteralPath $migrationPath) { try { $prev = Read-JsonFile -Path $migrationPath } catch {} }
                $prevJson = if ($prev -and $prev.PSObject.Properties['LegacyJsonRenamed']) { @($prev.LegacyJsonRenamed) } else { @() }
                $record = [ordered]@{
                    Host              = $h
                    LauncherVersion   = $LauncherVersion
                    DeployedAt        = (Get-Date).ToString('s')
                    DeployedBy        = "$env:USERDOMAIN\$env:USERNAME"
                    KioskUser         = $account.User
                    Instances         = @($instances)
                    Shortcuts         = @(@(Get-RecordList -Record $prev -Name 'Shortcuts') + @($links) | Where-Object { $_ } | Select-Object -Unique)
                    LegacyJsonRenamed = @(Merge-Records -Previous $prevJson -New $jsonRenamed)
                }
                [void](Write-TextFile -Path $migrationPath -Text (ConvertTo-Json -InputObject ([pscustomobject]$record) -Depth 4))
            }
            $r.Result = if ($WhatIfPreference) { 'WHATIF' } else { 'INSTALLED' }
        }

        # --- restart and verify ----------------------------------------------------
        if ($Restart -and -not $WhatIfPreference) {
            $verifyScreens = @(if ($Rollback) { @() } else { $instances })
            $before = @{}
            foreach ($i in $verifyScreens) { $before[$i] = Read-LauncherStatus -Path (& $statusOf $i) }
            $comment = if ($Rollback) { 'IT is removing the web page launcher from this screen. It will come back on its own. [WEB-LAUNCHER deploy]' }
            else { 'IT is updating the web page launcher on this screen. It will come back on its own. [WEB-LAUNCHER deploy]' }
            $send = Send-KioskRestart -HostName $h -Credential $Credential -WarningSeconds $RestartWarningSeconds -Comment $comment -ReasonCode ([uint32]2147745794)
            if (-not $send.Sent) { $r.Restart = 'FAILED'; $r.Result = 'FAILED'; $notes.Add("restart: $($send.Detail)"); $halted = $true; continue }
            $r.Restart = "sent ($($send.Via))"
            if ($Rollback) { $r.Verified = 'not checked' }
            else {
                Write-Host ("  restarting, waiting up to {0} min for {1}..." -f $VerifyMinutes, ($verifyScreens -join ', ')) -ForegroundColor DarkGray
                $verified = @(); $ok = $true
                foreach ($i in $verifyScreens) {
                    $v = Wait-LauncherShowing -HostName $h -StatusPath (& $statusOf $i) -Before $before[$i]
                    $verified += "${i}: $($v.Detail)"
                    if (-not $v.Ok) { $ok = $false; break }
                }
                $r.Verified = $verified -join '; '
                if ($ok) { $r.Result = 'VERIFIED' } else { $r.Result = 'FAILED'; $halted = $true }
            }
        }
        elseif (-not $Restart -and -not $WhatIfPreference -and $r.Result -in @('INSTALLED', 'ROLLED_BACK')) {
            $notes.Add('takes effect at the next logon or restart (-Restart to do it now)')
        }
    }
    catch {
        $r.Result = 'FAILED'
        $notes.Add($_.Exception.Message)
        if ($Restart) { $halted = $true }
    }
    finally {
        if ($notes.Count) { $r.Detail = (@($r.Detail) + $notes | Where-Object { $_ }) -join '; ' }
        Disconnect-KioskShare -Drive $drive
        $color = switch -Wildcard ($r.Result) { 'VERIFIED' { 'Green' } 'INSTALLED' { 'Green' } 'ROLLED_BACK' { 'Green' } 'SENT' { 'Green' } 'WHATIF' { 'Gray' } 'FAILED' { 'Red' } default { 'Yellow' } }
        Write-Host ("  {0,-12} screens={1} files={2} startup={3}" -f $r.Result, $r.Instances, $r.Files, $r.Startup) -ForegroundColor $color
        if ($r.Legacy) { Write-Host ("  {0,-12} old launcher: {1}" -f '', $r.Legacy) -ForegroundColor DarkGray }
        if ($r.Restart) { Write-Host ("  {0,-12} restart: {1}; {2}" -f '', $r.Restart, $r.Verified) -ForegroundColor DarkGray }
        if ($r.Detail) { Write-Host ("  {0,-12} {1}" -f '', $r.Detail) -ForegroundColor $(if ($r.Result -eq 'FAILED') { 'Red' } else { 'DarkGray' }) }
    }
}

# --- Report -----------------------------------------------------------------------
Write-Host ''
$results | Group-Object Result | Sort-Object Name | ForEach-Object { Write-Host ("{0,4}  {1}" -f $_.Count, $_.Name) }
if ($halted) { Write-Host 'Stopped at the first failure; later kiosks were not touched (HALTED).' -ForegroundColor Red }
if (-not $WhatIfPreference) {
    if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
    $report = Join-Path $LogDir "web-deploy_$Stamp.csv"
    $results | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8
    Write-Host "Report: $report" -ForegroundColor DarkGray
}
if (@($results | Where-Object { $_.Result -in @('FAILED', 'HALTED') }).Count) { exit 1 }
