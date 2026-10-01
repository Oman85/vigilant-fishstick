#Requires -Version 5.1
<#
.SYNOPSIS
    Saves the kiosk-admin credential for unattended collector runs.

.DESCRIPTION
    Prompts for the AD account that has admin rights on the kiosks, proves it
    works against one kiosk (admin share and remote event log), and only then
    saves it to Config\kiosk-admin.cred.xml.

    The file is encrypted with DPAPI by Export-Clixml. That ties it to the
    Windows account that ran this script, on this machine: nobody else, and no
    other machine, can decrypt it. It also means two things in practice:

      - run this as the same account the scheduled task runs as (you), and
      - run it again whenever the admin account's password changes. Until you
        do, scans report NO_ACCESS for every kiosk.

    Testing before saving matters because a mistyped password would otherwise
    only surface as a fleet of NO_ACCESS rows the next morning - and repeated
    failed logons can lock the admin account.

.PARAMETER Path
    Where to save. Default: Config\kiosk-admin.cred.xml next to this script.

.PARAMETER TestHost
    Kiosk to test against. Default: the first HAS MWST = Y kiosk in the list.

.PARAMETER NoTest
    Save without testing (e.g. when no kiosk is currently reachable).
#>

[CmdletBinding()]
param(
    [string]$Path,
    [string]$TestHost,
    [switch]$NoTest
)

Set-StrictMode -Off

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'Lib\MWST.KioskList.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.Remote.ps1')

if (-not $Path) { $Path = Join-Path $ScriptDir 'Config\kiosk-admin.cred.xml' }

$cred = Get-Credential -Message 'AD account with admin rights on the kiosks (DOMAIN\user)'
if (-not $cred) { Write-Host 'Cancelled - nothing saved.'; return }

if (-not $NoTest) {
    if (-not $TestHost) {
        $listInfo = Resolve-KioskListPath -ScriptDir $ScriptDir
        if ($listInfo.Path) {
            $first = Import-KioskList -Path $listInfo.Path | Where-Object { $_.RunsWatchdog } | Select-Object -First 1
            if ($first) { $TestHost = $first.Host }
        }
    }

    if (-not $TestHost) {
        Write-Warning 'No kiosk to test against (no list found). Use -TestHost, or -NoTest to save untested.'
        return
    }

    Write-Host "Testing the credential against $TestHost..."
    $reach = Test-HostReachable -HostName $TestHost
    if (-not $reach.Ok) {
        Write-Warning "$TestHost is not reachable ($($reach.Error)). Pick another with -TestHost, or use -NoTest."
        return
    }

    $folder = '\\{0}\C$\Users\Public\Documents' -f $TestHost
    $drive = $null
    try {
        $drive = Connect-KioskShare -Folder $folder -Credential $cred
        if (-not (Test-Path -LiteralPath $folder)) { throw "Connected, but $folder is not visible." }
        Write-Host '  admin share  ok' -ForegroundColor Green
    }
    catch {
        Write-Host "  admin share  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Nothing saved.' -ForegroundColor Red
        return
    }
    finally {
        Disconnect-KioskShare -Drive $drive
    }

    try {
        Get-WinEvent -ComputerName $TestHost -Credential $cred -FilterHashtable @{ LogName = 'System'; Id = 6005 } -MaxEvents 1 -ErrorAction Stop | Out-Null
        Write-Host '  event log    ok' -ForegroundColor Green
    }
    catch {
        if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') {
            Write-Host '  event log    ok' -ForegroundColor Green
        }
        else {
            # Expected on a zero-trust network, and it does not matter: each
            # kiosk reads its own System log and copies the reboot records
            # into its ledger, which the collector reads over the admin share.
            # Only the optional -RemoteEventLog needs this to work.
            Write-Host "  event log    not reachable across the network" -ForegroundColor DarkGray
            Write-Host "               ($($_.Exception.Message))" -ForegroundColor DarkGray
            Write-Host '               That is fine: the kiosks read their own System logs and the' -ForegroundColor DarkGray
            Write-Host '               collector picks the records up from the ledger. Only the' -ForegroundColor DarkGray
            Write-Host '               optional -RemoteEventLog switch needs this path.' -ForegroundColor DarkGray
        }
    }
}

$dir = Split-Path -Parent $Path
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

$cred | Export-Clixml -LiteralPath $Path

Write-Host ''
Write-Host "Saved credential for $($cred.UserName) to $Path" -ForegroundColor Green
Write-Host "Only $env:USERDOMAIN\$env:USERNAME on $env:COMPUTERNAME can decrypt it."
Write-Host 'Run this again whenever that account''s password changes.'
