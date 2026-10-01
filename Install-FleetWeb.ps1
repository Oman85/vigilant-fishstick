#Requires -Version 5.1
<#
.SYNOPSIS
    Sets Kiosk Fleet Web up on this PC as a server: the address reserved
    for its account, the firewall opened, the certificate bound (for
    HTTPS), the local accounts file locked down, and a scheduled task that
    starts it with the PC and restarts it if it stops.

.DESCRIPTION
    Run once, as an administrator, on the one PC that serves the page - the
    same PC that runs the collector (see "One collector" in README.md).

    The server runs as -ServiceAccount: an AD account (or a gMSA, ending in
    $) with admin rights on the kiosks. It is also the account that must
    hold the saved kiosk-admin credential, because that file is
    DPAPI-encrypted for the account that saved it. This script says how to
    save it as that account when it is not there yet.

    Nothing here touches a kiosk. -Uninstall takes it all away again.

.PARAMETER ServiceAccount
    DOMAIN\account the server runs as. A gMSA (DOMAIN\name$) needs no
    password; any other account is asked for its password once, for the
    scheduled task.

.PARAMETER Port
    Default 8080 for HTTP, 8443 with -CertificateThumbprint.

.PARAMETER CertificateThumbprint
    A certificate in LocalMachine\My for this PC's name, from the internal
    CA. With it the page is served over HTTPS only.

.PARAMETER AllowHttp
    Serve plain HTTP on the network (no certificate yet).

.EXAMPLE
    .\Install-FleetWeb.ps1 -ServiceAccount 'CONTOSO\svc-kioskfleet' -AllowHttp -AdminGroup 'CONTOSO\KioskFleet-Admins' -OperatorGroup 'CONTOSO\KioskFleet-Operators'

.EXAMPLE
    .\Install-FleetWeb.ps1 -ServiceAccount 'CONTOSO\gmsa-kioskfleet$' -CertificateThumbprint 3F1C...A9 -AdminGroup 'CONTOSO\KioskFleet-Admins' -OperatorGroup 'CONTOSO\KioskFleet-Operators'

.EXAMPLE
    .\Install-FleetWeb.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install', Mandatory)][string]$ServiceAccount,
    [Parameter(ParameterSetName = 'Install')][int]$Port,
    [Parameter(ParameterSetName = 'Install')][string]$CertificateThumbprint,
    [Parameter(ParameterSetName = 'Install')][switch]$AllowHttp,
    [Parameter(ParameterSetName = 'Install')][string]$AdminGroup = 'KioskFleet-Admins',
    [Parameter(ParameterSetName = 'Install')][string]$OperatorGroup = 'KioskFleet-Operators',
    [Parameter(ParameterSetName = 'Install')][switch]$NoWindowsAuth,
    [Parameter(ParameterSetName = 'Install')][switch]$NoLocalAccounts,
    [Parameter(ParameterSetName = 'Install')][switch]$AutoScan,
    [Parameter(ParameterSetName = 'Install')][switch]$NoFirewall,
    [Parameter(ParameterSetName = 'Uninstall', Mandatory)][switch]$Uninstall,
    [Parameter(ParameterSetName = 'Uninstall')][int]$UninstallPort,
    [string]$TaskName = 'Kiosk Fleet Web'
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$FirewallName = 'Kiosk Fleet Web'
# Any fixed GUID will do: netsh only records which application owns the binding.
$AppId = '{6b0b9b3e-4f53-4c7e-9a5e-0d6f1f2b7a61}'

$me = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $me.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this as an administrator.' }

function Invoke-Netsh {
    param([string[]]$Arguments, [switch]$Quiet)
    $out = & netsh.exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $Quiet) { throw ("netsh {0} failed: {1}" -f ($Arguments -join ' '), ($out -join ' ')) }
    return $out
}

if ($Uninstall) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        # The prefix the task was started with tells which port to free.
        $argsText = [string]$task.Actions[0].Arguments
        if (-not $UninstallPort -and $argsText -match ':(\d+)/') { $UninstallPort = [int]$Matches[1] }
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed the scheduled task '$TaskName'."
    }
    if ($UninstallPort) {
        foreach ($scheme in @('http', 'https')) { [void](Invoke-Netsh -Quiet @('http', 'delete', 'urlacl', "url=${scheme}://+:$UninstallPort/")) }
        [void](Invoke-Netsh -Quiet @('http', 'delete', 'sslcert', "ipport=0.0.0.0:$UninstallPort"))
        Write-Host "Freed port $UninstallPort."
    }
    Get-NetFirewallRule -DisplayName $FirewallName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    Write-Host 'Done. Config\web-users.json and the logs are left where they are.'
    return
}

$https = [bool]$CertificateThumbprint
if (-not $https -and -not $AllowHttp) { throw 'Say -CertificateThumbprint <thumbprint> for HTTPS, or -AllowHttp to serve unencrypted HTTP for now.' }
if (-not $Port) { $Port = $(if ($https) { 8443 } else { 8080 }) }
$scheme = $(if ($https) { 'https' } else { 'http' })
$prefix = '{0}://+:{1}/' -f $scheme, $Port
$isGmsa = $ServiceAccount.EndsWith('$')

# The account must exist, and is written as AD knows it.
try { $sid = (New-Object Security.Principal.NTAccount($ServiceAccount)).Translate([Security.Principal.SecurityIdentifier]) }
catch { throw "There is no account '$ServiceAccount'." }

# 1. The address, reserved for the server's account (it does not run as admin).
[void](Invoke-Netsh -Quiet @('http', 'delete', 'urlacl', "url=$prefix"))
[void](Invoke-Netsh @('http', 'add', 'urlacl', "url=$prefix", "user=$ServiceAccount"))
Write-Host "Reserved $prefix for $ServiceAccount."

# 2. The certificate, for HTTPS.
if ($https) {
    $thumb = ($CertificateThumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
    $cert = Get-Item -LiteralPath "Cert:\LocalMachine\My\$thumb" -ErrorAction SilentlyContinue
    if (-not $cert) { throw "No certificate $thumb in LocalMachine\My." }
    if (-not $cert.HasPrivateKey) { throw "The certificate $thumb has no private key on this PC." }
    if ($cert.NotAfter -lt (Get-Date)) { throw "The certificate $thumb expired on $($cert.NotAfter)." }
    [void](Invoke-Netsh -Quiet @('http', 'delete', 'sslcert', "ipport=0.0.0.0:$Port"))
    [void](Invoke-Netsh @('http', 'add', 'sslcert', "ipport=0.0.0.0:$Port", "certhash=$thumb", "appid=$AppId"))
    Write-Host ("Bound {0} ({1}, until {2:yyyy-MM-dd}) to port {3}." -f $thumb, $cert.Subject, $cert.NotAfter, $Port)
}

# 3. The firewall: domain network only.
if (-not $NoFirewall) {
    Get-NetFirewallRule -DisplayName $FirewallName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $FirewallName -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Domain | Out-Null
    Write-Host "Opened TCP $Port inbound on the domain network."
}

# 4. The local accounts file and the logs: the server's account may write
#    them, the PC's administrators may, nobody else may read them.
$configDir = Join-Path $ScriptDir 'Config'
$logDir = Join-Path $ScriptDir 'Logs'
foreach ($d in @($configDir, $logDir)) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }
$usersFile = Join-Path $configDir 'web-users.json'
if (-not (Test-Path -LiteralPath $usersFile)) { [IO.File]::WriteAllText($usersFile, '{ "Version": 1, "Users": [] }') }
$acl = New-Object Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
foreach ($who in @(
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')),  # Administrators
        (New-Object Security.Principal.SecurityIdentifier('S-1-5-18')))) {   # SYSTEM
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($who, 'FullControl', 'Allow')))
}
$acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'Modify', 'Allow')))
Set-Acl -LiteralPath $usersFile -AclObject $acl
$logAcl = Get-Acl -LiteralPath $logDir
$logAcl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($sid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
Set-Acl -LiteralPath $logDir -AclObject $logAcl
Write-Host "Locked down $usersFile; $ServiceAccount can write to Logs."

# 5. The scheduled task: at startup, as the service account, restarted if it stops.
$server = Join-Path $ScriptDir 'Start-FleetWeb.ps1'
$argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $server), '-Prefix', $prefix,
    '-AdminGroup', ('"{0}"' -f $AdminGroup), '-OperatorGroup', ('"{0}"' -f $OperatorGroup))
if ($AllowHttp -and -not $https) { $argList += '-AllowHttp' }
if ($NoWindowsAuth) { $argList += '-NoWindowsAuth' }
if ($NoLocalAccounts) { $argList += '-NoLocalAccounts' }
if ($AutoScan) { $argList += '-AutoScan' }
$action = New-ScheduledTaskAction -Execute (Join-Path $PSHOME 'powershell.exe') -Argument ($argList -join ' ') -WorkingDirectory $ScriptDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
    -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
if ($isGmsa) {
    $principal = New-ScheduledTaskPrincipal -UserId $ServiceAccount -LogonType Password -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
        -Description 'Kiosk Fleet Web: the fleet dashboard on the intranet (Start-FleetWeb.ps1).' | Out-Null
}
else {
    $cred = Get-Credential -UserName $ServiceAccount -Message "The password of $ServiceAccount, for the scheduled task"
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -RunLevel Limited `
        -User $ServiceAccount -Password $cred.GetNetworkCredential().Password `
        -Description 'Kiosk Fleet Web: the fleet dashboard on the intranet (Start-FleetWeb.ps1).' | Out-Null
}
Write-Host "Registered the scheduled task '$TaskName' (at startup, as $ServiceAccount)."

# What is left to do by hand.
$fqdn = [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
Write-Host ''
Write-Host 'Before starting it:' -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath (Join-Path $configDir 'kiosk-admin.cred.xml'))) {
    Write-Host ("  - Save the kiosk-admin credential AS {0} (it only opens for the account that saved it):" -f $ServiceAccount)
    Write-Host ("      runas /user:{0} ""powershell -NoProfile -ExecutionPolicy Bypass -File \""{1}\""""" -f $ServiceAccount, (Join-Path $ScriptDir 'Save-KioskCredential.ps1'))
    if ($isGmsa) { Write-Host '    (a gMSA cannot log on interactively: run Save-KioskCredential.ps1 from a one-off scheduled task as the gMSA instead)' }
}
else { Write-Host '  - A saved kiosk-admin credential is there; it must have been saved by the service account.' }
if (-not $NoWindowsAuth) {
    Write-Host ("  - Make sure {0} and {1} exist in AD." -f $AdminGroup, $OperatorGroup)
    Write-Host ("  - For Kerberos (no prompt, no NTLM): setspn -S HTTP/{0} {1}" -f $fqdn, $ServiceAccount)
    Write-Host ("    and put {0}://{1}:{2} in the Local intranet zone by GPO." -f $scheme, $fqdn, $Port)
}
Write-Host ("  - Optionally a break-glass local account: .\Set-FleetWebUser.ps1 -Name breakglass -Role admin")
Write-Host ''
Write-Host ("Then: Start-ScheduledTask -TaskName '{0}', and open {1}://{2}:{3}/" -f $TaskName, $scheme, $fqdn, $Port)
