#Requires -Version 5.1
<#
.SYNOPSIS
    Deploy ver 1.02NG: installs Mach2 Launcher ver 1.02NG on Mach2 kiosks
    over the admin share, and retires the old Mach2Launcher.exe and the MWST
    watchdog - or rolls that back.

.DESCRIPTION
    Mach2 Launcher NG shows the Mach2 dashboard and is the kiosk's watchdog
    as well, so it replaces two things on each kiosk. For each kiosk:

      1. checks it is reachable (ping, then SMB)
      2. finds the old launcher: <HOST>.json next to Mach2Launcher.exe in
         C:\Users\Public\Documents\Mach2Launchers\Launcher S<n>\ (or under
         ...\Launchers\), one per screen
      3. installs Mach2LauncherNG.ps1, Start-Mach2LauncherNG.cmd and
         EXAMPLE.json in C:\Users\Public\Documents\Mach2LauncherNG.
         Hash-verified, the previous copy kept as .bak-<timestamp>, swapped
         into place in one step.
      4. writes one instance folder per screen (S1, S2, ...) with a
         <HOST>.json made from the old config: same dashboard, login
         address, user, screen, zoom, refresh and restart settings, same
         central log folder - but no password. S1 (the lowest) is the
         watchdog. An existing config is left alone unless -UpdateConfig.
      5. if an instance has no encrypted password yet, writes password.seed
         there (from -SignInCredential, else from the old config); the
         launcher encrypts it for the kiosk account and deletes it.
      6. puts "Mach2 Launcher NG S<n>.lnk" in the kiosk account's Startup
         folder: conhost.exe > powershell.exe -WindowStyle Hidden, so the
         console is the classic one and never shows.
      7. retires the old launcher, reversibly: the StartupLauncher shortcut
         is moved out of the Startup folder into
         Mach2LauncherNG\Retired shortcuts\<account>\ (unless it also
         starts something that is not Mach2). Not renamed in place: Windows
         opens everything in a Startup folder at logon whatever it is
         called, and 1.00NG's "*.disabled-by-Mach2LauncherNG" made it ask
         which app to open the file with, on top of the dashboard. Any such
         file still there is moved out too.
         Mach2LauncherShortcuts.ps1 copies the StartupLauncher shortcut
         back at every logon, and the old Mach2 launcher has no setting
         that keeps it off, so what really keeps it off is the new launcher
         itself: it stops the old one for its screen whenever it finds it
         running (StopOldLauncher, from 1.01NG). DisableStartup = 1 is still
         set in an old config that has the setting.
      8. retires the MWST watchdog, reversibly: its logon task (any task
         that runs MWSTv*_Launcher.bat or mwstv4.ps1) is disabled over
         CIM/DCOM, and a Startup shortcut to it moved out the same way. Its
         files stay. If the task cannot be disabled, the new launcher stops
         the old watchdog whenever it finds it running.
      Everything changed is recorded in migration.json for -Rollback.

    The new launcher starts at the kiosk account's next logon. -Restart
    restarts each kiosk right away - one at a time - and waits until every
    screen's launcher reports its dashboard on screen (SHOWING), with the
    watchdog running in the classic console, hidden. The first kiosk that
    does not get there stops the run.

    -Rollback puts the old launcher and the old watchdog back: their
    shortcuts back in the Startup folder (from Retired shortcuts, or
    renamed back where 1.00NG renamed them), DisableStartup, the watchdog's
    task, and the new launcher stopped (kill.txt) and its shortcuts
    removed. The installed files stay.

    -Command sends one control file to the running launchers: Stop
    (kill.txt), Refresh, Relaunch, Hold, Resume (deletes hold.txt) or
    Snapshot. -Instance picks one screen; the default is all of them.

    Targets: -Hosts, or -AllMach2Kiosks for every Mach2 kiosk in the master
    kiosk list that is not inactive. Every run writes
    Logs\m2ng-deploy_<timestamp>.csv. Supports -WhatIf.

.PARAMETER Hosts
    Kiosks to work on, as a list or comma-separated. Start with one.

.PARAMETER AllMach2Kiosks
    Every active Mach2 kiosk in the kiosk list.

.PARAMETER KioskList
    Kiosk list for -AllMach2Kiosks. Default: the SharePoint master.

.PARAMETER FleetRoot
    Folder holding the fleet tools' Lib\, Config\ and Tools\. Default: the
    folder this script is in.

.PARAMETER Credential
    Admin credential for the kiosks' C$ share (and CIM for the task).

.PARAMETER CredentialFile
    A credential saved by Save-KioskCredential.ps1. Default:
    <FleetRoot>\Config\kiosk-admin.cred.xml when it exists.

.PARAMETER SignInCredential
    The Mach2 user's password to hand to the launcher (as password.seed),
    for example after it was changed. The user name is not used.

.PARAMETER KioskUser
    Windows account the kiosk signs in as. Default: the one whose Startup
    folder holds the old StartupLauncher, else the account named after the
    kiosk.

.PARAMETER UpdateConfig
    Rewrite each instance's <HOST>.json from the old config even if it
    already exists.

.PARAMETER KeepLegacy
    Install, but leave the old launcher as it is: its shortcut stays, and
    the new launcher's config gets StopOldLauncher = 0 so it leaves the old
    one running. For trying the two side by side; they fight over the
    screen.

.PARAMETER KeepWatchdog
    Install, but leave the MWST watchdog's task as it is. The new launcher
    still stops the old watchdog when it finds it running - two watchdogs
    must not restart the same PC - so this is for testing only.

.PARAMETER Force
    Copy the launcher files even when the kiosk already has them.

.PARAMETER Restart
    Restart each kiosk after the change and wait for the result.

.PARAMETER RestartWarningSeconds
    Countdown shown on the kiosk before it restarts. Default 60.

.PARAMETER VerifyMinutes
    How long a restarted kiosk has to show its dashboard. Default 12.

.PARAMETER Rollback
    Put the old launcher and the old watchdog back (see above).

.PARAMETER Command
    Stop, Refresh, Relaunch, Hold, Resume or Snapshot.

.PARAMETER Instance
    With -Command: the one screen (S1, S2, ...) to send it to.

.PARAMETER RootTemplate
    For testing only: a local folder that stands in for each kiosk's C:
    drive, such as C:\Temp\FakeKiosks\{0}.

.PARAMETER ReportDir
    Where the CSV report goes. Default: Logs next to this script.

.EXAMPLE
    .\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI12473 -WhatIf

.EXAMPLE
    .\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI12473 -Restart

.EXAMPLE
    .\Deploy-Mach2LauncherNG.ps1 -AllMach2Kiosks -Restart

.EXAMPLE
    .\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI12473 -SignInCredential (Get-Credential operator)

.EXAMPLE
    .\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI12473 -Rollback -Restart

.EXAMPLE
    .\Deploy-Mach2LauncherNG.ps1 -Hosts SHCZ5KPI9114 -Command Refresh -Instance S2
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$Hosts,
    [switch]$AllMach2Kiosks,
    [string]$KioskList,
    [string]$FleetRoot,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredentialFile,
    [System.Management.Automation.PSCredential]$SignInCredential,
    [string]$KioskUser,
    [switch]$UpdateConfig,
    [switch]$KeepLegacy,
    [switch]$KeepWatchdog,
    [switch]$Force,
    [switch]$Restart,
    [ValidateRange(0, 600)][int]$RestartWarningSeconds = 60,
    [ValidateRange(2, 60)][int]$VerifyMinutes = 12,
    [switch]$Rollback,
    [ValidateSet('Stop', 'Refresh', 'Relaunch', 'Hold', 'Resume', 'Snapshot')][string]$Command,
    [ValidatePattern('^[A-Za-z0-9_.-]*$')][string]$Instance,
    # For testing: a local folder standing in for each kiosk's C: drive.
    # Reachability, restarts, the share login and the watchdog task are
    # skipped for a local root.
    [string]$RootTemplate = '\\{0}\C$',
    [string]$ReportDir
)

# Off, like the fleet tools this script shares its libraries with.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$DeployVersion = '1.02NG'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $FleetRoot) { $FleetRoot = $ScriptDir }
$SourceDir = Join-Path $ScriptDir 'Mach2LauncherNG'
$InstallRel = 'Users\Public\Documents\Mach2LauncherNG'
$InstallLocal = "C:\$InstallRel"
$PublicRel = 'Users\Public\Documents'
$PayloadFiles = @('Mach2LauncherNG.ps1', 'Start-Mach2LauncherNG.cmd', 'EXAMPLE.json')
$LegacyRoots = @('Users\Public\Documents\Mach2Launchers', 'Users\Public\Documents\Launchers')
$ShortcutPrefix = 'Mach2 Launcher NG '
# Where retired Startup shortcuts go, under the install folder: anywhere
# but a Startup folder, which Windows runs whatever the file is called.
$RetiredRel = 'Retired shortcuts'
$DisabledSuffix = '.disabled-by-Mach2LauncherNG'
$StartupRel = 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
$AllUsersStartupRel = 'ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'
$WatchdogPattern = '(?i)MWSTv\d+_Launcher\.bat|mwstv4\.ps1'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$LogDir = if ($ReportDir) { $ReportDir } else { Join-Path $ScriptDir 'Logs' }

# --- Fleet helpers ----------------------------------------------------------
foreach ($lib in @('MWST.Remote.ps1', 'MWST.KioskList.ps1', 'MWST.LegacyLauncher.ps1')) {
    $p = Join-Path $FleetRoot "Lib\$lib"
    if (-not (Test-Path -LiteralPath $p)) { throw "Fleet library not found: $p. Point -FleetRoot at the fleet tools." }
    . $p
}

# --- Arguments ----------------------------------------------------------------
if ($Rollback -and $Command) { throw '-Rollback and -Command cannot be combined.' }
$RemoteRoots = $RootTemplate.StartsWith('\\')
if ($Restart -and -not $RemoteRoots) { throw '-Restart needs real kiosks (-RootTemplate is for testing).' }
if ($Command -and $Restart) { throw '-Command and -Restart cannot be combined.' }
if ($Instance -and -not $Command) { throw '-Instance goes with -Command.' }
if (-not $Hosts -and -not $AllMach2Kiosks) { throw 'Name the kiosks with -Hosts, or use -AllMach2Kiosks for the whole list.' }
if ($Hosts -and $AllMach2Kiosks) { throw 'Use -Hosts or -AllMach2Kiosks, not both.' }

if ($RemoteRoots -and -not $Credential -and -not $CredentialFile) {
    $default = Join-Path $FleetRoot 'Config\kiosk-admin.cred.xml'
    if (Test-Path -LiteralPath $default) { $CredentialFile = $default }
}
if ($CredentialFile -and -not $Credential) { $Credential = Import-StoredCredential -Path $CredentialFile }

# Loaded now rather than on first use: loading a module under -WhatIf only
# reports the aliases it would have made, and then they are missing.
if ($RemoteRoots) {
    $savedWhatIf = $WhatIfPreference
    $WhatIfPreference = $false
    try { Import-Module CimCmdlets, ScheduledTasks -ErrorAction SilentlyContinue } finally { $WhatIfPreference = $savedWhatIf }
}

foreach ($f in $PayloadFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $f))) { throw "Missing from ${SourceDir}: $f" }
}
$tokens = $null; $parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceDir 'Mach2LauncherNG.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "Mach2LauncherNG.ps1 does not parse - not deploying it: $($parseErrors[0].Message) (line $($parseErrors[0].Extent.StartLineNumber))" }
$LauncherVersion = ''
if ((Get-Content -LiteralPath (Join-Path $SourceDir 'Mach2LauncherNG.ps1') -TotalCount 200) -join "`n" -match "\`$LauncherVersion = '([^']+)'") { $LauncherVersion = $Matches[1] }

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
        if ([string]$row.Type -notmatch '^\s*MACH') { continue }
        if ($row.Active -and $row.Active.Trim().ToUpperInvariant().StartsWith('N')) { Write-Host ("Skipping {0}: ACTIVE = {1}." -f $row.Host, $row.Active) -ForegroundColor DarkGray; continue }
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
    # Copy under a temporary name, verify, swap into place in one step; keep
    # the previous copy. Returns UPDATED, UP_TO_DATE or WHATIF.
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
    finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
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

function ConvertTo-KioskPath {
    # \\HOST\C$\x or <test root>\x -> C:\x, for what the kiosk itself sees.
    param([string]$Path, [string]$Root)
    return ('C:' + $Path.Substring($Root.Length))
}

function ConvertFrom-KioskPath {
    param([string]$Path, [string]$Root)
    return (Join-Path $Root ($Path -replace '^[A-Za-z]:\\', ''))
}

$script:Shell = New-Object -ComObject WScript.Shell

function Get-ShortcutTarget {
    param([string]$Path)
    try {
        $lnk = $script:Shell.CreateShortcut($Path)
        return ('{0} {1}' -f $lnk.TargetPath, $lnk.Arguments)
    }
    catch { return '' }
}

function New-LauncherShortcut {
    # Built locally, then copied: the target is the kiosk's own path.
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$InstanceName, [string]$ExtraArguments = '')
    $lnk = $script:Shell.CreateShortcut($Path)
    $lnk.TargetPath = 'C:\Windows\System32\conhost.exe'
    $lnk.Arguments = ('"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\Mach2LauncherNG.ps1" -Instance {1}{2}' -f $InstallLocal, $InstanceName, $(if ($ExtraArguments) { " $ExtraArguments" } else { '' }))
    $lnk.WorkingDirectory = $InstallLocal
    $lnk.WindowStyle = 7
    $lnk.Description = "Mach2 Launcher ver $LauncherVersion - the Mach2 dashboard on screen $InstanceName, and the kiosk's watchdog"
    $lnk.Save()
}

function Find-LegacyInstall {
    # The old launcher's configs for this kiosk (one per screen), and what
    # its StartupLauncher starts besides Mach2 launchers.
    param([string]$Root, [string]$HostName)

    $screens = [ordered]@{}
    foreach ($rel in $LegacyRoots) {
        $base = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $base -Directory -Filter 'Launcher S*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($dir.Name -notmatch '^Launcher (S\d+)$') { continue }
            $screen = $Matches[1].ToUpperInvariant()
            $p = Join-Path $dir.FullName "$HostName.json"
            # Renamed by an earlier deploy: still where its settings come from.
            if (-not (Test-Path -LiteralPath $p)) { $retired = Find-RetiredLegacyJson -Path $p; if ($retired) { $p = $retired } }
            # A config only counts next to Mach2Launcher.exe: other launchers
            # use the same file name.
            if ((Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath (Join-Path $dir.FullName 'Mach2Launcher.exe')) -and -not $screens.Contains($screen)) {
                $screens[$screen] = $p
            }
        }
    }

    $startupJson = $null
    foreach ($rel in $LegacyRoots) {
        foreach ($name in @("$HostName.json", 'startup.json')) {
            $p = Join-Path $Root "$rel\StartupLauncher\$name"
            if (Test-Path -LiteralPath $p) { $startupJson = $p; break }
        }
        if ($startupJson) { break }
    }
    $others = @()
    if ($startupJson) {
        try {
            $sj = @(Read-JsonFile -Path $startupJson)[0]
            foreach ($n in 1..4) {
                $pathProp = $sj.PSObject.Properties["LauncherPath$n"]
                $nameProp = $sj.PSObject.Properties["LauncherName$n"]
                if (-not $pathProp -or -not $nameProp -or -not $pathProp.Value -or -not $nameProp.Value) { continue }
                if ([string]$nameProp.Value -like 'Mach2Launcher*') { continue }
                $local = Join-Path ([string]$pathProp.Value) ([string]$nameProp.Value)
                if (Test-Path -LiteralPath (ConvertFrom-KioskPath -Path $local -Root $Root)) { $others += $local }
            }
        }
        catch { $others += "(could not read $startupJson)" }
    }
    return [pscustomobject]@{ Screens = $screens; StartupJson = $startupJson; OtherLaunchers = $others }
}

function Find-StartupFolder {
    # The kiosk account's Startup folder, and the old launcher's and the old
    # watchdog's shortcuts in it or in the all-users Startup folder.
    param([string]$Root, [string]$HostName)

    $legacyLinks = @(); $watchdogLinks = @(); $candidates = @()
    $usersDir = Join-Path $Root 'Users'
    $folders = @()
    foreach ($u in @(Get-ChildItem -LiteralPath $usersDir -Directory -ErrorAction SilentlyContinue)) {
        $sf = Join-Path $u.FullName $StartupRel
        if (Test-Path -LiteralPath $sf) { $folders += [pscustomobject]@{ User = $u.Name; Path = $sf } }
    }
    $folders += [pscustomobject]@{ User = ''; Path = (Join-Path $Root $AllUsersStartupRel) }
    foreach ($f in $folders) {
        foreach ($l in @(Get-ChildItem -LiteralPath $f.Path -File -ErrorAction SilentlyContinue)) {
            $disabled = $l.Name -like "*$DisabledSuffix"
            # Our own shortcut says whose Startup folder it is, once the old
            # one is disabled.
            if (-not $disabled -and $l.Name -like "$ShortcutPrefix*.lnk") { if ($f.User) { $candidates += $f.User }; continue }
            if (-not $disabled -and $l.Extension -ne '.lnk') { continue }
            $target = if ($disabled) { '' } else { Get-ShortcutTarget $l.FullName }
            $isWatchdog = $l.Name -match '(?i)^MWST' -or $target -match $WatchdogPattern
            if ($isWatchdog) { $watchdogLinks += $l.FullName; continue }
            if ($disabled -or $target -match 'StartupLauncher|Mach2Launcher') {
                $legacyLinks += $l.FullName
                if ($f.User -and -not $disabled) { $candidates += $f.User }
            }
        }
    }
    $user = if ($KioskUser) { $KioskUser }
    elseif (@($candidates | Select-Object -Unique).Count -eq 1) { $candidates[0] }
    else { $HostName }
    $profileDir = Join-Path $usersDir $user
    return [pscustomobject]@{
        User = $user; ProfileExists = (Test-Path -LiteralPath $profileDir); Folder = (Join-Path $profileDir $StartupRel)
        LegacyLinks = $legacyLinks; WatchdogLinks = $watchdogLinks
    }
}

function ConvertFrom-LegacyConfig {
    # The old settings the new launcher uses, without the password.
    param($Legacy, [string]$SourcePath, [string]$HostName, [bool]$Watchdog)

    $keep = @('LoginURL', 'DisplayURL', 'UserName', 'UsernameFieldName', 'PasswordFieldName', 'LoginButtonID',
        'ZoomPercent', 'UsePriScreen', 'ScreenSelect', 'KioskMode', 'ForcedRefreshTime', 'EnableRefresh', 'BrowserRefreshDelay',
        'ScheduledRestartEnabled', 'ScheduledRestartTime', 'RestartDelay', 'StartupDelay', 'LogPath', 'RemoteLogPath', 'LogName', 'DebugLogging')
    $out = [ordered]@{
        ConfigVersion = '1.00NG'
        MigratedFrom  = ('{0} on {1:yyyy-MM-dd}' -f $SourcePath, (Get-Date))
    }
    foreach ($k in $keep) {
        $p = $Legacy.PSObject.Properties[$k]
        if ($p) { $out[$k] = $p.Value }
    }
    $out['DisableStartup'] = '0'
    $out['Watchdog'] = $(if ($Watchdog) { '1' } else { '0' })
    # The new launcher stops the old one for its screen when it finds it
    # running - unless the old one is being kept on purpose (-KeepLegacy).
    $out['StopOldLauncher'] = $(if ($KeepLegacy) { '0' } else { '1' })
    # The same central folder, a new file name, so old and new logs are told
    # apart at a glance.
    $name = if ($out.Contains('LogName') -and $out['LogName']) { [string]$out['LogName'] } else { "Mach2Launcher_$HostName.log" }
    if ($name -notmatch 'Mach2LauncherNG') {
        $new = $name -replace 'Mach2Launcher', 'Mach2LauncherNG'
        if ($new -eq $name) { $new = "Mach2LauncherNG_$name" }
        $name = $new
    }
    $out['LogName'] = $name
    return $out
}

function Set-JsonFlag {
    # Flips "Key": "x" in place, keeping the rest of the file as it is.
    param([string]$Path, [string]$Key, [string]$Value)
    $text = Read-SharedText -Path $Path
    $pattern = '("' + [regex]::Escape($Key) + '"\s*:\s*)"[^"]*"'
    if ($text -notmatch $pattern) { throw "no $Key in $Path" }
    $new = [regex]::Replace($text, $pattern, ('${1}"' + $Value + '"'))
    if ($new -ceq $text) { return $false }
    if (-not $PSCmdlet.ShouldProcess($Path, "Set $Key = $Value")) { return $false }
    Invoke-Retry { Copy-Item -LiteralPath $Path -Destination "$Path.bak-$Stamp" -Force }
    [void](Write-TextFile -Path $Path -Text $new)
    return $true
}

function Move-ShortcutOut {
    <#
        Retires a Startup shortcut by moving it out of the Startup folder, to
        <install>\Retired shortcuts\<account>\, under its own name. Returns
        @{ From; To } as the kiosk sees them (for migration.json and the
        rollback), or $null under -WhatIf.

        Not renamed in place: Windows opens everything in a Startup folder at
        logon whatever it is called, and a "StartupLauncher.exe.lnk.disabled"
        is opened with a "Select an app to open this file" dialog on top of
        the dashboard - which is what 1.00NG left behind. A file still
        carrying that old suffix is moved out the same way, under its real
        name, which is how a redeploy clears it.
    #>
    param([string]$Path, [string]$Root, [string]$Target)

    $leaf = Split-Path -Leaf $Path
    $name = if ($leaf -like "*$DisabledSuffix") { $leaf.Substring(0, $leaf.Length - $DisabledSuffix.Length) } else { $leaf }
    $folder = Split-Path -Parent $Path
    $usersPrefix = (Join-Path $Root 'Users') + '\'
    $owner = if ($folder.StartsWith($usersPrefix, [StringComparison]::OrdinalIgnoreCase)) { $folder.Substring($usersPrefix.Length).Split('\')[0] } else { 'All Users' }
    $destDir = Join-Path $Target "$RetiredRel\$owner"
    $dest = Join-Path $destDir $name
    if (-not $PSCmdlet.ShouldProcess($Path, "Move out of the Startup folder to $(ConvertTo-KioskPath -Path $destDir -Root $Root)")) { return $null }
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    # Retired before and back again (the logon script copies it back): the
    # two are the same shortcut, so the newer one simply takes the place.
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
    Invoke-Retry { Move-Item -LiteralPath $Path -Destination $dest }
    return [pscustomobject]@{
        From = ConvertTo-KioskPath -Path (Join-Path $folder $name) -Root $Root
        To   = ConvertTo-KioskPath -Path $dest -Root $Root
    }
}

function Get-RecordList {
    <#
        A list from migration.json, as non-blank strings. Windows PowerShell
        writes an empty list as {} - an empty object - and read back that is
        one blank entry, which as a path is the kiosk's own C:\. 1.00NG's
        records have it wherever nothing was changed (TV4's old configs had
        no DisableStartup to set), so every list is read through this.
    #>
    param($Record, [string]$Name)
    if (-not $Record -or -not $Record.PSObject.Properties[$Name]) { return @() }
    return @(@($Record.$Name) | Where-Object { $_ -is [string] -and $_.Trim() })
}

function Merge-RetiredShortcuts {
    # The record so far plus this run's, one entry per original place.
    param($Previous, [array]$New)
    $byFrom = [ordered]@{}
    foreach ($e in @(@($Previous) + @($New) | Where-Object { $_ -and $_.From })) { $byFrom[[string]$e.From] = [pscustomobject]@{ From = [string]$e.From; To = [string]$e.To } }
    return @($byFrom.Values)
}

function Rename-Shortcut {
    param([string]$Path, [string]$NewName)
    if (-not $PSCmdlet.ShouldProcess($Path, "Rename to $NewName")) { return $false }
    $dest = Join-Path (Split-Path -Parent $Path) $NewName
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
    Invoke-Retry { Rename-Item -LiteralPath $Path -NewName $NewName }
    return $true
}

function Set-WatchdogTasks {
    <#
        -Enable $false: disables every enabled task that starts the old
        watchdog (its action runs MWSTv*_Launcher.bat or mwstv4.ps1) and
        returns their full names - under -WhatIf, the ones it would have
        disabled, marked " (WhatIf)". -Enable $true: enables the named tasks
        again. Over CIM/DCOM, as the old watchdog's deploy registered them.
    #>
    param([string]$HostName, [bool]$Enable, [string[]]$Names = @())

    $done = @()
    $session = New-KioskCimSession -HostName $HostName -Credential $Credential -TimeoutSec 60
    try {
        if ($Enable) {
            foreach ($full in $Names) {
                $i = $full.LastIndexOf('\')
                $path = $full.Substring(0, $i + 1); $name = $full.Substring($i + 1)
                if (-not $PSCmdlet.ShouldProcess("$HostName $full", 'Enable task')) { $done += "$full (WhatIf)"; continue }
                $null = Enable-ScheduledTask -CimSession $session -TaskPath $path -TaskName $name -ErrorAction Stop
                $done += $full
            }
            return $done
        }
        foreach ($t in @(Get-ScheduledTask -CimSession $session -ErrorAction Stop)) {
            $actions = @($t.Actions | ForEach-Object { '{0} {1}' -f $_.Execute, $_.Arguments }) -join ' | '
            if ($actions -notmatch $WatchdogPattern -or $t.State -eq 'Disabled') { continue }
            $full = $t.TaskPath + $t.TaskName
            if (-not $PSCmdlet.ShouldProcess("$HostName $full", 'Disable task')) { $done += "$full (WhatIf)"; continue }
            $null = Disable-ScheduledTask -CimSession $session -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop
            $done += $full
        }
        return $done
    }
    finally { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue -WhatIf:$false }
}

function Send-DeployRestart {
    # Send-KioskRestart (Lib\MWST.Remote.ps1): Win32ShutdownTracker over
    # CIM/DCOM, recorded as planned, application: installation. Returns how
    # it went out; throws when it did not.
    param([string]$HostName, [string]$Comment)
    $send = Send-KioskRestart -HostName $HostName -Credential $Credential -WarningSeconds $RestartWarningSeconds `
                              -Comment $Comment -ReasonCode ([uint32]2147745794)
    if (-not $send.Sent) { throw $send.Detail }
    return $send.Via
}

function Read-LauncherStatus {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Read-JsonFile -Path $Path) } catch { return $null }
}

function Get-LastAgentStart {
    # The newest AGENT_START in the kiosk's ledger (the tail is enough).
    param([string]$Ledger)
    if (-not (Test-Path -LiteralPath $Ledger)) { return $null }
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $fs = New-Object IO.FileStream($Ledger, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $header = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)).ReadLine()
        [void]$fs.Seek([math]::Max([long]0, $fs.Length - 131072), [IO.SeekOrigin]::Begin)
        $text = (New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8, $true)).ReadToEnd()
    }
    finally { $fs.Dispose() }
    $lines = @($text -split "`r?`n" | Where-Object { $_ -like '*"AGENT_START"*' })
    if (-not $header -or $lines.Count -eq 0) { return $null }
    return @(ConvertFrom-Csv -InputObject $lines[-1] -Header ($header -split ','))[0]
}

function Wait-DashboardShowing {
    <#
        After a restart: waits for every instance to report SHOWING from a
        run that started after the restart (a new PID or start time), and
        for the watchdog's AGENT_START with its console hidden. A state that
        needs a person ends the wait early.
    #>
    param([string]$HostName, [hashtable]$StatusPaths, [hashtable]$Before, [string]$Ledger)

    $deadline = (Get-Date).AddMinutes($VerifyMinutes)
    $wentDown = $false
    $last = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        if (-not (Test-HostReachable -HostName $HostName -TimeoutMs 1000).Ok) { $wentDown = $true; $last = 'offline (restarting)'; continue }
        $states = @()
        $allShowing = $true
        $stop = ''
        foreach ($inst in ($StatusPaths.Keys | Sort-Object)) {
            $st = Read-LauncherStatus -Path $StatusPaths[$inst]
            $b = $Before[$inst]
            if (-not $st) { $states += "${inst}: no status yet"; $allShowing = $false; continue }
            $isNew = -not $b -or $st.StartedUtc -ne $b.StartedUtc -or $st.Pid -ne $b.Pid
            if (-not $isNew) { $states += "${inst}: waiting for the restart"; $allShowing = $false; continue }
            $states += ("{0}: {1} {2}" -f $inst, $st.State, $st.Detail).Trim()
            if ($st.State -ne 'SHOWING') { $allShowing = $false }
            if ($st.State -in @('SIGNIN_BLOCKED', 'DISABLED', 'UNSUPERVISED')) { $stop = "${inst}: $($st.State) $($st.Detail)" }
        }
        $last = $states -join '; '
        if ($stop) { return [pscustomobject]@{ Ok = $false; Detail = $stop } }
        if (-not $allShowing) { continue }

        $start = Get-LastAgentStart -Ledger $Ledger
        if (-not $start -or $start.AgentVersion -notmatch 'NG$') { $last = "$last; no AGENT_START from the new launcher in the ledger yet"; continue }
        $console = if ("$($start.Detail)" -match 'Console=([^,;\s]+)') { $Matches[1] } else { '' }
        $window = if ("$($start.Detail)" -match 'Window=([^,;\s]+)') { $Matches[1] } else { '' }
        if ($window -in @('not-hideable', 'visible')) {
            return [pscustomobject]@{ Ok = $false; Detail = "dashboard SHOWING, but the launcher's console window is on screen (Console=$console, Window=$window). Set the kiosk account's default terminal to Windows Console Host." }
        }
        $note = if ($console -and $console -ne 'conhost') { " (Console=$console)" } else { '' }
        return [pscustomobject]@{ Ok = $true; Detail = ("SHOWING on {0}; watchdog v{1} running, Window={2}{3}" -f (($StatusPaths.Keys | Sort-Object) -join ', '), $start.AgentVersion, $window, $note) }
    }
    if (-not $wentDown) { $last = "never went offline - did it restart? Last: $last" }
    return [pscustomobject]@{ Ok = $false; Detail = "not SHOWING after $VerifyMinutes min: $last" }
}

# --- Run ------------------------------------------------------------------------
$action = if ($Rollback) { 'Rollback' } elseif ($Command) { "Command $Command" } else { 'Install' }
Write-Host ("Mach2 Launcher ver {0} (deploy ver {1}) - {2} on {3} kiosk(s){4}" -f $LauncherVersion, $DeployVersion, $action, $targets.Count, $(if ($WhatIfPreference) { ' (WhatIf)' } else { '' }))
if ($Credential) { Write-Host "Admin share as $($Credential.UserName)" -ForegroundColor DarkGray }

$results = New-Object System.Collections.Generic.List[object]
$halted = $false

foreach ($t in $targets) {
    $h = $t.Host
    $r = [pscustomobject]@{
        Host = $h; Location = $t.Location; Action = $action; Result = ''; Instances = ''; Files = ''; Config = ''; Password = ''
        Startup = ''; Legacy = ''; Watchdog = ''; Restart = ''; Verified = ''; Detail = ''
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
        $ledger = Join-Path $root "$PublicRel\mwst_events.csv"
        $existing = @()
        if (Test-Path -LiteralPath $target) {
            # { $_.Name }, not "ForEach-Object Name": under -WhatIf that form
            # asks ShouldProcess and returns nothing, and a dry run would not
            # see the screens already installed.
            $existing = @(Get-ChildItem -LiteralPath $target -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "$h.json") } | ForEach-Object { $_.Name })
        }

        # --- -Command ----------------------------------------------------------
        if ($Command) {
            if (-not (Test-Path -LiteralPath (Join-Path $target 'Mach2LauncherNG.ps1'))) { $r.Result = 'NOT_INSTALLED'; continue }
            $which = if ($Instance) { @($Instance) } else { $existing }
            if ($which.Count -eq 0) { $r.Result = 'NOT_INSTALLED'; $r.Detail = 'no instance folders'; continue }
            $states = @()
            foreach ($i in $which) {
                $dir = Join-Path $target $i
                if (-not (Test-Path -LiteralPath $dir)) { $notes.Add("no instance $i"); continue }
                if ($Command -eq 'Resume') {
                    $hold = Join-Path $dir 'hold.txt'
                    if ((Test-Path -LiteralPath $hold) -and $PSCmdlet.ShouldProcess($hold, 'Delete')) { Remove-Item -LiteralPath $hold -Force }
                }
                else {
                    $file = @{ Stop = 'kill.txt'; Refresh = 'refresh.txt'; Relaunch = 'relaunch.txt'; Hold = 'hold.txt'; Snapshot = 'snapshot.txt' }[$Command]
                    [void](Write-TextFile -Path (Join-Path $dir $file) -Text ("{0} by {1}\{2}" -f (Get-Date -Format s), $env:USERDOMAIN, $env:USERNAME) -Action 'Create')
                }
                $st = Read-LauncherStatus -Path (Join-Path $dir "Status\$i.status.json")
                if ($st) { $states += "$i was $($st.State)" }
            }
            $r.Instances = $which -join ','
            $r.Result = 'SENT'
            if ($states.Count) { $r.Detail = $states -join '; ' }
            continue
        }

        $legacy = Find-LegacyInstall -Root $root -HostName $h
        $startup = Find-StartupFolder -Root $root -HostName $h

        # --- -Rollback --------------------------------------------------------
        if ($Rollback) {
            $m = $null
            if (Test-Path -LiteralPath $migrationPath) { $m = Read-JsonFile -Path $migrationPath }

            # The shortcuts the install recorded, wherever they are (the
            # kiosk account may not be named after the PC), and any in the
            # account's Startup folder.
            $linkPaths = @()
            $linkPaths += @(Get-RecordList -Record $m -Name 'Shortcuts' | ForEach-Object { ConvertFrom-KioskPath -Path $_ -Root $root })
            if (Test-Path -LiteralPath $startup.Folder) {
                $linkPaths += @(Get-ChildItem -LiteralPath $startup.Folder -Filter "$ShortcutPrefix*.lnk" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            }
            $removed = 0
            foreach ($lp in @($linkPaths | Select-Object -Unique)) {
                if ((Test-Path -LiteralPath $lp) -and $PSCmdlet.ShouldProcess($lp, 'Delete')) { Remove-Item -LiteralPath $lp -Force; $removed++ }
            }
            $r.Startup = "removed $removed"

            $restored = 0
            # Retired shortcuts go back where they came from. One that is
            # there already (the logon script copies StartupLauncher back)
            # only needs our copy removed.
            if ($m -and $m.PSObject.Properties['RetiredShortcuts']) {
                foreach ($rs in @($m.RetiredShortcuts | Where-Object { $_ -and $_.From -and $_.To })) {
                    $to = ConvertFrom-KioskPath -Path ([string]$rs.To) -Root $root
                    $from = ConvertFrom-KioskPath -Path ([string]$rs.From) -Root $root
                    if (-not (Test-Path -LiteralPath $to)) { continue }
                    if (Test-Path -LiteralPath $from) {
                        if ($PSCmdlet.ShouldProcess($to, 'Delete (the shortcut is back in the Startup folder already)')) { Remove-Item -LiteralPath $to -Force; $restored++ }
                        continue
                    }
                    if ($PSCmdlet.ShouldProcess($to, "Move back to $([string]$rs.From)")) {
                        $dir = Split-Path -Parent $from
                        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                        Invoke-Retry { Move-Item -LiteralPath $to -Destination $from }
                        $restored++
                    }
                }
            }
            # Renamed in place by 1.00NG.
            foreach ($l in @(@($startup.LegacyLinks) + @($startup.WatchdogLinks) | Where-Object { $_ -like "*$DisabledSuffix" })) {
                $leaf = Split-Path -Leaf $l
                if (Rename-Shortcut -Path $l -NewName $leaf.Substring(0, $leaf.Length - $DisabledSuffix.Length)) { $restored++ }
            }
            $reverted = 0
            $legacyChanged = @()
            $legacyChanged = @(Get-RecordList -Record $m -Name 'LegacyConfigsDisabled')
            foreach ($lc in $legacyChanged) {
                $unc = ConvertFrom-KioskPath -Path ([string]$lc) -Root $root
                if ((Test-Path -LiteralPath $unc) -and (Set-JsonFlag -Path $unc -Key 'DisableStartup' -Value '0')) { $reverted++ }
            }
            $renamedBack = 0
            if ($m -and $m.PSObject.Properties['LegacyJsonRenamed']) { $renamedBack = Undo-LegacyJsonRenames -Root $root -Records @($m.LegacyJsonRenamed) -Cmdlet $PSCmdlet }
            $r.Legacy = "shortcuts restored $restored, configs re-enabled $reverted, JSON renamed back $renamedBack"

            $tasks = @()
            $tasks = @(Get-RecordList -Record $m -Name 'WatchdogTasksDisabled')
            if ($tasks.Count -eq 0) { $r.Watchdog = 'no task to re-enable' }
            elseif (-not $RemoteRoots) { $r.Watchdog = "task(s) not re-enabled (test root): $($tasks -join ', ')" }
            else {
                try { $r.Watchdog = 'task re-enabled: ' + ((Set-WatchdogTasks -HostName $h -Enable $true -Names $tasks) -join ', ') }
                catch { $r.Watchdog = 'FAILED to re-enable the task'; $notes.Add("watchdog task: $($_.Exception.Message) - enable $($tasks -join ', ') by hand") }
            }
            if ($restored -eq 0 -and $reverted -eq 0 -and $renamedBack -eq 0 -and $tasks.Count -eq 0) { $notes.Add('nothing of the old launcher or watchdog to restore - was it retired by this script?') }

            foreach ($i in $existing) {
                [void](Write-TextFile -Path (Join-Path $target "$i\kill.txt") -Text 'rollback' -Action 'Create')
            }
            $r.Instances = $existing -join ','
            if ($existing.Count) { $r.Files = 'kept (launcher told to stop)' }
            if ($m -and $PSCmdlet.ShouldProcess($migrationPath, 'Mark as rolled back')) {
                Move-Item -LiteralPath $migrationPath -Destination "$migrationPath.rolledback-$Stamp" -Force
            }
            $r.Result = if ($WhatIfPreference) { 'WHATIF' } else { 'ROLLED_BACK' }
        }
        # --- Install -------------------------------------------------------------
        else {
            $plan = [ordered]@{}
            foreach ($screen in $legacy.Screens.Keys) { $plan[$screen] = $legacy.Screens[$screen] }
            foreach ($i in $existing) { if (-not $plan.Contains($i)) { $plan[$i] = $null } }
            # One launcher per screen: a screen PBI Launcher or Web Launcher
            # has now is theirs, whatever the old launcher ran there.
            $owners = Get-ScreenOwners -Root $root -HostName $h
            foreach ($s in @($plan.Keys)) {
                if ($owners.ContainsKey($s) -and $owners[$s] -ne 'MACH2') {
                    $notes.Add("$s belongs to $($ScreenLauncherTitles[$owners[$s]]) on this kiosk - not set up for Mach2")
                    $plan.Remove($s)
                }
            }
            if ($plan.Count -eq 0) {
                $r.Result = 'NO_CONFIG'
                $r.Detail = "no old Mach2 launcher to copy settings from. Put $h.json (from EXAMPLE.json) in $InstallLocal\S1 and run again."
                continue
            }
            if (-not $startup.ProfileExists) {
                $r.Result = 'FAILED'
                $r.Detail = "no profile for kiosk account '$($startup.User)' on this kiosk - has it ever signed in? Use -KioskUser."
                continue
            }
            $instances = @($plan.Keys | Sort-Object)
            $watchdogInstance = $instances[0]
            $r.Instances = ($instances -join ',') + " (watchdog: $watchdogInstance)"

            if (-not (Test-Path -LiteralPath $target) -and $PSCmdlet.ShouldProcess($target, 'Create folder')) { New-Item -ItemType Directory -Path $target -Force | Out-Null }

            # files
            $fileResults = @()
            if (Test-Path -LiteralPath $target) {
                foreach ($f in $PayloadFiles) { $fileResults += Install-File -Source (Join-Path $SourceDir $f) -Destination (Join-Path $target $f) }
            }
            else { $fileResults = @('WHATIF') }
            $r.Files = if ($fileResults -contains 'WHATIF') { 'WHATIF' } elseif ($fileResults -contains 'UPDATED') { 'UPDATED' } else { 'UP_TO_DATE' }

            # instances: config, password, shortcut
            $configResults = @(); $pwResults = @(); $links = @()
            foreach ($i in $instances) {
                $dir = Join-Path $target $i
                if (-not (Test-Path -LiteralPath $dir) -and $PSCmdlet.ShouldProcess($dir, 'Create folder')) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $configPath = Join-Path $dir "$h.json"
                $legacyPath = $plan[$i]
                $legacyConfig = $null
                if ($legacyPath) {
                    try { $legacyConfig = @(Read-JsonFile -Path $legacyPath)[0] }
                    catch { $notes.Add("${i}: old config unreadable: $($_.Exception.Message)") }
                }
                $haveConfig = Test-Path -LiteralPath $configPath
                if ($haveConfig -and (-not $UpdateConfig -or -not $legacyConfig)) { $configResults += "${i}:KEPT" }
                elseif ($legacyConfig) {
                    $newCfg = ConvertFrom-LegacyConfig -Legacy $legacyConfig -SourcePath (ConvertTo-KioskPath -Path $legacyPath -Root $root) -HostName $h -Watchdog ($i -eq $watchdogInstance)
                    if ($haveConfig -and $PSCmdlet.ShouldProcess($configPath, 'Back up')) { Invoke-Retry { Copy-Item -LiteralPath $configPath -Destination "$configPath.bak-$Stamp" -Force } }
                    $written = if (Test-Path -LiteralPath $dir) { Write-TextFile -Path $configPath -Text (ConvertTo-Json -InputObject ([pscustomobject]$newCfg)) } else { $false }
                    $configResults += $(if ($written) { "${i}:FROM_OLD_LAUNCHER" } else { "${i}:WHATIF" })
                }
                else { $configResults += "${i}:NONE" }

                # password
                $credPath = Join-Path $dir "$h.cred"
                $seedPath = Join-Path $dir 'password.seed'
                $seed = $null
                if ($SignInCredential) { $seed = $SignInCredential.GetNetworkCredential().Password; $pwResults += "${i}:SEED_FROM_PARAMETER" }
                elseif (Test-Path -LiteralPath $credPath) { $pwResults += "${i}:ALREADY_STORED" }
                elseif (Test-Path -LiteralPath $seedPath) { $pwResults += "${i}:SEED_WAITING" }
                elseif ($legacyConfig -and $legacyConfig.PSObject.Properties['Password'] -and $legacyConfig.Password) { $seed = [string]$legacyConfig.Password; $pwResults += "${i}:SEED_FROM_OLD_LAUNCHER" }
                else { $pwResults += "${i}:NONE"; $notes.Add("${i}: no password to hand over - run again with -SignInCredential") }
                if ($seed) {
                    if (-not (Test-Path -LiteralPath $dir) -or -not (Write-TextFile -Path $seedPath -Text $seed -Action 'Write password.seed')) { $pwResults[-1] = "${i}:WHATIF" }
                    $seed = $null
                }

                # startup shortcut
                $newLink = Join-Path $startup.Folder "$ShortcutPrefix$i.lnk"
                if ($PSCmdlet.ShouldProcess($newLink, 'Create startup shortcut')) {
                    if (-not (Test-Path -LiteralPath $startup.Folder)) { New-Item -ItemType Directory -Path $startup.Folder -Force | Out-Null }
                    $tmpLink = Join-Path $env:TEMP "Mach2LauncherNG-$Stamp-$i.lnk"
                    New-LauncherShortcut -Path $tmpLink -InstanceName $i
                    Invoke-Retry { Copy-Item -LiteralPath $tmpLink -Destination $newLink -Force }
                    Remove-Item -LiteralPath $tmpLink -Force
                    $links += ConvertTo-KioskPath -Path $newLink -Root $root
                }
            }
            $r.Config = $configResults -join ' '
            $r.Password = $pwResults -join ' '
            $r.Startup = if ($links.Count) { "for $($startup.User): $($links.Count) shortcut(s)" } else { 'WHATIF' }

            # retire the old launcher
            #
            # Its StartupLauncher shortcut leaves the Startup folder. On most
            # Mach2 kiosks Mach2LauncherShortcuts.ps1 copies it back at every
            # logon, and the old launcher has no setting that keeps it off -
            # its configs have no DisableStartup - so what really keeps it
            # off is the new launcher, which stops the old one for its screen
            # whenever it finds it running (StopOldLauncher, 1.01NG).
            $prevRecord = $null
            if (Test-Path -LiteralPath $migrationPath) { try { $prevRecord = Read-JsonFile -Path $migrationPath } catch {} }
            $prevRetired = @()
            if ($prevRecord -and $prevRecord.PSObject.Properties['RetiredShortcuts']) { $prevRetired = @($prevRecord.RetiredShortcuts) }
            $retired = @(); $disabled = @(); $jsonRenamed = @(); $cleared = 0; $legacyRetired = 0
            # Left in a Startup folder by 1.00NG: renamed, so Windows asks
            # what to open it with at every logon. Always cleared.
            foreach ($l in @(@($startup.LegacyLinks) + @($startup.WatchdogLinks) | Where-Object { $_ -like "*$DisabledSuffix" })) {
                $rec = Move-ShortcutOut -Path $l -Root $root -Target $target
                if ($rec) { $retired += $rec; $cleared++ }
            }
            if ($cleared) { $notes.Add("moved $cleared shortcut(s) that 1.00NG had renamed out of the Startup folder - they made Windows ask which app to open them with at logon") }

            if ($KeepLegacy) { $r.Legacy = 'kept (-KeepLegacy)' }
            else {
                if ($legacy.OtherLaunchers.Count -gt 0) {
                    $notes.Add("StartupLauncher also starts $($legacy.OtherLaunchers -join ', ') - its shortcut stays; the new launcher stops the old Mach2 launcher when it finds it running")
                }
                else {
                    foreach ($l in @($startup.LegacyLinks | Where-Object { $_ -notlike "*$DisabledSuffix" })) {
                        $kioskPath = ConvertTo-KioskPath -Path $l -Root $root
                        if (@($prevRetired | Where-Object { $_.From -eq $kioskPath }).Count) {
                            $notes.Add("$(Split-Path -Leaf $l) was retired before and is back - Mach2LauncherShortcuts.ps1 copies it back at logon. Harmless: the new launcher stops the old one when it finds it running.")
                        }
                        $rec = Move-ShortcutOut -Path $l -Root $root -Target $target
                        if ($rec) { $retired += $rec; $legacyRetired++ }
                    }
                }
                # The old configs are renamed: without <HOST>.json the old
                # launcher does not run, and the logon script
                # (Mach2LauncherShortcuts.ps1) makes no shortcut for it. Then
                # StartupLauncher's own configs, once it has nothing left to
                # start (Lib\MWST.LegacyLauncher.ps1).
                foreach ($screen in $legacy.Screens.Keys) {
                    if ($legacy.Screens[$screen] -match $LegacyDisabledPattern -or $screen -notin $instances) { continue }
                    try {
                        $to = Disable-LegacyJson -Path $legacy.Screens[$screen] -Tag 'Mach2LauncherNG' -Cmdlet $PSCmdlet
                        if ($to) { $jsonRenamed += [pscustomobject]@{ From = (ConvertTo-KioskPath -Path $legacy.Screens[$screen] -Root $root); To = (ConvertTo-KioskPath -Path $to -Root $root) } }
                    }
                    catch { $notes.Add("could not rename the old $screen config: $($_.Exception.Message)") }
                }
                try {
                    $sl = Invoke-RetireLegacyStartup -Root $root -HostName $h -Tag 'Mach2LauncherNG' -Cmdlet $PSCmdlet
                    $jsonRenamed += @($sl.Renamed)
                    foreach ($k in $sl.Kept) { $notes.Add("StartupLauncher kept: $k") }
                }
                catch { $notes.Add("could not retire StartupLauncher's config: $($_.Exception.Message)") }
                $r.Legacy = "screens $(@($legacy.Screens.Keys) -join ',' ); shortcuts retired $legacyRetired, JSON renamed $($jsonRenamed.Count)"
            }

            # retire the old watchdog
            $tasksOff = @(); $wdLinks = @()
            if ($KeepWatchdog) { $r.Watchdog = 'kept (-KeepWatchdog); the new launcher still stops it when it finds it running' }
            else {
                foreach ($l in @($startup.WatchdogLinks | Where-Object { $_ -notlike "*$DisabledSuffix" })) {
                    $rec = Move-ShortcutOut -Path $l -Root $root -Target $target
                    if ($rec) { $retired += $rec; $wdLinks += $rec.From }
                }
                if (-not $RemoteRoots) { $r.Watchdog = 'task not checked (test root)' }
                else {
                    try {
                        $tasksOff = @(Set-WatchdogTasks -HostName $h -Enable $false)
                        $r.Watchdog = if ($tasksOff.Count) { 'task disabled: ' + ($tasksOff -join ', ') } else { 'no enabled watchdog task' }
                    }
                    catch {
                        $r.Watchdog = 'task NOT disabled'
                        $notes.Add("watchdog task: $($_.Exception.Message) - the new launcher stops the old watchdog whenever it finds it running")
                    }
                }
                if ($wdLinks.Count) { $r.Watchdog += "; startup shortcut(s) retired $($wdLinks.Count)" }
            }

            # migration record, merged with any earlier one
            if (-not $WhatIfPreference) {
                $prev = $null
                if (Test-Path -LiteralPath $migrationPath) { try { $prev = Read-JsonFile -Path $migrationPath } catch {} }
                $merge = {
                    param([string]$Name, [array]$New)
                    if ($prev -and $prev.PSObject.Properties[$Name]) { return @(@(Get-RecordList -Record $prev -Name $Name) + $New | Where-Object { $_ -is [string] -and $_.Trim() } | Select-Object -Unique) }
                    return @($New)
                }
                $record = [ordered]@{
                    Host                    = $h
                    LauncherVersion         = $LauncherVersion
                    DeployedAt              = (Get-Date).ToString('s')
                    DeployedBy              = "$env:USERDOMAIN\$env:USERNAME"
                    KioskUser               = $startup.User
                    Instances               = $instances
                    WatchdogInstance        = $watchdogInstance
                    # @() around each: an empty list otherwise goes out as {}.
                    Shortcuts               = @(& $merge 'Shortcuts' $links)
                    LegacyConfigs           = @($legacy.Screens.Values | ForEach-Object { ConvertTo-KioskPath -Path $_ -Root $root })
                    # Where each retired shortcut came from and where it is now.
                    RetiredShortcuts        = @(Merge-RetiredShortcuts -Previous $prevRetired -New $retired)
                    # 1.00NG renamed shortcuts in place; kept for the record.
                    LegacyShortcutsDisabled = @(& $merge 'LegacyShortcutsDisabled' @())
                    LegacyConfigsDisabled   = @(& $merge 'LegacyConfigsDisabled' $disabled)
                    # Old launcher JSON renamed out of the way: {From; To}.
                    LegacyJsonRenamed       = @(Merge-RetiredShortcuts -Previous $(if ($prev -and $prev.PSObject.Properties['LegacyJsonRenamed']) { @($prev.LegacyJsonRenamed) } else { @() }) -New $jsonRenamed)
                    WatchdogTasksDisabled   = @(& $merge 'WatchdogTasksDisabled' @($tasksOff | Where-Object { $_ -notlike '*(WhatIf)' }))
                }
                [void](Write-TextFile -Path $migrationPath -Text (ConvertTo-Json -InputObject ([pscustomobject]$record)))
            }
            $r.Result = if ($WhatIfPreference) { 'WHATIF' } else { 'INSTALLED' }
        }

        # --- restart and verify ------------------------------------------------------
        if ($Restart -and -not $WhatIfPreference) {
            $statusPaths = @{}; $before = @{}
            foreach ($i in @(if ($Rollback) { @() } else { $instances })) {
                $statusPaths[$i] = Join-Path $target "$i\Status\$i.status.json"
                $before[$i] = Read-LauncherStatus -Path $statusPaths[$i]
            }
            $comment = if ($Rollback) { 'IT is switching this screen back to the previous Mach2 launcher. It will come back on its own. [MACH2-LAUNCHER-NG deploy]' }
            else { 'IT is updating the Mach2 screen launcher. It will come back on its own. [MACH2-LAUNCHER-NG deploy]' }
            try {
                $via = Send-DeployRestart -HostName $h -Comment $comment
                $r.Restart = "sent ($via)"
            }
            catch {
                $r.Restart = 'FAILED'
                $r.Result = 'FAILED'
                $notes.Add("restart: $($_.Exception.Message)")
                $halted = $true
                continue
            }
            if ($Rollback) { $r.Verified = 'not checked (old launcher)' }
            else {
                Write-Host ("  restarting, waiting up to {0} min for the dashboard..." -f $VerifyMinutes) -ForegroundColor DarkGray
                $v = Wait-DashboardShowing -HostName $h -StatusPaths $statusPaths -Before $before -Ledger $ledger
                $r.Verified = $v.Detail
                if ($v.Ok) { $r.Result = 'VERIFIED' }
                else {
                    $r.Result = 'FAILED'
                    $halted = $true
                }
                try {
                    $s = New-KioskCimSession -HostName $h -Credential $Credential -TimeoutSec 20
                    try {
                        $findOld = {
                            @(Get-CimInstance -CimSession $s -ClassName Win32_Process -Filter "Name = 'Mach2Launcher.exe' OR Name = 'powershell.exe'" |
                                Where-Object { $_.Name -eq 'Mach2Launcher.exe' -or $_.CommandLine -match $WatchdogPattern })
                        }
                        # Something at logon may start them again; the new
                        # launcher stops both within seconds of finding them.
                        # Only what is still there a little later is news.
                        $running = @(& $findOld)
                        if ($running.Count) { Start-Sleep -Seconds 45; $running = @(& $findOld) }
                        if ($running.Count) { $notes.Add('still running after the restart: ' + (($running | ForEach-Object { if ($_.Name -eq 'Mach2Launcher.exe') { 'the OLD Mach2Launcher.exe' } else { 'the OLD watchdog' } }) -join ', ') + ' - the new launcher did not stop it within a minute; is StopOldLauncher 0 in its config?') }
                    }
                    finally { Remove-CimSession $s -ErrorAction SilentlyContinue }
                }
                catch {}
            }
        }
        elseif (-not $Restart -and -not $WhatIfPreference -and $r.Result -in @('INSTALLED', 'ROLLED_BACK')) {
            $notes.Add('takes effect at the next logon or restart (-Restart to do it now)')
            if ($r.Result -eq 'INSTALLED' -and $r.Legacy -match 'JSON renamed [1-9]') {
                $notes.Add('WARNING: the old launcher now exits the next time it restarts itself, and the screen stays empty until the kiosk restarts - restart it soon')
            }
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
        Write-Host ("  {0,-12} screens={1} files={2}" -f $r.Result, $r.Instances, $r.Files) -ForegroundColor $color
        if ($r.Config -or $r.Password) { Write-Host ("  {0,-12} config={1} password={2} startup={3}" -f '', $r.Config, $r.Password, $r.Startup) -ForegroundColor DarkGray }
        if ($r.Legacy) { Write-Host ("  {0,-12} old launcher: {1}" -f '', $r.Legacy) -ForegroundColor DarkGray }
        if ($r.Watchdog) { Write-Host ("  {0,-12} old watchdog: {1}" -f '', $r.Watchdog) -ForegroundColor DarkGray }
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
    $report = Join-Path $LogDir "m2ng-deploy_$Stamp.csv"
    $results | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8
    Write-Host "Report: $report" -ForegroundColor DarkGray
}
if (@($results | Where-Object { $_.Result -in @('FAILED', 'HALTED') }).Count) { exit 1 }
