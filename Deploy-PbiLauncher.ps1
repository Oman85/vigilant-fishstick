#Requires -Version 5.1
<#
.SYNOPSIS
    Installs PBI Launcher 2.0 on Power BI kiosks over the admin share and
    retires the old PowerBILauncher.exe - or rolls that back.

.DESCRIPTION
    For each kiosk:

      1. checks it is reachable (ping, then SMB)
      2. finds the old launcher: <HOST>.json next to PowerBILauncher.exe in
         C:\Users\Public\Documents\Launchers\Launcher S<n>\ (1.0.0.14) or
         ...\Launcher S<n>\PowerBILauncher\ (1.0.0.11), or the same under
         ...\Mach2Launchers\. Launcher S<n> is screen S<n>.
      3. installs PbiLauncher.ps1, Start-PbiLauncher.cmd and EXAMPLE.json in
         C:\Users\Public\Documents\PbiLauncher. Hash-verified, the previous
         copy kept as .bak-<timestamp>, swapped into place in one step.
      4. one folder per screen (S1, S2, ...) with <HOST>.json from the old
         config - same report, user, screen, refresh and restart settings,
         same central log folder - but without the password. An existing new
         config is left alone unless -UpdateConfig is given. A screen that
         Mach2 Launcher NG or Web Launcher has is left to it. A kiosk from
         before the screen folders (config next to the script) has it moved
         into S1, with its password and status.
      5. if a screen has no encrypted password yet, writes password.seed
         (from -SignInCredential, else from the old config). The launcher
         encrypts it for the kiosk account on its next start and deletes it.
      6. puts "PBI Launcher S<n>.lnk" in the kiosk account's Startup folder,
         one per screen (and removes the single "PBI Launcher.lnk" of 2.0.0).
         It runs conhost.exe > powershell.exe -WindowStyle Hidden, so the
         console is the classic one and never shows.
      7. retires the old launcher, reversibly:
           - its StartupLauncher shortcut is moved out of the Startup folder
             into PbiLauncher\Retired shortcuts\<account>\ - unless that
             StartupLauncher also starts something other than Power BI, in
             which case it stays. Not renamed in place: Windows opens
             everything in a Startup folder at logon whatever it is called,
             and the first version's "*.disabled-by-PbiLauncher" made it ask
             which app to open the file with, over the report. Any such
             file still there is moved out too.
           - its JSON files are renamed (<HOST>.json.disabled-by-PbiLauncher):
             each moved screen's old config, so the old launcher does not
             run and the logon script (Mach2LauncherShortcuts.ps1) makes no
             shortcut for it; and StartupLauncher's own configs, once
             nothing it starts is still configured. The logon script puts
             the StartupLauncher shortcut back at every logon; without its
             config it starts nothing (Lib\MWST.LegacyLauncher.ps1).
         Everything changed is recorded in migration.json for -Rollback.

    The new launcher starts at the kiosk account's next logon. -Restart
    restarts each kiosk right away - one at a time - and waits until the
    launcher reports the report on screen (status SHOWING). The first kiosk
    that does not get there stops the run.

    -Rollback puts the old launcher back: its shortcut back in the Startup
    folder (from Retired shortcuts, or renamed back where the first version
    renamed it), its JSON files renamed back (and DisableStartup, which
    2.0.0 set), and the new launcher stopped (kill.txt) and its shortcuts
    removed. The installed files stay. Add -Restart to switch over at once.

    -Command sends one control file to running launchers: Stop (kill.txt),
    Refresh, Relaunch, Hold, or Resume (deletes hold.txt). -Instance picks
    one screen; the default is all of them.

    Targets: -Hosts, or -AllPbiKiosks for every Power BI kiosk in the master
    kiosk list that is not inactive and not "NO SCRIPT". The list and the
    admin-share helpers are the fleet tools' own (Lib\ next to this script).

    Every run writes Logs\deploy_<timestamp>.csv. Supports -WhatIf.

.PARAMETER Hosts
    Kiosks to work on, as a list or comma-separated. Start with one.

.PARAMETER AllPbiKiosks
    Every active Power BI kiosk in the kiosk list, except "NO SCRIPT" ones.

.PARAMETER KioskList
    Kiosk list to use with -AllPbiKiosks. Default: the SharePoint master,
    found the same way the fleet collector finds it.

.PARAMETER FleetRoot
    Folder holding the fleet tools' Lib\, Config\ and Tools\. Default: the
    folder this script is in.

.PARAMETER Credential
    Admin credential for the kiosks' C$ share.

.PARAMETER CredentialFile
    A credential saved by the fleet's Save-KioskCredential.ps1. Default:
    <FleetRoot>\Config\kiosk-admin.cred.xml when it exists and -Credential
    is not given.

.PARAMETER SignInCredential
    The Power BI account's password to hand to the launcher (as
    password.seed), for example after it was changed. Get-Credential with
    the account's e-mail address as the user name.

.PARAMETER KioskUser
    Windows account the kiosk signs in as. Default: the one whose Startup
    folder holds the old StartupLauncher, else the account named after the
    kiosk.

.PARAMETER UpdateConfig
    Rewrite <HOST>.json from the old config even if it already exists.

.PARAMETER KeepLegacy
    Install, but leave the old launcher as it is.

.PARAMETER Force
    Copy the launcher files even when the kiosk already has them.

.PARAMETER Restart
    Restart each kiosk after the change and wait for the result.

.PARAMETER RestartWarningSeconds
    Countdown shown on the kiosk before it restarts. Default 60.

.PARAMETER VerifyMinutes
    How long a restarted kiosk has to show the report. Default 12.

.PARAMETER Rollback
    Put the old launcher back (see above).

.PARAMETER Command
    Stop, Refresh, Relaunch, Hold, Resume or Snapshot the launchers on the
    kiosks. Snapshot makes each launcher save a screenshot to its Status\
    folder (see Get-PbiLauncherSnapshot in Show-FleetDashboard.ps1).

.PARAMETER Instance
    With -Command: the one screen (S1, S2, ...) to send it to.

.PARAMETER RootTemplate
    For testing only: a local folder that stands in for each kiosk's C:
    drive, such as C:\Temp\FakeKiosks\{0}.

.PARAMETER ReportDir
    Where the CSV report goes. Default: Logs next to this script.

.EXAMPLE
    .\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980 -WhatIf

.EXAMPLE
    .\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980 -Restart

.EXAMPLE
    .\Deploy-PbiLauncher.ps1 -AllPbiKiosks -Restart

.EXAMPLE
    .\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980 -SignInCredential (Get-Credential SHPowerBITopCZAPU1@shapecorp.com)

.EXAMPLE
    .\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980 -Rollback -Restart

.EXAMPLE
    .\Deploy-PbiLauncher.ps1 -Hosts SHCZ5KPI11980, SHCZ5KPI11982 -Command Refresh
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$Hosts,
    [switch]$AllPbiKiosks,
    [string]$KioskList,
    [string]$FleetRoot,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredentialFile,
    [System.Management.Automation.PSCredential]$SignInCredential,
    [string]$KioskUser,
    [switch]$UpdateConfig,
    [switch]$KeepLegacy,
    [switch]$Force,
    [switch]$Restart,
    [ValidateRange(0, 600)][int]$RestartWarningSeconds = 60,
    [ValidateRange(2, 60)][int]$VerifyMinutes = 12,
    [switch]$Rollback,
    [ValidateSet('Stop', 'Refresh', 'Relaunch', 'Hold', 'Resume', 'Snapshot')][string]$Command,
    [ValidatePattern('^[A-Za-z0-9_.-]*$')][string]$Instance,
    # For testing: a local folder standing in for each kiosk's C: drive, for
    # example C:\Temp\FakeKiosks\{0}. Reachability, restarts and the share
    # login are skipped for a local root.
    [string]$RootTemplate = '\\{0}\C$',
    [string]$ReportDir
)

# Off, like the fleet tools this script shares its libraries with.
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
if (-not $FleetRoot) { $FleetRoot = $ScriptDir }
$SourceDir = Join-Path $ScriptDir 'PbiLauncher'
$InstallRel = 'Users\Public\Documents\PbiLauncher'
$InstallLocal = "C:\$InstallRel"
$PayloadFiles = @('PbiLauncher.ps1', 'Start-PbiLauncher.cmd', 'EXAMPLE.json')
$LegacyRoots = @('Users\Public\Documents\Launchers', 'Users\Public\Documents\Mach2Launchers')
# 2.0.0's single shortcut; from 2.0.1 one per screen: 'PBI Launcher S1.lnk'.
$ShortcutName = 'PBI Launcher.lnk'
$ShortcutPrefix = 'PBI Launcher '
$DisabledSuffix = '.disabled-by-PbiLauncher'
# Where retired Startup shortcuts go, under the install folder: anywhere
# but a Startup folder, which Windows runs whatever the file is called.
$RetiredRel = 'Retired shortcuts'
$StartupRel = 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'
$AllUsersStartupRel = 'ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$LogDir = if ($ReportDir) { $ReportDir } else { Join-Path $ScriptDir 'Logs' }

# --- Fleet helpers ------------------------------------------------------------
foreach ($lib in @('MWST.Remote.ps1', 'MWST.KioskList.ps1', 'MWST.LegacyLauncher.ps1')) {
    $p = Join-Path $FleetRoot "Lib\$lib"
    if (-not (Test-Path -LiteralPath $p)) { throw "Fleet library not found: $p. Point -FleetRoot at the MWST fleet tools." }
    . $p
}

# --- Arguments ------------------------------------------------------------------
if ($Rollback -and $Command) { throw '-Rollback and -Command cannot be combined.' }
$RemoteRoots = $RootTemplate.StartsWith('\\')
if ($Restart -and -not $RemoteRoots) { throw '-Restart needs real kiosks (-RootTemplate is for testing).' }
if ($Command -and $Restart) { throw '-Command and -Restart cannot be combined.' }
if ($Instance -and -not $Command) { throw '-Instance goes with -Command.' }
if (-not $Hosts -and -not $AllPbiKiosks) { throw 'Name the kiosks with -Hosts, or use -AllPbiKiosks for the whole list.' }
if ($Hosts -and $AllPbiKiosks) { throw 'Use -Hosts or -AllPbiKiosks, not both.' }

if ($RemoteRoots -and -not $Credential -and -not $CredentialFile) {
    $default = Join-Path $FleetRoot 'Config\kiosk-admin.cred.xml'
    if (Test-Path -LiteralPath $default) { $CredentialFile = $default }
}
if ($CredentialFile -and -not $Credential) { $Credential = Import-StoredCredential -Path $CredentialFile }


foreach ($f in $PayloadFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $SourceDir $f))) { throw "Missing from ${SourceDir}: $f" }
}
$tokens = $null; $parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceDir 'PbiLauncher.ps1'), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "PbiLauncher.ps1 does not parse - not deploying it: $($parseErrors[0].Message) (line $($parseErrors[0].Extent.StartLineNumber))" }
$LauncherVersion = ''
if ((Get-Content -LiteralPath (Join-Path $SourceDir 'PbiLauncher.ps1') -TotalCount 200) -join "`n" -match "\`$LauncherVersion = '([^']+)'") { $LauncherVersion = $Matches[1] }

# --- Targets --------------------------------------------------------------------
$targets = @()
if ($Hosts) {
    # "A,B" arrives as one string when the script is run with -File.
    $Hosts = @($Hosts | ForEach-Object { $_ -split '[,;\s]+' } | Where-Object { $_ })
    $targets = @($Hosts | ForEach-Object { [pscustomobject]@{ Host = $_.Trim().ToUpperInvariant(); Location = ''; Type = '' } } | Where-Object { $_.Host })
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
        if (-not (Test-IsPowerBiKiosk -Type $row.Type)) { continue }
        if ($row.Type -match 'NO\s*SCRIPT') { Write-Host ("Skipping {0}: type '{1}'." -f $row.Host, $row.Type) -ForegroundColor DarkGray; continue }
        if ($row.Active -and $row.Active.Trim().ToUpperInvariant().StartsWith('N')) { Write-Host ("Skipping {0}: ACTIVE = {1}." -f $row.Host, $row.Active) -ForegroundColor DarkGray; continue }
        $targets += [pscustomobject]@{ Host = $row.Host.ToUpperInvariant(); Location = $row.Location; Type = $row.Type }
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
        if ($exists) {
            Invoke-Retry { [IO.File]::Replace($tmp, $Destination, "$Destination.bak-$Stamp") }
        }
        else {
            Invoke-Retry { [IO.File]::Move($tmp, $Destination) }
        }
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
    $lnk.Arguments = ('"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}\PbiLauncher.ps1" -Instance {1}{2}' -f $InstallLocal, $InstanceName, $(if ($ExtraArguments) { " $ExtraArguments" } else { '' }))
    $lnk.WorkingDirectory = $InstallLocal
    $lnk.WindowStyle = 7
    $lnk.Description = "PBI Launcher - the Power BI report on screen $InstanceName"
    $lnk.Save()
}

function Find-LegacyInstall {
    # The old launcher's configs for this kiosk, one per screen (Launcher S2
    # is S2), and its StartupLauncher.
    param([string]$Root, [string]$HostName)

    $screens = [ordered]@{}
    foreach ($rel in $LegacyRoots) {
        $base = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $base -Directory -Filter 'Launcher S*' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            if ($dir.Name -notmatch '^Launcher (S\d+)$') { continue }
            $screen = $Matches[1].ToUpperInvariant()
            # 1.0.0.11 lives in Launcher Sn\PowerBILauncher\; 1.0.0.14 directly
            # in Launcher Sn\. A config only counts next to PowerBILauncher.exe,
            # since other launchers use the same file name. One renamed by an
            # earlier deploy is still where the settings come from.
            foreach ($folder in @((Join-Path $dir.FullName 'PowerBILauncher'), $dir.FullName)) {
                $p = Join-Path $folder "$HostName.json"
                if (-not (Test-Path -LiteralPath $p)) { $retired = Find-RetiredLegacyJson -Path $p; if ($retired) { $p = $retired } }
                if ((Test-Path -LiteralPath $p) -and (Test-Path -LiteralPath (Join-Path $folder 'PowerBILauncher.exe')) -and -not $screens.Contains($screen)) { $screens[$screen] = $p }
            }
        }
    }
    $configs = @($screens.Values)

    $startupJson = $null
    foreach ($rel in $LegacyRoots) {
        foreach ($name in @("$HostName.json", 'startup.json')) {
            $p = Join-Path $Root "$rel\StartupLauncher\$name"
            if (Test-Path -LiteralPath $p) { $startupJson = $p; break }
        }
        if ($startupJson) { break }
    }

    # Does the StartupLauncher start anything besides the Power BI launcher?
    $others = @()
    if ($startupJson) {
        try {
            $sj = @(Read-JsonFile -Path $startupJson)[0]
            foreach ($n in 1..4) {
                $pathProp = $sj.PSObject.Properties["LauncherPath$n"]
                $nameProp = $sj.PSObject.Properties["LauncherName$n"]
                if (-not $pathProp -or -not $nameProp -or -not $pathProp.Value -or -not $nameProp.Value) { continue }
                if ([string]$nameProp.Value -like 'PowerBILauncher*') { continue }
                $local = Join-Path ([string]$pathProp.Value) ([string]$nameProp.Value)
                if ($local -match '^[A-Za-z]:\\(.*)$' -and (Test-Path -LiteralPath (Join-Path $Root $Matches[1]))) { $others += $local }
            }
        }
        catch { $others += "(could not read $startupJson)" }
    }

    return [pscustomobject]@{ Screens = $screens; Configs = $configs; StartupJson = $startupJson; OtherLaunchers = $others }
}

function Find-StartupFolder {
    <#
        The kiosk account's Startup folder, plus any old launcher shortcuts
        in it or in the all-users Startup folder.
    #>
    param([string]$Root, [string]$HostName)

    $legacyLinks = @()
    $candidates = @()
    $usersDir = Join-Path $Root 'Users'
    foreach ($u in @(Get-ChildItem -LiteralPath $usersDir -Directory -ErrorAction SilentlyContinue)) {
        $sf = Join-Path $u.FullName $StartupRel
        if (-not (Test-Path -LiteralPath $sf)) { continue }
        foreach ($l in @(Get-ChildItem -LiteralPath $sf -File -ErrorAction SilentlyContinue)) {
            if ($l.Name -like "*.lnk$DisabledSuffix") { $legacyLinks += $l.FullName; continue }
            if ($l.Extension -ne '.lnk' -or $l.Name -eq $ShortcutName) { continue }
            if ((Get-ShortcutTarget $l.FullName) -match 'StartupLauncher|PowerBILauncher') {
                $legacyLinks += $l.FullName
                $candidates += $u.Name
            }
        }
    }
    $allUsers = Join-Path $Root $AllUsersStartupRel
    foreach ($l in @(Get-ChildItem -LiteralPath $allUsers -File -ErrorAction SilentlyContinue)) {
        if ($l.Name -like "*.lnk$DisabledSuffix") { $legacyLinks += $l.FullName; continue }
        if ($l.Extension -eq '.lnk' -and (Get-ShortcutTarget $l.FullName) -match 'StartupLauncher|PowerBILauncher') { $legacyLinks += $l.FullName }
    }

    $user = if ($KioskUser) { $KioskUser }
    elseif (@($candidates | Select-Object -Unique).Count -eq 1) { $candidates[0] }
    else { $HostName }

    $profileDir = Join-Path $usersDir $user
    return [pscustomobject]@{
        User          = $user
        ProfileExists = (Test-Path -LiteralPath $profileDir)
        Folder        = (Join-Path $profileDir $StartupRel)
        LegacyLinks   = $legacyLinks
    }
}

function ConvertFrom-LegacyConfig {
    # The old settings the new launcher uses, without the password.
    param($Legacy, [string]$SourcePath, [string]$HostName)

    $keep = @('DisplayURL', 'UserName', 'StaySignedIn', 'KioskMode', 'UsePriScreen', 'ScreenSelect', 'ZoomPercent',
        'EnableRefresh', 'BrowserRefreshDelay', 'ForcedRefreshTime', 'ScheduledRestartEnabled', 'ScheduledRestartTime',
        'RestartDelay', 'StartupDelay', 'LogPath', 'RemoteLogPath', 'LogName', 'DebugLogging')
    $out = [ordered]@{
        ConfigVersion = '2.0'
        MigratedFrom  = ('{0} on {1:yyyy-MM-dd}' -f $SourcePath, (Get-Date))
    }
    foreach ($k in $keep) {
        $p = $Legacy.PSObject.Properties[$k]
        if ($p) { $out[$k] = $p.Value }
    }
    $out['DisableStartup'] = '0'
    # New file name in the same central folder, so old and new logs are
    # told apart at a glance.
    $name = if ($out.Contains('LogName') -and $out['LogName']) { [string]$out['LogName'] } else { "PowerBI_$HostName.log" }
    $out['LogName'] = ($name -replace '^PowerBI_', 'PbiLauncher_')
    if ($out['LogName'] -eq $name) { $out['LogName'] = "PbiLauncher_$name" }
    return $out
}

function Set-JsonFlag {
    # Flips "Key": "x" in place, keeping the rest of the file as it is.
    # -AddIfMissing puts the key first in the (first) object when the file
    # does not have it: the old Power BI launcher reads DisableStartup when
    # it is there ("Disable Startup = True, exiting!"), but not every old
    # config was written with it.
    param([string]$Path, [string]$Key, [string]$Value, [switch]$AddIfMissing)
    $text = Read-SharedText -Path $Path
    $pattern = '("' + [regex]::Escape($Key) + '"\s*:\s*)"[^"]*"'
    if ($text -match $pattern) { $new = [regex]::Replace($text, $pattern, ('${1}"' + $Value + '"')) }
    elseif ($AddIfMissing) {
        $open = $text.IndexOf('{')
        if ($open -lt 0) { throw "no JSON object in $Path" }
        $rest = $text.Substring($open + 1)
        $sep = if ($rest.TrimStart().StartsWith('}')) { '' } else { ',' }
        $new = $text.Substring(0, $open + 1) + "`r`n   `"$Key`": `"$Value`"$sep" + $rest
        # Only a file that still reads as JSON is written.
        try { $null = ConvertFrom-Json -InputObject $new } catch { throw "adding $Key would break $Path" }
    }
    else { throw "no $Key in $Path" }
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
        logon whatever it is called, and a "StartupLauncher.exe.lnk.disabled-
        by-PbiLauncher" is opened with a "Select an app to open this file"
        dialog on top of the report - which is what the first version left
        behind. A file still carrying that suffix is moved out the same way,
        under its real name, which is how a redeploy clears it.
    #>
    param([string]$Path, [string]$Root, [string]$Target)

    $leaf = Split-Path -Leaf $Path
    $name = if ($leaf -like "*$DisabledSuffix") { $leaf.Substring(0, $leaf.Length - $DisabledSuffix.Length) } else { $leaf }
    $folder = Split-Path -Parent $Path
    $usersPrefix = (Join-Path $Root 'Users') + '\'
    $owner = if ($folder.StartsWith($usersPrefix, [StringComparison]::OrdinalIgnoreCase)) { $folder.Substring($usersPrefix.Length).Split('\')[0] } else { 'All Users' }
    $destDir = Join-Path $Target "$RetiredRel\$owner"
    $dest = Join-Path $destDir $name
    if (-not $PSCmdlet.ShouldProcess($Path, "Move out of the Startup folder to $($destDir.Replace($Root, 'C:'))")) { return $null }
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    # Retired before and back again: the same shortcut, the newer one wins.
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
    Invoke-Retry { Move-Item -LiteralPath $Path -Destination $dest }
    return [pscustomobject]@{ From = (Join-Path $folder $name).Replace($Root, 'C:'); To = $dest.Replace($Root, 'C:') }
}

function Get-RecordList {
    <#
        A list from migration.json, as non-blank strings. Windows PowerShell
        writes an empty list as {} - an empty object - and read back that is
        one blank entry, which as a path is the kiosk's own C:\. So every
        list is read through this.
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

function Wait-LauncherShowing {
    <#
        After a restart: waits for a launcher run that started after the
        restart (a new PID or start time in the status file) to report
        SHOWING. A state that needs a person ends the wait early.
    #>
    param([string]$HostName, [string]$StatusPath, $Before)

    $deadline = (Get-Date).AddMinutes($VerifyMinutes)
    $wentDown = $false
    $last = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        if (-not (Test-HostReachable -HostName $HostName -TimeoutMs 1000).Ok) { $wentDown = $true; $last = 'offline (restarting)'; continue }
        $st = Read-LauncherStatus -Path $StatusPath
        if (-not $st) { $last = 'no status file yet'; continue }
        $isNew = -not $Before -or $st.StartedUtc -ne $Before.StartedUtc -or $st.Pid -ne $Before.Pid
        if (-not $isNew) { $last = 'waiting for the restart'; continue }
        $last = "$($st.State) $($st.Detail)".Trim()
        # The report on screen is not enough: it must be the configured
        # account's (launcher 2.0 records both).
        $wanted = if ($st.PSObject.Properties['UserName']) { [string]$st.UserName } else { '' }
        $actual = if ($st.PSObject.Properties['SignedInAs']) { [string]$st.SignedInAs } else { '' }
        if ($st.State -eq 'SHOWING' -and $wanted -and $actual -ne $wanted) {
            $last = "SHOWING, but signed in as '$actual' (expected $wanted)"
            continue
        }
        switch ($st.State) {
            'SHOWING' {
                $as = if ($actual) { ", signed in as $actual" } else { '' }
                return [pscustomobject]@{ Ok = $true; Detail = ("SHOWING{0} (Edge {1}, launcher {2})" -f $as, $st.EdgeVersion, $st.LauncherVersion) }
            }
            { $_ -in @('SIGNIN_BLOCKED', 'DISABLED', 'UNSUPERVISED') } { return [pscustomobject]@{ Ok = $false; Detail = $last } }
        }
    }
    if (-not $wentDown) { $last = "never went offline - did it restart? Last: $last" }
    return [pscustomobject]@{ Ok = $false; Detail = "not SHOWING after $VerifyMinutes min: $last" }
}

# --- Run ------------------------------------------------------------------------
$action = if ($Rollback) { 'Rollback' } elseif ($Command) { "Command $Command" } else { 'Install' }
Write-Host ("PBI Launcher {0} - {1} on {2} kiosk(s){3}" -f $LauncherVersion, $action, $targets.Count, $(if ($WhatIfPreference) { ' (WhatIf)' } else { '' }))
if ($Credential) { Write-Host "Admin share as $($Credential.UserName)" -ForegroundColor DarkGray }

$results = New-Object System.Collections.Generic.List[object]
$halted = $false

foreach ($t in $targets) {
    $h = $t.Host
    $r = [pscustomobject]@{
        Host = $h; Location = $t.Location; Action = $action; Result = ''; Instances = ''; Files = ''; Config = ''; Password = ''
        Startup = ''; Legacy = ''; Restart = ''; Verified = ''; Detail = ''
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
        # The screens PBI Launcher has here: S1, S2, ... with a config. The
        # layout from before the screen folders (config next to the script)
        # is its S1 until it is moved below.
        $existing = @()
        if (Test-Path -LiteralPath $target) {
            # { $_.Name }, not "ForEach-Object Name": under -WhatIf that form
            # asks ShouldProcess and returns nothing.
            $existing = @(Get-ChildItem -LiteralPath $target -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^S\d+$' -and (Test-Path -LiteralPath (Join-Path $_.FullName "$h.json")) } | ForEach-Object { $_.Name.ToUpperInvariant() })
        }
        $rootConfig = Join-Path $target "$h.json"
        $rootLayout = (Test-Path -LiteralPath $rootConfig) -and ($existing -notcontains 'S1')
        $screenDir = { param($i) if ($rootLayout -and $i -eq 'S1') { $target } else { Join-Path $target $i } }
        $statusOf = {
            param($i)
            $dir = & $screenDir $i
            $name = $i
            if ($dir -eq $target) {
                # 2.0.0 named its status file after the config's Instance, or the host.
                $name = $h
                try { $c = @(Read-JsonFile -Path $rootConfig)[0]; if ($c.PSObject.Properties['Instance'] -and $c.Instance) { $name = [string]$c.Instance } } catch {}
            }
            Join-Path $dir "Status\$name.status.json"
        }
        $known = @($existing)
        if ($rootLayout) { $known = @('S1') + $known }

        # --- -Command ----------------------------------------------------------
        if ($Command) {
            if (-not (Test-Path -LiteralPath (Join-Path $target 'PbiLauncher.ps1'))) { $r.Result = 'NOT_INSTALLED'; continue }
            $which = if ($Instance) { @($Instance.ToUpperInvariant()) } else { $known }
            if ($which.Count -eq 0) { $r.Result = 'NOT_INSTALLED'; $r.Detail = 'no screen folders'; continue }
            $states = @()
            foreach ($i in $which) {
                $dir = & $screenDir $i
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
                if ($st) { $states += "$i was $($st.State) (updated $($st.UpdatedUtc))" }
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

            # Every shortcut of ours: recorded, 2.0.0's single one, and any
            # "PBI Launcher S<n>.lnk" in the account's Startup folder.
            $linkPaths = @(Join-Path $startup.Folder $ShortcutName)
            if ($m -and $m.PSObject.Properties['Shortcut'] -and $m.Shortcut) { $linkPaths += (ConvertFrom-LegacyKioskPath -Path ([string]$m.Shortcut) -Root $root) }
            $linkPaths += @(Get-RecordList -Record $m -Name 'Shortcuts' | ForEach-Object { ConvertFrom-LegacyKioskPath -Path $_ -Root $root })
            if (Test-Path -LiteralPath $startup.Folder) {
                $linkPaths += @(Get-ChildItem -LiteralPath $startup.Folder -Filter "$ShortcutPrefix*.lnk" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
            }
            $removed = 0
            foreach ($lp in @($linkPaths | Select-Object -Unique)) {
                if ((Test-Path -LiteralPath $lp) -and $PSCmdlet.ShouldProcess($lp, 'Delete')) { Remove-Item -LiteralPath $lp -Force; $removed++ }
            }
            if ($removed) { $r.Startup = "removed $removed" }

            $restored = 0
            # Retired shortcuts go back where they came from. One that is
            # there already (something at logon puts it back) only needs our
            # copy removed.
            if ($m -and $m.PSObject.Properties['RetiredShortcuts']) {
                foreach ($rs in @($m.RetiredShortcuts | Where-Object { $_ -and $_.From -and $_.To })) {
                    $to = Join-Path $root ([string]$rs.To -replace '^[A-Za-z]:\\', '')
                    $from = Join-Path $root ([string]$rs.From -replace '^[A-Za-z]:\\', '')
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
            # Renamed in place by the first version.
            foreach ($l in @($startup.LegacyLinks | Where-Object { $_ -like "*$DisabledSuffix" })) {
                if (Rename-Shortcut -Path $l -NewName ((Split-Path -Leaf $l).Substring(0, (Split-Path -Leaf $l).Length - $DisabledSuffix.Length))) { $restored++ }
            }
            # JSON renamed out of the way (2.0.1), DisableStartup (2.0.0).
            $renamedBack = 0
            if ($m -and $m.PSObject.Properties['LegacyJsonRenamed']) { $renamedBack = Undo-LegacyJsonRenames -Root $root -Records @($m.LegacyJsonRenamed) -Cmdlet $PSCmdlet }
            $reverted = 0
            $legacyChanged = @(Get-RecordList -Record $m -Name 'LegacyConfigsDisabled')
            foreach ($lc in $legacyChanged) {
                $unc = Join-Path $root ([string]$lc -replace '^[A-Za-z]:\\', '')
                if ((Test-Path -LiteralPath $unc) -and (Set-JsonFlag -Path $unc -Key 'DisableStartup' -Value '0')) { $reverted++ }
            }
            $r.Legacy = "shortcuts restored $restored, JSON renamed back $renamedBack, configs re-enabled $reverted"
            if ($restored -eq 0 -and $reverted -eq 0 -and $renamedBack -eq 0) { $notes.Add('nothing of the old launcher to restore - was it retired by this script?') }

            foreach ($i in $known) {
                [void](Write-TextFile -Path (Join-Path (& $screenDir $i) 'kill.txt') -Text 'rollback' -Action 'Create')
            }
            $r.Instances = $known -join ','
            if ($known.Count) { $r.Files = 'kept (launcher told to stop)' }
            if ($m -and $PSCmdlet.ShouldProcess($migrationPath, 'Mark as rolled back')) {
                Move-Item -LiteralPath $migrationPath -Destination "$migrationPath.rolledback-$Stamp" -Force
            }
            $r.Result = if ($WhatIfPreference) { 'WHATIF' } else { 'ROLLED_BACK' }
        }
        # --- Install -------------------------------------------------------------
        else {
            # Which screens: the old launcher's, and those set up already.
            $plan = [ordered]@{}
            foreach ($s in $legacy.Screens.Keys) { $plan[$s] = $legacy.Screens[$s] }
            foreach ($i in $known) { if (-not $plan.Contains($i)) { $plan[$i] = $null } }
            # One launcher per screen: a screen Mach2 Launcher NG or Web
            # Launcher has now is theirs, whatever the old launcher ran there.
            $owners = Get-ScreenOwners -Root $root -HostName $h
            foreach ($s in @($plan.Keys)) {
                if ($owners.ContainsKey($s) -and $owners[$s] -ne 'PBI') {
                    $notes.Add("$s belongs to $($ScreenLauncherTitles[$owners[$s]]) on this kiosk - not set up for Power BI")
                    $plan.Remove($s)
                }
            }
            if ($plan.Count -eq 0) {
                $r.Result = 'NO_CONFIG'
                $r.Detail = (@("no old launcher to copy settings from. Put $h.json (from EXAMPLE.json) in $InstallLocal\S1 and run again.") + $notes) -join '; '
                $notes.Clear()
                continue
            }
            if (-not $startup.ProfileExists) {
                $r.Result = 'FAILED'
                $r.Detail = "no profile for kiosk account '$($startup.User)' on this kiosk - has it ever signed in? Use -KioskUser."
                continue
            }
            $instances = @($plan.Keys | Sort-Object)
            $r.Instances = $instances -join ','
            $r.Legacy = if ($legacy.Screens.Count) { (@($legacy.Screens.Keys | ForEach-Object { '{0}: {1}' -f $_, (ConvertTo-LegacyKioskPath -Path $legacy.Screens[$_] -Root $root) })) -join ', ' } else { 'none found' }

            if (-not (Test-Path -LiteralPath $target)) {
                if ($PSCmdlet.ShouldProcess($target, 'Create folder')) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
            }

            # files
            $fileResults = @()
            if (Test-Path -LiteralPath $target) {
                foreach ($f in $PayloadFiles) { $fileResults += Install-File -Source (Join-Path $SourceDir $f) -Destination (Join-Path $target $f) }
            }
            else { $fileResults = @('WHATIF') }
            $r.Files = if ($fileResults -contains 'WHATIF') { 'WHATIF' } elseif ($fileResults -contains 'UPDATED') { 'UPDATED' } else { 'UP_TO_DATE' }

            # 2.0.0's layout moves into S1: the config, the password, a hold
            # and the status. The launcher running now keeps its files open
            # only briefly; it is restarted with the kiosk.
            $movedToS1 = @()
            if ($rootLayout -and $plan.Contains('S1')) {
                $s1 = Join-Path $target 'S1'
                if (-not (Test-Path -LiteralPath $s1) -and $PSCmdlet.ShouldProcess($s1, 'Create folder')) { New-Item -ItemType Directory -Path $s1 -Force | Out-Null }
                foreach ($name in @("$h.json", "$h.cred", 'password.seed', 'hold.txt', 'Status')) {
                    $from = Join-Path $target $name
                    if (-not (Test-Path -LiteralPath $from)) { continue }
                    if (-not $PSCmdlet.ShouldProcess($from, "Move into S1")) { continue }
                    $to = Join-Path $s1 $name
                    if (Test-Path -LiteralPath $to) { Remove-Item -LiteralPath $to -Recurse -Force }
                    Invoke-Retry { Move-Item -LiteralPath $from -Destination $to }
                    $movedToS1 += $name
                }
                if ($movedToS1.Count) {
                    $notes.Add("moved $($movedToS1 -join ', ') into S1 (screen folders, 2.0.1)")
                    $rootLayout = $false
                }
            }

            # screens: config, password, shortcut
            $configResults = @(); $pwResults = @(); $links = @()
            foreach ($i in $instances) {
                $dir = & $screenDir $i
                if (-not (Test-Path -LiteralPath $dir) -and $PSCmdlet.ShouldProcess($dir, 'Create folder')) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $configPath = Join-Path $dir "$h.json"
                $legacyPath = $plan[$i]
                $legacyConfig = $null
                if ($legacyPath) {
                    try { $legacyConfig = @(Read-JsonFile -Path $legacyPath)[0] }
                    catch { $notes.Add("${i}: old config unreadable: $($_.Exception.Message)") }
                }
                $haveConfig = Test-Path -LiteralPath $configPath
                if ($haveConfig -and $UpdateConfig -and -not $legacyConfig) { $notes.Add("${i}: -UpdateConfig: no old launcher config to copy from, so the existing config is kept") }
                if ($haveConfig -and (-not $UpdateConfig -or -not $legacyConfig)) { $configResults += "${i}:KEPT" }
                elseif ($legacyConfig) {
                    $newCfg = ConvertFrom-LegacyConfig -Legacy $legacyConfig -SourcePath (ConvertTo-LegacyKioskPath -Path $legacyPath -Root $root) -HostName $h
                    if ($i -ne 'S1' -and -not $legacyConfig.PSObject.Properties['LogName']) { $newCfg['LogName'] = "PbiLauncher_${h}_$i.log" }
                    if ($haveConfig -and $PSCmdlet.ShouldProcess($configPath, 'Back up')) { Invoke-Retry { Copy-Item -LiteralPath $configPath -Destination "$configPath.bak-$Stamp" -Force } }
                    $written = if (Test-Path -LiteralPath $dir) { Write-TextFile -Path $configPath -Text (ConvertTo-Json -InputObject ([pscustomobject]$newCfg)) } else { $false }
                    $configResults += $(if ($written) { "${i}:FROM_OLD_LAUNCHER" } else { "${i}:WHATIF" })
                }
                else { $configResults += "${i}:NONE" }

                # password
                $credPath = Join-Path $dir "$h.cred"
                $seedPath = Join-Path $dir 'password.seed'
                $seed = $null
                if ($SignInCredential) {
                    $seed = $SignInCredential.GetNetworkCredential().Password
                    $pwResults += "${i}:SEED_FROM_PARAMETER"
                    if ($legacyConfig -and $legacyConfig.PSObject.Properties['UserName'] -and $SignInCredential.UserName -and $SignInCredential.UserName -ne [string]$legacyConfig.UserName) {
                        $notes.Add("${i}: -SignInCredential user $($SignInCredential.UserName) differs from the config's $($legacyConfig.UserName); only the password is used")
                    }
                }
                elseif (Test-Path -LiteralPath $credPath) { $pwResults += "${i}:ALREADY_STORED" }
                elseif (Test-Path -LiteralPath $seedPath) { $pwResults += "${i}:SEED_WAITING" }
                elseif ($legacyConfig -and $legacyConfig.PSObject.Properties['Password'] -and $legacyConfig.Password) { $seed = [string]$legacyConfig.Password; $pwResults += "${i}:SEED_FROM_OLD_LAUNCHER" }
                else { $pwResults += "${i}:NONE"; $notes.Add("${i}: no password to hand over - sign in once at the kiosk, or run again with -SignInCredential") }
                if ($seed) {
                    if (-not (Test-Path -LiteralPath $dir) -or -not (Write-TextFile -Path $seedPath -Text $seed -Action 'Write password.seed')) { $pwResults[-1] = "${i}:WHATIF" }
                    $seed = $null
                }

                # startup shortcut
                $newLink = Join-Path $startup.Folder "$ShortcutPrefix$i.lnk"
                if ($PSCmdlet.ShouldProcess($newLink, 'Create startup shortcut')) {
                    if (-not (Test-Path -LiteralPath $startup.Folder)) { New-Item -ItemType Directory -Path $startup.Folder -Force | Out-Null }
                    $tmpLink = Join-Path $env:TEMP "PbiLauncher-$Stamp-$i.lnk"
                    New-LauncherShortcut -Path $tmpLink -InstanceName $i
                    Invoke-Retry { Copy-Item -LiteralPath $tmpLink -Destination $newLink -Force }
                    Remove-Item -LiteralPath $tmpLink -Force
                    $links += ConvertTo-LegacyKioskPath -Path $newLink -Root $root
                }
            }
            $r.Config = $configResults -join ' '
            $r.Password = $pwResults -join ' '
            # 2.0.0's single shortcut started S1 without saying so; the
            # screen's own shortcut does that now.
            $oldLink = Join-Path $startup.Folder $ShortcutName
            if ((Test-Path -LiteralPath $oldLink) -and $PSCmdlet.ShouldProcess($oldLink, 'Delete (replaced by one shortcut per screen)')) { Remove-Item -LiteralPath $oldLink -Force }
            $r.Startup = if ($links.Count) { "for $($startup.User): $($links.Count) shortcut(s)" } else { 'WHATIF' }

            # retire the old launcher
            $prevRecord = $null
            if (Test-Path -LiteralPath $migrationPath) { try { $prevRecord = Read-JsonFile -Path $migrationPath } catch {} }
            $prevRetired = @()
            if ($prevRecord -and $prevRecord.PSObject.Properties['RetiredShortcuts']) { $prevRetired = @($prevRecord.RetiredShortcuts) }
            $retired = @()
            $jsonRenamed = @()
            # Left in the Startup folder by the first version: renamed, so
            # Windows asks what to open it with at every logon. Always cleared.
            $cleared = 0
            foreach ($l in @($startup.LegacyLinks | Where-Object { $_ -like "*$DisabledSuffix" })) {
                $rec = Move-ShortcutOut -Path $l -Root $root -Target $target
                if ($rec) { $retired += $rec; $cleared++ }
            }
            if ($cleared) { $notes.Add("moved $cleared shortcut(s) the first version had renamed out of the Startup folder - they made Windows ask which app to open them with at logon") }

            if ($KeepLegacy) { $r.Legacy += ' (kept, -KeepLegacy)' }
            else {
                $moved = 0
                if ($legacy.OtherLaunchers.Count -gt 0) {
                    $notes.Add("StartupLauncher also starts $($legacy.OtherLaunchers -join ', ') - its shortcut stays; only the old Power BI launcher is retired")
                }
                else {
                    foreach ($l in @($startup.LegacyLinks | Where-Object { $_ -notlike "*$DisabledSuffix" })) {
                        # Retired once already and back again: the logon
                        # script (Mach2LauncherShortcuts.ps1) restores it.
                        # Harmless now: StartupLauncher has no config left.
                        if (@($prevRetired | Where-Object { $_.From -eq $l.Replace($root, 'C:') }).Count) {
                            $notes.Add("$(Split-Path -Leaf $l) was retired before and is back - the logon script restores it; its config is renamed, so it starts nothing")
                        }
                        $rec = Move-ShortcutOut -Path $l -Root $root -Target $target
                        if ($rec) { $retired += $rec; $moved++ }
                    }
                }
                # The old configs are renamed: without <HOST>.json the old
                # launcher does not run and the logon script makes no
                # shortcut for it. Then StartupLauncher's own, once it has
                # nothing left to start.
                foreach ($s in $legacy.Screens.Keys) {
                    if ($legacy.Screens[$s] -match $LegacyDisabledPattern -or $s -notin $instances) { continue }
                    try {
                        $to = Disable-LegacyJson -Path $legacy.Screens[$s] -Tag 'PbiLauncher' -Cmdlet $PSCmdlet
                        if ($to) { $jsonRenamed += [pscustomobject]@{ From = (ConvertTo-LegacyKioskPath -Path $legacy.Screens[$s] -Root $root); To = (ConvertTo-LegacyKioskPath -Path $to -Root $root) } }
                    }
                    catch { $notes.Add("could not rename the old $s config: $($_.Exception.Message)") }
                }
                try {
                    $sl = Invoke-RetireLegacyStartup -Root $root -HostName $h -Tag 'PbiLauncher' -Cmdlet $PSCmdlet
                    $jsonRenamed += @($sl.Renamed)
                    foreach ($k in $sl.Kept) { $notes.Add("StartupLauncher kept: $k") }
                }
                catch { $notes.Add("could not retire StartupLauncher's config: $($_.Exception.Message)") }
                $r.Legacy += " (shortcuts retired $moved, JSON renamed $($jsonRenamed.Count))"
            }

            # migration record, merged with any earlier one
            if (-not $WhatIfPreference) {
                $prev = $prevRecord
                # The first version renamed shortcuts in place, 2.0.0 set
                # DisableStartup; their records are kept as they were.
                $allRenamed = @(Get-RecordList -Record $prev -Name 'LegacyShortcutsDisabled')
                $allDisabled = @(Get-RecordList -Record $prev -Name 'LegacyConfigsDisabled')
                $prevLinks = @(Get-RecordList -Record $prev -Name 'Shortcuts')
                $prevJson = if ($prev -and $prev.PSObject.Properties['LegacyJsonRenamed']) { @($prev.LegacyJsonRenamed) } else { @() }
                $record = [ordered]@{
                    Host                    = $h
                    LauncherVersion         = $LauncherVersion
                    DeployedAt              = (Get-Date).ToString('s')
                    DeployedBy              = "$env:USERDOMAIN\$env:USERNAME"
                    KioskUser               = $startup.User
                    Instances               = @($instances)
                    # @() around each: an empty list otherwise goes out as {}.
                    Shortcuts               = @(@($prevLinks) + @($links) | Where-Object { $_ } | Select-Object -Unique)
                    LegacyConfigs           = @($legacy.Screens.Values | ForEach-Object { ConvertTo-LegacyKioskPath -Path $_ -Root $root })
                    MovedToS1               = @($movedToS1)
                    RetiredShortcuts        = @(Merge-RetiredShortcuts -Previous $prevRetired -New $retired)
                    LegacyJsonRenamed       = @(Merge-RetiredShortcuts -Previous $prevJson -New $jsonRenamed)
                    LegacyShortcutsDisabled = @($allRenamed)
                    LegacyConfigsDisabled   = @($allDisabled)
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
            $comment = if ($Rollback) { 'IT is switching this screen back to the previous Power BI launcher. It will come back on its own. [PBI-LAUNCHER deploy]' }
            else { 'IT is updating the Power BI screen launcher. It will come back on its own. [PBI-LAUNCHER deploy]' }
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
            if ($Rollback) {
                $r.Verified = 'not checked (old launcher)'
            }
            else {
                Write-Host ("  restarting, waiting up to {0} min for the report on {1}..." -f $VerifyMinutes, ($verifyScreens -join ', ')) -ForegroundColor DarkGray
                $verified = @(); $ok = $true
                foreach ($i in $verifyScreens) {
                    $v = Wait-LauncherShowing -HostName $h -StatusPath (& $statusOf $i) -Before $before[$i]
                    $verified += "${i}: $($v.Detail)"
                    if (-not $v.Ok) { $ok = $false; break }
                }
                $r.Verified = $verified -join '; '
                if (-not $ok) {
                    $r.Result = 'FAILED'
                    $halted = $true
                    $s = $null
                    try {
                        $s = New-KioskCimSession -HostName $h -Credential $Credential -TimeoutSec 20
                        $old = @(Get-CimInstance -CimSession $s -ClassName Win32_Process -Filter "Name = 'PowerBILauncher.exe'")
                        if ($old.Count) { $notes.Add('the OLD PowerBILauncher.exe is running - something else still starts it') }
                    }
                    catch {}
                    finally { if ($s) { Remove-CimSession -CimSession $s -ErrorAction SilentlyContinue -WhatIf:$false } }
                }
                else { $r.Result = 'VERIFIED' }
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
        Write-Host ("  {0,-12} screens={1} files={2} config={3} password={4} startup={5}" -f $r.Result, $r.Instances, $r.Files, $r.Config, $r.Password, $r.Startup) -ForegroundColor $color
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
    $report = Join-Path $LogDir "deploy_$Stamp.csv"
    $results | Export-Csv -LiteralPath $report -NoTypeInformation -Encoding UTF8
    Write-Host "Report: $report" -ForegroundColor DarkGray
}
if (@($results | Where-Object { $_.Result -in @('FAILED', 'HALTED') }).Count) { exit 1 }
