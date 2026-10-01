#Requires -Version 5.1
<#
.SYNOPSIS
    The web dashboard's local accounts: add one, set its password or role,
    disable, enable or remove it, or list them.

.DESCRIPTION
    Local accounts are for when Windows sign-in cannot be used - no AD, a
    PC outside the domain, AD itself being the problem. People normally
    sign in with their own Windows account instead (Start-FleetWeb.ps1
    -AdminGroup / -OperatorGroup), and need nothing here.

    Each account has a role - admin or operator - and a salted
    PBKDF2-SHA256 hash of its password in Config\web-users.json. The
    password itself is never stored. A running server picks up a change
    within seconds: a removed or disabled account is signed out at once,
    and a changed role applies to the next thing that account does.

    Keep the file readable only by the server's account and the PC's
    administrators; Install-FleetWeb.ps1 sets that up.

.EXAMPLE
    .\Set-FleetWebUser.ps1 -Name breakglass -Role admin
    Asks for the password twice and adds the account (or sets its password).

.EXAMPLE
    .\Set-FleetWebUser.ps1 -Name nightshift -Role operator

.EXAMPLE
    .\Set-FleetWebUser.ps1 -Name nightshift -Disable

.EXAMPLE
    .\Set-FleetWebUser.ps1 -List
#>
[CmdletBinding(DefaultParameterSetName = 'Set')]
param(
    [Parameter(ParameterSetName = 'Set', Mandatory)]
    [Parameter(ParameterSetName = 'Disable', Mandatory)]
    [Parameter(ParameterSetName = 'Enable', Mandatory)]
    [Parameter(ParameterSetName = 'Remove', Mandatory)]
    [string]$Name,
    [Parameter(ParameterSetName = 'Set')][ValidateSet('admin', 'operator')][string]$Role,
    # For scripts: the password as a SecureString instead of asking.
    [Parameter(ParameterSetName = 'Set')][System.Security.SecureString]$Password,
    # Keep the password, change only the role.
    [Parameter(ParameterSetName = 'Set')][switch]$RoleOnly,
    [Parameter(ParameterSetName = 'Disable', Mandatory)][switch]$Disable,
    [Parameter(ParameterSetName = 'Enable', Mandatory)][switch]$Enable,
    [Parameter(ParameterSetName = 'Remove', Mandatory)][switch]$Remove,
    [Parameter(ParameterSetName = 'List', Mandatory)][switch]$List,
    [string]$UsersFile
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'Lib\Fleet.WebAuth.ps1')
if (-not $UsersFile) { $UsersFile = Join-Path $ScriptDir 'Config\web-users.json' }

$users = New-Object System.Collections.ArrayList
foreach ($u in @(Read-FleetWebUsers -Path $UsersFile)) { [void]$users.Add($u) }

function Get-PlainText {
    param([System.Security.SecureString]$Secure)
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

if ($List) {
    if ($users.Count -eq 0) { Write-Host "No local accounts in $UsersFile."; return }
    $users | Sort-Object Name | Select-Object Name, Role,
        @{ n = 'State'; e = { if ($_.Disabled) { 'disabled' } else { 'enabled' } } },
        @{ n = 'Password set'; e = { $_.PasswordSet } }, @{ n = 'By'; e = { $_.SetBy } } | Format-Table -AutoSize
    return
}

if (-not (Test-FleetUserName $Name)) { throw 'An account name is 2 to 40 letters, digits, dots, dashes or underscores, starting with a letter or digit.' }
$existing = @($users | Where-Object { ([string]$_.Name).Equals($Name, [StringComparison]::OrdinalIgnoreCase) })[0]
$by = '{0}\{1}' -f [Environment]::UserDomainName, [Environment]::UserName

switch ($PSCmdlet.ParameterSetName) {
    'Remove' {
        if (-not $existing) { throw "There is no account '$Name'." }
        $users.Remove($existing)
        Save-FleetWebUsers -Path $UsersFile -Users @($users)
        Write-Host "Removed '$Name'. If it was signed in, it is signed out within seconds."
        return
    }
    { $_ -in @('Disable', 'Enable') } {
        if (-not $existing) { throw "There is no account '$Name'." }
        $existing | Add-Member -NotePropertyName Disabled -NotePropertyValue ([bool]$Disable) -Force
        Save-FleetWebUsers -Path $UsersFile -Users @($users)
        Write-Host $(if ($Disable) { "Disabled '$Name'. If it was signed in, it is signed out within seconds." } else { "Enabled '$Name'." })
        return
    }
}

# Set: a new account, a new password, or a new role.
if (-not $existing -and -not $Role) { throw "A new account needs -Role admin or -Role operator." }
if ($RoleOnly) {
    if (-not $existing) { throw "There is no account '$Name' to change the role of." }
    if (-not $Role) { throw '-RoleOnly needs -Role.' }
    $existing | Add-Member -NotePropertyName Role -NotePropertyValue $Role -Force
    Save-FleetWebUsers -Path $UsersFile -Users @($users)
    Write-Host "'$Name' is now $Role."
    return
}

if (-not $Password) {
    $Password = Read-Host -AsSecureString "New password for '$Name'"
    $again = Read-Host -AsSecureString 'Again'
    if ((Get-PlainText $Password) -cne (Get-PlainText $again)) { throw 'The two did not match. Nothing was changed.' }
}
$plain = Get-PlainText $Password
$weak = Test-FleetPasswordStrength -Password $plain -UserName $Name
if ($weak) { $plain = $null; throw "The password needs to be stronger: $weak." }
$hash = New-FleetPasswordHash -Password $plain
$plain = $null

$record = [pscustomobject]@{
    Name = $(if ($existing) { $existing.Name } else { $Name })
    Role = $(if ($Role) { $Role } else { $existing.Role })
    Disabled = $(if ($existing) { [bool]$existing.Disabled } else { $false })
    Algorithm = $hash.Algorithm; Iterations = $hash.Iterations; Salt = $hash.Salt; Hash = $hash.Hash
    PasswordSet = (Get-Date).ToString('yyyy-MM-dd HH:mm'); SetBy = $by
}
if ($existing) { $users.Remove($existing) }
[void]$users.Add($record)
Save-FleetWebUsers -Path $UsersFile -Users @($users)
Write-Host $(if ($existing) { "Password set for '$($record.Name)' ($($record.Role))." } else { "Added '$($record.Name)' as $($record.Role)." })
