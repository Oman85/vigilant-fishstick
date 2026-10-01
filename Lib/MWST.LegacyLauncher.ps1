<#
.SYNOPSIS
    Retiring the old launchers (Mach2Launcher.exe, PowerBILauncher.exe and
    the StartupLauncher.exe that starts them) by renaming their JSON files,
    and undoing that.

.DESCRIPTION
    Dot-sourced by Deploy-PbiLauncher.ps1, Deploy-Mach2LauncherNG.ps1 and
    Deploy-WebLauncher.ps1.

    The old launchers only run with a config named after the kiosk, and the
    logon script on the kiosks (C:\Users\Public\Documents\
    Mach2LauncherShortcuts.ps1) says so itself: "If one is found it is
    assumed it has been configured for use and will create a shortcut". It
    puts the StartupLauncher shortcut back into the kiosk account's Startup
    folder at every logon, and a Mach2Launcher shortcut for every screen
    folder that has a <HOST>.json - so moving shortcuts out never lasted.
    Renaming the JSON files does:

      Launcher S<n>\<HOST>.json      the old launcher of that screen: no
                                     config, so it does not run, and the
                                     logon script makes no shortcut for it
      StartupLauncher\<HOST>.json    what StartupLauncher starts ("If its not
      StartupLauncher\startup.json   configured nothing should happen") -
                                     renamed only once nothing it starts is
                                     still configured, so a kiosk moved one
                                     screen at a time keeps its other old
                                     launcher until that one is moved too

    Each file becomes <name>.disabled-by-<new launcher>, next to where it
    was. The deploys record every rename in migration.json; -Rollback
    renames them back.
#>

Set-StrictMode -Off

$LegacyLauncherRoots = @('Users\Public\Documents\Mach2Launchers', 'Users\Public\Documents\Launchers')
$LegacyDisabledPattern = '\.disabled-by-[A-Za-z0-9]+$'

function ConvertTo-LegacyKioskPath {
    # \\HOST\C$\x (or a test root) -> C:\x, as the kiosk sees it.
    param([string]$Path, [string]$Root)
    if ($Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) { return 'C:' + $Path.Substring($Root.Length) }
    return $Path
}

function ConvertFrom-LegacyKioskPath {
    # C:\x as the kiosk sees it -> under $Root.
    param([string]$Path, [string]$Root)
    if ($Path -match '^[A-Za-z]:\\(.*)$') { return (Join-Path $Root $Matches[1]) }
    return $Path
}

function Find-RetiredLegacyJson {
    # A config renamed by an earlier deploy, if there is one: X.json.disabled-by-*.
    param([Parameter(Mandatory)][string]$Path)
    $dir = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    return @(Get-ChildItem -LiteralPath $dir -File -Filter "$leaf.disabled-by-*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName })[0]
}

function Disable-LegacyJson {
    <#
        Renames X.json to X.json.disabled-by-<Tag>. Returns the new path, or
        $null under -WhatIf or when there is nothing to rename. A copy retired
        earlier is replaced: the file just found is the newer one.
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Tag, $Cmdlet)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $dest = "$Path.disabled-by-$Tag"
    if ($Cmdlet -and -not $Cmdlet.ShouldProcess($Path, "Rename to $(Split-Path -Leaf $dest) - the old launcher no longer finds its config")) { return $null }
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
    Move-Item -LiteralPath $Path -Destination $dest
    return $dest
}

function Enable-LegacyJson {
    <#
        Undoes Disable-LegacyJson: X.json.disabled-by-* back to X.json.
        Returns $true when it renamed. A config that is back already (someone
        put one there) wins; the renamed copy is left where it is.
    #>
    param([Parameter(Mandatory)][string]$DisabledPath, $Cmdlet)
    if (-not (Test-Path -LiteralPath $DisabledPath)) { return $false }
    $orig = $DisabledPath -replace $LegacyDisabledPattern, ''
    if ($orig -eq $DisabledPath -or (Test-Path -LiteralPath $orig)) { return $false }
    if ($Cmdlet -and -not $Cmdlet.ShouldProcess($DisabledPath, "Rename back to $(Split-Path -Leaf $orig)")) { return $false }
    Move-Item -LiteralPath $DisabledPath -Destination $orig
    return $true
}

function Find-LegacyScreenConfigs {
    <#
        The old launchers' configs on this kiosk, by screen: Launcher S2 is
        S2, whichever old launcher it holds (Mach2Launcher.exe, or
        PowerBILauncher.exe - directly or in its PowerBILauncher\ folder). A
        hashtable S<n> -> @(paths); configs already renamed are left out.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$HostName)
    $out = @{}
    foreach ($rel in $LegacyLauncherRoots) {
        $base = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($dir in @(Get-ChildItem -LiteralPath $base -Directory -Filter 'Launcher S*' -ErrorAction SilentlyContinue)) {
            if ($dir.Name -notmatch '^Launcher (S\d+)$') { continue }
            $screen = $Matches[1].ToUpperInvariant()
            foreach ($folder in @((Join-Path $dir.FullName 'PowerBILauncher'), $dir.FullName)) {
                $p = Join-Path $folder "$HostName.json"
                if (-not (Test-Path -LiteralPath $p)) { continue }
                if (-not ((Test-Path -LiteralPath (Join-Path $folder 'Mach2Launcher.exe')) -or (Test-Path -LiteralPath (Join-Path $folder 'PowerBILauncher.exe')))) { continue }
                if (-not $out.ContainsKey($screen)) { $out[$screen] = @() }
                $out[$screen] += $p
            }
        }
    }
    return $out
}

function Get-LegacyStartupLaunchers {
    <#
        Each StartupLauncher on the kiosk (Mach2Launchers\StartupLauncher,
        Launchers\StartupLauncher): its JSON files, and every launcher it
        starts with whether that one is still configured. Still configured
        means: its folder has <HOST>.json - or it is not an old Mach2 or
        Power BI launcher, whose needs are unknown here, so it counts as in
        use.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$HostName)

    $out = @()
    foreach ($rel in $LegacyLauncherRoots) {
        $folder = Join-Path $Root "$rel\StartupLauncher"
        if (-not (Test-Path -LiteralPath $folder)) { continue }
        $jsons = @(@("$HostName.json", 'startup.json') | ForEach-Object { Join-Path $folder $_ } | Where-Object { Test-Path -LiteralPath $_ })
        # What it starts: its own config first, the template otherwise.
        $launchers = @()
        foreach ($j in $jsons) {
            try {
                # Assigned first: Windows PowerShell's ConvertFrom-Json hands
                # an array over as one object, so @(ConvertFrom-Json ..)[0]
                # would be the whole array.
                $parsed = ConvertFrom-Json -InputObject (Read-SharedText -Path $j)
                $sj = @($parsed)[0]
                foreach ($n in 1..8) {
                    $pathProp = $sj.PSObject.Properties["LauncherPath$n"]
                    $nameProp = $sj.PSObject.Properties["LauncherName$n"]
                    if (-not $pathProp -or -not $nameProp -or -not $pathProp.Value -or -not $nameProp.Value) { continue }
                    $dir = ConvertFrom-LegacyKioskPath -Path ([string]$pathProp.Value) -Root $Root
                    $exe = Join-Path $dir ([string]$nameProp.Value)
                    if (-not (Test-Path -LiteralPath $exe)) { continue }
                    $known = [string]$nameProp.Value -match '^(Mach2Launcher|PowerBILauncher)'
                    $configured = if ($known) { Test-Path -LiteralPath (Join-Path $dir "$HostName.json") } else { $true }
                    $launchers += [pscustomobject]@{
                        Exe = (Join-Path ([string]$pathProp.Value) ([string]$nameProp.Value)); Known = $known; Configured = $configured
                    }
                }
                break
            }
            catch { $launchers += [pscustomobject]@{ Exe = "(could not read $j)"; Known = $false; Configured = $true } }
        }
        $out += [pscustomobject]@{ Folder = $folder; Jsons = $jsons; Launchers = $launchers }
    }
    return $out
}

function Invoke-RetireLegacyStartup {
    <#
        Renames every StartupLauncher's JSON files once nothing it starts is
        still configured - call it after renaming the screens' configs.
        Returns Renamed (@{From; To} as the kiosk sees them) and Kept (why a
        StartupLauncher was left alone).
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][string]$Tag, $Cmdlet)

    $renamed = @(); $kept = @()
    foreach ($sl in @(Get-LegacyStartupLaunchers -Root $Root -HostName $HostName)) {
        if ($sl.Jsons.Count -eq 0) { continue }
        $still = @($sl.Launchers | Where-Object { $_.Configured })
        if ($still.Count) {
            $kept += ('{0} still starts {1}' -f (ConvertTo-LegacyKioskPath -Path $sl.Folder -Root $Root), (($still | ForEach-Object { $_.Exe }) -join ', '))
            continue
        }
        foreach ($j in $sl.Jsons) {
            $to = Disable-LegacyJson -Path $j -Tag $Tag -Cmdlet $Cmdlet
            if ($to) { $renamed += [pscustomobject]@{ From = (ConvertTo-LegacyKioskPath -Path $j -Root $Root); To = (ConvertTo-LegacyKioskPath -Path $to -Root $Root) } }
        }
    }
    return [pscustomobject]@{ Renamed = $renamed; Kept = $kept }
}

$ScreenLaunchers = [ordered]@{ 'MACH2' = 'Mach2LauncherNG'; 'PBI' = 'PbiLauncher'; 'WEB' = 'WebLauncher' }
$ScreenLauncherTitles = @{ 'MACH2' = 'Mach2 Launcher NG'; 'PBI' = 'PBI Launcher'; 'WEB' = 'Web Launcher' }

function Get-ScreenOwners {
    <#
        Which of the new launchers has a config for which screen on this
        kiosk: a hashtable S1 -> MACH2 / PBI / WEB. One screen, one launcher -
        a deploy must not set up a screen another launcher has. PBI
        Launcher's config from before the screen folders (next to its
        script) is its S1.
    #>
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$HostName)
    $owners = @{}
    foreach ($kind in $ScreenLaunchers.Keys) {
        $base = Join-Path $Root "Users\Public\Documents\$($ScreenLaunchers[$kind])"
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^S\d+$' })) {
            if (Test-Path -LiteralPath (Join-Path $d.FullName "$HostName.json")) {
                $s = $d.Name.ToUpperInvariant()
                if (-not $owners.ContainsKey($s)) { $owners[$s] = $kind }
            }
        }
        if ($kind -eq 'PBI' -and -not $owners.ContainsKey('S1') -and (Test-Path -LiteralPath (Join-Path $base "$HostName.json"))) { $owners['S1'] = 'PBI' }
    }
    return $owners
}

function Undo-LegacyJsonRenames {
    # Rollback: every {From; To} recorded, renamed back. Returns how many.
    param([Parameter(Mandatory)][string]$Root, [array]$Records, $Cmdlet)
    $n = 0
    foreach ($rec in @($Records | Where-Object { $_ -and $_.To })) {
        if (Enable-LegacyJson -DisabledPath (ConvertFrom-LegacyKioskPath -Path ([string]$rec.To) -Root $Root) -Cmdlet $Cmdlet) { $n++ }
    }
    return $n
}
