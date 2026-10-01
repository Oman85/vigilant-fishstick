<#
.SYNOPSIS
    Who may use the web dashboard, and what they may do: the two roles,
    what each one is allowed, and the local break-glass accounts.

.DESCRIPTION
    Dot-sourced by Start-FleetWeb.ps1 and Set-FleetWebUser.ps1.

    Two roles:

      operator  sees everything, and can do what cannot break a kiosk:
                scan now, read live, screenshot, reload, restart the
                browser, a message on the screen, the launcher log
      admin     everything: restart a kiosk, hold/resume, stop, the
                sign-in password, the kiosk config, deploy and roll back,
                auto-scan, stopping a run, the audit log

    People normally sign in with their own Windows account; the role comes
    from AD group membership (Start-FleetWeb.ps1 -AdminGroup and
    -OperatorGroup). Local accounts are for when AD is not there: a few
    names in Config\web-users.json, each with a role and a salted
    PBKDF2-SHA256 hash of its password - never the password itself.
#>

Set-StrictMode -Off

$FleetRoleRank = @{ operator = 1; admin = 2 }

# The least role each thing needs. Anything not listed needs admin.
$FleetPermissions = @{
    view      = 'operator'
    scan      = 'operator'
    live      = 'operator'
    snapshot  = 'operator'
    reload    = 'operator'
    relaunch  = 'operator'
    message   = 'operator'
    log       = 'operator'
    restart   = 'admin'
    hold      = 'admin'
    resume    = 'admin'
    stop      = 'admin'
    password  = 'admin'
    config    = 'admin'
    deploy    = 'admin'
    autoscan  = 'admin'
    stoprun   = 'admin'
    audit     = 'admin'
}

function Test-FleetPermission {
    param([string]$Role, [string]$Action)
    if (-not $Role -or -not $FleetRoleRank.ContainsKey($Role)) { return $false }
    $need = $(if ($FleetPermissions.ContainsKey($Action)) { $FleetPermissions[$Action] } else { 'admin' })
    return ($FleetRoleRank[$Role] -ge $FleetRoleRank[$need])
}

function Get-FleetAllowedActions {
    param([string]$Role)
    return @($FleetPermissions.Keys | Where-Object { Test-FleetPermission -Role $Role -Action $_ } | Sort-Object)
}

# ---------------------------------------------------------------------------
# Password hashes
# ---------------------------------------------------------------------------
$FleetHashIterations = 210000

function Get-FleetPbkdf2 {
    param([byte[]]$Password, [byte[]]$Salt, [int]$Iterations, [int]$Bytes = 32)
    # PBKDF2 with SHA-256 needs .NET Framework 4.7.2 or later (Windows 10
    # 1803 and up have it).
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $Salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    try { return $kdf.GetBytes($Bytes) }
    finally { $kdf.Dispose() }
}

function New-FleetRandomBytes {
    param([int]$Count = 32)
    $b = New-Object byte[] $Count
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return , $b
}

function New-FleetToken {
    # 256 random bits, URL-safe.
    return ([Convert]::ToBase64String((New-FleetRandomBytes 32)).TrimEnd('=').Replace('+', '-').Replace('/', '_'))
}

function Test-FleetBytesEqual {
    # The same time whatever the bytes, so a guess learns nothing from how
    # long the answer took.
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    $diff = $A.Length -bxor $B.Length
    for ($i = 0; $i -lt [math]::Min($A.Length, $B.Length); $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    return ($diff -eq 0)
}

function New-FleetPasswordHash {
    param([Parameter(Mandatory)][string]$Password, [int]$Iterations = $FleetHashIterations)
    $salt = New-FleetRandomBytes 16
    $hash = Get-FleetPbkdf2 -Password ([Text.Encoding]::UTF8.GetBytes($Password)) -Salt $salt -Iterations $Iterations
    return [pscustomobject]@{
        Algorithm = 'PBKDF2-SHA256'; Iterations = $Iterations
        Salt = [Convert]::ToBase64String($salt); Hash = [Convert]::ToBase64String($hash)
    }
}

function Test-FleetPasswordHash {
    param($Record, [string]$Password)
    if (-not $Record -or -not $Record.Salt -or -not $Record.Hash -or $Record.Algorithm -ne 'PBKDF2-SHA256') { return $false }
    try {
        $salt = [Convert]::FromBase64String([string]$Record.Salt)
        $want = [Convert]::FromBase64String([string]$Record.Hash)
        $got = Get-FleetPbkdf2 -Password ([Text.Encoding]::UTF8.GetBytes([string]$Password)) -Salt $salt -Iterations ([int]$Record.Iterations) -Bytes $want.Length
        return (Test-FleetBytesEqual $got $want)
    }
    catch { return $false }
}

# ---------------------------------------------------------------------------
# The local accounts file
# ---------------------------------------------------------------------------
function Read-FleetWebUsers {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $text = [IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    $doc = ConvertFrom-Json -InputObject $text
    return @($doc.Users | Where-Object { $_ })
}

function Save-FleetWebUsers {
    param([Parameter(Mandatory)][string]$Path, [array]$Users)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $doc = [pscustomobject]@{ Version = 1; Users = @($Users | Sort-Object Name) }
    $tmp = "$Path.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $doc -Depth 5), (New-Object Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Test-FleetUserName {
    param([string]$Name)
    return ($Name -match '^[A-Za-z0-9][A-Za-z0-9._-]{1,39}$')
}

function Test-FleetPasswordStrength {
    # Returns why a password is not good enough, or $null.
    param([string]$Password, [string]$UserName)
    if (-not $Password -or $Password.Length -lt 12) { return 'at least 12 characters' }
    if ($UserName -and $Password.IndexOf($UserName, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'not containing the account name' }
    $kinds = 0
    foreach ($re in @('[a-z]', '[A-Z]', '[0-9]', '[^A-Za-z0-9]')) { if ($Password -cmatch $re) { $kinds++ } }
    if ($kinds -lt 3 -and $Password.Length -lt 20) { return 'three of: lower case, upper case, digits, symbols (or 20 characters or more)' }
    return $null
}

$script:FleetDummyHash = $null
function Find-FleetLocalUser {
    <#
        The account for a name and password, or $null. A name that does not
        exist costs the same work as one that does, so how long it takes says
        nothing about which names are real.
    #>
    param([array]$Users, [string]$Name, [string]$Password)
    $user = @($Users | Where-Object { $_.Name -and ([string]$_.Name).Equals($Name, [StringComparison]::OrdinalIgnoreCase) })[0]
    if (-not $user) {
        if (-not $script:FleetDummyHash) { $script:FleetDummyHash = New-FleetPasswordHash -Password ([guid]::NewGuid().ToString()) }
        [void](Test-FleetPasswordHash -Record $script:FleetDummyHash -Password $Password)
        return $null
    }
    $ok = Test-FleetPasswordHash -Record $user -Password $Password
    if (-not $ok -or $user.Disabled) { return $null }
    if (-not $FleetRoleRank.ContainsKey([string]$user.Role)) { return $null }
    return $user
}
