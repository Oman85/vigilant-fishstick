#Requires -Version 5.1
<#
.SYNOPSIS
    Shows a message on kiosks whose watchdog is V7.0 or later.

.DESCRIPTION
    The message appears in a large window on the kiosk, with an OK button and
    a countdown, and closes itself when the countdown runs out. Each kiosk is
    reported on as it goes: shown, acknowledged (OK pressed), timed out, or
    why it could not be delivered.

    The watchdog picks messages up on its next screen check, so within about
    ten seconds. A message nobody picks up within -WaitSeconds is withdrawn.
    Kiosks still on V6.1 have no message inbox and are reported as NOT_SENT.

    The same thing is on the dashboard's M key.

.PARAMETER Hosts
    One or more kiosks; a comma-separated list works too.

.PARAMETER Text
    The message. `n in the text starts a new line.

.PARAMETER Title
    Shown above the message. Default: Message from IT.

.PARAMETER Seconds
    How long the message stays up unless OK is pressed. 5-900, default 60.

.PARAMETER WaitForClose
    Wait until each message is closed and report how (OK or countdown),
    instead of moving on once it is on screen.

.PARAMETER PassThru
    Also return one result object per kiosk (Host, Id, Status, Detail).

.EXAMPLE
    .\Send-KioskMessage.ps1 -Hosts SHCZ5KPI6082 -Text 'Planned restart at 14:00'

.EXAMPLE
    .\Send-KioskMessage.ps1 -Hosts SHCZ5KPI6082,SHCZ5KPI9093 -Text "Line 1`nLine 2" -Seconds 120 -WaitForClose
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Hosts,
    [Parameter(Mandatory)][string]$Text,
    [string]$Title = 'Message from IT',
    [ValidateRange(5, 900)][int]$Seconds = 60,
    [ValidateRange(10, 600)][int]$WaitSeconds = 45,
    [switch]$WaitForClose,
    [System.Management.Automation.PSCredential]$Credential,
    [string]$CredentialFile,
    [switch]$PassThru
)

Set-StrictMode -Off

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $ScriptDir 'Lib\MWST.Remote.ps1')
. (Join-Path $ScriptDir 'Lib\MWST.Message.ps1')

if (-not $CredentialFile) {
    $default = Join-Path $ScriptDir 'Config\kiosk-admin.cred.xml'
    if (Test-Path -LiteralPath $default) { $CredentialFile = $default }
}
if (-not $Credential -and $CredentialFile) { $Credential = Import-StoredCredential -Path $CredentialFile }

$targets = @($Hosts | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)

foreach ($h in $targets) {
    Write-Host ("{0}" -f $h) -ForegroundColor White
    $r = Invoke-KioskMessage -HostName $h -Text $Text -Title $Title -Seconds $Seconds -WaitSeconds $WaitSeconds `
                             -WaitForClose:$WaitForClose -Credential $Credential `
                             -Progress { param($s) Write-Host "  $s" -ForegroundColor DarkGray }

    $colour = switch ($r.Status) {
        'ACKNOWLEDGED' { 'Green' }
        'SHOWN'        { 'Green' }
        'TIMEOUT'      { 'Cyan' }
        default        { 'Yellow' }
    }
    Write-Host ("  {0,-13} {1}" -f $r.Status, $r.Detail) -ForegroundColor $colour
    if ($PassThru) { $r }
}
