#Requires -Version 5.1
<#
.SYNOPSIS
    Shows what Web Launcher is doing on each kiosk, screen by screen.

.DESCRIPTION
    Get-PbiLauncherStatus.ps1 -Launcher Web: the same table, read the same
    way (the status file in C:\Users\Public\Documents\WebLauncher\S<n>\
    Status\ over the admin share). Nothing on the kiosk is changed.

    Launcher states: SHOWING, BROWSING (someone followed a link), LOADING,
    RECOVERING, WAITING_DISPLAY, HOLD, ERROR, UNSUPERVISED, DISABLED,
    STOPPED, RESTARTING_PC. STALE, NOT_INSTALLED, NO_STATUS, OFFLINE and
    NO_ACCESS come from the tool.

.PARAMETER Hosts
    Kiosks to check. Default: every active Web kiosk in the kiosk list.

.EXAMPLE
    .\Get-WebLauncherStatus.ps1 -Hosts SHCZ5KPI11980
#>
[CmdletBinding()]
param(
    [string[]]$Hosts,
    [string]$KioskList,
    [string]$FleetRoot,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredentialFile,
    [switch]$PassThru,
    [string]$RootTemplate = '\\{0}\C$'
)

$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$PSBoundParameters['Launcher'] = 'Web'
& (Join-Path $here 'Get-PbiLauncherStatus.ps1') @PSBoundParameters
